import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'common.dart';

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = context.read<AppState>().db;
    r = await db.recording(widget.recordingId);
    s = r == null ? null : await db.subject(r!.subjectId);
    if (mounted) setState(() {});
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
