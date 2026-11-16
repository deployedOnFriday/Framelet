import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/media_source.dart';
import 'scraper_service.dart';

/// Jellyfin / Emby 媒体服务器直连。
///
/// 两者 API 兼容（Emby 是 Jellyfin 的上游），用同一套实现：
/// `POST /Users/AuthenticateByName` 登录拿 AccessToken，之后
/// `GET /Users/{id}/Items` 拉媒体库，播放走 `/Videos/{id}/stream`。
/// 媒体库条目直接继承服务端已整理好的元数据与海报，不再走本地刮削。
class JellyfinSession {
  const JellyfinSession({
    required this.baseUrl,
    required this.token,
    required this.userId,
    required this.serverName,
    required this.product,
  });

  final String baseUrl;
  final String token;
  final String userId;
  final String serverName;
  final String product;

  bool get isEmby => product.toLowerCase().contains('emby');
}

class JellyfinException implements Exception {
  const JellyfinException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Jellyfin 服务端的一条字幕轨。
class JellyfinSubtitle {
  const JellyfinSubtitle({
    required this.path,
    required this.title,
    this.language,
  });

  /// `jfsub://{itemId}/{mediaSourceId}/{index}.{format}`。
  final String path;
  final String title;
  final String? language;
}

class JellyfinService {
  JellyfinService._();

  static const _clientName = 'Framelet';
  static const _deviceName = 'Framelet Windows';
  static const _deviceId = 'framelet-windows';

  static final Map<String, JellyfinSession> _sessions = {};

  static String _authHeader() =>
      'MediaBrowser Client="$_clientName", Device="$_deviceName", '
      'DeviceId="$_deviceId", Version="0.1"';

  static String normalizeBaseUrl(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return value;
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'http://$value';
    }
    return value.replaceFirst(RegExp(r'/+$'), '');
  }

  static void clearSession([String? sourceId]) {
    if (sourceId == null) {
      _sessions.clear();
    } else {
      _sessions.remove(sourceId);
    }
  }

  /// 登录（成功后按媒体源缓存 token）。
  static Future<JellyfinSession> connect(
    MediaSource source,
    String password, {
    bool force = false,
  }) async {
    final cached = _sessions[source.id];
    if (cached != null && !force) return cached;
    final baseUrl = normalizeBaseUrl(source.address);
    if (baseUrl.isEmpty) {
      throw const JellyfinException('服务器地址不能为空');
    }
    final uri = Uri.parse('$baseUrl/Users/AuthenticateByName');
    final body = await _request(
      uri,
      method: 'POST',
      body: jsonEncode({'Username': source.username.trim(), 'Pw': password}),
      token: null,
    );
    final token = body['AccessToken'] as String?;
    final user = body['User'];
    final userId = user is Map ? user['Id'] as String? : null;
    if (token == null || token.isEmpty || userId == null || userId.isEmpty) {
      throw const JellyfinException('登录失败：服务器没有返回访问令牌');
    }
    final info = await _request(
      Uri.parse('$baseUrl/System/Info'),
      token: token,
    );
    final session = JellyfinSession(
      baseUrl: baseUrl,
      token: token,
      userId: userId,
      serverName: (info['ServerName'] as String?)?.trim() ?? '',
      product: (info['ProductName'] as String?)?.trim() ?? '',
    );
    _sessions[source.id] = session;
    return session;
  }

  static Future<void> testConnection(
    MediaSource source,
    String password,
  ) async {
    final session = await connect(source, password, force: true);
    if (session.userId.isEmpty) {
      throw const JellyfinException('登录成功但没有返回用户信息');
    }
  }

  static Future<ScanResult> scan(
    MediaSource source,
    String password, {
    void Function(String message)? onProgress,
  }) async {
    final session = await connect(source, password, force: true);
    onProgress?.call('已连接 ${session.serverName}，正在读取媒体库…');
    final items = await _fetchItems(session);
    onProgress?.call('读取到 ${items.length} 个条目，正在整理…');

    final videos = <ScannedVideo>[];
    for (final item in items) {
      final video = await videoFromItem(source, session, item);
      if (video != null) videos.add(video);
    }
    return ScanResult(videos: videos);
  }

