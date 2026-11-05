import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../models/history_entry.dart';
import '../models/media_source.dart';

/// 媒体库与播放历史的本地持久化入口。
///
/// 只有密码、TMDB Key、DanDanPlay Secret 等敏感信息留在安全存储；
/// 媒体库、播放历史和普通设置进入 SQLite。
abstract class FrameletStore {
  static FrameletStore instance = SqliteFrameletStore();

  Future<void> open();

  Future<List<MediaSource>> loadSources();

  Future<void> saveSources(List<MediaSource> sources);

  Future<Map<String, List<ScannedVideo>>> loadVideos();

  Future<void> saveVideos(String sourceId, List<ScannedVideo> videos);

  Future<void> deleteSourceData(String sourceId);

  Future<List<HistoryEntry>> loadHistory();

  Future<void> saveHistory(List<HistoryEntry> entries);

  Future<bool> hasCompletedLegacyMigration();

  Future<void> markLegacyMigrationCompleted();

  /// 读取普通设置项（键值对表 app_meta）。
  Future<String?> loadMeta(String key);

  /// 写入普通设置项。
  Future<void> saveMeta(String key, String value);
}

class SqliteFrameletStore implements FrameletStore {
  Database? _db;
  Future<void>? _opening;

  Database get _database {
    final db = _db;
    if (db == null) {
      throw StateError('FrameletStore 尚未打开');
    }
    return db;
  }

  @override
  Future<void> open() {
    final existing = _db;
    if (existing != null) return Future.value();
    return _opening ??= _openInternal();
  }

