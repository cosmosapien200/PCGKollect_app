import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import '../core/frames.dart';
import '../core/protocol.dart';
import 'device_link.dart';

/// Byte pipe to the device (Android USB host in the app, in-memory in tests).
abstract class UsbTransport {
  Stream<Uint8List> get data; // closes / errors when the cable is unplugged
  Future<void> write(Uint8List bytes);
  Future<void> close();
}

/// A PCGKolect device seen on USB.
class UsbDeviceInfo {
  final String name, product;
  final bool permission;
  UsbDeviceInfo(this.name, this.product, this.permission);
}

/// Android USB host bridge (android/.../UsbBridge.kt).
class AndroidUsb implements UsbTransport {
  static const _m = MethodChannel('pcgk/usb');
  static const _data = EventChannel('pcgk/usb/data');
  static const _attach = EventChannel('pcgk/usb/attach');

  static Future<List<UsbDeviceInfo>> list() async {
    if (!Platform.isAndroid) return [];
    try {
      final l = await _m.invokeListMethod<Map>('list') ?? [];
      return [
        for (final d in l) UsbDeviceInfo(d['name'] as String, (d['product'] ?? 'PCGKolect') as String, d['permission'] == true)
      ];
    } on MissingPluginException {
      return [];
    }
  }

  /// attached / detached events for PCGKolect devices.
  static Stream<({String event, String name})> attachEvents() => Platform.isAndroid
      ? _attach.receiveBroadcastStream().map((e) => (event: (e as Map)['event'] as String, name: e['name'] as String))
      : const Stream.empty();

  late final Stream<Uint8List> _stream;

  AndroidUsb._() {
    _stream = _data.receiveBroadcastStream().map((e) => e as Uint8List);
  }

  /// Asks for USB permission if needed (system dialog) and claims the interface.
  static Future<AndroidUsb> open(String name) async {
    final t = AndroidUsb._();
    try {
      await _m.invokeMethod('open', {'name': name});
    } on PlatformException catch (e) {
      throw DeviceError('ERROR', e.code);
    }
    return t;
  }

  @override
  Stream<Uint8List> get data => _stream;

  @override
  Future<void> write(Uint8List bytes) async {
    try {
      await _m.invokeMethod('write', {'data': bytes});
    } on PlatformException catch (e) {
      throw DeviceError('ERROR', e.code);
    }
  }

  @override
  Future<void> close() => _m.invokeMethod('close');
}

/// Wired link straight to the RV1103 over USB (PROTOCOL.md §5): the same JSON ops as over
/// BLE, carried in link message frames, plus direct file reads (no hotspot needed).
class UsbLink implements DeviceLink {
  @override
  final String name;
  final String usbName;
  final UsbTransport _t;
  String _deviceId;

  final _state = StreamController<LinkState>.broadcast();
  final _tlm = StreamController<DeviceStatus>.broadcast();
  final _parser = FrameParser();
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _chunkWaiters = <int, Completer<Chunk>>{};
  StreamSubscription<Uint8List>? _sub;
  LinkState _current = LinkState.disconnected;
  int _nextId = Random().nextInt(0x3FFFFFFF) + 1;
  int _seq = 0;
  Future<void> _writeChain = Future.value();

  UsbLink(this._t, {this.name = 'PCGKolect (USB)', this.usbName = 'usb'}) : _deviceId = 'usb:$usbName';

  @override
  String get deviceId => _deviceId;
  @override
  Stream<LinkState> get state => _state.stream;
  @override
  LinkState get currentState => _current;
  @override
  Stream<DeviceStatus> get telemetry => _tlm.stream;
  @override
  Stream<WifiStatus> get wifi => const Stream.empty();

  void _set(LinkState s) {
    _current = s;
    _state.add(s);
  }

  /// Starts reading and checks that the RV firmware answers on the link.
  Future<void> connect() async {
    _set(LinkState.connecting);
    _sub = _t.data.listen(_onBytes, onError: (_) => _lost(), onDone: _lost);
    _current = LinkState.connected; // call() needs it; confirmed by hello below
    try {
      final h = await call('hello', const {}, const Duration(seconds: 3));
      final id = h['device_id'] as String?;
      if (id != null && id.isNotEmpty) _deviceId = id;
      _set(LinkState.connected);
    } catch (e) {
      _set(LinkState.error);
      await disconnect();
      if (e is DeviceError && e.status == Status.timeout) throw DeviceError('ERROR', 'USB_NO_ANSWER');
      rethrow;
    }
  }

  void _lost() {
    if (_current == LinkState.disconnected) return;
    _fail('USB_DISCONNECTED');
    _set(LinkState.disconnected);
  }

  void _onBytes(Uint8List b) {
    for (final f in _parser.add(b)) {
      switch (f.type) {
        case FrameType.rsp:
          final m = _json(f.data);
          final id = (m?['id'] as num?)?.toInt();
          final c = id == null ? null : _pending.remove(id);
          if (c != null && !c.isCompleted) c.complete(m);
          // an error answer to a file read arrives as RSP, not CHUNK
          final w = id == null ? null : _chunkWaiters.remove(id);
          if (w != null && !w.isCompleted) w.completeError(DeviceError((m!['st'] ?? 'ERROR') as String, (m['err'] ?? 'READ_FAILED') as String));
        case FrameType.evt:
          final m = _json(f.data);
          if (m != null && m['ev'] == 'status') _tlm.add(DeviceStatus.fromJson(m));
        case FrameType.chunk:
          final c = parseChunk(f.data);
          final w = _chunkWaiters.remove(c.reqId);
          if (w != null && !w.isCompleted) w.complete(c);
      }
    }
  }

