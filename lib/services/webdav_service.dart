import 'dart:convert';

import 'package:webdav_client/webdav_client.dart' as webdav;

import '../models/media_source.dart';

/// WebDAV 连接与扫描服务。密码只在内存中传递，绝不落日志。
class WebDavService {
  WebDavService._();

  static final videoExtensions = {
    '.mp4',
    '.mkv',
    '.avi',
    '.mov',
    '.wmv',
    '.flv',
    '.ts',
    '.m2ts',
    '.webm',
    '.rmvb',
    '.rm',
    '.m4v',
    '.mpg',
    '.mpeg',
    '.vob',
  };

  static const _kindKeywords = <MediaKind, List<String>>{
    MediaKind.movie: ['电影', 'movie', 'film'],
    MediaKind.series: ['电视剧', '剧集', '连续剧', 'tv', 'series', 'drama'],
    MediaKind.anime: ['动漫', '动画', '番剧', 'anime', 'animation'],
    MediaKind.variety: ['综艺', 'variety', 'show'],
  };

  static const maxScanDepth = 3;
  static const maxVideoCount = 3000;

  /// 建立客户端。uri 规范化：去掉结尾斜杠。
  static webdav.Client _client(MediaSource source, String password) {
    final client = webdav.newClient(
      source.address.trim().replaceFirst(RegExp(r'/+$'), ''),
      user: source.username,
      password: password,
      debug: false,
    );
    client.setConnectTimeout(15000);
    client.setSendTimeout(30000);
    client.setReceiveTimeout(30000);
    return client;
  }

  /// 测试连接；失败抛异常，成功静默返回。
  static Future<void> testConnection(
    MediaSource source,
    String password,
  ) async {
    final client = _client(source, password);
    final directory = source.directory.trim().isEmpty
        ? '/'
        : source.directory.trim();
    // 直接对媒体目录做 PROPFIND：同时验证连通性与认证，
    // 兼容「地址填主机、媒体目录填 /dav」的网盘填法。
    await client.readDir(directory);
  }

  /// 递归扫描视频文件，返回扁平列表。
  ///
  /// 分类规则：路径上第一段命中关键词的目录决定分类；未命中的默认按电影处理。
  static Future<List<ScannedVideo>> scan(
    MediaSource source,
    String password, {
    void Function(String message)? onProgress,
  }) async {
    final client = _client(source, password);
    final videos = <ScannedVideo>[];
    final root = source.directory.trim().isEmpty
        ? '/'
        : source.directory.trim();
    final visited = <String>{};

    // 队列元素：目录路径、已确定分类（null=待定）、当前深度
    final queue = <(String, MediaKind?, int)>[(root, null, 0)];

    while (queue.isNotEmpty) {
      final (dirPath, kind, depth) = queue.removeAt(0);
      final key = dirPath.toLowerCase();
      if (visited.contains(key)) continue;
      visited.add(key);

      onProgress?.call('正在读取 $dirPath');
      final List<webdav.File> entries;
      try {
        entries = await client.readDir(dirPath);
      } catch (error) {
        // 单个目录失败不中断整体扫描
        onProgress?.call('跳过无法读取的目录 $dirPath');
        continue;
      }

      for (final entry in entries) {
        final name = entry.name ?? '';
        final path = entry.path ?? '';
        if (name.isEmpty || path.isEmpty) continue;

        if (entry.isDir ?? false) {
          final childKind = kind ?? matchKind(name);
          if (depth < maxScanDepth) {
            queue.add((path, childKind, depth + 1));
          }
          continue;
        }
        if (!isVideoFile(name)) continue;
        if (videos.length >= maxVideoCount) {
          onProgress?.call('已达到扫描上限 $maxVideoCount 个文件，停止深入');
          return videos;
        }
        videos.add(
          ScannedVideo(
            sourceId: source.id,
            path: path,
            title: cleanTitle(name),
            kind: kind ?? matchKind(name) ?? MediaKind.movie,
            sizeBytes: entry.size ?? 0,
            modified: entry.mTime,
          ),
        );
      }
    }
    return videos;
  }

  static bool isVideoFile(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return videoExtensions.contains(name.substring(dot).toLowerCase());
  }

  /// 目录名 -> 分类；不匹配返回 null。
  static MediaKind? matchKind(String name) {
    final lower = name.toLowerCase();
    for (final entry in _kindKeywords.entries) {
      for (final keyword in entry.value) {
        if (lower.contains(keyword)) return entry.key;
      }
    }
    return null;
  }

  /// 构造可直接播放的文件 URL（路径逐段编码，避免中文/空格问题）。
  static Uri playUrl(MediaSource source, String filePath) {
    final base = Uri.parse(source.address.trim());
    final segments = filePath
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map((segment) => Uri.decodeComponent(segment))
        .toList();
    return Uri(
      scheme: base.scheme.isEmpty ? 'http' : base.scheme,
      host: base.host,
      port: base.port,
      pathSegments: segments,
    );
  }

  /// Basic 认证头，供播放器以 HTTP 头方式访问 WebDAV 文件。
  static String authHeader(String username, String password) {
    final raw = utf8.encode('$username:$password');
    return 'Basic ${base64Encode(raw)}';
  }

  /// 文件名 -> 展示标题：去扩展名、去常见压制标签。
  static String cleanTitle(String fileName) {
    final dot = fileName.lastIndexOf('.');
    var title = dot > 0 ? fileName.substring(0, dot) : fileName;
    title = title.replaceAll(RegExp(r'\.[0-9A-Za-z]{2,4}$'), '');
    title = title
        .replaceAll(
          RegExp(
            r'[-.\s]*\b(1080p|720p|2160p|4k|x264|x265|h\.?264|h\.?265|hevc|aac|flac|bluray|web-?dl|hdr)\b[-.\s]*',
            caseSensitive: false,
          ),
          ' ',
        )
        .trim();
    return title.isEmpty ? fileName : title;
  }
}
