import 'package:flutter/material.dart';

import 'framelet_store.dart';

/// 外观模式的单一来源：跟随系统 / 浅色 / 深色。
///
/// 值变化后 `MaterialApp` 整树重建完成换肤；选择持久化在 SQLite 的 app_meta 表。
class ThemeController extends ValueNotifier<ThemeMode> {
  ThemeController._() : super(ThemeMode.system);

  static final ThemeController instance = ThemeController._();

  static const _metaKey = 'theme_mode';

  /// 启动时恢复上次选择；读取失败时静默回落到跟随系统。
  Future<void> load() async {
    try {
      final raw = await FrameletStore.instance.loadMeta(_metaKey);
      if (raw == null) return;
      value = ThemeMode.values.firstWhere(
        (mode) => mode.name == raw,
        orElse: () => ThemeMode.system,
      );
    } catch (error) {
      debugPrint('[Theme] 读取外观设置失败: $error');
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    if (value == mode) return;
    value = mode;
    try {
      await FrameletStore.instance.saveMeta(_metaKey, mode.name);
    } catch (error) {
      debugPrint('[Theme] 保存外观设置失败: $error');
    }
  }
}
