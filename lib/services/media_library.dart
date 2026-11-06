import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/media_source.dart';
import 'credential_store.dart';
import 'danmaku_service.dart';
import 'framelet_store.dart';
import 'local_media_service.dart';
import 'scraper_service.dart';
import 'update_service.dart';
import 'webdav_service.dart';

enum ScanStatus { idle, scanning, done, failed }

/// 媒体库全局状态：媒体源配置、扫描结果与分类视图。
class MediaLibrary extends ChangeNotifier {
  MediaLibrary({CredentialStore? store, FrameletStore? db})
    : _store = store ?? CredentialStore(),
      _db = db ?? FrameletStore.instance;

  static MediaLibrary? _instance;

  static MediaLibrary get instance => _instance ??= MediaLibrary();

  /// 测试用：替换全局实例，避免触达真实系统存储。
  @visibleForTesting
  static set instanceForTesting(MediaLibrary library) => _instance = library;

  final CredentialStore _store;
  final FrameletStore _db;

  final List<MediaSource> _sources = [];
  final Map<String, String> _passwords = {};
  final Map<String, List<ScannedVideo>> _videosBySource = {};
  final Map<String, String> _sourceErrors = {};

  ScanStatus scanStatus = ScanStatus.idle;
  String scanProgress = '';

  bool scraping = false;
  String scrapeProgress = '';
  int scrapeDone = 0;
  int scrapeMatched = 0;
  int scrapeTotal = 0;

  /// 刮削设置（TMDB 密钥与可选代理），保存于安全存储。
  String? scrapeProxy;
  String? tmdbKey;
  DanmakuProvider danmakuProvider = DanmakuProvider.dandanplay;
  String danmakuBaseUrl = DanmakuService.officialBaseUrl;
  String? danmakuAppId;
  String? danmakuAppSecret;

  /// TMDB 是否可用：用户配置了 key，或存在内置 key（开箱即用）。
  bool get hasTmdb =>
      (tmdbKey ?? '').trim().isNotEmpty ||
      ScraperService.builtinTmdbApiKey.isNotEmpty;

  bool get hasDanmaku => DanmakuService.configured;

  String get scraperSourceLabel => hasTmdb ? 'TMDB + TVmaze' : 'TVmaze（免费）';

  List<MediaSource> get sources => List.unmodifiable(_sources);

  /// 聚合结果缓存：byKind / aggregate 都是 O(n) 的正则+排序，
  /// 首页每次重建要调十几次，必须缓存。失效统一走 notifyListeners。
  final Map<MediaKind, List<ScannedVideo>> _byKindCache = {};
  final Map<String, List<ScannedVideo>> _aggregateCache = {};

  @override
  void notifyListeners() {
    _byKindCache.clear();
    _aggregateCache.clear();
    super.notifyListeners();
  }

