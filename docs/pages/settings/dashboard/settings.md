---
title: Settings
sidebar_label: Settings
sidebar_position: 20
---

# Settings

The settings the dashboard themes themselves offer. The page is a grid of tiles, one per theme
that has settings, and a tile opens that theme's own page — the battery bounds it draws its
gauges against, the values it puts in its rows, the colours it uses. Nothing here is a setting
of the suite: what a tile opens is written by the theme, so two radios with different themes
installed see different pages.

Which theme a model actually shows is chosen on [*Theme*](theme.md), and a theme keeps its
settings whether or not it is the one in use.

The theme tiles edit the **standard values**, which every model without settings of its own uses; the first
line of a theme's page reads *Standard values for all models*. A model with settings of its own changes
some of them for itself, on the *Per-Model Settings* tile.

## Where to find it

*System* → *Settings* → *Dashboard* → *Settings*

Always available. A theme appears here when it ships a settings module and does not declare
itself standalone; a theme with neither is configured nowhere, and one whose module offers
nothing opens a page saying so.

The tiles are made when the grid is opened, from the themes installed on the radio. While that
is under way the grid shows *Loading...*, and then all of its tiles at once; with the shipped
themes that is a moment. The more themes there are, the longer it takes, and once made the grid
opens at once until the tool is closed -- up to fifteen themes. With sixteen or more, the grid
shows *Loading...* for a moment each time it is opened or drawn again -- back from a theme's
page, for one -- while its tiles are made, sixteen at a time, and then all of them at once.

## Settings

| Setting | What it does |
| --- | --- |
| Per-Model Settings | The first tile, only while a flight controller is connected and per-model settings are on for its model (see [*Theme*](theme.md)). Opens [the list of what that model changes](overrides.md), and from there the settings of each theme that model draws, for that model alone. |
| *(one tile per theme)* | Opens that theme's standard settings. What the page holds is the theme's own business; several of the shipped themes offer the battery voltage bounds their gauges are scaled to. |

### Default

Default opens a grid with **Look**, **Before flight**, **In flight**, **Statistics**,
**Info bar** and **Keys**. The existing settings below are on Look; the other five use the
shared pages described next.

| Setting | What it does |
| --- | --- |
| Minimum, Maximum | The battery voltage the gauge spans. Editing either limit saves both as an explicit range. Saving another option leaves an automatic or inherited range unchanged. |
| Colour at alert levels | Off by default. On, the link quality box turns amber at the *Warning (%)* and red at the *Critical (%)* of the *Link Quality* announcement (*Settings* → *Audio* → *Events* → *Link*) — but only while that announcement is switched on; with it off, or with this setting off, the box draws as it always did. |

A theme may split its settings into pages. Its tile then opens a second grid, one tile per
page, and each of those opens part of the theme's settings — the same settings, divided so a
page fits the screen. Themes that do not split show their settings directly.

### Shared phase, Info bar and Keys pages

Themes that declare boxes can offer shared **Before flight**, **In flight**, **Statistics**,
**Info bar** and **Keys** pages; every shipped theme that declares boxes uses them -- Default, RF Status,
@AERC, @AERC Nitro, @RT-RC, @RT-RC Nitro and @SRB-RC, each with its own settings on Look. Each
phase page lists one
dropdown per reassignable plain value tile, labelled with its own caption. Before flight and
In flight choose live readings; Statistics chooses figures from the last flight. The choice
starts on the theme's own value, and the caption, unit and decimals follow a different choice.
A tile without a caption stays without one. Gauges, timers, governor, blackbox, flight count
and the model image keep what the theme draws.

The shared Info bar page arranges the bar across the top of the theme's full screen.
**Buttons** puts the tool, quick menu and close buttons at the **Left** (as it comes) or the
**Right** end. **Position 1** to **Position 6** choose what the other end shows, Position 1 at
the far end and the others following inwards: **Empty**, **Clock**, **Radio battery symbol**,
**Radio battery %**, **Radio battery V**, **Link bars** or **Link value**. As it comes,
Position 1 is the battery symbol, Position 2 the clock and Position 3 the link bars; the rest
are empty. What does not fit before the buttons is left out; on the smaller screens that can be
the inner positions. The bar and its buttons are drawn whatever is chosen.

