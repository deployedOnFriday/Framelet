import 'dart:io';

import 'package:flutter/material.dart';

import '../core/utils/decode_width.dart';
import '../models/media_item.dart';

class MediaArtwork extends StatelessWidget {
  const MediaArtwork({
    required this.item,
    this.borderRadius = 12,
    this.showQuality = false,
    this.fit = BoxFit.cover,
    super.key,
  });

  final MediaItem item;
  final double borderRadius;
  final bool showQuality;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final posterPath = item.posterPath;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: item.colors,
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 不做 existsSync 预检：同步磁盘 IO 在 build 里会造成滚动掉帧。
            // 文件缺失/损坏时 errorBuilder 兜底显示占位渐变。
            if (posterPath != null)
              LayoutBuilder(
                builder: (context, constraints) {
                  final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
                  // 档位化解码宽度：布局微变（如侧栏展开动画）不触发重新解码
                  final cacheWidth = decodeCacheWidth(
                    constraints.maxWidth,
                    dpr,
                    max: 1600,
                  );
                  return Image.file(
                    File(posterPath),
                    fit: fit,
                    alignment: Alignment.center,
                    cacheWidth: cacheWidth,
                    // 解码完成前保持透明，帧就绪后淡入，避免海报闪现
                    frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                      if (wasSynchronouslyLoaded) return child;
                      return AnimatedOpacity(
                        opacity: frame == null ? 0 : 1,
                        duration: const Duration(milliseconds: 240),
                        curve: Curves.easeOut,
                        child: child,
                      );
                    },
                    errorBuilder: (context, error, stackTrace) =>
                        _buildPlaceholder(),
                  );
                },
              )
            else
              _buildPlaceholder(),
            if (item.rating != null)
              Positioned(
                left: 9,
                top: 9,
                child: _ArtworkLabel(
                  icon: Icons.star_rounded,
                  text: item.rating!,
                ),
              ),
            if (showQuality && item.quality != null)
              Positioned(
                right: 9,
                top: 9,
                child: _ArtworkLabel(text: item.quality!),
              ),
          ],
        ),
      ),
    );
  }

  /// 没有海报时的渐变占位（图标 + 氛围圆环）。
  Widget _buildPlaceholder() {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          right: -24,
          top: -34,
          child: _ArtworkCircle(size: 120, opacity: 0.12),
        ),
        Positioned(
          left: -30,
          bottom: -46,
          child: _ArtworkCircle(size: 140, opacity: 0.1),
        ),
        Center(
          child: Icon(
            item.icon,
            size: 48,
            color: Colors.white.withValues(alpha: 0.76),
          ),
        ),
      ],
    );
  }
}

class _ArtworkCircle extends StatelessWidget {
  const _ArtworkCircle({required this.size, required this.opacity});

  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: opacity),
      ),
    );
  }
}

class _ArtworkLabel extends StatelessWidget {
  const _ArtworkLabel({this.icon, required this.text});

  final IconData? icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: const Color(0xFFFFD889)),
            const SizedBox(width: 3),
          ],
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
