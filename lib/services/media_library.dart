import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/media_source.dart';
import 'credential_store.dart';
import 'webdav_service.dart';

enum ScanStatus { idle, scanning, done, failed }

/// 媒体库全局状态：媒体源配置、扫描结果与分类视图。
class MediaLibrary extends ChangeNotifier {
  MediaLibrary({CredentialStore? store}) : _store = store ?? CredentialStore();

  static MediaLibrary? _instance;

  static MediaLibrary get instance => _instance ??= MediaLibrary();

  /// 测试用：替换全局实例，避免触达真实系统存储。
  @visibleForTesting
  static set instanceForTesting(MediaLibrary library) => _instance = library;

  final CredentialStore _store;

  final List<MediaSource> _sources = [];
  final Map<String, String> _passwords = {};
  final Map<String, List<ScannedVideo>> _videosBySource = {};
  final Map<String, String> _sourceErrors = {};

  ScanStatus scanStatus = ScanStatus.idle;
  String scanProgress = '';

  List<MediaSource> get sources => List.unmodifiable(_sources);

  MediaSource? sourceById(String id) {
    for (final source in _sources) {
      if (source.id == id) return source;
    }
    return null;
  }

  String? errorOf(String sourceId) => _sourceErrors[sourceId];

  bool hasPassword(String sourceId) => _passwords.containsKey(sourceId);

  String? passwordOf(String sourceId) => _passwords[sourceId];

  /// 按 sourceId + 路径精确查找原始扫描条目（用于从播放历史续播）。
  ScannedVideo? findVideo(String sourceId, String path) {
    for (final videos in _videosBySource.values) {
      for (final video in videos) {
        if (video.sourceId == sourceId && video.path == path) return video;
      }
    }
    return null;
  }

  /// 某分类的聚合条目（跨所有媒体源）。
  List<ScannedVideo> byKind(MediaKind kind) {
    final merged = <String, ScannedVideo>{};
    for (final videos in _videosBySource.values) {
      for (final video in videos) {
        if (video.kind != kind) continue;
        final key = '${video.sourceId}|${video.title.toLowerCase()}';
        final existing = merged[key];
        if (existing == null) {
          merged[key] = video;
        } else if (video.episodeCount > existing.episodeCount) {
          merged[key] = video;
        }
      }
    }
    final list = merged.values.toList()
      ..sort(
        (a, b) =>
            (b.modified ?? DateTime(0)).compareTo(a.modified ?? DateTime(0)),
      );
    return list;
  }

  int countByKind(MediaKind kind) => byKind(kind).length;

  /// 某聚合条目对应的单集文件列表（电影返回自身）。
  List<ScannedVideo> episodesOf(ScannedVideo video) {
    if (video.episodeCount <= 1) return [video];
    final parent = parentPathOf(video.path);
    final result = <ScannedVideo>[];
    for (final videos in _videosBySource.values) {
      for (final candidate in videos) {
        if (candidate.sourceId != video.sourceId) continue;
        if (candidate.kind != video.kind) continue;
        if (parentPathOf(candidate.path) != parent) continue;
        result.add(candidate);
      }
    }
    result.sort((a, b) => _naturalCompare(a.path, b.path));
    return result.isEmpty ? [video] : result;
  }

  /// 自然排序：让 第2集 排在 第10集 前面。
  static int _naturalCompare(String a, String b) {
    final numbers = RegExp(r'\d+');
    final aParts = a.split(numbers);
    final bParts = b.split(numbers);
    final aNums = numbers.allMatches(a).map((m) => int.parse(m.group(0)!));
    final bNums = numbers.allMatches(b).map((m) => int.parse(m.group(0)!));
    final aIter = aNums.iterator;
    final bIter = bNums.iterator;
    final length = aParts.length.clamp(0, bParts.length);
    for (var i = 0; i < length; i++) {
      final compare = aParts[i].compareTo(bParts[i]);
      if (compare != 0) return compare;
      final aHas = aIter.moveNext();
      final bHas = bIter.moveNext();
      if (aHas && bHas) {
        final numCompare = aIter.current.compareTo(bIter.current);
        if (numCompare != 0) return numCompare;
      }
    }
    return a.compareTo(b);
  }

  bool get hasAnyContent =>
      _videosBySource.values.any((videos) => videos.isNotEmpty);

  /// 启动时恢复配置与凭据。
  Future<void> load() async {
    final raw = await _store.readSources();
    if (raw == null || raw.isEmpty) return;
    try {
      final list = (jsonDecode(raw) as List<Object?>)
          .map((item) => MediaSource.fromJson(item! as Map<String, Object?>))
          .toList();
      _sources
        ..clear()
        ..addAll(list);
      for (final source in _sources) {
        final password = await _store.readPassword(source.id);
        if (password != null) _passwords[source.id] = password;
        final videosRaw = await _store.read('framelet.videos.${source.id}');
        if (videosRaw != null && videosRaw.isNotEmpty) {
          try {
            _videosBySource[source.id] =
                (jsonDecode(videosRaw) as List<Object?>)
                    .map(
                      (item) =>
                          ScannedVideo.fromJson(item! as Map<String, Object?>),
                    )
                    .toList();
          } catch (_) {
            // 扫描缓存损坏时留空，用户手动同步即可。
          }
        }
      }
      notifyListeners();
    } catch (_) {
      // 配置损坏时宁可重新添加，也不让应用崩溃。
    }
  }

  Future<void> _persistSources() async {
    final json = jsonEncode(_sources.map((source) => source.toJson()).toList());
    await _store.writeSources(json);
  }

