import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'models/media_source.dart';
import 'services/media_library.dart';
import 'services/playback_history.dart';

void main() async {
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
  await PlaybackHistory.instance.load();
  // 诊断：FRAMELET_DUMP=1 时导出媒体库结构，便于排查聚合/刮削问题
  if (Platform.environment['FRAMELET_DUMP'] == '1') {
    _dumpLibrary();
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
        // 每集的原始文件：核对剧照与单集名是否写入
        if (item.episodeCount > 1) {
          for (final episode in library.episodesOf(item)) {
            rows.add({
              'type': 'episode',
              'of': item.title,
              'title': episode.title,
              'path': episode.path,
              'stillPath': episode.stillPath,
              'episodeTitle': episode.episodeTitle,
              'episodeNumber': MediaLibrary.episodeNumberOf(episode.title),
            });
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
