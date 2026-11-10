import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../models/media_item.dart';
import '../models/media_source.dart';
import '../pages/detail_page.dart';
import 'media_artwork.dart';

/// 电视端海报卡：大字号、明显的遥控焦点框，2:3 海报。
class TvPosterCard extends StatefulWidget {
  const TvPosterCard({
    required this.item,
    this.width = 280,
    this.onTap,
    super.key,
  });

  final MediaItem item;
  final double width;
  final VoidCallback? onTap;

  static const double titleFontSize = 20;
  static const double metaFontSize = 15;
  static const double _titleGap = 14;
  static const double _metaGap = 6;
  static const double _bottomInset = 4;

  /// 卡片高度随字号缩放，避免系统大字号时溢出。
  static double extentForWidth(double width, TextScaler textScaler) {
    final titleLine = textScaler.scale(titleFontSize) * 1.3;
    final metaLine = textScaler.scale(metaFontSize) * 1.3;
    return width * 1.5 +
        _titleGap +
        titleLine * 2 +
        _metaGap +
        metaLine +
        _bottomInset;
  }

  @override
  State<TvPosterCard> createState() => _TvPosterCardState();
}

class _TvPosterCardState extends State<TvPosterCard> {
  bool _focused = false;

  static const _duration = Duration(milliseconds: 160);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final textScaler = MediaQuery.textScalerOf(context);
    final item = widget.item;
    final meta = item.year.trim().isEmpty
        ? item.subtitle
        : '${item.year} · ${item.subtitle}';

    return AnimatedScale(
      scale: _focused ? 1.04 : 1,
      duration: _duration,
      curve: Curves.easeOutCubic,
      child: AnimatedContainer(
        duration: _duration,
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _focused ? colors.primary : Colors.transparent,
            width: 3,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: _focused ? 0.45 : 0),
              blurRadius: 26,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        padding: const EdgeInsets.all(3),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            focusColor: Colors.transparent,
            hoverColor: Colors.transparent,
            onFocusChange: (value) {
              if (_focused != value) setState(() => _focused = value);
            },
            onTap: widget.onTap ?? () => _openDetail(context),
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
                        borderRadius: 16,
                        fit: BoxFit.cover,
                        showRating: false,
                      ),
                      if (item.rating != null)
                        Positioned(
                          left: 10,
                          top: 10,
                          child: _RatingPill(rating: item.rating!),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: TvPosterCard._titleGap),
                SizedBox(
                  height:
                      textScaler.scale(TvPosterCard.titleFontSize) * 1.3 * 2,
                  child: Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: TvPosterCard.titleFontSize,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                      color: _focused ? colors.primary : colors.text,
                    ),
                  ),
                ),
                const SizedBox(height: TvPosterCard._metaGap),
                SizedBox(
                  height: textScaler.scale(TvPosterCard.metaFontSize) * 1.3,
                  child: Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: TvPosterCard.metaFontSize,
                      height: 1.3,
                      color: colors.muted,
                    ),
                  ),
                ),
                const SizedBox(height: TvPosterCard._bottomInset),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openDetail(BuildContext context) {
    final payload = widget.item.payload;
    if (payload is ScannedVideo) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => DetailPage(video: payload)),
      );
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('演示内容，去设置里添加你的媒体源吧')));
  }
}

class _RatingPill extends StatelessWidget {
  const _RatingPill({required this.rating});

  final String rating;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, size: 16, color: Color(0xFFFFD166)),
          const SizedBox(width: 4),
          Text(
            rating,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              height: 1,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
