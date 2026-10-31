-- The controls the widget draws over a theme that draws its own fullscreen and binds no control
-- of its own: a way into the quick menu, a way out of fullscreen, and a way into the suite's tool.
--
-- A theme that has taken fullscreen decides which controls it shows and what they do; it binds
-- them through the `ctx` its build receives. This file is what such a screen gets when its tree
-- carries no press at all, which is always the case for a declarative theme -- the engine has
-- no way to bind a tap -- so that no fullscreen the widget puts up is without the menu and a
-- way out. Loaded only then, by the runtime's fullscreen build.
--
-- The geometry is the quick menu's: the X lands exactly where the menu's close box lands, at
-- both layout profiles (`dH > 350` is the split fullscreen_menu.lua uses), the menu control
-- sits one box to its left and the tool control one box to the left of that. The info bar can
-- put the three at the left end instead, mirrored: the X in the corner, the menu control one box
-- to its right, the tool control one further.
--
-- The tool control is also drawn on its own, on the connect splash at full screen
-- (`M.appendTool`), so the tool can be reached before the dashboard has anything to show.

local M = {}

local requireModule = (_G.rfsuite and _G.rfsuite.require) or function(path)
  local fullPath = string.sub(path, 1, 1) == "/" and path or ("/SCRIPTS/TOOLS/rfsuite-core/" .. path)
  local chunk = loadScript(fullPath, "t")
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local Views = requireModule("widgets/dashboard/views.lua")

-- The glyph opens the menu over the theme. The X is drawn on the theme, which is the whole of
-- fullscreen, so it leaves fullscreen -- where the menu's own X, drawn on a view over the
-- theme, closes that view and puts the theme back.
local AFTER_MENU = "openView:menu"
local AFTER_CLOSE = "exitFullscreen"
-- The tool runs in place of the dashboard until it is closed; see widgets/dashboard/tool_host.lua.
local AFTER_TOOL = "openTool"

local function navigate(widget, after)
  if Views and type(Views.navigate) == "function" then Views.navigate(widget, after) end
end

local function geometry(widget)
  local zone = widget.zone
  local dW = (zone and zone.w) or LCD_W or 0
  local dH = (zone and zone.h) or LCD_H or 0

  local isLarge = dH > 350
  local size = isLarge and 44 or 20
  -- The quick menu's own inset for its close box, so the X is not a pixel off the menu's.
  local margin = isLarge and 8 or 1
  return {
    isLarge = isLarge,
    size = size,
    margin = margin,
    cx = dW - size - margin,
    cy = isLarge and 8 or 1,
  }
end

-- The tool control: a button with three slider lines on it. Lines for the same reason as the
-- menu control's bars below -- a line object is not clickable, so a press on the glyph reaches
-- the button. Not drawn while the model is armed: the tool is not opened then (tool_host.lua).
local function appendToolControl(children, widget, x, y, size)
  if widget.state and widget.state.armed == true then return end
  children[#children+1] = {
    type = "button", x = x, y = y, w = size, h = size, color = COLOR_THEME_PRIMARY1 or BLACK,
    press = function() navigate(widget, AFTER_TOOL) end
  }
  local lineW = math.floor(size * 0.56)
  local thin = math.max(1, math.floor(size * 0.05))
  local knobW = math.max(2, math.floor(size * 0.12))
  local knobH = math.max(4, math.floor(size * 0.2))
  local lineX = x + math.floor((size - lineW) / 2)
  local step = math.max(knobH + 1, math.floor(size * 0.25))
  local firstY = y + math.floor(size / 2) - step
  local knobAt = { 0.7, 0.3, 0.55 }
  for i = 0, 2 do
    local lineY = firstY + i * step
    children[#children+1] = {
      type = "line", x = 0, y = 0, w = 0, h = 0,
      pts = { { lineX, lineY }, { lineX + lineW, lineY } },
      color = WHITE, thickness = thin
    }
    local knobX = lineX + math.floor(lineW * knobAt[i + 1])
    local half = math.floor(knobH / 2)
    children[#children+1] = {
      type = "line", x = 0, y = 0, w = 0, h = 0,
      pts = { { knobX, lineY - half }, { knobX, lineY + half } },
      color = WHITE, thickness = knobW
    }
  end
