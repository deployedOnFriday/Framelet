import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/services/smb_service.dart';

void main() {
  group('SmbService.normalizeAddress', () {
    test('smb:// 统一成 UNC', () {
      expect(
        SmbService.normalizeAddress('smb://192.168.1.10/media'),
        r'\\192.168.1.10\media',
      );
    });

    test('正斜杠与多余分隔符', () {
      expect(
        SmbService.normalizeAddress('//nas/share/movies/'),
        r'\\nas\share\movies',
      );
      expect(SmbService.normalizeAddress(r'\\nas\\share\\'), r'\\nas\share');
    });

    test('空地址与已规范地址', () {
      expect(SmbService.normalizeAddress('   '), '');
      expect(SmbService.normalizeAddress(r'\\nas\share'), r'\\nas\share');
    });
  });

  group('SmbService.shareRootOf', () {
    test('只保留服务器与共享名', () {
      expect(
        SmbService.shareRootOf(r'\\nas\share\movies\2026'),
        r'\\nas\share',
      );
      expect(SmbService.shareRootOf('smb://nas/share/movies'), r'\\nas\share');
    });
  });
}
