---
title: Dashboard themes
sidebar_label: Themes
---

# Dashboard themes

A theme decides what the *RFSuite* dashboard widget draws. The suite ships ten of them, and
every theme draws three screens: one before the flight, one in flight and one after it. This page
shows each shipped theme on them, and says how to choose one.

## Choosing a theme

*System* → *Settings* → *Dashboard* → *Theme*. The theme chosen there is the one every model
shows. A different theme for the inflight or the postflight screen alone, and a theme of a
model's own, are switched on on the same page; [Theme](../pages/settings/dashboard/theme.md)
describes every row of it. A model's own theme and its model-specific settings stay on the
post-flight screen after the battery is unplugged, until the next flight controller connects.
The retained settings also apply when the model customizes the radio's selected theme.

A theme's own settings, such as the voltage range its gauges span, are under
*System* → *Settings* → *Dashboard* → *Settings*, one tile per theme
([Settings](../pages/settings/dashboard/settings.md)).

## What every theme has in common

- **The screen follows the flight, not a switch.** The widget shows the preflight screen until
  the model is armed and flying — the governor active or the throttle above its threshold — then
  the inflight screen, and after disarming the postflight screen with the numbers of the flight that
  just ended. A model armed on the bench that never spools up goes back to the preflight screen
  and shows no postflight screen, because there was no flight. The exact rules are in
  [developer/dashboard-themes.md](../developer/dashboard-themes.md#what-puts-the-widget-into-each-phase).
- **Before the first screen, a connecting screen.** Until the flight controller answers, battery
  and link telemetry have arrived and the suite has finished its connection tasks, every theme shows
  *Connecting FBL...* with a line saying what it is still waiting for, in place of its preflight
  screen.

When local SmartFuel cannot determine the cell count because the maximum cell voltage is
missing or invalid, current fuel and estimated consumption become unavailable. The dashboard
stops using the previous estimate or falling back to an older sensor reading. Valid historical
flight statistics are retained. See [SmartFuel](../pages/setup/power/smartfuel.md) for recovery
and the distinction between local and flight-controller estimates.

### Automatic voltage bounds

Unless the theme has saved voltage bounds, the dashboard scales its voltage range to the
battery cell count and the flight controller's minimum and maximum cell voltages. A cell
count from telemetry takes priority, followed by the configured cell count. If neither is
available, the dashboard estimates the count from the pack voltage and maximum cell voltage,
including when the controller supplies its cell limits in centivolts. Saved voltage bounds
keep their configured range.

## The shipped themes

The pictures were taken on a TX16S MK3 (800x480) during a short simulated flight of a 6S
electric helicopter, left to right before, during and after the flight; for the two nitro themes,
during and after it. Some values in them come
from the simulation rather than from a model in the air: the head speed reads 0 throughout, and
*Total time* is the flight controller's own lifetime counter, which is why it differs between the
pictures.

### Default

The theme a new installation starts with. Before the flight: the model picture and name, the
flight timer, the blackbox state, the PID and rate profile, the flight count, the link quality
and a voltage gauge. In flight it is reduced to the flight time, the link quality and the voltage
gauge; after the flight it shows the last flight's time, the total time, the lowest voltage per
cell and the lowest link quality.

Default's settings now open a grid of six pages: **Look**, **Before flight**, **In flight**,
**Statistics**, **Info bar** and **Keys**. Look holds the existing voltage range and link colours. Each
flight-phase page offers one dropdown per plain value tile, labelled with that tile's own
caption: choose a live reading before or during flight, or a figure from the last flight on
Statistics. Each choice starts on the theme's own value; choosing another changes the caption,
unit and decimals with it, while a tile without a caption keeps none. Gauges, timers, governor,
blackbox, flight count and the model image keep what the theme draws.

Keys assigns PAGE >, PAGE <, MDL, SYS and TELE to nothing, the quick menu, the suite tool,
Flight Log or leaving full screen. A key held by *Settings* → *Dashboard* → *Keys* is greyed
out and marked *(global)*; set it to **Theme** on that radio-wide page to use the theme's
binding. These choices are standard settings for the theme, and a model can override each
one through [Per-Model Settings](../pages/settings/dashboard/overrides.md).

Info bar chooses what the bar across the top of the full screen shows: the end its buttons sit
at, and what each of six positions shows. As it comes, the buttons are at the left and the bar
shows the radio battery symbol at the far right, the clock beside it and the link bars.

In fullscreen, Default shows the dashboard at the full screen size with the same layouts,
below an info bar that takes the place of the radio's own top bar, drawn in the colour of the
tiles. The bar's buttons open the suite tool (while disarmed), open the quick menu, and leave
fullscreen with **X**; at the left they sit mirrored, **X** in the corner. The other end
carries what the Info bar page chooses, from the far end inwards: the clock, the radio battery
as a symbol, a percentage or a voltage (in the warning colour below the radio's battery warning
level), and the link quality as four steps or as a percentage (on a receiver that reports only
a signal strength, the strength in dB). What does not fit before the buttons is left out. The
quick menu keeps its own **X** at the top right. A long press on the return key also leaves
fullscreen.
With the global [Keys](../pages/settings/dashboard/keys.md) choices as they come, SYS opens
the suite tool, and TELE and the page keys open the quick menu, also before the FC connects;
Default binds no key itself, so MDL, and any key put on **Theme**, does nothing while the
dashboard itself is showing.
That describes the initial settings; Default's **Keys** page can now bind those keys, and a
saved binding acts on the dashboard when the radio-wide page leaves that key on **Theme**.
With a view open, PAGE as it comes, or on **Theme**, closes the quick menu or opens it over
another view; PAGE set there to another action does that action, and on **Nothing** nothing. Closing the menu returns to the
dashboard.

![Default before, during and after the flight](../images/dashboard/themes/default.png)

### RF Status

Telemetry first. Before the flight: the model picture, the pack voltage, the battery percentage,
the link quality, the timer, the governor state, the current and the head speed. In flight: a
voltage gauge and a battery gauge above the governor state, the link quality, the head speed and
the timer. After the flight: the lowest and highest voltage and current, and the highest
temperature of the flight controller and of the ESC.

Like Default, RF Status takes the full screen with the same layouts and the same controls, and
its settings open the same six pages: **Look** (its voltage range), **Before flight**, **In
flight**, **Statistics**, **Info bar** and **Keys**, as described for [Default](#default).

![RF Status before, during and after the flight](../images/dashboard/themes/rfstatus.png)

### @AERC

Built around a battery bar that carries the percentage, the pack voltage, the voltage per cell,
the cell count and the capacity used. Before the flight: the model picture, the battery bar, the
BEC voltage and the ESC temperature as gauges, the rate and PID profile, the flight count, the
blackbox state and the governor state. In flight: the flight time, the battery bar, and the
throttle, the head speed and the ESC temperature as gauges, the last with its highest value of
the flight. After the flight, twelve numbers: flight time, highest power, capacity used, total
time, highest current, fuel left, flight count, highest ESC temperature, voltage, highest head
speed, highest altitude and lowest link quality.

Like Default, @AERC takes the full screen with the same layouts and the same controls, and
its settings open the same six pages: **Look** (its head speed, BEC and ESC temperature ranges), **Before flight**, **In
flight**, **Statistics**, **Info bar** and **Keys**, as described for [Default](#default).

![@AERC before, during and after the flight](../images/dashboard/themes/aerc.png)

### @AERC Nitro

The @AERC layout for a nitro helicopter: it shows the BEC voltage where @AERC shows the flight
pack. Before the flight: the throttle, the head
speed, the blackbox state, the governor state, the model picture, the rate and PID profile, the
flight count and a vertical BEC voltage bar. In flight: the head speed and the throttle as
gauges either side of the flight time and the voltage bar. After the flight: flight time, lowest
and highest head speed, voltage and lowest voltage, total time, flight count, highest throttle
and highest altitude.

Like Default, @AERC Nitro takes the full screen with the same layouts and the same controls, and
its settings open the same six pages: **Look** (its head speed, BEC and ESC temperature ranges), **Before flight**, **In
flight**, **Statistics**, **Info bar** and **Keys**, as described for [Default](#default).

![@AERC Nitro during and after the flight](../images/dashboard/themes/aerc-n.png)

### @RT-RC

Large arc gauges. Before the flight: the model picture, the governor state, the head speed, the
battery percentage and the pack voltage as gauges, the PID and rate profile, the flight count,
the link quality, the flight time and the blackbox state. In flight: the voltage and battery
gauges above a row with the governor state, the link quality, the head speed and the flight
time. After the flight, twelve numbers: flight time, highest throttle, capacity used, total time,
highest current, fuel left, highest head speed, highest ESC temperature, lowest voltage per cell,
highest power, link quality and voltage.

Like Default, @RT-RC takes the full screen with the same layouts and the same controls, and
its settings open the same six pages: **Look** (its voltage range), **Before flight**, **In
flight**, **Statistics**, **Info bar** and **Keys**, as described for [Default](#default).

![@RT-RC before, during and after the flight](../images/dashboard/themes/rt-rc.png)

### @RT-RC Nitro

The @RT-RC layout for a nitro helicopter, on the BEC voltage instead of a flight pack. Before the
flight: the model picture, the governor state, the head speed, the PID and rate profile, the
flight count, the link quality, the flight time, the throttle and the BEC voltage as gauges, and
the blackbox state. In flight: the BEC voltage and the throttle as gauges above the governor
state, the link quality, the head speed and the flight time. After the flight: flight time,
lowest and highest link quality, voltage, total time, lowest voltage per cell, lowest and highest
head speed and highest throttle.

Like Default, @RT-RC Nitro takes the full screen with the same layouts and the same controls, and
its settings open the same six pages: **Look** (its voltage range), **Before flight**, **In
flight**, **Statistics**, **Info bar** and **Keys**, as described for [Default](#default).

![@RT-RC Nitro during and after the flight](../images/dashboard/themes/rt-rc-n.png)

### @SRB-RC

A grid of large numbers over a full-width battery bar. Before the flight: the craft name, the
BEC voltage, the link quality, the head speed, the PID and rate profile, the ESC temperature, the
current and the timer. In flight the craft name gives way to the governor state, with the rest
in the same places. After the flight: flight time, highest current, capacity used, fuel left,
highest ESC temperature, voltage at the end of the flight, flight count, lowest link quality and
voltage per cell at the end of the flight (V/CELL).

Like Default, @SRB-RC takes the full screen with the same layouts and the same controls, and
its settings open the same six pages: **Look** (its BEC and ESC temperature warnings), **Before flight**, **In
flight**, **Statistics**, **Info bar** and **Keys**, as described for [Default](#default).

![@SRB-RC before, during and after the flight](../images/dashboard/themes/srb-rc.png)

### Urban

A theme drawn from code rather than from a grid of boxes, which takes the whole screen in
fullscreen mode. It has a page of its own: [Urban theme](urban-theme.md).

![Urban before, during and after the flight](../images/dashboard/themes/urban.png)

### Grid

Built on Urban and drawn from code in the same way, taking the whole screen in fullscreen mode:
Urban's top bar over a battery panel down the left — the battery percentage, the cell voltage,
the capacity used and a fill bar — beside a grid of value tiles, and a status bar at the foot
with the model name, the arm state, the transmitter power and the skipped telemetry frames, or
the reasons arming is blocked. The screen keeps its shape in flight; after the flight it shows
Urban's statistics screen in Grid's colours. It has a page of its own:
[Grid theme](grid-theme.md).

![Grid before, during and after the flight](../images/dashboard/themes/grid.png)

### Deck

Built on Urban and drawn from code in the same way, taking the whole screen in fullscreen mode:
under a header with the model name, the link bars, the clock and the radio battery, a column of
three cards on the left — by default the model picture with the flight count, total time and
battery profile, the arm state, and the governor — a big card with the head speed, the least and
the most of the flight under it and its highest value and the throttle beside it, a row of four
value cards with the least and the most of the flight under each figure, and a battery strip
across the foot. The screen keeps its shape in flight; after the flight it shows Urban's
statistics screen under Deck's header. It has a page of its own: [Deck theme](deck-theme.md).

![Deck before, during and after the flight](../images/dashboard/themes/deck.png)

## Related

- [Theme](../pages/settings/dashboard/theme.md) — choosing the theme, per flight phase and per
  model.
- [User themes](user-themes.md) — copying a shipped theme and changing what it shows.
- [developer/dashboard-themes.md](../developer/dashboard-themes.md) — how a theme is built.

*Documented against RFSuite 0.2.0.*
