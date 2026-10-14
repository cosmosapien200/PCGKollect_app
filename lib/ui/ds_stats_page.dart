import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/models.dart';
import '../services/export_service.dart';
import '../services/stats.dart';
import '../state/app_state.dart';
import 'common.dart';

/// Dataset statistics (spec 01 §8). Analysis unit: recording (quality) and
/// subject (balance). Recordings count only once verified on the phone.
class DsStatsPage extends StatefulWidget {
  const DsStatsPage({super.key});
  @override
  State<DsStatsPage> createState() => _DsStatsPageState();
}

enum _Status { all, complete, incomplete }

class _DsStatsPageState extends State<DsStatsPage> {
  DateTimeRange? range;
  _Status status = _Status.all;
  String? operator, site;
  bool completeMetaOnly = false;

  static bool _metaComplete(Subject s) =>
      s.heightCm != null && s.weightKg != null && (s.fields['site'] ?? '').isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final subjects = {for (final s in app.subjects) s.id: s};
    final allOnPhone = app.recordings.where((r) => r.onPhone).toList();
    final recs = allOnPhone.where((r) {
      final s = subjects[r.subjectId];
      final t = r.startAt ?? r.createdAt;
      if (range != null && (t.isBefore(range!.start) || t.isAfter(range!.end.add(const Duration(days: 1))))) return false;
      if (status == _Status.complete && r.state != RecState.complete) return false;
      if (status == _Status.incomplete && r.state == RecState.complete) return false;
      if (operator != null && s?.fields['operator'] != operator) return false;
      if (site != null && s?.fields['site'] != site) return false;
      if (completeMetaOnly && (s == null || !_metaComplete(s))) return false;
      return true;
    }).toList();
    final filtered = range != null || status != _Status.all || operator != null || site != null || completeMetaOnly;
    final subs = filtered ? recs.map((r) => subjects[r.subjectId]).whereType<Subject>().toSet().toList() : app.subjects;

    final captured = recs.fold<double>(0, (a, r) => a + (r.durationMs ?? 0));
    final usable = recs.fold<double>(0, (a, r) => a + (r.usableMs ?? 0));
    final complete = recs.where((r) => r.state == RecState.complete).length;
    final dur = Summary.of(recs.map((r) => r.durationMs));
    final ratio = Summary.of(recs.map((r) => r.usableRatio));
    final snr = Summary.of(recs.map((r) => r.snrDb));
    final operators = app.subjects.map((s) => s.fields['operator']).whereType<String>().toSet().toList()..sort();
    final sites = app.subjects.map((s) => s.fields['site']).whereType<String>().toSet().toList()..sort();

