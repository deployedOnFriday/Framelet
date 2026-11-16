import 'dart:convert';

import '../models/media_source.dart';
import 'credential_store.dart';
import 'series_key.dart';

/// 一部作品（整部剧）的片头片尾位置，单位秒。
///
/// 记录的是「片头结束点」和「片尾起点」，每集复用同一组值；
/// 不同集时长略有出入时由播放器做边界钳制。
class SeriesSkipMarks {
  const SeriesSkipMarks({
    this.introStartSec,
    this.introEndSec,
    this.outroStartSec,
  });

  /// 片头开始时间：为空表示片头从 0 开始。
  final double? introStartSec;

  /// 片头结束时间：跳过片头即跳到此处。
  final double? introEndSec;

  /// 片尾开始时间：到这里即可跳过片尾。
  final double? outroStartSec;

  bool get isEmpty => introEndSec == null && outroStartSec == null;

  bool get hasIntro => introEndSec != null && introEndSec! > 0;

  bool get hasOutro => outroStartSec != null && outroStartSec! > 0;

  SeriesSkipMarks copyWith({
    double? introStartSec,
    double? introEndSec,
    double? outroStartSec,
    bool clearIntroStart = false,
    bool clearIntro = false,
    bool clearOutro = false,
  }) {
    return SeriesSkipMarks(
      introStartSec: clearIntroStart
          ? null
          : (introStartSec ?? this.introStartSec),
      introEndSec: clearIntro ? null : (introEndSec ?? this.introEndSec),
      outroStartSec: clearOutro ? null : (outroStartSec ?? this.outroStartSec),
    );
  }

  Map<String, Object?> toJson() => {
    if (introStartSec != null) 'introStart': introStartSec,
    if (introEndSec != null) 'intro': introEndSec,
    if (outroStartSec != null) 'outro': outroStartSec,
  };

  /// 两侧都有的字段以 [other] 为准，用来「手动标记覆盖自动识别」。
  SeriesSkipMarks merge(SeriesSkipMarks? other) {
    if (other == null) return this;
    return SeriesSkipMarks(
      introStartSec: other.introStartSec ?? introStartSec,
      introEndSec: other.introEndSec ?? introEndSec,
      outroStartSec: other.outroStartSec ?? outroStartSec,
    );
  }

  static SeriesSkipMarks? fromJson(Object? raw) {
    if (raw is! Map) return null;
    double? read(Object? value) {
      final parsed = value is num
          ? value.toDouble()
          : double.tryParse(value?.toString() ?? '');
      if (parsed == null || !parsed.isFinite || parsed <= 0) return null;
      return parsed;
    }

    final marks = SeriesSkipMarks(
      introStartSec: read(raw['introStart']),
      introEndSec: read(raw['intro']),
      outroStartSec: read(raw['outro']),
    );
    return marks.isEmpty ? null : marks;
  }
}

/// 片头片尾标记的来源，用于界面上说明「这个时间是我手动标的还是查到的」。
enum SkipMarkSource { none, manual, auto }

/// 片头片尾标记查询结果。
class SkipMarkResult {
  const SkipMarkResult(this.marks, this.source);

  const SkipMarkResult.none()
    : marks = const SeriesSkipMarks(),
      source = SkipMarkSource.none;

  final SeriesSkipMarks marks;
  final SkipMarkSource source;
}

/// 持久化片头片尾标记。
///
/// 手动标记按「部」保存（整部剧共用）；自动识别结果按「集」缓存，
/// 因为每集的片头片尾长度并不一样。两者合并时手动值优先。
class SkipMarksStore {
  SkipMarksStore._();

  static final SkipMarksStore instance = SkipMarksStore._();

  static const _manualKey = 'framelet.skip.marks';
  static const _autoKey = 'framelet.skip.auto';
  static const _maxEntries = 200;

  final CredentialStore _store = CredentialStore();

  Map<String, SeriesSkipMarks>? _manualCache;
  Future<Map<String, SeriesSkipMarks>>? _manualLoading;
  Map<String, SeriesSkipMarks>? _autoCache;
  Future<Map<String, SeriesSkipMarks>>? _autoLoading;

  Future<SeriesSkipMarks?> manualMarksFor(ScannedVideo video) async {
    final key = SeriesKey.of(video);
    if (key.isEmpty) return null;
    final data = await _ensureManualLoaded();
    final marks = data[key];
    if (marks == null) return null;
    data
      ..remove(key)
      ..[key] = marks;
    return marks;
  }

