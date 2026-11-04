-- The quick menu as two rolling lists: the menu on the left, what the selected entry leads to on
-- the right. The current row always stands in the larger middle slot, and the lists end where they
-- end: no wrap, nothing drawn twice, free slots stay empty.
--
-- Which entries there are, whether one is offered and what a press does are the quick menu's own
-- records (fullscreen_menu.lua). This file only draws them and moves through them.
--
--   wheel    moves the list that has the focus; the left one shows on the right what its current
--            entry leads to
--   press    runs the left entry, or moves the focus right where it has a choice or a question;
--            on the right it finishes, and the menu closes
--   RTN      from the right returns left, from the left closes the menu
--   tap      on a row: what turning there and pressing does
--
-- The wheel. A Lua widget never receives EVT_ROTARY_*: the encoder moves LVGL's focus along the
-- scene's focusable objects in creation order, wrapping, and the fullscreen widget itself is one of
-- them. A press is only bound on a button, and no button can leave that walk. So a one-row
-- viewport holds a ladder of buttons, each a row high: a detent moves the focus to the next one,
-- LVGL scrolls it into view, and `scrolled` says where it went. The same mechanism as the in-flight
-- tuning surface (inflight/input.lua), without what that one needs for its value mode.
--
-- There are two ladders in the walk, the forward one first and the reverse one last, so that a
-- detent either way from the widget lands in one of them and everything else lies between. A
-- detent back onto the widget itself reports nothing: the row shown stays one detent behind until
-- the next detent, which is counted from the ladder position and so loses nothing in the sum. To
-- keep the focus off that step while turning back and forth, the scene is built again once the
-- wheel has rested, which puts the focus back on the widget with the selection kept.

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
local Look = requireModule("widgets/dashboard/menu_look.lua")
local Log = requireModule("lib/log.lua")

local TAG = "rfsuite.widget.roll"

local function trace(msg)
  if Log and type(Log.wanted) == "function" and Log.wanted("trace") then
    Log.emit(TAG, msg, "trace")
  end
end

-- Rows in each ladder. The scene is built again before a ladder runs out, so the walk never reaches
-- the rows and controls between the two; what is left past that absorbs a fast turn.
local LADDER = 12
local LADDER_MARGIN = 3

-- The slots either side of the middle one.
local REACH = 2

-- Ten milliseconds a tick: how long the wheel has to rest before the scene is built again.
local REST_TICKS = 60

local function rollOf(widget)
  if not (Views and type(Views.session) == "function") then return nil end
  local session = Views.session(widget)
  local roll = session.roll
  if roll == nil then
    roll = { side = "left", left = 1, right = 1, position = 0, epoch = 0 }
    session.roll = roll
  end
  return roll
end