The shared Keys page assigns PAGE >, PAGE <, MDL, SYS and TELE to nothing, the quick menu, the
suite tool, Flight Log or leaving full screen for that theme. A key held by the radio-wide
[*Settings* → *Dashboard* → *Keys*](keys.md) page is greyed out and marked *(global)*; change
it there, or set it to **Theme** there to enable the theme's binding. Theme bindings start on
Nothing. The radio-wide choice takes priority over both standard and model-specific bindings.

The phase choices, the info bar arrangement and theme key bindings are ordinary theme settings: the theme tile edits
the standard values, and opening the theme through [Per-Model Settings](overrides.md) lets
the connected model override them, along with its Look settings. Save each page before leaving
it for another page.

## Notes

- The voltage forms of Default, RF Status, @RT-RC and @RT-RC Nitro keep their existing range
  when neither voltage field was edited. An automatic range therefore stays automatic after
  saving another option. Editing either field saves both limits; in model settings this also
  preserves an explicit range equal to the theme's numeric defaults when the radio has none.
  Reset the model's voltage overrides to return to the standard or automatic range.

- Settings are stored per theme, so a theme copied into
  `/SCRIPTS/TOOLS/rfsuite.user/dashboard/` starts from its defaults rather than inheriting the
  original's values, and configuring the copy does not change the original.
- Where a value is stored follows the page, not the connection: a theme tile stores the radio's
  standard values whether or not a flight controller is connected, and a theme opened from
  *Per-Model Settings* stores the model's values — only those that differ from the standard. A
  model reads its own values only while per-model settings are on for it; switching them off on
  *Theme* keeps the values and ignores them.
- A save says *Saved* only when its values reached the card. A theme opened from *Per-Model
  Settings* stores them in the model's own file, so the save reports that file: where the card
  refuses it, the page shows *Save failed: the settings file could not be written to the SD card*,
  the values on the page have not been stored for the model, and saving again once the card can be
  written stores them. A theme tile stores the radio's values, so the save reports the radio's
  file, and a card that refuses it shows the same sentence; the model's file, rewritten beside it
  while a flight controller is connected, holds none of those values and does not decide the
  answer.
- A card from an earlier version may hold per-model theme settings saved while a flight
  controller was connected. Such a model keeps using them, and they are listed under *Per-Model
  Settings*, until the switches on *Theme* are saved off.
- A card from an earlier version may also hold, in the radio's own settings, a copy of a value
  that was saved for a model. Earlier versions removed that copy whenever the theme was saved for
  a model; this one does not, because such a copy cannot be told apart from a standard value set
  on purpose. It stays the standard for every model without values of its own until it is changed
  on the theme's tile. For the battery voltage bounds that means those models do not scale the
  bounds to the cell count they measure.
- A theme split into pages saves the page that is open. Leaving a page for another one of the
  same theme discards what has not been saved, so save before stepping across.
- Saving reloads the dashboard, so a change is visible on the widget as soon as the tool is
  closed.
- A theme's page that cannot be loaded says so under its first line, with the reason, and the
  same line goes to the log. A reason too long for the row is cut short with `...`; the log keeps
  it whole. *Reload* tries the load again. Opened from the dashboard, the tool runs under the dashboard's limit
  on the work one call may do, so a page whose opening needs more is stopped there with
  *CPU limit* while the same page opens from the radio's tool list.

## Related

- [Dashboard themes](../../../dashboard/README.md) — what the widget shows and which themes ship
  with the suite.
- [User themes](../../../dashboard/user-themes.md) — copying a theme onto the card and editing
  it, including the settings a copy carries.

*Documented against RFSuite 0.1.7.*
