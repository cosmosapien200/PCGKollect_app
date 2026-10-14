import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import '../core/protocol.dart';
import 'device_link.dart';
import 'http_files.dart';

/// Scan for PCGKolect devices (name prefix + service UUID in the scan response).
class BleScanner {
  static Future<bool> ensurePermissions() async {
    try {
      await UniversalBle.requestPermissions();
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> bluetoothOn() async =>
      await UniversalBle.getBluetoothAvailabilityState() == AvailabilityState.poweredOn;

  /// Emits devices as they are found; stops after [timeout].
  static Stream<BleDevice> scan({Duration timeout = const Duration(seconds: 8)}) {
    final ctl = StreamController<BleDevice>();
    final seen = <String>{};
    late StreamSubscription<BleDevice> sub;
    sub = UniversalBle.scanStream.listen((d) {
      final name = d.name ?? '';
      if (name.startsWith('PCGKolect') && seen.add(d.deviceId)) ctl.add(d);
    });
    UniversalBle.startScan(scanFilter: ScanFilter(withNamePrefix: ['PCGKolect'])).catchError((e) {
      ctl.addError(e);
    });
    Timer(timeout, () async {
      await UniversalBle.stopScan().catchError((_) {});
      await sub.cancel();
      await ctl.close();
    });
    return ctl.stream;
  }
}

class BleLink implements DeviceLink {
  @override
  final String deviceId;
  @override
  final String name;

  final _state = StreamController<LinkState>.broadcast();
  final _tlm = StreamController<DeviceStatus>.broadcast();
  final _wifi = StreamController<WifiStatus>.broadcast();
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _subs = <StreamSubscription>[];
  LinkState _current = LinkState.disconnected;
  int _mtu = 23;
  int _nextId = DateTime.now().millisecondsSinceEpoch & 0xFFFFFF;
  Future<void> _writeChain = Future.value();

  BleLink(this.deviceId, this.name);

  @override
  Stream<LinkState> get state => _state.stream;
  @override
  LinkState get currentState => _current;
  @override
  Stream<DeviceStatus> get telemetry => _tlm.stream;
  @override
  Stream<WifiStatus> get wifi => _wifi.stream;

  void _set(LinkState s) {
    _current = s;
    _state.add(s);
  }

  /// Connect, bond (system pairing dialog on Android), raise the MTU and subscribe.
  Future<void> connect() async {
    _set(LinkState.connecting);
    try {
      // A link dropped from the device side (reset, power cut) can leave stale state in
      // the plugin/Android stack that makes the next connect fail at once: clear it first
      // and retry once.
      try {
        await UniversalBle.disconnect(deviceId, timeout: const Duration(seconds: 3));
      } catch (_) {}
      try {
        await UniversalBle.connect(deviceId, timeout: const Duration(seconds: 20));
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 800));
        await UniversalBle.connect(deviceId, timeout: const Duration(seconds: 20));
      }
      _subs.add(UniversalBle.connectionStream(deviceId).listen((up) {
        if (!up) {
          _failPending('BLE_DISCONNECTED');
          _set(LinkState.disconnected);
        }
      }));
      await UniversalBle.discoverServices(deviceId);
      if (Platform.isAndroid) {
        try {
          _mtu = await UniversalBle.requestMtu(deviceId, 517);
        } catch (_) {
          _mtu = 23;
        }
        // The command characteristic needs an encrypted, bonded link.
        if (await UniversalBle.isPaired(deviceId) != true) {
          await UniversalBle.pair(deviceId);
        }
      } else {
        _mtu = 185;
      }
      final rsp = Reassembler(_onResponse);
      final tlm = Reassembler((m) => _tlm.add(DeviceStatus.fromJson(m)));
      final wifi = Reassembler((m) => _wifi.add(WifiStatus.fromJson(m)));
      _subs.add(UniversalBle.characteristicValueStream(deviceId, Gatt.response).listen(rsp.add));
      _subs.add(UniversalBle.characteristicValueStream(deviceId, Gatt.telemetry).listen(tlm.add));
      _subs.add(UniversalBle.characteristicValueStream(deviceId, Gatt.wifi).listen(wifi.add));
      for (final c in [Gatt.response, Gatt.telemetry, Gatt.wifi]) {
        await UniversalBle.subscribeNotifications(deviceId, Gatt.service, c);
      }
      _set(LinkState.connected);
    } catch (e) {
      _set(LinkState.error);
      await disconnect();
      rethrow;
    }
  }

  void _onResponse(Map<String, dynamic> m) {
    final id = (m['id'] as num?)?.toInt();
    final c = id == null ? null : _pending.remove(id);
    if (c != null && !c.isCompleted) c.complete(m);
  }

  void _failPending(String code) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(DeviceError(Status.timeout, code));
    }
    _pending.clear();
  }

  @override
  Future<Map<String, dynamic>> call(String op,
      [Map<String, dynamic> args = const {}, Duration timeout = const Duration(seconds: 8)]) async {
    if (_current != LinkState.connected) throw DeviceError('ERROR', 'BLE_DISCONNECTED');
    final id = _nextId++ & 0x7FFFFFFF;
    final req = {'v': kCtrlProto, 'id': id, 'op': op, 'utc_ms': DateTime.now().millisecondsSinceEpoch, ...args};
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    // Serialise writes so fragments of two messages never interleave.
    final frags = fragment(jsonEncode(req), _mtu);
    _writeChain = _writeChain.then((_) async {
      for (final f in frags) {
        await UniversalBle.write(deviceId, Gatt.service, Gatt.command, f);
      }
    }).catchError((Object e) {
      _pending.remove(id);
      if (!c.isCompleted) c.completeError(DeviceError('ERROR', 'BLE_WRITE_FAILED'));
    });
    try {
      final m = await c.future.timeout(timeout);
      final st = m['st'] as String? ?? 'ERROR';
      if (st != Status.ok) throw DeviceError(st, (m['err'] ?? st) as String, field: m['field'] as String?);
      return m;
    } on TimeoutException {
      _pending.remove(id);
      throw DeviceError(Status.timeout, 'BLE_TIMEOUT');
    }
  }

  Future<Map<String, dynamic>> readInfo() async {
    final v = await UniversalBle.read(deviceId, Gatt.service, Gatt.info);
    return jsonDecode(utf8.decode(v)) as Map<String, dynamic>;
  }

  @override
  FileSource? fileSource(WifiStatus w) =>
      (w.connected && w.token != null) ? HttpFileSource('http://${w.ip}:${w.port}/v1', w.token!) : null;

  @override
  Future<void> disconnect() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _failPending('BLE_DISCONNECTED');
    try {
      await UniversalBle.disconnect(deviceId);
    } catch (_) {}
    _set(LinkState.disconnected);
  }

  static Uint8List bytes(List<int> v) => Uint8List.fromList(v);
}
