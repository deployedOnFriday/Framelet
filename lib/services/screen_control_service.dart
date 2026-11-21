import 'package:flutter/services.dart';

/// 手机端播放手势需要的系统亮度 / 媒体音量控制。
///
/// Android 由 MainActivity 的 `framelet/screen` 通道实现；其他平台
/// 返回 null，由播放器层回退到应用内调暗与播放器音量。
class ScreenControlService {
  ScreenControlService._();

  static final ScreenControlService instance = ScreenControlService._();

  static const MethodChannel _channel = MethodChannel('framelet/screen');

  /// 当前窗口亮度（0.0–1.0），不可用时返回 null。
  Future<double?> readBrightness() async {
    try {
      return await _channel.invokeMethod<double>('getBrightness');
    } catch (_) {
      return null;
    }
  }

  /// 设置窗口亮度（0.0–1.0）。返回 false 表示平台不支持。
  Future<bool> setBrightness(double value) async {
    try {
      return await _channel.invokeMethod<bool>('setBrightness', {
            'value': value.clamp(0.0, 1.0),
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// 恢复系统 / 应用默认亮度。
  Future<void> resetBrightness() async {
    try {
      await _channel.invokeMethod<void>('resetBrightness');
    } catch (_) {
      // 平台不支持时无需处理。
    }
  }

  /// 当前媒体音量（0.0–1.0），不可用时返回 null。
  Future<double?> readVolume() async {
    try {
      return await _channel.invokeMethod<double>('getVolume');
    } catch (_) {
      return null;
    }
  }

  /// 设置媒体音量（0.0–1.0）。返回 false 表示平台不支持。
  Future<bool> setVolume(double value) async {
    try {
      return await _channel.invokeMethod<bool>('setVolume', {
            'value': value.clamp(0.0, 1.0),
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
