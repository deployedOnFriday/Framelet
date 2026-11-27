import '../models/cast_member.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'proxy_resolver.dart';

/// 刮削结果：海报地址、简介与评分。
class ScrapeResult {
  const ScrapeResult({
    required this.name,
    this.originalName,
    this.posterUrl,
    this.summary,
    this.rating,
    this.year,
    this.backdropUrl,
    this.genres = const [],
    this.cast = const [],
    this.releaseDate,
    this.runtimeSec,
    this.mediaType,
    this.tmdbId,
  });

  final String name;
  final String? originalName;
  final String? posterUrl;
  final String? summary;
  final String? rating;
  final int? year;
  final String? backdropUrl;
  final List<String> genres;
  final List<CastMember> cast;
  final String? releaseDate;
  final double? runtimeSec;
  final String? mediaType;
  final int? tmdbId;
}

/// 手动匹配用的候选条目（搜索结果的一项）。
class ScrapeCandidate {
  const ScrapeCandidate({
    required this.name,
    required this.mediaType,
    this.originalName,
    this.year,
    this.posterUrl,
    this.overview,
    this.rating,
    this.tmdbId,
    this.tvmazeId,
    this.source = 'tmdb',
  });

  final String name;
  final String mediaType; // 'movie' | 'tv'
  final String? originalName;
  final int? year;
  final String? posterUrl;
  final String? overview;
  final String? rating;

  /// TMDB 条目 ID；有 ID 时可继续拉取详情。
  final int? tmdbId;

  /// TVmaze 条目 ID；TMDB 接口不可用时作为免代理兜底。
  final int? tvmazeId;

  final String source;

  String get typeLabel => mediaType == 'tv' ? '剧集' : '电影';

  String get sourceLabel => source == 'tvmaze' ? 'TVmaze' : 'TMDB';
}

/// 刮削线路自检结果：供设置页「检测线路」按钮展示。
class ScrapeDiagnostics {
  const ScrapeDiagnostics({
    required this.apiOk,
    required this.imageOk,
    required this.mode,
    required this.apiDetail,
    required this.imageDetail,
  });

  final bool apiOk;
  final bool imageOk;
  final String mode;
  final String apiDetail;
  final String imageDetail;
}

class _SniAttempt {
  const _SniAttempt({
    required this.ip,
    this.status,
    this.bytes,
    this.error,
    this.conn,
  });

  final String ip;
  final int? status;
  final List<int>? bytes;
  final String? error;

  /// 响应读完后仍可复用的长连接；失败或不可复用时为 null。
  final _KeepAliveConn? conn;
}

/// 一条可复用的 HTTP/1.1 长连接（SNI 直连通道）。
///
/// 原实现每个请求都新建 TCP + TLS 连接（国内直连实测握手 300~400ms），
/// 是 API 延迟的大头。这里把连接按 host 缓存起来，连续请求复用同一条
/// 连接；任何异常都直接判废并回落到新建连接，不做修复尝试。
class _KeepAliveConn {
  _KeepAliveConn({
    required this.host,
    required this.ip,
    required this.socket,
    required this.iterator,
    required this.userAgent,
  });

  final String host;
  final String ip;
  final String userAgent;
  final Socket socket;
  final StreamIterator<List<int>> iterator;
  final List<int> _buffer = [];
  DateTime lastUsed = DateTime.now();
  bool broken = false;

  Future<void> close() async {
    broken = true;
    try {
      await iterator.cancel();
    } catch (_) {}
    try {
      await socket.close();
    } catch (_) {}
  }

