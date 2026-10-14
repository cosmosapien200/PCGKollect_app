import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:universal_ble/universal_ble.dart' show BleDevice;

import '../device/ble_link.dart';
import '../data/db.dart';
import '../device/device_link.dart';
import '../device/http_files.dart';
import '../state/app_state.dart';
import '../state/device_controller.dart';
import 'common.dart';
import 'sync_sheet.dart';

/// Device Settings: connection, phone-hotspot provisioning, diagnostics and
/// recording management (spec 01 §4, §10).
class DevicePage extends StatefulWidget {
  const DevicePage({super.key});
  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  Map<String, dynamic>? stats;
  DateTime? statsAt;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    _poll();
    timer = Timer.periodic(const Duration(seconds: 10), (_) => _poll()); // spec: 10 s while visible
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    final dev = context.read<DeviceController>();
    final app = context.read<AppState>();
    if (!dev.connected) return;
    try {
      // Prefer HTTP (adds ESP heap/RSSI/link counters); fall back to BLE.
      final fs = dev.fileSource();
      Map<String, dynamic> s;
      try {
        s = fs is HttpFileSource ? await fs.stats() : await dev.link!.call('stats');
      } catch (_) {
        s = await dev.link!.call('stats');
      }
      await app.db.addSnapshot(dev.deviceId, s);
      if (mounted) {
        setState(() {
          stats = s;
          statsAt = DateTime.now();
        });
      }
    } catch (_) {}
  }

  Future<void> _exportLogs(BuildContext context) async {
    final dev = context.read<DeviceController>();
    final app = context.read<AppState>();
    final r = await guarded(context, () => dev.call('logs', {'lines': 40}));
    if (r == null) return;
    final snaps = await app.db.snapshots(dev.deviceId, limit: 60);
    final b = StringBuffer()
      ..writeln('PCGKolect device log export ${DateTime.now().toUtc().toIso8601String()}')
      ..writeln('device ${dev.deviceId}  info ${jsonEncode(dev.info)}')
      ..writeln('\n== RV1103 session log (most recent)');
    for (final l in (r['lines'] as List)) {
      b.writeln(l);
    }
    b.writeln('\n== Diagnostics snapshots (newest first)');
    for (final s in snaps) {
      b.writeln('${s.$1.toUtc().toIso8601String()} ${jsonEncode(s.$2)}');
    }
    final dir = Directory(p.join(app.root, 'exports'));
    await dir.create(recursive: true);
    final f = File(p.join(dir.path, 'device_log_${DateTime.now().millisecondsSinceEpoch}.txt'));
    await f.writeAsString(b.toString());
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], subject: 'PCGKolect device log'));
  }

  @override
  Widget build(BuildContext context) {
    final dev = context.watch<DeviceController>();
    return Scaffold(
      appBar: AppBar(title: const Text('Device Settings'), actions: const [ConnChip()]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _ConnectionCard(onConnected: _poll),
        if (dev.connected) ...[
          const _WifiCard(),
          _InfoCard(stats: stats, statsAt: statsAt),
          const SectionTitle('Recordings on the device'),
          Wrap(spacing: 12, runSpacing: 8, children: [
            FilledButton.icon(
              onPressed: () => showSyncSheet(context, deleteAfter: false),
              icon: const Icon(Icons.download),
              label: const Text('Download recordings'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => showSyncSheet(context, deleteAfter: true),
              icon: const Icon(Icons.sync),
              label: const Text('Sync (download + delete verified)'),
            ),
            OutlinedButton.icon(
              onPressed: () => _exportLogs(context),
              icon: const Icon(Icons.receipt_long),
              label: const Text('Export device logs'),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              onPressed: () => _clear(context),
              icon: const Icon(Icons.delete_sweep),
              label: const Text('Clear device recordings'),
            ),
          ]),
        ],
        if (dev.lastError != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text('Last error: ${dev.lastError}', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
      ]),
    );
  }

  Future<void> _clear(BuildContext context) async {
    final dev = context.read<DeviceController>();
    final db = context.read<AppState>().db;
    final s = await guarded(context, () => dev.call('stats'));
    if (s == null || !context.mounted) return;
    final rc = (s['recordings'] ?? {}) as Map;
    final count = (rc['count'] as num?)?.toInt() ?? 0;
    final pending = (rc['pending_transfer'] as num?)?.toInt() ?? 0;
    final ok = await confirm(
      context,
      'Clear device recordings?',
      pending > 0
          ? '$pending of $count recording(s) have NOT been transferred and verified. They will be kept — '
              'only verified recordings are deleted. Download them first to remove them.'
          : 'All $count recording(s) on the device were verified on this phone and will be deleted from the device.',
      ok: 'Delete verified',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    final r = await guarded(context, () => dev.call('clear', {'force': false}, const Duration(seconds: 15)));
    if (r != null) await db.audit(null, 'device_clear', 'deleted ${(r['deleted'] as List).length}');
    if (r != null && context.mounted) {
      snack(context, 'Deleted ${(r['deleted'] as List).length}, kept ${(r['kept'] as List).length} untransferred');
      _poll();
    }
  }
}

class _ConnectionCard extends StatefulWidget {
  final VoidCallback onConnected;
  const _ConnectionCard({required this.onConnected});
  @override
  State<_ConnectionCard> createState() => _ConnectionCardState();
}

class _ConnectionCardState extends State<_ConnectionCard> {
  final found = <BleDevice>[];
  bool scanning = false;
  String? scanError;

  Future<void> _scan() async {
    setState(() {
      found.clear();
      scanning = true;
      scanError = null;
    });
    if (!await BleScanner.ensurePermissions()) {
      setState(() {
        scanning = false;
        scanError = 'Bluetooth permission is needed to find the device. Allow "Nearby devices" in the app settings.';
      });
      return;
    }
    if (!await BleScanner.bluetoothOn()) {
      setState(() {
        scanning = false;
        scanError = 'Turn on Bluetooth to find the device.';
      });
      return;
    }
    BleScanner.scan().listen(
      (d) => setState(() => found.add(d)),
      onError: (e) => setState(() => scanError = '$e'),
      onDone: () => mounted ? setState(() => scanning = false) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final dev = context.watch<DeviceController>();
    final t = Theme.of(context).textTheme;
    if (dev.connected) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.bluetooth_connected, color: Colors.green),
          title: Text(dev.name),
          subtitle: Text('Device ID ${dev.deviceId}${dev.isSimulated ? '\nSimulated device — recordings are synthetic' : ''}'),
          isThreeLine: dev.isSimulated,
          trailing: TextButton(onPressed: dev.disconnect, child: const Text('Disconnect')),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Connect over Bluetooth', style: t.titleMedium),
          const Text('Bluetooth is used for control and status. Recordings travel over the phone hotspot.'),
          const SizedBox(height: 8),
          Wrap(spacing: 12, children: [
            FilledButton.icon(
              onPressed: scanning || dev.ui == ConnUi.connecting ? null : _scan,
              icon: const Icon(Icons.bluetooth_searching),
              label: Text(scanning ? 'Scanning…' : 'Scan'),
            ),
            TextButton(
              onPressed: () async {
                await guarded(context, dev.connectSimulated);
                widget.onConnected();
              },
              child: const Text('Use simulated device'),
            ),
          ]),
          if (scanError != null) Text(scanError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          for (final d in found)
            ListTile(
              leading: const Icon(Icons.monitor_heart_outlined),
              title: Text(d.name ?? d.deviceId),
              subtitle: Text('${d.deviceId}${d.rssi == null ? '' : ' · ${d.rssi} dBm'}'),
              trailing: dev.ui == ConnUi.connecting ? const CircularProgressIndicator() : const Icon(Icons.link),
              onTap: dev.ui == ConnUi.connecting
                  ? null
                  : () async {
                      await guarded(context, () => dev.connectBle(d));
                      widget.onConnected();
                    },
            ),
        ]),
      ),
    );
  }
}

