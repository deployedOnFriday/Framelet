import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/history_entry.dart';
import 'credential_store.dart';
import 'framelet_store.dart';

export '../models/history_entry.dart';

/// 播放历史：内存缓存 + 安全存储持久化，最近 50 条。
class PlaybackHistory extends ChangeNotifier {
  PlaybackHistory._({FrameletStore? db, CredentialStore? store})
    : _db = db ?? FrameletStore.instance,
      _store = store ?? CredentialStore();

  static PlaybackHistory instance = PlaybackHistory._();

  @visibleForTesting
  factory PlaybackHistory.withStore(
    FrameletStore db, {
    CredentialStore? store,
  }) => PlaybackHistory._(db: db, store: store);

  @visibleForTesting
  static set instanceForTesting(PlaybackHistory history) =>
      instance = history;

  static const _key = 'framelet.history';
  static const _maxEntries = 50;

  final CredentialStore _store;
  final FrameletStore _db;
  final List<HistoryEntry> _entries = [];

  List<HistoryEntry> get entries => List.unmodifiable(_entries);

  HistoryEntry? entryOf(String sourceId, String path) {
    for (final entry in _entries) {
      if (entry.sourceId == sourceId && entry.path == path) return entry;
    }
    return null;
  }

  Future<void> load() async {
    await _db.open();
    try {
      _entries
        ..clear()
        ..addAll(await _db.loadHistory());
      if (_entries.isEmpty) {
        final raw = await _store.read(_key);
        if (raw != null && raw.isNotEmpty) {
          final list = (jsonDecode(raw) as List<Object?>)
              .map(
                (item) => HistoryEntry.fromJson(item! as Map<String, Object?>),
              )
              .toList();
          _entries.addAll(list);
          await _db.saveHistory(_entries);
          await _store.delete(_key);
        }
      }
      notifyListeners();
    } catch (_) {
      // 历史损坏时直接重新开始。
    }
  }

  Future<void> _persist() async {
    await _db.saveHistory(_entries);
  }

  /// 记录或更新一条播放进度，并置顶。
  Future<void> record(HistoryEntry entry) async {
    final existing = _entries
        .where(
          (item) =>
              item.sourceId == entry.sourceId && item.path == entry.path,
        )
        .firstOrNull;
    final next = entry.thumbnailPath == null
        ? entry.copyWith(thumbnailPath: existing?.thumbnailPath)
        : entry;
    _entries.removeWhere(
      (item) => item.sourceId == entry.sourceId && item.path == entry.path,
    );
    _entries.insert(0, next);
    if (_entries.length > _maxEntries) {
      _entries.removeRange(_maxEntries, _entries.length);
    }
    notifyListeners();
    await _persist();
  }

  /// 更新某条播放记录的暂停帧缩略图。
  Future<void> setThumbnail(
    String sourceId,
    String path,
    String thumbnailPath,
  ) async {
    final index = _entries.indexWhere(
      (item) => item.sourceId == sourceId && item.path == path,
    );
    if (index < 0) return;
    _entries[index] = _entries[index].copyWith(
      thumbnailPath: thumbnailPath,
    );
    notifyListeners();
    await _persist();
  }

  /// 从最近播放中移除一条记录（不会删除媒体文件）。
  Future<void> remove(String sourceId, String path) async {
    _entries.removeWhere(
      (item) => item.sourceId == sourceId && item.path == path,
    );
    notifyListeners();
    await _persist();
  }

  Future<void> clear() async {
    _entries.clear();
    notifyListeners();
    await _db.saveHistory(const []);
    await _store.delete(_key);
  }
}
