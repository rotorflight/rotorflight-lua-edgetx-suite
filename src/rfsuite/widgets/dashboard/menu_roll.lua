-- A menu as two rolling columns, for whichever menu hands in a description of itself
-- (menu_roll_sources.lua says what one holds; this file knows nothing else about the menu). The
-- current row always stands in the larger middle slot, and the lists end where they end: no wrap,
-- nothing drawn twice, free slots stay empty.
--
--   wheel    moves the list that has the focus; the left one shows on the right what its current
--            row leads to
--   press    moves the focus right where the row leads to a list or a question, else acts
--   RTN      from the right returns left, from the left is the description's `back`
--   finger   a swipe rolls the list it starts on, a row's height a row; a tap on the middle row is
--            a press, a tap on any other brings it to the middle and runs nothing
--
-- The place is a path of levels, each a list and the row current in it, with the focus on one of
-- them. Two columns show two levels at a time: the one with the focus and the one beside it.
--
-- The wheel. A Lua widget never receives EVT_ROTARY_*: the encoder moves LVGL's focus along the
-- scene's focusable objects in creation order, wrapping, and the fullscreen widget itself is one of
-- them. So a small viewport holds a ladder of buttons, each its own height: a detent moves the focus
-- to the next one, LVGL scrolls it into view, and `scrolled` says where it went. The same mechanism
-- as the in-flight tuning surface (inflight/input.lua), without what that one needs for its value
-- mode. The ladders lie under the header, where nothing can touch them.
--
-- There are two ladders in the walk, the forward one first and the reverse one last, so that a
-- detent either way from the widget lands in one of them and only the close box lies between. A
-- detent back onto the widget itself reports nothing: the row shown stays one detent behind until
-- the next detent, which is counted from the ladder position and so loses nothing in the sum. To
-- keep the focus off that step while turning back and forth, the scene is built again once the
-- wheel has rested, which puts the focus back on the widget with the selection kept.
--
-- The finger. A button keeps a touch to itself and takes the firmware's border and a place in the
-- wheel's walk, so the rows are not buttons. One empty box lies over them, which the firmware passes
-- on: its touches arrive at the widget as events with coordinates, handed here by views.lua.

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

local Views = requireModule("widgets/dashboard/views.lua")
local Log = requireModule("lib/log.lua")

local TAG = "rfsuite.widget.roll"

local function trace(msg)
  if Log and type(Log.wanted) == "function" and Log.wanted("trace") then
    Log.emit(TAG, msg, "trace")
  end
end

-- Rows in each ladder. The scene is built again before a ladder runs out, so the walk never reaches
-- the close box between the two; what is left past that absorbs a fast turn.
local LADDER = 12
local LADDER_MARGIN = 3

-- A ladder's width and row height, hidden under the header.
local LADDER_SIZE = 16

-- The slots either side of the middle one.
local REACH = 2

-- The most rows whose names a build measures to choose the middle row's face.
local MEASURED_ROWS = 40

-- Ten milliseconds a tick: how long the wheel has to rest before the scene is built again.
local REST_TICKS = 60

-- The roll of this visit for `view`, made where there is none. A visit has one: only the view on top
-- takes the wheel, and a menu a picker opened over is not returned to.
local function rollOf(widget, view)
  if not (Views and type(Views.session) == "function") then return nil end
  local session = Views.session(widget)
  local roll = session.roll
  if roll == nil or roll.view ~= view then
    roll = { view = view, levels = { { rows = {}, index = 1 } }, focus = 1, position = 0, epoch = 0 }
    session.roll = roll
  end
  return roll
end

local function current(widget)
  local session = widget._viewStack
  return session and session.roll or nil
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

-- Where a list starts: on the row marked current where it can be pressed, else on the answer that
-- changes nothing where the list has one, else on its first row.
local function startIndex(rows, source)
  local fallback = 1
  for i = 1, #rows do
    local row = rows[i]
    if row.none == true then fallback = i end
    if row.current == true and not (source.off and source.off(row)) then return i end
  end
  return fallback
