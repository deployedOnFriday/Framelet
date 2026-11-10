import 'dart:io';

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../core/utils/decode_width.dart';
import '../models/media_item.dart';

class BannerCarousel extends StatelessWidget {
  const BannerCarousel({
    required this.items,
    required this.controller,
    required this.index,
    required this.onPageChanged,
    this.onPlay,
    this.onShowDetails,
    this.large = false,
    super.key,
  });

  final List<MediaItem> items;
  final PageController controller;
  final int index;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<MediaItem>? onPlay;
  final ValueChanged<MediaItem>? onShowDetails;

  /// 电视端 10 尺界面：更大的横幅、字号与按钮。
  final bool large;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 宽银幕比例铺满内容区，高度设上限，避免首屏被横幅占满。
        final width = constraints.maxWidth;
        final height = (width * 9 / 21)
            .clamp(large ? 460.0 : 320.0, large ? 620.0 : 430.0)
            .toDouble();
        return Align(
          alignment: Alignment.center,
          child: SizedBox(
            width: width,
            height: height,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  PageView.builder(
                    controller: controller,
                    itemCount: items.length,
                    onPageChanged: onPageChanged,
                    itemBuilder: (context, itemIndex) => _BannerSlide(
                      item: items[itemIndex],
                      onPlay: onPlay,
                      onShowDetails: onShowDetails,
                      large: large,
                    ),
                  ),
                  Positioned(
                    right: 18,
                    bottom: 14,
                    child: Row(
                      children: [
                        _CarouselButton(
                          icon: Icons.chevron_left_rounded,
                          tooltip: '上一张',
                          large: large,
                          onTap: () => _goTo(index - 1),
                        ),
                        const SizedBox(width: 12),
                        for (var i = 0; i < items.length; i++)
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            width: i == index
                                ? (large ? 28 : 22)
                                : (large ? 9 : 7),
                            height: large ? 9 : 7,
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(
                                alpha: i == index ? 0.95 : 0.45,
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        const SizedBox(width: 12),
                        _CarouselButton(
                          icon: Icons.chevron_right_rounded,
                          tooltip: '下一张',
                          large: large,
                          onTap: () => _goTo(index + 1),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _goTo(int page) {
    final target = (page + items.length) % items.length;
    controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }
}

class _BannerSlide extends StatelessWidget {
  const _BannerSlide({
    required this.item,
    this.onPlay,
    this.onShowDetails,
    this.large = false,
  });

  final MediaItem item;
  final ValueChanged<MediaItem>? onPlay;
  final ValueChanged<MediaItem>? onShowDetails;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final image = item.backdropPath ?? item.posterPath;
    final meta = [
      if (item.rating?.isNotEmpty ?? false) '★ ${item.rating}',
      if (item.year.isNotEmpty) item.year,
      if (item.quality?.isNotEmpty ?? false) item.quality! else item.subtitle,
    ].where((value) => value.isNotEmpty).join('  ·  ');
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: item.colors,
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 背景：铺满横幅，上下做适度裁切。
          // 不做 existsSync 预检（build 内同步 IO 会掉帧），
          // 文件缺失时 errorBuilder 透出底层渐变；背景图很大，限宽解码。
          if (image != null) ...[
            Positioned.fill(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
                  // 档位化解码宽度：布局微变（如侧栏展开动画）不触发重新解码
                  final cacheWidth = decodeCacheWidth(
                    constraints.maxWidth,
                    dpr,
                    step: 96,
                    min: 192,
                    max: 2400,
                  );
                  return Image.file(
                    File(image),
                    fit: BoxFit.cover,
                    cacheWidth: cacheWidth,
                    // 略偏上，裁切时优先保留人物面部。
                    alignment: const Alignment(0, -0.15),
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  );
                },
              ),
            ),
            // 左侧文字区域的渐隐保护。
            const Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      stops: [0, 0.46, 0.68],
                      colors: [
                        Color(0xCC000000),
                        Color(0x66000000),
                        Color(0x00000000),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
          Padding(
            padding: large
                ? const EdgeInsets.fromLTRB(48, 34, 48, 30)
                : const EdgeInsets.fromLTRB(32, 24, 32, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: large ? 12 : 9,
                    vertical: large ? 6 : 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.32),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.16),
                    ),
                  ),
                  child: Text(
                    '今日推荐',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: large ? 13.5 : 11,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                SizedBox(height: large ? 14 : 10),
                Text(
                  item.title,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: large ? 46 : 32,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                    shadows: [
                      Shadow(
                        color: Color(0xCC000000),
                        blurRadius: 18,
                        offset: Offset(0, 3),
                      ),
                      Shadow(
                        color: Color(0x99000000),
                        blurRadius: 5,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                ),
                if (meta.isNotEmpty) ...[
                  SizedBox(height: large ? 10 : 7),
                  Text(
                    meta,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.92),
                      fontSize: large ? 17 : 12.5,
                      fontWeight: FontWeight.w600,
                      shadows: const [
                        Shadow(
                          color: Color(0x99000000),
                          blurRadius: 10,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ],
                SizedBox(height: large ? 11 : 8),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: large ? 760 : 560),
                  child: Text(
                    item.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.94),
                      fontSize: large ? 17.5 : 14,
                      fontWeight: FontWeight.w500,
                      height: 1.5,
                      shadows: const [
                        Shadow(
                          color: Color(0x99000000),
                          blurRadius: 10,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                Row(
                  children: [
                    FilledButton.icon(
                      key: const ValueKey('featured-play'),
                      onPressed: onPlay == null ? null : () => onPlay!(item),
                      icon: Icon(
                        Icons.play_arrow_rounded,
                        size: large ? 24 : 18,
                      ),
                      label: Text(
                        '立即播放',
                        style: TextStyle(fontSize: large ? 17 : 14),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: context.colors.accent,
                        padding: EdgeInsets.symmetric(
                          horizontal: large ? 26 : 18,
                          vertical: large ? 18 : 11,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    TextButton(
                      onPressed: onShowDetails == null
                          ? null
                          : () => onShowDetails!(item),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        backgroundColor: Colors.black.withValues(alpha: 0.22),
                        padding: EdgeInsets.symmetric(
                          horizontal: large ? 22 : 14,
                          vertical: large ? 17 : 10,
                        ),
                      ),
                      child: Text(
                        '查看详情',
                        style: TextStyle(fontSize: large ? 17 : 14),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CarouselButton extends StatelessWidget {
  const _CarouselButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.large = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool large;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      icon: Icon(icon, size: large ? 26 : 20),
      style: IconButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: Colors.black.withValues(alpha: 0.15),
        minimumSize: Size.square(large ? 46 : 32),
        padding: EdgeInsets.zero,
      ),
    );
  }
}
