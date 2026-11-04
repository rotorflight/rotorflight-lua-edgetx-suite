---
title: Servo Trims
sidebar_label: Trims
sidebar_position: 40
---

# Servo Trims

Swashplate and tail trims for linkages that cannot be adjusted. The header `*` holds the servos
at centre so every change can be watched on the model as it is made.

## Where to find it

*Configuration* → *Setup* → *Mixer* → *Trims*

Read-only while the model is armed.

## Settings

| Setting | What it does |
| --- | --- |
| Roll trim | Swashplate roll trim, -100.0% to +100.0%. Use it only when the linkages cannot be adjusted. |
| Pitch trim | Swashplate pitch trim, -100.0% to +100.0%. |
| Col. trim | Swashplate collective trim, -100.0% to +100.0%. |
| Yaw. trim | Variable-pitch tail only. Tail blade pitch at zero yaw command, in degrees, -25.0° to +25.0°: the same value as Yaw Center Trim on the Tail page. |
| Save | Writes the trims to EEPROM. |
| Reload | Reads the trims from the flight controller again. |
| Star (`*`) | Holds the swashplate and tail servos at centre for live trimming, after confirmation. Pressed again, it hands the servos back to the flight controller. |

## Trimming live

With `*` on, the flight controller holds roll, pitch, yaw and collective at centre and the title
shows a `*`. A changed trim is sent at most every 200 ms and applied at once, without an EEPROM
write. Save keeps it; leaving the page or Reload without Save puts back the trims the flight
controller had before, and leaving the page also releases the servos.

Nothing is sent while the model is armed. If the flight controller does not report whether it
is armed, the confirmation says so: make sure the rotors cannot spin before you confirm.

## Related

- *Configuration* → *Setup* → *Mixer* → *Tail* sets the tail's centre trim with only the tail
  held at centre.
- [Rotorflight documentation](https://doc.rotorflight.org/)

*Documented against RFSuite 0.2.2.*
