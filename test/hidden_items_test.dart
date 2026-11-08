import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/models/media_source.dart';
import 'package:framelet/services/credential_store.dart';
import 'package:framelet/services/framelet_store.dart';
import 'package:framelet/services/media_library.dart';
import 'package:framelet/services/webdav_service.dart';

class _MemoryCredentialStore extends CredentialStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> readSources() async => values['sources'];

  @override
  Future<void> writeSources(String json) async => values['sources'] = json;

  @override
  Future<String?> readPassword(String sourceId) async => null;

  @override
  Future<void> writePassword(String sourceId, String password) async {}

  @override
  Future<void> deletePassword(String sourceId) async {}
}

const _sourceId = 's1';
const _folder = '/夸克网盘/成何体统-全集/[片头片尾]';
const _movieFolder = '/夸克网盘/长丨安的荔枝（2025）';

List<ScannedVideo> _extrasVideos() => [
  for (final name in ['片头', '片尾', '片尾2', '片尾3'])
    ScannedVideo(
      sourceId: _sourceId,
      path: '$_folder/$name.mp4',
      title: name,
      kind: MediaKind.movie,
      tmdbId: 16906,
      tmdbTitle: '披头士精选辑',
      posterPath: 'poster.jpg',
    ),
];

/// 同一部电影的多版本：聚合成多条记录，但海报墙按 TMDB ID 只出一张卡。
List<ScannedVideo> _mergedMovieVideos() => [
  const ScannedVideo(
    sourceId: _sourceId,
    path: '$_movieFolder/2025.1080p.WEB-DL.H264.AAC-OurTV.mkv',
    title: '2025    OurTV',
    kind: MediaKind.movie,
    tmdbId: 272151,
    tmdbTitle: '长安的荔枝',
    posterPath: 'p_new.jpg',
  ),
  const ScannedVideo(
    sourceId: _sourceId,
    path: '$_movieFolder/2025.1080p.WEB-DL.H264.AAC-OurTV_with_header.mkv',
    title: '2025    OurTV_with_header',
    kind: MediaKind.movie,
    tmdbId: 272151,
    tmdbTitle: '长安的荔枝',
    posterPath: 'p_old.jpg',
  ),
  const ScannedVideo(
    sourceId: _sourceId,
    path:
        '$_movieFolder/2025.2160p.WEB-DL.H265.HDR.60fps.10bit.AAC5.1&DDP5.1.mkv',
    title: '2025    60fps.10bit.AAC5.1&DDP5.1',
    kind: MediaKind.movie,
    tmdbId: 272151,
    tmdbTitle: '长安的荔枝',
    posterPath: 'p_old.jpg',
  ),
];

Future<MemoryFrameletStore> _storeWith(
  List<ScannedVideo> videos, {
  Map<String, String>? legacyHidden,
}) async {
  final store = MemoryFrameletStore();
  await store.saveSources([
    MediaSource(
      id: _sourceId,
      name: 'test',
      kind: MediaSourceKind.local,
      address: 'x',
      username: '',
      connected: true,
      lastSync: '',
    ),
  ]);
  await store.saveVideos(_sourceId, videos);
  if (legacyHidden != null) {
    await store.saveMeta('hidden_items', jsonEncode(legacyHidden));
  }
  return store;
}

Future<MediaLibrary> _load(MemoryFrameletStore store) async {
  final library = MediaLibrary(store: _MemoryCredentialStore(), db: store)
    ..autoScrapeAfterScan = false;
  await library.load();
  return library;
}