end

-- The left level and the right one: the first two for as long as there are two levels.
local function leftLevel(roll) return roll.levels[1] end

-- What the right list holds now: the level the focus is on, else what the left row leads to. Asked
-- again only when the left row changes.
local function rightLevel(roll)
  local left = leftLevel(roll)
  local right = roll.levels[2]
  if roll.focus == 2 then return right end
  if right == nil or right.forIndex ~= left.index then
    local source = roll.source
    local row = left.rows[left.index]
    local rows = (row ~= nil and source.preview ~= nil) and source.preview(row) or nil
    right = { rows = rows, forIndex = left.index, index = rows and startIndex(rows, source) or 1 }
    roll.levels[2] = right
  end
  return right
end

local function rightRows(roll)
  local right = rightLevel(roll)
  return right and right.rows or nil
end

local function moveLeft(widget, roll)
  roll.focus = 1
  roll.levels[2] = nil
  trace("focus left")
  rebuild(widget, roll)
end

local function isOff(roll, row)
  local off = roll.source and roll.source.off
  return off ~= nil and row ~= nil and off(row) == true
end

-- ---------------------------------------------------------------------------
-- What the pilot does
-- ---------------------------------------------------------------------------

local function sideOf(roll)
  return (roll.focus == 2) and "right" or "left"
end

