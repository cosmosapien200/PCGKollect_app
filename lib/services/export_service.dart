import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../data/models.dart';
import 'stats.dart';

/// Dataset exports (spec 01 §8.3, §14.6). Every export keeps dataset/subject/
/// recording UUIDs and states units in column names. Missing values are empty
/// (CSV) or null (JSON) — never 0.
class ExportService {
  final String outDir;
  ExportService(this.outDir);

  static const _fields = ['site', 'operator', 'body_position', 'auscultation_location', 'device_placement', 'conditions'];
  static const _check = ['operator_id', 'posture', 'auscultation_site', 'contact', 'ambient_noise', 'breathing'];

  static List<String> csvHeader() => [
        'dataset_id', 'subject_id', 'recording_id', 'take_index', 'subject_label', 'age_years_at_capture', 'sex',
        'height_cm', 'weight_kg', ..._fields, for (final c in _check) 'take_$c', 'start_time_utc', 'state', 'completion_reason', 'on_phone',
        'captured_duration_ms', 'scored_duration_ms', 'usable_duration_ms', 'usable_ratio', 'usable_beats',
        'total_beats', 'longest_usable_run_ms', 'longest_usable_run_beats', 'mean_beat_conf', 'snr_db',
        'clipping_ratio', 'model_version', 'settings_revision', 'audio_sha256', 'reviewed_utc', 'tags', 'notes',
      ];

  static String _csv(Object? v) {
    if (v == null) return '';
    final s = v is double ? (v.isNaN ? '' : v.toString()) : '$v';
    return (s.contains(',') || s.contains('"') || s.contains('\n')) ? '"${s.replaceAll('"', '""')}"' : s;
  }

  static List<Object?> csvRow(Recording r, Subject? s) => [
        r.datasetId, r.subjectId, r.id, r.takeIndex, s?.label, s?.ageAt(r.startAt ?? r.createdAt), s?.sex,
        s?.heightCm, s?.weightKg, for (final f in _fields) s?.fields[f], for (final c in _check) r.checklist[c],
        r.startAt?.toUtc().toIso8601String(), r.state, r.completionReason, r.onPhone,
        r.durationMs, r.scoredMs, r.usableMs, r.usableRatio, r.usableBeats, r.totalBeats, r.longestRunMs,
        r.longestRunBeats, r.meanConf, r.snrDb, r.clippingRatio, r.modelVersion, r.settingsRev, r.sha256,
        r.reviewedAt?.toUtc().toIso8601String(), r.tags, r.notes,
      ];

  static String recordingsCsv(List<Recording> recs, Map<String, Subject> subjects) {
    final b = StringBuffer()..writeln(csvHeader().join(','));
    for (final r in recs) {
      b.writeln(csvRow(r, subjects[r.subjectId]).map(_csv).join(','));
    }
    return b.toString();
  }

  static Map<String, Object?> summaryJson(Dataset ds, List<Subject> subjects, List<Recording> recs,
      {Map<String, dynamic> calibration = const {}}) {
    final onPhone = recs.where((r) => r.onPhone).toList();
    return {
      'schema_version': 1,
      'generated_utc': DateTime.now().toUtc().toIso8601String(),
      'dataset': {
        'dataset_id': ds.id, 'name': ds.name, 'settings_revision': ds.settingsRev, 'settings': ds.policy.toJson(),
        'calibration': calibration,
      },
      'analysis_unit': 'recording',
      'quantile_convention': 'linear interpolation, h = (N-1)p (Hyndman & Fan type 7)',
      'counts': {
        'subjects': subjects.length,
        'recordings': recs.length,
        'recordings_on_phone': onPhone.length,
        'complete': onPhone.where((r) => r.state == RecState.complete).length,
      },
      'totals_ms': {
        'captured': onPhone.fold<double>(0, (a, r) => a + (r.durationMs ?? 0)),
        'usable': onPhone.fold<double>(0, (a, r) => a + (r.usableMs ?? 0)),
      },
      'distributions': {
        'captured_duration_ms': Summary.of(onPhone.map((r) => r.durationMs)).toJson(),
        'usable_duration_ms': Summary.of(onPhone.map((r) => r.usableMs)).toJson(),
        'usable_ratio': Summary.of(onPhone.map((r) => r.usableRatio)).toJson(),
        'snr_db': Summary.of(onPhone.map((r) => r.snrDb)).toJson(),
        'mean_beat_conf': Summary.of(onPhone.map((r) => r.meanConf)).toJson(),
        'usable_beats': Summary.of(onPhone.map((r) => r.usableBeats?.toDouble())).toJson(),
      },
      'subjects': [
        for (final s in subjects)
          {
            'subject_id': s.id, 'label': s.label, 'date_of_birth': s.dateOfBirth?.toIso8601String().substring(0, 10),
            'age_years': s.ageYears, 'sex': s.sex, 'height_cm': s.heightCm, 'weight_kg': s.weightKg,
            'fields': s.fields, 'created_utc': s.createdAt.toUtc().toIso8601String(),
          }
      ],
      'recordings': [
        for (final r in recs) Map.fromIterables(csvHeader(), csvRow(r, subjects.where((s) => s.id == r.subjectId).firstOrNull)),
      ],
    };
  }

