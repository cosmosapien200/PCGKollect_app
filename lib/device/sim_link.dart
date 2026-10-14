import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../core/protocol.dart';
import 'device_link.dart';

/// In-app simulated PCGKolect device for emulator/UI testing. Mirrors the RV1103
/// session engine semantics (policy validation, auto-start after contiguous usable
/// beats, completion targets, ack-before-delete) with synthetic heart sounds.
/// Never used for real data: recordings it produces are clearly synthetic.
class SimLink implements DeviceLink {
  @override
  final String name = 'PCGKolect-SIM';
  @override
  final String deviceId = 'pcgk-simulated';

  final _state = StreamController<LinkState>.broadcast();
  final _tlm = StreamController<DeviceStatus>.broadcast();
  final _wifi = StreamController<WifiStatus>.broadcast();
  final _rng = Random(7);
  LinkState _current = LinkState.disconnected;
  Timer? _timer;

  // device state
  String _st = 'IDLE', _reason = '';
  String _dsId = '', _dsName = '';
  int _rev = 0;
  Map<String, dynamic> _policy = {};
  String _rid = '', _subject = '';
  int _take = 0;
  double _elapsed = 0, _usable = 0, _arm = 0, _run = 0, _lrun = 0, _nextBeat = 0;
  int _ub = 0, _tb = 0, _runB = 0, _lrunB = 0;
  bool _forced = false;
  int? _q;
  double? _bc;
  final _beats = <List<num>>[]; // start, end, conf, usable
  final store = <String, _SimRec>{};
  String _wifiState = 'off', _ssid = '';
  final _token = List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  @override
  Stream<LinkState> get state => _state.stream;
  @override
  LinkState get currentState => _current;
  @override
  Stream<DeviceStatus> get telemetry => _tlm.stream;
  @override
  Stream<WifiStatus> get wifi => _wifi.stream;

