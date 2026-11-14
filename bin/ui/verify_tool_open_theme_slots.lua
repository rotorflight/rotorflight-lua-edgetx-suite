-- The radio's theme slots when the tool opens: the real ui/home.lua on the accounting stubs.
--   lua5.3 bin/ui/verify_tool_open_theme_slots.lua
-- What is checked: hosted in the dashboard, init writes no theme slot and builds nothing -- it is one widget
-- call under the instruction limit and already the heaviest of the open -- and the first pass of run writes
-- the slots and builds nothing either, so the first build, on the pass after, is drawn in the scheme; with a
-- landing as without one. A write that stops is tried again on the next passes, at most three times, and
-- the first build waits for it. A visit refused in init writes nothing. Run as a script of its own, the
-- tool still writes the slots in init. No pixels or timing are measured. Exit 0 green, 1 failed checks.

local checks, failures = 0, 0
local function check(ok, label, detail)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label .. (detail ~= nil and (": " .. tostring(detail)) or ""))
  end
end

local function find(fn, wanted, seen)
  seen = seen or {}
  if seen[fn] then return nil end
  seen[fn] = true
  local nested = {}
  for i = 1, 200 do
    local name, value = debug.getupvalue(fn, i)
    if not name then break end
    if name == wanted then return value end
    if type(value) == "function" then nested[#nested + 1] = value end
  end
  for i = 1, #nested do
    local found = find(nested[i], wanted, seen)
    if found ~= nil then return found end
  end
end

local Stubs = assert(loadfile("bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile("bin/accounting/stubs/fc.lua"))()
Stubs.clearCard()
Stubs.install("."); FC.install(Stubs); Stubs.reset(); FC.reset()
Stubs.installTool()

-- The radio's theme table, which the stubs do not have: getColor answers what setColor wrote. `stops` makes
-- the next setColor calls raise, as the instruction limit does part way through a write.
local slots, writes, stops = {}, 0, 0
lcd.getColor = function(flag) return slots[flag] or flag end
lcd.setColor = function(flag, color)
  if stops > 0 then
    stops = stops - 1
    error("instruction limit")
  end
  writes = writes + 1
  slots[flag] = color
end
local builds = 0
local realBuild = lvgl.build
lvgl.build = function(...)
  builds = builds + 1
  return realBuild(...)
end

-- The answer the tool reads for "has the flight controller answered", set per case.
local connected = true
local Home

local function freshHome()
  -- Each case opens a tool of its own: a new ui/home.lua, its theme slot module let go.
  local root = _G.rfsuite
  if type(root.clearModule) == "function" then root.clearModule("lib/theme_slots.lua") end
  Home = assert(loadfile("src/rfsuite/ui/home.lua"))()
  local readFbl = assert(find(Home.init, "readFblConnected"), "readFblConnected missing")
  local i = 1
  while true do
    local name, value = debug.getupvalue(readFbl, i)
    if not name then break end
    if name == "MspRuntime" then
      debug.upvaluejoin(readFbl, i, function() return value end, 1)
      debug.setupvalue(readFbl, i, { isFblConnected = function() return connected end })
    end
    i = i + 1
  end
end

local function open(opts)
  freshHome()
  writes, builds = 0, 0
  Home.init(opts)
  return assert(find(Home.run, "state"), "home state missing")
end

local function pass()
  Stubs.tick()
  Home.run(0, nil)
end

local function restore()
  stops = 0
  local ThemeSlots = _G.rfsuite.require("lib/theme_slots.lua")
  if type(ThemeSlots) == "table" then ThemeSlots.restore("case end") end
end

local PAGE = "setup_mixer_tail_page"

-- Hosted on its menu: nothing written or built in init, the slots on the first pass, the build after.
do
  connected = true
  local state = open({ hosted = true })
  check(writes == 0, "hosted init writes no theme slot", writes)
  check(builds == 0, "hosted init builds nothing", builds)
  pass()
  check(writes > 0, "the first pass writes the theme slots", writes)
  check(builds == 0, "and builds nothing", builds)
  local written = writes
  pass()
  check(builds > 0, "the pass after builds the first screen", builds)
  check(writes == written, "and writes no slot again", writes)
  check(state.isClosing ~= true, "the tool stays open")
  restore()
end

-- Hosted with a landing: the same order, and the page is what the first build opens.
do
  connected = true
  local state = open({ hosted = true, landing = PAGE, visit = true })
  check(writes == 0 and builds == 0, "a hosted landing writes and builds nothing in init", writes .. "/" .. builds)
  pass()
  check(writes > 0 and builds == 0, "its first pass writes the slots and builds nothing", writes .. "/" .. builds)
  pass()
  check(builds > 0 and state.menu.getCurrentMenuId() == PAGE, "the pass after builds the landing page",
    tostring(builds) .. " " .. tostring(state.menu.getCurrentMenuId()))
  restore()
end

-- A write that stops is tried again, and the first build waits for it.
do
  connected = true
  open({ hosted = true })
  stops = 1
  pass()
  check(stops == 0 and builds == 0, "control: the first pass's write stopped, nothing built")
  pass()
  check(writes > 0 and builds == 0, "the next pass writes the slots, still nothing built", writes .. "/" .. builds)
  pass()
  check(builds > 0, "the first build follows on the pass after", builds)
  restore()
end

-- A write that keeps stopping is given up after three tries, and the tool builds in the radio's colours.
do
  connected = true
  open({ hosted = true })
  local tried = 0
  for _ = 1, 3 do
    stops = 1
    pass()
    if stops == 0 then tried = tried + 1 end
    stops = 0
  end
  check(tried == 3 and builds == 0, "three stopped tries build nothing", tried .. "/" .. builds)
  stops = 1
  pass()
  check(stops == 1, "no fourth try", stops)
  stops = 0
  check(builds > 0, "and the first build goes ahead", builds)
  restore()
end

-- A visit refused in init closes the tool: no slot is written on the way out.
do
  connected = false
  local state = open({ hosted = true, landing = PAGE, visit = true })
  check(state.isClosing == true, "control: the refused visit closes the tool")
  pass()
  pass()
  check(writes == 0, "a closing tool writes no theme slot", writes)
  restore()
end

-- Run as a script of its own, init writes the slots as before (that call is not under the widget's limit).
do
  connected = true
  open({ hosted = false })
  check(writes > 0, "the tool run on its own writes the slots in init", writes)
  restore()
end

print(checks .. " checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
