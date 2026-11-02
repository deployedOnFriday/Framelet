import 'dart:convert';
import 'dart:io';

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
        // 前端只展示已刮削的条目；未刮的收在设置页处理
        if (!video.isScraped) continue;
        final key = _seriesMergeKey(video);
        final existing = merged[key];
        if (existing == null) {
          merged[key] = video;
        } else {
          // 同一部剧的多季：集数无条件相加（两季集数相同也要累加），
          // 剧名统一用规范化基名（魔幻手机2：傻妞归来 → 魔幻手机）
          merged[key] = video.copyWith(
            episodeCount: existing.episodeCount + video.episodeCount,
            title: normalizeSeriesTitle(video.tmdbTitle ?? video.title),
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

  /// 一部剧的每一季（跨文件夹、跨 TMDB ID）。单季剧集返回它自己。
  ///
  /// 判据与 byKind 合并一致：规范化剧名相同即同一部剧的不同季，
  /// 因此《旋风少女》《旋风少女2》即使 TMDB 是两个条目也能归到一起。
  List<ScannedVideo> seasonsOf(ScannedVideo video) {
    final key = _seriesMergeKey(video);
    final seasons = <ScannedVideo>[];
    for (final videos in _videosBySource.values) {
      for (final item in aggregate(videos)) {
        if (_seriesMergeKey(item) == key) seasons.add(item);
      }
    }
    seasons.sort((a, b) => seasonOf(a).compareTo(seasonOf(b)));
    return seasons.isEmpty ? [video] : seasons;
  }

  /// 合并键：电影按 TMDB ID；剧集按「规范化剧名」——
  /// 剥掉季号后同名视为同一部剧，跨 TMDB ID 也能合并展示。
  static String _seriesMergeKey(ScannedVideo video) {
    if (video.kind != MediaKind.movie) {
      final normalized = normalizeSeriesTitle(video.title);
      if (normalized.isNotEmpty) {
        return 'series|${normalized.toLowerCase()}';
      }
    }
    return video.tmdbId != null
        ? 'tmdb|${video.tmdbId}'
        : '${video.sourceId}|${video.title.toLowerCase()}';
  }

  /// 规范化剧名：剥掉季号/年份等后缀，用于判断是否同一部剧。
  ///
  /// 支持「魔幻手机2：傻妞归来」这类「基名+季号+副标题」——
  /// 数字后必须紧跟副标题分隔符才剥离，避免把《秘密森林》并进《秘密》。
  static String normalizeSeriesTitle(String title) {
    var text = title.trim();
    final withSubtitle = RegExp(r'^(.*?)\s*\d{1,2}\s*[：:·\-（(].+$')
        .firstMatch(text);
    if (withSubtitle != null) {
      final base = withSubtitle.group(1)!.trim();
      if (base.isNotEmpty) text = base;
    }
    text = text.replaceAll(RegExp(r'\s*第\s*[0-9一二三四五六七八九十]+\s*季\s*$'), '');
    text = text.replaceAll(
      RegExp(r'\s*season\s*\d+\s*$', caseSensitive: false),
      '',
    );
    text = text.replaceAll(RegExp(r'\s*[sS]\d{1,2}\s*$'), '');
    // 尾部季号数字（旋风少女2 → 旋风少女），数字前不限字符
    text = text.replaceAll(RegExp(r'\d{1,2}\s*$'), '');
    text = text.replaceAll(RegExp(r'[\s:：·\-]+$'), '');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text;
  }

  int countByKind(MediaKind kind) => byKind(kind).length;

  /// 未刮削的聚合条目（不进前端，等设置页手动处理）。
  List<ScannedVideo> unscrapedItems() {
    final result = <ScannedVideo>[];
    final seen = <String>{};
    for (final videos in _videosBySource.values) {
      for (final video in aggregate(videos)) {
        if (video.isScraped) continue;
        if (!seen.add(video.path)) continue;
        result.add(video);
      }
    }
    return result;
  }

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
      RegExp(
        r'(?:^|[.\s_-])e(?:p)?(\d{1,3})(?:$|[.\s_-])',
        caseSensitive: false,
      ),
      RegExp(r'第\s*(\d{1,4})\s*[集话期]'),
    ];
    // 综艺「第N期上/中/下」：每期按 上=1、中=2、下=3 顺延，与 TMDB 分集一致
    final part = RegExp(r'第\s*(\d{1,3})\s*期\s*([上中下])').firstMatch(title);
    if (part != null) {
      final base = int.tryParse(part.group(1)!);
      final sub = const {'上': 1, '中': 2, '下': 3}[part.group(2)];
      if (base != null && sub != null) return (base - 1) * 3 + sub;
    }
    for (final pattern in patterns) {
      final match = pattern.firstMatch(title);
      if (match?.group(1) case final number?) return int.tryParse(number);
    }
    // 结尾数字后允许带画质标记：01~4K、14_1080p。
    // 数字前必须紧跟分隔符或行首，避免把 H265 的 265 当集数。
    final plain = RegExp(
      r'(?:^|[.\s_~-])(\d{1,4})\s*[~\-_.]?\s*(4k|8k|1080p|720p|2160p|hdr10?)?\s*$',
      caseSensitive: false,
    ).firstMatch(title);
    return int.tryParse(plain?.group(1) ?? '');
  }

  /// 解析单集编号：优先清洗后的标题，失败回退原始文件名。
  ///
  /// 旧缓存的标题可能被旧版 cleanTitle 洗掉集数标记
  /// （Whirlwind.Girl.E01.mp4 → Whirlwind.Girl），原始文件名保底，
  /// 这样不重扫媒体源也能把集标题/剧照对回文件。
  static int? episodeNumberOfVideo(ScannedVideo video) =>
      episodeNumberOf(video.title) ?? episodeNumberOf(_lastSegment(video.path));

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
      // 重新扫描只更新文件结构：按 path 把之前刮到的数据（海报/剧照/匹配）
      // 合并回新条目，避免一次重扫把整个媒体库的元数据抹掉。
      final previous = _videosBySource[sourceId];
      if (previous != null && previous.isNotEmpty) {
        final byPath = {for (final video in previous) video.path: video};
        for (var i = 0; i < videos.length; i++) {
          final old = byPath[videos[i].path];
          if (old == null) continue;
          if (old.tmdbId == null && old.posterPath == null) continue;
          videos[i] = videos[i].copyWith(
            posterPath: old.posterPath,
            backdropPath: old.backdropPath,
            summary: old.summary,
            rating: old.rating,
            tmdbId: old.tmdbId,
            tmdbTitle: old.tmdbTitle,
            genres: old.genres,
            cast: old.cast,
            releaseDate: old.releaseDate,
            runtimeSec: old.runtimeSec,
            stillPath: old.stillPath,
            episodeTitle: old.episodeTitle,
          );
        }
      }
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

  /// 刮削过程文件日志：进程崩溃时也能看到死前最后一步。
  static void _scrapeLog(String message) {
    try {
      File('${Directory.systemTemp.path}/framelet_scrape.log')
          .writeAsStringSync(
            '${DateTime.now().toIso8601String().substring(11, 19)} $message\n',
            mode: FileMode.append,
            flush: true,
          );
    } catch (_) {}
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

      _scrapeLog('共 $scrapeTotal 个任务开始');
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
        _scrapeLog(
          '任务 $scrapeDone+: ${job.representative.title}（${job.group.length} 集）',
        );
        notifyListeners();

        final parsed = ScraperService.parseTitle(job.representative.title);
        final preferTv =
            job.group.length > 1 || job.representative.kind != MediaKind.movie;
        final seasonNumber = seasonOf(job.representative);

        // 候选评估：拉详情 + 目标季集数据，满足要求才算命中。
        // TMDB 上存在残缺的重复条目（如「旋风少女2」只登记了 1 季 1 集，
        // 而主条目「旋风少女」自带两季）——精确同名反而先命中它们，
        // 表现为多季拆成多个条目、整季集标题与剧照拉空。
        // 剧集因此要求目标季能拉到集数据；拉不到只记为保底候选，
        // 由外层换下一个查询词（通常是剥掉季号的主名）重试。
        ScrapeResult? best;
        ScrapeResult? firstUsable;
        var episodeInfos = const <int, ({String? title, String? stillUrl})>{};

        Future<void> consider(int tmdbId, String mediaType) async {
          _scrapeLog('  拉取详情 tmdbId=$tmdbId');
          final details = await ScraperService.fetchTmdbDetails(
            mediaType: mediaType,
            id: tmdbId,
          );
          if (details == null) return;
          firstUsable ??= details;
          if (best != null) return;
          if (details.mediaType == 'tv') {
            _scrapeLog('  拉取季剧照 season=$seasonNumber');
            final episodes = await ScraperService.fetchEpisodeStills(
              tvId: details.tmdbId ?? tmdbId,
              seasonNumber: seasonNumber,
            );
            if (isSeriesJob && episodes.isEmpty) return;
            episodeInfos = episodes;
          }
          best = details;
        }

        // 1) 既有匹配优先复用（路径 {tmdbid-NNN} 或上次刮削的 tmdbId），
        //    重扫时海报与条目保持稳定
        final cachedId = job.representative.tmdbId;
        if (cachedId != null) {
          _scrapeLog('  复用既有 tmdbId=$cachedId');
          await consider(cachedId, isSeriesJob ? 'tv' : 'movie');
        }
        // 2) TMDB 搜索（中文片名与电影覆盖最好），逐个查询词尝试
        if (best == null) {
          for (final query in parsed.queries) {
            final hit = await ScraperService.searchTmdb(
              query,
              year: parsed.year,
              preferTv: preferTv,
            );
            if (hit?.tmdbId == null) continue;
            await consider(hit!.tmdbId!, hit.mediaType ?? 'movie');
            if (best != null) break;
          }
        }
        // 3) TVmaze 兜底（无 TMDB Key 或 TMDB 不可达）
        var result = best ?? firstUsable;
        if (result == null) {
          for (final query in parsed.queries) {
            result = await ScraperService.search(query, year: parsed.year);
            if (result != null) break;
          }
        }

        final scrapedBackdrop = result == null
            ? null
            : await _downloadBackdrop(result);
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
              final episodeNumber = episodeNumberOfVideo(member);
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
        _scrapeLog('  完成 $scrapeDone/$scrapeTotal');
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

  /// 导入 CLI 后台补刮的结果（path → 各字段），并持久化。
  Future<int> importScrapeResults(
    Map<String, Map<String, Object?>> results,
  ) async {
    var updated = 0;
    for (final entry in _videosBySource.entries) {
      final videos = entry.value;
      var changed = false;
      for (var i = 0; i < videos.length; i++) {
        final data = results[videos[i].path];
        if (data == null) continue;
        videos[i] = videos[i].copyWith(
          posterPath: data['posterPath'] as String?,
          backdropPath: data['backdropPath'] as String?,
          summary: data['summary'] as String?,
          rating: data['rating'] as String?,
          tmdbId: (data['tmdbId'] as num?)?.toInt(),
          stillPath: data['stillPath'] as String?,
          episodeTitle: data['episodeTitle'] as String?,
          tmdbTitle: data['tmdbTitle'] as String?,
        );
        changed = true;
        updated++;
      }
      if (changed) await _persistVideos(entry.key);
    }
    notifyListeners();
    return updated;
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
      final episodeNumber = episodeNumberOfVideo(member);
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

  static List<ScannedVideo> aggregate(List<ScannedVideo> videos) {
    final byFolder = <String, List<ScannedVideo>>{};
    for (final video in videos) {
      // 花絮不再丢弃：保留在同一部剧的组里，详情页单独分区展示
      byFolder.putIfAbsent(parentPathOf(video.path), () => []).add(video);
    }

    final result = <ScannedVideo>[];
    for (final entry in byFolder.entries) {
      final group = entry.value
        ..sort((a, b) => _naturalCompare(a.path, b.path));
      // 展示名优先用 TMDB 官方名，缺失时用清洗后的文件夹名
      final tmdbTitle = group
          .firstWhere(
            (video) => (video.tmdbTitle ?? '').isNotEmpty,
            orElse: () => group.first,
          )
          .tmdbTitle;
      final rawFolderTitle = _seriesTitle(entry.key, group);
      final folderTitle = rawFolderTitle == null
          ? null
          : _cleanFolderTitle(rawFolderTitle);

      // 无有效目录名（文件直接放在电影/网盘等通用或根目录下）：
      // 各文件独立，标题保持文件名
      if (folderTitle == null || folderTitle.isEmpty) {
        result.addAll(group);
        continue;
      }

      // 目录名有效：标题一律取目录名（文件名常是压制信息，不可读）
      final tmdbId = _tmdbIdFromPaths(group.map((video) => video.path));
      final posterSource = group.firstWhere(
        (video) => video.posterPath != null,
        orElse: () => group.first,
      );

      // 剧集模式：同目录多文件带集数标记
      if (_isSeriesGroup(group)) {
        // 集数只统计正片，花絮单列
        final mainCount = group
            .where((video) => !WebDavService.isExtraFile(video.title))
            .length;
        var kind = group.first.kind == MediaKind.movie
            ? MediaKind.series
            : group.first.kind;
        // 按 TMDB 类型修正分类：动画→动漫、真人秀/脱口秀→综艺
        // （genres 在刮削时写入，byKind 每次实时聚合，刮完即自动归位）
        final genreSource = group.firstWhere(
          (video) => video.genres.isNotEmpty,
          orElse: () => group.first,
        );
        final genreText = genreSource.genres.join(' ');
        if (genreText.contains('动画')) {
          kind = MediaKind.anime;
        } else if (genreText.contains('真人秀') || genreText.contains('脱口秀')) {
          kind = MediaKind.variety;
        }
        result.add(
          group.first.copyWith(
            title: (tmdbTitle != null && tmdbTitle.isNotEmpty)
                ? tmdbTitle
                : folderTitle,
            kind: kind,
            episodeCount: mainCount > 0 ? mainCount : group.length,
            posterPath: posterSource.posterPath,
            summary: posterSource.summary,
            rating: posterSource.rating,
            tmdbId: tmdbId,
          ),
        );
        continue;
      }

      // 单文件电影：标题优先 TMDB 名，回退目录名
      if (group.length == 1) {
        result.add(
          group.first.copyWith(
            title: (tmdbTitle != null && tmdbTitle.isNotEmpty)
                ? tmdbTitle
                : folderTitle,
            tmdbId: tmdbId,
          ),
        );
        continue;
      }

      // 同目录多文件但无集数标记：视为同一部影片的多版本，合并为一条电影
      result.add(
        group.first.copyWith(
          title: (tmdbTitle != null && tmdbTitle.isNotEmpty)
              ? tmdbTitle
              : folderTitle,
          episodeCount: 1,
          posterPath: posterSource.posterPath,
          summary: posterSource.summary,
          rating: posterSource.rating,
          tmdbId: tmdbId,
        ),
      );
    }
    return result;
  }

  /// 清洗文件夹名作为展示标题：剥掉尾部的年份/画质/码率等杂质。
  /// 清洗后为空（全是杂质）时返回 null。
  static String? _cleanFolderTitle(String raw) {
    var title = raw.trim();
    title = title
        .replaceAll(RegExp(r'[（(]\s*(19|20)\d{2}\s*[）)]\s*$'), '')
        .replaceAll(RegExp(r'[（(][^）)]*[）)]\s*$'), '')
        .replaceAll(
          RegExp(
            r'\s*(60fps|120fps|60帧|120帧|高码|高码率|hq|4k|8k|1080p|2160p|hdr10?)\s*$',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    return title.isEmpty ? null : title;
  }

  /// 从一组路径中提取 {tmdbid-NNN} 标记（媒体管理器命名习惯，取第一个命中的）。
  static int? _tmdbIdFromPaths(Iterable<String> paths) {
    final pattern = RegExp(r'\{tmdbid-(\d+)\}', caseSensitive: false);
    for (final path in paths) {
      final match = pattern.firstMatch(path);
      if (match != null) return int.tryParse(match.group(1)!);
    }
    return null;
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
  /// 返回 null 表示没有有效目录名（如文件直接放在通用/根目录下）。
  static String? _seriesTitle(String parentPath, List<ScannedVideo> group) {
    var path = parentPath;
    var segment = _lastSegment(path);
    var guard = 0;
    while (guard < 4) {
      final isSeasonFolder =
          RegExp(r'^\d{1,2}$').hasMatch(segment) ||
          RegExp(r'^season\s*\d+', caseSensitive: false).hasMatch(segment);
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
    return null;
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
      '夸克网盘',
      '阿里云盘',
      '百度网盘',
      '蓝奏云',
      '天翼云盘',
      '123云盘',
      'dav',
      'webdav',
      'media',
      'videos',
      'downloads',
    };
    return generic.contains(lower) || lower.length <= 1;
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

    // 所在目录名的尾部数字视为季号：唐朝诡事录2 → 第2季
    final parentSegment = _lastSegment(parentPathOf(video.path));
    final tailMatch = RegExp(r'(\d{1,2})\s*$').firstMatch(parentSegment);
    if (tailMatch != null) {
      final parsed = int.tryParse(tailMatch.group(1)!);
      if (parsed != null && parsed > 0) return parsed;
    }

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
