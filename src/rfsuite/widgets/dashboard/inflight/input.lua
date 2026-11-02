-- The overlay owns PAGE/RTN ahead of the dashboard's build jobs and theme bindings. The encoder
-- remains an LVGL input device: Lua never receives EVT_ROTARY_* in a useLvgl widget. A one-row
-- viewport observes the scroll caused by focus moving between its full-height buttons.
local M = {}

local requireModule = _G.rfsuite and _G.rfsuite.require
local Log = requireModule and requireModule("lib/log.lua")

local function trace(kind, value, reason)
  if Log and Log.wanted("debug") then
    Log.emit("rfsuite.inflight.input", kind .. " value=" .. tostring(value) .. " result=" .. tostring(reason), "debug")
  end
end

function M.rebuild(widget, row)
  local drive = widget._inflight
  if not (drive and drive.live == true and drive.phase == "live") then return end
  local sensor = widget._inflightSensor
  if sensor then
    if sensor.rebuildRequested then return end
    sensor.rebuildRequested = true
  end
  drive.ladderEpoch = (drive.ladderEpoch or 0) + 1
  -- The snapshot is republished only when the layout epoch moves.
  drive.valueEpoch = (drive.valueEpoch or 0) + 1
  widget._tuningKeyDirty = true
  trace("ladder rebuild row=" .. tostring(row), row, "requested")
end

-- The same close is used by the touch box and RTN. Cancel a pending build before leaving: a
-- build-job pass can otherwise draw the overlay again after its input has already closed it.
function M.dispatch(widget, action, direction, source, index)
  local drive = widget and widget._inflight
  if drive == nil then return false, "no_drive" end
  -- A pointer can focus a touch control without traversing the encoder's guard rows. Fence the
  -- first sensor return even when that control's action is refused by the pulse owner.
  local sensor = widget._inflightSensor
  if sensor and (source == "touch" or source == "touch_hold") then sensor.index = nil end
  local armed = widget.state and widget.state.armed == true
  if drive.fcSetupOpen and drive.fcSurface and not armed then
    if action == "back" then
      local phase = drive.fcSetup and drive.fcSetup.phase
      if phase ~= "saving" and phase ~= "reread" then drive.fcSurface.close(widget, drive) end
      return true
    end
    return false, "setup"
  end
  local now = drive.radio.now()
  if action == "back" and drive.backHandledAt == now then return true end
  if action == "back" or action == "leave" then drive.backHandledAt = now end
  local ok, reason = drive:dispatch(action, direction, source, index, armed)
  if ok then widget._tuningKeyDirty = true end
  -- Touch moves native focus out of the ladder even when the action is refused. Keep a held
  -- button alive until release; rebuilding then returns focus to the fullscreen widget.
  if source == "touch" or (source == "touch_hold" and action == "release") then M.rebuild(widget) end
  if drive.closeRequested then
    drive.closeRequested = nil
    widget.inflightFullscreen = nil
    widget._job = nil
    widget.built, widget.renderKey = false, nil
    if widget.state then widget.state.inflight = nil end
  end
  trace("dispatch " .. action .. " source=" .. tostring(source) .. " index=" .. tostring(index),
    direction, ok and "accepted" or reason)
  return ok, reason
end

function M.key(widget, event)
  if event == nil or event == 0 then return false end
  local drive = widget and widget._inflight
  local nextPage, prevPage, exit = _G.EVT_VIRTUAL_NEXT_PAGE, _G.EVT_VIRTUAL_PREV_PAGE, _G.EVT_VIRTUAL_EXIT
  if nextPage ~= nil and event == nextPage then
    M.dispatch(widget, drive and drive.valueMode and "function" or "group", 1, "key")
  elseif prevPage ~= nil and event == prevPage then
    M.dispatch(widget, drive and drive.valueMode and "function" or "group", -1, "key")
  elseif exit ~= nil and event == exit then
    M.dispatch(widget, "back", nil, "key")
  elseif _G.EVT_VIRTUAL_ENTER ~= nil and event == _G.EVT_VIRTUAL_ENTER and drive and drive.groupPicker then
    -- Before native focus enters a group button, ENTER keeps the current group.
    M.dispatch(widget, "pick", nil, "encoder", drive.group)
  elseif _G.EVT_VIRTUAL_ENTER ~= nil and event == _G.EVT_VIRTUAL_ENTER and widget._inflightSensor then
    -- Before native focus enters a child, ENTER is delivered by the fullscreen widget.
    M.dispatch(widget, drive.valueMode and "leave" or "select", nil, "encoder", drive.entry)
  else
    return false
  end
  trace("key", event, "consumed")
  return true
end

-- Selection and reports are reactive on the live surface. Ground/post surfaces still use their
-- epoch because completed reads and transfers change their controls. Never key a live scene on
-- a cell, an input counter or the value epoch: that would delete the object observing focus.
function M.renderKey(snapshot)
  if snapshot.linkLost == true then return "link_lost" end
  if snapshot.phase == "live" then
    return tostring(snapshot.live) .. "|" .. tostring(snapshot.groups) .. "|" .. tostring(snapshot.group) .. "|"
      .. tostring(snapshot.valueMode) .. "|" .. tostring(snapshot.groupPicker) .. "|" .. tostring(snapshot.profileRefusal)
      .. "|" .. tostring(snapshot.ladderEpoch)
  end
  -- The ground surface sizes its model row by the verdict it is built with (screen.lua, buildGround).
  return tostring(snapshot.bank) .. "|" .. tostring(snapshot.row) .. "|" .. tostring(snapshot.epoch)
    .. "|" .. tostring(snapshot.setupVerdict)
end

