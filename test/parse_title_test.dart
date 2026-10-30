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

    test('英文剧名不受误伤', () {
      final parsed = ScraperService.parseTitle(
        'Apocalypse.Hotel.2025.S01E01.CR.UBWEB',
      );
      expect(parsed.queries.first, 'Apocalypse Hotel');
      expect(parsed.year, 2025);
    });
  });
}
