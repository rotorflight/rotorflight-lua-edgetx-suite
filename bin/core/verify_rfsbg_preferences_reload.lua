-- Run from the repository root: lua5.3 bin/core/verify_rfsbg_preferences_reload.lua
--
-- Drives the real background function script (src/functions/rfsbg.lua) with the real settings
-- stack under it -- lib/require.lua, lib/preferences.lua, lib/model_preferences.lua and
-- lib/config_store.lua -- over a card held in memory, a radio clock stepped one cycle at a time,
-- and the firmware's io, fstat, rename and del. The decoder and the adjustment teller are stand-ins:
-- what is checked is when the script re-reads the settings file and what it then holds.
--
-- Checked:
--   1. quiet intervals: the settings file is not opened again while nothing has changed, and
--      rfsuite.preferences stays the same table;
--   2. a save made by the tool is in rfsuite.preferences within one re-read interval;
--   3. no settings file on the card: the defaults are there, a missing file is not probed again
--      on every interval, and the first save is picked up;
--   4. a card from an earlier release: the former file is brought across on the first read, and a
--      bring-across whose write failed is tried again on the next interval -- also where an empty
--      settings file stands in the new file's place;
--   5. a read that raised, or a settings file the card did not hand over: nothing is adopted, and
--      the next interval reads the file again;
--   6. a write that keeps the file's size and time: the reload request beside it carries it;
--   7. a radio without fstat: the file is read on every interval, as before;
--   8. a settings file that does not compile: the defaults are used, it is not read again on every
--      interval, and the save that replaces it is picked up.
local checks, failures = 0, 0
local function check(ok, label)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label)
  end
end

local CORE = "/SCRIPTS/TOOLS/rfsuite-core/"
local FUNCTIONS = "/SCRIPTS/FUNCTIONS/"
local USER = "/SCRIPTS/TOOLS/rfsuite.user"
local PREFS = USER .. "/preferences.lua"
local LEGACY = USER .. "/preferences.ini"

-- The interval the script re-reads on, as rfsbg.lua states it. A change has to be in the table
-- within one interval and one cycle of being written.
local INTERVAL = 30
local CYCLE = 10 -- getTime() ticks (10 ms each) between two run() calls: 0.1 s

-- ------------------------------------------------------------------------------- the card

local files     -- path -> { data = string, time = table }
local opens     -- path -> io.open calls
local reads     -- path -> io.read calls
local stats     -- fstat calls
local failWrite -- path -> true: io.open(path, "w") answers nil
local raiseRead -- path -> true: the next io.open(path, "r") raises
local nilOpen   -- path -> true: the next io.open(path, "r") answers nil although the file is there
local clock     -- getTime() ticks
local frozenRtc -- a card time every write gets, for a radio without a running clock

local function cardTime()
  if frozenRtc then return frozenRtc end
  local s = math.floor(clock / 100)
  -- FAT keeps seconds in two-second steps.
  return { year = 2026, mon = 11, day = 2, hour = math.floor(s / 3600) % 24,
    min = math.floor(s / 60) % 60, sec = (s % 60) - (s % 2) }
end

local function resetCard()
  files, opens, reads, stats = {}, {}, {}, 0
  failWrite, raiseRead, nilOpen = {}, {}, {}
  clock, frozenRtc = 1000, nil
end

local function bump(t, k) t[k] = (t[k] or 0) + 1 end

