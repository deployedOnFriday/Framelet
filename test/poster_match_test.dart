import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/models/media_source.dart';
import 'package:framelet/services/credential_store.dart';
import 'package:framelet/services/framelet_store.dart';
import 'package:framelet/services/media_library.dart';

class _MemoryCredentialStore extends CredentialStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<String?> readSources() async => _values['sources'];

  @override
  Future<void> writeSources(String json) async => _values['sources'] = json;

  @override
  Future<String?> readPassword(String sourceId) async => null;

  @override
  Future<void> writePassword(String sourceId, String password) async {}

  @override
  Future<void> deletePassword(String sourceId) async {}
}

Future<MediaLibrary> _libraryWith(List<ScannedVideo> videos) async {
  final store = MemoryFrameletStore();
  await store.saveSources([
    MediaSource(
      id: 's1',
      name: 'test',
      kind: MediaSourceKind.local,
      address: 'x',
      username: '',
      connected: true,
      lastSync: '',
    ),
  ]);
  await store.saveVideos('s1', videos);
  final library = MediaLibrary(store: _MemoryCredentialStore(), db: store);
  await library.load();
  return library;
}

void main() {
  test('同一 tmdbId 的多条聚合条目合并时，取修正后的新海报', () async {
    const folder = '/夸克网盘/长丨安的荔枝（2025）';
    final videos = [
      ScannedVideo(
        sourceId: 's1',
        path: '$folder/2025.1080p.WEB-DL.H264.AAC-OurTV.mkv',
        title: '2025    OurTV',
        kind: MediaKind.movie,
        tmdbId: 272151,
        posterPath: 'p_new.jpg',
        summary: '长安的荔枝简介',
        rating: '7.3',
      ),
      ScannedVideo(
        sourceId: 's1',
        path: '$folder/2025.1080p.WEB-DL.H264.AAC-OurTV_with_header.mkv',
        title: '2025    OurTV_with_header',
        kind: MediaKind.movie,
        tmdbId: 272151,
        posterPath: 'p_old.jpg',
      ),
      ScannedVideo(
        sourceId: 's1',
        path:
            '$folder/2025.2160p.WEB-DL.H265.HDR.60fps.10bit.AAC5.1&DDP5.1.mkv',
        title: '2025    60fps.10bit.AAC5.1&DDP5.1',
        kind: MediaKind.movie,
        tmdbId: 272151,
        posterPath: 'p_old.jpg',
      ),
    ];
    final library = await _libraryWith(videos);

    // 三个文件被解析成三条聚合条目，但 tmdbId 相同，海报墙只出一张卡。
    expect(MediaLibrary.aggregate(videos), hasLength(3));
    final cards = library.byKind(MediaKind.movie);
    expect(cards, hasLength(1));
    expect(cards.single.posterPath, 'p_new.jpg');
    expect(cards.single.rating, '7.3');
  });

  test('clearPoster / clearTmdbId 能彻底移除旧匹配', () {
    const video = ScannedVideo(
      sourceId: 's1',
      path: '/a/b.mkv',
      title: 'b',
      kind: MediaKind.movie,
      posterPath: 'old.jpg',
      tmdbId: 1,
      tmdbTitle: '旧片名',
    );
    final cleared = video.copyWith(clearPoster: true, clearTmdbId: true);
    expect(cleared.posterPath, isNull);
    expect(cleared.tmdbId, isNull);
  });
}