  /// 缓存版 aggregate()：按媒体源缓存，notifyListeners 时统一失效。
  List<ScannedVideo> _aggregated(String sourceId) {
    final cached = _aggregateCache[sourceId];
    if (cached != null) return cached;
    final videos = _videosBySource[sourceId];
    if (videos == null || videos.isEmpty) return const [];
    return _aggregateCache[sourceId] = aggregate(videos);
  }

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
    final cached = _byKindCache[kind];
    if (cached != null) return cached;
    // 先按文件夹聚合，再按聚合后的分类筛选：
    // 这样「想见你」这类 14 集的剧集不会留在电影分类里。
    final merged = <String, ScannedVideo>{};
    for (final entry in _videosBySource.entries) {
      final aggregated = _aggregated(entry.key);
      for (final video in aggregated) {
        if (video.kind != kind) continue;
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
    return _byKindCache[kind] = list;
  }

  /// 一部剧的每一季（跨文件夹、跨 TMDB ID）。单季剧集返回它自己。
  ///
  /// 判据与 byKind 合并一致：规范化剧名相同即同一部剧的不同季，
  /// 因此《旋风少女》《旋风少女2》即使 TMDB 是两个条目也能归到一起。
  List<ScannedVideo> seasonsOf(ScannedVideo video) {
    final key = _seriesMergeKey(video);
    final seasons = <ScannedVideo>[];
    for (final entry in _videosBySource.entries) {
      for (final item in _aggregated(entry.key)) {
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

  /// 同步所有媒体源（扫描完成后会自动触发刮削）。
  Future<int> syncAll() async {
    final targets = List<MediaSource>.of(_sources);
    var done = 0;
    for (final source in targets) {
      try {
        await scan(source.id);
        if (scanStatus != ScanStatus.failed) done++;
      } catch (_) {
        // 单个源失败不影响其他源
      }
    }
    return done;
  }

  /// 未刮削的聚合条目（不进前端，等设置页手动处理）。
  List<ScannedVideo> unscrapedItems() {
    final result = <ScannedVideo>[];
    final seen = <String>{};
    for (final sourceId in _videosBySource.keys) {
      for (final video in _aggregated(sourceId)) {
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
        // 花絮不过滤：详情页需要它们单独分区展示
        if (parentPathOf(candidate.path) != parent) continue;
        result.add(candidate);
      }
    }
    // 正片排前、花絮排后；同类按自然顺序
    result.sort((a, b) {
      final aExtra = WebDavService.isExtraFile(a.title) ? 1 : 0;
      final bExtra = WebDavService.isExtraFile(b.title) ? 1 : 0;
      if (aExtra != bExtra) return aExtra - bExtra;
      return _naturalCompare(a.path, b.path);
    });
    return result.isEmpty ? [video] : result;
  }

  /// 单集文件所属的聚合条目（按同一媒体源 + 同一文件夹查找）。
  ///
  /// [resolveAggregated] 只匹配聚合条目的代表文件；播放历史可能来自任意一集，
  /// 因此这里按文件夹反查，才能拿到正确的剧名、季号和集数。
  ScannedVideo aggregateOf(ScannedVideo video) {
    final videos = _videosBySource[video.sourceId];
    if (videos == null || videos.isEmpty) return video;
    final parent = parentPathOf(video.path);
    for (final item in _aggregated(video.sourceId)) {
      if (parentPathOf(item.path) == parent) return item;
    }
    return video;
  }

  /// 剧集卡片的集数徽标；电影或无法解析集数时返回 null。
  static String? episodeLabelOf(ScannedVideo video) {
    if (video.kind == MediaKind.movie) return null;
    final episode = episodeNumberOfVideo(video);
    if (episode == null) return null;
    final season = seasonOf(video);
    if (season > 1) return 'S${season}E$episode';
    final unit = video.kind == MediaKind.variety ? '期' : '集';
    return '第 $episode $unit';
  }

  /// 集名是否只是占位（第N话/第N集/Episode N/E{N}），这类不展示。
  static bool isPlaceholderEpisodeTitle(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return true;
    final pattern = RegExp(
      r'^(第\s*[0-9一二三四五六七八九十百]+\s*[话話集期回]'
      r'|episode\s*\d+'
      r'|e\d{1,3}'
      r'|第\s*\d+\s*[话話集])$',
      caseSensitive: false,
    );
    return pattern.hasMatch(text);
  }

  /// 单集展示名：优先「第 N 集 · 单集标题」，没有标题时只显示集号。
  static String episodeDisplayTitle(ScannedVideo video, {int? fallbackNumber}) {
    final number = episodeNumberOfVideo(video) ?? fallbackNumber ?? 1;
    final title = video.episodeTitle?.trim() ?? '';
    if (title.isNotEmpty && !isPlaceholderEpisodeTitle(title)) {
      return '第 $number 集 · $title';
    }
    return '第 $number 集';
  }

  /// 从单集标题中剥离集数标记，得到可展示的剧名。
  static String seriesTitleForDisplay(String title) {
    var text = title.trim();
    final patterns = [
      RegExp(r'\s*[sS]\d{1,2}[eE]\d{1,3}.*$'),
      RegExp(r'\s*第\s*\d{1,4}\s*[集话期].*$'),
      RegExp(
        r'(?:^|[.\s_-])[eE][pP]?\d{1,3}(?:$|[.\s_-]).*$',
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      if (match != null && match.start > 0) {
        text = text.substring(0, match.start).trim();
      }
    }
    return text.replaceAll(RegExp(r'[.\s_-]+$'), '');
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
    await _db.open();
    await _loadScrapeSettings();
    await _migrateLegacyStorage();
    final sources = await _db.loadSources();
    if (sources.isEmpty) return;
    try {
      _sources
        ..clear()
        ..addAll(sources);
      for (final source in _sources) {
        if (!source.isLocal) {
          final password = await _store.readPassword(source.id);
          if (password != null) _passwords[source.id] = password;
        }
      }
      _videosBySource.addAll(await _db.loadVideos());
      notifyListeners();
      await _migrateKinds();
    } catch (_) {
      // 配置损坏时宁可重新添加，也不让应用崩溃。
    }
  }

  /// 一次性把旧版安全存储的媒体源、扫描缓存迁移到 SQLite。
  Future<void> _migrateLegacyStorage() async {
    if (await _db.hasCompletedLegacyMigration()) return;
    try {
      final raw = await _store.readSources();
      final existing = await _db.loadSources();
      var allSaved = true;
      if (existing.isEmpty && raw != null && raw.isNotEmpty) {
        final sources = (jsonDecode(raw) as List<Object?>)
            .map((item) => MediaSource.fromJson(item! as Map<String, Object?>))
            .toList();
        await _db.saveSources(sources);
        for (final source in sources) {
          final videosRaw = await _store.read('framelet.videos.${source.id}');
          if (videosRaw == null || videosRaw.isEmpty) continue;
          try {
            final videos = (jsonDecode(videosRaw) as List<Object?>)
                .map(
                  (item) =>
                      ScannedVideo.fromJson(item! as Map<String, Object?>),
                )
                .toList();
            await _db.saveVideos(source.id, videos);
          } catch (_) {
            // 单源缓存损坏时跳过，保留可恢复的源配置。
            allSaved = false;
          }
        }
      }
      if (!allSaved) return;
      await _db.markLegacyMigrationCompleted();
      // 仅在成功落库后清理旧副本；密码与其它敏感设置仍留在安全存储。
      for (final source in await _db.loadSources()) {
        await _store.delete('framelet.videos.${source.id}');
      }
      await _store.delete('framelet.sources');
    } catch (_) {
      // 迁移失败不阻塞启动，下次启动继续尝试。
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
        var kind = video.kind;
        if (video.kind == MediaKind.movie &&
            WebDavService.looksLikeEpisode(video.title)) {
          kind = MediaKind.series;
        }
        kind = kindForGenres(kind, video.genres);
        if (kind != video.kind) {
          videos[i] = video.copyWith(kind: kind);
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
  /// 扫描完成后自动刮削新内容（默认开启）。
  bool autoScrapeAfterScan = true;

  Future<void> _loadScrapeSettings() async {
    try {
      scrapeProxy = await _store.read('framelet.scrape.proxy');
      tmdbKey = await _store.read('framelet.scrape.tmdbkey');
      final provider = await _store.read('framelet.danmaku.provider');
      danmakuProvider =
          DanmakuProvider.values
              .where((item) => item.name == provider)
              .firstOrNull ??
          DanmakuProvider.dandanplay;
      danmakuBaseUrl =
          await _store.read('framelet.danmaku.baseUrl') ??
          (danmakuProvider == DanmakuProvider.dandanplay
              ? DanmakuService.officialBaseUrl
              : '');
      danmakuAppId =
          await _store.read('framelet.danmaku.appId') ??
          await _store.read('framelet.dandanplay.appId');
      danmakuAppSecret =
          await _store.read('framelet.danmaku.appSecret') ??
          await _store.read('framelet.dandanplay.appSecret');
      final auto = await _store.read('framelet.scrape.auto');
      // 未设置过时默认开启
      autoScrapeAfterScan = auto == null ? true : auto == '1';
      ScraperService.proxyAddress = (scrapeProxy ?? '').trim().isEmpty
          ? null
          : scrapeProxy!.trim();
      ScraperService.tmdbApiKey = (tmdbKey ?? '').trim().isEmpty
          ? ScraperService.builtinTmdbApiKey
          : tmdbKey!.trim();
      UpdateService.proxyAddress = scrapeProxy;
      DanmakuService.provider = danmakuProvider;
      DanmakuService.baseUrl = danmakuBaseUrl;
      DanmakuService.appId = danmakuAppId;
      DanmakuService.appSecret = danmakuAppSecret;
      DanmakuService.proxyAddress = ScraperService.proxyAddress;
    } catch (_) {
      // 读取失败不影响使用默认源
    }
  }

  /// 保存刮削设置。留空表示清除该项。
  Future<void> setAutoScrapeAfterScan(bool value) async {
    autoScrapeAfterScan = value;
    await _store.write('framelet.scrape.auto', value ? '1' : '0');
    notifyListeners();
  }

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
        ? ScraperService.builtinTmdbApiKey
        : this.tmdbKey!.trim();
    ScraperService.resetNetworkSettings();
    UpdateService.proxyAddress = scrapeProxy;
    DanmakuService.proxyAddress = ScraperService.proxyAddress;
    notifyListeners();
  }

  Future<void> saveDanmakuSettings({
    required DanmakuProvider provider,
    required String baseUrl,
    required String appId,
    required String appSecret,
  }) async {
    danmakuProvider = provider;
    danmakuBaseUrl = provider == DanmakuProvider.dandanplay
        ? DanmakuService.officialBaseUrl
        : baseUrl.trim();
    danmakuAppId = appId.trim();
    danmakuAppSecret = appSecret.trim();
    await _store.write('framelet.danmaku.provider', danmakuProvider.name);
    await _store.write('framelet.danmaku.baseUrl', danmakuBaseUrl);
    await _store.write('framelet.danmaku.appId', danmakuAppId!);
    await _store.write('framelet.danmaku.appSecret', danmakuAppSecret!);
    DanmakuService.provider = danmakuProvider;
    DanmakuService.baseUrl = danmakuBaseUrl;
    DanmakuService.appId = danmakuAppId;
    DanmakuService.appSecret = danmakuAppSecret;
    DanmakuService.proxyAddress = ScraperService.proxyAddress;
    DanmakuService.clearCache();
    notifyListeners();
  }

  /// 清除所有已下载的刮削图片，并清空数据库里的图片路径。
  /// TMDB 匹配结果、简介、评分等元数据保留，下次刮削会重新下载图片。
  Future<({int files, int bytes})> clearImageCache() async {
    final stats = ScraperService.clearImageCache();
    for (final entry in _videosBySource.entries) {
      final videos = entry.value;
      var changed = false;
      for (var i = 0; i < videos.length; i++) {
        final video = videos[i];
        if (video.posterPath == null &&
            video.backdropPath == null &&
            video.stillPath == null) {
          continue;
        }
        videos[i] = video.withoutImages();
        changed = true;
      }
      if (changed) await _persistVideos(entry.key);
    }
    notifyListeners();
    return stats;
  }

  Future<void> _persistSources() async {
    await _db.saveSources(_sources);
  }

  Future<void> _persistVideos(String sourceId) async {
    final videos = _videosBySource[sourceId];
    if (videos == null || videos.isEmpty) {
      await _db.saveVideos(sourceId, const []);
      return;
    }
    await _db.saveVideos(sourceId, videos);
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
    if (source.isLocal) {
      _passwords.remove(source.id);
      await _store.deletePassword(source.id);
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
    await _db.deleteSourceData(id);
    notifyListeners();
  }

  /// 连接测试。返回 null 表示成功，否则为可读错误信息。
  Future<String?> testConnection(MediaSource source, String password) async {
    try {
      if (source.isLocal) {
        await LocalMediaService.testConnection(source);
      } else {
        await WebDavService.testConnection(source, password);
      }
      return null;
    } on StateError catch (error) {
      // WebDavService 抛出的是已经写好人话的诊断文案，原样透传
      return error.message;
    } catch (error) {
      return describeError(error);
    }
  }

  /// 全量扫描一个媒体源。完成后视频按分类就位。
  Future<void> scan(String sourceId) async {
    final source = sourceById(sourceId);
    final password = _passwords[sourceId];
    if (source == null) return;
    if (!source.isLocal && password == null) {
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
      final videos = source.isLocal
          ? await LocalMediaService.scan(
              source,
              onProgress: (message) {
                scanProgress = message;
                notifyListeners();
              },
            )
          : await WebDavService.scan(
              source,
              password!,
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
            kind: kindForGenres(videos[i].kind, old.genres),
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
      // 扫描完成后自动刮削：只补没刮过的条目（已有海报的自动跳过）
      if (autoScrapeAfterScan && !scraping && unscrapedItems().isNotEmpty) {
        unawaited(scrapeAll());
      }
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
    // 注入刮削日志回调：图片下载等失败必须显性化，否则无从排查
    ScraperService.onLog = _scrapeLog;
    scraping = true;
    scrapeDone = 0;
    scrapeMatched = 0;
    scrapeTotal = 0;
    scrapeProgress = '准备刮削…';
    notifyListeners();

    try {
      final jobs = _scrapeJobsOf(_videosBySource);

      // 进度按「条目数」统计而非任务数：一个 40 集的剧是 1 个任务
      // 却是 40 个条目，任务进度会与「待匹配」统计严重对不上
      scrapeTotal = jobs.fold(0, (sum, job) => sum + job.group.length);
      if (scrapeTotal == 0) {
        scrapeProgress = '媒体库还是空的，先同步媒体源';
        return;
      }

      _scrapeLog('共 $scrapeTotal 个任务开始');
      final networkFailedJobs =
          <({ScannedVideo representative, List<ScannedVideo> group})>[];
      for (final job in jobs) {
        final target = job.group.firstWhere(
          (v) => v.posterPath != null,
          orElse: () => job.representative,
        );
        final isSeriesJob = job.group.length > 1;
        final hasPoster = _imageExists(target.posterPath);
        final hasBackdrop = _imageExists(target.backdropPath);
        final stillComplete =
            !isSeriesJob ||
            job.group.where((v) => _imageExists(v.stillPath)).length >=
                ((job.group.length + 1) ~/ 2);
        if (!force && hasPoster && hasBackdrop && stillComplete) {
          final episodes = job.group.length;
          scrapeDone += episodes;
          scrapeMatched += episodes;
          scrapeProgress = '已刮削 $scrapeDone / $scrapeTotal 个条目（跳过已有海报）';
          // 早期版本刮削没落 tmdbTitle（海报下显示的是目录名）：
          // 对这类条目按既有 tmdbId 补拉一次详情，把官方名写回库。
          // 只在缺名时触发，补齐后不再产生请求。
          await _backfillTmdbTitle(job);
          // 不逐条 notify：几百个已刮条目会在一帧内触发几百次全界面重建
          continue;
        }

        final matched = await _processScrapeJob(job);
        if (!matched && ScraperService.tmdbCoolingDown) {
          // 接口处于离线冷却（网络原因）才进重试队列；
          // 真正「搜不到结果」的留给手动匹配。
          networkFailedJobs.add(job);
        }
      }

      // 网络原因失败的任务：等离线冷却结束自动重试一轮（仅一轮，
      // 避免死循环）。
      if (networkFailedJobs.isNotEmpty) {
        scrapeProgress =
            '${networkFailedJobs.length} 个任务因网络失败，'
            '等线路恢复后自动重试…';
        notifyListeners();
        var waited = 0;
        while (ScraperService.tmdbCoolingDown && waited < 70) {
          await Future.delayed(const Duration(seconds: 2));
          waited += 2;
        }
        if (!ScraperService.tmdbCoolingDown) {
          scrapeProgress =
              '线路恢复，自动重试 ${networkFailedJobs.length} 个任务…';
          notifyListeners();
          for (final job in networkFailedJobs) {
            // 首轮已计入进度，重试前先扣回，避免重复计数
            scrapeDone -= job.group.length;
            await _processScrapeJob(job);
          }
        }
      }

      final unmatched = scrapeTotal - scrapeMatched;
      scrapeProgress = unmatched <= 0
          ? '刮削完成，共匹配 $scrapeMatched 个条目'
          : '刮削完成：已匹配 $scrapeMatched / $scrapeTotal，'
                '$unmatched 个未匹配（可在下方手动匹配，或先检测刮削线路）';
    } finally {
      scraping = false;
      notifyListeners();
    }
  }

  /// 早期版本刮削只落海报没落 tmdbTitle：对已刮但缺官方名的条目，
  /// 按既有 tmdbId 补拉一次详情把名字写回库。每条至多一次轻量请求，
  /// 补齐后不再触发。
  Future<void> _backfillTmdbTitle(
    ({ScannedVideo representative, List<ScannedVideo> group}) job,
  ) async {
    final id = job.representative.tmdbId;
    if (id == null) return;
    if ((job.representative.tmdbTitle ?? '').trim().isNotEmpty) return;
    final details = await ScraperService.fetchTmdbDetails(
      mediaType: job.representative.kind == MediaKind.movie ? 'movie' : 'tv',
      id: id,
    );
    final name = details?.name.trim() ?? '';
    if (name.isEmpty) return;
    for (final member in job.group) {
      _updateVideo(
        member.sourceId,
        member.path,
        (video) => video.copyWith(tmdbTitle: name),
      );
    }
    await _persistVideos(job.representative.sourceId);
    notifyListeners();
  }

  /// 单个刮削任务：解析查询词 → 复用/搜索 TMDB → TVmaze 兜底 → 落库
  /// → 下载剧照。返回是否成功匹配。首轮与网络失败重试共用。
  Future<bool> _processScrapeJob(
    ({ScannedVideo representative, List<ScannedVideo> group}) job,
  ) async {
        scrapeProgress = '正在匹配「${job.representative.title}」…';
        _scrapeLog(
          '任务 $scrapeDone+: ${job.representative.title}（${job.group.length} 集）',
        );
        notifyListeners();

        final parsed = ScraperService.parseTitle(job.representative.title);
        final preferTv =
            job.group.length > 1 || job.representative.kind != MediaKind.movie;
        final isSeriesJob = job.group.length > 1;
        final seasonNumber = seasonOf(job.representative);
        var matched = false;

        // 候选评估：拉详情 + 目标季集数据，满足要求才算命中。
        // TMDB 上存在残缺的重复条目（如「旋风少女2」只登记了 1 季 1 集，
        // 而主条目「旋风少女」自带两季）——精确同名反而先命中它们，
        // 表现为多季拆成多个条目、整季集标题与剧照拉空。
        // 剧集因此要求目标季能拉到集数据；拉不到只记为保底候选，
        // 由外层换下一个查询词（通常是剥掉季号的主名）重试。
        ScrapeResult? best;
        ScrapeResult? firstUsable;
        var episodeInfos = const <int, ({String? title, String? stillUrl})>{};
        String? seasonOverview;
        String? seasonAirDate;
        double? seasonRuntimeSec;

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
            // 每季简介不同，优先写季简介；拉不到再退回整剧简介。
            final seasonDetails = await ScraperService.fetchSeasonDetails(
              tvId: details.tmdbId ?? tmdbId,
              seasonNumber: seasonNumber,
            );
            episodeInfos = episodes;
            seasonOverview = seasonDetails?.overview;
            seasonAirDate = seasonDetails?.airDate;
            seasonRuntimeSec = seasonDetails?.runtimeSec;
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
        // 2) TMDB 搜索（中文片名与电影覆盖最好），逐个查询词尝试。
        //    三个来源按置信度排序：条目标题 → 文件名 → 祖先目录名，
        //    已试过的查询词不重复请求。
        final triedQueries = <String>{};
        Future<bool> searchQuery(String query, int? year) async {
          final q = query.trim();
          if (q.isEmpty || !triedQueries.add(q)) return false;
          final hit = await ScraperService.searchTmdb(
            q,
            year: year,
            preferTv: preferTv,
          );
          if (hit?.tmdbId == null) return false;
          await consider(hit!.tmdbId!, hit.mediaType ?? 'movie');
          return best != null;
        }

        if (best == null) {
          for (final query in parsed.queries) {
            if (await searchQuery(query, parsed.year)) break;
          }
        }
        // 2.5) 文件名兜底：目录名常带序号/标签噪音（「24 黑寡妇 Black
        // Widow MA」），正式发布的文件名（Black.Widow.2021.2160p…）反而
        // 是 guessit 式的干净来源。仅在前面的查询词全部落空时才试。
        if (best == null) {
          final segments = job.representative.path.split(RegExp(r'[\\/]'));
          final baseName = segments.last;
          final fromFile = ScraperService.parseTitle(baseName);
          for (final query in fromFile.queries) {
            if (await searchQuery(query, fromFile.year ?? parsed.year)) break;
          }
          // 2.6) 祖先目录兜底：网盘常见「/网盘/片名/标签子目录/文件.mkv」
          //      结构（挽救计划/英语中字/…、变相怪杰(1994) 4K/…），真正的
          //      片名往往在上级目录名里。从最深一层往上逐个试。
          if (best == null && segments.length > 1) {
            for (final dir in segments.reversed.skip(1)) {
              if (best != null) break;
              if (dir.isEmpty) continue;
              final fromDir = ScraperService.parseTitle(dir);
              for (final query in fromDir.queries) {
                if (await searchQuery(query, fromDir.year ?? parsed.year)) {
                  break;
                }
              }
            }
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

        final episodeStillPaths = <int, String>{};
        if (result != null) {
          final scraped = result;
          // 先落海报与详情，让条目立即可见（isScraped 依赖 posterPath
          // 或 tmdbId）。老流程把全部集剧照下载完才写库，中途关应用/
          // 断网会让整条进度全丢（龙门镖局事故）。
          String? posterPath;
          if (scraped.posterUrl != null) {
            posterPath = await ScraperService.downloadPoster(
              scraped.posterUrl!,
              cacheKey: '${job.representative.kind.name}_${scraped.name}',
            );
          }
          final scrapedBackdrop = await _downloadBackdrop(scraped);
          if (posterPath != null ||
              scraped.summary != null ||
              scraped.rating != null ||
              scraped.tmdbId != null) {
            if (posterPath != null || scraped.tmdbId != null) {
              scrapeMatched += job.group.length;
              matched = true;
            }
            for (final member in job.group) {
              final episodeNumber = episodeNumberOfVideo(member);
              _updateVideo(
                member.sourceId,
                member.path,
                (video) => video.copyWith(
                  posterPath: posterPath,
                  summary: seasonOverview ?? scraped.summary,
                  rating: scraped.rating,
                  backdropPath: scrapedBackdrop,
                  genres: scraped.genres,
                  cast: scraped.cast,
                  releaseDate: seasonAirDate ?? scraped.releaseDate,
                  runtimeSec: seasonRuntimeSec ?? scraped.runtimeSec,
                  episodeTitle: episodeInfos[episodeNumber]?.title,
                  tmdbId: scraped.tmdbId,
                  // TMDB 官方名落库：聚合层与海报墙的展示名都取它
                  tmdbTitle: scraped.name.trim().isEmpty
                      ? null
                      : scraped.name.trim(),
                  kind: kindForGenres(video.kind, scraped.genres),
                ),
              );
            }
            await _persistVideos(job.representative.sourceId);
          }
        }

        // 剧照逐张下载、逐张落库（断点续传）：中断后重刮时
        // downloadPoster 的本地缓存会命中已下载的，只补缺失的。
        for (final entry in episodeInfos.entries) {
          final stillUrl = entry.value.stillUrl;
          if (stillUrl == null) continue;
          final path = await ScraperService.downloadPoster(
            stillUrl,
            cacheKey: 'still_${result?.tmdbId}_s${seasonNumber}e${entry.key}',
          );
          if (path == null) continue;
          episodeStillPaths[entry.key] = path;
          for (final member in job.group) {
            if (episodeNumberOfVideo(member) != entry.key) continue;
            _updateVideo(
              member.sourceId,
              member.path,
              (video) => video.copyWith(stillPath: path),
            );
          }
          await _persistVideos(job.representative.sourceId);
        }

        if (result == null) {
          _scrapeLog(
            '  未匹配：${job.representative.title}'
            '${ScraperService.lastError.isEmpty ? '' : '（${ScraperService.lastError}）'}',
          );
        }

        scrapeDone += job.group.length;
        _scrapeLog('  完成 $scrapeDone/$scrapeTotal');
        scrapeProgress = '已刮削 $scrapeDone / $scrapeTotal 个条目';
        notifyListeners();
        return matched;
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
    for (final item in _aggregated(video.sourceId)) {
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
        final seasonDetails = await ScraperService.fetchSeasonDetails(
          tvId: candidate.tmdbId!,
          seasonNumber: seasonNumber,
        );
        summary = seasonDetails?.overview ?? summary;
        releaseDate = seasonDetails?.airDate ?? releaseDate;
        runtimeSec = seasonDetails?.runtimeSec ?? runtimeSec;
      }
    } else if (candidate.tvmazeId != null) {
      final details = await ScraperService.fetchTvmazeDetails(
        candidate.tvmazeId!,
      );
      if (details != null) {
        summary = details.summary ?? summary;
        rating = details.rating ?? rating;
        genres = details.genres;
        cast = details.cast;
        releaseDate = details.releaseDate;
        runtimeSec = details.runtimeSec;
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
          // 手动匹配同样要落 TMDB 官方名，海报墙才不显示原始文件名
          tmdbTitle: candidate.name.trim().isEmpty
              ? null
              : candidate.name.trim(),
          kind: kindForGenres(video.kind, genres),
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

  /// 把底层错误翻译成人话。分支顺序注意：dio 的连接超时 toString 是
  /// 「DioError [connection timeout]」，含 "connection" 字样，必须先判
  /// 超时再判 connection，否则超时会被误报成「无法连接」。
  static String describeError(Object error) {
    final text = error.toString();
    final lower = text.toLowerCase();
    if (lower.contains('401') ||
        lower.contains('unauthorized') ||
        lower.contains('auth')) {
      return '用户名或密码不正确（服务器返回 401）';
    }
    if (lower.contains('404')) {
      return '目录不存在（服务器返回 404），请检查媒体目录';
    }
    if (lower.contains('timed out') ||
        lower.contains('timeout') ||
        lower.contains('连接超时')) {
      return '连接超时，服务器无响应。若域名有 IPv6 地址，常见原因是 '
          'IPv6 路由不通（浏览器会自动回落 IPv4 所以网页打得开），'
          '可尝试重新测试连接（会自动改用 IPv4）';
    }
    if (text.contains('Connection refused') || lower.contains('connection')) {
      return '无法连接服务器，请检查地址与网络';
    }
    return '连接失败：$text';
  }

  static bool _imageExists(String? path) {
    if (path == null || path.isEmpty) return false;
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// TMDB 类型 → 应用分类：动画归动漫，真人秀/脱口秀归综艺。
  /// 电影不参与归类，避免动画电影从「电影」里消失。
  static MediaKind kindForGenres(MediaKind current, List<String> genres) {
    if (current == MediaKind.movie || genres.isEmpty) return current;
    final text = genres.join(' ');
    if (text.contains('动画')) return MediaKind.anime;
    if (text.contains('真人秀') || text.contains('脱口秀')) {
      return MediaKind.variety;
    }
    return current;
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
      // 各文件独立，标题用文件名解析出的片名（比原始文件名干净），
      // 解析不出再回退清洗后的文件名
      if (folderTitle == null || folderTitle.isEmpty) {
        for (final video in group) {
          final parsedName = _parsedName(video);
          result.add(
            video.copyWith(
              title: parsedName.isNotEmpty ? parsedName : video.title,
            ),
          );
        }
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
        kind = kindForGenres(kind, genreSource.genres);
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

      // 电影：按「文件名解析出的片名+年份」聚类（Jellyfin 规则——
      // 同目录多文件只有解析出同一部片才是多版本，不同的各自独立）。
      // 目录是容器还是片名文件夹由此自然判定，不再依赖通用名单枚举。
      final clusters = _clusterMovieFiles(group);
      // 花絮不单独成片：正片存在时挂到其详情页「花絮与相关」分区
      final mains = clusters
          .where((c) => !WebDavService.isExtraFile(c.first.title))
          .toList();
      final effective = mains.isNotEmpty ? mains : clusters;
      final folderIsTitle = effective.length == 1 &&
          _sameTitleLoose(
            _parsedName(effective.first.first),
            folderTitle,
          );
      for (final cluster in effective) {
        final first = cluster.first;
        final ownTitle = first.tmdbTitle?.trim() ?? '';
        final parsedName = _parsedName(first);
        final groupTitle = (tmdbTitle != null && tmdbTitle.isNotEmpty)
            ? tmdbTitle
            : folderTitle;
        final String title;
        if (ownTitle.isNotEmpty) {
          title = ownTitle;
        } else if (folderIsTitle || parsedName.isEmpty) {
          // 目录名与文件名解析一致（片名文件夹）或文件名无法解析：
          // 用 TMDB 名 / 目录名
          title = groupTitle;
        } else {
          // 目录是容器（里面是多部不同的片）：用文件名解析出的片名
          title = parsedName;
        }
        result.add(
          first.copyWith(
            title: title,
            episodeCount: 1,
            posterPath: folderIsTitle
                ? posterSource.posterPath
                : first.posterPath,
            summary: folderIsTitle ? posterSource.summary : first.summary,
            rating: folderIsTitle ? posterSource.rating : first.rating,
            tmdbId: folderIsTitle ? tmdbId : first.tmdbId,
          ),
        );
      }
    }
    return result;
  }

  /// 把同目录的电影文件按「解析出的片名 + 年份」聚类。
  ///
  /// 年份缺失视为通配：同名即同一部（多版本常只有部分文件带年份）；
  /// 同名但年份不同是不同的片（续集/重拍版），按年份拆开。
  /// 返回 ≥1 个聚类，每个聚类是同一部影片的版本集合。
  static List<List<ScannedVideo>> _clusterMovieFiles(
    List<ScannedVideo> group,
  ) {
    final parsedCache = <ScannedVideo, ({String name, int? year})>{};
    for (final video in group) {
      final parsed = ScraperService.parseTitle(video.title);
      parsedCache[video] = (
        name: parsed.queries.isEmpty ? '' : parsed.queries.first,
        year: parsed.year,
      );
    }
    final byName = <String, List<ScannedVideo>>{};
    for (final video in group) {
      final name = parsedCache[video]!.name.trim().toLowerCase();
      byName.putIfAbsent(
        name.isEmpty ? 'file:${video.title.toLowerCase()}' : name,
        () => [],
      ).add(video);
    }
    final clusters = <List<ScannedVideo>>[];
    for (final sameName in byName.values) {
      final years = sameName
          .map((v) => parsedCache[v]!.year)
          .whereType<int>()
          .toSet();
      if (years.length <= 1) {
        clusters.add(sameName);
        continue;
      }
      // 同名不同年份是不同的片，按年份拆开（无年份的归入最早年份组）
      final byYear = <int, List<ScannedVideo>>{};
      for (final video in sameName) {
        final year = parsedCache[video]!.year ?? -1;
        byYear.putIfAbsent(year, () => []).add(video);
      }
      final ordered = byYear.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      for (final entry in ordered) {
        clusters.add(entry.value);
      }
    }
    return clusters;
  }

  /// 文件名解析出的主片名（parseTitle 的首个查询词），解析失败返回空串。
  static String _parsedName(ScannedVideo video) {
    final parsed = ScraperService.parseTitle(video.title);
    return parsed.queries.isEmpty ? '' : parsed.queries.first.trim();
  }

  /// 宽松比较两个片名：去空白/点/下划线/括号内容与大小写后相等，
  /// 或一方为另一方的前缀（目录名常带年份尾巴，如「一代宗师 (2013)」）。
  static bool _sameTitleLoose(String a, String b) {
    String norm(String text) => text
        .toLowerCase()
        .replaceAll(RegExp(r'[（(][^）)]*[）)]'), '')
        .replaceAll(RegExp(r'[\s._（）()\-]+'), '');
    final left = norm(a);
    final right = norm(b);
    if (left.isEmpty || right.isEmpty) return false;
    return left == right || left.startsWith(right) || right.startsWith(left);
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

  /// 由所在目录推导剧名：跳过「1」（季号）这类无效目录，向上找真正的剧名。
  /// 返回 null 表示没有有效目录名，回退用清洗后的文件名。
  ///
  /// 关键规则：直接父目录是分类容器（movie/电影/夸克网盘这类）时
  /// 返回 null——容器的祖先只可能是组织性目录（挂载名/根目录），
  /// 继续向上只会拿到「首页」这类垃圾片名；此时正确标题就是文件名。
  /// 季目录（1、Season 2）除外：它们的上层才是剧名。
  static String? _seriesTitle(String parentPath, List<ScannedVideo> group) {
    var path = parentPath;
    var segment = _lastSegment(path);
    if (!_isSeasonFolder(segment) && _isGenericFolder(segment)) return null;
    var guard = 0;
    while (guard < 4) {
      if (!_isGenericFolder(segment) &&
          !_isSeasonFolder(segment) &&
          segment.isNotEmpty) {
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

  /// 目录名是否是季目录：纯数字（1、2）或 Season 2 / Season.2 / Season-2。
  static bool _isSeasonFolder(String segment) =>
      RegExp(r'^\d{1,2}$').hasMatch(segment) ||
      RegExp(r'^season[\s._-]*\d+', caseSensitive: false).hasMatch(segment);

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
      '影视',
      '首页',
      '根目录',
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
