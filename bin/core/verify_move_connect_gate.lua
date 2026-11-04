-- Whether the two widgets hold the connection back for lib/precompile.lua's pass: the real runtimes
-- against a stand-in pass, each widget alone on the model. Offline, from the repository root:
--
--   lua5.3 bin/core/verify_move_connect_gate.lua
--
-- A pass that holds keeps the event runtime from running, and so does the restart request after it.
-- A retry of the move of the pilot's data after a failed attempt runs behind the connection: the
-- widget goes on stepping it while the event runtime runs.
-- Exit status: 0 green, 1 failed expectations.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]core$") or (dir .. "/../..") end
end

local Stubs = assert(loadfile(ROOT .. "/bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile(ROOT .. "/bin/accounting/stubs/fc.lua"))()
Stubs.clearCard()
Stubs.install(ROOT)
FC.install(Stubs)
Stubs.reset()
FC.reset()

local failures = 0
local function check(ok, label)
  if not ok then
    failures = failures + 1
    print("FAIL " .. label)
  end
end

local requireModule = _G.rfsuite.require
local Events = requireModule("tasks/events/runtime.lua")
local wakes = 0
local realWakeup = Events.wakeup
Events.wakeup = function(...)
  wakes = wakes + 1
  return realWakeup(...)
end

local PRECOMPILE = _G.rfsuite.paths.core .. "/lib/precompile.lua"

local function standIn(behind)
  local pass = { running = true, behind = behind, restart = false, steps = 0 }
  pass.module = {
    startIfStale = function() return true end,
    stepShared = function() pass.steps = pass.steps + 1 end,
    isRunning = function() return pass.running end,
    runsBehindConnection = function() return pass.running and pass.behind end,
    needsRestart = function() return pass.restart end,
    getProgress = function() return 0, 0, not pass.running end,
  }
  return pass
end

local WIDGETS = {
  { name = "dashboard", file = "/src/rfsuite/widgets/dashboard/runtime.lua", zone = { x = 0, y = 0, w = 800, h = 458 } },
  { name = "service", file = "/src/rfsuite/widgets/service/runtime.lua", zone = { x = 0, y = 0, w = 200, h = 100 } },
}

local function newWidget(info)
  -- A fresh chunk each time: the gate keeps what it asked the pass in an upvalue of the file.
  local runtime = assert(loadfile(ROOT .. info.file))()
  return runtime.new(info.zone, {})
end

local function cycles(widget, n)
  for _ = 1, n do
    Stubs.tick()
    widget.background(widget)
  end
end

for _, info in ipairs(WIDGETS) do
  -- Holding: nothing runs until the pass is through, and not while the restart is asked for.
  do
    local pass = standIn(false)
    _G.rfsuite.modules[PRECOMPILE] = pass.module
    local widget = newWidget(info)
    wakes = 0
    cycles(widget, 40)
    check(pass.steps > 0, info.name .. ": a holding pass is stepped")
    check(wakes == 0, info.name .. ": a holding pass keeps the event runtime from running")
    pass.running = false
    pass.restart = true
    cycles(widget, 40)
    check(wakes == 0, info.name .. ": the restart request keeps it from running")
  end

  -- Behind the connection: the event runtime runs and the pass is stepped alongside.
  do
    local pass = standIn(true)
    _G.rfsuite.modules[PRECOMPILE] = pass.module
    local widget = newWidget(info)
    wakes = 0
    cycles(widget, 60)
    check(wakes > 0, info.name .. ": a retry behind the connection lets the event runtime run")
    check(pass.steps > 0, info.name .. ": the retry is stepped")
    local steps = pass.steps
    pass.running = false
    cycles(widget, 40)
    check(pass.steps == steps + 1 or pass.steps == steps, info.name .. ": a finished retry is not stepped on")
  end
end

if failures > 0 then
  print(failures .. " expectations failed")
  os.exit(1)
end
print("move connect gate: all expectations hold")