  /// 播放地址：`jf://movie/{itemId}` 直取；剧集按集号回查服务器。
  static Future<({Uri url, String label})> playUrl(
    MediaSource source,
    String password,
    String path,
  ) async {
    final session = await connect(source, password);
    final itemId = await resolveItemId(session, path);
    if (itemId == null) {
      throw const JellyfinException('服务器上找不到这一集，请重新同步媒体源');
    }
    final url = Uri.parse(
      '${session.baseUrl}/Videos/$itemId/stream'
      '?static=true&api_key=${session.token}&MediaSourceId=$itemId',
    );
    return (url: url, label: itemId);
  }

  /// 从库内虚拟路径解析出服务器 itemId。
  static Future<String?> resolveItemId(
    JellyfinSession session,
    String path,
  ) async {
    final trimmed = path.trim();
    if (!trimmed.startsWith('jf://')) return null;
    final rest = trimmed.substring('jf://'.length);
    final parts = rest.split('/');
    if (parts.length < 2) return null;
    final kind = parts[0];
    final firstId = parts[1];
    if (kind == 'movie') return firstId;
    if (kind != 'show') return null;
    final coordinates = parseEpisodeName(parts.last);
    if (coordinates == null) return null;
    final body = await _request(
      Uri.parse(
        '${session.baseUrl}/Shows/$firstId/Episodes',
      ).replace(queryParameters: {'userId': session.userId, 'Fields': 'Path'}),
      token: session.token,
    );
    final items = body['Items'];
    if (items is! List) return null;
    for (final raw in items) {
      if (raw is! Map) continue;
      final s = raw['ParentIndexNumber'];
      final e = raw['IndexNumber'];
      if (s is! num || e is! num) continue;
      if (s.toInt() == coordinates.season && e.toInt() == coordinates.episode) {
        final id = raw['Id'];
        if (id is String && id.isNotEmpty) return id;
      }
    }
    return null;
  }

  /// 列出服务端字幕轨（内嵌与外挂都包含）。
  static Future<List<JellyfinSubtitle>> listSubtitles(
    MediaSource source,
    String password,
    String videoPath,
  ) async {
    final session = await connect(source, password);
    final itemId = await resolveItemId(session, videoPath);
    if (itemId == null) return const [];
    final body = await _request(
      Uri.parse('${session.baseUrl}/Users/${session.userId}/Items/$itemId')
          .replace(queryParameters: {'Fields': 'MediaSources,MediaStreams'}),
      token: session.token,
    );
    final sources = body['MediaSources'];
    var mediaSourceId = itemId;
    List<Map<Object?, Object?>> streams = const [];
    if (sources is List && sources.isNotEmpty && sources.first is Map) {
      final first = sources.first as Map;
      final id = (first['Id'] as String?)?.trim() ?? '';
      if (id.isNotEmpty) mediaSourceId = id;
      final rawStreams = first['MediaStreams'];
      if (rawStreams is List) {
        streams = rawStreams.whereType<Map>().toList();
      }
    }
    if (streams.isEmpty) {
      final rawStreams = body['MediaStreams'];
      if (rawStreams is List) {
        streams = rawStreams.whereType<Map>().toList();
      }
    }

    final result = <JellyfinSubtitle>[];
    for (final stream in streams) {
      if (stream['Type'] != 'Subtitle') continue;
      // 内嵌字幕由 mpv 直接从视频流里读取，只补服务端外挂字幕。
      if (stream['IsExternal'] != true) continue;
      final index = stream['Index'];
      if (index is! num) continue;
      final codec = (stream['Codec'] as String?)?.trim().toLowerCase() ?? '';
      final format = switch (codec) {
        'subrip' || 'srt' => 'srt',
        'ass' => 'ass',
        'ssa' => 'ssa',
        'webvtt' || 'vtt' => 'vtt',
        'hdmv_pgs_subtitle' => 'sup',
        'dvd_subtitle' => 'sub',
        _ => 'srt',
      };
      final display = (stream['DisplayTitle'] as String?)?.trim() ?? '';
      final language = _subtitleLanguage(stream['Language'] as String?);
      final forced = stream['IsForced'] == true;
      final title = display.isNotEmpty
          ? (forced ? '$display（强制）' : display)
          : '字幕 ${result.length + 1}${forced ? '（强制）' : ''}';
      result.add(
        JellyfinSubtitle(
          path: 'jfsub://$itemId/$mediaSourceId/${index.toInt()}.$format',
          title: title,
          language: language,
        ),
      );
    }
    return result;
  }

