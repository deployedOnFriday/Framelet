import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/services/danmaku_service.dart';
import 'package:framelet/widgets/danmaku_overlay.dart';

void main() {
  testWidgets('弹幕层会按 B 站样式绘制当前时间窗口内的彩色弹幕', (tester) async {
    final clock = ValueNotifier<double>(10);
    addTearDown(clock.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: DanmakuOverlay(
            comments: const [
              DanmakuComment(
                timeSec: 9,
                mode: 1,
                color: 0xFFFFFF,
                text: '这是一条测试弹幕',
              ),
              DanmakuComment(
                timeSec: 9,
                mode: 1,
                color: 0xFF0000,
                text: '彩色弹幕',
              ),
              DanmakuComment(
                timeSec: 9,
                mode: 1,
                color: 0x000000,
                text: '黑色弹幕',
              ),
            ],
            clock: clock,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await expectLater(
      find.byType(DanmakuOverlay),
      matchesGoldenFile('goldens/danmaku_overlay.png'),
    );
  });
}