end

--- Append the tool control alone, in the place of the close control, for a fullscreen surface
--- that carries no other control -- the connect splash.
function M.appendTool(children, widget)
  local g = geometry(widget)
  appendToolControl(children, widget, g.cx, g.cy, g.size)
  return children
end

--- Append the tool control, the menu control and the close control to `children`, after
--- whatever is there, so they lie above it: at the right end, or mirrored at the left end where
--- `side` is "left".
function M.append(children, widget, side)
  local g = geometry(widget)
  local isLarge, size, margin = g.isLarge, g.size, g.margin
  local fontH = isLarge and 24 or 12
  local font = isLarge and MIDSIZE or SMLSIZE
  local textOffY = isLarge and -8 or -4

  -- The X in the corner, then the menu and the tool control one box inwards each.
  local step = size + margin
  local cx = (side == "left") and margin or g.cx
  if side == "left" then step = -step end
  local gx = cx - step
  local cy = g.cy

  appendToolControl(children, widget, gx - step, cy, size)

  children[#children+1] = {
    type = "button", x = gx, y = cy, w = size, h = size, color = COLOR_THEME_PRIMARY1 or BLACK,
    press = function() navigate(widget, AFTER_MENU) end
  }

  -- The three bars are LINES, and that is not a drawing preference. A `rectangle` built while
  -- the widget is fullscreen is a clickable object that passes its press to its parent
  -- (lua_lvgl_widget.cpp, LvglWidgetBox::build clears the clickable flag only for a widget that
  -- is not fullscreen), so bars drawn as boxes would lie on top of the button and swallow every
  -- press that lands on them: the control would answer around its bars and not at its centre.
  -- LVGL's line object is created not clickable, so a press on a bar reaches the button -- the
  -- same reason the quick menu's X label over its own button has always worked. The points are
  -- a plain table, not a function, so nothing here is resolved per frame.
  local barW = math.floor(size * 0.5)
  local barH = math.max(2, math.floor(size * 0.08))
  local barX = gx + math.floor((size - barW) / 2)
  local step = math.max(barH + 2, math.floor(size * 0.2))
  local barY = cy + math.floor((size - (barH + step * 2)) / 2) + math.floor(barH / 2)
  for i = 0, 2 do
    local lineY = barY + i * step
    children[#children+1] = {
      type = "line", x = 0, y = 0, w = 0, h = 0,
      pts = { { barX, lineY }, { barX + barW, lineY } },
      color = WHITE, thickness = barH
    }
  end

  children[#children+1] = {
    type = "button", x = cx, y = cy, w = size, h = size, color = COLOR_THEME_SECONDARY1 or RED,
    press = function() navigate(widget, AFTER_CLOSE) end
  }
  children[#children+1] = {
    type = "label", x = cx, y = cy + math.floor((size - fontH) / 2) + textOffY, w = size,
    text = "X", color = WHITE, align = CENTER, font = font
  }
  return children
end

-- ---------------------------------------------------------------------------
-- The info bar
-- ---------------------------------------------------------------------------
--
-- A declarative theme is laid out for the widget area of a normal screen, which lies below the
-- radio's own top bar. At full screen that top bar is gone, so the runtime lays the theme out
-- below a bar of the same kind instead (`M.barHeight`) and draws the bar with `M.appendBar`: the
-- three controls above at one end, inside the bar rather than over the theme, and readings of
-- the kind the radio's top bar showed at the other. The bar is drawn in the colour of the
-- theme's tiles, so it reads as one more tile above the grid.
--
-- What it shows is the pilot's choice on the theme's Info bar page (`M.layout`): the end the
-- controls sit at, and up to six positions, counted from the far end inwards. What does not fit
-- before the controls is left out, so nothing is drawn under them.

-- The readings are taken by `M.refresh`, which the runtime calls from the widget's own refresh
-- while the bar is up, at most once a second -- never from the bar's labels: their getters run in
-- the firmware's reactive sweep, which may read a prepared value and do nothing else. getTime()
-- counts in 10 ms ticks.
local REFRESH_TICKS = 100

