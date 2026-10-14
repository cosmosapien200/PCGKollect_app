import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/protocol.dart';
import '../data/db.dart';
import '../data/models.dart';

/// Datasets and the active dataset; everything shown is scoped to [active].
class AppState extends ChangeNotifier {
  final AppDb db;
  final String root; // app-private storage
  List<Dataset> datasets = [];
  Dataset? active;
  List<Subject> subjects = [];
  List<Recording> recordings = [];

  AppState(this.db, this.root);

  Future<void> load() async {
    datasets = await db.datasets();
    final id = await db.getMeta('active_dataset');
    active = datasets.where((d) => d.id == id).firstOrNull ?? datasets.firstOrNull;
    await _loadScoped();
  }

  Future<void> _loadScoped() async {
    if (active == null) {
      subjects = [];
      recordings = [];
    } else {
      subjects = await db.subjects(active!.id);
      recordings = await db.recordings(active!.id);
    }
    notifyListeners();
  }

  Future<void> refresh() async {
    datasets = await db.datasets();
    if (active != null) active = await db.dataset(active!.id) ?? active;
    await _loadScoped();
  }

  Subject? subjectById(String id) => subjects.where((s) => s.id == id).firstOrNull;

  Future<Dataset> createDataset(String name) async {
    final now = DateTime.now();
    final d = Dataset(id: const Uuid().v4(), name: name.trim(), createdAt: now, updatedAt: now, policy: Policy());
    await db.saveDataset(d); // throws DuplicateNameException
    datasets = await db.datasets();
    await switchTo(d);
    return d;
  }

  Future<void> switchTo(Dataset d) async {
    active = d;
    await db.setMeta('active_dataset', d.id);
    await _loadScoped();
  }

  Future<void> rename(Dataset d, String name) async {
    final old = d.name;
    d
      ..name = name.trim()
      ..updatedAt = DateTime.now();
    try {
      await db.saveDataset(d);
    } catch (e) {
      d.name = old;
      rethrow;
    }
    await refresh();
  }

  Future<void> archive(Dataset d) async {
    d
      ..archived = true
      ..updatedAt = DateTime.now();
    await db.saveDataset(d);
    datasets = await db.datasets();
    if (active?.id == d.id) {
      active = datasets.firstOrNull;
      await db.setMeta('active_dataset', active?.id);
    }
    await _loadScoped();
  }

  /// Saves edited settings as a new revision (the device keeps the old one until Activate DS).
  Future<void> saveSettings(Dataset d, Policy p) async {
    d
      ..policy = p
      ..settingsRev = d.settingsRev + 1
      ..updatedAt = DateTime.now();
    await db.saveDataset(d);
    await refresh();
  }

  Future<void> markActivated(Dataset d, int rev) async {
    d
      ..deviceRev = rev
      ..deviceSyncedAt = DateTime.now();
    await db.saveDataset(d);
    await refresh();
  }
}
