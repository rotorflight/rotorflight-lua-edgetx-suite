-- What the widget's own menu pages have in common: the quick menu, the battery picker, the battery
-- profile page and the erase question. Their colours, the two layout profiles and the frame around
-- a page -- background, header, title, close box -- are written here once.
--
-- The colours are the suite's two schemes (lib/color_schemes.lua), under the names of what they are
-- used for on these pages; a change of a value there reaches every page here. They do not come from
-- the radio theme, for the reason a dashboard theme paints its own surface: a radio theme is chosen
-- for the radio's own screens, and on an arbitrary one the text and the buttons have no guaranteed
-- contrast. Every dashboard theme shows these pages the same.
--
-- The pilot's choice is `general.color_scheme` in the radio's preferences, on Settings > General >
-- Appearance; anything else reads as light.

local M = {}

local requireModule = (_G.rfsuite and _G.rfsuite.require) or function(path)
  local fullPath = string.sub(path, 1, 1) == "/" and path or (_G.rfsuite.paths.core .. "/" .. path)
  local chunk = loadScript(fullPath, "t")
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local Schemes = requireModule("lib/color_schemes.lua")

M.KEY = "color_scheme"

-- The name each of these pages reads a colour by, and the scheme's role it is.
M.ROLES = {
  bg = "page",
  panel = "card",
  off = "raised",
  head = "header",
  headText = "headerText",
  text = "text",
  muted = "muted",
  disabled = "disabled",
  accent = "accent",
  onAccent = "onAccent",
  fill = "selection",
  close = "error",
  onClose = "onError",
  rule = "rule",
}

-- The rotary style's outermost rows, a step paler than `muted`. Not a role of the schemes.
local FAR = { light = 0x969DA3, dark = 0x68737D }

--- The menu style a widget's preferences name, `general.menu_style`: "rotary", else "card".
function M.style(widget)
  local prefs = widget and widget.preferences or nil
  local general = type(prefs) == "table" and prefs.general or nil
  if type(general) == "table" and general.menu_style == "rotary" then return "rotary" end
  return "card"
end

-- The last scheme resolved. A build of a page asks once; the value changes only when the pilot saves
-- the settings page, and two tables of these colours are not worth keeping side by side.
local lastName, lastColors = nil, nil

--- The colours of the scheme the pilot has chosen, as this widget's preferences have it.
function M.colors(widget)
  local prefs = widget and widget.preferences or nil
  local general = type(prefs) == "table" and prefs.general or nil
  local name = Schemes.name(type(general) == "table" and general[M.KEY] or nil)
  if name ~= lastName then
    local scheme = Schemes.colors(name)
    local colors = {}
    for own, role in pairs(M.ROLES) do colors[own] = scheme[role] end
    colors.far = lcd.RGB(FAR[name])
    lastName, lastColors = name, colors
    local Log = requireModule("lib/log.lua")
    if Log and type(Log.emit) == "function" then Log.emit("rfsuite.widget", "menu colors: " .. name, "debug") end
  end
  return lastColors
end

-- The two layout profiles: the large high-resolution radio, and the standard one. Placement figures:
-- `fontH` is where a line goes, not the face's height (see M.lineHeight).
local LARGE = {
  isLarge = true, headerH = 60, fontH = 24, smallH = 16, closeSize = 44, contentGap = 20,
  gapY = 10, paddingX = 15, edge = 8, headTextOffY = -6, closeTextOffY = -8, btnTextOffY = -8,
}
local SMALL = {
  isLarge = false, headerH = 22, fontH = 12, smallH = 10, closeSize = 20, contentGap = 5,
  gapY = 6, paddingX = 5, edge = 1, headTextOffY = -2, closeTextOffY = -4, btnTextOffY = -4,
}

--- The layout profile for a zone of height `dH`.
function M.profile(dH)
  local p = (dH > 350) and LARGE or SMALL
  -- The faces are the firmware's constants, read when asked for rather than when this file loads.
  p.titleFont = p.isLarge and MIDSIZE or SMLSIZE
  p.rowFont = p.titleFont
  return p
end

--- The height the firmware lays a line of `font` out in, or `fallback` where it cannot say. The
--- profile's `fontH` is a placement figure: MIDSIZE on an 800x480 radio is taller than it, and a line
--- placed `fontH` under another runs into it there.
function M.lineHeight(font, fallback)
  if lcd and type(lcd.sizeText) == "function" then
    local ok, _, h = pcall(lcd.sizeText, "Ag", font)
    if ok and type(h) == "number" and h > 0 then return h end
  end
  return fallback
end

--- A page's frame: the background, the header with its title and close box, and a back box where
--- `backPress` is given. Answers the layout profile, the colours and where the content starts.
function M.frame(children, widget, title, closePress, backPress)
  local dW, dH = widget.zone.w, widget.zone.h
  local p = M.profile(dH)
  local colors = M.colors(widget)

  children[#children + 1] = { type = "rectangle", x = 0, y = 0, w = dW, h = dH, color = colors.bg, filled = true }
  children[#children + 1] = { type = "rectangle", x = 0, y = 0, w = dW, h = p.headerH, color = colors.head, filled = true }
  children[#children + 1] = { type = "rectangle", x = 0, y = p.headerH, w = dW, h = 1, color = colors.rule, filled = true }

  local boxY = math.floor((p.headerH - p.closeSize) / 2)
  local labelY = boxY + math.floor((p.closeSize - p.fontH) / 2) + p.closeTextOffY
  local titleX = p.paddingX
  if backPress ~= nil then
    children[#children + 1] = {
      type = "button", x = p.edge, y = boxY, w = p.closeSize, h = p.closeSize, color = colors.fill, press = backPress,
    }
    children[#children + 1] = {
      type = "label", x = p.edge, y = labelY, w = p.closeSize, text = "<", color = colors.text, align = CENTER, font = p.titleFont,
    }
    titleX = p.edge + p.closeSize + p.paddingX
  end
  children[#children + 1] = {
    type = "label", x = titleX, y = math.floor((p.headerH - p.fontH) / 2) + p.headTextOffY,
    w = dW - titleX - p.closeSize - 2 * p.paddingX, text = title or "", color = colors.headText, align = LEFT, font = p.titleFont,
  }

  local closeX = dW - p.closeSize - p.edge
  children[#children + 1] = {
    type = "button", x = closeX, y = boxY, w = p.closeSize, h = p.closeSize, color = colors.close, press = closePress,
  }
  children[#children + 1] = {
    type = "label", x = closeX, y = labelY, w = p.closeSize, text = "X", color = colors.onClose, align = CENTER, font = p.titleFont,
  }
  return p, colors, p.headerH + p.contentGap
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
