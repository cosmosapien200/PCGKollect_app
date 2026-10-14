import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/protocol.dart';
import '../state/app_state.dart';
import '../state/device_controller.dart';
import 'common.dart';
import 'ds_extras.dart';
import 'home_shell.dart';

class DsSettingsPage extends StatefulWidget {
  const DsSettingsPage({super.key});
  @override
  State<DsSettingsPage> createState() => _DsSettingsPageState();
}

class _DsSettingsPageState extends State<DsSettingsPage> {
  late Policy p;
  String? loadedFor;
  int loadedRev = -1;
  bool dirty = false;

  void _load(AppState app) {
    final d = app.active!;
    if (loadedFor != d.id || (!dirty && loadedRev != d.settingsRev)) {
      p = d.policy.copy();
      loadedFor = d.id;
      loadedRev = d.settingsRev;
      dirty = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final dev = context.watch<DeviceController>();
    _load(app);
    final ds = app.active!;
    final errs = p.validate();
    final onDevice = dev.deviceDatasetId == ds.id ? dev.deviceRev : null;

    Widget num(String key, String label, String help, double value, ValueChanged<double> set,
        {bool integer = false, String unit = '', (double, double)? range}) {
      final r = range ?? Policy.ranges[key]!;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextFormField(
          key: ValueKey('$key-${ds.id}-$loadedRev-${p.hashCode}'),
          initialValue: integer ? value.toInt().toString() : _trim(value),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          decoration: InputDecoration(
            labelText: label,
            helperText: '$help  (range ${_trim(r.$1)}–${_trim(r.$2)}${unit.isEmpty ? '' : ' $unit'})',
            helperMaxLines: 2,
            suffixText: unit,
            border: const OutlineInputBorder(),
          ),
          onChanged: (t) {
            final v = double.tryParse(t);
            if (v != null) {
              setState(() {
                set(v);
                dirty = true;
              });
            }
          },
        ),
      );
    }

    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ds.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            KV('Dataset ID', ds.id),
            KV('Settings revision', '${ds.settingsRev}${dirty ? ' (unsaved edits)' : ''}'),
            KV('On device', onDevice == null ? 'not active' : 'revision $onDevice${onDevice == ds.settingsRev ? ' (current)' : ' (outdated)'}'),
            Row(children: [
              TextButton.icon(onPressed: () => createDatasetDialog(context, rename: ds), icon: const Icon(Icons.edit), label: const Text('Rename')),
              TextButton.icon(
                onPressed: () async {
                  if (await confirm(context, 'Archive "${ds.name}"?',
                      'The dataset is hidden from the selector. Its recordings stay in the archive.')) {
                    await app.archive(ds);
                  }
                },
                icon: const Icon(Icons.archive_outlined),
                label: const Text('Archive'),
              ),
            ]),
          ]),
        ),
      ),
      const SectionTitle('Usable beat definition'),
      num('conf_threshold', 'Confidence threshold', 'A beat is usable when the model confidence is at least this',
          p.confThreshold * 100, (v) => p.confThreshold = v / 100, unit: '%', range: (50, 99)),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Rhythm / beat-sequence check'),
        subtitle: const Text('Reject beats whose length differs > 30 % from their neighbours'),
        value: p.rhythmCheck,
        onChanged: (v) => setState(() {
          p.rhythmCheck = v;
          dirty = true;
        }),
      ),
      Text(
        'The confidence is the segmentation model\'s mean posterior for the decoded heart-sound states of each beat. '
        'Beat length (0.3–2.0 s) is checked by the model decoder and is not a dataset setting. '
        'Clipping or signal level never rejects a beat.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SectionTitle('Completion targets'),
      num('target_usable_s', 'Required total usable time', '0 = off', p.targetUsableS, (v) => p.targetUsableS = v, unit: 's'),
      num('target_usable_beats', 'Required total usable beats', '0 = off', p.targetUsableBeats.toDouble(),
          (v) => p.targetUsableBeats = v.toInt(), integer: true),
      num('min_run_beats', 'Minimum consecutive usable beats', 'At least one uninterrupted run; 0 = off',
          p.minRunBeats.toDouble(), (v) => p.minRunBeats = v.toInt(), integer: true),
      num('min_run_s', 'Minimum consecutive usable time', 'At least one uninterrupted run; 0 = off', p.minRunS,
          (v) => p.minRunS = v, unit: 's'),
      const SectionTitle('Capture'),
      num('autostart_s', 'Auto-start after reliable audio', 'Contiguous usable audio before recording starts; Force Start skips the wait',
          p.autostartS, (v) => p.autostartS = v, unit: 's'),
      num('max_duration_s', 'Maximum recording duration', 'The take ends as incomplete after this', p.maxDurationS,
          (v) => p.maxDurationS = v, unit: 's'),
      num('telemetry_hz', 'Live update rate', 'Status updates per second during capture', p.telemetryHz,
          (v) => p.telemetryHz = v, unit: 'Hz'),
      if (errs.isNotEmpty)
        Card(
          color: Theme.of(context).colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final e in errs) Text('• $e')]),
          ),
        ),
      const SizedBox(height: 12),
      Wrap(spacing: 12, runSpacing: 8, children: [
        FilledButton.icon(
          onPressed: !dirty || errs.isNotEmpty
              ? null
              : () async {
                  await app.saveSettings(ds, p.copy());
                  setState(() => dirty = false);
                  if (context.mounted) snack(context, 'Saved as revision ${ds.settingsRev}. Use Activate DS to send it to the device.');
                },
          icon: const Icon(Icons.save),
          label: const Text('Save'),
        ),
        OutlinedButton.icon(
          onPressed: dirty || errs.isNotEmpty || !dev.connected ? null : () => activateDataset(context),
          icon: const Icon(Icons.upload),
          label: const Text('Activate on device'),
        ),
        if (dirty)
          TextButton(
            onPressed: () => setState(() {
              p = ds.policy.copy();
              dirty = false;
              loadedRev = -1;
            }),
            child: const Text('Discard edits'),
          ),
      ]),
      const SizedBox(height: 16),
      PresetsCard(
        current: () => p,
        onLoad: (np) => setState(() {
          p = np;
          dirty = true;
          loadedRev = -2; // rebuild fields
        }),
      ),
      CalibrationCard(datasetId: ds.id),
      AuditCard(datasetId: ds.id),
      const SizedBox(height: 24),
    ]);
  }

  static String _trim(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
}
