---
title: Grid theme
sidebar_label: Grid theme
---

# Grid theme

*Grid* is a dashboard theme that draws its own screen from code and takes full screen for
itself, like [Urban](urban-theme.md), and it is built on Urban: the top bar, the keys, the
readings it can show, the pages it opens in full screen and the statistics screen are Urban's,
in Grid's own colours. What is Grid's own is the flight screen: a battery panel down the left and
a grid of value tiles beside it, both laid out as the pilot chooses.

## Where to find it

*System* → *Settings* → *Dashboard* → *Theme*: choose *Grid* for a flight phase, or for all
three. Its settings are under *System* → *Settings* → *Dashboard* → *Settings* → *Grid*, split
into six pages: *Look*, *Layout*, *Tiles*, *Top Bar*, *Keys* and *Telemetry*. They are stored for
the radio, and a model can carry its own under
[*Per-Model Settings*](../pages/settings/dashboard/overrides.md) where per-model settings are
switched on. Its tile carries an icon of its own, a small picture of its flight screen. Its words
come from the suite's translations, so it speaks the language of the package that was installed.

## What it shows

![Grid before, during and after the flight, on a TX16S MK3](../images/dashboard/themes/grid.png)

**On the ground and in flight** one screen, which does not change shape at spool-up:

- **Top bar** — Urban's: in full screen the menu and the tool buttons at the left, then the
  clock; up to four stacked link bars in the middle; the radio's battery at the right. What each
  part shows is described on the [Urban page](urban-theme.md#what-it-shows).
- **Battery panel** — down the left, as chosen on the *Layout* page:
  - *Battery card* (default): the word *Battery* with the cell count and the capacity used at
    the top, the fuel percentage large in the middle, the cell voltage under it and a fill bar at
    the foot.
  - *Battery gauge*: Urban's vertical gauge, with the cell count, the fuel percentage and the
    capacity used over its segments.
  - *Off*: no panel; the tiles take the whole width.

  Until the model has reported a fuel reading the percentage reads `--%` rather than an empty
  pack. The fill is red at the red step and below, yellow at the yellow step and below, and
  green above that -- or orange instead of green when the pack was not full when it was plugged
  in, by the same verdict Urban's gauge uses. The two steps are set on the *Look* page. The cell
  voltage reads `-` until the cell count is known, and turns red below the minimum pack voltage
  the widget works out for the model, as Urban's cell voltage row does.
  With the main pack lost the percentage reads `--%` in red and the bar empties.
- **Tile grid** — beside the panel: 2 x 2, 3 x 2 (default), 4 x 2, 2 x 3 or 3 x 3 cells, filled in
  order from six slots chosen on the *Tiles* page. Each tile shows the reading's name, its unit at
  the right where *Units beside the values* is on, and the figure along the foot. A slot set to
  nothing moves the next one up, and a slot past the last cell is not drawn. Every figure shares
  one size, picked against the widest figure on the grid; a reading in words (the governor
  state, ESC status, air rate) takes the largest size up to that one in which it fits.
- **Extra tile** — in the first cell the slots leave free: the model picture (default), or the
  PID, rate and battery profile numbers side by side, or nothing. While the suite is waiting for
  a battery pick on this connection the battery profile's word is drawn in the warning colour.
- **Status bar** — at the foot, unless it is switched off on the *Layout* page: the model name,
  the arm state in the middle, the transmitter power and the skipped-frame count. The middle says
  *MAIN POWER LOST* in red while the main pack is lost and the flight controller still answers,
  and the speed controller's live verdict in its level's colour while the controller reports a
  warning or a fault; otherwise the arm state. While the flight controller names reasons that
  block arming, the whole bar shows them one at a time instead.

**After a flight** Urban's statistics screen in Grid's colours: the model with its totals, a
table of the last flight with the latest reading, the minimum and the maximum of each row, the
flight time and the capacity used beneath it, and -- where the status bar is shown -- a bar with
the transmitter power, the lowest link quality, the highest MCU temperature and the skipped
frames. The [Urban page](urban-theme.md#what-it-shows) lists the rows and says how the cell
voltage row counts the cells of the pack that flew and how long the transmitter power and the
skipped frames follow the link; both hold for Grid's screen too.

## Full screen

With *Grid* selected, full screen shows the theme itself rather than the quick menu. The theme
draws no close button: a **long press on RTN** leaves full screen. What opens where:

- **The menu button** opens the [quick menu](quick-menu.md); so do TELE and the page keys by
  default.
- **The tool button** opens the suite's tool, only while the model is disarmed; so does SYS, as it
  comes.
- **The link bars** open the *ELRS* link page.
- **A value tile** opens *Telemetry*: up to twelve readings as tiles, chosen on the *Telemetry*
  page, each with the least and the most the flight reached.
- **The battery panel**, card or gauge, opens the *Battery* page.
- **The extra tile**, picture or profile numbers, opens *Profile & Tuning*: the in-flight tuning
  surface and, while the model is disarmed, the battery profiles, each with its cell count
  and warning voltage under its capacity where the flight controller reports them.
- **The status bar** opens *Status*: the arm state with what stands in its way, the governor, the
  throttle, the speed controller's live verdict and the event log.

These pages, the quick menu, the battery picker and the battery profile page are the ones
Urban draws, in Grid's colours;
the [Urban page](urban-theme.md#full-screen) describes each of them, the *Link view switch* that
opens the *ELRS* page on a switch, and what the keys do. Every place that takes a press has the
radio's frame around it while *Frames on tap areas* is on. A bar is only redrawn when its reading
changes.

## Settings

| Page | Setting | What it does |
| --- | --- | --- |
| Look | Colour scheme | *Light* (default) or *Dark*. |
| Look | Arm state colours | *Amber and grey* (default): armed amber, disarmed in the label colour. *Green and red*: armed green, disarmed red. |
| Look | Frames on tap areas | *On* (default) shows the radio's own frame around every place on the full screen that takes a press; *Off* covers it. |
| Look | Battery yellow at | The fuel percentage at and below which the battery panel turns yellow, 0 % to 100 %, default 20 %. |
| Look | Battery red at | The fuel percentage at and below which it turns red, 0 % to 100 %, default 0 %. It cannot be set above *Battery yellow at*. |
| Layout | Left panel | *Battery card* (default), *Battery gauge* or *Off*. |
| Layout | Left panel width | *Narrow* (22 % of the width), *Normal* (30 %, default) or *Wide* (40 %). On a narrow widget zone the panel gives way so the grid keeps room. |
| Layout | Status bar | The bar at the foot of the flight screen and the statistics screen. On by default; off, the tiles and the table take its height. |
| Layout | Status bar: TPWR | The transmitter power in the status bar. On by default. |
| Tiles | Grid size | *2 x 2*, *3 x 2* (default), *4 x 2*, *2 x 3* or *3 x 3* -- columns by rows. |
| Tiles | Tile 1 … Tile 6 | The reading each slot shows: everything Urban's value rows offer (see the [Urban page](urban-theme.md#settings)), plus the governor state, the PID, rate and battery profile, the flight time, the total flight time and the flight count, or nothing. Defaults: headspeed, current, ESC temperature, BEC voltage, power, and slot 6 off. ESC load is offered and not a default: it reads `-` on a model whose controller limit is not known. |
| Tiles | Extra tile | *Model image* (default), *Profiles P/R/B* or *Off*. |
| Tiles | Units beside the values | The unit in each tile's caption and beside the battery card's cell voltage. On by default. |
| Tiles | Temperature colours | Colours the ESC and MCU temperature tiles, as on Urban. *Off* (default), *Standard* or *Early*. |
| Top Bar | Clock, RQ bar, TQ bar, RSSI bars, Transmitter battery, Colour the bars, Link view switch | As on Urban, with Urban's defaults. The link bars' warning and critical steps are not set here: they are the levels of the link announcements, as on Urban -- see [the link steps](urban-theme.md#the-link-steps). |
| Keys | Key PAGE >, Key PAGE <, Key MDL, Key SYS, Key TELE | As on Urban: for the keys left on *Theme* at *System* → *Settings* → *Dashboard* → [*Keys*](../pages/settings/dashboard/keys.md), unbound until the pilot binds them, a key held radio-wide marked *(global)* -- as the radio comes PAGE >, PAGE <, SYS and TELE, so a PAGE binding here takes effect only once PAGE is set to *Theme* there; *Theme: Tuning* opens *Profile & Tuning*, *Theme: Status* the *Status* page, and so on. |
| Telemetry | Tile 1 … Tile 12 | The reading each tile of the *Telemetry* page shows, from the same list as the six slots. Defaults as on Urban. |

Every setting Urban has is carried; *Status bar: TPWR* moved from the top bar's page to the
*Layout* page, beside the status bar it belongs to.

The link bars, in the top bar and on the *ELRS* page, take their amber and red steps from the
announcements under *System* → *Settings* → *Audio* → *Events* → *Link*, exactly as Urban's do:
the [Urban page](urban-theme.md#the-link-steps) lists which announcement each bar follows. A value
an earlier version of Grid stored for *Link good above*, *Signal good above* or *TX power limit*
stays in the settings file and is no longer read.

## What it reads

What Urban's flight screen declares whatever its rows show -- the transmitter's link quality and
power, the air rate's sensitivity floor, whether a second antenna has been seen, the
skipped-frame count and the speed controller's live status -- plus whatever a tile that is
actually drawn needs: a slot past the last cell of the grid declares nothing. The *Telemetry* and
*ELRS* pages name their own readings, as on Urban. The statistics screen declares only the
transmitter power and the skipped-frame count of its bar (`TPWR`, `*Skp`) and reads everything
else from the flight record. A reading the model does not carry shows `-`.

## What it does not do yet

- **The governor state, the throttle and the flight totals are not on the flight screen unless a
  tile shows them**: Grid has no panel for them. The governor, the profiles, the flight time,
  the total flight time and the flight count can be put in a tile; the throttle shows on the
  *Status* page.
- **With the status bar off, the flight screen loses everything the bar says**: the model name,
  the arm state and the arming reasons, *MAIN POWER LOST* in words, the speed controller's live
  warning or fault, the transmitter power and the skipped frames. A lost main pack still shows on
  the battery panel (`--%` in red, the cell row red). The *Status* page is then reached by a key
  only.
- **A copy in the user folder draws with the shipped files**, as Urban's does.
- What Urban's page lists for its *Telemetry* and *ELRS* pages and its statistics bar holds for
  Grid's too.

## Related

- [Urban theme](urban-theme.md) — the pages Grid shares with it, described in full.
- [Dashboard themes](../developer/dashboard-themes.md) — the manifest keys, `fullscreen`,
  `sources` and the settings pages this theme uses.
- [Quick menu](quick-menu.md) — what opens over the theme in full screen.

*Documented against RFSuite 0.1.7.*
