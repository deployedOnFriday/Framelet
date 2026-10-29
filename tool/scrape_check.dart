// 临时验证脚本：dart run tool/scrape_check.dart
// ignore_for_file: avoid_print

import 'package:framelet/services/scraper_service.dart';

/// 临时验证脚本：dart run tool/scrape_check.dart
Future<void> main() async {
  const samples = [
    '[末日酒店].Apocalypse.Hotel.2025.S01E01.CR.UBWEB',
    '三体_01_4K',
    'Three.Body.2023.S01E01.2160p.WEB-DL',
    '[OurTV] The.Last.of.Us.S02E03.1080p',
    '流浪地球2.2023.2160p',
  ];

  for (final raw in samples) {
    final parsed = ScraperService.parseTitle(raw);
    print('原始: $raw');
    print('  查询候选: ${parsed.queries}  年份: ${parsed.year}');
    ScrapeResult? hit;
    for (final query in parsed.queries) {
      hit = await ScraperService.search(query, year: parsed.year);
      if (hit != null) {
        print('  命中: ${hit.name} (${hit.year}) 评分 ${hit.rating}');
        print('  海报: ${hit.posterUrl}');
        print('  简介: ${(hit.summary ?? '').substring(0, (hit.summary?.length ?? 0).clamp(0, 60))}…');
        break;
      }
    }
    if (hit == null) print('  ✗ 未匹配');
    print('');
  }
}
