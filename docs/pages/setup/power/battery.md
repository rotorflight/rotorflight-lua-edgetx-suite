---
title: Battery
sidebar_label: Battery
sidebar_position: 10
---

# Battery

The pack the flight controller is flying: which of its six battery profiles is selected, the
capacity stored in each of them, the cell count, the four per-cell voltage levels the alarms
are built on, and how much of the pack is held back as a reserve.

## Where to find it

*Configuration* → *Setup* → *Power* → *Battery*

Read-only while the model is armed.

## Settings

| Setting | What it does |
| --- | --- |
| Selected Battery | Which of the flight controller's six battery profiles is active. Switching it here switches it on the board. |
| Battery 1 … Battery 6 | The capacity stored in each profile, 0 to 40000 mAh. All six are written on every save, so a capacity can be edited without selecting its profile. |
| Edit Battery | Shown only on firmware that keeps the cell count and cell voltages per battery profile: which profile the five rows below show and edit. It opens on the active profile and is never sent to the flight controller, so editing another profile does not make it active. |
| Max cell voltage | The top of a cell's voltage range. The flight controller uses it to work out the cell count when Cell count is 0, and to scale the charge level when no capacity is set. 1.00 to 5.00 V, default 4.30. |
| Full cell voltage | The nominal voltage of a fully charged cell, which is what a full pack is measured against. 1.00 to 5.00 V, default 4.10. |
| Warn cell voltage | The per-cell voltage at which the low-voltage alarm starts. 1.00 to 5.00 V, default 3.50. |
| Min cell voltage | The minimum per-cell voltage, below which the low-voltage alarm is triggered. 1.00 to 5.00 V, default 3.30. |
| Cell count | Cells in the pack, 0 to 24. 0 lets the flight controller work it out from the pack voltage. |
| Consumption reserve | How much of the capacity is held back, so that the fuel reading reaches zero with that much of the pack left. The SmartFuel warning at 0 % speaks at that point. 0 to 60 %, default 35; 0 means no reserve. |

On firmware that keeps the cell count and the four cell voltages per battery profile, those five
rows show and edit the profile chosen in *Edit Battery*, and every profile is written on save; a
profile that is not edited keeps exactly what the board holds. *Selected Battery* alone decides which
profile is active. On older firmware *Edit Battery* is not shown and the five rows are one set of
values for every profile.

## Notes

- **The selected profile is sent only when it is changed here.** The page has no way to ask
  the flight controller which battery profile is active: `MSP_BATTERY_CONFIG` carries no
  profile field, and the `BatP` telemetry sensor that would answer is part of the custom CRSF
  sensor set, so it does not exist on a native CRSF link. Where there is no answer the combo
  shows the first profile, because it has to show something — and a save made in that state
  leaves the board's profile alone rather than switching it to the one on screen. Selecting a
  profile on this page always sends it.
- Saving writes the whole battery configuration to the flight controller and commits it to the
  board's own storage; the shared save reports success only after the writes and EEPROM commit
  succeed, or reports *Not saved* if a write fails. A cell voltage that was not edited goes back
  exactly as the flight controller reported it. The page still saves this model's preferences on
  the radio before starting the flight-controller save, even if that save is refused or fails;
  a failure to save the model preferences is reported with its reason, separately from the
  flight-controller outcome.
- **When the flight controller uses a saved value.** Capacity, maximum cell voltage and the
  profile apply at once. The cell count and the warning and minimum cell voltage are taken when
  the flight controller detects a pack, so with a pack connected they apply at the next plug-in
  or restart. On firmware with SmartFuel the page also reads the SmartFuel configuration after it
  has loaded and sends it back unchanged with the save, so the flight controller's SmartFuel
  estimate uses the new minimum and full cell voltage at once, as a save from Rotorflight
  Configurator does. If that read was not answered, the save goes ahead without it and the
  estimate picks up the new voltages at the next restart.
- **Per profile, each cell voltage stays between its neighbours.** On firmware with per-profile
  cells the flight controller keeps every profile ordered — Min below Max, and Min ≤ Warn ≤ Full ≤
  Max — and changes a profile that is out of that order itself when it stores it. So a voltage
  here stops at the next one: to raise all four, raise Max first; to lower them, lower Min first.
- **Which profile's cells the alarms use.** The flight controller runs the cell count and the
  cell voltages of its active profile. A profile change made while the model is armed is applied
  when it is disarmed, and the suite's own voltage callouts and its own SmartFuel estimate
  follow the `BatP` sensor, which reports the profile the board is running.
- The Consumption reserve is also kept in this model's preferences on the radio, and is written
  to the flight controller only when it is edited here. The SmartFuel level the dashboard shows and
  the announcements speak reads 0 % at the reserve and 100 % on a full pack, and the SmartFuel
  warning speaks at 0 %. So a warning with an estimated 40 % of the pack left is a reserve of 40; the
  announcements are set under [Audio → Events → SmartFuel](../../settings/audio/events/fuel.md),
  the estimate itself on the [SmartFuel](smartfuel.md) page.

## Related

- [Audio → Events → SmartFuel](../../settings/audio/events/fuel.md) — the callouts of the level and
  the warning at 0 %
- [Rotorflight documentation](https://doc.rotorflight.org/) — the battery profiles and the
  voltage levels themselves are the flight controller's

*Documented against RFSuite 0.1.7.*
