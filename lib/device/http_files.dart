import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/protocol.dart';
import 'device_link.dart';

/// Recording downloads from the ESP32 HTTP API on the phone hotspot (PROTOCOL.md §4).
/// The bearer token travels only in the Authorization header, never in URLs.
class HttpFileSource implements FileSource {
  final String base; // http://ip:port/v1
  final String token;
  final http.Client _client = http.Client();

  HttpFileSource(this.base, this.token);

  Map<String, String> get _auth => {'Authorization': 'Bearer $token'};

  @override
  Future<void> health() async {
    try {
      final r = await _client.get(Uri.parse('$base/health'), headers: _auth).timeout(const Duration(seconds: 5));
      if (r.statusCode == 401) throw TransferException('The device rejected the access token. Reconnect Bluetooth.');
      if (r.statusCode != 200) throw TransferException('Device HTTP error ${r.statusCode}');
    } on SocketException {
      throw TransferException(
          'The phone cannot reach the device on the hotspot network. Some phones block traffic between '
          'the hotspot and its clients; check that the hotspot is on and try again.');
    } on TimeoutException {
      throw TransferException('The device did not answer on the hotspot network.');
    }
  }

  /// ESP + RV diagnostics over HTTP (adds the ESP heap/RSSI/link counters).
  Future<Map<String, dynamic>> stats() async {
    final r = await _client.get(Uri.parse('$base/stats'), headers: _auth).timeout(const Duration(seconds: 5));
    if (r.statusCode != 200) throw TransferException('Stats failed (${r.statusCode})');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  @override
  Future<List<ManifestItem>> manifest() async {
    final r = await _client.get(Uri.parse('$base/recordings'), headers: _auth).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw TransferException('Manifest failed (${r.statusCode})');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (j['items'] as List).map((e) => ManifestItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  static String _path(String kind) => switch (kind) {
        'audio' => 'audio',
        'meta' => 'metadata',
        'beats' => 'sidecars/beats',
        'quality' => 'sidecars/quality',
        _ => throw ArgumentError(kind),
      };

  @override
  Future<String?> download(String recordingId, String kind, File dest,
      {void Function(int done, int total)? progress}) async {
    var have = await dest.exists() ? await dest.length() : 0;
    final req = http.Request('GET', Uri.parse('$base/recordings/$recordingId/${_path(kind)}'));
    req.headers.addAll(_auth);
    if (have > 0) req.headers['Range'] = 'bytes=$have-';
    final r = await _client.send(req).timeout(const Duration(seconds: 15));
    if (r.statusCode == 416) {
      return r.headers['x-content-sha256']; // already complete
    }
    if (r.statusCode != 200 && r.statusCode != 206) {
      throw TransferException('Download of $kind failed (${r.statusCode})');
    }
    if (r.statusCode == 200 && have > 0) have = 0; // server ignored the range: start over
    final total = int.tryParse(r.headers['x-file-size'] ?? '') ?? (have + (r.contentLength ?? 0));
    final sink = dest.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
    var done = have;
    try {
      await for (final chunk in r.stream.timeout(const Duration(seconds: 15))) {
        sink.add(chunk);
        done += chunk.length;
        progress?.call(done, total);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    if (done < total) throw TransferException('Transfer of $kind interrupted at $done/$total bytes');
    return r.headers['x-content-sha256'];
  }
}
