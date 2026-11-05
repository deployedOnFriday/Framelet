import '../models/cast_member.dart';

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
    this.backdropUrl,
    this.genres = const [],
    this.cast = const [],
    this.releaseDate,
    this.runtimeSec,
    this.mediaType,
    this.tmdbId,
  });

  final String name;
  final String? posterUrl;
  final String? summary;
  final String? rating;
  final int? year;
  final String? backdropUrl;
  final List<String> genres;
  final List<CastMember> cast;
  final String? releaseDate;
  final double? runtimeSec;
  final String? mediaType;
  final int? tmdbId;
}

/// 手动匹配用的候选条目（搜索结果的一项）。
class ScrapeCandidate {
  const ScrapeCandidate({
    required this.name,
    required this.mediaType,
    this.originalName,
    this.year,
    this.posterUrl,
    this.overview,
    this.rating,
    this.tmdbId,
  });

  final String name;
  final String mediaType; // 'movie' | 'tv'
  final String? originalName;
  final int? year;
  final String? posterUrl;
  final String? overview;
  final String? rating;

  /// TMDB 条目 ID；有 ID 时可继续拉取详情。
  final int? tmdbId;

  String get typeLabel => mediaType == 'tv' ? '剧集' : '电影';
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

  /// 刮削过程日志回调（由 MediaLibrary 注入，写入临时目录日志）。
  /// 关键失败（图片下载等）必须经由这里显性化，避免静默丢图。
  static void Function(String message)? onLog;

  /// 内置 TMDB API Key：以「明文 XOR 掩码」的十六进制对存储，
  /// 仓库与二进制中不含可直接 grep 的明文，运行时还原。
  /// 注意这是混淆而非加密——决心逆向仍可还原；TMDB key 属免费
  /// 申请的低敏感凭据，此级别足够。用户在设置里填写的 key 永远优先。
  static const String _tmdbKeyMaskedHex =
      '2805d1326095c22fc1cc628f7c4cea7c827dbfce07ef28a40fda02d50f8d5bf2';
  static const String _tmdbKeyMaskHex =
      '1d67b30151a3f74da5ff5bb9197bdf45b21c88f666d84cc73fb935b338ba3ec4';

  static List<int> _unhex(String hex) => [
    for (var i = 0; i + 1 < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];

  static String get builtinTmdbApiKey {
    final masked = _unhex(_tmdbKeyMaskedHex);
    final mask = _unhex(_tmdbKeyMaskHex);
    return String.fromCharCodes([
      for (var i = 0; i < masked.length; i++) masked[i] ^ mask[i],
    ]);
  }

  /// 可选 HTTP 代理（如 127.0.0.1:7890）。
  static String? proxyAddress;

  /// 可选 TMDB API Key（v3）：配置后优先用 TMDB，中文与电影覆盖最好。
  static String? tmdbApiKey;

  /// TMDB API 域名在国内被 DNS 污染，直连超时；
  /// 改用可访问的 CloudFront 节点 IP 直连（TLS 仍按域名校验，安全不受影响）。
  /// IP 来源：CheckTMDB 项目每日更新的国内可用地址。
  static const tmdbIpv4 = <String>[
    '3.167.212.53',
    '3.167.192.35',
    '3.167.194.87',
    '3.164.180.201',
    '3.167.212.89',
    '18.154.132.115',
    '18.154.130.110',
    '3.167.192.127',
  ];

  static HttpClient _httpClient() {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = _userAgent;
    final proxy = proxyAddress?.trim();
    if (proxy != null && proxy.isNotEmpty) {
      client.findProxy = (_) => 'PROXY $proxy';
    }
    return client;
  }

  /// 通过「国内可用 IP + 域名 SNI」直连 TMDB API。
  ///
  /// TMDB 在国内被 DNS 污染，直接解析域名会超时；
  /// 这里用 SecureSocket 手工完成 TLS（host 参数保证 SNI 与证书校验仍按域名），
  /// 再由 IP 建立 TCP 连接，从而绕过污染。
  static Future<String?> _tmdbGet(String pathAndQuery) async {
    const domain = 'api.themoviedb.org';
    final proxy = (proxyAddress ?? '').trim();
    if (proxy.isNotEmpty) {
      // 配了代理时走标准通道
      final client = _httpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('https://$domain$pathAndQuery'),
        );
        final response = await request.close().timeout(
          const Duration(seconds: 15),
        );
        if (response.statusCode != 200) return null;
        return await response.transform(utf8.decoder).join();
      } catch (_) {
        return null;
      } finally {
        client.close(force: true);
      }
    }

