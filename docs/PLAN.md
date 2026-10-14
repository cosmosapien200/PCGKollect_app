# PCGKolect — App + Firmware Integration Plan

Specs: `new_task_specs/01..04` (app, ESP32-S3, RV1103, cross-component contract).
Wire protocols: [PROTOCOL.md](PROTOCOL.md).

## Decisions taken before implementation

| Topic | Decision | Source |
|---|---|---|
| RV1103 ↔ ESP32 link | **No hardware change.** The existing duplex UART (ESP GPIO17/18 ↔ RV `/dev/ttyS3`) carries everything through a versioned typed-frame multiplexer: legacy audio frames (`A5 5A`) plus message frames (`A5 5C`) for control, telemetry and file chunks. Baud raised from 460800 to the highest rate that benchmarks error-free (RV clocks are exact at 1.5/3/4 Mbaud). | user |
| Quality score / usability | One user knob per dataset: **beat confidence threshold**, default **0.80**. A beat is usable when the v2 decoder emits it, its confidence ≥ threshold, its duration is 0.3–2.0 s and (if rhythm check enabled) it is within ±30 % of the neighbour median. The live 0–100 `window_quality_score` = 100 × mean max-heart-state posterior of the last second (`SegQuality::recentConf`). v1 SQI / CLEAN / NOISE / CLIPPING metrics never gate anything. | user |
| Clipping | Never rejects data. Clipping ratio is recorded as an informational statistic only. | user |
| Platforms | Android (Flutter). Code stays cross-platform but only Android is built/tested. Emulator has no BLE, so the app ships a **simulated device** backend and `tools/mock_device.py` for UI/transfer testing; BLE/hotspot are tested on a real phone. | user |
| Usable time | Union of usable-beat intervals on the recording's sample axis (no double counting). Coverage = usable / scored. | spec 04 §2 |
| Auto-start | 2 s (setting) of **contiguous** usable-beat coverage while armed. A rolling pre-trigger buffer keeps that audio, so the recording starts at the first qualifying beat. Force Start skips the wait only. | spec 03 §4.3 |
| UART gaps | Missing frames (sequence gap / CRC drop / overrun) are written as zero samples so the WAV time axis stays true; each gap is listed in metadata and labelled `unscored`. | spec 04 §5 |
| Settings changes | Apply to future recordings only; rejected while a recording is active. | spec 04 §6.9 |
| Identity | Opaque UUIDs (phone-generated) are machine keys; participant labels are presentation only and never appear in file names or device logs. | spec 04 §6.5 |
| HTTP auth | Plain HTTP on the hotspot LAN, per-BLE-session random bearer token delivered over the bonded BLE link. Threat model in PROTOCOL.md. | spec 02 §6 |

## Status (2026-10-14)

| Milestone | State |
|---|---|
| M1 record + retrieve | done — verified with a real phone and a real heart recording |
| M2 playback | done |
| M3 stats + export | done |
| M4 device page | done |
| M5 hardening | in progress |

## Milestones and checkpoints

Each checkpoint ends with a commit in every repo it touched.

### M1 — Record from the app and retrieve recordings (basic working system)
1. **CP1 Link layer** (ESP + RK): typed message frames both directions, HELLO/version, ping, baud benchmark (choose rate), link counters. ESP serial console that injects JSON requests for testing.
2. **CP2 RV1103 session engine** (RK): settings/policy, state machine (IDLE → CONFIGURED → ARMED → RECORDING → FINALIZING → DONE / INCOMPLETE / CANCELLED / INTERRUPTED / STORAGE_FULL / MODEL_ERROR), pre-trigger buffer, gap-aware WAV writer, UUID-named files, metadata JSON + beat/quality sidecars, atomic finalisation, reboot recovery, manifest, file-read service, ACK/DELETE with durable transfer state, telemetry events, OLED WIP/DONE layout.
3. **CP3 ESP BLE** (ESP): NimBLE GATT (info, command, response, telemetry, Wi-Fi status), fragmentation, bonding, command proxy to RV with correlation + timeouts, state mirror.
4. **CP4 ESP Wi-Fi + HTTP** (ESP): station mode on phone hotspot via BLE provisioning, token-authenticated HTTP API, range downloads proxied chunk-by-chunk from RV.
5. **CP5 Flutter M1** (app): SQLite schema + migrations, datasets, subject form, BLE scan/connect, Activate DS, hotspot provisioning, recording screen (prepare / force start / stop / live telemetry), Sync/Download with temp file → SHA-256 + WAV check → atomic commit → ACK → delete. Simulated device for emulator.

### M2 — Data page
List (search/sort/filter), detail metadata, waveform + green/red/grey interval timeline aligned to samples, playback with seek, Useful-audio (concatenate usable intervals with source-time mapping), Enhance (20–800 Hz band-pass, playback only), notes/tags/reviewed.

### M3 — DS Stats + export
Cards, balance charts with N/missing, quality distributions (mean, min, P25/P50/P75/P100, Tukey outliers, one quantile convention), filters, CSV/JSON export, ZIP backup.

### M4 — Device Settings page
Diagnostics (versions, model hash, uptime, UART counters + rates, RAM/CPU, storage + remaining-time estimate) refreshed every 10 s, Download, Sync, guarded Clear, logs export.

### M5 — Hardening
Interruption/reconnect recovery, resume tests, HIL load test (USB + UART + BLE + Wi-Fi), recording checklist, review queue, settings presets, calibration record, audit trail.

## Test strategy
- Firmware: protocol unit tests (CRC vectors, frame parser incl. split/corrupt input, JSON command validation) on host; RK parity tests stay green.
- Link: on-board benchmark (bytes/s, CRC errors) at each candidate baud while audio streams.
- App: Dart unit tests (stats/quantiles, WAV parsing, interval union, transfer verification), widget tests, emulator run against simulated device / `mock_device.py`.
- End to end: real phone + device (needs the user's phone).
