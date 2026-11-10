// 生成移动端应用图标（Android / iOS）。
//
// 用法：flutter test tool/generate_launcher_icons_test.dart
// 该文件不在 test/ 目录下，不会被常规 `flutter test` 收集。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/widgets/brand_logo.dart';

const Map<String, int> _iosIcons = {
  'Icon-App-20x20@1x.png': 20,
  'Icon-App-20x20@2x.png': 40,
  'Icon-App-20x20@3x.png': 60,
  'Icon-App-29x29@1x.png': 29,
  'Icon-App-29x29@2x.png': 58,
  'Icon-App-29x29@3x.png': 87,
  'Icon-App-40x40@1x.png': 40,
  'Icon-App-40x40@2x.png': 80,
  'Icon-App-40x40@3x.png': 120,
  'Icon-App-60x60@2x.png': 120,
  'Icon-App-60x60@3x.png': 180,
  'Icon-App-76x76@1x.png': 76,
  'Icon-App-76x76@2x.png': 152,
  'Icon-App-83.5x83.5@2x.png': 167,
  'Icon-App-1024x1024@1x.png': 1024,
};

const Map<String, int> _androidLegacy = {
  'mipmap-mdpi': 48,
  'mipmap-hdpi': 72,
  'mipmap-xhdpi': 96,
  'mipmap-xxhdpi': 144,
  'mipmap-xxxhdpi': 192,
};

/// 自适应图标前景 / 单色图层的 108dp 画布。
const Map<String, int> _androidAdaptive = {
  'mipmap-mdpi': 108,
  'mipmap-hdpi': 162,
  'mipmap-xhdpi': 216,
  'mipmap-xxhdpi': 324,
  'mipmap-xxxhdpi': 432,
};

const Map<String, int> _macosIcons = {
  'app_icon_16.png': 16,
  'app_icon_32.png': 32,
  'app_icon_64.png': 64,
  'app_icon_128.png': 128,
  'app_icon_256.png': 256,
  'app_icon_512.png': 512,
  'app_icon_1024.png': 1024,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('生成 Android / iOS 应用图标', () async {
    final root = Directory.current;
    expect(
      File('${root.path}/pubspec.yaml').existsSync(),
      isTrue,
      reason: '请在项目根目录运行本脚本',
    );

    final iosDir = Directory(
      '${root.path}/ios/Runner/Assets.xcassets/AppIcon.appiconset',
    );
    final androidRes = Directory('${root.path}/android/app/src/main/res');
    final macosDir = Directory(
      '${root.path}/macos/Runner/Assets.xcassets/AppIcon.appiconset',
    );

    for (final entry in _iosIcons.entries) {
      final bytes = await _rasterize(entry.value, _paintIosIcon, alpha: false);
      File('${iosDir.path}/${entry.key}').writeAsBytesSync(bytes);
    }

    for (final entry in _androidLegacy.entries) {
      final bytes = await _rasterize(
        entry.value,
        _paintLegacyIcon,
        alpha: true,
      );
      File('${androidRes.path}/${entry.key}/ic_launcher.png')
          .writeAsBytesSync(bytes);
    }

    for (final entry in _androidAdaptive.entries) {
      final foreground = await _rasterize(
        entry.value,
        _paintAdaptiveForeground,
        alpha: true,
      );
      File('${androidRes.path}/${entry.key}/ic_launcher_foreground.png')
          .writeAsBytesSync(foreground);

      final monochrome = await _rasterize(
        entry.value,
        _paintAdaptiveMonochrome,
        alpha: true,
      );
      File('${androidRes.path}/${entry.key}/ic_launcher_monochrome.png')
          .writeAsBytesSync(monochrome);
    }

    for (final entry in _macosIcons.entries) {
      final bytes = await _rasterize(entry.value, _paintMacosIcon, alpha: true);
      File('${macosDir.path}/${entry.key}').writeAsBytesSync(bytes);
    }

    // Android TV 主屏横幅（Leanback banner）：320×180，需不透明。
    final banner = await _rasterizeBanner(320, 180, _paintTvBanner);
    final bannerDir = Directory('${androidRes.path}/drawable-xhdpi')
      ..createSync(recursive: true);
    File('${bannerDir.path}/tv_banner.png').writeAsBytesSync(banner);
  });
}

/// iOS：满幅品牌渐变 + 居中字标，不能有透明像素。
void _paintIosIcon(Canvas canvas, double size) {
  paintBrandBackdrop(canvas, Rect.fromLTWH(0, 0, size, size));
  _paintCenteredGlyph(canvas, size, glyphHeight: size * 0.58);
}

