import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/protocol.dart';
import '../data/db.dart';
import '../state/app_state.dart';
import 'common.dart';

/// Named settings presets per study protocol (spec 01 §14.5).
class PresetsCard extends StatefulWidget {
  final Policy Function() current;
  final ValueChanged<Policy> onLoad;
  const PresetsCard({super.key, required this.current, required this.onLoad});
  @override
  State<PresetsCard> createState() => _PresetsCardState();
}

class _PresetsCardState extends State<PresetsCard> {
  Map<String, Map<String, dynamic>> presets = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    presets = await context.read<AppState>().db.presets();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final db = context.read<AppState>().db;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Protocol presets', style: Theme.of(context).textTheme.titleMedium),
          const Text('Save these settings under a name, or load a saved protocol into the form (then Save + Activate).'),
          for (final e in presets.entries)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(e.key),
              subtitle: Text('threshold ${((e.value['conf_threshold'] as num) * 100).round()} % · '
                  'target ${e.value['target_usable_s']} s · max ${e.value['max_duration_s']} s'),
              trailing: Wrap(children: [
                IconButton(
                  tooltip: 'Load',
                  icon: const Icon(Icons.download),
                  onPressed: () => widget.onLoad(Policy.fromJson(e.value)),
                ),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await db.deletePreset(e.key);
                    _load();
                  },
                ),
              ]),
            ),
          TextButton.icon(
            icon: const Icon(Icons.bookmark_add_outlined),
            label: const Text('Save current settings as preset'),
            onPressed: () async {
              final ctl = TextEditingController();
              final name = await showDialog<String>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('Preset name'),
                  content: TextField(controller: ctl, autofocus: true),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Save')),
                  ],
                ),
              );
              if (name == null || name.isEmpty) return;
              await db.savePreset(name, widget.current().toJson());
              await db.audit(null, 'preset_saved', name);
              _load();
            },
          ),
        ]),
      ),
    );
  }
}

/// Calibration record for the dataset (spec 01 §14.7): hardware and model context
/// needed to interpret recordings later.
class CalibrationCard extends StatefulWidget {
  final String datasetId;
  const CalibrationCard({super.key, required this.datasetId});
  @override
  State<CalibrationCard> createState() => _CalibrationCardState();
}

class _CalibrationCardState extends State<CalibrationCard> {
  static const fields = {
    'analog_gain_db': 'Analog gain (dB)',
    'sensor_revision': 'Sensor revision',
    'frontend_revision': 'Front-end board revision',
    'device_id': 'Device ID',
    'model_version': 'Model version',
    'calibration_notes': 'Calibration notes',
  };
  final ctl = {for (final k in fields.keys) k: TextEditingController()};
  String? loadedFor;

  Future<void> _load() async {
    loadedFor = widget.datasetId;
    final c = await context.read<AppState>().db.calibration(widget.datasetId);
    for (final k in fields.keys) {
      ctl[k]!.text = '${c[k] ?? ''}';
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (loadedFor != widget.datasetId) _load();
    final db = context.read<AppState>().db;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Calibration record', style: Theme.of(context).textTheme.titleMedium),
          const Text('Hardware context for this dataset (stored locally, included in exports).'),
          for (final e in fields.entries)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                controller: ctl[e.key],
                maxLines: e.key == 'calibration_notes' ? 3 : 1,
                decoration: InputDecoration(labelText: e.value, border: const OutlineInputBorder(), isDense: true),
              ),
            ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: () async {
              final c = {for (final k in fields.keys) if (ctl[k]!.text.trim().isNotEmpty) k: ctl[k]!.text.trim()};
              await db.setCalibration(widget.datasetId, c);
              await db.audit(widget.datasetId, 'calibration_updated', c.keys.join(','));
              if (context.mounted) snack(context, 'Calibration record saved');
            },
            child: const Text('Save calibration record'),
          ),
        ]),
      ),
    );
  }
}

/// Local audit trail (spec 01 §14.8).
class AuditCard extends StatelessWidget {
  final String datasetId;
  const AuditCard({super.key, required this.datasetId});

  @override
  Widget build(BuildContext context) {
    final db = context.read<AppState>().db;
    return Card(
      child: ExpansionTile(
        title: const Text('Audit trail'),
        subtitle: const Text('Settings, activation, deletion and export events on this phone'),
        children: [
          FutureBuilder(
            future: db.auditLog(datasetId, limit: 100),
            builder: (c, s) {
              final rows = s.data ?? [];
              if (rows.isEmpty) return const Padding(padding: EdgeInsets.all(12), child: Text('No events yet'));
              return Column(children: [
                for (final r in rows)
                  ListTile(
                    dense: true,
                    title: Text('${r['action']}${(r['detail'] as String).isEmpty ? '' : ' — ${r['detail']}'}'),
                    subtitle: Text('${fmtDate(DateTime.fromMillisecondsSinceEpoch(r['ts'] as int))}'
                        '${r['operator'] == null ? '' : ' · operator ${r['operator']}'}'),
                  ),
              ]);
            },
          ),
        ],
      ),
    );
  }
}
