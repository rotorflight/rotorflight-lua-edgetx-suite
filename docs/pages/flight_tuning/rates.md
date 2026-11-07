---
title: Rates
sidebar_label: Rates
sidebar_position: 20
---

# Rates

How far and how fast the helicopter follows the sticks. The page holds one rate profile: a
rate type, and three values for each of Roll, Pitch, Yaw and Collective. What the three
columns are called and what they mean depends on the rate type.

## Where to find it

*Configuration* → *Flight Tuning* → *Rates*

Read-only while the model is armed.

## Settings

| Setting | What it does |
| --- | --- |
| Rates Type | Which rate curve the flight controller applies. Set on the flight controller and shown in the page heading; the column titles and the ranges below follow it. *None* applies no curve at all, and its cells are read-only. |
| First column | The rate at full stick, or the sensitivity around centre, depending on the type. *RC Rate*, *Rate* or *Center Sens*. |
| Second column | Raises the rate at full stick while reducing sensitivity in between, or shifts the vertex of the curve. *Super Rate*, *Acro+*, *Rate*, *Max Rate* or *Shape*. |
| Third column | Reduces sensitivity around centre stick. *Expo* or *RC Curve*. |

Each cell is bounded by the limits its rate type actually has. For Roll, Pitch and Yaw
those are the limits the flight controller itself enforces when the settings are stored; for
Collective, which the flight controller does not limit, they are the ones the Rotorflight
Configurator applies to the same field. Raceflight's RC Rate and Actual's and Quick's
rates therefore reach 2000 °/s on Roll, Pitch and Yaw, where the Configurator stops at
1000 °/s: a value above 1000 °/s, set over the CLI or by the Tune Advisor's Apply, is shown
as the flight controller holds it.

| Rates Type | First column | Second column | Third column |
| --- | --- | --- | --- |
| None | read-only | read-only | read-only |
| Betaflight | RC Rate 0.01 to 2.55 (collective 0.01 to 2.20) | Super Rate 0.00 to 0.90 (collective 0.00 to 0.99) | Expo 0.00 to 1.00 |
| Raceflight | RC Rate 10 to 2000 °/s (collective 0.00 to 25.00) | Acro+ 0 to 255 | Expo 0 to 100 |
| KISS | RC Rate 0.01 to 2.55 | Rate 0.00 to 0.90 (collective 0.00 to 0.99) | RC Curve 0.00 to 1.00 |
| Actual | Center Sens 10 to 2000 °/s (collective 0.00 to 25.00) | Max Rate 0 to 2000 °/s (collective 0.00 to 25.00) | Expo 0.00 to 1.00 |
| Quick | RC Rate 0.01 to 2.55 | Max Rate 0 to 2000 °/s | Expo 0.00 to 1.00 |
| Rotorflight | Rate 10 to 1000 °/s (collective 0.00 to 25.00) | Shape 0 to 100 (collective 0 to 127) | Expo 0 to 100 |

The collective row has its own range wherever the table names one. The flight controller
limits Roll, Pitch and Yaw per rate type when it stores the settings and leaves Collective
alone, so Collective keeps the wider range the Configurator offers.

Save reports success only once the flight controller has stored the rates; a failed or
refused save is shown. After a successful save, the page reads the values back because the
flight controller limits Roll, Pitch and Yaw to its own per-type range when it stores them.

## Notes

- Changing the rate type changes what the three columns mean and what they may hold. The
  values are not converted: read the new type's values off the board before flying it.
- For Roll, Pitch and Yaw the range above is the flight controller's own, so every value it
  holds after a save is shown as it is. A Collective value outside the range -- one set over
  the CLI, or left behind by an older release -- is displayed at the limit, and is sent back
  to the board unchanged unless that cell is edited; editing it moves it inside the range.
- Response time, accelerometer limit, setpoint boost and the cyclic ring belong to the same
  rate profile and are on *Advanced* → *Rates (Advanced)*.
- Which rate profile is being edited is shown in the page heading. It follows the flight
  controller's active rate profile, so a rate-profile switch reloads the page and redraws its
  heading and rows. With an edit not yet saved the page is not reloaded and Save is refused
  until it is -- see [Saving configuration](../../reference/saving.md).

## Related

- [Rotorflight documentation](https://doc.rotorflight.org/)

*Documented against RFSuite 0.1.7.*
