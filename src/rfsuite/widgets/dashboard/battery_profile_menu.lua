-- The battery profile page the dashboard shows in fullscreen, opened from the BATTERY PROFILE row of
-- the quick menu.
--
-- It is the page the widget draws for every theme that does not draw its own -- a free-form theme
-- may replace this view's look, and nothing else. The same layout profile as fullscreen_menu.lua,
-- so a radio at either resolution gets the sizes it already gets from the quick menu.
--
-- What the page offers and what each press does is not decided here. It is the quick menu's
-- `battery_profile` record (fullscreen_menu.lua): one option per profile the flight controller
-- carries, the capacity as its label and the cells and warning voltage as its `detail`. A press
-- runs the option through the menu's `run`, with a reporter, and the page stays up: the line at
-- its foot says how the write went. Before the connection is ready and while the model is armed
-- the profiles are drawn without a press and the line says why; the profile in force stays marked.
--
-- The back box returns to the quick menu, the close box leaves fullscreen, and RTN does what the
-- back box does.

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

local Menu = requireModule("widgets/dashboard/fullscreen_menu.lua")
local Views = requireModule("widgets/dashboard/views.lua")

local ID = "battery_profile"

-- The record this view draws, or nil where the menu module could not be loaded.
local function record(widget)
  if Menu and type(Menu.entry) == "function" then return Menu.entry(widget, ID) end
  return nil
end

local function navigate(widget, after)
  if Views and type(Views.navigate) == "function" then Views.navigate(widget, after) end
end

-- The height the firmware lays a line of `font` out in, or `fallback` where it cannot say. The
-- layout profile's `fontH` is a placement figure, not the face's height: MIDSIZE on an 800x480
-- radio is taller than it, and a line placed `fontH` under a capacity runs into it there.
local function lineHeight(font, fallback)
  if lcd and type(lcd.sizeText) == "function" then
    local ok, _, h = pcall(lcd.sizeText, "Ag", font)
    if ok and type(h) == "number" and h > 0 then return h end
  end
  return fallback
end

--- What RTN does while the page is on top: what its back box does.
function M.back(widget)
  navigate(widget, "closeView")
end

--- Rebuilt when the profile in force moves, when the model arms or disarms and when the connection
--- becomes ready or is lost; a new outcome of a write rebuilds the page on its own (views.lua,
--- `reporter`).
function M.renderKey(widget)
  local state = widget and widget.state or {}
  return tostring(state.batteryProfile) .. (state.armed == true and "|a" or "|")
    .. (state.connectionReady == true and "r" or "")
end

