-- A menu as two rolling columns, for whichever menu hands in a description of itself
-- (menu_roll_sources.lua says what one holds; this file knows nothing else about the menu). The
-- current row always stands in the larger middle slot, and the lists end where they end: no wrap,
-- nothing drawn twice, free slots stay empty.
--
--   wheel    moves the list that has the focus; the left one shows on the right what its current
--            row leads to
--   press    moves the focus right where the row leads to a list or a question; on the right, where
--            the row leads to a list, both columns shift by one level; else acts
--   RTN      takes back one press: from the right returns left with nothing shifting, from the left
--            shifts both columns back a level, and on the first level is the description's `back`
--   finger   a swipe rolls the list it starts on, a row's height a row; a tap on the middle row is
--            a press, a tap on any other brings it to the middle and runs nothing
--
-- The place is a path of levels, each a list and the row current in it. Two columns show two levels
-- of it at a time: `base` is the one on the left, the next the one on the right, and `focus` says
-- which of the two has the wheel (1 left, 2 right).
--
-- The wheel. A Lua widget never receives EVT_ROTARY_*: the encoder moves LVGL's focus along the
-- scene's focusable objects in creation order, wrapping, and the fullscreen widget itself is one of
-- them. So a small viewport holds a ladder of buttons, each its own height: a detent moves the focus
-- to the next one, LVGL scrolls it into view, and `scrolled` says where it went. The same mechanism
-- as the in-flight tuning surface (inflight/input.lua), without what that one needs for its value
-- mode. The ladders lie under the header, where nothing can touch them.
--
-- There are two ladders in the walk, the forward one first and the reverse one last, so that a
-- detent either way from the widget lands in one of them, and nothing else lies between. A
-- detent back onto the widget itself reports nothing: the row shown stays one detent behind until
-- the next detent, which is counted from the ladder position and so loses nothing in the sum. To
-- keep the focus off that step while turning back and forth, the focus goes back to the widget once
-- the wheel has rested: every ladder button is hidden for one sweep, and LVGL moves the focus off a
-- button that is hidden onto the next one shown, which after the last ladder is the widget. The
-- scene is not built for it: on EdgeTX up to 2.12.5 every build leaves memory behind.
--
-- The finger. A button keeps a touch to itself and takes the firmware's border and a place in the
-- wheel's walk, so the rows are not buttons, and neither is the header's close box. One empty box lies
-- over them, which the firmware passes on: its touches arrive at the widget as events with
-- coordinates, handed here by views.lua.

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

local function info(msg)
  if Log and type(Log.emit) == "function" then Log.emit(TAG, msg, "info") end
end

-- Rows in each ladder. The scene is built again before a ladder runs out, so the walk never reaches
-- the other ladder; what is left past that absorbs a fast turn.
local LADDER = 12
local LADDER_MARGIN = 3

-- A ladder's width and row height, hidden under the header.
local LADDER_SIZE = 16

-- The slots either side of the middle one.
local REACH = 2

-- The most rows whose names a build measures to choose the middle row's face.
local MEASURED_ROWS = 40

-- Ten milliseconds a tick: how long the wheel has to rest before the focus goes back to the widget.
local REST_TICKS = 60

-- For how many passes the ladders may stay hidden or not yet shown: one is the rule. Counted in passes, not
-- time, since a slow pass is no reason; a sweep that never ends the hiding would leave the wheel nothing to
-- move to, so past this the scene is built instead.
local HIDDEN_PASSES = 3

-- How long a press may wait to open its page. Longer means the menu was covered, and the press is over.
local OPENING_TICKS = 300

-- The roll of this visit for `view`, made where there is none. One per view: only the view on top
-- takes the wheel, and a menu a picker opened over keeps its place under it. A roll a visit to the
-- tool left (views.lua, `toolClosed`) has only its place so far, and is completed here.
local function rollOf(widget, view)
  if not (Views and type(Views.session) == "function") then return nil end
  local session = Views.session(widget)
  session.rolls = session.rolls or {}
  local roll = session.rolls[view]
  if roll == nil or roll.levels == nil then
    local kept = roll
    roll = { view = view, levels = { { rows = {}, index = 1 } }, base = 1, focus = 1, position = 0, epoch = 0 }
    if kept ~= nil then roll.restore, roll.couldNotOpen = kept.restore, kept.couldNotOpen end
    session.rolls[view] = roll
  end
  return roll
end

local function current(widget)
  return Views and Views.topRoll(widget) or nil
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
  roll.slots = nil
  roll.epoch = roll.epoch + 1
  roll.steppedAt = nil
  roll.recentre = nil
  if Views and type(Views.invalidate) == "function" then Views.invalidate(widget) end
end

