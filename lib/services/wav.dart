import 'dart:io';
import 'dart:typed_data';

import '../core/protocol.dart';

/// Minimal PCM WAV reader/validator for the canonical device format
/// (RIFF/WAVE, PCM, mono, 16-bit, 8000 Hz).
class WavInfo {
  final int sampleRate, channels, bitsPerSample, dataOffset, dataBytes;
  WavInfo(this.sampleRate, this.channels, this.bitsPerSample, this.dataOffset, this.dataBytes);
  int get sampleCount => dataBytes ~/ (channels * bitsPerSample ~/ 8);

  bool get isCanonical => sampleRate == kSampleRate && channels == 1 && bitsPerSample == 16;

  static WavInfo parse(Uint8List b) {
    if (b.length < 44) throw const FormatException('WAV too short');
    final d = ByteData.sublistView(b);
    String tag(int o) => String.fromCharCodes(b.sublist(o, o + 4));
    if (tag(0) != 'RIFF' || tag(8) != 'WAVE') throw const FormatException('Not a RIFF/WAVE file');
    var off = 12;
    int? rate, ch, bits, fmt;
    while (off + 8 <= b.length) {
      final id = tag(off);
      final size = d.getUint32(off + 4, Endian.little);
      if (id == 'fmt ') {
        fmt = d.getUint16(off + 8, Endian.little);
        ch = d.getUint16(off + 10, Endian.little);
        rate = d.getUint32(off + 12, Endian.little);
        bits = d.getUint16(off + 22, Endian.little);
      } else if (id == 'data') {
        if (fmt != 1 || rate == null) throw const FormatException('Unsupported WAV encoding');
        final avail = b.length - off - 8;
        if (size > avail) throw const FormatException('WAV data chunk is truncated');
        return WavInfo(rate, ch!, bits!, off + 8, size);
      }
      off += 8 + size + (size & 1);
    }
    throw const FormatException('WAV has no data chunk');
  }

  static Future<WavInfo> ofFile(File f) async => parse(await f.readAsBytes());

  /// Samples as int16 (copy, little-endian safe).
  static Int16List samples(Uint8List b, WavInfo w) {
    final out = Int16List(w.sampleCount);
    final d = ByteData.sublistView(b, w.dataOffset, w.dataOffset + w.dataBytes);
    for (var i = 0; i < out.length; i++) {
      out[i] = d.getInt16(i * 2, Endian.little);
    }
    return out;
  }

  /// Builds a canonical WAV file from int16 samples.
  static Uint8List build(Int16List pcm, {int rate = kSampleRate}) {
    final h = ByteData(44);
    void s(int o, String v) => v.codeUnits.asMap().forEach((i, c) => h.setUint8(o + i, c));
    s(0, 'RIFF');
    h.setUint32(4, 36 + pcm.length * 2, Endian.little);
    s(8, 'WAVEfmt ');
    h.setUint32(16, 16, Endian.little);
    h.setUint16(20, 1, Endian.little);
    h.setUint16(22, 1, Endian.little);
    h.setUint32(24, rate, Endian.little);
    h.setUint32(28, rate * 2, Endian.little);
    h.setUint16(32, 2, Endian.little);
    h.setUint16(34, 16, Endian.little);
    s(36, 'data');
    h.setUint32(40, pcm.length * 2, Endian.little);
    final out = BytesBuilder(copy: false)
      ..add(h.buffer.asUint8List())
      ..add(Uint8List.view(pcm.buffer, pcm.offsetInBytes, pcm.lengthInBytes));
    return out.toBytes();
  }
}