  Future<File> _write(String name, String data) async {
    await Directory(outDir).create(recursive: true);
    final f = File(p.join(outDir, name));
    await f.writeAsString(data);
    return f;
  }

  static String _slug(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
  static String _stamp() => DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[:.]'), '').substring(0, 15);

  Future<File> exportCsv(Dataset ds, List<Subject> subjects, List<Recording> recs) => _write(
      '${_slug(ds.name)}_recordings_${_stamp()}.csv', recordingsCsv(recs, {for (final s in subjects) s.id: s}));

  Future<File> exportJson(Dataset ds, List<Subject> subjects, List<Recording> recs,
          {Map<String, dynamic> calibration = const {}}) =>
      _write('${_slug(ds.name)}_summary_${_stamp()}.json',
          const JsonEncoder.withIndent('  ').convert(summaryJson(ds, subjects, recs, calibration: calibration)));

  /// ZIP: README, manifest.json, recordings.csv and `recordings/<id>/` (audio.wav, sidecars, meta).
  Future<File> exportZip(Dataset ds, List<Subject> subjects, List<Recording> recs,
      {Map<String, dynamic> calibration = const {}}) async {
    await Directory(outDir).create(recursive: true);
    final path = p.join(outDir, '${_slug(ds.name)}_backup_${_stamp()}.zip');
    final enc = ZipFileEncoder()..create(path);
    void addText(String name, String text) {
      final bytes = utf8.encode(text);
      enc.addArchiveFile(ArchiveFile(name, bytes.length, bytes));
    }

    addText('README.md', _readme(ds));
    addText('manifest.json',
        const JsonEncoder.withIndent('  ').convert(summaryJson(ds, subjects, recs, calibration: calibration)));
    addText('recordings.csv', recordingsCsv(recs, {for (final s in subjects) s.id: s}));
    for (final r in recs.where((r) => r.onPhone)) {
      for (final f in ['audio.wav', 'beats.csv', 'quality.csv', 'meta.json']) {
        final file = File(p.join(r.localDir!, f));
        if (await file.exists()) await enc.addFile(file, 'recordings/${r.id}/$f');
      }
    }
    await enc.close();
    return File(path);
  }

  static String _readme(Dataset ds) => '''
# PCGKolect dataset export — ${ds.name}

Dataset ID: ${ds.id}
Settings revision: ${ds.settingsRev}
Generated (UTC): ${DateTime.now().toUtc().toIso8601String()}

PCGKolect is a research data-acquisition instrument, not a diagnostic device. Quality labels
describe acquisition quality (usable / unusable / unscored), not health.

## Contents
- `manifest.json` — dataset settings, subjects, per-recording metadata and summary statistics
  (schema_version 1; quantiles: linear interpolation, h = (N-1)p).
- `recordings.csv` — one row per recording; units are in the column names; empty = missing.
- `recordings/<recording_id>/audio.wav` — original device audio, PCM16 LE mono 8000 Hz, unmodified
  (SHA-256 in `meta.json` and `recordings.csv`).
- `recordings/<recording_id>/beats.csv` — `start_sample,end_sample,conf,pnoise,usable,reason`
- `recordings/<recording_id>/quality.csv` — 1 s windows `start_sample,end_sample,label,score,pnoise,reason`
- `recordings/<recording_id>/meta.json` — device metadata (policy, model version, link integrity, gaps).

All times in the sidecars are sample indices of `audio.wav` (start inclusive, end exclusive).
A beat is usable when its model confidence ≥ the dataset threshold, its length is valid and
(if enabled) its rhythm check passed. Usable time is the union of usable beats.
Participant labels may identify people: handle this archive under your study's data policy.
''';
}
