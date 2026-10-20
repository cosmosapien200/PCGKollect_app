import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart' show BleDevice;

import '../core/protocol.dart';
import '../data/models.dart';
import '../device/ble_link.dart';
import '../device/device_link.dart';
import '../device/sim_link.dart';
import '../device/usb_link.dart';

enum ConnUi { disconnected, connecting, connected, busy, error }

/// Owns the device link and mirrors its state for the UI. Commands report success
/// only after the device acknowledged them.
const _readOnly = {'hello', 'status', 'stats', 'manifest', 'wifi_status', 'logs'};

enum Transport { none, ble, usb, sim }

class DeviceController extends ChangeNotifier {
  DeviceLink? link;

  /// BLE link kept connected in the background while the USB cable is in use, so
  /// unplugging the cable falls back to it without a reconnect.
  BleLink? standby;
  StreamSubscription? _standbySub;
  StreamSubscription? _attachSub;
  bool _usbConnecting = false;
  LinkState linkState = LinkState.disconnected;
  int _busy = 0;
  String? lastError;
  Map<String, dynamic>? info;
  DeviceStatus? status;
  WifiStatus wifi = const WifiStatus.off();
  final _subs = <StreamSubscription>[];

  bool get connected => link != null && linkState == LinkState.connected;
  bool get isSimulated => link is SimLink;
  Transport get transport => switch (link) {
        UsbLink() => Transport.usb,
        BleLink() => Transport.ble,
        SimLink() => Transport.sim,
        _ => Transport.none,
      };
  bool get isUsb => link is UsbLink;
  String get deviceId => (info?['device_id'] as String?) ?? link?.deviceId ?? '';
  String get name => link?.name ?? '';

  ConnUi get ui {
    if (linkState == LinkState.connecting) return ConnUi.connecting;
    if (linkState == LinkState.error) return ConnUi.error;
    if (!connected) return ConnUi.disconnected;
    if (_busy > 0) return ConnUi.busy;
    return status?.linkUp == false ? ConnUi.error : ConnUi.connected;
  }

  /// Active dataset on the device as reported by hello / telemetry.
  String get deviceDatasetId => status?.datasetId ?? ((info?['dataset'] as Map?)?['id'] as String? ?? '');
  int get deviceRev => status?.settingsRev ?? ((info?['dataset'] as Map?)?['rev'] as int? ?? -1);

  Future<void> connectBle(BleDevice d) =>
      _attach(BleLink(d.deviceId, d.name ?? 'PCGKolect'), (l) => (l as BleLink).connect());

  Future<void> connectSimulated() => _attach(SimLink(), (l) => (l as SimLink).connect());

  /// Wired link to the RV1103 (PROTOCOL.md §5). The cable takes over control and
  /// transfers; an open BLE link stays connected as standby.
  Future<void> connectUsb(UsbDeviceInfo d) async {
    if (_usbConnecting || link is UsbLink) return;
    _usbConnecting = true;
    try {
      final ble = link is BleLink && connected ? link as BleLink : null;
      if (ble != null) {
        await _detachSubs();
        standby = ble;
        _standbySub = ble.state.listen((s) {
          if (s != LinkState.connected && standby == ble) {
            standby = null;
            notifyListeners();
          }
        });
        link = null;
      }
      await _attach(UsbLink(await AndroidUsb.open(d.name), name: '${d.product} (USB)', usbName: d.name),
          (l) => (l as UsbLink).connect(),
          keepStandby: true);
    } catch (_) {
      // cable link failed: return to BLE if we had it
      final s = standby;
      if (s != null && s.currentState == LinkState.connected) {
        standby = null;
        await _standbySub?.cancel();
        await _attach(s, (_) async {});
      }
      rethrow;
    } finally {
      _usbConnecting = false;
    }
  }

  /// Watches for the device being plugged in / unplugged (Android USB host).
  void watchUsb() {
    _attachSub ??= AndroidUsb.attachEvents().listen((e) async {
      if (e.event == 'attached') {
        await autoConnectUsb();
      }
    });
  }

  /// Connects over USB when a PCGKolect device is plugged in (cable = intent to use it).
  Future<void> autoConnectUsb() async {
    if (link is UsbLink || link is SimLink) return;
    final l = await AndroidUsb.list();
    if (l.isEmpty) return;
    try {
      await connectUsb(l.first);
    } catch (_) {}
  }

