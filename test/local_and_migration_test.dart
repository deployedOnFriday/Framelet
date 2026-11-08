import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/models/media_source.dart';
import 'package:framelet/services/credential_store.dart';
import 'package:framelet/services/framelet_store.dart';
import 'package:framelet/services/local_media_service.dart';
import 'package:framelet/services/media_library.dart';
import 'package:framelet/services/playback_history.dart';
import 'package:framelet/services/subtitle_service.dart';

class _MemoryCredentialStore extends CredentialStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> readSources() async => values['framelet.sources'];

  @override
  Future<void> writeSources(String json) async =>
      values['framelet.sources'] = json;

  @override
  Future<String?> readPassword(String sourceId) async =>
      values['pwd.$sourceId'];

  @override
  Future<void> writePassword(String sourceId, String password) async =>
      values['pwd.$sourceId'] = password;

  @override
  Future<void> deletePassword(String sourceId) async =>
      values.remove('pwd.$sourceId');
}

void main() {
  group('本地目录媒体源', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('framelet_local_');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('扫描电影、剧集和动漫，隐藏文件跳过、花絮保留入库', () async {
      Future<void> create(String relative, [String content = 'x']) async {
        final file = File('${root.path}${Platform.pathSeparator}$relative');
        await file.parent.create(recursive: true);
        await file.writeAsString(content);
      }

      await create('Movies/流浪地球.2023.mp4');
      await create('TV/Signal/Signal.S01E01.mkv');
      await create('TV/Signal/Signal.S01E02.mkv');
      await create('TV/Signal/trailer.mp4');
      await create('Anime/进击的巨人/进击的巨人.第01集.mp4');
      await create('Anime/进击的巨人/进击的巨人.第02集.mp4');
      await create('Movies/.hidden.mp4');

      final source = MediaSource(
        id: 'local',
        name: '本地测试',
        address: root.path,
        username: '',
        kind: MediaSourceKind.local,
      );
      final videos = (await LocalMediaService.scan(source)).videos;

      // 花絮（trailer.mp4）保留入库，详情页单独分区展示；
      // 隐藏文件（.hidden.mp4）仍被跳过。
      expect(videos, hasLength(6));
      expect(videos.every((video) => !video.path.contains(r'\')), isTrue);
      expect(
        videos.any((video) => video.path.contains('trailer.mp4')),
        isTrue,
      );
      expect(videos.any((video) => video.path.contains('.hidden')), isFalse);
      expect(
        videos.where((video) => video.kind == MediaKind.movie),
        hasLength(1),
      );
      expect(
        videos.where((video) => video.kind == MediaKind.series),
        hasLength(3),
      );
      expect(
        videos.where((video) => video.kind == MediaKind.anime),
        hasLength(2),
      );
    });

    test('藏得很深的影片目录也能扫描到（不设层级上限）', () async {
      Future<void> createDeepMovie(int levels) async {
        final segments = List.generate(levels, (index) => 'L${index + 1}');
        final directory = Directory(
          '${root.path}${Platform.pathSeparator}'
          '${segments.join(Platform.pathSeparator)}',
        );
        await directory.create(recursive: true);
        await File(
          '${directory.path}${Platform.pathSeparator}藏得深.2024.mp4',
        ).writeAsString('x');
      }

      // 真实媒体库常见的深层结构必须都能扫到。
      await createDeepMovie(10);
      await createDeepMovie(16);

      final source = MediaSource(
        id: 'local-deep',
        name: '本地测试',
        address: root.path,
        username: '',
        kind: MediaSourceKind.local,
      );
      final result = await LocalMediaService.scan(source);

      expect(result.videos, hasLength(2));
      expect(
        result.videos.map((video) => video.path),
        contains(contains('L1/L2/L3/L4/L5/L6/L7/L8/L9/L10/藏得深.2024.mp4')),
      );
      expect(
        result.videos.map((video) => video.path),
        contains(contains('L16/藏得深.2024.mp4')),
      );
      expect(result.truncated, isFalse);
    });

    test('发现同名字幕并按语言标记展示', () async {
      final video = File(
        '${root.path}${Platform.pathSeparator}电影.2026.mp4',
      );
      await video.writeAsString('video');
      await File(
        '${root.path}${Platform.pathSeparator}电影.2026.zh.srt',
      ).writeAsString('subtitle');
      await File(
        '${root.path}${Platform.pathSeparator}电影.2026.en.ass',
      ).writeAsString('subtitle');
      await File(
        '${root.path}${Platform.pathSeparator}其他.srt',
      ).writeAsString('subtitle');

      final source = MediaSource(
        id: 'local',
        name: '本地测试',
        address: root.path,
        username: '',
        kind: MediaSourceKind.local,
      );
      final subtitles = await SubtitleService.discover(
        source,
        LocalMediaService.normalizePath(video.path),
        '',
      );

      expect(subtitles, hasLength(2));
      expect(subtitles.map((item) => item.language), containsAll(['中文', '英语']));
    });

    test('同步会扫描未连接的本地源，未刮削条目用渐变封面展示', () async {
      final video = File('${root.path}${Platform.pathSeparator}电影.mp4');
      await video.writeAsString('video');

      final library = MediaLibrary(
        store: _MemoryCredentialStore(),
        db: MemoryFrameletStore(),
      )..autoScrapeAfterScan = false;
      final source = MediaSource(
        id: 'local-sync',
        name: '本地测试',
        address: root.path,
        username: '',
        kind: MediaSourceKind.local,
      );
      await library.addOrUpdateSource(source);

      final synced = await library.syncAll();

      expect(synced, 1);
      expect(library.sources.single.connected, isTrue);
      expect(
        library.findVideo(
          source.id,
          LocalMediaService.normalizePath(video.path),
        ),
        isNotNull,
      );
      final movies = library.byKind(MediaKind.movie);
      expect(movies, hasLength(1));
      expect(movies.single.posterPath, isNull);
    });

    test('重复同步未变化的文件走增量路径，文件变化后才更新条目', () async {
      final video = File('${root.path}${Platform.pathSeparator}电影.mp4');
      await video.writeAsString('video');

      final library = MediaLibrary(
        store: _MemoryCredentialStore(),
        db: MemoryFrameletStore(),
      )..autoScrapeAfterScan = false;
      final source = MediaSource(
        id: 'local-incremental',
        name: '本地测试',
        address: root.path,
        username: '',
        kind: MediaSourceKind.local,
      );
      await library.addOrUpdateSource(source);
      await library.syncAll();

      final path = LocalMediaService.normalizePath(video.path);
      final first = library.findVideo(source.id, path);
      expect(first, isNotNull);
      expect(library.scanProgress, contains('新增 1'));

      // 文件没变：复用上次的对象，不重新刮削、不重写数据库。
      await library.syncAll();
      expect(library.scanProgress, contains('无文件变化'));
      expect(identical(library.findVideo(source.id, path), first), isTrue);

      // 文件变了：条目被替换，统计为更新。
      await video.writeAsString('video changed');
      await library.syncAll();
      expect(library.scanProgress, contains('更新 1'));
      expect(identical(library.findVideo(source.id, path), first), isFalse);
    });

    test('定时扫描间隔可配置、可关闭并持久化', () async {
      final store = _MemoryCredentialStore();
      final library = MediaLibrary(store: store, db: MemoryFrameletStore());
      await library.load();
      expect(library.autoScanInterval, const Duration(minutes: 30));

      await library.setAutoScanInterval(const Duration(hours: 2));
      expect(library.autoScanInterval, const Duration(hours: 2));
      library.stopAutoScan();

      final reopened = MediaLibrary(store: store, db: MemoryFrameletStore());
      await reopened.load();
      expect(reopened.autoScanInterval, const Duration(hours: 2));

      await reopened.setAutoScanInterval(null);
      expect(reopened.autoScanInterval, isNull);
      reopened.stopAutoScan();
    });

    test('同一时间只允许一轮扫描，重复触发不会叠加', () async {
      final video = File('${root.path}${Platform.pathSeparator}电影.mp4');
      await video.writeAsString('video');

      final library = MediaLibrary(
        store: _MemoryCredentialStore(),
        db: MemoryFrameletStore(),
      )..autoScrapeAfterScan = false;
      final source = MediaSource(
        id: 'local-lock',
        name: '本地测试',
        address: root.path,
        username: '',
        kind: MediaSourceKind.local,
      );
      await library.addOrUpdateSource(source);

      final first = library.scan(source.id);
      expect(library.isScanning, isTrue);
      // 第二轮被互斥挡掉，同步返回（不会产生第二份扫描任务）。
      final second = library.scan(source.id);
      expect(library.isScanning, isTrue);
      await Future.wait([first, second]);
      expect(library.isScanning, isFalse);
      expect(library.byKind(MediaKind.movie), hasLength(1));
    });

    test('蓝光原盘 BDMV 只保留主片，并用片名目录命名', () async {
      Future<void> create(String relative, int bytes) async {
        final file = File('${root.path}${Platform.pathSeparator}$relative');
        await file.parent.create(recursive: true);
        await file.writeAsString('x' * bytes);
      }

      await create('Movies/一代宗师 (2013)/BDMV/STREAM/00000.m2ts', 10);
      await create('Movies/一代宗师 (2013)/BDMV/STREAM/00001.m2ts', 500);
      await create('Movies/一代宗师 (2013)/BDMV/STREAM/00002.m2ts', 20);
      // 同一文件夹里同时有压制版：应合并成一张卡的两个版本。
      await create('Movies/一代宗师 (2013)/一代宗师.2013.1080p.mkv', 300);

      final library = MediaLibrary(
        store: _MemoryCredentialStore(),
        db: MemoryFrameletStore(),
      )..autoScrapeAfterScan = false;
      final source = MediaSource(
        id: 'local-bdmv',
        name: '本地测试',
        address: root.path,
        username: '',
        kind: MediaSourceKind.local,
      );
      await library.addOrUpdateSource(source);
      await library.syncAll();

      final movies = library.byKind(MediaKind.movie);
      expect(movies, hasLength(1));
      expect(movies.single.title, '一代宗师');
      final versions = library.versionsOf(movies.single);
      expect(versions, hasLength(2));
      expect(
        versions.map((video) => video.path),
        contains(endsWith('/00001.m2ts')),
      );
      expect(
        versions.map((video) => video.path),
        contains(endsWith('.mkv')),
      );
      final disc = versions.firstWhere(
        (video) => video.path.endsWith('/00001.m2ts'),
      );
      expect(
        library.findVideo(source.id, disc.path)?.sizeBytes,
        500,
      );
    });

    test('播放历史能按文件夹找回剧名与集数', () async {
      Future<void> create(String relative) async {
        final file = File('${root.path}${Platform.pathSeparator}$relative');
        await file.parent.create(recursive: true);
        await file.writeAsString('video');
      }

      await create('TV/Signal/Signal.S01E01.mkv');
      await create('TV/Signal/Signal.S01E02.mkv');
      await create('TV/Signal/Signal.S02E03.mkv');

      final library = MediaLibrary(
        store: _MemoryCredentialStore(),
        db: MemoryFrameletStore(),
      )..autoScrapeAfterScan = false;
      const sourceId = 'local-history';
      await library.addOrUpdateSource(
        MediaSource(
          id: sourceId,
          name: '本地测试',
          address: root.path,
          username: '',
          kind: MediaSourceKind.local,
        ),
      );
      await library.syncAll();

      String pathOf(String relative) => LocalMediaService.normalizePath(
        '${root.path}${Platform.pathSeparator}$relative',
      );
      final second = library.findVideo(
        sourceId,
        pathOf('TV/Signal/Signal.S01E02.mkv'),
      );
      final third = library.findVideo(
        sourceId,
        pathOf('TV/Signal/Signal.S02E03.mkv'),
      );

      expect(library.aggregateOf(second!).title, 'Signal');
      expect(MediaLibrary.episodeLabelOf(second), '第 2 集');
      expect(MediaLibrary.episodeLabelOf(third!), 'S2E3');
      expect(
        MediaLibrary.seriesTitleForDisplay('Signal.S01E02'),
        'Signal',
      );
      expect(
        MediaLibrary.seriesTitleForDisplay('进击的巨人.第03集'),
        '进击的巨人',
      );
    });
  });

  group('安全存储迁移', () {
    test('媒体源、扫描缓存与播放历史迁入数据库且旧副本被清理', () async {
      final credentials = _MemoryCredentialStore();
      final db = MemoryFrameletStore();
      final source = MediaSource(
        id: 'legacy',
        name: '旧媒体库',
        address: 'https://dav.example.com',
        username: 'user',
      );
      credentials.values['framelet.sources'] = jsonEncode([
        source.toJson()..remove('kind'),
      ]);
      credentials.values['framelet.videos.legacy'] = jsonEncode([
        {
          'sourceId': 'legacy',
          'path': '/电影/测试电影.mp4',
          'title': '测试电影',
          'kind': MediaKind.movie.index,
          'episodeCount': 1,
          'sizeBytes': 1024,
          'modified': null,
          'posterPath': null,
          'summary': null,
          'rating': null,
          'backdropPath': null,
          'genres': <String>[],
          'cast': <Object?>[],
          'releaseDate': null,
          'runtimeSec': null,
          'stillPath': null,
          'episodeTitle': null,
          'tmdbId': null,
          'tmdbTitle': null,
        },
      ]);
      credentials.values['framelet.history'] = jsonEncode([
        {
          'sourceId': 'legacy',
          'path': '/电影/测试电影.mp4',
          'title': '测试电影',
          'kind': MediaKind.movie.index,
          'positionSec': 120.0,
          'durationSec': 600.0,
          'updatedAtMs': 1,
        },
      ]);

      final library = MediaLibrary(store: credentials, db: db);
      await library.load();
      final history = PlaybackHistory.withStore(db, store: credentials);
      await history.load();

      expect(library.sources, hasLength(1));
      expect(library.sources.first.kind, MediaSourceKind.webdav);
      expect(library.findVideo('legacy', '/电影/测试电影.mp4'), isNotNull);
      expect(history.entries, hasLength(1));
      expect(history.entries.first.positionSec, 120.0);
      expect(credentials.values.containsKey('framelet.sources'), isFalse);
      expect(
        credentials.values.containsKey('framelet.videos.legacy'),
        isFalse,
      );
      expect(credentials.values.containsKey('framelet.history'), isFalse);
    });
  });

  group('播放记录', () {
    test('轮播描述使用影片简介而不是文件路径', () {
      const video = ScannedVideo(
        sourceId: 'demo',
        path: '/movies/demo.mkv',
        title: '测试电影',
        kind: MediaKind.movie,
        summary: '这是一段影片简介。',
      );

      final item = toMediaItem(video);

      expect(item?.description, '这是一段影片简介。');
    });

    test('更新进度时保留暂停帧缩略图', () async {
      final history = PlaybackHistory.withStore(
        MemoryFrameletStore(),
        store: _MemoryCredentialStore(),
      );
      await history.record(
        HistoryEntry(
          sourceId: 's1',
          path: '/movies/a.mkv',
          title: '测试电影',
          kind: MediaKind.movie,
          positionSec: 10,
          durationSec: 100,
          thumbnailPath: '/thumbs/a.jpg',
          updatedAtMs: 1,
        ),
      );

      await history.record(
        HistoryEntry(
          sourceId: 's1',
          path: '/movies/a.mkv',
          title: '测试电影',
          kind: MediaKind.movie,
          positionSec: 30,
          durationSec: 100,
          updatedAtMs: 2,
        ),
      );
      expect(history.entries.single.thumbnailPath, '/thumbs/a.jpg');

      await history.setThumbnail('s1', '/movies/a.mkv', '/thumbs/b.jpg');
      expect(history.entries.single.thumbnailPath, '/thumbs/b.jpg');

      await history.remove('s1', '/movies/a.mkv');
      expect(history.entries, isEmpty);
    });
  });
}
