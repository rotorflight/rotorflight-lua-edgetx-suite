--[[
  Lightweight events manager for RFSuite (EdgeTX port)
  - Monitors MSP runtime and sets `rfsuite.session.isConnected` with hysteresis
  - Minimal dependency set to avoid heavy startup costs
]]

if type(_G) == "table" and type(_G.__rfsuite_events_module) == "table" then
  return _G.__rfsuite_events_module
end

local Events = {}

local function loadModule(path)
  if _G.rfsuite and _G.rfsuite.require then
    return _G.rfsuite.require(path)
  end
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local MspRuntime = nil
local Log = nil
local Env = nil
local ModelNameStore = nil
local FlightRecord = nil
-- The Tune Advisor capture (tasks/events/tune_capture.lua), loaded only while a capture has work
-- and is due. See driveTuneCapture.
local TuneCapture = nil

-- Per-category task runners cache will be stored at `_G.rfsuite.tasks.events`
local function ensureEventRunner(name)
  if type(name) ~= "string" then return nil end
  _G.rfsuite = _G.rfsuite or {}
  _G.rfsuite.tasks = _G.rfsuite.tasks or {}
  _G.rfsuite.tasks.events = _G.rfsuite.tasks.events or {}
  local cached = _G.rfsuite.tasks.events[name]
  if type(cached) == "table" then return cached end
  if cached == false then return nil end

  local ok, mod = pcall(loadModule, "tasks/events/" .. name .. "/tasks.lua")
  if not ok or type(mod) ~= "table" then
    if Log and type(Log.emit) == "function" then
      pcall(Log.emit, "rfsuite.events", "no runner for events/" .. tostring(name), "debug")
    end
    _G.rfsuite.tasks.events[name] = false
    return nil
  end

  _G.rfsuite.tasks.events[name] = mod
  return mod
end

local CONNECT_STABLE_SECONDS = 0.6
local DISCONNECT_STABLE_SECONDS = 2.0
-- How long a link that came back after a loss in flight waits for an armed reading the radio has
-- received since, before it is taken for a new session after all. See settleFlightAfterGap.
local FLIGHT_CONFIRM_SECONDS = 5.0

local state = {
  linkUpSince = nil,
  linkDownSince = nil,
  linkStableUp = false,
  lastArmed = nil,
  -- Which arm/disarm category still has work, if either does. See driveEdgeRunner below.
  edgeRunner = nil,
  -- The link went down while the craft was armed, and the flight was kept rather than dropped.
  flightKept = false,
  -- The link is back after such a loss, and whether the craft is still flying is not known yet:
  -- the time it came back, until settleFlightAfterGap decides.
  flightPendingSince = nil,
}

-- The argument a runner's wakeup is called with. One table for every call rather than a
-- constructor per call: onconnect is woken on every pass while the link is up, for as long as
-- the script runs. `context` is set immediately before each call. Reusing it is safe only while
-- no task keeps it or writes into it: runner.wakeup in common/runner.lua hands it to the task
-- as `pcall(module.wakeup, args)`, and every task under tasks/events/ either ignores it or hands
-- it to a task in common/ that ignores it. A task that stored it (`M.args = args`) would read what
-- the latest call set, and a field a task wrote into it would reach every later call, so a task
-- that needs `context` after its call copies the string.
local wakeupArgs = { context = nil }

-- One pass of an arm or disarm runner, and whether it still has work.
--
-- The runner completes AT MOST ONE task per wakeup by design: it takes the first eligible entry
-- of the manifest, calls it and returns. So an edge that wakes it exactly once runs the first
-- entry and nothing else -- and not even that one to the end, because a task waiting on an MSP
-- reply needs a later pass to report itself complete. Measured on the disarm chain: `flight_stats`
-- was started and never marked complete, and `dataflash_summary` behind it was never started at
-- all. `onconnect` above does not have this problem because it is called on every pass while it
-- says it is active; this is the same shape for the two edge categories.
local function driveEdgeRunner(category, context)
  local runner = ensureEventRunner(category)
  if not runner then return false end

  if type(runner.wakeup) == "function" then
    wakeupArgs.context = context
    local ok, err = pcall(runner.wakeup, wakeupArgs)
    if not ok and Log and type(Log.emit) == "function" then
      pcall(Log.emit, "rfsuite.events", category .. ".wakeup error: " .. tostring(err), "error")
    end
  end

  if type(runner.active) == "function" then
    local ok, active = pcall(runner.active)
    return ok and active == true
  end
  return false
