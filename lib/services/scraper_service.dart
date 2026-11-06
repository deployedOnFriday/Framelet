import '../models/cast_member.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'proxy_resolver.dart';

/// 刮削结果：海报地址、简介与评分。
class ScrapeResult {
  const ScrapeResult({
    required this.name,
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
  const _SniAttempt({required this.ip, this.status, this.bytes, this.error});

  final String ip;
  final int? status;
  final List<int>? bytes;
  final String? error;
}

/// 海报与元数据刮削：
/// - 主源 TVmaze（免费、无需密钥，覆盖剧集/动漫/部分电影）
/// - 图片本地缓存，避免重复下载
/// - 限速友好，失败静默跳过，不影响媒体库使用
class ScraperService {
  ScraperService._();

  static const _userAgent = 'Framelet/0.1 (media library scraper)';
  static const _requestGap = Duration(milliseconds: 260);
  static DateTime _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);

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
  static String? tmdbApiKey;

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

  /// 最近一次刮削网络失败原因；UI 用它区分「真没搜到」与「网络不通」。
  static String? lastSearchError;

  static String get lastError => lastSearchError ?? '';

  static String get lastChannel => _lastChannel;

  /// 设置变更后清掉探测缓存，下一次请求按新代理/网络重新选择线路。
  static void resetNetworkSettings() {
    ProxyResolver.reset();
    _tmdbOfflineUntil = null;
    _tvmazeOfflineUntil = null;
    _preferredIp.clear();
    _ipCooldown.clear();
    lastSearchError = null;
  }

  static HttpClient _httpClient({String? proxy}) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..userAgent = _userAgent;
    final effective = ProxyResolver.normalize(proxy ?? proxyAddress ?? '');
    if (effective.isNotEmpty) {
      client.findProxy = (_) => 'PROXY $effective';
    }
    return client;
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
      client.close(force: true);
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

  /// 是否处于离线冷却（此时请求会被短路直接返回失败）。
  static bool get tmdbCoolingDown =>
      _tmdbOfflineUntil != null &&
      _tmdbOfflineUntil!.isAfter(DateTime.now());

  /// 通过「国内可用 IP + 域名 SNI」直连 TMDB API。
  ///
  /// TMDB 在国内被 DNS 污染，直接解析域名常会超时；这里用 SecureSocket
  /// 手工完成 TLS（host 参数保证 SNI 与证书校验仍按域名），再由 IP
  /// 建立 TCP 连接，从而绕过污染。
  static Future<String?> _tmdbGet(String pathAndQuery) async {
    if (_tmdbOfflineUntil != null &&
        _tmdbOfflineUntil!.isAfter(DateTime.now())) {
      return null;
    }

    var proxy = await _activeProxy();
    final usingSystemProxy =
        (proxyAddress ?? '').trim().isEmpty && proxy != null;
    final uri = Uri.parse('https://$_apiHost$pathAndQuery');
    _lastNetworkDetail = null;
    _lastHttpStatus = 0;
    // 各线路是否收到过 HTTP 状态码。收到了（哪怕 404/5xx）说明线路可达，
    // 属内容/节点层问题；只有全程无响应才算真不可达、才值得全局冷却。
    var sawHttpStatus = false;
    void noteHttpStatus() {
      if (_lastHttpStatus != 0) sawHttpStatus = true;
    }

    if (proxy != null) {
      final text = await _httpGetText(uri, proxy: proxy);
      if (text != null) {
        _markTmdbOnline('代理');
        return text;
      }
      if (_lastHttpStatus == 401 || _lastHttpStatus == 403) {
        _markTmdbOnline('代理');
        lastSearchError = 'TMDB API Key 无效或已失效，请到 设置 → 刮削 重新填写';
        return null;
      }
      // 系统代理存在但实际上不通（代理软件已退出等）：本次运行不再尝试，
      // 直接走直连线路，避免每个条目都先等一次代理超时。
      if (usingSystemProxy && _lastHttpStatus == 0) {
        ProxyResolver.disableSystemProxy();
        proxy = null;
      }
      noteHttpStatus();
    }

    bool keyRejected() => _lastHttpStatus == 401 || _lastHttpStatus == 403;

    void rejectKey(String channel) {
      _markTmdbOnline(channel);
      lastSearchError = 'TMDB API Key 无效或已失效，请到 设置 → 刮削 重新填写';
    }

    noteHttpStatus();
    _lastHttpStatus = 0;
    final body = await _sniGetBytes(_apiHost, pathAndQuery);
    if (body != null) {
      _markTmdbOnline('SNI 直连');
      return utf8.decode(body, allowMalformed: true);
    }
    if (keyRejected()) {
      // 能收到 401 说明线路是通的，问题在密钥而不是网络。
      rejectKey('SNI 直连');
      return null;
    }

    // api.tmdb.org 是 TMDB 的另一条 CloudFront 线路，域名未被污染时
    // 可直接 HTTPS 访问；这是实测最有效的免代理备用通道。
    noteHttpStatus();
    _lastHttpStatus = 0;
    var text = await _httpGetText(
      Uri.parse('https://$_apiAltHost$pathAndQuery'),
    );
    if (text != null) {
      _markTmdbOnline('api.tmdb.org 直连');
      return text;
    }
    if (keyRejected()) {
      rejectKey('api.tmdb.org 直连');
      return null;
    }

    noteHttpStatus();
    _lastHttpStatus = 0;
    final altBody = await _sniGetBytes(_apiAltHost, pathAndQuery);
    if (altBody != null) {
      _markTmdbOnline('api.tmdb.org SNI');
      return utf8.decode(altBody, allowMalformed: true);
    }
    if (keyRejected()) {
      rejectKey('api.tmdb.org SNI');
      return null;
    }

    // 端口 80 + 内置 IP + Host 头：绕过 SNI 阻断与污染 DNS。
    noteHttpStatus();
    _lastHttpStatus = 0;
    final plain = await _plainHttpGetViaIp(
      _apiHost,
      pathAndQuery,
      acceptAnyStatus: true,
    );
    if (plain?.bytes != null) {
      _markTmdbOnline('HTTP 直连');
      return utf8.decode(plain!.bytes!, allowMalformed: true);
    }
    if (keyRejected()) {
      rejectKey('HTTP 直连');
      return null;
    }

    noteHttpStatus();
    _lastHttpStatus = 0;
    final altPlain = await _plainHttpGetViaIp(
      _apiAltHost,
      pathAndQuery,
      acceptAnyStatus: true,
    );
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
    noteHttpStatus();
    _lastHttpStatus = 0;
    text = await _httpGetText(uri);
    if (text != null) {
      _markTmdbOnline('普通直连');
      return text;
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
    final basePath = qIndex < 0 ? pathAndQuery : pathAndQuery.substring(0, qIndex);
    final params = <String>[];
    if (qIndex >= 0) {
      for (final pair in pathAndQuery.substring(qIndex + 1).split('&')) {
        if (pair.isEmpty || pair.startsWith('api_key=')) continue;
        params.add(pair);
      }
    }
    final bust = DateTime.now().millisecondsSinceEpoch;
    Future<String?> tryProxy({required bool withKey}) {
      final all = <String>[
        if (withKey && (tmdbApiKey?.trim().isNotEmpty ?? false))
          'api_key=${tmdbApiKey!.trim()}',
        ...params,
        '_cb=$bust${withKey ? 'k' : 'n'}',
      ];
      return _httpGetText(
        Uri.parse('https://$_apiProxyHost$basePath?${all.join('&')}'),
        timeout: const Duration(seconds: 20),
      );
    }

    // 先不带 key（反代注入自己的）；反代要求 key（401）再带上重试
    var proxyText = await tryProxy(withKey: false);
    if (proxyText == null && _lastHttpStatus == 401) {
      proxyText = await tryProxy(withKey: true);
    }
    if (proxyText != null) {
      _markTmdbOnline('自建反代');
      return proxyText;
    }

    noteHttpStatus();

    // 线路收到过 HTTP 响应（如 404/5xx）：网络是通的，属内容/节点层问题
    // （实测失效的 CloudFront 边缘节点会对有效路径回 404）。此时绝不进入
    // 离线冷却——否则一次瞬时异常会把整批任务连坐成"未匹配"；让调用方
    // 回退到搜索线路自行恢复。
    if (sawHttpStatus) {
      lastSearchError =
          'TMDB 线路可达但返回 HTTP $_lastHttpStatus'
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

  static Future<String?> _httpGetText(
    Uri uri, {
    String? proxy,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final client = _httpClient(proxy: proxy);
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      final response = await request.close().timeout(timeout);
      _lastHttpStatus = response.statusCode;
      if (response.statusCode != 200) {
        try {
          await response.drain<void>();
        } catch (_) {}
        return null;
      }
      final bytes = await _readLimited(response, 8 * 1024 * 1024, timeout);
      return utf8.decode(bytes, allowMalformed: true);
    } catch (error) {
      _lastNetworkDetail = error.toString();
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<List<int>?> _httpGetBytes(
    Uri uri, {
    String? proxy,
    Duration timeout = const Duration(seconds: 15),
    int retries = 2,
  }) async {
    for (var attempt = 0; attempt < retries; attempt++) {
      if (attempt > 0) await _throttle();
      final client = _httpClient(proxy: proxy);
      try {
        final request = await client.getUrl(uri).timeout(timeout);
        final response = await request.close().timeout(timeout);
        _lastHttpStatus = response.statusCode;
        if (response.statusCode != 200) {
          try {
            await response.drain<void>();
          } catch (_) {}
          if (response.statusCode == 401 ||
              response.statusCode == 403 ||
              response.statusCode == 404) {
            return null;
          }
          continue;
        }
        final bytes = await _readLimited(response, 20 * 1024 * 1024, timeout);
        if (bytes.length >= 1024) return bytes;
      } catch (error) {
        _lastNetworkDetail = error.toString();
      } finally {
        client.close(force: true);
      }
    }
    return null;
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
  static Future<List<int>?> _sniGetBytes(
    String host,
    String pathAndQuery, {
    int maxBytes = 16 * 1024 * 1024,
    bool image = false,
  }) async {
    await _ensureIpPool();
    _lastHttpStatus = 0;
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
    if (dnsIps.isEmpty) return null;
    final dnsResult = await _sniTryIps(
      host,
      dnsIps,
      pathAndQuery,
      maxBytes: maxBytes,
      image: image,
    );
    return dnsResult == null ? null : _acceptSniResult(host, dnsResult);
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
  /// 例外：非 200/206 的状态不把该 IP 记为「首选」并短暂冷却——
  /// 实测失效的 CloudFront 边缘节点会对有效路径回 404，若记为首选
  /// 会导致后续请求全部优先命中这个坏节点，恶性循环。
  static List<int>? _acceptSniResult(String host, _SniAttempt result) {
    final status = result.status;
    if (status != null && status != 200 && status != 206) {
      _preferredIp.remove(host);
      _ipCooldown[result.ip] = DateTime.now().add(
        const Duration(minutes: 3),
      );
    } else {
      _preferredIp[host] = result.ip;
      _ipCooldown.remove(result.ip);
    }
    _lastHttpStatus = status ?? 200;
    return result.bytes;
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

    void finish(_SniAttempt? attempt) {
      if (completer.isCompleted) return;
      if (attempt != null &&
          (attempt.bytes != null || attempt.status != null)) {
        completer.complete(attempt);
        return;
      }
      pending--;
      if (pending == 0) completer.complete(null);
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
  }) async {
    Socket? raw;
    Socket? secure;
    try {
      raw = await Socket.connect(ip, 443).timeout(const Duration(seconds: 5));
      secure = await SecureSocket.secure(
        raw,
        host: host,
      ).timeout(const Duration(seconds: 6));
      final response = await _sniRequest(
        secure,
        host,
        pathAndQuery,
        maxBytes: maxBytes,
        image: image,
      );
      if (response == null) {
        _ipCooldown[ip] = DateTime.now().add(const Duration(minutes: 3));
        return _SniAttempt(ip: ip, error: 'empty response');
      }
      return _SniAttempt(
        ip: ip,
        status: response.status,
        bytes: response.status == 200 ? response.body : null,
      );
    } catch (error) {
      _ipCooldown[ip] = DateTime.now().add(const Duration(minutes: 2));
      return _SniAttempt(ip: ip, error: error.toString());
    } finally {
      try {
        await secure?.close();
      } catch (_) {}
      try {
        await raw?.close();
      } catch (_) {}
    }
  }

  static Future<({int status, List<int> body})?> _sniRequest(
    Socket secure,
    String host,
    String pathAndQuery, {
    required int maxBytes,
    required bool image,
  }) async {
    secure.write(
      'GET $pathAndQuery HTTP/1.1\r\n'
      'Host: $host\r\n'
      'User-Agent: $_userAgent\r\n'
      'Accept: ${image ? 'image/avif,image/webp,image/*,*/*;q=0.8' : 'application/json,*/*'}\r\n'
      'Accept-Encoding: identity\r\n'
      'Connection: close\r\n\r\n',
    );
    final bytes = <int>[];
    await for (final chunk in secure.timeout(const Duration(seconds: 20))) {
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) break;
    }
    return _parseHttpBytes(bytes);
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

    final bracketNames = RegExp(r'[\[【]([^\]】]+)[\]】]')
        .allMatches(text)
        .map((m) => m.group(1)!.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    text = text.replaceAll(RegExp(r'[\[【][^\]】]*[\]】]'), ' ');
    // 圆括号内容剥掉（(1994)/(加长版) 等），年份由独立 token 识别
    text = text.replaceAll(RegExp(r'[（(][^）)]*[）)]'), ' ');

    final tokens = text
        .split(RegExp(r'[.\s_]+'))
        .map((token) => token.trim())
        .where((token) => token.isNotEmpty)
        .toList();

    const junkPattern =
        r'^(1080p|720p|2160p|4k|8k|uhd|x264|x265|h264|h265|hevc|avc|aac|ac3|eac3|dts|flac|truehd|bluray|blu-ray|bdrip|webrip|web-dl|webdl|hdtv|remux|hdr10?|dv|dolby|atmos|10bits?|8bits?|proper|repack|extended|uncut|cr|ubweb|nf|amzn|dsnp|hmax|atvp|max|sdr|hevc10|60fps|120fps|60帧|120帧|高码|高bitrate|hq|web)$';
    final junk = RegExp(junkPattern, caseSensitive: false);
    final episode = RegExp(
      r'^(s\d{1,2}(e\d{1,2})?|e\d{1,2}|ep\d{1,3}|\d{1,2}[集期])$',
      caseSensitive: false,
    );

    int? year;
    final cleaned = <String>[];
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      final isYear = RegExp(r'^(19|20)\d{2}$').hasMatch(token);
      if (isYear) {
        year = int.tryParse(token);
        continue;
      }
      if (junk.hasMatch(token) || episode.hasMatch(token)) continue;
      // 连字符粘着的技术段（Atmos-CiNEPHiLES、Blu-ray-Remux 之类）：
      // 任一段是技术词就整段丢弃；纯标题连字符（Spider-Man）不含
      // 技术词，原样保留。
      if (token.contains('-') &&
          token
              .toLowerCase()
              .split('-')
              .any((segment) => junk.hasMatch(segment))) {
        continue;
      }
      // 末尾的 1~2 位纯数字视为集数
      if (RegExp(r'^\d{1,2}$').hasMatch(token) && i >= tokens.length - 2) {
        continue;
      }
      cleaned.add(token);
    }

    var name = cleaned.join(' ').trim();
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

    final queries = <String>[if (name.isNotEmpty) name, ...bracketNames];
    // 通用规则：标题尾部的 1~2 位纯数字多为季号（唐朝诡事录1/魔幻手机2），
    // 生成一个剥掉后的变体用于搜索——命中率高且无需逐部写别名
    final tail = RegExp(r'^(.*[^0-9])(\d{1,2})$').firstMatch(name);
    if (tail != null) {
      final stripped = tail.group(1)!.trim();
      if (stripped.length >= 2 && !queries.contains(stripped)) {
        queries.add(stripped);
      }
    }
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
      await _throttle();
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
      client.close(force: true);
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
      await _throttle();
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
      client.close(force: true);
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
      await _throttle();
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
      client.close(force: true);
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

  static String _imageProxyUrl(
    Uri uri, {
    String host = 'images.weserv.nl',
  }) {
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
    await _ensureIpPool();
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
        _lastHttpStatus = attempt.status ?? 200;
        return attempt;
      }
      if (acceptAnyStatus && attempt?.status != null) {
        _preferredIp[host] = attempt!.ip;
        _lastHttpStatus = attempt.status!;
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

    void finish(_SniAttempt? attempt) {
      if (completer.isCompleted) return;
      if (attempt?.bytes != null ||
          (acceptAnyStatus && attempt?.status != null)) {
        completer.complete(attempt);
        return;
      }
      pending--;
      if (pending == 0) completer.complete(null);
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

  static Future<List<int>?> _plainHttpImageViaIp(Uri uri) async {
    final attempt = await _plainHttpGetViaIp(
      uri.host,
      _pathAndQuery(uri),
      maxBytes: 20 * 1024 * 1024,
      image: true,
    );
    return attempt?.bytes;
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

  /// 执行指定取图线路（不校验内容，校验由调用方 accept 负责）。
  static Future<List<int>?> _runImageChannel(
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
        return _sniGetBytes(_imageCdnHost, path, maxBytes: maxBytes, image: true);
      case _chPlainHttp:
        return _plainHttpImageViaIp(uri);
      case _chSni:
        return _sniGetBytes(_imageHost, path, maxBytes: maxBytes, image: true);
      case _chHttps:
        return _httpGetBytes(uri, timeout: const Duration(seconds: 10), retries: 1);
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
        if (first != null) return first;
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
    return null;
  }

  /// 首次取图前并行探测各线路（同一张 w92 小图，~3KB），按实测耗时
  /// 排序缓存；失败的线路排到最后。并行跑总耗时≈最慢线路，
  /// 每次运行只测一次。全部失败时保持默认顺序。
  static Future<void> _probeImageChannels() async {
    if (_imageChannelProbeDone) return;
    _imageChannelProbeDone = true;
    const sample = '/t/p/w92/zxfBtHz5UmSTfIEC4O4GngyjHwa.jpg';
    final sampleUri = Uri.parse('https://$_imageHost$sample');
    final timings = <String, int>{};
    await Future.wait(
      _defaultImageChannels.map((channel) async {
        final watch = Stopwatch()..start();
        try {
          final bytes = await _runImageChannel(
            channel,
            uri: sampleUri,
            path: sample,
            maxBytes: 1 << 20,
          ).timeout(const Duration(seconds: 6));
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

  /// 免代理取图：首次先并行测速各线路选最快的，随后按实测顺序
  /// 逐条尝试；代理可用时先走代理，但代理不通也不会挡住直连线路。
  static Future<List<int>?> _fetchTmdbImage(
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
      _lastHttpStatus = 200;
      return bytes;
    }

    if (proxy != null) {
      final bytes = await _httpGetBytes(
        uri,
        proxy: proxy,
        timeout: const Duration(seconds: 12),
        retries: 1,
      );
      if (bytes != null && _looksLikeImage(bytes)) {
        _lastImageChannel = '代理';
        return bytes;
      }
      if (usingSystemProxy && _lastHttpStatus == 0) {
        ProxyResolver.disableSystemProxy();
      }
    }

    // 代理没走通才需要直连线路：先测速选最快的（仅首次，~6 秒内）。
    await _probeImageChannels();
    final order = _imageChannelOrder ?? _defaultImageChannels;

    List<int>? bytes;
    for (final channel in order) {
      await _throttle();
      bytes = accept(
        await _runImageChannel(channel, uri: uri, path: path, maxBytes: maxBytes),
        channel,
      );
      if (bytes != null) return bytes;
    }
    return null;
  }

  /// 非 TMDB 图片（如 TVmaze）的免代理通道：HTTP/IP 直连、
  /// 普通 HTTPS、HTTP 以及图片加速节点逐级兜底。
  static Future<List<int>?> _fetchOtherImage(Uri uri, {String? proxy}) async {
    List<int>? accept(List<int>? bytes) {
      if (bytes == null || bytes.length < 1024 || !_looksLikeImage(bytes)) {
        return null;
      }
      return bytes;
    }

    List<int>? bytes;
    if (uri.host.endsWith('tvmaze.com')) {
      bytes = accept(await _plainHttpImageViaIp(uri));
      if (bytes != null) return bytes;
    }
    bytes = accept(
      await _httpGetBytes(
        uri,
        proxy: proxy,
        timeout: const Duration(seconds: 10),
        retries: 1,
      ),
    );
    if (bytes != null) return bytes;
    bytes = accept(await _plainHttpImageViaIp(uri));
    if (bytes != null) return bytes;
    bytes = accept(
      await _httpGetBytes(
        uri.replace(scheme: 'http'),
        timeout: const Duration(seconds: 12),
        retries: 1,
      ),
    );
    if (bytes != null) return bytes;
    bytes = accept(
      await _httpGetBytes(
        Uri.parse(_imageProxyUrl(uri)),
        timeout: const Duration(seconds: 15),
        retries: 1,
      ),
    );
    if (bytes != null) return bytes;
    return null;
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

    final uri = Uri.parse(url);
    final isTmdbImage = uri.host == _imageHost || uri.host == _imageCdnHost;
    final proxy = await _activeProxy();
    List<int>? bytes;
    _lastNetworkDetail = null;
    _lastHttpStatus = 0;

    try {
      if (isTmdbImage) {
        bytes = await _fetchTmdbImage(uri, proxy: proxy);
      } else {
        bytes = await _fetchOtherImage(uri, proxy: proxy);
      }
    } catch (error) {
      _lastNetworkDetail = error.toString();
      bytes = null;
    }

    if (bytes == null || bytes.length < 1024 || !_looksLikeImage(bytes)) {
      onLog?.call('  下载图片失败 $cacheKey：${_networkHint()}');
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
    final imageBytes = await _fetchTmdbImage(
      probeUri,
      proxy: proxy,
      maxBytes: 2 * 1024 * 1024,
    );
    final imageOk = imageBytes != null;
    final imageDetail = imageOk
        ? '成功：${imageBytes.length ~/ 1024} KB'
              '（${watch.elapsedMilliseconds} ms，'
              '${_lastImageChannel.isEmpty ? '未知' : _lastImageChannel}）'
        : '失败：${_networkHint()}'
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
    _ipListRefreshedAt = DateTime.fromMillisecondsSinceEpoch(0);
    _ipRefreshAttemptedAt = DateTime.fromMillisecondsSinceEpoch(0);
    _ipRefreshTask = null;
    lastSearchError = null;

    return (files: files, bytes: bytes);
  }

  static Future<void> _throttle() async {
    final now = DateTime.now();
    final elapsed = now.difference(_lastRequest);
    if (elapsed < _requestGap) {
      await Future<void>.delayed(_requestGap - elapsed);
    }
    _lastRequest = DateTime.now();
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

  static String _normalize(String raw) => raw
      .toLowerCase()
      .replaceAll(RegExp(r'[-_.]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
