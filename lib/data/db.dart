import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// Local archive database (spec 01 §12). Schema changes go through [_migrations];
/// never edit an existing migration.
class AppDb {
  final Database db;
  AppDb._(this.db);

  static final List<List<String>> _migrations = [
    // v1
    [
      '''CREATE TABLE datasets(
        dataset_id TEXT PRIMARY KEY, name TEXT NOT NULL, name_lc TEXT NOT NULL UNIQUE,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, archived INTEGER NOT NULL DEFAULT 0,
        settings_json TEXT NOT NULL, settings_rev INTEGER NOT NULL,
        device_rev INTEGER, device_synced_at INTEGER)''',
      '''CREATE TABLE subjects(
        subject_id TEXT PRIMARY KEY, dataset_id TEXT NOT NULL REFERENCES datasets(dataset_id),
        label TEXT NOT NULL, dob TEXT, age_years REAL, sex TEXT NOT NULL,
        height_cm REAL, weight_kg REAL, fields_json TEXT NOT NULL DEFAULT '{}',
        notes TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL)''',
      'CREATE INDEX subjects_ds ON subjects(dataset_id)',
      '''CREATE TABLE recordings(
        recording_id TEXT PRIMARY KEY, dataset_id TEXT NOT NULL, subject_id TEXT NOT NULL,
        take_index INTEGER NOT NULL, state TEXT NOT NULL, created_at INTEGER NOT NULL,
        start_at INTEGER, end_at INTEGER, duration_ms REAL, scored_ms REAL, usable_ms REAL,
        usable_ratio REAL, usable_beats INTEGER, total_beats INTEGER, longest_run_ms REAL,
        longest_run_beats INTEGER, snr_db REAL, mean_conf REAL, clipping_ratio REAL,
        fw_rv TEXT, fw_esp TEXT, model_version TEXT, settings_rev INTEGER, completion TEXT,
        completion_reason TEXT, local_dir TEXT, sha256 TEXT, file_size INTEGER,
        transfer_state TEXT NOT NULL, transfer_error TEXT, device_id TEXT, reviewed_at INTEGER,
        notes TEXT NOT NULL DEFAULT '', tags TEXT NOT NULL DEFAULT '', meta_json TEXT)''',
      'CREATE INDEX recordings_ds ON recordings(dataset_id)',
      'CREATE INDEX recordings_subj ON recordings(subject_id)',
      '''CREATE TABLE quality_intervals(
        recording_id TEXT NOT NULL, start_sample INTEGER NOT NULL, end_sample INTEGER NOT NULL,
        label TEXT NOT NULL, score REAL, pnoise REAL, reason TEXT NOT NULL)''',
      'CREATE INDEX qi_rec ON quality_intervals(recording_id)',
      '''CREATE TABLE beats(
        recording_id TEXT NOT NULL, start_sample INTEGER NOT NULL, end_sample INTEGER NOT NULL,
        usable INTEGER NOT NULL, conf REAL, pnoise REAL, reason TEXT NOT NULL)''',
      'CREATE INDEX beats_rec ON beats(recording_id)',
      '''CREATE TABLE device_snapshots(
        device_id TEXT NOT NULL, ts INTEGER NOT NULL, json TEXT NOT NULL)''',
      'CREATE TABLE app_meta(key TEXT PRIMARY KEY, value TEXT)',
    ],
  ];

