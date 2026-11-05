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

  static final Player player = Player();
  static final VideoController controller = VideoController(player);
}
