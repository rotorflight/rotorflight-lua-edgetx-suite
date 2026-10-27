---
title: Governor
sidebar_label: Governor
sidebar_position: 40
---

# Governor

Tune headspeed, throttle limits, governor gains, precompensation and Tail Torque Assist in
the active PID profile. The heading shows the profile number and stored governor mode.

## Where to find it

*Configuration* → *Flight Tuning* → *Governor*

Read-only while the model is armed.
Needs MSP API 12.09; hidden on an older flight controller.

With governor mode OFF the page shows a disabled message instead of fields, and Save and
Reload are disabled. LIMIT and DIRECT show only the two throttle limits. ELECTRO (the page's
name for ELECTRIC) and NITRO show all fields below.

With the flight controller's GOVERNOR feature off, no governor runs regardless of the stored
mode. The page shows the mode as OFF and hides the governor gains, as *Setup* → *Governor* →
*General* does. The stored mode is kept and returns when the feature is switched on.

## Settings

Values are read from the flight controller. All fields except the throttle limits are shown
only in ELECTRO and NITRO modes.

| Setting | What it does |
| --- | --- |
| Full headspeed (rpm) | Target headspeed is the full headspeed times the throttle input. Page range: 0 to 30000 rpm, in steps of 10. |
| Min throttle (%) | The minimum throttle output the governor may use. Page range: 10 to 100%; also shown in LIMIT and DIRECT. |
| Max throttle (%) | The maximum throttle output the governor may use. Page range: 10 to 100%; also shown in LIMIT and DIRECT. |
| Master gain | Master PID loop gain, usually 10..100. Page range: 0 to 255. |
| Gains / P | PID loop P-term gain, usually 10..100. Page range: 0 to 255. |
| Gains / I | PID loop I-term gain, usually 10..100. Page range: 0 to 255. |
| Gains / D | PID loop D-term gain, usually 0..100. Page range: 0 to 255. |
| Gains / FF | Collective/cyclic feedforward gain, usually 0..100. Page range: 0 to 255. |
| Precomp / YAW | How much yaw is mixed into the feedforward, usually 20..100. Page range: 0 to 255. |
| Precomp / CYC | How much cyclic is mixed into the feedforward, usually 20..100. Page range: 0 to 255. |
| Precomp / COL | How much collective is mixed into the feedforward, usually 20..100. Page range: 0 to 255. |
| Tail Torque Assist / MASTER GAIN | Tail Torque Assist gain; raises headspeed to control the tail in the negative direction, usually 50..150. Page range: 0 to 255. |
| Tail Torque Assist / LIMIT | Maximum Tail Torque Assist headspeed increase over Full headspeed, usually 20..50%. Page range: 0 to 255%, in steps of 1%. |

## Notes

- Set the operating mode under *Setup* → *Governor* → *General*; this page changes only the
  governor profile, including the fields shared with *Flight Tuning* → *Advanced* → *Tail Rotor*.
- Changing headspeed can require the PID controller gains to be tuned again.
- A profile switch keeps unsaved edits on screen and refuses Save until the original profile
  is selected again or Reload reads the new one.
- Save writes the values present when pressed, then commits them to EEPROM without a restart;
  success is reported only after the flight controller confirms storage, and the page reads
  back the values. A refused or failed save keeps the edits unsaved.
  See [Saving configuration](../../reference/saving.md).

## Related

- [Rotorflight governor documentation](https://doc.rotorflight.org/docs/configurator/tabs/governor)
- [Rotorflight governor profile settings](https://doc.rotorflight.org/docs/configurator/tabs/governor#governor-profile-settings)

*Documented against RFSuite 0.2.1.*
