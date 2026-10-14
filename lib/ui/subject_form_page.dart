import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../data/db.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'recording_page.dart';

/// Subject registration (spec 01 §6.1). Only label, age/DOB and sex are required;
/// optional fields never block recording and stay null when empty.
class SubjectFormPage extends StatefulWidget {
  final Subject? existing; // new take for an existing subject
  const SubjectFormPage({super.key, this.existing});
  @override
  State<SubjectFormPage> createState() => _SubjectFormPageState();
}

const _optionalFields = {
  'site': 'Site / location',
  'operator': 'Operator ID',
  'body_position': 'Body position',
  'auscultation_location': 'Auscultation location',
  'device_placement': 'Device placement',
  'conditions': 'Acquisition conditions',
};

/// Per-take recording checklist (spec 01 §14.1): reproducibility, not required to record.
const takeChecklist = {
  'posture': ['Supine', 'Sitting', 'Standing', 'Left lateral', 'Other'],
  'auscultation_site': ['Aortic', 'Pulmonic', 'Tricuspid', 'Mitral', 'Other'],
  'contact': ['Bare skin', 'Through thin clothing', 'Gel / coupling medium'],
  'ambient_noise': ['Quiet', 'Moderate', 'Noisy'],
  'breathing': ['Normal', 'Breath hold', 'Deep breathing'],
};

class _SubjectFormPageState extends State<SubjectFormPage> {
  final checklist = <String, String>{};
  final operatorId = TextEditingController();
  final _form = GlobalKey<FormState>();
  late final String subjectId = widget.existing?.id ?? const Uuid().v4();
  final label = TextEditingController();
  final age = TextEditingController();
  final height = TextEditingController();
  final weight = TextEditingController();
  final notes = TextEditingController();
  final extra = {for (final k in _optionalFields.keys) k: TextEditingController()};
  DateTime? dob;
  bool useDob = false;
  String? sex;

  @override
  void initState() {
    super.initState();
    context.read<AppState>().db.getMeta('operator_id').then((v) => operatorId.text = v ?? '');
    final s = widget.existing;
    if (s != null) {
      label.text = s.label;
      dob = s.dateOfBirth;
      useDob = s.dateOfBirth != null;
      age.text = s.ageYears?.toStringAsFixed(0) ?? '';
      sex = s.sex;
      height.text = s.heightCm?.toString() ?? '';
      weight.text = s.weightKg?.toString() ?? '';
      notes.text = s.notes;
      for (final e in s.fields.entries) {
        extra[e.key]?.text = e.value;
      }
    }
  }

  double? _num(TextEditingController c) => c.text.trim().isEmpty ? null : double.tryParse(c.text.trim());

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    final app = context.read<AppState>();
    final ds = app.active!;
    final s = Subject(
      id: subjectId,
      datasetId: widget.existing?.datasetId ?? ds.id,
      label: label.text.trim(),
      dateOfBirth: useDob ? dob : null,
      ageYears: useDob ? null : _num(age),
      sex: sex!,
      heightCm: _num(height),
      weightKg: _num(weight),
      fields: {for (final e in extra.entries) if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim()},
      notes: notes.text.trim(),
      createdAt: widget.existing?.createdAt ?? DateTime.now(),
    );
    // 1) subject saved locally first, 2) recording session record in pending state
    await app.db.saveSubject(s);
    final take = await app.db.nextTake(s.id);
    final rec = Recording(
      id: const Uuid().v4(),
      datasetId: ds.id,
      subjectId: s.id,
      takeIndex: take,
      state: RecState.pending,
      createdAt: DateTime.now(),
    )..settingsRev = ds.settingsRev;
    await app.db.saveRecording(rec);
    final op = operatorId.text.trim();
    await app.db.setMeta('operator_id', op.isEmpty ? null : op);
    await app.db.setChecklist(rec.id, {...checklist, if (op.isNotEmpty) 'operator_id': op});
    await app.refresh();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => RecordingPage(recordingId: rec.id)));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? 'New subject' : 'New take')),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          KV('Dataset', app.active?.name ?? '—'),
          KV('Subject ID', '${shortId(subjectId)}  ($subjectId)'),
          const SizedBox(height: 12),
          TextFormField(
            controller: label,
            decoration: const InputDecoration(
              labelText: 'Participant label *',
              helperText: 'A participant code is recommended over a real name',
              border: OutlineInputBorder(),
            ),
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
          ),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Age')),
              ButtonSegment(value: true, label: Text('Date of birth')),
            ],
            selected: {useDob},
            onSelectionChanged: (v) => setState(() => useDob = v.first),
          ),
          const SizedBox(height: 8),
          if (!useDob)
            TextFormField(
              controller: age,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Age *', suffixText: 'years', border: OutlineInputBorder()),
              validator: (v) {
                final a = double.tryParse(v ?? '');
                return (a == null || a < 0 || a > 120) ? 'Enter an age between 0 and 120' : null;
              },
            )
          else
            FormField<DateTime>(
              validator: (_) => dob == null ? 'Required' : null,
              builder: (f) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(dob == null ? 'Select date of birth *' : 'Born ${dob!.toIso8601String().substring(0, 10)}'),
                subtitle: f.hasError ? Text(f.errorText!, style: TextStyle(color: Theme.of(context).colorScheme.error)) : null,
                trailing: const Icon(Icons.calendar_month),
                onTap: () async {
                  final d = await showDatePicker(
                      context: context, firstDate: DateTime(1900), lastDate: DateTime.now(), initialDate: dob ?? DateTime(1990));
                  if (d != null) setState(() => dob = d);
                },
              ),
            ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: sex,
            decoration: const InputDecoration(labelText: 'Sex / gender *', border: OutlineInputBorder()),
            items: [for (final o in sexOptions) DropdownMenuItem(value: o, child: Text(o))],
            onChanged: (v) => setState(() => sex = v),
            validator: (v) => v == null ? 'Required (choose "Prefer not to say" or "Unknown" if needed)' : null,
          ),
          const SectionTitle('Optional'),
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: height,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Height', suffixText: 'cm', border: OutlineInputBorder()),
                validator: (v) => (v ?? '').isEmpty || (double.tryParse(v!) ?? -1) > 0 ? null : 'Invalid',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: weight,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Weight', suffixText: 'kg', border: OutlineInputBorder()),
                validator: (v) => (v ?? '').isEmpty || (double.tryParse(v!) ?? -1) > 0 ? null : 'Invalid',
              ),
            ),
          ]),
          for (final e in _optionalFields.entries) ...[
            const SizedBox(height: 12),
            TextFormField(
              controller: extra[e.key],
              decoration: InputDecoration(labelText: e.value, border: const OutlineInputBorder()),
            ),
          ],
          const SizedBox(height: 12),
          TextFormField(
            controller: notes,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Notes', border: OutlineInputBorder()),
          ),
          const SectionTitle('Take checklist (this recording)'),
          TextField(
            controller: operatorId,
            decoration: const InputDecoration(labelText: 'Operator ID', helperText: 'Remembered on this phone', border: OutlineInputBorder()),
          ),
          for (final e in takeChecklist.entries) ...[
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: checklist[e.key],
              decoration: InputDecoration(labelText: e.key.replaceAll('_', ' '), border: const OutlineInputBorder()),
              items: [for (final o in e.value) DropdownMenuItem(value: o, child: Text(o))],
              onChanged: (v) => setState(() => v == null ? checklist.remove(e.key) : checklist[e.key] = v),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _submit,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Submit and prepare recording'),
          ),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }
}