  void send(String pathAndQuery, {required bool image}) {
    socket.write(
      'GET $pathAndQuery HTTP/1.1\r\n'
      'Host: $host\r\n'
      'User-Agent: $userAgent\r\n'
      'Accept: ${image ? 'image/avif,image/webp,image/*,*/*;q=0.8' : 'application/json,*/*'}\r\n'
      'Accept-Encoding: identity\r\n'
      'Connection: keep-alive\r\n\r\n',
    );
  }

  /// 读取一个完整响应；连接不可用时返回 null。
  Future<({int status, List<int> body})?> readResponse({
    required int maxBytes,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final headerEnd = ScraperService._findHeaderEnd(_buffer);
      if (headerEnd >= 0) {
        final headers = latin1
            .decode(_buffer.sublist(0, headerEnd))
            .toLowerCase();
        final match = RegExp(r'http/1\.[01]\s+(\d{3})').firstMatch(headers);
        if (match == null) {
          broken = true;
          return null;
        }
        final status = int.tryParse(match.group(1)!) ?? 0;
        final closeAfter = headers.contains('connection: close');
        final chunked = headers.contains('transfer-encoding: chunked');
        final lengthMatch = RegExp(r'content-length:\s*(\d+)')
            .firstMatch(headers);
        final bodyStart = headerEnd + 4;

        if (lengthMatch != null) {
          final length = int.tryParse(lengthMatch.group(1)!);
          if (length == null || length > maxBytes) {
            broken = true;
            return null;
          }
          final need = bodyStart + length;
          while (_buffer.length < need) {
            if (!await _readMore(deadline)) {
              broken = true;
              return null;
            }
          }
          final body = _buffer.sublist(bodyStart, need);
          _buffer.removeRange(0, need);
          if (closeAfter) broken = true;
          lastUsed = DateTime.now();
          return (status: status, body: body);
        }

        if (chunked) {
          while (true) {
            final decoded = ScraperService._tryDecodeChunked(
              _buffer,
              bodyStart,
            );
            if (decoded != null) {
              if (decoded.body.length > maxBytes) {
                broken = true;
                return null;
              }
              _buffer.removeRange(0, decoded.consumed);
              if (closeAfter) broken = true;
              lastUsed = DateTime.now();
              return (status: status, body: decoded.body);
            }
            if (!await _readMore(deadline) ||
                _buffer.length > maxBytes + (1 << 16)) {
              broken = true;
              return null;
            }
          }
        }

        // 无长度信息：只能读到连接关闭，此连接不可再用
        while (await _readMore(deadline)) {
          if (_buffer.length > maxBytes + (1 << 16)) break;
        }
        broken = true;
        final body = _buffer.sublist(bodyStart);
        lastUsed = DateTime.now();
        return (status: status, body: body);
      }

      if (!await _readMore(deadline) || _buffer.length > maxBytes + (1 << 16)) {
        broken = true;
        return null;
      }
    }
  }

  Future<bool> _readMore(DateTime deadline) async {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) return false;
    try {
      final hasNext = await iterator.moveNext().timeout(remaining);
      if (!hasNext) return false;
      _buffer.addAll(iterator.current);
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// 海报与元数据刮削：
/// - 主源 TVmaze（免费、无需密钥，覆盖剧集/动漫/部分电影）
/// - 图片本地缓存，避免重复下载
/// - 限速友好，失败静默跳过，不影响媒体库使用
class ScraperService {
  ScraperService._();

  static const _userAgent = 'Framelet/0.1 (media library scraper)';

  /// API 请求间隔（TMDB/TVmaze 共用）。约 7.7 请求/秒，仍远低于
  /// TMDB 的 50 次/秒上限；刮削任务已允许少量并发，这个值决定 API
  /// 吞吐上限。触发 429 时自动指数退避，恢复后逐步回到基准值。
  static const _minRequestGap = Duration(milliseconds: 130);
  static const _maxRequestGap = Duration(seconds: 3);
  static const _maxRateLimitWait = Duration(seconds: 60);
  static Duration _requestGap = _minRequestGap;
  static DateTime _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);
  static DateTime? _rateLimitedUntil;
  static int _rateLimitStreak = 0;

  /// 刮削过程日志回调（由 MediaLibrary 注入，写入临时目录日志）。
  /// 关键失败（图片下载等）必须经由这里显性化，避免静默丢图。
  static void Function(String message)? onLog;

  /// 内置 TMDB API Key：以「明文 XOR 掩码」的十六进制对存储，
  /// 仓库与二进制中不含可直接 grep 的明文，运行时还原。
  /// 注意这是混淆而非加密——决心逆向仍可还原；TMDB key 属免费
  /// 申请的低敏感凭据，此级别足够。用户在设置里填写的 key 永远优先。
  static const String _tmdbKeyMaskedHex =
      '2805d1326095c22fc1cc628f7c4cea7c827dbfce07ef28a40fda02d50f8d5bf2';
  static const String _tmdbKeyMaskHex =
      '1d67b30151a3f74da5ff5bb9197bdf45b21c88f666d84cc73fb935b338ba3ec4';

  static List<int> _unhex(String hex) => [
    for (var i = 0; i + 1 < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];

  static String get builtinTmdbApiKey {
    final masked = _unhex(_tmdbKeyMaskedHex);
    final mask = _unhex(_tmdbKeyMaskHex);
    return String.fromCharCodes([
      for (var i = 0; i < masked.length; i++) masked[i] ^ mask[i],
    ]);
  }

  /// 可选 HTTP 代理（如 127.0.0.1:7890）。
  static String? proxyAddress;

  /// 可选 TMDB API Key（v3）：配置后优先用 TMDB，中文与电影覆盖最好。
  ///
  /// 默认即内置 Key：安全存储读取失败（macOS 钥匙串无权限、
  /// Android Keystore 异常等）时仍能开箱即用，避免误报
  /// 「未配置 TMDB API Key」。
  static String? tmdbApiKey = builtinTmdbApiKey;

  static const _apiHost = 'api.themoviedb.org';
  static const _apiAltHost = 'api.tmdb.org';

  /// 自建 TMDB API 反代（Cloudflare）：官方全部线路不可达时的最后
  /// 通道。换域名改这里即可。
  static const _apiProxyHost = 'tmdb.qizhunanhai.ccwu.cc';
  static const _imageHost = 'image.tmdb.org';

  /// TMDB 图片实际落在 Bunny CDN。该域名绕开被污染的 image.tmdb.org
  /// 域名，同时仍走 HTTPS 与证书校验。
  static const _imageCdnHost = 'tmdb-image-prod.b-cdn.net';

  /// 内置兜底 IP。来源为 CheckTMDB 每日列表与实测可用的 CloudFront
  /// 边缘节点；不同省份/运营商可达的节点不同，因此同时保留多组。
  static const Map<String, List<String>> _builtinIpv4 = {
    _apiHost: [
      '108.138.246.55',
      '52.85.151.79',
      '3.167.212.53',
      '3.167.192.35',
      '3.167.194.87',
      '3.164.180.201',
      '3.167.212.89',
      '3.167.192.127',
      '18.154.132.115',
      '18.154.130.110',
    ],
    _apiAltHost: [
      '13.226.38.82',
      '13.226.38.125',
      '13.226.38.46',
      '13.226.38.104',
      '3.167.212.53',
      '108.138.246.55',
      '52.85.151.79',
    ],
    _imageHost: [
      '143.244.50.214',
      '143.244.50.83',
      '3.167.212.53',
      '3.167.194.87',
      '3.167.212.89',
      '3.167.192.35',
      '3.164.180.201',
      '3.167.192.127',
    ],
    _imageCdnHost: [
      '79.127.134.131',
      '79.127.134.228',
      '143.244.50.214',
      '143.244.50.83',
    ],
  };

  /// CheckTMDB 的 hosts 列表。jsDelivr 在国内通常可达，作为首选镜像；
  /// 其余两个用于镜像故障时兜底。
  static const _ipListMirrors = <String>[
    'https://cdn.jsdelivr.net/gh/cnwikee/CheckTMDB@main/Tmdb_host_ipv4',
    'https://ghproxy.net/https://raw.githubusercontent.com/cnwikee/CheckTMDB/main/Tmdb_host_ipv4',
    'https://raw.githubusercontent.com/cnwikee/CheckTMDB/main/Tmdb_host_ipv4',
  ];

  static final Map<String, List<String>> _dynamicIps = {};
  static final Map<String, String> _preferredIp = {};
  static final Map<String, DateTime> _ipCooldown = {};
  static final Map<String, ({List<String> ips, DateTime at})> _dnsCache = {};

  /// SNI 长连接池（按 host）。空闲超过 45 秒或出现异常即废弃；
  /// 每个 host 最多保留 4 条，够 3 路并发刮削轮转。
  static const _sniPoolIdleTtl = Duration(seconds: 45);
  static const _sniPoolMaxPerHost = 4;
  static final Map<String, List<_KeepAliveConn>> _sniPool = {};

  static _KeepAliveConn? _takePooledSni(String host) {
    final list = _sniPool[host];
    if (list == null) return null;
    while (list.isNotEmpty) {
      final conn = list.removeLast();
      if (conn.broken ||
          DateTime.now().difference(conn.lastUsed) > _sniPoolIdleTtl) {
        conn.close();
        continue;
      }
      return conn;
    }
    _sniPool.remove(host);
    return null;
  }

  static void _releasePooledSni(_KeepAliveConn conn) {
    if (conn.broken) {
      conn.close();
      return;
    }
    final list = _sniPool.putIfAbsent(conn.host, () => []);
    if (list.length >= _sniPoolMaxPerHost) {
      list.removeAt(0).close();
    }
    list.add(conn);
  }

  static void _closeSniPool() {
    for (final list in _sniPool.values) {
      for (final conn in list) {
        conn.close();
      }
    }
    _sniPool.clear();
  }

  static DateTime _ipListRefreshedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static DateTime _ipRefreshAttemptedAt = DateTime.fromMillisecondsSinceEpoch(
    0,
  );
  static Future<void>? _ipRefreshTask;
  static bool _ipCacheLoaded = false;

  static String? _lastNetworkDetail;
  static int _lastHttpStatus = 0;
  static String _lastChannel = '';
  static DateTime? _tmdbOfflineUntil;
  static DateTime? _tvmazeOfflineUntil;

  /// TMDB GET 结果短时缓存。同一 URL（搜索/详情/季数据）在短时间内只发
  /// 一次请求：剧集任务原本对季接口连发两次（剧照 + 季详情），线路慢时
  /// 白白多等一个往返；网络失败重试与多季条目也复用同一份结果。
  static const _getCacheTtl = Duration(minutes: 10);
  static const _getCacheMax = 300;
  static final Map<String, ({String body, DateTime at})> _getCache = {};

  /// 已确认不存在的图片 URL（404/410）。TMDB 很多剧集没有单集剧照，
  /// 一张缺失的图逐条走完 8 条取图线路要 17~23 秒，整季会卡上几分钟。
  static final Set<String> _missingImages = {};
  static const _missingImagesMax = 4000;

  /// 最近一次刮削网络失败原因；UI 用它区分「真没搜到」与「网络不通」。
  static String? lastSearchError;

  static String get lastError => lastSearchError ?? '';

  static String get lastChannel => _lastChannel;

  /// 设置变更后清掉探测缓存，下一次请求按新代理/网络重新选择线路。
  static void resetNetworkSettings() {
    ProxyResolver.reset();
    _tmdbOfflineUntil = null;
    _rateLimitedUntil = null;
    _rateLimitStreak = 0;
    _requestGap = _minRequestGap;
    _tvmazeOfflineUntil = null;
    _preferredIp.clear();
    _ipCooldown.clear();
    _getCache.clear();
    _missingImages.clear();
    _closeSniPool();
    _closeSharedClient();
    lastSearchError = null;
  }

  /// 复用一个 HttpClient：Dart 的 HttpClient 自带连接池与 keep-alive，
  /// 每个请求新建再强制关闭会让每次请求都重新握手。代理配置变化时重建。
  static HttpClient? _sharedClient;
  static String _sharedClientProxyKey = '';

  static HttpClient _httpClient({String? proxy}) {
    final effective = ProxyResolver.normalize(proxy ?? proxyAddress ?? '');
    final existing = _sharedClient;
    if (existing != null && _sharedClientProxyKey == effective) {
      return existing;
    }
    existing?.close(force: true);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..userAgent = _userAgent
      ..idleTimeout = const Duration(seconds: 20)
      ..maxConnectionsPerHost = 6;
    if (effective.isNotEmpty) {
      client.findProxy = (_) => 'PROXY $effective';
    }
    _sharedClient = client;
    _sharedClientProxyKey = effective;
    return client;
  }

  static void _closeSharedClient() {
    _sharedClient?.close(force: true);
    _sharedClient = null;
    _sharedClientProxyKey = '';
  }

  /// 用户显式配置的代理优先；未配置时尝试系统/环境代理（Clash、v2ray
  /// 等开启「系统代理」后无需再手填），最后才走免代理直连线路。
  static Future<String?> _activeProxy() =>
      ProxyResolver.resolve(explicit: proxyAddress);

  static Future<void> _ensureIpPool() async {
    final now = DateTime.now();
    if (_ipCacheLoaded &&
        now.difference(_ipListRefreshedAt) < const Duration(hours: 12)) {
      return;
    }
    // 拉取失败后 10 分钟内不重复尝试，避免每个请求都等镜像超时。
    if (_ipCacheLoaded &&
        now.difference(_ipRefreshAttemptedAt) < const Duration(minutes: 10)) {
      return;
    }
    if (_ipRefreshTask != null) return _ipRefreshTask!;
    _ipCacheLoaded = true;
    _ipRefreshAttemptedAt = now;
    final task = _refreshIpPoolSafely();
    _ipRefreshTask = task;
    try {
      await task;
    } finally {
      if (identical(_ipRefreshTask, task)) _ipRefreshTask = null;
    }
  }

  static Future<void> _refreshIpPoolSafely() async {
    try {
      _loadIpCache();
      if (DateTime.now().difference(_ipListRefreshedAt) <
          const Duration(hours: 12)) {
        return;
      }
      for (final url in _ipListMirrors) {
        final text = await _fetchSmallText(url);
        if (text == null) continue;
        final parsed = _parseHosts(text);
        if (parsed[_apiHost]?.isNotEmpty != true) continue;
        _dynamicIps
          ..clear()
          ..addAll(parsed);
        _ipListRefreshedAt = DateTime.now();
        _writeIpCache(text);
        onLog?.call(
          '  TMDB 直连 IP 已更新：${parsed[_apiHost]!.first}'
          '${parsed[_imageHost]?.isNotEmpty == true ? ' / ${parsed[_imageHost]!.first}' : ''}',
        );
        return;
      }
      onLog?.call('  TMDB 直连 IP 列表更新失败，使用内置节点');
    } catch (_) {
      // 使用内置节点即可
    }
  }

  static Future<String?> _fetchSmallText(String url) async {
    final client = _httpClient(proxy: await _activeProxy());
    try {
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 4));
      final response = await request.close().timeout(
        const Duration(seconds: 4),
      );
      if (response.statusCode != 200) return null;
      final bytes = await _readLimited(
        response,
        256 * 1024,
        const Duration(seconds: 4),
      );
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    } finally {
      // 共享 HttpClient 自带连接池，不逐请求关闭
    }
  }

  static File _ipCacheFile() =>
      File('${posterDir().parent.path}${Platform.pathSeparator}tmdb_hosts.txt');

  static void _loadIpCache() {
    try {
      final file = _ipCacheFile();
      if (!file.existsSync()) return;
      final parsed = _parseHosts(file.readAsStringSync());
      if (parsed[_apiHost]?.isNotEmpty != true) return;
      _dynamicIps
        ..clear()
        ..addAll(parsed);
      _ipListRefreshedAt = file.lastModifiedSync();
    } catch (_) {
      // 缓存损坏时忽略
    }
  }

  static void _writeIpCache(String text) {
    try {
      final file = _ipCacheFile();
      if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
      file.writeAsStringSync(text, flush: true);
    } catch (_) {
      // 缓存写入失败不影响本次刮削
    }
  }

  static Map<String, List<String>> _parseHosts(String text) {
    final result = <String, List<String>>{};
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final ip = parts.first;
      final host = parts[1].toLowerCase();
      if (host != _apiHost && host != _imageHost) continue;
      if (!RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(ip)) continue;
      final list = result.putIfAbsent(host, () => []);
      if (!list.contains(ip)) list.add(ip);
    }
    return result;
  }

  static List<String> _candidateIps(String host) {
    final now = DateTime.now();
    final result = <String>[];

    void add(String ip) {
      final until = _ipCooldown[ip];
      if (until != null && until.isAfter(now)) return;
      if (!result.contains(ip)) result.add(ip);
    }

    final preferred = _preferredIp[host];
    if (preferred != null) add(preferred);
    for (final ip in _dynamicIps[host] ?? const <String>[]) {
      add(ip);
    }
    for (final ip in _builtinIpv4[host] ?? const <String>[]) {
      add(ip);
    }
    if (host == _imageHost) {
      for (final ip in _builtinIpv4[_apiHost] ?? const <String>[]) {
        add(ip);
      }
    }
    return result.take(16).toList();
  }

  /// 是否处于限流冷却（HTTP 429/503，等待 Retry-After 或指数退避）。
  static bool get isRateLimited =>
      _rateLimitedUntil != null && _rateLimitedUntil!.isAfter(DateTime.now());

  /// 是否处于冷却期（离线或限流），此时请求会被短路直接返回失败。
  static bool get tmdbCoolingDown =>
      isRateLimited ||
      (_tmdbOfflineUntil != null && _tmdbOfflineUntil!.isAfter(DateTime.now()));

  /// 同一 URL 的并发请求只发一次（in-flight 合并）：多个刮削任务同时
  /// 搜同一部剧/拉同一季数据时不重复走网络。
  static final Map<String, Future<String?>> _inflightGets = {};

  /// 带短时缓存的 TMDB GET：命中缓存直接返回，成功响应才写入缓存
  /// （失败不缓存，避免一次瞬时故障卡住后续重试）。
  static Future<String?> _tmdbGet(String pathAndQuery) {
    final cached = _getCache[pathAndQuery];
    if (cached != null) {
      if (DateTime.now().difference(cached.at) <= _getCacheTtl) {
        return Future<String?>.value(cached.body);
      }
      _getCache.remove(pathAndQuery);
    }
    final existing = _inflightGets[pathAndQuery];
    if (existing != null) return existing;

    final task = _tmdbGetAndCache(pathAndQuery);
    _inflightGets[pathAndQuery] = task;
    Future<void>(() async {
      try {
        await task;
      } catch (_) {}
      if (identical(_inflightGets[pathAndQuery], task)) {
        _inflightGets.remove(pathAndQuery);
      }
    });
    return task;
  }

  static Future<String?> _tmdbGetAndCache(String pathAndQuery) async {
    final body = await _tmdbGetNetwork(pathAndQuery);
    if (body != null) {
      if (_getCache.length >= _getCacheMax) {
        final oldest = _getCache.entries.toList()
          ..sort((a, b) => a.value.at.compareTo(b.value.at));
        for (final entry in oldest.take(_getCacheMax ~/ 3)) {
          _getCache.remove(entry.key);
        }
      }
      _getCache[pathAndQuery] = (body: body, at: DateTime.now());
    }
    return body;
  }

  /// 通过「国内可用 IP + 域名 SNI」直连 TMDB API。
  ///
  /// TMDB 在国内被 DNS 污染，直接解析域名常会超时；这里用 SecureSocket
  /// 手工完成 TLS（host 参数保证 SNI 与证书校验仍按域名），再由 IP
  /// 建立 TCP 连接，从而绕过污染。
  static Future<String?> _tmdbGetNetwork(String pathAndQuery) async {
    if (isRateLimited) {
      lastSearchError = 'TMDB 限流冷却中，本轮稍后自动重试';
      return null;
    }
    if (_tmdbOfflineUntil != null &&
        _tmdbOfflineUntil!.isAfter(DateTime.now())) {
      return null;
    }

    var proxy = await _activeProxy();
    final usingSystemProxy =
        (proxyAddress ?? '').trim().isEmpty && proxy != null;
    final uri = Uri.parse('https://$_apiHost$pathAndQuery');
    _lastNetworkDetail = null;
    // 各线路是否收到过 HTTP 状态码。收到了（哪怕 404/5xx）说明线路可达，
    // 属内容/节点层问题；只有全程无响应才算真不可达、才值得全局冷却。
    var sawHttpStatus = false;
    // 状态码按本次请求就地记录：并发刮削时多个请求会同时走线路链，
    // 共享一个静态变量会互相覆盖，导致误判「API Key 无效」。
    var status = 0;

    void noteStatus(int value, {Duration? retryAfter}) {
      status = value;
      _lastHttpStatus = value; // 仅供错误提示展示
      if (value == 0) return;
      sawHttpStatus = true;
      if (value == 429 || value == 503) {
        _noteRateLimited(retryAfter: retryAfter);
      } else if (value == 200 || value == 206) {
        _noteRequestOk();
      }
    }

    if (proxy != null) {
      final result = await _httpGetText(uri, proxy: proxy);
      noteStatus(result.status, retryAfter: result.retryAfter);
      if (result.text != null) {
        _markTmdbOnline('代理');
        return result.text;
      }
      if (status == 401 || status == 403) {
        _markTmdbOnline('代理');
        lastSearchError = 'TMDB API Key 无效或已失效，请到 设置 → 刮削 重新填写';
        return null;
      }
      // 系统代理存在但实际上不通（代理软件已退出等）：本次运行不再尝试，
      // 直接走直连线路，避免每个条目都先等一次代理超时。
      if (usingSystemProxy && status == 0) {
        ProxyResolver.disableSystemProxy();
        proxy = null;
      }
    }

    bool keyRejected() => status == 401 || status == 403;

    void rejectKey(String channel) {
      _markTmdbOnline(channel);
      lastSearchError = 'TMDB API Key 无效或已失效，请到 设置 → 刮削 重新填写';
    }

    final sni = await _sniGetResult(_apiHost, pathAndQuery);
    noteStatus(sni.status);
    if (sni.bytes != null) {
      _markTmdbOnline('SNI 直连');
      return utf8.decode(sni.bytes!, allowMalformed: true);
    }
    if (keyRejected()) {
      // 能收到 401 说明线路是通的，问题在密钥而不是网络。
      rejectKey('SNI 直连');
      return null;
    }

    // api.tmdb.org 是 TMDB 的另一条 CloudFront 线路，域名未被污染时
    // 可直接 HTTPS 访问；这是实测最有效的免代理备用通道。
    final altText = await _httpGetText(
      Uri.parse('https://$_apiAltHost$pathAndQuery'),
    );
    noteStatus(altText.status, retryAfter: altText.retryAfter);
    if (altText.text != null) {
      _markTmdbOnline('api.tmdb.org 直连');
      return altText.text;
    }
    if (keyRejected()) {
      rejectKey('api.tmdb.org 直连');
      return null;
    }

    final altSni = await _sniGetResult(_apiAltHost, pathAndQuery);
    noteStatus(altSni.status);
    if (altSni.bytes != null) {
      _markTmdbOnline('api.tmdb.org SNI');
      return utf8.decode(altSni.bytes!, allowMalformed: true);
    }
    if (keyRejected()) {
      rejectKey('api.tmdb.org SNI');
      return null;
    }

    // 端口 80 + 内置 IP + Host 头：绕过 SNI 阻断与污染 DNS。
    final plain = await _plainHttpGetViaIp(
      _apiHost,
      pathAndQuery,
      acceptAnyStatus: true,
    );
    noteStatus(plain?.status ?? 0);
    if (plain?.bytes != null) {
      _markTmdbOnline('HTTP 直连');
      return utf8.decode(plain!.bytes!, allowMalformed: true);
    }
    if (keyRejected()) {
      rejectKey('HTTP 直连');
      return null;
    }

    final altPlain = await _plainHttpGetViaIp(
      _apiAltHost,
      pathAndQuery,
      acceptAnyStatus: true,
    );
    noteStatus(altPlain?.status ?? 0);
    if (altPlain?.bytes != null) {
      _markTmdbOnline('api.tmdb.org HTTP');
      return utf8.decode(altPlain!.bytes!, allowMalformed: true);
    }
    if (keyRejected()) {
      rejectKey('api.tmdb.org HTTP');
      return null;
    }

    // 部分地区没有 DNS 污染（或用户改了 hosts / 开了系统级 VPN），
    // 普通直连反而最稳，作为最后一条通道。
    final direct = await _httpGetText(uri);
    noteStatus(direct.status, retryAfter: direct.retryAfter);
    if (direct.text != null) {
      _markTmdbOnline('普通直连');
      return direct.text;
    }
    if (keyRejected()) {
      rejectKey('普通直连');
      return null;
    }

    // 自建反代兜底：官方线路全挂时走自己的 Cloudflare 反代，
    // 避免整批任务因离线冷却全部连坐失败。
    // 反代行为（实测）：请求不带 api_key 时注入自己的 key（返回 200）；
    // 带了则原样转发。且响应带 max-age=3600 的缓存头，偶发 404 会被
    // 缓存一小时——因此剥离应用的 key 并加时间戳参数防缓存命中。
    final qIndex = pathAndQuery.indexOf('?');
    final basePath = qIndex < 0
        ? pathAndQuery
        : pathAndQuery.substring(0, qIndex);
    final params = <String>[];
    if (qIndex >= 0) {
      for (final pair in pathAndQuery.substring(qIndex + 1).split('&')) {
        if (pair.isEmpty || pair.startsWith('api_key=')) continue;
        params.add(pair);
      }
    }
    final bust = DateTime.now().millisecondsSinceEpoch;
    Future<String?> tryProxy({required bool withKey}) async {
      final all = <String>[
        if (withKey && (tmdbApiKey?.trim().isNotEmpty ?? false))
          'api_key=${tmdbApiKey!.trim()}',
        ...params,
        '_cb=$bust${withKey ? 'k' : 'n'}',
      ];
      final result = await _httpGetText(
        Uri.parse('https://$_apiProxyHost$basePath?${all.join('&')}'),
        timeout: const Duration(seconds: 20),
      );
      noteStatus(result.status, retryAfter: result.retryAfter);
      return result.text;
    }

    // 先不带 key（反代注入自己的）；反代要求 key（401）再带上重试
    var proxyText = await tryProxy(withKey: false);
    if (proxyText == null && status == 401) {
      proxyText = await tryProxy(withKey: true);
    }
    if (proxyText != null) {
      _markTmdbOnline('自建反代');
      return proxyText;
    }

    // 线路收到过 HTTP 响应（如 404/5xx）：网络是通的，属内容/节点层问题
    // （实测失效的 CloudFront 边缘节点会对有效路径回 404）。此时绝不进入
    // 离线冷却——否则一次瞬时异常会把整批任务连坐成"未匹配"；让调用方
    // 回退到搜索线路自行恢复。
    if (sawHttpStatus) {
      lastSearchError =
          'TMDB 线路可达但返回 HTTP $status'
          '（可能为失效节点或反代异常），本条目未匹配，可重试';
      onLog?.call('  TMDB 请求失败：$lastSearchError');
      return null;
    }

    _tmdbOfflineUntil = DateTime.now().add(const Duration(seconds: 45));
    lastSearchError =
        'TMDB 官方线路与自建反代均不可达：${_networkHint()}'
        '（45 秒后自动重试）';
    onLog?.call('  TMDB 请求失败：$lastSearchError');
    return null;
  }

  static void _markTmdbOnline(String channel) {
    _tmdbOfflineUntil = null;
    _lastChannel = channel;
    lastSearchError = null;
  }

  /// 返回正文与本次状态码（429 时一并带回 Retry-After）。状态码不写
  /// 全局变量：刮削任务并发时，多个请求会互相覆盖。
  static Future<({String? text, int status, Duration? retryAfter})>
  _httpGetText(
    Uri uri, {
    String? proxy,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final client = _httpClient(proxy: proxy);
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      final response = await request.close().timeout(timeout);
      final status = response.statusCode;
      if (status != 200) {
        final retryAfter = _retryAfterOf(response);
        try {
          await response.drain<void>();
        } catch (_) {}
        return (text: null, status: status, retryAfter: retryAfter);
      }
      final bytes = await _readLimited(response, 8 * 1024 * 1024, timeout);
      return (
        text: utf8.decode(bytes, allowMalformed: true),
        status: status,
        retryAfter: null,
      );
    } catch (error) {
      _lastNetworkDetail = error.toString();
      return (text: null, status: 0, retryAfter: null);
    } finally {
      // 共享 HttpClient 自带连接池，不逐请求关闭
    }
  }

  /// 二进制请求（图片/头像等）。返回 bytes 与本次 HTTP 状态码，状态码
  /// 交给调用方判定终态（404 等），不写全局 [_lastHttpStatus]——图片
  /// 下载是并发的，共享状态会互相污染。
  static Future<({List<int>? bytes, int status})> _httpGetBytes(
    Uri uri, {
    String? proxy,
    Duration timeout = const Duration(seconds: 15),
    int retries = 2,
  }) async {
    var status = 0;
    for (var attempt = 0; attempt < retries; attempt++) {
      if (attempt > 0) await _throttleImage();
      final client = _httpClient(proxy: proxy);
      try {
        final request = await client.getUrl(uri).timeout(timeout);
        final response = await request.close().timeout(timeout);
        status = response.statusCode;
        if (status != 200) {
          try {
            await response.drain<void>();
          } catch (_) {}
          if (status == 401 || status == 403 || status == 404) {
            return (bytes: null, status: status);
          }
          continue;
        }
        final bytes = await _readLimited(response, 20 * 1024 * 1024, timeout);
        if (bytes.length >= 1024) return (bytes: bytes, status: status);
      } catch (error) {
        _lastNetworkDetail = error.toString();
      } finally {
        // 共享 HttpClient 自带连接池，不逐请求关闭
      }
    }
    return (bytes: null, status: status);
  }

  static Future<List<int>> _readLimited(
    Stream<List<int>> stream,
    int maxBytes,
    Duration timeout,
  ) async {
    final bytes = <int>[];
    await for (final chunk in stream.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) break;
    }
    return bytes;
  }

  /// 通过「可用 IP + 域名 SNI」直连 CDN 并取回响应体（二进制）。
  /// 同一批候选 IP 并发探测，先返回可用者；失败节点短暂冷却，
  /// 避免每次请求都在死节点上串行等 6 秒。
  ///
  /// 状态码随响应一并带回、不写全局变量：并发取图/刮削时会互相覆盖。
  static Future<({List<int>? bytes, int status})> _sniGetResult(
    String host,
    String pathAndQuery, {
    int maxBytes = 16 * 1024 * 1024,
    bool image = false,
  }) async {
    // 内置 IP 立即可用，IP 列表刷新放后台：镜像（jsDelivr 等）在国内
    // 经常要等满 4 秒超时，不该让首个请求替它买单。
    unawaited(_ensureIpPool());

    // 优先复用长连接：省掉 TCP + TLS 握手（国内直连实测 300~400ms）
    final pooled = _takePooledSni(host);
    if (pooled != null) {
      final attempt = await _attemptSni(
        pooled.ip,
        host,
        pathAndQuery,
        maxBytes: maxBytes,
        image: image,
        pooled: pooled,
        timeout: image
            ? const Duration(seconds: 12)
            : const Duration(seconds: 5),
      );
      if (attempt.bytes != null || attempt.status != null) {
        return _acceptSniResult(host, attempt);
      }
      // 连接被服务端回收等情况：落到下面重新建连
    }

    final candidates = _candidateIps(host);
    final result = candidates.isEmpty
        ? null
        : await _sniTryIps(
            host,
            candidates,
            pathAndQuery,
            maxBytes: maxBytes,
            image: image,
          );
    if (result != null) return _acceptSniResult(host, result);

    // 内置/缓存 IP 全部不可达时，用系统 DNS 解析结果再试一轮。
    // 不同运营商可达的 CDN 节点不同，部分网络对 CDN 域名并无污染，
    // 本机解析出的节点往往比过期的内置 IP 更可靠。
    final dnsIps = (await _resolveDnsIps(host))
        .where((ip) => !candidates.contains(ip))
        .take(8)
        .toList();
    if (dnsIps.isEmpty) return (bytes: null, status: 0);
    final dnsResult = await _sniTryIps(
      host,
      dnsIps,
      pathAndQuery,
      maxBytes: maxBytes,
      image: image,
    );
    return dnsResult == null
        ? (bytes: null, status: 0)
        : _acceptSniResult(host, dnsResult);
  }

  /// 分批竞速尝试一组 IP，命中即返回。
  static Future<_SniAttempt?> _sniTryIps(
    String host,
    List<String> ips,
    String pathAndQuery, {
    required int maxBytes,
    required bool image,
  }) async {
    for (var offset = 0; offset < ips.length; offset += 4) {
      final end = offset + 4 > ips.length ? ips.length : offset + 4;
      final result = await _raceSni(
        host,
        ips.sublist(offset, end),
        pathAndQuery,
        maxBytes: maxBytes,
        image: image,
      );
      if (result == null) continue;
      if (result.bytes != null || result.status != null) return result;
    }
    return null;
  }

  /// 记录命中节点并返回响应；收到任何 HTTP 状态码都说明该节点可用，
  /// 401/403/404 等是内容层问题，换 IP 也不会变，交上层处理。
  ///
  /// 4xx 不冷却该 IP：缺失的图片/无效的 key 会让健康节点回 404，拉黑它
  /// 只会让后续请求重新竞速、逐渐把可用节点全部冷却掉。失效边缘节点
  /// 对有效路径回 404 的情况由 [_raceSni] 的弱结果窗口兜住。
  static ({List<int>? bytes, int status}) _acceptSniResult(
    String host,
    _SniAttempt result,
  ) {
    final status = result.status;
    final contentLevel = status != null && status >= 300 && status < 500;
    if (contentLevel) {
      _preferredIp[host] = result.ip;
      _ipCooldown.remove(result.ip);
    } else if (status != null && status != 200 && status != 206) {
      _preferredIp.remove(host);
      _ipCooldown[result.ip] = DateTime.now().add(const Duration(minutes: 3));
    } else {
      _preferredIp[host] = result.ip;
      _ipCooldown.remove(result.ip);
    }
    final conn = result.conn;
    if (conn != null) _releasePooledSni(conn);
    return (bytes: result.bytes, status: status ?? 200);
  }

  static Future<_SniAttempt?> _raceSni(
    String host,
    List<String> ips,
    String pathAndQuery, {
    required int maxBytes,
    required bool image,
  }) {
    final completer = Completer<_SniAttempt?>();
    var pending = ips.length;
    _SniAttempt? weak;
    Timer? grace;

    void settle() {
      if (completer.isCompleted) return;
      if (pending == 0) {
        grace?.cancel();
        completer.complete(weak);
      }
    }

    void finish(_SniAttempt? attempt) {
      if (completer.isCompleted) {
        // 落败的并发尝试：连接不再需要，立即关掉，避免泄漏
        attempt?.conn?.close();
        return;
      }
      if (attempt != null && attempt.bytes != null) {
        grace?.cancel();
        // 之前暂存的弱结果让位给健康节点
        weak?.conn?.close();
        weak = null;
        completer.complete(attempt);
        return;
      }
      if (attempt != null && attempt.status != null) {
        // 只拿到状态码（4xx/5xx）：先记为弱结果，给并发节点一个很短的
        // 窗口。实测失效的 CloudFront 边缘节点会对有效路径回 404，
        // 直接采信会把健康节点返回的 200 挡在门外，也误伤缺失图片。
        if (weak == null) {
          weak = attempt;
          grace ??= Timer(const Duration(milliseconds: 600), () {
            if (!completer.isCompleted) completer.complete(weak);
          });
        } else {
          attempt.conn?.close();
        }
      }
      pending--;
      settle();
    }

    for (final ip in ips) {
      _attemptSni(
        ip,
        host,
        pathAndQuery,
        maxBytes: maxBytes,
        image: image,
      ).then(finish).catchError((_) {
        finish(null);
      });
    }
    return completer.future;
  }

  static Future<_SniAttempt> _attemptSni(
    String ip,
    String host,
    String pathAndQuery, {
    required int maxBytes,
    required bool image,
    _KeepAliveConn? pooled,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final reuse = pooled != null;
    var conn = pooled;
    try {
      if (conn == null) {
        final raw = await Socket.connect(
          ip,
          443,
        ).timeout(const Duration(seconds: 5));
        final secure = await SecureSocket.secure(
          raw,
          host: host,
        ).timeout(const Duration(seconds: 6));
        conn = _KeepAliveConn(
          host: host,
          ip: ip,
          socket: secure,
          iterator: StreamIterator<List<int>>(secure),
          userAgent: _userAgent,
        );
      }
      conn.send(pathAndQuery, image: image);
      final response = await conn.readResponse(
        maxBytes: maxBytes,
        timeout: timeout,
      );
      if (response == null) {
        await conn.close();
        // 复用连接被服务端回收不算 IP 故障，不冷却
        if (!reuse) {
          _ipCooldown[ip] = DateTime.now().add(const Duration(minutes: 3));
        }
        return _SniAttempt(ip: ip, error: 'empty response');
      }
      return _SniAttempt(
        ip: ip,
        status: response.status,
        bytes: response.status == 200 ? response.body : null,
        conn: conn,
      );
    } catch (error) {
      await conn?.close();
      if (!reuse) {
        _ipCooldown[ip] = DateTime.now().add(const Duration(minutes: 2));
      }
      return _SniAttempt(ip: ip, error: error.toString());
    }
  }

  /// 解析手写的 HTTP 响应：返回状态码与（chunked 解码后的）原始正文。
  static ({int status, List<int> body})? _parseHttpBytes(List<int> bytes) {
    final headerEnd = _findHeaderEnd(bytes);
    if (headerEnd < 0) return null;
    final headerText = latin1.decode(bytes.sublist(0, headerEnd));
    final headers = headerText.toLowerCase();
    final statusLine = headers.split('\r\n').first;
    final match = RegExp(r'http/1\.[01]\s+(\d{3})').firstMatch(statusLine);
    if (match == null) return null;
    final status = int.tryParse(match.group(1)!) ?? 0;
    final bodyBytes = bytes.sublist(headerEnd + 4);
    final body = headers.contains('transfer-encoding: chunked')
        ? _decodeChunkedBytes(bodyBytes)
        : bodyBytes;
    return (status: status, body: body);
  }

  static int _findHeaderEnd(List<int> bytes) {
    for (var i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  /// 严格解析 chunked 正文：数据不完整返回 null（等待更多字节）。
  /// [start] 指向 chunked 正文的第一个字节；consumed 含结尾 0\r\n\r\n。
  static ({List<int> body, int consumed})? _tryDecodeChunked(
    List<int> bytes,
    int start,
  ) {
    final body = <int>[];
    var offset = start;
    while (true) {
      var lineEnd = -1;
      for (var i = offset; i + 1 < bytes.length; i++) {
        if (bytes[i] == 13 && bytes[i + 1] == 10) {
          lineEnd = i;
          break;
        }
      }
      if (lineEnd < 0) return null;
      final sizeText = latin1.decode(bytes.sublist(offset, lineEnd)).trim();
      final size = int.tryParse(sizeText.split(';').first, radix: 16);
      if (size == null) return null;
      final dataStart = lineEnd + 2;
      if (size == 0) {
        // 结尾块：0\r\n\r\n（无 trailer）或 0\r\n<trailer>\r\n\r\n
        if (dataStart + 1 >= bytes.length) return null;
        if (bytes[dataStart] == 13 && bytes[dataStart + 1] == 10) {
          return (body: body, consumed: dataStart + 2);
        }
        final trailerEnd = _findHeaderEnd(bytes.sublist(dataStart));
        if (trailerEnd < 0) return null;
        return (body: body, consumed: dataStart + trailerEnd + 4);
      }
      final end = dataStart + size;
      if (end + 1 >= bytes.length) return null;
      if (bytes[end] != 13 || bytes[end + 1] != 10) return null;
      body.addAll(bytes.sublist(dataStart, end));
      offset = end + 2;
    }
  }

  static List<int> _decodeChunkedBytes(List<int> bytes) {
    final buffer = <int>[];
    var offset = 0;
    while (offset < bytes.length) {
      var lineEnd = -1;
      for (var i = offset; i + 1 < bytes.length; i++) {
        if (bytes[i] == 13 && bytes[i + 1] == 10) {
          lineEnd = i;
          break;
        }
      }
      if (lineEnd < 0) break;
      final sizeText = latin1.decode(bytes.sublist(offset, lineEnd)).trim();
      final size = int.tryParse(sizeText.split(';').first, radix: 16);
      if (size == null || size <= 0) break;
      final start = lineEnd + 2;
      final end = (start + size).clamp(0, bytes.length);
      buffer.addAll(bytes.sublist(start, end));
      offset = end + 2;
    }
    return buffer;
  }

  static String _networkHint() {
    if (_lastHttpStatus >= 500) {
      return 'TMDB 服务暂时异常（HTTP $_lastHttpStatus）';
    }
    if (_lastHttpStatus != 0) return 'HTTP $_lastHttpStatus';
    final detail = _lastNetworkDetail;
    if (detail != null && detail.isNotEmpty) {
      return '无法连接（$detail）';
    }
    return '无法连接 api.themoviedb.org，可在 设置 → 刮削 填写代理';
  }

  static String _pathAndQuery(Uri uri) =>
      '${uri.path}${uri.query.isEmpty ? '' : '?${uri.query}'}';

  /// 海报缓存目录：Windows 为 %APPDATA%/com.framelet/framelet/posters，
  /// macOS/Linux 使用各自的应用数据目录。
  static Directory posterDir() {
    if (Platform.isWindows) {
      final appData =
          Platform.environment['APPDATA'] ??
          '${Platform.environment['USERPROFILE'] ?? '.'}'
              '\\AppData\\Roaming';
      return Directory('$appData\\com.framelet\\framelet\\posters');
    }
    final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
    if (Platform.isMacOS) {
      return Directory(
        '$home/Library/Application Support/com.framelet/framelet/posters',
      );
    }
    if (Platform.isLinux) {
      final data =
          Platform.environment['XDG_DATA_HOME'] ?? '$home/.local/share';
      return Directory('$data/com.framelet/framelet/posters');
    }
    return Directory(
      '${Directory.systemTemp.path}/com.framelet/framelet/posters',
    );
  }

  /// 从文件名/系列名推导查询词与年份。
  ///
  /// 例：`[末日酒店].Apocalypse.Hotel.2025.S01E01.CR.UBWEB`
  /// → 查询候选 ["Apocalypse Hotel", "末日酒店"]，年份 2025。
  static ({List<String> queries, int? year}) parseTitle(String raw) {
    var text = raw;
    final dot = text.lastIndexOf('.');
    if (dot > 0 && dot >= text.length - 5) {
      text = text.substring(0, dot);
    }

    const junkPattern =
        r'^(1080p|720p|2160p|4k|8k|uhd|x264|x265|h264|h265|hevc|avc|aac|ac3|eac3|dts|flac|truehd|bluray|blu-ray|bdrip|webrip|web-dl|webdl|hdtv|remux|hdr10?|hdr|dv|dolby|atmos|ddp?\d{1,2}(\.1)?|dd\+|imax|(re)?upscale(2160|1080|720)?p?|10bits?|8bits?|50fps|60fps|120fps|60帧|120帧|proper|repack|extended|uncut|cr|ubweb|nf|amzn|dsnp|hmax|atvp|max|sdr|hevc10|高码|高bitrate|hq|web|multi|french|german|italian|spanish|russian|korean|japanese|mandarin|cantonese|dualaudio|inter)$';
    final junk = RegExp(junkPattern, caseSensitive: false);
    // 中文网盘目录常见的发布标签。它们不是片名，必须在切词阶段就丢掉，
    // 否则「嫁金钗 杜比视界」「… 全30集」会原样进入 TMDB 查询。
    final chineseJunk = RegExp(
      r'^(全集|完整版|全\d{1,4}集|共\d{1,4}集|完结|已完结|杜比视界|杜比全景声|杜比音效|国粤双语|国粤|国语|粤语|双语|中字|中英字幕|简繁|简体|繁体|内封|内嵌|外挂|无损|原盘|蓝光|高码|高码率)$',
      caseSensitive: false,
    );

    // 目录名开头的粘连年份（「1995-玩具总动员1」）：剥离并记为年份。
    // 仅处理 -/_ 粘连——点分隔的发布名是「片名在前」（2012.2009.1080p
    // 的开头 2012 是片名本身），空格分隔则与「2012」这类年份片名难区分。
    int? leadingYear;
    final leadYear = RegExp(r'^(19|20)\d{2}[-_]').firstMatch(text);
    if (leadYear != null && text.length > leadYear.end) {
      leadingYear = int.tryParse(text.substring(0, leadYear.end - 1));
      text = text.substring(leadYear.end);
    }

    // 字幕/音轨/封装标签（中英字幕、简繁、国粤双语…）不是片名候选，
    // 拿去搜索只会命中噪音；这里的方括号只可能是标签或发布组。
    final bracketLabel = RegExp(
      r'字幕|简体|繁体|中字|英字|双语|国语|国粤|粤语|普通话|内封|内嵌|外挂|杜比|全景声|原盘|无损|高码|DIY|简繁',
      caseSensitive: false,
    );
    // 年份先于括号清理提取：(2026) 是年份，不能被当作标题噪音丢掉。
    final parentheticalYears = RegExp(r'[（(]\s*((?:19|20)\d{2})\s*[）)]')
        .allMatches(text)
        .map((match) => int.tryParse(match.group(1)!))
        .whereType<int>()
        .toList();
    final parentheticalYear = parentheticalYears.isEmpty
        ? null
        : parentheticalYears.last;
    final bracketNames = RegExp(r'[\[【]([^\]】]+)[\]】]')
        .allMatches(text)
        .map((m) => m.group(1)!.trim())
        .where(
          (s) => s.isNotEmpty && !bracketLabel.hasMatch(s) && !junk.hasMatch(s),
        )
        .toList();
    text = text.replaceAll(RegExp(r'[\[【][^\]】]*[\]】]'), ' ');
    // 圆括号内容剥掉（(1994)/(加长版) 等），年份由独立 token 识别
    text = text.replaceAll(RegExp(r'[（(][^）)]*[）)]'), ' ');

    final tokens = text
        .split(RegExp(r'[.\s_]+'))
        .map((token) => token.trim())
        .where((token) => token.isNotEmpty)
        .toList();

    final episode = RegExp(
      r'^(s\d{1,2}(e\d{1,2})?|e\d{1,2}|ep\d{1,3}|\d{1,2}[集期])$',
      caseSensitive: false,
    );

    // 文件名里的独立年份 token 更可信，覆盖目录名剥出的粘连年份
    int? year = leadingYear ?? parentheticalYear;
    final yearTokens = <int>[];
    // (token 原始下标, 清洗后的标题词)——供位置规则变体使用
    final cleaned = <(int, String)>[];
    // 首个「已识别模式」（年份/技术词/集数）的位置：guessit 位置规则认为
    // 标题只出现在它之前（Loki.Glorious.Purpose.DDP5.Atmos → Loki…）
    int? titleEnd;
    final cjk = RegExp(r'[\u4e00-\u9fff]');
    final cjkBoundary = RegExp(
      r'(?<=[\u4e00-\u9fff])(?=[A-Za-z0-9])|(?<=[A-Za-z0-9])(?=[\u4e00-\u9fff])',
    );
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      final isYear = RegExp(r'^(19|20)\d{2}$').hasMatch(token);
      if (isYear) {
        year = int.tryParse(token);
        yearTokens.add(year!);
        titleEnd ??= i;
        continue;
      }
      final mixedCjkLatin =
          cjk.hasMatch(token) && RegExp(r'[A-Za-z0-9]').hasMatch(token);
      if (junk.hasMatch(token) ||
          chineseJunk.hasMatch(token) ||
          episode.hasMatch(token) ||
          (!mixedCjkLatin && bracketLabel.hasMatch(token))) {
        titleEnd ??= i;
        continue;
      }
      // 纯标点/连字符残段（「A - B」剥词后剩下的「-」）
      if (RegExp(r'^[-–—.·]+$').hasMatch(token)) continue;
      // 连字符粘着的技术段（Atmos-CiNEPHiLES、Blu-ray-Remux 之类）：
      // 任一段是技术词就整段丢弃；纯标题连字符（Spider-Man）不含
      // 技术词，原样保留。
      if (token.contains('-') &&
          token
              .toLowerCase()
              .split('-')
              .any((segment) => junk.hasMatch(segment))) {
        titleEnd ??= i;
        continue;
      }
      // 末尾的 1~2 位纯数字视为集数
      if (RegExp(r'^\d{1,2}$').hasMatch(token) && i >= tokens.length - 2) {
        titleEnd ??= i;
        continue;
      }
      // 中英粘连单 token（挽救计划4K英语中字）：按 CJK↔拉丁边界拆子词，
      // 技术/标签子词剔除，其余子词无缝拼回（「哆啦A梦」拆完原样还原）
      if (mixedCjkLatin) {
        final subs = token
            .split(cjkBoundary)
            .where((s) => s.isNotEmpty)
            .toList();
        final kept = <String>[];
        for (var s = 0; s < subs.length; s++) {
          final sub = subs[s];
          final isTrailingDigit =
              RegExp(r'^\d{1,2}$').hasMatch(sub) && s == subs.length - 1;
          if (junk.hasMatch(sub) ||
              chineseJunk.hasMatch(sub) ||
              bracketLabel.hasMatch(sub) ||
              episode.hasMatch(sub) ||
              isTrailingDigit) {
            continue;
          }
          kept.add(sub);
        }
        if (kept.isEmpty) {
          titleEnd ??= i;
          continue;
        }
        cleaned.add((i, kept.join()));
        continue;
      }
      if (bracketLabel.hasMatch(token)) {
        titleEnd ??= i;
        continue;
      }
      cleaned.add((i, token));
    }

    var name = cleaned.map((r) => r.$2).join(' ').trim();
    if (name.isEmpty && yearTokens.isNotEmpty) {
      // 剩余无标题块：被当作年份吃掉的首个四位数字就是片名本身
      // （《2012》《1917》）——首个年份升为片名，其余年份做消歧
      name = '${yearTokens.first}';
      year = yearTokens.length > 1 ? yearTokens.last : null;
    }
    name = name.replaceAll(RegExp(r'\s+'), ' ');
    // 去掉残留的中文集数后缀，如 "三体 01"
    name = name.replaceAll(RegExp(r'\s+\d{1,2}$'), '').trim();
    // 剥离分类前缀（「动漫 启示录酒店…」→「启示录酒店…」）
    name = name.replaceAll(RegExp(r'^(动漫|动画|综艺|电影|电视剧|剧集)[\s：:－-]*'), '');
    // 剥离末尾的季/年份标记：幸福伽菜子的快乐杀手生活S1（2025）→ 幸福伽菜子的快乐杀手生活
    name = name
        .replaceAll(RegExp(r'[（(]\s*(19|20)\d{2}\s*[)）]\s*$'), '')
        .replaceAll(RegExp(r'\s*[sS](?:eason)?\s*\d{1,2}\s*$'), '')
        .replaceAll(RegExp(r'\s*第\s*[0-9一二三四五六七八九十]+\s*季\s*$'), '')
        .trim();

    // 查询词候选管线（guessit 思路：已知模式剥干净后，剩余块按置信度
    // 降序逐个尝试，外层命中即停）。中文媒体库目录名常见
    // 「序号 中文片名 英文名 标签尾」结构（「24 黑寡妇 Black Widow MA」），
    // 逐层生成更干净的变体，全名命中不了时还有后路。
    final variants = <String>[];
    // 「英语中字」「中英字幕」这类整串都是标签的词拿去搜索只会命中噪音
    final pureLabelTail = RegExp(r'(中字|字幕|国粤|国语|粤语|双语|简体|繁体|普通话)$');
    void addVariant(String q) {
      final t = q.trim();
      if (t.length < 2) return; // 单字符查询噪音太大
      if (isSubtitleOrAudioLabel(t)) return;
      if (pureLabelTail.hasMatch(t) && t.length <= 6) return;
      if (!variants.contains(t)) variants.add(t);
    }

    if (name.isNotEmpty) addVariant(name);
    // guessit 位置规则变体：标题只出现在首个已识别模式之前
    // （Loki Glorious Purpose DDP5 Atmos → Loki Glorious Purpose）
    if (titleEnd != null) {
      final prefix = cleaned
          .where((r) => r.$1 < titleEnd!)
          .map((r) => r.$2)
          .join(' ')
          .trim();
      if (prefix.isNotEmpty && prefix != name) addVariant(prefix);
    }
    final expanded = <String>[];
    for (final v in variants) {
      expanded.add(v);
      // 剥开头序号（「24 黑寡妇 …」→「黑寡妇 …」）
      final leadingIndex = RegExp(r'^\d{1,2}\s+(?=\S)');
      if (leadingIndex.hasMatch(v)) {
        final stripped = v.replaceFirst(leadingIndex, '').trim();
        if (stripped.length >= 2) expanded.add(stripped);
      }
    }
    variants
      ..clear()
      ..addAll(expanded);
    // 剥结尾孤立的 1~3 位字母标签（「… Black Widow MA」→「… Black Widow」，
    // MA7/HEVC/HSBS 这类多为发布组或规格残留）。完整片名剥完为空的
    // 不受影响——「Ma」「IT」「Up」本身就是片名。
    final expanded2 = <String>[];
    for (final v in variants) {
      expanded2.add(v);
      final m = RegExp(r'^(.+?)\s+[A-Za-z]{1,3}\d{0,2}$').firstMatch(v);
      if (m != null) {
        final stripped = m.group(1)!.trim();
        if (stripped.length >= 2) expanded2.add(stripped);
      }
    }
    variants
      ..clear()
      ..addAll(expanded2);
    // 中英混排时补单语变体：TMDB 对纯中文/纯英文的检索明显更准
    final expanded3 = <String>[];
    for (final v in variants) {
      expanded3.add(v);
      if (cjk.hasMatch(v) && RegExp(r'[A-Za-z]').hasMatch(v)) {
        final words = v.split(RegExp(r'\s+'));
        final zh = words.where(cjk.hasMatch).join(' ').trim();
        final en = words
            .where((w) => !cjk.hasMatch(w) && RegExp(r'[A-Za-z]').hasMatch(w))
            .join(' ')
            .trim();
        if (zh.length >= 2) expanded3.add(zh);
        if (en.length >= 2) expanded3.add(en);
      }
    }
    variants
      ..clear()
      ..addAll(expanded3);

    final queries = <String>[...variants.take(12)];
    // 通用规则：标题尾部的 1~2 位纯数字多为季号（唐朝诡事录1/魔幻手机2），
    // 生成一个剥掉后的变体用于搜索——命中率高且无需逐部写别名
    for (final v in List<String>.of(queries)) {
      final tail = RegExp(r'^(.*[^0-9])(\d{1,2})$').firstMatch(v);
      if (tail != null) {
        final stripped = tail.group(1)!.trim();
        if (stripped.length >= 2 && !queries.contains(stripped)) {
          queries.add(stripped);
        }
      }
    }
    queries.addAll(bracketNames);
    return (queries: queries, year: year);
  }

  /// TMDB 搜索（需 API Key；网络不通时自动回退 TVmaze）。
  ///
  /// 中文片名、电影、剧集全覆盖，海报质量最好。
  /// 手动匹配：返回多个候选供用户挑选。
  ///
  /// 剧集条目默认优先展示 tv，电影优先 movie，但两类都会返回。
  static Future<List<ScrapeCandidate>> searchCandidates(
    String query, {
    int? year,
    bool preferTv = false,
  }) async {
    final key = tmdbApiKey?.trim();
    if (key == null || key.isEmpty) {
      lastSearchError = '未配置 TMDB API Key';
      return const [];
    }
    if (query.trim().isEmpty) return const [];
    lastSearchError = null;
    final pathAndQuery =
        '/3/search/multi'
        '?api_key=$key&language=zh-CN&include_adult=false'
        '&query=${Uri.encodeQueryComponent(query)}';
    try {
      await _throttle();
      final body = await _tmdbGet(pathAndQuery);
      if (body == null) {
        final fallback = await _searchTvmazeCandidates(query);
        if (fallback.isNotEmpty) {
          lastSearchError = null;
          return fallback;
        }
        lastSearchError ??= 'TMDB 搜索失败，请检查网络或代理';
        return const [];
      }
      final data = jsonDecode(body) as Map<String, Object?>;
      final results = data['results'] as List<Object?>? ?? const [];
      final candidates = <ScrapeCandidate>[];
      for (final item in results) {
        final map = item as Map<String, Object?>;
        final mediaType = map['media_type'] as String? ?? '';
        if (mediaType != 'movie' && mediaType != 'tv') continue;
        final title =
            (map['title'] as String?) ?? (map['name'] as String?) ?? '';
        if (title.isEmpty) continue;
        final date =
            (map['release_date'] as String?) ??
            (map['first_air_date'] as String?) ??
            '';
        final posterPath = map['poster_path'] as String?;
        final vote = (map['vote_average'] as num?)?.toDouble();
        candidates.add(
          ScrapeCandidate(
            name: title,
            mediaType: mediaType,
            tmdbId: (map['id'] as num?)?.toInt(),
            originalName:
                (map['original_title'] as String?) ??
                (map['original_name'] as String?),
            year: int.tryParse(date.split('-').first),
            posterUrl: posterPath == null
                ? null
                : 'https://image.tmdb.org/t/p/w200$posterPath',
            overview: (map['overview'] as String?)?.trim(),
            rating: vote == null || vote <= 0 ? null : vote.toStringAsFixed(1),
          ),
        );
      }
      // 类型优先排序，同年份优先
      candidates.sort((a, b) {
        final aType = preferTv
            ? (a.mediaType == 'tv' ? 0 : 1)
            : (a.mediaType == 'movie' ? 0 : 1);
        final bType = preferTv
            ? (b.mediaType == 'tv' ? 0 : 1)
            : (b.mediaType == 'movie' ? 0 : 1);
        if (aType != bType) return aType - bType;
        if (year != null) {
          final aGap = (a.year ?? 0) == year ? 0 : 1;
          final bGap = (b.year ?? 0) == year ? 0 : 1;
          if (aGap != bGap) return aGap - bGap;
        }
        return 0;
      });
      if (candidates.isEmpty) {
        final fallback = await _searchTvmazeCandidates(query);
        if (fallback.isNotEmpty) {
          lastSearchError = null;
          return fallback;
        }
      }
      return candidates.take(18).toList();
    } catch (error) {
      lastSearchError = 'TMDB 返回数据异常：$error';
      return const [];
    }
  }

  /// TMDB 完全不可达时，用 TVmaze 提供手动匹配候选。
  /// TVmaze 的 API 与图片 CDN 通常不依赖 TMDB 域名，可继续出图。
  static Future<List<ScrapeCandidate>> _searchTvmazeCandidates(
    String query,
  ) async {
    if (_tvmazeOfflineUntil != null &&
        _tvmazeOfflineUntil!.isAfter(DateTime.now())) {
      return const [];
    }
    final url = Uri.parse(
      'https://api.tvmaze.com/search/shows?q=${Uri.encodeQueryComponent(query)}',
    );
    final client = _httpClient();
    try {
      await _throttleTvmaze();
      final request = await client.getUrl(url);
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      if (response.statusCode != 200) {
        if (response.statusCode >= 500) {
          _tvmazeOfflineUntil = DateTime.now().add(const Duration(seconds: 45));
        }
        return const [];
      }
      final body = await response.transform(utf8.decoder).join();
      final list = jsonDecode(body) as List<Object?>;
      final candidates = <ScrapeCandidate>[];
      for (final item in list) {
        final show =
            (item as Map<String, Object?>)['show'] as Map<String, Object?>?;
        if (show == null) continue;
        final id = (show['id'] as num?)?.toInt();
        final name = show['name'] as String? ?? '';
        if (id == null || name.isEmpty) continue;
        final premiered = show['premiered'] as String? ?? '';
        final image = show['image'] as Map<String, Object?>?;
        final poster =
            image?['medium'] as String? ?? image?['original'] as String?;
        final ratingValue =
            (show['rating'] as Map<String, Object?>?)?['average'];
        final summary = stripHtml(show['summary'] as String? ?? '');
        candidates.add(
          ScrapeCandidate(
            name: name,
            mediaType: 'tv',
            originalName: name,
            year: int.tryParse(premiered.split('-').first),
            posterUrl: poster,
            overview: summary.isEmpty ? null : summary,
            rating: ratingValue is num && ratingValue > 0
                ? ratingValue.toStringAsFixed(1)
                : null,
            tvmazeId: id,
            source: 'tvmaze',
          ),
        );
        if (candidates.length >= 18) break;
      }
      return candidates;
    } catch (error) {
      _tvmazeOfflineUntil = DateTime.now().add(const Duration(seconds: 45));
      _lastNetworkDetail = error.toString();
      return const [];
    } finally {
      // 共享 HttpClient 自带连接池，不逐请求关闭
    }
  }

  static Future<ScrapeResult?> searchTmdb(
    String query, {
    int? year,
    bool preferTv = false,
  }) async {
    final key = tmdbApiKey?.trim();
    if (key == null || key.isEmpty || query.trim().isEmpty) return null;
    final pathAndQuery =
        '/3/search/multi'
        '?api_key=$key&language=zh-CN&include_adult=false'
        '&query=${Uri.encodeQueryComponent(query)}';
    try {
      await _throttle();
      final body = await _tmdbGet(pathAndQuery);
      if (body == null) return null;
      final data = jsonDecode(body) as Map<String, Object?>;
      final results = data['results'] as List<Object?>?;
      if (results == null || results.isEmpty) return null;

      Map<String, Object?>? best;
      var bestScore = 0.0;
      var bestOriginalName = '';
      for (final item in results) {
        final map = item as Map<String, Object?>;
        final mediaType = map['media_type'] as String? ?? '';
        if (mediaType != 'movie' && mediaType != 'tv') continue;
        final name =
            (map['title'] as String?) ?? (map['name'] as String?) ?? '';
        // 原名（英文/日文）也参与比较，避免中文译名差异导致漏配
        final originalName =
            (map['original_title'] as String?) ??
            (map['original_name'] as String?) ??
            '';
        final date =
            (map['release_date'] as String?) ??
            (map['first_air_date'] as String?) ??
            '';
        final itemYear = int.tryParse(date.split('-').first);
        var score = _similarity(query, name);
        final originalScore = _similarity(query, originalName);
        if (originalScore > score) score = originalScore;
        // 类型匹配加权：剧集优先匹配 tv，电影优先匹配 movie，
        // 避免《想见你》《信号》这类同名电影/剧集张冠李戴。
        if (preferTv && mediaType == 'tv') score += 0.35;
        if (!preferTv && mediaType == 'movie') score += 0.3;
        if (itemYear != null && year != null) {
          final gap = (year - itemYear).abs();
          if (gap == 0) score += 0.3;
          if (gap > 2) score -= 0.35;
        }
        if (map['poster_path'] == null) score -= 0.1;
        if (score > bestScore) {
          bestScore = score;
          best = map;
          bestOriginalName = originalName;
        }
      }
      if (best == null || bestScore < 0.35) return null;

      final posterPath = best['poster_path'] as String?;
      final overview = (best['overview'] as String? ?? '').trim();
      final vote = (best['vote_average'] as num?)?.toDouble();
      final title =
          (best['title'] as String?) ?? (best['name'] as String?) ?? query;
      final date =
          (best['release_date'] as String?) ??
          (best['first_air_date'] as String?) ??
          '';
      return ScrapeResult(
        name: title,
        originalName: bestOriginalName.isEmpty ? null : bestOriginalName,
        posterUrl: posterPath == null
            ? null
            : 'https://image.tmdb.org/t/p/w500$posterPath',
        summary: overview.isEmpty ? null : overview,
        rating: vote == null || vote <= 0 ? null : vote.toStringAsFixed(1),
        year: int.tryParse(date.split('-').first),
        mediaType: (best['media_type'] as String?) ?? 'movie',
        tmdbId: (best['id'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  /// 读取 TMDB 详情：背景图、类型、演员、时长与日期。
  /// credits 一次请求带回，避免为每个条目发两次。
  static Future<ScrapeResult?> fetchTmdbDetails({
    required String mediaType,
    required int id,
  }) async {
    final key = tmdbApiKey?.trim();
    if (key == null || key.isEmpty) return null;
    final type = mediaType == 'tv' ? 'tv' : 'movie';
    final pathAndQuery =
        '/3/$type/$id'
        '?api_key=$key&language=zh-CN&append_to_response=credits';
    try {
      await _throttle();
      final body = await _tmdbGet(pathAndQuery);
      if (body == null) return null;
      final map = jsonDecode(body) as Map<String, Object?>;
      final genres = (map['genres'] as List<Object?>? ?? const [])
          .map((item) {
            if (item is! Map<String, Object?>) return '';
            return item['name'] as String? ?? '';
          })
          .where((name) => name.isNotEmpty)
          .take(4)
          .toList();
      final runtimeMinutes =
          (map['runtime'] as num?)?.toDouble() ??
          ((map['episode_run_time'] as List<Object?>?)?.firstOrNull as num?)
              ?.toDouble();
      final crew =
          (map['credits'] as Map<String, Object?>?)?['crew']
              as List<Object?>? ??
          const [];
      final cast =
          (map['credits'] as Map<String, Object?>?)?['cast']
              as List<Object?>? ??
          const [];
      final members = <CastMember>[];
      for (final item in crew.take(3)) {
        final map = item as Map<String, Object?>;
        if (map['job'] != 'Director') continue;
        final name = map['name'] as String? ?? '';
        if (name.isEmpty) continue;
        members.add(CastMember(name: name, role: '导演'));
      }
      for (final item in cast) {
        final map = item as Map<String, Object?>;
        final name = map['name'] as String? ?? '';
        if (name.isEmpty) continue;
        final profilePath = map['profile_path'] as String?;
        members.add(
          CastMember(
            name: name,
            role: map['character'] as String? ?? '',
            photoUrl: profilePath == null
                ? null
                : 'https://image.tmdb.org/t/p/w185$profilePath',
          ),
        );
        if (members.length >= 12) break;
      }
      final posterPath = map['poster_path'] as String?;
      final backdropPath = map['backdrop_path'] as String?;
      final vote = (map['vote_average'] as num?)?.toDouble();
      return ScrapeResult(
        name: (map['title'] as String?) ?? (map['name'] as String?) ?? '',
        originalName:
            (map['original_title'] as String?) ??
            (map['original_name'] as String?),
        posterUrl: posterPath == null
            ? null
            : 'https://image.tmdb.org/t/p/w500$posterPath',
        summary: (map['overview'] as String? ?? '').trim(),
        rating: vote == null || vote <= 0 ? null : vote.toStringAsFixed(1),
        backdropUrl: backdropPath == null
            ? null
            : 'https://image.tmdb.org/t/p/w1280$backdropPath',
        genres: genres,
        cast: members,
        releaseDate:
            (map['release_date'] as String?) ??
            (map['first_air_date'] as String?),
        runtimeSec: runtimeMinutes == null ? null : runtimeMinutes * 60,
        mediaType: type,
        tmdbId: id,
      );
    } catch (_) {
      return null;
    }
  }

  /// TVmaze 详情：简介、类型、演员、首播日期与单集时长。
  static Future<ScrapeResult?> fetchTvmazeDetails(int id) async {
    if (_tvmazeOfflineUntil != null &&
        _tvmazeOfflineUntil!.isAfter(DateTime.now())) {
      return null;
    }
    final url = Uri.parse('https://api.tvmaze.com/shows/$id?embed=cast');
    final client = _httpClient();
    try {
      await _throttleTvmaze();
      final request = await client.getUrl(url);
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      if (response.statusCode != 200) {
        if (response.statusCode >= 500) {
          _tvmazeOfflineUntil = DateTime.now().add(const Duration(seconds: 45));
        }
        return null;
      }
      final map = jsonDecode(
        await response.transform(utf8.decoder).join(),
      ) as Map<String, Object?>;
      final image = map['image'] as Map<String, Object?>?;
      final poster =
          image?['medium'] as String? ?? image?['original'] as String?;
      final ratingValue = (map['rating'] as Map<String, Object?>?)?['average'];
      final genres = (map['genres'] as List<Object?>? ?? const [])
          .whereType<String>()
          .where((genre) => genre.isNotEmpty)
          .take(4)
          .toList();
      final cast = <CastMember>[];
      final embedded = map['_embedded'] as Map<String, Object?>?;
      final castList = embedded?['cast'] as List<Object?>? ?? const [];
      for (final item in castList) {
        if (item is! Map<String, Object?>) continue;
        final person = item['person'] as Map<String, Object?>?;
        final name = person?['name'] as String? ?? '';
        if (name.isEmpty) continue;
        final personImage = person?['image'] as Map<String, Object?>?;
        final photo =
            personImage?['medium'] as String? ??
            personImage?['original'] as String?;
        final character = item['character'] as Map<String, Object?>?;
        cast.add(
          CastMember(
            name: name,
            role: character?['name'] as String? ?? '',
            photoUrl: photo,
          ),
        );
        if (cast.length >= 12) break;
      }
      final runtime =
          (map['averageRuntime'] as num?)?.toDouble() ??
          (map['runtime'] as num?)?.toDouble();
      final summary = stripHtml(map['summary'] as String? ?? '');
      return ScrapeResult(
        name: map['name'] as String? ?? '',
        posterUrl: poster,
        summary: summary.isEmpty ? null : summary,
        rating: ratingValue is num && ratingValue > 0
            ? ratingValue.toStringAsFixed(1)
            : null,
        genres: genres,
        cast: cast,
        releaseDate: map['premiered'] as String?,
        runtimeSec: runtime == null ? null : runtime * 60,
        mediaType: 'tv',
        tmdbId: null,
      );
    } catch (error) {
      _tvmazeOfflineUntil = DateTime.now().add(const Duration(seconds: 45));
      _lastNetworkDetail = error.toString();
      return null;
    } finally {
      // 共享 HttpClient 自带连接池，不逐请求关闭
    }
  }

  /// 读取一季的单集信息：缩略图 URL 与标题。
  static Future<Map<int, ({String? title, String? stillUrl})>>
  fetchEpisodeStills({required int tvId, required int seasonNumber}) async {
    final key = tmdbApiKey?.trim();
    if (key == null || key.isEmpty) return const {};
    final pathAndQuery =
        '/3/tv/$tvId/season/$seasonNumber'
        '?api_key=$key&language=zh-CN';
    try {
      await _throttle();
      final body = await _tmdbGet(pathAndQuery);
      if (body == null) return const {};
      final data = jsonDecode(body) as Map<String, Object?>;
      final episodes = data['episodes'] as List<Object?>? ?? const [];
      final result = <int, ({String? title, String? stillUrl})>{};
      for (final item in episodes) {
        if (item is! Map<String, Object?>) continue;
        final episodeNumber = (item['episode_number'] as num?)?.toInt();
        if (episodeNumber == null) continue;
        final stillPath = item['still_path'] as String?;
        result[episodeNumber] = (
          title: (item['name'] as String?)?.trim(),
          stillUrl: stillPath == null
              ? null
              : 'https://image.tmdb.org/t/p/w500$stillPath',
        );
      }
      return result;
    } catch (_) {
      return const {};
    }
  }

  /// 拉取某一季的详情：季海报、季简介、首播日期与单集平均时长。
  static Future<
    ({
      String? posterUrl,
      String? overview,
      String? airDate,
      double? runtimeSec,
    })?
  >
  fetchSeasonDetails({required int tvId, required int seasonNumber}) async {
    final key = tmdbApiKey?.trim();
    if (key == null || key.isEmpty) return null;
    final pathAndQuery =
        '/3/tv/$tvId/season/$seasonNumber'
        '?api_key=$key&language=zh-CN';
    try {
      await _throttle();
      final body = await _tmdbGet(pathAndQuery);
      if (body == null) return null;
      final data = jsonDecode(body) as Map<String, Object?>;
      final posterPath = data['poster_path'] as String?;
      final overview = (data['overview'] as String?)?.trim();
      final airDate = (data['air_date'] as String?)?.trim();
      final episodes = (data['episodes'] as List<Object?>? ?? const [])
          .whereType<Map<String, Object?>>()
          .toList();
      final runtimes = episodes
          .map((episode) => (episode['runtime'] as num?)?.toDouble() ?? 0)
          .where((runtime) => runtime > 0)
          .toList();
      final averageRuntime = runtimes.isEmpty
          ? null
          : runtimes.reduce((a, b) => a + b) / runtimes.length;
      return (
        posterUrl: posterPath == null
            ? null
            : 'https://image.tmdb.org/t/p/w500$posterPath',
        overview: (overview == null || overview.isEmpty) ? null : overview,
        airDate: (airDate == null || airDate.isEmpty) ? null : airDate,
        runtimeSec: averageRuntime == null ? null : averageRuntime * 60,
      );
    } catch (_) {
      return null;
    }
  }

  /// 在 TVmaze 搜索并挑选最匹配的剧集/影片。
  static Future<ScrapeResult?> search(String query, {int? year}) async {
    if (query.trim().isEmpty) return null;
    if (_tvmazeOfflineUntil != null &&
        _tvmazeOfflineUntil!.isAfter(DateTime.now())) {
      return null;
    }
    final url = Uri.parse(
      'https://api.tvmaze.com/search/shows?q=${Uri.encodeQueryComponent(query)}',
    );
    final client = _httpClient();
    try {
      await _throttleTvmaze();
      final request = await client.getUrl(url);
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      if (response.statusCode != 200) {
        if (response.statusCode >= 500) {
          _tvmazeOfflineUntil = DateTime.now().add(const Duration(seconds: 45));
        }
        return null;
      }
      final body = await response.transform(utf8.decoder).join();
      final list = jsonDecode(body) as List<Object?>;
      ScrapeResult? best;
      var bestScore = 0.0;
      for (final item in list) {
        final show =
            (item as Map<String, Object?>)['show'] as Map<String, Object?>;
        final name = show['name'] as String? ?? '';
        final premiered = show['premiered'] as String? ?? '';
        final showYear = int.tryParse(premiered.split('-').first);
        final image = show['image'] as Map<String, Object?>?;
        final poster =
            image?['medium'] as String? ?? image?['original'] as String?;
        final ratingValue =
            (show['rating'] as Map<String, Object?>?)?['average'];
        final summaryRaw = show['summary'] as String?;

        var score = _similarity(query, name);
        if (year != null && showYear != null) {
          final gap = (year - showYear).abs();
          if (gap == 0) score += 0.25;
          if (gap > 2) score -= 0.3;
        }
        if (poster == null) score -= 0.1;
        if (score > bestScore) {
          bestScore = score;
          best = ScrapeResult(
            name: name,
            posterUrl: poster,
            summary: summaryRaw == null ? null : stripHtml(summaryRaw),
            rating: ratingValue is num ? ratingValue.toStringAsFixed(1) : null,
            year: showYear,
          );
        }
      }
      return bestScore >= 0.35 ? best : null;
    } catch (error) {
      _tvmazeOfflineUntil = DateTime.now().add(const Duration(seconds: 45));
      _lastNetworkDetail = error.toString();
      return null;
    } finally {
      // 共享 HttpClient 自带连接池，不逐请求关闭
    }
  }

  static bool _looksLikeImage(List<int> bytes) {
    if (bytes.length < 12) return false;
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) return true; // JPEG
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true; // PNG
    }
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
      return true; // GIF
    }
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46) {
      return true; // WebP / RIFF
    }
    // AVIF / HEIC: ....ftyp
    if (bytes[4] == 0x66 &&
        bytes[5] == 0x74 &&
        bytes[6] == 0x79 &&
        bytes[7] == 0x70) {
      return true;
    }
    return false;
  }

  static String _lastImageChannel = '';

  /// 404/410 是内容层结论（这张图本来就不存在），换线路也没用。
  static bool _isMissingImageStatus(int status) =>
      status == 404 || status == 410;

  static void _rememberMissingImage(String url) {
    if (_missingImages.length >= _missingImagesMax) _missingImages.clear();
    _missingImages.add(url);
  }

  static String _imageProxyUrl(Uri uri, {String host = 'images.weserv.nl'}) {
    final width = RegExp(r'/t/p/(w\d+)/').firstMatch(uri.path)?.group(1);
    final query = <String>[
      'url=${Uri.encodeQueryComponent(uri.toString())}',
      'output=jpg',
      'q=88',
      if (width != null) 'w=${width.substring(1)}',
    ];
    return 'https://$host/?${query.join('&')}';
  }

  /// 用内置 IP + Host 头发起纯 HTTP 请求。部分运营商只阻断
  /// TMDB 域名的 TLS SNI，但 HTTP 仍可到达 CDN；同时绕过污染
  /// DNS，作为完全无代理的兜底。
  static Future<_SniAttempt?> _plainHttpGetViaIp(
    String host,
    String pathAndQuery, {
    int maxBytes = 8 * 1024 * 1024,
    bool image = false,
    bool acceptAnyStatus = false,
  }) async {
    unawaited(_ensureIpPool());
    var candidates = _candidateIps(host).take(8).toList();
    if (candidates.isEmpty) {
      candidates = (await _resolveDnsIps(host)).take(8).toList();
    }
    if (candidates.isEmpty) return null;

    for (var offset = 0; offset < candidates.length; offset += 4) {
      final end = offset + 4 > candidates.length
          ? candidates.length
          : offset + 4;
      final attempt = await _racePlainHttp(
        host,
        candidates.sublist(offset, end),
        pathAndQuery,
        maxBytes: maxBytes,
        image: image,
        acceptAnyStatus: acceptAnyStatus,
      );
      if (attempt?.bytes != null) {
        _preferredIp[host] = attempt!.ip;
        return attempt;
      }
      if (acceptAnyStatus && attempt?.status != null) {
        _preferredIp[host] = attempt!.ip;
        return attempt;
      }
    }
    return null;
  }

  /// 未知图片域名回退到系统 DNS 解析出的 IPv4，仍由 Host 头指定域名。
  static Future<List<String>> _resolveDnsIps(String host) async {
    final cached = _dnsCache[host];
    if (cached != null &&
        DateTime.now().difference(cached.at) < const Duration(minutes: 10)) {
      return cached.ips;
    }
    try {
      final addresses = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 5));
      final ips = addresses
          .where((address) => address.type == InternetAddressType.IPv4)
          .map((address) => address.address)
          .toSet()
          .toList();
      _dnsCache[host] = (ips: ips, at: DateTime.now());
      return ips;
    } catch (_) {
      return const [];
    }
  }

  static Future<_SniAttempt?> _racePlainHttp(
    String host,
    List<String> ips,
    String pathAndQuery, {
    required int maxBytes,
    required bool image,
    required bool acceptAnyStatus,
  }) {
    final completer = Completer<_SniAttempt?>();
    var pending = ips.length;
    _SniAttempt? weak;
    Timer? grace;

    void settle() {
      if (completer.isCompleted) return;
      if (pending == 0) {
        grace?.cancel();
        completer.complete(acceptAnyStatus ? weak : null);
      }
    }

    void finish(_SniAttempt? attempt) {
      if (completer.isCompleted) return;
      if (attempt?.bytes != null) {
        grace?.cancel();
        completer.complete(attempt);
        return;
      }
      if (acceptAnyStatus && attempt?.status != null) {
        // 与 SNI 竞速同规则：状态码先记为弱结果，给并发 IP 一个短窗口，
        // 让能返回 200 的节点优先（缺失图片 404 也能尽快定论）。
        weak ??= attempt;
        grace ??= Timer(const Duration(milliseconds: 600), () {
          if (!completer.isCompleted) completer.complete(weak);
        });
      }
      pending--;
      settle();
    }

    for (final ip in ips) {
      _attemptPlainHttp(
        ip,
        host,
        pathAndQuery,
        maxBytes: maxBytes,
        image: image,
      ).then(finish).catchError((_) {
        finish(null);
      });
    }
    return completer.future;
  }

  static Future<_SniAttempt> _attemptPlainHttp(
    String ip,
    String host,
    String pathAndQuery, {
    required int maxBytes,
    required bool image,
  }) async {
    Socket? socket;
    try {
      socket = await Socket.connect(ip, 80).timeout(const Duration(seconds: 4));
      socket.write(
        'GET $pathAndQuery HTTP/1.1\r\n'
        'Host: $host\r\n'
        'User-Agent: $_userAgent\r\n'
        'Accept: ${image ? 'image/avif,image/webp,image/*,*/*;q=0.8' : 'application/json,*/*'}\r\n'
        'Accept-Encoding: identity\r\n'
        'Connection: close\r\n\r\n',
      );
      final bytes = <int>[];
      await for (final chunk in socket.timeout(const Duration(seconds: 15))) {
        bytes.addAll(chunk);
        if (bytes.length > maxBytes) break;
      }
      final response = _parseHttpBytes(bytes);
      if (response == null) {
        return _SniAttempt(ip: ip, error: 'empty response');
      }
      if (response.status == 200 &&
          (!image || _looksLikeImage(response.body))) {
        return _SniAttempt(ip: ip, status: 200, bytes: response.body);
      }
      return _SniAttempt(ip: ip, status: response.status);
    } catch (error) {
      return _SniAttempt(ip: ip, error: error.toString());
    } finally {
      try {
        await socket?.close();
      } catch (_) {}
    }
  }

  static Future<({List<int>? bytes, int status})> _plainHttpImageViaIp(
    Uri uri,
  ) async {
    final attempt = await _plainHttpGetViaIp(
      uri.host,
      _pathAndQuery(uri),
      maxBytes: 20 * 1024 * 1024,
      image: true,
      // 把 404 也带出来：缺失的图片可以立刻定论，不必再逐条试线路
      acceptAnyStatus: true,
    );
    return (bytes: attempt?.bytes, status: attempt?.status ?? 0);
  }

  /// 免代理直连线路名（与探测排序、诊断展示共用）。
  static const _chBunnyHttps = 'Bunny CDN 直连';
  static const _chBunnySni = 'Bunny CDN 节点直连';
  static const _chPlainHttp = 'HTTP 直连（免 DNS/SNI）';
  static const _chSni = 'SNI 直连';
  static const _chHttps = 'HTTPS 直连';
  static const _chHttp = 'HTTP 直连';
  static const _chWsrv = '图片加速节点';
  static const _chAmodb = '社区图片反代';

  /// 默认线路顺序（测速前的兜底顺序）。
  static const _defaultImageChannels = [
    _chBunnyHttps,
    _chBunnySni,
    _chPlainHttp,
    _chSni,
    _chHttps,
    _chHttp,
    _chWsrv,
    _chAmodb,
  ];

  /// 本次运行实测的线路顺序（快→慢），会话内缓存；null 表示尚未测速。
  static List<String>? _imageChannelOrder;
  static bool _imageChannelProbeDone = false;

  /// 线路连续失败计数：某条线路连续 3 次失败后调到队尾，
  /// 避免一条中途失效的线路让后续每张图都先等一次超时。
  static final Map<String, int> _imageChannelFailStreak = {};
  static const _imageFailDemoteAt = 3;

  static void _noteImageChannelResult(String channel, {required bool ok}) {
    if (ok) {
      _imageChannelFailStreak[channel] = 0;
      return;
    }
    final streak = (_imageChannelFailStreak[channel] ?? 0) + 1;
    _imageChannelFailStreak[channel] = streak;
    final order = _imageChannelOrder;
    if (streak >= _imageFailDemoteAt && order != null) {
      _imageChannelOrder = List<String>.of(order)
        ..remove(channel)
        ..add(channel);
      _imageChannelFailStreak[channel] = 0;
    }
  }

  /// 执行指定取图线路（不校验内容，校验由调用方 accept 负责）。
  /// 返回响应体与状态码，状态码用于判定 404 等终态。
  static Future<({List<int>? bytes, int status})> _runImageChannel(
    String channel, {
    required Uri uri,
    required String path,
    required int maxBytes,
  }) async {
    switch (channel) {
      case _chBunnyHttps:
        // Bunny 域名的 DNS 解析在国内基本不被污染，普通 HTTPS 直连优先。
        return _httpGetBytes(
          Uri.parse('https://$_imageCdnHost$path'),
          timeout: const Duration(seconds: 10),
          retries: 1,
        );
      case _chBunnySni:
        return _sniGetResult(
          _imageCdnHost,
          path,
          maxBytes: maxBytes,
          image: true,
        );
      case _chPlainHttp:
        return _plainHttpImageViaIp(uri);
      case _chSni:
        return _sniGetResult(_imageHost, path, maxBytes: maxBytes, image: true);
      case _chHttps:
        return _httpGetBytes(
          uri,
          timeout: const Duration(seconds: 10),
          retries: 1,
        );
      case _chHttp:
        return _httpGetBytes(
          uri.replace(scheme: 'http'),
          timeout: const Duration(seconds: 10),
          retries: 1,
        );
      case _chWsrv:
        // 兜底图片代理：正式域名 images.weserv.nl 实测可达，
        // 短域名 wsrv.nl 部分网络连不上，作为第二入口。
        final first = await _httpGetBytes(
          Uri.parse(_imageProxyUrl(uri)),
          timeout: const Duration(seconds: 15),
          retries: 1,
        );
        if (first.bytes != null || _isMissingImageStatus(first.status)) {
          return first;
        }
        return _httpGetBytes(
          Uri.parse(_imageProxyUrl(uri, host: 'wsrv.nl')),
          timeout: const Duration(seconds: 15),
          retries: 1,
        );
      case _chAmodb:
        // 社区部署的 TMDB 图片反代（img.amodb.dev，Cloudflare），
        // 实测时通时不通，只做最后的兜底线路之一。
        return _httpGetBytes(
          Uri.parse('https://img.amodb.dev$path'),
          timeout: const Duration(seconds: 12),
          retries: 1,
        );
    }
    return (bytes: null, status: 0);
  }

  /// 首次取图前并行探测各线路（同一张 w92 小图，~3KB），按实测耗时
  /// 排序缓存；失败的线路排到最后。并行跑总耗时≈最慢线路，
  /// 每次运行只测一次。全部失败时保持默认顺序。
  static Future<void>? _imageProbeTask;

  static Future<void> _probeImageChannels() {
    if (_imageChannelProbeDone) return Future<void>.value();
    // 预热与首张图共用同一次测速，避免重复探测或各测各的
    return _imageProbeTask ??= _runImageChannelProbe();
  }

  static Future<void> _runImageChannelProbe() async {
    _imageChannelProbeDone = true;
    const sample = '/t/p/w92/zxfBtHz5UmSTfIEC4O4GngyjHwa.jpg';
    final sampleUri = Uri.parse('https://$_imageHost$sample');
    final timings = <String, int>{};
    await Future.wait(
      _defaultImageChannels.map((channel) async {
        final watch = Stopwatch()..start();
        try {
          final result = await _runImageChannel(
            channel,
            uri: sampleUri,
            path: sample,
            maxBytes: 1 << 20,
          ).timeout(const Duration(seconds: 6));
          final bytes = result.bytes;
          if (bytes != null && bytes.length >= 1024) {
            timings[channel] = watch.elapsedMilliseconds;
          }
        } catch (_) {
          // 探测失败：该线路排到最后
        }
      }),
    );
    if (timings.isEmpty) return;
    final failed = _defaultImageChannels
        .where((channel) => !timings.containsKey(channel))
        .toList();
    final sorted = timings.keys.toList()
      ..sort((a, b) => timings[a]!.compareTo(timings[b]!));
    _imageChannelOrder = [...sorted, ...failed];
  }

  /// 预热：后台刷新直连 IP 池与取图线路测速。刮削开始时调用，
  /// 让第一批图片命中已经测好的线路，而不是在第一张图上现测。
  static Future<void> warmUp() async {
    unawaited(_ensureIpPool());
    try {
      await _probeImageChannels();
    } catch (_) {
      // 预热失败不影响正常流程，取图时会重新测速
    }
  }

  /// 免代理取图：首次先并行测速各线路选最快的，随后按实测顺序
  /// 逐条尝试；代理可用时先走代理，但代理不通也不会挡住直连线路。
  /// 返回响应体与最后一条线路的状态码（供失败日志说明原因）。
  static Future<({List<int>? bytes, int status})> _fetchTmdbImage(
    Uri uri, {
    String? proxy,
    int maxBytes = 20 * 1024 * 1024,
  }) async {
    _lastImageChannel = '';
    final path = _pathAndQuery(uri);
    final usingSystemProxy =
        (proxyAddress ?? '').trim().isEmpty && proxy != null;

    List<int>? accept(List<int>? bytes, String channel) {
      if (bytes == null || bytes.length < 1024 || !_looksLikeImage(bytes)) {
        return null;
      }
      _lastImageChannel = channel;
      return bytes;
    }

    if (proxy != null) {
      await _throttleImage();
      final result = await _httpGetBytes(
        uri,
        proxy: proxy,
        timeout: const Duration(seconds: 12),
        retries: 1,
      );
      final proxied = result.bytes;
      if (proxied != null && _looksLikeImage(proxied)) {
        _lastImageChannel = '代理';
        return (bytes: proxied, status: result.status);
      }
      // 代理明确回了 404：图不存在，不要再逐条试直连线路。
      if (_isMissingImageStatus(result.status)) {
        _rememberMissingImage(uri.toString());
        return result;
      }
      if (usingSystemProxy && result.status == 0) {
        ProxyResolver.disableSystemProxy();
      }
    }

    // 代理没走通才需要直连线路：先测速选最快的（仅首次，~6 秒内）。
    await _probeImageChannels();
    final order = _imageChannelOrder ?? _defaultImageChannels;

    // 单张图的整体预算：卡死的线路（端口被吞、DNS 污染超时）不该让
    // 一张图等十几秒。真实图片通常在前两条线路就拿到，超时即放弃，
    // 下次重刮会重新尝试。
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    var lastStatus = 0;
    for (final channel in order) {
      if (DateTime.now().isAfter(deadline)) {
        onLog?.call('  取图超时，跳过本张：${uri.path.split('/').last}');
        return (bytes: null, status: lastStatus);
      }
      await _throttleImage();
      final result = await _runImageChannel(
        channel,
        uri: uri,
        path: path,
        maxBytes: maxBytes,
      );
      if (result.status != 0) lastStatus = result.status;
      final bytes = accept(result.bytes, channel);
      if (bytes != null) {
        _noteImageChannelResult(channel, ok: true);
        return result;
      }
      // 任一条线路拿到 404/410 即可下结论：图片在 CDN 上不存在。
      // 继续换线路只是把同一个「没有」重复等十几秒（实测 17~23 秒/张）。
      if (_isMissingImageStatus(result.status)) {
        _rememberMissingImage(uri.toString());
        return result;
      }
      _noteImageChannelResult(channel, ok: false);
    }
    return (bytes: null, status: lastStatus);
  }

  /// 非 TMDB 图片（如 TVmaze）的免代理通道：HTTP/IP 直连、
  /// 普通 HTTPS、HTTP 以及图片加速节点逐级兜底。
  static Future<({List<int>? bytes, int status})> _fetchOtherImage(
    Uri uri, {
    String? proxy,
  }) async {
    await _throttleImage();
    List<int>? accept(List<int>? bytes) {
      if (bytes == null || bytes.length < 1024 || !_looksLikeImage(bytes)) {
        return null;
      }
      return bytes;
    }

    bool missing(({List<int>? bytes, int status}) result) {
      if (!_isMissingImageStatus(result.status)) return false;
      _rememberMissingImage(uri.toString());
      return true;
    }

    ({List<int>? bytes, int status}) result = (bytes: null, status: 0);
    if (uri.host.endsWith('tvmaze.com')) {
      result = await _plainHttpImageViaIp(uri);
      final bytes = accept(result.bytes);
      if (bytes != null) return result;
      if (missing(result)) return result;
    }
    result = await _httpGetBytes(
      uri,
      proxy: proxy,
      timeout: const Duration(seconds: 10),
      retries: 1,
    );
    final direct = accept(result.bytes);
    if (direct != null) return result;
    if (missing(result)) return result;
    result = await _plainHttpImageViaIp(uri);
    final viaIp = accept(result.bytes);
    if (viaIp != null) return result;
    if (missing(result)) return result;
    result = await _httpGetBytes(
      uri.replace(scheme: 'http'),
      timeout: const Duration(seconds: 12),
      retries: 1,
    );
    final plain = accept(result.bytes);
    if (plain != null) return result;
    if (missing(result)) return result;
    return _httpGetBytes(
      Uri.parse(_imageProxyUrl(uri)),
      timeout: const Duration(seconds: 15),
      retries: 1,
    );
  }

  /// 局域网/本机地址，图片直连不走代理。
  static bool _isLocalImageHost(String host) {
    final value = host.toLowerCase();
    if (value == 'localhost' || value == '127.0.0.1' || value == '::1') {
      return true;
    }
    if (value.startsWith('10.') ||
        value.startsWith('192.168.') ||
        value.endsWith('.local')) {
      return true;
    }
    final match = RegExp(r'^172\.(\d+)\.').firstMatch(value);
    if (match != null) {
      final second = int.tryParse(match.group(1)!);
      if (second != null && second >= 16 && second <= 31) return true;
    }
    return false;
  }

  /// 下载海报到本地缓存，返回文件路径；失败返回 null。
  static Future<String?> downloadPoster(
    String url, {
    required String cacheKey,
  }) async {
    final dir = posterDir();
    final safeKey = _sanitizeFileName(cacheKey);
    final file = File('${dir.path}/$safeKey.jpg');
    if (file.existsSync() && file.lengthSync() > 1024) return file.path;

    // 本轮已确认不存在的图（404）：后续重试直接跳过，不再空等线路超时。
    if (_missingImages.contains(url)) return null;

    final uri = Uri.parse(url);
    final isTmdbImage = uri.host == _imageHost || uri.host == _imageCdnHost;
    // 内网服务器（Jellyfin/Emby 等）直连，避免被刮削代理绕出去。
    final proxy = _isLocalImageHost(uri.host) ? null : await _activeProxy();
    ({List<int>? bytes, int status}) result = (bytes: null, status: 0);
    _lastNetworkDetail = null;

    try {
      result = isTmdbImage
          ? await _fetchTmdbImage(uri, proxy: proxy)
          : await _fetchOtherImage(uri, proxy: proxy);
    } catch (error) {
      _lastNetworkDetail = error.toString();
    }
    final bytes = result.bytes;

    if (bytes == null || bytes.length < 1024 || !_looksLikeImage(bytes)) {
      final hint = result.status != 0
          ? 'HTTP ${result.status}'
          : _networkHint();
      onLog?.call('  下载图片失败 $cacheKey：$hint');
      return null;
    }

    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (error) {
      try {
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
      onLog?.call('  下载图片失败 $cacheKey：$error');
      return null;
    }
  }

  /// 刮削线路自检：设置页按钮调用，快速判断 API 与图片 CDN 是否可达。
  static Future<ScrapeDiagnostics> diagnose() async {
    _tmdbOfflineUntil = null;
    _tvmazeOfflineUntil = null;
    lastSearchError = null;
    _lastNetworkDetail = null;
    _lastHttpStatus = 0;
    // 「检测线路」必须真的走网络：清掉缓存，避免命中上次的成功结果
    // 造成线路可用的假象。
    _getCache.clear();

    final proxy = await _activeProxy();
    final explicitProxy = (proxyAddress ?? '').trim();
    final mode = explicitProxy.isNotEmpty
        ? '手动代理 $explicitProxy'
        : proxy != null
        ? '系统/环境代理 $proxy'
        : '直连（自动测速节点）';

    final key = (tmdbApiKey ?? '').trim();
    var apiOk = false;
    var apiDetail = '未配置 TMDB API Key';
    String? probeUrl;
    if (key.isNotEmpty) {
      final watch = Stopwatch()..start();
      final hit = await searchTmdb('三体', preferTv: true);
      apiOk = hit != null;
      probeUrl = hit?.posterUrl;
      apiDetail = apiOk
          ? '成功：${hit.name}'
                '（${watch.elapsedMilliseconds} ms，'
                '${_lastChannel.isEmpty ? '未知' : _lastChannel}）'
          : '失败：${lastSearchError ?? '未返回结果'}'
                '（${watch.elapsedMilliseconds} ms）';
    }

    final watch = Stopwatch()..start();
    final probeUri = Uri.parse(
      probeUrl ?? 'https://$_imageHost/t/p/w92/zxfBtHz5UmSTfIEC4O4GngyjHwa.jpg',
    );
    final imageResult = await _fetchTmdbImage(
      probeUri,
      proxy: proxy,
      maxBytes: 2 * 1024 * 1024,
    );
    final imageBytes = imageResult.bytes;
    final imageOk = imageBytes != null;
    final imageDetail = imageOk
        ? '成功：${imageBytes.length ~/ 1024} KB'
              '（${watch.elapsedMilliseconds} ms，'
              '${_lastImageChannel.isEmpty ? '未知' : _lastImageChannel}）'
        : '失败：${imageResult.status != 0 ? 'HTTP ${imageResult.status}' : _networkHint()}'
              '（${watch.elapsedMilliseconds} ms）';

    return ScrapeDiagnostics(
      apiOk: apiOk,
      imageOk: imageOk,
      mode: mode,
      apiDetail: apiDetail,
      imageDetail: imageDetail,
    );
  }

  /// 删除海报/背景/剧照/演员头像缓存，并清掉直连 IP 缓存。
  /// 返回删除的文件数与释放的字节数。
  static ({int files, int bytes}) clearImageCache() {
    var files = 0;
    var bytes = 0;
    final dir = posterDir();
    if (dir.existsSync()) {
      try {
        for (final entity in dir.listSync(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File) continue;
          try {
            bytes += entity.lengthSync();
            entity.deleteSync();
            files++;
          } catch (_) {
            // 文件被占用时跳过，下次再删
          }
        }
      } catch (_) {
        // 目录不可读时返回已统计的部分
      }
    }

    try {
      final cache = _ipCacheFile();
      if (cache.existsSync()) cache.deleteSync();
    } catch (_) {}
    _dynamicIps.clear();
    _preferredIp.clear();
    _ipCooldown.clear();
    _getCache.clear();
    _missingImages.clear();
    _closeSniPool();
    _closeSharedClient();
    _imageChannelFailStreak.clear();
    _imageChannelProbeDone = false;
    _imageChannelOrder = null;
    _imageProbeTask = null;
    _ipListRefreshedAt = DateTime.fromMillisecondsSinceEpoch(0);
    _ipRefreshAttemptedAt = DateTime.fromMillisecondsSinceEpoch(0);
    _ipRefreshTask = null;
    lastSearchError = null;

    return (files: files, bytes: bytes);
  }

  /// 图片请求的节流：图片走图片 CDN（Bunny/反代），不吃 TMDB API 的
  /// 配额，不需要跟 API 共用一个间隔；留一个很小的间隔只为避免瞬间
  /// 打出几十个连接。取图已改为并发下载，这里不能按 API 的 260ms 卡。
  static const _minImageGap = Duration(milliseconds: 60);
  static DateTime _lastImageRequest = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<void> _throttleImage() async {
    final now = DateTime.now();
    final elapsed = now.difference(_lastImageRequest);
    if (elapsed < _minImageGap) {
      await Future<void>.delayed(_minImageGap - elapsed);
    }
    _lastImageRequest = DateTime.now();
  }

  static Future<void> _throttle() async {
    // 被限流时全局暂停：等 Retry-After / 退避结束再发下一条请求，
    // 避免撞上服务端封控（Jellyfin / Emby 也是统一节流而非并发猛拉）。
    await _waitRateLimitGate();
    final now = DateTime.now();
    final elapsed = now.difference(_lastRequest);
    if (elapsed < _requestGap) {
      await Future<void>.delayed(_requestGap - elapsed);
    }
    _lastRequest = DateTime.now();
  }

  /// TVmaze 的公开接口建议不超过 2 次/秒；它只在 TMDB 缺失/不可用时
  /// 兜底，不该被 TMDB 的快节奏带着走。
  static const _tvmazeGap = Duration(milliseconds: 1000);
  static DateTime _lastTvmazeRequest = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<void> _throttleTvmaze() async {
    await _waitRateLimitGate();
    final now = DateTime.now();
    final elapsed = now.difference(_lastTvmazeRequest);
    if (elapsed < _tvmazeGap) {
      await Future<void>.delayed(_tvmazeGap - elapsed);
    }
    _lastTvmazeRequest = DateTime.now();
  }

  static Future<void> _waitRateLimitGate() async {
    final gate = _rateLimitedUntil;
    if (gate == null) return;
    final wait = gate.difference(DateTime.now());
    if (wait > Duration.zero) {
      final capped = wait > _maxRateLimitWait ? _maxRateLimitWait : wait;
      onLog?.call('  限流冷却中，暂停 ${capped.inSeconds} 秒');
      await Future<void>.delayed(capped);
    }
    if (_rateLimitedUntil != null &&
        !_rateLimitedUntil!.isAfter(DateTime.now())) {
      _rateLimitedUntil = null;
    }
  }

  /// 收到 429/503 时记录全局冷却，并按指数退避放慢后续请求。
  static void _noteRateLimited({Duration? retryAfter}) {
    _rateLimitStreak = (_rateLimitStreak + 1).clamp(1, 5).toInt();
    final backoff = Duration(seconds: 5 * (1 << (_rateLimitStreak - 1)));
    var wait = retryAfter ?? backoff;
    if (wait > _maxRateLimitWait) wait = _maxRateLimitWait;
    final until = DateTime.now().add(wait);
    if (_rateLimitedUntil == null || until.isAfter(_rateLimitedUntil!)) {
      _rateLimitedUntil = until;
    }
    final doubled = _requestGap * 2;
    _requestGap = doubled > _maxRequestGap ? _maxRequestGap : doubled;
    lastSearchError = 'TMDB 触发限流，已暂停 ${wait.inSeconds} 秒后自动继续';
    onLog?.call('  触发限流（429/503），全局暂停 ${wait.inSeconds} 秒');
  }

  /// 请求成功后逐步恢复基准间隔，避免限流解除后立刻再次撞上。
  static void _noteRequestOk() {
    if (_rateLimitStreak == 0) return;
    _rateLimitStreak = 0;
    final eased = _requestGap * 0.7;
    _requestGap = eased < _minRequestGap ? _minRequestGap : eased;
  }

  /// 解析 Retry-After（秒数或 HTTP 日期），返回服务端要求的等待时长。
  static Duration? _retryAfterOf(HttpClientResponse response) {
    final raw = response.headers.value(HttpHeaders.retryAfterHeader);
    if (raw == null || raw.trim().isEmpty) return null;
    final seconds = int.tryParse(raw.trim());
    if (seconds != null) {
      return seconds <= 0 ? null : Duration(seconds: seconds);
    }
    try {
      final delta = HttpDate.parse(raw.trim()).difference(DateTime.now());
      return delta > Duration.zero ? delta : null;
    } catch (_) {
      return null;
    }
  }

  static String stripHtml(String html) => html
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String _sanitizeFileName(String raw) {
    var hash = 0;
    for (final code in raw.codeUnits) {
      hash = (hash * 31 + code) & 0x7FFFFFFF;
    }
    final cleaned = raw
        .replaceAll(RegExp(r'[^\w\u4e00-\u9fa5-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final trimmed = cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
    return '${trimmed}_${hash.toRadixString(36)}';
  }

  /// 名称相似度：归一化后比较（连字符/下划线/点都视作空格）。
  ///
  /// 英文按词重叠，中文按字符集 Jaccard——
  /// 这样「末日酒店」与「末日后酒店」也能得到较高分。
  static double _similarity(String query, String name) {
    final a = _normalize(query);
    final b = _normalize(name);
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;
    // 连字符差异："three body" vs "threebody"
    final aCompact = a.replaceAll(' ', '');
    final bCompact = b.replaceAll(' ', '');
    if (aCompact == bCompact) return 0.95;
    if (b.contains(a) || a.contains(b)) return 0.85;

    final aWords = a.split(' ').where((w) => w.length > 1).toSet();
    final bWords = b.split(' ').where((w) => w.length > 1).toSet();
    var wordScore = 0.0;
    if (aWords.isNotEmpty && bWords.isNotEmpty) {
      wordScore = (aWords.intersection(bWords).length / aWords.length) * 0.75;
    }

    // 字符级相似度（主要惠及中文片名）
    final aChars = aCompact.split('').toSet();
    final bChars = bCompact.split('').toSet();
    var charScore = 0.0;
    if (aChars.isNotEmpty && bChars.isNotEmpty) {
      final union = aChars.union(bChars).length;
      if (union > 0) {
        charScore = (aChars.intersection(bChars).length / union) * 0.85;
      }
    }
    return wordScore > charScore ? wordScore : charScore;
  }

  /// 供刮削层校验「缓存条目/候选条目」是否真的对应当前目录。
  static double nameSimilarity(String a, String b) => _similarity(a, b);

  /// 纯季号查询词（「第 4 季」「Season 4」「S04」）。
  ///
  /// TMDB 上有大量恶意创建/重复的条目专门用这种名字劫持刮削，
  /// 拿它们当搜索词只会命中垃圾数据。
  static bool isSeasonLabelQuery(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return false;
    return RegExp(
      r'^(第\s*[0-9一二三四五六七八九十百]+\s*[季部]|season\s*\d{1,3}|s\d{1,2})$',
      caseSensitive: false,
    ).hasMatch(text);
  }

  /// 整个字符串是否只是语言/字幕标签（「英语」「中字」「英语中字」…）。
  ///
  /// 网盘文件名常写成「4K.英语中字.mkv」，清掉画质后只剩语言标签。
  /// 它不是片名：拿去搜索会命中《萌之英语单词》这类长片（挽救计划事故），
  /// 拿它当「可信目录名」也会让错误匹配通过校验。
  static bool isSubtitleOrAudioLabel(String raw) {
    var text = raw.toLowerCase();
    text = text.replaceAll(RegExp(r'[\s\-_.·/|+、，,（）()\[\]【】]'), '');
    if (text.isEmpty) return false;
    // 长标签在前，避免「中英字幕」被「中英」吃掉后残留「字幕」再匹配
    const labels = <String>[
      '国粤双语',
      '英语中字',
      '国语中字',
      '粤语中字',
      '中英双字',
      '中英字幕',
      '中文字幕',
      '英文字幕',
      '简繁字幕',
      '西班牙语',
      '意大利语',
      '葡萄牙语',
      '阿拉伯语',
      '普通话',
      '多语言',
      '内封字幕',
      '内嵌字幕',
      '外挂字幕',
      '中英',
      '中字',
      '英字',
      '双字',
      '双语',
      '字幕',
      '简体',
      '繁体',
      '简繁',
      '简中',
      '繁中',
      '内封',
      '内嵌',
      '外挂',
      '国语',
      '粤语',
      '英语',
      '英文',
      '日语',
      '日文',
      '韩语',
      '韩文',
      '法语',
      '德语',
      '俄语',
      '泰语',
      '印地语',
      '原声',
      '配音',
      '多语',
      '国配',
      '台配',
      '港配',
    ];
    var rest = text;
    var changed = true;
    while (changed && rest.isNotEmpty) {
      changed = false;
      for (final label in labels) {
        if (rest.startsWith(label)) {
          rest = rest.substring(label.length);
          changed = true;
          break;
        }
      }
    }
    return rest.isEmpty;
  }

  static String _normalize(String raw) => raw
      .toLowerCase()
      .replaceAll(RegExp(r'[-_.]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
