import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'common.dart';

/// Dataset summary cards. (Distributions, filters and export arrive in milestone M3.)
class DsStatsPage extends StatelessWidget {
  const DsStatsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final recs = app.recordings.where((r) => r.onPhone).toList();
    final complete = recs.where((r) => r.state == RecState.complete).length;
    final captured = recs.fold<double>(0, (a, r) => a + (r.durationMs ?? 0));
    final usable = recs.fold<double>(0, (a, r) => a + (r.usableMs ?? 0));
    Widget card(String k, String v) => SizedBox(
          width: 170,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(k, style: Theme.of(context).textTheme.labelMedium),
                const SizedBox(height: 4),
                Text(v, style: Theme.of(context).textTheme.headlineSmall),
              ]),
            ),
          ),
        );
    return ListView(padding: const EdgeInsets.all(12), children: [
      Wrap(children: [
        card('Subjects', '${app.subjects.length}'),
        card('Recordings', '$complete complete / ${recs.length - complete} incomplete'),
        card('Captured', fmtDuration(captured)),
        card('Usable', fmtDuration(usable)),
        card('Usable ratio', captured > 0 ? fmtPct(usable / captured) : '—'),
        card('Not transferred', '${app.recordings.where((r) => !r.onPhone).length}'),
      ]),
      const Padding(
        padding: EdgeInsets.all(8),
        child: Text('Counts cover recordings verified on this phone. Detailed distributions come in the next milestone.'),
      ),
    ]);
  }
}
