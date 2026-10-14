import 'package:flutter/material.dart' hide Interval;
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'player.dart';
import 'package:path/path.dart' as p;

/// Recording detail: subject + capture metadata and quality summary.
/// (Playback, timeline and annotations arrive in milestone M2.)
class RecordingDetailPage extends StatefulWidget {
  final String recordingId;
  const RecordingDetailPage({super.key, required this.recordingId});
  @override
  State<RecordingDetailPage> createState() => _RecordingDetailPageState();
}

class _RecordingDetailPageState extends State<RecordingDetailPage> {
  Recording? r;
  Subject? s;
  List<Interval> quality = [], beats = [];
  final notes = TextEditingController();
  final tags = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = context.read<AppState>().db;
    r = await db.recording(widget.recordingId);
    s = r == null ? null : await db.subject(r!.subjectId);
    if (r != null) {
      quality = await db.qualityIntervals(r!.id);
      beats = await db.beats(r!.id);
      notes.text = r!.notes;
      tags.text = r!.tags;
    }
    if (mounted) setState(() {});
  }

  /// Notes, tags and review are user annotations; they never change algorithmic labels.
  Future<void> _saveAnnotations({bool? reviewed}) async {
    final app = context.read<AppState>();
    r!
      ..notes = notes.text.trim()
      ..tags = tags.text.trim();
    if (reviewed != null) r!.reviewedAt = reviewed ? DateTime.now() : null;
    await app.db.saveRecording(r!);
    await app.refresh();
    if (mounted) {
      setState(() {});
      snack(context, 'Saved');
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = this.r;
    if (r == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final s = this.s;
    final m = r.meta ?? {};
    final audio = (m['audio'] ?? {}) as Map;
    final tr = (m['transport'] ?? {}) as Map;
    final gaps = (m['gaps'] ?? []) as List;
    return Scaffold(
      appBar: AppBar(title: Text('${s?.label ?? 'Recording'} · take ${r.takeIndex}')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (m['simulated'] == true)
          const Card(child: ListTile(leading: Icon(Icons.science), title: Text('Synthetic recording from the simulated device'))),
        if (!r.onPhone)
          Card(
            child: ListTile(
              leading: const Icon(Icons.cloud_off),
              title: Text('${RecState.label(r.state)} · not yet transferred'),
              subtitle: Text(r.transferError ?? 'Use Sync or Download to copy it from the device.'),
            ),
          ),
        if (r.onPhone) ...[
          const SectionTitle('Playback'),
          RecordingPlayer(
            wavPath: p.join(r.localDir!, 'audio.wav'),
            cacheDir: p.join(context.read<AppState>().root, 'cache', r.id),
            quality: quality,
            beats: beats,
          ),
        ],
        const SectionTitle('Review'),
        TextField(controller: notes, maxLines: 3, decoration: const InputDecoration(labelText: 'Notes', border: OutlineInputBorder())),
        const SizedBox(height: 8),
        TextField(controller: tags, decoration: const InputDecoration(labelText: 'Tags (comma separated)', border: OutlineInputBorder())),
        const SizedBox(height: 8),
        Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilledButton.tonal(onPressed: () => _saveAnnotations(), child: const Text('Save notes')),
          r.reviewedAt == null
              ? OutlinedButton.icon(onPressed: () => _saveAnnotations(reviewed: true), icon: const Icon(Icons.task_alt), label: const Text('Mark reviewed'))
              : TextButton.icon(onPressed: () => _saveAnnotations(reviewed: false), icon: const Icon(Icons.task_alt, color: Colors.green),
                  label: Text('Reviewed ${fmtDate(r.reviewedAt)} — undo')),
        ]),
        const SectionTitle('Subject'),
        KV('Label', s?.label ?? '—'),
        KV('Subject ID', r.subjectId),
        KV('Age at capture', fmtNum(s?.ageAt(r.startAt ?? r.createdAt), digits: 1, unit: ' y')),
        KV('Sex / gender', s?.sex ?? '—'),
        KV('Height', fmtNum(s?.heightCm, digits: 0, unit: ' cm')),
        KV('Weight', fmtNum(s?.weightKg, digits: 1, unit: ' kg')),
        for (final e in (s?.fields ?? {}).entries) KV(e.key.replaceAll('_', ' '), e.value),
        if ((s?.notes ?? '').isNotEmpty) KV('Notes', s!.notes),
        const SectionTitle('Quality'),
        KV('State', '${RecState.label(r.state)}${r.completionReason == null ? '' : ' (${r.completionReason})'}'),
        KV('Usable time', '${fmtDuration(r.usableMs)} of ${fmtDuration(r.durationMs)}'),
        KV('Usable ratio', '${fmtPct(r.usableRatio)} (usable / scored time)'),
        KV('Usable beats', '${r.usableBeats ?? '—'} of ${r.totalBeats ?? '—'}'),
        KV('Longest usable run', '${r.longestRunBeats ?? '—'} beats · ${fmtDuration(r.longestRunMs)}'),
        KV('Mean beat confidence', fmtPct(r.meanConf)),
        KV('SNR', r.snrDb == null ? 'not available' : '${r.snrDb!.toStringAsFixed(1)} dB'),
        KV('Clipping', r.clippingRatio == null ? '—' : '${(r.clippingRatio! * 100).toStringAsFixed(2)} % of samples (informational)'),
        if ((tr['uart_crc_errors'] ?? 0) != 0 || gaps.isNotEmpty)
          KV('Link integrity', '${gaps.length} gap(s) in this recording (zero-filled, labelled unscored)'),
        const SectionTitle('Capture'),
        KV('Recording ID', r.id),
        KV('Dataset ID', r.datasetId),
        KV('Start', fmtDate(r.startAt)),
        KV('End', fmtDate(r.endAt)),
        KV('Firmware', 'RV ${r.firmwareRv ?? '—'}'),
        KV('Model', r.modelVersion ?? '—'),
        KV('Settings revision', '${r.settingsRev ?? '—'}'),
        KV('Format', audio.isEmpty ? '—' : '${audio['sample_rate_hz']} Hz · ${audio['bits_per_sample']}-bit · ${audio['channels']} ch WAV'),
        KV('File size', fmtBytes(r.fileSize)),
        KV('SHA-256', r.sha256 ?? '—'),
        KV('Transfer', r.onPhone ? 'verified on phone' : r.transferState),
        KV('Device', r.deviceId ?? '—'),
      ]),
    );
  }
}
