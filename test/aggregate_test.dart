import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/models/media_source.dart';
import 'package:framelet/services/media_library.dart';
import 'package:framelet/services/webdav_service.dart';

ScannedVideo video(
  String path,
  String title, {
  MediaKind kind = MediaKind.movie,
}) => ScannedVideo(
  sourceId: 's1',
  path: path,
  title: title,
  kind: kind,
  sizeBytes: 1024 * 1024 * 1024,
);

void main() {
  group('按文件夹聚合', () {
    test('标准 S01E 标记的 16 集合并为一条剧集', () {
      final signal = [
        for (var i = 1; i <= 16; i++)
          video(
            '/电影/Signal/Signal.S01E${i.toString().padLeft(2, '0')}',
            'Signal.S01E${i.toString().padLeft(2, '0')}',
          ),
      ];
      final result = MediaLibrary.aggregate(signal);
      expect(result, hasLength(1));
      expect(result.first.title, 'Signal');
      expect(result.first.episodeCount, 16);
      expect(result.first.kind, MediaKind.series);
    });

    test('纯数字编号的剧集（三体_01…三体_16）也能合并', () {
      final santi = [
        for (var i = 1; i <= 16; i++)
          video(
            '/电影/三体/三体_${i.toString().padLeft(2, '0')}_4K',
            '三体_${i.toString().padLeft(2, '0')}_4K',
          ),
      ];
      final result = MediaLibrary.aggregate(santi);
      expect(result, hasLength(1));
      expect(result.first.episodeCount, 16);
      expect(result.first.title, '三体');
    });

    test('单文件电影保持独立', () {
      final result = MediaLibrary.aggregate([
        video('/电影/流浪地球2.2023.2160p', '流浪地球2'),
      ]);
      expect(result, hasLength(1));
      expect(result.first.episodeCount, 1);
    });

    test('同目录多部不同电影不会被误合并', () {
      final result = MediaLibrary.aggregate([
        video('/电影/流浪地球2', '流浪地球2'),
        video('/电影/星际穿越', '星际穿越'),
        video('/电影/盗梦空间', '盗梦空间'),
      ]);
      expect(result, hasLength(3));
    });

    test('续集（仅两个文件）不会被误合并', () {
      final result = MediaLibrary.aggregate([
        video('/电影/流浪地球2', '流浪地球2'),
        video('/电影/流浪地球3', '流浪地球3'),
      ]);
      expect(result, hasLength(2));
    });

    test('动漫目录下的中文集数标记保留动漫分类', () {
      final anime = [
        for (var i = 1; i <= 12; i++)
          video('/动漫/进击的巨人/进击的巨人.第$i集', '进击的巨人.第$i集', kind: MediaKind.anime),
      ];
      final result = MediaLibrary.aggregate(anime);
      expect(result, hasLength(1));
      expect(result.first.episodeCount, 12);
      expect(result.first.kind, MediaKind.anime);
    });
  });

  group('分类判定', () {
    test('文件名含 S01E13 时判定为剧集，即使目录是电影', () {
      expect(
        WebDavService.resolveKind('Signal.S01E13', MediaKind.movie),
        MediaKind.series,
      );
    });

    test('无集数标记的单文件保持电影', () {
      expect(
        WebDavService.resolveKind('流浪地球2.2023.2160p', MediaKind.movie),
        MediaKind.movie,
      );
    });

    test('动漫目录优先于集数标记', () {
      expect(
        WebDavService.resolveKind('进击的巨人.第03集', MediaKind.anime),
        MediaKind.anime,
      );
    });
  });
}
