---
title: Radio Config
sidebar_label: Radio Config
sidebar_position: 20
---

# Radio Config

Set the receiver channel values for centered sticks, full stick travel and throttle limits,
and the deadbands that keep small variations around stick center from becoming control inputs.

## Where to find it

*Configuration* → *Setup* → *Radio Config*

Read-only while the model is armed.

## Settings

All values are in microseconds (us). Settings are listed from left to right within each row.

| Setting | What it does |
| --- | --- |
| Center | In the Stick row, the channel value for centered roll, pitch and yaw sticks (0% input). Range: 1400–1600 us. |
| Deflection | In the Stick row, the maximum travel from center that gives 100% input at the stick limits. Range: 200–700 us. |
| Cyclic | In the Deadband row, the distance roll and pitch channels must move from center before they count as input. Use the smallest value that eliminates drift in Rotorflight Configurator's Rates Preview. Range: 0–100 us. |
| Yaw | In the Deadband row, the distance the yaw channel must move from center before it counts as input. Use the smallest value that eliminates drift in Rates Preview. Range: 0–100 us. |
| Min | In the Throttle row, the channel value for 0% throttle. The channel must reach at least 10 us below this value to signal throttle off and allow arming. Range: 860–1500 us. |
| Max | In the Throttle row, the channel value for 100% throttle. Range: 1510–2150 us. |

## Notes

These stick and throttle settings are stored on the flight controller; Save restarts it. See
[Saving configuration](../../reference/saving.md) for the shared Save action and restart notice.

## Related

- [Rotorflight documentation: Receiver tab](https://doc.rotorflight.org/configurator/tabs/receiver/)

*Documented against RFSuite 0.2.1.*
