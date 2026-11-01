---
title: MSP setup API modules
---

# MSP setup API modules

These modules use the existing MSP API loader and queue. Loading a codec does not
start polling, change a setting or establish firmware support. A caller must handle
unsupported commands and validate the flight controller's state before writing.
No page or menu entry is added.

| Module | Command | Contract |
| --- | --- | --- |
| `servo` | 103 | U16 live outputs in microseconds, in the order `servo_configurations` lists the servos (up to 26 on current firmware). `servos[1]` is the servo at configuration index 0. |
| `attitude` | 108 | Three signed S16 values; roll/pitch in tenths of degrees, yaw in degrees. |
| `rc_command` | 113 | Signed function commands, at least roll, pitch, yaw, collective and throttle. |
| `rx_channels` | 114 | 0–18 raw receiver channels before RX_MAP. These differ from mapped MSP_RC functions. An empty reply is zero channels. |
| `motor_telemetry` | 139 | Count followed by 16-byte records: U32 RPM, four U16 fields and two S16 temperatures. Up to four motors; zero is valid. |
| `arming_disable` | 99 | U8 inhibit 1/release 0, scoped by firmware to the MSP connection. The caller owns entry, readback and cleanup. |
| `acc_calibration` | 205 | Empty write payload; the caller marks the message `isWrite = true`, since a message without a payload is otherwise queued as a read. The caller owns calibration preconditions and completion checks. |
| `rx_serial_trial` | `0x5F12` | `buildPayload(action)` like `esc_sensor_trial`: 0 polls, 1 starts, 2 stops. Seven-byte state reply. Receiver UART reinitialization can interrupt a radio MSP link; this codec does not make radio-side START safe. |
| `tail_motor_output` | `0x5F14` | Read without payload or with action 0; write action 1 selects SERVO 4, 2 selects MOTOR 2. Reply: output and result. Requires firmware implementing the extension. |
| `servo_configurations` | 120/212 | Existing count/table decoder plus U8 index and a complete 16-byte configuration write. Retains all calibration fields; a record with a field missing is refused. |
| `mixer_input` | 170/171 | Adds zero-based signed `inputs[index]` records alongside the existing unsigned flat fields. |
| `rc_config` | 66/67 | Refuses replies shorter than the complete 12-byte configuration. |

The MSP queue takes a message with a payload on `0x5F12` or `0x5F14` for a write unless the
message says otherwise, and a write clears the response cache. A poll that carries an action
byte is therefore queued with `isWrite = false`; a start, stop or tail selection with
`isWrite = true`.

The optional `0x5F12`/`0x5F14` commands are protocol codecs, not a claim that an
API-version number proves support. Their callers must establish support from an
actual reply. Existing board-alignment and ESC-wiring codecs are separate changes.

Large tables may exceed a telemetry transport's reply limit. The bulk servo codec
remains available; callers on a radio link should use existing indexed reads when
the whole table cannot fit. This change does not add a bulk-read retry fallback.

Run `lua5.3 bin/msp/verify_msp_setup_apis.lua` for byte vectors, signs, record order,
truncated replies and complete servo write/read round trips. These are offline
protocol checks; no physical flight controller or actuator was tested.

## Simulator replies

Without a flight controller the MSP queue answers a message with its `simulatorResponse`,
so every module under `tasks/msp/api/` that has a fixture and a `parse` must carry a
fixture its own parser reads to the end. Run
`lua5.3 bin/msp/verify_simulator_fixture_lengths.lua`: it runs each module's `parse` on
its own fixture and fails when the parser refuses it, reads past its end or leaves
trailing bytes unread, when the fixture is empty or shorter than the module's `Api.fields`,
or when the parser, given a longer reply, would go on into an optional section the fixture
leaves out.

Where a module needs an exception, the check names it in a list with the reason: a
write-only module, a parser with no fixture on purpose, an empty reply that is valid, a
parser that scans a string to its terminator, a reply whose parser accepts more than one
length (its length is listed), an optional section left out on purpose, and a read no page
sends. A module without a parser or without a fixture fails unless it is listed.
