import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart' show BleDevice;

import '../core/protocol.dart';
import '../data/models.dart';
import '../device/ble_link.dart';
import '../device/device_link.dart';
import '../device/sim_link.dart';

enum ConnUi { disconnected, connecting, connected, busy, error }

/// Owns the device link and mirrors its state for the UI. Commands report success
/// only after the device acknowledged them.
class DeviceController extends ChangeNotifier {
  DeviceLink? link;
  LinkState linkState = LinkState.disconnected;
  int _busy = 0;
  String? lastError;
  Map<String, dynamic>? info;
  DeviceStatus? status;
  WifiStatus wifi = const WifiStatus.off();
  final _subs = <StreamSubscription>[];

  bool get connected => link != null && linkState == LinkState.connected;
  bool get isSimulated => link is SimLink;
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

  Future<void> _attach(DeviceLink l, Future<void> Function(DeviceLink) open) async {
    await disconnect();
    link = l;
    lastError = null;
    _subs
      ..add(l.state.listen((s) {
        linkState = s;
        notifyListeners();
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
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
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
      final r = await l.call(op, args, timeout);
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
    disconnect();
    super.dispose();
  }
}
