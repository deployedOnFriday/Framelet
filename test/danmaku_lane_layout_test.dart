import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/services/danmaku_service.dart';
import 'package:framelet/widgets/danmaku_lane_layout.dart';

void main() {
  test('密集弹幕分配到同一轨道时不会互相遮挡', () {
    const width = 1280.0;
    const height = 720.0;
    const fontSize = 18.0;
    const lifetime = 16.0;
    const lanes = 5;
    const textWidth = 110.0;
    final comments = List.generate(
      80,
      (index) => DanmakuComment(
        timeSec: index * 0.18,
        mode: 1,
        color: 0xFFFFFF,
        text: '弹幕 $index',
      ),
    );

    final layout = DanmakuLaneLayout.assign(
      comments: comments,
      viewportWidth: width,
      viewportHeight: height,
      fontSize: fontSize,
      lifetimeSeconds: lifetime,
      laneCount: lanes,
      measureWidth: (_) => textWidth,
    );

    final assigned = <int>{};
    for (var index = 0; index < comments.length; index++) {
      if (layout.laneOf(index) >= 0) assigned.add(layout.laneOf(index));
    }
    expect(assigned.length, lanes);

    final speed = (width + textWidth + 40) / lifetime;
    for (var first = 0; first < comments.length; first++) {
      final lane = layout.laneOf(first);
      if (lane < 0) continue;
      for (var second = first + 1; second < comments.length; second++) {
        if (layout.laneOf(second) != lane) continue;
        final firstStart = comments[first].timeSec;
        final secondStart = comments[second].timeSec;
        final end = (firstStart + lifetime).clamp(0.0, secondStart + lifetime);
        for (var time = secondStart; time <= end; time += 0.02) {
          final firstLeft = width - (time - firstStart) * speed;
          final secondLeft = width - (time - secondStart) * speed;
          final overlaps =
              firstLeft < secondLeft + textWidth &&
              secondLeft < firstLeft + textWidth;
          expect(
            overlaps,
            isFalse,
            reason:
                '第 $first 条与第 $second 条在 ${time.toStringAsFixed(2)}s '
                '的同一轨道 $lane 上重叠',
          );
        }
      }
    }
  });

  test('没有空轨道时跳过弹幕而不是强行叠字', () {
    final comments = List.generate(
      30,
      (index) => DanmakuComment(
        timeSec: index * 0.02,
        mode: 1,
        color: 0xFFFFFF,
        text: '同屏弹幕 $index',
      ),
    );

    final layout = DanmakuLaneLayout.assign(
      comments: comments,
      viewportWidth: 1280,
      viewportHeight: 720,
      fontSize: 18,
      lifetimeSeconds: 16,
      laneCount: 3,
      measureWidth: (_) => 100,
    );

    expect(List.generate(comments.length, layout.laneOf), contains(-1));
  });
}
