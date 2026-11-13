-- The two search throttles of lib/sensors.lua count per widget pass, not per clock tick. Offline:
--
--   lua5.3 bin/telemetry/verify_sensor_search_per_pass.lua
--   lua5.3 bin/telemetry/verify_sensor_search_per_pass.lua --verbose
--
-- Sensors.getValue limits how much searching one pass may do: at most FIRST_SEARCHES_PER_PASS
-- sources start their first search, and at most one source repeats a search. Both caps used to be
-- keyed on the clock reading, so a pass that spans several 10 ms ticks -- on a radio, a pass that
-- searches routinely does -- got the caps again with every tick. Right after Sensors.reset(),
-- when every source searches, that put the whole search list into one widget call.
--
-- Here the stub clock advances one tick with every getTime() call, which is the radio's case at
-- its extreme, and no source answers (the link is down). What is checked:
--   marked pass       with Sensors.passBegins() before each pass, no pass starts more than the
--                     cap of first searches, nor more than one repeated search, and every source
--                     has searched within a few passes;
--   no mark           a host that never marks keeps the clock key, so its searches still run;
--   stale mark        a mark older than a second is no mark: searches resume instead of being
--                     held by a pass number that no longer moves;
--   arming fallback   with the cap spent, the arming state is still read from the System Status
--                     word when the board sends no ARM row;
--   the dashboard     the real dashboard runtime marks a pass in refresh() and in background().
-- Exit status: 0 green, 1 failed expectations, 2 invalid arguments.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]telemetry$") or (dir .. "/../..") end
end

local verbose = false
for i = 1, #arg do
  if arg[i] == "--verbose" then
    verbose = true
  else
    io.stderr:write("usage: lua5.3 bin/telemetry/verify_sensor_search_per_pass.lua [--verbose]\n")
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

local Sensors = _G.rfsuite.require("lib/sensors.lua")
assert(type(Sensors) == "table" and type(Sensors.getValue) == "function", "lib/sensors.lua did not load")

-- The sources the dashboard reads, every one with a search list.
local SOURCES = {
  "rpm", "link", "pid_profile", "rate_profile", "battery_profile", "governor", "temp_mcu", "temp_esc",
  "throttle_percent", "current", "voltage", "bec_voltage", "smartconsumption", "fuel",
}
for _, source in ipairs(SOURCES) do
  check(type(Sensors.search_paths[source]) == "table", "source " .. source .. " has a search list")
end

-- The clock: one tick per pass from the host, and one more with every getTime() call inside it.
local stubGetTime = _G.getTime
local drift = 0
_G.getTime = function()
  drift = drift + 1
  return stubGetTime() + drift
end

-- One pass: optionally the mark, then every source read once, as the dashboard's telemetry read
-- does. Returns how many sources started a first search and how many repeated one.
local function pass(mark)
  Stubs.tick()
  if mark and type(Sensors.passBegins) == "function" then Sensors.passBegins() end
  local before = {}
  for _, source in ipairs(SOURCES) do before[source] = Sensors.search_misses and Sensors.search_misses[source] end
  for _, source in ipairs(SOURCES) do Sensors.getValue(source) end
  local first, repeated = 0, 0
  for _, source in ipairs(SOURCES) do
    local now = Sensors.search_misses and Sensors.search_misses[source]
    if now ~= nil and now ~= before[source] then
      if before[source] == nil then first = first + 1 else repeated = repeated + 1 end
    end
  end
  return first, repeated
end

