import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

class DanmakuEpisode {
  const DanmakuEpisode({
    required this.animeTitle,
    required this.episodeTitle,
    required this.episodeId,
  });

  final String animeTitle;
  final String episodeTitle;
  final int episodeId;

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

enum DanmakuProvider { dandanplay, custom }

/// 弹弹play 开放弹幕网络 API v2。
///
/// 注意：弹弹play 提供的是弹幕，不提供 .srt/.ass 字幕文件。
class DanmakuService {
  DanmakuService._();

  static const officialBaseUrl = 'https://api.dandanplay.net';
  static DanmakuProvider provider = DanmakuProvider.dandanplay;
  static String baseUrl = officialBaseUrl;
  static String? appId;
  static String? appSecret;
  static String? proxyAddress;

  static bool get configured => switch (provider) {
    DanmakuProvider.dandanplay =>
      (appId ?? '').trim().isNotEmpty &&
          (appSecret ?? '').trim().isNotEmpty,
    DanmakuProvider.custom => baseUrl.trim().isNotEmpty,
  };

  static String get providerLabel =>
      provider == DanmakuProvider.dandanplay ? 'DanDanPlay' : '自定义 / 御坂';

  static final Map<int, List<DanmakuComment>> _cache = {};

  /// 切换弹幕服务后清空缓存，避免不同服务使用相同 episodeId 时串弹幕。
  static void clearCache() => _cache.clear();

  static Future<List<DanmakuEpisode>> searchEpisodes({
    required String anime,
    required int episode,
  }) async {
    final uri = Uri.parse(_endpoint('/search/episodes')).replace(
      queryParameters: {
        'anime': anime,
        'episode': episode.toString(),
      },
    );
    final data = await _getJson(uri);
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
          ),
        );
      }
    }
    return result;
  }

  static Future<List<DanmakuComment>> comments(int episodeId) async {
    final cached = _cache[episodeId];
    if (cached != null) return cached;
    final uri = Uri.parse(
      _endpoint('/comment/$episodeId'),
    ).replace(queryParameters: {'withRelated': 'true'});
    final data = await _getJson(uri);
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
        DanmakuComment(
          timeSec: time,
          mode: mode,
          color: color,
          text: text,
        ),
      );
    }
    result.sort((a, b) => a.timeSec.compareTo(b.timeSec));
    _cache[episodeId] = result;
    return result;
  }

  static Future<Map<String, Object?>> _getJson(Uri uri) async {
    if (!configured) {
      throw DanmakuException(
        provider == DanmakuProvider.dandanplay
            ? '尚未配置弹弹play AppId/AppSecret，请到 设置 → 弹幕 填写'
            : '尚未配置自定义弹幕接口地址，请到 设置 → 弹幕 填写',
      );
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = 'Framelet/0.1';
    final proxy = (proxyAddress ?? '').trim();
    if (proxy.isNotEmpty) {
      client.findProxy = (_) => 'PROXY $proxy';
    }
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (provider == DanmakuProvider.dandanplay) {
        final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final path = uri.path;
        final signature = base64Encode(
          sha256
              .convert(utf8.encode('$appId$timestamp$path$appSecret'))
              .bytes,
        );
        request.headers
          ..set('X-AppId', appId!.trim())
          ..set('X-Timestamp', timestamp.toString())
          ..set('X-Signature', signature);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        final detail = response.headers.value('X-Error-Message');
        throw DanmakuException(
          '弹弹play 请求失败（HTTP ${response.statusCode}）'
          '${detail == null ? '' : '：$detail'}',
        );
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?>) {
        throw const DanmakuException('弹弹play 返回格式异常');
      }
      if (decoded['success'] == false) {
        throw DanmakuException(
          decoded['errorMessage'] as String? ?? '弹弹play 请求失败',
        );
      }
      return decoded;
    } on DanmakuException {
      rethrow;
    } on TimeoutException {
      throw const DanmakuException('弹弹play 请求超时');
    } catch (error) {
      throw DanmakuException('弹弹play 请求失败：$error');
    } finally {
      client.close(force: true);
    }
  }

  /// 兼容两种填法：
  /// - https://api.dandanplay.net
  /// - `http://host:7768/api/v1/<token>`
  /// - `http://host:7768/api/v1/<token>/api/v2`
  static String _endpoint(String path) {
    var root = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    if (root.isEmpty) root = officialBaseUrl;
    final normalized = root.endsWith('/api/v2') ? root : '$root/api/v2';
    return '$normalized$path';
  }
}