  Future<void> connect() async {
    _current = LinkState.connecting;
    _state.add(_current);
    await Future.delayed(const Duration(milliseconds: 600));
    _current = LinkState.connected;
    _state.add(_current);
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick(0.5));
  }

  @override
  Future<void> disconnect() async {
    _timer?.cancel();
    _current = LinkState.disconnected;
    _state.add(_current);
  }

  double get _thr => (_policy['conf_threshold'] as num?)?.toDouble() ?? 0.8;
  double _p(String k, double d) => (_policy[k] as num?)?.toDouble() ?? d;

  void _tick(double dt) {
    final active = _st == 'ARMED' || _st == 'RECORDING';
    if (active) {
      // synthetic beat stream: ~70 bpm, a noisy stretch every ~20 s
      _nextBeat -= dt;
      final noisy = (_elapsed % 20) > 15;
      _q = noisy ? 10 + _rng.nextInt(30) : 80 + _rng.nextInt(15);
      while (_nextBeat <= 0) {
        _nextBeat += 0.85;
        final conf = noisy ? 0.4 + _rng.nextDouble() * 0.3 : 0.76 + _rng.nextDouble() * 0.2;
        _onBeat(conf, 0.85);
      }
      if (_st == 'RECORDING') {
        _elapsed += dt;
        if (_elapsed >= _p('max_duration_s', 180)) _finish('incomplete', 'INSUFFICIENT_USABLE_TIME');
      }
    } else {
      _q = null;
    }
    _emit();
  }

  void _onBeat(double conf, double dur) {
    final usable = conf >= _thr;
    _bc = conf;
    if (_st == 'ARMED') {
      _arm = usable ? _arm + dur : 0;
      if (_arm >= _p('autostart_s', 2)) _startRec(false);
      return;
    }
    if (_st != 'RECORDING') return;
    _tb++;
    final start = _elapsed;
    _beats.add([start, start + dur, conf, usable ? 1 : 0]);
    if (usable) {
      _ub++;
      _usable += dur;
      _runB++;
      _run += dur;
      _lrunB = max(_lrunB, _runB);
      _lrun = max(_lrun, _run);
    } else {
      _runB = 0;
      _run = 0;
    }
    final tS = _p('target_usable_s', 30), tB = _p('target_usable_beats', 0);
    final mB = _p('min_run_beats', 0), mS = _p('min_run_s', 0);
    if ((tS <= 0 || _usable >= tS) && (tB <= 0 || _ub >= tB) && (mB <= 0 || _lrunB >= mB) && (mS <= 0 || _lrun >= mS)) {
      _finish('complete', 'TARGET_REACHED');
    }
  }

  void _startRec(bool forced) {
    _st = 'RECORDING';
    _reason = forced ? 'FORCE_START' : 'RELIABLE_AUDIO';
    _forced = forced;
    _elapsed = forced ? 0 : _arm;
    _usable = forced ? 0 : _arm;
    _ub = forced ? 0 : (_arm / 0.85).round();
    _tb = _ub;
    _run = _usable;
    _runB = _ub;
    _lrun = _run;
    _lrunB = _runB;
    _beats.clear();
    for (var i = 0; i < _ub; i++) {
      _beats.add([i * 0.85, (i + 1) * 0.85, 0.85, 1]);
    }
  }

  void _finish(String completion, String reason) {
    _st = 'FINALIZING';
    _emit();
    store[_rid] = _SimRec.build(this, completion, reason);
    _st = completion == 'complete' ? 'DONE' : 'INCOMPLETE';
    _reason = reason;
  }

  Map<String, dynamic> _status() => {
        'ev': 'status', 'state': _st, 'rid': _rid, 'q': _q, 'qdef': 'wqs_v2', 'bc': _bc,
        'el_ms': (_elapsed * 1000).round(), 'sc_ms': (_elapsed * 1000).round(), 'us_ms': (_usable * 1000).round(),
        'req_ms': (_p('target_usable_s', 30) * 1000).round(), 'ub': _ub, 'req_b': _p('target_usable_beats', 0).round(),
        'run_b': _runB, 'run_ms': (_run * 1000).round(), 'lrun_b': _lrunB, 'lrun_ms': (_lrun * 1000).round(),
        'arm_ms': (_arm * 1000).round(), 'rs': _reason, 'rev': _rev, 'ds': _dsId,
        'link': {'ok': 0, 'crc': 0, 'gaps': 0, 'ovr': 0}, 'src': 'rv', 'link_up': true,
      };

  void _emit() => _tlm.add(DeviceStatus.fromJson(_status()));

  Map<String, dynamic> _wifiJson(bool token) => {
        'state': _wifiState, 'ssid': _ssid,
        if (_wifiState == 'connected') 'ip': '127.0.0.1',
        if (_wifiState == 'connected') 'port': 8080,
        if (token) 'token': _token,
        'rssi': _wifiState == 'connected' ? -48 : 0,
        'http_ready': _wifiState == 'connected',
      };

  @override
  Future<Map<String, dynamic>> call(String op,
      [Map<String, dynamic> args = const {}, Duration timeout = const Duration(seconds: 8)]) async {
    await Future.delayed(const Duration(milliseconds: 120));
    Never fail(String st, String err) => throw DeviceError(st, err);
    final ok = <String, dynamic>{'st': 'OK'};
    switch (op) {
      case 'hello':
        return {
          ...ok, 'device_id': deviceId, 'esp_fw': 'sim', 'rv_fw': 'sim', 'ctrl_proto': 1,
          'model': {'version': 'segnet-v2-w8a8 (simulated)', 'sha256': '', 'loaded': true},
          'dataset': {'id': _dsId, 'name': _dsName, 'rev': _rev}, 'bonded': true, 'link_up': true,
        };
      case 'status':
        return {...ok, ..._status()};
      case 'set_dataset':
        if (_st == 'ARMED' || _st == 'RECORDING') fail('BUSY', 'SESSION_ACTIVE');
        _dsId = args['dataset_id'] as String;
        _dsName = args['name'] as String;
        _rev = args['rev'] as int;
        _policy = Map<String, dynamic>.from(args['settings'] as Map);
        final errs = Policy.fromJson(_policy).validate();
        if (errs.isNotEmpty) fail('INVALID', 'SETTINGS');
        _st = 'CONFIGURED';
        return {...ok, 'rev': _rev, 'settings': _policy};
      case 'prepare':
        if (_st == 'ARMED' || _st == 'RECORDING') {
          if (args['recording_id'] == _rid) return {...ok, 'state': _st};
          fail('BUSY', 'SESSION_ACTIVE');
        }
        if (args['dataset_id'] != _dsId) fail('REJECTED', 'DATASET_MISMATCH');
        if (args['rev'] != _rev) fail('REJECTED', 'SETTINGS_MISMATCH');
        if (store.containsKey(args['recording_id'])) fail('REJECTED', 'DUPLICATE_RECORDING');
        _rid = args['recording_id'] as String;
        _subject = args['subject_id'] as String;
        _take = args['take'] as int? ?? 1;
        _elapsed = _usable = _arm = _run = _lrun = 0;
        _ub = _tb = _runB = _lrunB = 0;
        _st = 'ARMED';
        _reason = 'WAITING_FOR_QUALITY';
        return {...ok, 'state': _st};
      case 'force_start':
        if (args['recording_id'] != _rid) fail('REJECTED', 'UNKNOWN_RECORDING');
        if (_st == 'ARMED') _startRec(true);
        return {...ok, 'state': _st};
      case 'stop':
        if (args['recording_id'] != _rid) fail('REJECTED', 'UNKNOWN_RECORDING');
        if (_st == 'ARMED') {
          _st = 'CANCELLED';
        } else if (_st == 'RECORDING') {
          _finish('incomplete', 'USER_STOPPED');
        }
        return {...ok, 'state': _st};
      case 'cancel':
        if (_st == 'RECORDING') fail('REJECTED', 'RECORDING_ACTIVE');
        if (_st == 'ARMED') _st = 'CANCELLED';
        return {...ok, 'state': _st};
      case 'ack':
        final r = store[args['recording_id']] ?? fail('REJECTED', 'NOT_FOUND');
        if (args['sha256'] != r.sha['audio']) fail('REJECTED', 'HASH_MISMATCH');
        r.verified = true;
        return {...ok, 'transfer_state': 'verified'};
      case 'delete':
        final r = store[args['recording_id']];
        if (r == null) return {...ok, 'deleted': true};
        if (!r.verified || args['sha256'] != r.sha['audio']) fail('REJECTED', 'NOT_VERIFIED');
        store.remove(args['recording_id']);
        return {...ok, 'deleted': true};
      case 'clear':
        final kept = store.entries.where((e) => !e.value.verified).map((e) => {'recording_id': e.key, 'err': 'NOT_VERIFIED'}).toList();
        final del = store.keys.where((k) => store[k]!.verified).toList();
        store.removeWhere((k, v) => v.verified);
        return {...ok, 'deleted': del, 'kept': kept};
      case 'stats':
        final bytes = store.values.fold<int>(0, (a, r) => a + r.files['audio']!.length);
        return {
          ...ok, 'uptime_s': 3600, 'mem_kb': {'total': 33820, 'available': 18000}, 'cpu_pct': 6.0,
          'npu_pct': 'unsupported', 'temp_c': 41.0,
          'storage': {'total_bytes': 5800000000, 'free_bytes': 5800000000 - bytes, 'est_remaining_s': 340000},
          'recordings': {'count': store.length, 'pending_transfer': store.values.where((r) => !r.verified).length,
            'incomplete': store.values.where((r) => r.completion != 'complete').length},
          'uart': {'baud': 4000000, 'frames_ok': 36000, 'crc_errors': 0, 'seq_gaps': 0, 'overruns': 0},
          'model': {'loaded': true, 'version': 'segnet-v2-w8a8 (simulated)'},
        };
      case 'wifi_set':
        _ssid = args['ssid'] as String;
        _wifiState = 'connecting';
        _wifi.add(WifiStatus.fromJson(_wifiJson(false)));
        Timer(const Duration(seconds: 2), () {
          _wifiState = 'connected';
          _wifi.add(WifiStatus.fromJson(_wifiJson(false)));
        });
        return {...ok, 'state': 'connecting'};
      case 'wifi_forget':
        _wifiState = 'off';
        _ssid = '';
        _wifi.add(WifiStatus.fromJson(_wifiJson(false)));
        return ok;
      case 'wifi_status':
        return {...ok, ..._wifiJson(true)};
      case 'logs':
        return {...ok, 'lines': ['[sim] simulated device log']};
    }
    fail('UNSUPPORTED', 'UNKNOWN_OP');
  }

  @override
  FileSource? fileSource(WifiStatus w) => w.connected ? _SimFiles(this) : null;
}

