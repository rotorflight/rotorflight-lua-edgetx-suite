---
title: XDFly Configurator
sidebar_label: XDFly
sidebar_position: 80
---

# XDFly Configurator

Reads the parameter block out of an XDFly ESC and writes it back, so the ESC can be set up
from the radio instead of from a separate programmer. A pilot opens it to set the BEC
voltage, the direction and startup behaviour of the motor, the battery cutoff and the ESC's
own governor, without unplugging anything.

## Where to find it

*Configuration* → *Setup* → *ESC & Motors* → *ESC Tools* → *XDFly*

Lit only while the flight controller reports this ESC telemetry protocol. Read-only while
the model is armed.

## Settings

The page opens on the ESC's model and firmware version. *Section* switches between three
groups of settings. Which rows a group shows depends on the connected ESC: it reports which
of these settings it has, and one it does not report is not drawn.

| Setting | What it does |
| --- | --- |
| Section | *Basic*, *Advanced* or *Governor*. Switching it rebuilds the list below; nothing is read from the ESC again. |

### Basic

| Setting | What it does |
| --- | --- |
| BEC Voltage (LV) | The BEC output on a low-voltage BEC: *6.0V*, *7.4V* or *8.4V*. |
| BEC Voltage (HV) | The BEC output on a high-voltage BEC: *6.0V* to *12.0V* in 0.2 V steps. |
| Motor Direction | Which way the ESC turns the motor, *CW* or *CCW*. |
| Startup Power | How hard the ESC pushes on startup, *Low*, *Medium* or *High*. |
| LED Color | The ESC's LED colour: *Red*, *Yellow*, *Orange*, *Green*, *Jade Green*, *Blue*, *Cyan*, *Purple*, *Pink* or *White*. |
| Smart Fan | The ESC's fan control, *On* or *Off*. |

### Advanced

| Setting | What it does |
| --- | --- |
| Motor Timing | Commutation timing, *Auto*, *Low*, *Medium* or *High*. |
| Acceleration | How quickly the ESC follows a throttle increase, *Fast*, *Normal*, *Slow* or *Very Slow*. |
| Brake Force | 0 to 100 %, in steps of 1 %. |
| Synchronous Rectification | *On* or *Off*. |
| Capacity Correction | Trims the ESC's capacity figure, -10 % to +10 % in steps of 1 %. |
| Auto Restart Time | *Off*, or *90s* to let the ESC restart by itself after that long. |
| Cell Cutoff | The per-cell cutoff voltage: *Off*, *2.7V*, *3.0V*, *3.2V*, *3.4V*, *3.6V* or *3.8V*. Shown where the ESC reports either this setting or the high-voltage BEC. |

### Governor

| Setting | What it does |
| --- | --- |
| Governor Mode | Which governor holds the headspeed: *ESC Gov*, *External Gov* or *Flybarless Gov*. |
| Governor P Gain | Proportional gain of the ESC's governor, 1 to 10. |
| Governor I Gain | Integral gain of the ESC's governor, 1 to 10. |
| Motor Poles | Number of motor poles, 1 to 55. Used by the ESC to turn its electrical RPM into a headspeed. |

## Notes

- *Governor P Gain*, *Governor I Gain* and *Motor Poles* are shown one above the word the
  parameter block stores, which is how Rotorflight's other configuration tools present them.
  Earlier releases put the page's number straight on the wire instead: the page then read one
  below what those tools show for the same ESC, a save stored a word one above the number that
  had been entered, and the lowest setting of each of the three rows could not be reached at
  all. The same ESC therefore reads one higher here than it did on an earlier release.
- The page opens behind a notice asking for the main and tail blades to be removed. The
  settings appear once it is acknowledged.
- Saving writes the whole parameter block to the ESC, not only the settings that were
  changed. Values this page has no control for go back as they were read, so a Save with
  nothing edited changes nothing in the ESC.
- The ESC is read when the page opens, and again on *Reload*. Switching *Section* does not
  read it again.
- An unsaved edit is marked below the list, and is lost if the page is left without saving.
- If the ESC does not answer a write, the page says so and the edits stay pending, so the
  save can be repeated.

## Related

- [Rotorflight documentation](https://www.rotorflight.org/docs/)
- [XDFly](https://www.xdfly.com/) -- what each of these settings does inside the ESC, and
  the manuals for the individual ESC models.

*Documented against RFSuite 0.1.7.*
