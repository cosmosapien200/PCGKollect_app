import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import '../state/device_controller.dart';
import 'common.dart';
import 'recording_detail_page.dart';
import 'recording_page.dart';
import 'subject_form_page.dart';

enum _Sort { newest, subject, quality, duration }

enum _Filter { all, needsReview, complete, incomplete, notTransferred, transferError }

class DataPage extends StatefulWidget {
  const DataPage({super.key});
  @override
  State<DataPage> createState() => _DataPageState();
}

class _DataPageState extends State<DataPage> {
  String query = '';
  _Sort sort = _Sort.newest;
  _Filter filter = _Filter.all;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    var rows = app.recordings.map((r) => (r, app.subjectById(r.subjectId))).toList();
    final q = query.trim().toLowerCase();
    if (q.isNotEmpty) {
      rows = rows.where((x) {
        final s = x.$2;
        return (s?.label.toLowerCase().contains(q) ?? false) ||
            shortId(x.$1.subjectId).toLowerCase().contains(q) ||
            shortId(x.$1.id).toLowerCase().contains(q);
      }).toList();
    }
    rows = rows.where((x) => switch (filter) {
          _Filter.all => true,
          _Filter.needsReview => needsReview(x.$1),
          _Filter.complete => x.$1.state == RecState.complete,
          _Filter.incomplete => x.$1.state != RecState.complete,
          _Filter.notTransferred => !x.$1.onPhone,
          _Filter.transferError => x.$1.transferError != null,
        }).toList();
    rows.sort((a, b) => switch (sort) {
          _Sort.newest => b.$1.createdAt.compareTo(a.$1.createdAt),
          _Sort.subject => (a.$2?.label ?? '').toLowerCase().compareTo((b.$2?.label ?? '').toLowerCase()),
          _Sort.quality => (b.$1.usableRatio ?? -1).compareTo(a.$1.usableRatio ?? -1),
          _Sort.duration => (b.$1.durationMs ?? -1).compareTo(a.$1.durationMs ?? -1),
        });

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _newRecording(context),
        icon: const Icon(Icons.fiber_manual_record),
        label: const Text('New recording'),
      ),
      body: RefreshIndicator(
        onRefresh: app.refresh,
        child: CustomScrollView(slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Column(children: [
                TextField(
                  decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search), hintText: 'Search name or ID', border: OutlineInputBorder(), isDense: true),
                  onChanged: (v) => setState(() => query = v),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: DropdownButton<_Filter>(
                      isExpanded: true,
                      value: filter,
                      items: const [
                        DropdownMenuItem(value: _Filter.all, child: Text('All statuses')),
                        DropdownMenuItem(value: _Filter.needsReview, child: Text('Review queue')),
                        DropdownMenuItem(value: _Filter.complete, child: Text('Complete')),
                        DropdownMenuItem(value: _Filter.incomplete, child: Text('Incomplete')),
                        DropdownMenuItem(value: _Filter.notTransferred, child: Text('Not yet transferred')),
                        DropdownMenuItem(value: _Filter.transferError, child: Text('Transfer error')),
                      ],
                      onChanged: (v) => setState(() => filter = v!),
                    ),
                  ),
                  const SizedBox(width: 12),
                  DropdownButton<_Sort>(
                    value: sort,
                    items: const [
                      DropdownMenuItem(value: _Sort.newest, child: Text('Newest')),
                      DropdownMenuItem(value: _Sort.subject, child: Text('Subject')),
                      DropdownMenuItem(value: _Sort.quality, child: Text('Quality')),
                      DropdownMenuItem(value: _Sort.duration, child: Text('Duration')),
                    ],
                    onChanged: (v) => setState(() => sort = v!),
                  ),
                ]),
              ]),
            ),
          ),
          SliverToBoxAdapter(child: _DataChecks(subjects: app.subjects)),
          if (rows.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('No recordings yet. Tap "New recording" to register a subject.')),
            )
          else
            SliverList.separated(
              itemCount: rows.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (c, i) => _RecordingTile(rec: rows[i].$1, subject: rows[i].$2),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 88)),
        ]),
      ),
    );
  }

  Future<void> _newRecording(BuildContext context) async {
    final app = context.read<AppState>();
    if (!context.read<DeviceController>().connected) {
      snack(context, 'Connect the device first (tap the connection status).', error: true);
      return;
    }
    Subject? existing;
    if (app.subjects.isNotEmpty) {
      final choice = await showModalBottomSheet<Object>(
        context: context,
        builder: (c) => SafeArea(
          child: ListView(shrinkWrap: true, children: [
            ListTile(leading: const Icon(Icons.person_add), title: const Text('New subject'), onTap: () => Navigator.pop(c, 'new')),
            const Divider(),
            const Padding(padding: EdgeInsets.fromLTRB(16, 8, 16, 4), child: Text('New take for an existing subject')),
            for (final s in app.subjects.reversed)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(s.label),
                subtitle: Text(shortId(s.id)),
                onTap: () => Navigator.pop(c, s),
              ),
          ]),
        ),
      );
      if (choice == null) return;
      if (choice is Subject) existing = choice;
    }
    if (!context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SubjectFormPage(existing: existing)));
  }
}