class _SimFiles implements FileSource {
  final SimLink sim;
  _SimFiles(this.sim);

  @override
  Future<void> health() async {}

  @override
  Future<List<ManifestItem>> manifest() async => sim.store.values.map((r) => ManifestItem.fromJson(r.item())).toList();

  @override
  Future<String?> download(String recordingId, String kind, File dest, {void Function(int, int)? progress}) async {
    final r = sim.store[recordingId] ?? (throw TransferException('not found'));
    final bytes = r.files[kind]!;
    final have = await dest.exists() ? await dest.length() : 0;
    final sink = dest.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
    for (var off = have; off < bytes.length; off += 32768) {
      final end = min(off + 32768, bytes.length);
      sink.add(bytes.sublist(off, end));
      progress?.call(end, bytes.length);
      await Future.delayed(const Duration(milliseconds: 15));
    }
    await sink.close();
    return r.sha[kind];
  }
}

/// A finished simulated recording with real WAV bytes and sidecars.
class _SimRec {
  final String rid, ds, subject, completion;
  final int take, startMs;
  final double durationMs, usableMs;
  final Map<String, Uint8List> files = {};
  final Map<String, String> sha = {};
  bool verified = false;

  _SimRec(this.rid, this.ds, this.subject, this.completion, this.take, this.startMs, this.durationMs, this.usableMs);