    final body = await _sniGetBytes(domain, pathAndQuery);
    return body == null ? null : utf8.decode(body, allowMalformed: true);
  }

  /// 通过「国内可用 IP + 域名 SNI」直连 CDN 并取回响应体（二进制）。
  ///
  /// api 与 image 共用 CloudFront 边缘——同一批边缘 IP 按 SNI 分发，
  /// 因此 image.tmdb.org 的图片也能走这条免代理通道（探针实测可用，
  /// 4 个 IP 中约 2 个直连可达，靠轮询容错）。
  static Future<List<int>?> _sniGetBytes(String host, String pathAndQuery) async {
    for (final ip in tmdbIpv4) {
      final raw = await _sniConnect(ip, host);
      if (raw == null) continue;
      try {
        final bytes = await _sniRequest(
          raw,
          host,
          pathAndQuery,
          maxBytes: 16 * 1024 * 1024,
        );
        if (bytes == null) continue;
        return bytes;
      } catch (_) {
        // 换下一个 IP
      } finally {
        try {
          await raw.close();
        } catch (_) {}
      }
    }
    return null;
  }

  static Future<Socket?> _sniConnect(String ip, String host) async {
    Socket? raw;
    try {
      raw = await Socket.connect(ip, 443).timeout(
        const Duration(seconds: 6),
      );
      return await SecureSocket.secure(raw, host: host).timeout(
        const Duration(seconds: 8),
      );
    } catch (_) {
      try {
        await raw?.close();
      } catch (_) {}
      return null;
    }
  }

  static Future<List<int>?> _sniRequest(
    Socket secure,
    String host,
    String pathAndQuery, {
    required int maxBytes,
  }) async {
    secure.write(
      'GET $pathAndQuery HTTP/1.1\r\n'
      'Host: $host\r\n'
      'User-Agent: $_userAgent\r\n'
      'Accept: */*\r\n'
      'Connection: close\r\n\r\n',
    );
    final bytes = <int>[];
    await for (final chunk in secure.timeout(const Duration(seconds: 30))) {
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) break;
    }
    final parsed = _parseHttpBytes(bytes);
    if (parsed == null) return null;
    // 200 取内容；401/403 等鉴权问题返回 null（停止轮询）
    return parsed.status == 200 ? parsed.body : null;
  }

  /// 解析手写的 HTTP 响应：返回状态码与（chunked 解码后的）原始正文。
  static ({int status, List<int> body})? _parseHttpBytes(List<int> bytes) {
    final headerEnd = _findHeaderEnd(bytes);
    if (headerEnd < 0) return null;
    final headerText = latin1.decode(bytes.sublist(0, headerEnd));
    final headers = headerText.toLowerCase();
    final statusLine = headers.split('\r\n').first;
    final match = RegExp(r'http/1\.[01]\s+(\d{3})').firstMatch(statusLine);
    if (match == null) return null;
    final status = int.tryParse(match.group(1)!) ?? 0;
    final bodyBytes = bytes.sublist(headerEnd + 4);
    final body = headers.contains('transfer-encoding: chunked')
        ? _decodeChunkedBytes(bodyBytes)
        : bodyBytes;
    return (status: status, body: body);
  }

  static int _findHeaderEnd(List<int> bytes) {
    for (var i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  static List<int> _decodeChunkedBytes(List<int> bytes) {
    final buffer = <int>[];
    var offset = 0;
    while (offset < bytes.length) {
      var lineEnd = -1;
      for (var i = offset; i + 1 < bytes.length; i++) {
        if (bytes[i] == 13 && bytes[i + 1] == 10) {
          lineEnd = i;
          break;
        }
      }
      if (lineEnd < 0) break;
      final sizeText = latin1.decode(bytes.sublist(offset, lineEnd)).trim();
      final size = int.tryParse(sizeText.split(';').first, radix: 16);
      if (size == null || size <= 0) break;
      final start = lineEnd + 2;
      final end = (start + size).clamp(0, bytes.length);
      buffer.addAll(bytes.sublist(start, end));
      offset = end + 2;
    }
    return buffer;
  }

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
    // 圆括号内容剥掉（(1994)/(加长版) 等），年份由独立 token 识别
    text = text.replaceAll(RegExp(r'[（(][^）)]*[）)]'), ' ');

    final tokens = text
        .split(RegExp(r'[.\s_]+'))
        .map((token) => token.trim())
        .where((token) => token.isNotEmpty)
        .toList();

    const junkPattern =
        r'^(1080p|720p|2160p|4k|8k|x264|x265|h264|h265|hevc|avc|aac|ac3|eac3|dts|flac|truehd|bluray|blu-ray|bdrip|webrip|web-dl|webdl|hdtv|remux|hdr10?|dv|dolby|atmos|10bit|8bit|proper|repack|extended|uncut|cr|ubweb|nf|amzn|dsnp|hmax|atvp|max|sdr|hevc10|60fps|120fps|60帧|120帧|高码|高bitrate|hq|web)$';
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
    // 剥离分类前缀（「动漫 启示录酒店…」→「启示录酒店…」）
    name = name.replaceAll(RegExp(r'^(动漫|动画|综艺|电影|电视剧|剧集)[\s：:－-]*'), '');
    // 剥离末尾的季/年份标记：幸福伽菜子的快乐杀手生活S1（2025）→ 幸福伽菜子的快乐杀手生活
    name = name
        .replaceAll(RegExp(r'[（(]\s*(19|20)\d{2}\s*[)）]\s*$'), '')
        .replaceAll(RegExp(r'\s*[sS](?:eason)?\s*\d{1,2}\s*$'), '')
        .replaceAll(RegExp(r'\s*第\s*[0-9一二三四五六七八九十]+\s*季\s*$'), '')
        .trim();

    final queries = <String>[if (name.isNotEmpty) name, ...bracketNames];
    // 通用规则：标题尾部的 1~2 位纯数字多为季号（唐朝诡事录1/魔幻手机2），
    // 生成一个剥掉后的变体用于搜索——命中率高且无需逐部写别名
    final tail = RegExp(r'^(.*[^0-9])(\d{1,2})$').firstMatch(name);
    if (tail != null) {
      final stripped = tail.group(1)!.trim();
      if (stripped.length >= 2 && !queries.contains(stripped)) {
        queries.add(stripped);
      }
    }
    return (queries: queries, year: year);
  }

  /// TMDB 搜索（需 API Key；网络不通时自动回退 TVmaze）。
  ///
  /// 中文片名、电影、剧集全覆盖，海报质量最好。
  /// 手动匹配：返回多个候选供用户挑选。
  ///
  /// 剧集条目默认优先展示 tv，电影优先 movie，但两类都会返回。
  static Future<List<ScrapeCandidate>> searchCandidates(
    String query, {
    int? year,
    bool preferTv = false,
  }) async {
    final key = tmdbApiKey?.trim();
    if (key == null || key.isEmpty || query.trim().isEmpty) return const [];
    final pathAndQuery =
        '/3/search/multi'
        '?api_key=$key&language=zh-CN&include_adult=false'
        '&query=${Uri.encodeQueryComponent(query)}';
    try {
      await _throttle();
      final body = await _tmdbGet(pathAndQuery);
      if (body == null) return const [];
      final data = jsonDecode(body) as Map<String, Object?>;
      final results = data['results'] as List<Object?>? ?? const [];
      final candidates = <ScrapeCandidate>[];
      for (final item in results) {
        final map = item as Map<String, Object?>;
        final mediaType = map['media_type'] as String? ?? '';
        if (mediaType != 'movie' && mediaType != 'tv') continue;
        final title =
            (map['title'] as String?) ?? (map['name'] as String?) ?? '';
        if (title.isEmpty) continue;
        final date =
            (map['release_date'] as String?) ??
            (map['first_air_date'] as String?) ??
            '';
        final posterPath = map['poster_path'] as String?;
        final vote = (map['vote_average'] as num?)?.toDouble();
        candidates.add(
          ScrapeCandidate(
            name: title,
            mediaType: mediaType,
            originalName:
                (map['original_title'] as String?) ??
                (map['original_name'] as String?),
            year: int.tryParse(date.split('-').first),
            posterUrl: posterPath == null
                ? null
                : 'https://image.tmdb.org/t/p/w200$posterPath',
            overview: (map['overview'] as String?)?.trim(),
            rating: vote == null || vote <= 0 ? null : vote.toStringAsFixed(1),
          ),
        );
      }
      // 类型优先排序，同年份优先
      candidates.sort((a, b) {
        final aType = preferTv
            ? (a.mediaType == 'tv' ? 0 : 1)
            : (a.mediaType == 'movie' ? 0 : 1);
        final bType = preferTv
            ? (b.mediaType == 'tv' ? 0 : 1)
            : (b.mediaType == 'movie' ? 0 : 1);
        if (aType != bType) return aType - bType;
        if (year != null) {
          final aGap = (a.year ?? 0) == year ? 0 : 1;
          final bGap = (b.year ?? 0) == year ? 0 : 1;
          if (aGap != bGap) return aGap - bGap;
        }
        return 0;
      });
      return candidates.take(18).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<ScrapeResult?> searchTmdb(
    String query, {
    int? year,
    bool preferTv = false,
  }) async {
    final key = tmdbApiKey?.trim();
    if (key == null || key.isEmpty || query.trim().isEmpty) return null;
    final pathAndQuery =
        '/3/search/multi'
        '?api_key=$key&language=zh-CN&include_adult=false'
        '&query=${Uri.encodeQueryComponent(query)}';
    try {
      await _throttle();
      final body = await _tmdbGet(pathAndQuery);
      if (body == null) return null;
      final data = jsonDecode(body) as Map<String, Object?>;
      final results = data['results'] as List<Object?>?;
      if (results == null || results.isEmpty) return null;

      Map<String, Object?>? best;
      var bestScore = 0.0;
      for (final item in results) {
        final map = item as Map<String, Object?>;
        final mediaType = map['media_type'] as String? ?? '';
        if (mediaType != 'movie' && mediaType != 'tv') continue;
        final name =
            (map['title'] as String?) ?? (map['name'] as String?) ?? '';
        // 原名（英文/日文）也参与比较，避免中文译名差异导致漏配
        final originalName =
            (map['original_title'] as String?) ??
            (map['original_name'] as String?) ??
            '';
        final date =
            (map['release_date'] as String?) ??
            (map['first_air_date'] as String?) ??
            '';
        final itemYear = int.tryParse(date.split('-').first);
        var score = _similarity(query, name);
        final originalScore = _similarity(query, originalName);
        if (originalScore > score) score = originalScore;
        // 类型匹配加权：剧集优先匹配 tv，电影优先匹配 movie，
        // 避免《想见你》《信号》这类同名电影/剧集张冠李戴。
        if (preferTv && mediaType == 'tv') score += 0.35;
        if (!preferTv && mediaType == 'movie') score += 0.3;
        if (itemYear != null && year != null) {
          final gap = (year - itemYear).abs();
          if (gap == 0) score += 0.3;
          if (gap > 2) score -= 0.35;
        }
        if (map['poster_path'] == null) score -= 0.1;
        if (score > bestScore) {
          bestScore = score;
          best = map;
        }
      }
      if (best == null || bestScore < 0.35) return null;

      final posterPath = best['poster_path'] as String?;
      final overview = (best['overview'] as String? ?? '').trim();
      final vote = (best['vote_average'] as num?)?.toDouble();
      final title =
          (best['title'] as String?) ?? (best['name'] as String?) ?? query;
      final date =
          (best['release_date'] as String?) ??
          (best['first_air_date'] as String?) ??
          '';
      return ScrapeResult(
        name: title,
        posterUrl: posterPath == null
            ? null
            : 'https://image.tmdb.org/t/p/w500$posterPath',
        summary: overview.isEmpty ? null : overview,
        rating: vote == null || vote <= 0 ? null : vote.toStringAsFixed(1),
        year: int.tryParse(date.split('-').first),
        mediaType: (best['media_type'] as String?) ?? 'movie',
        tmdbId: (best['id'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  /// 读取 TMDB 详情：背景图、类型、演员、时长与日期。
  /// credits 一次请求带回，避免为每个条目发两次。
  static Future<ScrapeResult?> fetchTmdbDetails({
    required String mediaType,
    required int id,
  }) async {
    final key = tmdbApiKey?.trim();
    if (key == null || key.isEmpty) return null;
    final type = mediaType == 'tv' ? 'tv' : 'movie';
    final pathAndQuery =
        '/3/$type/$id'
        '?api_key=$key&language=zh-CN&append_to_response=credits';
    try {
      await _throttle();
      final body = await _tmdbGet(pathAndQuery);
      if (body == null) return null;
      final map = jsonDecode(body) as Map<String, Object?>;
      final genres = (map['genres'] as List<Object?>? ?? const [])
          .map((item) {
            if (item is! Map<String, Object?>) return '';
            return item['name'] as String? ?? '';
          })
          .where((name) => name.isNotEmpty)
          .take(4)
          .toList();
      final runtimeMinutes =
          (map['runtime'] as num?)?.toDouble() ??
          ((map['episode_run_time'] as List<Object?>?)?.firstOrNull as num?)
              ?.toDouble();
      final crew =
          (map['credits'] as Map<String, Object?>?)?['crew']
              as List<Object?>? ??
          const [];
      final cast =
          (map['credits'] as Map<String, Object?>?)?['cast']
              as List<Object?>? ??
          const [];
      final members = <CastMember>[];
      for (final item in crew.take(3)) {
        final map = item as Map<String, Object?>;
        if (map['job'] != 'Director') continue;
        final name = map['name'] as String? ?? '';
        if (name.isEmpty) continue;
        members.add(CastMember(name: name, role: '导演'));
      }
      for (final item in cast) {
        final map = item as Map<String, Object?>;
        final name = map['name'] as String? ?? '';
        if (name.isEmpty) continue;
        final profilePath = map['profile_path'] as String?;
        members.add(
          CastMember(
            name: name,
            role: map['character'] as String? ?? '',
            photoUrl: profilePath == null
                ? null
                : 'https://image.tmdb.org/t/p/w185$profilePath',
          ),
        );
        if (members.length >= 12) break;
      }
      final posterPath = map['poster_path'] as String?;
      final backdropPath = map['backdrop_path'] as String?;
      final vote = (map['vote_average'] as num?)?.toDouble();
      return ScrapeResult(
        name: (map['title'] as String?) ?? (map['name'] as String?) ?? '',
        posterUrl: posterPath == null
            ? null
            : 'https://image.tmdb.org/t/p/w500$posterPath',
        summary: (map['overview'] as String? ?? '').trim(),
        rating: vote == null || vote <= 0 ? null : vote.toStringAsFixed(1),
        backdropUrl: backdropPath == null
            ? null
            : 'https://image.tmdb.org/t/p/w1280$backdropPath',
        genres: genres,
        cast: members,
        releaseDate:
            (map['release_date'] as String?) ??
            (map['first_air_date'] as String?),
        runtimeSec: runtimeMinutes == null ? null : runtimeMinutes * 60,
        mediaType: type,
        tmdbId: id,
      );
    } catch (_) {
      return null;
    }
  }

  /// 读取一季的单集信息：缩略图 URL 与标题。
  static Future<Map<int, ({String? title, String? stillUrl})>>
  fetchEpisodeStills({required int tvId, required int seasonNumber}) async {
    final key = tmdbApiKey?.trim();
    if (key == null || key.isEmpty) return const {};
    final pathAndQuery =
        '/3/tv/$tvId/season/$seasonNumber'
        '?api_key=$key&language=zh-CN';
    try {
      await _throttle();
      final body = await _tmdbGet(pathAndQuery);
      if (body == null) return const {};
      final data = jsonDecode(body) as Map<String, Object?>;
      final episodes = data['episodes'] as List<Object?>? ?? const [];
      final result = <int, ({String? title, String? stillUrl})>{};
      for (final item in episodes) {
        if (item is! Map<String, Object?>) continue;
        final episodeNumber = (item['episode_number'] as num?)?.toInt();
        if (episodeNumber == null) continue;
        final stillPath = item['still_path'] as String?;
        result[episodeNumber] = (
          title: (item['name'] as String?)?.trim(),
          stillUrl: stillPath == null
              ? null
              : 'https://image.tmdb.org/t/p/w500$stillPath',
        );
      }
      return result;
    } catch (_) {
      return const {};
    }
  }

  /// 拉取某一季的详情：季海报、季简介、首播日期与单集平均时长。
  static Future<
    ({
      String? posterUrl,
      String? overview,
      String? airDate,
      double? runtimeSec,
    })?
  >
  fetchSeasonDetails({required int tvId, required int seasonNumber}) async {
    final key = tmdbApiKey?.trim();
    if (key == null || key.isEmpty) return null;
    final pathAndQuery =
        '/3/tv/$tvId/season/$seasonNumber'
        '?api_key=$key&language=zh-CN';
    try {
      await _throttle();
      final body = await _tmdbGet(pathAndQuery);
      if (body == null) return null;
      final data = jsonDecode(body) as Map<String, Object?>;
      final posterPath = data['poster_path'] as String?;
      final overview = (data['overview'] as String?)?.trim();
      final airDate = (data['air_date'] as String?)?.trim();
      final episodes = (data['episodes'] as List<Object?>? ?? const [])
          .whereType<Map<String, Object?>>()
          .toList();
      final runtimes = episodes
          .map((episode) => (episode['runtime'] as num?)?.toDouble() ?? 0)
          .where((runtime) => runtime > 0)
          .toList();
      final averageRuntime = runtimes.isEmpty
          ? null
          : runtimes.reduce((a, b) => a + b) / runtimes.length;
      return (
        posterUrl: posterPath == null
            ? null
            : 'https://image.tmdb.org/t/p/w500$posterPath',
        overview: (overview == null || overview.isEmpty) ? null : overview,
        airDate: (airDate == null || airDate.isEmpty) ? null : airDate,
        runtimeSec: averageRuntime == null ? null : averageRuntime * 60,
      );
    } catch (_) {
      return null;
    }
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
      return bestScore >= 0.35 ? best : null;
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

    final proxyConfigured = (proxyAddress ?? '').trim().isNotEmpty;
    // 未配刮削代理时，image.tmdb.org 直连被墙，HttpClient 必然失败——
    // 直接走 SNI 免代理通道（与 API 同一套 CloudFront 边缘 IP）。
    if (!proxyConfigured && url.contains('image.tmdb.org')) {
      final uri = Uri.parse(url);
      try {
        await _throttle();
        final bytes = await _sniGetBytes(
          uri.host,
          '${uri.path}${uri.query.isEmpty ? '' : '?${uri.query}'}',
        );
        if (bytes == null || bytes.length < 1024) {
          onLog?.call('  下载图片失败 $cacheKey: SNI 直连无可用节点');
          return null;
        }
        if (!dir.existsSync()) dir.createSync(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        return file.path;
      } catch (error) {
        if (file.existsSync()) file.deleteSync();
        onLog?.call('  下载图片失败 $cacheKey: $error');
        return null;
      }
    }

    final client = _httpClient();
    try {
      // 网络抖动容错：失败自动重试一次（image.tmdb.org 国内直连
      // 常见间歇性失败，重试能救回相当一部分）。
      for (var attempt = 1; attempt <= 2; attempt++) {
        await _throttle();
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close().timeout(
          const Duration(seconds: 20),
        );
        if (response.statusCode != 200) {
          onLog?.call('  下载图片失败 $cacheKey: HTTP ${response.statusCode}');
          continue;
        }
        if (!dir.existsSync()) dir.createSync(recursive: true);
        final sink = file.openWrite();
        await response.pipe(sink);
        if (file.lengthSync() < 1024) {
          file.deleteSync();
          onLog?.call('  下载图片失败 $cacheKey: 文件过小');
          continue;
        }
        return file.path;
      }
      return null;
    } catch (error) {
      if (file.existsSync()) file.deleteSync();
      onLog?.call('  下载图片失败 $cacheKey: $error');
      onLog?.call('  （未配置刮削代理时图片域名直连，国内网络下会失败——'
          '请到 设置→刮削 填写刮削代理）');
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
  ///
  /// 英文按词重叠，中文按字符集 Jaccard——
  /// 这样「末日酒店」与「末日后酒店」也能得到较高分。
  static double _similarity(String query, String name) {
    final a = _normalize(query);
    final b = _normalize(name);
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;
    // 连字符差异："three body" vs "threebody"
    final aCompact = a.replaceAll(' ', '');
    final bCompact = b.replaceAll(' ', '');
    if (aCompact == bCompact) return 0.95;
    if (b.contains(a) || a.contains(b)) return 0.85;

    final aWords = a.split(' ').where((w) => w.length > 1).toSet();
    final bWords = b.split(' ').where((w) => w.length > 1).toSet();
    var wordScore = 0.0;
    if (aWords.isNotEmpty && bWords.isNotEmpty) {
      wordScore = (aWords.intersection(bWords).length / aWords.length) * 0.75;
    }

    // 字符级相似度（主要惠及中文片名）
    final aChars = aCompact.split('').toSet();
    final bChars = bCompact.split('').toSet();
    var charScore = 0.0;
    if (aChars.isNotEmpty && bChars.isNotEmpty) {
      final union = aChars.union(bChars).length;
      if (union > 0) {
        charScore = (aChars.intersection(bChars).length / union) * 0.85;
      }
    }
    return wordScore > charScore ? wordScore : charScore;
  }

  static String _normalize(String raw) => raw
      .toLowerCase()
      .replaceAll(RegExp(r'[-_.]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
