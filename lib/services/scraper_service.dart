import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 刮削结果：海报地址、简介与评分。
class ScrapeResult {
  const ScrapeResult({
    required this.name,
    this.posterUrl,
    this.summary,
    this.rating,
    this.year,
  });

  final String name;
  final String? posterUrl;
  final String? summary;
  final String? rating;
  final int? year;
}

/// 海报与元数据刮削：
/// - 主源 TVmaze（免费、无需密钥，覆盖剧集/动漫/部分电影）
/// - 图片本地缓存，避免重复下载
/// - 限速友好，失败静默跳过，不影响媒体库使用
class ScraperService {
  ScraperService._();

  static const _userAgent = 'Framelet/0.1 (media library scraper)';
  static const _requestGap = Duration(milliseconds: 260);
  static DateTime _lastRequest = DateTime.fromMillisecondsSinceEpoch(0);

  static HttpClient _httpClient() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..userAgent = _userAgent;

  /// 海报缓存目录：%APPDATA%/com.framelet/framelet/posters
  static Directory posterDir() {
    final appData =
        Platform.environment['APPDATA'] ??
        '${Platform.environment['USERPROFILE']}/AppData/Roaming';
    return Directory('$appData/com.framelet/framelet/posters');
  }

  /// 从文件名/系列名推导查询词与年份。
  ///
  /// 例：`[末日酒店].Apocalypse.Hotel.2025.S01E01.CR.UBWEB`
  /// → 查询候选 ["Apocalypse Hotel", "末日酒店"]，年份 2025。
  static ({List<String> queries, int? year}) parseTitle(String raw) {
    var text = raw;
    final dot = text.lastIndexOf('.');
    if (dot > 0 && dot >= text.length - 5) {
      text = text.substring(0, dot);
    }

    final bracketNames = RegExp(r'[\[【]([^\]】]+)[\]】]')
        .allMatches(text)
        .map((m) => m.group(1)!.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    text = text.replaceAll(RegExp(r'[\[【][^\]】]*[\]】]'), ' ');

    final tokens = text
        .split(RegExp(r'[.\s_]+'))
        .map((token) => token.trim())
        .where((token) => token.isNotEmpty)
        .toList();

    const junkPattern =
        r'^(1080p|720p|2160p|4k|8k|x264|x265|h264|h265|hevc|avc|aac|ac3|eac3|dts|flac|truehd|bluray|blu-ray|bdrip|webrip|web-dl|webdl|hdtv|remux|hdr10?|dv|dolby|atmos|10bit|8bit|proper|repack|extended|uncut|cr|ubweb|nf|amzn|dsnp|hmax|atvp|max|sdr|hevc10)$';
    final junk = RegExp(junkPattern, caseSensitive: false);
    final episode = RegExp(
      r'^(s\d{1,2}(e\d{1,2})?|e\d{1,2}|ep\d{1,3}|\d{1,2}[集期])$',
      caseSensitive: false,
    );

    int? year;
    final cleaned = <String>[];
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      final isYear = RegExp(r'^(19|20)\d{2}$').hasMatch(token);
      if (isYear) {
        year = int.tryParse(token);
        continue;
      }
      if (junk.hasMatch(token) || episode.hasMatch(token)) continue;
      // 末尾的 1~2 位纯数字视为集数
      if (RegExp(r'^\d{1,2}$').hasMatch(token) && i >= tokens.length - 2) {
        continue;
      }
      cleaned.add(token);
    }

    var name = cleaned.join(' ').trim();
    name = name.replaceAll(RegExp(r'\s+'), ' ');
    // 去掉残留的中文集数后缀，如 "三体 01"
    name = name.replaceAll(RegExp(r'\s+\d{1,2}$'), '').trim();

    final queries = <String>[if (name.isNotEmpty) name, ...bracketNames];
    return (queries: queries, year: year);
  }

