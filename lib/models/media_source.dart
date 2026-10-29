import 'package:flutter/material.dart';

import 'media_item.dart';

class MediaSource {
  MediaSource({
    required this.id,
    required this.name,
    required this.address,
    required this.username,
    this.directory = '/',
    this.connected = false,
    this.lastSync = '尚未同步',
  });

  final String id;
  final String name;
  final String address;
  final String username;
  final String directory;
  final bool connected;
  final String lastSync;

  MediaSource copyWith({
    String? id,
    String? name,
    String? address,
    String? username,
    String? directory,
    bool? connected,
    String? lastSync,
  }) {
    return MediaSource(
      id: id ?? this.id,
      name: name ?? this.name,
      address: address ?? this.address,
      username: username ?? this.username,
      directory: directory ?? this.directory,
      connected: connected ?? this.connected,
      lastSync: lastSync ?? this.lastSync,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'address': address,
    'username': username,
    'directory': directory,
    'connected': connected,
    'lastSync': lastSync,
  };

  factory MediaSource.fromJson(Map<String, Object?> json) {
    return MediaSource(
      id: json['id']! as String,
      name: json['name']! as String,
      address: json['address']! as String,
      username: json['username'] as String? ?? '',
      directory: json['directory'] as String? ?? '/',
      connected: json['connected'] as bool? ?? false,
      lastSync: json['lastSync'] as String? ?? '尚未同步',
    );
  }

  static String newId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);
}

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
  );

  ScannedVideo copyWith({
    String? title,
    int? episodeCount,
    String? posterPath,
    String? summary,
    String? rating,
  }) => ScannedVideo(
    sourceId: sourceId,
    path: path,
    title: title ?? this.title,
    kind: kind,
    episodeCount: episodeCount ?? this.episodeCount,
    sizeBytes: sizeBytes,
    modified: modified,
    posterPath: posterPath ?? this.posterPath,
    summary: summary ?? this.summary,
    rating: rating ?? this.rating,
  );
}

/// 把扫描到的视频转成 UI 使用的 MediaItem，避免分类页关心文件细节。
MediaItem? toMediaItem(ScannedVideo video) {
  final subtitle = video.episodeCount > 1
      ? '共 ${video.episodeCount} 集'
      : _formatSize(video.sizeBytes);
  return MediaItem(
    title: video.title,
    subtitle: subtitle,
    year: video.modified == null ? '' : video.modified!.year.toString(),
    colors: _paletteFor(video.title),
    icon: _iconFor(video.kind),
    rating: video.rating,
    quality: video.episodeCount > 1 ? '${video.episodeCount} 集' : null,
    description: video.path,
    payload: video,
    posterPath: video.posterPath,
  );
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