  Future<void> _persistVideos(String sourceId) async {
    final videos = _videosBySource[sourceId];
    if (videos == null || videos.isEmpty) {
      await _store.delete('framelet.videos.$sourceId');
      return;
    }
    await _store.write(
      'framelet.videos.$sourceId',
      jsonEncode(videos.map((video) => video.toJson()).toList()),
    );
  }

  /// 新增或更新媒体源。password 为空表示沿用已保存的密码。
  Future<void> addOrUpdateSource(MediaSource source, {String? password}) async {
    final index = _sources.indexWhere((item) => item.id == source.id);
    if (index >= 0) {
      _sources[index] = source;
    } else {
      _sources.add(source);
    }
    if (password != null && password.isNotEmpty) {
      _passwords[source.id] = password;
      await _store.writePassword(source.id, password);
    }
    await _persistSources();
    notifyListeners();
  }

  Future<void> deleteSource(String id) async {
    _sources.removeWhere((source) => source.id == id);
    _videosBySource.remove(id);
    _sourceErrors.remove(id);
    _passwords.remove(id);
    await _store.deletePassword(id);
    await _store.delete('framelet.videos.$id');
    await _persistSources();
    notifyListeners();
  }

  /// 连接测试。返回 null 表示成功，否则为可读错误信息。
  Future<String?> testConnection(MediaSource source, String password) async {
    try {
      await WebDavService.testConnection(source, password);
      return null;
    } catch (error) {
      return describeError(error);
    }
  }

  /// 全量扫描一个媒体源。完成后视频按分类就位。
  Future<void> scan(String sourceId) async {
    final source = sourceById(sourceId);
    final password = _passwords[sourceId];
    if (source == null) return;
    if (password == null) {
      _sourceErrors[sourceId] = '未保存密码，请编辑媒体源后重新输入';
      scanStatus = ScanStatus.failed;
      notifyListeners();
      return;
    }

    scanStatus = ScanStatus.scanning;
    scanProgress = '正在连接 ${source.name}…';
    _sourceErrors.remove(sourceId);
    notifyListeners();

    try {
      final videos = await WebDavService.scan(
        source,
        password,
        onProgress: (message) {
          scanProgress = message;
          notifyListeners();
        },
      );
      _videosBySource[sourceId] = videos;
      final now = DateTime.now();
      final index = _sources.indexWhere((item) => item.id == sourceId);
      if (index >= 0) {
        _sources[index] = _sources[index].copyWith(
          connected: true,
          lastSync:
              '${now.hour.toString().padLeft(2, '0')}:'
              '${now.minute.toString().padLeft(2, '0')}',
        );
      }
      scanStatus = ScanStatus.done;
      scanProgress = '扫描完成，共发现 ${videos.length} 个视频';
      await _persistSources();
      await _persistVideos(sourceId);
    } catch (error) {
      _sourceErrors[sourceId] = describeError(error);
      final index = _sources.indexWhere((item) => item.id == sourceId);
      if (index >= 0) {
        _sources[index] = _sources[index].copyWith(connected: false);
      }
      scanStatus = ScanStatus.failed;
      scanProgress = '';
      await _persistSources();
    }
    notifyListeners();
  }

  /// 把底层错误翻译成人话。
  static String describeError(Object error) {
    final text = error.toString();
    if (text.contains('401') ||
        text.toLowerCase().contains('unauthorized') ||
        text.toLowerCase().contains('auth')) {
      return '用户名或密码不正确（服务器返回 401）';
    }
    if (text.contains('404')) return '目录不存在（服务器返回 404），请检查媒体目录';
    if (text.contains('Connection refused') || text.contains('connection')) {
      return '无法连接服务器，请检查地址与网络';
    }
    if (text.contains('timed out') || text.contains('Timeout')) {
      return '连接超时，服务器无响应';
    }
    return '连接失败：$text';
  }

  /// 把扫描出的文件聚合成展示条目：
  /// 剧集/动漫/综艺按父目录合并成一条并统计集数，电影按文件单列。
  static List<ScannedVideo> aggregate(List<ScannedVideo> videos) {
    final movies = <ScannedVideo>[];
    final grouped = <String, List<ScannedVideo>>{};

    for (final video in videos) {
      if (video.kind == MediaKind.movie) {
        movies.add(video);
        continue;
      }
      final parent = parentPathOf(video.path);
      grouped.putIfAbsent(parent, () => []).add(video);
    }

    final result = movies;
    for (final entry in grouped.entries) {
      final group = entry.value..sort((a, b) => a.path.compareTo(b.path));
      final folderName = _lastSegment(entry.key);
      final isSeriesFolder =
          group.length > 1 || _looksLikeEpisode(group.first.title);
      if (isSeriesFolder && folderName.isNotEmpty) {
        result.add(
          group.first.copyWith(
            title: WebDavService.cleanTitle(folderName),
            episodeCount: group.length,
          ),
        );
      } else {
        result.addAll(group);
      }
    }
    return result;
  }

  static String parentPathOf(String path) {
    final index = path.lastIndexOf('/');
    return index > 0 ? path.substring(0, index) : path;
  }

  static String _lastSegment(String path) {
    final clean = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final index = clean.lastIndexOf('/');
    var segment = index >= 0 ? clean.substring(index + 1) : clean;
    try {
      segment = Uri.decodeComponent(segment);
    } catch (_) {
      // 已是明文则直接使用
    }
    return segment;
  }

  static final _episodePattern = RegExp(
    r'[Ss]\d{1,2}[Ee]\d{1,2}|\bEP?\d{1,3}\b|第\s*\d+\s*[集期]',
  );

  static bool _looksLikeEpisode(String title) =>
      _episodePattern.hasMatch(title);
}
