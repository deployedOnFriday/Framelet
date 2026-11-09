import 'package:flutter_test/flutter_test.dart';
import 'package:framelet/services/scraper_service.dart';

void main() {
  test('内置 TMDB Key 解码为 32 位十六进制 v3 Key', () {
    expect(
      ScraperService.builtinTmdbApiKey,
      matches(RegExp(r'^[0-9a-f]{32}$')),
    );
  });

  test('未读取到用户配置时默认就用内置 Key', () {
    expect(ScraperService.tmdbApiKey, isNotEmpty);
    expect(
      ScraperService.tmdbApiKey,
      ScraperService.builtinTmdbApiKey,
    );
  });
}
