-- The battery prompt's registry load, through the real dashboard runtime, offline:
--
--   lua5.3 bin/dashboard/verify_battery_pick_passes.lua
--   lua5.3 bin/dashboard/verify_battery_pick_passes.lua --verbose
--   lua5.3 bin/dashboard/verify_battery_pick_passes.lua --runtime <other runtime.lua>
--
-- The accounting stubs supply EdgeTX, the flight controller and a temporary SD card; a registry
-- of 100 packs for every model is written to that card. Runtime.new(...) and its refresh passes are
-- real, and every pass is counted with debug.sethook at count 1. Checked:
--
-- * no pass that runs the load costs more than PASS_LIMIT instructions, and the load is spread
--   over several passes with a pass between any two of them that runs no load;
-- * the views never see part of the list: `candidates` holds no packs or all of them;
-- * the prompt is raised with every pack once the load is done;
-- * a load step that raises is not run again on the passes after it;
-- * a load the reconnect edge drops (it replaces the prompt's state) starts over.
--
-- `--runtime` runs the same expectations against another runtime.lua, so a source that loads the
-- whole registry in one pass can be shown to fail. These are controlled states on the stubs, not
-- a hardware measurement. Exit status: 0 green, 1 failed expectations, 2 invalid arguments.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]dashboard$") or (dir .. "/../..") end
end

local PACKS = 100
local PASS_LIMIT = 10000
local PASSES = 600

local runtimePath = ROOT .. "/src/rfsuite/widgets/dashboard/runtime.lua"
local verbose = false
local i = 1
while i <= #arg do
  if arg[i] == "--verbose" then
    verbose = true
  elseif arg[i] == "--runtime" and arg[i + 1] then
    i = i + 1
    runtimePath = arg[i]
  else
    io.stderr:write("usage: lua5.3 bin/dashboard/verify_battery_pick_passes.lua [--verbose] [--runtime <file>]\n")
    os.exit(2)
  end
  i = i + 1
end

local failures = 0
local function check(label, ok, detail)
  if not ok then failures = failures + 1 end
  if verbose or not ok then
    print(string.format("%s: %s%s", ok and "PASS" or "FAIL", label, detail and (" (" .. tostring(detail) .. ")") or ""))
  end
end

