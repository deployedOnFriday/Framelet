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
  List<ScannedVideo> byKind(MediaKind kind) {
    final merged = <String, ScannedVideo>{};
    for (final videos in _videosBySource.values) {
      for (final video in videos) {
        if (video.kind != kind) continue;
        final key = '${video.sourceId}|${video.title.toLowerCase()}';
        final existing = merged[key];
        if (existing == null) {
          merged[key] = video;
        } else if (video.episodeCount > existing.episodeCount) {
          merged[key] = video;
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

  int countByKind(MediaKind kind) => byKind(kind).length;

  /// 某聚合条目对应的单集文件列表（电影返回自身）。
  List<ScannedVideo> episodesOf(ScannedVideo video) {
    if (video.episodeCount <= 1) return [video];
    final parent = parentPathOf(video.path);
    final result = <ScannedVideo>[];
    for (final videos in _videosBySource.values) {
      for (final candidate in videos) {
        if (candidate.sourceId != video.sourceId) continue;
        if (candidate.kind != video.kind) continue;
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
  /// 已刮到海报的条目跳过；剧集同组共享一张海报。
  Future<void> scrapeAll() async {
    if (scraping) return;
    scraping = true;
    scrapeDone = 0;
    scrapeTotal = 0;
    scrapeProgress = '准备刮削…';
    notifyListeners();

    try {
      final jobs =
          <({ScannedVideo representative, List<ScannedVideo> group})>[];
      for (final entry in _videosBySource.entries) {
        final videos = entry.value;
        final grouped = <String, List<ScannedVideo>>{};
        for (final video in videos) {
          // 与展示聚合保持一致：带集数标记的按文件夹成组，其余单条
          if (!WebDavService.looksLikeEpisode(video.title)) {
            jobs.add((representative: video, group: [video]));
            continue;
          }
          grouped.putIfAbsent(parentPathOf(video.path), () => []).add(video);
        }
        for (final group in grouped.values) {
          jobs.add((representative: group.first, group: group));
        }
      }

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
        if (target.posterPath != null) {
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
        for (final query in parsed.queries) {
          result = await ScraperService.searchTmdb(query, year: parsed.year);
          if (result != null) break;
        }
        if (result == null) {
          for (final query in parsed.queries) {
            result = await ScraperService.search(query, year: parsed.year);
            if (result != null) break;
          }
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
              _updateVideo(
                member.sourceId,
                member.path,
                (video) => video.copyWith(
                  posterPath: posterPath,
                  summary: result!.summary,
                  rating: result.rating,
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
      final folderName = _lastSegment(entry.key);
      final folderTitle = WebDavService.cleanTitle(folderName);
      final title = _isGenericFolder(folderTitle)
          ? _commonPrefixTitle(group)
          : folderTitle;
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
