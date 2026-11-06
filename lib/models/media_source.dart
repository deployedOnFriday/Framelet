import 'package:flutter/material.dart';

export 'cast_member.dart';
import 'cast_member.dart';
import 'media_item.dart';

enum MediaSourceKind { webdav, local }

class MediaSource {
  MediaSource({
    required this.id,
    required this.name,
    required this.address,
    required this.username,
    this.kind = MediaSourceKind.webdav,
    this.directory = '/',
    this.connected = false,
    this.lastSync = '尚未同步',
    this.enabled = true,
  });

  final String id;
  final String name;
  final MediaSourceKind kind;
  final String address;
  final String username;
  final String directory;
  final bool connected;
  final String lastSync;

  /// 「显示并刮削」开关：关闭后该源不参与海报墙展示与自动刮削，
  /// 已同步的数据保留，重新打开即恢复。
  final bool enabled;

  bool get isLocal => kind == MediaSourceKind.local;

  String get kindLabel => isLocal ? '本地目录' : 'WebDAV';

  String get location {
    if (isLocal) return address;
    final root = address.trim().replaceFirst(RegExp(r'/+$'), '');
    final folder = directory.trim();
    if (folder.isEmpty || folder == '/') return root;
    return '$root${folder.startsWith('/') ? folder : '/$folder'}';
  }

