import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/models/media_item.dart';
import 'package:framelet/widgets/recent_playback_card.dart';

void main() {
  testWidgets('右键最近播放卡片可打开删除菜单', (tester) async {
    var deleted = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 420,
              child: RecentPlaybackCard(
                item: const MediaItem(
                  title: '怪奇物语',
                  subtitle: '看到 50%',
                  year: '',
                  colors: [Colors.blue, Colors.indigo],
                  icon: Icons.live_tv_outlined,
                  episodeLabel: '第 2 集',
                ),
                onDelete: () => deleted = true,
              ),
            ),
          ),
        ),
      ),
    );

    final card = find.byType(RecentPlaybackCard);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(card));
    await tester.pump();
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    await mouse.removePointer();

    await tester.tapAt(
      tester.getCenter(card),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('从最近播放移除'), findsOneWidget);
    await tester.tap(find.text('从最近播放移除'));
    await tester.pumpAndSettle();

    expect(deleted, isTrue);
    expect(find.text('从最近播放移除'), findsNothing);
  });
}
