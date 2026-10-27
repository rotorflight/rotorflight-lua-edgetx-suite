---
title: Flyrotor Configurator
sidebar_label: Flyrotor
sidebar_position: 40
---

# Flyrotor Configurator

Reads the parameter block out of a Flyrotor ESC and writes it back, so the ESC can be set up
from the radio instead of from a computer. A pilot opens it to check or change the cell
count, the protections, the startup behaviour and the ESC's own governor without unplugging
anything.

## Where to find it

*Configuration* → *Setup* → *ESC & Motors* → *ESC Tools* → *Flyrotor*

Lit only while the flight controller reports this ESC telemetry protocol. Read-only while
the model is armed.

## Settings

Option names are shown in the radio's language; maker abbreviations such as CW/CCW and BEC remain in English as in the maker's software.

The page opens on a safety notice, and behind it on a summary of the ESC's model, firmware
and version. *Section* switches between three groups of settings; every setting of the
chosen group is always shown. Each setting has its own `?`; the header `?` describes the page.

| Setting | What it does |
| --- | --- |
| Section | *Basic*, *Advanced* or *Governor*. Switching it rebuilds the list below; nothing is read from the ESC again. |

### Basic

| Setting | What it does |
| --- | --- |
| Cell Count | The cell count of the flight pack as the ESC assumes it, 4 to 14. |
| Low Voltage Protection | The cell voltage the low-voltage protection acts at, 2.8V to 3.8V in 0.1 V steps. |
| Temperature Protection | The ESC temperature the protection acts at, 50 C to 135 C in five-degree steps. |
| BEC Voltage | The output voltage of the ESC's BEC: *Disabled*, *7.5V*, *8.0V*, *8.5V* or *12.0V*. |
| Electrical Angle | *Auto*, or a fixed 1 deg to 10 deg in one-degree steps. *Auto* adjusts the angle to the motor's speed and the ESC's temperature and is the recommended setting; a fixed angle can give a smoother run or suit a non-standard motor. If the motor runs hot, raise it. |
| Motor Direction | Which way the motor turns: *CW* or *CCW*. |
| Starting Torque | 1 to 15. Lower it if the tail kicks as the motor spools up. |
| Response Speed | How directly the ESC follows the throttle, 1 to 15. |
| Buzzer Volume | How loud the ESC beeps, 1 to 5. |
| Current Gain | A correction applied to the ESC's current reading, -20 to 20 in steps of 1. |
| Fan Control | *Automatic* runs the cooling fan by temperature; *Always On* or *Always Off*. |

### Advanced

| Setting | What it does |
| --- | --- |
| Auto Restart Time | How long after a throttle cut the ESC still restarts the motor quickly (bailout), 0 s to 100 s in one-second steps. |
| Restart Acc | How fast the motor spools back up on such a restart, 1 to 10. |

### Governor

| Setting | What it does |
| --- | --- |
| ESC Mode | Which governor runs the head speed: *ESC Gov*, *Linear Throttle* or *RF Gov*. *RF Gov* is the choice when Rotorflight's governor holds the head speed; *ESC Gov* uses the ESC's own governor. |
| Soft Start | The time the ESC takes to spool the motor up, 5 s to 55 s in one-second steps. |
| Governor P | The ESC governor's P gain, 0 to 100. It acts only with *ESC Mode* on *ESC Gov*. |
| Governor I | The ESC governor's I gain, 0 to 100. It acts only with *ESC Mode* on *ESC Gov*. |

## Notes

- The page opens behind a safety notice asking for the main and tail blades to be removed
  before the ESC is configured. Nothing else is drawn until the notice is dismissed.
- Saving writes the whole parameter block to the ESC, not only the settings that were
  changed. A setting the page does not offer is written back as it was read, so a Save with
  nothing edited changes nothing in the ESC.
- After a save the page reads the ESC again on its own, and a further save is not
  accepted until that read has come back.
- The ESC is read when the page opens, and again on *Reload*, which also drops any unsaved
  edit. Switching *Section* does not read it again.
- An unsaved edit is marked below the list, and is lost if the page is left without saving.
- If the ESC does not answer the write, the page says so and the edits stay marked as
  unsaved.
- A reply that is not a Flyrotor parameter block -- shorter than the 56-byte block, or
  carrying another ESC family's signature -- is refused. The values on screen stay as they were
  (on a fresh visit, the page's own initial ones), Save is refused until a read succeeds, and the refusal is listed as a warning on the
  *Session Logs* page.

## Related

- [Rotorflight documentation](https://doc.rotorflight.org/) -- what each of these
  settings does inside the ESC, and how the ESC's own governor relates to the flight
  controller's.
- [Flyrotor Governor setup](https://doc.rotorflight.org/setup/governor-setup/#flyrotor)
  -- Rotorflight's own page on this ESC: wiring, the electrical angle, the starting torque and
  which ESC mode goes with which governor.

*Documented against RFSuite 0.1.7.*
