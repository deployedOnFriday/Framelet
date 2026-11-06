import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/danmaku_service.dart';

/// 弹幕覆盖层：Canvas 绘制。
///
/// 性能要点（旧实现是播放页每秒 setState 重建最多 60 个带双阴影的
/// Text widget，整树重新 layout + 阴影开销，低端机直接掉帧）：
/// ① 文本用 TextPainter 预排版并缓存，每帧只做 canvas 平移绘制；
/// ② 重绘由 Ticker + 时钟 ValueListenable 驱动，不经 setState，
///    不牵连播放页其它子树；
/// ③ 弹幕按时间升序排列后用二分定位当前窗口，避免全量扫描。
class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.comments,
    required this.clock,
  });

  /// 已按 timeSec 升序排列的弹幕。
  final List<DanmakuComment> comments;

  /// 当前播放秒数的实时值（由播放器的 position 流更新，不经 setState）。
  final ValueListenable<double> clock;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  /// 每帧跳动的驱动器：AnimationController 是 Listenable，直接作为
  /// CustomPainter 的 repaint 信号，全程不经 setState。
  late final AnimationController _ticker = AnimationController(vsync: this)
    ..repeat();
  final Map<String, TextPainter> _painterCache = <String, TextPainter>{};

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  TextPainter _textPainterFor(String text, int colorValue) {
    final key = '$text\u0000$colorValue';
    var painter = _painterCache[key];
    if (painter != null) return painter;
    // 弹幕文本只前进不回头（回退进度条时重建少量即可），超限直接清空
    if (_painterCache.length > 600) _painterCache.clear();
    final color = colorValue == 0
        ? Colors.white
        : Color(0xFF000000 | colorValue);
    painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          shadows: const [
            Shadow(blurRadius: 3, color: Colors.black87),
            Shadow(blurRadius: 6, color: Colors.black54),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return _painterCache[key] = painter;
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _DanmakuPainter(
          comments: widget.comments,
          clock: widget.clock,
          painterFor: _textPainterFor,
          repaint: Listenable.merge([widget.clock, _ticker]),
        ),
      ),
    );
  }
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({
    required this.comments,
    required this.clock,
    required this.painterFor,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final List<DanmakuComment> comments;
  final ValueListenable<double> clock;
  final TextPainter Function(String text, int colorValue) painterFor;

  static const _lifetime = 8.0;
  static const _maxActive = 60;

  @override
  void paint(Canvas canvas, Size size) {
    if (comments.isEmpty) return;
    final position = clock.value;
    final floor = position - _lifetime;

    // 二分定位：第一条可能仍存活的弹幕（timeSec >= position - lifetime）
    var lo = 0;
    var hi = comments.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (comments[mid].timeSec < floor) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }

    var painted = 0;
    for (var i = lo; i < comments.length; i++) {
      final comment = comments[i];
      if (comment.timeSec > position) break;
      if (painted >= _maxActive) break;
      final elapsed = position - comment.timeSec;
      final lane = comment.text.hashCode.abs() % 7;
      final painter = painterFor(comment.text, comment.color & 0xFFFFFF);

      if (comment.mode == 4 || comment.mode == 5) {
        // 顶部/底部固定弹幕，停留 4 秒
        if (elapsed > 4) continue;
        final top = (comment.mode == 5
                ? 74.0 + lane * 27
                : size.height - 130.0 - lane * 27)
            .clamp(54.0, size.height - 54);
        painter.paint(canvas, Offset((size.width - painter.width) / 2, top));
        painted++;
        continue;
      }

      // 滚动弹幕：从右缘进入、完全离开视口即消失
      final progress = (elapsed / _lifetime).clamp(0.0, 1.0);
      final left = size.width - progress * (size.width + painter.width + 40);
      if (left + painter.width <= 0) continue;
      painter.paint(canvas, Offset(left, 74.0 + lane * 31));
      painted++;
    }
  }

  @override
  bool shouldRepaint(_DanmakuPainter oldDelegate) => false;
}
