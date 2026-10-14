import 'package:flutter_test/flutter_test.dart';
import 'package:pcgkolect_app/core/protocol.dart';
import 'package:pcgkolect_app/data/db.dart';
import 'package:pcgkolect_app/data/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('saving rows keeps v2 columns (checklist, calibration) and audit is recorded', () async {
    final db = await AppDb.open(path: inMemoryDatabasePath);
    final now = DateTime.now();
    final ds = Dataset(id: 'ds-1', name: 'A', createdAt: now, updatedAt: now, policy: Policy());
    await db.saveDataset(ds);
    await db.setCalibration(ds.id, {'analog_gain_db': '20'});
    ds.name = 'B';
    await db.saveDataset(ds);
    expect(await db.calibration(ds.id), {'analog_gain_db': '20'});

    await db.saveSubject(Subject(id: 's-1', datasetId: ds.id, label: 'P1', createdAt: now));
    final r = Recording(id: 'r-1', datasetId: ds.id, subjectId: 's-1', takeIndex: 1, createdAt: now);
    await db.saveRecording(r);
    await db.setChecklist(r.id, {'posture': 'Supine'});
    r.notes = 'edited';
    await db.saveRecording(r);
    expect(await db.checklist(r.id), {'posture': 'Supine'});
    expect((await db.recording(r.id))!.checklist['posture'], 'Supine');

    await db.audit(ds.id, 'settings_saved', 'rev 2');
    expect((await db.auditLog(ds.id)).single['action'], 'settings_saved');
    await db.savePreset('Adult protocol', Policy(targetUsableS: 60).toJson());
    expect((await db.presets())['Adult protocol']!['target_usable_s'], 60);
    await db.db.close();
  });
}
