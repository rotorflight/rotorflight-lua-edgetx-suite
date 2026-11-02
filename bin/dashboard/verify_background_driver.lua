-- Who drives the widget state's background work, and who writes the card log, when the RFSuite
-- dashboard widget and the RFSuite Service widget are on the same model. Offline:
--
--   lua5.3 bin/dashboard/verify_background_driver.lua
--   lua5.3 bin/dashboard/verify_background_driver.lua --verbose
--
-- Both widgets' real runtimes are created and called through the entry points EdgeTX calls on a
-- widget that is not on screen (widget.background), one host cycle of the stub clock (0.1 s) per
-- round, in the order the two widgets happen to sit on the screens. The accounting stubs supply
-- EdgeTX, the flight controller and a temporary SD card. Events.wakeup and LogSink.tick are wrapped
-- on the module tables both widgets call through and each call is attributed to the widget whose
-- call is running. What is counted for the card log is who ticks the sink -- the call the dashboard
-- used to leave out for good once a service widget had attached; whether a tick then writes, and
-- what, is lib/log_sink.lua's own business and unchanged here (the option is off in this world).
--
-- What is checked, in one Lua state as on the radio:
--   both widgets      the event runtime is driven by the dashboard alone, never twice in a cycle,
--                     and the dashboard ticks the card log -- in either call order;
--   dashboard gone    the service widget takes the work over within a second, and not at once;
--   service gone      a dashboard that is still running (or added again) ticks the card log;
--   flight clock      an armed flight's clock follows the stub clock through all of the above.
--
-- The stub clock steps 0.1 s per cycle and the widgets compare float seconds against 0.1 s, so a
-- widget skips some cycles' logic ticks; the checks count cycles and bounds, never exact rates.
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
    io.stderr:write("usage: lua5.3 bin/dashboard/verify_background_driver.lua [--verbose]\n")
    os.exit(2)
  end
end

