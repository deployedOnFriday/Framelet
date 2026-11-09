import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/models/media_source.dart';
import 'package:framelet/services/media_library.dart';
import 'package:framelet/services/scraper_service.dart';
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

    test('TMDB 动画类型会把剧集归到动漫分类', () {
      final folder =
          '/dav/夸克网盘/东岛丹三郎想成为假面骑士 (2025) {tmdbid-285788}'
          '/Season 1（4K）';
      final episodes = [
        for (var i = 1; i <= 5; i++)
          video(
            '$folder/东岛丹三郎想成为假面骑士.2025.S01E0$i.2160p.WebRip.mkv',
            '东岛丹三郎想成为假面骑士.2025.S01E0$i WebRip',
            kind: MediaKind.series,
          ).copyWith(
            genres: const ['动画', '动作冒险', '喜剧'],
            tmdbId: 285788,
            tmdbTitle: '东岛丹三郎想成为假面骑士',
          ),
      ];
      final result = MediaLibrary.aggregate(episodes);
      expect(result, hasLength(1));
      expect(result.single.kind, MediaKind.anime);
      expect(result.single.title, '东岛丹三郎想成为假面骑士');
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

    test('片头片尾等花絮不计入集数（但仍保留在库里）', () {
      final result = MediaLibrary.aggregate([
        video('/夸克网盘/成何体统/[片头片尾]/片头', '片头'),
        video('/夸克网盘/成何体统/[片头片尾]/片尾', '片尾'),
        video('/夸克网盘/成何体统/[片头片尾]/片尾2', '片尾2'),
        video('/夸克网盘/成何体统/成何体统.S01E01', '成何体统.S01E01'),
        video('/夸克网盘/成何体统/成何体统.S01E02', '成何体统.S01E02'),
      ]);
      // 花絮单独目录不参与正片集数；正片 2 集
      final main = result.where((v) => v.episodeCount > 1).toList();
      expect(main, hasLength(1));
      expect(main.first.episodeCount, 2);
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

    test('网盘目录的年份与发布标签不会进入展示标题', () {
      final show = [
        for (var i = 28; i <= 30; i++)
          video(
            '/夸克网盘/movie/嫁金钗 (2026) 4K HDR杜比视界 全30集/$i HDR.mkv',
            '$i',
            kind: MediaKind.series,
          ),
      ];
      final result = MediaLibrary.aggregate(show);
      expect(result, hasLength(1));
      expect(result.single.title, '嫁金钗');
      expect(result.single.kind, MediaKind.series);
      expect(result.single.episodeCount, 3);
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

    test('标题被洗掉集号时回退原始文件名', () {
      final v = video('/剧/旋风少女/Whirlwind.Girl.E01.mp4', 'Whirlwind.Girl');
      expect(MediaLibrary.episodeNumberOfVideo(v), 1);
    });

    test('标题自身带集号时优先用标题', () {
      final v = video('/剧/某剧/第12集.mp4', '第12集');
      expect(MediaLibrary.episodeNumberOfVideo(v), 12);
    });
  });

  group('cleanTitle 集数标记保护', () {
    test('E01 不再被当作扩展名剥掉', () {
      expect(
        WebDavService.cleanTitle('Whirlwind.Girl.E01.mp4'),
        'Whirlwind.Girl.E01',
      );
    });

    test('纯数字集号同样保留', () {
      expect(WebDavService.cleanTitle('某剧.01.mp4'), '某剧.01');
    });

    test('双重扩展名仍会被剥掉', () {
      expect(WebDavService.cleanTitle('流浪地球.mkv.torrent'), '流浪地球');
    });

    test('画质后缀仍会被清洗且不影响集数标记', () {
      final title = WebDavService.cleanTitle('某剧.S01E01.1080p.WEB-DL.mkv');
      expect(title, contains('S01E01'));
      expect(title, isNot(contains('1080p')));
    });

    test('网盘目录年份与中文发布标签被清洗', () {
      expect(WebDavService.cleanTitle('嫁金钗 (2026) 4K HDR杜比视界 全30集'), '嫁金钗');
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

  group('剧名规范化（跨 TMDB ID 合并判据）', () {
    test('尾部季号数字剥离', () {
      expect(MediaLibrary.normalizeSeriesTitle('旋风少女2'), '旋风少女');
      expect(MediaLibrary.normalizeSeriesTitle('旋风少女'), '旋风少女');
    });

    test('第X季/Season N 剥离', () {
      expect(MediaLibrary.normalizeSeriesTitle('某剧第2季'), '某剧');
      expect(MediaLibrary.normalizeSeriesTitle('某剧 Season 3'), '某剧');
    });

    test('季号+副标题归并到基名（魔幻手机2：傻妞归来 → 魔幻手机）', () {
      expect(MediaLibrary.normalizeSeriesTitle('魔幻手机2：傻妞归来'), '魔幻手机');
      expect(
        MediaLibrary.normalizeSeriesTitle('魔幻手机2：傻妞归来') ==
            MediaLibrary.normalizeSeriesTitle('魔幻手机'),
        isTrue,
      );
    });

    test('名字包含但无关的不误合并（秘密 vs 秘密森林）', () {
      expect(MediaLibrary.normalizeSeriesTitle('秘密森林'), '秘密森林');
      expect(
        MediaLibrary.normalizeSeriesTitle('秘密森林') ==
            MediaLibrary.normalizeSeriesTitle('秘密'),
        isFalse,
      );
    });
  });

  group('清除缓存', () {
    test('withoutImages 清空图片路径但保留 TMDB 元数据', () {
      const original = ScannedVideo(
        sourceId: 's1',
        path: '/剧/某剧/01.mp4',
        title: '某剧',
        kind: MediaKind.series,
        posterPath: '/cache/poster.jpg',
        backdropPath: '/cache/backdrop.jpg',
        stillPath: '/cache/still.jpg',
        summary: '简介',
        rating: '8.6',
        tmdbId: 123,
        tmdbTitle: '某剧',
      );

      final cleared = original.withoutImages();

      expect(cleared.posterPath, isNull);
      expect(cleared.backdropPath, isNull);
      expect(cleared.stillPath, isNull);
      expect(cleared.summary, '简介');
      expect(cleared.rating, '8.6');
      expect(cleared.tmdbId, 123);
      expect(cleared.tmdbTitle, '某剧');
    });
  });

  group('电影聚类（Jellyfin 规则）', () {
    test('分类容器下多部不同电影按文件名解析各自独立', () {
      final result = MediaLibrary.aggregate([
        video(
          '/首页/夸克网盘/movie/Transformers.Rise.of.The.Beasts.2023.2160p.UHD',
          'Transformers.Rise.of.The.Beasts.2023.2160p.UHD',
        ),
        video(
          '/首页/夸克网盘/movie/Oppenheimer.2023.1080p.BluRay',
          'Oppenheimer.2023.1080p.BluRay',
        ),
      ]);
      expect(result, hasLength(2));
      expect(result.every((v) => v.episodeCount == 1), isTrue);
      // 标题用解析出的片名，不带技术杂质
      expect(
        result.map((v) => v.title),
        containsAll(['Transformers Rise of The Beasts', 'Oppenheimer']),
      );
    });

    test('同目录同名多版本合并为一条', () {
      final result = MediaLibrary.aggregate([
        video('/夸克网盘/一代宗师/一代宗师.2013.1080p', '一代宗师.2013.1080p'),
        video('/夸克网盘/一代宗师/一代宗师.2013.2160p', '一代宗师.2013.2160p'),
      ]);
      expect(result, hasLength(1));
      expect(result.first.episodeCount, 1);
      expect(result.first.title, '一代宗师');
    });

    test('目录是容器时两部不同的片不再错并', () {
      final result = MediaLibrary.aggregate([
        video('/夸克网盘/我的收藏/流浪地球.2019.1080p', '流浪地球.2019.1080p'),
        video('/夸克网盘/我的收藏/疯狂的石头.2006.1080p', '疯狂的石头.2006.1080p'),
      ]);
      expect(result, hasLength(2));
      expect(result.map((v) => v.title), containsAll(['流浪地球', '疯狂的石头']));
    });

    test('同名不同年份是不同的片（续集/重拍版）', () {
      final result = MediaLibrary.aggregate([
        video('/夸克网盘/电影角/Transformers.2007.1080p', 'Transformers.2007.1080p'),
        video('/夸克网盘/电影角/Transformers.2009.1080p', 'Transformers.2009.1080p'),
      ]);
      expect(result, hasLength(2));
    });

    test('带发布标签的季目录向上取剧名，不用「第 1 季」当片名', () {
      const folder =
          '/夸克网盘/影视/一人之下/第 1 季 - 2160p WEB-DL HQ H265 AAC';
      final result = MediaLibrary.aggregate([
        for (var i = 1; i <= 12; i++)
          video(
            '$folder/The OutCast S01E${i.toString().padLeft(2, '0')} - 第 $i 集.mp4',
            'The OutCast S01E${i.toString().padLeft(2, '0')} - 第 $i 集',
            kind: MediaKind.series,
          ),
      ]);
      expect(result, hasLength(1));
      expect(result.first.title, '一人之下');
      expect(result.first.episodeCount, 12);
    });

    test('刮削误命中的「第16集」不当作剧名展示', () {
      const folder =
          '/夸克网盘/影视/一人之下/第 1 季 - 2160p WEB-DL HQ H265 AAC';
      final result = MediaLibrary.aggregate([
        for (var i = 1; i <= 3; i++)
          video(
            '$folder/The OutCast S01E${i.toString().padLeft(2, '0')} - 第 $i 集.mp4',
            'The OutCast S01E${i.toString().padLeft(2, '0')} - 第 $i 集',
            kind: MediaKind.series,
          ).copyWith(tmdbId: 610704, tmdbTitle: '第16集'),
      ]);
      expect(result, hasLength(1));
      expect(result.first.title, '一人之下');
    });

    test('带发布标签的季目录（第 4 季 - 1080p）仍向上取剧名', () {
      const folder = '/夸克网盘/影视/一人之下/第 4 季 - 1080p WEB-DL H264 AAC';
      final result = MediaLibrary.aggregate([
        for (var i = 1; i <= 12; i++)
          video(
            '$folder/The OutCast S04E${i.toString().padLeft(2, '0')} - 第 $i 集.mp4',
            'The OutCast S04E${i.toString().padLeft(2, '0')} - 第 $i 集',
            kind: MediaKind.series,
          ),
      ]);
      expect(result, hasLength(1));
      expect(result.first.title, '一人之下');
      expect(result.first.episodeCount, 12);
    });

    test('中文季号目录（第四季）仍向上取剧名', () {
      const folder = '/夸克网盘/影视/一人之下/第四季';
      final result = MediaLibrary.aggregate([
        for (var i = 1; i <= 12; i++)
          video(
            '$folder/The OutCast S04E${i.toString().padLeft(2, '0')} - 第 $i 集.mp4',
            'The OutCast S04E${i.toString().padLeft(2, '0')} - 第 $i 集',
            kind: MediaKind.series,
          ),
      ]);
      expect(result, hasLength(1));
      expect(result.first.title, '一人之下');
      expect(result.first.episodeCount, 12);
    });
  });

  group('单集标题识别', () {
    test('命中「第 N 集」这类单集标题', () {
      for (final name in ['第16集', '第 1 集', '第3话', 'Episode 5', 'E07', 'S01E02']) {
        expect(MediaLibrary.isEpisodeLikeTitle(name), isTrue, reason: name);
      }
    });

    test('正常剧名/电影名不误判', () {
      for (final name in ['一人之下', 'The 16th Episode', '三体', 'Signal', '第16集之上']) {
        expect(MediaLibrary.isEpisodeLikeTitle(name), isFalse, reason: name);
      }
    });
  });

  group('TMDB 错配校验', () {
    test('恶意重复条目名与目录名无关时判为不可信', () {
      expect(
        MediaLibrary.isPlausibleTmdbMatch(
          name: '诛仙第一百季',
          originalName: '诛仙第一百季',
          sourceNames: ['一人之下', 'The OutCast'],
        ),
        isFalse,
      );
    });

    test('官方名或原名任一与目录名相符即可信', () {
      expect(
        MediaLibrary.isPlausibleTmdbMatch(
          name: '一人之下',
          originalName: '一人之下',
          sourceNames: ['一人之下', 'The OutCast'],
        ),
        isTrue,
      );
      // 英文原名兜底：中文目录/条目标题对不上时仍能靠原名确认。
      expect(
        MediaLibrary.isPlausibleTmdbMatch(
          name: '洛基',
          originalName: 'Loki',
          sourceNames: ['Loki'],
        ),
        isTrue,
      );
    });

    test('纯季号不能作为 TMDB 搜索词', () {
      for (final query in ['第 4 季', '第4季', '第四季', 'Season 4', 'S04']) {
        expect(ScraperService.isSeasonLabelQuery(query), isTrue, reason: query);
      }
      for (final query in ['一人之下', '一人之下 第4季', 'The OutCast']) {
        expect(
          ScraperService.isSeasonLabelQuery(query),
          isFalse,
          reason: query,
        );
      }
    });

    test('手动匹配初始搜索词取剧名目录而非季目录', () {
      expect(
        MediaLibrary.suggestedQueryForPath(
          '/夸克网盘/影视/一人之下/第四季/The.OutCast.S04E01.mkv',
        ),
        '一人之下',
      );
      expect(
        MediaLibrary.suggestedQueryForPath('/影视/黑寡妇.Black.Widow.2021.mkv'),
        contains('黑寡妇'),
      );
    });
  });
}
