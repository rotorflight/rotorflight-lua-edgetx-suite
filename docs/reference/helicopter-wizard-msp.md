---
title: Helicopter wizard MSP and lifecycle
---

# Helicopter wizard MSP and lifecycle

The [Helicopter Setup page](../pages/helicopter_setup.md) uses the Suite's normal
MSP queue and API modules. It never opens another telemetry transport.

| API module | Command | Wire contract |
| --- | --- | --- |
| `servo` | 103 | PWM/bus output pulses, U16 values; length determines count. |
| `rc_command` | 113 | Signed S16 roll, pitch, yaw, collective and throttle commands. |
| `rx_channels` | 114 | Raw receiver channels as U16, before function mapping. |
| `motor_telemetry` | 139 | U8 count, then 16 bytes per motor: U32 RPM; U16 invalid ratio, mV, mA and mAh; S16 tenths of degrees for two temperatures. |
| `tail_motor_output` | `0x5F14` | U8 action 0/read, 1/SERVO 4, 2/MOTOR 2. Reply is U8 output plus U8 result; movement is unsaved until EEPROM/reboot. |
| `arming_disable` | 99 | U8 1 on wizard entry; verify MSP disable bit 16 in STATUS before enabling controls. U8 0 after cleanup on exit. Reassert after reboot. |
| `servo_override` | 192/193 | Read eight U16 values; write U8 index + U16 value, with optional U16 timeout. OFF = 2001. |
| `servo_override_all` | 196 | U16 value, optionally U16 timeout. Kept as a direct all-servo API; not used to infer mixer support. |
| `mixer_override` | 190/191 | Read 29 U16 values; write one U8 index + U16 value, optionally U16 timeout. OFF = 2501; passthrough = 2502. |
| `mixer_input` | 170/171 | Read signed rate/min/max records, indexed from zero; write U8 index plus three S16 values. Stabilized axes are 1, 2, 3, 4. |
| `get_servo_config` / `servo_configurations` | 125/212 | Read U8 raw servo-parameter index, reply one 16-byte record. PWM slots retain their index; packed bus slots map to raw 8–25. Writes retain packed U8 index plus one complete record. Bulk command 120 is not used. |
| `get_adjustment_range` / `set_adjustment_range` | 156/53 | Read U8 index, reply one 14-byte record; all 42 slots are read sequentially. Bulk command 52 is not used. |
| `rc_config` | 66/67 | A complete 12-byte RC configuration is required; truncated throttle/deflection data is refused. |
| `acc_calibration` / `attitude` | 205 / 108 | Empty calibration command; S16 tenths of degrees roll/pitch and S16 degree yaw. |
| `board_auto_align` | `0x5F13` | U8 start; query state and three signed alignment angles. Optional firmware extension. |
| `rx_serial_trial` | `0x5F12` | U8 start/stop; state, combination, inversion, half-duplex, pin swap and elapsed time. Wire codec retained; radio wizard directs detection to USB and sends no START. |
| `esc_sensor_trial` | `0x5F0C` | U8 start/stop; state, combination, half-duplex, pin swap and elapsed time. Optional firmware extension. |

Bulk adjustment command 52 returns 588 bytes, beyond the firmware's 320-byte
telemetry response buffer. A servo table with bus channels can also exceed it.
Indexed reads publish a complete table only after every record succeeds. Each
request remains a read, with one U8 index. A timeout or malformed record stops
startup without offering partially loaded settings. Progress is a cached label.

Receiver setup requires a working MSP radio link. Receiver wiring detection must
run through USB Configurator: the firmware trial closes/reopens the receiver UART
that also carries radio MSP. The page explains this instead of starting a trial
that can disconnect itself. ESC trials and board alignment remain available.

Timeout support is not a version predicate. Pre-extension API 12.10 firmware can
silently treat a five-byte per-output override as permanent. Each command (193 and
191) is probed with OFF only: valid five-byte payload ACK plus explicit refusal
of the invalid four-byte payload. Trailing-byte acceptance and transport timeout
both leave that command on legacy holds. Servo capability never authorizes mixer
timeouts. Ordinary releases have no timeout bytes. Motor override 195 keeps its
independent firmware expiry and always has the three-byte payload.

Cleanup has its own bounded queue owner. One OFF is in flight at a time and its
callback queues at most one next OFF; STATUS can run between them. Normal close
waits for all required OFF acknowledgements before releasing MSP_ARMING_DISABLE.
A missing connection cannot prove cleanup: the page requires physical power-off
before exit. External teardown retains the FC lock and marks this FC for a power
cycle on the next visit in the same Suite session. No automatic rollback is
claimed after external teardown; an FC power cycle clears unsaved RAM.

The transport decodes one reply, loads one API, dispatches one request, or expands
one indexed record per call. It never recursively continues from an MSP callback.
Configuration writes remain ordered before EEPROM. Profile transactions restore
the previous PID/rate profile, including a best-effort restore after failure.

The host's `buildScene` recognizes `hideSuiteFrame = true` on a page module. It
omits the native page/header while reserving space for its independent ARMED banner. Lifecycle, queue ownership
and RTN/EXIT remain in `ui/home.lua`; the native standalone/widget cancel event feeds
that dispatch. The page supplies its own Back/Continue/Save navigation.
Its `handlesDisconnect` opt-in also retains the visit through an expected reboot's
RF-link interruption. The wizard owns reconnection and stops desired overrides;
other pages keep the host's normal return-to-root behaviour.

Scene assembly is paced, and MSP callbacks only publish buffers. Live labels and
control properties read cached page state. Normal close releases visit state after cleanup; an external teardown retains the recovery marker.
STATUS refresh can preempt indexed jobs, saving/rollback transactions and wiring trials. A status older than three
seconds releases overrides before waiting for pending replies. Successful wiring
trials remain live for inspection until save/cancel/leave; STOP uses cleanup ownership.

No radio code uses `os`, coroutines, canvas drawing or image rotation.

*Documented against RFSuite 0.2.1 and the fixed Configurator reference recorded on
the page. This is a protocol/code review, not a physical-radio test.*