  Future<void> _onUsbLost() async {
    final s = standby;
    standby = null;
    await _standbySub?.cancel();
    _standbySub = null;
    if (s != null && s.currentState == LinkState.connected) {
      await _detachSubs();
      link = null;
      try {
        await _attach(s, (_) async {});
        lastError = 'USB cable disconnected — using Bluetooth';
        notifyListeners();
      } catch (_) {}
    }
  }

  Future<void> _detachSubs() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }

  Future<void> _attach(DeviceLink l, Future<void> Function(DeviceLink) open, {bool keepStandby = false}) async {
    if (keepStandby) {
      await _detachSubs();
      await link?.disconnect();
      link = null;
    } else {
      await disconnect();
    }
    link = l;
    lastError = null;
    _subs
      ..add(l.state.listen((s) {
        linkState = s;
        notifyListeners();
        if (l is UsbLink && s == LinkState.disconnected && link == l) _onUsbLost();
      }))
      ..add(l.telemetry.listen((s) {
        status = s;
        notifyListeners();
      }))
      ..add(l.wifi.listen((w) {
        // notifications never carry the token: keep the one from wifi_status
        wifi = WifiStatus.fromJson({..._wifiJson(w), if (wifi.token != null) 'token': wifi.token});
        notifyListeners();
      }));
    try {
      await open(l);
      linkState = l.currentState; // stream events arrive asynchronously
      notifyListeners();
      await refresh();
    } catch (e) {
      lastError = e is DeviceError ? e.message : 'Connection failed: $e';
      linkState = LinkState.error;
      notifyListeners();
      rethrow;
    }
  }

  static Map<String, dynamic> _wifiJson(WifiStatus w) => {
        'state': w.state, 'ssid': w.ssid, 'ip': w.ip, 'port': w.port, 'rssi': w.rssi,
        'err': w.error, 'http_ready': w.httpReady,
      };

  Future<void> disconnect() async {
    await _detachSubs();
    await _standbySub?.cancel();
    _standbySub = null;
    await standby?.disconnect();
    standby = null;
    await link?.disconnect();
    link = null;
    linkState = LinkState.disconnected;
    status = null;
    info = null;
    wifi = const WifiStatus.off();
    notifyListeners();
  }

  /// Runs a command with Busy state and error capture. Throws [DeviceError].
  Future<Map<String, dynamic>> call(String op,
      [Map<String, dynamic> args = const {}, Duration timeout = const Duration(seconds: 8)]) async {
    final l = link;
    if (l == null || !connected) throw DeviceError('ERROR', 'BLE_DISCONNECTED');
    _busy++;
    notifyListeners();
    try {
      Map<String, dynamic> r;
      try {
        r = await l.call(op, args, timeout);
      } on DeviceError catch (e) {
        // Read-only ops are retried once after a timeout; state-changing ops are not
        // (the device answers duplicates idempotently, but the operator decides).
        if (e.status != Status.timeout || !_readOnly.contains(op)) rethrow;
        r = await l.call(op, args, timeout);
      }
      lastError = null;
      return r;
    } on DeviceError catch (e) {
      lastError = e.message;
      rethrow;
    } finally {
      _busy--;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    info = await call('hello');
    try {
      status = DeviceStatus.fromJson(await call('status'));
    } catch (_) {}
    await refreshWifi();
  }

  Future<void> refreshWifi() async {
    if (isUsb) return; // Wi-Fi state lives on the ESP32; over the cable it is not needed
    try {
      wifi = WifiStatus.fromJson(await call('wifi_status'));
      notifyListeners();
    } catch (_) {}
  }

  /// Activate DS: send dataset identity + settings revision; returns the accepted revision.
  Future<int> activate(Dataset d) async {
    final r = await call('set_dataset', {
      'dataset_id': d.id,
      'name': d.name,
      'rev': d.settingsRev,
      'settings': d.policy.toJson(),
    });
    await refresh();
    return (r['rev'] as num).toInt();
  }

  Future<void> provisionWifi(String ssid, String pass) async {
    await call('wifi_set', {'ssid': ssid, 'pass': pass}, const Duration(seconds: 10));
    await refreshWifi();
  }

  Future<void> forgetWifi() async {
    await call('wifi_forget');
    await refreshWifi();
  }

  FileSource? fileSource() => link?.fileSource(wifi);

  @override
  void dispose() {
    _attachSub?.cancel();
    disconnect();
    super.dispose();
  }
}
