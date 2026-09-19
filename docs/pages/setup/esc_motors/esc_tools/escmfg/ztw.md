---
title: ZTW Configurator
sidebar_label: ZTW
sidebar_position: 100
---

# ZTW Configurator

Reads the parameter block out of a ZTW ESC and writes it back, so the ESC can be set up from
the radio instead of from a computer. The controls follow the ESC's own firmware: the ESC
reports which of its settings it supports, and a setting the connected firmware does not have
is not shown.

## Where to find it

*Configuration* → *Setup* → *ESC & Motors* → *ESC Tools* → *ZTW*

Lit only while the flight controller reports this ESC telemetry protocol. Read-only while
the model is armed.

## Settings

The page opens on a safety notice; behind it stands a summary of the ESC's model, firmware and
version. *Section* switches between three groups of settings. Every row listed below is drawn
only where the connected ESC reports that setting as one of its own.

| Setting | What it does |
| --- | --- |
| Section | *Basic*, *Advanced* or *Governor*. Switching it rebuilds the list below; nothing is read from the ESC again. |

### Basic

| Setting | What it does |
| --- | --- |
| BEC Voltage (LV) | The BEC output on a low-voltage BEC: *6.0V*, *7.4V* or *8.4V*. |
| BEC Voltage (HV) | The BEC output on a high-voltage BEC, 6.0 V to 12.0 V in 0.2 V steps. |
| Motor Direction | Which way the motor turns, *CW* or *CCW*. |
| Startup Power | How hard the ESC pushes while the motor spools up, *Low*, *Medium* or *High*. |
| LED Color | The ESC's LED colour: *Red*, *Yellow*, *Orange*, *Green*, *Jade Green*, *Blue*, *Cyan*, *Purple*, *Pink* or *White*. |
| Smart Fan | The ESC's fan control, *On* or *Off*. |

### Advanced

| Setting | What it does |
| --- | --- |
| Motor Timing | Commutation timing, *Auto*, *Low*, *Medium* or *High*. |
| Acceleration | How quickly the ESC follows a change of throttle: *Fast*, *Normal*, *Slow* or *Very Slow*. |
| Brake Force | How hard the ESC brakes, 0 % to 100 % in steps of 1 %. |
| Synchronous Rectification | *On* or *Off*. |
| Capacity Correction | Trims the capacity the ESC accounts for, -10 % to +10 % in steps of 1 %. |
| Auto Restart Time | *Off* or *90s*. |
| Cell Cutoff | The cell voltage the ESC cuts off at: *Off*, *2.7V*, *3.0V*, *3.2V*, *3.4V*, *3.6V* or *3.8V*. Shown where the ESC reports either this setting or the high-voltage BEC. |

### Governor

| Setting | What it does |
| --- | --- |
| Governor Mode | Which governor holds the headspeed: *ESC Gov*, *External Gov* or *Flybarless Gov*. |
| Governor P Gain | The governor's proportional gain, 1 to 10 in steps of 1. |
| Governor I Gain | The governor's integral gain, 1 to 10 in steps of 1. |
| Motor Poles | The motor's pole count, 1 to 55 in steps of 1. |

## Notes

- *Governor P Gain*, *Governor I Gain* and *Motor Poles* are shown one above the word the
  parameter block stores, which is how Rotorflight's other configuration tools present them.
  Earlier releases put the page's number straight on the wire instead: the page then read one
  below what those tools show for the same ESC, a save stored a word one above the number that
  had been entered, and the lowest setting of each of the three rows could not be reached at
  all. The same ESC therefore reads one higher here than it did on an earlier release.
- The page opens behind a notice asking for the main and tail blades to be taken off. The
  settings appear once it is dismissed.
- Saving writes the whole parameter block to the ESC, not only the settings that were changed.
  A setting the page does not show, or does not touch, is written back as it was read, so a
  Save with nothing edited changes nothing in the ESC.
- The ESC is read when the page opens, and again on *Reload*. Switching *Section* does not read
  it again, and an edit made in one section is kept while another section is on screen.
- An unsaved edit is marked below the list. It reaches the ESC on Save and on nothing else: a
  *Reload*, and the read the page does the next time it is opened, both overwrite it with what
  the ESC holds.
- If the ESC does not answer the write, the page says so and the edit stays unsaved.

## Related

- [Rotorflight documentation](https://www.rotorflight.org/docs/)
- [ZTW](https://ztwesc.com/) -- what each of these settings does inside the ESC, and which
  models and firmware versions have it.

*Documented against RFSuite 0.1.7.*