-- Where a list starts: on the row marked current where it can be pressed, else on the answer that
-- changes nothing where the list has one, else on its first row that can be pressed, and with none
-- on its first.
local function startIndex(rows, source)
  local none, open = nil, nil
  for i = 1, #rows do
    local row = rows[i]
    if row.none == true then none = i end
    -- Asked only where the answer decides anything: a long list has one row in force.
    if row.current == true or open == nil then
      local off = source.off ~= nil and source.off(row) == true
      if row.current == true and not off then return i end
      if open == nil and not off then open = i end
    end
  end
  return none or open or 1
end

local function leftLevel(roll) return roll.levels[roll.base] end

-- What the right list holds now: the level the focus is on, else what the left row leads to. Asked
-- again only when the left row changes.
local function rightLevel(roll)
  local left = leftLevel(roll)
  local right = roll.levels[roll.base + 1]
  if roll.focus == 2 then return right end
  if right == nil or right.forIndex ~= left.index then
    local source = roll.source
    local row = left.rows[left.index]
    local rows = (row ~= nil and source.preview ~= nil) and source.preview(row) or nil
    right = { rows = rows, forIndex = left.index, index = rows and startIndex(rows, source) or 1 }
    roll.levels[roll.base + 1] = right
  end
  return right
end

local function isOff(roll, row)
  local off = roll.source and roll.source.off
  return off ~= nil and row ~= nil and off(row) == true
end

-- A row that cannot be pressed has nothing to show on the right: it says why instead.
local function rightRows(roll)
  local right = rightLevel(roll)
  if right == nil then return nil end
  if roll.focus == 1 then
    local left = leftLevel(roll)
    if isOff(roll, left.rows[left.index]) then return nil end
  end
  return right.rows
end

-- Everything below `depth` goes, and the wheel is there.
local function cutTo(roll, depth)
  for i = #roll.levels, depth + 1, -1 do roll.levels[i] = nil end
  roll.base = depth
  roll.focus = 1
end

local function moveLeft(widget, roll)
  roll.focus = 1
  -- Nothing shifts, and the right list stays where it was; a question has been taken back with its press.
  local right = roll.levels[roll.base + 1]
  if right ~= nil and right.question ~= nil then roll.levels[roll.base + 1] = nil end
  trace("focus left at level " .. tostring(roll.base))
  rebuild(widget, roll)
end

-- The rows from the first list down to the one pressed.
local function pathTo(roll, depth)
  local path = {}
  for i = 1, depth do
    local level = roll.levels[i]
    path[i] = level.rows and level.rows[level.index] or nil
  end
  return path
end

--- Where the wheel stands, as what the rows ARE: enough to find the place again in lists made afresh
--- (`M.build`, after a visit to the tool).
function M.place(roll)
  local depth = (roll.focus == 2) and (roll.base + 1) or roll.base
  local ids = {}
  for i = 1, depth do
    local level = roll.levels[i]
    local row = level.rows and level.rows[level.index] or nil
    ids[i] = row and row.id or false
  end
  return { ids = ids, base = roll.base, focus = roll.focus }
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
  roll.slots = nil
  if Log and type(Log.wanted) == "function" and Log.wanted("trace") then
    local row = rows and level and rows[level.index] or nil
    trace(sideOf(roll) .. " " .. tostring(before) .. " -> " .. tostring(level and level.index) .. " " .. tostring(row and row.id))
  end
end

-- A detent, or several where the wheel outran the callbacks. The sum is taken from the ladder
-- position, so a detent that went unreported on the widget is counted by the next one.
local function stepped(widget, roll, delta)
  if delta == 0 then return end
  if roll.opening ~= nil then return end
  moveBy(roll, delta)
  roll.couldNotOpen = nil
  roll.steppedAt = getTime()
  roll.detentAt = roll.steppedAt
  if math.abs(roll.position) >= LADDER - LADDER_MARGIN then rebuild(widget, roll) end
end

