import 'package:flutter_test/flutter_test.dart';
import 'package:pcgkolect_app/data/models.dart';
import 'package:pcgkolect_app/services/export_service.dart';
import 'package:pcgkolect_app/services/stats.dart';

void main() {
  test('quantiles follow the type-7 convention (numpy default)', () {
    final v = <double>[1, 2, 3, 4, 10];
    // numpy.percentile([1,2,3,4,10], [25,50,75,100]) -> 2, 3, 4, 10
    expect(quantile(v, 0.25), 2);
    expect(quantile(v, 0.5), 3);
    expect(quantile(v, 0.75), 4);
    expect(quantile(v, 1), 10);
    expect(quantile([1.0, 2], 0.5), 1.5);
  });

  test('summary counts missing values and Tukey outliers', () {
    final s = Summary.of([1, 2, 3, 4, 10, null, double.nan]);
    expect(s.n, 5);
    expect(s.missing, 2);
    expect(s.mean, 4);
    expect(s.min, 1);
    expect(s.max, 10);
    expect(s.outliers, 1, reason: '10 > Q3 + 1.5*IQR = 7');
  });

  test('empty data stays missing, never zero', () {
    final s = Summary.of([null, null]);
    expect(s.n, 0);
    expect(s.missing, 2);
    expect(s.mean.isNaN, isTrue);
    expect(s.toJson()['mean'], isNull);
  });

  test('category and binned counts', () {
    final c = Counts.of(['F', 'M', 'F', null, '']);
    expect(c.counts, {'F': 2, 'M': 1});
    expect(c.missing, 2);
    final b = Counts.binned([5, 25, 30, 80, null], [0, 18, 30, 200], (a, b) => '$a');
    expect(b.counts.values.toList(), [1, 1, 2]);
    expect(b.missing, 1);
  });

  test('CSV keeps UUIDs and leaves missing values empty', () {
    final r = Recording(id: 'rid-1', datasetId: 'ds-1', subjectId: 'sub-1', takeIndex: 2, createdAt: DateTime.utc(2026))
      ..usableMs = 1500
      ..snrDb = null;
    final s = Subject(id: 'sub-1', datasetId: 'ds-1', label: 'P, 01', createdAt: DateTime.utc(2026));
    final csv = ExportService.recordingsCsv([r], {'sub-1': s}).split('\n');
    final header = csv[0].split(',');
    expect(header.first, 'dataset_id');
    expect(csv[1], startsWith('ds-1,sub-1,rid-1,2,"P, 01"'));
    final snrIdx = header.indexOf('snr_db');
    // find the snr column in the row (quoted label contains one comma)
    final cells = csv[1].replaceFirst('"P, 01"', 'P01').split(',');
    expect(cells[snrIdx], '');
  });
}
