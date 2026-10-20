// Wire-level constants and models shared with the firmware (docs/PROTOCOL.md).
import 'dart:convert';
import 'dart:typed_data';

const int kCtrlProto = 1;
const int kSampleRate = 8000;

String _uuid(int n) =>
    '7a1c00${n.toRadixString(16).padLeft(2, '0')}-5b6e-4e8a-9c1f-50434b4f4c54';

/// BLE GATT service and characteristics (PROTOCOL.md §3).
class Gatt {
  static final String service = _uuid(1);
  static final String info = _uuid(2);
  static final String command = _uuid(3);
  static final String response = _uuid(4);
  static final String telemetry = _uuid(5);
  static final String wifi = _uuid(6);
}

/// Splits a JSON message into BLE fragments: HDR (bit7 FIRST, bit6 LAST, bits0-5 index) + data.
List<Uint8List> fragment(String json, int mtu) {
  final data = utf8.encode(json);
  // <= 244 B per fragment: some phones drop larger GATT packets despite a 517 MTU
  final chunk = (mtu - 3 - 1).clamp(19, 243);
  final out = <Uint8List>[];
  var off = 0, idx = 0;
  do {
    final n = (data.length - off).clamp(0, chunk);
    final hdr = (off == 0 ? 0x80 : 0) | (off + n >= data.length ? 0x40 : 0) | (idx & 0x3F);
    out.add(Uint8List.fromList([hdr, ...data.sublist(off, off + n)]));
    off += n;
    idx++;
  } while (off < data.length);
  return out;
}

/// Reassembles notification fragments into complete JSON objects.
class Reassembler {
  final void Function(Map<String, dynamic>) onMessage;
  final _buf = BytesBuilder();
  Reassembler(this.onMessage);

  void add(Uint8List value) {
    if (value.isEmpty) return;
    final hdr = value[0];
    if (hdr & 0x80 != 0) _buf.clear();
    _buf.add(value.sublist(1));
    if (hdr & 0x40 != 0) {
      final bytes = _buf.takeBytes();
      try {
        final m = jsonDecode(utf8.decode(bytes));
        if (m is Map<String, dynamic>) onMessage(m);
      } catch (_) {
        // corrupt message: dropped; the request times out and is retried
      }
    }
  }
}

/// Response statuses (PROTOCOL.md §2).
class Status {
  static const ok = 'OK';
  static const rejected = 'REJECTED';
  static const busy = 'BUSY';
  static const invalid = 'INVALID';
  static const timeout = 'TIMEOUT';
}

/// A non-OK answer from the device (or a transport failure).
class DeviceError implements Exception {
  final String status;
  final String code;
  final String? field;
  DeviceError(this.status, this.code, {this.field});

  /// Human-readable explanation for the operator.
  String get message => switch (code) {
        'DATASET_MISMATCH' => 'The device has a different active dataset. Activate this dataset first.',
        'SETTINGS_MISMATCH' => 'The device has an older settings revision. Activate the dataset again.',
        'SESSION_ACTIVE' => 'A recording session is active on the device.',
        'MODEL_UNAVAILABLE' => 'The quality model is not loaded on the device.',
        'STORAGE_FULL' => 'Device storage is full. Sync and delete transferred recordings.',
        'DUPLICATE_RECORDING' => 'This recording ID already exists on the device.',
        'NOT_VERIFIED' => 'The recording has not been verified on the phone yet.',
        'HASH_MISMATCH' => 'The file hash does not match the device copy.',
        'NOT_BONDED' => 'This action needs a paired (bonded) Bluetooth connection.',
        'FORCE_DISABLED' => 'The device does not allow deleting untransferred recordings.',
        'BLE_DISCONNECTED' => 'The device is not connected.',
        'BLE_WRITE_FAILED' => 'Sending to the device over Bluetooth failed.',
        'LINK_DOWN' => 'The Bluetooth module cannot reach the recorder board.',
        'RV_TIMEOUT' || 'BLE_TIMEOUT' || 'USB_TIMEOUT' => 'The device did not answer in time.',
        'USB_DISCONNECTED' => 'The USB cable was disconnected.',
        'USB_WRITE_FAILED' || 'USB_WRITE' => 'Sending to the device over USB failed.',
        'USB_PERMISSION' => 'USB access was not allowed. Plug the cable in again and tap Allow.',
        'USB_NOT_FOUND' => 'The device is no longer plugged in.',
        'USB_OPEN' => 'The phone could not open the device\'s USB connection.',
        'USB_NO_ANSWER' => 'The device is plugged in but its recorder firmware does not answer on USB. '
            'It may still be starting (wait ~20 s) or need a firmware update.',
        'SETTINGS' => 'The device rejected setting "${field ?? '?'}".',
        _ => '$status: $code',
      };

