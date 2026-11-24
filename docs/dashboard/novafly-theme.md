---
title: "@NovaFly theme"
sidebar_label: "@NovaFly theme"
---

# @NovaFly theme

*@NovaFly* is a dashboard theme that draws its own screen from code and takes full screen for
itself. It shows one cockpit in every flight phase, and two pages of its own beside it:
**VORFLUG**, the model and its battery before the flight, and **BÄNKE**, the governor, rates and
gains of the active bank. It is drawn for radios with an 800 x 480 screen, such as the TX16S MK3.

## Where to find it

*System* → *Settings* → *Dashboard* → *Theme*: choose *@NovaFly* for a flight phase, or for all
three. Its one setting, the colour of the cockpit, is under *System* → *Settings* → *Dashboard* →
*Settings* → *@NovaFly*. It is stored for the radio, and a model can carry its own under
[*Per-Model Settings*](../pages/settings/dashboard/overrides.md) where per-model settings are
switched on.

Its fixed words come from a table of the theme's own in English, German, French, Spanish, Italian
and Dutch, and follow the radio's language; any other language shows English. Abbreviations such
as BEC, ESC, MCU, RSSI and the arm state read the same in every language.

## What it shows

![@NovaFly: VORFLUG, the cockpit and BÄNKE, in the simulator of a TX16S MK3](../images/dashboard/themes/novafly.png)

A value the model does not send reads `--` in grey.

### The cockpit

The same screen before, during and after the flight:

- **Head** — at the left the arm state: *ARMED* on green, *DISARMED* on red, *ARM ?* on grey
  while the state is not known, and *NO LINK* in red on grey without a telemetry link. Beside it
  the direction ring (below). In the middle the Rotorflight logo; at the right the receiver's
  signal strength (`1RSS`, in dB) and the link quality (`VFR`, or `RQly` where there is no `VFR`),
  yellow at the warning level and red at the critical level of the link quality announcement.
- **Direction ring** — in full screen a needle in the ring turns with the model, from the flight
  controller's `Yaw` telemetry. The heading it is measured from is taken when the model is armed
  and kept for the flight; on the ground a tap on the ring takes the present heading, with a beep.
  Without `Yaw` the ring stays empty.
- **Left field** — the flight timer, the rate profile (*RATE*) and the PID profile (*BANK*); the
  two profile numbers turn red while they differ.
- **Middle** — the head speed in figures and on a dial with a pointer. The dial runs to 1.25 times
  the highest head speed since the theme was loaded, and to 2 500 rpm at least; it is green to 78 %
  of its length, yellow to 90 % and red beyond. Above the dial the flight controller's MCU
  temperature and its load (*RT*, or *CPU* where the controller sends no `RT%`); under it the
  model name.
- **Right field** — the BEC voltage (yellow below 5.0 V), the radio's own battery (*TX*: yellow
  within 0.4 V of the radio's battery warning level, red below it), the current under *ESC*, and
  four bars for the battery percentage, one per full quarter.
- **Foot** — at the left the altitude, in metres or feet as the suite's altitude unit is set. In
  the middle a battery with five bars, the pack voltage and the battery percentage (without a
  percentage from the model, the share of the voltage range). At the right the ESC temperature; an
  ESC that sends no temperature leaves the field to the voltage per cell, under *CELL*.

The battery figures turn from green through yellow and orange to red as the voltage falls between
the bounds the suite works out for the model; without bounds the range is 4.2 V to 3.5 V per cell,
and red starts below 3.45 V per cell. The MCU and ESC temperatures turn yellow and red at the
warning and critical levels of their announcements (80 and 95 °C, and 90 and 110 °C, unless they
are changed). The load turns yellow from 50 % and red from 80 %.

### VORFLUG

The page before the cockpit:

- **Head band** — at the left the flight mode from the flight controller's flight mode telemetry
  (`Mode` on CRSF, `5121` on S.Port): *ACRO*, *ANGLE*, *HORIZON* or *RESCUE*. In the middle the
  model name. At the right five bars for the link reading and five for the link quality, without
  figures, in the colour of the link quality.
- **Model picture** — the picture the suite shows for the model, with a soft edge; the field
  stays empty for a model without a picture of its own.
- **Battery** — the battery percentage, the pack voltage, the cell count and the capacity of the
  battery, as the suite holds it or read once from the flight controller for each model; under it
  the voltage per cell (*CELL*) and the capacity used (*CONSUMPTION*), in the battery colours of the
  cockpit.
