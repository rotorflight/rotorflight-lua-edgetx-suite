---
title: Keys
sidebar_label: Keys
sidebar_position: 29
---

# Keys

Choose the dashboard's hardware shortcuts at fullscreen, including before the flight controller
connects. These choices belong to the radio and apply to every theme and model.
Out of the box, SYS opens the suite tool, and TELE, PAGE > and PAGE < the quick menu; MDL is the
theme's.

## Where to find it

*System* → *Settings* → *Dashboard* → *Keys*. Always available, including without a flight controller.

## Settings

| Setting | What it does |
| --- | --- |
| MDL | One action per key, **Theme** by default. With the theme itself showing and no view on top, **Theme** uses the theme's binding; an unbound key is consumed without opening anything. **Nothing** disables the key. **Quick menu**, **Main menu**, **Flight log**, **Exit fullscreen** and **In-flight tuning** override any theme binding. |
| PAGE >, PAGE < | As above, **Quick menu** by default: the key opens the quick menu and closes it again. |
| SYS | As above, **Main menu** by default. |
| TELE | As above, **Quick menu** by default. |

A radio without one of these keys never sends it; its saved choice still remains.

## Notes

- Save applies the choices to every model; no per-model copy is written. A key left on its
  default stores nothing, so PAGE, SYS and TELE put on **Theme** are stored as Theme.
- PAGE, SYS and TELE hold their default for **every** theme. On a theme that draws its own full
  screen, such as Urban, Grid and Deck, the page keys are the key path to the quick menu. On
  themes whose full screen is the quick menu, SYS opens the suite tool there as well, and TELE
  and the page keys answer with the quick menu that is already on screen, or open it over
  another view. Put a key on **Theme** to give it back to the theme.
- A theme binds keys in its full-screen build, or declares them in its manifest (`init.lua`).
  Build bindings take precedence over manifest bindings. Urban, Grid and Deck let the pilot bind them on
  their own *Keys* settings page, which only acts on keys left on **Theme** here: a key held here
  is marked *(global)* there and cannot be changed. As the radio comes that holds PAGE >,
  PAGE <, SYS and TELE, so a theme's own PAGE binding takes effect only once the page keys are
  set to **Theme** here. That page starts unbound, so a key on **Theme** does nothing until it
  is bound there, PAGE > and PAGE < on the theme base included.
  Default binds none, so on Default a key put on **Theme**, PAGE > and PAGE < included, does
  nothing while the dashboard itself is showing.
  This describes Default's initial bindings; its shared **Keys** settings page -- which RF
  Status, @AERC, @AERC Nitro, @RT-RC, @RT-RC Nitro and @SRB-RC have as well -- now lets the
  pilot assign those keys too, with the same *(global)* marker and greyed rows for keys held
  here, and its bindings can be overridden through **Per-Model Settings** while this
  radio-wide page still takes priority.
- On the connection screen, global actions already work, and so do manifest bindings to the
  host's actions and to its own views, such as the quick menu. A manifest binding to one of the
  theme's own views takes effect once the connection is ready, when those views are registered;
  build bindings once that theme has built.
- An opened menu can be closed with its bound menu key. Short RTN keeps the current Back/Close
  behavior, and long RTN leaves fullscreen. MDL, SYS or TELE on Theme does nothing while another
  view is on top unless the theme binds it to that view. PAGE keys on Theme close the quick menu
  or open it over another view, unless bound to the view on top, which they toggle instead.
  A global action — a default included — still
  applies there. Nothing also consumes the key before LVGL sees it.
- On themes without a theme base layer (legacy quick-menu fullscreen), keys on **Theme** are
  left to LVGL as before.
- While the suite tool or in-flight tuning owns the fullscreen, these shortcuts do not take its keys.
- **In-flight tuning** opens the tuning surface directly, as the quick menu's *IN-FLIGHT TUNING*
  entry does, and only where that entry is offered (the in-flight tuning preview and the radio's
  in-flight tuning switch on, and the model disarmed); otherwise the key does nothing. A surface
  opened on the ground stays open through arming, so the key cannot open tuning in the air.
- Main menu and Flight log are refused while armed.
  The quick menu's FC writes stay hidden until the connection is ready and the model is disarmed.
- A failed SD-card save reports the error and leaves the page marked as unsaved.
- Unknown stored action values use the key's default. Existing theme configuration is not changed
  by this page.

## Related

- [Quick menu](../../../dashboard/quick-menu.md)
- [Dashboard themes](../../../dashboard/themes.md)

*Documented against RFSuite 0.2.1.*
