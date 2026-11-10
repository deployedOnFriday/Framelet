import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// 品牌标设计稿坐标系边长（48×48）。
const double kBrandMarkDesignSize = 48;

/// 品牌标深色圆角底板。
const Rect kBrandPlateRect = Rect.fromLTWH(2, 2, 44, 44);
const double kBrandPlateRadius = 13;

/// 品牌字标（F + 播放键）在设计稿中的包围盒。
const Rect kBrandGlyphBounds = Rect.fromLTRB(14, 11, 36, 37);

const List<Color> kBrandPlateGradientColors = [
  Color(0xFF1E293B),
  Color(0xFF0F172A),
];
const List<Color> kBrandBandGradientColors = [
  Color(0xFF38BDF8),
  Color(0xFF2563EB),
];
const List<Color> kBrandPlayGradientColors = [
  Color(0xFF60A5FA),
  Color(0xFF818CF8),
];

/// F 的上横（蓝色渐变横带）。
Path buildBrandBandPath() => Path()
  ..moveTo(14, 14)
  ..cubicTo(14, 12.34, 15.34, 11, 17, 11)
  ..lineTo(33, 11)
  ..cubicTo(34.66, 11, 36, 12.34, 36, 14)
  ..lineTo(36, 16)
  ..cubicTo(36, 17.66, 34.66, 19, 33, 19)
  ..lineTo(14, 19)
  ..close();

/// F 的竖笔（白色）。
Path buildBrandStemPath() => Path()
  ..moveTo(14, 19)
  ..lineTo(21, 19)
  ..lineTo(21, 34)
  ..cubicTo(21, 35.66, 19.66, 37, 18, 37)
  ..lineTo(17, 37)
  ..cubicTo(15.34, 37, 14, 35.66, 14, 34)
  ..close();

/// 播放三角（蓝色渐变）。
Path buildBrandPlayPath() => Path()
  ..moveTo(24, 22.8)
  ..cubicTo(24, 21.98, 24.89, 21.48, 25.59, 21.91)
  ..lineTo(32.45, 26.11)
  ..cubicTo(33.11, 26.51, 33.11, 27.49, 32.45, 27.89)
  ..lineTo(25.59, 32.09)
  ..cubicTo(24.89, 32.52, 24, 32.02, 24, 31.2)
  ..close();

/// 绘制品牌深色渐变底板，默认按设计稿坐标（2,2,44,44）与 13 圆角。
void paintBrandPlate(
  Canvas canvas, {
  Rect rect = kBrandPlateRect,
  double radius = kBrandPlateRadius,
}) {
  canvas.drawRRect(
    RRect.fromRectAndRadius(rect, Radius.circular(radius)),
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: kBrandPlateGradientColors,
      ).createShader(rect),
  );
}

/// 铺满 [rect] 的品牌深色渐变背景（用于应用图标）。
void paintBrandBackdrop(Canvas canvas, Rect rect) {
  canvas.drawRect(
    rect,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: kBrandPlateGradientColors,
      ).createShader(rect),
  );
}

/// 在设计稿坐标系（48×48）中绘制 F + 播放键字标。
///
/// [monochrome] 为 true 时全部使用白色单色，供 Android 主题图标使用。
void paintBrandGlyph(
  Canvas canvas, {
  bool monochrome = false,
  Color monochromeColor = Colors.white,
}) {
  canvas.drawPath(
    buildBrandBandPath(),
    monochrome
        ? (Paint()..color = monochromeColor)
        : (Paint()
            ..shader = const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: kBrandBandGradientColors,
            ).createShader(const Rect.fromLTWH(12, 11, 24, 8))),
  );

  canvas.drawPath(
    buildBrandStemPath(),
    Paint()..color = monochrome ? monochromeColor : Colors.white,
  );

  canvas.drawPath(
    buildBrandPlayPath(),
    monochrome
        ? (Paint()..color = monochromeColor)
        : (Paint()
            ..shader = const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: kBrandPlayGradientColors,
            ).createShader(const Rect.fromLTWH(24, 21.5, 9, 11))),
  );
}

/// 方案 C「折纸胶片 F」品牌标。
class BrandLogo extends StatelessWidget {
  const BrandLogo({this.size = 40, this.showWordmark = false, super.key});

  final double size;
  final bool showWordmark;

  @override
  Widget build(BuildContext context) {
    final mark = SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _RibbonLogoPainter()),
    );
    if (!showWordmark) {
      return Tooltip(message: '拾帧 Framelet', child: mark);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        const SizedBox(width: 11),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '拾帧',
              style: TextStyle(
                fontSize: 21,
                height: 1.1,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
                color: context.colors.text,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Framelet',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
                color: context.colors.muted,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _RibbonLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / kBrandMarkDesignSize;
    canvas.save();
    canvas.scale(scale);

    final background = RRect.fromRectAndRadius(
      kBrandPlateRect,
      const Radius.circular(kBrandPlateRadius),
    );
    paintBrandPlate(canvas);

    canvas.save();
    canvas.clipRRect(background);
    paintBrandGlyph(canvas);

    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RibbonLogoPainter oldDelegate) => false;
}
