---
title: User themes
sidebar_label: User themes
sidebar_position: 40
---

# User themes

RFSuite loads dashboard themes from two folders: the shipped ones from `/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/themes/`, and yours from the user folder at `/SCRIPTS/TOOLS/rfsuite.user/dashboard/`. A theme folder goes directly in there — `/SCRIPTS/TOOLS/rfsuite.user/dashboard/mytheme/init.lua`, with no `themes` level in between.

Both folders are listed, so a theme in the user folder is an additional choice in the theme selector under *System* → *Settings* → *Dashboard* → *Theme* rather than a replacement: a copy that keeps the original's `name` appears in the list twice, once for each folder. Give a copy a name of its own.

## Structure of a theme

A theme is a folder containing an `init.lua` manifest and one module per flight phase:

- `init.lua`: the theme's name, the phase module file names, optional settings and views, and optionally `fullscreen = "theme"`, which makes full screen show the theme itself with the quick menu opening over it. An optional `keys` table declares fullscreen shortcuts for the keys the pilot has on **Theme** on the global Keys page (as the radio comes, only MDL: the page keys, SYS and TELE start on a radio-wide action); the theme's build bindings take precedence. See the [full manifest field table](../developer/dashboard-themes.md#the-manifest-initlua) and [fullscreen details](../developer/dashboard-themes.md#a-theme-that-takes-fullscreen).
- `preflight.lua`: layout and boxes shown on the ground, before arming.
- `inflight.lua`: layout and boxes shown once the model is flying.
- `postflight.lua`: summary boxes shown after a flight, from the disarm onwards.

Two further modules are optional, and a theme that does not carry them loses nothing:

- `armed.lua`: shown from the arm until the model spools up. Without it that phase shows `preflight.lua`.
- `offline.lua`: shown after a flight once the flight controller has stopped answering — an unplugged battery, or the model out of range. Without it that phase shows `postflight.lua`.
- `icon.png`: the picture the theme selector draws for the theme. A theme without one is still selectable and shows an empty tile.

Each phase module returns a table with `layout` options (margins, grid dimensions) and a list of `boxes`.

Which module is on screen is not a setting: the widget computes the phase from the flight controller's own telemetry, and arming alone does not put the model in flight. [Adding a dashboard theme](../developer/dashboard-themes.md) gives the manifest keys, the exact phase triggers and the full box vocabulary.

## Box types and text styling

Themes define objects such as gauges (`type = "gauge"`), telemetry text (`type = "text"`), clocks and timers (`type = "time"`), and battery/governor status indicators.

### Text colors

Text boxes configure their default font color via `textcolor`. This property accepts:
- Numeric 16-bit RGB values (e.g. from `lcd.RGB(r, g, b)`).
- EdgeTX theme color constants (e.g. `COLOR_WHITE`, `COLOR_BLACK`).
- Named color strings: `"white"`, `"black"`, `"red"`, `"green"`, `"blue"`, `"yellow"`, `"orange"`, `"cyan"`, `"magenta"`, and `"grey"`.

```lua
{
  type = "text",
  source = "rpm",
  label = "RPM",
  textcolor = "orange",
}
```

### Tile fill and frame

Every box draws a tile under its content, filled with `bgcolor` (white where it names none).
Three more fields shape that tile:

- `bordercolor` draws a frame around the tile in that colour, `borderwidth` pixels wide (2 when
  omitted). It takes the same values as `textcolor`, named colours included.
- `rounded` rounds the corners of the fill and the frame by that many pixels.
- `bgcolor = false` draws no fill at all, so the box shows whatever lies under it — the theme's
  background, or a box declared before it in the same cells. That is how a gauge stands inside a
  framed panel: declare the panel first, then the gauge over it with `bgcolor = false`.

```lua
{ col = 1, row = 1, colspan = 2, rowspan = 2, type = "text", subtype = "governor",
  title = "GOVERNOR", bgcolor = BLACK, bordercolor = "red", borderwidth = 3, rounded = 6 }
```

A box without these fields draws the plain filled rectangle it always did.

### Gauges

A gauge shows the live reading by default. Given `stattype = "max"` or `stattype = "min"` it
shows that extreme of the flight instead — the same figure a `stats` text box shows for that
source — which is how a post-flight screen draws the highest head speed as a bar. Only the
sources the flight record keeps an extreme of have one
([flight statistics](../reference/flight-statistics.md)); for any other the gauge shows no value.

A horizontal bar is half its panel high, centred, and 4 px in from each side. The paddings change
that one direction at a time: given `gaugepaddingtop` or `gaugepaddingbottom` the bar spans the
panel's height less them, and given `gaugepaddingleft` or `gaugepaddingright` its width, as a
vertical bar always has. Paddings larger than the panel leave a thin bar inside the tile.

### Dynamic color thresholds

Both gauges and text boxes support a `thresholds` list. When telemetry values update, the box evaluates the thresholds and updates its text or accent color reactively:

#### Numeric thresholds
For numeric sources (e.g. `rpm`, `bec_voltage`, `temp_esc`, `altitude`, `flight_time`, `blackbox`), thresholds are specified as a table ordered by trigger values:

```lua
{
  type = "text",
  source = "bec_voltage",
  label = "BEC",
  thresholds = {
    { value = 6.5, textcolor = "red" },
    { value = 7.0, textcolor = "orange" },
    { value = 8.5, textcolor = "white" },
  }
}
```

Thresholds are evaluated in order (`value <= threshold.value`). Gauge fill thresholds use `fillcolor` (or `color`), while text and value labels use `textcolor` (or `color`). An entry can declare either or both. If no threshold matches, the default `textcolor` is used.

For temperature sources (`esc_temp`, `temp_esc`, `mcu_temp`, `temp_mcu`), threshold values are defined in Celsius (°C) in the theme and automatically converted when the radio is configured for Fahrenheit (°F).

#### When a threshold is resolved

A `value`, a `textcolor` and a `fillcolor` may each be given as a function, so that a limit can
come out of the theme's own configuration rather than being written into the box:

```lua
{
  type = "gauge",
  subtype = "arc",
  source = "bec_voltage",
  thresholds = {
    { value = function(_, state) return (state.themeConfig or {}).bec_warn or 6.0 end, fillcolor = "red" },
    { value = 1000, fillcolor = "green" },
  }
}
```

The list is resolved **once, when the box is built**, and the box then matches every value it is
given against the list that resolution produced. So anything such a function reads has to be
something that rebuilds the screen when it changes. The theme configuration is: saving it reloads
the active theme, which builds the boxes again. Live telemetry is not, and does not belong in a
threshold limit -- the box already re-evaluates the whole list against the current reading on
every change, which is what thresholds are for.

The same holds for the named colour strings above: they are mapped to a colour number when the
box is built, not on the first reading that arrives.

#### Governor state thresholds
With the GOVERNOR feature off, the governor mode reads OFF regardless of the stored mode, as on *Setup* → *Governor* → *General*, provided the flight controller reported its feature setting at connect.

For governor status boxes (`type = "text"`, `source = "governor"`), thresholds can match against governor state labels:

```lua
{
  type = "text",
  source = "governor",
  label = "GOV",
  thresholds = {
    { value = "DISARMED", textcolor = "grey" },
    { value = "SPOOLUP", textcolor = "orange" },
    { value = "ACTIVE", textcolor = "green" },
    { value = "RECOVERY", textcolor = "red" },
  }
}
```

Use the internal state names in thresholds: `OFF`, `IDLE`, `SPOOLUP`, `RECOVERY`, `ACTIVE`,
`THROFF`, `LOSTHS`, `AUTOROT`, `BAILOUT`, `DISABLED`, and `DISARMED`. The widget first tries the
displayed label and then these names, so the internal form keeps a user theme independent of the
radio language.

Write box and page titles in the plain text you want displayed. The installed archive contains
the i18n runtime (`i18n/init.lua`) but no locale bundles; `@i18n(...)@` markers in a user theme are
therefore not translated at runtime. The markers in the themes shipped with RFSuite work because
the package builder replaces them before the archive is created.

In governor modes OFF and LIMIT the flight controller keeps no governor state, so while the model is armed the box shows the mode instead, and its internal names are `MODE_OFF` and `MODE_LIMIT`. A threshold on a state name such as `OFF` does not match there.

## Notes

- User themes in `/SCRIPTS/TOOLS/rfsuite.user/` are preserved across suite updates.
- If a theme includes a `configure.lua` file, its configurable options (such as voltage ranges) are saved in the radio's preferences as the standard values, and a model with per-model settings switched on keeps the values it changes in its own file. See [Settings](../pages/settings/dashboard/settings.md).
- If a theme breaks while its screen is being drawn -- an error, or a screen too large for the radio to draw within its instruction limit -- the widget tries three times in a row, then shows *Dashboard error* instead of the dashboard and stops trying. Choosing another theme, changing a setting, reconnecting the flight controller or a flight phase with a screen of its own makes it try again; until then *Dashboard error* stays, which in flight can be until the end of the flight. [Adding a dashboard theme](../developer/dashboard-themes.md) says where the error is logged.

*Documented against RFSuite 0.1.7.*