  @override
  String toString() => message;
}

/// Device session states (PROTOCOL.md §2.2).
enum DeviceState {
  idle, configured, armed, recording, finalizing, done, incomplete, cancelled, interrupted,
  storageFull, modelError, linkDegraded, unknown;

  static DeviceState parse(String? s) => switch (s) {
        'IDLE' => idle,
        'CONFIGURED' => configured,
        'ARMED' => armed,
        'RECORDING' => recording,
        'FINALIZING' => finalizing,
        'DONE' => done,
        'INCOMPLETE' => incomplete,
        'CANCELLED' => cancelled,
        'INTERRUPTED' => interrupted,
        'STORAGE_FULL' => storageFull,
        'MODEL_ERROR' => modelError,
        'LINK_DEGRADED' => linkDegraded,
        _ => unknown,
      };

  bool get isActive => this == armed || this == recording || this == finalizing;
}

/// Live status / telemetry from the RV1103 (via the ESP32).
class DeviceStatus {
  final DeviceState state;
  final String recordingId;
  final int? quality; // window_quality_score 0-100, null = unavailable
  final String qualityDef;
  final double? beatConf;
  final int elapsedMs, scoredMs, usableMs, requiredMs;
  final int usableBeats, requiredBeats, runBeats, runMs, longestRunBeats, longestRunMs, armMs;
  final String reason;
  final int settingsRev;
  final String datasetId;
  final int crcErrors, seqGaps, overruns;
  final bool linkUp;
  final DateTime received;

  DeviceStatus.fromJson(Map<String, dynamic> j)
      : state = DeviceState.parse(j['state'] as String?),
        recordingId = (j['rid'] ?? '') as String,
        quality = (j['q'] as num?)?.toInt(),
        qualityDef = (j['qdef'] ?? '') as String,
        beatConf = (j['bc'] as num?)?.toDouble(),
        elapsedMs = _i(j['el_ms']),
        scoredMs = _i(j['sc_ms']),
        usableMs = _i(j['us_ms']),
        requiredMs = _i(j['req_ms']),
        usableBeats = _i(j['ub']),
        requiredBeats = _i(j['req_b']),
        runBeats = _i(j['run_b']),
        runMs = _i(j['run_ms']),
        longestRunBeats = _i(j['lrun_b']),
        longestRunMs = _i(j['lrun_ms']),
        armMs = _i(j['arm_ms']),
        reason = (j['rs'] ?? '') as String,
        settingsRev = _i(j['rev']),
        datasetId = (j['ds'] ?? '') as String,
        crcErrors = _i((j['link'] as Map?)?['crc']),
        seqGaps = _i((j['link'] as Map?)?['gaps']),
        overruns = _i((j['link'] as Map?)?['ovr']),
        linkUp = j['link_up'] != false,
        received = DateTime.now();

  static int _i(Object? v) => (v as num?)?.toInt() ?? 0;
}

/// ESP32 Wi-Fi (phone hotspot) state.
class WifiStatus {
  final String state; // off | connecting | connected | failed
  final String ssid, ip, error;
  final int port, rssi;
  final String? token;
  final bool httpReady;

  WifiStatus.fromJson(Map<String, dynamic> j)
      : state = (j['state'] ?? 'off') as String,
        ssid = (j['ssid'] ?? '') as String,
        ip = (j['ip'] ?? '') as String,
        error = (j['err'] ?? '') as String,
        port = (j['port'] as num?)?.toInt() ?? 0,
        rssi = (j['rssi'] as num?)?.toInt() ?? 0,
        token = j['token'] as String?,
        httpReady = j['http_ready'] == true;

  const WifiStatus.off()
      : state = 'off', ssid = '', ip = '', error = '', port = 0, rssi = 0, token = null, httpReady = false;

  bool get connected => state == 'connected' && ip.isNotEmpty && port > 0;
}

/// One recording in the device manifest.
class ManifestItem {
  final String recordingId, datasetId, subjectId, completion, transfer;
  final int take, startUtcMs;
  final double durationMs, usableMs;
  final Map<String, ({int size, String sha256})> files;

