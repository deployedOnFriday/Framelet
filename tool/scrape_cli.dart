// 后台补刮 CLI：无窗口运行，刮完输出结果 JSON 供应用导入。
// 用法：
//   TMDB_KEY=<key> dart run tool/scrape_cli.dart
// 输入：%TEMP%/framelet_dump.json（应用导出的媒体库快照）
// 输出：%TEMP%/framelet_scrape_result.json
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:framelet/services/scraper_service.dart';

/// 与应用内 ScannedVideo 对齐的轻量条目。
class Item {
  Item({
    required this.sourceId,
    required this.path,
    required this.title,
    required this.kind,
    required this.episodeCount,
    this.tmdbId,
  });

  final String sourceId;
  final String path;
  String title;
  final String kind;
  int episodeCount;
  int? tmdbId;
  String? posterPath;
  String? backdropPath;
  String? summary;
  String? rating;
  String? stillPath;
  String? episodeTitle;

  String get parent {
    final index = path.lastIndexOf('/');
    return index > 0 ? path.substring(0, index) : path;
  }
}

bool looksLikeEpisode(String name) {
  final lower = name.toLowerCase();
  return RegExp(r'[sS]\d{1,2}[eE]\d{1,3}').hasMatch(lower) ||
      RegExp(r'\b[eE][pP]?\d{1,3}\b').hasMatch(lower) ||
      RegExp(r'\b\d{1,2}[xX]\d{1,3}\b').hasMatch(lower) ||
      RegExp(r'第\s*\d{1,4}\s*[集期话]').hasMatch(name) ||
      RegExp(r'\bepisode\s*\d{1,3}\b', caseSensitive: false).hasMatch(lower);
}

int seasonOf(Item item) {
  int extract(String text) {
    for (final pattern in [
      RegExp(r'[sS](\d{1,2})[eE]\d{1,3}'),
      RegExp(r'第\s*([0-9一二三四五六七八九十]+)\s*季'),
      RegExp(r'season\s*(\d{1,2})', caseSensitive: false),
    ]) {
      final match = pattern.firstMatch(text);
      if (match != null) {
        final parsed = int.tryParse(match.group(1)!);
        if (parsed != null) return parsed;
      }
    }
    return 0;
  }

  var season = extract(item.title);
  if (season > 0) return season;
  season = extract(item.path);
  if (season > 0) return season;

  // 所在目录名的尾部数字视为季号：唐朝诡事录2 → 第2季
  final parent = item.parent;
  final index = parent.lastIndexOf('/');
  final segment = index >= 0 ? parent.substring(index + 1) : parent;
  final tailMatch = RegExp(r'(\d{1,2})\s*$').firstMatch(segment);
  if (tailMatch != null) {
    final parsed = int.tryParse(tailMatch.group(1)!);
    if (parsed != null && parsed > 0) return parsed;
  }
  return 1;
}

