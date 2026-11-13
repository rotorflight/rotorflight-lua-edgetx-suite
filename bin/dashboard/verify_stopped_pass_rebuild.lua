-- What the widget entry point does with the screen after a refresh pass that stopped. Offline:
--
--   lua5.3 bin/dashboard/verify_stopped_pass_rebuild.lua
--   lua5.3 bin/dashboard/verify_stopped_pass_rebuild.lua --verbose
--
-- The real entry point (src/widgets/rfsuite/main.lua) over the real dashboard runtime, on the
-- accounting stubs, one host cycle of the stub clock (0.1 s) per pass. The standby screen is used as
-- the surface because it stands without a flight controller. Builds are counted as LVGL trees the
-- stub radio was handed.
--
-- What is checked:
--   no job, CPU limit    a pass that stops while the standby stands finished (no job pending) keeps
--                        it: after the 1.2 s back-off no tree is built and `built` stays set;
--   no job, other error  the same for an ordinary raise, which the entry point used to treat alike;
--   job queued in pass   a state pass that queues a job and then stops gives the tree up and rebuilds;
--   job, outside step    a raise in a job pass outside the step (the queue pump) drops the job and
--                        the tree, so the widget is not pinned in the job branch (#280), and the
--                        surface is built again once;
--   job, inside step     a step stopped at the instruction limit still rebuilds;
--   one-shot job         a stop in a one-shot job's pass over a finished tree still rebuilds;
--   release              a stop right after, or right before, the standby's tree is cleared on
--                        leaving the screen leaves it marked unbuilt and still to be cleared;
--   log                  the stop line names the pass's last work; a rebuild after a stop says so,
--                        and a stop that keeps the tree does not claim one.
--
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
    io.stderr:write("usage: lua5.3 bin/dashboard/verify_stopped_pass_rebuild.lua [--verbose]\n")
    os.exit(2)
  end
end

local Stubs = assert(loadfile(ROOT .. "/bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile(ROOT .. "/bin/accounting/stubs/fc.lua"))()

Stubs.clearCard()

local failures = 0
local checks = 0
local function check(label, ok, detail)
  checks = checks + 1
  if ok then
    if verbose then print("ok   " .. label .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or "")) end
  else
    failures = failures + 1
    print("FAIL " .. label .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
  end
end

local lines = {}
local function logged(part)
  for i = 1, #lines do
    if string.find(lines[i], part, 1, true) then return true end
  end
  return false
end

local Entry, Runtime, MspRuntime, widget
-- Builds, counted at the stub radio's lvgl.build: the stub's tree list is emptied by every clear.
local builds, standbyBuilds = 0, 0
local realBuild

-- A world of its own: the stubs installed afresh, as bin/accounting/measure.lua does between worlds,
-- and the entry point, the runtime and a widget loaded into it. The stub flight controller connects
-- after a number of passes, and the standby makes way for the dashboard then, so a case that needs
-- the standby on screen and comes late takes a world of its own rather than the passes left over.
local function newWorld()
  Stubs.install(ROOT)
  FC.install(Stubs)
  Stubs.reset()
  FC.reset()
  Entry = assert(loadfile(ROOT .. "/src/widgets/rfsuite/main.lua"))()
  assert(type(Entry) == "table" and type(Entry.refresh) == "function", "widget entry point did not load")
  Runtime = assert(loadfile(ROOT .. "/src/rfsuite/widgets/dashboard/runtime.lua"))()
  MspRuntime = assert(_G.rfsuite.require("tasks/msp/runtime.lua"))

  widget = Runtime.new({ x = 0, y = 0, w = 480, h = 320 }, {})
  widget.preferences.dashboard = widget.preferences.dashboard or {}
  widget.preferences.dashboard.standby_intro_seen = true
  widget.state.fblConnected, widget.state.armed = false, false
  widget.state.hadInflightFlight, widget.flightMode = false, "preflight"

  realBuild = lvgl.build
  lvgl.build = function(...)
    builds = builds + 1
    if widget._job and widget._job.kind == "standby" then standbyBuilds = standbyBuilds + 1 end
    return realBuild(...)
  end
end
newWorld()

-- Every line given to the logger the entry point reaches (`rfsuite.Log`), whatever the level. That
-- table is replaced while the dashboard loads, so it is wrapped again before every pass.
local wrapped = setmetatable({}, { __mode = "k" })
local function recordLog()
  local Log = _G.rfsuite and _G.rfsuite.Log
  if type(Log) ~= "table" or wrapped[Log] then return end
  local realEmit = Log.emit
  wrapped[Log] = realEmit
  Log.emit = function(tag, msg, level, ...)
    lines[#lines + 1] = tostring(level) .. " " .. tostring(tag) .. ": " .. tostring(msg)
    return realEmit(tag, msg, level, ...)
  end
end

local function pass()
  recordLog()
  Stubs.tick()
  Entry.refresh(widget, nil, nil)
end

-- Passes until the standby stands built with nothing queued, and a few more for it to settle.
local function settle()
  local quiet = 0
  for _ = 1, 200 do
    pass()
    if widget.built and widget._job == nil and widget._standbyModule ~= nil then
      quiet = quiet + 1
      if quiet >= 5 then return true end
    else
      quiet = 0
    end
  end
  return false
end

-- 1.2 s of back-off and two more seconds of passes.
local function rideOut()
  for _ = 1, 32 do pass() end
end

check("the standby stands before the first stop", settle(), builds)

-- A raise once, from the standby's per-pass read of the radio -- state pass, no job pending.
local function stopInStatePass(message)
  local module = widget._standbyModule
  local realSnapshot = module.snapshot
  local fired = false
  module.snapshot = function(...)
    if not fired then
      fired = true
      error(message, 0)
    end
    return realSnapshot(...)
  end
  local trees = builds
  pass()
  local wasFired = fired
  rideOut()
  module.snapshot = realSnapshot
  return wasFired, builds - trees
end

lines = {}
local fired, built = stopInStatePass("CPU limit")
check("no job, CPU limit: the stop happened in a state pass", fired)
check("no job, CPU limit: the standby on screen is not built again", built == 0, built)
check("no job, CPU limit: the tree stays marked built", widget.built == true and widget._job == nil)
check("no job, CPU limit: the stop line names the pass's last work",
  logged("widget.refresh stopped: CPU limit (last work state)"))
check("no job, CPU limit: no rebuild is claimed", not logged("rebuild: after a stopped pass"))

lines = {}
fired, built = stopInStatePass("state read failed")
check("no job, other error: the stop happened in a state pass", fired)
check("no job, other error: the standby on screen is not built again", built == 0, built)
check("no job, other error: the tree stays marked built", widget.built == true)

-- A job pending and the raise outside its step: the queue pump the job pass runs first.
check("the standby stands again before the job cases", settle())
-- A key the surface was never built for, so the standby is queued again for a reason of its own.
widget.built, widget.renderKey = false, "a surface since"
local armed = false
for _ = 1, 10 do
  pass()
  if widget._job ~= nil then armed = true break end
end
check("job, outside step: a build is queued", armed)
local realPump = MspRuntime.pump
local pumpFired = false
MspRuntime.pump = function(...)
  if not pumpFired then
    pumpFired = true
    error("CPU limit", 0)
  end
  return realPump(...)
end
lines = {}
local trees = builds
pass()
MspRuntime.pump = realPump
check("job, outside step: the stop happened in the job pass", pumpFired)
check("job, outside step: the job is dropped (#280)", widget._job == nil)
check("job, outside step: the tree is given up", widget.built == false)
check("job, outside step: the rebuild says why", logged("rebuild: after a stopped pass, job standby"))
check("job, outside step: the stop line names the job pass", logged("widget.refresh stopped: CPU limit (last work standby)"))
rideOut()
built = builds - trees
check("job, outside step: the surface is built again, once", built == 1, built)
check("job, outside step: it stands built afterwards", widget.built == true and widget._job == nil)

-- A step stopped at the instruction limit: the dashboard drops the job and hands the stop on.
check("the standby stands again before the step case", settle())
-- A key the surface was never built for, so the standby is queued again for a reason of its own.
widget.built, widget.renderKey = false, "a surface since"
armed = false
for _ = 1, 10 do
  pass()
  if widget._job ~= nil then armed = true break end
end
check("job, inside step: a build is queued", armed)
local job = widget._job
local realStep = job and job.step
local stepFired = false
if job then
  job.step = function(...)
    if not stepFired then
      stepFired = true
      error("CPU limit", 0)
    end
    return realStep(...)
  end
end
lines = {}
trees = builds
pass()
check("job, inside step: the stop happened in the step", stepFired)
check("job, inside step: the job is dropped and the tree given up", widget._job == nil and widget.built == false)
check("job, inside step: the rebuild says why", logged("rebuild: after a stopped pass, job standby"))
rideOut()
built = builds - trees
check("job, inside step: the surface is built again, once", built == 1, built)

-- A one-shot job (the battery prompt's kind) can be queued over a finished tree. A stop in its pass
-- outside the step gives the tree up as well: the entry point cannot tell what such a pass has
-- touched, and this is what it did before. (A raise inside any step is the dashboard's to handle,
-- and it gives the tree up itself.)
check("the standby stands again before the one-shot case", settle())
widget._job = { kind = "one_shot_probe", oneShot = true, step = function() return true end }
local oneShotFired = false
MspRuntime.pump = function(...)
  if not oneShotFired then
    oneShotFired = true
    error("CPU limit", 0)
  end
  return realPump(...)
end
lines = {}
trees = builds
pass()
MspRuntime.pump = realPump
check("one-shot over a built tree: the stop happened in its pass", oneShotFired)
check("one-shot over a built tree: the tree is given up", widget._job == nil and widget.built == false)
check("one-shot over a built tree: the rebuild says why", logged("rebuild: after a stopped pass, job one_shot_probe"))
rideOut()
built = builds - trees
check("one-shot over a built tree: the surface is built again, once", built == 1, built)

-- The standby let go of while it stands (the widget leaves the screen), stopped right after the
-- tree was cleared: the flags must already say the tree is gone, or the screen stays empty and is
-- never built again.
check("the standby stands again before the release case", settle())
local realClear = lvgl.clear
local clearFired = false
lvgl.clear = function(...)
  realClear(...)
  if not clearFired then
    clearFired = true
    error("CPU limit", 0)
  end
end
trees = builds
Stubs.tick()
Entry.background(widget)
lvgl.clear = realClear
check("release: the stop happened right after the clear", clearFired)
check("release: the cleared tree is not marked built", widget.built == false)
rideOut()
built = builds - trees
check("release: back on screen, the standby is built again, once", built == 1, built)
check("release: it stands built afterwards", widget.built == true and widget._job == nil)

-- The same release stopped just BEFORE the clear: the tree still stands, so the record must still
-- say there is a standby to clear, or the next release (the next pass off screen) skips the clear
-- and the tree is held until something else builds.
check("the standby stands again before the early-stop release case", settle())
local earlyFired, clears = false, 0
lvgl.clear = function(...)
  if not earlyFired then
    earlyFired = true
    error("CPU limit", 0)
  end
  clears = clears + 1
  return realClear(...)
end
local standbyBefore = standbyBuilds
Stubs.tick()
Entry.background(widget)
check("release, early stop: the stop happened before the clear", earlyFired and clears == 0)
check("release, early stop: the standing tree is not marked built", widget.built == false)
for _ = 1, 10 do
  Stubs.tick()
  Entry.background(widget)
end
lvgl.clear = realClear
check("release, early stop: a later pass off screen clears the tree", clears >= 1, clears)
rideOut()
-- Counted as standby builds: by now the stub flight controller has connected, so the dashboard's
-- scene follows the standby within these passes.
built = standbyBuilds - standbyBefore
check("release, early stop: back on screen, the standby is built again, once", built == 1, built)

-- A job queued in the state pass that then stops: nothing was pending when the pass began, so only
-- the job left behind tells the entry point that the tree may be about to be replaced.
lvgl.build = realBuild
newWorld()
check("a fresh world: the standby stands before the queued-in-pass case", settle())
do
  local module = widget._standbyModule
  local realSnapshot = module.snapshot
  local queued = false
  module.snapshot = function(...)
    if not queued then
      queued = true
      widget._job = { kind = "queued_probe", step = function() return true end }
      error("CPU limit", 0)
    end
    return realSnapshot(...)
  end
  lines = {}
  local standbyBefore = standbyBuilds
  pass()
  module.snapshot = realSnapshot
  check("job queued in the pass: the stop happened after the job was queued", queued)
  check("job queued in the pass: the job is dropped", widget._job == nil)
  check("job queued in the pass: the tree is given up", widget.built == false)
  check("job queued in the pass: the rebuild says why", logged("rebuild: after a stopped pass, job queued_probe"))
  rideOut()
  local rebuilt = standbyBuilds - standbyBefore
  check("job queued in the pass: the standby is built again, once", rebuilt == 1, rebuilt)
end

for Log, realEmit in pairs(wrapped) do Log.emit = realEmit end
lvgl.build = realBuild
Stubs.releaseCard()

print(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
