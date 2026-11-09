import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/services/credential_store.dart';
import 'package:framelet/services/danmaku_service.dart';
import 'package:framelet/services/framelet_store.dart';
import 'package:framelet/services/media_library.dart';

class _MemoryCredentialStore extends CredentialStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  late String originalBaseUrl;
  late bool originalDandanplayEnabled;
  late bool originalCustomEnabled;

  setUp(() {
    originalBaseUrl = DanmakuService.baseUrl;
    originalDandanplayEnabled = DanmakuService.dandanplayEnabled;
    originalCustomEnabled = DanmakuService.customEnabled;
  });

  tearDown(() {
    DanmakuService.baseUrl = originalBaseUrl;
    DanmakuService.dandanplayEnabled = originalDandanplayEnabled;
    DanmakuService.customEnabled = originalCustomEnabled;
  });

  group('内置弹幕地址', () {
    test('可以解密出有效的 https 服务地址', () {
      final url = DanmakuService.builtinBaseUrl;
      final uri = Uri.parse(url);

      expect(uri.scheme, 'https');
      expect(uri.host, isNotEmpty);
      expect(
        uri.pathSegments.where((segment) => segment.isNotEmpty).length,
        greaterThanOrEqualTo(2),
      );
      expect(url, isNot(contains(' ')));
      expect(url.endsWith('/'), isFalse);
      expect(DanmakuService.builtinBaseUrl, url);
    });

    test('默认配置指向内置服务且可直接使用', () {
      expect(DanmakuService.baseUrl, DanmakuService.builtinBaseUrl);
      expect(DanmakuService.configured, isTrue);
      expect(DanmakuService.usingBuiltin, isTrue);
    });

    test('展示用主机名不包含路径里的 token', () {
      DanmakuService.baseUrl = 'https://danmu.example.com/secret-token';
      expect(DanmakuService.displayHost, 'danmu.example.com');
      expect(DanmakuService.displayHost, isNot(contains('secret-token')));
    });
  });

  group('接口地址拼接', () {
    test('自建服务根地址自动补 /api/v2', () {
      expect(
        DanmakuService.endpoint(
          '/search/episodes',
          base: 'https://danmu.example.com/token',
        ),
        'https://danmu.example.com/token/api/v2/search/episodes',
      );
    });

    test('已带 /api/v2 或末尾斜杠时不会重复拼接', () {
      expect(
        DanmakuService.endpoint(
          '/comment/9',
          base: 'https://danmu.example.com/token/api/v2',
        ),
        'https://danmu.example.com/token/api/v2/comment/9',
      );
      expect(
        DanmakuService.endpoint(
          '/comment/9',
          base: 'https://danmu.example.com/token///',
        ),
        'https://danmu.example.com/token/api/v2/comment/9',
      );
    });

    test('留空时回退到内置服务', () {
      expect(
        DanmakuService.endpoint('/comment/9', base: '   '),
        '${DanmakuService.builtinBaseUrl}/api/v2/comment/9',
      );
    });

    test('官方直连地址始终是 api.dandanplay.net', () {
      expect(DanmakuService.officialBaseUrl, 'https://api.dandanplay.net');
      expect(DanmakuService.builtinAppId, isNotEmpty);
      expect(DanmakuService.builtinAppSecret, isNotEmpty);
    });
  });

  group('弹幕配置迁移', () {
    test('全新安装默认使用内置服务', () async {
      final library = MediaLibrary(
        store: _MemoryCredentialStore(),
        db: MemoryFrameletStore(),
      );
      await library.load();

      expect(library.usingBuiltinDanmaku, isTrue);
      expect(library.danmakuBaseUrl, DanmakuService.builtinBaseUrl);
      expect(DanmakuService.baseUrl, DanmakuService.builtinBaseUrl);
    });

    test('旧 DanDanPlay 配置迁移到内置服务并清理凭据', () async {
      final store = _MemoryCredentialStore()
        ..values['framelet.danmaku.provider'] = 'dandanplay'
        ..values['framelet.danmaku.baseUrl'] = 'https://api.dandanplay.net'
        ..values['framelet.danmaku.appId'] = 'old-app'
        ..values['framelet.danmaku.appSecret'] = 'old-secret'
        ..values['framelet.dandanplay.appId'] = 'older-app'
        ..values['framelet.dandanplay.appSecret'] = 'older-secret';
      final library = MediaLibrary(store: store, db: MemoryFrameletStore());
      await library.load();

      expect(library.usingBuiltinDanmaku, isTrue);
      expect(store.values.containsKey('framelet.danmaku.provider'), isFalse);
      expect(store.values.containsKey('framelet.danmaku.appId'), isFalse);
      expect(store.values.containsKey('framelet.danmaku.appSecret'), isFalse);
      expect(store.values.containsKey('framelet.dandanplay.appId'), isFalse);
      expect(
        store.values.containsKey('framelet.dandanplay.appSecret'),
        isFalse,
      );
    });

    test('用户自定义地址在重启后保留', () async {
      final store = _MemoryCredentialStore()
        ..values['framelet.danmaku.provider'] = 'custom'
        ..values['framelet.danmaku.baseUrl'] =
            'https://danmu.example.com/token';
      final library = MediaLibrary(store: store, db: MemoryFrameletStore());
      await library.load();

      expect(library.usingBuiltinDanmaku, isFalse);
      expect(library.danmakuBaseUrl, 'https://danmu.example.com/token');
      expect(DanmakuService.baseUrl, 'https://danmu.example.com/token');
    });

    test('旧版内置地址（无端口）自动升级到当前内置地址', () async {
      final builtin = Uri.parse(DanmakuService.builtinBaseUrl);
      final staleUrl = '${builtin.scheme}://${builtin.host}${builtin.path}';
      expect(staleUrl, isNot(DanmakuService.builtinBaseUrl));
      final store = _MemoryCredentialStore()
        ..values['framelet.danmaku.baseUrl'] = staleUrl;
      final library = MediaLibrary(store: store, db: MemoryFrameletStore());
      await library.load();

      expect(library.danmakuBaseUrl, DanmakuService.builtinBaseUrl);
      expect(library.usingBuiltinDanmaku, isTrue);
    });

    test('清空地址会保存为空并回退内置服务', () async {
      final store = _MemoryCredentialStore();
      final library = MediaLibrary(store: store, db: MemoryFrameletStore());
      await library.load();

      await library.saveDanmakuSettings(
        baseUrl: 'https://danmu.example.com/token',
      );
      expect(store.values['framelet.danmaku.baseUrl'], isNotEmpty);

      await library.saveDanmakuSettings(baseUrl: '');
      expect(store.values['framelet.danmaku.baseUrl'], isEmpty);
      expect(library.usingBuiltinDanmaku, isTrue);
      expect(DanmakuService.baseUrl, DanmakuService.builtinBaseUrl);
    });

    test('两个弹幕源默认都开启', () async {
      final library = MediaLibrary(
        store: _MemoryCredentialStore(),
        db: MemoryFrameletStore(),
      );
      await library.load();

      expect(library.danmakuDandanplayEnabled, isTrue);
      expect(library.danmakuCustomEnabled, isTrue);
      expect(DanmakuService.enabledBackends, [
        DanmakuBackend.dandanplay,
        DanmakuBackend.custom,
      ]);
    });

    test('关掉某个源后持久化并在重启后生效', () async {
      final store = _MemoryCredentialStore();
      final library = MediaLibrary(store: store, db: MemoryFrameletStore());
      await library.load();

      await library.setDanmakuCustomEnabled(false);
      expect(store.values['framelet.danmaku.custom.enabled'], '0');
      expect(DanmakuService.enabledBackends, [DanmakuBackend.dandanplay]);

      final reopened = MediaLibrary(store: store, db: MemoryFrameletStore());
      await reopened.load();
      expect(reopened.danmakuCustomEnabled, isFalse);
      expect(DanmakuService.enabledBackends, [DanmakuBackend.dandanplay]);
    });

    test('两个源都关掉时视为未配置', () async {
      final library = MediaLibrary(
        store: _MemoryCredentialStore(),
        db: MemoryFrameletStore(),
      );
      await library.load();

      await library.setDanmakuDandanplayEnabled(false);
      await library.setDanmakuCustomEnabled(false);

      expect(DanmakuService.configured, isFalse);
      expect(DanmakuService.enabledBackends, isEmpty);
    });
  });
}