-- The link item's four steps: in percent of a link quality, or in dBm where the link sensor that
-- answered is a signal strength (1RSS/2RSS, which the suite's search for `link` ends in; the
-- runtime publishes which one answered as `state.lqSource`).
local LINK_STEPS = { 1, 50, 70, 90 }
local RSSI_STEPS = { -120, -100, -85, -70 }
local RSSI_LINK_SOURCES = { ["1RSS"] = true, ["2RSS"] = true }

-- The battery symbol's segments, one lit per started fifth of the charge.
local BATTERY_SEGMENTS = 5

-- Which reading each choice needs; the refresh takes only those.
local READS = {
  clock = "clock",
  battery_icon = "battery", battery_percent = "battery", battery_volts = "battery",
  link_bars = "link", link_value = "link",
}

-- Kept once loaded; a load that failed is tried again on the next refresh.
local RadioStatus = nil

--- Take the readings `values.reads` asks for into `values`, at most once a second (`force` skips
--- that wait). Called from the widget's refresh, where probing the radio is legal.
function M.refresh(widget, values, force)
  local now = (type(getTime) == "function" and getTime()) or 0
  if not force and values.at ~= nil and now - values.at < REFRESH_TICKS and now >= values.at then return end
  values.at = now
  local reads = values.reads or {}

  if reads.clock then
    local ok, dt = false, nil
    if type(getDateTime) == "function" then ok, dt = pcall(getDateTime) end
    values.clock = (ok and type(dt) == "table")
      and string.format("%02d:%02d", dt.hour or 0, dt.min or 0) or "--:--"
  end

  if reads.battery then
    if RadioStatus == nil then RadioStatus = requireModule("lib/radio_status.lua") end
    local volts, percent, low = nil, nil, false
    if type(RadioStatus) == "table" and type(RadioStatus.txBattery) == "function" then
      local okBattery, v, p, l = pcall(RadioStatus.txBattery)
      if okBattery then volts, percent, low = v, p, l == true end
    end
    values.batteryVolts = volts and string.format("%.1fV", volts) or "-V"
    values.batteryPercent = percent and string.format("%d%%", percent) or "-%"
    values.batterySegments = percent and math.ceil(percent * BATTERY_SEGMENTS / 100) or 0
    values.batteryLow = low
  end

  if reads.link then
    local state = widget.state
    local reading = state and state.lq
    local rssi = state and type(state.lqSource) == "string" and RSSI_LINK_SOURCES[state.lqSource] == true
    local steps, limits = 0, rssi and RSSI_STEPS or LINK_STEPS
    if type(reading) == "number" and reading == reading then
      reading = math.floor(reading + 0.5)
      if not rssi then reading = math.max(0, math.min(100, reading)) end
      values.link = string.format(rssi and "%ddB" or "%d%%", reading)
      for i = 1, #limits do
        if reading >= limits[i] then steps = i end
      end
    else
      values.link = rssi and "-dB" or "-%"
    end
    values.linkSteps = steps
  end
end

local function fontHeight(font, fallback)
  if lcd and type(lcd.sizeText) == "function" then
    local ok, _, h = pcall(lcd.sizeText, "0", font)
    if ok and type(h) == "number" and h > 0 then return h end
  end
  return fallback
end

local function textWidth(text, font, fallback)
  if lcd and type(lcd.sizeText) == "function" then
    local ok, w = pcall(lcd.sizeText, text, font)
    if ok and type(w) == "number" and w > 0 then return w end
  end
  return fallback
end

--- The height of the bar at this zone: the controls with their top inset above and below.
function M.barHeight(widget)
  local g = geometry(widget)
  return g.size + 2 * g.cy
end

--- The area a declarative theme is laid out in at full screen: the zone below the bar. The whole
--- zone where the bar would leave nothing.
function M.bodyZone(widget)
  local zone = widget.zone or {}
  local barH = M.barHeight(widget)
  local h = (zone.h or LCD_H or 0) - barH
  if h <= 0 then return zone end
  return { x = zone.x or 0, y = (zone.y or 0) + barH, w = zone.w or LCD_W or 0, h = h }
end