    Widget card(String k, String v) => SizedBox(
          width: 168,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(k, style: Theme.of(context).textTheme.labelMedium),
                const SizedBox(height: 4),
                Text(v, style: Theme.of(context).textTheme.titleLarge),
              ]),
            ),
          ),
        );

    return ListView(padding: const EdgeInsets.all(12), children: [
      // ---- filters
      Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        ActionChip(
          avatar: const Icon(Icons.date_range, size: 18),
          label: Text(range == null ? 'Any date' : '${fmtDate(range!.start).substring(0, 10)} – ${fmtDate(range!.end).substring(0, 10)}'),
          onPressed: () async {
            final r = await showDateRangePicker(context: context, firstDate: DateTime(2024), lastDate: DateTime.now().add(const Duration(days: 1)));
            setState(() => range = r);
          },
        ),
        DropdownButton<_Status>(
          value: status,
          items: const [
            DropdownMenuItem(value: _Status.all, child: Text('All statuses')),
            DropdownMenuItem(value: _Status.complete, child: Text('Complete')),
            DropdownMenuItem(value: _Status.incomplete, child: Text('Incomplete')),
          ],
          onChanged: (v) => setState(() => status = v!),
        ),
        if (operators.isNotEmpty)
          DropdownButton<String?>(
            value: operator,
            hint: const Text('Operator'),
            items: [const DropdownMenuItem(value: null, child: Text('Any operator')), for (final o in operators) DropdownMenuItem(value: o, child: Text(o))],
            onChanged: (v) => setState(() => operator = v),
          ),
        if (sites.isNotEmpty)
          DropdownButton<String?>(
            value: site,
            hint: const Text('Location'),
            items: [const DropdownMenuItem(value: null, child: Text('Any location')), for (final o in sites) DropdownMenuItem(value: o, child: Text(o))],
            onChanged: (v) => setState(() => site = v),
          ),
        FilterChip(label: const Text('Complete metadata'), selected: completeMetaOnly, onSelected: (v) => setState(() => completeMetaOnly = v)),
        if (filtered)
          TextButton(
            onPressed: () => setState(() {
              range = null;
              status = _Status.all;
              operator = site = null;
              completeMetaOnly = false;
            }),
            child: const Text('Clear filters'),
          ),
      ]),
      // ---- cards
      Wrap(children: [
        card('Subjects', '${subs.length}'),
        card('Recordings', '$complete complete\n${recs.length - complete} incomplete'),
        card('Captured', fmtDuration(captured)),
        card('Usable', fmtDuration(usable)),
        card('Usable / captured', captured > 0 ? fmtPct(usable / captured) : '—'),
        card('Mean SNR', snr.n == 0 ? 'not available' : '${snr.mean.toStringAsFixed(1)} dB'),
        card('Median duration', dur.n == 0 ? '—' : fmtDuration(dur.p50)),
        card('Median coverage\n(usable / scored)', ratio.n == 0 ? '—' : fmtPct(ratio.p50)),
      ]),
      if (app.recordings.length > allOnPhone.length)
        Padding(
          padding: const EdgeInsets.all(4),
          child: Text('${app.recordings.length - allOnPhone.length} recording(s) not yet transferred are excluded.',
              style: Theme.of(context).textTheme.bodySmall),
        ),
      // ---- balance
      const SectionTitle('Dataset balance (per subject)'),
      _Bars('Age at first recording',
          Counts.binned(subs.map((s) => s.ageAt(s.createdAt)), [0, 18, 30, 45, 60, 75, 200], (a, b) => b >= 200 ? '${a.toInt()}+' : '${a.toInt()}–${(b - 1).toInt()}')),
      _Bars('Sex / gender', Counts.of(subs.map((s) => s.sex))),
      _Bars('Height', Counts.histogram(subs.map((s) => s.heightCm), unit: ' cm')),
      _Bars('Weight', Counts.histogram(subs.map((s) => s.weightKg), unit: ' kg')),
      for (final f in const {
        'site': 'Site / location',
        'operator': 'Operator',
        'body_position': 'Body position',
        'auscultation_location': 'Auscultation location',
      }.entries)
        if (subs.any((s) => (s.fields[f.key] ?? '').isNotEmpty)) _Bars(f.value, Counts.of(subs.map((s) => s.fields[f.key]))),
      // ---- quality distribution
      const SectionTitle('Quality distribution (per recording)'),
      _SummaryTable(rows: [
        ('Recording duration', Summary.of(recs.map((r) => r.durationMs == null ? null : r.durationMs! / 1000)), 's'),
        ('Usable duration', Summary.of(recs.map((r) => r.usableMs == null ? null : r.usableMs! / 1000)), 's'),
        ('Coverage (usable/scored)', Summary.of(recs.map((r) => r.usableRatio == null ? null : r.usableRatio! * 100)), '%'),
        ('SNR', snr, 'dB'),
        ('Mean beat confidence', Summary.of(recs.map((r) => r.meanConf == null ? null : r.meanConf! * 100)), '%'),
        ('Usable beats', Summary.of(recs.map((r) => r.usableBeats?.toDouble())), ''),
        ('Link gaps', Summary.of(recs.map((r) => ((r.meta?['gaps'] as List?)?.length)?.toDouble())), ''),
      ]),
      Text(
        'Percentiles: linear interpolation, h = (N−1)p. Outliers: Tukey fences (below Q1 − 1.5·IQR or above Q3 + 1.5·IQR); '
        'these are statistical outliers, not automatically bad recordings. Each recording is one observation.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      // ---- export
      const SectionTitle('Export'),
      Text('Exports include participant labels and keep all UUIDs. Share them only under your study\'s data policy.',
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(onPressed: () => _export(context, 'csv', recs, subs), icon: const Icon(Icons.table_chart), label: const Text('CSV')),
        OutlinedButton.icon(onPressed: () => _export(context, 'json', recs, subs), icon: const Icon(Icons.data_object), label: const Text('JSON summary')),
        FilledButton.tonalIcon(onPressed: () => _export(context, 'zip', recs, subs), icon: const Icon(Icons.archive), label: const Text('ZIP backup (audio + sidecars)')),
      ]),
      const SizedBox(height: 24),
    ]);
  }

  Future<void> _export(BuildContext context, String kind, List<Recording> recs, List<Subject> subs) async {
    final app = context.read<AppState>();
    final svc = ExportService(p.join(app.root, 'exports'));
    final ds = app.active!;
    final f = await guarded(context, () => switch (kind) {
          'csv' => svc.exportCsv(ds, subs, recs),
          'json' => svc.exportJson(ds, subs, recs),
          _ => svc.exportZip(ds, subs, recs),
        });
    if (f == null) return;
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], subject: 'PCGKolect export — ${ds.name}'));
  }
}

