-- The colours of the widget's own quick menu and of the pages it opens: the battery picker, the
-- battery profile page and the erase question.
--
-- Two fixed schemes instead of the radio theme's colours, for the reason a dashboard theme paints
-- its own surface: a radio theme is chosen for the radio's own screens, and on an arbitrary one the
-- text and the buttons here have no guaranteed contrast. The values are the Rotorflight
-- Configurator's light and dark themes; `fill` is the selected row's blue of the in-flight tuning
-- list, and its light counterpart.
--
-- The pilot's choice is `general.color_scheme` in the radio's preferences, on Settings > General >
-- Appearance; anything else reads as light. A theme that draws these views itself draws them in
-- its own colours and does not read this.

local M = {}

M.KEY = "color_scheme"
M.DEFAULT = "light"

local SCHEMES = {
  light = {
    bg       = { 241, 242, 243 },
    text     = { 19, 21, 22 },
    muted    = { 84, 92, 100 },
    fill     = { 207, 229, 244 },
    accent   = { 0, 123, 199 },
    onAccent = { 255, 255, 255 },
    off      = { 227, 230, 232 },
    panel    = { 255, 255, 255 },
    close    = { 197, 38, 27 },
    onClose  = { 255, 255, 255 },
  },
  dark = {
    bg       = { 16, 18, 19 },
    text     = { 244, 245, 246 },
    muted    = { 172, 179, 185 },
    fill     = { 30, 52, 67 },
    accent   = { 60, 168, 236 },
    onAccent = { 16, 21, 24 },
    off      = { 37, 41, 44 },
    panel    = { 26, 28, 31 },
    close    = { 243, 113, 104 },
    onClose  = { 16, 21, 24 },
  },
}

-- What a role falls back to on a firmware build without lcd.RGB.
local function fallback(role)
  if role == "text" or role == "onAccent" or role == "onClose" then return WHITE end
  if role == "close" then return COLOR_THEME_SECONDARY1 or RED end
  if role == "muted" or role == "off" then return COLOR_THEME_DISABLED or DARKGREY end
  if role == "accent" then return COLOR_THEME_SECONDARY1 or BLUE end
  if role == "fill" then return COLOR_THEME_PRIMARY1 or BLACK end
  return COLOR_THEME_PRIMARY3 or BLACK
end

local function resolve(name)
  local colors = {}
  for role, value in pairs(SCHEMES[name]) do
    local color = nil
    if lcd and type(lcd.RGB) == "function" then
      local ok, c = pcall(lcd.RGB, value[1], value[2], value[3])
      if ok then color = c end
    end
    if color == nil then color = fallback(role) end
    colors[role] = color
  end
  return colors
end

-- The name a stored value stands for.
function M.scheme(value)
  if type(value) == "string" and SCHEMES[value] ~= nil then return value end
  return M.DEFAULT
end

-- The last scheme resolved. A build of the menu asks once; the value changes only when the pilot
-- saves the settings page, and two tables of ten colours are not worth keeping side by side.
local lastName, lastColors = nil, nil

--- The colours of the scheme the pilot has chosen, as this widget's preferences have it.
function M.colors(widget)
  local prefs = widget and widget.preferences or nil
  local general = type(prefs) == "table" and prefs.general or nil
  local name = M.scheme(type(general) == "table" and general[M.KEY] or nil)
  if name ~= lastName then
    lastName, lastColors = name, resolve(name)
  end
  return lastColors
end

--- A box outline drawn as four lines: a line is created not clickable, so the outline can lie over
--- a button without taking its press, where a rectangle over a button would take it.
function M.outline(children, x, y, w, h, color, thickness)
  local x1, y1 = x + w - 1, y + h - 1
  local function line(ax, ay, bx, by)
    children[#children + 1] = { type = "line", x = 0, y = 0, w = 0, h = 0,
      pts = { { ax, ay }, { bx, by } }, color = color, thickness = thickness or 2 }
  end
  line(x, y, x1, y)
  line(x, y1, x1, y1)
  line(x, y, x, y1)
  line(x1, y, x1, y1)
end

return M
