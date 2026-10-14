import 'dart:async';
import 'dart:io';

import '../core/protocol.dart';

enum LinkState { disconnected, connecting, connected, error }

/// Control channel to a PCGKolect device (BLE in production, simulated for tests).
/// [call] returns the response payload or throws [DeviceError]; it never reports
/// success before the device acknowledged.
abstract class DeviceLink {
  String get name;
  String get deviceId;
  Stream<LinkState> get state;
  LinkState get currentState;
  Stream<DeviceStatus> get telemetry;
  Stream<WifiStatus> get wifi;

  Future<Map<String, dynamic>> call(String op,
      [Map<String, dynamic> args = const {}, Duration timeout = const Duration(seconds: 8)]);

  /// File access over the local network (null when Wi-Fi is not ready).
  FileSource? fileSource(WifiStatus wifi);

  Future<void> disconnect();
}

/// Bulk recording access (HTTP over the phone hotspot; in-memory for the simulator).
abstract class FileSource {
  /// Authenticated reachability check; throws on failure.
  Future<void> health();
  Future<List<ManifestItem>> manifest();

  /// Downloads [kind] (audio|meta|beats|quality) into [dest]. If [dest] already holds a
  /// prefix of the file the transfer resumes from there. Returns the device's SHA-256 header.
  Future<String?> download(String recordingId, String kind, File dest,
      {void Function(int done, int total)? progress});
}

class TransferException implements Exception {
  final String message;
  TransferException(this.message);
  @override
  String toString() => message;
}
