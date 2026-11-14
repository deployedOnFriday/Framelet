import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/widgets/subtitle_picker_dialog.dart';

void main() {
  testWidgets('点击字幕弹窗选项会带着 value 关闭', (tester) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showDialog<String>(
                    context: context,
                    builder: (_) => const SubtitlePickerDialog(
                      entries: [
                        SubtitlePickerEntry(
                          value: 'track:1',
                          label: '1 中上英下-ASS',
                          selected: true,
                        ),
                        SubtitlePickerEntry(
                          value: 'track:2',
                          label: '2 简体中文-SRT',
                        ),
                        SubtitlePickerEntry.divider(),
                        SubtitlePickerEntry(value: 'pick', label: '加载外挂字幕…'),
                      ],
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('1 中上英下-ASS'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);

    await tester.tap(find.text('2 简体中文-SRT'));
    await tester.pumpAndSettle();

    expect(result, 'track:2');
    expect(find.text('2 简体中文-SRT'), findsNothing);
  });

  testWidgets('提示行与分隔线不可点击', (tester) async {
    String? result = 'unset';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showDialog<String>(
                    context: context,
                    builder: (_) => const SubtitlePickerDialog(
                      entries: [
                        SubtitlePickerEntry.hint('未发现内嵌或同名字幕'),
                        SubtitlePickerEntry.divider(),
                        SubtitlePickerEntry(value: 'no', label: '关闭字幕'),
                      ],
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('未发现内嵌或同名字幕'));
    await tester.pumpAndSettle();

    expect(result, 'unset');
    expect(find.byType(SubtitlePickerDialog), findsOneWidget);
  });
}
