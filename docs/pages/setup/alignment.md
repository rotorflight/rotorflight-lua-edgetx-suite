---
title: Alignment
sidebar_label: Alignment
sidebar_position: 50
---

# Alignment

Set how the flight controller is mounted in the model -- its roll, pitch and yaw offsets and the
magnetometer's orientation -- and check the result on a live picture of the helicopter that follows
the board's attitude.

## Where to find it

*Configuration* → *Setup* → *Alignment*

Read-only while the model is armed.

## Settings

| Setting | What it does |
| --- | --- |
| Roll | Board roll offset, in degrees, from -180 to 360. Disabled while Live View runs. |
| Pitch | Board pitch offset, in degrees, from -180 to 360. Disabled while Live View runs. |
| Yaw | Board yaw offset, in degrees, from -180 to 360. Disabled while Live View runs. |
| Mag | Magnetometer orientation: Default, CW 0/90/180/270 deg, the same four flipped, or Custom. Disabled while Live View runs. |
| Live View | Shows the board's attitude for 60 seconds, four readings a second; the button counts down and ends Live View early when pressed again. |
| Refresh | Reads the attitude once and redraws the picture. Disabled while Live View runs. |
| Auto-align | On firmware API 12.10 or later, detects the board mounting angle from a level pose followed by lifting the tail at least 20 degrees. The action appears only when the flight controller confirms command support. The flight controller applies a successful result at once and the page loads it into Roll, Pitch and Yaw; Save stores it now, and otherwise the flight controller stores it itself the next time the model is disarmed. |
| Save | Writes the offsets and the magnetometer orientation, then restarts the flight controller. |
| Reload | Reads the alignment from the flight controller again. |
| Star | Turns the view so the tail faces you, after a confirmation. |

## The live picture

The left panel shows the live roll, pitch and yaw, the offsets as set, the view's yaw, and the
nose direction (*Nose Up*, *Nose Down* or *Nose Level*, with *Leaning Left* or *Leaning Right*
when the board rolls more than 3.5 degrees). The picture on the right is the helicopter with the
offsets applied, drawn in the colour scheme of *Settings* > *General* > *Appearance*: outlines and
blades in the text colour, the fuselage in three greys, the nose face in the accent colour.

The picture moves only when roll or pitch has changed by more than 0.3 degrees, or yaw has
changed, since it was last drawn, so a model lying still holds a steady picture. The readouts on
the left follow every reading.

## Notes

Saving restarts the flight controller, so the link drops for a moment after Save.

Auto-align requires a disarmed model and a calibrated accelerometer. It waits up to 15 seconds for
the tail lift. Keep the model still while level, start the action, then lift the tail in one clear
movement. Leaving the page stops polling; the flight controller may still finish the procedure, and
the page reads the current alignment again when it is reopened.

## Related

- [Rotorflight documentation](https://doc.rotorflight.org/)

*Documented against RFSuite 0.1.7.*
