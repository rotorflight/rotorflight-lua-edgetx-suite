-- The radio's theme slots when the tool opens: the real ui/home.lua on the accounting stubs.
--   lua5.3 bin/ui/verify_tool_open_theme_slots.lua
-- What is checked: hosted in the dashboard, init writes no theme slot and builds nothing -- it is one widget
-- call under the instruction limit and already the heaviest of the open -- and the first pass of run writes
-- the slots and builds nothing either, so the first build, on the pass after, is drawn in the scheme; with a
-- landing as without one. A write that stops is tried again on the next passes, at most three times, and
-- the first build waits for it. A write that never completes -- stopped after some slots were written --
-- has those slots put back on the passes after (at most three tries), and the first build meets the
-- radio's colours. A visit refused in init writes nothing. Run as a script of its own, the
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

-- The radio's theme table, which the stubs do not have: getColor answers what setColor wrote, and a slot's
-- own colour is its flag. `stops` makes setColor calls raise, as the instruction limit does part way through
-- a write; `stopAfter` lets that many calls through first, so a stop can land after some slots were written.
local slots, writes, stops, stopAfter = {}, 0, 0, 0
-- `readStops` makes getColor calls raise, as a stop in the write's preparation does, before any slot is written.
local readStops = 0
lcd.getColor = function(flag)
  if readStops > 0 then
    readStops = readStops - 1
    error("instruction limit")
  end
  return slots[flag] or flag
end
lcd.setColor = function(flag, color)
  if stops > 0 then
    if stopAfter > 0 then
      stopAfter = stopAfter - 1
    else
      stops = stops - 1
      error("instruction limit")
    end
  end
  writes = writes + 1
  slots[flag] = color
end

-- How many theme slots hold something other than the radio's own colour (the slot list read once, here).
local SLOTS = assert(_G.rfsuite.require("lib/theme_slots.lua"), "lib/theme_slots.lua missing").SLOTS
local function changedSlots()
  local changed = 0
  for i = 1, #SLOTS do
    local flag = _G[SLOTS[i][1]]
    if flag ~= nil and lcd.getColor(flag) ~= flag then changed = changed + 1 end
  end
  return changed
end

-- The slots as the first build meets them, counted inside the build.
local builds, changedAtBuild = 0, nil
local realBuild = lvgl.build
lvgl.build = function(...)
  builds = builds + 1
  if changedAtBuild == nil then changedAtBuild = changedSlots() end
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
  writes, builds, changedAtBuild = 0, 0, nil
  Home.init(opts)
  return assert(find(Home.run, "state"), "home state missing")
end

local function pass()
  Stubs.tick()
  Home.run(0, nil)
end

local function restore()
  stops, stopAfter, readStops = 0, 0, 0
  local ThemeSlots = _G.rfsuite.require("lib/theme_slots.lua")
  if type(ThemeSlots) == "table" then ThemeSlots.restore("case end") end
end

local PAGE = "setup_mixer_tail_page"

-- Hosted on its menu: nothing loaded, written or built in init, the slots on the first pass, the build after.
do
  connected = true
  local root = _G.rfsuite
  local realRequire = root.require
  local slotLoads = 0
  root.require = function(path)
    if path == "lib/theme_slots.lua" then slotLoads = slotLoads + 1 end
    return realRequire(path)
  end
  local state = open({ hosted = true })
  check(slotLoads == 0, "hosted init does not load lib/theme_slots.lua", slotLoads)
  check(writes == 0, "hosted init writes no theme slot", writes)
  check(builds == 0, "hosted init builds nothing", builds)
  pass()
  check(writes > 0, "the first pass writes the theme slots", writes)
  check(builds == 0, "and builds nothing", builds)
  check(slotLoads == 1, "the first pass loads the module", slotLoads)
  root.require = realRequire
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

