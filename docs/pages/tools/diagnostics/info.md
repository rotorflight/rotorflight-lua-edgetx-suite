---
title: Info
sidebar_label: Info
sidebar_position: 70
---

# Info

One screen with the versions, the board and the link details the suite knows about — the page to
open before reporting a problem, and the page whose values go into the report.

## Where to find it

*System* → *Tools* → *Diagnostics* → *Info*

Read-only while the model is armed.

## Settings

The page has no settings. Everything on it is read: some of it from the radio, the rest from
the flight controller over MSP.

| Row | Where it comes from |
| --- | --- |
| Version | The suite's own version. |
| EdgeTX Version | The radio. |
| Rotorflight Version | The flight controller. |
| FC Version | The flight controller. |
| FBL Serial | The flight controller's MCU id. |
| Variant | Read over MSP when the page opens. |
| Board Info | Read over MSP when the page opens. |
| Build Info | Read over MSP when the page opens. |
| RF Mode | The `RFMD` telemetry sensor, where the RF module publishes one. |
| RF Band | Shown for ExpressLRS 4.x modules, whose RF Mode value carries the band; `-` for 3.x. |
| Packet Ratio | The telemetry link ratio set on the flight controller, read over MSP when the page opens and again every 45 seconds while it stays open. It is a setting, not a measurement of the link. |
| MSP Version | The API version the flight controller reports. |
| MSP Transport | The transport MSP is running over, or `SIMULATOR`. |
| Supported MSP API | What this version of the suite supports. |
| Simulation | Whether the radio is a simulator. |

## Notes

- **Loading failed names a refused MSP API version.** If the flight controller answered with
  an unsupported API version, the notice shows that version when loading times out.
  If the controller did not answer, it says so and asks you to check
  `FEATURE_TELEMETRY` and the MSP serial port configuration. The *Supported MSP API* row lists
  the versions the suite supports.
- **A dash means the value was not read, and never a guessed one.** *RF Mode* and *RF Band* need
  an RF module that publishes an `RFMD` telemetry sensor and a link that is currently delivering
  it. RF Mode is decoded for the module's ExpressLRS generation (3.x or 4.x) once the module has
  identified itself; until then, or with the sensor or live link missing, both rows read `-`.
  A module that is not ExpressLRS 3.x or 4.x reads `-` in both rows. RF Band is shown for
  ExpressLRS 4.x modules, whose RF Mode value carries the band; it reads `-` for 3.x.
- **The three MSP rows are re-read each time the page is opened.** Variant, Board Info and Build
  Info are the flight controller's, so they are dropped when the page is left and fetched again
  on the next visit — which is what makes them right after a model change rather than the
  previous helicopter's.
- **Reload in the header re-reads Variant, Board Info, Build Info and Packet Ratio on demand.**
  Leaving the page and coming back reads those fields again too.

*Documented against RFSuite 0.1.7.*
