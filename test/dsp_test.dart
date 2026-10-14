import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pcgkolect_app/data/models.dart';
import 'package:pcgkolect_app/services/dsp.dart';

Int16List tone(double f, {int n = 16000, double amp = 10000}) =>
    Int16List.fromList(List.generate(n, (i) => (amp * sin(2 * pi * f * i / 8000)).round()));

double rms(Int16List x, {int skip = 2000}) {
  var s = 0.0;
  for (var i = skip; i < x.length - skip; i++) {
    s += x[i] * x[i].toDouble();
  }
  return sqrt(s / (x.length - 2 * skip));
}

void main() {
  test('band-pass keeps heart-sound band, removes drift and hiss', () {
    final pass = rms(bandpass(tone(100))) / rms(tone(100));
    final low = rms(bandpass(tone(3))) / rms(tone(3));
    final high = rms(bandpass(tone(2500))) / rms(tone(2500));
    expect(pass, closeTo(1.0, 0.05));
    expect(low, lessThan(0.05));
    expect(high, lessThan(0.05));
  });

  test('band-pass is zero phase (no time shift)', () {
    final x = tone(60);
    final y = bandpass(x);
    // peak correlation at lag 0
    double corr(int lag) {
      var s = 0.0;
      for (var i = 3000; i < 13000; i++) {
        s += x[i] * y[i + lag].toDouble();
      }
      return s;
    }
    expect(corr(0), greaterThan(corr(5)));
    expect(corr(0), greaterThan(corr(-5)));
  });

  test('useful audio concatenates usable beats and maps back to source time', () {
    final pcm = Int16List.fromList(List.generate(40000, (i) => i % 1000));
    final beats = [
      const Interval(1000, 9000, 'usable', 0.9, 0.1, 'OK'),
      const Interval(9000, 17000, 'unusable', 0.5, 0.6, 'LOW_CONF'),
      const Interval(17000, 25000, 'usable', 0.9, 0.1, 'OK'),
      const Interval(25200, 30000, 'usable', 0.9, 0.1, 'OK'), // 25 ms gap -> joined
    ];
    final ranges = usableRanges(beats);
    expect(ranges, [(1000, 9000), (17000, 30000)]);
    final u = buildUseful(pcm, ranges);
    expect(u.pcm.length, 8000 + 13000);
    expect(u.toSource(0), 1000);
    expect(u.toSource(8000), 17000);
    expect(u.toSource(8500), 17500);
    expect(u.toPlayback(17500), 8500);
    expect(u.toPlayback(12000), 8000, reason: 'unusable source time maps to the next usable piece');
    // interior samples are copied unchanged (only 10 ms fades at the joints)
    expect(u.pcm[4000], pcm[5000]);
  });
}