- **Last flight** — four fields along the foot: the highest altitude, the strongest climb, the
  strongest sink and the flight time of the last flight, counted while the model was armed with
  the rotor turning. Before the first flight since the theme was loaded, the first three show the
  highest values since then. Climb and sink are worked out from the altitude over half a
  second at least.

### BÄNKE

The page after the cockpit:

- **Head band** — the governor mode (*OFF*, *LIMIT*, *DIRECT*, *ELECTRIC* or *NITRO*; on a flight
  controller older than MSP API 12.09 *OFF*, *PASSTHROUGH*, *STANDARD*, *MODE1* or *MODE2*), the
  active bank's governor head speed (*HEADSPEED*), the spool-up time (*SPOOL UP*), the governor
  gain (*GAIN*) and the measured head speed (*ACTUAL*).
- **Rates** — four fields with the rates of the active rate profile for roll, pitch, tail and
  collective, shown as the rate type defines them.
- **Gains** — three fields with P, I, D, F, B and O of the active PID profile for roll, pitch and
  tail (no O for the tail).
- **Head speed bar** — the measured head speed against the bank's target: green up to the target,
  yellow up to 108 % of it, red above, on a scale to 125 % of the target, with a mark and the
  figure at the target and a mark at the highest head speed of this bank since the model was
  armed. In a governor mode in which the flight controller holds no head speed, the bar uses the
  scale of the cockpit's dial. Beside it *BANK 1*, *BANK 2* and *BANK 3*, the active one in white.
- **Foot** — the rate profile and its rate type. Where a read did not succeed, *MSP* and the name
  of what could not be read take the place of the rate type, in red.

The values are read from the flight controller through the suite's MSP service when the page
opens, and again after a change of bank or rate profile; a read that fails is tried again three
seconds later. The page only reads: it changes nothing on the flight controller.

## Full screen

With *@NovaFly* selected, full screen shows the theme itself. The theme draws no close button: a
**long press on RTN** leaves full screen. In the cockpit:

- **The arm state** opens the [quick menu](quick-menu.md).
- **A tap on the battery** opens VORFLUG, **a tap on BANK** opens BÄNKE.
- **A long press on the head**, by the logo, changes the colour of the cockpit to the next one, with
  a beep. It does nothing while the model is armed.
- **A tap on the direction ring** takes the present heading, on the ground.
- **The page keys**, where *System* → *Settings* → *Dashboard* →
  [*Keys*](../pages/settings/dashboard/keys.md) leaves them on *Theme*: PAGE < opens VORFLUG and
  PAGE > opens BÄNKE.

On VORFLUG and BÄNKE a tap anywhere, RTN or either page key goes back to the cockpit. BÄNKE also
opens by itself after a flight; opened that way, it closes again when the model is armed.

Outside full screen the cockpit is drawn without anything that takes a press, and the direction
ring without its needle.

## Settings

| Setting | What it does |
| --- | --- |
| Colour | The colour of the lines of the cockpit and of its two pages: *Blue* (default), *Turquoise*, *Green*, *Yellow*, *Gold*, *Orange*, *Red*, *Magenta*, *Violet* or *Silver*. A long press on the head of the cockpit moves to the next one. |

## What it reads

The cockpit names the pack voltage, the current, the battery percentage, the head speed, the BEC
voltage, the ESC and MCU temperatures, the PID and rate profiles, `1RSS`, `VFR`, `RQly`, `RT%`,
`CPU%`, the altitude, the capacity used and `Yaw`, and reads the radio's own battery voltage.
VORFLUG adds the link reading and the flight mode telemetry, and reads `BATTERY_CONFIG` from the
flight controller where the suite holds no battery. BÄNKE reads `PID_TUNING`, `RC_TUNING`,
`GOVERNOR_CONFIG` and `GOVERNOR_PROFILE` from the flight controller.

## What it does not do

- **No statistics screen after the flight**: the cockpit stays, and BÄNKE opens.
- **BÄNKE does not change the flight controller**: it shows the bank, it does not set it.
- **No pages beyond the colour**: the theme declares no boxes, so the shared *Before flight*,
  *In flight*, *Statistics*, *Info bar* and *Keys* pages are not offered for it.
- **Its words do not come from the suite's translations**, so a language outside its own six shows
  English.
- **Its pictures are drawn for 800 x 480.**

## Related

- [Dashboard themes](themes.md) — all shipped themes, and choosing one.
- [Quick menu](quick-menu.md) — what the arm state opens in full screen.
- [Dashboard themes for developers](../developer/dashboard-themes.md) — the manifest keys,
  `fullscreen` and `views`, which this theme uses.

*Documented against RFSuite 0.3.1.*
