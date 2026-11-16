import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/models/media_source.dart';

MediaSource _source({
  required MediaSourceKind kind,
  String address = '',
  String directory = '/',
}) {
  return MediaSource(
    id: 's1',
    name: '测试源',
    kind: kind,
    address: address,
    username: '',
    directory: directory,
  );
}

void main() {
  test('每种类型的展示名称', () {
    expect(_source(kind: MediaSourceKind.local).kindLabel, '本地目录');
    expect(_source(kind: MediaSourceKind.webdav).kindLabel, 'WebDAV');
    expect(_source(kind: MediaSourceKind.smb).kindLabel, 'SMB 共享');
    expect(
      _source(kind: MediaSourceKind.jellyfin).kindLabel,
      'Jellyfin / Emby',
    );
  });

  test('只有 WebDAV 强制要求密码', () {
    expect(_source(kind: MediaSourceKind.webdav).requiresPassword, isTrue);
    expect(_source(kind: MediaSourceKind.local).requiresPassword, isFalse);
    expect(_source(kind: MediaSourceKind.smb).requiresPassword, isFalse);
    expect(_source(kind: MediaSourceKind.jellyfin).requiresPassword, isFalse);
  });

  test('本地目录与 SMB 复用文件系统扫描', () {
    expect(_source(kind: MediaSourceKind.local).isFileSystem, isTrue);
    expect(_source(kind: MediaSourceKind.smb).isFileSystem, isTrue);
    expect(_source(kind: MediaSourceKind.webdav).isFileSystem, isFalse);
    expect(_source(kind: MediaSourceKind.jellyfin).isFileSystem, isFalse);
  });

  test('SMB 地址拼接子目录时使用反斜杠', () {
    final root = _source(kind: MediaSourceKind.smb, address: r'\\nas\media');
    expect(root.location, r'\\nas\media');
    final nested = _source(
      kind: MediaSourceKind.smb,
      address: r'\\nas\media',
      directory: '/Movies/2026',
    );
    expect(nested.location, r'\\nas\media\Movies\2026');
  });

  test('WebDAV 与本地/Jellyfin 的 location 规则保持不变', () {
    expect(
      _source(
        kind: MediaSourceKind.webdav,
        address: 'https://dav.example.org',
        directory: '/media',
      ).location,
      'https://dav.example.org/media',
    );
    expect(
      _source(
        kind: MediaSourceKind.local,
        address: r'D:\Movies',
        directory: '/ignored',
      ).location,
      r'D:\Movies',
    );
    expect(
      _source(
        kind: MediaSourceKind.jellyfin,
        address: 'http://192.168.1.10:8096',
        directory: '/ignored',
      ).location,
      'http://192.168.1.10:8096',
    );
  });

  test('旧数据没有 kind 字段时按 WebDAV 读取', () {
    final source = MediaSource.fromJson({
      'id': 'old',
      'name': '旧源',
      'address': 'https://dav.example.org',
      'username': 'u',
    });
    expect(source.kind, MediaSourceKind.webdav);
  });

  test('新增类型可以 JSON 往返', () {
    for (final kind in [MediaSourceKind.smb, MediaSourceKind.jellyfin]) {
      final source = _source(kind: kind, address: 'address', directory: '/sub');
      final restored = MediaSource.fromJson(source.toJson());
      expect(restored.kind, kind);
      expect(restored.address, 'address');
      expect(restored.directory, '/sub');
    }
  });
}
