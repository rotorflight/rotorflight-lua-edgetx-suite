---
title: General
sidebar_label: General
sidebar_position: 10
---

# General

Configure the governor's operating mode and throttle behaviour, including idle output and
autorotation bailout.

## Where to find it

*Configuration* → *Setup* → *Governor* → *General*

Read-only while the model is armed.

## Settings

Values are read from the flight controller. The defaults below are the page's initial values
before that read, not firmware reset defaults.

| Setting | What it does |
| --- | --- |
| Mode | OFF passes the throttle input straight to the motor; LIMIT applies the global idle throttle and the profile's minimum and maximum throttle; DIRECT handles slow spoolup and bailout recovery and leaves headspeed to an external governor or throttle curve; ELECTRIC and NITRO are complete governors for electric motors and combustion engines. Initial value: OFF. |
| Throttle type | NORMAL: the throttle input drives the motor until the target headspeed is reached, then the governor takes over until the input falls below handover. SWITCH: below handover the input drives the motor, above it the governor engages and the input sets the headspeed target (ELECTRIC and NITRO only). FUNCTION: the throttle input selects each governor mode. Initial value: NORMAL. |
| Idle throttle | Minimum throttle output while the governor is not actively controlling the headspeed. 0.0–25.0 %, in 0.1 % steps; initial value: 1.0 %. |
| Auto throttle | With NORMAL or SWITCH throttle type, a throttle input below this value cancels autorotation mode and so prevents a bailout; with FUNCTION it is the throttle output in autorotation mode. 0.0–25.0 %, in 0.1 % steps; initial value: 1.0 %. |
| Handover throttle% | Above this throttle input the governor controls the motor; below it the input is sent straight to the motor. The motor must be able to start below this level. 0–100 %, in 1 % steps; initial value: 20 %. |
| Throttle hold timeout | The grace period after throttle hold is activated while the governor is active: if the throttle input returns within it, the governor performs a recovery spoolup, which guards against an accidental throttle cut. 0.0–25.0 s, in 0.1 s steps; initial value: 5.0 s. |

## Notes

- Mode shows OFF while the flight controller's governor feature is disabled, even if another
  mode is stored. Leaving Mode untouched preserves both the stored mode and the feature bit.
  Changing Mode saves the selected mode and enables the governor feature for any mode other
  than OFF; selecting OFF disables it. Other feature bits are preserved.
  After a save, Flight Tuning > Governor, Tail Rotor and the dashboard follow the new GOVERNOR feature state without reconnecting.
- **Save restarts the flight controller when it changes any setting on this page, or the
  governor feature**, because the firmware hands the governor these settings only at start-up; a
  save that changes nothing does not restart it.
  See [Saving configuration](../../../reference/saving.md).
- *Reload* reads the flight controller again and discards unsaved changes. If a read fails,
  Save stays unavailable until Reload succeeds.

## Related

- [Rotorflight documentation](https://doc.rotorflight.org/)

*Documented against RFSuite 0.2.1.*