-- io is the firmware's: open, read, write and close take the handle as their first argument.
_G.io = {
  open = function(path, mode)
    bump(opens, path)
    mode = mode or "r"
    if string.sub(mode, 1, 1) == "w" then
      if failWrite[path] then return nil, "simulated write refusal" end
      local h = { path = path, out = {}, write = true }
      files[path] = { data = "", time = cardTime() }
      return h
    end
    if raiseRead[path] then
      raiseRead[path] = nil
      error("simulated card error reading " .. path)
    end
    if nilOpen[path] then
      nilOpen[path] = nil
      return nil, "simulated card that did not answer"
    end
    local f = files[path]
    if not f then return nil, "not found" end
    return { path = path, data = f.data, pos = 1 }
  end,
  read = function(h, n)
    bump(reads, h.path)
    local s = string.sub(h.data, h.pos, h.pos + (n or 1) - 1)
    h.pos = h.pos + #s
    return s
  end,
  write = function(h, ...)
    for i = 1, select("#", ...) do h.out[#h.out + 1] = tostring((select(i, ...))) end
    return h
  end,
  close = function(h)
    if h.write then files[h.path] = { data = table.concat(h.out), time = cardTime() } end
  end,
}

fstat = function(path)
  stats = stats + 1
  local f = files[path]
  if f then
    local t = f.time
    return { size = #f.data, attrib = 0,
      time = { year = t.year, mon = t.mon, day = t.day, hour = t.hour, min = t.min, sec = t.sec } }
  end
  -- A directory is there when a file is under it.
  local prefix = path .. "/"
  for p in pairs(files) do
    if string.sub(p, 1, #prefix) == prefix then return { size = 0, attrib = 16, time = cardTime() } end
  end
  return nil
end
local realFstat = fstat

rename = function(from, to)
  if not files[from] or files[to] then return 4 end
  files[to], files[from] = files[from], nil
  return 0
end

del = function(path)
  if not files[path] then return 4 end
  files[path] = nil
  return 0
end

mkdir = function() return 0 end

getTime = function() return clock end

-- ------------------------------------------------------------------------------- the code

local STAND_INS = {
  ["tasks/events/telemetry_bg/drain.lua"] = function()
    return { wakeup = function() return 0 end, publishLiveness = function() end }
  end,
  ["tasks/events/telemetry_bg/adjustments.lua"] = function()
    return { wakeup = function() end }
  end,
}

loadScript = function(path)
  if string.sub(path, 1, #FUNCTIONS) == FUNCTIONS then
    return loadfile("src/functions/" .. string.sub(path, #FUNCTIONS + 1))
  end
  assert(string.sub(path, 1, #CORE) == CORE, "unexpected module path: " .. tostring(path))
  local relative = string.sub(path, #CORE + 1)
  if STAND_INS[relative] then return STAND_INS[relative] end
  return loadfile("src/rfsuite/" .. relative)
end

-- A fresh script state: nothing of the suite loaded, the card as it stands.
local function boot()
  _G.rfsuite = nil
  _G.__rfsuite_config_store = nil
  fstat = realFstat
  local script = assert(loadScript(FUNCTIONS .. "rfsbg.lua"))()
  assert(type(script) == "table" and type(script.run) == "function", "rfsbg.lua returns no run function")
  return script
end

local function cycle(script)
  clock = clock + CYCLE
  script.run()
end

local function runFor(script, seconds)
  for _ = 1, math.floor(seconds * 100 / CYCLE + 0.5) do cycle(script) end
end

-- Runs until `done()` holds, at most `limit` seconds. Answers the seconds it took, or nil.
local function runUntil(script, limit, done)
  local start = clock
  for _ = 1, math.floor(limit * 100 / CYCLE + 0.5) do
    cycle(script)
    if done() then return (clock - start) / 100 end
  end
  return nil
end

local function prefs() return _G.rfsuite and _G.rfsuite.preferences end

local function adjustmentEvents()
  local p = prefs()
  return p and p.audio_events and p.audio_events.adjustment_events
end

-- The settings as the tool saves them: the real save, with the reload request it bumps. It runs
-- in a throwaway state, as the tool's own, and only the card it leaves behind is kept.
local function toolSave(edit)
  local keepRoot, keepStore, keepFstat = _G.rfsuite, _G.__rfsuite_config_store, fstat
  _G.rfsuite = nil
  _G.__rfsuite_config_store = nil
  fstat = realFstat
  assert(loadScript(CORE .. "lib/require.lua"))()
  local Preferences = _G.rfsuite.require("lib/preferences.lua")
  local p = Preferences.load()
  edit(p)
  assert(Preferences.save(p), "the tool's save failed")
  _G.rfsuite, _G.__rfsuite_config_store, fstat = keepRoot, keepStore, keepFstat
end

local function settingsOpens()
  return (opens[PREFS] or 0) + (opens[LEGACY] or 0) + (opens[PREFS .. ".tmp"] or 0)
end

local function zeroCounts()
  opens, reads, stats = {}, {}, 0
end

-- ------------------------------------------------------------------------------- 1 and 2

do
  resetCard()
  toolSave(function(p) p.audio_events.adjustment_events = false end)
  local script = boot()
  zeroCounts()
  runFor(script, 1)
  -- The control the count below cannot do without: the first read is seen by the same counter.
  check(settingsOpens() > 0, "1: the first run reads the settings file (control; opens "
    .. settingsOpens() .. ")")
  check(adjustmentEvents() == false, "1: the saved setting is read on the first run")

  runFor(script, 2 * INTERVAL)
  local held = prefs()
  zeroCounts()
  local quiet = 10
  runFor(script, quiet * INTERVAL)
  check(settingsOpens() == 0, string.format(
    "1: %d quiet intervals open the settings file %d times, %d reads (0 expected)",
    quiet, settingsOpens(), (reads[PREFS] or 0)))
  check(prefs() == held, "1: rfsuite.preferences stays the same table while nothing changed")

  -- 2. A save from the tool, at an arbitrary point inside an interval.
  runFor(script, 7.3)
  toolSave(function(p) p.audio_events.adjustment_events = true end)
  local took = runUntil(script, INTERVAL + 1, function() return adjustmentEvents() == true end)
  check(took ~= nil and took <= INTERVAL + 2 * CYCLE / 100, string.format(
    "2: a saved change reaches rfsuite.preferences within %d s (took %s)", INTERVAL, tostring(took)))

  -- Once adopted, quiet again.
  runFor(script, INTERVAL + 1)
  zeroCounts()
  runFor(script, 3 * INTERVAL)
  check(settingsOpens() == 0, "2: after the change is read, quiet intervals open nothing (opens "
    .. settingsOpens() .. ")")
end

-- ------------------------------------------------------------------------------- 3

do
  resetCard()
  local script = boot()
  runFor(script, 1)
  local p = prefs()
  check(type(p) == "table" and type(p.general) == "table" and p.general.debug_level == "off",
    "3: with no settings file the declared defaults are in rfsuite.preferences")
  check(files[PREFS] == nil, "3: reading a card without a settings file writes none")

  runFor(script, INTERVAL)
  zeroCounts()
  runFor(script, 5 * INTERVAL)
  check(settingsOpens() == 0, "3: a missing settings file is not probed on every interval (opens "
    .. settingsOpens() .. ")")

  toolSave(function(q) q.audio_events.adjustment_events = true end)
  local took = runUntil(script, INTERVAL + 1, function() return adjustmentEvents() == true end)
  check(took ~= nil, "3: the first save on such a card is picked up within one interval (took "
    .. tostring(took) .. ")")
end

-- ------------------------------------------------------------------------------- 4

local LEGACY_TEXT = "[general]\ndebug_level=off\n[audio_events]\nadjustment_events=true\n"

do
  resetCard()
  files[LEGACY] = { data = LEGACY_TEXT, time = cardTime() }
  local script = boot()
  runFor(script, 1)
  check(files[PREFS] ~= nil, "4: the former file is brought across on the first read")
  check(files[LEGACY] == nil and files[LEGACY .. ".bak"] ~= nil, "4: the former file is set aside")
  check(adjustmentEvents() == true, "4: the brought-across value is in rfsuite.preferences")
  runFor(script, 2 * INTERVAL + 1)
  zeroCounts()
  runFor(script, 3 * INTERVAL)
  check(settingsOpens() == 0, "4: after the bring-across, quiet intervals open nothing (opens "
    .. settingsOpens() .. ")")
end

do
  resetCard()
  files[LEGACY] = { data = LEGACY_TEXT, time = cardTime() }
  failWrite[PREFS .. ".tmp"] = true
  failWrite[PREFS] = true
  local script = boot()
  runFor(script, 1)
  check(files[PREFS] == nil and files[LEGACY] ~= nil, "4: a refused write leaves the former file in place")
  check(adjustmentEvents() == true, "4: with the write refused the former file's values are still read")

  -- The card takes writes again: the next interval brings it across.
  failWrite = {}
  local took = runUntil(script, INTERVAL + 1, function() return files[PREFS] ~= nil end)
  check(took ~= nil, "4: a bring-across whose write failed is tried again within one interval (took "
    .. tostring(took) .. ")")
  check(adjustmentEvents() == true, "4: after the retried bring-across the value is still there")
end

do
  -- An empty settings file in the new file's place: the store treats it as not there, so the
  -- former file is still the one to bring across.
  resetCard()
  files[PREFS] = { data = "", time = cardTime() }
  files[LEGACY] = { data = LEGACY_TEXT, time = cardTime() }
  failWrite[PREFS .. ".tmp"] = true
  failWrite[PREFS] = true
  local script = boot()
  runFor(script, 1)
  check(files[PREFS].data == "" and files[LEGACY] ~= nil,
    "4: with an empty settings file and the write refused the former file stays in place")
  check(adjustmentEvents() == true, "4: with an empty settings file the former file's values are read")

  failWrite = {}
  local took = runUntil(script, INTERVAL + 1, function() return files[PREFS].data ~= "" end)
  check(took ~= nil, "4: over an empty settings file a bring-across whose write failed is tried again"
    .. " within one interval (took " .. tostring(took) .. ")")
  check(files[LEGACY] == nil and adjustmentEvents() == true,
    "4: over an empty settings file the retried bring-across sets the former file aside and keeps the value")
end

-- ------------------------------------------------------------------------------- 5

do
  resetCard()
  toolSave(function(p) p.audio_events.adjustment_events = false end)
  local script = boot()
  runFor(script, 2 * INTERVAL + 1)
  local held = prefs()

  toolSave(function(p) p.audio_events.adjustment_events = true end)
  raiseRead[PREFS] = true
  -- The interval whose read raises.
  local raised = runUntil(script, INTERVAL + 1, function() return raiseRead[PREFS] == nil end)
  check(raised ~= nil, "5: the read on the next interval is the one that raises (control)")
  check(prefs() == held and adjustmentEvents() == false,
    "5: a read that raised leaves the settings already held in place")
  local took = runUntil(script, INTERVAL + 1, function() return adjustmentEvents() == true end)
  check(took ~= nil, "5: the interval after a read that raised reads the change (took "
    .. tostring(took) .. ")")
end

do
  -- A save is seen, but on the interval that reads it the card does not hand the file over: the
  -- store answers the declared defaults without raising.
  resetCard()
  toolSave(function(p) p.audio_events.adjustment_events = false end)
  local script = boot()
  runFor(script, 2 * INTERVAL + 1)

  toolSave(function(p) p.audio_events.adjustment_events = true end)
  nilOpen[PREFS] = true
  local missed = runUntil(script, INTERVAL + 1, function() return nilOpen[PREFS] == nil end)
  check(missed ~= nil, "5: the read on the next interval is the one the card does not answer (control)")
  local took = runUntil(script, INTERVAL + 1, function() return adjustmentEvents() == true end)
  check(took ~= nil, "5: after a settings file the card did not hand over, the next interval reads it"
    .. " again (took " .. tostring(took) .. ")")
end

-- ------------------------------------------------------------------------------- 6

do
  resetCard()
  frozenRtc = { year = 2026, mon = 1, day = 1, hour = 0, min = 0, sec = 0 }
  toolSave(function(p) p.audio_events.adjustment_events = false end)
  local script = boot()
  runFor(script, 2 * INTERVAL + 1)

  -- The same number of bytes with another value, under the same card time.
  local before = files[PREFS]
  local edited, n = string.gsub(before.data, "adjustment_events = false,", "adjustment_events = true, ")
  assert(n == 1 and #edited == #before.data, "setup: the same-size edit did not apply")
  files[PREFS] = { data = edited, time = before.time }
  -- What every save of the suite does beside the file: the rotating reload request.
  local MP = _G.rfsuite.require("lib/model_preferences.lua")
  MP.bumpReloadCounter(USER)
  local took = runUntil(script, INTERVAL + 1, function() return adjustmentEvents() == true end)
  check(took ~= nil, "6: a write that keeps size and time is picked up by the reload request (took "
    .. tostring(took) .. ")")
end

-- ------------------------------------------------------------------------------- 7

do
  resetCard()
  toolSave(function(p) p.audio_events.adjustment_events = false end)
  local script = boot()
  fstat = nil
  runFor(script, 2 * INTERVAL + 1)
  zeroCounts()
  runFor(script, 3 * INTERVAL)
  check(settingsOpens() >= 3, "7: without fstat the settings are read on every interval (opens "
    .. settingsOpens() .. ")")
  -- Written behind the script's back, the way only a radio without fstat leaves undetectable.
  local edited = string.gsub(files[PREFS].data, "adjustment_events = false,", "adjustment_events = true,")
  files[PREFS] = { data = edited, time = cardTime() }
  local took = runUntil(script, INTERVAL + 1, function() return adjustmentEvents() == true end)
  check(took ~= nil, "7: without fstat a change is read within one interval (took " .. tostring(took) .. ")")
  fstat = realFstat
end

-- ------------------------------------------------------------------------------- 8

do
  resetCard()
  -- A save cut off part-way: the table is never closed.
  files[PREFS] = { data = "return {\n  general = {\n", time = cardTime() }
  local script = boot()
  runFor(script, 1)
  local p = prefs()
  check(type(p) == "table" and type(p.general) == "table" and p.general.debug_level == "off",
    "8: with a settings file that does not compile the declared defaults are in rfsuite.preferences")
  runFor(script, INTERVAL)
  zeroCounts()
  runFor(script, 5 * INTERVAL)
  check(settingsOpens() == 0, "8: a settings file that does not compile is not read on every interval (opens "
    .. settingsOpens() .. ")")
  toolSave(function(q) q.audio_events.adjustment_events = true end)
  local took = runUntil(script, INTERVAL + 1, function() return adjustmentEvents() == true end)
  check(took ~= nil, "8: the save that replaces it is picked up within one interval (took " .. tostring(took) .. ")")
end

print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
