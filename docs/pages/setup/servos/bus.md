---
title: BUS Output
sidebar_label: BUS Output
sidebar_position: 20
---

# BUS Output

Centre, travel, speed and direction of each servo on a serial bus output (SBUS or F.Bus), one
servo at a time. The header `*` holds the servos so Center can be set while watching the servo
arm.

## Where to find it

*Configuration* → *Setup* → *Servos* → *BUS Output*

Read-only while the model is armed. Save and `*` are offered once the selected servo has been
read.

## Settings

| Setting | What it does |
| --- | --- |
| Servo | The bus servo whose settings are shown below, 1 to 16. Picking another servo while this one has unsaved changes asks first: Save stores them, Discard puts back what the flight controller holds. |
| Center | Centre position, 1000 to 2000 µs; the servo arm should be level there. |
| Minimum | Lowest point of travel, -500 to -1 µs; it limits the negative throw so the servo arm does not bind. |
| Maximum | Highest point of travel, 1 to 500 µs; it limits the positive throw so the servo arm does not bind. |
| Scale Negative | Scaling on the negative side, 100 to 1000; typically 500 for 1520 µs servos and 250 for 760 µs servos. |
| Scale Positive | Scaling on the positive side, 100 to 1000. |
| Speed | The time in ms the servo takes for 60° of rotation, 0 to 60000; 0 means no limit. |
| Reverse | Reverses the servo when it moves the wrong way. |
| Geometry | Corrects the rotational geometry at the ends of travel; not for linear servos. |
| Save | Writes the selected servo's settings to EEPROM. |
| Reload | Reads the servos from the flight controller again. |
| Star (`*`) | Holds the servos for setting Center, after confirmation. Pressed again, it hands them back to the flight controller. |

## Setting Center live

With `*` on, the flight controller holds every servo at its centre and the title shows a `*`.
A changed Center is sent at most every 200 ms and applied at once, without an EEPROM write. The
other settings and the servo selector are shown as text and cannot be changed until `*` is
switched off.

Save keeps the change. Leaving the page or Reload without Save puts back the centre the flight
controller had before, and leaving the page also releases the servos. If a save fails, the page
stays unsaved, and leaving it puts back the centre the flight controller has stored.

While `*` is on, the flight controller refuses to arm. Nothing is sent while the model is armed.
If the flight controller does not report whether it is armed, the confirmation says so: make
sure the rotors cannot spin before you confirm.

## Related

- *Configuration* → *Setup* → *Servos* → *PWM Output* sets the servos on the PWM outputs.
- [Rotorflight documentation](https://doc.rotorflight.org/)

*Documented against RFSuite 0.2.2.*
