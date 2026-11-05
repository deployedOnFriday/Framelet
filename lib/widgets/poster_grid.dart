import 'package:flutter/material.dart';

import '../models/media_item.dart';
import 'poster_card.dart';

/// 统一的海报网格：按可用宽度计算等宽卡片，保证每一列都完整落在容器内。
class PosterGrid extends StatelessWidget {
  const PosterGrid({
    required this.items,
    this.shrinkWrap = false,
    this.physics,
    this.targetColumnWidth = 168,
    this.maxColumns = 7,
    this.crossAxisSpacing = 16,
    this.mainAxisSpacing = 22,
    super.key,
  });

  final List<MediaItem> items;
  final bool shrinkWrap;
  final ScrollPhysics? physics;

  /// 理想卡片宽度。实际宽度会随列数拉伸或压缩，但始终保持海报 2:3 比例。
  final double targetColumnWidth;
  final int maxColumns;
  final double crossAxisSpacing;
  final double mainAxisSpacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        if (!availableWidth.isFinite || availableWidth <= 0) {
          return const SizedBox.shrink();
        }
        final columns =
            ((availableWidth + crossAxisSpacing) /
                    (targetColumnWidth + crossAxisSpacing))
                .floor()
                .clamp(1, maxColumns);
        final cardWidth =
            (availableWidth - crossAxisSpacing * (columns - 1)) / columns;

        return GridView.builder(
          shrinkWrap: shrinkWrap,
          physics:
              physics ??
              (shrinkWrap ? const NeverScrollableScrollPhysics() : null),
          itemCount: items.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: crossAxisSpacing,
            mainAxisSpacing: mainAxisSpacing,
            mainAxisExtent: PosterCard.extentForWidth(cardWidth),
          ),
          itemBuilder: (context, index) =>
              PosterCard(item: items[index], width: cardWidth),
        );
      },
    );
  }
}
