import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/media_source.dart';
import 'credential_store.dart';

/// 一条播放记录：最近播放列表与续播进度的最小单元。
class HistoryEntry {
  const HistoryEntry({
    required this.sourceId,
    required this.path,
    required this.title,
    required this.kind,
    this.positionSec = 0,
    this.durationSec = 0,
    required this.updatedAtMs,
  });

  final String sourceId;
  final String path;
  final String title;
  final MediaKind kind;
  final double positionSec;
  final double durationSec;
  final int updatedAtMs;

  double get progress {
    if (durationSec <= 0) return 0;
    return (positionSec / durationSec).clamp(0.0, 1.0);
  }

  bool get finished => progress >= 0.98;

  Map<String, Object?> toJson() => {
    'sourceId': sourceId,
    'path': path,
    'title': title,
    'kind': kind.index,
    'positionSec': positionSec,
    'durationSec': durationSec,
    'updatedAtMs': updatedAtMs,
  };

  factory HistoryEntry.fromJson(Map<String, Object?> json) => HistoryEntry(
    sourceId: json['sourceId']! as String,
    path: json['path']! as String,
    title: json['title']! as String,
    kind: MediaKind.values[json['kind']! as int],
    positionSec: (json['positionSec'] as num?)?.toDouble() ?? 0,
    durationSec: (json['durationSec'] as num?)?.toDouble() ?? 0,
    updatedAtMs: json['updatedAtMs']! as int,
  );

  HistoryEntry copyWith({
    double? positionSec,
    double? durationSec,
    int? updatedAtMs,
  }) => HistoryEntry(
    sourceId: sourceId,
    path: path,
    title: title,
    kind: kind,
    positionSec: positionSec ?? this.positionSec,
    durationSec: durationSec ?? this.durationSec,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );
}

/// 播放历史：内存缓存 + 安全存储持久化，最近 50 条。
class PlaybackHistory extends ChangeNotifier {
  PlaybackHistory._();

  static final PlaybackHistory instance = PlaybackHistory._();

  static const _key = 'framelet.history';
  static const _maxEntries = 50;

  final CredentialStore _store = CredentialStore();
  final List<HistoryEntry> _entries = [];

  List<HistoryEntry> get entries => List.unmodifiable(_entries);

  HistoryEntry? entryOf(String sourceId, String path) {
    for (final entry in _entries) {
      if (entry.sourceId == sourceId && entry.path == path) return entry;
    }
    return null;
  }

  Future<void> load() async {
    final raw = await _store.read(_key);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = (jsonDecode(raw) as List<Object?>)
          .map((item) => HistoryEntry.fromJson(item! as Map<String, Object?>))
          .toList();
      _entries
        ..clear()
        ..addAll(list);
      notifyListeners();
    } catch (_) {
      // 历史损坏时直接重新开始。
    }
  }

  Future<void> _persist() async {
    final json = jsonEncode(_entries.map((entry) => entry.toJson()).toList());
    await _store.write(_key, json);
  }

  /// 记录或更新一条播放进度，并置顶。
  Future<void> record(HistoryEntry entry) async {
    _entries.removeWhere(
      (item) => item.sourceId == entry.sourceId && item.path == entry.path,
    );
    _entries.insert(0, entry);
    if (_entries.length > _maxEntries) {
      _entries.removeRange(_maxEntries, _entries.length);
    }
    notifyListeners();
    await _persist();
  }

  Future<void> clear() async {
    _entries.clear();
    notifyListeners();
    await _store.delete(_key);
  }
}
