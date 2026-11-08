---
title: SmartFuel
sidebar_label: SmartFuel
sidebar_position: 80
---

# SmartFuel

Speaks the SmartFuel level as it falls, at the steps chosen here, and warns when it reaches 0 %.
0 % is not an empty pack: it is the *Consumption reserve* set under *Configuration* → *Setup* →
*Power* → *Battery*, so the warning comes with that share of the pack still left.

## Where to find it

*System* → *Settings* → *Audio* → *Events* → *SmartFuel*

Always available.

## Settings

| Setting | What it does |
| --- | --- |
| SmartFuel | Speaks the falling level at the steps below, and warns when it reaches 0 %. On by default. |
| Callout % | The steps at which the falling level is spoken, each once: *Only at 10%*, or every 5, 10, 20, 25 or 50 %. Default every 10 %. |
| Finer below | From this level down the steps are finer: the level itself, then every *Finer step* below it, in place of the *Callout %* steps there. *Off*, or 10, 15, 20, 25, 30, 40 or 50 %. Default *Off*. |
| Finer step | The finer step, 1, 2 or 5 %. Used only while *Finer below* is set. Default 5 %. |
| Repeat | How often the warning at 0 % speaks while the level stays there, 10 s apart: *Until cleared*, or 1 to 10 times. Default once. |
| Haptic | Vibrates with the warning at 0 %. Off by default. |
| Raise Volume | *Master volume* mode only: the warning at 0 % is spoken at the *Alert Level*, the steps above it are not. On by default. |

These are radio-wide: one setting for every model. With *SmartFuel* off nothing on this page is
spoken, the rows below it cannot be changed, and *Raise Volume* is not shown.

## Notes

- **0 % is the reserve.** The level spoken here is the one the dashboard shows: the pack's charge
  rescaled so that the *Consumption reserve* reads 0 % and a full pack still reads 100 %. With the
  default reserve of 35 %, the warning comes with 35 % of the pack left, and a spoken "40 %" means
  about 61 % of the pack left. A reserve of 0 makes the level follow the pack one-to-one, and the
  warning then comes at an empty pack. The reserve is kept per model.
- **A warning at a given share of the pack, for example 40 % left:** set the *Consumption reserve*
  to 40. The warning at 0 % then speaks with 40 % of the pack left, and the dashboard reads 0 % at
  the same point. A step does not do the same: it is spoken as a level, without the warning sound,
  *Repeat* or *Haptic*, and it counts in the rescaled level described above.
- The level is computed by the flight controller when SmartFuel is switched on there
  (*Setup* → *Power* → *SmartFuel*, MSP API 12.09 and later), otherwise by the radio from the local
  source set under *Setup* → *Power* → *Preferences*.
- Each step is spoken once, as the level falls past it. A level that rises again (a fresh pack)
  speaks nothing; the steps are passed again as it falls.
- The warning needs one reading above 0 % first: a pack that reads 0 % from the moment it
  connects is not warned about.
- *Only at 10%* speaks the 10 % step alone. *Every 20%* with *Finer below* 30 % and a
  *Finer step* of 5 % speaks 80, 60, 40, 30, 25, 20, 15, 10 and 5 %.
- An electric model hears the battery sounds, a nitro model the fuel sounds; *Model Type* under
  *Setup* → *Power* → *Preferences* decides. The level once after connecting is a separate
  announcement, under *Events* → *On Connect*.
- When the announcements are made, and the files they play, are on
  [Audio Events](../../../../audio/events.md).

## Related

- [Battery](../../../setup/power/battery.md) — the *Consumption reserve*, the point the warning
  speaks at.
- [SmartFuel](../../../setup/power/smartfuel.md) — how the flight controller estimates the level.
- [Rotorflight documentation: SmartFuel](https://doc.rotorflight.org/setup/smartfuel/)

*Documented against RFSuite 0.2.2.*
