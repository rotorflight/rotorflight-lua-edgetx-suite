---
title: Bluejay Configurator
sidebar_label: Bluejay
sidebar_position: 30
---

# Bluejay Configurator

Reads the parameter block out of a Bluejay ESC and writes it back, so the ESC can be set up
from the radio instead of from a computer. The controls follow the ESC's own firmware: what
the page offers depends on the layout revision the ESC reports, and a setting the connected
firmware does not have is not shown.

## Where to find it

*Configuration* → *Setup* → *ESC & Motors* → *ESC Tools* → *Bluejay*

Lit only while the flight controller reports this ESC telemetry protocol. Read-only while
the model is armed.

## Settings

The page opens on a summary of the ESC's firmware and version. *Section* switches between
four groups of settings; on a model with more than one ESC, *ESC Target* chooses which one
is read and written.

| Setting | What it does |
| --- | --- |
| ESC Target | Which ESC of the model is read and written. Only shown where the flight controller reports more than one. |
| Section | *General*, *Brake*, *Beacon* or *Other*. Switching it rebuilds the list below; nothing is read from the ESC again. |

### General

| Setting | What it does |
| --- | --- |
| Motor Direction | *Normal*, *Reversed*, *Forward/Reverse (3D)* or *Forward/Reverse (3D) Rev*. |
| Rampup Power | How hard the ESC may push during rampup, *Off* or 1x to 13x, where 1x protects most. On a layout revision of 200 or below the same control is *Rampup Start Power*, given as a percentage. |
| Min Startup Power | Lower bound of the startup power, 1000 to 1125 in steps of 5. |
| Max Startup Power | Upper bound of the startup power, 1004 to 1300 in steps of 4. Needs layout revision 201 or above. |
| PWM Frequency | *24kHz*, *48kHz* or *96kHz*, and from layout revision 209 also *Dynamic*, which lets the ESC pick by throttle. Shown on layout revision 205 and on 209 or above. |

### Brake

| Setting | What it does |
| --- | --- |
| Motor Timing | Commutation timing, *0 deg (Low)* to *30 deg (High)* in five steps. |
| Demag Compensation | *Off*, *Low* or *High*. |
| Brake on Stop | Whether the ESC brakes once the throttle is closed. |
| Braking Strength | 0 to 255. On layout revision 202 the same byte is a three-way *Braking Mode* instead; needs layout revision 204 or above for the numeric control. |
| LED Control | The ESC's LED colour, where the connected firmware has one. |

### Beacon

| Setting | What it does |
| --- | --- |
| Beep Strength | Volume of the ESC's beeps, 1 to 255. |
| Beacon Strength | Volume of the lost-model beacon, 1 to 255. |
| Beacon Delay | How long after the throttle is closed the beacon starts: 1, 2, 5 or 10 minutes, or *Infinite* to leave it off. |
| Startup Beep | Whether the ESC beeps when it powers up. Shown on layout revision 202 and below, and on 205, where it is a three-way *Off* / *Normal* / *Custom*. |

### Other

| Setting | What it does |
| --- | --- |
| Temperature Protection | *Disabled*, or the temperature the ESC starts limiting at, 80 °C to 140 °C in ten-degree steps. |
| Low RPM Power Protection | On layout revision 200 and below only. |
| Power Rating | *1S* or *2S+*. Needs layout revision 206 or above. |
| Force EDT Arm | Whether extended DShot telemetry is armed regardless of what the ESC detects. Needs layout revision 207 or above. |
| Dithering | On layout revision 207 and below only. |
| Threshold 96to48 | Throttle below which a *Dynamic* PWM frequency drops from 96 kHz to 48 kHz, 0 to 100 %. Needs layout revision 209 or above. |
| Threshold 48to24 | Throttle below which it drops from 48 kHz to 24 kHz, 0 to 100 %. Needs layout revision 209 or above. |

## Notes

- Saving writes the whole parameter block to the ESC, not only the settings that were
  changed. A setting the page leaves alone is written back as the byte it was read from, so
  a Save with nothing edited changes nothing in the ESC.
- The choices of *Motor Direction*, *Motor Timing*, *Demag Compensation*, *Beacon Delay* and
  *Power Rating* stand for the numbers Bluejay itself stores them as, which start at 1, and
  the chosen number is what the ESC receives. A number the ESC answers with that has no entry
  -- a 0 written by an earlier version of this page, say, which Bluejay runs as bidirectional
  and reversed when it is the direction -- is shown as *Unknown (n)*, cannot be chosen, and is
  written back unchanged by a Save. An ESC saved from an earlier version of this page holds
  these settings one entry off what was picked there, so check them after updating. Until the
  ESC has been read, *Motor Direction*, *Motor Timing* and *Demag Compensation* show
  *Unknown (0)*.
- *Threshold 96to48* is held at or below *Threshold 48to24* when the block is written, since
  the ESC steps down through both.
- A BLHeli_S ESC answers with the same ESC family byte and the same block length as a Bluejay
  one, so the page decides on the main revision the ESC reports: 0 is Bluejay, 16 is BLHeli_S.
  A block from a BLHeli_S ESC is refused rather than shown here: the two layouts share five
  header fields and then diverge, so that ESC's governor I gain, governor mode and low
  voltage limit would appear as *Min Startup Power*, *Startup Beep* and *Dithering* -- and a
  Save would write them back with those meanings. Use the *BLHeli_S* page for that ESC.
- Save is refused until the ESC has been read, and says so. The write is the whole block, so
  without a read every setting the page does not itself show would go to the ESC as zero.
- Leaving the page drops what the ESC answered -- the block, its firmware and version, and
  the values in the list -- so the next visit shows nothing until its own read lands.
- The ESC is read when the page opens. Switching *ESC Target* reads the newly chosen ESC;
  switching *Section* does not. Until a read succeeds for the selected target, its initial
  values and no model name are shown, unless the session holds a read from that same target.

## Related

- [Bluejay firmware documentation](https://github.com/bird-sanctuary/bluejay) — what each of
  these settings does inside the ESC, and which firmware version introduced it.

*Documented against RFSuite 0.1.7.*