  static String? _subtitleLanguage(String? code) {
    final value = (code ?? '').trim().toLowerCase();
    if (value.isEmpty) return null;
    if (value == 'chi' ||
        value == 'zho' ||
        value == 'zh' ||
        value.startsWith('zh-')) {
      return '中文';
    }
    if (value == 'eng' || value == 'en' || value.startsWith('en-')) {
      return '英语';
    }
    if (value == 'jpn' || value == 'ja' || value.startsWith('ja-')) {
      return '日语';
    }
    if (value == 'kor' || value == 'ko' || value.startsWith('ko-')) {
      return '韩语';
    }
    return value;
  }

  /// 从 `剧名 S01E02.mkv` 里解析季/集号。
  static ({int season, int episode})? parseEpisodeName(String name) {
    final match = RegExp(r'[sS](\d{1,2})[eE](\d{1,3})').firstMatch(name);
    if (match == null) return null;
    final season = int.tryParse(match.group(1)!);
    final episode = int.tryParse(match.group(2)!);
    if (season == null || episode == null) return null;
    return (season: season, episode: episode);
  }

  static Future<List<Map<String, Object?>>> _fetchItems(
    JellyfinSession session,
  ) async {
    const fields = <String>[
      'Path',
      'Overview',
      'ProductionYear',
      'PremiereDate',
      'RunTimeTicks',
      'CommunityRating',
      'ProviderIds',
      'Genres',
      'MediaSources',
      'SeriesId',
      'SeriesName',
      'SeriesPrimaryImageTag',
      'ParentIndexNumber',
      'IndexNumber',
      'ImageTags',
      'BackdropImageTags',
    ];
    final result = <Map<String, Object?>>[];
    var startIndex = 0;
    const pageSize = 500;
    while (true) {
      final uri = Uri.parse('${session.baseUrl}/Users/${session.userId}/Items')
          .replace(
            queryParameters: {
              'Recursive': 'true',
              'IncludeItemTypes': 'Movie,Episode',
              'Fields': fields.join(','),
              'EnableImages': 'true',
              'ImageTypeLimit': '1',
              'EnableImageTypes': 'Primary,Backdrop',
              'EnableTotalRecordCount': 'false',
              'StartIndex': '$startIndex',
              'Limit': '$pageSize',
              'api_key': session.token,
            },
          );
      final body = await _request(uri, token: session.token);
      final items = body['Items'];
      if (items is! List || items.isEmpty) break;
      for (final item in items) {
        if (item is Map) {
          result.add(item.cast<String, Object?>());
        }
      }
      if (items.length < pageSize) break;
      startIndex += items.length;
    }
    return result;
  }