  static Map<String, dynamic>? _json(Uint8List d) {
    try {
      final m = jsonDecode(utf8.decode(d));
      return m is Map<String, dynamic> ? m : null;
    } catch (_) {
      return null;
    }
  }

  void _fail(String code) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(DeviceError(Status.timeout, code));
    }
    for (final c in _chunkWaiters.values) {
      if (!c.isCompleted) c.completeError(DeviceError(Status.timeout, code));
    }
    _pending.clear();
    _chunkWaiters.clear();
  }

  int _send(String op, Map<String, dynamic> args) {
    final id = _nextId++ & 0x7FFFFFFF;
    final req = {'v': kCtrlProto, 'id': id, 'op': op, 'utc_ms': DateTime.now().millisecondsSinceEpoch, ...args};
    final frame = encodeFrame(FrameType.req, _seq++, utf8.encode(jsonEncode(req)));
    // serialise writes so frames never interleave
    _writeChain = _writeChain.then((_) => _t.write(frame)).catchError((Object _) {
      final c = _pending.remove(id);
      if (c != null && !c.isCompleted) c.completeError(DeviceError('ERROR', 'USB_WRITE_FAILED'));
      final w = _chunkWaiters.remove(id);
      if (w != null && !w.isCompleted) w.completeError(DeviceError('ERROR', 'USB_WRITE_FAILED'));
    });
    return id;
  }

  @override
  Future<Map<String, dynamic>> call(String op,
      [Map<String, dynamic> args = const {}, Duration timeout = const Duration(seconds: 8)]) async {
    if (_current != LinkState.connected) throw DeviceError('ERROR', 'USB_DISCONNECTED');
    final c = Completer<Map<String, dynamic>>();
    final id = _send(op, args); // the frame goes out asynchronously, after this registers
    _pending[id] = c;
    try {
      final m = await c.future.timeout(timeout);
      final st = m['st'] as String? ?? 'ERROR';
      if (st != Status.ok) throw DeviceError(st, (m['err'] ?? st) as String, field: m['field'] as String?);
      return m;
    } on TimeoutException {
      _pending.remove(id);
      throw DeviceError(Status.timeout, 'USB_TIMEOUT');
    }
  }

  /// One file read: the answer is a CHUNK frame (empty data = end of file).
  Future<Chunk> read(int handle, int offset, int len, {Duration timeout = const Duration(seconds: 3)}) {
    if (_current != LinkState.connected) throw DeviceError('ERROR', 'USB_DISCONNECTED');
    final c = Completer<Chunk>();
    final id = _send('read', {'handle': handle, 'offset': offset, 'len': len});
    _chunkWaiters[id] = c;
    return c.future.timeout(timeout, onTimeout: () {
      _chunkWaiters.remove(id);
      throw DeviceError(Status.timeout, 'USB_TIMEOUT');
    });
  }

  @override
  FileSource? fileSource(WifiStatus wifi) => _current == LinkState.connected ? UsbFileSource(this) : null;

  @override
  Future<void> disconnect() async {
    await _sub?.cancel();
    _sub = null;
    _fail('USB_DISCONNECTED');
    try {
      await _t.close();
    } catch (_) {}
    if (_current != LinkState.disconnected) _set(LinkState.disconnected);
  }
}

/// Recording downloads over the USB link: manifest pages + pipelined 4 KB reads, resumable
/// from a partial file like the HTTP source.
class UsbFileSource implements FileSource {
  final UsbLink link;
  static const _chunk = 4096;
  static const _window = 8;
  UsbFileSource(this.link);

  @override
  Future<void> health() async {
    await link.call('ping', const {}, const Duration(seconds: 3));
  }

  @override
  Future<List<ManifestItem>> manifest() async {
    final items = <ManifestItem>[];
    var total = 1;
    while (items.length < total) {
      // 6 items per answer keeps every answer inside one link frame
      final r = await link.call('manifest', {'offset': items.length, 'limit': 6}, const Duration(seconds: 6));
      total = (r['total'] as num).toInt();
      final page = (r['items'] as List).map((e) => ManifestItem.fromJson(e as Map<String, dynamic>)).toList();
      if (page.isEmpty) break;
      items.addAll(page);
    }
    return items;
  }

  @override
  Future<String?> download(String recordingId, String kind, File dest,
      {void Function(int done, int total)? progress}) async {
    final o = await link.call('open', {'recording_id': recordingId, 'kind': kind});
    final handle = (o['handle'] as num).toInt();
    final size = (o['size'] as num).toInt();
    final sha = o['sha256'] as String?;
    var have = await dest.exists() ? await dest.length() : 0;
    if (have > size) have = 0; // not a prefix of this file: start over
    final sink = dest.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
    try {
      // keep _window reads in flight; the device answers them in order
      final inflight = Queue<(int, Future<Chunk>)>();
      var next = have;
      var done = have;
      while (done < size) {
        while (inflight.length < _window && next < size) {
          inflight.add((next, _readRetry(handle, next)));
          next += _chunk;
        }
        final (off, f) = inflight.removeFirst();
        final c = await f;
        if (c.offset != off || (c.data.isEmpty && done < size)) {
          throw TransferException('Transfer of $kind out of step at $done/$size bytes');
        }
        sink.add(c.data);
        done += c.data.length;
        progress?.call(done, size);
      }
    } finally {
      await sink.flush();
      await sink.close();
      try {
        await link.call('close', {'handle': handle}, const Duration(seconds: 2));
      } catch (_) {}
    }
    return sha;
  }

  /// Reads are idempotent: a lost answer is simply asked for again.
  Future<Chunk> _readRetry(int handle, int offset) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await link.read(handle, offset, _chunk);
      } on DeviceError catch (e) {
        if (e.status != Status.timeout || attempt >= 2) {
          throw TransferException('USB read failed at byte $offset (${e.code})');
        }
      }
    }
  }
}
