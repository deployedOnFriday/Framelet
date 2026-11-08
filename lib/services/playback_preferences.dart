import 'package:flutter/foundation.dart';

import 'credential_store.dart';

/// 播放偏好：自动连播、默认倍速、快进步长、续播回退、硬件解码等。
///
/// 启动时在 main() 里 load() 一次，之后设置页修改立即持久化。
/// 播放器在打开媒体 / 触发相应行为时读取最新值，改动下次播放生效。
class PlaybackPreferences extends ChangeNotifier {
  PlaybackPreferences._();

  static final PlaybackPreferences instance = PlaybackPreferences._();

  final CredentialStore _store = CredentialStore();

  /// 与播放器倍速菜单一致的可选倍速。
  static const speedOptions = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

  /// 方向键快进/快退步长（秒）。
  static const seekStepOptions = [5, 10, 15, 30];

  /// 续播回退秒数：从上次进度继续时往前回退，帮助衔接剧情。
  static const rewindOptions = [0, 3, 5, 10];

  /// 剧集播完自动播放下一集。
  bool autoPlayNext = true;

  /// 下次播放沿用上次的音量与静音状态。
  bool rememberVolume = true;

  /// 硬件解码；关闭后走软解，兼容性更好但 CPU 占用更高。
  bool hardwareDecode = true;

  /// 播放时自动匹配并加载弹幕（需先配置弹幕服务）。
  bool autoLoadDanmaku = false;

  /// 弹幕字号（12–30）。
  double danmakuFontSize = 22;

  /// 弹幕不透明度（0.3–1）。
  double danmakuOpacity = 0.65;

  /// 单条弹幕横向滚动时长（秒，4–24）。数值越大越慢。
  double danmakuLifetime = 14;

  /// 弹幕轨道行数（3–10）。
  int danmakuLanes = 6;

  /// 每次打开播放器的初始倍速。
  double defaultSpeed = 1.0;

  /// 方向键快进/快退步长（秒）。
  int seekStep = 5;

  /// 续播回退秒数。
  int rewindSeconds = 3;

  /// 从本地存储读取全部偏好，读取失败保持默认值。
  Future<void> load() async {
    try {
      autoPlayNext = await _store.read('framelet.player.autoNext') != '0';
      rememberVolume =
          await _store.read('framelet.player.rememberVolume') != '0';
      hardwareDecode = await _store.read('framelet.player.hwdec') != '0';
      autoLoadDanmaku = await _store.read('framelet.player.autoDanmaku') == '1';
      final fontSizeRaw = await _store.read('framelet.danmaku.fontSize');
      final opacityRaw = await _store.read('framelet.danmaku.opacity');
      final lifetimeRaw = await _store.read('framelet.danmaku.lifetime');
      final lanesRaw = await _store.read('framelet.danmaku.lanes');
      danmakuFontSize = double.tryParse(fontSizeRaw ?? '') ?? 22;
      danmakuOpacity = double.tryParse(opacityRaw ?? '') ?? 0.65;
      danmakuLifetime = double.tryParse(lifetimeRaw ?? '') ?? 14;
      danmakuLanes = int.tryParse(lanesRaw ?? '') ?? 6;
      // 0.1.31 / 0.1.32 的默认值整体变过一次。只有四项都还是旧默认值
      // 时才迁移到新默认，避免覆盖用户自己调过的设置。
      final defaultsVersion =
          int.tryParse(
            await _store.read('framelet.danmaku.defaultsVersion') ?? '',
          ) ??
          0;
      final oldDefaults =
          (danmakuFontSize == 25 &&
              danmakuOpacity == 1 &&
              danmakuLifetime == 9 &&
              danmakuLanes == 7) ||
          (danmakuFontSize == 18 &&
              danmakuOpacity == 1 &&
              danmakuLifetime == 16 &&
              danmakuLanes == 7);
      if (defaultsVersion < 2 && oldDefaults) {
        danmakuFontSize = 22;
        danmakuOpacity = 0.65;
        danmakuLifetime = 14;
        danmakuLanes = 6;
        await _store.write('framelet.danmaku.fontSize', '22');
        await _store.write('framelet.danmaku.opacity', '0.65');
        await _store.write('framelet.danmaku.lifetime', '14');
        await _store.write('framelet.danmaku.lanes', '6');
      }
      if (defaultsVersion < 2) {
        await _store.write('framelet.danmaku.defaultsVersion', '2');
      }
      defaultSpeed =
          double.tryParse(await _store.read('framelet.player.speed') ?? '') ??
          1.0;
      seekStep =
          int.tryParse(await _store.read('framelet.player.seekStep') ?? '') ??
          5;
      rewindSeconds =
          int.tryParse(await _store.read('framelet.player.rewind') ?? '') ?? 3;
      // 防御非法值：持久化数据被外部改坏时退回默认
      if (!speedOptions.contains(defaultSpeed)) defaultSpeed = 1.0;
      if (!seekStepOptions.contains(seekStep)) seekStep = 5;
      if (!rewindOptions.contains(rewindSeconds)) rewindSeconds = 3;
      if (!danmakuFontSize.isFinite) danmakuFontSize = 22;
      if (!danmakuOpacity.isFinite) danmakuOpacity = 0.65;
      if (!danmakuLifetime.isFinite) danmakuLifetime = 14;
      danmakuFontSize = danmakuFontSize.clamp(12.0, 30.0);
      danmakuOpacity = danmakuOpacity.clamp(0.3, 1.0);
      danmakuLifetime = danmakuLifetime.clamp(4.0, 24.0);
      danmakuLanes = danmakuLanes.clamp(3, 10);
    } catch (_) {
      // 读取失败不影响使用默认值
    }
  }

