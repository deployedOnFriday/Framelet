import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../models/media_item.dart';
import '../models/media_source.dart';
import '../pages/detail_page.dart';
import 'media_artwork.dart';

/// 手机端海报卡：2:3 圆角封面 + 评分胶囊 + 两行标题 + 副信息。
class MobilePosterCard extends StatelessWidget {
  const MobilePosterCard({required this.item, super.key});

  final MediaItem item;

  static const double _titleGap = 9;
  static const double _metaGap = 4;
  static const double _bottomInset = 2;
  static const double _titleFontSize = 14.5;
  static const double _metaFontSize = 12;

  /// 卡片文字区高度随系统字体缩放，避免大字号下网格溢出。
  static double extentForWidth(double width, TextScaler textScaler) {
    final titleLine = textScaler.scale(_titleFontSize) * 1.32;
    final metaLine = textScaler.scale(_metaFontSize) * 1.3;
    return width * 1.5 +
        _titleGap +
        titleLine * 2 +
        _metaGap +
        metaLine +
        _bottomInset;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final textScaler = MediaQuery.textScalerOf(context);
    final titleHeight = textScaler.scale(_titleFontSize) * 1.32 * 2;
    final metaHeight = textScaler.scale(_metaFontSize) * 1.3;
    final year = item.year.trim();
    final meta = year.isEmpty ? item.subtitle : '$year · ${item.subtitle}';

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openDetail(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: Stack(
              fit: StackFit.expand,
              children: [
                MediaArtwork(
                  item: item,
                  borderRadius: 14,
                  fit: BoxFit.cover,
                  showRating: false,
                ),
                if (item.rating != null)
                  Positioned(
                    left: 8,
                    top: 8,
                    child: _RatingPill(rating: item.rating!),
                  ),
              ],
            ),
          ),
          const SizedBox(height: _titleGap),
          SizedBox(
            height: titleHeight,
            child: Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _titleFontSize,
                height: 1.32,
                fontWeight: FontWeight.w600,
                color: colors.text,
              ),
            ),
          ),
          const SizedBox(height: _metaGap),
          SizedBox(
            height: metaHeight,
            child: Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _metaFontSize,
                height: 1.3,
                color: colors.muted,
              ),
            ),
          ),
          const SizedBox(height: _bottomInset),
        ],
      ),
    );
  }

  void _openDetail(BuildContext context) {
    final payload = item.payload;
    if (payload is ScannedVideo) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => DetailPage(video: payload)),
      );
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text('「${item.title}」是演示内容，去设置里添加你的媒体源吧')),
      );
  }
}

class _RatingPill extends StatelessWidget {
  const _RatingPill({required this.rating});

  final String rating;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.52),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, size: 12, color: Color(0xFFFFD166)),
          const SizedBox(width: 3),
          Text(
            rating,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              height: 1,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