  MediaSource copyWith({
    String? id,
    String? name,
    MediaSourceKind? kind,
    String? address,
    String? username,
    String? directory,
    bool? connected,
    String? lastSync,
    bool? enabled,
  }) {
    return MediaSource(
      id: id ?? this.id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      address: address ?? this.address,
      username: username ?? this.username,
      directory: directory ?? this.directory,
      connected: connected ?? this.connected,
      lastSync: lastSync ?? this.lastSync,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'address': address,
    'username': username,
    'directory': directory,
    'connected': connected,
    'lastSync': lastSync,
    'enabled': enabled,
  };

  factory MediaSource.fromJson(Map<String, Object?> json) {
    final kindName = json['kind'] as String?;
    final kind = MediaSourceKind.values
        .where((item) => item.name == kindName)
        .firstOrNull;
    return MediaSource(
      id: json['id']! as String,
      name: json['name']! as String,
      kind: kind ?? MediaSourceKind.webdav,
      address: json['address']! as String,
      username: json['username'] as String? ?? '',
      directory: json['directory'] as String? ?? '/',
      connected: json['connected'] as bool? ?? false,
      lastSync: json['lastSync'] as String? ?? '尚未同步',
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  static String newId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);
}

/// 演员信息：TMDB credits 数据的最小化展示模型。
/// 视频文件分类，与左侧导航一一对应。
enum MediaKind { movie, series, anime, variety }

class ScannedVideo {
  const ScannedVideo({
    required this.sourceId,
    required this.path,
    required this.title,
    required this.kind,
    this.episodeCount = 1,
    this.sizeBytes = 0,
    this.modified,
    this.posterPath,
    this.summary,
    this.rating,
    this.backdropPath,
    this.genres = const [],
    this.cast = const [],
    this.releaseDate,
    this.runtimeSec,
    this.stillPath,
    this.episodeTitle,
    this.tmdbId,
    this.tmdbTitle,
  });

  final String sourceId;
  final String path;
  final String title;
  final MediaKind kind;
  final int episodeCount;
  final int sizeBytes;
  final DateTime? modified;

  /// 刮削得到的本地海报文件路径。
  final String? posterPath;

  /// 刮削得到的剧情简介。
  final String? summary;

  /// 评分（0-10 文本，例如 "8.6"）。
  final String? rating;

  /// 刮削得到的高清背景图文件路径。
  final String? backdropPath;

  /// 类型标签，例如 ['剧情', '悬疑']。
  final List<String> genres;

  /// 主要演员与导演。
  final List<CastMember> cast;

  /// 上映/首播日期，格式 yyyy-MM-dd。
  final String? releaseDate;

  /// TMDB 提供的影片时长（秒）。
  final double? runtimeSec;

  /// 单集缩略图文件路径。
  final String? stillPath;

  /// TMDB 单集标题（刮削得到）。
  final String? episodeTitle;

  /// 所属剧集的 TMDB 条目 ID，多季关联与刮削去重用。
  final int? tmdbId;

  /// TMDB 官方剧名（聚合展示优先用它）。
  final String? tmdbTitle;

  /// 是否已刮削（有海报或已匹配 TMDB）。未刮条目仍会以渐变封面展示。
  bool get isScraped => posterPath != null || tmdbId != null;

  Map<String, Object?> toJson() => {
    'sourceId': sourceId,
    'path': path,
    'title': title,
    'kind': kind.index,
    'episodeCount': episodeCount,
    'sizeBytes': sizeBytes,
    'modified': modified?.millisecondsSinceEpoch,
    'posterPath': posterPath,
    'summary': summary,
    'rating': rating,
    'backdropPath': backdropPath,
    'genres': genres,
    'cast': cast.map((member) => member.toJson()).toList(),
    'releaseDate': releaseDate,
    'runtimeSec': runtimeSec,
    'stillPath': stillPath,
    'episodeTitle': episodeTitle,
    'tmdbId': tmdbId,
    'tmdbTitle': tmdbTitle,
  };

  factory ScannedVideo.fromJson(Map<String, Object?> json) => ScannedVideo(
    sourceId: json['sourceId']! as String,
    path: json['path']! as String,
    title: json['title']! as String,
    kind: MediaKind.values[json['kind']! as int],
    episodeCount: json['episodeCount'] as int? ?? 1,
    sizeBytes: json['sizeBytes'] as int? ?? 0,
    modified: json['modified'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(json['modified']! as int),
    posterPath: json['posterPath'] as String?,
    summary: json['summary'] as String?,
    rating: json['rating'] as String?,
    backdropPath: json['backdropPath'] as String?,
    genres: (json['genres'] as List<Object?>? ?? const [])
        .whereType<String>()
        .toList(),
    cast: (json['cast'] as List<Object?>? ?? const [])
        .whereType<Map>()
        .map((member) => CastMember.fromJson(member.cast<String, Object?>()))
        .toList(),
    releaseDate: json['releaseDate'] as String?,
    runtimeSec: (json['runtimeSec'] as num?)?.toDouble(),
    stillPath: json['stillPath'] as String?,
    episodeTitle: json['episodeTitle'] as String?,
    tmdbId: (json['tmdbId'] as num?)?.toInt(),
    tmdbTitle: json['tmdbTitle'] as String?,
  );

  ScannedVideo copyWith({
    String? title,
    MediaKind? kind,
    int? episodeCount,
    String? posterPath,
    String? summary,
    String? rating,
    String? backdropPath,
    List<String>? genres,
    List<CastMember>? cast,
    String? releaseDate,
    double? runtimeSec,
    String? stillPath,
    String? episodeTitle,
    int? tmdbId,
    String? tmdbTitle,
    bool clearPoster = false,
    bool clearBackdrop = false,
    bool clearStill = false,
    bool clearEpisodeTitle = false,
    bool clearTmdbId = false,
  }) => ScannedVideo(
    sourceId: sourceId,
    path: path,
    title: title ?? this.title,
    kind: kind ?? this.kind,
    episodeCount: episodeCount ?? this.episodeCount,
    sizeBytes: sizeBytes,
    modified: modified,
    posterPath: clearPoster ? null : (posterPath ?? this.posterPath),
    summary: summary ?? this.summary,
    rating: rating ?? this.rating,
    backdropPath: clearBackdrop ? null : (backdropPath ?? this.backdropPath),
    genres: genres ?? this.genres,
    cast: cast ?? this.cast,
    releaseDate: releaseDate ?? this.releaseDate,
    runtimeSec: runtimeSec ?? this.runtimeSec,
    stillPath: clearStill ? null : (stillPath ?? this.stillPath),
    episodeTitle: clearEpisodeTitle
        ? null
        : (episodeTitle ?? this.episodeTitle),
    tmdbId: clearTmdbId ? null : (tmdbId ?? this.tmdbId),
    tmdbTitle: tmdbTitle ?? this.tmdbTitle,
  );

  /// 清空所有图片文件路径，保留 TMDB 元数据，供「清除缓存」使用。
  ScannedVideo withoutImages() => ScannedVideo(
    sourceId: sourceId,
    path: path,
    title: title,
    kind: kind,
    episodeCount: episodeCount,
    sizeBytes: sizeBytes,
    modified: modified,
    summary: summary,
    rating: rating,
    genres: genres,
    cast: cast,
    releaseDate: releaseDate,
    runtimeSec: runtimeSec,
    episodeTitle: episodeTitle,
    tmdbId: tmdbId,
    tmdbTitle: tmdbTitle,
  );
}

/// 把扫描到的视频转成 UI 使用的 MediaItem，避免分类页关心文件细节。
MediaItem? toMediaItem(ScannedVideo video) {
  final subtitle = video.episodeCount > 1
      ? '共 ${video.episodeCount} 集'
      : _formatSize(video.sizeBytes);
  final summary = video.summary?.trim() ?? '';
  final tmdbTitle = video.tmdbTitle?.trim() ?? '';
  return MediaItem(
    // 已刮削成功的条目用 TMDB 官方名，避免目录名/清洗文件名上墙；
    // 未刮削的保持原名。
    title: tmdbTitle.isNotEmpty ? tmdbTitle : video.title,
    subtitle: subtitle,
    // 与详情页 _yearOf 同优先级：TMDB 上映/首播年份优先，
    // 未刮削成功才回退文件修改时间（那只是入库时间，不是影片时间）。
    year: _yearOf(video),
    colors: _paletteFor(video.title),
    icon: _iconFor(video.kind),
    rating: video.rating,
    quality: video.episodeCount > 1 ? '${video.episodeCount} 集' : null,
    description: summary.isEmpty ? subtitle : summary,
    payload: video,
    posterPath: video.posterPath,
    backdropPath: video.backdropPath,
  );
}

/// 影片年份：优先 TMDB 上映/首播年份，刮削失败回退文件修改时间。
String _yearOf(ScannedVideo video) {
  final release = video.releaseDate;
  if (release != null && release.trim().length >= 4) {
    return release.trim().substring(0, 4);
  }
  final modified = video.modified;
  return modified == null ? '' : modified.year.toString();
}

String _formatSize(int bytes) {
  if (bytes <= 0) return '未知大小';
  final gb = bytes / (1024 * 1024 * 1024);
  if (gb >= 1) return '${gb.toStringAsFixed(1)} GB';
  final mb = bytes / (1024 * 1024);
  return '${mb.toStringAsFixed(0)} MB';
}

IconData _iconFor(MediaKind kind) => switch (kind) {
  MediaKind.movie => Icons.movie_outlined,
  MediaKind.series => Icons.live_tv_outlined,
  MediaKind.anime => Icons.animation_outlined,
  MediaKind.variety => Icons.emoji_events_outlined,
};

const _palettes = <List<Color>>[
  [Color(0xFF3D6B5C), Color(0xFF7FB89F)],
  [Color(0xFF4A5E85), Color(0xFF8FA8D0)],
  [Color(0xFF7A5C4A), Color(0xFFC89F7F)],
  [Color(0xFF5C4A7A), Color(0xFFA88FC8)],
  [Color(0xFF4A7A6E), Color(0xFF8FC8B4)],
  [Color(0xFF7A6E4A), Color(0xFFC8B48F)],
];

List<Color> _paletteFor(String title) {
  var hash = 0;
  for (final code in title.codeUnits) {
    hash = (hash * 31 + code) & 0x7FFFFFFF;
  }
  return _palettes[hash % _palettes.length];
}
