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

    test('纯数字文件名（14 4K.mp4）按文件夹合并', () {
      final tang = [
        for (var i = 14; i <= 40; i++) video('/夸克网盘/唐朝诡事录/唐朝诡事录3/$i', '$i'),
      ];
      final result = MediaLibrary.aggregate(tang);
      expect(result, hasLength(1));
      expect(result.first.title, '唐朝诡事录3');
      expect(result.first.episodeCount, 27);
      expect(result.first.kind, MediaKind.series);
    });

    test('季号目录（剧名/1/1.mkv）向上取剧名', () {
      final doctor = [
        for (var i = 1; i <= 9; i++) video('/夸克网盘/机智的医生生活/1/$i', '$i'),
      ];
      final result = MediaLibrary.aggregate(doctor);
      expect(result, hasLength(1));
      expect(result.first.title, '机智的医生生活');
      expect(result.first.episodeCount, 9);
    });

    test('片头片尾等花絮不进入媒体库', () {
      final result = MediaLibrary.aggregate([
        video('/夸克网盘/成何体统/[片头片尾]/片头', '片头'),
        video('/夸克网盘/成何体统/[片头片尾]/片尾', '片尾'),
        video('/夸克网盘/成何体统/[片头片尾]/片尾2', '片尾2'),
        video('/夸克网盘/成何体统/成何体统.S01E01', '成何体统.S01E01'),
        video('/夸克网盘/成何体统/成何体统.S01E02', '成何体统.S01E02'),
      ]);
      expect(result, hasLength(1));
      expect(result.first.episodeCount, 2);
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

  group('季号识别', () {
    test('S02E13 文件名识别为第 2 季', () {
      expect(MediaLibrary.seasonOf(video('/剧/某剧/某剧.S02E13', '某剧.S02E13')), 2);
    });

    test('第2季 目录识别为第 2 季', () {
      expect(MediaLibrary.seasonOf(video('/剧/某剧/第2季/01', '01')), 2);
    });

    test('纯数字季目录识别为第 3 季', () {
      expect(MediaLibrary.seasonOf(video('/剧/某剧/3/01', '01')), 3);
    });

    test('无季号标记时按第 1 季', () {
      expect(MediaLibrary.seasonOf(video('/剧/某剧/01~4K', '01~4K')), 1);
    });

    test('中文季号（第二季）识别', () {
      expect(MediaLibrary.seasonOf(video('/剧/某剧/第二季/01', '01')), 2);
    });
  });

  group('集数解析', () {
    test('01~4K 解析为第 1 集', () {
      expect(MediaLibrary.episodeNumberOf('01~4K'), 1);
    });

    test('14_1080p 解析为第 14 集', () {
      expect(MediaLibrary.episodeNumberOf('14_1080p'), 14);
    });

    test('S02E13 解析为第 13 集', () {
      expect(MediaLibrary.episodeNumberOf('某剧.S02E13'), 13);
    });

    test('第08集 解析为第 8 集', () {
      expect(MediaLibrary.episodeNumberOf('某剧.第08集'), 8);
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
