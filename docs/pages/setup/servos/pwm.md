---
title: PWM Output
sidebar_label: PWM Output
sidebar_position: 10
---

# PWM Output

Centre, travel, speed and direction of each servo on the flight controller's PWM outputs, one
servo at a time. The header `*` holds the servos so Center can be set while watching the servo
arm.

## Where to find it

*Configuration* → *Setup* → *Servos* → *PWM Output*

Read-only while the model is armed. Save and `*` are offered once the selected servo has been
read; a flight controller with no PWM servo offers neither.

## Settings

| Setting | What it does |
| --- | --- |
| Servo | The servo output whose settings are shown below. Picking another servo while this one has unsaved changes asks first: Save stores them, Discard puts back what the flight controller holds. |
| Center | Centre position, 50 to 2250 µs; the servo arm should be level there. |
| Minimum | Lowest point of travel, -1000 to 1000 µs; it limits the negative throw so the servo arm does not bind. |
| Maximum | Highest point of travel, -1000 to 1000 µs; it limits the positive throw so the servo arm does not bind. |
| Scale Negative | Scaling on the negative side, 100 to 1000; typically 500 for 1520 µs servos and 250 for 760 µs servos. |
| Scale Positive | Scaling on the positive side, 100 to 1000. |
| Rate | PWM update rate, 50 to 5000 Hz; 50 Hz for analog servos, typically 100 to 560 Hz for digital ones. Check the servo's data sheet. |
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
controller had before; leaving the page also releases the servos, and Reload switches `*` off.
If a save fails, the page stays unsaved, and leaving it puts back the centre the flight
controller has stored. Only the centre is put back: other settings the failed save sent can stay
active in the flight controller until it restarts, which **Restart FC** in the notice does.

While `*` is on, the flight controller refuses to arm. Nothing is sent while the model is armed.
If the flight controller does not report whether it is armed, the confirmation says so: make
sure the rotors cannot spin before you confirm.

## Related

- *Configuration* → *Setup* → *Servos* → *BUS Output* sets the servos on a serial bus output.
- [Rotorflight documentation](https://doc.rotorflight.org/)

*Documented against RFSuite 0.2.2.*
