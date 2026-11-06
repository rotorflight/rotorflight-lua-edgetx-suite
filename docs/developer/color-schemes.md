---
title: Colour schemes
sidebar_label: Colour schemes
---

# Colour schemes

`src/rfsuite/lib/color_schemes.lua` holds the suite's two colour schemes, light and dark, by role.
It is the one place a scheme colour is defined. Change a value there and everything that reads the
role follows.

**The widget's menu pages read it, through `widgets/dashboard/menu_look.lua`, and so do its loading and standby screens and the tool's start screen, directly, which also take their logo from `logo()`.** The tool's `ui/palette.lua` and the widget's own colours stay as they are
until they are moved onto it, each in a pull request of its own.

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

## What a scheme cannot reach

`toggle`, `choice` and `numberEdit` parse `color` and ignore it, so they draw in the radio's theme.
The header of an LVGL `page` node is the firmware's as well: it paints the radio theme's
`COLOR_THEME_SECONDARY1`.