end

local function ensureDeps()
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not Log then Log = loadModule("lib/log.lua") end
  if not Env then Env = loadModule("lib/env.lua") end
end

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, v = pcall(getTime)
    if ok and type(v) == "number" then return v / 100 end
  end
  if type(os) == "table" and type(os.clock) == "function" then return os.clock() end
  return 0
end

local function ensureSession()
  _G.rfsuite = _G.rfsuite or {}
  _G.rfsuite.session = _G.rfsuite.session or {}
end

local function modelNameStore()
  if ModelNameStore == nil then
    ModelNameStore = loadModule("lib/model_name_store.lua") or false
  end
  if type(ModelNameStore) ~= "table" then return nil end
  return ModelNameStore
end

-- A link coming up is, as far as anything here can tell, a fresh pack and a fresh session, and
-- that is what ends the record of the one before it: the statistics and the flight clock go, and
-- the board's flight count is zeroed until the connect chain has read this board's. A record
-- still open has no honest end to it and goes with them.
local function endSession(session)
  session.flightcount = 0
  -- A flight controller that answered the Tune Advisor with "no such command" is asked again on
  -- the next connection: it may have been flashed in between.
  if type(session.tuneCapture) == "table" then session.tuneCapture.noCommand = nil end
  if FlightRecord and type(FlightRecord.reset) == "function" then
    pcall(FlightRecord.reset)
  end
end

