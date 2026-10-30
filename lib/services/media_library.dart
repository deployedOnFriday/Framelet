import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/media_source.dart';
import 'credential_store.dart';
import 'scraper_service.dart';
import 'webdav_service.dart';

enum ScanStatus { idle, scanning, done, failed }

/// 媒体库全局状态：媒体源配置、扫描结果与分类视图。
class MediaLibrary extends ChangeNotifier {
  MediaLibrary({CredentialStore? store}) : _store = store ?? CredentialStore();

  static MediaLibrary? _instance;

  static MediaLibrary get instance => _instance ??= MediaLibrary();

  /// 测试用：替换全局实例，避免触达真实系统存储。
  @visibleForTesting
  static set instanceForTesting(MediaLibrary library) => _instance = library;

  final CredentialStore _store;

  final List<MediaSource> _sources = [];
  final Map<String, String> _passwords = {};
  final Map<String, List<ScannedVideo>> _videosBySource = {};
  final Map<String, String> _sourceErrors = {};

  ScanStatus scanStatus = ScanStatus.idle;
  String scanProgress = '';

  bool scraping = false;
  String scrapeProgress = '';
  int scrapeDone = 0;
  int scrapeTotal = 0;

  /// 刮削设置（TMDB 密钥与可选代理），保存于安全存储。
  String? scrapeProxy;
  String? tmdbKey;

  bool get hasTmdb => (tmdbKey ?? '').trim().isNotEmpty;

  String get scraperSourceLabel => hasTmdb ? 'TMDB + TVmaze' : 'TVmaze（免费）';

  List<MediaSource> get sources => List.unmodifiable(_sources);

