// Link message frames (PROTOCOL.md §1.2), used by the USB wired link (§5):
//
//   A5 5C | LEN u16 | TYPE u8 | SEQ u8 | DATA[LEN] | CRC16-CCITT-FALSE over LEN..DATA
//
// Audio frames (A5 5A) never travel to the phone; the parser skips anything that is not a
// valid message frame and resynchronises on the next A5 5C.
import 'dart:typed_data';

class FrameType {
  static const req = 0x01;
  static const rsp = 0x02;
  static const evt = 0x03;
  static const chunk = 0x10;
}

const int kMaxFramePayload = 4200;

int crc16(List<int> data, [int start = 0, int? end]) {
  var crc = 0xFFFF;
  for (var i = start; i < (end ?? data.length); i++) {
    crc ^= data[i] << 8;
    for (var j = 0; j < 8; j++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
    }
  }
  return crc;
}

Uint8List encodeFrame(int type, int seq, List<int> payload) {
  final n = payload.length;
  if (n > kMaxFramePayload) throw ArgumentError('frame payload $n > $kMaxFramePayload');
  final f = Uint8List(8 + n);
  f[0] = 0xA5;
  f[1] = 0x5C;
  f[2] = n & 0xFF;
  f[3] = n >> 8;
  f[4] = type;
  f[5] = seq & 0xFF;
  f.setRange(6, 6 + n, payload);
  final c = crc16(f, 2, 6 + n);
  f[6 + n] = c & 0xFF;
  f[7 + n] = c >> 8;
  return f;
}

typedef Frame = ({int type, Uint8List data});

/// Incremental parser: feed byte chunks as they arrive, get complete valid frames back.
class FrameParser {
  final _buf = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);
  int crcErrors = 0;

  List<Frame> add(Uint8List chunk) {
    _buf.add(_pending);
    _buf.add(chunk);
    final b = _buf.takeBytes();
    final out = <Frame>[];
    var i = 0;
    while (i + 8 <= b.length) {
      if (b[i] != 0xA5 || b[i + 1] != 0x5C) {
        i++;
        continue;
      }
      final n = b[i + 2] | (b[i + 3] << 8);
      if (n > kMaxFramePayload) {
        i++; // impossible length: false sync
        continue;
      }
      if (i + 8 + n > b.length) break; // incomplete: wait for more
      final c = b[i + 6 + n] | (b[i + 7 + n] << 8);
      if (crc16(b, i + 2, i + 6 + n) == c) {
        out.add((type: b[i + 4], data: Uint8List.sublistView(b, i + 6, i + 6 + n)));
        i += 8 + n;
      } else {
        crcErrors++;
        i++;
      }
    }
    _pending = Uint8List.fromList(Uint8List.sublistView(b, i));
    return out;
  }
}

/// CHUNK payload: req_id u32 | offset u32 | data.
typedef Chunk = ({int reqId, int offset, Uint8List data});

Chunk parseChunk(Uint8List p) {
  final v = ByteData.sublistView(p);
  return (reqId: v.getUint32(0, Endian.little), offset: v.getUint32(4, Endian.little), data: Uint8List.sublistView(p, 8));
}
