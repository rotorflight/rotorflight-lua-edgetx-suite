-- The post-flight theme reload does not share a widget call with the disarm's flight log write.
-- Offline:
--
--   lua5.3 bin/dashboard/verify_disarm_reload_hold.lua
--   lua5.3 bin/dashboard/verify_disarm_reload_hold.lua --verbose
--
-- On a disarm the dashboard's event runtime starts the ondisarm tasks in the widget's own calls,
-- one logic tick after another, and the flight log task writes the flight to the card in one of
-- them. The phase change follows the telemetry read cadence, so without a hold the post-flight
-- reload can run in the same widget call as the flight log write, the read and the first
-- post-flight reads -- a call EdgeTX can stop at its instruction limit.
--
-- The dashboard's real runtime runs in the accounting world (bin/accounting/stubs): settled on
-- the reference theme, armed, flown, disarmed, with the flight log switched on. The stub clock
-- moves one host cycle (0.1 s) per call, and five more while the flight log opens its file for
-- writing, which stands in for the write's wall time (the two meet at the same phases without
-- it). The disarm is moved across ten cadence phases, one pass apart, because which pass the
-- 0.5 s read falls on decides whether the two meet.
--
-- What is checked, at every phase:
--   logged    the flight log reports the flight written ("flight logged"), so the run reaches
--             the path at all, and the pass that reports it is the write's pass;
--   held      while the reload waits, the event runtime names the ondisarm runner as the edge
--             still driven (Events.edgeChainActive);
--   loaded    the post-flight theme module is loaded within six seconds of the disarm by the
--             stub clock, and a theme is still standing on that state at the end;
--   apart     the post-flight module is loaded on a later pass than the one that wrote the log;
--   waited    the ondisarm runner has nothing left at the end of the pass that loads it (the
--             runner may finish in that same pass, before the reload), or the load is not before
--             three seconds after the disarm (the hold's limit).
-- Exit status: 0 green, 1 failed expectations, 2 invalid arguments.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]dashboard$") or (dir .. "/../..") end
end

local verbose = false
for i = 1, #arg do
  if arg[i] == "--verbose" then
    verbose = true
  else
    io.stderr:write("usage: lua5.3 bin/dashboard/verify_disarm_reload_hold.lua [--verbose]\n")
    os.exit(2)
  end
end

