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
}
