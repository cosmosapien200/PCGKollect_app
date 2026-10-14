import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core/protocol.dart';
import '../data/db.dart';
import '../data/models.dart';
import '../device/device_link.dart';
import 'wav.dart';

class SyncProgress {
  final int index, total;
  final String recordingId, phase; // download | verify | commit | ack | delete | skip | done | error
  final int bytes, bytesTotal;
  final String? error;
  const SyncProgress(this.index, this.total, this.recordingId, this.phase,
      {this.bytes = 0, this.bytesTotal = 0, this.error});
}

class SyncResult {
  int imported = 0, alreadyHad = 0, deleted = 0, failed = 0;
  final errors = <String>[];
  @override
  String toString() =>
      'imported $imported, already on phone $alreadyHad, deleted from device $deleted, failed $failed';
}

/// Verified download-and-commit of device recordings (spec 01 §11.2).
///
/// Per recording: download every file to `tmp/<rid>/` (resuming partial files), check
/// sizes + SHA-256 against the manifest, validate the WAV header against the metadata,
/// move the folder into `recordings/<rid>/` and commit the DB rows in one transaction,
/// then ACK with the audio hash. Device copies are deleted only when [deleteAfter]
/// (the Sync action) and only after the ACK succeeded. Re-running is idempotent.
class SyncService {
  final AppDb db;
  final String root; // app-private storage root
  SyncService(this.db, this.root);

  static const kinds = ['meta', 'beats', 'quality', 'audio'];

  String recordingDir(String rid) => p.join(root, 'recordings', rid);