-- A flight kept across a link loss that did not go on: what the disconnect and the connect edge
-- would have done to it, done now. The flight log's entry goes with the record -- the craft
-- disarmed somewhere in the gap, so there is no honest duration and no line. The arm-edge
-- detector is reset as the disconnect resets it (#278), so a craft that is armed after all opens
-- a record of its own from here.
-- Not through lib/require.lua, and not through the caching loader a tool hosted by the dashboard
-- puts over loadScript (widgets/dashboard/tool_host.lua): the capture's code leaves once it has
-- nothing left to do.
local function loadPlain(path)
  local utils = _G.rfsuite and _G.rfsuite.utils
  local loader = utils and utils.loadScriptUncached or loadScript
  local chunk = loader("/SCRIPTS/TOOLS/rfsuite-core/" .. path, (_G.rfsuite and _G.rfsuite.loadMode) or "bt")
  if type(chunk) ~= "function" then return false end
  local ok, mod = pcall(chunk)
  return ok and type(mod) == "table" and mod or false
end

local function endKeptFlight(session)
  session.flightlog = nil
  endSession(session)
  state.lastArmed = false
  -- The flight controller kept the Tune Advisor's numbers of the flight that ended in the gap,
  -- so they are still owed to the flight history -- the one thing of that flight that is.
  if Env and Env.get() == "widget" then
    local disarm = loadPlain("tasks/events/ondisarm/tasks/tune_history.lua")
    if disarm and type(disarm.owe) == "function" then
      pcall(disarm.owe, session, nowSeconds())
    end
  end
end

-- Whether a flight kept across a link loss went on. A sensor can keep the state from before the
-- loss until a decoder writes it again, so the armed state tick() reads cannot say; a reading
-- the radio has received since the link came back can (MspRuntime.armedReading). Armed: the same
-- flight, and nothing is done. Disarmed: endKeptFlight. No such reading within
-- FLIGHT_CONFIRM_SECONDS: endKeptFlight as well, which is what a reconnect did before a flight
-- was kept at all.
-- The MSP runtime also holds its last armed state while uncertain, bounded by FLIGHT_CONFIRM_SECONDS
-- of continuous uncertainty with the link up.
local function settleFlightAfterGap(t)
  if state.flightPendingSince == nil then return end
  local armed, current = nil, false
  if MspRuntime and type(MspRuntime.armedReading) == "function" then
    local ok, a, c = pcall(MspRuntime.armedReading)
    if ok then armed, current = a, c end
  end
  local outcome
  if current == true then
    outcome = (armed == true) and "armed, the flight goes on" or "disarmed, the flight is not logged"
  elseif (t - state.flightPendingSince) >= FLIGHT_CONFIRM_SECONDS then
    outcome = "not confirmed, a new session"
  else
    return
  end
  local waited = t - state.flightPendingSince
  state.flightPendingSince = nil
  if current ~= true or armed ~= true then
    endKeptFlight(_G.rfsuite.session)
  end
  if Log and type(Log.emit) == "function" then
    pcall(Log.emit, "rfsuite.events",
      string.format("link back after a loss in flight, after %.1fs: %s", waited, outcome), "info")
  end
end

local function publishConnected(val)
  ensureSession()
  local session = _G.rfsuite.session
  if session.isConnected == val then return end
  session.isConnected = val
  session.rfConnected = val
  if val == false then
    session.fblConnected = false
    -- A link lost while the craft is armed is a craft still in the air as far as anything here
    -- can tell -- the pack cannot have been swapped under a flying model -- so its flight is kept
    -- rather than ended here: the flight log's entry, the arm-edge detector and, on the connect
    -- edge below, the record and the flight count. Whether it really is the same flight is only
    -- known once the link is back; settleFlightAfterGap decides it then.
    local inFlight = state.lastArmed == true
    state.flightKept = inFlight
    state.flightPendingSince = nil
    -- The flight log's pending entry belongs to the connection: which battery was picked for it,
    -- and whether a use has already been counted against that pack. A link that comes back is, as
    -- far as anything here can tell, a fresh pack, so the entry is dropped rather than carried
    -- into it -- unless the craft was flying when it went.
    if not inFlight then
      session.flightlog = nil
    end
    -- The flight statistics and the board's flight count are deliberately NOT dropped here. The
    -- link going down is what unplugging the pack after a flight looks like, and the dashboard's
    -- post-flight page reads rfsuite.session.flight for its tiles: a reset at this edge blanked
    -- them the moment the battery came off. Both are dropped when the next session begins, below.
    -- The tool and each widget are separate Lua states holding their own copy of what the card
    -- said, and the state that renames is usually not the state that puts the name back. One
    -- that first read the file while it was still empty would answer "nothing to do" for the
    -- rest of its life, including for a record another state wrote in the meantime. The link
    -- going down is the one moment where re-reading it is both cheap and certain to be worth it,
    -- and it comes before the runner resets below, which read the store themselves.
    local nameStore = modelNameStore()
    if nameStore and type(nameStore.invalidate) == "function" then
      pcall(nameStore.invalidate)
    end
    -- Reset the arm-edge detector so that a reconnect while still armed is seen as a fresh
    -- arm edge (false → true) and triggers Record.open() via the onarm manifest.  Without this,
    -- both `armed` and `state.lastArmed` are still true on the reconnect, the condition
    -- `armed ~= state.lastArmed` is false, and the record is never reopened for the rest of the
    -- flight — leaving Record.close() at the real disarm to overwrite `flight.last` with an
    -- empty record. (#278)
    --
    -- `false` rather than `nil`: the nil-guard two lines above the edge condition silently
    -- initialises `state.lastArmed` to the current armed value without firing an edge, which
    -- would defeat the purpose of the reset.
    --
    -- A kept flight keeps its detector instead: the record is not reset on the reconnect, so
    -- there is nothing to reopen, and the next edge is the flight's own disarm. Where the flight
    -- turns out not to have gone on, endKeptFlight resets it then.
    if not inFlight then
      state.lastArmed = false
    end
  end
  if val == true then
    if state.flightKept then
      -- The record, its clock and the flight count are left as they are until
      -- settleFlightAfterGap knows whether the craft is still flying.
      state.flightKept = false
      state.flightPendingSince = nowSeconds()
    else
      endSession(session)
    end
  end
  if Log and type(Log.emit) == "function" then
    pcall(Log.emit, "rfsuite.events", "session.isConnected=" .. tostring(val), "info")
  end
  if val == false and _G.rfsuite and _G.rfsuite.tasks and _G.rfsuite.tasks.events then
    for name, runner in pairs(_G.rfsuite.tasks.events) do
      if type(runner) == "table" and type(runner.reset) == "function" then
        pcall(runner.reset)
        if Log and type(Log.emit) == "function" then
          pcall(Log.emit, "rfsuite.events", "reset runner " .. tostring(name), "debug")
        end
      end
    end
    if type(collectgarbage) == "function" then
      collectgarbage("collect")
    end
  end
end

-- Put a model name back that the disconnect hook never got to.
--
-- `model_name_sync` restores from its own reset, and that reset is reached only through
-- publishConnected(false) -- i.e. only where something was ticking at the moment the link went.
-- Nothing is ticking when the radio is switched off with a craft still connected, so the model
-- comes back up wearing the craft's name and no event is ever going to say so. The reading side
-- therefore cannot be an event: it is a STATE, checked on a tick that has established there is no
-- craft, which a cold start reaches on its first pass.
--
-- The cost on that tick is the context check below and one boolean. The store answers hasAny() from a flag after its first
-- call, and everything past it -- reading the model, writing to it, touching the card -- happens
-- only where a rename is actually outstanding.
--
-- Only in the context that renames. `model_name_sync` is a `widget` task
-- (tasks/events/onconnect/manifest.lua), so the configuration tool never writes the craft name,
-- and it must not take it off either. While a standalone tool is open EdgeTX runs no widget, so a
-- link that drops and comes back in that time is seen by the tool alone: a restore from the tool
-- puts the model's own name back and spends the record, the tool's reconnect cannot write the
-- craft name again, and the widget, resuming with the link up, has seen no disconnect and does
-- not either -- the model keeps its own name while the craft is connected. A link that is still
-- down when the tool closes is seen by the widget on its next ticks, and a cold start reaches a
-- widget tick like any other, so every case above still has a state that restores.
--
-- One case is left without one: a model that no longer carries the dashboard or the service widget
-- when the link goes, or when the radio starts. Its record stays on the card and the model keeps
-- the craft name until one of the two widgets is on it again, which puts the name back on its first
-- tick without a link; a rename in between takes the recorded name, not the current one, as the
-- original (tasks/events/onconnect/tasks/model_name_sync.lua).
local function restorePendingModelName()
  local context = Env and Env.get() or "tool"
  if context ~= "widget" then return end

  local nameStore = modelNameStore()
  if not nameStore then return end

  local okAny, any = pcall(nameStore.hasAny)
  if not okAny or not any then return end

  local ok, restored = pcall(nameStore.restore)
  if ok and restored and Log and type(Log.emit) == "function" then
    pcall(Log.emit, "rfsuite.events", "model name put back: " .. tostring(restored), "info")
  end
end

-- The Tune Advisor capture's passes. Its state is the session's (rfsuite.session.tuneCapture),
-- which a disarm creates, so a radio that never flew a craft with the command pays one table
-- lookup per pass here.
--
-- Its code is loaded only once the capture is DUE: the first read waits five seconds after the
-- disarm, so nothing of it is compiled or run on the disarm edge or the passes right after it,
-- where the disarm chain does its own work. The load is a pass of its own, and the capture
-- takes no pass the dashboard spends on its telemetry read (`carry`). Once it reports no work
-- left the module is dropped again.
--
-- Arming ends any capture in progress: the flight controller keeps adding to its numbers, so
-- the next disarm reads this flight together with the one it was still reading.
local function driveTuneCapture(capture, armed, linkUp, t, carry, mspState)
  if armed then
    capture.pending = false
    capture.state = "idle"
    TuneCapture = nil
    return
  end
  if carry then return end
  if TuneCapture == nil then
    local work = capture.pending or (capture.clearPending and not capture.refusedOnFc)
      or capture.contextPending
    if not work or t < (capture.nextAt or 0) then return end
    TuneCapture = loadPlain("tasks/events/tune_capture.lua")
    return
  end
  -- A capture whose code cannot be loaded is dropped rather than asked for from the card on
  -- every pass; the next arm lets the next disarm try again.
  if not TuneCapture then
    -- A saved flight whose settings were owed is complete as it is: a reader is told
    if capture.contextPending and type(capture.context) == "table" then
      capture.saved = (capture.saved or 0) + 1
      capture.savedMcu = capture.context.mcuId
    end
    capture.pending, capture.clearPending, capture.contextPending = false, false, false
    capture.state = "idle"
    return
  end
  local ok, more = pcall(TuneCapture.tick, capture, mspState, linkUp, t)
  if not ok and Log and type(Log.emit) == "function" then
    pcall(Log.emit, "rfsuite.events", "tune capture error: " .. tostring(more), "error")
  end
  if not ok or not more then TuneCapture = nil end
end

function Events.reset()
  state.linkUpSince = nil
  state.linkDownSince = nil
  state.linkStableUp = false
  -- A flight kept across a link loss belongs to the link this forgets.
  state.flightKept = false
  state.flightPendingSince = nil
  ensureSession()
  _G.rfsuite.session.isConnected = false
  _G.rfsuite.session.rfConnected = false
  _G.rfsuite.session.fblConnected = false
  _G.rfsuite.session.modelName = nil
end

--- Make the connect tasks run again, and nothing else.
--
-- After a reboot the tasks are all still marked complete, so the work they do at connect --
-- sending the clock among it -- is not redone unless something resets them. The only place
-- that resets a runner today is publishConnected(false), which is reached from the link
-- detector: a reboot short enough not to hold the link down for DISCONNECT_STABLE_SECONDS
-- never gets there. Events.reset() looks like the way to force it and is not -- it clears the
-- link state directly, without touching a single runner.
--
-- This resets the connect runner alone. It leaves session state, the link detector and every
-- other category untouched, and it is idempotent: if the detector did notice the reboot and
-- already reset the runner, calling it again costs one pass over a queue that is going to be
-- rerun anyway.
function Events.rerunOnconnect()
  local onconnect = ensureEventRunner("onconnect")
  if onconnect and type(onconnect.reset) == "function" then
    pcall(onconnect.reset)
    return true
  end
  return false
end

function Events.isOnconnectActive()
  local onconnect = ensureEventRunner("onconnect")
  if onconnect and type(onconnect.active) == "function" then
    return onconnect.active()
  end
  return false
end

function Events.getOnconnectProgress()
  local onconnect = ensureEventRunner("onconnect")
  if onconnect and type(onconnect.getProgress) == "function" then
    return onconnect.getProgress()
  end
  return nil
end

function Events.getOnconnectPendingTaskName()
  local onconnect = ensureEventRunner("onconnect")
  if onconnect and type(onconnect.getPendingTaskName) == "function" then
    return onconnect.getPendingTaskName()
  end
  return nil
end

--- One pass of the event runtime.
--
-- `carry` is the dashboard widget's: true on a pass that also runs its telemetry read, so that the
-- work in here that need not share that pass waits one logic tick -- today SmartFuel's wake, in
-- telemetry_bg/tasks.lua. Every other caller passes nothing.
function Events.wakeup(carry)
  ensureDeps()
  if not MspRuntime or type(MspRuntime.getState) ~= "function" then return end
  local mspState = MspRuntime.getState()
  if type(mspState) ~= "table" then return end

  local connected = mspState.lastConnected == true
  local t = nowSeconds()

  if connected then
    state.linkDownSince = nil
    if not state.linkUpSince then state.linkUpSince = t end
    if not state.linkStableUp and (t - state.linkUpSince) >= CONNECT_STABLE_SECONDS then
      state.linkStableUp = true
      publishConnected(true)
    end
  else
    state.linkUpSince = nil
    if not state.linkDownSince then state.linkDownSince = t end
    if state.linkStableUp and (t - state.linkDownSince) >= DISCONNECT_STABLE_SECONDS then
      state.linkStableUp = false
      publishConnected(false)
    end
    -- Only once the link is HELD to be down. The two seconds above exist because a brief
    -- telemetry dropout is not a disconnect, and a restore inside one would rename the model in
    -- flight and spend the record -- while linkStableUp never changed, so the returning link
    -- publishes no connect and nothing writes the craft name back for the rest of the flight. A
    -- cold start is unaffected: linkStableUp starts false, so the first pass still restores.
    if not state.linkStableUp then
      restorePendingModelName()
    end
  end
  if state.flightPendingSince ~= nil and state.linkStableUp then
    settleFlightAfterGap(t)
  end
  -- Trigger per-category runners
  do
    -- onconnect: call runner while linkStableUp is true (runner progresses internally)

    -- Determine context: widget/tool/both
    local context = Env and Env.get() or "tool"

    local armed = mspState and mspState.lastArmed == true

    -- A board whose MSP API version was refused gets no connect chain: the MSP runtime sends
    -- nothing to it, so every task would only wait out its timeout and retries in turn. The
    -- refusal is reported by the tool's notice and the dashboard's status line instead.
    local refused = mspState.unsupportedApi == true

    local onconnectActive = false
    if state.linkStableUp and not armed and not refused then
      local onconnect = ensureEventRunner("onconnect")
      if onconnect then
        local wasActive = false
        if type(onconnect.active) == "function" then
          wasActive = onconnect.active()
        end
        if type(onconnect.wakeup) == "function" then
          wakeupArgs.context = context
          local ok, err = pcall(onconnect.wakeup, wakeupArgs)
          if not ok and Log and type(Log.emit) == "function" then
            pcall(Log.emit, "rfsuite.events", "onconnect.wakeup error: " .. tostring(err), "error")
          end
        end
        if type(onconnect.active) == "function" then
          onconnectActive = onconnect.active()
        end
        if wasActive and not onconnectActive then
          if Log and type(Log.emit) == "function" then
            pcall(Log.emit, "rfsuite.events", "onconnect tasks finished, running GC", "info")
          end
          if type(collectgarbage) == "function" then
            collectgarbage("collect")
          end
        end
      end
    end

    -- Defer telemetry_bg until onconnect tasks are done to avoid blocking the Lua VM during startup
    -- Also run telemetry_bg when armed so CRSF custom frames are parsed to keep telemetry active and update disarm state
    --
    -- The deferral is a WIDGET one, and the third term is what keeps it from reaching the tool.
    -- What it protects is the per-call instruction ceiling the firmware puts on a widget:
    -- lua_widget.cpp arms lsWidgets with a count hook of 20000/100 before every call, and
    -- standalone_lua.cpp creates lsStandalone with no count hook at all, so a tool call is not
    -- billed against that ceiling and has nothing to be deferred out of.
    --
    -- What a tool does have instead is a monopoly on the interpreter. Starting a standalone
    -- script sets luaState = INTERPRETER_PAUSED ("Pause function and mixer scripts"), and
    -- interface.cpp runs nothing in that state -- so SCRIPTS/FUNCTIONS/rfsbg.lua, which decodes
    -- the same custom telemetry frames for the rest of the radio, is stopped for as long as the
    -- tool is open. This drain is then the only decoder there is, and while it is deferred the
    -- tool publishes no sensor from frame 0x88 at all. The one that costs something is ARM:
    -- tasks/msp/runtime.lua reads the armed state off that sensor and empties the MSP queue on
    -- it, so with the drain deferred the gate cannot fire for the whole connect sequence and the
    -- sequence keeps sending -- including MSP_SET_RTC -- to a flight controller that has armed.
    if state.linkStableUp and (not onconnectActive or armed or context == "tool") then
      local telemetry_bg = ensureEventRunner("telemetry_bg")
      if telemetry_bg and type(telemetry_bg.wakeup) == "function" then
        local ok, err = pcall(telemetry_bg.wakeup, carry)
        if not ok and Log and type(Log.emit) == "function" then
          pcall(Log.emit, "rfsuite.events", "telemetry_bg.wakeup error: " .. tostring(err), "error")
        end
      end
    end

    -- arm/ disarm transitions: detect changes and call corresponding runners (linkStableUp only).
    -- Not while a flight kept across a link loss is still being settled: `armed` may be the
    -- reading from before the loss, and an edge taken off it would open or close a flight that
    -- nothing has seen.
    if state.linkStableUp and state.flightPendingSince == nil then
      if state.lastArmed == nil then
        state.lastArmed = armed
      end
      if armed ~= state.lastArmed then
        state.lastArmed = armed
        local category = armed and "onarm" or "ondisarm"
        local runner = ensureEventRunner(category)
        if runner and type(runner.resetAllTasks) == "function" then
          -- Reset on BOTH edges, because neither is a one-off. The runner marks a task complete
          -- when it reports itself finished and never looks at it again; without this the first
          -- arm of a session would be the only one an onarm task ever saw. A task that does not
          -- report itself finished fares no better: it is re-queued on a timeout it can only meet
          -- by being called twice inside 25 s, and the runner gives up on it after three rounds.
          local ok, err = pcall(runner.resetAllTasks)
          if not ok and Log and type(Log.emit) == "function" then
            pcall(Log.emit, "rfsuite.events", category .. ".resetAllTasks error: " .. tostring(err), "error")
          end
        end
        state.edgeRunner = category
      end
    end

    -- Driven until it says it has nothing left, not once at the edge -- see driveEdgeRunner.
    if state.edgeRunner then
      if not driveEdgeRunner(state.edgeRunner, context) then
        state.edgeRunner = nil
      end
    end

    -- The flight record, last: on the arm edge the runner above has just opened it in this same
    -- wakeup, so the first sample belongs to the new flight and not to the one before it; on the
    -- disarm edge it has just been closed, and `armed` is already false, so nothing is sampled
    -- into a record that has been put away.
    --
    -- Widget context only. The record belongs to the widget that runs this work; the tool has a
    -- clock of its own and is not a second writer.
    --
    -- `connected` is this pass's raw link state, not the held one: the MSP runtime ticked just
    -- before this wakeup, and EdgeTX answers getRSSI() with 0 on the same condition on which it
    -- answers every telemetry source with 0. The record samples nothing while it is false. (The two
    -- are read a moment apart in the pass, so a gap that starts between them can still let one
    -- sample through.)
    if context == "widget" then
      if FlightRecord == nil then
        FlightRecord = loadModule("tasks/events/telemetry/flight_record.lua") or false
      end
      if FlightRecord then
        local ok, err = pcall(FlightRecord.wakeup, armed, connected)
        if not ok and Log and type(Log.emit) == "function" then
          pcall(Log.emit, "rfsuite.events", "flight_record.wakeup error: " .. tostring(err), "error")
        end
      end
      -- After the record, so a disarm's own work keeps the order it had. `armed` is only taken
      -- as the craft's state while the link is held up and no kept flight is being settled,
      -- the same condition the edge detector above runs under. The session is there: the widget
      -- context is read off it.
      local capture = _G.rfsuite.session.tuneCapture
      if capture ~= nil then
        local trusted = state.linkStableUp and state.flightPendingSince == nil
        driveTuneCapture(capture, armed and trusted, trusted, t, carry, mspState)
      end
    end
  end
end

if type(_G) == "table" then
  _G.__rfsuite_events_module = Events
end

return Events
