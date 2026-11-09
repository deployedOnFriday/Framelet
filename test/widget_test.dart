import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/app.dart';
import 'package:framelet/core/theme/app_theme.dart';
import 'package:framelet/models/media_item.dart';
import 'package:framelet/models/media_source.dart';
import 'package:framelet/pages/detail_page.dart';
import 'package:framelet/pages/home_page.dart';
import 'package:framelet/services/credential_store.dart';
import 'package:framelet/services/framelet_store.dart';
import 'package:framelet/services/media_library.dart';
import 'package:framelet/services/playback_history.dart';
import 'package:framelet/services/theme_controller.dart';
import 'package:framelet/widgets/banner_carousel.dart';
import 'package:framelet/widgets/media_artwork.dart';
import 'package:framelet/widgets/poster_card.dart';
import 'package:framelet/widgets/recent_playback_card.dart';
import 'package:framelet/widgets/side_navigation.dart';

/// 测试专用的内存凭据存储，避免触达 Windows 安全存储。
/// 注意：必须重写全部读写方法——flutter_secure_storage 的 read 在
/// widget 测试的假异步 zone 里会永久挂起（曾导致内容态用例集体卡死）。
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

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// 测试用媒体库：记录扫描调用，避免真实网络/磁盘扫描拖慢界面测试。
class _TestMediaLibrary extends MediaLibrary {
  _TestMediaLibrary({super.store, super.db});

  final List<String> scannedSourceIds = [];

  @override
  Future<void> scan(String sourceId) async {
    scannedSourceIds.add(sourceId);
    scanStatus = ScanStatus.done;
    scanProgress = '扫描完成';
    notifyListeners();
  }
}

late _TestMediaLibrary _library;

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
  _library = _TestMediaLibrary(
    store: InMemoryCredentialStore(),
    db: MemoryFrameletStore(),
  );
  MediaLibrary.instanceForTesting = _library;
  PlaybackHistory.instanceForTesting = PlaybackHistory.withStore(
    MemoryFrameletStore(),
  );
  await tester.pumpWidget(const FrameletApp());
  await tester.pump(const Duration(milliseconds: 300));
}

/// 构造一批已刮削条目：每个条目独占一个目录，避免被聚合合并。
List<ScannedVideo> _sampleVideos() {
  const entries = <(String, MediaKind)>[
    ('风之谷', MediaKind.movie),
    ('千与千寻', MediaKind.movie),
    ('星际穿越', MediaKind.movie),
    ('火星救援', MediaKind.movie),
    ('盗梦空间', MediaKind.movie),
    ('沙丘', MediaKind.movie),
    ('银翼杀手', MediaKind.movie),
    ('降临', MediaKind.movie),
    ('瞬息全宇宙', MediaKind.movie),
    ('想见你', MediaKind.series),
    ('漫长的季节', MediaKind.series),
    ('三体', MediaKind.series),
    ('黑镜', MediaKind.series),
    ('进击的巨人', MediaKind.anime),
    ('鬼灭之刃', MediaKind.anime),
    ('紫罗兰永恒花园', MediaKind.anime),
    ('向往的生活', MediaKind.variety),
  ];
  return [
    for (var i = 0; i < entries.length; i++)
      ScannedVideo(
        sourceId: 'local',
        path: 'D:/Media/${entries[i].$1}/${entries[i].$1}.mkv',
        title: entries[i].$1,
        kind: entries[i].$2,
        sizeBytes: 1024 * 1024 * 1200,
        rating: '8.${i % 10}',
        tmdbId: 1000 + i,
      ),
  ];
}

