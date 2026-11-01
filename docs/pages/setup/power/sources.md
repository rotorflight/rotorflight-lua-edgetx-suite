---
title: Sources
sidebar_label: Sources
sidebar_position: 30
---

# Sources

Where the flight controller takes the pack voltage and the pack current from. A pilot opens it
when the battery readings come from somewhere other than the board's own inputs -- the ESC's
telemetry, an FBUS sensor or, on newer firmware, a CRSF sensor.

## Where to find it

*Configuration* → *Setup* → *Power* → *Sources*

Read-only while the model is armed.

## Settings

| Setting | What it does |
| --- | --- |
| Voltage Source | Where the pack voltage is read from: *NONE*, *ADC* (the flight controller's own input), *ESC*, *FBUS*, or *CRSF*. *CRSF* needs MSP API 12.10; on an older flight controller it is not offered. A value this page does not know is shown as *Unknown* with its number and is kept on save. |
| Current Source | Where the pack current is read from, with the same choices and the same rules as *Voltage Source*. |

## Notes

- **CRSF reads an external CRSF sensor wired to a serial port.** Set that port to *CRSF Sensors*
  on the [Ports](../ports.md) page first. The flight controller opens the port only when it
  starts; a Ports save restarts it, a save on this page does not.
- Without readings from the sensor -- no port set to *CRSF Sensors*, nothing connected, or no
  frame for longer than the sensor timeout -- the flight controller reads 0 V and 0 A from it.
- The current always comes from the sensor's battery frame. The voltage comes from that frame or
  from the sum of its cell voltages, as the flight controller's `crsf_sensors_battery_source`
  setting chooses. That setting and the other `crsf_sensors_` settings (timeout, barometer, RPM,
  pin swap) are set in the flight controller's CLI; this suite has no page for them.
- Save writes the battery configuration through the shared save, which reports success only after
  the write and EEPROM commit succeed, or *Not saved* if a write fails. See
  [Saving configuration](../../../reference/saving.md).

## Related

- [Battery](battery.md) -- the capacity, cell count and cell voltages the readings are measured against.
- [Rotorflight documentation](https://doc.rotorflight.org/)

*Documented against RFSuite 0.1.7.*
