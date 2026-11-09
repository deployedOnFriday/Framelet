import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/models/media_source.dart';
import 'package:framelet/services/credential_store.dart';
import 'package:framelet/services/framelet_store.dart';
import 'package:framelet/services/media_library.dart';
import 'package:framelet/services/playback_history.dart';
import 'package:framelet/services/webdav_service.dart';

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

ScannedVideo _video(String path) => ScannedVideo(
  sourceId: 's1',
  path: path,
  title: path.split('/').last,
  kind: MediaKind.series,
);

void main() {
  group('WebDAV 路径工具', () {
    test('规范化、拼接与取父目录', () {
      expect(WebDavService.normalizePath(''), '/');
      expect(WebDavService.normalizePath('影视/一人之下/'), '/影视/一人之下');
      expect(WebDavService.joinPath('/', '电影'), '/电影');
      expect(WebDavService.joinPath('/影视/一人之下', '第 4 季'), '/影视/一人之下/第 4 季');
      expect(WebDavService.parentPath('/影视/一人之下'), '/影视');
      expect(WebDavService.parentPath('/影视'), '/');
    });

    test('名称不允许空值或路径分隔符', () {
      expect(
        () => WebDavService.validateEntryName(' '),
        throwsA(isA<StateError>()),
      );
      expect(
        () => WebDavService.validateEntryName('a/b'),
        throwsA(isA<StateError>()),
      );
      expect(
        () => WebDavService.validateEntryName('a\\b'),
        throwsA(isA<StateError>()),
      );
      expect(WebDavService.validateEntryName(' 一人之下 '), '一人之下');
    });
  });

  test('WebDAV 改名/删除同步更新媒体库路径', () async {
    final store = MemoryFrameletStore();
    await store.saveSources([
      MediaSource(
        id: 's1',
        name: 'test',
        kind: MediaSourceKind.webdav,
        address: 'http://example.com/dav',
        username: '',
        connected: true,
        lastSync: '',
      ),
    ]);
    await store.saveVideos('s1', [
      _video('/影视/一人之下/第 4 季/E01.mkv'),
      _video('/影视/一人之下/第 4 季/E02.mkv'),
      _video('/影视/其他/E01.mkv'),
    ]);
    final library = MediaLibrary(store: _MemoryCredentialStore(), db: store);
    await library.load();

    final renamed = await library.applyRemoteRename(
      sourceId: 's1',
      oldPath: '/影视/一人之下/第 4 季',
      newPath: '/影视/一人之下/第四季',
      isDir: true,
    );
    expect(renamed, 2);
    expect(library.findVideo('s1', '/影视/一人之下/第四季/E01.mkv'), isNotNull);
    expect(library.findVideo('s1', '/影视/一人之下/第 4 季/E01.mkv'), isNull);
    expect(library.findVideo('s1', '/影视/其他/E01.mkv'), isNotNull);

    final removed = await library.applyRemoteDelete(
      sourceId: 's1',
      path: '/影视/一人之下/第四季',
      isDir: true,
    );
    expect(removed, 2);
    expect(library.findVideo('s1', '/影视/一人之下/第四季/E01.mkv'), isNull);
  });

  test('WebDAV 改名/删除同步更新播放历史', () async {
    final store = MemoryFrameletStore();
    final history = PlaybackHistory.withStore(store);
    await history.record(
      HistoryEntry(
        sourceId: 's1',
        path: '/影视/一人之下/第 4 季/E01.mkv',
        title: 'E01',
        kind: MediaKind.series,
        updatedAtMs: 1,
      ),
    );

    await history.renamePath(
      's1',
      '/影视/一人之下/第 4 季',
      '/影视/一人之下/第四季',
      isDir: true,
    );
    expect(history.entryOf('s1', '/影视/一人之下/第四季/E01.mkv'), isNotNull);
    expect(history.entryOf('s1', '/影视/一人之下/第 4 季/E01.mkv'), isNull);

    await history.removePath('s1', '/影视/一人之下/第四季', isDir: true);
    expect(history.entryOf('s1', '/影视/一人之下/第四季/E01.mkv'), isNull);
  });
}