  Future<void> _openInternal() async {
    final support = await getApplicationSupportDirectory();
    await support.create(recursive: true);
    final db = sqlite3.open('${support.path}${Platform.pathSeparator}framelet.db');
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('''
      CREATE TABLE IF NOT EXISTS sources (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        kind TEXT NOT NULL,
        address TEXT NOT NULL,
        username TEXT NOT NULL,
        directory TEXT NOT NULL,
        connected INTEGER NOT NULL,
        last_sync TEXT NOT NULL
      )
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS videos (
        source_id TEXT NOT NULL,
        path TEXT NOT NULL,
        title TEXT NOT NULL,
        kind INTEGER NOT NULL,
        episode_count INTEGER NOT NULL,
        size_bytes INTEGER NOT NULL,
        modified INTEGER,
        poster_path TEXT,
        summary TEXT,
        rating TEXT,
        backdrop_path TEXT,
        genres_json TEXT NOT NULL,
        cast_json TEXT NOT NULL,
        release_date TEXT,
        runtime_sec REAL,
        still_path TEXT,
        episode_title TEXT,
        tmdb_id INTEGER,
        tmdb_title TEXT,
        PRIMARY KEY (source_id, path),
        FOREIGN KEY (source_id) REFERENCES sources(id) ON DELETE CASCADE
      )
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS history (
        source_id TEXT NOT NULL,
        path TEXT NOT NULL,
        title TEXT NOT NULL,
        kind INTEGER NOT NULL,
        position_sec REAL NOT NULL,
        duration_sec REAL NOT NULL,
        thumbnail_path TEXT,
        updated_at_ms INTEGER NOT NULL,
        PRIMARY KEY (source_id, path)
      )
    ''');
    final historyColumns = db
        .select('PRAGMA table_info(history)')
        .map((row) => row['name'] as String)
        .toSet();
    if (!historyColumns.contains('thumbnail_path')) {
      db.execute('ALTER TABLE history ADD COLUMN thumbnail_path TEXT');
    }
    db.execute('''
      CREATE TABLE IF NOT EXISTS app_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    db.execute('CREATE INDEX IF NOT EXISTS idx_videos_source ON videos(source_id)');
    db.execute('CREATE INDEX IF NOT EXISTS idx_history_updated ON history(updated_at_ms DESC)');
    _db = db;
  }

  @override
  Future<List<MediaSource>> loadSources() async {
    await open();
    return _database
        .select('SELECT * FROM sources ORDER BY rowid')
        .map(_sourceFromRow)
        .toList();
  }

  @override
  Future<void> saveSources(List<MediaSource> sources) async {
    await open();
    final db = _database;
    db.execute('BEGIN IMMEDIATE');
    try {
      final stmt = db.prepare('''
        INSERT INTO sources
          (id, name, kind, address, username, directory, connected, last_sync)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          name = excluded.name,
          kind = excluded.kind,
          address = excluded.address,
          username = excluded.username,
          directory = excluded.directory,
          connected = excluded.connected,
          last_sync = excluded.last_sync
      ''');
      try {
        for (final source in sources) {
          stmt.execute([
            source.id,
            source.name,
            source.kind.name,
            source.address,
            source.username,
            source.directory,
            source.connected ? 1 : 0,
            source.lastSync,
          ]);
        }
      } finally {
        stmt.dispose();
      }
      final ids = sources.map((source) => source.id).toSet();
      final stale = db
          .select('SELECT id FROM sources')
          .map((row) => row['id'] as String)
          .where((id) => !ids.contains(id))
          .toList();
      for (final id in stale) {
        db.execute('DELETE FROM sources WHERE id = ?', [id]);
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<Map<String, List<ScannedVideo>>> loadVideos() async {
    await open();
    final result = <String, List<ScannedVideo>>{};
    for (final row in _database.select('SELECT * FROM videos ORDER BY rowid')) {
      final sourceId = row['source_id'] as String;
      result.putIfAbsent(sourceId, () => []).add(_videoFromRow(row));
    }
    return result;
  }

  @override
  Future<void> saveVideos(String sourceId, List<ScannedVideo> videos) async {
    await open();
    final db = _database;
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute('DELETE FROM videos WHERE source_id = ?', [sourceId]);
      final stmt = db.prepare('''
        INSERT INTO videos (
          source_id, path, title, kind, episode_count, size_bytes, modified,
          poster_path, summary, rating, backdrop_path, genres_json, cast_json,
          release_date, runtime_sec, still_path, episode_title, tmdb_id,
          tmdb_title
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''');
      try {
        for (final video in videos) {
          stmt.execute([
            video.sourceId,
            video.path,
            video.title,
            video.kind.index,
            video.episodeCount,
            video.sizeBytes,
            video.modified?.millisecondsSinceEpoch,
            video.posterPath,
            video.summary,
            video.rating,
            video.backdropPath,
            jsonEncode(video.genres),
            jsonEncode(video.cast.map((member) => member.toJson()).toList()),
            video.releaseDate,
            video.runtimeSec,
            video.stillPath,
            video.episodeTitle,
            video.tmdbId,
            video.tmdbTitle,
          ]);
        }
      } finally {
        stmt.dispose();
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> deleteSourceData(String sourceId) async {
    await open();
    _database.execute('DELETE FROM sources WHERE id = ?', [sourceId]);
  }

  @override
  Future<List<HistoryEntry>> loadHistory() async {
    await open();
    return _database
        .select('SELECT * FROM history ORDER BY updated_at_ms DESC LIMIT 50')
        .map(
          (row) => HistoryEntry(
            sourceId: row['source_id'] as String,
            path: row['path'] as String,
            title: row['title'] as String,
            kind: MediaKind.values[row['kind'] as int],
            positionSec: (row['position_sec'] as num).toDouble(),
            durationSec: (row['duration_sec'] as num).toDouble(),
            thumbnailPath: row['thumbnail_path'] as String?,
            updatedAtMs: row['updated_at_ms'] as int,
          ),
        )
        .toList();
  }

  @override
  Future<void> saveHistory(List<HistoryEntry> entries) async {
    await open();
    final db = _database;
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute('DELETE FROM history');
      final stmt = db.prepare('''
        INSERT INTO history (
          source_id, path, title, kind, position_sec, duration_sec,
          thumbnail_path, updated_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''');
      try {
        for (final entry in entries) {
          stmt.execute([
            entry.sourceId,
            entry.path,
            entry.title,
            entry.kind.index,
            entry.positionSec,
            entry.durationSec,
            entry.thumbnailPath,
            entry.updatedAtMs,
          ]);
        }
      } finally {
        stmt.dispose();
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<bool> hasCompletedLegacyMigration() async {
    await open();
    final rows = _database.select(
      "SELECT value FROM app_meta WHERE key = 'legacy_secure_storage_v1'",
    );
    return rows.isNotEmpty && rows.first['value'] == '1';
  }

  @override
  Future<void> markLegacyMigrationCompleted() async {
    await open();
    _database.execute(
      "INSERT OR REPLACE INTO app_meta (key, value) VALUES ('legacy_secure_storage_v1', '1')",
    );
  }

  @override
  Future<String?> loadMeta(String key) async {
    await open();
    final rows = _database.select(
      'SELECT value FROM app_meta WHERE key = ?',
      [key],
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  @override
  Future<void> saveMeta(String key, String value) async {
    await open();
    _database.execute(
      'INSERT OR REPLACE INTO app_meta (key, value) VALUES (?, ?)',
      [key, value],
    );
  }

  MediaSource _sourceFromRow(Row row) {
    final kindName = row['kind'] as String? ?? MediaSourceKind.webdav.name;
    final kind = MediaSourceKind.values
        .where((item) => item.name == kindName)
        .firstOrNull;
    return MediaSource(
      id: row['id'] as String,
      name: row['name'] as String,
      kind: kind ?? MediaSourceKind.webdav,
      address: row['address'] as String,
      username: row['username'] as String? ?? '',
      directory: row['directory'] as String? ?? '/',
      connected: (row['connected'] as int? ?? 0) == 1,
      lastSync: row['last_sync'] as String? ?? '尚未同步',
    );
  }

  ScannedVideo _videoFromRow(Row row) {
    final genres = (jsonDecode(row['genres_json'] as String? ?? '[]') as List)
        .whereType<String>()
        .toList();
    final cast = (jsonDecode(row['cast_json'] as String? ?? '[]') as List)
        .whereType<Map>()
        .map((item) => CastMember.fromJson(item.cast<String, Object?>()))
        .toList();
    final modified = row['modified'] as int?;
    return ScannedVideo(
      sourceId: row['source_id'] as String,
      path: row['path'] as String,
      title: row['title'] as String,
      kind: MediaKind.values[row['kind'] as int],
      episodeCount: row['episode_count'] as int,
      sizeBytes: row['size_bytes'] as int,
      modified: modified == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(modified),
      posterPath: row['poster_path'] as String?,
      summary: row['summary'] as String?,
      rating: row['rating'] as String?,
      backdropPath: row['backdrop_path'] as String?,
      genres: genres,
      cast: cast,
      releaseDate: row['release_date'] as String?,
      runtimeSec: (row['runtime_sec'] as num?)?.toDouble(),
      stillPath: row['still_path'] as String?,
      episodeTitle: row['episode_title'] as String?,
      tmdbId: row['tmdb_id'] as int?,
      tmdbTitle: row['tmdb_title'] as String?,
    );
  }
}

class MemoryFrameletStore implements FrameletStore {
  final List<MediaSource> _sources = [];
  final Map<String, List<ScannedVideo>> _videos = {};
  final List<HistoryEntry> _history = [];
  final Map<String, String> _meta = {};
  bool _migrated = false;

  @override
  Future<void> open() async {}

  @override
  Future<List<MediaSource>> loadSources() async => List.of(_sources);

  @override
  Future<void> saveSources(List<MediaSource> sources) async {
    _sources
      ..clear()
      ..addAll(sources);
  }

  @override
  Future<Map<String, List<ScannedVideo>>> loadVideos() async => {
    for (final entry in _videos.entries) entry.key: List.of(entry.value),
  };

  @override
  Future<void> saveVideos(String sourceId, List<ScannedVideo> videos) async {
    _videos[sourceId] = List.of(videos);
  }

  @override
  Future<void> deleteSourceData(String sourceId) async {
    _sources.removeWhere((source) => source.id == sourceId);
    _videos.remove(sourceId);
  }

  @override
  Future<List<HistoryEntry>> loadHistory() async => List.of(_history);

  @override
  Future<void> saveHistory(List<HistoryEntry> entries) async {
    _history
      ..clear()
      ..addAll(entries);
  }

  @override
  Future<bool> hasCompletedLegacyMigration() async => _migrated;

  @override
  Future<void> markLegacyMigrationCompleted() async => _migrated = true;

  @override
  Future<String?> loadMeta(String key) async => _meta[key];

  @override
  Future<void> saveMeta(String key, String value) async => _meta[key] = value;
}