/// Android 旧版图标：圆角深色底板 + 字标，四角透明。
void _paintLegacyIcon(Canvas canvas, double size) {
  final rect = Rect.fromLTWH(0, 0, size, size);
  final radius = Radius.circular(size * 0.225);
  canvas.drawRRect(
    RRect.fromRectAndRadius(rect, radius),
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: kBrandPlateGradientColors,
      ).createShader(rect),
  );
  canvas.save();
  canvas.clipRRect(RRect.fromRectAndRadius(rect, radius));
  _paintCenteredGlyph(canvas, size, glyphHeight: size * 0.6);
  canvas.restore();
}

/// Android 自适应图标前景：108dp 画布，字标收在 66dp 安全区内。
void _paintAdaptiveForeground(Canvas canvas, double size) {
  _paintCenteredGlyph(canvas, size, glyphHeight: size * 50 / 108);
}

/// Android 13 主题图标单色图层。
void _paintAdaptiveMonochrome(Canvas canvas, double size) {
  _paintCenteredGlyph(
    canvas,
    size,
    glyphHeight: size * 50 / 108,
    monochrome: true,
  );
}

/// macOS：带留白与投影的圆角方块（Big Sur 起的使用习惯）。
void _paintMacosIcon(Canvas canvas, double size) {
  final inset = size * 0.098;
  final body = Rect.fromLTWH(inset, inset, size - inset * 2, size - inset * 2);
  final radius = Radius.circular(body.width * 0.225);
  final bodyPath = Path()..addRRect(RRect.fromRectAndRadius(body, radius));

  canvas.drawShadow(
    bodyPath,
    Colors.black.withValues(alpha: 0.35),
    size * 0.012,
    false,
  );
  canvas.drawPath(
    bodyPath,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: kBrandPlateGradientColors,
      ).createShader(body),
  );

  canvas.save();
  canvas.clipPath(bodyPath);
  _paintCenteredGlyph(canvas, size, glyphHeight: body.height * 0.6);
  canvas.restore();
}

/// Android TV 横幅：品牌渐变底 + 居中字标与柔和光晕。
void _paintTvBanner(Canvas canvas, double width, double height) {
  paintBrandBackdrop(canvas, Rect.fromLTWH(0, 0, width, height));

  final glowCenter = Offset(width * 0.8, height * 0.15);
  final glowRadius = height * 1.05;
  canvas.drawCircle(
    glowCenter,
    glowRadius,
    Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFF2563EB).withValues(alpha: 0.35),
          const Color(0xFF2563EB).withValues(alpha: 0),
        ],
      ).createShader(Rect.fromCircle(center: glowCenter, radius: glowRadius)),
  );

  // 用画布中心做字标定位，宽高比不影响视觉重心。
  final bounds = kBrandGlyphBounds;
  final glyphHeight = height * 0.56;
  final scale = glyphHeight / bounds.height;
  canvas.save();
  canvas.translate(
    width / 2 - bounds.center.dx * scale,
    height / 2 - bounds.center.dy * scale,
  );
  canvas.scale(scale);
  paintBrandGlyph(canvas);
  canvas.restore();
}

Future<Uint8List> _rasterizeBanner(
  int width,
  int height,
  void Function(Canvas canvas, double width, double height) paint,
) async {
  const supersample = 2;
  final renderWidth = width * supersample;
  final renderHeight = height * supersample;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(0, 0, renderWidth.toDouble(), renderHeight.toDouble()),
  );
  paint(canvas, renderWidth.toDouble(), renderHeight.toDouble());
  final picture = recorder.endRecording();
  final large = await picture.toImage(renderWidth, renderHeight);
  picture.dispose();

  final scaledRecorder = ui.PictureRecorder();
  final scaledCanvas = Canvas(
    scaledRecorder,
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
  );
  scaledCanvas.drawImageRect(
    large,
    Rect.fromLTWH(0, 0, renderWidth.toDouble(), renderHeight.toDouble()),
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()
      ..isAntiAlias = true
      ..filterQuality = FilterQuality.high,
  );
  final scaledPicture = scaledRecorder.endRecording();
  final image = await scaledPicture.toImage(width, height);
  scaledPicture.dispose();
  large.dispose();

  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  final rgba = data!.buffer.asUint8List();
  for (var i = 3; i < rgba.length; i += 4) {
    if (rgba[i] != 255) {
      throw StateError('TV 横幅存在透明像素');
    }
  }
  return _encodePng(width, height, rgba, alpha: false);
}

