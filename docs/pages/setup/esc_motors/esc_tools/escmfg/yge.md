---
title: YGE Configurator
sidebar_label: YGE
sidebar_position: 90
---

# YGE Configurator

Reads the parameter block out of a YGE ESC and writes it back, so the ESC can be set up from
the radio instead of from a computer. The page opens on the ESC's own model name, firmware and
serial number (shown as S/N with plain digits), and offers its settings in three groups.

## Where to find it

*Configuration* → *Setup* → *ESC & Motors* → *ESC Tools* → *YGE*

Lit only while the flight controller reports the OpenYGE ESC telemetry protocol. Read-only
while the model is armed.

## Settings

Each setting has its own `?` for a short explanation.

Option names are shown in the radio's language; maker abbreviations such as CW/CCW and BEC remain in English as in the maker's software.

| Setting | What it does |
| --- | --- |
| Section | *Basic*, *Advanced* or *Other*. Switching it rebuilds the list below; nothing is read from the ESC again. |

### Basic

| Setting | What it does |
| --- | --- |
| Governor Mode | The ESC's operating mode: *Mode Free*, *Mode Ext*, *Mode Heli*, *Mode Store*, *Mode Glider*, *Mode Air* or *Mode F3A*. |
| Direction | Which way the motor turns, *Normal* or *Reverse*. |
| BEC Voltage | The BEC output voltage, 5.5 V to 8.4 V in 0.1 V steps. On an ESC model that has a 12 V BEC the range runs to 12.0 V. |
| Auto Restart Type | What the ESC does after a cutoff: *Off*, *Slowdown* or *Cutoff*. |
| Cell Cutoff | The per-cell voltage the ESC cuts at, 2.9 V to 3.4 V. |
| Current Limit | The ESC's current limit, 1 A to 655 A in 1 A steps. |
| F3C Auto | The F3C autorotation setting, *Off* or *On*. |
| Keep mAh | Whether the ESC keeps its consumed-capacity count across a power cycle, *Off* or *On*. |

### Advanced

| Setting | What it does |
| --- | --- |
| Min Start Power | Lower bound of the startup power, 0 % to 26 %. |
| Max Start Power | Upper bound of the startup power, 0 % to 31 %. |
| Startup Response | How hard the ESC comes up, *Normal* or *Smooth*. |
| Throttle Response | *Slow*, *Medium*, *Fast* or *Custom*, the last being the curve set from the ESC's own PC tool. |
| Motor Timing | Commutation timing. Four automatic modes — *Auto Normal*, *Auto Efficient*, *Auto Power*, *Auto Extreme* — and six fixed advance angles, *0 deg* to *30 deg* in six-degree steps. |
| Active Freewheel | *Off*, *Auto*, *Unused* or *Always On*. |

### Other

| Setting | What it does |
| --- | --- |
| Governor P Gain | 1 to 10. |
| Governor I Gain | 1 to 10. |
| Motor Pole Pairs | Pole pairs of the motor, 1 to 100. |
| Main Gear Teeth | 1 to 1800. |
| Pinion Teeth | 1 to 255. |
| Stick Zero | Throttle pulse width the ESC reads as zero, 900 µs to 1900 µs in 10 µs steps. |
| Stick Range | Pulse width span from zero to full throttle, 600 µs to 1500 µs in 10 µs steps. |

## Notes

- Opening this page stores the ESC's current limit in this flight controller's preferences on the radio,
  as whole amps and marked as this family's, where the dashboard reads it to show the current
  as an ESC load percentage and the ESC load announcement speaks it
  ([Power → Preferences](../../../power/preferences.md)). Nothing is asked of the flight
  controller for it -- the value comes out of the parameter block the page reads anyway -- and
  a visit that finds the same limit, already marked as this family's, writes nothing.
- Saving writes the whole parameter block to the ESC, not only the settings that were changed.
  Every setting the page offers is written back as it was read unless it was edited, and so is
  everything in the block the page does not show. That includes the bits of the flags byte the
  page does not set: it sets only bits 0..2 -- *Direction*, *F3C Auto* and *Keep mAh* -- and
  writes the rest back as the ESC reported them, bit 3 included: whether bit 3 is a 12 V BEC
  capability or a switch is not documented.
- After a save the page reads the ESC again on its own, and a further save is not
  accepted until that read has come back.
- *Motor Timing* is stored in the ESC in an encoding of its own, which is not the order the
  list is drawn in: the automatic modes and the fixed angles are separate ranges, and the ESC
  defines no value between them. The page translates in both directions, so what the row reads
  is what the ESC holds and what is picked is what the ESC is given. A word the ESC does not
  define — which no version of this page can produce, but an older one could — reads as
  *Auto Normal*, and the next Save replaces it with the word for *Auto Normal*, which is what
  the row was showing.
- The ESC is read when the page opens. Switching *Section* does not read it again.
- An unsaved edit is marked below the list, and is lost if the page is left without saving.

## Related

- [YGE](https://www.yge.de/) — the manufacturer's own documentation for what each of these
  settings does inside the ESC, and which of them a given firmware has.

*Documented against RFSuite 0.1.7.*
