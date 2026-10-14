import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pcgkolect_app/core/protocol.dart';
import 'package:pcgkolect_app/services/wav.dart';

void main() {
  group('BLE fragmentation', () {
    test('round-trips messages at any MTU', () {
      final msg = jsonEncode({'v': 1, 'id': 7, 'op': 'set_dataset', 'name': 'x' * 900});
      for (final mtu in [23, 64, 185, 517]) {
        Map<String, dynamic>? got;
        final r = Reassembler((m) => got = m);
        final frags = fragment(msg, mtu);
        expect(frags.first[0] & 0x80, 0x80, reason: 'FIRST flag');
        expect(frags.last[0] & 0x40, 0x40, reason: 'LAST flag');
        for (final f in frags) {
          expect(f.length, lessThanOrEqualTo(mtu - 3));
          r.add(f);
        }
        expect(got?['name'], 'x' * 900);
      }
    });

    test('a FIRST fragment discards a stale partial message', () {
      final out = <Map<String, dynamic>>[];
      final r = Reassembler(out.add);
      r.add(Uint8List.fromList([0x80, ...utf8.encode('{"bro')])); // never finished
      r.add(Uint8List.fromList([0xC0, ...utf8.encode('{"ok":1}')]));
      expect(out, [
        {'ok': 1}
      ]);
    });
  });

  group('Policy validation mirrors the firmware', () {
    test('defaults are valid', () => expect(Policy().validate(), isEmpty));
    test('needs a time or beat target', () {
      expect(Policy(targetUsableS: 0).validate(), isNotEmpty);
      expect(Policy(targetUsableS: 0, targetUsableBeats: 30).validate(), isEmpty);
    });
    test('contiguous run cannot exceed the total target', () {
      expect(Policy(targetUsableS: 20, minRunS: 30).validate(), isNotEmpty);
      expect(Policy(targetUsableBeats: 10, minRunBeats: 12).validate(), isNotEmpty);
    });
    test('max duration must exceed the usable target', () {
      expect(Policy(targetUsableS: 60, maxDurationS: 60).validate(), isNotEmpty);
    });
    test('ranges', () {
      expect(Policy(confThreshold: 0.4).validate(), isNotEmpty);
      expect(Policy(confThreshold: 0.995).validate(), isNotEmpty);
      expect(Policy(telemetryHz: 6).validate(), isNotEmpty);
    });
    test('json round trip', () {
      final p = Policy(confThreshold: 0.85, rhythmCheck: false, targetUsableBeats: 40);
      expect(Policy.fromJson(jsonDecode(jsonEncode(p.toJson()))).toJson(), p.toJson());
    });
  });

  group('WAV', () {
    test('build and parse the canonical format', () {
      final pcm = Int16List.fromList(List.generate(8000, (i) => (i % 200) - 100));
      final bytes = WavInfo.build(pcm);
      final w = WavInfo.parse(bytes);
      expect(w.isCanonical, isTrue);
      expect(w.sampleCount, 8000);
      expect(WavInfo.samples(bytes, w), pcm);
    });
    test('rejects truncated data', () {
      final bytes = WavInfo.build(Int16List(100));
      expect(() => WavInfo.parse(bytes.sublist(0, 100)), throwsFormatException);
    });
  });

  test('device status parses telemetry and keeps null quality', () {
    final s = DeviceStatus.fromJson({'state': 'RECORDING', 'q': null, 'us_ms': 1500, 'link': {'crc': 2}});
    expect(s.state, DeviceState.recording);
    expect(s.quality, isNull);
    expect(s.usableMs, 1500);
    expect(s.crcErrors, 2);
  });
}
