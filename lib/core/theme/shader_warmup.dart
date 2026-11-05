import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Framelet 高频绘制效果的 Skia shader 预热。
///
/// Skia 按需编译 GPU 着色器：每种效果首次出现会阻塞光栅线程
/// （实测最大 1.3s）。这里把应用高频效果的绘制组合在启动时离屏
/// 执行一次，把编译成本从用户操作的瞬间转移到启动 loading 里。
///
/// 必须在 WidgetsFlutterBinding.ensureInitialized() 之前赋值给
/// PaintingBinding.shaderWarmUp（initInstances 时执行预热）。
class FrameletShaderWarmUp extends ShaderWarmUp {
  const FrameletShaderWarmUp();

  @override
  ui.Size get size => const ui.Size(256, 256);

  @override
  Future<void> warmUpOnCanvas(ui.Canvas canvas) async {
    // 1) 圆角矩形 + 双色线性渐变（海报卡占位背景、横幅渐变保护层）
    final gradientPaint = Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, 0),
        const Offset(171, 256),
        const [Color(0xFF3D6B5C), Color(0xFF7FB89F)],
      );
    canvas.drawRRect(
      _posterRRect,
      gradientPaint,
    );

    // 2) 圆角裁剪（MediaArtwork 的 ClipRRect）
    canvas.save();
    canvas.clipRRect(_posterRRect);
    canvas.drawRect(
      _posterRect,
      Paint()..color = const Color(0xFF185FA5),
    );
    canvas.restore();

    // 3) 阴影模糊（卡片 hover 的 BoxShadow）
    canvas.drawRRect(
      _posterRRect,
      Paint()
        ..color = const Color(0x380F172A)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 20),
    );

    // 4) saveLayer 离屏合成（页面转场淡入淡出、AnimatedOpacity）
    canvas.saveLayer(
      const Rect.fromLTWH(0, 0, 256, 256),
      Paint()..color = const Color(0x80FFFFFF),
    );
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 256, 256),
      Paint()..color = const Color(0xFF141414),
    );
    canvas.restore();

    // 5) 页面转场的缩放变换（Zoom/FadeUpwards 转场中的 Transform）
    canvas.save();
    canvas.scale(0.92, 0.92);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 256, 256),
      Paint()..color = const Color(0x80000000),
    );
    canvas.restore();
  }

  static const _posterRect = Rect.fromLTWH(0, 0, 170.8, 256.2);

  static final _posterRRect = RRect.fromRectAndRadius(
    _posterRect,
    const Radius.circular(12),
  );
}
