import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// 播放暂停帧缩略图：写入应用支持目录，供最近播放卡片显示。
class ThumbnailService {
  ThumbnailService._();

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
      await directory.create(recursive: true);
      final key = sha1
          .convert(utf8.encode('$sourceId|$videoPath'))
          .toString();
      final file = File(
        '${directory.path}${Platform.pathSeparator}$key.jpg',
      );
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }
}