  ManifestItem.fromJson(Map<String, dynamic> j)
      : recordingId = j['recording_id'] as String,
        datasetId = (j['dataset_id'] ?? '') as String,
        subjectId = (j['subject_id'] ?? '') as String,
        completion = (j['completion'] ?? '') as String,
        transfer = (j['transfer'] ?? 'available') as String,
        take = (j['take'] as num?)?.toInt() ?? 0,
        startUtcMs = (j['start_utc_ms'] as num?)?.toInt() ?? 0,
        durationMs = (j['duration_ms'] as num?)?.toDouble() ?? 0,
        usableMs = (j['usable_ms'] as num?)?.toDouble() ?? 0,
        files = {
          for (final e in ((j['files'] ?? {}) as Map).entries)
            e.key as String: (
              size: ((e.value as Map)['size'] as num).toInt(),
              sha256: (e.value as Map)['sha256'] as String,
            ),
        };
}

/// Dataset recording policy (PROTOCOL.md §2.1). Ranges mirror the RV1103 validation.
class Policy {
  double confThreshold;
  bool rhythmCheck;
  double autostartS;
  double targetUsableS;
  int targetUsableBeats;
  int minRunBeats;
  double minRunS;
  double maxDurationS;
  double telemetryHz;

  Policy({
    this.confThreshold = 0.80,
    this.rhythmCheck = true,
    this.autostartS = 2.0,
    this.targetUsableS = 30,
    this.targetUsableBeats = 0,
    this.minRunBeats = 0,
    this.minRunS = 0,
    this.maxDurationS = 180,
    this.telemetryHz = 2,
  });

  static const ranges = {
    'conf_threshold': (0.50, 0.99),
    'autostart_s': (0.0, 10.0),
    'target_usable_s': (0.0, 600.0),
    'target_usable_beats': (0.0, 2000.0),
    'min_run_beats': (0.0, 200.0),
    'min_run_s': (0.0, 300.0),
    'max_duration_s': (10.0, 1800.0),
    'telemetry_hz': (0.5, 5.0),
  };

  Map<String, dynamic> toJson() => {
        'conf_threshold': confThreshold,
        'rhythm_check': rhythmCheck,
        'autostart_s': autostartS,
        'target_usable_s': targetUsableS,
        'target_usable_beats': targetUsableBeats,
        'min_run_beats': minRunBeats,
        'min_run_s': minRunS,
        'max_duration_s': maxDurationS,
        'telemetry_hz': telemetryHz,
      };

  factory Policy.fromJson(Map<String, dynamic> j) {
    double d(String k, double def) => (j[k] as num?)?.toDouble() ?? def;
    return Policy(
      confThreshold: d('conf_threshold', 0.80),
      rhythmCheck: j['rhythm_check'] as bool? ?? true,
      autostartS: d('autostart_s', 2),
      targetUsableS: d('target_usable_s', 30),
      targetUsableBeats: d('target_usable_beats', 0).toInt(),
      minRunBeats: d('min_run_beats', 0).toInt(),
      minRunS: d('min_run_s', 0),
      maxDurationS: d('max_duration_s', 180),
      telemetryHz: d('telemetry_hz', 2),
    );
  }

  Policy copy() => Policy.fromJson(toJson());

  /// Returns a list of problems (empty = valid). Same rules as the firmware.
  List<String> validate() {
    final errs = <String>[];
    toJson().forEach((k, v) {
      final r = ranges[k];
      if (r != null && v is num && (v < r.$1 || v > r.$2)) {
        errs.add('$k must be between ${r.$1} and ${r.$2}');
      }
    });
    if (targetUsableS <= 0 && targetUsableBeats <= 0) {
      errs.add('Set a usable-time target or a usable-beat target');
    }
    if (minRunS > 0 && targetUsableS > 0 && minRunS > targetUsableS) {
      errs.add('Minimum contiguous time cannot exceed the total usable-time target');
    }
    if (minRunBeats > 0 && targetUsableBeats > 0 && minRunBeats > targetUsableBeats) {
      errs.add('Minimum consecutive beats cannot exceed the total usable-beat target');
    }
    if (maxDurationS <= targetUsableS) {
      errs.add('Maximum duration must be longer than the usable-time target');
    }
    return errs;
  }
}
