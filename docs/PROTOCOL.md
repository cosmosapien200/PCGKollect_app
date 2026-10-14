# PCGKolect Protocols — v1

Canonical, shared by [PCGKolect](https://github.com/cosmosapien200/PCGKolect) (ESP32-S3),
[PCGKolect_rk](https://github.com/cosmosapien200/PCGKolect_rk) (RV1103) and this app.
Each interface is versioned independently:

| Interface | Constant | Version |
|---|---|---|
| UART link framing (ESP ↔ RV) | `LINK_PROTO` | 1 |
| Audio frame format | `AUDIO_PROTO` | 1 (unchanged legacy frame) |
| Control JSON (app ↔ ESP ↔ RV) | `CTRL_PROTO` | 1 |
| HTTP API | path prefix `/v1` | 1 |
| Recording metadata | `schema_version` | 1 |

---

## 1. UART link (ESP32 GPIO17 TX / GPIO18 RX ↔ RV1103 `/dev/ttyS3`)

8N1, no flow control. Both ends boot at **460 800** and the ESP negotiates **4 000 000** (§1.5).

### 1.1 Frames

All multi-byte integers little-endian. CRC = CRC16-CCITT-FALSE (poly 0x1021, init 0xFFFF,
no reflection, xorout 0), stored LE.

**Audio frame** (ESP → RV only, unchanged):
```
A5 5A | LEN u16 | SEQ u8 | PCM[LEN] | CRC16      CRC over LEN..PCM
```
LEN = 1600 (800 × int16 @ 8 kHz = 100 ms). SEQ increments mod 256.

**Message frame** (both directions):
```
A5 5C | LEN u16 | TYPE u8 | SEQ u8 | PAYLOAD[LEN] | CRC16     CRC over LEN..PAYLOAD
```
LEN ≤ 4200. SEQ is a per-direction message counter mod 256 (diagnostics only).

| TYPE | Name | Direction | Payload |
|---|---|---|---|
| 0x01 | REQ | ESP → RV | UTF-8 JSON request (§2) |
| 0x02 | RSP | RV → ESP | UTF-8 JSON response |
| 0x03 | EVT | RV → ESP | UTF-8 JSON event (telemetry, state change) |
| 0x10 | CHUNK | RV → ESP | `req_id u32 | offset u32 | data[...]` answer to a `read` request |

Writers emit whole frames atomically (never interleave bytes of two frames). A receiver that
sees a bad CRC or impossible LEN drops the frame, counts it, and resynchronises on the next
`A5 5A` / `A5 5C`.

### 1.2 Reliability

The link has no retransmission at frame level. Requests are made reliable end-to-end:
- Every request has a numeric `id`. The ESP retries a request with the **same id** after a
  timeout (default 400 ms, `read` 250 ms, 3 attempts).
- The RV keeps the last 16 responses keyed by id and replays them for duplicates, so
  non-idempotent operations run once.
- A corrupt CHUNK is simply re-requested with the same offset.

### 1.3 Audio integrity

The RV tracks audio SEQ continuity. A missing frame (gap, CRC drop) or receive overrun inserts
zero samples for the missing time **in the recording** and adds a gap record to the metadata
(`gaps: [{start_sample, samples, reason}]`); those samples are labelled `unscored`.

### 1.4 Test vectors

- `crc16("123456789") == 0x29B1`
- Audio, samples {1,2}, SEQ 1: `A5 5A 04 00 01 01 00 02 00 8F 8A`
- Message, TYPE REQ, SEQ 0, payload `{}`: `A5 5C 02 00 01 00 7B 7D 7D 88`

### 1.5 Baud negotiation and benchmark

- Both ends boot at 460 800. The ESP link supervisor pings the RV; on the first answer it sends
  `{"op":"baud","baud":4000000}`. The RV answers at the old rate, then switches; the ESP follows
  and confirms with a ping (falls back on failure).
- The RV returns to 460 800 when it hears no valid frame for 3 s at another rate (ESP reboot);
  the ESP drops to 460 800 after two failed pings, waits 3.5 s, then negotiates again.
- RV1103 UART3 clocks are exact at 1.5/3/4 Mbaud (24/48/64 MHz); ESP32-S3 is exact at 4 Mbaud.

Measured (ESP32-S3 ↔ Luckfox Pico Mini, audio streaming and NPU running, 2026-10-14):

| Baud | RV→ESP stream | request/response read (4 KB chunks) | errors |
|---|---|---|---|
| 460 800 | 40 KB/s | 32 KB/s | 0 |
| 1 500 000 | 129 KB/s | 79 KB/s | 0 chunk, 2 audio frames lost |
| 3 000 000 | 254 KB/s | 100 KB/s | 0 |
| **4 000 000** | **334 KB/s** | **128 KB/s** | **0 in 18 MB soak** |

---

## 2. Control JSON (CTRL_PROTO 1)

Requests: `{"v":1,"id":<u32>,"op":"<name>", "utc_ms":<phone wall clock, optional>, ...args}`

The RV1103 has no RTC: any request carrying `utc_ms` (the app sends it with every request) sets
the device's wall-clock offset used for `start_time_utc`.
Responses: `{"v":1,"id":<same>,"st":"OK|REJECTED|BUSY|UNSUPPORTED|INVALID|TIMEOUT|ERROR", "err":"<code>", ...payload}`

The same JSON travels app → ESP (BLE) → RV (UART). Ops marked **ESP** are answered by the ESP
and never forwarded.

| op | handled by | args | response payload |
|---|---|---|---|
| `hello` | ESP + RV | – | `device_id, esp_fw, rv_fw, ctrl_proto, link_proto, audio_proto, model{version,sha256,loaded}, dataset{id,name,rev}, caps[]` |
| `status` | RV | – | status object (§2.2) |
| `stats` | RV + ESP | – | diagnostics (§2.3) |
| `set_dataset` | RV | `dataset_id, name, rev, settings{}` | `rev` accepted, effective `settings` |
| `prepare` | RV | `dataset_id, subject_id, recording_id, rev, take` | `state` |
| `force_start` | RV | `recording_id` | `state` |
| `stop` | RV | `recording_id, reason` | `state` (recording becomes `INCOMPLETE` unless targets were already met) |
| `cancel` | RV | `recording_id` | `state` (only before RECORDING; nothing saved) |
| `manifest` | RV | `offset?, limit?` (limit ≤ 6 so a page fits one 4 KB frame) | `total, offset, items[]` (§5 manifest item) |
| `open` | RV | `recording_id, kind` (`audio`,`beats`,`quality`,`meta`) | `handle, size, sha256` |
| `read` | RV | `handle, offset, len` (≤ 4096) | CHUNK frame; JSON RSP only on error |
| `close` | RV | `handle` | – |
| `ack` | RV | `recording_id, sha256` | `transfer_state` = `verified` |
| `delete` | RV | `recording_id, sha256` | `deleted:true` — REJECTED `NOT_VERIFIED` unless acked with the same hash |
| `clear` | RV | `force` (bool, default false) | `deleted[], kept[]`; without `force` only verified recordings are deleted |
| `logs` | RV | `lines?` (≤ 40) | `lines[]` |
| `ping`, `link_stats`, `baud`, `flood` | RV | – | link maintenance / benchmark (ESP-internal) |
| `wifi_set` | **ESP** | `ssid, pass` | `state` |
| `wifi_forget` | **ESP** | – | – |
| `wifi_status` | **ESP** | – | `state (off|connecting|connected|failed), ssid, ip, port, rssi, token (bonded links only), http_ready, err` |

### 2.1 Dataset settings (sent in `set_dataset`)

| key | type | range | default | meaning |
|---|---|---|---|---|
| `conf_threshold` | float | 0.50–0.99 | 0.80 | minimum beat confidence for a usable beat |
| `rhythm_check` | bool | – | true | require beat length within ±30 % of neighbour median |
| `autostart_s` | float | 0.0–10.0 | 2.0 | contiguous usable coverage needed before auto-start (0 = start immediately) |
| `target_usable_s` | float | 0–600 | 30 | total usable time to finish (0 = off) |
| `target_usable_beats` | int | 0–2000 | 0 | total usable beats to finish (0 = off) |
| `min_run_beats` | int | 0–200 | 0 | at least one run of this many consecutive usable beats (0 = off) |
| `min_run_s` | float | 0–300 | 0 | at least one contiguous usable run this long (0 = off) |
| `max_duration_s` | float | 10–1800 | 180 | recording ends `INCOMPLETE` after this |
| `telemetry_hz` | float | 0.5–5 | 2 | status event rate |

Validation (RV is authoritative, the app pre-validates): at least one of `target_usable_s`,
`target_usable_beats` > 0; `min_run_s ≤ target_usable_s` when both > 0;
`min_run_beats ≤ target_usable_beats` when both > 0; `max_duration_s > target_usable_s`.
Rejected settings → `INVALID` with `err` naming the field; the previous revision stays active.
`set_dataset` while ARMED/RECORDING → `BUSY`.

Fixed decoder criteria (model version, not user settings): beat duration 0.3–2.0 s, rhythm
tolerance ±30 %.

### 2.2 Status object / telemetry event

Sent as `EVT {"ev":"status", ...}` at `telemetry_hz` and on every state change, and returned by `status`.

| key | meaning |
|---|---|
| `state` | `IDLE, CONFIGURED, ARMED, RECORDING, FINALIZING, DONE, INCOMPLETE, CANCELLED, INTERRUPTED, STORAGE_FULL, MODEL_ERROR` |
| `rid` | active/last recording id |
| `q` | `window_quality_score` 0–100 (int) or `null` when no model output |
| `qdef` | `"wqs_v2"` = 100 × mean max-heart-state posterior over the last scored second |
| `bc` | last beat confidence 0–1 or null |
| `el_ms` | elapsed recording time |
| `sc_ms` | scored time |
| `us_ms` | usable time (union of usable beats) |
| `req_ms` | `target_usable_s` × 1000 |
| `ub`, `req_b` | usable beats / target beats |
| `run_b`, `run_ms` | current consecutive usable run |
| `lrun_b`, `lrun_ms` | longest run so far |
| `arm_ms` | contiguous qualifying time while ARMED |
| `rs` | reason code (spec 03 §13), e.g. `NOISY`, `TARGET_REACHED` |
| `rev` | active settings revision |
| `link` | `{ok, crc, gaps, ovr}` UART audio counters |

---

## 3. BLE GATT (ESP32-S3 peripheral)

Advertised name `PCGKolect-XXXX` (last 2 bytes of MAC). No participant data in advertising.

Service `7a1c0001-5b6e-4e8a-9c1f-50434b4f4c54`

| Characteristic | UUID | Properties | Content |
|---|---|---|---|
| Info | `7a1c0002-…` | read | `hello` response JSON |
| Command | `7a1c0003-…` | write (with response), encrypted | fragmented request JSON |
| Response | `7a1c0004-…` | notify | fragmented response JSON |
| Telemetry | `7a1c0005-…` | notify | latest status JSON, ≤ 5 Hz |
| Wi-Fi | `7a1c0006-…` | read, notify | `wifi_status` JSON |

**Fragmentation** (Command, Response, Telemetry, Wi-Fi): each value is `HDR u8 | data`.
`HDR` bit7 = FIRST, bit6 = LAST, bits0–5 = fragment index mod 64. A message is the
concatenation of fragments FIRST … LAST. The app requests MTU 517, but every fragment is at most
**244 bytes** (header included) in both directions: some phones negotiate a large MTU yet drop
larger GATT packets.

Pairing: LE Secure Connections, Just Works, bonding. Writes to Command require an encrypted
link; destructive ops (`delete`, `clear`, `wifi_set`) are rejected on unbonded links.

---

## 4. Local HTTP API (ESP32 on the phone hotspot)

Base `http://<ip>:<port>/v1`, `ip`/`port`/`token` from `wifi_status` over BLE.
Every request carries `Authorization: Bearer <token>`; otherwise 401. The token is random
(128 bit), created at boot and rotated on each new BLE connection.

| Method | Path | Notes |
|---|---|---|
| GET | `/v1/health` | `{ok, ctrl_proto, device_id}` |
| GET | `/v1/device` | `hello` |
| GET | `/v1/stats` | `stats` |
| GET | `/v1/recordings?offset=&limit=` | manifest |
| GET | `/v1/recordings/{id}/metadata` | `meta.json` bytes |
| GET | `/v1/recordings/{id}/audio` | WAV bytes, `Range: bytes=a-b` → 206, `X-Content-SHA256` header |
| GET | `/v1/recordings/{id}/sidecars/{beats|quality}` | CSV bytes, Range supported |
| POST | `/v1/transfers/{id}/ack` | body `{sha256}` |
| POST | `/v1/transfers/{id}/delete` | body `{sha256}` |
| POST | `/v1/recordings/clear` | body `{force:false}` |

Downloads carry `Content-Length`, `Accept-Ranges: bytes`, `X-Content-SHA256` (whole-file hash) and
`X-File-Size`; `Range: bytes=a-b` answers 206 with `Content-Range`. If the RV read fails mid-body
the connection closes early — the client detects the short body and resumes with Range.
RV statuses map to HTTP: OK→200, INVALID→400, REJECTED/NOT_FOUND→404, REJECTED/BUSY→409,
TIMEOUT→504, link down→503, other→502.

One request is served at a time (3 sockets max); bodies are streamed from the RV in ≤ 4 KB chunks, never
held whole in ESP RAM. Errors: JSON `{err}` with 400/401/404/409/503/504.

Threat model: the hotspot LAN is private to the operator's phone but any hotspot client could
probe the port. The bearer token (delivered only over the bonded BLE link) gates every request;
it is never placed in URLs or logs. Traffic is unencrypted on the LAN (acceptable for v1; HTTPS
is a later option if ESP memory allows).

---

## 5. Recording files (RV1103, `/root/recordings`)

```
/root/recordings/<recording_id>/audio.wav      PCM16 LE mono 8 kHz, immutable after finalise
/root/recordings/<recording_id>/beats.csv      beat sidecar
/root/recordings/<recording_id>/quality.csv    per-second quality timeline
/root/recordings/<recording_id>/meta.json      metadata (schema_version 1), immutable after finalise
/root/recordings/<recording_id>/transfer.json  {"state":"available|verified|delete_pending", "sha256":..., "acked_at":...}
/root/recordings/.partial/<recording_id>/      in-progress session; renamed into place on finalise
```

All times are **sample indices** of `audio.wav` (8 kHz): `start_sample` inclusive,
`end_sample` exclusive.

`beats.csv` header: `start_sample,end_sample,conf,pnoise,usable,reason`
(`reason` ∈ `OK, LOW_CONF, BAD_DURATION, RHYTHM, UNSCORED`)

`quality.csv` header: `start_sample,end_sample,label,score,pnoise,reason`
(1 s windows; `label` ∈ `usable, unusable, unscored`; `score` = window_quality_score or empty)

`meta.json` (schema_version 1): `recording_id, dataset_id, dataset_name, subject_id, take_index,
start_time_utc, end_time_utc, audio{path,sample_rate_hz,channels,bits_per_sample,sample_count,sha256},
quality{score_definition, model_version, model_sha256, policy_revision, policy{...},
captured_duration_ms, scored_duration_ms, usable_duration_ms, usable_ratio, usable_beats,
total_beats, longest_usable_run_ms, longest_usable_run_beats, mean_beat_conf, snr_db (null),
clipping_ratio, criteria{name: met}}, transport{uart_frames_ok, uart_crc_errors,
uart_sequence_gaps, audio_buffer_overruns}, gaps[], completion_state, force_started,
pretrigger_samples, firmware{rv, esp}`.

Manifest item: `recording_id, dataset_id, subject_id, take, start_utc_ms, duration_ms,
usable_ms, completion (complete|incomplete|interrupted), transfer (available|verified),
files{audio,beats,quality,meta: {size, sha256}}`.

`clear` with `force:true` is refused (`FORCE_DISABLED`) unless the device-side flag file
`/root/pcg_state/allow_force_clear` exists — the app alone cannot authorise destructive clears.

Transfer states: `available → verified (ack) → deleted`. Only `verified` with matching hash may
be deleted. The phone never deletes on transport completion alone.
