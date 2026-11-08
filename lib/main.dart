import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'core/theme/shader_warmup.dart';
import 'models/media_source.dart';
import 'services/media_library.dart';
import 'services/playback_history.dart';
import 'services/playback_preferences.dart';
import 'services/theme_controller.dart';

void main() async {
  // 必须在 ensureInitialized 之前赋值：initInstances 会执行预热，
  // 把高频效果（渐变卡/圆角裁剪/阴影/转场合成）的 shader 编译从
  // 用户操作的瞬间挪到启动 loading 里。
  PaintingBinding.shaderWarmUp = const FrameletShaderWarmUp();
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // 错误落盘： framework 断言等问题的精确堆栈写入临时目录，便于排障
  FlutterError.onError = (details) {
    try {
      File('${Directory.systemTemp.path}/framelet_error.log').writeAsStringSync(
        '${DateTime.now().toIso8601String()}\n${details.toString()}\n\n',
        mode: FileMode.append,
      );
    } catch (_) {}
    FlutterError.presentError(details);
  };
  await MediaLibrary.instance.load();
  // 定时增量扫描：间隔在设置页配置（默认 30 分钟，可关闭）。
  MediaLibrary.instance.startAutoScan();
  await PlaybackHistory.instance.load();
  await PlaybackPreferences.instance.load();
  await ThemeController.instance.load();
  // 诊断：FRAMELET_DUMP=1 时导出媒体库结构，便于排查聚合/刮削问题
  if (Platform.environment['FRAMELET_DUMP'] == '1') {
    _dumpLibrary();
  }
  // 诊断：FRAMELET_IMPORT=1 时导入 CLI 后台补刮的结果
  if (Platform.environment['FRAMELET_IMPORT'] == '1') {
    Future(() async {
      await Future<void>.delayed(const Duration(seconds: 2));
      final file = File(
        '${Directory.systemTemp.path}/framelet_scrape_result.json',
      );
      if (!file.existsSync()) {
        debugPrint('[Import] 无补刮结果文件');
        return;
      }
      final raw = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final count = await MediaLibrary.instance.importScrapeResults(
        raw.map((k, v) => MapEntry(k, v as Map<String, Object?>)),
      );
      debugPrint('[Import] 已导入 $count 条');
      _dumpLibrary();
    });
  }
  // 诊断：FRAMELET_SCRAPE=1 时启动后自动刮削并导出结果（脚本化补刮）
  if (Platform.environment['FRAMELET_SCRAPE'] == '1') {
    Future(() async {
      await Future<void>.delayed(const Duration(seconds: 4));
      debugPrint('[Scrape] 自动刮削开始');
      await MediaLibrary.instance.scrapeAll();
      debugPrint('[Scrape] 自动刮削结束: ${MediaLibrary.instance.scrapeProgress}');
      _dumpLibrary();
    });
  }
  runApp(const FrameletApp());
}

void _dumpLibrary() {
  try {
    final library = MediaLibrary.instance;
    final rows = <Map<String, Object?>>[];
    for (final source in library.sources) {
      rows.add({
        'type': 'source',
        'name': source.name,
        'address': source.address,
        'directory': source.directory,
      });
    }
    for (final kind in MediaKind.values) {
      final items = library.byKind(kind);
      for (final item in items) {
        rows.add({
          'type': 'aggregated',
          'kind': kind.name,
          'title': item.title,
          'path': item.path,
          'episodeCount': item.episodeCount,
          'hasPoster': item.posterPath != null,
          'poster': item.posterPath,
          'backdrop': item.backdropPath,
          'tmdbId': item.tmdbId,
          'season': MediaLibrary.seasonOf(item),
        });
        // 每集的原始文件：展开该剧所有季（合并条目的 path 只代表其中一季）
        if (item.episodeCount > 1) {
          final seenPaths = <String>{};
          for (final season in library.seasonsOf(item)) {
            for (final episode in library.episodesOf(season)) {
              if (!seenPaths.add(episode.path)) continue;
              rows.add({
                'type': 'episode',
                'of': item.title,
                'title': episode.title,
                'path': episode.path,
                'stillPath': episode.stillPath,
                'episodeTitle': episode.episodeTitle,
                'episodeNumber': MediaLibrary.episodeNumberOf(episode.title),
                'season': MediaLibrary.seasonOf(season),
              });
            }
          }
        }
      }
    }
    final file = File('${Directory.systemTemp.path}/framelet_dump.json');
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(rows),
      flush: true,
    );
    debugPrint('[Dump] 已导出 ${rows.length} 条到 ${file.path}');
  } catch (error) {
    debugPrint('[Dump] 失败: $error');
  }
}
