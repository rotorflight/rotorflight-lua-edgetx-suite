-- The battery picker the dashboard shows in fullscreen when the flight log is on and
-- the pilot has not answered it yet for this connection.
--
-- It is the picker the widget draws for every theme that does not draw its own -- a free-form
-- theme may replace this view's look, and nothing else -- so its close box is always there. What
-- is drawn here is deliberately the same layout profile as fullscreen_menu.lua, so that a radio
-- at either resolution gets rows of the size it already gets from the quick menu.
--
-- What the picker offers and what each press does is not decided here. It is the quick menu's
-- `battery_pick` record (fullscreen_menu.lua): its options are the picks, one per pack and then
-- NO BATTERY, and its `close` ends the prompt. This file draws that record, and a press runs the
-- option through the menu's `run`, which does the work and then the action that follows it.
--
-- Every string the tree carries is built while the menu is built -- the record's options carry
-- theirs already. Nothing below is a closure, so nothing below runs in the reactive sweep.

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

-- The record this view draws, or nil where the menu module could not be loaded.
local function record(widget)
  if Menu and type(Menu.entry) == "function" then return Menu.entry(widget, "battery_pick") end
  return nil
end

local function run(widget, entry, option)
  if entry ~= nil then Menu.run(widget, entry, option) end
end

--- What RTN does while the picker is on top: exactly what its close box does. A plain
--- `closeView` would leave `pending` standing, and the picker's own condition would open it
--- again on the next pass.
function M.back(widget)
  local entry = record(widget)
  if entry ~= nil then run(widget, entry, entry.close) end
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

  children[#children+1] = {
    type = "rectangle", x=dX, y=dY, w=dW, h=dH, color=bg_color, filled=true
  }

  -- The same two layout profiles fullscreen_menu.lua uses: a large high-resolution radio, and
  -- the standard 480x272 one.
  local isLarge = dH > 350

  local headerH, titleFont, rowFont, fontH, smallH, closeSize, contentGap, btnH, gapY, paddingX
  local headTextOffY, closeTextOffY

  if isLarge then
    headerH = 60
    titleFont = MIDSIZE
    rowFont = MIDSIZE
    fontH = 24
    smallH = 16
    closeSize = 44
    contentGap = 20
    btnH = 62
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
    btnH = 34
    gapY = 6
    paddingX = 5
    headTextOffY = -2
    closeTextOffY = -4
  end

  children[#children+1] = {
    type = "rectangle", x=dX, y=dY, w=dW, h=headerH, color=btn_color, filled=true
  }
  children[#children+1] = {
    type = "label", x=dX + paddingX, y=dY + math.floor((headerH - fontH)/2) + headTextOffY, w=dW-60,
    text=t("widgets.dashboard.battery_pick_title", "WHICH BATTERY?"), color=WHITE, align=LEFT, font=titleFont
  }

  local entry = record(widget)

  local cx = dX + dW - closeSize - (isLarge and 8 or 1)
  local cy = dY + math.floor((headerH - closeSize)/2)
  children[#children+1] = {
    type = "button", x=cx, y=cy, w=closeSize, h=closeSize, color=COLOR_THEME_SECONDARY1 or RED,
    press = function() if entry ~= nil then run(widget, entry, entry.close) end end
  }
  children[#children+1] = {
    type = "label", x=cx, y=cy + math.floor((closeSize - fontH)/2) + closeTextOffY, w=closeSize,
    text="X", color=WHITE, align=CENTER, font=titleFont
  }

  -- The packs, and NO BATTERY apart from them: it is laid out on a row of its own below.
  local packs, none = {}, nil
  local options = entry and entry.options() or {}
  for i = 1, #options do
    if options[i].none then none = options[i] else packs[#packs+1] = options[i] end
  end

  -- Two columns from four packs up, so a pilot with a handful of them still sees the whole
  -- registry without scrolling. One column below that keeps the names readable.
  local cols = (#packs >= 4 and dW >= 400) and 2 or 1
  local btnW = math.floor((dW - paddingX*(cols+1)) / cols)
  local listY = dY + headerH + contentGap
  local bottom = dY + dH - paddingX

  -- NO BATTERY has the foot row to itself, reserved before the packs are laid out, so it can
  -- never be the entry that falls off the screen. The pack grid is cut, not scrolled: packs past
  -- what fits above it are not drawn.
  local noneY = bottom - btnH
  local gridBottom = noneY - gapY

  for i = 1, #packs do
    local option = packs[i]
    local row = math.floor((i-1)/cols)
    local col = (i-1)%cols
    local bx = dX + paddingX + col*(btnW+paddingX)
    local by = listY + row*(btnH+gapY)
    if by + btnH > gridBottom then break end

    local isCurrent = option.current == true
    local bColor = isCurrent and accent_color or btn_color
    local tColor = isCurrent and BLACK or WHITE

    children[#children+1] = {
      type = "button", x=bx, y=by, w=btnW, h=btnH, color=bColor,
      press = function() run(widget, entry, option) end
    }
    children[#children+1] = {
      type = "label", x=bx, y=by + (isLarge and 8 or 3), w=btnW,
      text=option.label, color=tColor, align=CENTER, font=rowFont
    }
    children[#children+1] = {
      type = "label", x=bx, y=by + btnH - smallH - (isLarge and 8 or 3), w=btnW,
      text=option.detail, color=tColor, align=CENTER, font=SMLSIZE
    }
  end

  if none ~= nil then
    local noneW = math.floor(dW - paddingX * 2)
    children[#children+1] = {
      type = "button", x=dX + paddingX, y=noneY, w=noneW, h=btnH, color=btn_color,
      press = function() run(widget, entry, none) end
    }
    children[#children+1] = {
      type = "label", x=dX + paddingX, y=noneY + math.floor((btnH - fontH)/2), w=noneW,
      text=none.label, color=WHITE, align=CENTER, font=titleFont
    }
  end
end

return M
