---
title: Telemetry
sidebar_label: Telemetry
sidebar_position: 30
---

# Telemetry

Configuration of flight controller telemetry sensors. The flight controller can stream real-time flight data to the transmitter over CRSF (Crossfire / ELRS) or FrSky SmartPort.

## Where to find it

*Configuration* → *Setup* → *Telemetry*

Read-only while the model is armed.

## Mode Awareness

With a CRSF receiver, the header of the page indicates the active telemetry mode configured on the flight controller:

- **CRSF Telemetry: Native**: The flight controller sends standard CRSF frames for the native sensors whose IDs occupy telemetry slots (e.g. Attitude, Flight Mode, Altitude). These sensors are locked on in the page because removing them from the slots would stop the flight controller from sending them. Additional custom sensors require Custom mode. Unmanaged sensor slots on the flight controller are preserved in place, and conflicting individual sub-axes (e.g. pitch/roll/yaw attitude) are disabled when their parent is native-locked.
- **CRSF Telemetry: Custom**: The flight controller transmits individual custom telemetry sensors selected from the catalog.

## Sensor Groups

The page opens on a list of sensor groups -- Battery, Voltage, Current, Temperatures, ESC 1,
ESC 2, RPM, Barometer, Gyro, GPS, Status, Profiles, Control, System and Debug. Each row shows how
many of the group's sensors are switched on, of all the group offers (for example `5 / 7`).
The chevron opens the group, which shows a switch for each of its sensors and nothing else; Back
returns to the list, and Back on the list leaves the page.
Sensor names are translated like the rest of the page.

Switches changed in one group are kept while another group is opened, and Save writes all of
them at once from either level. Leaving the page without saving discards them.

The mode header and the native-mode note are shown on the list only, with a CRSF receiver. With any other receiver, no CRSF header or warning is shown and the native sensors are ordinary switches.

## System Status and System Config

The Status group lists **System Status** and **System Config** when the flight controller runs
firmware with MSP API 12.10 or newer; on older firmware they are not shown and the Star button
does not select them. They pack the arm state, governor and rescue state, failsafe phase, profile
numbers and other flight controller status into two sensors (`STAT` and `SCFG` on CRSF).

When the individual Arming Flags, Governor State, Rescue State or profile sensors are not selected, the suite
reads those values from the two packed sensors instead, so the dashboard and announcements keep
working with just these two.

## Sensor Slots & Limits

The flight controller provides up to 40 telemetry sensor slots (`telemetry_sensors[40]`).
Any sensor slot holding an ID outside the custom catalog (such as native CRSF sensors or aggregate sensors) is preserved in place upon saving. Saving writes selected catalog sensors to available slots while ensuring the total number of enabled sensors does not exceed the 40-slot hardware limit.

Both levels show a line `Sensors: n / 40`: the number of slots a save would fill. It counts
every switched-on sensor, the native sensors that are locked on in native mode, and the
preserved slots the page does not list. It updates as a switch is changed. Above 40 it is drawn
in the warning colour and says that more than 40 cannot be saved; Save then refuses with the
same message as before. The line and the save check use the same count.

## Actions

- **Save**: Writes the enabled telemetry sensors to the flight controller and saves to EEPROM.
  Success is reported only after the telemetry write and EEPROM commit succeed; a failed save reports an error and keeps the selection unsaved. A save that worked restarts the flight controller, because it sets up its telemetry sensors and the CRSF telemetry mode only at start-up.
  Save keeps every selected sensor in its existing slot. A switched-off sensor frees its slot without moving the others, and newly switched-on sensors fill the lowest free slots in catalogue order, which can be a slot freed in the same save.
- **Reload**: Re-reads the current telemetry configuration from the flight controller.
- **Star (*)**: Loads default custom telemetry sensors into the selection.

## Related

- [Custom telemetry sensors](../../reference/telemetry-sensors.md) — how the values selected here
  become sensors on the radio, and why an unrecognised sensor costs more than itself.
