// 临时验证：完整刮削链路（搜索 + 海报下载 + 缓存）
// 用法：TMDB_KEY=<your key> dart run tool/tmdb_scrape_check.dart
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:framelet/services/scraper_service.dart';

Future<void> main() async {
  final key = Platform.environment['TMDB_KEY'];
  if (key == null || key.isEmpty) {
    print('请通过环境变量 TMDB_KEY 提供密钥');
    return;
  }
  ScraperService.tmdbApiKey = key;

  const samples = [
    '三体_01_4K',
    '[末日酒店].Apocalypse.Hotel.2025.S01E01.CR.UBWEB',
    '流浪地球2.2023.2160p',
    'Three.Body.2023.S01E01.2160p.WEB-DL',
  ];

  for (final raw in samples) {
    final parsed = ScraperService.parseTitle(raw);
    print('原始: $raw');
    print('  查询: ${parsed.queries} 年份: ${parsed.year}');
    final stopwatch = Stopwatch()..start();
    ScrapeResult? hit;
    for (final query in parsed.queries) {
      hit = await ScraperService.searchTmdb(query, year: parsed.year);
      if (hit != null) break;
    }
    if (hit == null) {
      print('  ✗ 未匹配 (${stopwatch.elapsedMilliseconds}ms)');
      continue;
    }
    print(
      '  ✓ 命中: ${hit.name} (${hit.year}) 评分 ${hit.rating} (${stopwatch.elapsedMilliseconds}ms)',
    );
    print('    简介: ${(hit.summary ?? '').substring(0, (hit.summary?.length ?? 0).clamp(0, 50))}…');
    if (hit.posterUrl != null) {
      final path = await ScraperService.downloadPoster(
        hit.posterUrl!,
        cacheKey: 'check_${hit.name}',
      );
      print('    海报缓存: ${path ?? '下载失败'}');
      if (path != null) {
        final size = File(path).lengthSync();
        print('    文件大小: ${(size / 1024).toStringAsFixed(0)} KB');
      }
    }
    print('');
  }
  print('缓存目录: ${ScraperService.posterDir().path}');
}
