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
| Mode | Select the governor operating mode: OFF, LIMIT, DIRECT, ELECTRIC or NITRO. Initial value: OFF. |
| Throttle type | Select the throttle input type: NORMAL, SWITCH or FUNCTION. Initial value: NORMAL. |
| Idle throttle | Minimum throttle output while armed. 0.0–25.0 %, in 0.1 % steps; initial value: 1.0 %. |
| Auto throttle | Throttle output during autorotation bailout. 0.0–25.0 %, in 0.1 % steps; initial value: 1.0 %. |
| Handover throttle% | Throttle threshold for handing over to governor control. 0–100 %, in 1 % steps; initial value: 20 %. |
| Throttle hold timeout | Timeout before disarming from throttle hold. 0.0–25.0 s, in 0.1 s steps; initial value: 5.0 s. |

## Notes

- Mode shows OFF while the flight controller's governor feature is disabled, even if another
  mode is stored. Leaving Mode untouched preserves both the stored mode and the feature bit.
  Changing Mode saves the selected mode and enables the governor feature for any mode other
  than OFF; selecting OFF disables it. Other feature bits are preserved.
  After a save, Flight Tuning > Governor, Tail Rotor and the dashboard follow the new GOVERNOR feature state without reconnecting.
- **Save restarts the flight controller when Mode or the governor feature changes**, because
  the firmware applies both only at start-up. The other settings save without a restart.
  See [Saving configuration](../../../reference/saving.md).
- *Reload* reads the flight controller again and discards unsaved changes. If a read fails,
  Save stays unavailable until Reload succeeds.

## Related

- [Rotorflight documentation](https://doc.rotorflight.org/)

*Documented against RFSuite 0.2.1.*
