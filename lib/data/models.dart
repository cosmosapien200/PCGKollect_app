import 'dart:convert';

import '../core/protocol.dart';

/// Short human-readable form of a UUID (first 8 hex chars, upper case).
String shortId(String uuid) => uuid.replaceAll('-', '').substring(0, 8).toUpperCase();

class Dataset {
  final String id;
  String name;
  final DateTime createdAt;
  DateTime updatedAt;
  bool archived;
  Policy policy;
  int settingsRev;
  int? deviceRev; // last revision the device acknowledged
  DateTime? deviceSyncedAt;

  Dataset({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.archived = false,
    required this.policy,
    this.settingsRev = 1,
    this.deviceRev,
    this.deviceSyncedAt,
  });

  bool get deviceUpToDate => deviceRev == settingsRev;

  Map<String, Object?> toRow() => {
        'dataset_id': id,
        'name': name,
        'name_lc': name.trim().toLowerCase(),
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
        'archived': archived ? 1 : 0,
        'settings_json': jsonEncode(policy.toJson()),
        'settings_rev': settingsRev,
        'device_rev': deviceRev,
        'device_synced_at': deviceSyncedAt?.millisecondsSinceEpoch,
      };

  factory Dataset.fromRow(Map<String, Object?> r) => Dataset(
        id: r['dataset_id'] as String,
        name: r['name'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
        archived: (r['archived'] as int) == 1,
        policy: Policy.fromJson(jsonDecode(r['settings_json'] as String) as Map<String, dynamic>),
        settingsRev: r['settings_rev'] as int,
        deviceRev: r['device_rev'] as int?,
        deviceSyncedAt: r['device_synced_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['device_synced_at'] as int),
      );
}

/// Sex/gender options; configurable list with the required neutral choices.
const sexOptions = ['Female', 'Male', 'Intersex', 'Other', 'Prefer not to say', 'Unknown'];

class Subject {
  final String id;
  final String datasetId;
  String label; // participant code or name
  DateTime? dateOfBirth; // canonical when known
  double? ageYears; // used only when DOB is not collected
  String sex;
  double? heightCm, weightKg;
  Map<String, String> fields; // site, operator, position, auscultation location, ...
  String notes;
  final DateTime createdAt;

  Subject({
    required this.id,
    required this.datasetId,
    required this.label,
    this.dateOfBirth,
    this.ageYears,
    this.sex = 'Unknown',
    this.heightCm,
    this.weightKg,
    Map<String, String>? fields,
    this.notes = '',
    required this.createdAt,
  }) : fields = fields ?? {};

  /// Age in years at a given moment (reproducible from DOB; else the stored age).
  double? ageAt(DateTime t) {
    if (dateOfBirth != null) return t.difference(dateOfBirth!).inDays / 365.2425;
    return ageYears;
  }

  Map<String, Object?> toRow() => {
        'subject_id': id,
        'dataset_id': datasetId,
        'label': label,
        'dob': dateOfBirth?.toIso8601String().substring(0, 10),
        'age_years': ageYears,
        'sex': sex,
        'height_cm': heightCm,
        'weight_kg': weightKg,
        'fields_json': jsonEncode(fields),
        'notes': notes,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory Subject.fromRow(Map<String, Object?> r) => Subject(
        id: r['subject_id'] as String,
        datasetId: r['dataset_id'] as String,
        label: r['label'] as String,
        dateOfBirth: r['dob'] == null ? null : DateTime.parse(r['dob'] as String),
        ageYears: (r['age_years'] as num?)?.toDouble(),
        sex: r['sex'] as String,
        heightCm: (r['height_cm'] as num?)?.toDouble(),
        weightKg: (r['weight_kg'] as num?)?.toDouble(),
        fields: (jsonDecode(r['fields_json'] as String) as Map).map((k, v) => MapEntry(k as String, '$v')),
        notes: (r['notes'] ?? '') as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      );
}

/// App-side recording lifecycle (spec 01 §6.3) plus transfer state.
class RecState {
  static const draft = 'draft';
  static const pending = 'pending_device';
  static const armed = 'armed';
  static const recording = 'recording';
  static const finalizing = 'finalizing';
  static const complete = 'complete';
  static const incomplete = 'incomplete';
  static const interrupted = 'interrupted';
  static const cancelled = 'cancelled';
  static const failed = 'failed';
  static const storageFull = 'storage_full';
  static const disconnected = 'device_disconnected';

  static String label(String s) => switch (s) {
        draft => 'Draft',
        pending => 'Pending device',
        armed => 'Waiting for reliable audio',
        recording => 'Recording',
        finalizing => 'Finalizing',
        complete => 'Complete',
        incomplete => 'Incomplete',
        interrupted => 'Interrupted',
        cancelled => 'Cancelled',
        failed => 'Failed',
        storageFull => 'Device storage full',
        disconnected => 'Device disconnected',
        _ => s,
      };

  static bool terminal(String s) =>
      const {complete, incomplete, interrupted, cancelled, failed, storageFull}.contains(s);
}

class Transfer {
  static const notTransferred = 'not_transferred';
  static const verified = 'verified'; // on the phone, hash-checked
  static const error = 'error';
}

class Recording {
  final String id;
  final String datasetId;
  final String subjectId;
  final int takeIndex;
  String state;
  final DateTime createdAt;
  DateTime? startAt, endAt;
  double? durationMs, scoredMs, usableMs, usableRatio, longestRunMs, snrDb, meanConf, clippingRatio;
  int? usableBeats, totalBeats, longestRunBeats;
  String? firmwareRv, firmwareEsp, modelVersion, completion, completionReason, localDir, sha256, deviceId;
  int? settingsRev, fileSize;
  String transferState;
  String? transferError;
  DateTime? reviewedAt;
  String notes;
  String tags;
  Map<String, dynamic>? meta; // device meta.json
  Map<String, dynamic> checklist = {}; // take checklist (saved via AppDb.setChecklist)

  Recording({
    required this.id,
    required this.datasetId,
    required this.subjectId,
    required this.takeIndex,
    this.state = RecState.draft,
    required this.createdAt,
    this.transferState = Transfer.notTransferred,
    this.notes = '',
    this.tags = '',
  });

  bool get onPhone => transferState == Transfer.verified && localDir != null;

  Map<String, Object?> toRow() => {
        'recording_id': id,
        'dataset_id': datasetId,
        'subject_id': subjectId,
        'take_index': takeIndex,
        'state': state,
        'created_at': createdAt.millisecondsSinceEpoch,
        'start_at': startAt?.millisecondsSinceEpoch,
        'end_at': endAt?.millisecondsSinceEpoch,
        'duration_ms': durationMs,
        'scored_ms': scoredMs,
        'usable_ms': usableMs,
        'usable_ratio': usableRatio,
        'usable_beats': usableBeats,
        'total_beats': totalBeats,
        'longest_run_ms': longestRunMs,
        'longest_run_beats': longestRunBeats,
        'snr_db': snrDb,
        'mean_conf': meanConf,
        'clipping_ratio': clippingRatio,
        'fw_rv': firmwareRv,
        'fw_esp': firmwareEsp,
        'model_version': modelVersion,
        'settings_rev': settingsRev,
        'completion': completion,
        'completion_reason': completionReason,
        'local_dir': localDir,
        'sha256': sha256,
        'file_size': fileSize,
        'transfer_state': transferState,
        'transfer_error': transferError,
        'device_id': deviceId,
        'reviewed_at': reviewedAt?.millisecondsSinceEpoch,
        'notes': notes,
        'tags': tags,
        'meta_json': meta == null ? null : jsonEncode(meta),
      };

  factory Recording.fromRow(Map<String, Object?> r) {
    DateTime? t(String k) => r[k] == null ? null : DateTime.fromMillisecondsSinceEpoch(r[k] as int);
    double? d(String k) => (r[k] as num?)?.toDouble();
    return Recording(
      id: r['recording_id'] as String,
      datasetId: r['dataset_id'] as String,
      subjectId: r['subject_id'] as String,
      takeIndex: r['take_index'] as int,
      state: r['state'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      transferState: r['transfer_state'] as String,
      notes: (r['notes'] ?? '') as String,
      tags: (r['tags'] ?? '') as String,
    )
      ..startAt = t('start_at')
      ..endAt = t('end_at')
      ..durationMs = d('duration_ms')
      ..scoredMs = d('scored_ms')
      ..usableMs = d('usable_ms')
      ..usableRatio = d('usable_ratio')
      ..usableBeats = r['usable_beats'] as int?
      ..totalBeats = r['total_beats'] as int?
      ..longestRunMs = d('longest_run_ms')
      ..longestRunBeats = r['longest_run_beats'] as int?
      ..snrDb = d('snr_db')
      ..meanConf = d('mean_conf')
      ..clippingRatio = d('clipping_ratio')
      ..firmwareRv = r['fw_rv'] as String?
      ..firmwareEsp = r['fw_esp'] as String?
      ..modelVersion = r['model_version'] as String?
      ..settingsRev = r['settings_rev'] as int?
      ..completion = r['completion'] as String?
      ..completionReason = r['completion_reason'] as String?
      ..localDir = r['local_dir'] as String?
      ..sha256 = r['sha256'] as String?
      ..fileSize = r['file_size'] as int?
      ..transferError = r['transfer_error'] as String?
      ..deviceId = r['device_id'] as String?
      ..reviewedAt = t('reviewed_at')
      ..meta = r['meta_json'] == null ? null : jsonDecode(r['meta_json'] as String) as Map<String, dynamic>
      ..checklist = r['checklist_json'] == null ? {} : jsonDecode(r['checklist_json'] as String) as Map<String, dynamic>;
  }
}

/// Per-second quality window or per-beat annotation on the WAV sample axis.
class Interval {
  final int startSample, endSample;
  final String label; // usable | unusable | unscored (quality) ; OK/LOW_CONF/... (beats)
  final double? score;
  final double? pnoise;
  final String reason;
  const Interval(this.startSample, this.endSample, this.label, this.score, this.pnoise, this.reason);

  double get startS => startSample / kSampleRate;
  double get endS => endSample / kSampleRate;
}