class _WifiCard extends StatefulWidget {
  const _WifiCard();
  @override
  State<_WifiCard> createState() => _WifiCardState();
}

class _WifiCardState extends State<_WifiCard> {
  static const _store = FlutterSecureStorage();
  final ssid = TextEditingController();
  final pass = TextEditingController();
  bool remember = true;
  bool obscure = true;
  String? health;

  @override
  void initState() {
    super.initState();
    _store.read(key: 'hotspot_ssid').then((v) => ssid.text = v ?? '');
    _store.read(key: 'hotspot_pass').then((v) => pass.text = v ?? '');
  }

  Future<void> _check() async {
    final dev = context.read<DeviceController>();
    await dev.refreshWifi();
    final fs = dev.fileSource();
    if (fs == null) {
      setState(() => health = 'Not on the hotspot yet');
      return;
    }
    try {
      final t0 = DateTime.now();
      await fs.health();
      setState(() => health = 'Reachable (${DateTime.now().difference(t0).inMilliseconds} ms)');
    } on TransferException catch (e) {
      setState(() => health = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dev = context.watch<DeviceController>();
    final w = dev.wifi;
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Wi-Fi transfer (phone hotspot)', style: t.titleMedium),
          const SizedBox(height: 4),
          const Text('1. Turn on this phone\'s Wi-Fi hotspot (Settings → Hotspot & tethering).\n'
              '2. Enter the hotspot name and password below and send them to the device over Bluetooth.\n'
              'No internet access is needed.'),
          const SizedBox(height: 8),
          KV('Status', '${w.state}${w.error.isNotEmpty ? ' (${w.error})' : ''}'),
          if (w.ssid.isNotEmpty) KV('Network', w.ssid),
          if (w.connected) KV('Device address', '${w.ip}:${w.port} · RSSI ${w.rssi} dBm'),
          if (health != null) KV('Phone → device', health!),
          const SizedBox(height: 8),
          TextField(controller: ssid, decoration: const InputDecoration(labelText: 'Hotspot name (SSID)', border: OutlineInputBorder())),
          const SizedBox(height: 8),
          TextField(
            controller: pass,
            obscureText: obscure,
            decoration: InputDecoration(
              labelText: 'Hotspot password',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => obscure = !obscure),
              ),
            ),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: remember,
            onChanged: (v) => setState(() => remember = v ?? false),
            title: const Text('Remember on this phone (encrypted storage)'),
          ),
          Wrap(spacing: 12, runSpacing: 8, children: [
            FilledButton.icon(
              onPressed: () async {
                if (remember) {
                  await _store.write(key: 'hotspot_ssid', value: ssid.text.trim());
                  await _store.write(key: 'hotspot_pass', value: pass.text);
                } else {
                  await _store.delete(key: 'hotspot_pass');
                }
                if (!context.mounted) return;
                await guarded(context, () => dev.provisionWifi(ssid.text.trim(), pass.text));
              },
              icon: const Icon(Icons.wifi),
              label: const Text('Send to device'),
            ),
            OutlinedButton.icon(onPressed: _check, icon: const Icon(Icons.network_check), label: const Text('Test connection')),
            TextButton(
              onPressed: () async {
                await _store.delete(key: 'hotspot_pass');
                pass.clear();
                if (context.mounted) await guarded(context, dev.forgetWifi);
              },
              child: const Text('Forget network'),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final Map<String, dynamic>? stats;
  final DateTime? statsAt;
  const _InfoCard({required this.stats, required this.statsAt});

  @override
  Widget build(BuildContext context) {
    final dev = context.watch<DeviceController>();
    final app = context.watch<AppState>();
    final i = dev.info ?? {};
    final s = stats ?? {};
    final model = (i['model'] ?? {}) as Map;
    final ds = (i['dataset'] ?? {}) as Map;
    final sto = (s['storage'] ?? {}) as Map;
    final mem = (s['mem_kb'] ?? {}) as Map;
    final uart = (s['uart'] ?? {}) as Map;
    final rc = (s['recordings'] ?? {}) as Map;
    final dsName = app.datasets.where((d) => d.id == ds['id']).map((d) => d.name).firstOrNull ?? ds['name'];
    String unsupported(Object? v, String Function(Object) f) => v == null ? 'unavailable' : v is String ? v : f(v);
    final upMin = ((uart['since_s'] as num?) ?? 0) / 60;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Device', style: Theme.of(context).textTheme.titleMedium),
          Text(
            statsAt == null
                ? 'Stats not loaded'
                : DateTime.now().difference(statsAt!).inSeconds > 30
                    ? 'STALE — last update ${fmtDate(statsAt)}'
                    : 'Updated ${fmtDate(statsAt)} (every 10 s)',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: statsAt != null && DateTime.now().difference(statsAt!).inSeconds > 30 ? Theme.of(context).colorScheme.error : null),
          ),
          KV('Device ID', dev.deviceId),
          KV('Firmware', 'ESP ${i['esp_fw'] ?? '—'} · RV ${i['rv_fw'] ?? '—'}'),
          KV('Model', '${model['version'] ?? '—'}${model['loaded'] == false ? ' (NOT LOADED)' : ''}'),
          KV('Model SHA-256', '${model['sha256'] ?? '—'}'),
          KV('Active dataset', '${dsName ?? '—'} · rev ${ds['rev'] ?? '—'}'),
          KV('Uptime', unsupported(s['uptime_s'], (v) => fmtDuration((v as num) * 1000))),
          KV('Storage', sto.isEmpty ? '—' : '${fmtBytes(sto['free_bytes'] as num?)} free of ${fmtBytes(sto['total_bytes'] as num?)}'),
          KV('Remaining recording time', sto['est_remaining_s'] == null ? '—' : '≈ ${fmtDuration((sto['est_remaining_s'] as num) * 1000)} (approximate)'),
          KV('Recordings', rc.isEmpty ? '—' : '${rc['count']} stored · ${rc['pending_transfer']} not transferred · ${rc['incomplete']} incomplete'),
          KV('RAM', mem.isEmpty ? '—' : '${fmtBytes(((mem['available'] as num?) ?? 0) * 1024)} available of ${fmtBytes(((mem['total'] as num?) ?? 0) * 1024)}'),
          KV('CPU', unsupported(s['cpu_pct'], (v) => '${(v as num).toStringAsFixed(1)} %')),
          KV('NPU', unsupported(s['npu_pct'], (v) => '$v %')),
          KV('Temperature', unsupported(s['temp_c'], (v) => '${(v as num).toStringAsFixed(1)} °C')),
          KV('UART', uart.isEmpty
              ? '—'
              : '${uart['frames_ok']} frames · ${uart['crc_errors']} CRC errors · ${uart['seq_gaps']} lost frames'
                  '${upMin > 1 ? ' (${(((uart['crc_errors'] as num) + (uart['seq_gaps'] as num)) / upMin * 60).toStringAsFixed(1)}/h)' : ''}'),
          KV('Average SNR', 'not defined yet'),
          if (s['esp'] is Map) ...[
            KV('ESP uptime', fmtDuration(((s['esp']['uptime_s'] as num?) ?? 0) * 1000)),
            KV('ESP free RAM', '${fmtBytes(s['esp']['heap_internal_free'] as num?)} internal · ${fmtBytes(s['esp']['heap_free'] as num?)} total'),
            KV('Hotspot signal', '${s['esp']['wifi_rssi']} dBm'),
            KV('ESP link', 'baud ${(s['esp']['link'] as Map)['baud']} · ${(s['esp']['link'] as Map)['rx_crc_errors']} CRC · ${(s['esp']['link'] as Map)['req_retries']} retries · ${(s['esp']['link'] as Map)['link_downs']} link drops'),
          ],
        ]),
      ),
    );
  }
}
