---
title: Telemetry
sidebar_label: Telemetry
sidebar_position: 20
---

# Telemetry

Which telemetry protocol the flight controller expects on the ESC telemetry wire, how that
wire is driven, and the correction factors applied to what the speed controller reports.

## Where to find it

*Configuration* → *Setup* → *ESC & Motors* → *Telemetry*

Read-only while the model is armed. Needs MSP API 12.06 or later; an older flight controller
gets a message instead of the settings.

## Settings

| Setting | What it does |
| --- | --- |
| Telemetry Protocol | The protocol the speed controller speaks: *NONE*, *BLHELI32*, *HOBBYWING V4*, *HOBBYWING V5*, *SCORPION*, *KONTRONIK*, *OMP*, *ZTW*, *APD*, *OPENYGE*, *FLYROTOR*, *GRAUPNER*, and *RECORD*, which logs the raw bytes to the blackbox instead of decoding them. *XDFLY* is offered on MSP API 12.08 and later, *FrSky F.BUS* on 12.09 and later, *SRXL2* and *GOOSKY* on 12.10 and later. A Goosky ESC runs AM32 firmware and sends BLHeli32 telemetry, so *GOOSKY* and *BLHELI32* read it the same way. |
| Half Duplex | The telemetry line is shared with the output rather than a separate receive line. Greyed out while the protocol is *NONE*. |
| Pin Swap | Swaps the port's two pins. MSP API 12.07 and later. Greyed out while the protocol is *NONE*. |
| Voltage Correction | Scales the voltage the speed controller reports. -99 to 125 %, default 0. MSP API 12.08 and later. |
| Current Correction | Scales the current the speed controller reports. -99 to 125 %, default 0. MSP API 12.08 and later. |
| Consumption Correction | Scales the consumed capacity the speed controller reports. -99 to 125 %, default 0. MSP API 12.08 and later. |
| Detect wiring | On MSP API 12.10 and later, tries the valid *Half Duplex* and *Pin Swap* combinations for the saved telemetry protocol. It requires a live, disarmed connection. Save protocol changes before starting detection. |

## Notes

- **Which protocols exist depends on the MSP API version the board reports**, and the number
  written for one of them is not a constant. *XDFLY*, *FrSky F.BUS* and *SRXL2* were each
  added to the firmware in front of *RECORD*, so *RECORD* has a different number on each of
  those firmware generations. The page builds the list from the reported API version for that
  reason: the board stores whatever number it is sent, so offering an entry the board does not
  have would select a different protocol than the one named. *GOOSKY* stands behind *RECORD*
  rather than in front of it, so it moves no other number.
- **A flight controller that reports MSP API 12.10 but predates the Goosky protocol has no
  entry at that number.** It stores the value and then reads no ESC telemetry at all. If the
  readings stop after selecting *GOOSKY*, select *BLHELI32* instead.
- *GOOSKY* and *BLHELI32* both light the [AM32](esc_tools/escmfg/am32.md) and *Goosky* tiles
  under *ESC Tools*.
- A protocol the board reports that this build has no name for is shown as an unknown value
  and cannot be selected; that is a flight controller newer than the suite.
- The telemetry wire itself is assigned on *Setup* → *Ports*; this page only says what is
  expected on it.
- Detection polls the flight controller while it works. The fields, Save and Reload remain
  locked until it finishes. **Cancel** restores the wiring that was active before detection.
  A successful result fills *Half Duplex* and *Pin Swap* as unsaved changes; use **Save** to
  store them and perform the normal reboot. If the connection is lost or the result is unknown,
  reload the page before saving. Leaving the page does not cancel a completed detection result;
  an unfinished firmware trial expires and restores its previous wiring automatically.
  A finished detection is reported only on the visit that followed it. Opened again before a
  reboot, the page shows the wiring the flight controller uses at that moment; a detected wiring
  that was not saved is live there but is lost at the next reboot unless Save stores it.
- Saving reboots the flight controller. Once the settings are stored the notice can be closed
  and the page left; the outcome is then shown the next time the page is opened. The page also
  reads again if a different flight controller answers while it is open. Both are described in
  [Saving configuration](../../../reference/saving.md).

## Related

- [Saving configuration](../../../reference/saving.md) — the save that restarts the flight
  controller, and what a different flight controller does to an open page.
- [Rotorflight documentation](https://doc.rotorflight.org/)

*Documented against RFSuite 0.1.7.*
