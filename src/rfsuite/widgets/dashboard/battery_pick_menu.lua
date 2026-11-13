-- The battery picker the dashboard shows in fullscreen when the flight log is on and
-- the pilot has not answered it yet for this connection.
--
-- Every dashboard theme shows this picker, in the menu style the pilot has chosen: a grid of cards
-- here, or the rolling lists of menu_roll.lua. A free-form theme could still replace this view's
-- look, and nothing else, so its close box is always there.
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
local Look = requireModule("widgets/dashboard/menu_look.lua")
local Log = requireModule("lib/log.lua")

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

-- The most packs drawn as cards. Every card is built at once, about 300 instructions each, and a widget
-- call is stopped at 20 000: past this the rolling list, which draws only the rows on screen, is what
-- can show them all, whichever style the pilot has chosen.
local CARDS_MAX = 40

local function rolling(widget)
  if Look.style(widget) == "rotary" then return true end
  local pick = widget.state and widget.state.batteryPick or nil
  return type(pick) == "table" and type(pick.candidates) == "table" and #pick.candidates > CARDS_MAX
end

local function rollModule()
  local Roll = requireModule("widgets/dashboard/menu_roll.lua")
  if type(Roll) == "table" and type(Roll.build) == "function" then return Roll end
  if Log and type(Log.emit) == "function" then
    Log.emit("rfsuite.widget", "rotary picker did not load, drawing the cards", "warn")
  end
  return nil
end

--- Rebuilt when what the flight controller reported arrives or is replaced, which decides what can
--- be picked and which profile a pack names, and when the pack in force or the list changes. A write's
--- outcome rebuilds it on its own (views.lua, `reporter`).
function M.renderKey(widget)
  local state = widget and widget.state or nil
  if state == nil then return "" end
  local pick = state.batteryPick
  local key = tostring(state.battery_config) .. "|" .. tostring(type(pick) == "table" and pick.selectedId or "")
    .. "|" .. tostring(type(pick) == "table" and pick.candidates or "")
  if rolling(widget) then
    local Roll = rollModule()
    if Roll then key = key .. "|" .. Roll.renderKey(widget) end
  end
  return key
end

-- One pack as a card. A pack that cannot be picked is still a button: the wheel walks the buttons and
-- the grid scrolls the focused one into view, so a box in its place could not be reached and read. Its
-- press does nothing, because the menu's `run` refuses it.
local function packCard(nodes, widget, entry, option, x, y, w, h, p, colors, nameH)
  local isCurrent = option.current == true
  local bColor = isCurrent and colors.accent or colors.fill
  local tColor = isCurrent and colors.onAccent or colors.text
  if option.selectable == false then
    bColor, tColor = colors.panel, isCurrent and colors.muted or colors.disabled
  end
  nodes[#nodes + 1] = {
    type = "button", x = x, y = y, w = w, h = h, color = bColor,
    press = function() run(widget, entry, option) end,
  }
  local pad = p.isLarge and 8 or 3
  local subH = Look.lineHeight(SMLSIZE, p.smallH)
  -- The two lines stand in the middle of the card, whatever height the room gave it.
  local top = y + math.max(0, math.floor((h - nameH - subH) / 2))
  nodes[#nodes + 1] = {
    type = "label", x = x, y = top, w = w, text = option.label, color = tColor, align = CENTER, font = p.rowFont,
  }
  local detail = option.detail or ""
  if type(option.details) == "table" then
    detail = Menu.fitFirst(option.details, SMLSIZE, w - 2 * pad) or detail
  end
  nodes[#nodes + 1] = {
    type = "label", x = x, y = top + nameH, w = w,
    text = detail, color = tColor, align = CENTER, font = SMLSIZE,
  }
end