  static Future<ScannedVideo?> videoFromItem(
    MediaSource source,
    JellyfinSession session,
    Map<String, Object?> item, {
    bool downloadImages = true,
  }) async {
    final id = (item['Id'] as String?)?.trim() ?? '';
    if (id.isEmpty) return null;
    final type = (item['Type'] as String?) ?? '';
    final name = ((item['Name'] as String?) ?? '').trim();
    if (name.isEmpty) return null;
    final isEpisode = type == 'Episode';
    final seriesId = (item['SeriesId'] as String?)?.trim() ?? '';
    final seriesName = ((item['SeriesName'] as String?) ?? '').trim();
    if (isEpisode && (seriesId.isEmpty || seriesName.isEmpty)) return null;

    final season = (item['ParentIndexNumber'] as num?)?.toInt() ?? 1;
    final episode = (item['IndexNumber'] as num?)?.toInt() ?? 1;
    final extension = _extensionOf(item);
    final displayName = isEpisode
        ? '$seriesName S${_two(season)}E${_two(episode)}'
        : name;
    final safeName = _sanitize(displayName);
    final path = isEpisode
        ? 'jf://show/$seriesId/${_sanitize(seriesName)}/$safeName.$extension'
        : 'jf://movie/$id/$safeName/$safeName.$extension';

    final genres = (item['Genres'] as List<Object?>? ?? const [])
        .whereType<String>()
        .toList();
    final kind = _kindOf(isEpisode, genres);
    final runtimeTicks = item['RunTimeTicks'];
    final runtimeSec = runtimeTicks is num
        ? runtimeTicks.toDouble() / 10000000
        : null;
    final providerIds = item['ProviderIds'];
    final tmdbId = providerIds is Map
        ? int.tryParse('${providerIds['Tmdb'] ?? ''}')
        : null;

    final posterItemId = isEpisode ? seriesId : id;
    final posterTag = isEpisode
        ? item['SeriesPrimaryImageTag'] as String?
        : (item['ImageTags'] is Map
              ? (item['ImageTags'] as Map)['Primary'] as String?
              : null);
    final posterUrl = posterTag == null
        ? null
        : '${session.baseUrl}/Items/$posterItemId/Images/Primary'
              '?maxHeight=600&quality=88&api_key=${session.token}';
    final episodeThumbUrl = isEpisode
        ? '${session.baseUrl}/Items/$id/Images/Primary'
              '?maxHeight=360&quality=85&api_key=${session.token}'
        : null;

    final posterPath = !downloadImages || posterUrl == null
        ? null
        : await ScraperService.downloadPoster(
            posterUrl,
            cacheKey: 'jf-poster-$posterItemId',
          );
    final stillPath = !downloadImages || episodeThumbUrl == null
        ? null
        : await ScraperService.downloadPoster(
            episodeThumbUrl,
            cacheKey: 'jf-still-$id',
          );

    return ScannedVideo(
      sourceId: source.id,
      path: path,
      title: displayName,
      kind: kind,
      sizeBytes: _sizeOf(item),
      posterPath: posterPath,
      stillPath: stillPath,
      modified: DateTime.tryParse((item['PremiereDate'] as String?) ?? ''),
      summary: (item['Overview'] as String?)?.trim(),
      rating: item['CommunityRating'] is num
          ? (item['CommunityRating'] as num).toStringAsFixed(1)
          : null,
      genres: genres,
      releaseDate: (item['PremiereDate'] as String?)?.split('T').first,
      runtimeSec: runtimeSec,
      episodeTitle: isEpisode ? name : null,
      tmdbId: tmdbId,
      tmdbTitle: isEpisode ? seriesName : name,
    );
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  static MediaKind _kindOf(bool isEpisode, List<String> genres) {
    final joined = genres.join(' ');
    final anime =
        joined.contains('动画') || joined.toLowerCase().contains('animation');
    if (anime) return MediaKind.anime;
    return isEpisode ? MediaKind.series : MediaKind.movie;
  }

  static String _extensionOf(Map<String, Object?> item) {
    final sources = item['MediaSources'];
    if (sources is List && sources.isNotEmpty && sources.first is Map) {
      final first = sources.first as Map;
      final container = first['Container'];
      if (container is String && container.trim().isNotEmpty) {
        return container.trim().toLowerCase();
      }
      final path = first['Path'];
      if (path is String) {
        final index = path.lastIndexOf('.');
        if (index > 0 && index < path.length - 1) {
          return path.substring(index + 1).toLowerCase();
        }
      }
    }
    final path = item['Path'];
    if (path is String) {
      final index = path.lastIndexOf('.');
      if (index > 0 && index < path.length - 1) {
        return path.substring(index + 1).toLowerCase();
      }
    }
    return 'mkv';
  }

  static String _sanitize(String raw) =>
      raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim();

  static int _sizeOf(Map<String, Object?> item) {
    final sources = item['MediaSources'];
    if (sources is List && sources.isNotEmpty && sources.first is Map) {
      final size = (sources.first as Map)['Size'];
      if (size is num) return size.toInt();
    }
    final size = item['Size'];
    return size is num ? size.toInt() : 0;
  }

  static Future<Map<String, Object?>> _request(
    Uri uri, {
    String? token,
    String method = 'GET',
    String? body,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..userAgent = 'Framelet/0.1';
    try {
      final request = await client
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 12));
      request.headers.set('Authorization', _authHeader());
      if (token != null) request.headers.set('X-Emby-Token', token);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(body);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 30));
      if (response.statusCode == 401) {
        throw const JellyfinException('账号或密码不正确');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw JellyfinException(
          '服务器返回 HTTP ${response.statusCode}'
          '${text.trim().isEmpty ? '' : '：${text.trim().substring(0, text.trim().length.clamp(0, 120))}'}',
        );
      }
      final decoded = text.trim().isEmpty ? null : jsonDecode(text);
      if (decoded is Map) return decoded.cast<String, Object?>();
      return <String, Object?>{};
    } on SocketException catch (error) {
      throw JellyfinException('连不上服务器：${error.message}');
    } finally {
      client.close(force: true);
    }
  }
}