local function moveBy(roll, delta)
  local level = (roll.focus == 2) and rightLevel(roll) or leftLevel(roll)
  local rows = level and level.rows or nil
  local before = level and level.index or 1
  if level ~= nil then level.index = clamp(before + delta, rows and #rows or 0) end
  trace(sideOf(roll) .. " " .. tostring(before) .. " -> " .. tostring(level and level.index))
end

-- A detent, or several where the wheel outran the callbacks. The sum is taken from the ladder
-- position, so a detent that went unreported on the widget is counted by the next one.
local function stepped(widget, roll, delta)
  if delta == 0 then return end
  moveBy(roll, delta)
  roll.steppedAt = getTime()
  if math.abs(roll.position) >= LADDER - LADDER_MARGIN then rebuild(widget, roll) end
end

--- A press of the wheel, or a tap on the middle row: what the current row does.
function M.press(widget)
  local roll = current(widget)
  if roll == nil or roll.source == nil then return end
  local source = roll.source
  local left = leftLevel(roll)
  local row = left.rows[left.index]
  if roll.focus == 2 then
    local right = roll.levels[2]
    local choice = right and right.rows and right.rows[right.index] or nil
    if row == nil or choice == nil or isOff(roll, choice) then return end
    if source.act({ row, choice }, roll) == "back" then moveLeft(widget, roll) end
    return
  end
  if row == nil or isOff(roll, row) then return end
  local rows, question
  if source.enter ~= nil then rows, question = source.enter(row) end
  if rows ~= nil then
    roll.levels[2] = { rows = rows, question = question, forIndex = left.index, index = startIndex(rows, source) }
    roll.focus = 2
    trace("focus right")
    rebuild(widget, roll)
    return
  end
  source.act({ row }, roll)
end

--- RTN: from the right back to the left, from the left the description's own. Answers true.
function M.back(widget)
  local roll = current(widget)
  if roll == nil or roll.source == nil then return false end
  if roll.focus == 2 then
    moveLeft(widget, roll)
    return true
  end
  roll.source.back()
  return true
end

-- ---------------------------------------------------------------------------
-- The finger
-- ---------------------------------------------------------------------------

-- Which row of which list is at (x, y), by the geometry of the last build: "left" or "right" and
-- the slot's distance from the middle, or nil.
local function rowAt(roll, x, y)
  local geo = roll.geo
  if geo == nil or y < geo.top then return nil end
  local side
  if x >= geo.leftX and x < geo.leftX + geo.colW then
    side = "left"
  elseif x >= geo.rightX and x < geo.rightX + geo.colW then
    side = "right"
  else
    return nil
  end
  for offset = -REACH, REACH do
    local top = geo.slotY(offset)
    if y >= top and y < top + ((offset == 0) and geo.midH or geo.rowH) then return side, offset end
  end
  return side, nil
end

-- The list a touch acts on takes the focus. Answers whether that side has a list to act on.
local function focusSide(roll, side)
  if side == sideOf(roll) then return true end
  if side == "left" then
    roll.focus = 1
    roll.levels[2] = nil
    return true
  end
  local right = rightLevel(roll)
  if right == nil or right.rows == nil then return false end
  roll.focus = 2
  return true
end

-- A tap: on the middle row of the list with the focus it is a press; any other row comes to the
-- middle of its list, and that list takes the focus, and nothing runs.
local function tapped(widget, roll, x, y)
  local side, offset = rowAt(roll, x, y)
  if side == nil or offset == nil then return end
  if offset == 0 and side == sideOf(roll) then
    M.press(widget)
    return
  end
  if offset == 0 and side == "right" and rightRows(roll) ~= nil then
    -- The preview's middle row is the left row's choice: as the press on that row.
    M.press(widget)
    return
  end
  local level = (side == "left") and leftLevel(roll) or rightLevel(roll)
  if level == nil or level.rows == nil or level.rows[level.index + offset] == nil then return end
  local index = level.index + offset
  if not focusSide(roll, side) then return end
  level = (side == "left") and leftLevel(roll) or rightLevel(roll)
  level.index = index
  trace("tap " .. side .. " -> " .. tostring(index))
  rebuild(widget, roll)
end

-- A row's height of finger is a row: the finger moving up brings the next row to the middle.
local function swiped(roll, dy)
  local geo = roll.geo
  if geo == nil or geo.rowH <= 0 then return end
  roll.slide = (roll.slide or 0) + dy
  while roll.slide <= -geo.rowH or roll.slide >= geo.rowH do
    local delta = (roll.slide < 0) and 1 or -1
    roll.slide = roll.slide + delta * geo.rowH
    moveBy(roll, delta)
  end
end

--- A touch event of the firmware's, while this menu is up. Answers true where it is one.
function M.touch(widget, event, touch)
  if _G.EVT_TOUCH_FIRST == nil or type(touch) ~= "table" then
    return false
  end
  local roll = current(widget)
  if roll == nil then return false end
  if event == _G.EVT_TOUCH_FIRST then
    -- Against the box under the whole screen, and the one rectangle over it starts at the same corner.
    roll.touchX, roll.touchY = touch.x, touch.y
    roll.slide, roll.sliding, roll.focusBefore, roll.slideOn = 0, false, roll.focus, nil
    return true
  end
  if event == _G.EVT_TOUCH_SLIDE then
    if roll.touchX == nil then return true end
    if not roll.sliding then
      roll.sliding = true
      local side = rowAt(roll, roll.touchX, roll.touchY or 0)
      if side ~= nil and focusSide(roll, side) then roll.slideOn = true end
    end
    if roll.slideOn then swiped(roll, touch.slideY or 0) end
    return true
  end
  if event == _G.EVT_TOUCH_BREAK then
    local x, y, wasSliding = roll.touchX, roll.touchY, roll.sliding
    roll.touchX, roll.touchY, roll.sliding, roll.slideOn = nil, nil, false, nil
    if wasSliding then
      -- The focus's outline is drawn with the scene.
      if roll.focus ~= roll.focusBefore then rebuild(widget, roll) end
    elseif x ~= nil then
      tapped(widget, roll, x, y)
    end
    return true
  end
  return event == _G.EVT_TOUCH_TAP
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
--- when the wheel has rested, the one place that is asked on every pass while the menu is up. Not
--- while a finger is down: a build under it would take the touch away.
function M.renderKey(widget)
  local roll = current(widget)
  if roll == nil then return "" end
  if roll.steppedAt ~= nil and roll.touchX == nil and getTime() - roll.steppedAt >= REST_TICKS then
    roll.epoch = roll.epoch + 1
    roll.steppedAt = nil
  end
  return tostring(roll.epoch)
end

-- One row of a list, as text read when it is drawn: the rows do not move, what they say does.
local function itemAt(roll, side, offset)
  local level = (side == "left") and leftLevel(roll) or rightLevel(roll)
  if level == nil or level.rows == nil then return nil end
  return level.rows[level.index + offset]
end

local function rowText(roll, side, offset)
  return function()
    local item = itemAt(roll, side, offset)
    if item == nil then return "" end
    return item.title or item.label or ""
  end
end

-- What a current row says under its name.
local function subText(roll, side)
  -- Asked on every pass the menu is up, and a row's second line only changes with the row.
  local lastItem, lastText = nil, ""
  return function()
    local item = itemAt(roll, side, 0)
    if item == lastItem then return lastText end
    lastItem, lastText = item, ""
    if item == nil then return lastText end
    local sub = roll.source.sub
    if sub ~= nil then
      lastText = sub(item) or ""
    else
      lastText = item.detail or ""
    end
    return lastText
  end
end

-- The middle row's face for a list: the large one where every name in it fits the width, else the
-- face under it, the same for the whole list so a row does not change size as it comes to the middle. A
-- long list takes the smaller one without measuring every name in a build.
local function middleFace(list, large, small, maxW)
  if type(list) ~= "table" or not (lcd and type(lcd.sizeText) == "function") then return large end
  if #list > MEASURED_ROWS then return small end
  for i = 1, #list do
    local ok, w = pcall(lcd.sizeText, list[i].title or list[i].label or "", large)
    if ok and type(w) == "number" and w > maxW then return small end
  end
  return large
end

-- A row is the same row by its id, and NO BATTERY by its mark.
local function indexOfRow(rows, row)
  if rows == nil or row == nil then return nil end
  for i = 1, #rows do
    local candidate = rows[i]
    if (row.none == true and candidate.none == true) or (row.id ~= nil and candidate.id == row.id) then return i end
  end
  return nil
end

-- The scene is built again whenever the wheel rests, and the lists are made afresh with it, for what
-- they say about the choice in force. The pilot's place in them goes by what the row IS: a row can
-- come or go above it, and the same number can then be another row.
local function refreshLists(roll, source)
  local left = leftLevel(roll)
  local right = roll.levels[2]
  local before = left.rows[left.index]
  local beforeChoice = (right ~= nil and right.question == nil and right.rows ~= nil and right.forIndex == left.index)
    and right.rows[right.index] or nil

  left.rows = source.rows()
  trace("left list " .. tostring(#left.rows))
  local found = indexOfRow(left.rows, before)
  if found == nil then
    -- The row the pilot was on has gone: the model armed, or the link dropped. On a first build there
    -- was none, and the list starts where it starts.
    left.index = (before == nil) and startIndex(left.rows, source) or clamp(left.index, #left.rows)
    roll.focus = 1
    roll.levels[2] = nil
  else
    left.index = found
    if right ~= nil then right.forIndex = found end
    local row = left.rows[found]
    if right ~= nil and right.question ~= nil then
      -- A question stands, in what the row says now.
      local rows, question
      if source.enter ~= nil then rows, question = source.enter(row) end
      if rows ~= nil and question ~= nil then
        right.rows, right.question = rows, question
      else
        roll.focus = 1
        roll.levels[2] = nil
      end
    elseif beforeChoice ~= nil then
      right.rows = source.preview and source.preview(row) or nil
      local place = indexOfRow(right.rows, beforeChoice)
      if place ~= nil then
        right.index = place
      else
        -- The option the pilot was on has gone. Another one must not take its place under the same
        -- press: the focus goes back to the left, and the list starts over on the one in force.
        roll.focus = 1
        right.index = right.rows and startIndex(right.rows, source) or 1
      end
    else
      roll.levels[2] = nil
    end
  end
  roll.position, roll.steppedAt = 0, nil
  if roll.focus == 2 and (roll.levels[2] == nil or roll.levels[2].rows == nil) then
    roll.focus = 1
    roll.levels[2] = nil
  end
end

--- Draw the menu `source` describes (menu_roll_sources.lua) into the view it names.
function M.build(children, widget, source, colors)
  local roll = rollOf(widget, source.id)
  if roll == nil then return end
  roll.source = source
  refreshLists(roll, source)

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
  local onRight = roll.focus == 2
  local activeX = onRight and rightX or leftX

  local function slotY(offset)
    if offset < 0 then return midY + offset * (rowH + gap) end
    if offset == 0 then return midY end
    return midY + midH + gap + (offset - 1) * (rowH + gap)
  end

  -- The middle rows' surfaces: the one with the focus, and the other list's where it has a row.
  local function surface(x, color)
    children[#children + 1] = { type = "rectangle", x = x, y = midY, w = colW, h = midH, color = color, filled = true, rounded = radius }
  end
  surface(activeX, colors.fill)
  if onRight then
    surface(leftX, colors.off)
  elseif rightRows(roll) ~= nil then
    surface(rightX, colors.off)
  end
  children[#children + 1] = { type = "rectangle", x = activeX, y = midY, w = colW, h = midH, color = colors.accent,
    thickness = thickness, rounded = radius }

  children[#children + 1] = { type = "rectangle", x = pad + colW + math.floor(pad / 2), y = top, w = 1, h = bottom - top,
    color = colors.rule, filled = true }

  roll.geo = { leftX = leftX, rightX = rightX, colW = colW, midH = midH, rowH = rowH, slotY = slotY, top = headH }

  local windows = {}

  -- In the walk: the forward ladder, the header's close box, the reverse ladder. Both ladders lie in
  -- the header's corner and under it: the wheel needs them, and nothing should see or touch them.
  viewport(widget, roll, windows, "forward", "reverse", children, 0, 0, LADDER_SIZE, LADDER_SIZE, colors.head, 0)

  children[#children + 1] = { type = "rectangle", x = 0, y = 0, w = W, h = headH, color = colors.head, filled = true }
  children[#children + 1] = { type = "rectangle", x = 0, y = headH, w = W, h = 1, color = colors.rule, filled = true }

  -- Over every surface and empty, not scrolling: a touch reaches the widget against this box, with
  -- its coordinates. Labels take no touch, and the close box and the rectangle below come after it.
  children[#children + 1] = { type = "box", x = 0, y = 0, w = W, h = H, borderPad = 0, scrollDir = 0, scrollBar = false, children = {} }

  local closeX, closeY = W - closeSize - pad, math.floor((headH - closeSize) / 2)
  children[#children + 1] = {
    type = "button", x = closeX, y = closeY, w = closeSize, h = closeSize, color = colors.close, cornerRadius = radius,
    text = "X", textColor = colors.onClose,
    press = function() source.close() end,
  }

  viewport(widget, roll, windows, "reverse", "forward", children, 0, 0, LADDER_SIZE, LADDER_SIZE, colors.head, 0)
  children[#children + 1] = { type = "rectangle", x = 0, y = 0, w = closeX - pad, h = headH, color = colors.head, filled = true }
  children[#children + 1] = {
    type = "label", x = pad, y = math.floor((headH - midH_) / 2), w = math.floor(W / 2), font = large and MIDSIZE or nearFont,
    text = source.title or "", color = colors.headText, align = LEFT,
  }

  local markW = 2 * nearH
  local leftFace = middleFace(leftLevel(roll).rows, midFont, nearFont, colW - 2 * markW)
  local rightFace = middleFace(rightRows(roll), midFont, nearFont, colW - 2 * markW)

  -- A row that cannot be pressed reads paler wherever it stands. Only a menu that has such rows pays
  -- for the colour being asked on every pass.
  local function shaded(side, offset, color, offColor)
    if source.off == nil then return color end
    return function()
      local item = itemAt(roll, side, offset)
      if item ~= nil and source.off(item) then return offColor end
      return color
    end
  end

  local function row(side, colX, offset)
    local isMid = offset == 0
    local hasFocus = side == sideOf(roll)
    local h = isMid and midH or rowH
    local font, fontH, color
    if isMid then
      font = (side == "left") and leftFace or rightFace
      fontH = (font == midFont) and midH_ or nearH
      color = hasFocus and colors.text or colors.muted
    elseif math.abs(offset) == 1 then
      font, fontH, color = nearFont, nearH, colors.muted
    else
      -- The step outward is the smaller face: the colour has to stay readable on the page.
      font, fontH, color = farFont, farH, colors.muted
    end
    local y = slotY(offset) + math.floor((h - fontH) / 2)
    if isMid then y = slotY(offset) + math.floor((h - fontH - farH) / 2) end
    children[#children + 1] = {
      type = "label", x = colX + 4, y = y, w = colW - 8, font = font, align = CENTER,
      -- On the selected surface the disabled colour has no contrast left, so the middle row takes muted.
      color = shaded(side, offset, color, isMid and colors.muted or colors.disabled),
      text = rowText(roll, side, offset),
    }
    if isMid then
      children[#children + 1] = {
        type = "label", x = colX + 4, y = y + fontH + (large and 4 or 1), w = colW - 8, font = farFont, align = CENTER,
        color = colors.muted, text = subText(roll, side),
      }
    end
    if side == "left" and source.opens ~= nil then
      -- The mark that a left row opens something on the right.
      children[#children + 1] = {
        type = "label", x = colX + colW - pad - markW, y = slotY(offset) + math.floor((h - fontH) / 2), w = markW,
        font = font, align = RIGHT, color = (isMid and hasFocus) and colors.accent or color,
        text = function()
          local item = itemAt(roll, side, offset)
          return (item ~= nil and source.opens(item)) and ">" or ""
        end,
      }
    end
    if side == "right" or source.marks then
      -- The choice in force.
      local dot = large and 4 or 3
      children[#children + 1] = {
        type = "circle", x = colX + pad + dot, y = slotY(offset) + math.floor(h / 2), radius = dot, color = colors.accent, filled = true,
        visible = function()
          local item = itemAt(roll, side, offset)
          return item ~= nil and item.current == true
        end,
      }
    end
  end
  for offset = -REACH, REACH do
    row("left", leftX, offset)
    if source.details == nil then row("right", rightX, offset) end
  end

  -- Beside a row that leads to no list: what is known about it, taking no focus.
  if source.details ~= nil then
    for line = 1, 2 * REACH + 1 do
      local offset = line - REACH - 1
      children[#children + 1] = {
        type = "label", x = rightX + 4, y = slotY(offset) + math.floor(((offset == 0) and midH or rowH) / 2 - nearH / 2),
        w = colW - 8, font = nearFont, align = CENTER, color = colors.text,
        text = function()
          local item = itemAt(roll, "left", 0)
          local lines = item and source.details(item) or nil
          -- The lines stand around the middle slot.
          local first = lines and (REACH + 1 - math.floor((#lines - 1) / 2)) or 1
          return lines and lines[line - first + 1] or ""
        end,
      }
    end
  end

  local right = roll.levels[2]
  local question = onRight and right and right.question or nil
  if question ~= nil then
    children[#children + 1] = {
      type = "label", x = rightX + pad, y = headH + 2, w = colW - 2 * pad, font = farFont, align = LEFT, color = colors.text,
      text = (question.message or "") .. ((type(question.detail) == "string" and question.detail ~= "") and (" " .. question.detail) or ""),
    }
  end

  -- In the header: how a write went.
  if source.status ~= nil then
    children[#children + 1] = {
      type = "label", x = math.floor(W / 2), y = math.floor((headH - farH) / 2), w = closeX - pad - math.floor(W / 2),
      font = farFont, align = RIGHT, color = colors.headText,
      text = function() return source.status() or "" end,
    }
  end
end

return M