/// 带内容的媒体库：用于海报墙与搜索面板的视觉/行为校验。
Future<void> _pumpAppWithLibrary(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1440, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final store = MemoryFrameletStore();
  await store.saveSources([
    MediaSource(
      id: 'local',
      name: '本机媒体库',
      kind: MediaSourceKind.local,
      address: 'D:/Media',
      username: '',
      connected: true,
      lastSync: '刚刚',
    ),
  ]);
  await store.saveVideos('local', _sampleVideos());
  final library = _TestMediaLibrary(
    store: InMemoryCredentialStore(),
    db: store,
  );
  await library.load();
  _library = library;
  MediaLibrary.instanceForTesting = library;
  PlaybackHistory.instanceForTesting = PlaybackHistory.withStore(
    MemoryFrameletStore(),
  );
  // 横幅轮播内容随机会导致文本断言与 golden 截图不稳定，固定随机源
  HomePage.bannerShuffleRandom = Random(2026);
  addTearDown(() => HomePage.bannerShuffleRandom = null);
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

  testWidgets('首页显示空媒体库引导', (tester) async {
    await _pumpApp(tester);

    // 品牌标已从侧栏移除，只剩窗口标题栏
    expect(find.byTooltip('拾帧 Framelet'), findsNothing);
    expect(find.byKey(const ValueKey('nav-search')), findsOneWidget);
    expect(find.text('媒体库还是空的'), findsOneWidget);
    expect(find.text('去添加媒体源'), findsOneWidget);
    expect(find.text('最近播放'), findsNothing);
  });

  testWidgets('侧栏搜索面板可展开、搜索并关闭', (tester) async {
    await _pumpApp(tester);

    await tester.tap(find.byKey(const ValueKey('nav-search')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-field')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('search-field')),
      '不存在的片名',
    );
    await tester.pumpAndSettle();
    expect(find.text('没有找到「不存在的片名」'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('search-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-field')), findsNothing);
  });

  testWidgets('Ctrl+K 可唤起搜索面板', (tester) async {
    await _pumpApp(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-field')), findsOneWidget);
  });

  testWidgets('有内容时首页海报墙完整铺开并保持 2:3 比例', (tester) async {
    await _pumpAppWithLibrary(tester);

    expect(find.text('媒体库还是空的'), findsNothing);
    expect(find.byType(PosterCard), findsWidgets);
    final cardSize = tester.getSize(find.byType(PosterCard).first);
    expect(cardSize.width, greaterThanOrEqualTo(168));
    expect(
      cardSize.height,
      closeTo(PosterCard.extentForWidth(cardSize.width), 0.1),
    );
    final artworkSize = tester.getSize(
      find
          .descendant(
            of: find.byType(PosterCard).first,
            matching: find.byType(MediaArtwork),
          )
          .first,
    );
    expect(artworkSize.width / artworkSize.height, closeTo(2 / 3, 0.001));
    // 横幅轮播随机抽取，标题可能撞车——限定海报卡内断言
    expect(find.widgetWithText(PosterCard, '风之谷'), findsOneWidget);
    // 首页海报墙由响应式网格铺开，不再出现横向滚动列表
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('点搜索后左栏展开成输入框，结果实时显示在右侧', (tester) async {
    await _pumpAppWithLibrary(tester);
    await tester.tap(find.byKey(const ValueKey('nav-search')));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(SideNavigation)).width,
      SideNavigation.expandedWidth,
    );
    await tester.enterText(find.byKey(const ValueKey('search-field')), '星际');
    await tester.pumpAndSettle();

    // 搜索结果层是覆盖层，首页内容仍在树中——断言必须限定在结果网格内
    final grid = find.byKey(const ValueKey('search-results-grid'));
    expect(grid, findsOneWidget);
    final resultTitle = find.descendant(of: grid, matching: find.text('星际穿越'));
    expect(resultTitle, findsOneWidget);
    expect(find.descendant(of: grid, matching: find.text('风之谷')), findsNothing);

    final fieldRect = tester.getRect(
      find.byKey(const ValueKey('search-field')),
    );
    final resultRect = tester.getRect(resultTitle);
    expect(resultRect.left, greaterThan(fieldRect.right));

    await tester.tap(find.byKey(const ValueKey('search-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-field')), findsNothing);
    expect(
      tester.getSize(find.byType(SideNavigation)).width,
      SideNavigation.width,
    );
  });

  testWidgets('侧栏可切换分类与设置页面', (tester) async {
    await _pumpApp(tester);

    await tester.tap(find.byKey(const ValueKey('nav-movie')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('共 0 个条目'), findsOneWidget);
    expect(find.text('这里还没有内容，去「设置 → 媒体源」添加并同步你的媒体库'), findsOneWidget);

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
    await tester.pumpAndSettle();

    expect(find.text('测试媒体库'), findsOneWidget);
    expect(find.text('https://dav.example.org/media'), findsOneWidget);
    expect(find.text('未同步 · 最近同步 尚未同步'), findsOneWidget);
    expect(_library.scannedSourceIds, hasLength(1));
  });

  testWidgets('可添加本地目录媒体源', (tester) async {
    final directory = Directory.systemTemp.createTempSync('framelet_ui_');
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    await _pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('add-source')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('本地目录').last);
    await tester.pump(const Duration(milliseconds: 200));

    await tester.enterText(find.byKey(const ValueKey('source-name')), '本机电影');
    await tester.enterText(
      find.byKey(const ValueKey('source-local-path')),
      directory.path,
    );
    await tester.tap(find.byKey(const ValueKey('save-source')));
    await tester.pumpAndSettle();

    expect(find.text('本机电影'), findsOneWidget);
    expect(find.text('本地目录'), findsOneWidget);
    expect(find.text(directory.path), findsOneWidget);
    expect(_library.scannedSourceIds, hasLength(1));
  });

  testWidgets('右键移除最近播放后首页立即刷新', (tester) async {
    await _pumpApp(tester);
    await PlaybackHistory.instance.record(
      HistoryEntry(
        sourceId: 'local',
        path: r'D:\Media\怪奇物语\S01E02.mkv',
        title: '怪奇物语',
        kind: MediaKind.series,
        positionSec: 1200,
        durationSec: 3000,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await tester.pump();
    expect(find.text('怪奇物语'), findsOneWidget);

    await tester.tapAt(
      tester.getCenter(find.byType(RecentPlaybackCard)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('从最近播放移除'));
    await tester.pumpAndSettle();

    expect(find.text('怪奇物语'), findsNothing);
    expect(find.text('最近播放'), findsNothing);
  });

  testWidgets('首页最近播放同一部作品只显示最新一条', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final store = MemoryFrameletStore();
    await store.saveSources([
      MediaSource(
        id: 'local',
        name: '本机媒体库',
        kind: MediaSourceKind.local,
        address: 'D:/Media',
        username: '',
        connected: true,
        lastSync: '刚刚',
      ),
    ]);
    await store.saveVideos('local', const [
      ScannedVideo(
        sourceId: 'local',
        path: r'D:\Media\成何体统\S01E01.mkv',
        title: '成何体统.S01E01',
        kind: MediaKind.series,
        tmdbId: 9001,
        tmdbTitle: '成何体统',
      ),
      ScannedVideo(
        sourceId: 'local',
        path: r'D:\Media\成何体统\S01E02.mkv',
        title: '成何体统.S01E02',
        kind: MediaKind.series,
        tmdbId: 9001,
        tmdbTitle: '成何体统',
      ),
      ScannedVideo(
        sourceId: 'local',
        path: r'D:\Media\一代宗师\一代宗师.2013.1080p.mkv',
        title: '一代宗师.2013.1080p',
        kind: MediaKind.movie,
        tmdbId: 44826,
        tmdbTitle: '一代宗师',
      ),
      ScannedVideo(
        sourceId: 'local',
        path: r'D:\Media\一代宗师\一代宗师.2013.2160p.mkv',
        title: '一代宗师.2013.2160p',
        kind: MediaKind.movie,
        tmdbId: 44826,
        tmdbTitle: '一代宗师',
      ),
    ]);
    final library = _TestMediaLibrary(
      store: InMemoryCredentialStore(),
      db: store,
    );
    await library.load();
    MediaLibrary.instanceForTesting = library;
    PlaybackHistory.instanceForTesting = PlaybackHistory.withStore(
      MemoryFrameletStore(),
    );
    await tester.pumpWidget(const FrameletApp());
    await tester.pump(const Duration(milliseconds: 300));

    final now = DateTime.now().millisecondsSinceEpoch;
    await PlaybackHistory.instance.record(
      HistoryEntry(
        sourceId: 'local',
        path: r'D:\Media\成何体统\S01E01.mkv',
        title: '成何体统.S01E01',
        kind: MediaKind.series,
        positionSec: 300,
        durationSec: 2520,
        updatedAtMs: now - 1,
      ),
    );
    await PlaybackHistory.instance.record(
      HistoryEntry(
        sourceId: 'local',
        path: r'D:\Media\成何体统\S01E02.mkv',
        title: '成何体统.S01E02',
        kind: MediaKind.series,
        positionSec: 1200,
        durationSec: 2520,
        updatedAtMs: now - 2,
      ),
    );
    await PlaybackHistory.instance.record(
      HistoryEntry(
        sourceId: 'local',
        path: r'D:\Media\一代宗师\一代宗师.2013.1080p.mkv',
        title: '一代宗师.2013.1080p',
        kind: MediaKind.movie,
        positionSec: 600,
        durationSec: 7800,
        updatedAtMs: now - 1,
      ),
    );
    await PlaybackHistory.instance.record(
      HistoryEntry(
        sourceId: 'local',
        path: r'D:\Media\一代宗师\一代宗师.2013.2160p.mkv',
        title: '一代宗师.2013.2160p',
        kind: MediaKind.movie,
        positionSec: 1200,
        durationSec: 7800,
        updatedAtMs: now,
      ),
    );
    await tester.pump();

    // 两集剧 + 两个版本电影 → 最近播放只留「最新一集」和「最新版本」。
    expect(find.byType(RecentPlaybackCard), findsNWidgets(2));
    final seriesCard = find.ancestor(
      of: find.text('成何体统'),
      matching: find.byType(RecentPlaybackCard),
    );
    final movieCard = find.ancestor(
      of: find.text('一代宗师'),
      matching: find.byType(RecentPlaybackCard),
    );
    expect(
      find.descendant(of: seriesCard, matching: find.text('第 2 集')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: movieCard, matching: find.text('4K')),
      findsOneWidget,
    );

    await tester.tapAt(
      tester.getCenter(seriesCard),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('从最近播放移除'));
    await tester.pumpAndSettle();

    // 移除一部剧时只清掉它的各集，电影卡片仍在。
    expect(find.byType(RecentPlaybackCard), findsOneWidget);
    expect(PlaybackHistory.instance.entries, hasLength(2));

    await tester.tapAt(
      tester.getCenter(movieCard),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('从最近播放移除'));
    await tester.pumpAndSettle();

    expect(find.text('最近播放'), findsNothing);
    expect(PlaybackHistory.instance.entries, isEmpty);
  });

  testWidgets('首页白玉横卡黄金截图', (tester) async {
    await _pumpApp(tester);
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final entry in [
      HistoryEntry(
        sourceId: 'local',
        path: r'D:\Media\怪奇物语\S01E02.mkv',
        title: '怪奇物语',
        kind: MediaKind.series,
        positionSec: 1800,
        durationSec: 3000,
        updatedAtMs: now,
      ),
      HistoryEntry(
        sourceId: 'local',
        path: r'D:\Media\挽救计划.mkv',
        title: '挽救计划',
        kind: MediaKind.movie,
        positionSec: 300,
        durationSec: 8940,
        updatedAtMs: now - 1,
      ),
      HistoryEntry(
        sourceId: 'local',
        path: r'D:\Media\成何体统\S01E01.mkv',
        title: '成何体统',
        kind: MediaKind.series,
        positionSec: 30,
        durationSec: 2520,
        updatedAtMs: now - 2,
      ),
      HistoryEntry(
        sourceId: 'local',
        path: r'D:\Media\火星救援.mkv',
        title: '火星救援',
        kind: MediaKind.movie,
        positionSec: 0,
        durationSec: 9120,
        updatedAtMs: now - 3,
      ),
    ]) {
      await PlaybackHistory.instance.record(entry);
    }
    await tester.pump();
    expect(find.byType(RecentPlaybackCard), findsNWidgets(3));

    await expectLater(
      find.byType(FrameletApp),
      matchesGoldenFile('goldens/home_recent_playback.png'),
    );
  });

  testWidgets('首页黄金截图', (tester) async {
    await _pumpApp(tester);
    await expectLater(
      find.byType(FrameletApp),
      matchesGoldenFile('goldens/home_page.png'),
    );
  });

  testWidgets('今日推荐横幅黄金截图', (tester) async {
    tester.view.physicalSize = const Size(1360, 460);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final controller = PageController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(28),
            child: BannerCarousel(
              items: const [
                MediaItem(
                  title: '星际穿越',
                  subtitle: '13.2 GB',
                  year: '2014',
                  colors: [Color(0xFF1E3A5F), Color(0xFF0F172A)],
                  icon: Icons.movie_outlined,
                  rating: '9.4',
                  quality: '4K HDR',
                  description:
                      '近未来地球环境恶化，一支探险队穿越虫洞寻找人类新家园。'
                      '在时间与引力的错位中，父女之间的牵挂成为穿越星际的坐标。',
                ),
              ],
              controller: controller,
              index: 0,
              onPageChanged: (_) {},
              onPlay: (_) {},
              onShowDetails: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(BannerCarousel),
      matchesGoldenFile('goldens/banner_carousel.png'),
    );
  });

  testWidgets('设置页黄金截图', (tester) async {
    await _pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    // 分两步泵：让切页淡入动画的 Ticker 先拿到起始时间戳，再推进完成
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(
      find.byType(FrameletApp),
      matchesGoldenFile('goldens/settings_page.png'),
    );
  });

  testWidgets('播放设置提供标准、弱网与自定义网络缓存', (tester) async {
    await _pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('settings-tab-2')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('网络缓存'), findsOneWidget);
    final standardChip = find.byKey(
      const ValueKey('playback-cache-NetworkCacheMode.standard'),
    );
    final weakChip = find.byKey(
      const ValueKey('playback-cache-NetworkCacheMode.weak'),
    );
    final customChip = find.byKey(
      const ValueKey('playback-cache-NetworkCacheMode.custom'),
    );
    expect(standardChip, findsOneWidget);
    expect(weakChip, findsOneWidget);
    expect(customChip, findsOneWidget);
    expect(
      find.descendant(of: standardChip, matching: find.text('标准')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: weakChip, matching: find.text('弱网')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: customChip, matching: find.text('自定义')),
      findsOneWidget,
    );

    await tester.ensureVisible(customChip);
    await tester.pumpAndSettle();
    await tester.tap(customChip);
    await tester.pumpAndSettle();
    expect(find.text('自定义网络缓存'), findsOneWidget);
    expect(find.byKey(const ValueKey('cache-custom-forward')), findsOneWidget);
    expect(find.byKey(const ValueKey('cache-custom-back')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('cache-custom-readahead')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const ValueKey('cache-custom-forward')),
      '100',
    );
    await tester.tap(find.byKey(const ValueKey('cache-custom-save')));
    await tester.pumpAndSettle();
    expect(find.text('范围 128–2048'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cache-custom-cancel')));
    await tester.pumpAndSettle();
    expect(find.text('自定义网络缓存'), findsNothing);
  });

  testWidgets('弹幕设置只保留自定义源并使用内置服务', (tester) async {
    await _pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('settings-tab-4')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('自定义弹幕源'), findsOneWidget);
    expect(find.text('弹弹play 直连'), findsOneWidget);
    expect(find.text('内置'), findsOneWidget);
    expect(find.text('DanDanPlay'), findsNothing);
    expect(
      find.byKey(const ValueKey('danmaku-dandanplay-switch')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('danmaku-custom-switch')), findsOneWidget);
    expect(find.byKey(const ValueKey('dandanplay-app-id')), findsNothing);
    expect(find.byKey(const ValueKey('dandanplay-app-secret')), findsNothing);
    expect(find.byKey(const ValueKey('danmaku-base-url')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('reset-danmaku-settings')),
      findsOneWidget,
    );
  });

  testWidgets('深色模式首页黄金截图', (tester) async {
    ThemeController.instance.value = ThemeMode.dark;
    addTearDown(() => ThemeController.instance.value = ThemeMode.system);
    await _pumpApp(tester);
    expect(
      Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
      Brightness.dark,
    );
    await expectLater(
      find.byType(FrameletApp),
      matchesGoldenFile('goldens/home_page_dark.png'),
    );
  });

  testWidgets('外观可在浅色深色间切换并生效', (tester) async {
    await _pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('settings-tab-0')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('外观'), findsOneWidget);
    expect(find.text('跟随系统'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('theme-dark')));
    await tester.pumpAndSettle();
    expect(ThemeController.instance.value, ThemeMode.dark);
    expect(
      Theme.of(tester.element(find.text('外观'))).brightness,
      Brightness.dark,
    );

    await tester.tap(find.byKey(const ValueKey('theme-light')));
    await tester.pumpAndSettle();
    expect(ThemeController.instance.value, ThemeMode.light);
    expect(
      Theme.of(tester.element(find.text('外观'))).brightness,
      Brightness.light,
    );

    await expectLater(
      find.byType(FrameletApp),
      matchesGoldenFile('goldens/settings_general.png'),
    );
  });

  testWidgets('深色模式设置页黄金截图', (tester) async {
    ThemeController.instance.value = ThemeMode.dark;
    addTearDown(() => ThemeController.instance.value = ThemeMode.system);
    await _pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('settings-tab-0')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(FrameletApp),
      matchesGoldenFile('goldens/settings_general_dark.png'),
    );
  });

  testWidgets('深色模式详情页无浅色残留', (tester) async {
    ThemeController.instance.value = ThemeMode.dark;
    addTearDown(() => ThemeController.instance.value = ThemeMode.system);
    await _pumpApp(tester);
    MediaLibrary.instanceForTesting = _TestMediaLibrary(
      store: InMemoryCredentialStore(),
      db: MemoryFrameletStore(),
    );

    const video = ScannedVideo(
      sourceId: 'demo',
      path: '/media/星际穿越.2014.2160p.mkv',
      title: '星际穿越',
      kind: MediaKind.movie,
      sizeBytes: 14 * 1024 * 1024 * 1024,
      summary:
          '近未来地球环境恶化，一支探险队穿越虫洞寻找人类新家园。'
          '在时间与引力的错位中，父女之间的牵挂成为穿越星际的坐标。',
      rating: '9.4',
      genres: ['剧情', '科幻'],
      releaseDate: '2014-11-07',
      runtimeSec: 10140,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: const DetailPage(video: video),
      ),
    );
    await tester.pumpAndSettle();

    // 页面骨架必须是暗色：底色取自深色调色板的 background
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, AppColors.dark.background);

    await expectLater(
      find.byType(DetailPage),
      matchesGoldenFile('goldens/detail_page_dark.png'),
    );
  });

  testWidgets('电影多版本共用一张详情页并可切换播放文件', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final store = MemoryFrameletStore();
    await store.saveSources([
      MediaSource(
        id: 'local',
        name: '本机媒体库',
        kind: MediaSourceKind.local,
        address: 'D:/Media',
        username: '',
        connected: true,
        lastSync: '刚刚',
      ),
    ]);
    const videos = [
      ScannedVideo(
        sourceId: 'local',
        path: '/Media/一代宗师/一代宗师.2013.1080p.mkv',
        title: '一代宗师.2013.1080p',
        kind: MediaKind.movie,
        sizeBytes: 3 * 1024 * 1024 * 1024,
        tmdbId: 44826,
        tmdbTitle: '一代宗师',
      ),
      ScannedVideo(
        sourceId: 'local',
        path: '/Media/一代宗师/一代宗师.2013.2160p.HDR.mkv',
        title: '一代宗师.2013.2160p.HDR',
        kind: MediaKind.movie,
        sizeBytes: 12 * 1024 * 1024 * 1024,
        tmdbId: 44826,
        tmdbTitle: '一代宗师',
      ),
    ];
    await store.saveVideos('local', videos);
    final library = _TestMediaLibrary(
      store: InMemoryCredentialStore(),
      db: store,
    );
    await library.load();
    MediaLibrary.instanceForTesting = library;
    PlaybackHistory.instanceForTesting = PlaybackHistory.withStore(
      MemoryFrameletStore(),
    );

    final card = library.byKind(MediaKind.movie).single;
    expect(card.episodeCount, 1);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: DetailPage(video: card),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('版本'), findsOneWidget);
    expect(find.text('3.0 GB'), findsOneWidget);
    expect(find.text('12.0 GB'), findsWidgets);
    expect(find.textContaining('第 1 季'), findsNothing);
    await tester.tap(
      find.byKey(ValueKey('detail-version-${videos.first.path}')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining(videos.first.path), findsOneWidget);
  });
}
