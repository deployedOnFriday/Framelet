import 'package:flutter/material.dart';

import '../models/media_item.dart';
import 'mobile_poster_card.dart';

/// 手机端固定双列海报网格。
class MobilePosterGrid extends StatelessWidget {
  const MobilePosterGrid({
    required this.items,
    this.padding = const EdgeInsets.fromLTRB(20, 12, 20, 24),
    this.crossAxisSpacing = 14,
    this.mainAxisSpacing = 22,
    super.key,
  });

  final List<MediaItem> items;
  final EdgeInsets padding;
  final double crossAxisSpacing;
  final double mainAxisSpacing;

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth - padding.horizontal;
        if (!availableWidth.isFinite || availableWidth <= 0) {
          return const SizedBox.shrink();
        }
        const columns = 2;
        final cardWidth =
            (availableWidth - crossAxisSpacing * (columns - 1)) / columns;

        return GridView.builder(
          padding: padding,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          itemCount: items.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: crossAxisSpacing,
            mainAxisSpacing: mainAxisSpacing,
            mainAxisExtent: MobilePosterCard.extentForWidth(
              cardWidth,
              textScaler,
            ),
          ),
          itemBuilder: (context, index) => MobilePosterCard(item: items[index]),
        );
      },
    );
  }
}