void _paintCenteredGlyph(
  Canvas canvas,
  double size, {
  required double glyphHeight,
  bool monochrome = false,
}) {
  final bounds = kBrandGlyphBounds;
  final scale = glyphHeight / bounds.height;
  final center = Offset(size / 2, size / 2);
  canvas.save();
  canvas.translate(
    center.dx - bounds.center.dx * scale,
    center.dy - bounds.center.dy * scale,
  );
  canvas.scale(scale);
  paintBrandGlyph(canvas, monochrome: monochrome);
  canvas.restore();
}

Future<Uint8List> _rasterize(
  int size,
  void Function(Canvas canvas, double size) paint, {
  required bool alpha,
}) async {
  // 小尺寸先按 256 渲染再高质量缩小，避免细节糊掉。
  final renderSize = size < 128 ? 256 : size;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(
    recorder,
    Rect.fromLTWH(0, 0, renderSize.toDouble(), renderSize.toDouble()),
  );
  paint(canvas, renderSize.toDouble());
  final picture = recorder.endRecording();
  var image = await picture.toImage(renderSize, renderSize);
  picture.dispose();

  if (renderSize != size) {
    final scaledRecorder = ui.PictureRecorder();
    final scaledCanvas = Canvas(
      scaledRecorder,
      Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    );
    scaledCanvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, renderSize.toDouble(), renderSize.toDouble()),
      Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      Paint()
        ..isAntiAlias = true
        ..filterQuality = FilterQuality.high,
    );
    final scaledPicture = scaledRecorder.endRecording();
    final scaledImage = await scaledPicture.toImage(size, size);
    scaledPicture.dispose();
    image.dispose();
    image = scaledImage;
  }

  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  final rgba = data!.buffer.asUint8List();

  if (alpha) {
    // rawRgba 是预乘 alpha，PNG 需要直通 alpha，否则透明边缘会发暗。
    for (var i = 0; i < rgba.length; i += 4) {
      final a = rgba[i + 3];
      if (a == 0 || a == 255) {
        continue;
      }
      final scale = 255 / a;
      rgba[i] = (rgba[i] * scale).round().clamp(0, 255);
      rgba[i + 1] = (rgba[i + 1] * scale).round().clamp(0, 255);
      rgba[i + 2] = (rgba[i + 2] * scale).round().clamp(0, 255);
    }
  } else {
    for (var i = 3; i < rgba.length; i += 4) {
      if (rgba[i] != 255) {
        throw StateError('iOS 图标存在透明像素，App Store 会拒绝');
      }
    }
  }

  return _encodePng(size, size, rgba, alpha: alpha);
}

Uint8List _encodePng(
  int width,
  int height,
  Uint8List rgba, {
  required bool alpha,
}) {
  final channels = alpha ? 4 : 3;
  final stride = width * channels + 1;
  final raw = Uint8List(stride * height);
  var offset = 0;
  for (var y = 0; y < height; y++) {
    raw[offset++] = 0;
    var source = y * width * 4;
    for (var x = 0; x < width; x++) {
      raw[offset++] = rgba[source];
      raw[offset++] = rgba[source + 1];
      raw[offset++] = rgba[source + 2];
      if (alpha) {
        raw[offset++] = rgba[source + 3];
      }
      source += 4;
    }
  }

  final output = BytesBuilder(copy: false);
  output.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  void writeChunk(String type, List<int> payload) {
    final typeBytes = ascii.encode(type);
    final body = Uint8List(typeBytes.length + payload.length)
      ..setAll(0, typeBytes)
      ..setAll(typeBytes.length, payload);
    output.add(_uint32(payload.length));
    output.add(body);
    output.add(_uint32(_crc32(body)));
  }

  writeChunk('IHDR', [
    ..._uint32(width),
    ..._uint32(height),
    8,
    alpha ? 6 : 2,
    0,
    0,
    0,
  ]);
  writeChunk('IDAT', ZLibEncoder(level: 9).convert(raw));
  writeChunk('IEND', const []);
  return output.takeBytes();
}

Uint8List _uint32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value);

final List<int> _crcTable = List<int>.generate(256, (index) {
  var value = index;
  for (var bit = 0; bit < 8; bit++) {
    value = (value & 1) != 0 ? 0xEDB88320 ^ (value >> 1) : value >> 1;
  }
  return value;
});

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