  Future<void> save(ScannedVideo video, SeriesSkipMarks marks) async {
    final key = SeriesKey.of(video);
    if (key.isEmpty) return;
    final data = await _ensureManualLoaded();
    if (marks.isEmpty) {
      if (data.remove(key) == null) return;
    } else {
      data
        ..remove(key)
        ..[key] = marks;
      while (data.length > _maxEntries) {
        data.remove(data.keys.first);
      }
    }
    await _persist(_manualKey, data);
  }

  /// 自动识别结果的缓存：按「TMDB + 季 + 集」。
  static String autoKeyOf({
    required int tmdbId,
    required int season,
    required int episode,
  }) => 'tmdb:$tmdbId|s${season}e$episode';

  Future<SeriesSkipMarks?> autoMarksOf(String key) async {
    if (key.isEmpty) return null;
    final data = await _ensureAutoLoaded();
    return data[key];
  }

  Future<void> saveAuto(String key, SeriesSkipMarks marks) async {
    if (key.isEmpty || marks.isEmpty) return;
    final data = await _ensureAutoLoaded();
    data
      ..remove(key)
      ..[key] = marks;
    while (data.length > _maxEntries) {
      data.remove(data.keys.first);
    }
    await _persist(_autoKey, data);
  }

  /// 删掉某一集的自动识别缓存（用户手动清除后不要又被自动结果顶回来）。
  Future<void> clearAuto(String key) async {
    if (key.isEmpty) return;
    final data = await _ensureAutoLoaded();
    if (data.remove(key) == null) return;
    await _persist(_autoKey, data);
  }

  /// 最终生效的标记：手动标注覆盖自动识别。
  Future<SkipMarkResult> resolve(
    ScannedVideo video, {
    SeriesSkipMarks? auto,
  }) async {
    final manual = await manualMarksFor(video);
    if (manual != null && !manual.isEmpty) {
      return SkipMarkResult(manual.merge(auto), SkipMarkSource.manual);
    }
    if (auto != null && !auto.isEmpty) {
      return SkipMarkResult(auto, SkipMarkSource.auto);
    }
    return const SkipMarkResult.none();
  }

  Future<Map<String, SeriesSkipMarks>> _ensureManualLoaded() {
    final cached = _manualCache;
    if (cached != null) return Future.value(cached);
    return _manualLoading ??= _load(_manualKey)
        .whenComplete(() => _manualLoading = null);
  }

  Future<Map<String, SeriesSkipMarks>> _ensureAutoLoaded() {
    final cached = _autoCache;
    if (cached != null) return Future.value(cached);
    return _autoLoading ??= _load(_autoKey)
        .whenComplete(() => _autoLoading = null);
  }

  Future<Map<String, SeriesSkipMarks>> _load(String storageKey) async {
    final data = <String, SeriesSkipMarks>{};
    try {
      final raw = await _store.read(storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final marks = SeriesSkipMarks.fromJson(entry.value);
            if (marks != null) data[entry.key.toString()] = marks;
          }
        }
      }
    } catch (_) {
      // 存储损坏时按「没有标记」处理，不影响播放。
    }
    return storageKey == _autoKey ? _autoCache = data : _manualCache = data;
  }

  Future<void> _persist(
    String storageKey,
    Map<String, SeriesSkipMarks> data,
  ) async {
    final encoded = jsonEncode({
      for (final entry in data.entries) entry.key: entry.value.toJson(),
    });
    try {
      await _store.write(storageKey, encoded);
    } catch (_) {
      // 写失败只影响下次能否恢复，不该打断播放。
    }
  }
}

/// 当前进度是否该提示跳过。
enum SkipPrompt { none, intro, outro }

/// 纯函数：根据标记与当前进度决定要不要弹「跳过」按钮。
///
/// - 片头：只有停在片头区间内才提示，跳过或越过之后不再打扰；
/// - 片尾：进入片尾区间后提示一次，跳过/播完即消失。
class SkipPromptResolver {
  SkipPromptResolver._();

  /// 距离片头结束不足这么多次秒就不再提示，避免刚进片头就跳。
  static const introTailSeconds = 2.0;

  static SkipPrompt resolve({
    required SeriesSkipMarks marks,
    required double positionSec,
    required double durationSec,
    required bool introSkipped,
    required bool outroSkipped,
  }) {
    if (positionSec <= 0) return SkipPrompt.none;
    final introEnd = marks.introEndSec;
    if (!introSkipped &&
        introEnd != null &&
        positionSec >= (marks.introStartSec ?? 0) &&
        positionSec < introEnd - introTailSeconds) {
      return SkipPrompt.intro;
    }
    final outroStart = marks.outroStartSec;
    if (!outroSkipped &&
        outroStart != null &&
        (durationSec <= 0 || outroStart < durationSec) &&
        positionSec >= outroStart) {
      return SkipPrompt.outro;
    }
    return SkipPrompt.none;
  }
}
