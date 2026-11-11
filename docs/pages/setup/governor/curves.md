---
title: Bypass Curve
sidebar_label: Bypass Curve
sidebar_position: 40
---

# Bypass Curve

The throttle curve the flight controller flies while governor bypass is active. Bypass switches the
governor off, and the throttle then follows this curve over the collective stick, from the bottom
of its travel to the top. Governor bypass is a flight mode; its switch is set up under *Setup* →
*Controls* → *Modes*.

## Where to find it

*Configuration* → *Setup* → *Governor* → *Bypass Curve*

Read-only while the model is armed.

## Settings

Values are read from the flight controller. The initial values below are the page's own before that
read, not firmware reset defaults.

| Setting | What it does |
| --- | --- |
| Nine points, 0% to 100% | The throttle output at nine evenly spaced collective stick positions, the first at the bottom of the stick's travel and the last at the top; between two points the throttle follows a straight line. 0 to 100 % in 1 % steps; initial values 0, 5, 10, 15, 25, 30, 35, 40, 50 %. |
| Refresh Graph | Redraws the curve above the points from the values entered. |

## Notes

- The flight controller stores each point in half-percent steps, and this page shows whole percent.
  A point set to a half percent elsewhere, in the Rotorflight Configurator for example, is shown
  rounded, and a save leaves it as it is unless that point is changed here.
- **Save restarts the flight controller when it changes a value** on this page, because the
  firmware hands the governor these settings only at start-up; a save that changes nothing does
  not restart it. See [Saving configuration](../../../reference/saving.md).
- *Reload* reads the flight controller again and discards unsaved changes.

## Related

- [Governor → General](general.md) -- the governor this curve stands in for.
- [Rotorflight documentation](https://doc.rotorflight.org/) -- governor bypass and its throttle
  curve on the Configurator's Governor and Modes tabs.

*Documented against RFSuite 0.2.2.*
