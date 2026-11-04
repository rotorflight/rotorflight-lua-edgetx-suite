---
title: SRXL2 ESC
sidebar_label: SRXL2 ESC
sidebar_position: 60
---

# SRXL2 ESC

The settings of a Spektrum Smart ESC on the SRXL2 ESC port: how often the flight controller
asks the ESC for telemetry, and which SRXL2 channel drives the second motor of a dual-motor
Smart ESC. Saving reboots the flight controller.

## Where to find it

*Configuration* → *Setup* → *ESC & Motors* → *SRXL2 ESC*

Needs MSP API 12.10. Lit only while the flight controller reports the SRXL2 ESC telemetry
protocol, which it sets by itself once a serial port carries the *SRXL2 ESC* function
(*Setup* → *Ports*) and the flight controller has rebooted. Read-only while the model is armed.

## Settings

| Setting | What it does |
| --- | --- |
| Telemetry Interval | How many throttle frames pass between two telemetry requests to the ESC. 0 to 255, default 7; *Off* (0) stops the telemetry polling. |
| Motor 2 Channel | For dual-motor Smart ESCs (for example the Spektrum SPMXAE1020 of the Blade 230 S Smart): the SRXL2 channel that carries motor 2. *Off* (the default) for an ESC with one motor, otherwise 1 to 31; motor 1 is always channel 0. With a channel set, the flight controller drives motor 2 from the mixer's second motor output. |

## Notes

- Each row has a `?` of its own that explains its setting in one line; the page's `?` says what
  the page is for.
- **The settings need a flight controller firmware that offers them.** A firmware without
  them answers the read with an error, and the page then says that this firmware does not
  offer the SRXL2 ESC settings instead of showing values; Save is refused. A reply the page
  cannot read is shown as a failed read, and Save is refused as well, so nothing is written
  from values the flight controller never sent.
- The throttle rate the flight controller keeps beside these settings is not shown. It
  follows the *Update frequency* on the [Throttle](throttle.md) page, and this page writes it
  back exactly as it was read.
- The flight controller reads these settings only at boot, and fixes the motor 2 channel
  there, so saving sends them and then reboots it; the link drops and comes back. See
  [Saving configuration](../../../reference/saving.md).

## Related

- [Throttle](throttle.md) — the SRXL2 throttle protocol and the update frequency.
- [Telemetry](telemetry.md) — the ESC telemetry protocol this tile is lit for.
- [Saving configuration](../../../reference/saving.md) — the save that restarts the flight
  controller.
- [Rotorflight documentation](https://doc.rotorflight.org/)

*Documented against RFSuite 0.2.2.*
