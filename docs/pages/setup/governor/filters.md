---
title: Filters
sidebar_label: Filters
sidebar_position: 30
---

# Filters

The lowpass filters on the signals the governor works with: the headspeed, the battery voltage, the
Tail Torque Assist input, the precompensation and the governor's D-term.

## Where to find it

*Configuration* → *Setup* → *Governor* → *Filters*

Read-only while the model is armed.

## Settings

Values are read from the flight controller. The initial values below are the page's own before that
read, not firmware reset defaults. A lower cutoff smooths a signal more and passes its changes on
later.

| Setting | What it does |
| --- | --- |
| Headspeed Filter Cutoff | Cutoff of the lowpass filter on the headspeed signal the governor regulates on. 0 to 250 Hz; initial value 20 Hz. |
| Voltage Filter Cutoff | Cutoff of the lowpass filter on the battery voltage the governor compensates for. 0 to 250 Hz; initial value 20 Hz. |
| TTA Bandwidth | Cutoff of the lowpass filter on the Tail Torque Assist input. 0 to 250 Hz; initial value 0 Hz. |
| Precomp Bandwidth | Cutoff of the lowpass filter on the cyclic and collective precompensation. 0 to 25 Hz; initial value 10 Hz. |
| D-Term Cutoff | Cutoff of the lowpass filter on the governor's D-term. 0.0 to 25.0 Hz in 0.1 Hz steps; initial value 5.0 Hz. |

## Notes

- **Save restarts the flight controller when it changes a value** on this page, because the
  firmware hands the governor these settings only at start-up; a save that changes nothing does
  not restart it. See [Saving configuration](../../../reference/saving.md).
- *Reload* reads the flight controller again and discards unsaved changes.

## Related

- [Governor → General](general.md) -- the mode these filters serve.
- [Rotorflight documentation](https://doc.rotorflight.org/) -- the governor filters on the
  Configurator's Governor tab.

*Documented against RFSuite 0.2.2.*