local Stubs = assert(loadfile(ROOT .. "/bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile(ROOT .. "/bin/accounting/stubs/fc.lua"))()

local SENSORS = {
  ["Vbat"] = 24.6, ["Curr"] = 3.2, ["Capa"] = 850, ["Bat%"] = 74, ["Cel#"] = 6,
  ["Hspd"] = 1750, ["RQly"] = 96, ["1RSS"] = -42, ["2RSS"] = -45, ["Vbec"] = 8.1,
  ["EscT"] = 48, ["Tmcu"] = 39, ["Thr%"] = 12, ["PID#"] = 1, ["RTE#"] = 1, ["BatP"] = 1,
  ["ARM"] = 0, ["ARMD"] = 0, ["Gov"] = 4,
}

local failures = 0
local checks = 0
local function check(ok, label, detail)
  checks = checks + 1
  if ok then
    if verbose then print("ok   " .. label .. (detail and ("  (" .. detail .. ")") or "")) end
  else
    failures = failures + 1
    print("FAIL " .. label .. (detail and ("  (" .. detail .. ")") or ""))
  end
end

-- The flight log's card write: the clock moves while it opens the file, once per flight.
local writes = 0
local stalled = false
local realOpen = io.open
io.open = function(path, mode, ...)
  if type(path) == "string" and string.find(path, "flightlog", 1, true) and type(mode) == "string"
      and (string.find(mode, "a", 1, true) or string.find(mode, "w", 1, true)) then
    writes = writes + 1
    if not stalled then
      stalled = true
      for _ = 1, 5 do Stubs.tick() end
    end
  end
  return realOpen(path, mode, ...)
end

-- A fresh world: the stubs reinstalled (which also clears the modules parked in _G), the flight
-- log's two firmware calls the accounting world does not provide for widgets, and the sensors.
local function freshWorld()
  Stubs.clearCard()
  Stubs.install(ROOT)
  FC.install(Stubs)
  Stubs.reset()
  FC.reset()
  for k, v in pairs(SENSORS) do Stubs.sensors[k] = v end
  _G.getDateTime = function() return { year = 2026, mon = 1, day = 1, hour = 12, min = 0, sec = 0 } end
  -- The stub answers fstat for the preference files only; the flight log verifies its own write.
  local stubFstat = _G.fstat
  _G.fstat = function(path, ...)
    if type(path) == "string" and string.find(path, "flightlog", 1, true) then
      local f = realOpen(path, "rb")
      if not f then return nil end
      local size = f:seek("end")
      f:close()
      return { size = size, attrib = 0, time = { year = 2026, mon = 1, day = 1, hour = 12, min = 0, sec = 0 } }
    end
    return stubFstat(path, ...)
  end
  stalled = false
end

local function pass(widget)
  Stubs.tick()
  widget.refresh(widget, nil, nil)
end

local function runPhase(pad)
  freshWorld()
  local Runtime = assert(loadfile(ROOT .. "/src/rfsuite/widgets/dashboard/runtime.lua"))()
  local widget = Runtime.new({ x = 0, y = 0, w = 800, h = 458 }, {})
  widget.preferences = widget.preferences or {}
  widget.preferences.dashboard = { theme_preflight = "system/default", standby_intro_seen = true }
  local flightlog = { enabled = true, min_seconds = 5, ask_on_connect = false, set_fc_profile = false }
  widget.preferences.flightlog = flightlog
  _G.rfsuite.preferences.flightlog = flightlog

  for _ = 1, 400 do pass(widget) end

  local function moving(i, throttle)
    local k = i % 8
    Stubs.sensors["Hspd"] = 1500 + k * 100
    Stubs.sensors["Curr"] = 10 + k
    Stubs.sensors["Vbat"] = 23 + k / 10
    Stubs.sensors["EscT"] = 40 + k
    Stubs.sensors["Thr%"] = throttle + k
  end

  Stubs.sensors["Gov"] = 2
  Stubs.sensors["ARM"] = 1
  for i = 1, 240 do moving(i, 20); pass(widget) end
  Stubs.sensors["Gov"] = 4
  for i = 1, 120 + pad do moving(i, 40); pass(widget) end
  local wasInflight = widget.flightMode == "inflight"

  local postKey = widget.themeStateKeys and widget.themeStateKeys.postflight
  local Events = _G.rfsuite.require("tasks/events/runtime.lua")
  Stubs.sensors["ARM"] = 0
  Stubs.sensors["Gov"] = 0
  Stubs.sensors["Thr%"] = 0
  local disarmAt = getTime()
  local r = { loggedPass = nil, loadedPass = nil, loadedAfter = nil, held = false, chainAtLoad = nil }
  local function chain()
    return type(Events.edgeChainActive) == "function" and Events.edgeChainActive() or nil
  end
  for i = 1, 70 do
    local seq0 = _G.rfsuite.log_history_seq or 0
    local key0 = widget.themeStateKey
    pass(widget)
    local history = _G.rfsuite.log_history or {}
    local added = (_G.rfsuite.log_history_seq or 0) - seq0
    for k = math.max(1, #history - added + 1), #history do
      if string.find(history[k].msg, "flight logged", 1, true) == 1 then r.loggedPass = r.loggedPass or i end
    end
    if r.loadedPass == nil and key0 ~= postKey and widget.themeStateKey == postKey then
      r.loadedPass, r.loadedAfter, r.chainAtLoad = i, (getTime() - disarmAt) / 100, chain()
    end
    if r.loadedPass == nil and chain() == "ondisarm" then r.held = true end
  end
  -- A theme module that failed to load leaves the requested state key behind with no theme table.
  r.standing = postKey ~= nil and widget.themeStateKey == postKey and type(widget.theme) == "table"
  return wasInflight, r
end

for pad = 0, 9 do
  writes = 0
  local inflight, r = runPhase(pad)
  local tag = "phase " .. pad
  check(inflight, tag .. ": the flight reaches the inflight phase before the disarm")
  check(r.loggedPass ~= nil, tag .. ": logged -- the flight log reports the flight written",
    r.loggedPass and ("pass " .. r.loggedPass) or (writes .. " open(s) for writing, no report"))
  check(r.held, tag .. ": held -- the event runtime names the ondisarm runner while the reload waits")
  check(r.loadedAfter ~= nil and r.loadedAfter <= 6.0 and r.standing,
    tag .. ": loaded -- the post-flight module within six seconds of the disarm, and still standing",
    r.loadedAfter and string.format("%.1f s", r.loadedAfter) or "never")
  check(r.loadedPass ~= nil and r.loggedPass ~= nil and r.loadedPass > r.loggedPass,
    tag .. ": apart -- the post-flight module is loaded after the pass that wrote the flight log",
    string.format("written pass %s, loaded pass %s", tostring(r.loggedPass), tostring(r.loadedPass)))
  check(r.chainAtLoad ~= "ondisarm" or (r.loadedAfter or 0) >= 3.0,
    tag .. ": waited -- loaded with the disarm's tasks done, or not before three seconds after the disarm",
    string.format("runner %s after the loading pass, %.1f s", tostring(r.chainAtLoad), r.loadedAfter or -1))
end

-- The foreground guard during a hold that began after the reload had already been carried off a
-- read pass: in fullscreen (an event number, 0 when idle) the surface keeps building, outside it
-- nothing is queued for the theme about to be replaced. Called without moving the stub clock, so
-- the logic tick is throttled and the two flags stand as set (checked after each call). Both
-- surfaces clear _tuningKeyDirty right after the guard and nowhere before it, so a marker left
-- there tells a pass that got past the guard from one that stopped at it.
do
  freshWorld()
  local Runtime = assert(loadfile(ROOT .. "/src/rfsuite/widgets/dashboard/runtime.lua"))()
  local widget = Runtime.new({ x = 0, y = 0, w = 800, h = 458 }, {})
  widget.preferences = widget.preferences or {}
  widget.preferences.dashboard = { theme_preflight = "system/default", standby_intro_seen = true }
  for _ = 1, 400 do pass(widget) end
  local function probe(event, pending, holding)
    widget._job = nil
    widget._themeReloadPending, widget._edgeHoldBusy = pending, holding
    widget._tuningKeyDirty = "probe"
    widget.refresh(widget, event, nil)
    local past = widget._tuningKeyDirty ~= "probe"
    local kept = widget._themeReloadPending == pending and widget._edgeHoldBusy == holding
    widget._themeReloadPending, widget._edgeHoldBusy, widget._tuningKeyDirty = nil, nil, nil
    return past, kept
  end
  local past, kept = probe(nil, nil, nil)
  check(past and kept, "control -- with no flag set, a widget pass gets past the guard")
  past, kept = probe(0, true, true)
  check(past and kept, "fullscreen -- a carried reload does not stop the surface building during the hold")
  past, kept = probe(nil, true, true)
  check(not past and kept, "widget -- nothing is built for the old theme during the hold")
  past, kept = probe(0, true, nil)
  check(not past and kept, "fullscreen without a hold -- a carried reload still waits for its tick")
end

io.open = realOpen
Stubs.releaseCard()
print(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
