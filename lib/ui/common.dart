import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/protocol.dart';
import '../state/device_controller.dart';

String fmtDuration(num? ms) {
  if (ms == null) return '—';
  final s = ms / 1000;
  if (s < 60) return '${s.toStringAsFixed(1)} s';
  final m = s ~/ 60;
  final r = (s - m * 60).round();
  if (m < 60) return '${m}m ${r.toString().padLeft(2, '0')}s';
  return '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
}

String fmtPct(num? v) => v == null ? '—' : '${(v * 100).toStringAsFixed(0)}%';
String fmtNum(num? v, {int digits = 1, String unit = ''}) =>
    v == null ? '—' : '${v.toStringAsFixed(digits)}$unit';
String fmtDate(DateTime? t) => t == null ? '—' : DateFormat('yyyy-MM-dd HH:mm').format(t);

String fmtBytes(num? b) {
  if (b == null) return '—';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${u[i]}';
}

void snack(BuildContext context, String msg, {bool error = false}) {
  final cs = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg, style: error ? TextStyle(color: cs.onErrorContainer) : null),
    backgroundColor: error ? cs.errorContainer : null,
    closeIconColor: error ? cs.onErrorContainer : null,
    showCloseIcon: true,
  ));
}

/// Runs a device command and reports a readable error; returns null on failure.
Future<T?> guarded<T>(BuildContext context, Future<T> Function() fn) async {
  try {
    return await fn();
  } on DeviceError catch (e) {
    if (context.mounted) snack(context, e.message, error: true);
  } catch (e) {
    if (context.mounted) snack(context, '$e', error: true);
  }
  return null;
}

Future<bool> confirm(BuildContext context, String title, String body,
    {String ok = 'Continue', bool destructive = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error) : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// Disconnected / Connecting / Connected / Busy / Error indicator (spec 01 §3).
class ConnChip extends StatelessWidget {
  final VoidCallback? onTap;
  const ConnChip({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final dev = context.watch<DeviceController>();
    final cs = Theme.of(context).colorScheme;
    final (label, color, icon) = switch (dev.ui) {
      ConnUi.disconnected => ('Disconnected', cs.outline, Icons.bluetooth_disabled),
      ConnUi.connecting => ('Connecting', Colors.amber.shade700, Icons.bluetooth_searching),
      ConnUi.connected => ('Connected', Colors.green.shade700, Icons.bluetooth_connected),
      ConnUi.busy => ('Busy', Colors.blue.shade700, Icons.sync),
      ConnUi.error => ('Error', cs.error, Icons.error_outline),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: onTap == null
          ? Chip(
              avatar: Icon(icon, size: 18, color: color),
              label: Text(dev.isSimulated ? '$label (sim)' : label),
              side: BorderSide(color: color),
            )
          : ActionChip(
              avatar: Icon(icon, size: 18, color: color),
              label: Text(dev.isSimulated ? '$label (sim)' : label),
              side: BorderSide(color: color),
              onPressed: onTap,
            ),
    );
  }
}

/// Small labelled value used in detail/stat lists.
class KV extends StatelessWidget {
  final String k;
  final String v;
  const KV(this.k, this.v, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 170, child: Text(k, style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant))),
        Expanded(child: SelectableText(v, style: t.bodyMedium)),
      ]),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  const SectionTitle(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      );
}