function M.build(children, widget)
  local dW = widget.zone.w
  local dH = widget.zone.h
  local dX = 0
  local dY = 0

  local t = (widget.i18n and type(widget.i18n.t) == "function") and widget.i18n.t or function(k, f) return f or k end

  local bg_color = COLOR_THEME_PRIMARY3 or BLACK
  if bg_color == BLACK and lcd and type(lcd.RGB) == "function" then
    bg_color = lcd.RGB(40, 40, 40)
  end
  local btn_color = COLOR_THEME_PRIMARY1 or BLACK
  local accent_color = COLOR_THEME_SECONDARY1 or WHITE
  local off_color = (lcd and type(lcd.RGB) == "function") and lcd.RGB(90, 90, 90) or btn_color

  children[#children+1] = {
    type = "rectangle", x=dX, y=dY, w=dW, h=dH, color=bg_color, filled=true
  }

  -- The same two layout profiles fullscreen_menu.lua uses: a large high-resolution radio, and
  -- the standard 480x272 one.
  local isLarge = dH > 350

  local headerH, titleFont, rowFont, fontH, smallH, closeSize, contentGap, gapY, paddingX
  local headTextOffY, closeTextOffY

  if isLarge then
    headerH = 60
    titleFont = MIDSIZE
    rowFont = MIDSIZE
    fontH = 24
    smallH = 16
    closeSize = 44
    contentGap = 20
    gapY = 10
    paddingX = 15
    headTextOffY = -6
    closeTextOffY = -8
  else
    headerH = 22
    titleFont = SMLSIZE
    rowFont = SMLSIZE
    fontH = 12
    smallH = 10
    closeSize = 20
    contentGap = 5
    gapY = 6
    paddingX = 5
    headTextOffY = -2
    closeTextOffY = -4
  end

  local entry = record(widget)
  local armed = widget.state and widget.state.armed == true
  -- The runtime sets `state.connectionReady` together with the widget's own `connectionReady`,
  -- which a profile's press asks (fullscreen_menu.lua): before it is ready a press queues nothing.
  local notReady = not (widget.state and widget.state.connectionReady == true)
  local inert = armed or notReady

  -- The header: the back box, the title, the close box.
  children[#children+1] = {
    type = "rectangle", x=dX, y=dY, w=dW, h=headerH, color=btn_color, filled=true
  }
  local bx = dX + (isLarge and 8 or 1)
  local by = dY + math.floor((headerH - closeSize)/2)
  children[#children+1] = {
    type = "button", x=bx, y=by, w=closeSize, h=closeSize, color=btn_color,
    press = function() navigate(widget, "closeView") end
  }
  children[#children+1] = {
    type = "label", x=bx, y=by + math.floor((closeSize - fontH)/2) + closeTextOffY, w=closeSize,
    text="<", color=WHITE, align=CENTER, font=titleFont
  }
  local titleX = bx + closeSize + paddingX
  children[#children+1] = {
    type = "label", x=titleX, y=dY + math.floor((headerH - fontH)/2) + headTextOffY, w=dW - titleX - closeSize - 2 * paddingX,
    text=(entry and entry.title) or t("widgets.dashboard.battery_profile", "BATTERY PROFILE"),
    color=WHITE, align=LEFT, font=titleFont
  }
  local cx = dX + dW - closeSize - (isLarge and 8 or 1)
  children[#children+1] = {
    type = "button", x=cx, y=by, w=closeSize, h=closeSize, color=COLOR_THEME_SECONDARY1 or RED,
    press = function() navigate(widget, "done") end
  }
  children[#children+1] = {
    type = "label", x=cx, y=by + math.floor((closeSize - fontH)/2) + closeTextOffY, w=closeSize,
    text="X", color=WHITE, align=CENTER, font=titleFont
  }

  -- The foot line: why nothing can be pressed before the connection is ready or while the model
  -- is armed, else how the last write from this page went, where there was one. Not ready wins:
  -- the arm state is the last one read and is not cleared when the link drops.
  local foot
  if notReady then
    foot = entry and entry.notReadyNote or ""
  elseif armed then
    foot = entry and entry.armedNote or ""
  else
    local status = Views and type(Views.status) == "function" and Views.status(widget, ID) or nil
    if status == "busy" then
      foot = t("widgets.dashboard.battery_profile_busy", "SENDING...")
    elseif status == "ok" then
      foot = t("widgets.dashboard.battery_profile_ok", "SET AND SAVED")
    elseif status == "failed" then
      foot = t("widgets.dashboard.battery_profile_failed", "NOT SAVED")
    end
  end
  local bottom = dY + dH - paddingX
  local footY = bottom - fontH
  children[#children+1] = {
    type = "label", x=dX + paddingX, y=footY + headTextOffY, w=dW - 2 * paddingX,
    text=foot or "", color=WHITE, align=CENTER, font=titleFont
  }

  -- The profiles: three columns from five up on a wide zone, so six are two rows; two below that,
  -- and one on a narrow zone. The rows share the room between the header and the foot line.
  local options = (entry ~= nil and type(entry.options) == "function") and entry.options() or {}
  if #options == 0 then return end
  local cols = 2
  if dW < 200 then cols = 1 end
  if #options > 4 and dW >= 400 then cols = 3 end
  local rows = math.ceil(#options / cols)
  local labelH = lineHeight(rowFont, fontH)
  local listY = dY + headerH + contentGap
  local btnW = math.floor((dW - paddingX * (cols + 1)) / cols)
  local btnH = math.floor((footY - gapY - listY - (rows - 1) * gapY) / rows)

  for i = 1, #options do
    local option = options[i]
    local x = dX + paddingX + ((i - 1) % cols) * (btnW + paddingX)
    local y = listY + math.floor((i - 1) / cols) * (btnH + gapY)
    local isCurrent = option.current == true
    local bColor = isCurrent and accent_color or (inert and off_color or btn_color)
    local tColor = isCurrent and BLACK or WHITE

    -- Not ready or armed, a profile is a filled box rather than a button: nothing to press.
    if inert then
      children[#children+1] = { type = "rectangle", x=x, y=y, w=btnW, h=btnH, color=bColor, filled=true }
    else
      children[#children+1] = {
        type = "button", x=x, y=y, w=btnW, h=btnH, color=bColor,
        press = function()
          local report = Views and type(Views.reporter) == "function" and Views.reporter(widget, ID) or nil
          Menu.run(widget, entry, option, "none", report)
        end
      }
    end

    local hasDetail = option.detail ~= nil and option.detail ~= ""
    local blockH = labelH + (hasDetail and smallH or 0)
    local top = y + math.max(0, math.floor((btnH - blockH) / 2))
    children[#children+1] = {
      type = "label", x=x, y=top + headTextOffY, w=btnW,
      text=option.label, color=tColor, align=CENTER, font=rowFont
    }
    if hasDetail then
      children[#children+1] = {
        type = "label", x=x, y=top + labelH, w=btnW,
        text=option.detail, color=tColor, align=CENTER, font=SMLSIZE
      }
    end
  end
end

return M
