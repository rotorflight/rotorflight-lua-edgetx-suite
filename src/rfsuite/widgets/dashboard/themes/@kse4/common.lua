--[[
  Copyright (C) 2025 Rotorflight Project
  GPLv3 — https://www.gnu.org/licenses/gpl-3.0.en.html

  @KSE4 and @KSE5 -- what the two themes share: the palette, the tile, and the arithmetic that
  sizes a tile's value to the tile. After Kyle Stacy's KSE4 and KSE5 widgets
  (github.com/kylestacy2/KSE-Dashboards), by way of the Ethos suite's kse4 and kse5 themes.

  Every tile is a dark panel with a hairline frame, its caption small at the top. The value is
  centred in what the caption leaves, in the largest font that fits the tile at the size the
  widget is drawn, so the same layout reads in a quarter zone and at full screen.
]] --

if type(_G) == "table" and type(_G.__rfsuiteThemeKse4CommonModule) == "table" then
  return _G.__rfsuiteThemeKse4CommonModule
end

local Common = {}

local function rgb(hex, fallback)
  if lcd and type(lcd.RGB) == "function" then
    local ok, col = pcall(lcd.RGB, math.floor(hex / 65536) % 256, math.floor(hex / 256) % 256, hex % 256)
    if ok and col then return col end
  end
  return fallback
end

-- The Ethos themes take these from the radio's theme; EdgeTX themes are light and dark alike, so
-- the KSE look is fixed here: Ethos' dark palette.
Common.BG = BLACK
Common.PANEL = rgb(0x141414, BLACK)
Common.FRAME = rgb(0x30363E, COLOR_THEME_SECONDARY2)
Common.TRACK = rgb(0x2A2F36, COLOR_THEME_SECONDARY2)
Common.TITLE = rgb(0xB4B4B4, COLOR_THEME_DISABLED)
Common.TEXT = WHITE
Common.OK = rgb(0x8CC21E, GREEN)
Common.WARN = rgb(0xE3A300, YELLOW)
Common.CRIT = rgb(0xE52521, RED)
Common.ACCENT = rgb(0xBEBEBE, WHITE)


-- Font metrics of the two font sets the firmware ships: lrg on an 800x480 screen, std on the
-- smaller ones (bin/dashboard/edgetx_font_widths.lua). `line` is the label height, `digit` the
-- advance of a digit, which is what a tile's value is mostly made of.
local METRICS = {
  lrg = { { SMLSIZE, 23, 10 }, { 0, 31, 13 }, { MIDSIZE, 42, 19 }, { DBLSIZE, 55, 25 }, { XXLSIZE, 90, 40 } },
  std = { { SMLSIZE, 17, 7 }, { 0, 22, 9 }, { MIDSIZE, 29, 13 }, { DBLSIZE, 40, 18 }, { XXLSIZE, 66, 28 } },
}

local function fontSet()
  return ((tonumber(LCD_W) or 800) >= 700) and METRICS.lrg or METRICS.std
end

-- The grid the theme is about to be laid out on, at the size the widget is drawn: the zone, or
-- the full screen. A build without a zone -- the settings page enumerating the tiles -- gets an
-- 800 x 458 one, which changes no tile's identity.
function Common.grid(state, cols, rows, padding)
  local w = tonumber(state and state.zoneW) or 0
  local h = tonumber(state and state.zoneH) or 0
  if w <= 0 or h <= 0 then w, h = 800, 458 end
  local function track(total, count)
    return math.max(0, math.floor((total - (count - 1) * padding) / count))
  end
  return { cols = cols, rows = rows, padding = padding, colW = track(w, cols), rowH = track(h, rows), lowres = w <= 480 or h <= 176,
    cfg = type(state) == "table" and type(state.themeConfig) == "table" and state.themeConfig or {} }
end

-- Keep in step with @kse4/configure.lua.
Common.FUEL_DEFAULTS = { fuel_warn = 45, fuel_crit = 25 }

--- The fuel levels the fuel readings turn amber and red at, from the theme's settings.
function Common.fuelLevels(grid)
  local cfg = grid and grid.cfg or {}
  local warn = tonumber(cfg.fuel_warn) or Common.FUEL_DEFAULTS.fuel_warn
  local crit = tonumber(cfg.fuel_crit) or Common.FUEL_DEFAULTS.fuel_crit
  if crit > warn then crit, warn = warn, crit end
  return warn, crit
end

function Common.span(grid, colspan, rowspan)
  local w = colspan * grid.colW + (colspan - 1) * grid.padding
  local h = rowspan * grid.rowH + (rowspan - 1) * grid.padding
  return w, h