  static _SimRec build(SimLink s, String completion, String reason) {
    final dur = max(s._elapsed, 1.0);
    final r = _SimRec(s._rid, s._dsId, s._subject, completion, s._take,
        DateTime.now().millisecondsSinceEpoch - (dur * 1000).round(), dur * 1000, s._usable * 1000);
    final n = (dur * kSampleRate).round();
    final pcm = Int16List(n);
    final rnd = Random(r.rid.hashCode);
    for (final b in s._beats) {
      final noisy = b[3] == 0;
      final s1 = (b[0] * kSampleRate).round(), s2 = s1 + (0.32 * kSampleRate).round();
      for (final (at, f, amp) in [(s1, 55.0, 9000.0), (s2, 75.0, 6000.0)]) {
        for (var i = 0; i < 0.06 * kSampleRate && at + i < n; i++) {
          final t = i / kSampleRate;
          pcm[at + i] += (amp * exp(-t * 60) * sin(2 * pi * f * t)).round();
        }
      }
      if (noisy) {
        final a = s1, e = min(n, (b[1] * kSampleRate).round());
        for (var i = a; i < e; i++) {
          pcm[i] += (rnd.nextDouble() * 2 - 1) * 5000 ~/ 1;
        }
      }
    }
    for (var i = 0; i < n; i++) {
      pcm[i] += (rnd.nextDouble() * 2 - 1) * 150 ~/ 1;
    }
    final wav = BytesBuilder();
    final hdr = ByteData(44);
    void str(int o, String v) => v.codeUnits.asMap().forEach((i, c) => hdr.setUint8(o + i, c));
    str(0, 'RIFF');
    hdr.setUint32(4, 36 + n * 2, Endian.little);
    str(8, 'WAVEfmt ');
    hdr.setUint32(16, 16, Endian.little);
    hdr.setUint16(20, 1, Endian.little);
    hdr.setUint16(22, 1, Endian.little);
    hdr.setUint32(24, kSampleRate, Endian.little);
    hdr.setUint32(28, kSampleRate * 2, Endian.little);
    hdr.setUint16(32, 2, Endian.little);
    hdr.setUint16(34, 16, Endian.little);
    str(36, 'data');
    hdr.setUint32(40, n * 2, Endian.little);
    wav.add(hdr.buffer.asUint8List());
    wav.add(pcm.buffer.asUint8List());
    r.files['audio'] = wav.toBytes();

    final beats = StringBuffer('start_sample,end_sample,conf,pnoise,usable,reason\n');
    for (final b in s._beats) {
      final u = b[3] == 1;
      beats.writeln('${(b[0] * kSampleRate).round()},${(b[1] * kSampleRate).round()},${b[2].toStringAsFixed(4)},'
          '${u ? 0.05 : 0.6},${u ? 1 : 0},${u ? 'OK' : 'LOW_CONF'}');
    }
    r.files['beats'] = Uint8List.fromList(utf8.encode(beats.toString()));
    final q = StringBuffer('start_sample,end_sample,label,score,pnoise,reason\n');
    for (var a = 0; a < n; a += kSampleRate) {
      final e = min(a + kSampleRate, n);
      final cov = s._beats.where((b) => b[3] == 1 && b[1] * kSampleRate > a && b[0] * kSampleRate < e).isNotEmpty;
      q.writeln('$a,$e,${cov ? 'usable' : 'unusable'},${cov ? 88 : 30},${cov ? 0.05 : 0.7},${cov ? 'OK' : 'NOISY'}');
    }
    r.files['quality'] = Uint8List.fromList(utf8.encode(q.toString()));
    r.sha['audio'] = sha256.convert(r.files['audio']!).toString();
    final meta = {
      'schema_version': 1, 'recording_id': r.rid, 'dataset_id': r.ds, 'dataset_name': s._dsName,
      'subject_id': r.subject, 'take_index': r.take, 'start_utc_ms': r.startMs,
      'start_time_utc': DateTime.fromMillisecondsSinceEpoch(r.startMs, isUtc: true).toIso8601String(),
      'audio': {'path': 'audio.wav', 'sample_rate_hz': 8000, 'channels': 1, 'bits_per_sample': 16,
        'sample_count': n, 'sha256': r.sha['audio']},
      'quality': {'score_definition': 'wqs_v2', 'model_version': 'segnet-v2-w8a8 (simulated)', 'policy_revision': s._rev,
        'policy': s._policy, 'captured_duration_ms': r.durationMs, 'scored_duration_ms': r.durationMs,
        'usable_duration_ms': r.usableMs, 'usable_ratio': r.usableMs / r.durationMs, 'usable_beats': s._ub,
        'total_beats': s._tb, 'longest_usable_run_ms': s._lrun * 1000, 'longest_usable_run_beats': s._lrunB,
        'mean_beat_conf': 0.84, 'snr_db': null, 'clipping_ratio': 0.0},
      'transport': {'uart_frames_ok': 0, 'uart_crc_errors': 0, 'uart_sequence_gaps': 0, 'audio_buffer_overruns': 0},
      'gaps': [], 'completion_state': completion, 'completion_reason': reason, 'force_started': s._forced,
      'firmware': {'rv': 'sim'}, 'simulated': true,
    };
    r.files['meta'] = Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(meta)));
    for (final k in ['beats', 'quality', 'meta']) {
      r.sha[k] = sha256.convert(r.files[k]!).toString();
    }
    return r;
  }

  Map<String, dynamic> item() => {
        'recording_id': rid, 'dataset_id': ds, 'subject_id': subject, 'take': take, 'start_utc_ms': startMs,
        'duration_ms': durationMs, 'usable_ms': usableMs, 'completion': completion,
        'transfer': verified ? 'verified' : 'available',
        'files': {for (final k in files.keys) k: {'size': files[k]!.length, 'sha256': sha[k]}},
      };
}
