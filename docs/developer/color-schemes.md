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

**In-flight tuning reads it directly:** `widgets/dashboard/inflight/screen.lua` takes
`general.color_scheme` from the widget's preferences through `name()` and keeps one table per scheme
that names the roles for its surfaces, the selected row's fill (`selection`), the cells of its
actions (`raised`) and the track of its progress bars (`rule`) among them.

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
| `tileOff`, `tileOffText` | A disabled tile's face and its text. In light the face is greyed (`raised`'s value) with `muted`'s text; in dark the face is the page, so the tile is an empty frame, with `disabled`'s text |

A disabled tile's icon also fades into its face: `ICON_FADE` in the same file holds the opacity per
scheme (0-255), read through `iconFade()`. Light keeps the icon (0); dark fades it by 40 % (102), which
keeps the faded icon at about 3.8:1 on the face, above the 3:1 a disabled control needs.

## Rules

- **A new colour is a new role, not a literal.** The Alignment page's 3D model takes the `model*`
  roles. The Logs graph's four curves are data colours, not roles: `app/pages/logs/graph.lua` keeps one
  set for the dark page and darker ones of the same hues for the light page. A dashboard theme owns its
  own colours.
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
belongs in its list. `bin/ui/verify_scheme_drawings.lua` does the same for the tool's own drawings
in both schemes: Session Logs' warn and error rows, the 3D model and the four curves.

## Pictures

The firmware cannot tint a picture, so a picture that follows the scheme exists once per scheme.
`bin/icons/make_scheme_icons.py` makes them from the suite's own icons, which are dark on an opaque
ground: the darkness becomes transparency in the scheme's colour. It reads the colour from `lib/color_schemes.lua`:
`text` in light, as dark as the pictures are today; `accentInk` in dark, the role for a glyph. Run it after changing either
value; `--check` says where a picture is missing, stale or left over. A page whose scheme picture is missing is drawn with its own picture (`palette.iconPath`, one `fstat` per picture and scheme, logged at warn), so a forgotten run shows the old icon rather than a blank tile.

The page header's icon is the exception: the firmware tints it itself, with the header's title colour,
and reads only the picture's darkness as its shape. So it is the Rotorflight "RF" in black on white,
one file per header height and none per scheme: `assets/icon.png` (30 px, 480-wide screens, also the
model template's screens) and `assets/icon_800.png` (40 px, 800-wide screens), picked in `ui/home.lua`.

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

`PRIMARY3` keeps the radio's colour: EdgeTX paints the radio's top bar with it, not a control the tool shows. The header and the controls are
coupled by the firmware: the header's colour is the controls' text colour and its title colour their
background.

When they are written: run as a script of its own, the tool writes them in its start-up call, before
its first screen. Opened from the dashboard, the start-up call is one widget call under the instruction
limit and already the heaviest of the open, so it only marks them owed: the pass after it writes them,
a pass that builds nothing and runs no page or menu step, and the first screen is built on the pass after that, so nothing is drawn in the
radio's colours. A write stopped at the limit is tried again on the next passes, three times at most,
and the first build waits for it (`ui/home.lua`, `writeOwedThemeSlots`; checked by
`bin/ui/verify_tool_open_theme_slots.lua`).

`lcd.setColor` changes the whole radio's interface, and EdgeTX restores nothing when a script ends,
so the radio's colours are put back on every way the tool can end:

- `restore()` on every exit the suite runs itself: the closing sequence, and the dashboard's
  `tool_host.lua` when the hosted tool closes or fullscreen is left. It writes the colours back before
  it lets go of anything, so one stopped at the instruction limit is called again on the widget's next
  pass. `apply()` arms the finaliser and holds its state before it writes the marker or a slot, drops
  the scheme it named before the first slot, and names the new one only once every slot carries it.
- A finaliser. A long press of RTN closes the tool without running any Lua and an error ends it, but
  both close its Lua state, and `lua_close` runs every pending `__gc` metamethod first. The guard
  holds the radio's colours and `lcd.setColor` as upvalues, since the suite's globals may be gone by
  then. This holds from EdgeTX 2.11.2: on 2.11.0 and 2.11.1 the tool's Lua state is closed only when
  the next tool starts, so after a long RTN or an error the marker file below puts the colours back.
- A marker file, `theme_slots.txt` in the user folder, written before the first slot. Should neither
  of the above run, the dashboard widget's first refresh after a pause (EdgeTX stops widget refresh
  while a tool window is open) puts the radio's colours back and deletes it; the next start of the
  tool takes the radio's colours from it instead of from the slots, writes it again and puts them
  back when it closes. Both only while each slot holds the radio's colour or one a scheme writes
  there, so a theme applied since is left alone. Never while the tool is open in that widget.
- A restart of the radio, which reloads the theme.

`bin/ui/verify_theme_slots.lua` drives the module against a stub of the colour table, every way out
included.
