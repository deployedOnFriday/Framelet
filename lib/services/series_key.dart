import '../models/media_source.dart';
import 'media_library.dart';

/// 「一部作品」的稳定身份，用于按剧集记忆的设置（字幕、片头片尾等）。
///
/// 优先 TMDB ID：同一部剧跨季、跨目录都稳定；没有刮削结果时退回
/// 「媒体源 + 规范化剧名」，避免同一部剧因目录改名而丢设置。
class SeriesKey {
  SeriesKey._();

  static String of(ScannedVideo video) {
    final library = MediaLibrary.instance;
    final aggregated = library.resolveAggregated(video);
    final tmdbId = aggregated.tmdbId ?? video.tmdbId;
    if (tmdbId != null) return '${video.sourceId}|tmdb:$tmdbId';
    final official = MediaLibrary.officialTitleOf(aggregated);
    final title = MediaLibrary.normalizeSeriesTitle(
      (official ?? aggregated.title).trim(),
    );
    return '${video.sourceId}|title:${title.toLowerCase()}';
  }
}
