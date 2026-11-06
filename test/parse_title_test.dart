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
      expect(parsed.queries.first, '玩具总动员1');
      expect(parsed.queries, contains('玩具总动员'));
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
}
