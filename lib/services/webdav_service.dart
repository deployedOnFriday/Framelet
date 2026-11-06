import 'dart:convert';
import 'dart:io';

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

  static const subtitleExtensions = {
    '.srt',
    '.ass',
    '.ssa',
    '.vtt',
    '.sub',
    '.sup',
  };

  /// 本会话内按原始地址记忆的「可用 IPv4 主机」。家宽 IPv6 常见配置
  /// 问题：DNS 同时给 AAAA+A，AAAA 路由不通（浏览器 Happy Eyeballs 自动
  /// 回落所以「网页打得开」），而 Dart HttpClient 顺序尝试会被 IPv6 卡死。
  /// 探测出 IPv6 不通后把主机替换成 IPv4 记在这里，后续所有客户端受益。
  static final Map<String, String> _preferredHost = {};

  /// 建立客户端。uri 规范化：去掉结尾斜杠；命中 IPv4 回落时替换主机。
  static webdav.Client _client(MediaSource source, String password) {
    final raw = source.address.trim().replaceFirst(RegExp(r'/+$'), '');
    final address = _preferredHost[raw] ?? raw;
    final client = webdav.newClient(
      address,
      user: source.username,
      password: password,
      debug: false,
    );
    client.setConnectTimeout(15000);
    client.setSendTimeout(30000);
    client.setReceiveTimeout(30000);
    return client;
  }

  /// 规范化「目录」字段：地址尾段（如 /dav）在目录里被重复填写时
  /// 自动剥掉，避免拼出 /dav/dav 读 404。
  ///
  /// 标准填法：地址 = WebDAV 服务根（AList 为 http://host:5244/dav），
  /// 目录 = 服务根以下的相对路径（/ 或 /夸克网盘/movie）。
  /// （若用户真有一个名为 dav 的挂载目录且地址已含 /dav，此处会
  /// 误纠——比 404 静默 0 条好。）
  static String _normalizeDirectory(String address, String directory) {
    final dir = directory.trim();
    if (dir.isEmpty) return '/';
    final segments =
        Uri.parse(address.trim()).path.split('/').where((s) => s.isNotEmpty);
    final lastSegment = segments.isEmpty ? '' : segments.last.toLowerCase();
    if (lastSegment.isEmpty) return dir;
    final dirSegments =
        dir.split('/').where((s) => s.isNotEmpty).toList();
    if (dirSegments.isEmpty) return '/';
    if (dirSegments.first.toLowerCase() == lastSegment) {
      dirSegments.removeAt(0);
    }
    final normalized = '/${dirSegments.join('/')}';
    return normalized == '//' ? '/' : normalized;
  }

  /// 测试连接；失败抛 StateError（文案已是人话，调用方原样透传）。
  static Future<void> testConnection(
    MediaSource source,
    String password,
  ) async {
    final directory = _normalizeDirectory(source.address, source.directory);
    // 直接对媒体目录做 PROPFIND：同时验证连通性与认证，
    // 兼容「地址填主机、媒体目录填 /dav」的网盘填法。
    try {
      await _client(source, password).readDir(directory);
      return;
    } catch (error) {
      final text = error.toString().toLowerCase();
      if (text.contains('401') ||
          text.contains('unauthorized') ||
          text.contains('auth')) {
        throw StateError(
          '认证未通过（服务器返回 401）：请确认用户名与密码。'
          'AList 需在「用户管理」给账号勾选 WebDAV 读取权限，'
          'WebDAV 地址为 http://主机:5244/dav（浏览器打开的 :5244 是'
          '网页界面，与 WebDAV 认证无关）。',
        );
      }
      if (text.contains('404')) {
        throw StateError(
          '目录不存在（服务器返回 404）：请检查地址尾段与「目录」'
          '是否重复填写（例如地址已含 /dav，目录里又填了 /dav）。',
        );
      }

      // 网络/超时类错误：做 TCP 层探测，区分 IPv6 失联与整机不可达
      final probe = await _probeHost(source.address.trim());
      switch (probe) {
        case 'ipv6-broken':
          final ipv4 = await _firstIpv4(source.address.trim());
          if (ipv4 != null) {
            // 记住 IPv4 回落并重试一次（仅 http 可安全替换主机）
            final uri = Uri.parse(source.address.trim());
            if (uri.scheme != 'https') {
              _preferredHost[source.address.trim()] = ipv4;
              try {
                await _client(source, password).readDir(directory);
                return;
              } catch (retryError) {
                final retryText = retryError.toString().toLowerCase();
                if (retryText.contains('401') ||
                    retryText.contains('unauthorized') ||
                    retryText.contains('auth')) {
                  throw StateError(
                    '已连接成功但认证未通过（401）：请确认用户名与密码。'
                    'AList 需在「用户管理」给账号勾选 WebDAV 读取权限。',
                  );
                }
                throw StateError(
                  '服务器 IPv6 不可达，已自动改用 IPv4（$ipv4）仍失败：'
                  '$retryError',
                );
              }
            }
          }
          throw StateError(
            '服务器 IPv6 地址不通、IPv4 可达，但当前线路无法直接改用。'
            '可在 hosts 里把域名指向 IPv4，或换用 http 地址重试。',
          );
        case 'tcp-dead':
          final uri = Uri.tryParse(source.address.trim());
          final host = uri?.host ?? source.address.trim();
          final port =
              (uri?.port == 0 || uri?.port == null)
              ? (uri?.scheme == 'https' ? 443 : 80)
              : uri!.port;
          throw StateError(
            '无法建立 TCP 连接（$host:$port）：服务器未开机、端口未放行'
            '或被当前网络拦截。浏览器能打开网页界面，不代表 WebDAV '
            '端口对当前网络可达。',
          );
      }
      rethrow;
    }
  }

  /// TCP 探测：分别尝试 IPv6/IPv4 各一条，返回
  /// 'ipv6-broken'（v6 不通 v4 通）/ 'tcp-dead'（都不通）/ 'tcp-ok'。
  static Future<String> _probeHost(String address) async {
    final uri = Uri.tryParse(address);
    final host = uri?.host ?? '';
    if (host.isEmpty) return 'tcp-ok';
    final port = (uri!.port == 0)
        ? (uri.scheme == 'https' ? 443 : 80)
        : uri.port;
    List<InternetAddress> addrs;
    try {
      addrs = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 6));
    } catch (_) {
      return 'tcp-dead';
    }
    Future<bool> probeIp(InternetAddress a) => Socket.connect(a, port,
            timeout: const Duration(seconds: 4))
        .then((s) {
      s.destroy();
      return true;
    }).catchError((_) => false);
    final v6 = addrs
        .where((a) => a.type == InternetAddressType.IPv6)
        .toList();
    final v4 = addrs
        .where((a) => a.type == InternetAddressType.IPv4)
        .toList();
    final v6ok = v6.isEmpty ? null : await probeIp(v6.first);
    final v4ok = v4.isEmpty ? null : await probeIp(v4.first);
    if (v4ok == true && v6ok == false) return 'ipv6-broken';
    if (v4ok == false && v6ok != true) return 'tcp-dead';
    return 'tcp-ok';
  }

  static Future<String?> _firstIpv4(String address) async {
    final uri = Uri.tryParse(address);
    final host = uri?.host ?? '';
    if (host.isEmpty) return null;
    try {
      final addrs = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 6));
      for (final a in addrs) {
        if (a.type == InternetAddressType.IPv4) return a.address;
      }
    } catch (_) {}
    return null;
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
    final root = _normalizeDirectory(source.address, source.directory);
    final visited = <String>{};
    // 根目录读取失败时记录原因：扫出 0 条多半是这里出的问题，
    // 静默吞掉会让用户只看到「0 条」而不知道哪错了。
    var rootError = '';

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
        onProgress?.call('跳过无法读取的目录 $dirPath：$error');
        if (dirPath == root) {
          rootError = '$error';
        }
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
        // 花絮/预告不在此处丢弃：聚合与详情页会把它们单独分区展示
        // （集数只统计正片，海报墙不会混入花絮）
        if (videos.length >= maxVideoCount) {
          onProgress?.call('已达到扫描上限 $maxVideoCount 个文件，停止深入');
          return videos;
        }
        videos.add(
          ScannedVideo(
            sourceId: source.id,
            path: path,
            title: cleanTitle(name),
            kind: resolveKind(name, kind),
            sizeBytes: entry.size ?? 0,
            modified: entry.mTime,
          ),
        );
      }
    }

    // 根目录读不了 + 一无所获：把根因抛出去，别让用户对着 0 条猜。
    if (videos.isEmpty && rootError.isNotEmpty) {
      throw StateError(
        '无法读取 WebDAV 目录 $root：$rootError。'
        '常见原因：① 地址已含 /dav 时「目录」里不要再填 /dav；'
        '② 账号或密码不对；③ 服务端未开启 WebDAV。',
      );
    }
    return videos;
  }

  static bool isVideoFile(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return videoExtensions.contains(name.substring(dot).toLowerCase());
  }

  static bool isSubtitleFile(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return subtitleExtensions.contains(name.substring(dot).toLowerCase());
  }

  /// 查找同一目录下与视频同名的外挂字幕。
  static Future<List<String>> discoverSubtitles(
    MediaSource source,
    String password,
    String videoPath,
  ) async {
    final client = _client(source, password);
    final parent = videoPath.contains('/')
        ? videoPath.substring(0, videoPath.lastIndexOf('/'))
        : '/';
    final List<webdav.File> entries;
    try {
      entries = await client.readDir(parent.isEmpty ? '/' : parent);
    } catch (_) {
      return const [];
    }
    final videoStem = _stemOf(videoPath);
    final result = <String>[];
    for (final entry in entries) {
      if (entry.isDir ?? false) continue;
      final name = entry.name ?? '';
      final path = entry.path ?? '';
      if (path.isEmpty || !isSubtitleFile(name)) continue;
      if (!_subtitleMatches(videoStem, _stemOf(name))) continue;
      result.add(path);
    }
    result.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return result;
  }

  static String _stemOf(String path) {
    final name = path.split('/').last;
    final dot = name.lastIndexOf('.');
    return (dot > 0 ? name.substring(0, dot) : name).toLowerCase();
  }

  static bool _subtitleMatches(String videoStem, String subtitleStem) {
    if (subtitleStem == videoStem) return true;
    return subtitleStem.startsWith('$videoStem.') ||
        subtitleStem.startsWith('${videoStem}_') ||
        subtitleStem.startsWith('$videoStem-');
  }

  /// 文件名/标题是否含集数标记（S01E13、E13、EP13、第13集、1x13）。
  ///
  /// 这是判断「剧集 vs 电影」最可靠的信号，优先于目录名。
  static bool looksLikeEpisode(String name) {
    final lower = name.toLowerCase();
    return RegExp(r'[sS]\d{1,2}[eE]\d{1,3}').hasMatch(lower) ||
        RegExp(r'\b[eE][pP]?\d{1,3}\b').hasMatch(lower) ||
        RegExp(r'\b\d{1,2}[xX]\d{1,3}\b').hasMatch(lower) ||
        RegExp(r'第\s*\d{1,4}\s*[集期话]').hasMatch(name) ||
        RegExp(r'\bepisode\s*\d{1,3}\b', caseSensitive: false).hasMatch(lower);
  }

  /// 标题本身就是一个纯集数（如 "14"、"03"），常见于 `14 4K.mp4`、`1.mkv`。
  static bool looksLikeBareEpisode(String title) =>
      RegExp(r'^\d{1,3}\s*[~\-_.]*\s*$').hasMatch(title.trim());

  /// 花絮类文件：片头片尾、预告、特辑等，不应作为正片条目。
  static bool isExtraFile(String name) {
    final lower = name.toLowerCase();
    const extras = [
      '片头',
      '片尾',
      '预告',
      '花絮',
      '特辑',
      '彩蛋',
      '幕后',
      '制作特辑',
      '精编',
      '集结篇',
      '回顾',
      'trailer',
      'teaser',
      'sample',
      'nced',
      'ncop',
      'featurette',
      'extra',
      'preview',
      'interview',
      'making',
    ];
    final base = cleanTitle(name).toLowerCase();
    for (final extra in extras) {
      if (base.contains(extra) || lower.contains(extra)) return true;
    }
    return false;
  }

  /// 综合目录名与文件名判定分类。
  ///
  /// 规则：
  /// 1. 目录名已明确为动漫/综艺/电视剧 → 沿用（这些分类不会有歧义）
  /// 2. 文件名含集数标记（S01E13）或本身就是集数（14）→ 电视剧
  /// 3. 其余按目录名，最后兜底电影
  static MediaKind resolveKind(String fileName, MediaKind? dirKind) {
    if (dirKind != null &&
        dirKind != MediaKind.movie &&
        dirKind != MediaKind.series) {
      return dirKind;
    }
    // 注意用原始文件名判断：cleanTitle 会把 ".S01E13" 当作扩展名截掉
    if (looksLikeEpisode(fileName)) return MediaKind.series;
    if (looksLikeBareEpisode(cleanTitle(fileName))) return MediaKind.series;
    return dirKind ?? MediaKind.movie;
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

  /// 构造可直接播放的文件 URL。
  ///
  /// 注意：webdav_client 返回的 path 已是解码后的明文（中文、空格、方括号原样），
  /// 只在这里统一编码；再手动 decode 会在文件名含 % 时抛 Illegal percent encoding。
  static Uri playUrl(MediaSource source, String filePath) {
    final base = Uri.parse(source.address.trim());
    final segments = filePath
        .split('/')
        .where((segment) => segment.isNotEmpty)
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

  static final _ipv4Pattern = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

  /// 把域名解析成 IPv4 再播放。
  ///
  /// 很多家庭宽带/域名会同时解析出 IPv6，但 IPv6 实际不通；
  /// Dart 与 libmpv 都会优先尝试 IPv6 并长时间等待超时，表现为黑屏卡住。
  /// 这里只取 IPv4 地址，同时返回原 Host，以便服务器正常识别虚拟主机。
  static Future<({Uri url, String? hostHeader})> resolvePlayUrl(
    MediaSource source,
    String filePath,
  ) async {
    final base = playUrl(source, filePath);
    if (_ipv4Pattern.hasMatch(base.host)) {
      return (url: base, hostHeader: null);
    }
    try {
      final addresses = await InternetAddress.lookup(
        base.host,
        type: InternetAddressType.IPv4,
      ).timeout(const Duration(seconds: 5));
      if (addresses.isNotEmpty) {
        final hostHeader = base.port == 80
            ? base.host
            : '${base.host}:${base.port}';
        return (
          url: base.replace(host: addresses.first.address),
          hostHeader: hostHeader,
        );
      }
    } catch (_) {
      // 解析失败时退回域名直连。
    }
    return (url: base, hostHeader: null);
  }

  /// 文件名 -> 展示标题：去扩展名、去常见压制标签。
  static String cleanTitle(String fileName) {
    fileName = fileName.replaceAll(
      RegExp(r'\s*\{tmdbid-\d+\}\s*', caseSensitive: false),
      ' ',
    );
    // 记录第一个方括号段（[消失的爱人][2014]… 整名都在括号里的兜底）
    final bracket = RegExp(r'[\[【]([^\]】]{2,30})[\]】]')
        .firstMatch(fileName)
        ?.group(1);
    // 书名号与残缺括号当分隔符
    fileName = fileName
        .replaceAll('《', ' ')
        .replaceAll('》', ' ')
        .replaceAll('】', ' ')
        .replaceAll('【', ' ');
    // 「No.14｜」类编号前缀与防屏蔽竖线
    fileName = fileName
        .replaceAll(RegExp(r'^\s*No\.?\d*\s*[｜|]?\s*'), '')
        .replaceAll('丨', '');
    final dot = fileName.lastIndexOf('.');
    var title = dot > 0 ? fileName.substring(0, dot) : fileName;
    // 去双重扩展名（Movie.mkv.torrent → Movie）。
    // 但末尾 token 像集数标记（E01/EP01/纯数字）时必须保留：
    // 旧版会把 Whirlwind.Girl.E01 的 ".E01" 当扩展名剥掉，
    // 同目录所有文件的标题都退化成 "Whirlwind.Girl"，集号解析随之失效
    final trailing = RegExp(r'\.([0-9A-Za-z]{2,4})$').firstMatch(title);
    if (trailing != null && !_isEpisodeToken(trailing.group(1)!)) {
      title = title.substring(0, trailing.start);
    }
    title = title
        .replaceAll(RegExp(r'[-_～~\s]*(全集|完整版|全\d{1,3}集|完结)$'), '')
        .trim();
    title = title
        .replaceAll(
          RegExp(
            r'[-.\s]*\b(1080p|720p|2160p|4k|x264|x265|h\.?264|h\.?265|hevc|aac|flac|bluray|web-?dl|hdr)\b[-.\s]*',
            caseSensitive: false,
          ),
          ' ',
        )
        .trim();
    if (title.isEmpty && bracket != null && bracket.trim().isNotEmpty) {
      title = bracket.trim();
    }
    return title.isEmpty ? fileName : title;
  }

  /// 末尾 token 是否像集数标记：E01、EP01、01、001、S01E01。
  static bool _isEpisodeToken(String token) =>
      RegExp(r'^([eE][pP]?\d{1,3}|[sS]\d{1,2}[eE]\d{1,3}|\d{1,4})$')
          .hasMatch(token);
}
