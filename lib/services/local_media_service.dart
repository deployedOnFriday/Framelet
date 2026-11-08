import 'dart:async';
import 'dart:io';

import '../models/media_source.dart';
import 'webdav_service.dart';

/// 本地目录扫描。路径在库内统一保存为正斜杠形式，播放时再交给 File。
class LocalMediaService {
  LocalMediaService._();

  /// 视频数量上限，只用于防止误选到超大目录（如下载盘）时把内存撑爆；
  /// 目录层级不设上限，整棵树递归（主流媒体库软件的做法）。
  static const maxVideoCount = 20000;

  static Future<void> testConnection(MediaSource source) async {
    final directory = Directory(source.address);
    if (!await directory.exists()) {
      throw FileSystemException('目录不存在', source.address);
    }
    await directory.list(followLinks: false).take(1).toList();
  }

  static Future<ScanResult> scan(
    MediaSource source, {
    void Function(String message)? onProgress,
  }) async {
    final root = Directory(source.address);
    if (!await root.exists()) {
      throw FileSystemException('目录不存在', source.address);
    }

    final videos = <ScannedVideo>[];
    final visited = <String>{};
    var truncated = false;
    final queue = <({Directory directory, MediaKind? kind})>[
      (directory: root, kind: null),
    ];

    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      final key = normalizePath(current.directory.path).toLowerCase();
      if (!visited.add(key)) continue;

      onProgress?.call('正在读取 ${current.directory.path}');
      final List<FileSystemEntity> entries;
      try {
        entries = await current.directory
            .list(followLinks: false)
            .toList();
      } on FileSystemException {
        onProgress?.call('跳过无法读取的目录 ${current.directory.path}');
        continue;
      }

      entries.sort(
        (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()),
      );
      for (final entry in entries) {
        if (entry is Link) continue;
        final name = _basename(entry.path);
        if (name.startsWith('.')) continue;

        if (entry is Directory) {
          if (WebDavService.isSystemFolder(name)) continue;
          queue.add((
            directory: entry,
            kind: current.kind ?? WebDavService.matchKind(name),
          ));
          continue;
        }
        if (entry is! File || !WebDavService.isVideoFile(name)) continue;
        // 花絮/预告保留：详情页单独分区展示，海报墙不计入正片集数
        if (videos.length >= maxVideoCount) {
          onProgress?.call('已达到扫描上限 $maxVideoCount 个文件，停止深入');
          truncated = true;
          break;
        }

        var size = 0;
        DateTime? modified;
        try {
          final stat = await entry.stat();
          size = stat.size;
          modified = stat.modified;
        } catch (_) {
          // 单个文件元数据失败不影响扫描
        }
        videos.add(
          ScannedVideo(
            sourceId: source.id,
            path: normalizePath(entry.path),
            title: WebDavService.cleanTitle(name),
            kind: WebDavService.resolveKind(name, current.kind),
            sizeBytes: size,
            modified: modified,
          ),
        );
      }
      if (truncated) break;
    }
    return ScanResult(videos: videos, truncated: truncated);
  }

  static String normalizePath(String path) => path.replaceAll('\\', '/');

  static String _basename(String path) {
    final normalized = normalizePath(path);
    final index = normalized.lastIndexOf('/');
    return index >= 0 ? normalized.substring(index + 1) : normalized;
  }
}
