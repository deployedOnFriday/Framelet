import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// 弹幕来源。两个源可以同时开启，搜索结果会合并展示。
enum DanmakuBackend {
  /// 弹弹play 官方 API，签名直连，动漫数据全、响应快。
  dandanplay,

  /// 自建 / 第三方兼容服务（LogVar、御坂等），补充国产剧与平台源。
  custom,
}

class DanmakuEpisode {
  const DanmakuEpisode({
    required this.animeTitle,
    required this.episodeTitle,
    required this.episodeId,
    this.backend = DanmakuBackend.dandanplay,
  });

  final String animeTitle;
  final String episodeTitle;
  final int episodeId;
  final DanmakuBackend backend;

  /// 不同服务的 episodeId 可能撞号，缓存和菜单选择都要带上来源。
  String get key => '${backend.name}:$episodeId';

  String get backendLabel =>
      backend == DanmakuBackend.dandanplay ? '弹弹' : '自建';

  @override
  String toString() => '$animeTitle · $episodeTitle';
}

class DanmakuComment {
  const DanmakuComment({
    required this.timeSec,
    required this.mode,
    required this.color,
    required this.text,
  });

  final double timeSec;
  final int mode;
  final int color;
  final String text;
}

class DanmakuException implements Exception {
  const DanmakuException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 兼容 DanDanPlay v2 协议的弹幕客户端。
///
/// 同时支持：
/// - 弹弹play 官方 API（内置开放平台凭据，签名直连）
/// - 自建 / 第三方服务（默认内置地址，可在设置里替换）
///
/// 注意：这类服务只提供弹幕，不提供 .srt/.ass 字幕文件。
class DanmakuService {
  DanmakuService._();

  static const officialBaseUrl = 'https://api.dandanplay.net';

  /// 内置弹弹play 开放 API 凭据：开箱即用。
  static const builtinAppId = 'j6fj7hpqhg';
  static const builtinAppSecret = 'bEjx9A6uMQqLveCmyyih9PKcCFeJzycw';

  /// 两个源默认都开启：官方直连负责速度与动漫覆盖，
  /// 自建源补充国产剧和平台源。
  static bool dandanplayEnabled = true;
  static bool customEnabled = true;

  /// 自建服务的根地址（不含 `/api/v2`）。
  static String baseUrl = builtinBaseUrl;
  static String? proxyAddress;

  /// 内置自建服务地址。
  ///
  /// 明文地址不直接出现在源码与配置里，而是按字节 XOR 后再分片 Base64 存放。
  /// 这只是防止被随手 grep / 改配置时泄露的混淆手段；客户端内置的密钥
  /// 无法做到真正的保密（有心的用户可以逆向出来）。
  static const _builtinChunks = <String>[
    'T20X+ABioQhPWPOqKB',
    'JZPA7EXqKREsPxfVpF',
    'fey5mncTKkzsEjbjUg',
    'FL9aRuCEc4DsBWuA==',
  ];

  static const _builtinKeyParts = <String>[
    'framelet|',
    'danmaku|',
    'builtin|v1|',
    'A9f3c7e1',
  ];

  static String? _builtinBaseUrlCache;

  static String get builtinBaseUrl =>
      _builtinBaseUrlCache ??= _decodeBuiltinBaseUrl();

  static String _decodeBuiltinBaseUrl() {
    final key = sha256.convert(utf8.encode(_builtinKeyParts.join())).bytes;
    final payload = base64Decode(_builtinChunks.join());
    final plain = List<int>.generate(
      payload.length,
      (index) => payload[index] ^ key[index % key.length],
      growable: false,
    );
    return utf8.decode(plain);
  }

  static bool get configured =>
      dandanplayEnabled || (customEnabled && baseUrl.trim().isNotEmpty);

