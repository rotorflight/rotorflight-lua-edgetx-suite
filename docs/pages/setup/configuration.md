---
title: Configuration
sidebar_label: Configuration
sidebar_position: 10
---

# Configuration

Set the craft name, control-loop frequency and flight-controller features.
The PID loop and feature switches have inline help; the header help explains the name limit
and saving.

## Where to find it

*Configuration* → *Setup* → *Configuration*

Read-only while the model is armed.

## Settings

| Setting | What it does |
| --- | --- |
| Craft name | The helicopter's name for the OSD, Blackbox logs and diff/dump output, with at most 16 characters. |
| PID loop speed | How often the control loop runs. Choices divide the gyro rate by 1, 2, 3 or 4 and are labelled from the gyro rate the board reports, with two decimals in kHz (for example, 3.21 kHz for a 312 us gyro period divided by 1). A stored divisor outside this list is also shown. Rotorflight recommends 1 to 2 kHz; higher rates increase CPU load with little or no benefit, and realtime load should stay at or below 70%. |
| GPS | Enables GPS telemetry support; assign a GPS port under Ports first. GPS is not used for flight control. |
| LED_STRIP | Enables support for WS2811/2812 RGB LED strips. |
| CMS | Enables the firmware's Configuration Menu System. |

## Notes

Save writes these settings to EEPROM and restarts the flight controller, so the link drops
briefly. Save waits for the page's complete configuration read to succeed; use Reload if
the read fails. See [Saving configuration](../../reference/saving.md).

The page reads the gyro period as part of its normal status read and rebuilds the choices
after the configuration read completes.

## Related

- [Rotorflight documentation: Configuration tab](https://doc.rotorflight.org/configurator/tabs/configuration/)

*Documented against RFSuite 0.2.1.*
