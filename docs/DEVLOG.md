# PCGKolect App — Development Log

Newest last. Design: [PLAN.md](PLAN.md), wire formats: [PROTOCOL.md](PROTOCOL.md).

---

## 2026-10-14 — Decisions before code

- **One UART, no hardware change.** The user's wiring has a single duplex UART between the
  ESP32-S3 and the RV1103. Control, telemetry and file transfer share it with the audio via a
  typed message frame (`A5 5C`) next to the unchanged audio frame (`A5 5A`). Benchmarked
  460 k → 4 Mbaud; 4 Mbaud chosen (334 KB/s stream, 0 errors in an 18 MB soak).
- **Usability = one user knob.** A beat is usable when the v2 decoder emits it, its confidence
  is ≥ the dataset threshold (default 80 %), its length is valid and (optionally) the rhythm
  check passes. v1 SQI, CLEAN/NOISE and clipping no longer gate data (clipping is only a stat).
- **Android only** for builds/tests; the code stays cross-platform.
- **BLE library:** `flutter_blue_plus` 2.x moved to a non-OSS licence (paid for commercial use,
  build-time telemetry). Replaced with `universal_ble` (BSD-3). Other deps: `sqflite`,
  `just_audio` (MIT), `archive` (MIT), `share_plus` (BSD), `flutter_secure_storage`, `http`,
  `crypto`, `provider`, `uuid`.

## M1 — datasets, recording control, verified sync

- SQLite schema with append-only migrations: datasets (settings JSON + revision + last
  device-acknowledged revision), subjects, recordings, quality intervals, beats, device
  snapshots.
- `DeviceLink` abstraction with a BLE implementation and an in-app **simulated device** that
  mirrors the RV1103 session semantics (validation, auto-start, targets, ack-before-delete),
  so every screen and the full sync path run on the emulator (no BLE there).
- Sync (`SyncService`): manifest → download each file to `tmp/<rid>/` with Range resume →
  size + SHA-256 per file, WAV header vs metadata → move into `recordings/<rid>/` and commit
  DB rows in one transaction → ACK with the audio hash → delete only in Sync mode and only
  after the ACK. Re-running is idempotent; corrupt partials are deleted, never resumed.
- Tests: fragment codec, policy rules (mirror of the firmware), WAV, simulated
  record → sync → delete, corrupt-partial recovery.

### Bugs found on the emulator
- Connect race: the link-state stream delivers asynchronously, so `refresh()` ran while the
  controller still thought it was disconnected → take the state from the link after `open()`.
- Error snackbars were unreadable (default text on `errorContainer`).

## Real phone (Xiaomi 22101316I, Android 14)

- **MIUI USB install** needed "Install via USB" + "USB debugging (Security settings)"; a
  remembered *deny* had to be cleared on the phone.
- **Responses never arrived:** the phone negotiated MTU 517 but dropped notifications larger
  than ~330 B, so every multi-fragment response lost its FIRST fragment. Fragments are now
  ≤ 244 B on both sides (one LE data packet). Found by logging raw notifications
  (`hdr=0x41` = LAST without FIRST).
- **Reconnect after a device reset failed instantly** (plugin/Android stale state, the app
  issued `connect()` then `cancelOpen()` 20 ms later). The link now disconnects first and
  retries once.
- **HTTP download stalled** at 15 KB/s and failed mid-file → fixed in the ESP firmware (UART
  ISR on core 1, lower FIFO threshold, internal RAM freed). Resume from the partial worked as
  designed. Final: ~62 KB/s, hash-verified.
- First real heart recording made from the phone: auto-started, DONE at 30.7 s usable,
  downloaded and verified.

## M2 — playback

- Waveform (min/max envelope) + usable/unusable/unscored band on the original sample axis,
  tap/drag seek, playhead in source time.
- *Useful audio*: usable beats merged (gaps ≤ 0.1 s bridged), concatenated with 10 ms fades,
  with a segment map for source ↔ playback time. *Enhance*: zero-phase 4th-order Butterworth
  20–800 Hz band-pass (forward + backward). Both rendered to a cache WAV; the stored file and
  labels are never touched. Notes, tags and a reviewed mark are separate user annotations.

## M3 — statistics and export

- One quantile convention everywhere: linear interpolation h = (N−1)p (type 7, numpy default);
  Tukey fences for outlier counts, labelled as statistical outliers.
- Analysis units are explicit: per-subject balance, per-recording quality. Missing values stay
  missing (SNR shows "not available", never 0 dB).
- "Usable / captured" (dataset card, spec definition) is distinguished from the device's
  per-recording coverage "usable / scored".
- Exports: CSV (one row per recording, units in column names), JSON summary, ZIP backup with
  original WAVs + sidecars + manifest + schema README; verified the ZIP's WAV hash on the PC.

## M4 — device page

- Diagnostics every 10 s (HTTP adds ESP heap/RSSI/link counters), stored as snapshots, flagged
  STALE after 30 s; device log export; guarded clear (untransferred recordings are kept and
  counted in the dialog; force clear needs a device-side flag).

## M5 — hardening and extras

- Schema v2 (checklist, calibration, audit, presets). Saves use update-or-insert: SQLite
  `INSERT OR REPLACE` deletes and re-inserts the row, which would have reset the new columns.
  Verified the v1 → v2 upgrade on the phone with existing recordings.
- Per-take checklist (operator, posture, site, contact, ambient, breathing) → CSV columns;
  dataset calibration record → JSON/ZIP manifest; local audit trail; protocol presets; review
  queue; duplicate-label / missing-metadata banner; unfinished takes reopen the live screen.
- Read-only device commands retry once after a timeout.
- **BLE discovery race:** right after the ESP was reflashed, `connect()` resolved before
  Android reported the link and `discoverServices()` never completed (10 s timeout). The link
  now waits for the real connected state, then discovers with one retry.
- Firmware host tests added in PCGKolect_rk (`make -f tests/Makefile.host`).
- Final phone run with clean firmware builds: new take → Stop (incomplete) → Sync imported it
  and deleted all three device copies, each only after hash verification + ACK.