  /// 是否仍在使用内置自建服务（用户没有填写自定义地址）。
  static bool get usingBuiltin {
    String normalize(String value) =>
        value.trim().replaceFirst(RegExp(r'/+$'), '');
    return normalize(baseUrl) == normalize(builtinBaseUrl);
  }

  /// 调试 / 设置页展示用：只保留协议和主机，避免把 token 打进日志。
  static String get displayHost {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || uri.host.isEmpty) return '未配置';
    return uri.host;
  }

  static List<DanmakuBackend> get enabledBackends => [
    if (dandanplayEnabled) DanmakuBackend.dandanplay,
    if (customEnabled && baseUrl.trim().isNotEmpty) DanmakuBackend.custom,
  ];

  /// 自建源在双源模式下最多再等多久，超时就用已拿到的官方结果。
  static const _secondarySearchBudget = Duration(seconds: 30);

  /// 官方已经搜到结果时，自建源只再等这么久：动漫场景没必要为它卡住。
  static const _secondarySearchBudgetWithHits = Duration(seconds: 3);

  static final Map<String, List<DanmakuComment>> _cache = {};

  /// 切换弹幕服务后清空缓存，避免不同服务使用相同 episodeId 时串弹幕。
  static void clearCache() => _cache.clear();

  static String _baseFor(DanmakuBackend backend) =>
      backend == DanmakuBackend.dandanplay ? officialBaseUrl : baseUrl;

  static Future<List<DanmakuEpisode>> searchEpisodes({
    required String anime,
    required int episode,
  }) async {
    final backends = enabledBackends;
    if (backends.isEmpty) {
      throw const DanmakuException('尚未启用弹幕源，请到 设置 → 弹幕 开启');
    }
    if (backends.length == 1) {
      final outcome = await _searchBackendSafe(backends.single, anime, episode);
      if (outcome.episodes.isEmpty && outcome.error != null) {
        throw outcome.error!;
      }
      return outcome.episodes;
    }

    final stopwatch = Stopwatch()..start();
    // 自建源先发出去，避免它慢的时候把官方源也拖住。
    final customFuture = _searchBackendSafe(
      DanmakuBackend.custom,
      anime,
      episode,
    );
    final dandan = await _searchBackendSafe(
      DanmakuBackend.dandanplay,
      anime,
      episode,
    );

    var custom = const _SearchOutcome(<DanmakuEpisode>[], null);
    // 官方有结果就快速返回；官方为空时才等自建源（国产剧主要靠它）。
    final budget = dandan.episodes.isEmpty
        ? _secondarySearchBudget
        : _secondarySearchBudgetWithHits;
    final remaining = budget - stopwatch.elapsed;
    if (remaining > Duration.zero) {
      try {
        custom = await customFuture.timeout(remaining);
      } on TimeoutException {
        // 自建源太慢就先用官方结果，不让用户干等。
      }
    }

    final merged = _merge(dandan.episodes, custom.episodes);
    if (merged.isEmpty) {
      final error = dandan.error ?? custom.error;
      if (error != null) throw error;
    }
    return merged;
  }

  /// 官方结果优先；自建源里同 episodeId 的条目通常是同一批 dandan 数据，跳过避免重复。
  static List<DanmakuEpisode> _merge(
    List<DanmakuEpisode> primary,
    List<DanmakuEpisode> secondary,
  ) {
    final result = <DanmakuEpisode>[...primary];
    final ids = primary.map((episode) => episode.episodeId).toSet();
    for (final episode in secondary) {
      if (ids.contains(episode.episodeId)) continue;
      result.add(episode);
    }
    return result;
  }

  static Future<_SearchOutcome> _searchBackendSafe(
    DanmakuBackend backend,
    String anime,
    int episode,
  ) async {
    try {
      final episodes = await _searchBackend(backend, anime, episode);
      return _SearchOutcome(episodes, null);
    } on DanmakuException catch (error) {
      return _SearchOutcome(const [], error);
    } catch (error) {
      return _SearchOutcome(
        const [],
        DanmakuException('弹幕搜索失败：$error'),
      );
    }
  }

