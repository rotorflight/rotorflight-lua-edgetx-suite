---
title: Ports
sidebar_label: Ports
sidebar_position: 60
---

# Ports

Sets what each serial port of the flight controller is used for, and at what baud rate. A pilot
opens it to move a receiver, a GPS, an ESC telemetry line or a blackbox logger to another port.

## Where to find it

*Configuration* → *Setup* → *Ports*

Read-only while the model is armed.

## Settings

The page has one row per serial port the flight controller reports, up to twelve. The USB port is
not listed. Where the board layout is known, a row is named as the board prints it, with the UART
name in brackets (`Port A [UART4]` on an F7A1 board); otherwise it carries the UART name alone.

| Setting | What it does |
| --- | --- |
| Function | What the port is used for: *Disabled*, *MSP*, *GPS*, *RX Serial*, *ESC Sensor*, *Blackbox*, *SBus Out*, *FBus Out*, *S.PORT Master*, or one of the telemetry protocols (*FrSky*, *SmartPort*, *iBus*, *HoTT*, *MAVLink*, *LTM*). A function another port already uses is not offered, and only one port can carry telemetry. *SBus Out* needs MSP API 12.07, *FBus Out* and *S.PORT Master* need 12.09; on an older flight controller they are not offered. A function this page does not know is shown as *Custom* with its number. |
| Baud rate | The speed of the port. Which rates are offered depends on the function: *MSP* offers fixed rates from 9600 to 1000000, *GPS* and *MAVLink* offer *AUTO* and rates up to 460800, *Blackbox* offers *AUTO* and rates up to 2470000, a disabled port shows *Disabled*, and every other function is fixed at *AUTO*. A rate already stored that is not in that list is still offered. When a new function does not allow the current rate, the rate moves to the first one it allows. |

The port that carries the receiver is marked *[RX]* and cannot be changed here: both of its
controls are greyed out, and a save keeps that port as it was.

## Notes

- **Save writes every port, stores the configuration and restarts the flight controller.** See
  [Saving configuration](../../reference/saving.md).
- *Reload* reads the ports from the flight controller again and discards unsaved changes.

## Related

- [Rotorflight documentation](https://www.rotorflight.org/docs/)

*Documented against RFSuite 0.1.7.*
