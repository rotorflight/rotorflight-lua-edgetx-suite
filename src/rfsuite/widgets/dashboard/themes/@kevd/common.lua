--[[
  Copyright (C) 2025 Rotorflight Project
  GPLv3 — https://www.gnu.org/licenses/gpl-3.0.en.html

  @Kevd -- the palette, the framed tile, and the arithmetic that sizes a value to its tile.
  After the Ethos suite's kevd theme: gauges standing on the page, the small readings in tiles
  with a light frame, the governor in a red one.
]] --

if type(_G) == "table" and type(_G.__rfsuiteThemeKevdCommonModule) == "table" then
  return _G.__rfsuiteThemeKevdCommonModule
end

local Common = {}

local function rgb(hex, fallback)
  if lcd and type(lcd.RGB) == "function" then
    local ok, col = pcall(lcd.RGB, math.floor(hex / 65536) % 256, math.floor(hex / 256) % 256, hex % 256)
    if ok and col then return col end
  end
  return fallback
end

-- Ethos' dark palette, which the kevd theme was drawn in.
Common.BG = rgb(0x1B1F24, BLACK)
Common.PANEL = rgb(0x0E0F10, BLACK)
Common.FRAME = rgb(0xBDBDBD, WHITE)
Common.TRACK = rgb(0x2C333B, COLOR_THEME_SECONDARY2)
Common.TITLE = rgb(0xC8C8C8, COLOR_THEME_DISABLED)
Common.TEXT = WHITE
Common.OK = rgb(0x8CC21E, GREEN)
Common.WARN = rgb(0xE3A300, YELLOW)
Common.CRIT = rgb(0xE52521, RED)
Common.PURPLE = rgb(0x8B008B, COLOR_THEME_FOCUS)
Common.MAX = rgb(0xF0A000, YELLOW)


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
  return { padding = padding, colW = track(w, cols), rowH = track(h, rows), zoneH = h, lowres = w <= 480 or h <= 176 }
end

function Common.span(grid, colspan, rowspan)
  return colspan * grid.colW + (colspan - 1) * grid.padding, rowspan * grid.rowH + (rowspan - 1) * grid.padding
end

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

--- A reading in a framed tile, its caption at the foot: `chars` is how many characters the value
--- is wide at most, `maxIndex` how large its font may grow. The value is centred above the
--- caption -- objects/common.lua's defaultValueY puts a bottom-titled value at 35 % of the tile
--- less 4, and the caption 24 px above the foot, which is what the offset is taken from.
function Common.tile(grid, box, chars, maxIndex)
  local w, h = Common.span(grid, box.colspan or 1, box.rowspan or 1)
  local avail = h - 24
  local font, lineH = Common.fit(w - 12, avail - 2, chars or 5, maxIndex or 4)
  box.bgcolor = box.bgcolor or Common.PANEL
  box.bordercolor = box.bordercolor or Common.FRAME
  box.borderwidth = box.borderwidth or (grid.lowres and 2 or 3)
  box.rounded = box.rounded or 6
  box.titlepos = "bottom"
  box.titlealign = CENTER
  box.titlefont = box.titlefont or SMLSIZE
  box.titlecolor = box.titlecolor or Common.TITLE
  box.textcolor = box.textcolor or Common.TEXT
  box.valuealign = box.valuealign or CENTER
  box.font = box.font or font
  local base = math.max(8, math.floor(h * 0.35)) - 4
  box.value_offset_y = math.floor((avail - lineH) / 2) + 2 - base
  return box
end

--- An arc gauge standing on the page, its value centred in the arc and the highest value of the
--- flight under it. The arc's geometry is objects/gauge.lua's renderArc, so the value can be
--- sized to the inside of the arc.
function Common.arc(grid, box, chars)
  local w, h = Common.span(grid, box.colspan or 1, box.rowspan or 1)
  local panelH = math.max(40, h - 8 - 22)
  local radius = math.max(18, math.floor(math.min(w - 14, panelH - 10) / 2))
  local thickness = math.max(5, math.floor(radius * 0.18))
  local inner = 2 * (radius - thickness) - 8
  local font, lineH = Common.fit(inner, inner, chars or 4, 4)
  local lift = (grid.zoneH >= 400) and 8 or 0
  box.type, box.subtype = "gauge", "arc"
  box.bgcolor = box.bgcolor == nil and Common.BG or box.bgcolor
  box.titlepos = "bottom"
  box.titlecolor = Common.TITLE
  box.textcolor = Common.TEXT
  box.fillbgcolor = Common.TRACK
  box.value_font = font
  box.value_center_lift = lift
  box.value_offset_y = math.floor(thickness * 1.3) - math.floor(lineH / 2)
  if box.arcmax then
    box.maxprefix = "Max: "
    box.maxtextcolor = Common.MAX
    box.maxposition = "bottom"
    box.maxalign = CENTER
    box.maxpaddingleft, box.maxpaddingright = 0, 0
    box.maxpaddingbottom = 26
    box.maxfont = grid.lowres and SMLSIZE or 0
  end
  return box
end

if type(_G) == "table" then
  _G.__rfsuiteThemeKevdCommonModule = Common
end

return Common
