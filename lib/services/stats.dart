import 'dart:math';

/// Quantile convention used everywhere in the app: linear interpolation between
/// order statistics, h = (N - 1)·p (Hyndman & Fan type 7; numpy/R default).
double quantile(List<double> sorted, double p) {
  if (sorted.isEmpty) return double.nan;
  final h = (sorted.length - 1) * p;
  final lo = h.floor(), hi = h.ceil();
  return sorted[lo] + (h - lo) * (sorted[hi] - sorted[lo]);
}

/// Summary of one variable over one analysis unit (e.g. per recording).
class Summary {
  final int n, missing;
  final double mean, min, p25, p50, p75, max;
  final int outliers; // Tukey: < Q1 - 1.5 IQR or > Q3 + 1.5 IQR (statistical, not "bad")

  const Summary(this.n, this.missing, this.mean, this.min, this.p25, this.p50, this.p75, this.max, this.outliers);

  /// [values] may contain nulls (missing); NaN is treated as missing too.
  factory Summary.of(Iterable<double?> values) {
    final v = <double>[];
    var missing = 0;
    for (final x in values) {
      if (x == null || x.isNaN) {
        missing++;
      } else {
        v.add(x);
      }
    }
    if (v.isEmpty) return Summary(0, missing, double.nan, double.nan, double.nan, double.nan, double.nan, double.nan, 0);
    v.sort();
    final q1 = quantile(v, 0.25), q3 = quantile(v, 0.75), iqr = q3 - q1;
    final out = v.where((x) => x < q1 - 1.5 * iqr || x > q3 + 1.5 * iqr).length;
    return Summary(v.length, missing, v.reduce((a, b) => a + b) / v.length, v.first, q1, quantile(v, 0.5), q3, v.last, out);
  }

  Map<String, Object?> toJson() => {
        'n': n, 'missing': missing,
        'mean': _j(mean), 'min': _j(min), 'p25': _j(p25), 'p50': _j(p50), 'p75': _j(p75), 'p100': _j(max),
        'tukey_outliers': outliers,
      };
  static double? _j(double x) => x.isNaN ? null : x;
}

/// Counts per category, including an explicit missing bucket.
class Counts {
  final Map<String, int> counts;
  final int missing;
  const Counts(this.counts, this.missing);
  int get n => counts.values.fold(0, (a, b) => a + b);

  factory Counts.of(Iterable<String?> values) {
    final c = <String, int>{};
    var missing = 0;
    for (final v in values) {
      if (v == null || v.trim().isEmpty) {
        missing++;
      } else {
        c[v.trim()] = (c[v.trim()] ?? 0) + 1;
      }
    }
    final sorted = Map.fromEntries(c.entries.toList()..sort((a, b) => b.value.compareTo(a.value)));
    return Counts(sorted, missing);
  }

  /// Numeric values binned into labelled ranges [edges[i], edges[i+1]).
  factory Counts.binned(Iterable<double?> values, List<double> edges, String Function(double lo, double hi) label) {
    final c = {for (var i = 0; i < edges.length - 1; i++) label(edges[i], edges[i + 1]): 0};
    var missing = 0;
    final keys = c.keys.toList();
    for (final v in values) {
      if (v == null || v.isNaN) {
        missing++;
        continue;
      }
      var i = 0;
      while (i < edges.length - 2 && v >= edges[i + 1]) {
        i++;
      }
      c[keys[i]] = c[keys[i]]! + 1;
    }
    return Counts(c, missing);
  }

  /// Even bins over the data range (for height/weight histograms).
  factory Counts.histogram(Iterable<double?> values, {int bins = 6, String unit = ''}) {
    final v = values.whereType<double>().where((x) => !x.isNaN).toList();
    if (v.isEmpty) return Counts.of(values.map((_) => null));
    final lo = v.reduce(min).floorToDouble(), hi = v.reduce(max).ceilToDouble() + 1;
    final step = ((hi - lo) / bins).ceilToDouble().clamp(1, double.infinity);
    final edges = [for (var i = 0; i <= bins; i++) lo + i * step];
    return Counts.binned(values, edges, (a, b) => '${a.toStringAsFixed(0)}–${b.toStringAsFixed(0)}$unit');
  }
}
