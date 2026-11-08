---
title: Colour schemes
sidebar_label: Colour schemes
---

# Colour schemes

`src/rfsuite/lib/color_schemes.lua` holds the suite's two colour schemes, light and dark, by role.
It is the one place a scheme colour is defined. Change a value there and everything that reads the
role follows.

**The widget's menu pages read it, through `widgets/dashboard/menu_look.lua`, and so do its loading and standby screens and the tool's start screen, directly, which also take their logo from `logo()`.** The widget's own colours stay as they are until they are moved onto it.

**The tool reads it through `ui/palette.lua`**, which holds no value of its own: it names the
scheme role each tool role takes, and `palette.apply(name)` rewrites the roles in place, so every
module holding the table sees a change. `ui/home.lua` applies the stored scheme before its first
build and again when a save changes it, and then builds the open page again. Every page body gets
a rectangle in `page` behind it (`palette.appendBackground`).
The tile icons and the shipped dashboard themes' pictures come once per scheme (see *Pictures*), in
`app/icons/<scheme>/` and `widgets/dashboard/theme_icons/<scheme>/`, named by their path below
`app/pages/` or `widgets/dashboard/themes/` with the slashes joined (`setup/mixer/icon.png` is
`setup_mixer_icon.png`); `palette.iconPath` picks the scheme's file, and a pilot's own theme keeps its
pictures.

**The helicopter setup wizard reads it directly:** `helicopter_setup/page.lua` loads the file when
the page opens, takes `general.color_scheme` through `name()` and hands the colours to its views as
`w.palette`, and the scheme's name as `w.scheme`, which also picks the picture set
(`docs/developer/helicopter-wizard-artwork.md`). It lets go of both when the page closes, so a changed setting
shows the next time the page opens.

## Using it

The tool and the dashboard widget are separate Lua states, and each loads its own copy:

```lua
local Schemes = rfsuite.require("lib/color_schemes.lua")
local colors = Schemes.colors("dark")
-- { type = "rectangle", color = colors.page, ... }
```

`colors()` takes a scheme's name and treats anything else as the default, light. It converts a
scheme through `lcd.RGB` in place the first time it is asked for, so asking again costs a table
read, and `SCHEMES` is not to be read directly. Read the table `colors()` returns and never write to
it, since every caller in the Lua state shares it.

## The roles

| Role | Where it belongs |
| --- | --- |
| `page` | Behind everything on a screen |
| `card` | A surface on the page |
| `raised` | An inactive row, a progress track |
| `header`, `headerText` | A header strip the suite draws itself, and the text on it |
| `text` | Body text |
| `muted` | Secondary text: captions, neighbouring rows |
| `disabled` | The text of a disabled control, on `page` or `card` and not on `raised`, where it falls below 3:1. A disabled control has an outline rather than a fill. At 3:1 it never carries anything the pilot needs |
| `accent` | A fill or a line: focus outline, primary button, divider under a section |
| `accentInk` | The accent as text or a glyph. `accent` itself is too pale for small text on a light surface |
| `onAccent` | Text on an `accent` fill |
| `selection` | The selected row. An `accent` outline carries the selection, since in light the fill alone is close to `raised` |
| `warning` | Something the pilot should look at before going on |
| `error`, `onError` | A failure or a close button, and the text on it |
| `ok`, `onOk` | A check that passed, and a mark on an `ok` fill |
| `rule` | A quiet divider, and the track of a progress bar, where `raised` hardly shows on the page |

## Rules

- **A new colour is a new role, not a literal.** Log graph curves and the alignment page's shading
  are data colours and stay where they are, and a dashboard theme owns its own colours.
- **Take the role, not the value that looks right.** Two roles sharing a value today are still two
  roles.
- **A value never crosses schemes.** Dark's warning on the light page reads at about 1.4:1, so a
  screen that is always dark or always light still goes through a scheme.
- **Colour is never the only signal.** A warning also says so in words, a selection also has its
  outline.
- **Check a neutral as it is drawn.** The panels are RGB565, and green has one more bit than red and
  blue, so a light grey can draw pink or a dark one green. `241,242,243` draws `247,243,247`.

`bin/ui/verify_color_schemes.lua` holds both schemes to the same set of roles and checks each
foreground against the surfaces it is drawn on, as RGB565 draws them. A pair a new role is used on
belongs in its list.

## Pictures

The firmware cannot tint a picture, so a picture that follows the scheme exists once per scheme.
`bin/icons/make_scheme_icons.py` makes them from the suite's own icons, which are dark on an opaque
ground: the darkness becomes transparency in the scheme's colour. It reads the colour from this file:
`text` in light, as dark as the pictures are today; `accentInk` in dark, the role for a glyph. Run it after changing either
value; `--check` says where a picture is missing, stale or left over.

## What a scheme cannot reach

Directly, nothing: `toggle`, `choice` and `numberEdit` parse `color` and ignore it, and the header of
an LVGL `page` node is the firmware's. All of them take their colours from the radio theme's slots
(`libui/etx_lv_theme.cpp` in EdgeTX), so while the tool is open, `lib/theme_slots.lua` writes those
slots from the scheme with `lcd.setColor`, through one mapping:

| Slot | Role | What EdgeTX paints with it |
| --- | --- | --- |
| `PRIMARY1` | `text` | Text on a checked control |
| `PRIMARY2` | `card` | A control's background, the page header's title |
| `SECONDARY1` | `accentInk` | A control's text, the toggle's knob, the page header |
| `SECONDARY2` | `rule` | A control's border |
| `SECONDARY3` | `page` | A window's own background, the keyboard, a full-screen dialog's buttons |
| `FOCUS` | `accent` | The focus border and outline |
| `EDIT` | `accent` | A number or text field while it is edited (its text is `PRIMARY2`) |
| `ACTIVE` | `accent` | A checked control, a switched-on toggle's track |
| `WARNING` | `warning` | Warning text |
| `DISABLED` | `disabled` | Disabled text |

`PRIMARY3` keeps the radio's colour: nothing in EdgeTX's own interface paints with it. The header and the controls are
coupled by the firmware: the header's colour is the controls' text colour and its title colour their
background.

`lcd.setColor` changes the whole radio's interface, and EdgeTX restores nothing when a script ends,
so the radio's colours are put back on every way the tool can end:

- `restore()` on every exit the suite runs itself: the closing sequence, and the dashboard's
  `tool_host.lua` when the hosted tool closes or fullscreen is left.
- A finaliser. A long press of RTN closes the tool without running any Lua and an error ends it, but
  both close its Lua state, and `lua_close` runs every pending `__gc` metamethod first. The guard
  holds the radio's colours and `lcd.setColor` as upvalues, since the suite's globals may be gone by
  then.
- A marker file, `theme_slots.txt` in the user folder, written before the first slot. Should neither
  of the above run, the next start of the tool, or the dashboard widget's first refresh after a pause
  (EdgeTX stops widget refresh while a tool window is open), puts the radio's colours back -- only
  while the slots still hold what the suite wrote, so a theme applied since is left alone.
- A restart of the radio, which reloads the theme.

`bin/ui/verify_theme_slots.lua` drives the module against a stub of the colour table, every way out
included.