void main() {
  test('隐藏按海报卡生效：同一 TMDB 的多条聚合条目一起隐藏', () async {
    final store = await _storeWith(_mergedMovieVideos());
    final library = await _load(store);

    // 同一部电影的多版本会聚成多条记录，但海报墙只显示一张卡。
    expect(MediaLibrary.aggregate(_mergedMovieVideos()).length, greaterThan(1));
    final cards = library.byKind(MediaKind.movie);
    expect(cards, hasLength(1));
    expect(cards.single.episodeCount, 1);
    expect(library.seasonsOf(cards.single), hasLength(1));
    final versions = library.versionsOf(cards.single);
    expect(versions, hasLength(3));
    expect(versions.first.path, contains('2160p'));
    expect(MediaLibrary.versionLabelOf(versions.first), contains('4K'));

    await library.hideItem(cards.single, displayName: '长安的荔枝');
    expect(library.byKind(MediaKind.movie), isEmpty);
    expect(library.hiddenItems, hasLength(1));

    // 模拟下次启动/同步：仍然按同一张卡隐藏，不会重新刷回首页。
    final reloaded = await _load(store);
    expect(reloaded.byKind(MediaKind.movie), isEmpty);
    expect(reloaded.hiddenItems.values.single, '长安的荔枝');
  });

  test('旧版按文件路径隐藏的记录会迁移成海报卡隐藏', () async {
    final store = await _storeWith(
      _mergedMovieVideos(),
      // 旧版可能只记了多版本中的某个非代表文件。
      legacyHidden: {
        '$_sourceId|$_movieFolder/'
                '2025.2160p.WEB-DL.H265.HDR.60fps.10bit.AAC5.1&DDP5.1.mkv':
            '长安的荔枝',
      },
    );
    final library = await _load(store);

    expect(library.byKind(MediaKind.movie), isEmpty);
    expect(library.hiddenItems, hasLength(1));
    expect(library.hiddenItems.keys.single, 'tmdb|272151');
  });

  test('纯片头片尾目录不进入海报墙，也不进入待匹配/刮削队列', () async {
    final store = await _storeWith(_extrasVideos());
    final library = await _load(store);

    expect(MediaLibrary.aggregate(_extrasVideos()), isEmpty);
    expect(library.byKind(MediaKind.movie), isEmpty);
    expect(library.unscrapedItems(), isEmpty);
  });

  test('旧版误隐藏的片头片尾记录会在迁移时清理', () async {
    final store = await _storeWith(
      _extrasVideos(),
      legacyHidden: {
        '$_sourceId|$_folder/片头.mp4': '披头士精选辑',
        '$_sourceId|$_folder/片尾2.mp4': '披头士精选辑',
      },
    );
    final library = await _load(store);

    expect(library.byKind(MediaKind.movie), isEmpty);
    expect(library.hiddenItems, isEmpty);
  });

  test('片头片尾 / OP / ED 识别为花絮，正常片名不误伤', () {
    expect(WebDavService.isExtraFile('片头'), isTrue);
    expect(WebDavService.isExtraFile('片尾2'), isTrue);
    expect(WebDavService.isExtraFile('NCOP1'), isTrue);
    expect(WebDavService.isExtraFile('OP01'), isTrue);
    expect(WebDavService.isExtraFile('ED 2'), isTrue);
    expect(WebDavService.isExtraFile('Ed Wood'), isFalse);
    expect(WebDavService.isExtraFile('Red'), isFalse);
    expect(WebDavService.isExtraFile('Open Season'), isFalse);
    expect(WebDavService.isExtraFolder('[片头片尾]'), isTrue);
    expect(WebDavService.isExtraFolder('Extraordinary'), isFalse);
    expect(WebDavService.isExtraFolder('Trailer Park Boys'), isFalse);
    expect(WebDavService.isExtraFolder('Extras'), isTrue);
    expect(WebDavService.isExtraFolder('[Extras]'), isTrue);
    expect(WebDavService.isExtraFolder('978'), isFalse);
    expect(WebDavService.isSystemFolder('@eaDir'), isTrue);
    expect(WebDavService.isSystemFolder('#recycle'), isTrue);
    expect(WebDavService.isSystemFolder(r'$RECYCLE.BIN'), isTrue);
    expect(WebDavService.isSystemFolder('System Volume Information'), isTrue);
    expect(WebDavService.isSystemFolder('电影'), isFalse);
  });

  test('单文件目录只有强花絮标记才被丢弃', () {
    const interview = ScannedVideo(
      sourceId: _sourceId,
      path: '/电影/The Interview/The Interview.mkv',
      title: 'The Interview',
      kind: MediaKind.movie,
    );
    const opening = ScannedVideo(
      sourceId: _sourceId,
      path: '/某剧/[片头片尾]/片头.mp4',
      title: '片头',
      kind: MediaKind.movie,
    );

    expect(MediaLibrary.aggregate([interview]), hasLength(1));
    expect(MediaLibrary.aggregate([opening]), isEmpty);
  });

  test('从任意一集打开仍能拿到整季列表（上一集/下一集/选集）', () async {
    const folder = '/夸克网盘/movie/嫁金钗 (2026) 4K HDR杜比视界 全30集';
    final videos = [
      for (var i = 28; i <= 30; i++)
        ScannedVideo(
          sourceId: _sourceId,
          path: '$folder/$i HDR.mkv',
          title: '$i HDR',
          kind: MediaKind.series,
        ),
    ];
    final library = await _load(await _storeWith(videos));
    final second = library.findVideo(_sourceId, '$folder/29 HDR.mkv')!;

    final aggregate = library.resolveAggregated(second);
    expect(aggregate.title, '嫁金钗');
    expect(aggregate.episodeCount, 3);
    expect(library.episodesOf(second), hasLength(3));
    expect(library.episodesOf(aggregate), hasLength(3));
  });
}