class _Bars extends StatelessWidget {
  final String title;
  final Counts c;
  const _Bars(this.title, this.c);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final maxV = c.counts.values.fold<int>(0, (a, b) => a > b ? a : b);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: t.titleSmall),
          Text('N = ${c.n}, missing = ${c.missing}', style: t.bodySmall),
          const SizedBox(height: 6),
          if (c.n == 0) Text('No values yet', style: t.bodySmall),
          for (final e in c.counts.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                SizedBox(width: 110, child: Text(e.key, style: t.bodyMedium, overflow: TextOverflow.ellipsis)),
                Expanded(
                  child: LayoutBuilder(
                    builder: (c2, box) => Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        height: 16,
                        width: maxV == 0 ? 0 : box.maxWidth * e.value / maxV,
                        color: cs.primary,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 72,
                  child: Text('${e.value} (${c.n == 0 ? 0 : (100 * e.value / c.n).round()}%)', textAlign: TextAlign.right, style: t.bodySmall),
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}

class _SummaryTable extends StatelessWidget {
  final List<(String, Summary, String)> rows;
  const _SummaryTable({required this.rows});

  @override
  Widget build(BuildContext context) {
    String f(double v) => v.isNaN ? '—' : (v.abs() >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1));
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 14,
        columns: const [
          DataColumn(label: Text('Variable')),
          DataColumn(label: Text('N'), numeric: true),
          DataColumn(label: Text('Missing'), numeric: true),
          DataColumn(label: Text('Mean'), numeric: true),
          DataColumn(label: Text('Min'), numeric: true),
          DataColumn(label: Text('P25'), numeric: true),
          DataColumn(label: Text('P50'), numeric: true),
          DataColumn(label: Text('P75'), numeric: true),
          DataColumn(label: Text('P100'), numeric: true),
          DataColumn(label: Text('Outliers'), numeric: true),
        ],
        rows: [
          for (final r in rows)
            DataRow(cells: [
              DataCell(Text(r.$3.isEmpty ? r.$1 : '${r.$1} (${r.$3})')),
              DataCell(Text('${r.$2.n}')),
              DataCell(Text('${r.$2.missing}')),
              DataCell(Text(f(r.$2.mean))),
              DataCell(Text(f(r.$2.min))),
              DataCell(Text(f(r.$2.p25))),
              DataCell(Text(f(r.$2.p50))),
              DataCell(Text(f(r.$2.p75))),
              DataCell(Text(f(r.$2.max))),
              DataCell(Text('${r.$2.outliers}')),
            ]),
        ],
      ),
    );
  }
}
