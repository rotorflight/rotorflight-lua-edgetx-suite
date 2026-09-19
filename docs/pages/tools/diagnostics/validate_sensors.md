---
title: Validate Sensors
sidebar_label: Validate Sensors
sidebar_position: 40
---

# Validate Sensors

Lists every telemetry sensor the flight controller is configured to send, and says for each one
whether the radio has it and is receiving it right now. Open it when a value somewhere in the
suite is missing or looks stale and you need to know whether the sensor, the telemetry slot or
the link is the problem.

## Where to find it

*System* → *Tools* → *Diagnostics* → *Validate Sensors*

Greyed out until the flight controller answers.
Read-only while the model is armed.

## Settings

The page has no settings. It reads the flight controller's telemetry slot configuration and
shows one row per configured sensor.

| Column | What it shows |
| --- | --- |
| Sensor | The sensor the flight controller has in that telemetry slot. |
| Status | `OK`, `NO DATA` or `INVALID` — see below. |

## Notes

The three statuses answer three different questions, and the colour matches the word:

| Status | Colour | What it means | What to do |
| --- | --- | --- | --- |
| `OK` | green | The radio has this sensor and is receiving it now. | Nothing. |
| `NO DATA` | orange | The radio has the sensor, but nothing current is arriving for it. | The model is off, the link is down, or the source of that one sensor — an ESC, a GPS receiver — is not reporting. |
| `INVALID` | red | The radio has no sensor of that name at all. | Let the radio discover the sensors: power the model up with telemetry running, then use *Discover new* on the radio's own Telemetry page. |

Two points worth knowing before you read a row:

- **`NO DATA` is not instant.** The radio marks a sensor as no longer current as soon as the
  whole link drops, but a single sensor that falls silent while the link stays up is only
  marked after its own timeout of about twenty seconds. A row can therefore still read `OK`
  for a few seconds after its source has stopped.
- **A sensor that has once been received keeps its name for the rest of the power-on.** So a
  row that goes from `OK` to `NO DATA` after a flight is the expected reading, not a fault: it
  says the radio still knows the sensor and is not being sent it.

*Documented against RFSuite 0.1.7.*