-- 1. Marked passes, straight after a reset. Run on a tree without the mark as well, so that the
-- caps are seen being exceeded there and not only the missing function.
check(type(Sensors.passBegins) == "function", "lib/sensors.lua offers Sensors.passBegins")
do
  Sensors.reset()
  local mostFirst, passes, searched = 0, 0, 0
  for _ = 1, 20 do
    local first = pass(true)
    passes = passes + 1
    if first > mostFirst then mostFirst = first end
    searched = searched + first
    if searched >= #SOURCES then break end
  end
  check(mostFirst >= 1 and mostFirst <= 4, "a marked pass starts at most 4 first searches",
    "most " .. mostFirst)
  check(searched == #SOURCES, "every source searched within the marked passes",
    searched .. " of " .. #SOURCES .. " in " .. passes .. " passes")

  -- Let every miss wait run out (the first wait is 2 s; 3 s of stub clock), then the repeats.
  for _ = 1, 30 do Stubs.tick() end
  local mostRepeated, repeatedTotal = 0, 0
  for _ = 1, 30 do
    local _, repeated = pass(true)
    if repeated > mostRepeated then mostRepeated = repeated end
    repeatedTotal = repeatedTotal + repeated
  end
  check(mostRepeated == 1, "a marked pass repeats at most one search", "most " .. mostRepeated)
  check(repeatedTotal >= 1, "repeated searches still run across marked passes", "total " .. repeatedTotal)
end

-- 2. A host that never marks: the searches are keyed on the clock, so they still run. A fresh
-- copy of the module, which has never seen a mark.
do
  _G.rfsuite.modules = _G.rfsuite.modules or {}
  local fresh = assert(loadfile(ROOT .. "/src/rfsuite/lib/sensors.lua"))()
  local saved = Sensors
  Sensors = fresh
  Sensors.reset()
  local searched = 0
  for _ = 1, 10 do searched = searched + pass(false) end
  check(searched == #SOURCES, "with no mark the searches run on the clock key", searched .. " of " .. #SOURCES)
  Sensors = saved
end

-- 3. A stale mark: marked once, then two seconds of passes without a mark.
if type(Sensors.passBegins) == "function" then
  Sensors.reset()
  Sensors.passBegins()
  for _ = 1, 20 do Stubs.tick() end
  local searched = 0
  for _ = 1, 10 do searched = searched + pass(false) end
  check(searched == #SOURCES, "a mark older than a second no longer holds the searches",
    searched .. " of " .. #SOURCES)
end

-- 3b. The arming state through its packed fallback is not held back by the cap. The board sends
-- no ARM row, only the System Status word (STAT, bit 0 = armed); four other sources have already
-- started their first search in this pass. `armflags` itself is exempt from the cap, and so must
-- be the System Status search it falls back to, or the armed bit reads as nothing for a pass.
if type(Sensors.passBegins) == "function" then
  Sensors.reset()
  Stubs.sensors["STAT"] = 1
  Stubs.tick()
  Sensors.passBegins()
  for _, source in ipairs({ "rpm", "link", "pid_profile", "rate_profile" }) do Sensors.getValue(source) end
  local armed = Sensors.getValue("armflags")
  check(armed == 1, "the armed bit is read from STAT in a pass whose first-search cap is spent",
    "armflags = " .. tostring(armed))
  Stubs.sensors["STAT"] = nil
  Sensors.reset()
end

-- 3c. The exemption is the arming fallback's alone, and it does not outlive that one read. The
-- fallback is answered from a path already adopted (it returns before any search), then the
-- sensors are reset, and an independent System Status read opens the next pass: it counts against
-- the cap like any other first search, so the fourth source after it is held back.
if type(Sensors.passBegins) == "function" then
  Sensors.reset()
  Stubs.sensors["STAT"] = 1
  for _ = 1, 3 do Stubs.tick(); Sensors.passBegins(); Sensors.getValue("armflags") end
  Sensors.reset()
  Stubs.tick()
  Sensors.passBegins()
  Sensors.getValue("system_status")
  -- Sources with no packed fallback of their own, so each read is exactly one first search.
  for _, source in ipairs({ "rpm", "link", "voltage", "current" }) do Sensors.getValue(source) end
  local searched = Sensors.search_misses and Sensors.search_misses["current"] ~= nil
  check(not searched, "an independent System Status search counts against the cap after the fallback was cached",
    searched and "five first searches in one pass" or "current held back")
  Stubs.sensors["STAT"] = nil
  Sensors.reset()
end

-- 4. The dashboard marks its passes, on screen and off.
do
  _G.getTime = stubGetTime
  local marks = 0
  local real = Sensors.passBegins
  Sensors.passBegins = function(...)
    marks = marks + 1
    if real then return real(...) end
  end
  local DashboardRuntime = assert(loadfile(ROOT .. "/src/rfsuite/widgets/dashboard/runtime.lua"))()
  local widget = DashboardRuntime.new({ x = 0, y = 0, w = 800, h = 458 }, {})
  Stubs.tick()
  local before = marks
  widget.refresh(widget, nil, nil)
  check(marks == before + 1, "the dashboard marks a pass in refresh()", (marks - before) .. " mark(s)")
  Stubs.tick()
  before = marks
  widget.background(widget)
  check(marks == before + 1, "the dashboard marks a pass in background()", (marks - before) .. " mark(s)")
  Sensors.passBegins = real
end

if failures > 0 then
  print(string.format("%d of %d checks failed", failures, checks))
  os.exit(1)
end
print(string.format("sensor search per pass: %d checks passed", checks))
