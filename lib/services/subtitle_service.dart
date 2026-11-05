import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../models/media_source.dart';
import 'local_media_service.dart';
import 'webdav_service.dart';

class SubtitleFile {
  const SubtitleFile({
    required this.path,
    required this.title,
    this.language,
  });

  /// 媒体源内的原始路径；本地源为真实文件路径。
  final String path;
  final String title;
  final String? language;

  String get extension {
    final dot = path.lastIndexOf('.');
    return dot >= 0 ? path.substring(dot).toLowerCase() : '.srt';
  }
}

/// 外挂字幕发现与读取。
///
/// 本地文件直接交给 media_kit；WebDAV 字幕先带认证下载到临时目录，
/// 因为 mpv 的 `sub-add` 不会复用播放视频时附带的 Basic Auth 头。
class SubtitleService {
  SubtitleService._();

  static Future<List<SubtitleFile>> discover(
    MediaSource source,
    String videoPath,
    String password,
  ) async {
    if (source.isLocal) {
      return _discoverLocal(videoPath);
    }
    final paths = await WebDavService.discoverSubtitles(
      source,
      password,
      videoPath,
    );
    return [for (final path in paths) _fromPath(path)];
  }

  static SubtitleFile fromLocalFile(String path) =>
      _fromPath(LocalMediaService.normalizePath(path));

  static Future<String?> materialize({
    required SubtitleFile subtitle,
    required MediaSource source,
    required String password,
  }) async {
    if (source.isLocal) {
      return File(subtitle.path).existsSync() ? subtitle.path : null;
    }
    final directory = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}framelet_subtitles',
    );
    await directory.create(recursive: true);
    final key = sha1.convert(utf8.encode(subtitle.path)).toString();
    final file = File(
      '${directory.path}${Platform.pathSeparator}$key${subtitle.extension}',
    );
    if (await file.exists() && await file.length() > 16) return file.path;

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final target = await WebDavService.resolvePlayUrl(source, subtitle.path);
      final request = await client.getUrl(target.url);
      request.headers.set(
        HttpHeaders.authorizationHeader,
        WebDavService.authHeader(source.username, password),
      );
      if (target.hostHeader != null) {
        request.headers.set(HttpHeaders.hostHeader, target.hostHeader!);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200) return null;
      final sink = file.openWrite();
      await response.pipe(sink);
      if (await file.length() < 16) {
        await file.delete();
        return null;
      }
      return file.path;
    } catch (_) {
      if (await file.exists()) await file.delete();
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<List<SubtitleFile>> _discoverLocal(String videoPath) async {
    final video = File(videoPath);
    final parent = video.parent;
    if (!await parent.exists()) return const [];
    final videoStem = _stemOf(videoPath);
    final result = <SubtitleFile>[];
    await for (final entity in parent.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (!WebDavService.isSubtitleFile(name)) continue;
      final subtitleStem = _stemOf(entity.path);
      if (!_matches(videoStem, subtitleStem)) continue;
      result.add(_fromPath(LocalMediaService.normalizePath(entity.path)));
    }
    result.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    return result;
  }

  static SubtitleFile _fromPath(String path) {
    final name = path.split('/').last;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    return SubtitleFile(
      path: path,
      title: _displayTitle(stem),
      language: _languageOf(stem),
    );
  }

  static String _displayTitle(String stem) {
    final lower = stem.toLowerCase();
    final language = _languageOf(lower);
    if (language == null) return stem;
    final suffix = RegExp(
      r'[._\-\s]*(zh|zho|chi|chs|cht|sc|tc|cn|eng|en|jpn|ja|kor|ko)([._\-\s].*)?$',
      caseSensitive: false,
    );
    final cleaned = stem.replaceFirst(suffix, '').trim();
    return cleaned.isEmpty ? '$stem（$language）' : '$cleaned（$language）';
  }

  static String? _languageOf(String value) {
    final lower = value.toLowerCase();
    if (RegExp(r'(zh|zho|chi|chs|cht|sc|tc|cn|中文|简体|繁体)')
        .hasMatch(lower)) {
      return '中文';
    }
    if (RegExp(r'(eng|en|英文|英语)').hasMatch(lower)) return '英语';
    if (RegExp(r'(jpn|ja|日文|日语)').hasMatch(lower)) return '日语';
    if (RegExp(r'(kor|ko|韩文|韩语)').hasMatch(lower)) return '韩语';
    return null;
  }

  static String _stemOf(String path) {
    final normalized = path.replaceAll('\\', '/');
    final name = normalized.split('/').last;
    final dot = name.lastIndexOf('.');
    return (dot > 0 ? name.substring(0, dot) : name).toLowerCase();
  }

  static bool _matches(String videoStem, String subtitleStem) =>
      subtitleStem == videoStem ||
      subtitleStem.startsWith('$videoStem.') ||
      subtitleStem.startsWith('${videoStem}_') ||
      subtitleStem.startsWith('$videoStem-');
}
