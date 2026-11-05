import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

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
    final scale = size.shortestSide / 48;
    canvas.save();
    canvas.scale(scale);

    final background = RRect.fromRectAndRadius(
      const Rect.fromLTWH(2, 2, 44, 44),
      const Radius.circular(13),
    );
    canvas.drawRRect(
      background,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
        ).createShader(const Rect.fromLTWH(2, 2, 44, 44)),
    );

    canvas.save();
    canvas.clipRRect(background);

    final topBand = Path()
      ..moveTo(14, 14)
      ..cubicTo(14, 12.34, 15.34, 11, 17, 11)
      ..lineTo(33, 11)
      ..cubicTo(34.66, 11, 36, 12.34, 36, 14)
      ..lineTo(36, 16)
      ..cubicTo(36, 17.66, 34.66, 19, 33, 19)
      ..lineTo(14, 19)
      ..close();
    canvas.drawPath(
      topBand,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF38BDF8), Color(0xFF2563EB)],
        ).createShader(const Rect.fromLTWH(12, 11, 24, 8)),
    );

    final stem = Path()
      ..moveTo(14, 19)
      ..lineTo(21, 19)
      ..lineTo(21, 34)
      ..cubicTo(21, 35.66, 19.66, 37, 18, 37)
      ..lineTo(17, 37)
      ..cubicTo(15.34, 37, 14, 35.66, 14, 34)
      ..close();
    canvas.drawPath(stem, Paint()..color = Colors.white);

    final play = Path()
      ..moveTo(24, 22.8)
      ..cubicTo(24, 21.98, 24.89, 21.48, 25.59, 21.91)
      ..lineTo(32.45, 26.11)
      ..cubicTo(33.11, 26.51, 33.11, 27.49, 32.45, 27.89)
      ..lineTo(25.59, 32.09)
      ..cubicTo(24.89, 32.52, 24, 32.02, 24, 31.2)
      ..close();
    canvas.drawPath(
      play,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF60A5FA), Color(0xFF818CF8)],
        ).createShader(const Rect.fromLTWH(24, 21.5, 9, 11)),
    );

    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RibbonLogoPainter oldDelegate) => false;
}
