import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/services/scraper_service.dart';

void main() {
  group('parseTitle 剥离季与年份后缀', () {
    test('S1（2025）后缀被剥离', () {
      final parsed = ScraperService.parseTitle('幸福伽菜子的快乐杀手生活S1（2025）');
      expect(parsed.queries.first, '幸福伽菜子的快乐杀手生活');
    });

    test('普通剧名不受影响', () {
      final parsed = ScraperService.parseTitle('幸福伽菜子的快乐杀手生活');
      expect(parsed.queries.first, '幸福伽菜子的快乐杀手生活');
    });

    test('「西部世界 S01」剥离季号', () {
      final parsed = ScraperService.parseTitle('西部世界 S01');
      expect(parsed.queries.first, '西部世界');
    });

    test('第2季后缀被剥离', () {
      final parsed = ScraperService.parseTitle('某剧第2季');
      expect(parsed.queries.first, '某剧');
    });

    test('中文数字季号剥离', () {
      final parsed = ScraperService.parseTitle('瑞克和莫蒂第九季');
      expect(parsed.queries.first, '瑞克和莫蒂');
    });

    test('英文剧名不受误伤', () {
      final parsed = ScraperService.parseTitle(
        'Apocalypse.Hotel.2025.S01E01.CR.UBWEB',
      );
      expect(parsed.queries.first, 'Apocalypse Hotel');
      expect(parsed.year, 2025);
    });
  });
  group('parseTitle 目录名噪音剥离（Pixar 式命名）', () {
    test('年份粘连前缀被剥离并记为年份', () {
      final parsed = ScraperService.parseTitle('1995-玩具总动员1【中英字幕】');
      // 中英粘连拆分后尾部序号直接剥掉，首个查询词即可命中
      expect(parsed.queries.first, '玩具总动员');
      expect(parsed.year, 1995);
      // 字幕标签不得进入查询词
      expect(parsed.queries, isNot(contains('中英字幕')));
    });

    test('序号前缀与 MA 标签尾生成干净变体', () {
      final parsed = ScraperService.parseTitle('24 黑寡妇 Black Widow MA');
      expect(parsed.queries.first, '24 黑寡妇 Black Widow MA');
      expect(parsed.queries, contains('黑寡妇 Black Widow MA'));
      expect(parsed.queries, contains('黑寡妇 Black Widow'));
      expect(parsed.queries, contains('黑寡妇'));
      expect(parsed.queries, contains('Black Widow'));
    });

    test('无字幕标签被过滤', () {
      final parsed = ScraperService.parseTitle('2001-怪兽电力公司【无字幕】');
      expect(parsed.queries.first, '怪兽电力公司');
      expect(parsed.queries, isNot(contains('无字幕')));
    });

    test('片名本身是短英文词不被误剥（Ma/IT/Up）', () {
      final parsed = ScraperService.parseTitle('Up 2009 1080p');
      expect(parsed.queries.first, 'Up');
      expect(parsed.year, 2009);
    });

    test('点分隔发布名开头的年份是片名（2012），不当年份剥', () {
      final parsed = ScraperService.parseTitle('2012.2009.2160p.BluRay.x265');
      expect(parsed.queries.first, '2012');
      expect(parsed.year, 2009);
    });

    test('年份-空格-片名（1995 玩具总动员）正常解析', () {
      final parsed = ScraperService.parseTitle('虫虫危机 1998');
      expect(parsed.queries.first, '虫虫危机');
      expect(parsed.year, 1998);
    });
  });

  group('parseTitle 网盘标签目录/粘连子词（v0.1.17）', () {
    test('中英粘连子词拆分：技术词与标签剔除', () {
      final parsed = ScraperService.parseTitle('挽救计划4K英语中字');
      expect(parsed.queries.first, '挽救计划');
      expect(parsed.queries, isNot(contains('英语中字')));
    });

    test('纯标签目录名不进查询词', () {
      final parsed = ScraperService.parseTitle('英语中字');
      expect(parsed.queries, isEmpty);
    });

    test('位置规则变体：标题在首个技术词前截断', () {
      final parsed = ScraperService.parseTitle('The Mask Upscale2160p Inter');
      expect(parsed.queries, contains('The Mask'));
    });

    test('位置规则变体：S01E01 之后的残留不影响', () {
      final parsed = ScraperService.parseTitle(
        'Loki.S01E01.Glorious.Purpose DDP5 1.Atmos.DV.H',
      );
      expect(parsed.queries, contains('Loki'));
      expect(parsed.queries.first, isNot(contains('DDP5')));
    });

    test('尾部「字母+数字」标签（MA7）剥出变体', () {
      final parsed = ScraperService.parseTitle('Life of Pi MA7');
      expect(parsed.queries, contains('Life of Pi'));
    });

    test('IMAX/iT 等规格词不污染英文标题', () {
      final parsed = ScraperService.parseTitle(
        'Project Hail Mary iMAX iT DDP5 せんどう',
      );
      expect(parsed.queries, contains('Project Hail Mary'));
    });

    test('语言标签（MULTI.FRENCH）剥出干净片名', () {
      final parsed = ScraperService.parseTitle(
        'Hoppers 2026.MULTI.FRENCH.2160p',
      );
      expect(parsed.queries, contains('Hoppers'));
      expect(parsed.year, 2026);
    });

    test('数字开头的中文片名不误伤（24城记）', () {
      final parsed = ScraperService.parseTitle('24城记');
      expect(parsed.queries.first, '24城记');
    });

    test('网盘目录的年份与中文发布标签被剥离', () {
      final parsed = ScraperService.parseTitle('嫁金钗 (2026) 4K HDR杜比视界 全30集');
      expect(parsed.queries.first, '嫁金钗');
      expect(parsed.queries, contains('嫁金钗'));
      expect(parsed.year, 2026);
    });
  });
}