-- The left list: the pilot's entries that are offered now, BATTERY PROFILE last where it is.
local function leftList(widget, entries)
  local out = {}
  for i = 1, #entries do
    local entry = entries[i]
    if entry.id ~= "battery_profile" and Menu.visible(widget, entry) then out[#out + 1] = entry end
  end
  local profile = Menu.entry(widget, "battery_profile")
  if profile ~= nil and Menu.visible(widget, profile) then out[#out + 1] = profile end
  return out
end

-- The options the entry leads to, or nil where it runs at once.
local function optionsOf(widget, entry)
  if entry == nil or entry.view == nil or type(entry.options) ~= "function" then return nil end
  local options = entry.options(widget)
  if type(options) ~= "table" or #options == 0 then return nil end
  return options
end

-- The question's two answers, in the order the wheel meets them, the safe one first: the focus
-- starts on it, so a double press on the row cannot answer for the pilot.
local function answers(confirm)
  return {
    { label = confirm.cancelLabel or "CANCEL", cancel = true },
    { label = confirm.confirmLabel or "OK", agree = true },
  }
end

local function clamp(value, count)
  if count < 1 then return 1 end
  if value < 1 then return 1 end
  if value > count then return count end
  return value
end

-- The ladder position is left alone here: detents can still arrive on the standing scene until the
-- new one is built, and M.build starts the count over.
local function rebuild(widget, roll)
  roll.epoch = roll.epoch + 1
  roll.steppedAt = nil
  if Views and type(Views.invalidate) == "function" then Views.invalidate(widget) end
end

local function currentIndex(options)
  for i = 1, #options do
    if options[i].current == true then return i end
  end
  return 1
end

-- What the right list holds now: the question, else what the left entry leads to. Asked again only
-- when the left entry changes.
local function rightList(widget, roll)
  if roll.side == "right" and roll.question ~= nil then return roll.questionList end
  if roll.rightFor ~= roll.left then
    roll.rightFor = roll.left
    roll.rightOptions = optionsOf(widget, roll.leftList and roll.leftList[roll.left])
    roll.right = roll.rightOptions and currentIndex(roll.rightOptions) or 1
  end
  return roll.rightOptions
end

local function moveTo(widget, roll, side)
  roll.side = side
  if side == "left" then roll.question, roll.questionList = nil, nil end
  trace("side " .. side)
  rebuild(widget, roll)
end

-- ---------------------------------------------------------------------------
-- What the pilot does
-- ---------------------------------------------------------------------------

-- A detent, or several where the wheel outran the callbacks. The sum is taken from the ladder
-- position, so a detent that went unreported on the widget is counted by the next one.
local function stepped(widget, roll, delta)
  if delta == 0 then return end
  if roll.side == "left" then
    local before = roll.left
    roll.left = clamp(before + delta, roll.leftList and #roll.leftList or 0)
    trace("left " .. tostring(before) .. " -> " .. tostring(roll.left))
  else
    local list = rightList(widget, roll)
    local before = roll.right
    roll.right = clamp(before + delta, list and #list or 0)
    trace("right " .. tostring(before) .. " -> " .. tostring(roll.right))
  end
  roll.steppedAt = getTime()
  local reach = math.abs(roll.position)
  if reach >= LADDER - LADDER_MARGIN then rebuild(widget, roll) end
end

local function finishRight(widget, roll)
  local list = rightList(widget, roll)
  local choice = list and list[roll.right] or nil
  if choice == nil then return end
  if roll.question ~= nil then
    if choice.cancel then
      moveTo(widget, roll, "left")
      return
    end
    local entry = roll.question
    trace("question answered " .. tostring(entry.id))
    Menu.perform(widget, entry, nil, entry.after)
    return
  end
  local entry = roll.leftList and roll.leftList[roll.left] or nil
  if entry == nil then return end
  if entry.id == "battery_profile" then
    -- The list stays up until the write has been answered: a failed write must not pass unseen.
    local base = Views.reporter(widget, entry.id)
    local session = Views.session(widget)
    local function report(value)
      base(value)
      trace("profile write " .. tostring(value))
      -- A chain with a failed message stays failed whatever the last answer says, and a reply to a
      -- write from before the menu was closed says nothing about this menu.
      if value == "ok" and widget._viewStack == session and session.roll == roll
        and Views.status(widget, entry.id) == "ok" then
        Views.navigate(widget, "done")
      end
    end
    Menu.run(widget, entry, choice, "none", report)
    return
  end
  Menu.run(widget, entry, choice)
end

--- A press of the wheel, or a tap on the middle row: what the current row does.
function M.press(widget)
  local roll = rollOf(widget)
  if roll == nil then return end
  if roll.side == "right" then
    finishRight(widget, roll)
    return
  end
  local entry = roll.leftList and roll.leftList[roll.left] or nil
  if entry == nil then return end
  if type(entry.confirm) == "table" then
    roll.question, roll.questionList = entry, answers(entry.confirm)
    roll.right = 1
    moveTo(widget, roll, "right")
    return
  end
  local options = optionsOf(widget, entry)
  if options ~= nil then
    roll.rightFor, roll.rightOptions = roll.left, options
    roll.right = currentIndex(options)
    moveTo(widget, roll, "right")
    return
  end
  trace("run " .. tostring(entry.id))
  Menu.run(widget, entry)
end

--- RTN: from the right back to the left, from the left out of the menu. Answers true.
function M.back(widget)
  local roll = rollOf(widget)
  if roll ~= nil and roll.side == "right" then
    moveTo(widget, roll, "left")
    return true
  end
  if Views.top(widget) == nil then
    Views.navigate(widget, "done")
  else
    Views.navigate(widget, "closeView")
  end
  return true
end

-- A tap on a row: the row becomes the current one, and it does what a press does. A tap on the
-- list that does not have the focus moves the focus there first.
local function tapped(widget, side, offset)
  local roll = rollOf(widget)
  if roll == nil then return end
  if side == "left" then
    local list = roll.leftList
    local index = roll.left + offset
    if list == nil or list[index] == nil then return end
    if roll.side ~= "left" then roll.side, roll.question, roll.questionList = "left", nil, nil end
    roll.left = index
  else
    if roll.side ~= "right" then return end
    local list = rightList(widget, roll)
    local index = roll.right + offset
    if list == nil or list[index] == nil then return end
    roll.right = index
  end
  -- A touch takes native focus out of the ladder, and a build gives it back.
  rebuild(widget, roll)
  M.press(widget)
end

-- ---------------------------------------------------------------------------
-- The ladders
-- ---------------------------------------------------------------------------

-- One viewport. The forward ladder starts on the spare row above its first button and scrolls
-- down, the reverse one on the spare row under its last and scrolls up; the detents are then
-- simply the distance from there, on either side of the widget.
local function viewport(widget, roll, windows, name, other, children, x, y, w, h, color, radius)
  local spare = (name == "reverse") and LADDER * h or 0
  local window = { y = spare, spare = spare }
  windows[name] = window
  local rows = {}
  local function press() M.press(widget) end
  if name == "forward" then
    rows[1] = { type = "rectangle", x = 0, y = 0, w = 1, h = 1, color = color }
    for i = 1, LADDER do
      rows[#rows + 1] = { type = "button", x = 0, y = i * h, w = w, h = h, borderPad = 0, text = "", color = color, cornerRadius = radius, press = press }
    end
  else
    for i = LADDER, 1, -1 do
      rows[#rows + 1] = { type = "button", x = 0, y = (LADDER - i) * h, w = w, h = h, borderPad = 0, text = "", color = color, cornerRadius = radius, press = press }
    end
    rows[#rows + 1] = { type = "rectangle", x = 0, y = LADDER * h, w = 1, h = 1, color = color }
  end
  children[#children + 1] = {
    type = "box", x = x, y = y, w = w, h = h, borderPad = 0,
    scrollDir = (lvgl and lvgl.SCROLL_VER) or 12, scrollBar = false, children = rows,
    scrollTo = function() return 0, window.y end,
    scrolled = function(sx, sy)
      -- Acknowledge the reset below; a programmatic scroll is not a detent.
      if window.pending ~= nil and sy == window.pending then
        window.pending = nil
        return
      end
      if sy == window.y then return end
      window.y = sy
      -- A finger dragging the list, or LVGL's elastic overscroll: not a move to a whole row.
      if sx ~= 0 or sy % h ~= 0 then return end
      local position
      if name == "forward" then position = math.floor(sy / h) else position = math.floor(sy / h) - LADDER end
      local delta = position - roll.position
      roll.position = position
      -- Coming back into this ladder must report again, so the other one starts over.
      local inactive = windows[other]
      if inactive ~= nil and inactive.y ~= inactive.spare then
        inactive.y = inactive.spare
        inactive.pending = inactive.spare
      end
      stepped(widget, roll, delta)
    end,
  }
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

--- Part of the view's key: the epoch moves when the scene has to be built again, and it moves here
--- when the wheel has rested, the one place that is asked on every pass while the menu is up.
function M.renderKey(widget)
  local session = widget._viewStack
  local roll = session and session.roll or nil
  if roll == nil then return "" end
  if roll.steppedAt ~= nil and getTime() - roll.steppedAt >= REST_TICKS then
    roll.epoch = roll.epoch + 1
    roll.steppedAt = nil
  end
  return tostring(roll.epoch)
end

-- One row of a list, as text read when it is drawn: the rows do not move, what they say does.
local function itemAt(roll, side, offset, widget)
  if side == "left" then
    local list = roll.leftList
    return list and list[roll.left + offset] or nil
  end
  local list = rightList(widget, roll)
  return list and list[roll.right + offset] or nil
end

local function rowText(roll, side, offset, widget)
  return function()
    local item = itemAt(roll, side, offset, widget)
    if item == nil then return "" end
    return item.title or item.label or ""
  end
end

-- What a current row says under its name: an option's detail, the blackbox's fill.
local function subText(roll, side, widget, fillFormat)
  -- Asked on every pass the menu is up, and a row's second line only changes with the row.
  local lastItem, lastText = nil, ""
  return function()
    local item = itemAt(roll, side, 0, widget)
    if item == lastItem then return lastText end
    lastItem, lastText = item, ""
    if item == nil then return lastText end
    if item.detail ~= nil then
      lastText = item.detail
    elseif type(item.info) == "function" then
      local percent = Menu.fillPercent(item)
      if percent ~= nil then lastText = string.format(fillFormat, percent) end
    end
    return lastText
  end
end

-- The middle row's face for a list: the large one where every name in it fits the width, else the
-- face under it, the same for the whole list so a row does not change size as it comes to the middle.
local function middleFace(list, large, small, maxW)
  if type(list) ~= "table" or not (lcd and type(lcd.sizeText) == "function") then return large end
  for i = 1, #list do
    local ok, w = pcall(lcd.sizeText, list[i].title or list[i].label or "", large)
    if ok and type(w) == "number" and w > maxW then return small end
  end
  return large
end

local function indexOfEntry(list, entry)
  if entry == nil then return nil end
  for i = 1, #list do
    if list[i].id == entry.id then return i end
  end
  return nil
end

-- An option is a pack or a profile by its id, and NO BATTERY by its mark.
local function indexOfOption(list, option)
  if list == nil or option == nil then return nil end
  for i = 1, #list do
    local candidate = list[i]
    if (option.none == true and candidate.none == true) or (option.id ~= nil and candidate.id == option.id) then return i end
  end
  return nil
end

--- Draw the menu. `entries` is the list the menu was asked to draw.
function M.build(children, widget, entries, colors, t)
  local roll = rollOf(widget)
  if roll == nil then return end

  -- The scene is built again whenever the wheel rests, and the lists are made afresh with it, for
  -- what they say about the profile in force. The pilot's place in them goes by what the row IS: an
  -- entry can come or go above it, and the same number can then be another entry.
  local before = roll.leftList and roll.leftList[roll.left] or nil
  local beforeOption = (roll.question == nil and roll.rightOptions ~= nil and roll.rightFor == roll.left)
    and roll.rightOptions[roll.right] or nil
  roll.leftList = leftList(widget, entries)
  trace("left list " .. tostring(#roll.leftList))
  local found = indexOfEntry(roll.leftList, before)
  if found ~= nil then
    roll.left = found
    if roll.rightOptions ~= nil and beforeOption ~= nil then
      roll.rightFor = found
      roll.rightOptions = optionsOf(widget, roll.leftList[found])
      local place = indexOfOption(roll.rightOptions, beforeOption)
      if place ~= nil then
        roll.right = place
      else
        -- The option the pilot was on has gone. Another one must not take its place under the same
        -- press: the focus goes back to the left, and the list starts over on the one in force.
        roll.side = "left"
        roll.right = roll.rightOptions and currentIndex(roll.rightOptions) or 1
      end
    else
      roll.rightFor, roll.rightOptions = nil, nil
    end
    -- A question stands, in what the row says now.
    if roll.question ~= nil then
      roll.question = roll.leftList[found]
      if type(roll.question.confirm) == "table" then
        roll.questionList = answers(roll.question.confirm)
      else
        roll.side, roll.question, roll.questionList = "left", nil, nil
      end
    end
  else
    -- The row the pilot was on has gone: the model armed, or the link dropped.
    roll.left = clamp(roll.left, #roll.leftList)
    roll.side, roll.question, roll.questionList = "left", nil, nil
    roll.rightFor, roll.rightOptions = nil, nil
  end
  roll.position, roll.steppedAt = 0, nil
  if roll.side == "right" and rightList(widget, roll) == nil then
    roll.side, roll.question, roll.questionList = "left", nil, nil
  end

  local W, H = widget.zone.w, widget.zone.h
  local large = H > 350
  local headH = large and 60 or 36
  local pad = large and 14 or 7
  local gap = large and 6 or 3
  local closeSize = large and 44 or 28
  local radius = large and 10 or 7
  local thickness = large and 3 or 2
  -- The faces' heights as the firmware lays them out, for placing only.
  local midFont, nearFont, farFont = MIDSIZE, _G.STDSIZE or 0, SMLSIZE
  local midH_, nearH, farH = large and 31 or 24, large and 23 or 17, large and 17 or 13

  children[#children + 1] = { type = "rectangle", x = 0, y = 0, w = W, h = H, color = colors.bg, filled = true }

  local top, bottom = headH + pad, H - pad
  local colW = math.floor((W - 3 * pad) / 2)
  local leftX, rightX = pad, pad + colW + pad
  local slots = 2 * REACH + 1

  -- The rows share the height, the middle one taller than the others.
  local avail = bottom - top - (slots - 1) * gap
  local rowH = math.floor(avail / (slots - 1 + (large and 1.75 or 1.65)))
  local midH = avail - (slots - 1) * rowH
  local midY = top + REACH * (rowH + gap)
  local activeX = (roll.side == "right") and rightX or leftX

  local function slotY(offset)
    if offset < 0 then return midY + offset * (rowH + gap) end
    if offset == 0 then return midY end
    return midY + midH + gap + (offset - 1) * (rowH + gap)
  end

  -- The right list's preview has no button under its middle row: nothing there can be pressed yet.
  if roll.side == "left" and rightList(widget, roll) ~= nil then
    children[#children + 1] = { type = "rectangle", x = rightX, y = midY, w = colW, h = midH, color = colors.off, filled = true, rounded = radius }
  end

  children[#children + 1] = { type = "rectangle", x = pad + colW + math.floor(pad / 2), y = top, w = 1, h = bottom - top,
    color = colors.rule, filled = true }

  local windows = {}

  -- In the walk: the forward ladder, the header's close box, the rows a finger taps, the reverse
  -- ladder. Everything a pilot reads is created after the ladders, which puts it over them.
  viewport(widget, roll, windows, "forward", "reverse", children, activeX, midY, colW, midH, colors.fill, radius)

  children[#children + 1] = { type = "rectangle", x = 0, y = 0, w = W, h = headH, color = colors.head, filled = true }
  children[#children + 1] = {
    type = "label", x = pad, y = math.floor((headH - midH_) / 2), w = math.floor(W / 2), font = large and MIDSIZE or nearFont,
    text = t("widgets.dashboard.quick_settings", "QUICK SETTINGS"), color = colors.headText, align = LEFT,
  }
  local closeX, closeY = W - closeSize - pad, math.floor((headH - closeSize) / 2)
  children[#children + 1] = {
    type = "button", x = closeX, y = closeY, w = closeSize, h = closeSize, color = colors.close, cornerRadius = radius,
    text = "X", textColor = colors.onClose,
    press = function() Views.navigate(widget, "done") end,
  }

  -- A press needs a button, and a button keeps the firmware's border whatever colour it is given. These
  -- rows are a list and not a set of buttons, so the button lies under one thick line in the background
  -- colour: a line is created not clickable, so it hides the button without taking its press.
  local function tapRow(side, colX, offset)
    local h = (offset == 0) and midH or rowH
    local y = slotY(offset)
    children[#children + 1] = {
      type = "button", x = colX, y = y, w = colW, h = h, borderPad = 0, text = "", cornerRadius = radius,
      color = (offset == 0) and colors.off or colors.bg,
      press = function() tapped(widget, side, offset) end,
      -- A slot with no row in it stays empty, and out of the wheel's walk as well.
      visible = function() return itemAt(roll, side, offset, widget) ~= nil end,
    }
    if offset ~= 0 then
      children[#children + 1] = {
        type = "line", x = 0, y = 0, w = 0, h = 0, color = colors.bg, thickness = h + 2,
        pts = { { colX - 1, y + math.floor(h / 2) }, { colX + colW + 1, y + math.floor(h / 2) } },
      }
    end
  end
  for offset = -REACH, REACH do
    if offset ~= 0 or roll.side ~= "left" then tapRow("left", leftX, offset) end
    if roll.side == "right" and offset ~= 0 then tapRow("right", rightX, offset) end
  end

  viewport(widget, roll, windows, "reverse", "forward", children, activeX, midY, colW, midH, colors.fill, radius)

  -- The row with the focus has the blue outline, in lines: a rectangle over a button takes its press.
  Look.outline(children, activeX, midY, colW, midH, colors.accent, thickness)

  local fillFormat = t("widgets.dashboard.erase_blackbox_confirm_used", "%d%% used")

  local markW = 2 * nearH
  local leftFace = middleFace(roll.leftList, midFont, nearFont, colW - 2 * markW)
  local rightFace = middleFace(rightList(widget, roll), midFont, nearFont, colW - 2 * markW)

  local function row(side, colX, offset)
    local isMid = offset == 0
    local hasFocus = side == roll.side
    local h = isMid and midH or rowH
    local font, fontH, color
    if isMid then
      font = (side == "left") and leftFace or rightFace
      fontH = (font == midFont) and midH_ or nearH
      color = hasFocus and colors.text or colors.muted
    elseif math.abs(offset) == 1 then
      font, fontH, color = nearFont, nearH, colors.muted
    else
      font, fontH, color = farFont, farH, colors.far
    end
    local y = slotY(offset) + math.floor((h - fontH) / 2)
    if isMid then y = slotY(offset) + math.floor((h - fontH - farH) / 2) end
    children[#children + 1] = {
      type = "label", x = colX + 4, y = y, w = colW - 8, font = font, align = CENTER, color = color,
      text = rowText(roll, side, offset, widget),
    }
    if isMid then
      children[#children + 1] = {
        type = "label", x = colX + 4, y = y + fontH + (large and 4 or 1), w = colW - 8, font = farFont, align = CENTER,
        color = colors.muted, text = subText(roll, side, widget, fillFormat),
      }
    end
    -- The mark that a left row opens something on the right.
    if side == "left" then
      children[#children + 1] = {
        type = "label", x = colX + colW - pad - markW, y = slotY(offset) + math.floor((h - fontH) / 2), w = markW,
        font = font, align = RIGHT, color = (isMid and hasFocus) and colors.accent or color,
        text = function()
          local item = itemAt(roll, side, offset, widget)
          return (item ~= nil and item.view ~= nil) and ">" or ""
        end,
      }
    else
      -- The option in force.
      local dot = large and 4 or 3
      children[#children + 1] = {
        type = "circle", x = colX + pad + dot, y = slotY(offset) + math.floor(h / 2), radius = dot, color = colors.accent, filled = true,
        visible = function()
          local item = itemAt(roll, side, offset, widget)
          return item ~= nil and item.current == true
        end,
      }
    end
  end
  for offset = -REACH, REACH do
    row("left", leftX, offset)
    row("right", rightX, offset)
  end

  if roll.question ~= nil then
    local confirm = roll.question.confirm
    children[#children + 1] = {
      type = "label", x = rightX + pad, y = headH + 2, w = colW - 2 * pad, font = farFont, align = LEFT, color = colors.text,
      text = (confirm.message or "") .. ((type(confirm.detail) == "string" and confirm.detail ~= "") and (" " .. confirm.detail) or ""),
    }
  end

  -- In the header: how a profile's write went.
  children[#children + 1] = {
    type = "label", x = math.floor(W / 2), y = math.floor((headH - farH) / 2), w = closeX - pad - math.floor(W / 2),
    font = farFont, align = RIGHT, color = colors.headText,
    text = function()
      local status = Views.status(widget, "battery_profile")
      if status == "busy" then return t("widgets.dashboard.battery_profile_busy", "SENDING...") end
      if status == "failed" then return t("widgets.dashboard.battery_profile_failed", "NOT SAVED") end
      return ""
    end,
  }
end

return M
