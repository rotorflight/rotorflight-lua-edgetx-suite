---
title: Swashplate Geometry
sidebar_label: Geometry
sidebar_position: 20
---

# Swashplate Geometry

The swashplate's gains, pitch limits, phase and tilt correction. The header `*` lets the sticks
move the swashplate through the mixer while these values are set, so every change can be watched
on the model as it is made.

## Where to find it

*Configuration* → *Setup* → *Mixer* → *Geometry*

Read-only while the model is armed.

## Settings

| Setting | What it does |
| --- | --- |
| Cyclic Calibration | Cyclic gain, 20.0% to 200.0%, matched to the mechanical gain of the rotor head. |
| Collective Calibration | Collective gain, 20.0% to 200.0%, matched to the mechanical gain of the rotor head. |
| Geo Correction | -25.0% to +25.0%, in steps of 0.2%. Adjust until the positive and negative collective deflections are equal. |
| Cyclic Pitch Limit | The most cyclic blade pitch the mixer commands, 0.0° to 20.0°. |
| Collective Pitch Limit | The most collective blade pitch the mixer commands, 0.0° to 20.0°. |
| Total Pitch Limit | The most total blade pitch, cyclic and collective together, 0.0° to 36.0°. |
| Phase Angle | Phase offset of the swashplate controls, -180.0° to +180.0°. |
| Collective Tilt Correction + | -100% to +100%. At full positive collective, adjust until the swashplate pivot ball stays still while cyclic is added. |
| Collective Tilt Correction - | -100% to +100%. The same at full negative collective. |
| Save | Writes the geometry to EEPROM. |
| Reload | Reads the geometry from the flight controller again. |
| Star (`*`) | Switches swash setup mode on, after confirmation. Pressed again, it switches it off. |

## Swash setup mode

With `*` on, the flight controller passes the sticks through the mixer for setup, and the title
shows a `*`. A changed value is sent at most every 200 ms and applied at once, without an EEPROM
write. Save keeps it; leaving the page or Reload without Save puts back the geometry the flight
controller had before, and leaving the page also switches setup mode off. If a save fails, the
page stays unsaved, and leaving it puts back the geometry the flight controller has stored.

While setup mode is on, the flight controller refuses to arm. Nothing is sent while the model is
armed. If the flight controller does not report whether it is armed, the confirmation says so:
make sure the rotors cannot spin before you confirm.

## Related

- *Configuration* → *Setup* → *Mixer* → *Trims* trims the swashplate with the servos held at
  centre.
- [Rotorflight documentation](https://doc.rotorflight.org/)

*Documented against RFSuite 0.2.2.*
