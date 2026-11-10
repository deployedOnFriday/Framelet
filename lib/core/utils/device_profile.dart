import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 运行设备形态识别。
///
/// Android 电视（含投影、机顶盒）走 Leanback 界面；手机/平板/桌面端保持原布局。
class DeviceProfile extends ChangeNotifier {
  DeviceProfile._();

  static final DeviceProfile instance = DeviceProfile._();

  static const MethodChannel _channel = MethodChannel('framelet/device');

  /// QA / 截图用：`--dart-define=FRAMELET_FORCE_TV=true` 强制电视布局。
  bool _isTelevision = const bool.fromEnvironment('FRAMELET_FORCE_TV');
  bool? _debugOverride;

  /// 是否为 Android 电视环境。
  bool get isTelevision => _debugOverride ?? _isTelevision;

  /// 测试注入：传 null 恢复自动检测。
  @visibleForTesting
  void debugForceTelevision(bool? value) {
    _debugOverride = value;
    notifyListeners();
  }

  /// 启动时调用；仅 Android 有原生实现，其他平台直接跳过。
  Future<void> detect() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final result = await _channel.invokeMethod<bool>('isTelevision') ?? false;
      if (result != _isTelevision) {
        _isTelevision = result;
        notifyListeners();
      }
    } catch (error) {
      debugPrint('[Device] 电视形态检测失败: $error');
    }
  }
}