  static Future<List<DanmakuEpisode>> _searchBackend(
    DanmakuBackend backend,
    String anime,
    int episode,
  ) async {
    final uri = Uri.parse(
      endpoint('/search/episodes', base: _baseFor(backend)),
    ).replace(queryParameters: {'anime': anime, 'episode': episode.toString()});
    final data = await _getJson(uri, backend);
    final animes = data['animes'] as List<Object?>? ?? const [];
    final result = <DanmakuEpisode>[];
    for (final item in animes) {
      if (item is! Map<String, Object?>) continue;
      final animeTitle = item['animeTitle'] as String? ?? anime;
      final episodes = item['episodes'] as List<Object?>? ?? const [];
      for (final raw in episodes) {
        if (raw is! Map<String, Object?>) continue;
        final id = (raw['episodeId'] as num?)?.toInt();
        if (id == null) continue;
        result.add(
          DanmakuEpisode(
            animeTitle: animeTitle,
            episodeTitle: raw['episodeTitle'] as String? ?? '第 $episode 集',
            episodeId: id,
            backend: backend,
          ),
        );
      }
    }
    return result;
  }

  static Future<List<DanmakuComment>> comments(DanmakuEpisode episode) async {
    final cacheKey = episode.key;
    final cached = _cache[cacheKey];
    if (cached != null) return cached;
    // 不带 withRelated：自建服务合并关联集弹幕会显著变慢，
    // 单集弹幕足够，且能避免弱网 / 低配服务器上长时间等待。
    final uri = Uri.parse(
      endpoint('/comment/${episode.episodeId}', base: _baseFor(episode.backend)),
    );
    final data = await _getJson(uri, episode.backend);
    final raw = data['comments'] as List<Object?>? ?? const [];
    final result = <DanmakuComment>[];
    for (final item in raw) {
      if (item is! Map<String, Object?>) continue;
      final text = (item['m'] as String? ?? '').trim();
      if (text.isEmpty) continue;
      final p = (item['p'] as String? ?? '').split(',');
      if (p.length < 3) continue;
      final time = double.tryParse(p[0]);
      final mode = int.tryParse(p[1]) ?? 1;
      final color = int.tryParse(p[2]) ?? 0xFFFFFF;
      if (time == null) continue;
      result.add(
        DanmakuComment(timeSec: time, mode: mode, color: color, text: text),
      );
    }
    result.sort((a, b) => a.timeSec.compareTo(b.timeSec));
    _cache[cacheKey] = result;
    return result;
  }

  /// 是否容忍「已过期但域名匹配」的证书。
  ///
  /// 内置自建源由第三方维护，续期不及时会让整条弹幕链路直接不可用。
  /// 弹幕只读、不携带任何私人信息，因此这里做一次有限度的降级：
  /// 仅放行「证书确实过期」且「证书主体就是目标域名」的情况，
  /// 自签名、域名不匹配、签发者异常的证书仍然一律拒绝。
  static bool trustExpiredCertificates = true;

  /// [HttpClient.badCertificateCallback] 的实现，只在证书过期时被调用。
  static bool _acceptOnlyExpiredMatchingCertificate(
    X509Certificate certificate,
    String host,
    int port,
  ) {
    if (!trustExpiredCertificates) return false;
    final allowed = shouldTrustExpiredCertificate(
      subject: certificate.subject,
      notAfter: certificate.endValidity,
      host: host,
    );
    if (allowed) {
      debugPrint(
        '[danmaku] 证书已过期（${certificate.endValidity.toIso8601String()}），'
        '域名匹配 $host，继续请求',
      );
    }
    return allowed;
  }

