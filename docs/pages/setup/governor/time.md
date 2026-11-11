---
title: Ramp Time
sidebar_label: Ramp Time
sidebar_position: 20
---

# Ramp Time

How fast the governor ramps the throttle in each situation. Every time is the time a change from
0 to 100 % throttle would take, so a longer time is a gentler ramp.

## Where to find it

*Configuration* → *Setup* → *Governor* → *Ramp Time*

Read-only while the model is armed.

## Settings

Values are read from the flight controller, which stores each time in tenths of a second. The
initial values below are the page's own before that read, not firmware reset defaults.

| Setting | What it does |
| --- | --- |
| Startup time | The ramp for throttle changes below handover, at idle -- starting the motor, for example. 0.0 to 60.0 s in 0.1 s steps; initial value 20.0 s. |
| Spoolup time | The ramp from idle up to the target headspeed. Long enough to be gentle on the drivetrain, about 10 s. 0.0 to 60.0 s; initial value 10.0 s. |
| Spooldown time | The ramp for throttle reductions at idle. 0.0 to 60.0 s; initial value 3.0 s. |
| Tracking time | The ramp for changes of the target headspeed in flight, such as a profile switch. 0.0 to 10.0 s; initial value 2.0 s. |
| Recovery time | The ramp for fast spool-ups in flight: recovery after throttle hold or a fallback, and the bailout from an autorotation. 0.0 to 10.0 s; initial value 2.0 s. |

## Notes

- **Save restarts the flight controller when it changes a value** on this page, because the
  firmware hands the governor these settings only at start-up; a save that changes nothing does
  not restart it. See [Saving configuration](../../../reference/saving.md).
- *Startup time* shows its value without the unit; the others show it with `s`.

## Related

- [Governor → General](general.md) -- the mode and the throttle behaviour these ramps belong to.
- [Rotorflight documentation](https://doc.rotorflight.org/) -- the governor's ramps on the
  Configurator's Governor tab.

*Documented against RFSuite 0.2.2.*
