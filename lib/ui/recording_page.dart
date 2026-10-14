import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/protocol.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import '../state/device_controller.dart';
import 'common.dart';
import 'home_shell.dart';
import 'subject_form_page.dart';
import 'sync_sheet.dart';

/// Live capture (spec 01 §6.2–6.4). The device is authoritative: this page only
/// shows what the RV1103 reports for this recording ID and never marks a take
/// complete on its own.
class RecordingPage extends StatefulWidget {
  final String recordingId;
  const RecordingPage({super.key, required this.recordingId});
  @override
  State<RecordingPage> createState() => _RecordingPageState();
}

class _RecordingPageState extends State<RecordingPage> {
  Recording? rec;
  Subject? subject;
  String? prepareError;
  bool preparing = false;
  String? lastSavedState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    final app = context.read<AppState>();
    rec = await app.db.recording(widget.recordingId);
    subject = rec == null ? null : await app.db.subject(rec!.subjectId);
    setState(() {});
    if (rec != null && rec!.state == RecState.pending) await _prepare();
  }

  Future<void> _prepare() async {
    final app = context.read<AppState>();
    final dev = context.read<DeviceController>();
    final ds = app.active!;
    setState(() {
      preparing = true;
      prepareError = null;
    });
    try {
      await dev.call('prepare', {
        'dataset_id': ds.id,
        'subject_id': rec!.subjectId,
        'recording_id': rec!.id,
        'rev': ds.settingsRev,
        'take': rec!.takeIndex,
      });
      await _setState(RecState.armed);
    } on DeviceError catch (e) {
      setState(() => prepareError = e.message);
      if ((e.code == 'DATASET_MISMATCH' || e.code == 'SETTINGS_MISMATCH') && mounted) {
        final ok = await confirm(context, 'Activate this dataset?',
            '${e.message}\n\nSend "${ds.name}" (settings rev ${ds.settingsRev}) to the device now?', ok: 'Activate');
        if (ok && mounted) {
          await activateDataset(context);
          if (mounted && dev.deviceDatasetId == ds.id && dev.deviceRev == ds.settingsRev) {
            setState(() => preparing = false);
            return _prepare();
          }
        }
      }
    } finally {
      if (mounted) setState(() => preparing = false);
    }
  }

  Future<void> _setState(String s) async {
    if (rec == null || rec!.state == s || lastSavedState == s) return;
    lastSavedState = s;
    rec!.state = s;
    if (s == RecState.recording) rec!.startAt ??= DateTime.now();
    final app = context.read<AppState>();
    await app.db.saveRecording(rec!);
    await app.refresh();
  }

  /// Maps device telemetry for this recording onto the app-side record.
  void _track(DeviceStatus? st, bool connected) {
    if (rec == null || RecState.terminal(rec!.state)) return;
    if (!connected) {
      if (rec!.state != RecState.pending) _setState(RecState.disconnected);
      return;
    }
    if (st == null || st.recordingId != rec!.id) return;
    final mapped = switch (st.state) {
      DeviceState.armed => RecState.armed,
      DeviceState.recording => RecState.recording,
      DeviceState.finalizing => RecState.finalizing,
      DeviceState.done => RecState.complete,
      DeviceState.incomplete => RecState.incomplete,
      DeviceState.cancelled => RecState.cancelled,
      DeviceState.interrupted => RecState.interrupted,
      DeviceState.storageFull => RecState.storageFull,
      _ => null,
    };
    if (mapped != null) {
      if (mapped == RecState.complete || mapped == RecState.incomplete) {
        rec!
          ..usableMs = st.usableMs.toDouble()
          ..durationMs = st.elapsedMs.toDouble()
          ..usableBeats = st.usableBeats
          ..longestRunMs = st.longestRunMs.toDouble()
          ..longestRunBeats = st.longestRunBeats;
      }
      _setState(mapped);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dev = context.watch<DeviceController>();
    final st = dev.status;
    WidgetsBinding.instance.addPostFrameCallback((_) => _track(st, dev.connected));
    final r = rec;
    if (r == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final mine = st != null && st.recordingId == r.id;
    final active = mine && st.state.isActive;
    final terminal = RecState.terminal(r.state);

    return PopScope(
      canPop: !active,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) snack(context, 'Stop or cancel the recording before leaving (it keeps running on the device).');
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('${subject?.label ?? ''} · take ${r.takeIndex}'),
          actions: const [ConnChip()],
        ),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          _StateBanner(rec: r, status: mine ? st : null, preparing: preparing, error: prepareError),
          const SizedBox(height: 12),
          if (mine) _Live(st: st, policy: context.read<AppState>().active!.policy),
          if (!dev.connected && !terminal)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: const ListTile(
                leading: Icon(Icons.bluetooth_disabled),
                title: Text('Device disconnected'),
                subtitle: Text('The device keeps recording on its own. Reconnect to see progress.'),
              ),
            ),
          const SizedBox(height: 16),
          Wrap(spacing: 12, runSpacing: 8, children: [
            if (prepareError != null && !terminal)
              FilledButton.icon(onPressed: preparing ? null : _prepare, icon: const Icon(Icons.refresh), label: const Text('Retry prepare')),
            if (mine && st.state == DeviceState.armed)
              FilledButton.icon(
                onPressed: () => guarded(context, () => dev.call('force_start', {'recording_id': r.id})),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Force Start'),
              ),
            if (mine && st.state == DeviceState.armed)
              OutlinedButton.icon(
                onPressed: () => guarded(context, () => dev.call('cancel', {'recording_id': r.id})),
                icon: const Icon(Icons.close),
                label: const Text('Cancel'),
              ),
            if (mine && st.state == DeviceState.recording)
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                onPressed: () async {
                  if (await confirm(context, 'Stop recording?',
                      'The take is saved but marked incomplete because the usable-time target is not reached yet.',
                      ok: 'Stop', destructive: true)) {
                    if (context.mounted) {
                      await guarded(context, () => dev.call('stop', {'recording_id': r.id, 'reason': 'user'}, const Duration(seconds: 12)));
                    }
                  }
                },
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
              ),
            if (terminal) ...[
              FilledButton.icon(
                onPressed: dev.connected ? () => showSyncSheet(context, deleteAfter: false) : null,
                icon: const Icon(Icons.download),
                label: const Text('Download now'),
              ),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(
                    builder: (_) => SubjectFormPage(existing: subject))),
                icon: const Icon(Icons.replay),
                label: const Text('New take'),
              ),
            ],
          ]),
          const SizedBox(height: 24),
          KV('Recording ID', r.id),
          KV('Subject ID', r.subjectId),
          KV('Settings revision', '${r.settingsRev ?? '—'}'),
          if (mine) KV('Score definition', st.qualityDef),
        ]),
      ),
    );
  }
}