  MediaSource? sourceById(String id) {
    for (final source in _sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  String? errorOf(String sourceId) => _sourceErrors[sourceId];

  bool hasPassword(String sourceId) => _passwords.containsKey(sourceId);

  String? passwordOf(String sourceId) => _passwords[sourceId];

  /// 按 sourceId + 路径精确查找原始扫描条目（用于从播放历史续播）。
  ScannedVideo? findVideo(String sourceId, String path) {
    for (final videos in _videosBySource.values) {
      for (final video in videos) {
        if (video.sourceId == sourceId && video.path == path) return video;
      }
    }
    return null;
  }

  /// 某分类的聚合条目（跨所有媒体源）。
  ///
  /// 刮削后同一部剧的多季带有相同 TMDB ID，此时合并为一条展示，
  /// 集数取各季之和；详情页通过 seasonsOf 取回每一季。
  List<ScannedVideo> byKind(MediaKind kind) {
    // 先按文件夹聚合，再按聚合后的分类筛选：
    // 这样「想见你」这类 14 集的剧集不会留在电影分类里。
    final merged = <String, ScannedVideo>{};
    for (final entry in _videosBySource.entries) {
      final aggregated = aggregate(entry.value);
      for (final video in aggregated) {
        if (video.kind != kind) continue;
        final key = video.tmdbId != null
            ? 'tmdb|${video.tmdbId}'
            : '${video.sourceId}|${video.title.toLowerCase()}';
        final existing = merged[key];
        if (existing == null) {
          merged[key] = video;
        } else if (video.episodeCount > existing.episodeCount) {
          // 同一部剧的多季：集数相加展示
          merged[key] = video.copyWith(
            episodeCount: existing.episodeCount + video.episodeCount,
          );
        }
      }
    }
    final list = merged.values.toList()
      ..sort(
        (a, b) =>
            (b.modified ?? DateTime(0)).compareTo(a.modified ?? DateTime(0)),
      );
    return list;
  }

  /// 一部剧的每一季（跨文件夹）。单季剧集返回它自己。
  List<ScannedVideo> seasonsOf(ScannedVideo video) {
    final tmdbId = video.tmdbId;
    if (tmdbId == null) return [video];
    final seasons = <ScannedVideo>[];
    for (final videos in _videosBySource.values) {
      for (final item in aggregate(videos)) {
        if (item.tmdbId == tmdbId) seasons.add(item);
      }
    }
    seasons.sort((a, b) => seasonOf(a).compareTo(seasonOf(b)));
    return seasons.isEmpty ? [video] : seasons;
  }

  int countByKind(MediaKind kind) => byKind(kind).length;

  /// 某聚合条目对应的单集文件列表（电影返回自身）。
  ///
  /// 只按「同一媒体源 + 同一文件夹」收集，不再比较 kind——
  /// 旧缓存里组内文件的分类可能与聚合条目不一致，按 kind 过滤会漏掉整部剧。
  List<ScannedVideo> episodesOf(ScannedVideo video) {
    if (video.episodeCount <= 1) return [video];
    final parent = parentPathOf(video.path);
    final result = <ScannedVideo>[];
    for (final videos in _videosBySource.values) {
      for (final candidate in videos) {
        if (candidate.sourceId != video.sourceId) continue;
        if (WebDavService.isExtraFile(candidate.title)) continue;
        if (parentPathOf(candidate.path) != parent) continue;
        result.add(candidate);
      }
    }
    result.sort((a, b) => _naturalCompare(a.path, b.path));
    return result.isEmpty ? [video] : result;
  }

  /// 自然排序：让 第2集 排在 第10集 前面。
  static int _naturalCompare(String a, String b) {
    final numbers = RegExp(r'\d+');
    final aParts = a.split(numbers);
    final bParts = b.split(numbers);
    final aNums = numbers.allMatches(a).map((m) => int.parse(m.group(0)!));
    final bNums = numbers.allMatches(b).map((m) => int.parse(m.group(0)!));
    final aIter = aNums.iterator;
    final bIter = bNums.iterator;
    final length = aParts.length.clamp(0, bParts.length);
    for (var i = 0; i < length; i++) {
      final compare = aParts[i].compareTo(bParts[i]);
      if (compare != 0) return compare;
      final aHas = aIter.moveNext();
      final bHas = bIter.moveNext();
      if (aHas && bHas) {
        final numCompare = aIter.current.compareTo(bIter.current);
        if (numCompare != 0) return numCompare;
      }
    }
    return a.compareTo(b);
  }

  /// 从文件名中解析单集编号，仅支持 S01E02 / E02 / 第02集 / 纯数字。
  static int? episodeNumberOf(String title) {
    final patterns = [
      RegExp(r'[sS]\d{1,2}[eE](\d{1,3})'),
      RegExp(r'(?:^|[.\s_-])e(?:p)?(\d{1,3})(?:$|[.\s_-])'),
      RegExp(r'第\s*(\d{1,4})\s*[集话期]'),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(title);
      if (match?.group(1) case final number?) return int.tryParse(number);
    }
    // 结尾数字后允许带画质标记：01~4K、14_1080p
    final plain = RegExp(
      r'(\d{1,4})\s*[~\-_.]?\s*(4k|8k|1080p|720p|2160p|hdr10?)?\s*$',
      caseSensitive: false,
    ).firstMatch(title);
    return int.tryParse(plain?.group(1) ?? '');
  }

  bool get hasAnyContent =>
      _videosBySource.values.any((videos) => videos.isNotEmpty);

  /// 启动时恢复配置与凭据。
  Future<void> load() async {
    await _loadScrapeSettings();
    final raw = await _store.readSources();
    if (raw == null || raw.isEmpty) return;
    try {
      final list = (jsonDecode(raw) as List<Object?>)
          .map((item) => MediaSource.fromJson(item! as Map<String, Object?>))
          .toList();
      _sources
        ..clear()
        ..addAll(list);
      for (final source in _sources) {
        final password = await _store.readPassword(source.id);
        if (password != null) _passwords[source.id] = password;
        final videosRaw = await _store.read('framelet.videos.${source.id}');
        if (videosRaw != null && videosRaw.isNotEmpty) {
          try {
            _videosBySource[source.id] =
                (jsonDecode(videosRaw) as List<Object?>)
                    .map(
                      (item) =>
                          ScannedVideo.fromJson(item! as Map<String, Object?>),
                    )
                    .toList();
          } catch (_) {
            // 扫描缓存损坏时留空，用户手动同步即可。
          }
        }
      }
      notifyListeners();
      await _migrateKinds();
    } catch (_) {
      // 配置损坏时宁可重新添加，也不让应用崩溃。
    }
  }

  /// 旧版本扫描把带集数标记的剧集误判为电影，这里按文件名自动修正并回写。
  Future<void> _migrateKinds() async {
    var anyChanged = false;
    for (final entry in _videosBySource.entries) {
      final videos = entry.value;
      var changed = false;
      for (var i = 0; i < videos.length; i++) {
        final video = videos[i];
        if (video.kind == MediaKind.movie &&
            WebDavService.looksLikeEpisode(video.title)) {
          videos[i] = video.copyWith(kind: MediaKind.series);
          changed = true;
        }
      }
      if (changed) {
        anyChanged = true;
        await _persistVideos(entry.key);
      }
    }
    if (anyChanged) notifyListeners();
  }

  /// 读取刮削设置并注入到刮削服务。
  Future<void> _loadScrapeSettings() async {
    try {
      scrapeProxy = await _store.read('framelet.scrape.proxy');
      tmdbKey = await _store.read('framelet.scrape.tmdbkey');
      ScraperService.proxyAddress = (scrapeProxy ?? '').trim().isEmpty
          ? null
          : scrapeProxy!.trim();
      ScraperService.tmdbApiKey = (tmdbKey ?? '').trim().isEmpty
          ? null
          : tmdbKey!.trim();
    } catch (_) {
      // 读取失败不影响使用默认源
    }
  }

  /// 保存刮削设置。留空表示清除该项。
  Future<void> saveScrapeSettings({String? proxy, String? tmdbKey}) async {
    if (proxy != null) {
      scrapeProxy = proxy.trim();
      await _store.write('framelet.scrape.proxy', scrapeProxy!);
    }
    if (tmdbKey != null) {
      this.tmdbKey = tmdbKey.trim();
      await _store.write('framelet.scrape.tmdbkey', this.tmdbKey!);
    }
    ScraperService.proxyAddress = (scrapeProxy ?? '').trim().isEmpty
        ? null
        : scrapeProxy!.trim();
    ScraperService.tmdbApiKey = (this.tmdbKey ?? '').trim().isEmpty
        ? null
        : this.tmdbKey!.trim();
    notifyListeners();
  }

  Future<void> _persistSources() async {
    final json = jsonEncode(_sources.map((source) => source.toJson()).toList());
    await _store.writeSources(json);
  }

  Future<void> _persistVideos(String sourceId) async {
    final videos = _videosBySource[sourceId];
    if (videos == null || videos.isEmpty) {
      await _store.delete('framelet.videos.$sourceId');
      return;
    }
    await _store.write(
      'framelet.videos.$sourceId',
      jsonEncode(videos.map((video) => video.toJson()).toList()),
    );
  }

  /// 新增或更新媒体源。password 为空表示沿用已保存的密码。
  Future<void> addOrUpdateSource(MediaSource source, {String? password}) async {
    final index = _sources.indexWhere((item) => item.id == source.id);
    if (index >= 0) {
      _sources[index] = source;
    } else {
      _sources.add(source);
    }
    if (password != null && password.isNotEmpty) {
      _passwords[source.id] = password;
      await _store.writePassword(source.id, password);
    }
    await _persistSources();
    notifyListeners();
  }

  Future<void> deleteSource(String id) async {
    _sources.removeWhere((source) => source.id == id);
    _videosBySource.remove(id);
    _sourceErrors.remove(id);
    _passwords.remove(id);
    await _store.deletePassword(id);
    await _store.delete('framelet.videos.$id');
    await _persistSources();
    notifyListeners();
  }

  /// 连接测试。返回 null 表示成功，否则为可读错误信息。
  Future<String?> testConnection(MediaSource source, String password) async {
    try {
      await WebDavService.testConnection(source, password);
      return null;
    } catch (error) {
      return describeError(error);
    }
  }

  /// 全量扫描一个媒体源。完成后视频按分类就位。
  Future<void> scan(String sourceId) async {
    final source = sourceById(sourceId);
    final password = _passwords[sourceId];
    if (source == null) return;
    if (password == null) {
      _sourceErrors[sourceId] = '未保存密码，请编辑媒体源后重新输入';
      scanStatus = ScanStatus.failed;
      notifyListeners();
      return;
    }

    scanStatus = ScanStatus.scanning;
    scanProgress = '正在连接 ${source.name}…';
    _sourceErrors.remove(sourceId);
    notifyListeners();

    try {
      final videos = await WebDavService.scan(
        source,
        password,
        onProgress: (message) {
          scanProgress = message;
          notifyListeners();
        },
      );
      _videosBySource[sourceId] = videos;
      final now = DateTime.now();
      final index = _sources.indexWhere((item) => item.id == sourceId);
      if (index >= 0) {
        _sources[index] = _sources[index].copyWith(
          connected: true,
          lastSync:
              '${now.hour.toString().padLeft(2, '0')}:'
              '${now.minute.toString().padLeft(2, '0')}',
        );
      }
      scanStatus = ScanStatus.done;
      scanProgress = '扫描完成，共发现 ${videos.length} 个视频';
      await _persistSources();
      await _persistVideos(sourceId);
    } catch (error) {
      _sourceErrors[sourceId] = describeError(error);
      final index = _sources.indexWhere((item) => item.id == sourceId);
      if (index >= 0) {
        _sources[index] = _sources[index].copyWith(connected: false);
      }
      scanStatus = ScanStatus.failed;
      scanProgress = '';
      await _persistSources();
    }
    notifyListeners();
  }

  /// 批量刮削：为所有条目匹配海报、简介与评分。
  ///
  /// 默认跳过已有海报的条目；force 为 true 时重新匹配并覆盖。
  Future<void> scrapeAll({bool force = false}) async {
    if (scraping) return;
    scraping = true;
    scrapeDone = 0;
    scrapeTotal = 0;
    scrapeProgress = '准备刮削…';
    notifyListeners();

    try {
      final jobs = _scrapeJobsOf(_videosBySource);

      scrapeTotal = jobs.length;
      if (scrapeTotal == 0) {
        scrapeProgress = '媒体库还是空的，先同步媒体源';
        return;
      }

      for (final job in jobs) {
        final target = job.group.firstWhere(
          (v) => v.posterPath != null,
          orElse: () => job.representative,
        );
        final isSeriesJob = job.group.length > 1;
        final stillComplete =
            !isSeriesJob ||
            job.group.where((v) => v.stillPath != null).length >=
                ((job.group.length + 1) ~/ 2);
        if (!force &&
            target.posterPath != null &&
            target.backdropPath != null &&
            stillComplete) {
          scrapeDone++;
          scrapeProgress = '已刮削 $scrapeDone / $scrapeTotal（跳过已有海报）';
          notifyListeners();
          continue;
        }

        scrapeProgress = '正在匹配「${job.representative.title}」…';
        notifyListeners();

        final parsed = ScraperService.parseTitle(job.representative.title);
        ScrapeResult? result;
        // 优先 TMDB（中文片名与电影覆盖最好），失败回退 TVmaze
        final preferTv =
            job.group.length > 1 || job.representative.kind != MediaKind.movie;
        for (final query in parsed.queries) {
          result = await ScraperService.searchTmdb(
            query,
            year: parsed.year,
            preferTv: preferTv,
          );
          if (result != null) break;
        }
        if (result == null) {
          for (final query in parsed.queries) {
            result = await ScraperService.search(query, year: parsed.year);
            if (result != null) break;
          }
        }

        final matchedResult = result;
        final matchedId = matchedResult?.tmdbId;
        if (matchedResult != null && matchedId != null) {
          final details = await ScraperService.fetchTmdbDetails(
            mediaType: matchedResult.mediaType ?? 'movie',
            id: matchedId,
          );
          result = details ?? result;
        }

        final scrapedBackdrop = result == null
            ? null
            : await _downloadBackdrop(result);
        final seasonNumber = seasonOf(job.representative);
        final episodeInfos = <int, ({String? title, String? stillUrl})>{};
        if (result?.mediaType == 'tv' && result?.tmdbId != null) {
          episodeInfos.addAll(
            await ScraperService.fetchEpisodeStills(
              tvId: result!.tmdbId!,
              seasonNumber: seasonNumber,
            ),
          );
        }
        final episodeStillPaths = <int, String>{};
        for (final entry in episodeInfos.entries) {
          final stillUrl = entry.value.stillUrl;
          if (stillUrl == null) continue;
          final path = await ScraperService.downloadPoster(
            stillUrl,
            cacheKey: 'still_${result?.tmdbId}_s${seasonNumber}e${entry.key}',
          );
          if (path != null) episodeStillPaths[entry.key] = path;
        }
        if (result != null) {
          String? posterPath;
          if (result.posterUrl != null) {
            posterPath = await ScraperService.downloadPoster(
              result.posterUrl!,
              cacheKey: '${job.representative.kind.name}_${result.name}',
            );
          }
          if (posterPath != null ||
              result.summary != null ||
              result.rating != null) {
            for (final member in job.group) {
              final episodeNumber = episodeNumberOf(member.title);
              _updateVideo(
                member.sourceId,
                member.path,
                (video) => video.copyWith(
                  posterPath: posterPath,
                  summary: result!.summary,
                  rating: result.rating,
                  backdropPath: scrapedBackdrop,
                  genres: result.genres,
                  cast: result.cast,
                  releaseDate: result.releaseDate,
                  runtimeSec: result.runtimeSec,
                  stillPath: episodeStillPaths[episodeNumber],
                  episodeTitle: episodeInfos[episodeNumber]?.title,
                  tmdbId: result.tmdbId,
                ),
              );
            }
            await _persistVideos(job.representative.sourceId);
          }
        }

        scrapeDone++;
        scrapeProgress = '已刮削 $scrapeDone / $scrapeTotal';
        notifyListeners();
      }

      scrapeProgress = '刮削完成，共处理 $scrapeTotal 个条目';
    } finally {
      scraping = false;
      notifyListeners();
    }
  }

  /// 刮削任务列表：与展示聚合同规则分组，组内文件一起刮削。
  ///
  /// representative 必须用聚合条目——它的 title 是从目录名推导出的剧名
  /// （如「成何体统」）；group.first 的 title 是原始文件名（如「01~4K」），
  /// 拿它去搜索永远搜不到。
  static List<({ScannedVideo representative, List<ScannedVideo> group})>
  _scrapeJobsOf(Map<String, List<ScannedVideo>> videosBySource) {
    final jobs = <({ScannedVideo representative, List<ScannedVideo> group})>[];
    for (final videos in videosBySource.values) {
      final aggregated = aggregate(videos);
      final byPath = <String, ScannedVideo>{
        for (final item in aggregated) item.path: item,
      };
      final grouped = <String, List<ScannedVideo>>{};
      for (final video in videos) {
        // 统一按父目录分组，与展示聚合同规则；
        // 若按「聚合条目 path」特殊处理首文件，剧集会被拆成 1+N 个组，
        // 第 2 集起的组拿原始文件名（02~）搜索必然失败。
        grouped.putIfAbsent(parentPathOf(video.path), () => []).add(video);
      }
      for (final group in grouped.values) {
        // 聚合条目的 path 等于组内第一个文件的 path，据此找回聚合标题。
        final representative = byPath[group.first.path] ?? group.first;
        jobs.add((representative: representative, group: group));
      }
    }
    return jobs;
  }

  /// 把任意条目解析为它所属的聚合条目（剧名/集数/海报都在聚合层）。
  ///
  /// 详情页必须用它而不是 findVideo——后者返回的是原始单集文件。
  ScannedVideo resolveAggregated(ScannedVideo video) {
    final videos = _videosBySource[video.sourceId];
    if (videos == null || videos.isEmpty) return video;
    for (final item in aggregate(videos)) {
      if (item.path == video.path) return item;
    }
    return video;
  }

  /// 手动匹配：把用户选中的候选应用到这一组（剧集整组共享同一张海报）。
  ///
  /// 有 TMDB ID 时拉取完整详情（背景图/类型/演员），剧集还会下载单集剧照。
  Future<String?> applyCandidate(
    ScannedVideo target,
    List<ScannedVideo> group,
    ScrapeCandidate candidate,
  ) async {
    String? poster;
    String? backdrop;
    String? summary = candidate.overview;
    String? rating = candidate.rating;
    List<String> genres = const [];
    List<CastMember> cast = const [];
    String? releaseDate;
    double? runtimeSec;
    Map<int, String> episodeStillPaths = const {};
    Map<int, String> episodeTitles = const {};
    if (candidate.tmdbId != null) {
      final details = await ScraperService.fetchTmdbDetails(
        mediaType: candidate.mediaType,
        id: candidate.tmdbId!,
      );
      if (details != null) {
        if (details.backdropUrl != null) {
          backdrop = await ScraperService.downloadPoster(
            details.backdropUrl!,
            cacheKey: 'manual_backdrop_${candidate.name}',
          );
        }
        summary = details.summary ?? summary;
        rating = details.rating ?? rating;
        genres = details.genres;
        cast = details.cast;
        releaseDate = details.releaseDate;
        runtimeSec = details.runtimeSec;
      }
      if (candidate.mediaType == 'tv') {
        final seasonNumber = group.length > 1 ? seasonOf(group.first) : 1;
        final stillUrls = await ScraperService.fetchEpisodeStills(
          tvId: candidate.tmdbId!,
          seasonNumber: seasonNumber,
        );
        episodeStillPaths = <int, String>{};
        episodeTitles = <int, String>{};
        for (final entry in stillUrls.entries) {
          if (entry.value.title != null) {
            episodeTitles[entry.key] = entry.value.title!;
          }
          final stillUrl = entry.value.stillUrl;
          if (stillUrl == null) continue;
          final path = await ScraperService.downloadPoster(
            stillUrl,
            cacheKey: 'still_${candidate.tmdbId}_s${seasonNumber}e${entry.key}',
          );
          if (path != null) episodeStillPaths[entry.key] = path;
        }
      }
    }
    if (candidate.posterUrl != null) {
      poster = await ScraperService.downloadPoster(
        candidate.posterUrl!,
        cacheKey: 'manual_${candidate.name}_${candidate.year ?? ''}',
      );
    }
    for (final member in group) {
      final episodeNumber = episodeNumberOf(member.title);
      _updateVideo(
        member.sourceId,
        member.path,
        (video) => video.copyWith(
          posterPath: poster,
          summary: summary,
          rating: rating,
          backdropPath: backdrop,
          genres: genres,
          cast: cast,
          releaseDate: releaseDate,
          runtimeSec: runtimeSec,
          stillPath: episodeStillPaths[episodeNumber],
          episodeTitle: episodeTitles[episodeNumber],
          tmdbId: candidate.tmdbId,
        ),
      );
    }
    await _persistVideos(target.sourceId);
    notifyListeners();
    return poster;
  }

  void _updateVideo(
    String sourceId,
    String path,
    ScannedVideo Function(ScannedVideo video) update,
  ) {
    final list = _videosBySource[sourceId];
    if (list == null) return;
    final index = list.indexWhere((video) => video.path == path);
    if (index >= 0) list[index] = update(list[index]);
  }

  Future<String?> _downloadBackdrop(ScrapeResult result) async {
    if (result.backdropUrl == null) return null;
    return ScraperService.downloadPoster(
      result.backdropUrl!,
      cacheKey: 'backdrop_${result.mediaType ?? 'item'}_${result.name}',
    );
  }

  /// 把底层错误翻译成人话。
  static String describeError(Object error) {
    final text = error.toString();
    if (text.contains('401') ||
        text.toLowerCase().contains('unauthorized') ||
        text.toLowerCase().contains('auth')) {
      return '用户名或密码不正确（服务器返回 401）';
    }
    if (text.contains('404')) return '目录不存在（服务器返回 404），请检查媒体目录';
    if (text.contains('Connection refused') || text.contains('connection')) {
      return '无法连接服务器，请检查地址与网络';
    }
    if (text.contains('timed out') || text.contains('Timeout')) {
      return '连接超时，服务器无响应';
    }
    return '连接失败：$text';
  }

  /// 把扫描出的文件聚合成展示条目。
  ///
  /// 规则：**按文件夹聚合**——同一目录下带集数标记的文件（S01E13/E13/第13集）
  /// 合并为一条剧集条目并统计集数；无集数标记的按单文件展示（电影）。
  static List<ScannedVideo> aggregate(List<ScannedVideo> videos) {
    final byFolder = <String, List<ScannedVideo>>{};
    for (final video in videos) {
      // 片头片尾、预告花絮等不是正片，直接不进入媒体库
      if (WebDavService.isExtraFile(video.title)) continue;
      byFolder.putIfAbsent(parentPathOf(video.path), () => []).add(video);
    }

    final result = <ScannedVideo>[];
    for (final entry in byFolder.entries) {
      final group = entry.value
        ..sort((a, b) => _naturalCompare(a.path, b.path));
      if (group.length < 2 || !_isSeriesGroup(group)) {
        result.addAll(group);
        continue;
      }
      final title = _seriesTitle(entry.key, group);
      // 电影目录下的剧集修正为电视剧；动漫/综艺保持原分类
      final kind = group.first.kind == MediaKind.movie
          ? MediaKind.series
          : group.first.kind;
      final posterSource = group.firstWhere(
        (video) => video.posterPath != null,
        orElse: () => group.first,
      );
      result.add(
        group.first.copyWith(
          title: title,
          kind: kind,
          episodeCount: group.length,
          posterPath: posterSource.posterPath,
          summary: posterSource.summary,
          rating: posterSource.rating,
        ),
      );
    }
    return result;
  }

  /// 一组同目录文件是否属于同一部剧集。
  static bool _isSeriesGroup(List<ScannedVideo> group) {
    if (group.any((video) => WebDavService.looksLikeEpisode(video.title))) {
      return true;
    }
    // 纯数字文件名（1.mkv、14~4K.mp4）在 ≥3 个文件时视为剧集
    if (group.length >= 3 &&
        group.every(
          (video) =>
              RegExp(r'^\d{1,3}\s*[~\-_.]*\s*$').hasMatch(video.title.trim()),
        )) {
      return true;
    }
    // 没有标准集数标记时，按「标题去掉末尾数字后是否一致」判断；
    // 至少 3 个文件才认定，避免把《流浪地球2》之类的续集误合并。
    if (group.length < 3) return false;
    final bases = group
        .map((video) => _stripTrailingNumber(video.title))
        .where((base) => base.isNotEmpty)
        .toSet();
    return bases.length == 1;
  }

  static String _stripTrailingNumber(String title) {
    // 先去掉末尾画质标记（三体_01_4K → 三体_01），再去掉集数数字
    var cleaned = title.replaceAll(
      RegExp(
        r'[\s._-]*(4k|8k|1080p|720p|2160p|hdr10?|10bit|8bit)$',
        caseSensitive: false,
      ),
      '',
    );
    cleaned = cleaned.replaceAll(RegExp(r'[\s._-]*\d{1,4}$'), '').trim();
    return cleaned;
  }

  /// 由所在目录推导剧名：跳过「电影」「1」（季号）这类无效目录，向上找真正的剧名。
  static String _seriesTitle(String parentPath, List<ScannedVideo> group) {
    var path = parentPath;
    var segment = _lastSegment(path);
    var guard = 0;
    while (guard < 4) {
      final isSeasonFolder =
          RegExp(r'^\d{1,2}$').hasMatch(segment) ||
          RegExp(
            r'^season\s*\d+\s*[（()）]*$',
            caseSensitive: false,
          ).hasMatch(segment);
      if (!_isGenericFolder(segment) && !isSeasonFolder && segment.isNotEmpty) {
        return WebDavService.cleanTitle(segment);
      }
      final nextPath = parentPathOf(path);
      final nextSegment = _lastSegment(nextPath);
      if (nextSegment == segment || nextSegment.isEmpty) break;
      path = nextPath;
      segment = nextSegment;
      guard++;
    }
    return _commonPrefixTitle(group);
  }

  /// 文件夹名是否只是"电影/电视剧/动漫/综艺"这类通用名。
  static bool _isGenericFolder(String name) {
    final lower = name.toLowerCase().trim();
    const generic = {
      '电影',
      '电视剧',
      '剧集',
      '动漫',
      '动画',
      '综艺',
      '影片',
      'movies',
      'movie',
      'tv',
      'tv shows',
      'series',
      'anime',
      'film',
    };
    return generic.contains(lower) || lower.length <= 1;
  }

  /// 从组内文件名推导公共前缀作为剧名（如 "Signal.S01E01" → "Signal"）。
  static String _commonPrefixTitle(List<ScannedVideo> group) {
    if (group.isEmpty) return '';
    final first = group.first.title;
    return WebDavService.cleanTitle(first);
  }

  static String parentPathOf(String path) {
    final index = path.lastIndexOf('/');
    return index > 0 ? path.substring(0, index) : path;
  }

  /// 从路径或文件名推断季号，识别失败按第 1 季处理。
  ///
  /// 支持 S02、第2季、Season 2 与「剧名/2/」这类季号目录；
  /// 只有「剧名/3」纯数字目录且文件名本身带集数时才算季号，
  /// 避免把「01~4K.mp4」这种纯集数文件名所在目录误判成季号。
  static int seasonOf(ScannedVideo video) {
    int extract(String text) {
      final patterns = [
        RegExp(r'[sS](\d{1,2})[eE]\d{1,3}'), // S02E13
        RegExp(r'第\s*([0-9一二三四五六七八九十]+)\s*季'),
        RegExp(r'season\s*(\d{1,2})', caseSensitive: false),
      ];
      for (final pattern in patterns) {
        final match = pattern.firstMatch(text);
        if (match != null) {
          final parsed =
              int.tryParse(match.group(1)!) ?? _chineseNumber(match.group(1)!);
          if (parsed != null) return parsed;
        }
      }
      return 0;
    }

    var season = extract(video.title);
    if (season > 0) return season;
    season = extract(video.path);
    if (season > 0) return season;

    // 纯数字目录视为季号：仅当目录上一级不是纯数字（排除顶级目录编号）
    var parent = parentPathOf(video.path);
    for (var guard = 0; guard < 3; guard++) {
      final index = parent.lastIndexOf('/');
      if (index < 0) break;
      final segment = parent.substring(index + 1);
      final parsed = int.tryParse(segment);
      if (parsed != null && parsed > 0) return parsed;
      parent = parent.substring(0, index);
    }
    return 1;
  }

  static int? _chineseNumber(String raw) {
    const digits = {
      '一': 1,
      '二': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
      '十': 10,
    };
    if (raw.length == 1) return digits[raw];
    if (raw.length == 2 && raw.startsWith('十')) {
      final one = digits[raw[1]];
      return one == null ? null : 10 + one;
    }
    if (raw.length == 2 && raw.endsWith('十')) {
      final one = digits[raw[0]];
      return one == null ? null : one * 10;
    }
    return null;
  }

  static String _lastSegment(String path) {
    final clean = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final index = clean.lastIndexOf('/');
    var segment = index >= 0 ? clean.substring(index + 1) : clean;
    try {
      segment = Uri.decodeComponent(segment);
    } catch (_) {
      // 已是明文则直接使用
    }
    return segment;
  }
}
