import 'dart:math' as math;

import '../services/danmaku_service.dart';

/// 预先计算每条弹幕使用的轨道。
///
/// 旧实现直接 `hashCode % laneCount`，同一轨道的弹幕会互相追尾遮挡。
/// 这里按时间顺序模拟每条弹幕的运动，只有不会追上前一条弹幕的轨道才可用；
/// 找不到空轨时返回 -1，绘制层直接跳过该条，宁可少画也不叠字。
class DanmakuLaneLayout {
  const DanmakuLaneLayout._(this._lanes);

  static const empty = DanmakuLaneLayout._([]);

  final List<int> _lanes;

  int get length => _lanes.length;

  int laneOf(int index) {
    if (index < 0 || index >= _lanes.length) return -1;
    return _lanes[index];
  }

  static DanmakuLaneLayout assign({
    required List<DanmakuComment> comments,
    required double viewportWidth,
    required double viewportHeight,
    required double fontSize,
    required double lifetimeSeconds,
    required int laneCount,
    required double Function(String text) measureWidth,
  }) {
    if (comments.isEmpty ||
        viewportWidth <= 0 ||
        viewportHeight <= 0 ||
        lifetimeSeconds <= 0) {
      return empty;
    }

    final laneGap = (fontSize * 1.72).clamp(26.0, 54.0).toDouble();
    final visibleLanes = ((viewportHeight - 90.0 - 74.0) / laneGap).floor() + 1;
    final lanes = laneCount.clamp(1, math.max(1, visibleLanes)).toInt();
    final scrollTracks = List.generate(lanes, (_) => <_ScrollTrack>[]);
    final topFixedTracks = List.generate(lanes, (_) => <_FixedTrack>[]);
    final bottomFixedTracks = List.generate(lanes, (_) => <_FixedTrack>[]);
    final placements = List<int>.filled(comments.length, -1);

    for (var index = 0; index < comments.length; index++) {
      final comment = comments[index];
      final width = measureWidth(comment.text);
      final start = comment.timeSec;

      if (comment.mode == 4 || comment.mode == 5) {
        final top = comment.mode == 5;
        final fixedTracks = top ? topFixedTracks : bottomFixedTracks;
        final track = _FixedTrack(
          start: start,
          width: width,
          viewportWidth: viewportWidth,
        );
        final lane = _findFixedLane(
          lanes: lanes,
          track: track,
          fixedTracks: fixedTracks,
          scrollTracks: top ? scrollTracks : null,
        );
        placements[index] = lane;
        if (lane >= 0) {
          fixedTracks[lane].add(track);
        }
        continue;
      }

      final speed =
          (viewportWidth + width + _horizontalPadding) / lifetimeSeconds;
      final track = _ScrollTrack(
        start: start,
        width: width,
        speed: speed,
        viewportWidth: viewportWidth,
        goneAt:
            start +
            lifetimeSeconds *
                (viewportWidth + width) /
                (viewportWidth + width + _horizontalPadding),
      );
      final lane = _findScrollLane(
        lanes: lanes,
        track: track,
        scrollTracks: scrollTracks,
        topFixedTracks: topFixedTracks,
      );
      placements[index] = lane;
      if (lane >= 0) {
        scrollTracks[lane].add(track);
      }
    }

    return DanmakuLaneLayout._(placements);
  }

  static const _horizontalPadding = 40.0;
  static const _fixedDuration = 4.0;
  static const _entryGap = 8.0;

  static int _findScrollLane({
    required int lanes,
    required _ScrollTrack track,
    required List<List<_ScrollTrack>> scrollTracks,
    required List<List<_FixedTrack>> topFixedTracks,
  }) {
    for (var lane = 0; lane < lanes; lane++) {
      final active = scrollTracks[lane]
        ..removeWhere((previous) => previous.goneAt <= track.start);
      if (active.any((previous) => track.conflictsWith(previous))) {
        continue;
      }
      final fixed = topFixedTracks[lane]
        ..removeWhere((fixedTrack) => fixedTrack.end <= track.start);
      if (fixed.any((fixedTrack) => track.hitsFixed(fixedTrack))) {
        continue;
      }
      return lane;
    }
    return -1;
  }

  static int _findFixedLane({
    required int lanes,
    required _FixedTrack track,
    required List<List<_FixedTrack>> fixedTracks,
    required List<List<_ScrollTrack>>? scrollTracks,
  }) {
    for (var lane = 0; lane < lanes; lane++) {
      final active = fixedTracks[lane]
        ..removeWhere((previous) => previous.end <= track.start);
      if (active.any(
        (previous) => previous.start < track.end && track.start < previous.end,
      )) {
        continue;
      }
      if (scrollTracks != null) {
        final scrolling = scrollTracks[lane]
          ..removeWhere((previous) => previous.goneAt <= track.start);
        if (scrolling.any((previous) => previous.hitsFixed(track))) {
          continue;
        }
      }
      return lane;
    }
    return -1;
  }
}

class _ScrollTrack {
  const _ScrollTrack({
    required this.start,
    required this.width,
    required this.speed,
    required this.viewportWidth,
    required this.goneAt,
  });

  final double start;
  final double width;
  final double speed;
  final double viewportWidth;
  final double goneAt;

  /// 当前弹幕入场时，上一条弹幕是否已经完全进入且留出间距；
  /// 以及速度更快时，是否会在上一条离开画面前追上它。
  bool conflictsWith(_ScrollTrack previous) {
    final elapsed = start - previous.start;
    if (elapsed < 0 || previous.goneAt <= start) return false;
    if (elapsed * previous.speed <
        previous.width + DanmakuLaneLayout._entryGap) {
      return true;
    }
    if (speed <= previous.speed) return false;

    // 两条弹幕的间距随时间线性缩小，用入场时的间距和相对速度求追尾时间。
    final entryGap = elapsed * previous.speed - previous.width;
    final catchUpTime = entryGap / (speed - previous.speed);
    return start + catchUpTime < previous.goneAt;
  }

  bool hitsFixed(_FixedTrack fixed) {
    final start = math.max(this.start, fixed.start);
    final end = math.min(goneAt, fixed.end);
    if (end <= start) return false;

    double leftAt(double time) => viewportWidth - (time - this.start) * speed;
    final firstLeft = leftAt(start);
    final lastLeft = leftAt(end);
    final left = math.min(firstLeft, lastLeft);
    final right = math.max(firstLeft, lastLeft) + width;
    return right > fixed.left && left < fixed.right;
  }
}

class _FixedTrack {
  _FixedTrack({
    required this.start,
    required this.width,
    required this.viewportWidth,
  });

  final double start;
  final double width;
  final double viewportWidth;

  double get end => start + DanmakuLaneLayout._fixedDuration;
  double get left => (viewportWidth - width) / 2;
  double get right => left + width;
}
