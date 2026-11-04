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
local function viewport(widget, roll, windows, name, other, children, x, y, w, h, color)
  local spare = (name == "reverse") and LADDER * h or 0
  local window = { y = spare, spare = spare }
  windows[name] = window
  local rows = {}
  local function press() M.press(widget) end
  if name == "forward" then
    rows[1] = { type = "rectangle", x = 0, y = 0, w = 1, h = 1, color = color }
    for i = 1, LADDER do
      rows[#rows + 1] = { type = "button", x = 0, y = i * h, w = w, h = h, borderPad = 0, text = "", color = color, press = press }
    end
  else
    for i = LADDER, 1, -1 do
      rows[#rows + 1] = { type = "button", x = 0, y = (LADDER - i) * h, w = w, h = h, borderPad = 0, text = "", color = color, press = press }
    end
    rows[#rows + 1] = { type = "rectangle", x = 0, y = LADDER * h, w = 1, h = 1, color = color }
  end
  children[#children + 1] = {
    type = "box", x = x, y = y, w = w, h = h, borderPad = 0,
    scrollDir = (lvgl and lvgl.SCROLL_VER) or 12, scrollBar = false, color = color, children = rows,
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
local function rowText(roll, side, offset, widget)
  return function()
    local list
    local index
    if side == "left" then
      list, index = roll.leftList, roll.left + offset
    else
      list, index = rightList(widget, roll), roll.right + offset
    end
    local item = list and list[index] or nil
    if item == nil then return "" end
    local text = item.title or item.label or ""
    if item.current == true then text = "* " .. text end
    return text
  end
end

-- What a current row says under its name: an option's detail, the blackbox's fill.
local function subText(roll, side, widget, fillFormat)
  -- Asked on every pass the menu is up, and a row's second line only changes with the row.
  local lastItem, lastText = nil, ""
  return function()
    local item
    if side == "left" then
      item = roll.leftList and roll.leftList[roll.left] or nil
    else
      local list = rightList(widget, roll)
      item = list and list[roll.right] or nil
    end
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

--- Draw the menu. `entries` is the list the menu was asked to draw.
function M.build(children, widget, entries, frame, colors, t)
  local roll = rollOf(widget)
  if roll == nil then return end

  roll.leftList = leftList(widget, entries)
  roll.left = clamp(roll.left, #roll.leftList)
  roll.rightFor, roll.rightOptions = nil, nil
  roll.position, roll.steppedAt = 0, nil
  if roll.side == "right" then
    local list = rightList(widget, roll)
    if list == nil then
      -- What the right list showed has gone: the model armed, or the link dropped.
      roll.side, roll.question, roll.questionList = "left", nil, nil
    else
      roll.right = clamp(roll.right, #list)
    end
  end

  local fill = colors.fill
  local x, top, width = frame.x, frame.top, frame.w
  local gapX, gapY = frame.gapX, frame.gapY
  local colW = math.floor((width - gapX) / 2)
  local rightX = x + colW + gapX
  local slots = 2 * REACH + 1

  -- The rows share the height, the middle one half as tall again as the others.
  local avail = frame.bottom - top - (slots - 1) * gapY
  local rowH = math.floor(avail / (slots + 0.5))
  local midH = avail - (slots - 1) * rowH
  local midY = top + REACH * (rowH + gapY)
  local activeX = (roll.side == "right") and rightX or x

  local function slotY(offset)
    if offset < 0 then return midY + offset * (rowH + gapY) end
    if offset == 0 then return midY end
    return midY + midH + gapY + (offset - 1) * (rowH + gapY)
  end

  local windows = {}

  -- In the walk: the forward ladder, the header's close box, the rows a finger taps, the reverse
  -- ladder. Everything a pilot reads is created after the ladders, which puts it over them.
  viewport(widget, roll, windows, "forward", "reverse", children, activeX, midY, colW, midH, fill)

  frame.drawHeader(children)

  local function tapRow(side, colX, offset)
    local h = (offset == 0) and midH or rowH
    children[#children + 1] = {
      type = "button", x = colX, y = slotY(offset), w = colW, h = h, borderPad = 0, text = "",
      color = (offset == 0) and colors.off or colors.bg,
      press = function() tapped(widget, side, offset) end,
    }
  end
  for offset = -REACH, REACH do
    if offset ~= 0 or roll.side ~= "left" then tapRow("left", x, offset) end
    if roll.side == "right" and offset ~= 0 then tapRow("right", rightX, offset) end
  end

  viewport(widget, roll, windows, "reverse", "forward", children, activeX, midY, colW, midH, fill)

  -- The current rows' frames: the blue outline is the row with the focus.
  Look.outline(children, activeX, midY, colW, midH, colors.accent, 2)

  local font, small = frame.font, frame.small
  local fontH, smallH = frame.fontH, frame.smallH
  local offY = frame.textOffY
  local fillFormat = t("widgets.dashboard.erase_blackbox_confirm_used", "%d%% used")

  local function label(side, colX, offset)
    local h = (offset == 0) and midH or rowH
    local isMid = offset == 0
    local isActive = (side == roll.side)
    local top2 = slotY(offset) + math.floor((h - fontH) / 2) + offY
    if isMid then top2 = slotY(offset) + math.floor((h - fontH - smallH) / 2) + offY end
    children[#children + 1] = {
      type = "label", x = colX + 4, y = top2, w = colW - 8,
      text = rowText(roll, side, offset, widget), font = font, align = CENTER,
      color = (isMid and isActive) and colors.text or colors.muted,
    }
    if isMid then
      children[#children + 1] = {
        type = "label", x = colX + 4, y = top2 + fontH + (frame.large and 8 or 2), w = colW - 8,
        text = subText(roll, side, widget, fillFormat), font = small, align = CENTER,
        color = colors.muted,
      }
    end
  end
  for offset = -REACH, REACH do
    label("left", x, offset)
    -- Over the question the rows above its answers carry its wording instead.
    if roll.question == nil or offset >= 0 then label("right", rightX, offset) end
  end

  if roll.question ~= nil then
    local confirm = roll.question.confirm
    children[#children + 1] = {
      type = "label", x = rightX + 4, y = top, w = colW - 8,
      text = confirm.message or "", font = small, align = LEFT, color = colors.text,
    }
    if type(confirm.detail) == "string" and confirm.detail ~= "" then
      children[#children + 1] = {
        type = "label", x = rightX + 4, y = midY - smallH - gapY, w = colW - 8,
        text = confirm.detail, font = small, align = LEFT, color = colors.muted,
      }
    end
  end

  -- In the header: how a profile's write went, or why nothing could be pressed.
  children[#children + 1] = {
    type = "label", x = frame.statusX, y = frame.statusY, w = frame.statusW, font = small, align = RIGHT,
    color = colors.text,
    text = function()
      local status = Views.status(widget, "battery_profile")
      if status == "busy" then return t("widgets.dashboard.battery_profile_busy", "SENDING...") end
      if status == "failed" then return t("widgets.dashboard.battery_profile_failed", "NOT SAVED") end
      return ""
    end,
  }
end

return M
