import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/models/media_source.dart';
import 'package:framelet/services/webdav_service.dart';

MediaSource source(String address) =>
    MediaSource(id: 's1', name: 'test', address: address, username: 'user');

void main() {
  group('WebDAV 播放地址', () {
    test('保留地址里的 /dav 前缀', () {
      final url = WebDavService.playUrl(
        source('http://112.236.165.83:5244/dav'),
        '/夸克网盘/成何体统-全集/01~4K.mp4',
      );
      expect(url.pathSegments, ['dav', '夸克网盘', '成何体统-全集', '01~4K.mp4']);
      expect(url.host, '112.236.165.83');
      expect(url.port, 5244);
    });

    test('地址不带路径前缀时保持原样', () {
      final url = WebDavService.playUrl(
        source('https://dav.example.com'),
        '/电影/流浪地球.mkv',
      );
      expect(url.pathSegments, ['电影', '流浪地球.mkv']);
      expect(url.scheme, 'https');
    });

    test('兼容路径里重复带上地址前缀的旧数据', () {
      final url = WebDavService.playUrl(
        source('http://host:5244/dav'),
        '/dav/夸克网盘/a.mp4',
      );
      expect(url.pathSegments, ['dav', '夸克网盘', 'a.mp4']);
    });

    test('多段地址路径前缀不会重复', () {
      final url = WebDavService.playUrl(
        source('http://host/webdav/dav'),
        '/webdav/dav/电影/a.mp4',
      );
      expect(url.pathSegments, ['webdav', 'dav', '电影', 'a.mp4']);
    });

    test('地址查询参数保留', () {
      final url = WebDavService.playUrl(
        source('http://host:5244/dav?token=abc'),
        '/电影/a.mp4',
      );
      expect(url.query, 'token=abc');
      expect(url.pathSegments, ['dav', '电影', 'a.mp4']);
    });
  });
}
