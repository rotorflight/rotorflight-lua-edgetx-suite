---
title: Tail Setup
sidebar_label: Tail
sidebar_position: 30
---

# Tail Setup

Tail rotor type, yaw direction, centre trim, yaw gain and yaw limits. On a variable-pitch tail
the header `*` holds the yaw input at centre, so Yaw Center Trim can be set while watching the
tail blades move.

## Where to find it

*Configuration* → *Setup* → *Mixer* → *Tail*

Read-only while the model is armed.

## Settings

| Setting | What it does |
| --- | --- |
| Tail Mode | *Variable Pitch*: a tail servo on Servo 4. *Motorized Tail*: a tail motor on Motor 2. *Bidirectional Motor*: a reversible tail motor. Changing it starts Yaw Calibration from that mode's usual value (25% for variable pitch, 100% for a motor) and restarts the flight controller on Save. |
| Yaw Direction | *Normal* or *Reversed*. Reverse it when the tail moves the wrong way for a yaw input; it depends on the tail rotor direction and the servo or ESC setup. |
| Yaw Center Trim | Variable pitch only. Tail blade pitch at zero yaw command, in degrees, -25.0° to +25.0°. With `*` on, the tail moves to it about half a second after the last change. |
| Tail center offset | Motorised and bidirectional tails only, in place of Yaw Center Trim. Tail motor throttle at zero yaw command, -50.0% to +50.0%. |
| Yaw Calibration | Yaw gain matched to the tail mechanics, 20.0% to 200.0%. Usually 50-150% for a servo tail, and quite different for a motorised tail. |
| Yaw CW Limit | Limit for clockwise yaw: a blade angle up to 60.0° on a servo tail, a throttle up to 200.0% on a motorised tail. Default 30.0°. |
| Yaw CCW Limit | Limit for counter-clockwise yaw, with the same units and ranges as the CW limit. |
| Tail Motor Idle | Motorised and bidirectional tails only. Lowest throttle sent to the tail motor, 0 to 25.0%; set it just high enough that the motor does not stop. |
| Save | Writes the tail settings to EEPROM. A Tail Mode change also restarts the flight controller. |
| Reload | Reads the tail settings from the flight controller again. |
| Star (`*`) | Variable pitch only: holds the yaw input at centre for live trimming, after confirmation. See below. |

Centre trim and the two limits are stored as the flight controller's raw numbers. Changing Tail
Mode changes how they read (degrees or percent), not what Save writes.

## Setting the centre trim live

1. Make sure the page shows the tail as the flight controller has it: Tail Mode *Variable Pitch*
   and nothing edited. Otherwise `*` is greyed out; Save or Reload first.
2. Press `*` and confirm. The flight controller holds the yaw input at centre, and the title
   shows a `*`. Until `*` is pressed again or the page is left, the other settings are shown
   greyed out as text and cannot be changed; only Yaw Center Trim can be edited.
3. Change Yaw Center Trim until the tail blades sit at zero pitch. About half a second after the
   last change, the value is sent to the flight controller, which applies it at once without
   writing it to EEPROM.
4. Press Save to keep it. Leaving the page or Reload without Save puts back the trim the
   flight controller had before, and leaving the page releases the yaw input.

Nothing is sent while the model is armed. If the flight controller does not report whether it
is armed, the confirmation says so: make sure the rotors cannot spin before you confirm.

On a motorised or bidirectional tail `*` stays greyed out: a disarmed flight controller drives
the motors only from motor override, never from the mixer.

## Related

- *Configuration* → *Setup* → *Mixer* → *Trims* shows the same centre trim beside the swashplate
  trims.
- [Rotorflight documentation](https://doc.rotorflight.org/)

*Documented against RFSuite 0.2.2.*
