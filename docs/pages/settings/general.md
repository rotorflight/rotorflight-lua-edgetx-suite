---
title: General
sidebar_label: General
sidebar_position: 10
---

# General

What holds for the whole suite on this radio: which questions it asks before it writes, which colors
the tool and the dashboard's quick menu are drawn in, which unfinished features it shows and whether
the developer tools are in the menu. The choice belongs to the radio and applies to every model on it.

## Where to find it

*System* → *Settings* → *General*

Always available.

## Settings

| Section | Setting | What it does |
| --- | --- | --- |
| Safety & Prompts | Confirm on Save | Asks before a Save writes to the flight controller. On as it comes. |
| Safety & Prompts | Show Disarm Warning on Save/Reload | Warns before a Save or Reload while the model is armed. On as it comes. |
| Safety & Prompts | Confirm on Reload | Asks before a Reload replaces edits that are not saved. On as it comes. |
| Appearance | Color scheme | *Light* or *Dark*: the colors of the whole tool -- its menu, pages, help and notices, and the radio's own switches, fields and page header while it is open -- of the dashboard's [quick menu](../../dashboard/quick-menu.md) and the pages it opens, of its loading and [standby](../../dashboard/standby-screen.md) screens and of the [helicopter setup wizard](../helicopter_setup.md), on every theme. *Light* as it comes. A saved change shows at once. |
| Appearance | Menu style | *Card*: a button for each entry, as it comes. *Rotary*: [rolling lists](../../dashboard/quick-menu.md#the-rotary-style) for the wheel or a finger. Sets the quick menu and the [battery picker](../../dashboard/quick-menu.md#the-battery-picker), on every theme. |
| Preview | Setup Assistant | Shows the unfinished setup assistant in the menu. It asks once when turned on, because it can write to the flight controller. Off as it comes. |
| Preview | In-flight tuning | Shows the unfinished [in-flight tuning](../../dashboard/inflight-tuning.md) surface, which changes parameters in flight. It asks once when turned on. Off as it comes. |
| Development | Developer Tools | Shows the developer pages and tools in the menu. Off as it comes. |

## Notes

- **The color scheme reaches the whole tool**, opened from the radio's tools or from the dashboard,
  and the dashboard's quick menu, battery picker, battery profile page, erase question, loading and
  standby screens and the helicopter setup wizard. In-flight tuning and the dashboard themes keep their
  colors, so a dark theme opens a light menu until the scheme is set to dark, and a widget zone on the
  radio's home screen stands in the scheme's color until the first connection.
- **While the tool is open, the radio's own controls take the scheme too.** EdgeTX draws its switches,
  number fields, choices and the page header in the radio theme's colors, so the tool writes those
  colors from the scheme when it opens and puts the radio theme's back when it closes -- also when it
  is closed with a long press of RTN or ends with an error. Should that ever fail, the next start of the
  tool or the dashboard puts them back, and a restart of the radio always does.
- **A menu tile that cannot be opened yet** -- such as the configuration tiles before the flight controller
  answers -- is grey with a grey label in *Light*, and an empty frame with a faded icon and a grey label
  in *Dark*.
- **A saved scheme shows in the tool at once**, on the page it was saved on. The widget picks it up
  with its next reload of the settings, which follows a save on its own.
- **A preview feature is already in the suite but not finished.** It stays hidden until it is
  switched on here, one switch per feature.

## Related

- [Quick menu](../../dashboard/quick-menu.md) — what the color scheme colors.
- [Quick Settings](dashboard/quick_menu.md) — the quick menu's entries.
