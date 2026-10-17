---
title: Adjustments
sidebar_label: Adjustments
sidebar_position: 20
---

# Adjustments

The flight controller's adjustment ranges: up to 42 slots, each tying a switch or a slider on
the radio to one parameter, so that parameter can be changed from the transmitter. The page
edits one slot at a time and writes every slot that was changed with a single Save.

## Where to find it

*Configuration* → *Setup* → *Controls* → *Adjustments*

Read-only while the model is armed.

## Settings

The line at the top shows how many of the 42 slots have a function (*Active ranges*), whether
there are unsaved changes, and the *Current Output* the selected slot produces from the channels as they
stand now (`-` while its enable channel is outside its range; a `*` marks an output that is live).

| Setting | What it does |
| --- | --- |
| Range | The slot being edited, 1 to 42. A slot that has a function shows its name beside the number. |
| Type | *OFF*: the slot does nothing. *MAPPED*: the value channel's position sets the value directly. *STEPPED*: two windows of the value channel step the value down and up. |
| Enable Channel | The AUX channel that switches the slot on, *Always* for a slot that is always on, or *AUTO*: move the switch you want and the page takes the AUX channel that moved. The live position of the channel is shown beside it: AUX 1 to AUX 3 are the radio channels the flight controller's channel map gives them, AUX 4 and above are radio channels 9 and up. *Set* takes the channel's current position, 50 µs either side, as the enable range, after asking. |
| Enable Range | The window, in µs, inside which the enable channel switches the slot on. 875 to 2125 µs, in steps of 5 µs. |
| Value Channel | *MAPPED* and *STEPPED* only. The AUX channel that carries the value, or *AUTO* as above, with its live position. |
| Step Size | *STEPPED* only. How far one step moves the value, 0 to 255. |
| Adjust Range | *MAPPED* only. The window of the value channel that is spread over the value range. *Set* works as on the enable channel. |
| Decrease Range / Increase Range | *STEPPED* only. The two windows of the value channel that step the value down and up. |
| Function | *MAPPED* and *STEPPED* only. The parameter the slot changes. The list holds the functions the connected flight controller's firmware offers. |
| Value Range | *MAPPED* and *STEPPED* only. The lowest and highest value the slot may set, bounded by what the chosen function allows. |

## Notes

- On a flight controller with MSP API 12.09 or later the page reads the function of every
  slot in one reply and the selected slot's own settings, and reads another slot when it is
  selected. An older firmware is read in one read of the whole table.
- *Cyclic Master Gain* and *Yaw Master Gain* are listed only on firmware carrying
  rotorflight-firmware#538, which added them without changing the MSP API version. On MSP API
  12.10, unless a PID profile has already been read since connecting, the page reads the PID
  profile once to find out. A 12.10 firmware without them would ignore a slot set to either one.
- Save writes each changed slot, then one EEPROM write. While it does, the page is covered by the
  save's progress, and Save or Reload pressed in the header has no effect until the save has finished.
- Reload discards every unsaved change, on every slot: a slot changed before Reload is not
  written by the next Save, and is read from the flight controller again when it is selected.
- The function names are shown in the radio's language.

## Related

- [Rotorflight documentation](https://doc.rotorflight.org/)

*Documented against RFSuite 0.1.7.*