void main(List<String> args) async {
  final key = Platform.environment['TMDB_KEY'] ?? '';
  if (key.isEmpty) {
    print('缺少 TMDB_KEY 环境变量');
    exit(2);
  }
  ScraperService.tmdbApiKey = key;

  final dumpPath = args.isNotEmpty ? args[0] : _defaultDumpPath();
  final dumpFile = File(dumpPath);
  if (!dumpFile.existsSync()) {
    print('找不到媒体库快照: $dumpPath');
    exit(2);
  }
  final rows = (jsonDecode(dumpFile.readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  // 从快照重建原始文件列表
  final items = <Item>[];
  final aggregatedByPath = <String, Map<String, dynamic>>{};
  for (final row in rows) {
    if (row['type'] == 'aggregated') {
      aggregatedByPath[row['path'] as String] = row;
      if ((row['episodeCount'] as int? ?? 1) <= 1) {
        items.add(
          Item(
            sourceId: 'main',
            path: row['path'] as String,
            title: row['title'] as String,
            kind: row['kind'] as String,
            episodeCount: 1,
          ),
        );
      }
    } else if (row['type'] == 'episode') {
      items.add(
        Item(
          sourceId: 'main',
          path: row['path'] as String,
          title: row['title'] as String,
          kind: 'series',
          episodeCount: 1,
        ),
      );
    }
  }
  print('待处理文件: ${items.length}');

  // 按父目录聚合成刮削任务（与应用同规则）
  final grouped = <String, List<Item>>{};
  for (final item in items) {
    grouped.putIfAbsent(item.parent, () => []).add(item);
  }
  final jobs = <(String title, String kind, List<Item> group)>[];
  for (final entry in grouped.entries) {
    final group = entry.value;
    final agg = aggregatedByPath[group.first.path];
    // 没有聚合记录（多季合并后非主季的文件）时，用文件夹名兜底，
    // 否则会拿原始文件名（01）去搜索，必然失败
    final title = agg != null
        ? agg['title'] as String
        : _folderTitle(group.first.parent);
    final kind = agg != null ? agg['kind'] as String : 'movie';
    jobs.add((title, kind, group));
  }
  print('刮削任务: ${jobs.length}');

  final resultOut = <String, Map<String, Object?>>{};
  var done = 0;
  for (final job in jobs) {
    final (title, kind, group) = job;
    done++;
    print('[$done/${jobs.length}] $title（${group.length} 集）');
    final preferTv = group.length > 1 || kind != 'movie';
    final parsed = ScraperService.parseTitle(title);
    final queries = parsed.queries;
    ScrapeResult? result;
    // 路径自带 {tmdbid-NNN} 时免搜索直取详情（最精确）
    int? pathTmdbId;
    final tmdbPattern = RegExp(r'\{tmdbid-(\d+)\}', caseSensitive: false);
    for (final member in group) {
      final m = tmdbPattern.firstMatch(member.path);
      if (m != null) {
        pathTmdbId = int.tryParse(m.group(1)!);
        break;
      }
    }
    if (pathTmdbId != null) {
      print('  路径自带 tmdbid=$pathTmdbId，免搜索');
      result = await ScraperService.fetchTmdbDetails(
        mediaType: preferTv ? 'tv' : 'movie',
        id: pathTmdbId,
      );
    }
    if (result == null) {
      for (final query in queries) {
        result = await ScraperService.searchTmdb(
          query,
          year: parsed.year,
          preferTv: preferTv,
        );
        if (result != null) break;
      }
    }

    if (result == null || result.tmdbId == null) {
      print('  ✗ 未命中 TMDB');
      continue;
    }

    // 详情（背景图/类型/演员）
    final details = await ScraperService.fetchTmdbDetails(
      mediaType: result.mediaType ?? 'movie',
      id: result.tmdbId!,
    );

    // 海报与背景
    String? posterPath;
    if (result.posterUrl != null) {
      posterPath = await ScraperService.downloadPoster(
        result.posterUrl!,
        cacheKey: 'cli_${kind}_${result.name}',
      );
    }
    String? backdropPath;
    final backdropUrl = details?.backdropUrl;
    if (backdropUrl != null) {
      backdropPath = await ScraperService.downloadPoster(
        backdropUrl,
        cacheKey: 'cli_backdrop_${result.name}',
      );
    }

    // 单集剧照与单集名（剧集）
    final seasonNumber = seasonOf(group.first);
    final episodeStillPaths = <int, String>{};
    final episodeTitles = <int, String>{};
    if ((result.mediaType ?? '') == 'tv') {
      final stills = await ScraperService.fetchEpisodeStills(
        tvId: result.tmdbId!,
        seasonNumber: seasonNumber,
      );
      for (final entry in stills.entries) {
        final stillUrl = entry.value.stillUrl;
        if (stillUrl != null) {
          final path = await ScraperService.downloadPoster(
            stillUrl,
            cacheKey:
                'cli_still_${result.tmdbId}_s${seasonNumber}e${entry.key}',
          );
          if (path != null) episodeStillPaths[entry.key] = path;
        }
        if (entry.value.title != null) {
          episodeTitles[entry.key] = entry.value.title!;
        }
      }
    }

    // 季海报与季简介：多季剧每季不同（如综艺第八季 vs 第一季）
    String? seasonOverview;
    if ((result.mediaType ?? '') == 'tv') {
      final seasonDetails = await ScraperService.fetchSeasonDetails(
        tvId: result.tmdbId!,
        seasonNumber: seasonNumber,
      );
      if (seasonDetails != null) {
        seasonOverview = seasonDetails.overview;
        if (seasonDetails.posterUrl != null) {
          final seasonPoster = await ScraperService.downloadPoster(
            seasonDetails.posterUrl!,
            cacheKey: 'cli_season_${result.tmdbId}_s$seasonNumber',
          );
          if (seasonPoster != null) posterPath = seasonPoster;
        }
      }
    }

    // 写回组内每个文件
    for (final member in group) {
      // 标题可能被 cleanTitle 洗掉集数标记（Whirlwind.Girl.E01 →
      // Whirlwind.Girl），回退用原始文件名解析集号
      final rawName = member.path.split('/').last;
      final epNumber = _episodeNumber(member.title) ?? _episodeNumber(rawName);
      resultOut[member.path] = {
        'posterPath': posterPath,
        'backdropPath': backdropPath,
        'summary': (seasonOverview ?? details?.summary ?? result.summary),
        'rating': (details?.rating ?? result.rating),
        'tmdbId': result.tmdbId,
        'tmdbTitle': result.name,
        'stillPath': episodeStillPaths[epNumber],
        'episodeTitle': episodeTitles[epNumber],
      };
    }
    print(
      '  ✓ ${result.name} (${result.year}) 剧照 ${episodeStillPaths.length}/${group.length}',
    );
  }

  final outFile = File(_defaultResultPath());
  outFile.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(resultOut),
    flush: true,
  );
  print('完成，共 ${resultOut.length} 条 → ${outFile.path}');
}

String _defaultDumpPath() {
  final temp = Platform.environment['TEMP'] ?? r'C:\Temp';
  return '$temp/framelet_dump.json';
}

String _defaultResultPath() {
  final temp = Platform.environment['TEMP'] ?? r'C:\Temp';
  return '$temp/framelet_scrape_result.json';
}

int? _episodeNumber(String title) {
  // 综艺「第N期上/中/下」：上=1、中=2、下=3 顺延，与 TMDB 分集一致
  final part = RegExp(r'第\s*(\d{1,3})\s*期\s*([上中下])').firstMatch(title);
  if (part != null) {
    final base = int.tryParse(part.group(1)!);
    final sub = const {'上': 1, '中': 2, '下': 3}[part.group(2)];
    if (base != null && sub != null) return (base - 1) * 3 + sub;
  }
  final patterns = [
    RegExp(r'[sS]\d{1,2}[eE](\d{1,3})'),
    RegExp(r'(?:^|[.\s_-])e(?:p)?(\d{1,3})(?:$|[.\s_-])', caseSensitive: false),
    RegExp(r'第\s*(\d{1,4})\s*[集话期]'),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(title);
    if (match?.group(1) case final number?) return int.tryParse(number);
  }
  final plain = RegExp(
    r'(?:^|[.\s_~-])(\d{1,4})\s*[~\-_.]?\s*(4k|8k|1080p|720p|2160p|hdr10?)?\s*$',
    caseSensitive: false,
  ).firstMatch(title);
  return int.tryParse(plain?.group(1) ?? '');
}

/// 从父目录路径取文件夹名并做最小清洗（剥季号/年份/画质尾巴）。
String _folderTitle(String parent) {
  var name = parent.split('/').lastWhere((s) => s.isNotEmpty, orElse: () => '');
  try {
    name = Uri.decodeComponent(name);
  } catch (_) {}
  name = name
      .replaceAll(RegExp(r'[（(]\s*(19|20)\d{2}\s*[）)]'), '')
      .replaceAll(RegExp(r'[（(][^）)]*[）)]'), '')
      .replaceAll(
        RegExp(
          r'\s*(60fps|120fps|60帧|120帧|高码|4k|8k|1080p|2160p)\s*',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
  return name;
}
