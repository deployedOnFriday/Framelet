import 'package:flutter/material.dart';

class MediaItem {
  const MediaItem({
    required this.title,
    required this.subtitle,
    required this.year,
    required this.colors,
    required this.icon,
    this.rating,
    this.quality,
    this.progress = 0,
    this.description = '',
    this.payload,
    this.posterPath,
  });

  final String title;
  final String subtitle;
  final String year;
  final List<Color> colors;
  final IconData icon;
  final String? rating;
  final String? quality;
  final double progress;
  final String description;

  /// 刮削得到的本地海报文件路径；为空时使用渐变封面。
  final String? posterPath;

  /// 任意关联数据：真实媒体条目时是 ScannedVideo，播放历史时是 HistoryEntry。
  final Object? payload;
}
