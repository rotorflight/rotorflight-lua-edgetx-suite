---
title: Quick Settings
sidebar_label: Quick Settings
sidebar_position: 28
---

# Quick Settings

Which entries the dashboard widget's [quick menu](../../../dashboard/quick-menu.md) — the list
headed *QUICK SETTINGS* at full screen — shows, and in which order. The choice belongs to the
radio and applies to every model on it, so no flight controller has to be connected to change it.

## Where to find it

*System* → *Settings* → *Dashboard* → *Quick Settings*

Always available.

## Settings

| Setting | What it does |
| --- | --- |
| Position 1 … Position 5 | The entry in that place of the quick menu, counted row by row, left to right. Each row offers every entry that can be placed — *ERASE BLACKBOX*, *IN-FLIGHT TUNING*, *BATTERY*, *MAIN MENU*, *FLIGHT LOG* — and a dash, which leaves the place empty. There is one row per entry, so every entry can be placed. Default: *ERASE BLACKBOX*, *IN-FLIGHT TUNING*, *BATTERY*, *MAIN MENU*; *FLIGHT LOG* is not in it until it is chosen here. |

Empty places are skipped, so the menu has no gaps: a dash in *Position 1* and *BATTERY* in
*Position 2* puts *BATTERY* in the first place.

## Notes

- **The choice takes effect with the widget's next reload of the settings**, which follows a save
  on its own. With the tool opened from the widget at full screen, the menu shows the new order
  once the tool is closed.
- **An entry chosen twice counts at its first place.** After a save the page shows it there only.
- **A chosen entry still hides where it does not apply.** The menu asks each entry's own
  condition on top of this list: *IN-FLIGHT TUNING* only while its preview is on, *BATTERY* only
  with a pack for this model while disarmed, *ERASE BLACKBOX* only with a ready connection while disarmed,
  *MAIN MENU* only while disarmed, *FLIGHT LOG*
  only while the model is disarmed. In the rotary style an entry that is only waiting for the connection
  or for the model to be disarmed stays, grey, and says why. Taking an entry
  out here hides it always.
- **BATTERY PROFILE is not a position.** The menu always draws it as its last row or entry, under the
  entries chosen here, while the connection is ready, the model is disarmed and the flight controller has reported a
  battery profile with a capacity.
- **A list saved by an earlier version that names BATTERY PROFILE** reads without it. One that
  named BATTERY PROFILE alone names nothing that can be placed, and reads as the default.
- **A dash in every place empties the menu.** The header and its close box stay, so full screen
  can still be left.
- **A save the card refuses** shows *Save failed: the settings file could not be written to the
  SD card*, and the order is not stored.
- **Saved with the default order, the page stores nothing**, and the menu then follows whatever
  default a later release brings. Any other order is stored as it stands.
- **A dashboard theme that draws the quick menu itself** follows this list — Urban does. A theme
  that places a single entry among its own controls, such as Urban's *Profile & Tuning* page, is
  not affected by it.

## Related

- [Quick menu](../../../dashboard/quick-menu.md) — what each entry does.

*Documented against RFSuite 0.1.7.*