-- The theme configuration keys of the Info bar page (app/pages/settings/dashboard/fields_form.lua,
-- which offers the same choices with the same defaults): the end the controls sit at, and what
-- each position shows, position 1 at the far end. A key never stored, or holding a choice this
-- file does not know, takes its default.
local SIDE_PREF = "bar_buttons"
local SLOT_DEFAULTS = { "battery_icon", "clock", "link_bars", "none", "none", "none" }

--- The end the controls sit at ("left" or "right") and the choices of the positions that show
--- something, from the far end inwards.
function M.layout(themeConfig)
  local config = type(themeConfig) == "table" and themeConfig or {}
  local side = (config[SIDE_PREF] == "right") and "right" or "left"
  local items = {}
  for i = 1, #SLOT_DEFAULTS do
    local choice = config["bar_slot" .. i]
    if READS[choice] == nil and choice ~= "none" then choice = SLOT_DEFAULTS[i] end
    if READS[choice] ~= nil then items[#items + 1] = choice end
  end
  return side, items
end

--- Append the bar for a declarative theme's full-screen build: what its configuration chooses,
--- in the colour of its tiles (`engine.tileColor(build)`).
function M.appendThemeBar(children, widget, build, engine)
  local tileColor = engine and type(engine.tileColor) == "function" and engine.tileColor(build) or nil
  local side, items = M.layout(widget.state and widget.state.themeConfig)
  return M.appendBar(children, widget, items, tileColor, side)
end

--- Append the info bar to `children`, after whatever is there: its background in `bgcolor`
--- (the colour of the theme's tiles; the radio's title bar colour when that is not known), the
--- three controls of `M.append` at the `side` end ("left"; anything else is the right), and the
--- `items` from the other end inwards, as far as they fit.
function M.appendBar(children, widget, items, bgcolor, side)
  local g = geometry(widget)
  local isLarge = g.isLarge
  local dW = (widget.zone and widget.zone.w) or LCD_W or 0
  local barH = M.barHeight(widget)
  local font = isLarge and 0 or SMLSIZE
  local textH = fontHeight(font, isLarge and 24 or 12)
  local textY = math.floor((barH - textH) / 2)
  local gap = isLarge and 16 or 6
  local barColor = bgcolor or COLOR_THEME_SECONDARY1 or BLACK
  -- Dark text on a white bar, light text on anything else -- the pairing the themes use.
  local textColor = (barColor == WHITE) and BLACK or WHITE
  local warnColor = COLOR_THEME_WARNING or RED

  local list = type(items) == "table" and items or {}

  -- The readings the getters below return, kept on the widget: the runtime refreshes them from
  -- the widget's refresh while the bar is up, and a rebuild of the scene starts from the last.
  local values = widget._fullscreenBarValues
  if values == nil then
    values = {}
    widget._fullscreenBarValues = values
  end
  local reads = {}
  for i = 1, #list do
    local read = READS[list[i]]
    if read then reads[read] = true end
  end
  values.reads = reads
  -- A rebuild keeps the last readings and the once-a-second limit; only a reading the bar now
  -- shows and has never taken is taken at once.
  local missing = (reads.clock and values.clock == nil) or (reads.battery and values.batteryVolts == nil)
    or (reads.link and values.link == nil)
  M.refresh(widget, values, missing)

  children[#children+1] = {
    type = "rectangle", x = 0, y = 0, w = dW, h = barH, filled = true, color = barColor
  }

  -- Everything drawn on the bar is a label or a line: a line object takes no press, so nothing
  -- here can catch a tap meant for the screen behind it.
  local stepW = isLarge and 5 or 2
  local stepGap = isLarge and 3 or 1
  local glyphH = math.max(4, textH - (isLarge and 4 or 2))
  local glyphBottom = textY + math.floor((textH + glyphH) / 2)
  local battH = math.max(6, math.floor(glyphH * 0.7))
  local battW = battH * 2
  local battNub = isLarge and 3 or 2
  local battLine = isLarge and 2 or 1

  local function label(x, w, getText, color)
    children[#children+1] = {
      type = "label", x = x, y = textY, w = w + 4, font = font, color = color or textColor,
      text = getText
    }
  end

  local function lowColor()
    return values.batteryLow and warnColor or textColor
  end

  local function widthOf(choice)
    if choice == "clock" then return textWidth("00:00", font, isLarge and 70 or 30) end
    if choice == "battery_icon" then return battW + battNub end
    if choice == "battery_percent" then return textWidth("100%", font, isLarge and 56 or 26) end
    if choice == "battery_volts" then return textWidth("00.0V", font, isLarge and 70 or 32) end
    if choice == "link_bars" then return #LINK_STEPS * (stepW + stepGap) - stepGap end
    if choice == "link_value" then return textWidth("-100dB", font, isLarge and 72 or 32) end
    return 0
  end

  local function drawBattery(x)
    -- An outline with a terminal on the right and five segments inside: the lit ones in the text
    -- colour (the warning colour while the radio's battery is low), the others in the bar's own.
    local top = glyphBottom - battH
    local right = x + battW
    local half = math.floor(battLine / 2)
    local outline = {
      { { x, top + half }, { right, top + half } },
      { { x, glyphBottom - half }, { right, glyphBottom - half } },
      { { x + half, top }, { x + half, glyphBottom } },
      { { right - half, top }, { right - half, glyphBottom } },
    }
    for i = 1, #outline do
      children[#children+1] = {
        type = "line", x = 0, y = 0, w = 0, h = 0, thickness = battLine, color = textColor,
        pts = outline[i]
      }
    end
    local nubX = right + math.floor(battNub / 2)
    local nubH = math.max(2, math.floor(battH * 0.4))
    local nubTop = top + math.floor((battH - nubH) / 2)
    children[#children+1] = {
      type = "line", x = 0, y = 0, w = 0, h = 0, thickness = battNub, color = textColor,
      pts = { { nubX, nubTop }, { nubX, nubTop + nubH } }
    }
    local inset = battLine + 1
    local segW = math.max(1, math.floor((battW - 2 * inset - (BATTERY_SEGMENTS - 1)) / BATTERY_SEGMENTS))
    for s = 1, BATTERY_SEGMENTS do
      local segX = x + inset + (s - 1) * (segW + 1) + math.floor(segW / 2)
      children[#children+1] = {
        type = "line", x = 0, y = 0, w = 0, h = 0, thickness = segW,
        pts = { { segX, top + inset }, { segX, glyphBottom - inset } },
        color = function()
          if (values.batterySegments or 0) < s then return barColor end
          return values.batteryLow and warnColor or textColor
        end
      }
    end
  end

  local function drawLinkBars(x)
    for s = 1, #LINK_STEPS do
      local h = math.max(2, math.floor(glyphH * s / #LINK_STEPS))
      local lineX = x + (s - 1) * (stepW + stepGap) + math.floor(stepW / 2)
      children[#children+1] = {
        type = "line", x = 0, y = 0, w = 0, h = 0, thickness = stepW,
        pts = { { lineX, glyphBottom - h }, { lineX, glyphBottom } },
        color = function()
          return (values.linkSteps or 0) >= s and textColor or (COLOR_THEME_DISABLED or textColor)
        end
      }
    end
  end

  local function draw(choice, x, w)
    if choice == "clock" then
      label(x, w, function() return values.clock end)
    elseif choice == "battery_icon" then
      drawBattery(x)
    elseif choice == "battery_percent" then
      label(x, w, function() return values.batteryPercent end, lowColor)
    elseif choice == "battery_volts" then
      label(x, w, function() return values.batteryVolts end, lowColor)
    elseif choice == "link_bars" then
      drawLinkBars(x)
    elseif choice == "link_value" then
      label(x, w, function() return values.link end)
    end
  end

  -- The readings fill from the far end towards the controls, which take three boxes and their
  -- insets at the other end; the first that would reach them ends the row.
  local pad = g.margin + (isLarge and 4 or 2)
  local controlsW = 3 * (g.size + g.margin) + g.margin
  if side == "left" then
    local x = dW - pad
    for i = 1, #list do
      local w = widthOf(list[i])
      if x - w < controlsW then break end
      draw(list[i], x - w, w)
      x = x - w - gap
    end
  else
    local x = pad
    for i = 1, #list do
      local w = widthOf(list[i])
      if x + w > dW - controlsW then break end
      draw(list[i], x, w)
      x = x + w + gap
    end
  end

  return M.append(children, widget, side)
end

return M
