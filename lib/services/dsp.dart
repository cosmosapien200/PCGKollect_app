import 'dart:math';
import 'dart:typed_data';

import '../data/models.dart';

/// Second-order IIR section (RBJ cookbook), direct form I.
class Biquad {
  final double b0, b1, b2, a1, a2;
  const Biquad(this.b0, this.b1, this.b2, this.a1, this.a2);

  /// Butterworth-style section (Q = 1/sqrt(2) gives a 2nd-order Butterworth).
  factory Biquad.highpass(double fc, double fs, [double q = 0.7071067811865476]) {
    final w = 2 * pi * fc / fs, c = cos(w), al = sin(w) / (2 * q), a0 = 1 + al;
    return Biquad((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - al) / a0);
  }

  factory Biquad.lowpass(double fc, double fs, [double q = 0.7071067811865476]) {
    final w = 2 * pi * fc / fs, c = cos(w), al = sin(w) / (2 * q), a0 = 1 + al;
    return Biquad((1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0, -2 * c / a0, (1 - al) / a0);
  }

  void apply(Float64List x) {
    double x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    for (var i = 0; i < x.length; i++) {
      final x0 = x[i];
      final y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
      x2 = x1;
      x1 = x0;
      y2 = y1;
      y1 = y0;
      x[i] = y0;
    }
  }
}

/// 20–800 Hz band-pass for playback ("Enhance"). 4th-order Butterworth high-pass and
/// low-pass (two sections each), run forward and backward (zero phase) so heart
/// sounds stay aligned with the original timeline. Never applied to stored audio.
Int16List bandpass(Int16List pcm, {double lo = 20, double hi = 800, double fs = 8000}) {
  final x = Float64List(pcm.length);
  for (var i = 0; i < pcm.length; i++) {
    x[i] = pcm[i].toDouble();
  }
  // Butterworth Qs for a 4th-order cascade: 0.5412 and 1.3066
  final sections = [
    Biquad.highpass(lo, fs, 0.5411961), Biquad.highpass(lo, fs, 1.3065630),
    Biquad.lowpass(hi, fs, 0.5411961), Biquad.lowpass(hi, fs, 1.3065630),
  ];
  for (final s in sections) {
    s.apply(x);
  }
  _reverse(x);
  for (final s in sections) {
    s.apply(x);
  }
  _reverse(x);
  final out = Int16List(pcm.length);
  for (var i = 0; i < x.length; i++) {
    out[i] = x[i].round().clamp(-32768, 32767);
  }
  return out;
}

void _reverse(Float64List x) {
  for (var i = 0, j = x.length - 1; i < j; i++, j--) {
    final t = x[i];
    x[i] = x[j];
    x[j] = t;
  }
}

/// One piece of the "useful audio" playback and where it came from.
class Segment {
  final int srcStart, srcEnd; // original sample axis
  final int dstStart; // position in the concatenated audio
  const Segment(this.srcStart, this.srcEnd, this.dstStart);
  int get length => srcEnd - srcStart;
}

class UsefulAudio {
  final Int16List pcm;
  final List<Segment> map;
  const UsefulAudio(this.pcm, this.map);

  /// Original sample index for a playback position in the concatenated audio.
  int toSource(int dst) {
    for (final s in map) {
      if (dst < s.dstStart + s.length) return s.srcStart + max(0, dst - s.dstStart);
    }
    return map.isEmpty ? 0 : map.last.srcEnd;
  }

  /// Playback position for an original sample (start of the next usable piece if outside).
  int toPlayback(int src) {
    for (final s in map) {
      if (src < s.srcEnd) return s.dstStart + max(0, src - s.srcStart);
    }
    return pcm.length;
  }
}

/// Merges usable intervals (gaps <= [joinGap] samples are bridged) in temporal order.
List<(int, int)> usableRanges(List<Interval> beats, {int joinGap = 800}) {
  final u = beats.where((b) => b.label == 'usable').toList()..sort((a, b) => a.startSample.compareTo(b.startSample));
  final out = <(int, int)>[];
  for (final b in u) {
    if (out.isNotEmpty && b.startSample <= out.last.$2 + joinGap) {
      out[out.length - 1] = (out.last.$1, max(out.last.$2, b.endSample));
    } else {
      out.add((b.startSample, b.endSample));
    }
  }
  return out;
}

/// Concatenates the usable ranges with 10 ms fades at every joint (no clicks).
UsefulAudio buildUseful(Int16List pcm, List<(int, int)> ranges, {int fade = 80}) {
  final map = <Segment>[];
  var total = 0;
  for (final r in ranges) {
    final a = r.$1.clamp(0, pcm.length), b = r.$2.clamp(0, pcm.length);
    if (b <= a) continue;
    map.add(Segment(a, b, total));
    total += b - a;
  }
  final out = Int16List(total);
  for (final s in map) {
    for (var i = 0; i < s.length; i++) {
      var v = pcm[s.srcStart + i].toDouble();
      final edge = min(i, s.length - 1 - i);
      if (edge < fade) v *= edge / fade;
      out[s.dstStart + i] = v.round();
    }
  }
  return UsefulAudio(out, map);
}

/// Min/max envelope for drawing a waveform with [buckets] columns.
Float32List envelope(Int16List pcm, int buckets) {
  final out = Float32List(buckets * 2);
  if (pcm.isEmpty) return out;
  final per = pcm.length / buckets;
  for (var b = 0; b < buckets; b++) {
    final a = (b * per).floor(), e = min(pcm.length, ((b + 1) * per).ceil());
    var lo = 0, hi = 0;
    for (var i = a; i < e; i++) {
      if (pcm[i] < lo) lo = pcm[i];
      if (pcm[i] > hi) hi = pcm[i];
    }
    out[2 * b] = lo / 32768;
    out[2 * b + 1] = hi / 32768;
  }
  return out;
}
