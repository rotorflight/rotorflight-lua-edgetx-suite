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
| RF Band | Derived from the same sensor. |
| Packet Ratio | The flight controller's telemetry link ratio. |
| MSP Version | The API version the flight controller reports. |
| MSP Transport | The transport MSP is running over, or `SIMULATOR`. |
| Supported MSP API | What this version of the suite supports. |
| Simulation | Whether the radio is a simulator. |

## Notes

- **A dash means the value was not read, and never a guessed one.** *RF Mode* and *RF Band* need
  an RF module that publishes an `RFMD` telemetry sensor and a link that is currently delivering
  it; with either missing, both rows read `-` rather than the mode that happens to sit at the
  bottom of the table.
- **The three MSP rows are re-read each time the page is opened.** Variant, Board Info and Build
  Info are the flight controller's, so they are dropped when the page is left and fetched again
  on the next visit — which is what makes them right after a model change rather than the
  previous helicopter's.
- **Reload in the header re-reads everything on demand**, and leaving the page and coming back
  does the same, because the flight controller's rows are dropped when the page closes.

*Documented against RFSuite 0.1.7.*
