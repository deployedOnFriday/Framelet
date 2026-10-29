import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/app.dart';
import 'package:framelet/services/credential_store.dart';
import 'package:framelet/services/media_library.dart';

/// 测试专用的内存凭据存储，避免触达 Windows 安全存储。
class InMemoryCredentialStore extends CredentialStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> readSources() async => _values['sources'];

  @override
  Future<void> writeSources(String json) async => _values['sources'] = json;

  @override
  Future<String?> readPassword(String sourceId) async =>
      _values['pwd.$sourceId'];

  @override
  Future<void> writePassword(String sourceId, String password) async =>
      _values['pwd.$sourceId'] = password;

  @override
  Future<void> deletePassword(String sourceId) async =>
      _values.remove('pwd.$sourceId');
}

Future<ByteData> _readFont(File file) async {
  final bytes = await file.readAsBytes();
  return ByteData.view(bytes.buffer);
}

Future<void> _pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1440, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  MediaLibrary.instanceForTesting = MediaLibrary(
    store: InMemoryCredentialStore(),
  );
  await tester.pumpWidget(const FrameletApp());
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUpAll(() async {
    final loads = <Future<void>>[];
    final chineseFontFile = File(r'C:\Windows\Fonts\msyh.ttc');
    if (chineseFontFile.existsSync()) {
      final font = FontLoader('Microsoft YaHei UI')
        ..addFont(_readFont(chineseFontFile));
      loads.add(font.load());
    }
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    if (flutterRoot != null) {
      final iconFile = File(
        '$flutterRoot/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
      );
      if (iconFile.existsSync()) {
        final font = FontLoader('MaterialIcons')..addFont(_readFont(iconFile));
        loads.add(font.load());
      }
    }
    await Future.wait(loads);
  });

  testWidgets('首页显示品牌、最近播放和内容分区', (tester) async {
    await _pumpApp(tester);

    expect(find.text('拾帧'), findsOneWidget);
    expect(find.text('Framelet'), findsOneWidget);
    expect(find.text('最近播放'), findsOneWidget);
    expect(find.text('晨光旅途'), findsOneWidget);
    expect(find.text('星海之旅'), findsOneWidget);
    expect(find.text('深海探索'), findsOneWidget);
    expect(find.text('电影'), findsWidgets);
    expect(find.text('电视剧'), findsWidgets);
  });

  testWidgets('侧栏可切换分类与设置页面', (tester) async {
    await _pumpApp(tester);

    await tester.tap(find.byKey(const ValueKey('nav-movie')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('共 6 个条目'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('添加媒体源'), findsOneWidget);
    expect(find.text('还没有媒体源，点击右上角添加'), findsOneWidget);
  });

  testWidgets('可添加真实 WebDAV 媒体源配置', (tester) async {
    await _pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('add-source')));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byKey(const ValueKey('source-name')), '测试媒体库');
    await tester.enterText(
      find.byKey(const ValueKey('source-address')),
      'https://dav.example.org/media',
    );
    await tester.enterText(find.byType(TextFormField).at(3), 'tester');
    await tester.enterText(find.byType(TextFormField).at(4), 'secret');
    await tester.tap(find.byKey(const ValueKey('save-source')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('测试媒体库'), findsOneWidget);
    expect(find.text('https://dav.example.org/media/'), findsOneWidget);
    expect(find.text('未同步 · 最近同步 尚未同步'), findsOneWidget);
  });

  testWidgets('首页黄金截图', (tester) async {
    await _pumpApp(tester);
    await expectLater(
      find.byType(FrameletApp),
      matchesGoldenFile('goldens/home_page.png'),
    );
  });

  testWidgets('设置页黄金截图', (tester) async {
    await _pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(
      find.byType(FrameletApp),
      matchesGoldenFile('goldens/settings_page.png'),
    );
  });
}
