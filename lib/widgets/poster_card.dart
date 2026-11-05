import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../models/media_item.dart';
import '../models/media_source.dart';
import '../pages/detail_page.dart';
import 'media_artwork.dart';

class PosterCard extends StatefulWidget {
  const PosterCard({required this.item, this.width = 148, super.key});

  final MediaItem item;
  final double width;

  static const double _titleGap = 9;
  static const double _titleHeight = 19;
  static const double _metaGap = 3;
  static const double _metaHeight = 15;
  static const double _bottomInset = 2;

  /// 卡片总高度：2:3 海报 + 固定高度的标题区。
  static double extentForWidth(double width) =>
      width * 1.5 +
      _titleGap +
      _titleHeight +
      _metaGap +
      _metaHeight +
      _bottomInset;

  @override
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  bool _hovered = false;

  static const _duration = Duration(milliseconds: 220);

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return SizedBox(
      width: widget.width,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child:           InkWell(
          onTap: () => _openDetail(context),
          borderRadius: BorderRadius.circular(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 海报区用 Expanded 占满 cell 高度减去文字区的剩余空间。
              // 不能写死 height: width * 1.5——SliverGrid relayout 时
              // 只改约束不重建 widget，侧栏展开动画中列数突变会导致
              // 旧 width 参数与新 cell 约束错位而逐帧溢出（黄黑条纹）。
              Expanded(
                child: AnimatedScale(
                  scale: _hovered ? 1.035 : 1,
                  duration: _duration,
                  curve: Curves.easeOutCubic,
                  child: AnimatedContainer(
                    duration: _duration,
                    curve: Curves.easeOutCubic,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF0F172A)
                              .withValues(alpha: _hovered ? 0.22 : 0),
                          blurRadius: _hovered ? 20 : 0,
                          offset: Offset(0, _hovered ? 10 : 0),
                        ),
                      ],
                    ),
                    // 完整显示整张海报；比例不符时由底层渐变补边，而不是裁切。
                    child: MediaArtwork(
                      item: item,
                      showQuality: true,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: PosterCard._titleGap),
              SizedBox(
                height: PosterCard._titleHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: AnimatedDefaultTextStyle(
                    duration: _duration,
                    curve: Curves.easeOutCubic,
                    style:
                        (Theme.of(context).textTheme.titleMedium ??
                                const TextStyle())
                            .copyWith(
                              height: 1.15,
                              color: _hovered
                                  ? context.colors.primary
                                  : context.colors.text,
                            ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: PosterCard._metaGap),
              SizedBox(
                height: PosterCard._metaHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${item.year} · ${item.subtitle}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          (Theme.of(context).textTheme.bodySmall ??
                                  const TextStyle())
                              .copyWith(height: 1.1),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: PosterCard._bottomInset),
            ],
          ),
        ),
      ),
    );
  }

  void _openDetail(BuildContext context) {
    final item = widget.item;
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
