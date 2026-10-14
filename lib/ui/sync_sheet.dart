import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../services/sync_service.dart';
import '../state/app_state.dart';
import '../state/device_controller.dart';
import 'common.dart';

/// Download (deleteAfter = false) or Sync (deleteAfter = true) with live progress.
Future<void> showSyncSheet(BuildContext context, {required bool deleteAfter}) async {
  final dev = context.read<DeviceController>();
  if (!dev.connected) {
    snack(context, 'Connect the device first.', error: true);
    return;
  }
  await dev.refreshWifi();
  if (!context.mounted) return;
  if (dev.fileSource() == null) {
    snack(context, 'The device is not on the phone hotspot yet. Open Device Settings → Wi-Fi transfer.', error: true);
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    builder: (_) => _SyncSheet(deleteAfter: deleteAfter),
  );
}

class _SyncSheet extends StatefulWidget {
  final bool deleteAfter;
  const _SyncSheet({required this.deleteAfter});
  @override
  State<_SyncSheet> createState() => _SyncSheetState();
}

class _SyncSheetState extends State<_SyncSheet> {
  SyncProgress? p;
  SyncResult? result;
  String? fatal;
  bool running = true;
  final log = <String>[];
  final skipped = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final app = context.read<AppState>();
    final dev = context.read<DeviceController>();
    try {
      final svc = SyncService(app.db, app.root);
      result = await svc.run(
        link: dev.link!,
        files: dev.fileSource()!,
        deleteAfter: widget.deleteAfter,
        deviceId: dev.deviceId,
        onProgress: (x) {
          if (!mounted) return;
          setState(() {
            p = x;
            if (x.phase == 'skip') skipped.add(x.recordingId);
            if (x.phase == 'done' || x.phase == 'error') {
              log.add('${shortId(x.recordingId)}: ${x.phase == 'error' ? 'failed — ${x.error}' : skipped.contains(x.recordingId) ? 'already on phone' : 'downloaded + verified'}'
                  '${x.phase == 'done' && widget.deleteAfter ? ', device copy deleted' : ''}');
            }
          });
        },
      );
    } catch (e) {
      fatal = '$e';
    }
    await app.refresh();
    await dev.refresh().catchError((_) {});
    if (mounted) setState(() => running = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final x = p;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.deleteAfter ? 'Sync' : 'Download recordings', style: t.titleLarge),
          Text(
            widget.deleteAfter
                ? 'Each recording is downloaded, hash-verified and saved on the phone; only then is the device copy deleted.'
                : 'Recordings are copied and verified; device copies are kept.',
            style: t.bodySmall,
          ),
          const SizedBox(height: 16),
          if (running) ...[
            Text(x == null ? 'Checking the device on the hotspot…' : 'Recording ${x.index + 1} of ${x.total} · ${x.phase}'),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: x == null || x.bytesTotal == 0 ? null : x.bytes / x.bytesTotal),
            if (x != null && x.bytesTotal > 0) Text('${fmtBytes(x.bytes)} / ${fmtBytes(x.bytesTotal)}', style: t.bodySmall),
          ],
          if (fatal != null) Text(fatal!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (result != null) Text(result.toString(), style: t.bodyLarge),
          if (log.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView(shrinkWrap: true, children: [for (final l in log) Text(l, style: t.bodySmall)]),
            ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(onPressed: running ? null : () => Navigator.pop(context), child: const Text('Close')),
          ),
        ]),
      ),
    );
  }
}