  /// 在 TVmaze 搜索并挑选最匹配的剧集/影片。
  static Future<ScrapeResult?> search(String query, {int? year}) async {
    if (query.trim().isEmpty) return null;
    final url = Uri.parse(
      'https://api.tvmaze.com/search/shows?q=${Uri.encodeQueryComponent(query)}',
    );
    final client = _httpClient();
    try {
      await _throttle();
      final request = await client.getUrl(url);
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      if (response.statusCode != 200) return null;
      final body = await response.transform(utf8.decoder).join();
      final list = jsonDecode(body) as List<Object?>;
      ScrapeResult? best;
      var bestScore = 0.0;
      for (final item in list) {
        final show =
            (item as Map<String, Object?>)['show'] as Map<String, Object?>;
        final name = show['name'] as String? ?? '';
        final premiered = show['premiered'] as String? ?? '';
        final showYear = int.tryParse(premiered.split('-').first);
        final image = show['image'] as Map<String, Object?>?;
        final poster =
            image?['original'] as String? ?? image?['medium'] as String?;
        final ratingValue =
            (show['rating'] as Map<String, Object?>?)?['average'];
        final summaryRaw = show['summary'] as String?;

        var score = _similarity(query, name);
        if (year != null && showYear != null) {
          final gap = (year - showYear).abs();
          if (gap == 0) score += 0.25;
          if (gap > 2) score -= 0.3;
        }
        if (poster == null) score -= 0.1;
        if (score > bestScore) {
          bestScore = score;
          best = ScrapeResult(
            name: name,
            posterUrl: poster,
            summary: summaryRaw == null ? null : stripHtml(summaryRaw),
            rating: ratingValue is num ? ratingValue.toStringAsFixed(1) : null,
            year: showYear,
          );
        }
      }
      return bestScore >= 0.45 ? best : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// 下载海报到本地缓存，返回文件路径；失败返回 null。
  static Future<String?> downloadPoster(
    String url, {
    required String cacheKey,
  }) async {
    final dir = posterDir();
    final safeKey = _sanitizeFileName(cacheKey);
    final file = File('${dir.path}/$safeKey.jpg');
    if (file.existsSync() && file.lengthSync() > 1024) return file.path;

    final client = _httpClient();
    try {
      await _throttle();
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200) return null;
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final sink = file.openWrite();
      await response.pipe(sink);
      if (file.lengthSync() < 1024) {
        file.deleteSync();
        return null;
      }
      return file.path;
    } catch (_) {
      if (file.existsSync()) file.deleteSync();
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _throttle() async {
    final now = DateTime.now();
    final elapsed = now.difference(_lastRequest);
    if (elapsed < _requestGap) {
      await Future<void>.delayed(_requestGap - elapsed);
    }
    _lastRequest = DateTime.now();
  }

  static String stripHtml(String html) => html
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String _sanitizeFileName(String raw) {
    var hash = 0;
    for (final code in raw.codeUnits) {
      hash = (hash * 31 + code) & 0x7FFFFFFF;
    }
    final cleaned = raw
        .replaceAll(RegExp(r'[^\w\u4e00-\u9fa5-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final trimmed = cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
    return '${trimmed}_${hash.toRadixString(36)}';
  }

  /// 名称相似度：归一化后比较（连字符/下划线/点都视作空格）。
  static double _similarity(String query, String name) {
    final a = _normalize(query);
    final b = _normalize(name);
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;
    // 连字符差异："three body" vs "threebody"
    if (a.replaceAll(' ', '') == b.replaceAll(' ', '')) return 0.95;
    if (b.contains(a) || a.contains(b)) return 0.8;
    final aWords = a.split(' ').where((w) => w.length > 1).toSet();
    final bWords = b.split(' ').where((w) => w.length > 1).toSet();
    if (aWords.isEmpty || bWords.isEmpty) return 0;
    final overlap = aWords.intersection(bWords).length;
    return (overlap / aWords.length) * 0.7;
  }

  static String _normalize(String raw) => raw
      .toLowerCase()
      .replaceAll(RegExp(r'[-_.]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