end

-- The caption's height: the small font and the 4 px drawContainer puts above it.
function Common.titleH()
  return fontSet()[1][2] + 4
end

--- The largest font, no larger than `maxIndex` (1 small .. 5 extra large), whose line fits `h`
--- and whose `chars` digits fit `w`.
function Common.fit(w, h, chars, maxIndex)
  local set = fontSet()
  local best = set[1]
  for i = 1, math.min(maxIndex or #set, #set) do
    local m = set[i]
    if m[2] <= h and m[3] * chars <= w then best = m end
  end
  return best[1], best[2]
end

function Common.lineH(font)
  local set = fontSet()
  for i = 1, #set do
    if set[i][1] == font then return set[i][2] end
  end
  return set[2][2]
end

--- The value_offset_y that centres a label `lineH` high in the part of a tile `h` high below a
--- caption `top` high (top = 0 for a tile without one). The value's own position is
--- objects/common.lua's defaultValueY; this moves it from there.
function Common.centreOffset(h, top, lineH, titlepos)
  local base
  if titlepos == "bottom" then
    base = math.max(8, math.floor(h * 0.35)) - 4
  else
    base = math.max(14, math.floor(h * 0.45))
  end
  local avail = h - top
  if titlepos == "bottom" then
    return math.floor((avail - lineH) / 2) - base
  end
  return top + math.floor((avail - lineH) / 2) - base
end

--- A value tile: `chars` is how many characters its value is wide at most, `maxIndex` how large
--- its font may grow. Fills in the caption, colours, font and offset; geometry stays the box's.
function Common.tile(grid, box, chars, maxIndex)
  local w, h = Common.span(grid, box.colspan or 1, box.rowspan or 1)
  local top = box.title and Common.titleH() or 0
  local font, lineH = Common.fit(w - 12, h - top - 4, chars or 5, maxIndex or 4)
  box.bgcolor = box.bgcolor or Common.PANEL
  box.bordercolor = box.bordercolor or Common.FRAME
  box.borderwidth = box.borderwidth or 1
  box.rounded = box.rounded or (grid.lowres and 4 or 6)
  box.titlepos = box.titlepos or "top"
  box.titlealign = box.titlealign or LEFT
  box.titlefont = box.titlefont or SMLSIZE
  box.titlecolor = box.titlecolor or Common.TITLE
  box.textcolor = box.textcolor or Common.TEXT
  box.valuealign = box.valuealign or CENTER
  box.font = box.font or font
  local valueH = Common.lineH(box.font) or lineH
  if h - top < math.floor(valueH / 2) then
    -- No room under the caption: the value goes on the caption's line, beside it.
    top = 0
  end
  box.value_offset_y = Common.centreOffset(h, top, valueH, box.titlepos)
  return box
end

--- The fuel bar across a tile: the value centred on the bar, coloured by what is left.
function Common.fuelBar(grid, box)
  local w, h = Common.span(grid, box.colspan or 1, box.rowspan or 1)
  -- The bar fills the tile below the caption. objects/gauge.lua starts a titled bar's panel 20 px
  -- down and ends it 2 px short of the bottom; the paddings are measured from there.
  local pad = grid.lowres and 5 or 8
  local padTop = math.max(0, Common.titleH() + 2 - 20)
  local barH = math.max(12, (h - 18 - 4) - padTop - pad)
  local font, lineH = Common.fit(w - 12, barH, 4, 4)
  box.gaugepaddingtop, box.gaugepaddingbottom = padTop, pad
  box.gaugepaddingleft, box.gaugepaddingright = pad, pad
  box.type, box.subtype = "gauge", "bar"
  box.source = box.source or "smartfuel"
  box.unit, box.transform, box.min, box.max = "%", "floor", 0, 100
  box.title = box.title or "@i18n(widgets.dashboard.battery):upper()@"
  box.titlepos = "top"
  box.valuealign = CENTER
  box.valuepaddingleft = 0
  box.valuepaddingtop = math.floor((8 - lineH) / 2)
  box.font = font
  box.fillbgcolor = Common.TRACK
  box.fillcolor = Common.OK
  local warn, crit = Common.fuelLevels(grid)
  box.thresholds = {
    { value = crit, fillcolor = Common.CRIT },
    { value = warn, fillcolor = Common.WARN },
    { value = 100000, fillcolor = Common.OK },
  }
  return Common.tile(grid, box, 4, 4)
end

if type(_G) == "table" then
  _G.__rfsuiteThemeKse4CommonModule = Common
end

return Common
