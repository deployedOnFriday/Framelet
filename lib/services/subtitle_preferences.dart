import 'dart:convert';

import 'package:media_kit/media_kit.dart';

import '../models/media_source.dart';
import 'credential_store.dart';
import 'series_key.dart';
import 'subtitle_service.dart';

/// 用户上次在这部作品里选的字幕。
///
/// 内嵌轨在不同集里的 `id` 通常一致，但不能保证；所以除了 id 还记录
/// 语言与标题，恢复时按「id → 语言 → 标题」逐级兜底。外挂字幕同理，
/// 先按路径（同一集重开），再按标题/语言在当集发现的外挂字幕里找。
class SubtitleChoice {
  const SubtitleChoice._({
    required this.kind,
    this.trackId,
    this.language,
    this.title,
    this.path,
  });

  const SubtitleChoice.off() : this._(kind: 'off');

  const SubtitleChoice.auto() : this._(kind: 'auto');

  const SubtitleChoice.track({
    required String id,
    String? language,
    String? title,
  }) : this._(kind: 'track', trackId: id, language: language, title: title);

  const SubtitleChoice.external({
    required String path,
    String? language,
    String? title,
  }) : this._(kind: 'external', path: path, language: language, title: title);

  /// `off` / `auto` / `track` / `external`。
  final String kind;
  final String? trackId;
  final String? language;
  final String? title;
  final String? path;

  bool get isOff => kind == 'off';

  Map<String, Object?> toJson() => {
    'k': kind,
    if (trackId != null && trackId!.isNotEmpty) 'id': trackId,
    if (language != null && language!.isNotEmpty) 'lang': language,
    if (title != null && title!.trim().isNotEmpty) 'title': title!.trim(),
    if (path != null && path!.isNotEmpty) 'path': path,
  };

  static SubtitleChoice? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = raw['k'];
    if (kind is! String) return null;
    if (kind != 'off' &&
        kind != 'auto' &&
        kind != 'track' &&
        kind != 'external') {
      return null;
    }
    String? text(Object? value) {
      final result = value?.toString().trim() ?? '';
      return result.isEmpty ? null : result;
    }

    return SubtitleChoice._(
      kind: kind,
      trackId: text(raw['id']),
      language: text(raw['lang']),
      title: text(raw['title']),
      path: text(raw['path']),
    );
  }
}

/// 按「作品」记住字幕选择，切集 / 重新打开时自动套用。
class SubtitlePreferences {
  SubtitlePreferences._();

  static final SubtitlePreferences instance = SubtitlePreferences._();

  static const _storageKey = 'framelet.subtitle.prefs';

  /// 最多保留的作品数：按最近使用淘汰，避免无限增长。
  static const _maxEntries = 200;

  final CredentialStore _store = CredentialStore();

  /// 插入顺序即最近使用顺序（Map 字面量保持插入序）。
  Map<String, SubtitleChoice>? _cache;
  Future<Map<String, SubtitleChoice>>? _loading;

  /// 作品身份：优先 TMDB ID（同一部剧跨季/跨目录都稳定），
  /// 没有刮削结果时退回「媒体源 + 剧名」。
  static String keyOf(ScannedVideo video) => SeriesKey.of(video);

  Future<SubtitleChoice?> choiceFor(ScannedVideo video) async {
    final key = keyOf(video);
    if (key.isEmpty) return null;
    final data = await _ensureLoaded();
    final choice = data[key];
    if (choice == null) return null;
    // 命中即刷新 LRU 顺序（下次写回时生效）。
    data
      ..remove(key)
      ..[key] = choice;
    return choice;
  }

  Future<void> save(ScannedVideo video, SubtitleChoice choice) async {
    final key = keyOf(video);
    if (key.isEmpty) return;
    final data = await _ensureLoaded();
    data
      ..remove(key)
      ..[key] = choice;
    while (data.length > _maxEntries) {
      data.remove(data.keys.first);
    }
    await _persist(data);
  }

  /// 清掉这部剧的记忆（用户选「自动」时视为恢复默认）。
  Future<void> clear(ScannedVideo video) async {
    final key = keyOf(video);
    if (key.isEmpty) return;
    final data = await _ensureLoaded();
    if (data.remove(key) == null) return;
    await _persist(data);
  }

  Future<Map<String, SubtitleChoice>> _ensureLoaded() {
    final cached = _cache;
    if (cached != null) return Future.value(cached);
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<Map<String, SubtitleChoice>> _load() async {
    final data = <String, SubtitleChoice>{};
    try {
      final raw = await _store.read(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final choice = SubtitleChoice.fromJson(entry.value);
            if (choice != null) data[entry.key.toString()] = choice;
          }
        }
      }
    } catch (_) {
      // 存储损坏/无权限时按「没有记忆」处理，不影响播放。
    }
    return _cache = data;
  }

  Future<void> _persist(Map<String, SubtitleChoice> data) async {
    final encoded = jsonEncode({
      for (final entry in data.entries) entry.key: entry.value.toJson(),
    });
    try {
      await _store.write(_storageKey, encoded);
    } catch (_) {
      // 写失败只影响下次恢复，不该打断当前播放。
    }
  }
}

/// 把记忆里的选择映射到「这一集」的实际轨道 / 外挂文件。
///
/// 纯函数，便于单测：不涉及播放器与 IO。
class SubtitleChoiceResolver {
  SubtitleChoiceResolver._();

  /// 返回应选中的内嵌轨下标；`null` 表示没有可信对应项。
  static int? trackIndex(SubtitleChoice choice, List<SubtitleTrack> tracks) {
    if (choice.kind != 'track' || tracks.isEmpty) return null;
    final id = choice.trackId;
    if (id != null) {
      final index = tracks.indexWhere((track) => track.id == id);
      if (index >= 0) return index;
    }
    final language = choice.language;
    if (language != null) {
      final index = tracks.indexWhere(
        (track) => _sameLanguage(track.language, language),
      );
      if (index >= 0) return index;
    }
    final title = choice.title;
    if (title != null) {
      final index = tracks.indexWhere(
        (track) => _sameTitle(track.title, title),
      );
      if (index >= 0) return index;
    }
    return null;
  }

  /// 返回应加载的外挂字幕；没有可信对应项时为 `null`。
  static SubtitleFile? externalFile(
    SubtitleChoice choice,
    List<SubtitleFile> files,
  ) {
    if (choice.kind != 'external' || files.isEmpty) return null;
    final path = choice.path;
    if (path != null) {
      final same = files.where((file) => file.path == path);
      if (same.isNotEmpty) return same.first;
    }
    final title = choice.title;
    if (title != null) {
      final same = files.where((file) => _sameTitle(file.title, title));
      if (same.isNotEmpty) return same.first;
    }
    final language = choice.language;
    if (language != null) {
      final same = files.where(
        (file) => _sameLanguage(file.language, language),
      );
      if (same.isNotEmpty) return same.first;
    }
    return null;
  }

  static bool _sameLanguage(String? a, String b) {
    final left = (a ?? '').trim().toLowerCase();
    final right = b.trim().toLowerCase();
    return left.isNotEmpty && left == right;
  }

  static bool _sameTitle(String? a, String b) {
    String norm(String value) =>
        value.toLowerCase().replaceAll(RegExp(r'[\s._\-（）()]+'), '').trim();
    final left = norm(a ?? '');
    final right = norm(b);
    return left.isNotEmpty && left == right;
  }
}
