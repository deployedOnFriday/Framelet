import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 播放暂停帧缩略图：写入应用支持目录，供最近播放卡片显示。
class ThumbnailService {
  ThumbnailService._();

  static int _lastStamp = 0;

  static Future<String?> save(
    Uint8List bytes,
    String sourceId,
    String videoPath,
  ) async {
    if (bytes.isEmpty) return null;
    try {
      final support = await getApplicationSupportDirectory();
      final directory = Directory(
        '${support.path}${Platform.pathSeparator}thumbnails',
      );
      return await saveTo(directory, bytes, sourceId, videoPath);
    } catch (_) {
      return null;
    }
  }

  /// 每次截图使用新文件名，避免 Flutter 按路径缓存旧解码结果。
  ///
  /// 若继续覆盖同一个 jpg，首页的 [Image.file] 不会重新读取内容，
  /// 最近播放就会长期显示第一次截图时的画面。写入成功后顺手清掉
  /// 该视频的旧缩略图，磁盘占用仍保持每集一张。
  @visibleForTesting
  static Future<String?> saveTo(
    Directory directory,
    Uint8List bytes,
    String sourceId,
    String videoPath,
  ) async {
    if (bytes.isEmpty) return null;
    try {
      await directory.create(recursive: true);
      final key = _keyOf(sourceId, videoPath);
      var stamp = DateTime.now().microsecondsSinceEpoch;
      if (stamp <= _lastStamp) stamp = _lastStamp + 1;
      _lastStamp = stamp;
      final file = File(
        '${directory.path}${Platform.pathSeparator}$key-$stamp.jpg',
      );
      await file.writeAsBytes(bytes, flush: true);
      await _deleteStale(directory, key, file.path);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  static String _keyOf(String sourceId, String videoPath) =>
      sha1.convert(utf8.encode('$sourceId|$videoPath')).toString();

  static Future<void> _deleteStale(
    Directory directory,
    String key,
    String keepPath,
  ) async {
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || entity.path == keepPath) continue;
      final name = entity.uri.pathSegments.last;
      if (name != '$key.jpg' && !name.startsWith('$key-')) continue;
      try {
        await entity.delete();
      } catch (_) {
        // 清理旧图失败不影响新截图展示。
      }
    }
  }
}
