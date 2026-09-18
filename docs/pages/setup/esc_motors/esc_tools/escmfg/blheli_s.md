---
title: BLHeli_S Configurator
sidebar_label: BLHeli_S
sidebar_position: 20
---

# BLHeli_S Configurator

Reads the parameter block out of a BLHeli_S ESC and writes it back, so the ESC can be set up
from the radio instead of from a computer. A pilot opens it to set the motor's direction, the
startup power and commutation timing, the temperature protection and the ESC's beeps.

## Where to find it

*Configuration* → *Setup* → *ESC & Motors* → *ESC Tools* → *BLHeli_S*

Lit only while the flight controller reports this ESC telemetry protocol. Read-only while
the model is armed.

The same protocol lights the *AM32* and *Bluejay* tiles beside it, because what the flight
controller reports is the telemetry protocol and all three share it. BLHeli_S and Bluejay
report the same ESC family as well, so this page tells them apart by the ESC's main revision
and refuses a Bluejay block rather than decoding it with its own field list — the two layouts
share five header fields and then diverge. That check, and what a refused read leaves on the
page, are described in [Saving configuration](../../../../../reference/saving.md).

## Settings

The page opens on a safety notice, and behind it on a summary of the ESC's model, firmware
and version. *Section* switches between three groups of settings; every setting of the chosen
group is always shown.

| Setting | What it does |
| --- | --- |
| ESC Target | Which ESC the page talks to, *ESC 1* or *ESC 2*. Shown only where the flight controller reports more than one motor. Changing it starts the connection again from the beginning, so the values on screen are replaced by the other ESC's after a few seconds. |
| Section | *Basic*, *Advanced* or *Input*. Switching it rebuilds the list below; nothing is read from the ESC again. |

### Basic

| Setting | What it does |
| --- | --- |
| Motor Direction | *Normal*, *Reversed*, *Bidirectional 3D* or *Bidirectional 3D Rev*. |
| Startup Power | The power the ESC starts the motor with, as a multiplier: *0.031* up to *1.50* in the thirteen steps the ESC itself offers. |
| Motor Timing | The commutation timing: *Low*, *Medium Low*, *Medium*, *Medium High* or *High*. |
| Demag Compensation | *Off*, *Low* or *High*. |
| Brake on Stop | *Off* or *On*. |

### Advanced

| Setting | What it does |
| --- | --- |
| Temperature Protection | The temperature the protection acts on: *Disabled*, or *80C* to *140C* in ten-degree steps. |
| Beep Strength | How loud the ESC's beeps are, 1 to 255. |
| Beacon Strength | How loud the lost-model beacon is, 1 to 255. |
| Beacon Delay | How long after the throttle stops the beacon starts: *1 minute*, *2 minutes*, *5 minutes*, *10 minutes* or *Infinite*, which never starts it. |

### Input

| Setting | What it does |
| --- | --- |
| PPM Min Throttle | 1000 us to 1500 us in four-microsecond steps. |
| PPM Max Throttle | 1504 us to 2020 us in four-microsecond steps. |
| PPM Center Throttle | 1000 us to 2020 us in four-microsecond steps. Used by the bidirectional modes. |

## Notes

- The page opens behind a safety notice asking for the main and tail blades to be removed
  before the ESC is configured. Nothing else is drawn until the notice is dismissed.
- **Opening the page takes several seconds before any value appears.** The flight controller
  has to be put into forward-programming mode and pointed at the ESC first, and that sequence
  waits for the ESC before the parameters are asked for at all. Changing *ESC Target* runs the
  same sequence again.
- Saving writes the whole parameter block to the ESC, not only the settings that were
  changed. A setting the page does not offer is written back as it was read, so a Save with
  nothing edited changes nothing in the ESC.
- Saving before this visit has read the ESC is refused with an error rather than written,
  since there would be no block to write back. Leaving the page and coming back starts again
  with nothing read, and so does *Reload* and a change of *ESC Target*.
- Leaving the page puts the settings, the model, firmware and version back to what the page
  shows before it has read anything, so a visit whose read does not arrive shows the page's
  own initial values rather than the last ESC's.
- An unsaved edit is marked below the list, and is lost if the page is left without saving.
- If the ESC does not answer the write, the page says so and nothing on the screen has been
  confirmed.

## Related

- [Bluejay Configurator](bluejay.md) — the other page behind the same tile condition and the
  same ESC family, for ESCs running Bluejay rather than BLHeli_S.
- [Saving configuration](../../../../../reference/saving.md) — what the ESC Configurator
  pages read and write, and when a read or a Save is refused.
- [Rotorflight documentation](https://www.rotorflight.org/docs/) — what each of these
  settings does inside the ESC.

*Documented against RFSuite 0.1.7.*
