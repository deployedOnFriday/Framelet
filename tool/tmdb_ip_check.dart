// 临时验证：TMDB 连通性（无效 key 应快速返回 null 而非超时）
// ignore_for_file: avoid_print

import 'package:framelet/services/scraper_service.dart';

Future<void> main() async {
  ScraperService.tmdbApiKey = 'test';
  final stopwatch = Stopwatch()..start();
  final result = await ScraperService.searchTmdb('三体');
  print('无效 key 结果: $result，耗时 ${stopwatch.elapsedMilliseconds}ms');
  print(result == null && stopwatch.elapsedMilliseconds < 8000
      ? '✓ 通路正常（服务器响应了，只是 key 无效）'
      : '✗ 通路异常');
}