  static Future<AppDb> open({String? path}) async {
    final file = path ?? p.join(await getDatabasesPath(), 'pcgkolect.db');
    final db = await openDatabase(
      file,
      version: _migrations.length,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, v) async {
        for (final m in _migrations) {
          for (final s in m) {
            await db.execute(s);
          }
        }
      },
      onUpgrade: (db, from, to) async {
        for (var i = from; i < to; i++) {
          for (final s in _migrations[i]) {
            await db.execute(s);
          }
        }
      },
    );
    return AppDb._(db);
  }

  // --- meta -----------------------------------------------------------------
  Future<String?> getMeta(String key) async {
    final r = await db.query('app_meta', where: 'key = ?', whereArgs: [key]);
    return r.isEmpty ? null : r.first['value'] as String?;
  }

  Future<void> setMeta(String key, String? value) =>
      db.insert('app_meta', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);

  // --- datasets ---------------------------------------------------------------
  Future<List<Dataset>> datasets({bool includeArchived = false}) async {
    final rows = await db.query('datasets',
        where: includeArchived ? null : 'archived = 0', orderBy: 'created_at');
    return rows.map(Dataset.fromRow).toList();
  }

  Future<Dataset?> dataset(String id) async {
    final r = await db.query('datasets', where: 'dataset_id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Dataset.fromRow(r.first);
  }

  /// Inserts or updates; throws [DuplicateNameException] if another dataset has the name.
  Future<void> saveDataset(Dataset d) async {
    final clash = await db.query('datasets',
        where: 'name_lc = ? AND dataset_id != ?', whereArgs: [d.name.trim().toLowerCase(), d.id]);
    if (clash.isNotEmpty) throw DuplicateNameException(d.name);
    await db.insert('datasets', d.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // --- subjects -------------------------------------------------------------
  Future<List<Subject>> subjects(String datasetId) async {
    final rows = await db.query('subjects', where: 'dataset_id = ?', whereArgs: [datasetId], orderBy: 'created_at');
    return rows.map(Subject.fromRow).toList();
  }

  Future<Subject?> subject(String id) async {
    final r = await db.query('subjects', where: 'subject_id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Subject.fromRow(r.first);
  }

  Future<void> saveSubject(Subject s) =>
      db.insert('subjects', s.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

  // --- recordings -----------------------------------------------------------
  Future<List<Recording>> recordings(String datasetId) async {
    final rows = await db.query('recordings', where: 'dataset_id = ?', whereArgs: [datasetId], orderBy: 'created_at DESC');
    return rows.map(Recording.fromRow).toList();
  }

  Future<Recording?> recording(String id) async {
    final r = await db.query('recordings', where: 'recording_id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Recording.fromRow(r.first);
  }

  Future<void> saveRecording(Recording r, {Transaction? txn}) =>
      (txn ?? db).insert('recordings', r.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

  Future<int> nextTake(String subjectId) async {
    final r = await db.rawQuery('SELECT MAX(take_index) AS m FROM recordings WHERE subject_id = ?', [subjectId]);
    return ((r.first['m'] as int?) ?? 0) + 1;
  }

  /// Replaces the annotations of a recording inside one transaction.
  Future<void> commitImport(Recording r, List<Interval> quality, List<Interval> beats) async {
    await db.transaction((txn) async {
      await saveRecording(r, txn: txn);
      await txn.delete('quality_intervals', where: 'recording_id = ?', whereArgs: [r.id]);
      await txn.delete('beats', where: 'recording_id = ?', whereArgs: [r.id]);
      final b = txn.batch();
      for (final q in quality) {
        b.insert('quality_intervals', {
          'recording_id': r.id, 'start_sample': q.startSample, 'end_sample': q.endSample,
          'label': q.label, 'score': q.score, 'pnoise': q.pnoise, 'reason': q.reason,
        });
      }
      for (final x in beats) {
        b.insert('beats', {
          'recording_id': r.id, 'start_sample': x.startSample, 'end_sample': x.endSample,
          'usable': x.label == 'usable' ? 1 : 0, 'conf': x.score, 'pnoise': x.pnoise, 'reason': x.reason,
        });
      }
      await b.commit(noResult: true);
    });
  }

  Future<List<Interval>> qualityIntervals(String recordingId) async {
    final rows = await db.query('quality_intervals',
        where: 'recording_id = ?', whereArgs: [recordingId], orderBy: 'start_sample');
    return rows
        .map((r) => Interval(r['start_sample'] as int, r['end_sample'] as int, r['label'] as String,
            (r['score'] as num?)?.toDouble(), (r['pnoise'] as num?)?.toDouble(), r['reason'] as String))
        .toList();
  }

  Future<List<Interval>> beats(String recordingId) async {
    final rows = await db.query('beats', where: 'recording_id = ?', whereArgs: [recordingId], orderBy: 'start_sample');
    return rows
        .map((r) => Interval(r['start_sample'] as int, r['end_sample'] as int,
            (r['usable'] as int) == 1 ? 'usable' : 'unusable', (r['conf'] as num?)?.toDouble(),
            (r['pnoise'] as num?)?.toDouble(), r['reason'] as String))
        .toList();
  }
}

class DuplicateNameException implements Exception {
  final String name;
  DuplicateNameException(this.name);
  @override
  String toString() => 'A dataset named "$name" already exists.';
}
