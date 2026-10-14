import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pcgkolect_app/core/protocol.dart';
import 'package:pcgkolect_app/data/db.dart';
import 'package:pcgkolect_app/data/models.dart';
import 'package:pcgkolect_app/device/sim_link.dart';
import 'package:pcgkolect_app/services/sync_service.dart';
import 'package:pcgkolect_app/services/wav.dart';
import 'package:pcgkolect_app/state/app_state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// End-to-end against the simulated device: activate a dataset, prepare, auto-start,
/// reach the target, then verified sync with delete — and check every guard on the way.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmp;
  late AppState app;
  late SimLink sim;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pcgk');
    app = AppState(await AppDb.open(path: inMemoryDatabasePath), tmp.path);
    await app.load();
    sim = SimLink();
    await sim.connect();
  });

  tearDown(() async {
    await sim.disconnect();
    await app.db.db.close();
    await tmp.delete(recursive: true);
  });

  Future<DeviceStatus> waitFor(DeviceState s, {Duration timeout = const Duration(seconds: 40)}) =>
      sim.telemetry.firstWhere((t) => t.state == s).timeout(timeout);

  test('record, sync, verify, delete', () async {
    final ds = await app.createDataset('Study A');
    expect(() => app.createDataset('study a'), throwsA(isA<DuplicateNameException>()));
    await app.saveSettings(ds, Policy(targetUsableS: 4, autostartS: 2));

    // prepare is refused until the dataset is active with the same revision
    final args = {'dataset_id': ds.id, 'subject_id': 'aaaaaaaa-0000-4000-8000-000000000001',
      'recording_id': 'bbbbbbbb-0000-4000-8000-000000000001', 'rev': ds.settingsRev, 'take': 1};
    await expectLater(sim.call('prepare', args), throwsA(isA<DeviceError>().having((e) => e.code, 'code', 'DATASET_MISMATCH')));
    await sim.call('set_dataset', {'dataset_id': ds.id, 'name': ds.name, 'rev': ds.settingsRev, 'settings': ds.policy.toJson()});
    await app.db.saveSubject(Subject(id: args['subject_id'] as String, datasetId: ds.id, label: 'P001', createdAt: DateTime.now()));

    final armed = await sim.call('prepare', args);
    expect(armed['state'], 'ARMED');
    expect((await sim.call('prepare', args))['state'], 'ARMED', reason: 'prepare is idempotent');
    await waitFor(DeviceState.recording);
    final done = await waitFor(DeviceState.done);
    expect(done.usableMs, greaterThanOrEqualTo(4000));

    // delete before verification must be refused by the device
    final rid = args['recording_id'] as String;
    await expectLater(sim.call('delete', {'recording_id': rid, 'sha256': 'x'}),
        throwsA(isA<DeviceError>().having((e) => e.code, 'code', 'NOT_VERIFIED')));

    await sim.call('wifi_set', {'ssid': 'test-hotspot', 'pass': 'test-pass-123'});
    await Future.delayed(const Duration(milliseconds: 2200));
    final wifi = WifiStatus.fromJson(await sim.call('wifi_status'));
    final files = sim.fileSource(wifi)!;

    final svc = SyncService(app.db, tmp.path);
    final res = await svc.run(link: sim, files: files, deleteAfter: true);
    expect(res.imported, 1, reason: res.errors.join('; '));
    expect(res.deleted, 1);
    expect(sim.store, isEmpty);

    final r = (await app.db.recording(rid))!;
    expect(r.onPhone, isTrue);
    expect(r.state, RecState.complete);
    expect(r.usableMs, greaterThanOrEqualTo(4000));
    expect(r.snrDb, isNull, reason: 'missing SNR must stay null, never 0 dB');
    final wav = await WavInfo.ofFile(File('${r.localDir}/audio.wav'));
    expect(wav.isCanonical, isTrue);
    expect((await app.db.qualityIntervals(rid)), isNotEmpty);
    expect((await app.db.beats(rid)), isNotEmpty);

    // re-running is idempotent and never duplicates
    final again = await svc.run(link: sim, files: files, deleteAfter: true);
    expect(again.imported + again.alreadyHad, 0);
    expect((await app.db.recordings(ds.id)).length, 1);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a corrupt partial download is discarded, not trusted', () async {
    final ds = await app.createDataset('Study B');
    await sim.call('set_dataset', {'dataset_id': ds.id, 'name': ds.name, 'rev': ds.settingsRev,
      'settings': Policy(targetUsableS: 3).toJson()});
    const rid = 'cccccccc-0000-4000-8000-000000000002';
    await sim.call('prepare', {'dataset_id': ds.id, 'subject_id': 'dddddddd-0000-4000-8000-000000000003',
      'recording_id': rid, 'rev': ds.settingsRev, 'take': 1});
    await sim.call('force_start', {'recording_id': rid});
    await waitFor(DeviceState.done);
    await sim.call('wifi_set', {'ssid': 's', 'pass': 'test-pass-123'});
    await Future.delayed(const Duration(milliseconds: 2200));
    final files = sim.fileSource(WifiStatus.fromJson(await sim.call('wifi_status')))!;

    // plant garbage where a resumed audio download would start
    final part = File('${tmp.path}/tmp/$rid/audio.wav');
    await part.create(recursive: true);
    await part.writeAsBytes(List.filled(100, 7));
    final svc = SyncService(app.db, tmp.path);
    final res = await svc.run(link: sim, files: files, deleteAfter: true);
    expect(res.failed, 1, reason: 'hash mismatch must fail the item');
    expect(sim.store.containsKey(rid), isTrue, reason: 'device copy must survive a failed transfer');
    // the bad partial was removed, so the retry succeeds
    final retry = await svc.run(link: sim, files: files, deleteAfter: false);
    expect(retry.imported, 1, reason: retry.errors.join('; '));
    expect(sim.store[rid]!.verified, isTrue, reason: 'acked');
    expect(sim.store.containsKey(rid), isTrue, reason: 'Download keeps the device copy');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