  Future<SyncResult> run({
    required DeviceLink link,
    required FileSource files,
    required bool deleteAfter,
    String? deviceId,
    void Function(SyncProgress)? onProgress,
  }) async {
    final res = SyncResult();
    await files.health();
    final items = await files.manifest();
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      void report(String phase, {int b = 0, int t = 0, String? err}) =>
          onProgress?.call(SyncProgress(i, items.length, it.recordingId, phase, bytes: b, bytesTotal: t, error: err));
      try {
        final audioSha = it.files['audio']?.sha256 ?? '';
        final local = await db.recording(it.recordingId);
        if (local != null && local.onPhone && local.sha256 == audioSha) {
          res.alreadyHad++;
          report('skip');
        } else {
          await _import(it, files, deviceId, report);
          await db.audit(it.datasetId, 'recording_imported', '${it.recordingId} sha256 $audioSha');
          res.imported++;
        }
        if (it.transfer != 'verified') {
          report('ack');
          await link.call('ack', {'recording_id': it.recordingId, 'sha256': audioSha});
        }
        if (deleteAfter) {
          report('delete');
          await link.call('delete', {'recording_id': it.recordingId, 'sha256': audioSha});
          await db.audit(it.datasetId, 'device_copy_deleted', '${it.recordingId} after verified transfer');
          res.deleted++;
        }
        report('done');
      } catch (e) {
        res.failed++;
        res.errors.add('${shortId(it.recordingId)}: $e');
        report('error', err: '$e');
        final local = await db.recording(it.recordingId);
        if (local != null && !local.onPhone) {
          local.transferError = '$e';
          await db.saveRecording(local);
        }
      }
    }
    return res;
  }

  Future<void> _import(ManifestItem it, FileSource files, String? deviceId,
      void Function(String, {int b, int t, String? err}) report) async {
    final tmp = Directory(p.join(root, 'tmp', it.recordingId));
    await tmp.create(recursive: true);
    final total = it.files.values.fold<int>(0, (a, f) => a + f.size);
    var before = 0;
    for (final kind in kinds) {
      final want = it.files[kind];
      if (want == null) throw TransferException('Device manifest lacks the $kind file');
      final f = File(p.join(tmp.path, _name(kind)));
      if (await f.exists() && await f.length() > want.size) await f.delete(); // stale partial
      await files.download(it.recordingId, kind, f, progress: (d, _) => report('download', b: before + d, t: total));
      report('verify', b: before + want.size, t: total);
      final bytes = await f.readAsBytes();
      final sha = sha256.convert(bytes).toString();
      if (bytes.length != want.size || sha != want.sha256) {
        await f.delete(); // corrupt: never resume from it
        throw TransferException('$kind failed verification (size or SHA-256 mismatch)');
      }
      before += want.size;
    }

    // Cross-check the metadata and the WAV header.
    final meta = jsonDecode(await File(p.join(tmp.path, 'meta.json')).readAsString()) as Map<String, dynamic>;
    if (meta['recording_id'] != it.recordingId) throw TransferException('Metadata belongs to another recording');
    final audio = (meta['audio'] ?? {}) as Map<String, dynamic>;
    if (audio['sha256'] != it.files['audio']!.sha256) throw TransferException('Audio hash differs from metadata');
    final wav = await WavInfo.ofFile(File(p.join(tmp.path, 'audio.wav')));
    if (!wav.isCanonical) throw TransferException('Unexpected audio format');
    if (audio['sample_count'] != null && wav.sampleCount != (audio['sample_count'] as num).toInt()) {
      throw TransferException('WAV length differs from metadata');
    }
    final quality = _parseQuality(await File(p.join(tmp.path, 'quality.csv')).readAsString());
    final beats = _parseBeats(await File(p.join(tmp.path, 'beats.csv')).readAsString());

    // Commit: move files into place, then the DB rows in one transaction.
    report('commit');
    final dest = Directory(recordingDir(it.recordingId));
    if (await dest.exists()) await dest.delete(recursive: true); // stale copy from an earlier failed commit
    await dest.parent.create(recursive: true);
    await tmp.rename(dest.path);

    final rec = await _recordingFromMeta(it, meta, dest.path, deviceId);
    await db.commitImport(rec, quality, beats);
  }

  static String _name(String kind) => switch (kind) {
        'audio' => 'audio.wav',
        'meta' => 'meta.json',
        'beats' => 'beats.csv',
        _ => 'quality.csv',
      };

  Future<Recording> _recordingFromMeta(
      ManifestItem it, Map<String, dynamic> meta, String dir, String? deviceId) async {
    final q = (meta['quality'] ?? {}) as Map<String, dynamic>;
    // Recordings made by another phone/dataset are imported, never relabelled.
    var ds = await db.dataset(it.datasetId);
    if (ds == null) {
      final now = DateTime.now();
      final base = 'Imported ${meta['dataset_name'] ?? shortId(it.datasetId)}';
      var name = base;
      for (var n = 2; (await db.datasets(includeArchived: true)).any((d) => d.name.toLowerCase() == name.toLowerCase()); n++) {
        name = '$base ($n)';
      }
      ds = Dataset(id: it.datasetId, name: name, createdAt: now, updatedAt: now,
          policy: Policy.fromJson((q['policy'] ?? {}) as Map<String, dynamic>));
      await db.saveDataset(ds);
    }
    if (await db.subject(it.subjectId) == null) {
      await db.saveSubject(Subject(
          id: it.subjectId, datasetId: it.datasetId, label: 'Unregistered ${shortId(it.subjectId)}',
          createdAt: DateTime.now()));
    }
    final existing = await db.recording(it.recordingId);
    final r = existing ??
        Recording(id: it.recordingId, datasetId: it.datasetId, subjectId: it.subjectId, takeIndex: it.take,
            createdAt: DateTime.fromMillisecondsSinceEpoch(it.startUtcMs));
    final completion = meta['completion_state'] as String? ?? it.completion;
    double? d(Object? v) => (v as num?)?.toDouble();
    r
      ..state = switch (completion) {
        'complete' => RecState.complete,
        'interrupted' => RecState.interrupted,
        _ => RecState.incomplete,
      }
      ..completion = completion
      ..completionReason = meta['completion_reason'] as String?
      ..startAt = it.startUtcMs > 0 ? DateTime.fromMillisecondsSinceEpoch(it.startUtcMs) : null
      ..durationMs = d(q['captured_duration_ms'])
      ..endAt = r.startAt?.add(Duration(milliseconds: (d(q['captured_duration_ms']) ?? 0).round()))
      ..scoredMs = d(q['scored_duration_ms'])
      ..usableMs = d(q['usable_duration_ms'])
      ..usableRatio = d(q['usable_ratio'])
      ..usableBeats = (q['usable_beats'] as num?)?.toInt()
      ..totalBeats = (q['total_beats'] as num?)?.toInt()
      ..longestRunMs = d(q['longest_usable_run_ms'])
      ..longestRunBeats = (q['longest_usable_run_beats'] as num?)?.toInt()
      ..snrDb = d(q['snr_db']) // null stays null — never 0 dB
      ..meanConf = d(q['mean_beat_conf'])
      ..clippingRatio = d(q['clipping_ratio'])
      ..modelVersion = q['model_version'] as String?
      ..settingsRev = (q['policy_revision'] as num?)?.toInt()
      ..firmwareRv = (meta['firmware'] as Map?)?['rv'] as String?
      ..localDir = dir
      ..sha256 = it.files['audio']!.sha256
      ..fileSize = it.files['audio']!.size
      ..transferState = Transfer.verified
      ..transferError = null
      ..deviceId = deviceId ?? r.deviceId
      ..meta = meta;
    return r;
  }

  static List<Interval> _parseQuality(String csv) => _rows(csv).map((c) => Interval(int.parse(c[0]),
      int.parse(c[1]), c[2], double.tryParse(c[3]), double.tryParse(c[4]), c.length > 5 ? c[5] : '')).toList();

  static List<Interval> _parseBeats(String csv) => _rows(csv).map((c) => Interval(int.parse(c[0]),
      int.parse(c[1]), c[4] == '1' ? 'usable' : 'unusable', double.tryParse(c[2]), double.tryParse(c[3]),
      c.length > 5 ? c[5] : '')).toList();

  static Iterable<List<String>> _rows(String csv) =>
      const LineSplitter().convert(csv).skip(1).where((l) => l.trim().isNotEmpty).map((l) => l.split(','));
}