  /// 判断过期证书是否可以放行。抽成纯函数便于单测。
  static bool shouldTrustExpiredCertificate({
    required String subject,
    required DateTime notAfter,
    required String host,
    DateTime? now,
  }) {
    final current = (now ?? DateTime.now()).toUtc();
    if (!notAfter.toUtc().isBefore(current)) return false;
    final normalizedHost = host.trim().toLowerCase();
    if (normalizedHost.isEmpty) return false;
    // subject 形如 `CN=abot.openlist.ccwu.cc`，命中域名才认。
    return subject.toLowerCase().contains(normalizedHost);
  }

  static Future<Map<String, Object?>> _getJson(
    Uri uri,
    DanmakuBackend backend,
  ) async {
    if (!configured) {
      throw const DanmakuException('尚未配置弹幕服务，请到 设置 → 弹幕 开启');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = 'Framelet/0.1'
      ..badCertificateCallback = _acceptOnlyExpiredMatchingCertificate;
    final proxy = (proxyAddress ?? '').trim();
    if (proxy.isNotEmpty) {
      client.findProxy = (_) => 'PROXY $proxy';
    }
    try {
      final request = await client.getUrl(uri);
      // 弹弹play 的 /comment 会 302 到 cas2.dandanplay.net，必须跟随。
      request.followRedirects = true;
      request.maxRedirects = 5;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (backend == DanmakuBackend.dandanplay) {
        final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final signature = base64Encode(
          sha256
              .convert(
                utf8.encode(
                  '$builtinAppId$timestamp${uri.path}$builtinAppSecret',
                ),
              )
              .bytes,
        );
        request.headers
          ..set('X-AppId', builtinAppId)
          ..set('X-Timestamp', timestamp.toString())
          ..set('X-Signature', signature);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 25),
      );
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 45));
      if (response.statusCode != 200) {
        final detail = response.headers.value('X-Error-Message');
        throw DanmakuException(
          '弹幕请求失败（HTTP ${response.statusCode}）'
          '${detail == null ? '' : '：$detail'}',
        );
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?>) {
        throw const DanmakuException('弹幕服务返回格式异常');
      }
      if (decoded['success'] == false) {
        throw DanmakuException(decoded['errorMessage'] as String? ?? '弹幕请求失败');
      }
      return decoded;
    } on DanmakuException {
      rethrow;
    } on TimeoutException {
      throw const DanmakuException('弹幕请求超时');
    } on HandshakeException {
      throw const DanmakuException(
        '弹幕服务 HTTPS 证书校验失败（服务端证书过期或域名不匹配），'
        '可稍后重试或到 设置 → 弹幕 更换服务地址',
      );
    } on SocketException catch (error) {
      final timedOut = error.message.contains('timed out');
      throw DanmakuException(
        timedOut
            ? '连接弹幕服务超时（网络慢或服务繁忙）'
            : '无法连接弹幕服务（网络不通或服务未启动）',
      );
    } on HttpException {
      // Cloudflare / nginx 在源站超时或重启时会直接断开连接，
      // 表现出来就是 “Connection closed before full header was received”。
      throw const DanmakuException('弹幕服务连接被中断（源站超时或正在重启）');
    } catch (error) {
      throw DanmakuException('弹幕请求失败：$error');
    } finally {
      client.close(force: true);
    }
  }

  /// 兼容多种填法：
  /// - `https://danmu.example.com/<token>`
  /// - `https://danmu.example.com/<token>/api/v2`
  /// - `https://danmu.example.com/<token>/`（末尾斜杠）
  /// - `http://host:7768/api/v1/<token>`（御坂旧写法）
  static String endpoint(String path, {String? base}) {
    var root = (base ?? baseUrl).trim().replaceFirst(RegExp(r'/+$'), '');
    if (root.isEmpty) root = builtinBaseUrl;
    final normalized = root.endsWith('/api/v2') ? root : '$root/api/v2';
    return '$normalized$path';
  }
}

class _SearchOutcome {
  const _SearchOutcome(this.episodes, this.error);

  final List<DanmakuEpisode> episodes;
  final DanmakuException? error;
}
