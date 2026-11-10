import 'package:flutter/material.dart';

import '../models/media_item.dart';
import 'tv_poster_card.dart';

/// 电视端海报网格：按可用宽度自动分列，卡片保持 2:3。
class TvPosterGrid extends StatelessWidget {
  const TvPosterGrid({
    required this.items,
    this.padding = const EdgeInsets.fromLTRB(40, 16, 40, 48),
    this.targetWidth = 260,
    this.crossAxisSpacing = 28,
    this.mainAxisSpacing = 34,
    this.controller,
    super.key,
  });

  final List<MediaItem> items;
  final EdgeInsets padding;
  final double targetWidth;
  final double crossAxisSpacing;
  final double mainAxisSpacing;
  final ScrollController? controller;

  /// 电视 10 尺界面：1920 宽内容区大约 5 列。
  static int columnsFor(
    double width, {
    double targetWidth = 260,
    double spacing = 28,
    int min = 2,
    int max = 7,
  }) {
    if (!width.isFinite || width <= 0) return min;
    return ((width + spacing) / (targetWidth + spacing)).floor().clamp(
      min,
      max,
    );
  }

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth - padding.horizontal;
        if (!availableWidth.isFinite || availableWidth <= 0) {
          return const SizedBox.shrink();
        }
        final columns = columnsFor(
          availableWidth,
          targetWidth: targetWidth,
          spacing: crossAxisSpacing,
        );
        final cardWidth =
            (availableWidth - crossAxisSpacing * (columns - 1)) / columns;

        return GridView.builder(
          controller: controller,
          padding: padding,
          itemCount: items.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: crossAxisSpacing,
            mainAxisSpacing: mainAxisSpacing,
            mainAxisExtent: TvPosterCard.extentForWidth(cardWidth, textScaler),
          ),
          itemBuilder: (context, index) =>
              TvPosterCard(item: items[index], width: cardWidth),
        );
      },
    );
  }
}
