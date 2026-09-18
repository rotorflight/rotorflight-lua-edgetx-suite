---
title: Scorpion Configurator
sidebar_label: Scorpion
sidebar_position: 70
---

# Scorpion Configurator

Reads the parameter block out of a Scorpion ESC and writes it back, so the ESC can be set up
from the radio instead of from a computer. A pilot opens it to set the ESC's mode, its BEC and
telemetry output, the governor and the runup timing, and the protection limits.

## Where to find it

*Configuration* → *Setup* → *ESC & Motors* → *ESC Tools* → *Scorpion*

Lit only while the flight controller reports this ESC telemetry protocol. Read-only while
the model is armed.

## Settings

The page opens behind a safety notice, and above the list it shows the model, firmware and
version the ESC reported. *Section* switches between three groups of settings.

| Setting | What it does |
| --- | --- |
| Section | *Basic*, *Advanced* or *Limits*. Switching it rebuilds the list below; nothing is read from the ESC again. |

### Basic

| Setting | What it does |
| --- | --- |
| ESC Mode | The ESC's operating mode: *Heli Gov*, *Heli Store*, *VBar Gov*, *Ext Gov*, *Airplane*, *Boat* or *Quad*. |
| Motor Rotation | Direction the motor turns, *CCW* or *CW*. |
| BEC Voltage | The BEC output: *5.1 V*, *6.1 V*, *7.3 V*, *8.3 V*, or *Disabled* to leave it off. |
| Telemetry Protocol | The telemetry the ESC sends: *Standard*, *VBar*, *ExBus*, *Unsolicited* or *Fut S.Bus*. |

### Advanced

| Setting | What it does |
| --- | --- |
| Soft Start Time | How long the ESC takes to bring the motor up on a soft start, 0 s to 60 s in 1 s steps. |
| Runup Time | The runup time, 0 s to 60 s in 1 s steps. |
| Bailout Time | The bailout time, 0 s to 100 s in 1 s steps. |
| Governor P Gain | Proportional gain of the ESC's own governor, 0.30 to 1.80 in steps of 0.01. |
| Governor I Gain | Integral gain of the ESC's own governor, 1.50 to 2.50 in steps of 0.01. |
| Startup Sound | Whether the motor plays the startup sound, *On* or *Off*. |

### Limits

| Setting | What it does |
| --- | --- |
| Protection Delay | How long the ESC waits before the protections take effect, 0 s to 5 s in 1 s steps. |
| Cutoff Handling | How hard the ESC cuts back when a limit is reached, 0 % to 100 % in 1 % steps. |
| Max Temperature | The ESC's temperature limit, 0 °C to 400 °C in one-degree steps. |
| Max Current | The ESC's current limit, 0 A to 300 A in 1 A steps. |
| Min Voltage | The pack voltage the ESC cuts back at, 0.0 V to 70.0 V in 1 V steps. |
| Max Capacity Used | The capacity the ESC allows to be drawn, 0.0 Ah to 60.0 Ah in 1 Ah steps. |

## Notes

- The page opens behind a notice asking for the main and tail blades to be removed. Nothing
  on the page is reachable until that notice is acknowledged.
- Saving writes the whole parameter block to the ESC, not only the settings that were
  changed. The block that was read is the basis, so a setting this page does not offer goes
  back exactly as it was read, and a Save with nothing edited changes nothing in the ESC.
- Saving before the ESC has been read is refused with an error rather than written, since
  there would be no block to write back. It is this visit's read that counts: leaving the page
  and coming back starts again with nothing read, and so does *Reload*.
- Leaving the page puts the settings, the model, firmware and version back to what the page
  shows before it has read anything, so a visit whose read does not arrive shows the page's own
  initial values rather than the last ESC's.
- The ESC is read when the page opens, and again by *Reload*. Switching *Section* does not
  read it again.
- After a successful write the page reads the ESC back on its own. The flight controller
  drops its cached copy of the parameters on a write and refuses the next request until it
  has re-read them from the ESC, so that first refusal is waited out and retried instead of
  being reported as a failure.
- An unsaved edit is marked below the list, and is lost if the page is left without saving.
- If the ESC does not answer the write, *Save Failed* is shown and nothing on the screen has
  been confirmed.

## Related

- [Rotorflight documentation](https://www.rotorflight.org/docs/)
- [Scorpion Power System](https://www.scorpionsystem.com/) -- what each of these settings does
  inside the ESC, and which ESC models support it.

*Documented against RFSuite 0.1.7.*
