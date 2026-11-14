---
title: Rotorflight model template
sidebar_label: Model template
---

# Rotorflight model template

The installation archive carries an EdgeTX model template, so a new helicopter model does not
have to be built by hand. On the radio, create a new model, open the folder **5.Rotorflight**
and choose **Rotorflight**. EdgeTX then creates the model from the template file and starts a
short dialog that asks for your switches and your CRSF module.

## What the new model brings

Before the dialog asks anything, the model already has:

- **A CRSF module** on the internal slot, with 16 channels. The dialog can move it to the
  external slot.
- **The four stick channels**: CH1 aileron, CH2 elevator, CH3 collective, CH4 rudder.
- **Six function switches** SW1 to SW6, on radios that have them: two-position, off at power-on,
  red while on.
- **Switch warnings** for SA to SF, all expected up at power-on. The throttle warning is off.
- **The radio's telemetry alarms are off.** That silences two EdgeTX warnings: *sensor lost* and
  the low and critical RSSI alarms. RFSuite's own link announcements are off too until you switch
  them on, under *System* → *Settings* → *Audio* → *Events* → *Link*. Until you do, the model
  warns you about nothing on the link. To get the radio's alarms back, untick *Disable telemetry
  alarms* on the model's telemetry page.
- **CH9 Blackbox and CH10 Backup**, held at the bottom of their travel (source `MIN`) until the
  dialog gives them a switch.
- **CH11** follows pot P2. **CH12** follows the trim buttons: each trim direction sends its own
  fixed value while it is pressed.
- **51 telemetry sensors**, so values show up without discovering sensors first. See
  [System Status and System Config in the model template](telemetry-sensors.md#system-status-and-system-config-in-the-model-template).
- **The RFSuite dashboard** on the first screen.

## The dialog

The dialog has two screens. It works by touch or with the keys: the rotary moves between the
rows and buttons, ENTER opens a picker or presses a button, RTN goes back.

**First screen: the switches the model needs.**

| Row | What to pick | Channel it lays out |
| --- | --- | --- |
| Arming switch | a switch with two or three positions; SW1 is preselected where the radio has it | CH5 *Arming* |
| Hold | the one switch position that locks the motor | CH6 *Thr* |
| Governor switch | a three-position switch | CH6 *Thr* |
| Profile switch | a three-position switch | CH7 *Prof* |
| Rescue switch | a switch with two or three positions | CH8 *Rescue* |

**Second screen: the optional channels and the module.**

| Row | What to pick | Effect |
| --- | --- | --- |
| Blackbox switch | a switch with two or three positions, or nothing | CH9 *BlkB* follows it; left empty, it stays at `MIN` |
| Backup pack switch | a switch with two or three positions, or nothing | CH10 *BckU* follows it; left empty, it stays at `MIN` |
| CRSF module | *Internal* or *External* | *External* sets the external slot to CRSF with 16 channels and switches the internal slot off |

*Next* and *Create switch setup* refuse to go on, with a sentence saying why, when:

- a row the model needs is empty,
- a switch has fewer positions than the row needs, or
- **one switch is picked for two functions**. Two pairs may share a switch: the governor and the
  profiles (each position then selects a profile and a governor level together), and the hold
  and the governor, which drive the same channel. Every other pair is refused, because one
  switch on two channels does both things at once, for example arming and switching the backup
  pack on.

The closing screen lists CH5 to CH10 and the module with the outcome of each write. A channel
left empty reads *not used*. It ends with the next step: connect the flight controller and set
it up under *Configuration* → *Setup* in RFSuite. RTN on the second screen goes back to the first; on the first screen and on the closing screen
it leaves the dialog. The model keeps everything from the list above, and the switches can be
set up later.

The dialog needs RFSuite on the card and a radio with LVGL (EdgeTX 2.11 or later). Without
them, the model is still created from the template file and a short notice says so; RTN
closes it, and so does its *Close* button on a radio with LVGL.

## Related

- [Custom telemetry sensors](telemetry-sensors.md) — the sensors the template carries
- [Rotorflight documentation](https://doc.rotorflight.org/) — setting up the receiver, modes
  and adjustments on the flight controller

*Documented against RFSuite 0.2.2.*