-- A stop before the first write (the module's load fails): tried again on the next pass all the same.
do
  connected = true
  local root = _G.rfsuite
  local realRequire = root.require
  local fails = 1
  root.require = function(path)
    if path == "lib/theme_slots.lua" and fails > 0 then
      fails = fails - 1
      return nil
    end
    return realRequire(path)
  end
  open({ hosted = true })
  pass()
  check(fails == 0 and writes == 0 and builds == 0, "control: the load failed, nothing written or built")
  pass()
  check(writes > 0 and builds == 0, "the next pass loads the module and writes the slots", writes .. "/" .. builds)
  root.require = realRequire
  pass()
  check(builds > 0, "and the first build follows", builds)
  restore()
end

-- A write that stops after its last slot (here: at its closing log line) has every slot in the scheme and the
-- scheme named: taken as written, no second try, and the build follows in the scheme. Only the module's own
-- log call is stopped, the tool's logging is left alone.
do
  connected = true
  local root = _G.rfsuite
  local realRequire = root.require
  local slotCount = 0
  for i = 1, #SLOTS do
    if _G[SLOTS[i][1]] ~= nil then slotCount = slotCount + 1 end
  end
  local trap = true
  root.require = function(path)
    local caller = debug.getinfo(2, "S")
    local fromModule = caller ~= nil and string.find(caller.source, "theme_slots.lua", 1, true) ~= nil
    if path == "lib/log.lua" and trap and fromModule and writes >= slotCount then
      trap = false
      error("instruction limit")
    end
    return realRequire(path)
  end
  open({ hosted = true })
  pass()
  root.require = realRequire
  check(not trap and writes == slotCount and builds == 0, "control: the write stopped after its last slot",
    tostring(trap) .. " " .. writes .. "/" .. slotCount .. " " .. builds)
  pass()
  check(builds > 0 and writes == slotCount, "taken as written: the next pass builds and writes nothing again",
    builds .. "/" .. writes)
  check(changedAtBuild == slotCount, "and the build meets the scheme in every slot", changedAtBuild)
  restore()
end

-- Three writes that each stop after two slots: given up, and the slots written are put back on a pass of their
-- own before the first build, which meets the radio's colours.
local function threePartialWrites()
  local tried = 0
  for _ = 1, 3 do
    stops, stopAfter = 1, 2
    pass()
    if stops == 0 then tried = tried + 1 end
    stops, stopAfter = 0, 0
  end
  return tried
end

do
  connected = true
  local state = open({ hosted = true })
  local tried = threePartialWrites()
  check(tried == 3 and builds == 0, "control: three writes stopped part way, nothing built", tried .. "/" .. builds)
  check(changedSlots() > 0, "control: the stopped writes left slots in the scheme", changedSlots())
  pass()
  check(builds == 0, "the pass after the third stop puts back and builds nothing", builds)
  check(changedSlots() == 0, "and the radio's colours are back", changedSlots())
  pass()
  check(builds > 0, "the first build follows on the pass after", builds)
  check(changedAtBuild == 0, "and meets the radio's colours", changedAtBuild)
  check(state.isClosing ~= true, "the tool stays open")
  restore()
end

-- The same with every write stopped before its first slot: the module already holds the radio's colours, so
-- the put-back pass runs all the same, and the build meets the radio's colours.
do
  connected = true
  open({ hosted = true })
  for _ = 1, 3 do
    stops = 1
    pass()
    stops = 0
  end
  check(builds == 0, "control: three writes stopped at the first slot, nothing built", builds)
  pass()
  pass()
  check(builds > 0 and changedAtBuild == 0, "the build follows the put-back in the radio's colours",
    tostring(builds) .. "/" .. tostring(changedAtBuild))
  restore()
end

-- A put-back that stops is tried again, and the first build waits for it.
do
  connected = true
  open({ hosted = true })
  threePartialWrites()
  stops, stopAfter = 1, 1
  pass()
  check(stops == 0 and builds == 0, "control: the put-back stopped part way, nothing built", stops .. "/" .. builds)
  stops, stopAfter = 0, 0
  pass()
  check(builds == 0 and changedSlots() == 0, "the next pass puts back and builds nothing",
    builds .. "/" .. changedSlots())
  pass()
  check(builds > 0 and changedAtBuild == 0, "the first build follows in the radio's colours",
    tostring(builds) .. "/" .. tostring(changedAtBuild))
  restore()
end

-- A put-back that keeps stopping is given up after three tries too: the tool builds, and the module still
-- holds the radio's colours, so the close puts them back.
do
  connected = true
  open({ hosted = true })
  threePartialWrites()
  for _ = 1, 3 do
    stops = 1
    pass()
    stops = 0
  end
  check(builds == 0, "control: three stopped put-backs, nothing built yet", builds)
  pass()
  check(builds > 0, "the build then goes ahead", builds)
  stops = 1
  pass()
  check(stops == 1, "no further try once the build is done", stops)
  stops = 0
  local ThemeSlots = _G.rfsuite.require("lib/theme_slots.lua")
  check(ThemeSlots.holding(), "the module still holds the radio's colours")
  restore()
  check(changedSlots() == 0, "and a restore, what the close calls, puts them back", changedSlots())
end

-- A put-back stopped after the colours are back but before the module lets go of them (here: where it
-- looks up the marker's path) is run again whole on the next pass, so nothing it holds is left half let go.
do
  connected = true
  open({ hosted = true })
  threePartialWrites()
  local root = _G.rfsuite
  local realPaths = root.paths
  local trap = true
  root.paths = setmetatable({}, { __index = function(_, key)
    if key == "user" and trap then
      trap = false
      error("instruction limit")
    end
    return realPaths and realPaths[key]
  end })
  pass()
  root.paths = realPaths
  local ThemeSlots = _G.rfsuite.require("lib/theme_slots.lua")
  check(not trap and builds == 0, "control: the put-back stopped after its colours, nothing built",
    tostring(trap) .. "/" .. builds)
  check(changedSlots() == 0, "the radio's colours are back", changedSlots())
  check(ThemeSlots.holding(), "and the module still holds them, so the put-back is owed again")
  pass()
  check(not ThemeSlots.holding() and builds == 0, "the next pass finishes the put-back and builds nothing",
    tostring(ThemeSlots.holding()) .. "/" .. builds)
  pass()
  check(builds > 0 and changedAtBuild == 0, "the first build follows in the radio's colours",
    tostring(builds) .. "/" .. tostring(changedAtBuild))
  restore()
end

-- A stop between the try count and the write (two loads failed, the third stopped before its load) leaves
-- the module unloaded: the pass after does not reach for it, and the build follows.
do
  connected = true
  local root = _G.rfsuite
  local realRequire = root.require
  root.require = function(path)
    if path == "lib/theme_slots.lua" then return nil end
    return realRequire(path)
  end
  local state = open({ hosted = true })
  pass()
  pass()
  root.require = realRequire
  state.themeSlotsTries = 3
  check(state.themeSlotsOwed == true and builds == 0, "control: still owed after the stopped third try",
    tostring(state.themeSlotsOwed) .. "/" .. builds)
  local ok, err = pcall(pass)
  check(ok, "the pass after does not raise", err)
  check(state.themeSlotsOwed == nil and state.isClosing ~= true, "nothing is owed and the tool stays open",
    tostring(state.themeSlotsOwed) .. "/" .. tostring(state.isClosing))
  pass()
  check(builds > 0 and writes == 0, "and the build follows, nothing written", builds .. "/" .. writes)
  restore()
end

-- A module that never loads holds nothing: given up after three tries, the build follows without a put-back.
do
  connected = true
  local root = _G.rfsuite
  local realRequire = root.require
  root.require = function(path)
    if path == "lib/theme_slots.lua" then return nil end
    return realRequire(path)
  end
  open({ hosted = true })
  pass()
  pass()
  pass()
  check(builds == 0 and writes == 0, "control: three failed loads, nothing written or built", builds .. "/" .. writes)
  pass()
  check(builds > 0 and writes == 0, "the build follows at once, nothing written", builds .. "/" .. writes)
  root.require = realRequire
  restore()
end

-- A scheme saved while the tool is open recolours at once. A slot write that stops part way through (after
-- some slots) is owed to the next pass like the opening write, and the page is built again only after it has
-- gone through, so the rebuilt page does not stand over a scheme written in part.
do
  connected = true
  local state = open({ hosted = true })
  pass()
  pass()
  local ThemeSlots = _G.rfsuite.require("lib/theme_slots.lua")
  check(builds > 0 and ThemeSlots.current() ~= nil, "control: the tool is built in a scheme", builds)
  local general = state.preferences.general
  local saved = general.color_scheme
  local other = (ThemeSlots.current() == "light") and "dark" or "light"
  general.color_scheme = other
  local applySaved = assert(find(Home.run, "applySavedScheme"), "applySavedScheme missing")
  stops, stopAfter = 1, 3
  applySaved()
  check(stops == 0 and ThemeSlots.current() == nil, "control: the save's slot write stopped part way")
  check(state.themeSlotsOwed == true, "a stopped save write is owed to the next pass")
  local before = builds
  pass()
  check(ThemeSlots.current() == other, "the next pass writes the saved scheme", ThemeSlots.current())
  check(builds == before, "and builds nothing", builds - before)
  pass()
  check(builds > before, "the page is built again on the pass after", builds - before)
  -- A save whose write goes through owes nothing more, even where an earlier save's write was given up and
  -- its put-back still waits: that put-back would undo the scheme just written.
  general.color_scheme = (other == "light") and "dark" or "light"
  stops, stopAfter = 1, 3
  applySaved()
  state.themeSlotsTries = 3                      -- the owed write given up: the next owed pass puts back
  general.color_scheme = other
  applySaved()
  check(ThemeSlots.current() == other and state.themeSlotsOwed == nil, "a save that goes through clears what was owed")
  pass()
  check(ThemeSlots.current() == other, "and the next pass leaves the saved scheme in the slots", ThemeSlots.current())
  general.color_scheme = saved
  restore()
end

-- A save's slot write that stops in its preparation, before a slot is written, while the slots still carry the
-- scheme before: the module still answers that scheme's name, which is not the saved one, so the write stays owed.
-- The owed write on the next pass stopping the same way stays owed too; the one after writes the saved scheme,
-- and the page is built again only on the pass after that.
do
  connected = true
  local state = open({ hosted = true })
  pass()
  pass()
  local ThemeSlots = _G.rfsuite.require("lib/theme_slots.lua")
  local before = ThemeSlots.current()
  check(builds > 0 and before ~= nil, "control: the tool is built in a scheme", builds)
  local general = state.preferences.general
  local saved = general.color_scheme
  local other = (before == "light") and "dark" or "light"
  general.color_scheme = other
  local applySaved = assert(find(Home.run, "applySavedScheme"), "applySavedScheme missing")
  local written = writes
  readStops = 1
  applySaved()
  check(readStops == 0 and writes == written and ThemeSlots.current() == before,
    "control: the save's write stopped in its preparation, nothing written, the old name kept", ThemeSlots.current())
  check(state.themeSlotsOwed == true, "a save's write stopped before any slot is owed to the next pass")
  -- The owed write on its own: stopped the same way, it is not taken for the saved scheme written either.
  state.themeSlotsOwed, state.themeSlotsTries = true, 0
  local built = builds
  readStops = 1
  pass()
  check(readStops == 0 and ThemeSlots.current() == before, "control: the owed write stopped in its preparation too")
  check(state.themeSlotsOwed == true and state.themeSlotsTries == 1, "a stopped owed write stays owed for its next try",
    tostring(state.themeSlotsOwed) .. "/" .. tostring(state.themeSlotsTries))
  check(builds == built, "and nothing is built over the old scheme's slots", builds - built)
  pass()
  check(ThemeSlots.current() == other and state.themeSlotsOwed == nil, "the next try writes the saved scheme",
    ThemeSlots.current())
  check(builds == built, "and builds nothing", builds - built)
  pass()
  check(builds > built, "the page is built again on the pass after", builds - built)
  general.color_scheme = saved
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
