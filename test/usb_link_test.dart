import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pcgkolect_app/core/frames.dart';
import 'package:pcgkolect_app/core/protocol.dart';
import 'package:pcgkolect_app/device/device_link.dart';
import 'package:pcgkolect_app/device/usb_link.dart';

/// Stands in for the RV1103 on the USB link: answers ops like control_server/file_service.
class FakeRv implements UsbTransport {
  final _out = StreamController<Uint8List>();
  final _parser = FrameParser();
  final Uint8List file;
  int seq = 0, reads = 0;
  int dropReadAt = -1; // offset whose first read answer is lost
  bool unplugOnManifest = false;
  FakeRv(this.file);

  @override
  Stream<Uint8List> get data => _out.stream;

  void _send(int type, List<int> payload) {
    final f = encodeFrame(type, seq++, payload);
    // split delivery, as USB transfers do
    _out.add(Uint8List.sublistView(f, 0, f.length ~/ 2));
    _out.add(Uint8List.sublistView(f, f.length ~/ 2));
  }

  void _rsp(Map<String, dynamic> req, Map<String, dynamic> body) =>
      _send(FrameType.rsp, utf8.encode(jsonEncode({'v': 1, 'id': req['id'], 'st': 'OK', ...body})));

  @override
  Future<void> write(Uint8List bytes) async {
    for (final f in _parser.add(bytes)) {
      final r = jsonDecode(utf8.decode(f.data)) as Map<String, dynamic>;
      switch (r['op']) {
        case 'hello':
          _rsp(r, {'device_id': 'pcgk-001122334455', 'rv_fw': 't'});
          _send(FrameType.evt, utf8.encode('{"ev":"status","state":"CONFIGURED","q":90}'));
        case 'manifest':
          if (unplugOnManifest) {
            await _out.close();
            return;
          }
          final off = r['offset'] as int;
          final all = [
            for (var i = 0; i < 8; i++)
              {'recording_id': 'r$i', 'files': {'audio': {'size': file.length, 'sha256': 'x'}}}
          ];
          _rsp(r, {'total': all.length, 'items': all.skip(off).take(r['limit'] as int).toList()});
        case 'open':
          _rsp(r, {'handle': 3, 'size': file.length, 'sha256': sha256.convert(file).toString()});
        case 'read':
          reads++;
          final off = r['offset'] as int;
          if (off == dropReadAt) {
            dropReadAt = -1;
            break;
          }
          final end = (off + (r['len'] as int)).clamp(0, file.length);
          final p = BytesBuilder()
            ..add((ByteData(4)..setUint32(0, r['id'] as int, Endian.little)).buffer.asUint8List())
            ..add((ByteData(4)..setUint32(0, off, Endian.little)).buffer.asUint8List())
            ..add(file.sublist(off.clamp(0, file.length), end));
          _send(FrameType.chunk, p.takeBytes());
        case 'close':
          _rsp(r, {});
        default:
          _send(FrameType.rsp, utf8.encode(jsonEncode({'v': 1, 'id': r['id'], 'st': 'UNSUPPORTED', 'err': 'UNKNOWN_OP'})));
      }
    }
  }

  @override
  Future<void> close() async {
    if (!_out.isClosed) await _out.close();
  }
}

void main() {
  test('frame codec matches the firmware test vector and resyncs after garbage', () {
    final f = encodeFrame(FrameType.req, 0, utf8.encode('{}'));
    expect(f, [0xA5, 0x5C, 0x02, 0x00, 0x01, 0x00, 0x7B, 0x7D, 0x7D, 0x88]);
    final p = FrameParser();
    final bad = Uint8List.fromList(f)..[7] ^= 1;
    final got = [
      ...p.add(Uint8List.fromList([0x00, 0xA5, 0x11, ...bad.sublist(0, 4)])),
      ...p.add(Uint8List.fromList([...bad.sublist(4), 0xA5, 0x5C, 0x02])),
      ...p.add(Uint8List.fromList(f.sublist(3))),
    ];
    expect(p.crcErrors, 1);
    expect(got.length, 1); // corrupt frame dropped; the frame split across adds is reassembled
    expect(utf8.decode(got.single.data), '{}');
    expect(p.add(Uint8List.fromList(f)).length, 1);
  });

  test('USB link: hello identity, telemetry, paged manifest, pipelined resumable download', () async {
    final file = Uint8List.fromList(List.generate(50000, (i) => (i * 31 + 7) & 0xFF));
    final rv = FakeRv(file)..dropReadAt = 8192;
    final link = UsbLink(rv);
    final tlm = link.telemetry.first;
    await link.connect();
    expect(link.deviceId, 'pcgk-001122334455');
    expect((await tlm).quality, 90);
    expect(() => link.call('wifi_status'), throwsA(isA<DeviceError>()));

    final fs = link.fileSource(const WifiStatus.off())!;
    final m = await fs.manifest();
    expect(m.map((e) => e.recordingId), List.generate(8, (i) => 'r$i'));

    final dir = await Directory.systemTemp.createTemp('usb_test');
    final dest = File('${dir.path}/audio.wav');
    await dest.writeAsBytes(file.sublist(0, 4096)); // partial from an earlier attempt
    final sha = await fs.download('r0', 'audio', dest);
    expect(await dest.readAsBytes(), file);
    expect(sha, sha256.convert(file).toString());
    await link.disconnect();
    await dir.delete(recursive: true);
  });

  test('USB link: unplugging fails the pending request and reports disconnected', () async {
    final rv = FakeRv(Uint8List(10))..unplugOnManifest = true;
    final link = UsbLink(rv);
    await link.connect();
    final states = <LinkState>[];
    link.state.listen(states.add);
    await expectLater(link.call('manifest', {'offset': 0, 'limit': 6}), throwsA(isA<DeviceError>()));
    await Future<void>.delayed(Duration.zero);
    expect(link.currentState, LinkState.disconnected);
    expect(states, contains(LinkState.disconnected));
  });
}