local Stubs = assert(loadfile(ROOT .. "/bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile(ROOT .. "/bin/accounting/stubs/fc.lua"))()

Stubs.clearCard()
Stubs.install(ROOT)
FC.install(Stubs)
Stubs.reset()
FC.reset()
-- A helicopter idling on the bench, as the accounting world has it: the values only have to be
-- plausible and constant.
local SENSORS = {
  ["Vbat"] = 24.6, ["Curr"] = 3.2, ["Capa"] = 850, ["Bat%"] = 74, ["Cel#"] = 6,
  ["Hspd"] = 1750, ["RQly"] = 96, ["1RSS"] = -42, ["2RSS"] = -45, ["Vbec"] = 8.1,
  ["EscT"] = 48, ["Tmcu"] = 39, ["Thr%"] = 12, ["PID#"] = 1, ["RTE#"] = 1, ["BatP"] = 1,
  ["ARM"] = 0, ["ARMD"] = 0, ["Gov"] = 4,
}
for k, v in pairs(SENSORS) do Stubs.sensors[k] = v end

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

local requireModule = _G.rfsuite.require
local Events = requireModule("tasks/events/runtime.lua")
local Sink = requireModule("lib/log_sink.lua")
assert(type(Events) == "table" and type(Events.wakeup) == "function", "events runtime did not load")
assert(type(Sink) == "table" and type(Sink.tick) == "function", "log sink did not load")

local DashboardRuntime = assert(loadfile(ROOT .. "/src/rfsuite/widgets/dashboard/runtime.lua"))()
local ServiceRuntime = requireModule("widgets/service/runtime.lua")
assert(type(ServiceRuntime) == "table" and type(ServiceRuntime.new) == "function", "service runtime did not load")

-- Attribution: the widget whose call is running.
local caller = "none"
local wakes = { dashboard = 0, service = 0 }
local sinks = { dashboard = 0, service = 0 }
local cycleWakes = 0
local realWakeup, realSinkTick = Events.wakeup, Sink.tick
Events.wakeup = function(...)
  wakes[caller] = (wakes[caller] or 0) + 1
  cycleWakes = cycleWakes + 1
  return realWakeup(...)
end
Sink.tick = function(...)
  sinks[caller] = (sinks[caller] or 0) + 1
  return realSinkTick(...)
end

local function nowSeconds() return getTime() / 100 end

local dashboard = DashboardRuntime.new({ x = 0, y = 0, w = 800, h = 458 }, {})
local service = ServiceRuntime.new({ x = 0, y = 0, w = 200, h = 100 }, {})

-- One host cycle: the clock moves once, then every widget on the model is called once, in screen
-- order. Returns how many times the event runtime ran in the cycle.
local function cycle(order)
  Stubs.tick()
  cycleWakes = 0
  for i = 1, #order do
    local name = order[i]
    caller = name
    if name == "dashboard" then
      dashboard.background(dashboard)
    else
      service.background(service)
    end
    caller = "none"
  end
  return cycleWakes
end

-- Run `n` cycles; returns per-widget counts over the run, the largest number of wakeups any one
-- cycle saw, and the stub time of the first cycle in which each widget ran the event runtime and
-- of the last.
local function run(n, order, onCycle)
  local before = { wd = wakes.dashboard, ws = wakes.service, sd = sinks.dashboard, ss = sinks.service }
  local most, first, last = 0, {}, {}
  for k = 1, n do
    if onCycle then onCycle(k) end
    local wd, ws = wakes.dashboard, wakes.service
    local c = cycle(order)
    if c > most then most = c end
    local t = nowSeconds()
    if wakes.dashboard > wd then first.dashboard = first.dashboard or t; last.dashboard = t end
    if wakes.service > ws then first.service = first.service or t; last.service = t end
  end
  return {
    dashboard = wakes.dashboard - before.wd, service = wakes.service - before.ws,
    sinkDashboard = sinks.dashboard - before.sd, sinkService = sinks.service - before.ss,
    most = most, first = first, last = last,
  }
end

local function flightSeconds()
  local session = _G.rfsuite and _G.rfsuite.session
  local flight = session and session.flight
  return flight and tonumber(flight.seconds) or nil
end

-- Warm-up: both widgets, the dashboard first. The link comes up and the connect chain runs.
run(60, { "dashboard", "service" })

-- Arm, and let the arm edge open the flight record.
Stubs.sensors["ARM"] = 1
Stubs.sensors["ARMD"] = 1
run(20, { "dashboard", "service" })
local flightStart, clockStart = flightSeconds(), nowSeconds()
check(flightStart ~= nil, "control: the arm edge opened a flight record", "seconds=" .. tostring(flightStart))

-- Both widgets on the model, the dashboard first in each cycle.
local a = run(100, { "dashboard", "service" })
check(a.dashboard > 0, "control: the dashboard ran the event runtime with both widgets on the model",
  "dashboard=" .. a.dashboard)
check(a.service == 0, "both widgets, dashboard first: the service widget does not run the event runtime as well",
  "dashboard=" .. a.dashboard .. " service=" .. a.service)
check(a.most <= 1, "both widgets, dashboard first: the event runtime runs at most once per cycle",
  "most in one cycle=" .. a.most)
check(a.sinkDashboard > 0, "both widgets, dashboard first: the dashboard ticks the card log",
  "dashboard=" .. a.sinkDashboard .. " service=" .. a.sinkService)
check(a.sinkService == 0, "both widgets, dashboard first: the service widget leaves the card log tick to it",
  "service=" .. a.sinkService)

-- The same, the service widget first in each cycle (it sits on an earlier screen, or in the top bar).
local b = run(100, { "service", "dashboard" })
check(b.dashboard > 0, "control: the dashboard ran the event runtime, service widget first", "dashboard=" .. b.dashboard)
check(b.service == 0, "both widgets, service first: the service widget does not run the event runtime as well",
  "dashboard=" .. b.dashboard .. " service=" .. b.service)
check(b.most <= 1, "both widgets, service first: the event runtime runs at most once per cycle",
  "most in one cycle=" .. b.most)
check(b.sinkService == 0, "both widgets, service first: the service widget leaves the card log tick to the dashboard",
  "service=" .. b.sinkService)

-- The dashboard is taken off the model (or its script has stopped): only the service widget is
-- called from here on. It has to notice and take the work over -- not on the next cycle, and
-- within the flight clock's largest step (one second), so the flight loses no time.
local dashboardLast = nowSeconds()
local c = run(100, { "service" })
local takeover = c.first.service and (c.first.service - dashboardLast) or nil
check(takeover ~= nil, "dashboard gone: the service widget takes the background work over",
  "service wakeups=" .. c.service)
check(takeover == nil or takeover <= 1.0 + 1e-6, "dashboard gone: the take-over comes within one second",
  "after " .. tostring(takeover) .. " s")
check(takeover == nil or takeover > 0.15, "dashboard gone: the service widget does not take over on the very next cycle",
  "after " .. tostring(takeover) .. " s")
check(c.service >= 50, "dashboard gone: the service widget keeps driving on its own", "service wakeups=" .. c.service)
check(c.sinkService > 0, "dashboard gone: the service widget ticks the card log", "service=" .. c.sinkService)

-- The flight clock through both widgets and the hand-over: neither doubled nor dropped.
local flightNow, clockNow = flightSeconds(), nowSeconds()
local credited = (flightNow or 0) - (flightStart or 0)
local elapsed = clockNow - clockStart
check(flightNow ~= nil and math.abs(credited - elapsed) <= 0.25,
  "flight clock: an armed flight is credited the time that passed, through both widgets and the hand-over",
  string.format("credited %.2f s of %.2f s", credited, elapsed))

-- The service widget is taken off the model, and a dashboard is placed again. The service widget
-- had attached to the MSP runtime while it drove, and EdgeTX gives a removed widget no call to
-- detach with.
Stubs.sensors["ARM"] = 0
Stubs.sensors["ARMD"] = 0
dashboard = DashboardRuntime.new({ x = 0, y = 0, w = 800, h = 458 }, {})
local d = run(60, { "dashboard" })
check(d.dashboard > 0, "control: the dashboard alone runs the event runtime", "dashboard=" .. d.dashboard)
check(d.sinkDashboard > 0, "service widget gone: the dashboard ticks the card log",
  "dashboard=" .. d.sinkDashboard)

Events.wakeup, Sink.tick = realWakeup, realSinkTick
Stubs.releaseCard()

if verbose then
  print(string.format("both/dashboard first: wakeups dashboard=%d service=%d; service first: dashboard=%d service=%d",
    a.dashboard, a.service, b.dashboard, b.service))
end
if failures > 0 then
  print(string.format("%d of %d background-driver checks failed", failures, checks))
  os.exit(1)
end
print(string.format("%d background-driver checks, 0 failures", checks))