M.LADDER_ROWS = 64

function M.ready(widget)
  local sensor = widget._inflightSensor
  if sensor then sensor.building = false end
end

-- Guard buttons separate the list and the other overlay controls from real rows.
function M.sensor(widget, rowHeight, count, valueMode)
  local drive = widget._inflight
  local start = valueMode and math.floor(count / 2) or drive.entry
  local sensor = { row = start, index = start, y = (start - 1) * rowHeight,
    building = true, positions = {}, indices = {} }
  widget._inflightSensor = sensor
  local group, groups = drive.group, drive.groups
  local positions, indices = sensor.positions, sensor.indices
  for index = 1, count do
    positions[index] = (index - 1) * rowHeight
    indices[index] = index
  end
  local function current()
    return widget._inflightSensor == sensor and drive.live and drive.phase == "live"
      and drive.group == group and drive.groups == groups and drive.valueMode == valueMode
  end
  local function endFeedback()
    return M.dispatch(widget, "function", nil, "encoder", count + 1)
  end
  -- The native focus walk is the creation-order list of the scene, with wrap: past the last row of
  -- a half it continues into the touch controls, and moving pixels does not move that list. So the
  -- ladder is not recentred in place; before a half runs out the live scene is rebuilt, the new
  -- ladder starts in the middle again, and the first detent after a build lands on a half's entry
  -- row. The rows left before the end absorb the detents that arrive while the build is pending.
  sensor.first = start + 1
  sensor.scrollTo = function() return 0, sensor.y end
  sensor.position = function(index)
    return function() return 0, sensor.positions[index] end
  end
  local function pressed(index)
    local ok, reason = false, "stale"
    if current() and not sensor.building then
      if not valueMode and (sensor.split or index > count or index < 1) then
        ok, reason = M.dispatch(widget, "select", nil, "encoder", drive.entry)
      else
        ok, reason = M.dispatch(widget, valueMode and "leave" or "select", nil, "encoder", index)
      end
    end
    trace("press row=" .. tostring(index), index, ok and (valueMode and "leave" or "select") or reason)
    return ok, reason
  end
  sensor.press = function(index)
    return function() return pressed(index) end
  end
  -- All neutral value buttons perform the same operation; their row is already cached by scroll.
  sensor.leave = function() return pressed(sensor.index or count + 1) end
  sensor.scrolled = function(x, y)
    local row = math.floor(y / rowHeight + 0.5) + 1
    local delta = row - sensor.row
    local function result(decision, ok)
      if decision ~= "unchanged" then
        trace("scrolled y=" .. tostring(y) .. " row=" .. tostring(row) .. " delta=" .. tostring(delta), x, decision)
      end
      return ok == true, decision
    end
    if not current() then return result("stale") end
    if sensor.building then return result("building") end
    -- Fractional touch drags and elastic overscroll are not focus moves to full rows.
    if x ~= 0 or row < 0 or row > count + 2 or y ~= (row - 1) * rowHeight then
      -- Retain the raw viewport position so scrollTo does not fight a finger dragging the list.
      if x == 0 and y >= 0 and y <= (count + 1) * rowHeight then sensor.y = y end
      return result("partial")
    end
    local index = sensor.indices[row]
    local previous = sensor.index
    sensor.row, sensor.index, sensor.y = row, index, y
    if delta == 0 then return result("unchanged") end
    if index == nil or previous == nil then
      if not valueMode then endFeedback() end
      if index == nil then M.rebuild(widget, row) end
      return result("focus_boundary")
    end
    if math.abs(delta) > 1 then
      if not valueMode then endFeedback() end
      if valueMode and (row <= 4 or row > count - 4) then M.rebuild(widget, row) end
      return result("jump")
    end
    -- Baseline first, even on refusal. No callback is kept for replay after the pulse/gap.
    local ok, reason
    if valueMode then
      ok, reason = M.dispatch(widget, "step", delta, "encoder")
      if row <= 4 or row > count - 4 then M.rebuild(widget, row) end
    else
      local target
      if not sensor.split then target = index end
      ok, reason = M.dispatch(widget, "function", delta, "encoder", target)
    end
    return result(ok and (valueMode and "step" or "function") or reason, ok)
  end
  -- Native focus initially belongs to the fullscreen widget. The forward half is created
  -- first and the reverse half last, around the touch controls. Each starts scrolled one
  -- row away from its entry button. Crossing between halves resets only the inactive
  -- viewport; those programmatic scrolls are acknowledged without dispatching input.
  sensor.windows = function()
    sensor.split = true
    local windows = {
      forward = {y = sensor.y}, reverse = {y = start * rowHeight}
    }
    local entered
    local function view(side, other, entry, direction)
      local window = windows[side]
      return {
        scrollTo = function() return 0, window.y + rowHeight end,
        opacity = function() return (sensor.side or "forward") == side and 255 or 0 end,
        position = function(index)
          return function() return 0, sensor.positions[index] + rowHeight end
        end,
        scrolled = function(x, y)
          y = y - rowHeight
          if window.pending ~= nil and y == window.pending then
            window.pending = nil
            return
          end
          if window.y == y then return end
          window.y = y
          if not current() or sensor.building then return end
          if not entered and direction < 0 and y == sensor.positions[start] then
            sensor.row = math.floor(y / rowHeight) + 2
          end
          entered, sensor.side = true, side
          sensor.scrolled(x, y)
          local inactive = windows[other]
          inactive.y = sensor.positions[entry] + direction * rowHeight
          inactive.pending = inactive.y
        end
      }
    end
    return view("forward", "reverse", start, 1), view("reverse", "forward", start + 1, -1)
  end
  return sensor
end

return M
