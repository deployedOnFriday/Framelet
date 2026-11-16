import 'dart:convert';
import 'dart:io';

import '../models/media_source.dart';
import 'media_library.dart';
import 'proxy_resolver.dart';
import 'skip_marks.dart';

/// 自动查询片头片尾时间。
///
/// 数据源是 TheIntroDB（社区维护的片头/片尾时间库，按 TMDB ID 索引）：
/// `GET https://api.theintrodb.org/v2/media?tmdb_id=..&season=..&episode=..`
/// 返回 `intro`（片头）与 `credits`（片尾）区间，单位毫秒。
///
/// 查到的结果按「TMDB + 季 + 集」缓存到本地，之后离线也能用；
/// 用户手动标记的片头片尾优先于自动结果。
class SkipMarksService {
  SkipMarksService._();

  static const _host = 'api.theintrodb.org';

  /// 与刮削共用代理设置（设置 → 刮削 → 代理）。
  static String? proxyAddress;

  /// 最近一次失败原因，供播放器日志使用。
  static String? lastError;

  static String cacheKeyFor(ScannedVideo video) {
    final library = MediaLibrary.instance;
    final aggregated = library.resolveAggregated(video);
    final tmdbId = aggregated.tmdbId ?? video.tmdbId;
    if (tmdbId == null) return '';
    if (video.kind == MediaKind.movie) {
      return SkipMarksStore.autoKeyOf(tmdbId: tmdbId, season: 0, episode: 0);
    }
    final season = MediaLibrary.seasonOf(video);
    final episode = MediaLibrary.episodeNumberOfVideo(video) ?? 1;
    return SkipMarksStore.autoKeyOf(
      tmdbId: tmdbId,
      season: season,
      episode: episode,
    );
  }

  /// 查询某一集的片头片尾；没有命中或网络失败时返回 null。
  static Future<SeriesSkipMarks?> fetch(ScannedVideo video) async {
    final library = MediaLibrary.instance;
    final aggregated = library.resolveAggregated(video);
    final tmdbId = aggregated.tmdbId ?? video.tmdbId;
    if (tmdbId == null) {
      lastError = '没有 TMDB ID';
      return null;
    }
    final isMovie = video.kind == MediaKind.movie;
    final uri = Uri.https(_host, '/v2/media', {
      'tmdb_id': '$tmdbId',
      if (!isMovie) 'season': '${MediaLibrary.seasonOf(video)}',
      if (!isMovie)
        'episode': '${MediaLibrary.episodeNumberOfVideo(video) ?? 1}',
    });
    final body = await _get(uri);
    if (body == null) return null;
    final marks = parseSegments(body);
    if (marks == null) lastError = '该集没有片头片尾数据';
    return marks;
  }

  /// 解析 TheIntroDB 的返回体，便于单测。
  static SeriesSkipMarks? parseSegments(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;

    /// 取第一个有效区间，返回（开始秒, 结束秒）。
    (double?, double?)? first(Object? raw) {
      if (raw is! List) return null;
      for (final item in raw) {
        if (item is! Map) continue;
        final startMs = item['start_ms'];
        final endMs = item['end_ms'];
        double? seconds(Object? value) {
          if (value is! num) return null;
          final result = value.toDouble() / 1000;
          return result.isFinite && result >= 0 ? result : null;
        }

        final start = seconds(startMs);
        final end = seconds(endMs);
        if (start == null && end == null) continue;
        return (start, end);
      }
      return null;
    }

    final intro = first(decoded['intro']);
    final credits = first(decoded['credits']);
    final marks = SeriesSkipMarks(
      introStartSec: intro?.$1,
      introEndSec: intro?.$2,
      outroStartSec: credits?.$1,
    );
    return marks.isEmpty ? null : marks;
  }

  static Future<String?> _get(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..userAgent = 'Framelet/0.1';
    final proxy = ProxyResolver.normalize(proxyAddress ?? '');
    if (proxy.isNotEmpty) {
      client.findProxy = (_) => 'PROXY $proxy';
    }
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 12));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        lastError = 'HTTP ${response.statusCode}';
        return null;
      }
      return body;
    } catch (error) {
      lastError = '$error';
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
