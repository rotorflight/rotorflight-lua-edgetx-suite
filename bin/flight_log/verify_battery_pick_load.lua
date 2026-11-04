-- The dashboard's battery prompt reads the pack registry a few lines per widget call.
--
-- Run from the repository root:
--     lua5.3 bin/flight_log/verify_battery_pick_load.lua
--
-- Drives the real src/rfsuite/lib/battery_pick.lua, lib/flight_log.lua, lib/atomic_file.lua and
-- lib/log.lua against an in-memory card. Two things are checked:
--
-- * What the load produces: the packs offered for the model, in registry order, with their fields
--   and the board profile each one resolves to, for a registry with comments, blank lines, CRLF,
--   a repeated id, a line without an id, "*", an empty model list and other models. The expected
--   values are literals; no copy of the production parser lives here. loadRegistry, which the
--   Flight Log page reads, is checked on the same file.
-- * What one step costs: every loadStep, counted with debug.sethook at count 1 (the mechanism the
--   firmware bills a widget call with), stays under STEP_LIMIT however many packs the registry
--   holds. A tree without loadStep is measured on candidates() plus the profile match, the work
--   the dashboard did in one call before, so this check fails there for the larger registries.

local STEP_LIMIT = 9000

local failures, checks = 0, 0
local function check(label, ok, detail)
  checks = checks + 1
  if ok then
    print("  ok    " .. label)
  else
    failures = failures + 1
    print("FAIL " .. label)
    if detail ~= nil then print("        " .. tostring(detail)) end
  end
end

-- ---------------------------------------------------------------------------
-- The card, and the module loader the radio's dashboard has
-- ---------------------------------------------------------------------------
-- luacheck: globals io fstat mkdir del rename loadScript getTime
local files = {}
local opened, closed = 0, 0
io.open = function(path, mode)
  mode = mode or "r"
  if string.sub(mode, 1, 1) == "r" and files[path] == nil then return nil end
  if string.sub(mode, 1, 1) == "w" then files[path] = "" end
  opened = opened + 1
  return { path = path, pos = 1 }
end
io.read = function(f, n)
  local data = files[f.path] or ""
  if f.pos > #data then return "" end
  local chunk = string.sub(data, f.pos, f.pos + n - 1)
  f.pos = f.pos + #chunk
  return chunk
end
io.write = function(f, ...)
  for i = 1, select("#", ...) do files[f.path] = files[f.path] .. tostring((select(i, ...))) end
  return f
end
io.close = function(f)
  if type(f) == "table" and not f.closed then
    f.closed = true
    closed = closed + 1
  end
  return true
