import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// 全局共享的播放器与视频控制器（桌面端常驻）。
///
/// 退出播放页只 stop、不 dispose：mpv 的 render context 释放
/// （VideoOutputManager.Dispose）与 terminate 都是同步 FFI，会阻塞
/// 平台线程，逐次销毁正是退出播放器卡顿的根源。常驻一个实例把
/// 销毁成本从每次退出中彻底去掉，顺带免去下次打开时的重建开销。
/// 单实例常驻内存占用仅个位数 MB，进程退出时由系统回收。
class PlayerHost {
  PlayerHost._();

  /// 交给 mpv/libass 渲染字幕：ASS/SSA 的字体、描边、中上英下等
  /// 定位信息才能保留；Flutter 纯文本渲染会丢掉这些版式。
  ///
  /// Android 的 fontconfig 看不到系统字体，必须随包提供一个中文字体
  /// （Noto Sans SC，OFL 许可），才能正常渲染中文 libass 字幕。
  static final bool useLibass =
      Platform.isWindows ||
      Platform.isMacOS ||
      Platform.isLinux ||
      Platform.isAndroid;

  static const _androidSubtitleFont = 'assets/fonts/NotoSansSC-Regular.otf';

  static final Player player = Player(
    configuration: PlayerConfiguration(
      libass: useLibass,
      libassAndroidFont: Platform.isAndroid ? _androidSubtitleFont : null,
      libassAndroidFontName: Platform.isAndroid ? 'Noto Sans SC' : null,
    ),
  );
  static final VideoController controller = VideoController(player);
}