function M.build(children, widget)
  local t = (widget.i18n and type(widget.i18n.t) == "function") and widget.i18n.t or function(k, f) return f or k end

  if rolling(widget) then
    local Roll = rollModule()
    local Sources = Roll and requireModule("widgets/dashboard/menu_roll_sources.lua") or nil
    if Roll and type(Sources) == "table" then
      Roll.build(children, widget, function() return Sources.pick(widget, t) end, Look.colors(widget))
      return
    end
  end
  -- Drawn as buttons: a rolling picker from before has stopped answering the wheel.
  local Views = requireModule("widgets/dashboard/views.lua")
  if type(Views) == "table" and type(Views.dropRoll) == "function" then Views.dropRoll(widget, "battery_pick") end

  local dW, dH = widget.zone.w, widget.zone.h
  local entry = record(widget)
  local p, colors, contentY = Look.frame(children, widget, t("widgets.dashboard.battery_pick_title", "WHICH BATTERY?"),
    function() if entry ~= nil then run(widget, entry, entry.close) end end)

  -- The packs, and NO BATTERY apart from them: it is laid out on a row of its own below.
  local packs, none = {}, nil
  local options = entry and entry.options() or {}
  for i = 1, #options do
    if options[i].none then none = options[i] else packs[#packs + 1] = options[i] end
  end

  local gap = p.gapY
  local nameH = Look.lineHeight(p.rowFont, p.fontH)
  local subH = Look.lineHeight(SMLSIZE, p.smallH)
  local textPad = p.isLarge and 8 or 3
  -- A card is never lower than the close box, so every target on the picker is at least its size.
  local minBtnH = math.max(nameH + subH + 2 * textPad, p.closeSize)
  local noneH = math.max(nameH + 2 * textPad, p.closeSize)

  -- The line that says how a write went, where a pick writes at all.
  local bottom = dH - p.paddingX
  if entry ~= nil and entry.writesProfile == true then
    local footH = nameH
    local status = Menu.pickStatusText and Menu.pickStatusText(widget, t) or ""
    children[#children + 1] = {
      type = "label", x = p.paddingX, y = bottom - footH, w = dW - 2 * p.paddingX,
      text = status, color = colors.text, align = CENTER, font = p.titleFont,
    }
    bottom = bottom - footH - gap
  end

  -- NO BATTERY has the foot row to itself, reserved before the packs are laid out, so it can never be
  -- the entry that falls off the screen.
  local noneY = bottom - noneH
  local gridH = noneY - gap - contentY
  local fullW = dW - 2 * p.paddingX
  local cols = (#packs >= 2 and dW >= 400) and 2 or 1
  local btnW = math.floor((fullW - (cols - 1) * gap) / cols)

  local rowsFit = (gridH >= minBtnH) and math.floor((gridH + gap) / (minBtnH + gap)) or 0
  local rowsNeeded = math.ceil(#packs / cols)
  local rows = math.min(rowsNeeded, rowsFit)
  local btnH = minBtnH
  if rows > 0 then
    -- Capped, or two packs become slabs as tall as the picker.
    btnH = math.max(minBtnH, math.min(math.floor((gridH - (rows - 1) * gap) / rows), 2 * minBtnH))
  end

  if rowsNeeded <= rowsFit then
    for i = 1, #packs do
      local row, col = math.floor((i - 1) / cols), (i - 1) % cols
      packCard(children, widget, entry, packs[i], p.paddingX + col * (btnW + gap), contentY + row * (btnH + gap),
        btnW, btnH, p, colors, nameH)
    end
  elseif gridH > 0 then
    -- More packs than the room holds: the grid scrolls in a box, which the firmware moves by a swipe
    -- and by the wheel, whose focus goes from button to button and brings the focused one into view.
    -- Every pack can be reached. The strip at the right is the scroll bar's.
    local barW = 2 * gap
    local cellW = math.floor((fullW - barW - (cols - 1) * gap) / cols)
    local cells = {}
    for i = 1, #packs do
      local row, col = math.floor((i - 1) / cols), (i - 1) % cols
      packCard(cells, widget, entry, packs[i], 1 + col * (cellW + gap), 1 + row * (btnH + gap),
        cellW, btnH, p, colors, nameH)
    end
    children[#children + 1] = {
      type = "box", x = p.paddingX - 1, y = contentY - 1, w = fullW + 1, h = gridH + 1, children = cells,
    }
  end

  if none ~= nil then
    local noneCurrent = none.current == true
    children[#children + 1] = {
      type = "button", x = p.paddingX, y = noneY, w = fullW, h = noneH, color = colors.fill,
      press = function() run(widget, entry, none) end,
    }
    children[#children + 1] = {
      type = "label", x = p.paddingX, y = noneY + math.floor((noneH - p.fontH) / 2) + p.btnTextOffY, w = fullW,
      text = none.label, color = noneCurrent and colors.accentInk or colors.text, align = CENTER, font = p.titleFont,
    }
  end
end

return M