/// Review queue (spec 01 §14.3): incomplete, low-coverage (< 50 %) or not yet reviewed takes.
bool needsReview(Recording r) =>
    r.onPhone && (r.state != RecState.complete || (r.usableRatio ?? 0) < 0.5 || r.reviewedAt == null);

/// Duplicate and missing-data checks (spec 01 §14.4).
class _DataChecks extends StatelessWidget {
  final List<Subject> subjects;
  const _DataChecks({required this.subjects});

  @override
  Widget build(BuildContext context) {
    final byLabel = <String, int>{};
    for (final s in subjects) {
      final k = s.label.trim().toLowerCase();
      byLabel[k] = (byLabel[k] ?? 0) + 1;
    }
    final dup = byLabel.entries.where((e) => e.value > 1).map((e) => e.key).toList();
    final noMeta = subjects.where((s) => s.heightCm == null || s.weightKg == null).length;
    if (dup.isEmpty && noMeta == 0) return const SizedBox.shrink();
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Card(
        color: Colors.amber.shade100,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (dup.isNotEmpty)
              Text('Possible duplicate subjects (same label): ${dup.join(', ')}', style: t.bodyMedium?.copyWith(color: Colors.black87)),
            if (noMeta > 0)
              Text('$noMeta subject(s) without height/weight', style: t.bodyMedium?.copyWith(color: Colors.black87)),
          ]),
        ),
      ),
    );
  }
}

class _RecordingTile extends StatelessWidget {
  final Recording rec;
  final Subject? subject;
  const _RecordingTile({required this.rec, required this.subject});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final s = subject;
    final age = s?.ageAt(rec.startAt ?? rec.createdAt);
    final meta = [
      if (age != null) '${age.floor()} y',
      if (s != null) s.sex,
      if (s?.heightCm != null) '${s!.heightCm!.toStringAsFixed(0)} cm',
      if (s?.weightKg != null) '${s!.weightKg!.toStringAsFixed(1)} kg',
    ].join(' · ');
    final (status, color) = rec.transferError != null && !rec.onPhone
        ? ('Transfer error', cs.error)
        : !rec.onPhone && !RecState.terminal(rec.state)
            ? (RecState.label(rec.state), Colors.blue.shade700)
            : !rec.onPhone
                ? ('${RecState.label(rec.state)} · not yet transferred', Colors.orange.shade800)
                : rec.state == RecState.complete
                    ? ('Complete', Colors.green.shade700)
                    : (RecState.label(rec.state), Colors.orange.shade800);
    return ListTile(
      // an unfinished take reopens the live screen (the device keeps recording without the app)
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => !rec.onPhone && !RecState.terminal(rec.state)
              ? RecordingPage(recordingId: rec.id)
              : RecordingDetailPage(recordingId: rec.id))),
      title: Text(s?.label ?? 'Unknown subject', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${shortId(rec.subjectId)} · take ${rec.takeIndex} · ${fmtDate(rec.startAt ?? rec.createdAt)}',
            style: t.bodyMedium),
        if (meta.isNotEmpty) Text(meta, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(height: 2),
        Row(children: [
          Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 6),
          Flexible(child: Text(status, style: t.labelMedium?.copyWith(color: color))),
          if (rec.usableMs != null) ...[
            const SizedBox(width: 12),
            Text('usable ${fmtDuration(rec.usableMs)} (${fmtPct(rec.usableRatio)})', style: t.labelMedium),
          ],
        ]),
      ]),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right),
    );
  }
}