class _StateBanner extends StatelessWidget {
  final Recording rec;
  final DeviceStatus? status;
  final bool preparing;
  final String? error;
  const _StateBanner({required this.rec, required this.status, required this.preparing, this.error});

  @override
  Widget build(BuildContext context) {
    final (title, sub, color, icon) = error != null
        ? ('Device did not accept the recording', error!, Colors.red.shade100, Icons.error_outline)
        : preparing
            ? ('Preparing device…', 'Sending dataset, subject and recording IDs', Colors.blueGrey.shade100, Icons.hourglass_top)
            : switch (rec.state) {
                RecState.armed => ('Waiting for reliable audio',
                    'Recording starts automatically after the required contiguous usable audio. Place the sensor and keep still.',
                    Colors.amber.shade100, Icons.hearing),
                RecState.recording => ('Recording', 'Collecting usable heart sounds', Colors.red.shade100, Icons.fiber_manual_record),
                RecState.finalizing => ('Finalizing', 'Saving files on the device', Colors.blueGrey.shade100, Icons.save),
                RecState.complete => ('DONE', 'Target reached and files saved on the device', Colors.green.shade100, Icons.check_circle),
                RecState.incomplete => ('Incomplete', 'Saved, but the targets were not met (${status?.reason ?? rec.completionReason ?? ''})',
                    Colors.orange.shade100, Icons.warning_amber),
                _ => (RecState.label(rec.state), status?.reason ?? '', Colors.blueGrey.shade100, Icons.info_outline),
              };
    return Card(
      color: color,
      child: ListTile(
        leading: Icon(icon, size: 32, color: Colors.black87),
        title: Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.black87)),
        subtitle: Text(sub, style: const TextStyle(color: Colors.black87)),
      ),
    );
  }
}

class _Live extends StatelessWidget {
  final DeviceStatus st;
  final Policy policy;
  const _Live({required this.st, required this.policy});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final req = st.requiredMs > 0 ? st.requiredMs : null;
    final progress = req == null
        ? (st.requiredBeats > 0 ? st.usableBeats / st.requiredBeats : 0.0)
        : st.usableMs / req;
    final q = st.quality;
    final age = DateTime.now().difference(st.received).inSeconds;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Live quality score', style: t.labelLarge),
      const SizedBox(height: 4),
      Row(children: [
        Expanded(
          child: LinearProgressIndicator(
            value: q == null ? 0 : q / 100,
            minHeight: 18,
            borderRadius: BorderRadius.circular(6),
            color: q == null ? cs.outline : (q >= policy.confThreshold * 100 ? Colors.green.shade600 : Colors.orange.shade700),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(width: 64, child: Text(q == null ? 'n/a' : '$q', style: t.headlineSmall, textAlign: TextAlign.right)),
      ]),
      Text(
        'Window quality score (${st.qualityDef}); usable beats need confidence ≥ ${(policy.confThreshold * 100).round()} %. '
        'Last beat confidence: ${st.beatConf == null ? '—' : (st.beatConf! * 100).toStringAsFixed(0)} %',
        style: t.bodySmall,
      ),
      const SizedBox(height: 16),
      Text('Usable time ${fmtDuration(st.usableMs)} / ${req == null ? '—' : fmtDuration(req)}', style: t.titleMedium),
      const SizedBox(height: 4),
      LinearProgressIndicator(value: progress.clamp(0, 1).toDouble(), minHeight: 10, borderRadius: BorderRadius.circular(5)),
      const SizedBox(height: 12),
      Wrap(spacing: 24, runSpacing: 8, children: [
        _stat(context, 'Elapsed', fmtDuration(st.elapsedMs)),
        _stat(context, 'Usable beats', '${st.usableBeats}${st.requiredBeats > 0 ? ' / ${st.requiredBeats}' : ''}'),
        _stat(context, 'Current run', '${st.runBeats} beats · ${fmtDuration(st.runMs)}'),
        _stat(context, 'Longest run', '${st.longestRunBeats} beats · ${fmtDuration(st.longestRunMs)}'),
        if (st.state == DeviceState.armed) _stat(context, 'Reliable audio', fmtDuration(st.armMs)),
        _stat(context, 'Reason', st.reason.isEmpty ? '—' : st.reason),
        _stat(context, 'Link', st.crcErrors + st.seqGaps + st.overruns == 0
            ? 'OK'
            : 'CRC ${st.crcErrors} · gaps ${st.seqGaps} · overruns ${st.overruns}'),
        if (age > 3) _stat(context, 'Telemetry', 'stale (${age}s)'),
      ]),
    ]);
  }

  Widget _stat(BuildContext context, String k, String v) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(k, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        Text(v, style: Theme.of(context).textTheme.bodyLarge),
      ]);
}
