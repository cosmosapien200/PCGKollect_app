# PCGKolect App

Companion app for **PCGKolect — System and Method for Intelligent Phonocardiogram Dataset
Acquisition Using Real-Time Recording Quality Assessment**. It manages research datasets and
subjects, drives the recorder over Bluetooth, shows live acquisition quality, and pulls
recordings over the phone's Wi-Fi hotspot into a verified local archive.

PCGKolect is a research data-collection instrument, **not** a diagnostic or health-monitoring
device. The app reports acquisition quality only (usable, noisy, incomplete, …).

Related repositories:
- [PCGKolect](https://github.com/cosmosapien200/PCGKolect) — ESP32-S3 firmware (audio, BLE, Wi-Fi/HTTP)
- [PCGKolect_rk](https://github.com/cosmosapien200/PCGKolect_rk) — RV1103 firmware (quality model, recording engine, OLED)
- [PCGKolect_model](https://github.com/cosmosapien200/PCGKolect_model) — quality models and training

Design documents: [docs/PLAN.md](docs/PLAN.md) (milestones and decisions) and
[docs/PROTOCOL.md](docs/PROTOCOL.md) (UART link, control JSON, BLE GATT, HTTP API, file formats).

## How it works

```
 phone app ──BLE (control, telemetry, hotspot credentials)──► ESP32-S3 ──UART 4 Mbaud──► RV1103
     ▲                                                           │                       (model,
     └──────── HTTP over the phone's hotspot (recordings) ◄──────┘◄── file chunks ──────  recordings)
```

1. **Datasets** (`+` in the drawer) hold their own subjects, recordings and recording policy.
2. **DS Settings**: usable-beat confidence threshold (default 80 %), rhythm check, usable time /
   beat targets, minimum contiguous run, auto-start delay, max duration. Saving creates a new
   settings revision; **Activate DS** sends it to the device, which acknowledges the revision.
3. **New recording**: register a subject (participant code, age or DOB, sex, optional fields) →
   the device is armed and starts automatically after 2 s of reliable audio (**Force Start**
   skips only the wait) → live score, usable time vs. target, beats and runs → **DONE** when the
   targets are met.
4. **Sync / Download**: the device joins the phone's hotspot (credentials sent over bonded BLE),
   the app downloads each recording to a temp folder (resumable), checks sizes and SHA-256 and
   the WAV header, commits files + database rows, then acknowledges the hash. Sync also deletes
   the device copy — only after that acknowledgement; Download keeps it.

## Code layout

```
lib/core/protocol.dart        UUIDs, BLE fragmentation, status/manifest models, Policy + validation
lib/data/                     SQLite schema (versioned migrations) and models
lib/device/ble_link.dart      BLE control link (universal_ble, BSD-3)
lib/device/http_files.dart    authenticated HTTP downloads with Range resume
lib/device/sim_link.dart      simulated device (emulator/UI tests; synthetic recordings, clearly marked)
lib/services/sync_service.dart  verified download → commit → ack → delete
lib/services/wav.dart         WAV validation/building
lib/state/                    AppState (datasets) and DeviceController (link, telemetry, Wi-Fi)
lib/ui/                       pages: shell, DS settings, DS stats, data list/detail, subject form,
                              live recording, device settings, sync sheet
test/                         unit tests + end-to-end sync tests against the simulated device
tools/ui_drive.py             adb helper to drive the app on an emulator/phone
```

## Build and run

Toolchain used: Flutter 3.47.7 (Dart 3.13), JDK 21, Android SDK 36, minSdk 24.

```bash
flutter pub get
flutter analyze
flutter test                      # unit tests + simulated record → sync → delete
flutter build apk --debug         # build/app/outputs/flutter-apk/app-debug.apk
flutter run                       # on a connected Android phone
```

The Android emulator has no Bluetooth: use **Device Settings → Use simulated device** to exercise
every screen and the full sync path with synthetic data. Real BLE + hotspot transfer needs an
Android phone (Bluetooth and "Nearby devices" permission, Wi-Fi hotspot on).

## Privacy

Participant data stays on the phone (app-private storage, opaque UUID file names, no cloud, no
analytics). Hotspot credentials are only stored if "Remember" is ticked, in encrypted storage,
and can be forgotten from Device Settings. The device's HTTP token is per Bluetooth session and
is never put in URLs.

## Status

- **M1 (done):** datasets, settings + activation, subject registration, BLE control, live
  recording, hotspot provisioning, verified sync/download, recording list and detail.
- **M2 (done):** playback with usable/unusable/unscored timeline, "useful audio only", 20–800 Hz enhance.
- **M3 (done):** dataset statistics (distributions, percentiles, Tukey outliers), filters, CSV/JSON/ZIP export.
- **M4 (done):** device diagnostics with history, logs export, guarded clear.
- **M5:** hardening, review queue, presets, calibration record, audit trail.

Tested on a Xiaomi phone (Android 14) with the real device; see [docs/DEVLOG.md](docs/DEVLOG.md).
