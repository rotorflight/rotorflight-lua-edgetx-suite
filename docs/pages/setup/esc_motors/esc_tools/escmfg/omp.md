---
title: OMP Configurator
sidebar_label: OMP
sidebar_position: 60
---

# OMP Configurator

Reads the parameter block out of an OMP ESC and writes it back, so the ESC can be set up from
the radio instead of from a computer. The controls follow the ESC's own firmware: the ESC
reports which settings it has, and a setting it does not report is not shown.

## Where to find it

*Configuration* → *Setup* → *ESC & Motors* → *ESC Tools* → *OMP*

Lit only while the flight controller reports this ESC telemetry protocol. Read-only while
the model is armed.

## Settings

The page opens on the ESC model and the firmware version the ESC reported. *Section* switches
between three groups of settings, and every row below is drawn only where the connected ESC
reports that setting as one it has.

| Setting | What it does |
| --- | --- |
| Section | *Basic*, *Advanced* or *Governor*. Switching it rebuilds the list below; nothing is read from the ESC again. |

### Basic

| Setting | What it does |
| --- | --- |
| BEC Voltage (LV) | The BEC output, *6.0V*, *7.4V* or *8.4V*. |
| BEC Voltage (HV) | The BEC output, *6.0V* to *12.0V* in 0.2 V steps. |
| Motor Direction | Which way the motor turns, *CW* or *CCW*. |
| Startup Power | How much power the ESC starts the motor with: *Low*, *Medium* or *High*. |
| LED Color | The colour of the ESC's LED: *Red*, *Yellow*, *Orange*, *Green*, *Jade Green*, *Blue*, *Cyan*, *Purple*, *Pink* or *White*. |
| Smart Fan | The ESC's fan control, *On* or *Off*. |

### Advanced

| Setting | What it does |
| --- | --- |
| Motor Timing | Commutation timing, *Auto*, *Low*, *Medium* or *High*. |
| Acceleration | How quickly the ESC follows a throttle change: *Fast*, *Normal*, *Slow* or *Very Slow*. |
| Brake Force | 0 % to 100 %, in steps of 1. |
| Synchronous Rectification | *On* or *Off*. |
| Capacity Correction | Corrects the capacity the ESC accounts with, -10 % to +10 % in steps of 1. |
| Auto Restart Time | *Off* or *90s*. |
| Cell Cutoff | The per-cell cutoff voltage: *Off*, *2.7V*, *3.0V*, *3.2V*, *3.4V*, *3.6V* or *3.8V*. Drawn where the ESC reports either of the two flags this setting has been carried under. |

### Governor

| Setting | What it does |
| --- | --- |
| Governor Mode | Which governor holds the head speed: *ESC Gov*, *External Gov* or *Flybarless Gov*. |
| Governor P Gain | 1 to 10, in steps of 1. |
| Governor I Gain | 1 to 10, in steps of 1. |
| Motor Poles | The motor's pole count, 1 to 55, in steps of 1. |

## Notes

- *Governor P Gain*, *Governor I Gain* and *Motor Poles* are shown one above the word the
  parameter block stores, which is how Rotorflight's other configuration tools present them.
  Earlier releases put the page's number straight on the wire instead: the page then read one
  below what those tools show for the same ESC, a save stored a word one above the number that
  had been entered, and the lowest setting of each of the three rows could not be reached at
  all. The same ESC therefore reads one higher here than it did on an earlier release.
- The page opens behind a notice asking for the main and tail blades to be taken off before
  the ESC is configured. The settings are drawn once that notice is dismissed.
- Saving writes the whole parameter block to the ESC, not only the settings that were
  changed. A setting the page does not show is written back as it was read, so a Save with
  nothing edited changes nothing in the ESC.
- The ESC is read when the page opens. Switching *Section* does not read it again; *Reload*
  does, and drops an edit that has not been saved.
- An unsaved edit is marked below the list, and is lost if the page is left without saving.
- If the ESC does not answer a write, the page reports the failure and the edit stays marked
  as unsaved.

## Related

- [Rotorflight documentation](https://www.rotorflight.org/docs/)

*Documented against RFSuite 0.1.7.*