  Future<void> setAutoPlayNext(bool value) =>
      _saveBool('framelet.player.autoNext', value, (v) => autoPlayNext = v);

  Future<void> setRememberVolume(bool value) => _saveBool(
    'framelet.player.rememberVolume',
    value,
    (v) => rememberVolume = v,
  );

  Future<void> setHardwareDecode(bool value) =>
      _saveBool('framelet.player.hwdec', value, (v) => hardwareDecode = v);

  Future<void> setAutoLoadDanmaku(bool value) => _saveBool(
    'framelet.player.autoDanmaku',
    value,
    (v) => autoLoadDanmaku = v,
  );

  Future<void> setDanmakuFontSize(double value) => _saveString(
    'framelet.danmaku.fontSize',
    value,
    (v) => danmakuFontSize = v,
  );

  Future<void> setDanmakuOpacity(double value) =>
      _saveString('framelet.danmaku.opacity', value, (v) => danmakuOpacity = v);

  Future<void> setDanmakuLifetime(double value) => _saveString(
    'framelet.danmaku.lifetime',
    value,
    (v) => danmakuLifetime = v,
  );

  Future<void> setDanmakuLanes(int value) =>
      _saveString('framelet.danmaku.lanes', value, (v) => danmakuLanes = v);

  Future<void> setDefaultSpeed(double value) =>
      _saveString('framelet.player.speed', value, (v) => defaultSpeed = v);

  Future<void> setSeekStep(int value) =>
      _saveString('framelet.player.seekStep', value, (v) => seekStep = v);

  Future<void> setRewindSeconds(int value) =>
      _saveString('framelet.player.rewind', value, (v) => rewindSeconds = v);

  Future<void> _saveBool(
    String key,
    bool value,
    void Function(bool) apply,
  ) async {
    apply(value);
    await _store.write(key, value ? '1' : '0');
    notifyListeners();
  }

  Future<void> _saveString<T>(
    String key,
    T value,
    void Function(T) apply,
  ) async {
    apply(value);
    await _store.write(key, value.toString());
    notifyListeners();
  }
}