--- A press of the wheel, or a tap on the middle row: what the current row does.
function M.press(widget)
  local roll = current(widget)
  if roll == nil or roll.source == nil or roll.opening ~= nil then return end
  -- A ladder's button calls this directly, past the widget's key path: the scene left from before a
  -- reconnect is not acted on here either.
  if type(Views) == "table" and type(Views.sceneStale) == "function" and Views.sceneStale(widget) then
    trace("press on the scene left from before the reconnect, not acted on")
    return
  end
  if Log and type(Log.wanted) == "function" and Log.wanted("trace") then
    local after = roll.detentAt ~= nil and ((getTime() - roll.detentAt) * 10) or -1
    trace("press on the " .. sideOf(roll) .. ", " .. tostring(after) .. " ms after the last detent")
  end
  if roll.notice ~= nil then
    roll.notice = nil
    rebuild(widget, roll)
    return
  end
  roll.couldNotOpen = nil
  local source = roll.source
  local left = leftLevel(roll)
  local row = left.rows[left.index]
  if roll.focus == 2 then
    local right = roll.levels[roll.base + 1]
    local choice = right and right.rows and right.rows[right.index] or nil
    if row == nil or choice == nil or isOff(roll, choice) then
      trace("press on a row that cannot be pressed now")
      return
    end
    if right.question == nil and source.enter ~= nil then
      local rows, question = source.enter(choice)
      if rows ~= nil then
        -- Both columns shift: the level just left stands on the left with that row in the middle.
        roll.base = roll.base + 1
        roll.levels[roll.base + 1] = { rows = rows, question = question, forIndex = right.index, index = startIndex(rows, source) }
        trace("shift to level " .. tostring(roll.base))
        rebuild(widget, roll)
        return
      end
    end
    if source.act(pathTo(roll, roll.base + 1), roll) == "back" then moveLeft(widget, roll) end
    return
  end
  if row == nil or isOff(roll, row) then
    trace("press on a row that cannot be pressed now")
    return
  end
  local rows, question
  if source.enter ~= nil then rows, question = source.enter(row) end
  if rows ~= nil then
    -- What the row already shows on the right keeps its place: after an RTN that is the row left from.
    local shown = roll.levels[roll.base + 1]
    if question == nil and shown ~= nil and shown.forIndex == left.index and shown.question == nil and shown.rows ~= nil then
      shown.rows = rows
      shown.index = clamp(shown.index, #rows)
    else
      roll.levels[roll.base + 1] = { rows = rows, question = question, forIndex = left.index, index = startIndex(rows, source) }
    end
    roll.focus = 2
    trace("focus right")
    rebuild(widget, roll)
    return
  end
  source.act(pathTo(roll, roll.base), roll)
end

--- RTN: one press taken back. Answers true.
function M.back(widget)
  local roll = current(widget)
  if roll == nil or roll.source == nil then return false end
  if roll.opening ~= nil then
    -- RTN in that moment takes the press back; once the tool is starting there is nothing left here to do.
    if not roll.opening.started then
      roll.opening, roll.slots = nil, nil
      trace("opening called off by RTN")
    end
    return true
  end
  if roll.notice ~= nil then
    roll.notice = nil
    rebuild(widget, roll)
    return true
  end
  roll.couldNotOpen = nil
  if roll.focus == 2 then
    moveLeft(widget, roll)
    return true
  end
  if roll.base > 1 then
    -- What was on the left goes back to being what its row shows on the right, and keeps its place.
    roll.levels[roll.base + 1] = nil
    roll.base = roll.base - 1
    trace("shift back to level " .. tostring(roll.base))
    rebuild(widget, roll)
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
    roll.levels[roll.base + 1] = nil
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
  local geo = roll.geo
  -- The close box: drawn, not a button, so that it stays out of the wheel's walk.
  if geo ~= nil and geo.closeX ~= nil and x >= geo.closeX and x < geo.closeX + geo.closeSize
    and y >= geo.closeY and y < geo.closeY + geo.closeSize then
    trace("close box tapped")
    roll.source.close()
    return
  end
  -- On the header's status: its details. The wheel does not reach them.
  if geo ~= nil and y < geo.top and x >= geo.statusX and x < geo.statusEnd and roll.source.notice ~= nil then
    roll.notice = { roll.source.notice() }
    trace("status notice")
    rebuild(widget, roll)
    return
  end
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
  if roll.opening ~= nil then
    -- Only the close box answers then, as the button it replaced did, and only before the tool is starting.
    if event == _G.EVT_TOUCH_FIRST then
      roll.heldX, roll.heldY = touch.x, touch.y
    elseif event == _G.EVT_TOUCH_BREAK then
      local x, y, geo = roll.heldX, roll.heldY, roll.geo
      roll.heldX, roll.heldY = nil, nil
      if x ~= nil and geo ~= nil and geo.closeX ~= nil and not roll.opening.started
        and x >= geo.closeX and x < geo.closeX + geo.closeSize and y >= geo.closeY and y < geo.closeY + geo.closeSize then
        roll.opening, roll.slots = nil, nil
        trace("opening called off by the close box")
        roll.source.close()
      end
    end
    return true
  end
  if roll.notice ~= nil then
    -- The details behind the status cover the menu: its geometry is that of the scene under them, so the
    -- finger acts on none of it. The notice's own button closes it.
    if event == _G.EVT_TOUCH_BREAK then trace("touch on the status notice, the menu under it not acted on") end
    roll.touchX, roll.touchY, roll.sliding, roll.slideOn = nil, nil, false, nil
    return true
  end
  if event == _G.EVT_TOUCH_FIRST then
    -- Against the box under the whole screen, and the one rectangle over it starts at the same corner.
    roll.touchX, roll.touchY = touch.x, touch.y
    roll.slots = nil
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
local function viewport(widget, roll, windows, name, other, children, x, y, w, h, color, radius, shown)
  local spare = (name == "reverse") and LADDER * h or 0
  local window = { y = spare, spare = spare }
  windows[name] = window
  local rows = {}
  local function press() M.press(widget) end
  if name == "forward" then
    rows[1] = { type = "rectangle", x = 0, y = 0, w = 1, h = 1, color = color }
    for i = 1, LADDER do
      rows[#rows + 1] = { type = "button", x = 0, y = i * h, w = w, h = h, borderPad = 0, text = "", color = color, cornerRadius = radius, press = press, visible = shown }
    end
  else
    for i = LADDER, 1, -1 do
      rows[#rows + 1] = { type = "button", x = 0, y = (LADDER - i) * h, w = w, h = h, borderPad = 0, text = "", color = color, cornerRadius = radius, press = press, visible = shown }
    end
    rows[#rows + 1] = { type = "rectangle", x = 0, y = LADDER * h, w = 1, h = 1, color = color }
  end
  children[#children + 1] = {
    type = "box", x = x, y = y, w = w, h = h, borderPad = 0,
    scrollDir = (lvgl and lvgl.SCROLL_VER) or 12, scrollBar = false, children = rows,
    scrollTo = function()
      -- The firmware asks this after the box's buttons, so on the reverse ladder, the last in the walk, the
      -- sweep that hid them all is over and the focus is on the widget; the sweep after it shows them again.
      local recentre = roll.recentre
      if name == "reverse" and recentre ~= nil then
        if recentre.state == "hide" then
          recentre.state = "show"
          trace("recentre: ladders hidden, " .. tostring(recentre.swallowed) .. " scroll calls passed by")
        else
          roll.recentre = nil
          trace("recentre: ladders shown again")
        end
      end
      return 0, window.y
    end,
    scrolled = function(sx, sy)
      -- While the ladders hide, the focus passes over buttons and back onto the widget: no detent.
      local recentre = roll.recentre
      if recentre ~= nil then
        recentre.swallowed = recentre.swallowed + 1
        return
      end
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

--- Part of the view's key: the epoch moves when the scene has to be built again. A rest of the wheel is
--- handled here, the one place that is asked on every pass while the menu is up, and moves it only where
--- the rest changed the level, the side or the question, or the scene could not be kept. Not while a
--- finger is down: a build under it would take the touch away.
function M.renderKey(widget)
  local roll = current(widget)
  if roll == nil then return "" end
  local opening = roll.opening
  if opening ~= nil then
    -- One pass for the words to be drawn; the next one starts what holds the screen. The words stay until
    -- the tool takes the screen: the request only schedules it.
    if not opening.started then
      if getTime() - opening.at >= OPENING_TICKS then
        roll.opening, roll.slots = nil, nil
        trace("opening given up, the menu was covered")
      elseif not opening.waited then
        opening.waited = true
      else
        opening.started = true
        trace("opening now")
        if opening.run() == false then
          roll.opening, roll.slots = nil, nil
          trace("opening refused")
        end
      end
    end
    return tostring(roll.epoch)
  end
  local recentre = roll.recentre
  if recentre ~= nil then recentre.passes = recentre.passes + 1 end
  if recentre ~= nil and recentre.passes > HIDDEN_PASSES then
    -- The sweep that hides or shows the ladders has not come: build the scene, which ends both.
    info("recentre not finished after " .. tostring(recentre.passes) .. " passes, "
      .. tostring((getTime() - recentre.at) * 10) .. " ms, in state " .. tostring(recentre.state) .. ", the scene is built")
    roll.recentre = nil
    roll.epoch = roll.epoch + 1
    roll.steppedAt = nil
  elseif roll.steppedAt ~= nil and recentre == nil and roll.touchX == nil and getTime() - roll.steppedAt >= REST_TICKS then
    roll.steppedAt = nil
    trace("the wheel rested, the focus goes back to the widget")
    local started = getTime()
    local relayout = M.rested(roll)
    -- What a rest costs now, in the words of the build's own timing line: the lists made afresh, in Lua.
    if Log and type(Log.wanted) == "function" and Log.wanted("trace") then
      trace("rest: " .. tostring((getTime() - started) * 10) .. " ms in Lua")
    end
    if relayout then
      roll.epoch = roll.epoch + 1
      trace("the rest changed the levels, the scene is built again")
    end
  end
  return tostring(roll.epoch)
end

-- The header's words: the path to the list with the wheel, shortened from the front, the level it is
-- on always staying.
local function pathText(roll, source, font, maxW)
  local depth = (roll.focus == 2) and (roll.base + 1) or roll.base
  if depth <= 1 then return source.title or "" end
  local names = {}
  for i = 1, depth - 1 do
    local level = roll.levels[i]
    local row = level.rows and level.rows[level.index] or nil
    names[#names + 1] = row and (row.title or row.label) or ""
  end
  local text = table.concat(names, " > ")
  if not (lcd and type(lcd.sizeText) == "function") then return text end
  local first = 1
  while first < #names do
    local ok, w = pcall(lcd.sizeText, text, font)
    if not ok or type(w) ~= "number" or w <= maxW then break end
    first = first + 1
    text = "... > " .. table.concat(names, " > ", first)
  end
  return text
end

-- One row of a list, as text read when it is drawn: the rows do not move, what they say does.
local function itemAt(roll, side, offset)
  local level = (side == "left") and leftLevel(roll) or rightLevel(roll)
  if level == nil or level.rows == nil then return nil end
  if side == "right" and rightRows(roll) == nil then return nil end
  return level.rows[level.index + offset]
end

-- What the firmware's sweep reads, on every pass and for every label of the scene. That sweep runs on
-- what the widget's pass left of its budget, and a stop inside it disables the widget, so on the pass
-- that builds the scene it has to cost next to nothing: each slot is worked out once per move of the
-- wheel or build, and read from here until the next. What decides a row between two builds -- armed, the
-- link -- is in the render key, so a change of it builds the scene.
local EMPTY = { text = "", sub = "" }

local function makeSlot(roll, side, offset, key)
  local slots = roll.slots
  if slots == nil then
    slots = {}
    roll.slots = slots
  end
  local item = itemAt(roll, side, offset)
  if item == nil then
    slots[key] = EMPTY
    return EMPTY
  end
  local source = roll.source
  local slot = {
    item = item,
    text = item.title or item.label or "",
    off = source.off ~= nil and source.off(item) == true,
    current = item.current == true,
    opens = source.opens ~= nil and source.opens(item) == true,
    icon = source.icon ~= nil and source.icon(item) or nil,
    why = source.reason ~= nil and source.reason(item) or nil,
  }
  if offset == 0 then
    local sub
    -- On the right there is no column further to say why a row cannot be pressed: it says so here.
    if side == "right" and slot.why ~= nil then
      sub = slot.why
    elseif source.sub ~= nil then
      sub = source.sub(item)
    else
      sub = item.detail
    end
    slot.sub = sub or ""
    -- Whether the other list's middle surface stands beside this row: only a row that leads somewhere shows it.
    if side == "left" then slot.preview = rightRows(roll) ~= nil end
    -- A slot made again while a page is opening says so as well.
    if roll.opening ~= nil and side == sideOf(roll) then slot.sub = roll.opening.text end
  end
  slots[key] = slot
  return slot
end

local function slotOf(roll, side, offset, key)
  local slots = roll.slots
  local slot = slots and slots[key]
  if slot ~= nil then return slot end
  return makeSlot(roll, side, offset, key)
end

local function slotKey(side, offset)
  return (side == "left") and offset or (offset + 10)
end

local function rowText(roll, side, offset)
  local key = slotKey(side, offset)
  return function() return slotOf(roll, side, offset, key).text end
end

--- Say `text` under the current row, and run `open` a pass later: loading the tool holds the screen for a
--- while, and the pilot has to see that the press was taken before it starts.
function M.openNext(roll, text, open)
  roll.opening = { run = open, text = text, at = getTime(), waited = false, started = false }
  local slot = slotOf(roll, sideOf(roll), 0, slotKey(sideOf(roll), 0))
  if slot ~= EMPTY then slot.sub = text end
end

-- What a current row says under its name.
local function subText(roll, side)
  local key = slotKey(side, 0)
  return function() return slotOf(roll, side, 0, key).sub or "" end
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

-- A list whose titles stay for the visit is measured once: the description names it with `faceKey`, and what it
-- was measured to is kept with the roll. Every shift and RTN builds the scene again, and measuring text is the
-- firmware's work.
local function faceOf(roll, list, large, small, maxW)
  local faceKey = roll.source and roll.source.faceKey
  local key = (type(list) == "table" and faceKey ~= nil) and faceKey(list) or nil
  if key == nil then return middleFace(list, large, small, maxW) end
  local faces = roll.faces
  if faces == nil then
    faces = {}
    roll.faces = faces
  end
  local face = faces[key]
  if face == nil then
    face = middleFace(list, large, small, maxW)
    faces[key] = face
  end
  return face
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

-- Back to a place M.place took, in lists made afresh. A row that has gone ends the walk: the wheel is
-- on the nearest level above it, and no other row has taken its place under the press.
local function restorePlace(roll, source, place)
  local levels = roll.levels
  local ids = place.ids
  local depth = 1
  for i = 1, #ids do
    local level = levels[i]
    local rowIndex = nil
    if level ~= nil and level.rows ~= nil then
      for k = 1, #level.rows do
        if ids[i] ~= false and level.rows[k].id == ids[i] then rowIndex = k end
      end
    end
    if rowIndex == nil then
      trace("place: row " .. tostring(ids[i]) .. " has gone, at level " .. tostring(i))
      cutTo(roll, math.max(1, i - 1))
      if level ~= nil and i > 1 then
        -- Above it, the row that led there stands, and shows on the right what it holds now.
        levels[i] = nil
      end
      return
    end
    level.index = rowIndex
    depth = i
    if i < #ids then
      local rows = source.preview and source.preview(level.rows[rowIndex]) or nil
      levels[i + 1] = { rows = rows, forIndex = rowIndex, index = 1 }
    end
  end
  roll.base = math.min(place.base, depth)
  roll.focus = (place.focus == 2 and depth > roll.base) and 2 or 1
end

-- The lists are made afresh at every build and whenever the wheel rests, for what they say about the
-- choice in force. The pilot's place in them goes by what the row IS: a row can
-- come or go above it, and the same number can then be another row.
local function refreshLists(roll, source)
  local levels = roll.levels
  local first = levels[1]
  local before = first.rows[first.index]
  local beforeIndex = first.index

  if source.refresh ~= nil then source.refresh() end
  first.rows = source.rows()
  trace("first list " .. tostring(#first.rows))
  local found = indexOfRow(first.rows, before)
  if found == nil then
    -- The row the pilot was on has gone. On a first build there was none, and the list starts where
    -- it starts.
    first.index = (before == nil) and startIndex(first.rows, source) or clamp(first.index, #first.rows)
    cutTo(roll, 1)
  else
    first.index = found
    local depth = 2
    while levels[depth] ~= nil do
      local parent, level = levels[depth - 1], levels[depth]
      local row = parent.rows[parent.index]
      if level.question ~= nil then
        -- A question stands, in what the row says now, and only for as long as the row can be pressed.
        local rows, question
        if source.enter ~= nil and not isOff(roll, row) then rows, question = source.enter(row) end
        if rows ~= nil and question ~= nil then
          level.rows, level.question = rows, question
        else
          cutTo(roll, depth - 1)
        end
        break
      end
      local chosen = (level.rows ~= nil and level.forIndex == beforeIndex) and level.rows[level.index] or nil
      if chosen == nil then
        cutTo(roll, math.min(roll.base, depth - 1))
        break
      end
      beforeIndex = level.index
      level.rows = source.preview and source.preview(row) or nil
      level.forIndex = parent.index
      local place = indexOfRow(level.rows, chosen)
      if place == nil then
        -- The row the pilot was on has gone. Another must not take its place under the same press:
        -- the wheel goes to the level above, which shows this list from its start.
        level.index = level.rows and startIndex(level.rows, source) or 1
        for i = #levels, depth + 1, -1 do levels[i] = nil end
        roll.base = math.min(roll.base, depth - 1)
        roll.focus = 1
        break
      end
      level.index = place
      depth = depth + 1
    end
  end
  if roll.restore ~= nil then
    restorePlace(roll, source, roll.restore)
    roll.restore = nil
  end
  roll.position, roll.steppedAt = 0, nil
  roll.slots = nil
  local right = levels[roll.base + 1]
  if roll.focus == 2 and (right == nil or right.rows == nil) then
    roll.focus = 1
    levels[roll.base + 1] = nil
  end
  if Log and type(Log.wanted) == "function" and Log.wanted("trace") then
    local place = M.place(roll)
    local ids = {}
    for i = 1, #place.ids do ids[i] = tostring(place.ids[i]) end
    trace("place " .. table.concat(ids, "/") .. " base=" .. tostring(place.base) .. " focus=" .. tostring(place.focus))
  end
end

-- What a question says over the right list, as one line; nil where there is none.
local function questionText(question)
  if question == nil then return nil end
  return (question.message or "") .. ((type(question.detail) == "string" and question.detail ~= "") and (" " .. question.detail) or "")
end

--- The wheel has rested: the lists are made afresh for what they say about the choice in force, and the focus
--- goes back to the widget by the ladders hiding for a sweep. Answers true where the refresh moved what a build
--- lays out -- the level on the left, the side with the focus, a question -- so the scene has to be built.
function M.rested(roll)
  local source = roll.source
  if source == nil then return true end
  -- The rows a menu hands in say what held when it made them: made afresh here, as a build makes them.
  if type(roll.make) == "function" then
    source = roll.make()
    roll.source = source
  end
  local base, focus = roll.base, roll.focus
  local right = roll.levels[base + 1]
  local said = questionText(right and right.question or nil)
  refreshLists(roll, source)
  local now = roll.levels[roll.base + 1]
  if roll.base ~= base or roll.focus ~= focus or questionText(now and now.question or nil) ~= said then return true end
  roll.recentre = { state = "hide", at = getTime(), passes = 0, swallowed = 0 }
  local windows = roll.windows
  if windows ~= nil then
    for _, window in pairs(windows) do
      window.y, window.pending = window.spare, nil
    end
  end
  trace("recentre: the ladders hide for a sweep")
  return false
end

--- Draw the menu that `make()` describes (menu_roll_sources.lua) into the view it names. A menu hands in how its
--- description is made rather than the description: the roll makes it again when the wheel rests, which builds
--- nothing, so a menu's own state (a value in a question, which entries are offered) is read there as a build reads it.
function M.build(children, widget, make, colors)
  local source = type(make) == "function" and make() or nil
  if type(source) ~= "table" then return end
  local roll = rollOf(widget, source.id)
  if roll == nil then return end
  roll.source, roll.make = source, make
  refreshLists(roll, source)
  roll.recentre = nil

  local W, H = widget.zone.w, widget.zone.h

  -- The details behind the header's status, over a plain page: nothing under them takes the wheel.
  if roll.notice ~= nil then
    local Overlay = requireModule("ui/loading_overlay.lua")
    children[#children + 1] = { type = "rectangle", x = 0, y = 0, w = W, h = H, color = colors.bg, filled = true }
    if type(Overlay) == "table" and type(Overlay.appendNotice) == "function" then
      Overlay.appendNotice(children, {
        x = 0, y = 0, w = W, h = H, title = roll.notice[1], message = roll.notice[2],
        buttonText = source.noticeClose or "Close",
        press = function()
          roll.notice = nil
          rebuild(widget, roll)
        end,
      })
      return
    end
    roll.notice = nil
  end

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
  elseif source.preview ~= nil then
    -- What the row shows on the right is made here, as before the wheel moves.
    rightRows(roll)
    surface(rightX, colors.off)
    -- Whether it stands follows the row on the left, which the wheel moves without a build.
    local key = slotKey("left", 0)
    children[#children].visible = function() return slotOf(roll, "left", 0, key).preview == true end
  end
  children[#children + 1] = { type = "rectangle", x = activeX, y = midY, w = colW, h = midH, color = colors.accent,
    thickness = thickness, rounded = radius }

  children[#children + 1] = { type = "rectangle", x = pad + colW + math.floor(pad / 2), y = top, w = 1, h = bottom - top,
    color = colors.rule, filled = true }

  local statusX = math.floor(W / 2)
  local closeX, closeY = W - closeSize - pad, math.floor((headH - closeSize) / 2)
  roll.geo = { leftX = leftX, rightX = rightX, colW = colW, midH = midH, rowH = rowH, slotY = slotY, top = headH,
    statusX = statusX, statusEnd = W - closeSize - 2 * pad, closeX = closeX, closeY = closeY, closeSize = closeSize }

  local windows = {}
  roll.windows = windows
  -- One answer for all 24 ladder buttons: hidden only in the sweep that takes the focus back to the widget.
  local function shown()
    local recentre = roll.recentre
    return recentre == nil or recentre.state ~= "hide"
  end

  -- In the walk: the forward ladder and the reverse ladder, nothing between. Both lie in the header's
  -- corner and under it: the wheel needs them, and nothing should see or touch them.
  viewport(widget, roll, windows, "forward", "reverse", children, 0, 0, LADDER_SIZE, LADDER_SIZE, colors.head, 0, shown)

  children[#children + 1] = { type = "rectangle", x = 0, y = 0, w = W, h = headH, color = colors.head, filled = true }
  children[#children + 1] = { type = "rectangle", x = 0, y = headH, w = W, h = 1, color = colors.rule, filled = true }

  -- The close box is drawn, not a button: a button would stand in the wheel's walk between the ladders. It lies
  -- under the box below: a touch arrives with coordinates relative to the object it lands on.
  children[#children + 1] = { type = "rectangle", x = closeX, y = closeY, w = closeSize, h = closeSize, color = colors.close,
    filled = true, rounded = radius }
  children[#children + 1] = { type = "label", x = closeX, y = closeY + math.floor((closeSize - nearH) / 2), w = closeSize,
    font = nearFont, align = CENTER, color = colors.onClose, text = "X" }

  -- Over every surface and empty, not scrolling: a touch reaches the widget against this box, with
  -- its coordinates, the close box's included. Labels take no touch, and the rectangle below starts at the
  -- same corner.
  children[#children + 1] = { type = "box", x = 0, y = 0, w = W, h = H, borderPad = 0, scrollDir = 0, scrollBar = false, children = {} }

  viewport(widget, roll, windows, "reverse", "forward", children, 0, 0, LADDER_SIZE, LADDER_SIZE, colors.head, 0, shown)
  children[#children + 1] = { type = "rectangle", x = 0, y = 0, w = closeX - pad, h = headH, color = colors.head, filled = true }
  local headFont = large and MIDSIZE or nearFont
  children[#children + 1] = {
    type = "label", x = pad, y = math.floor((headH - (large and midH_ or nearH)) / 2), w = statusX - pad, font = headFont,
    text = pathText(roll, source, headFont, statusX - 2 * pad), color = colors.headText, align = LEFT,
  }

  local markW = 2 * nearH
  local leftFace = faceOf(roll, leftLevel(roll).rows, midFont, nearFont, colW - 2 * markW)
  -- While the wheel is on the left the right list changes with every detent and a face is only chosen at a
  -- build, so a list's own face would show on the next list until the wheel rests. The right column keeps the
  -- smaller face throughout, which also leaves nothing to jump at a press or RTN.
  local rightFace = nearFont

  -- A row that cannot be pressed reads paler wherever it stands. Only a menu that has such rows pays
  -- for the colour being asked on every pass.
  local function shaded(side, offset, color, offColor)
    if source.off == nil then return color end
    return function()
      if slotOf(roll, side, offset, slotKey(side, offset)).off == true then return offColor end
      return color
    end
  end

  -- The pictures: the middle row's and its two neighbours', per list. The slots stay and what they show
  -- follows the row; the firmware reads a file only when the name it is given changes.
  local iconSize = large and 32 or 20
  local function iconSlot(side, colX, offset)
    local h = (offset == 0) and midH or rowH
    children[#children + 1] = {
      type = "image", x = colX + pad, y = slotY(offset) + math.floor((h - iconSize) / 2), w = iconSize, h = iconSize,
      visible = function()
        local slot = slotOf(roll, side, offset, slotKey(side, offset))
        return slot.icon ~= nil and slot.off ~= true
      end,
      file = function() return slotOf(roll, side, offset, slotKey(side, offset)).icon or "" end,
    }
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
        -- In the accent while it says that a page is opening.
        color = function() return roll.opening ~= nil and colors.accent or colors.muted end, text = subText(roll, side),
      }
    end
    if source.icon ~= nil and math.abs(offset) <= 1 then iconSlot(side, colX, offset) end
    if source.opens ~= nil then
      -- The mark that a row opens something further.
      children[#children + 1] = {
        type = "label", x = colX + colW - pad - markW, y = y, w = markW,
        font = font, align = RIGHT, color = (isMid and hasFocus) and colors.accent or color,
        text = function() return slotOf(roll, side, offset, slotKey(side, offset)).opens == true and ">" or "" end,
      }
    end
    if side == "right" or source.marks then
      -- The choice in force.
      local dot = large and 4 or 3
      children[#children + 1] = {
        type = "circle", x = colX + pad + dot, y = slotY(offset) + math.floor(h / 2), radius = dot, color = colors.accent, filled = true,
        visible = function() return slotOf(roll, side, offset, slotKey(side, offset)).current == true end,
      }
    end
  end
  for offset = -REACH, REACH do
    row("left", leftX, offset)
    if source.details == nil then row("right", rightX, offset) end
  end

  -- Beside a row that cannot be pressed: why, in the place of what it would show.
  if source.reason ~= nil then
    children[#children + 1] = {
      type = "label", x = rightX + 4, y = midY + math.floor((midH - nearH) / 2), w = colW - 8, font = nearFont,
      align = CENTER, color = colors.muted,
      text = function()
        if roll.focus ~= 1 then return "" end
        return slotOf(roll, "left", 0, 0).why or ""
      end,
    }
  end

  -- Beside a row that leads to no list: what is known about it, taking no focus.
  if source.details ~= nil then
    for line = 1, 2 * REACH + 1 do
      local offset = line - REACH - 1
      children[#children + 1] = {
        type = "label", x = rightX + 4, y = slotY(offset) + math.floor(((offset == 0) and midH or rowH) / 2 - nearH / 2),
        w = colW - 8, font = nearFont, align = CENTER, color = colors.text,
        text = function()
          local item = slotOf(roll, "left", 0, 0).item
          local lines = item and source.details(item) or nil
          -- The lines stand around the middle slot.
          local first = lines and (REACH + 1 - math.floor((#lines - 1) / 2)) or 1
          return lines and lines[line - first + 1] or ""
        end,
      }
    end
  end

  local right = roll.levels[roll.base + 1]
  local question = onRight and right and right.question or nil
  if question ~= nil then
    children[#children + 1] = {
      type = "label", x = rightX + pad, y = headH + 2, w = colW - 2 * pad, font = farFont, align = LEFT, color = colors.text,
      text = questionText(question),
    }
  end

  -- In the header: how a write went.
  if source.status ~= nil then
    children[#children + 1] = {
      type = "label", x = math.floor(W / 2), y = math.floor((headH - farH) / 2), w = closeX - pad - math.floor(W / 2),
      font = farFont, align = RIGHT,
      color = function()
        local _, role = source.status(roll)
        return colors[role or "headText"] or colors.headText
      end,
      text = function() return source.status(roll) or "" end,
    }
  end
end

return M
