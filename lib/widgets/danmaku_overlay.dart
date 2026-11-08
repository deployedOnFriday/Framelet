import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/danmaku_service.dart';
import 'danmaku_lane_layout.dart';

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
    this.fontSize = 18,
    this.opacity = 1,
    this.lifetimeSeconds = 16,
    this.laneCount = 7,
  });

  /// 已按 timeSec 升序排列的弹幕。
  final List<DanmakuComment> comments;

  /// 当前播放秒数的实时值（由播放器的 position 流更新，不经 setState）。
  final ValueListenable<double> clock;

  /// 字号、不透明度、滚动时长与可用行数（播放器内可调）。
  final double fontSize;
  final double opacity;
  final double lifetimeSeconds;
  final int laneCount;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  /// 每帧跳动的驱动器：AnimationController 是 Listenable，直接作为
  /// CustomPainter 的 repaint 信号，全程不经 setState。
  /// 必须给 duration——repeat() 在没有 duration 时 debug 抛
  /// FlutterError、release 抛 TypeError，弹幕层整个失效。
  late final AnimationController _ticker = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
    lowerBound: 0,
    upperBound: 1,
  )..repeat();
  final Map<String, _DanmakuTextPainters> _painterCache =
      <String, _DanmakuTextPainters>{};
  final Map<String, double> _widthCache = <String, double>{};

  List<DanmakuComment>? _layoutComments;
  Size _layoutSize = Size.zero;
  double _layoutFontSize = 0;
  double _layoutLifetime = 0;
  int _layoutLaneCount = 0;
  DanmakuLaneLayout _laneLayout = DanmakuLaneLayout.empty;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didUpdateWidget(covariant DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 字号/透明度变化会让已缓存的 TextPainter 失效
    if (oldWidget.fontSize != widget.fontSize ||
        oldWidget.opacity != widget.opacity) {
      _painterCache.clear();
    }
    if (oldWidget.fontSize != widget.fontSize) {
      _widthCache.clear();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  _DanmakuTextPainters _textPaintersFor(String text, int colorValue) {
    final key = '$text\u0000$colorValue\u0000${widget.fontSize}';
    final cached = _painterCache[key];
    if (cached != null) return cached;
    // 弹幕文本只前进不回头（回退进度条时重建少量即可），超限直接清空
    if (_painterCache.length > 600) _painterCache.clear();
    final alpha = widget.opacity.clamp(0.0, 1.0);
    // B 站解析器约定：0 表示黑色弹幕，配白描边；其余颜色配黑描边。
    final isBlack = colorValue == 0;
    final color = isBlack ? Colors.black : Color(0xFF000000 | colorValue);
    final strokeColor = isBlack ? Colors.white : Colors.black;
    final baseStyle = TextStyle(
      fontSize: widget.fontSize,
      fontWeight: FontWeight.w600,
    );
    // B 站弹幕是「实心字 + 1px 纯黑描边」，不是带模糊半径的投影。
    // 模糊黑影会把小字号文字糊成一团灰边，彩色弹幕也显得发闷。
    final fill = TextPainter(
      text: TextSpan(
        text: text,
        style: baseStyle.copyWith(color: color.withValues(alpha: alpha)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final strokeWidth = (widget.fontSize * 0.06).clamp(1.0, 2.0).toDouble();
    final stroke = TextPainter(
      text: TextSpan(
        text: text,
        style: baseStyle.copyWith(
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..strokeJoin = StrokeJoin.round
            ..color = strokeColor.withValues(alpha: alpha),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return _painterCache[key] = _DanmakuTextPainters(
      fill: fill,
      stroke: stroke,
    );
  }

  double _measureWidth(String text) {
    final key = '$text\u0000${widget.fontSize}';
    final cached = _widthCache[key];
    if (cached != null) return cached;
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: widget.fontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return _widthCache[key] = painter.width;
  }

  DanmakuLaneLayout _laneLayoutFor(Size size) {
    if (identical(_layoutComments, widget.comments) &&
        _layoutSize == size &&
        _layoutFontSize == widget.fontSize &&
        _layoutLifetime == widget.lifetimeSeconds &&
        _layoutLaneCount == widget.laneCount) {
      return _laneLayout;
    }
    _layoutComments = widget.comments;
    _layoutSize = size;
    _layoutFontSize = widget.fontSize;
    _layoutLifetime = widget.lifetimeSeconds;
    _layoutLaneCount = widget.laneCount;
    _laneLayout = DanmakuLaneLayout.assign(
      comments: widget.comments,
      viewportWidth: size.width,
      viewportHeight: size.height,
      fontSize: widget.fontSize,
      lifetimeSeconds: widget.lifetimeSeconds,
      laneCount: widget.laneCount,
      measureWidth: _measureWidth,
    );
    return _laneLayout;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (!size.isFinite || size.width <= 0 || size.height <= 0) {
          return const SizedBox.shrink();
        }
        return IgnorePointer(
          child: CustomPaint(
            size: size,
            painter: _DanmakuPainter(
              comments: widget.comments,
              clock: widget.clock,
              paintersFor: _textPaintersFor,
              laneLayout: _laneLayoutFor(size),
              fontSize: widget.fontSize,
              lifetimeSeconds: widget.lifetimeSeconds,
              laneCount: widget.laneCount,
              repaint: Listenable.merge([widget.clock, _ticker]),
            ),
          ),
        );
      },
    );
  }
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({
    required this.comments,
    required this.clock,
    required this.paintersFor,
    required this.laneLayout,
    required this.fontSize,
    required this.lifetimeSeconds,
    required this.laneCount,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final List<DanmakuComment> comments;
  final ValueListenable<double> clock;
  final _DanmakuTextPainters Function(String text, int colorValue) paintersFor;
  final DanmakuLaneLayout laneLayout;
  final double fontSize;
  final double lifetimeSeconds;
  final int laneCount;

  static const _maxActive = 60;

  @override
  void paint(Canvas canvas, Size size) {
    if (comments.isEmpty) return;
    final position = clock.value;
    final floor = position - lifetimeSeconds;
    final laneGap = (fontSize * 1.72).clamp(26.0, 54.0).toDouble();
    final lanes = laneCount.clamp(1, 12).toInt();

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
      final lane = laneLayout.laneOf(i);
      if (lane < 0 || lane >= lanes) continue;
      final textPainters = paintersFor(comment.text, comment.color & 0xFFFFFF);
      final width = textPainters.width;

      if (comment.mode == 4 || comment.mode == 5) {
        // 顶部/底部固定弹幕，停留 4 秒
        if (elapsed > 4) continue;
        final top =
            (comment.mode == 5
                    ? 74.0 + lane * laneGap
                    : size.height - 130.0 - lane * laneGap)
                .clamp(54.0, size.height - 54)
                .toDouble();
        textPainters.paint(canvas, Offset((size.width - width) / 2, top));
        painted++;
        continue;
      }

      // 滚动弹幕：从右缘进入、完全离开视口即消失
      final progress = (elapsed / lifetimeSeconds).clamp(0.0, 1.0);
      final left = size.width - progress * (size.width + width + 40);
      if (left + width <= 0) continue;
      final maxTop = (size.height - 90.0).clamp(54.0, size.height).toDouble();
      final top = (74.0 + lane * laneGap).clamp(54.0, maxTop).toDouble();
      textPainters.paint(canvas, Offset(left, top));
      painted++;
    }
  }

  @override
  bool shouldRepaint(_DanmakuPainter oldDelegate) =>
      oldDelegate.comments != comments ||
      oldDelegate.laneLayout != laneLayout ||
      oldDelegate.fontSize != fontSize ||
      oldDelegate.lifetimeSeconds != lifetimeSeconds ||
      oldDelegate.laneCount != laneCount;
}

/// 一条弹幕的填充与描边排版结果，绘制时先描边再填实心字。
class _DanmakuTextPainters {
  const _DanmakuTextPainters({required this.fill, required this.stroke});

  final TextPainter fill;
  final TextPainter stroke;

  double get width => fill.width;

  void paint(Canvas canvas, Offset offset) {
    stroke.paint(canvas, offset);
    fill.paint(canvas, offset);
  }
}