local Stubs = assert(loadfile(ROOT .. "/bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile(ROOT .. "/bin/accounting/stubs/fc.lua"))()

local count = 0
local function hook() count = count + 1 end

--- A widget on a fresh card holding a registry of `packs` packs for every model; `line` formats
--- one registry line from the pack's number.
local function newWidget(packs, line)
  Stubs.install(ROOT)
  FC.install(Stubs)
  Stubs.reset()
  FC.reset()
  local Runtime = assert(loadfile(runtimePath))()
  local widget = Runtime.new({ x = 0, y = 0, w = 800, h = 480 }, {})
  local FlightLog = _G.rfsuite.require("lib/flight_log.lua")
  local lines = { "# packs\n" }
  for n = 1, packs do
    lines[#lines + 1] = line and line(n) or string.format("id=%d;name=Pack %d;cap=5000;cells=6;cycles=%d\n", n, n, n)
  end
  local f = assert(io.open(FlightLog.registryPath(), "w"))
  io.write(f, table.concat(lines))
  io.close(f)
  widget.preferences = widget.preferences or {}
  widget.preferences.flightlog = { enabled = true }
  _G.rfsuite.session = _G.rfsuite.session or {}
  _G.rfsuite.session.modelName = "goblin"
  return widget
end

--- Run passes; `onPass(widget, i)` before each. Answers what the load passes did.
local function drive(widget, passes, onPass)
  local seen = { loads = 0, worst = 0, adjacent = false, partial = false, raisedAgain = 0, lastWasLoad = false }
  for n = 1, passes do
    Stubs.tick()
    widget.state.tasksDone = true
    if onPass then onPass(widget, n, seen) end
    local isLoad = widget._job ~= nil and widget._job.kind == "battery_pick_load"
    count = 0
    debug.sethook(hook, "", 1)
    local ok, err = pcall(widget.refresh, widget, nil, nil)
    debug.sethook()
    if not ok then error("pass " .. n .. " raised: " .. tostring(err)) end
    if isLoad then
      seen.loads = seen.loads + 1
      if count > seen.worst then seen.worst = count end
      if seen.lastWasLoad then seen.adjacent = true end
    end
    seen.lastWasLoad = isLoad
    local shown = #widget.state.batteryPick.candidates
    if shown ~= 0 and shown ~= seen.expect then seen.partial = true end
  end
  return seen
end

-- The load of 100 packs.
do
  local widget = newWidget(PACKS)
  local seen = drive(widget, PASSES, function(_, _, s) s.expect = PACKS end)
  local pick = widget.state.batteryPick
  check(string.format("no load pass costs more than %d instructions", PASS_LIMIT), seen.worst <= PASS_LIMIT,
    string.format("worst load pass %d over %d load passes", seen.worst, seen.loads))
  check("the load is spread over several passes", seen.loads > 1, seen.loads .. " load passes")
  check("a pass without load lies between any two load passes", not seen.adjacent)
  check("the views never see part of the list", not seen.partial)
  check("the prompt is raised with every pack", pick.loaded == true and #pick.candidates == PACKS and pick.pending == true,
    string.format("loaded=%s packs=%d pending=%s", tostring(pick.loaded), #pick.candidates, tostring(pick.pending)))
  print(string.format("%d packs: %d load passes, the worst %d instructions", PACKS, seen.loads, seen.worst))
end

-- A load step that raises, after one that did not, stays latched and leaves nothing behind.
do
  local widget = newWidget(PACKS)
  local BatteryPick = _G.rfsuite.require("lib/battery_pick.lua")
  local raises, calls = 0, 0
  local function boom() raises = raises + 1; error("a load step that raises") end
  local stepped = type(BatteryPick.loadStep) == "function"
  if stepped then
    local real = BatteryPick.loadStep
    BatteryPick.loadStep = function(...)
      calls = calls + 1
      if calls == 2 then boom() end
      return real(...)
    end
  else
    BatteryPick.candidates = boom
  end
  local seen = drive(widget, PASSES, function(_, _, s) s.expect = PACKS end)
  local pick = widget.state.batteryPick
  check("a raising load step is not enqueued again", raises == 1 and seen.loads == (stepped and 2 or 1),
    string.format("%d raises over %d load passes", raises, seen.loads))
  check("a raising load step publishes nothing", #pick.candidates == 0)
  check("a raising load step leaves no load held", pick.load == nil)
end

-- The reconnect edge replaces the prompt's state while a load is part-way: the next load starts over.
do
  local widget = newWidget(PACKS)
  local replaced = false
  local seen = drive(widget, PASSES, function(w, _, s)
    s.expect = PACKS
    if not replaced and s.loads == 2 then
      replaced = true
      w.state.batteryPick = { loaded = false, pending = false, candidates = {}, dismissed = false }
    end
  end)
  local pick = widget.state.batteryPick
  local inOrder = #pick.candidates == PACKS
  for n = 1, #pick.candidates do
    if pick.candidates[n].id ~= tostring(n) then inOrder = false end
  end
  check("a load dropped part-way starts over and publishes every pack once, in order", replaced and inOrder,
    string.format("replaced=%s packs=%d", tostring(replaced), #pick.candidates))
  check("nothing of the dropped load is shown", not seen.partial)
end

-- A pick requested while the load is part-way is applied once the load has published the list,
-- so it finds its pack and goes on to the board profile the pack names.
do
  local widget = newWidget(PACKS, function(n)
    return string.format("id=%d;name=Pack %d;cap=5000;cells=6;profile=2\n", n, n)
  end)
  widget.preferences.flightlog.set_fc_profile = true
  local requested, applyBeforeLoadEnd = false, false
  drive(widget, PASSES, function(w, _, s)
    s.expect = PACKS
    if not requested and s.loads == 1 then
      requested = true
      w._batteryPickRequest = "25"
    end
    if requested and w._job ~= nil and w._job.kind == "battery_pick_apply" and #w.state.batteryPick.candidates == 0 then
      applyBeforeLoadEnd = true
    end
  end)
  local pick = widget.state.batteryPick
  check("a pick requested mid-load waits for the list", requested and not applyBeforeLoadEnd)
  check("a pick requested mid-load finds its pack and queues the profile write",
    pick.selectedId == "25" and pick.selectedName == "Pack 25" and pick.applied == "queued",
    string.format("selected=%s name=%s applied=%s", tostring(pick.selectedId), tostring(pick.selectedName),
      tostring(pick.applied)))
end

-- A step stopped by the instruction limit after it handed the load back leaves the load held and
-- the latch raised. That load is not finished by anything, so it must not hold a pick up either.
do
  local widget = newWidget(PACKS)
  local requested = false
  drive(widget, PASSES, function(w, _, s)
    s.expect = PACKS
    local pick = w.state.batteryPick
    if not requested and pick.load ~= nil then
      requested = true
      pick.loaded = true
      w._batteryPickRequest = "25"
    end
  end)
  local pick = widget.state.batteryPick
  check("a pick is applied while a held load is latched", requested and widget._batteryPickRequest == nil
    and pick.selectedId == "25", string.format("requested=%s request=%s selected=%s", tostring(requested),
      tostring(widget._batteryPickRequest), tostring(pick.selectedId)))
  check("a held load that is latched is let go", pick.load == nil)
end

-- Three thousand one-field lines, and the chosen pack changed from the first to the last while the
-- load is part-way: the step that publishes the list does not search all of it for the choice.
do
  local MANY = 3000
  local widget = newWidget(MANY, function(n) return string.format("id=%d\n", n) end)
  local seen = drive(widget, 1900, function(_, _, s)
    s.expect = MANY
    _G.rfsuite.session.flightlog = { batteryId = s.loads < 5 and "1" or tostring(MANY) }
  end)
  local pick = widget.state.batteryPick
  check(string.format("%d packs, the choice changed mid-load: no load pass costs more than %d instructions", MANY,
    PASS_LIMIT), seen.worst <= PASS_LIMIT and #pick.candidates == MANY and pick.selectedId == tostring(MANY),
    string.format("worst load pass %d over %d load passes, %d packs, selected %s", seen.worst, seen.loads,
      #pick.candidates, tostring(pick.selectedId)))

  -- A pick of the last pack on that list does not cost a pass that grows with the registry either.
  widget._batteryPickRequest = tostring(MANY)
  local applyCost = nil
  for _ = 1, 50 do
    Stubs.tick()
    local isApply = widget._job ~= nil and widget._job.kind == "battery_pick_apply"
    count = 0
    debug.sethook(hook, "", 1)
    widget.refresh(widget, nil, nil)
    debug.sethook()
    if isApply then applyCost = count end
  end
  check(string.format("a pick on %d packs costs no more than %d instructions", MANY, PASS_LIMIT),
    applyCost ~= nil and applyCost <= PASS_LIMIT and widget._batteryPickRequest == nil,
    string.format("apply pass %s", tostring(applyCost)))
end

Stubs.releaseCard()
print(string.format("%d failures", failures))
os.exit(failures == 0 and 0 or 1)