end
function fstat(path)
  if files[path] == nil then return nil end
  return { size = #files[path] }
end
function mkdir() return 8 end
function del(path) files[path] = nil; return 0 end
function rename(from, to)
  if files[from] == nil or files[to] ~= nil then return 8 end
  files[to], files[from] = files[from], nil
  return 0
end
function getTime() return 100 end
-- The card roots, as every Lua state of the suite has them before its first module loads.
local PATHS = dofile("src/rfsuite/lib/paths.lua")
function loadScript(path)
  local relative = string.sub(path, 1, #PATHS.core + 1) == PATHS.core .. "/" and string.sub(path, #PATHS.core + 2) or path
  return assert(loadfile("src/rfsuite/" .. relative))
end

local modules = {}
local function require_(path)
  if modules[path] == nil then
    modules[path] = assert(loadScript(PATHS.core .. "/" .. path))()
  end
  return modules[path]
end
_G.rfsuite = { paths = PATHS, require = require_, log_history = {}, log_history_seq = 0, session = {} }
-- No flight controller: the profile read and write find no queue and say so.
modules["tasks/msp/runtime.lua"] = { getState = function() return nil end }

local FlightLog = require_("lib/flight_log.lua")
local BatteryPick = require_("lib/battery_pick.lua")
local REG = FlightLog.registryPath()

-- The board's six capacities, each profile with its own cell count: 5000 mAh is profile 3 at 6S
-- and profile 5 at 12S, so a 5000 mAh pack resolves by its cells.
local CFG = { hasProfileCells = true }
do
  local caps = { 2200, 3300, 5000, 4500, 5000, 1800 }
  local cells = { 6, 6, 6, 6, 12, 6 }
  for i = 0, 5 do
    CFG["batteryCapacity_" .. i] = caps[i + 1]
    CFG["batteryCellCount_" .. i] = cells[i + 1]
  end
end

-- ---------------------------------------------------------------------------
-- What the load produces
-- ---------------------------------------------------------------------------

local REGISTRY = table.concat({
  "# the pilot's packs\r\n",
  "# kept by hand\r\n",
  "id=1;name=Red 6S;cap=5000;cells=6;models=Goblin;cycles=12;last=2026-10-01\r\n",
  "\r\n",
  "id=2;name=Blue 12S;cap=5000;cells=12;models=goblin, logo;cycles=3\r\n",
  "  # id=9;name=commented out\r\n",
  "id=3;name=Any;cap=3300;models=*\r\n",
  "id=4;name=Other craft;cap=2200;models=logo\r\n",
  "name=No id;cap=2200\r\n",
  "id=1;name=Second line of id 1;cap=1800\r\n",
  "id=5;name=Every model;cap=9999;profile=6;cycles=40\r\n",
  "a line without the separator\r\n",
  "id=6;name=Empty list;models=;cap=4500;cells=6\n",
  "id=7;name=Last, no line end;cap=5000;models=GOBLIN",
})

-- id, name, cap, cells, cycles, last, targetProfile (0-based)
local EXPECTED = {
  { "1", "Red 6S", 5000, 6, 12, "2026-10-01", 2 },
  { "2", "Blue 12S", 5000, 12, 3, nil, 4 },
  { "3", "Any", 3300, nil, nil, nil, 1 },
  { "5", "Every model", 9999, nil, 40, nil, 5 },
  { "6", "Empty list", 4500, 6, nil, nil, 3 },
  { "7", "Last, no line end", 5000, nil, nil, nil, nil },
}

local function describe(list)
  local parts = {}
  for i = 1, #list do
    local p = list[i]
    parts[#parts + 1] = string.format("%s/%s/%s/%s/%s/%s/%s", tostring(p.id), tostring(p.name), tostring(p.cap),
      tostring(p.cells), tostring(p.cycles), tostring(p.last), tostring(p.targetProfile))
  end
  return table.concat(parts, " | ")
end

local function expected()
  local parts = {}
  for i = 1, #EXPECTED do
    local e = EXPECTED[i]
    parts[#parts + 1] = string.format("%s/%s/%s/%s/%s/%s/%s", e[1], e[2], tostring(e[3]), tostring(e[4]),
      tostring(e[5]), tostring(e[6]), tostring(e[7]))
  end
  return table.concat(parts, " | ")
end

local SESSION = { modelName = " goblin " }

-- The whole load, the way the dashboard takes it: step after step until the registry is read.
-- Answers the packs, the number of steps and the most instructions one step cost.
local function runLoad(session, cfg, maxLines)
  local count = 0
  local function hook() count = count + 1 end
  if type(BatteryPick.newLoad) ~= "function" then
    -- A tree without the stepped load: the one call the dashboard made.
    debug.sethook(hook, "", 1)
    local list = BatteryPick.candidates(session)
    for i = 1, #list do list[i].targetProfile = BatteryPick.targetProfile(list[i], cfg) end
    debug.sethook()
    return list, 1, count
  end
  local load = BatteryPick.newLoad(session, cfg)
  local steps, worst = 0, 0
  repeat
    count = 0
    debug.sethook(hook, "", 1)
    local done = BatteryPick.loadStep(load, maxLines)
    debug.sethook()
    steps = steps + 1
    if count > worst then worst = count end
  until done or steps > 100000
  return load.packs, steps, worst
end

files[REG] = REGISTRY
local list, steps = runLoad(SESSION, CFG)
check("the packs for the model, in registry order, with their fields and profiles",
  describe(list) == expected(), describe(list))
check("a registry of 13 lines is read in two steps of twelve", steps == 2, steps)

for _, size in ipairs({ 1, 2, 5, 13, 100 }) do
  local sized = runLoad(SESSION, CFG, size)
  check("the same packs taken " .. size .. " line(s) per step", describe(sized) == expected(), describe(sized))
end

local unmatched = runLoad({ modelName = "unknown" }, CFG)
check("another model gets the packs for every model only",
  describe(unmatched) == "3/Any/3300/nil/nil/nil/1 | 5/Every model/9999/nil/40/nil/5 | 6/Empty list/4500/6/nil/nil/3",
  describe(unmatched))
local noName = runLoad(nil, nil)
check("no session and no board configuration: the packs for every model, no profile from capacity",
  describe(noName) == "3/Any/3300/nil/nil/nil/nil | 5/Every model/9999/nil/40/nil/5 | 6/Empty list/4500/6/nil/nil/nil",
  describe(noName))

local profiles = {}
for k = 1, #list do profiles[k] = tostring(list[k].profile) end
check("each pack keeps the registry's own profile field", table.concat(profiles, ",") == "nil,nil,nil,6,nil,nil",
  table.concat(profiles, ","))

-- The board configuration is taken as it stood when the load started: a change to the table the
-- caller passed, between two steps, does not reach the packs after it.
if type(BatteryPick.newLoad) == "function" then
  local cfg = {}
  for k, v in pairs(CFG) do cfg[k] = v end
  local load = BatteryPick.newLoad(SESSION, cfg)
  BatteryPick.loadStep(load, 3)
  cfg.batteryCapacity_2, cfg.batteryCapacity_1 = 3300, 5000
  repeat until BatteryPick.loadStep(load, 1)
  check("a configuration changed during the load does not reach the packs after the change",
    describe(load.packs) == expected(), describe(load.packs))

  -- The load indexes its packs by id, so the caller looks a pack up instead of searching the list.
  local indexed = BatteryPick.newLoad(SESSION, CFG)
  repeat until BatteryPick.loadStep(indexed)
  local all = true
  for k = 1, #indexed.packs do
    if indexed.byId[indexed.packs[k].id] ~= indexed.packs[k] then all = false end
  end
  check("every pack of the load is found by its id", all and indexed.byId["6"] == indexed.packs[5])
  check("a pack the model is not offered is not in the index", indexed.byId["4"] == nil)
else
  check("a configuration changed during the load does not reach the packs after the change", false, "no stepped load")
  check("every pack of the load is found by its id", false, "no stepped load")
end

local registry = FlightLog.loadRegistry()
local ids = {}
for i = 1, #registry do ids[i] = registry[i].id end
check("loadRegistry reads the same file: every pack once, the first line of an id wins",
  table.concat(ids, ",") == "1,2,3,4,5,6,7" and registry[1].name == "Red 6S"
    and table.concat(registry[2].models, ",") == "goblin,logo" and #registry[6].models == 0,
  table.concat(ids, ","))

files[REG] = nil
local empty, emptySteps = runLoad(SESSION, CFG)
check("no registry file: no packs, one step", #empty == 0 and emptySteps == 1, emptySteps)

-- A load dropped part-way -- a reconnect replaces it -- holds no file open.
files[REG] = REGISTRY
opened, closed = 0, 0
if type(BatteryPick.newLoad) == "function" then
  local dropped = BatteryPick.newLoad(SESSION, CFG)
  BatteryPick.loadStep(dropped, 1)
end
check("a load dropped after its first step leaves no file open", opened == closed, opened .. " opened, " .. closed .. " closed")

-- ---------------------------------------------------------------------------
-- What one step costs
-- ---------------------------------------------------------------------------

local function bigRegistry(n)
  local lines = { "# packs\n" }
  for i = 1, n do
    lines[#lines + 1] = string.format("id=%d;name=Pack %d;cap=5000;cells=6;models=goblin;cycles=%d;last=2026-10-01\n",
      i, i, i)
  end
  return table.concat(lines)
end

print("  packs  bytes  steps  worst step (instructions)")
for _, n in ipairs({ 0, 1, 12, 36, 100, 500 }) do
  files[REG] = bigRegistry(n)
  _G.rfsuite.log_history = {}
  local packs, nSteps, worst = runLoad(SESSION, CFG)
  print(string.format("  %5d %6d %6d %8d", n, #files[REG], nSteps, worst))
  check(string.format("%d packs: all offered, and no step costs more than %d instructions", n, STEP_LIMIT),
    #packs == n and worst <= STEP_LIMIT, string.format("%d packs, worst step %d", #packs, worst))
end

print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
