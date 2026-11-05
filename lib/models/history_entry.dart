import 'media_source.dart';

/// 一条播放记录：最近播放列表与续播进度的最小单元。
class HistoryEntry {
  const HistoryEntry({
    required this.sourceId,
    required this.path,
    required this.title,
    required this.kind,
    this.positionSec = 0,
    this.durationSec = 0,
    this.thumbnailPath,
    required this.updatedAtMs,
  });

  final String sourceId;
  final String path;
  final String title;
  final MediaKind kind;
  final double positionSec;
  final double durationSec;
  final String? thumbnailPath;
  final int updatedAtMs;

  double get progress {
    if (durationSec <= 0) return 0;
    return (positionSec / durationSec).clamp(0.0, 1.0);
  }

  bool get finished => progress >= 0.98;

  Map<String, Object?> toJson() => {
    'sourceId': sourceId,
    'path': path,
    'title': title,
    'kind': kind.index,
    'positionSec': positionSec,
    'durationSec': durationSec,
    'thumbnailPath': thumbnailPath,
    'updatedAtMs': updatedAtMs,
  };

  factory HistoryEntry.fromJson(Map<String, Object?> json) => HistoryEntry(
    sourceId: json['sourceId']! as String,
    path: json['path']! as String,
    title: json['title']! as String,
    kind: MediaKind.values[json['kind']! as int],
    positionSec: (json['positionSec'] as num?)?.toDouble() ?? 0,
    durationSec: (json['durationSec'] as num?)?.toDouble() ?? 0,
    thumbnailPath: json['thumbnailPath'] as String?,
    updatedAtMs: json['updatedAtMs']! as int,
  );

  HistoryEntry copyWith({
    double? positionSec,
    double? durationSec,
    String? thumbnailPath,
    int? updatedAtMs,
  }) => HistoryEntry(
    sourceId: sourceId,
    path: path,
    title: title,
    kind: kind,
    positionSec: positionSec ?? this.positionSec,
    durationSec: durationSec ?? this.durationSec,
    thumbnailPath: thumbnailPath ?? this.thumbnailPath,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );
}
