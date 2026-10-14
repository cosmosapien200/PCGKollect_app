import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/db.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import '../state/device_controller.dart';
import 'common.dart';
import 'data_page.dart';
import 'device_page.dart';
import 'ds_settings_page.dart';
import 'ds_stats_page.dart';
import 'sync_sheet.dart';

enum Section { settings, stats, data }

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  Section section = Section.data;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final nav = _NavPanel(
      selected: section,
      onSelect: (s) {
        setState(() => section = s);
        if (!wide) Navigator.of(context).maybePop();
      },
    );
    final body = app.active == null
        ? _NoDataset(onCreate: () => createDatasetDialog(context))
        : switch (section) {
            Section.settings => const DsSettingsPage(),
            Section.stats => const DsStatsPage(),
            Section.data => const DataPage(),
          };
    final title = switch (section) {
      Section.settings => 'DS Settings',
      Section.stats => 'DS Stats',
      Section.data => 'Data',
    };
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title),
          if (app.active != null)
            Text(app.active!.name, style: Theme.of(context).textTheme.labelMedium),
        ]),
        actions: [ConnChip(onTap: () => openDevicePage(context))],
      ),
      drawer: wide ? null : Drawer(child: nav),
      body: wide ? Row(children: [SizedBox(width: 300, child: Material(elevation: 1, child: nav)), Expanded(child: body)]) : body,
    );
  }
}

void openDevicePage(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DevicePage()));

class _NoDataset extends StatelessWidget {
  final VoidCallback onCreate;
  const _NoDataset({required this.onCreate});
  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.dataset_outlined, size: 56),
          const SizedBox(height: 12),
          const Text('Create a dataset to start collecting recordings.'),
          const SizedBox(height: 16),
          FilledButton.icon(onPressed: onCreate, icon: const Icon(Icons.add), label: const Text('New dataset')),
        ]),
      );
}

class _NavPanel extends StatelessWidget {
  final Section selected;
  final ValueChanged<Section> onSelect;
  const _NavPanel({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final dev = context.watch<DeviceController>();
    final ds = app.active;
    Widget item(Section s, IconData icon, String label) => ListTile(
          leading: Icon(icon),
          title: Text(label),
          selected: selected == s,
          onTap: () => onSelect(s),
        );
    return SafeArea(
      child: Column(children: [
        // dataset selector + create
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
          child: Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: ds?.id,
                decoration: const InputDecoration(labelText: 'Dataset', border: OutlineInputBorder()),
                items: [
                  for (final d in app.datasets) DropdownMenuItem(value: d.id, child: Text(d.name, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (id) => app.switchTo(app.datasets.firstWhere((d) => d.id == id)),
              ),
            ),
            IconButton(tooltip: 'New dataset', icon: const Icon(Icons.add), onPressed: () => createDatasetDialog(context)),
          ]),
        ),
        const Divider(),
        item(Section.settings, Icons.tune, 'DS Settings'),
        item(Section.stats, Icons.insights, 'DS Stats'),
        item(Section.data, Icons.library_music_outlined, 'Data'),
        const Spacer(),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.upload),
          title: const Text('Activate DS'),
          subtitle: Text(ds == null
              ? 'No dataset'
              : ds.deviceUpToDate && dev.deviceDatasetId == ds.id
                  ? 'Active on device (rev ${ds.settingsRev})'
                  : 'Not active on device'),
          enabled: ds != null && dev.connected,
          onTap: () {
            Scaffold.maybeOf(context)?.closeDrawer();
            activateDataset(context);
          },
        ),
        ListTile(
          leading: const Icon(Icons.sync),
          title: const Text('Sync'),
          subtitle: const Text('Download, verify, then delete device copies'),
          enabled: dev.connected,
          onTap: () {
            Scaffold.maybeOf(context)?.closeDrawer();
            showSyncSheet(context, deleteAfter: true);
          },
        ),
        ListTile(
          leading: const Icon(Icons.settings_input_antenna),
          title: const Text('Device Settings'),
          subtitle: Text(dev.connected ? dev.name : 'Not connected'),
          onTap: () => openDevicePage(context),
        ),
        const SizedBox(height: 8),
      ]),
    );
  }
}

Future<void> createDatasetDialog(BuildContext context, {Dataset? rename}) async {
  final app = context.read<AppState>();
  final ctl = TextEditingController(text: rename?.name);
  String? error;
  await showDialog<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setSt) => AlertDialog(
        title: Text(rename == null ? 'New dataset' : 'Rename dataset'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: InputDecoration(labelText: 'Name', errorText: error),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final name = ctl.text.trim();
              if (name.isEmpty) return setSt(() => error = 'Required');
              try {
                if (rename == null) {
                  await app.createDataset(name);
                } else {
                  await app.rename(rename, name);
                }
                if (c.mounted) Navigator.pop(c);
              } on DuplicateNameException catch (e) {
                setSt(() => error = e.toString());
              }
            },
            child: Text(rename == null ? 'Create' : 'Save'),
          ),
        ],
      ),
    ),
  );
}

/// Activate DS: warn when the device still holds untransferred recordings of another
/// dataset, then send identity + settings and record the acknowledged revision.
Future<void> activateDataset(BuildContext context) async {
  final app = context.read<AppState>();
  final dev = context.read<DeviceController>();
  final ds = app.active;
  if (ds == null) return;
  if (dev.deviceDatasetId.isNotEmpty && dev.deviceDatasetId != ds.id) {
    final stats = await guarded(context, () => dev.call('stats'));
    final pending = ((stats?['recordings'] as Map?)?['pending_transfer'] as num?)?.toInt() ?? 0;
    if (!context.mounted) return;
    final ok = await confirm(
      context,
      'Change the device dataset?',
      'The device is set to another dataset.${pending > 0 ? ' It holds $pending recording(s) not yet transferred; they keep their original dataset.' : ''} '
          'New recordings will belong to "${ds.name}".',
      ok: 'Activate',
    );
    if (!ok || !context.mounted) return;
  }
  final rev = await guarded(context, () => dev.activate(ds));
  if (rev != null) {
    await app.markActivated(ds, rev);
    if (context.mounted) snack(context, '"${ds.name}" active on the device (settings rev $rev)');
  }
}
