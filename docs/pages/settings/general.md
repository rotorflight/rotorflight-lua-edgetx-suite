---
title: General
sidebar_label: General
sidebar_position: 10
---

# General

What holds for the whole suite on this radio: which questions it asks before it writes, how the
dashboard's quick menu is coloured, which unfinished features it shows and whether the developer
tools are in the menu. The choice belongs to the radio and applies to every model on it.

## Where to find it

*System* → *Settings* → *General*

Always available.

## Settings

| Section | Setting | What it does |
| --- | --- | --- |
| Safety & Prompts | Confirm on Save | Asks before a Save writes to the flight controller. On as it comes. |
| Safety & Prompts | Show Disarm Warning on Save/Reload | Warns before a Save or Reload while the model is armed. On as it comes. |
| Safety & Prompts | Confirm on Reload | Asks before a Reload replaces edits that are not saved. On as it comes. |
| Appearance | Color scheme | *Light* or *Dark*: the colors of the dashboard's [quick menu](../../dashboard/quick-menu.md) and the pages it opens, of its loading and [standby](../../dashboard/standby-screen.md) screens and of the tool's start screen, on every theme. *Light* as it comes. |
| Appearance | Menu style | *Card*: a button for each entry, as it comes. *Rotary*: [rolling lists](../../dashboard/quick-menu.md#the-rotary-style) for the wheel or a finger. Sets the quick menu and the [battery picker](../../dashboard/quick-menu.md#the-battery-picker), on every theme. |
| Preview | Setup Assistant | Shows the unfinished setup assistant in the menu. It asks once when turned on, because it can write to the flight controller. Off as it comes. |
| Preview | In-flight tuning | Shows the unfinished [in-flight tuning](../../dashboard/inflight-tuning.md) surface, which changes parameters in flight. It asks once when turned on. Off as it comes. |
| Development | Developer Tools | Shows the developer pages and tools in the menu. Off as it comes. |

## Notes

- **The color scheme reaches the quick menu, the battery picker, the battery profile page, the erase
  question, the dashboard's loading and standby screens and the tool's start screen, and nothing else
  yet.** The suite's own pages and their notices, in-flight tuning, the wizard and the dashboard
  themes keep their colors, so a dark theme opens a light menu until the scheme is set to dark, and
  a widget zone on the radio's home screen stands in the scheme's color until the first connection.
- **The widget picks a saved scheme up with its next reload of the settings**, which follows a
  save on its own.
- **A preview feature is already in the suite but not finished.** It stays hidden until it is
  switched on here, one switch per feature.

## Related

- [Quick menu](../../dashboard/quick-menu.md) — what the color scheme colors.
- [Quick Settings](dashboard/quick_menu.md) — the quick menu's entries.
