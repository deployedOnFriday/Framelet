import 'package:flutter/material.dart';

/// 手机端专用布局判定。
///
/// 只在 Android / iOS 且短边小于 600 时启用：Windows、macOS 以及
/// 平板（含 iPad 与横屏平板）继续使用原有的桌面/侧栏布局。
bool isPhoneLayout(BuildContext context) {
  final platform = Theme.of(context).platform;
  if (platform != TargetPlatform.android && platform != TargetPlatform.iOS) {
    return false;
  }
  return MediaQuery.sizeOf(context).shortestSide < 600;
}
