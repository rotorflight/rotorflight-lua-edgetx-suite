-- The Tune Advisor flight history and the change journal it is read beside.
--
-- Run from the repository root:
--     lua5.3 bin/flight_tuning/verify_tune_history.lua
--
-- Drives the real src/rfsuite/lib/tune_history.lua, lib/change_journal.lua, lib/atomic_file.lua
-- (the whole-file replace) and tasks/msp/api/tune_advisor.lua (the simulator replies the flights are
-- made of) against an in-memory card that answers io.open/io.read/io.write/io.close, fstat,
-- mkdir, rename and del the way the radio's filesystem library does.
--
-- The cases under "Ethos suite" are the Ethos suite's bin/tune_history/verify_tune_history.lua
-- at commit 098da94426 that test the history itself -- the aggregate and the Apply record -- and
-- the pilotValue cases of its bin/tune_advisor_apply/verify_tune_advisor_apply.lua, with the
-- same names, inputs and expected results. Two things differ by design and are named there:
-- a flight is saved by calling save() with three decoded replies (the Ethos cases save through
-- the disarm task, which this file does not cover), and each such flight is saved with one
-- known context (profiles, cyclic polarity, cyclic ring, relax type), since a flight of unknown
-- context is never combined with another. The Apply record is this suite's change journal.
-- The disarm capture and its pacing are the Ethos cases of the same file, driven through this
-- suite's event runtime, the real src/rfsuite/tasks/events/runtime.lua (bin/flight_tuning/
-- tune_capture_rig.lua); its request gate is
-- bin/flight_tuning/verify_tune_advisor_gate.lua.
--
-- Against a tree without lib/tune_history.lua this script stops at the first load: red.

local failures, checks = 0, 0
local function check(label, ok, detail)
  checks = checks + 1
  if ok then
    print("  ok    " .. label)
  else
    failures = failures + 1
    print("FAIL " .. label)
    if detail then print("        " .. tostring(detail)) end
  end
end

-- ---------------------------------------------------------------------------
-- The card: paths under /SCRIPTS/RFSUITE/user live in `files`.
-- ---------------------------------------------------------------------------
-- luacheck: globals io
local files = {}
local renameFails = {}         -- source path -> true: that rename answers an error
local openFails = {}           -- path -> n: the next n opens for reading answer nil
local renames = {}

io.open = function(path, mode)
  mode = mode or "r"
  if string.sub(mode, 1, 1) == "r" then
    if files[path] == nil then return nil end
    if (openFails[path] or 0) > 0 then openFails[path] = openFails[path] - 1; return nil end
    return { path = path, pos = 1, mode = "r" }
  end
  if string.sub(mode, 1, 1) == "w" then files[path] = "" end
  if string.sub(mode, 1, 1) == "a" and files[path] == nil then files[path] = "" end
  return { path = path, mode = "w" }
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
io.close = function() return true end
io.seek = function(f, at) f.pos = at + 1 end
function fstat(path)
  if files[path] == nil then return nil end
  return { size = #files[path] }
end
function mkdir() return 0 end
function del(path) files[path] = nil; return 0 end
function rename(from, to)
  renames[#renames + 1] = from .. " -> " .. to
  if renameFails[from] then return 1 end
  if files[from] == nil or files[to] ~= nil then return 8 end
  files[to], files[from] = files[from], nil
  return 0
end
function loadScript(path)
  local relative = string.match(path, "^/SCRIPTS/RFSUITE/core/(.+)$")
  assert(relative == "lib/atomic_file.lua", "unexpected module: " .. tostring(path))
  return assert(loadfile("src/rfsuite/" .. relative))
end
_G.rfsuite = { paths = dofile("src/rfsuite/lib/paths.lua") }

local Api = assert(loadfile("src/rfsuite/tasks/msp/api/tune_advisor.lua"))()
local tuneHistory = assert(loadfile("src/rfsuite/lib/tune_history.lua"))()
local journal = assert(loadfile("src/rfsuite/lib/change_journal.lua"))()

local MCU = "abc123"
local HISTORY = "/SCRIPTS/RFSUITE/user/tune/" .. MCU .. ".lua"
local JOURNAL = "/SCRIPTS/RFSUITE/user/journal/" .. MCU .. ".lua"
local CONTEXT = { pidProfile = 1, rateProfile = 1, cyclicPolarity = 0, cyclicRing = 0, relaxType = 2 }

local function reset()
  for k in pairs(files) do files[k] = nil end
  for k in pairs(renameFails) do renameFails[k] = nil end
  for k in pairs(openFails) do openFails[k] = nil end
  for i = #renames, 1, -1 do renames[i] = nil end
end

-- Three decoded simulator replies with these overrides on every axis
local function replies(seconds, fields)
  local out = {}
  for axis = 1, 3 do
    local d = assert(Api.parse(Api.simulatorResponseFor(axis)))
    d.seconds = seconds
    for k, v in pairs(fields or {}) do d.a[k] = v end
    out[axis] = d
  end
  return out
end

local clock = 1000
local function fly(seconds, f, context, extra)
  clock = clock + 60
  local fields = { F = f or 100 }
  for k, v in pairs(extra or {}) do fields[k] = v end
  return tuneHistory.save(MCU, replies(seconds, fields), context or CONTEXT, clock)
end

local function lines()
  local out = {}
  for l in string.gmatch(files[HISTORY] or "", "[^\n]+") do out[#out + 1] = l end
  return out
end

local function entriesText(rows)
  local out = {}
  for i = 1, #rows do out[i] = rows[i] end
  return table.concat(out, "\n") .. "\n"
end

-- ---------------------------------------------------------------------------
print("Ethos suite: the history file")
-- ---------------------------------------------------------------------------
do
  reset()
  fly(147)
  for n = 1, 6 do fly(100 + n) end
  local r = lines()
  check("only the last 5 flights are kept", #r == 16 and string.find(r[2], ',102,"roll",', 1, true) ~= nil
    and string.find(r[14], ',106,"roll",', 1, true) ~= nil, #r .. " lines; first " .. tostring(r[2]))
end

print("Ethos suite: the page's aggregate")
do
  reset()
  fly(60, 100)
  fly(70, 80)
  fly(80, 80)
  local flights = tuneHistory.read(MCU)
  check("the history reads back as flights", #flights == 3 and flights[3].seconds == 80
    and flights[3].axes[1].F == 80 and flights[3].axes[3].P == 100, #flights .. " flights")

  local a, used, seconds = tuneHistory.aggregate(flights, 1)
  local one = flights[3].axes[1]
  check("only flights on the newest tune are combined", used == 2 and seconds == 150 and a.F == 80,
    used .. " flights, " .. seconds .. " s")
  check("counts add up", a.ffCount == 2 * one.ffCount and a.releases == 2 * one.releases
    and a.spBands[1].count == 2 * one.spBands[1].count, a.ffCount)
  check("ratios are weighted means", math.abs(a.ffGain - one.ffGain) < 1e-9
    and math.abs(a.meanRebound - one.meanRebound) < 1e-9, a.ffGain)

  for n = 1, 6 do fly(90 + n, 80) end
  local _, usedMax = tuneHistory.aggregate(tuneHistory.read(MCU), 1)
  check("at most 5 flights are combined", usedMax == 5, usedMax)

  local empty, none = tuneHistory.aggregate({}, 2)
  check("no flights aggregate to zeros", none == 0 and empty.ffCount == 0 and empty.collBands[3].count == 0)

  files[HISTORY] = "some,other,columns\n1,2,3\n"
  check("a file with other columns reads as no flights", #tuneHistory.read(MCU) == 0)
end

print("Ethos suite: the Apply record reads back (this suite's change journal)")
do
  reset()
  files[JOURNAL] = entriesText({
    'e(1759312800,"tune_advisor",1,"pid_0_P",50,60)',
    'e(1759312800,"tune_advisor",1,"iterm_relax_cutoff_1",10,8)',
    "not,a,row",
  })
  local rows = journal.read(MCU) or {}
  check("each row reads as axis, setting, from, to", #rows == 2 and rows[1].field == "pid_0_P"
    and rows[1].old == 50 and rows[1].new == 60 and rows[2].field == "iterm_relax_cutoff_1" and rows[2].new == 8,
    #rows)
  files[JOURNAL] = nil
  rows = journal.read(MCU)
  check("no file reads as no changes", type(rows) == "table" and #rows == 0)
  files[JOURNAL] = "other,header\n1,2\n"
  rows = journal.read(MCU)
  check("a foreign file reads as no changes", type(rows) == "table" and #rows == 0, tostring(rows))
  files[JOURNAL] = 'date;axis;setting\ne(1759312800,"tune_advisor",1,"pid_0_P",50,60)\n'
  rows = journal.read(MCU)
  check("rows under another header are still read", type(rows) == "table" and #rows == 1, tostring(rows))
  files[JOURNAL] = nil
end

print("Ethos suite: pilotValue follows only an unbroken chain of Apply changes")
do
  local log = {
    { source = "tune_advisor", profile = 1, field = "pid_0_P", old = 40, new = 48 },
    { source = "tune_advisor", profile = 1, field = "pid_0_F", old = 100, new = 80 },
    { source = "tune_advisor", profile = 1, field = "pid_0_P", old = 48, new = 58 },
  }
  check("follows the chain back", tuneHistory.pilotValue(log, 1, "pid_0_P", 58) == 40)
  check("a different current value is the pilot's", tuneHistory.pilotValue(log, 1, "pid_0_P", 65) == 65)
  check("another axis is not followed", tuneHistory.pilotValue(log, 1, "pid_1_P", 58) == 58)
  check("no record: the current value", tuneHistory.pilotValue({}, 1, "pid_0_P", 58) == 58)
end

-- ---------------------------------------------------------------------------
print("Differences from the Ethos suite: the file (#979)")
-- ---------------------------------------------------------------------------
do
  reset()
  fly(147)
  local r = lines()
  check("a version line and one line per axis are written", #r == 4 and r[1] == "v(1)"
    and string.find(r[2], '^f%(%d+,147,"roll",1,1,0,0,2,70,100,0,10,4,18,24,') ~= nil
    and string.find(r[3], ',"pitch",', 1, true) ~= nil and string.find(r[4], ',"yaw",', 1, true) ~= nil,
    table.concat(r, "\n"))
  local _, commas2 = string.gsub(r[2], ",", "")
  local _, commas4 = string.gsub(r[4], ",", "")
  check("every line carries the same values", commas2 == commas4 and commas2 == 8 + #tuneHistory.FIELDS - 1,
    commas2 .. " vs " .. commas4)
  check("values keep their precision", string.find(r[2], ",1.531,", 1, true) ~= nil
    and string.find(r[2], ",3.0)", 1, true) ~= nil, r[2])
  -- A time stamp is an integer and is written as one: a radio built with 32-bit floats cannot
  -- hold today's clock in a float, so no step may pass it through one. 2^53 + 1 shows a float
  -- step on a desktop build as well.
  reset()
  tuneHistory.save(MCU, replies(147), CONTEXT, 1761900001)
  local stamped = tuneHistory.read(MCU)[1]
  check("the radio clock is written and read back as the same integer", stamped ~= nil
    and math.type(stamped.time) == "integer" and stamped.time == 1761900001, tostring(stamped and stamped.time))
  reset()
  tuneHistory.save(MCU, replies(147), CONTEXT, 9007199254740993)
  stamped = tuneHistory.read(MCU)[1]
  check("a time stamp never passes through a float on its way to the card", stamped ~= nil
    and stamped.time == 9007199254740993, tostring(stamped and stamped.time))
  reset()
  fly(147)
  check("the file lives per flight controller under the user directory",
    tuneHistory.path("ab c/1") == "/SCRIPTS/RFSUITE/user/tune/ab_c_1.lua"
    and string.match(journal.path("ab c/1"), "[^/]+$") == string.match(tuneHistory.path("ab c/1"), "[^/]+$"))

  fly(150)
  local before = files[HISTORY]
  files[HISTORY] = string.sub(before, 1, #before - 30)
  local flights = tuneHistory.read(MCU)
  check("a torn last line loses that line only", #flights == 2 and flights[2].axes[1] ~= nil
    and flights[2].axes[2] ~= nil and flights[2].axes[3] == nil and flights[1].axes[3] ~= nil, #flights .. " flights")

  r = lines()
  r[3] = "f(1,2,3"
  files[HISTORY] = table.concat(r, "\n") .. "\n"
  flights = tuneHistory.read(MCU)
  check("a broken line in the middle is skipped, the rest still read", #flights == 2
    and flights[1].axes[2] == nil and flights[1].axes[1] ~= nil and flights[2].axes[1] ~= nil, #flights .. " flights")

  r[3] = 'f(1,2,"roll",1,1,0,0,2,"x")'
  files[HISTORY] = table.concat(r, "\n") .. "\n"
  check("a line with a value that is not a number is skipped", #tuneHistory.read(MCU) == 2)

  r[1] = "v(2)"
  files[HISTORY] = table.concat(r, "\n") .. "\n"
  local none, why = tuneHistory.read(MCU)
  check("the version line is read on the line-by-line path too", #none == 0 and why == "version", tostring(why))
  check("a file of another version is started again", fly(160) and #lines() == 4 and lines()[1] == "v(1)",
    #lines() .. " lines")

  -- The page reads in steps: the file on one, then no more than one flight's lines on each
  reset()
  for n = 1, 5 do fly(100 + n) end
  local job, steps, most = tuneHistory.readJob(MCU), 0, 0
  local got
  repeat
    local col = job.collector
    local rowsBefore = col and #col.rows or 0
    got = tuneHistory.readStep(job)
    steps = steps + 1
    if col then most = math.max(most, #col.rows - rowsBefore) end
  until got ~= nil
  local whole = tuneHistory.read(MCU)
  check("a stepped read parses at most one flight's lines per step and reads what read() reads",
    steps >= 6 and most >= 1 and most <= 3 and #got == 5 and #whole == 5 and got[5].seconds == 105
    and got[5].axes[3].P == whole[5].axes[3].P and got[1].axes[1].ffGain == whole[1].axes[1].ffGain,
    steps .. " steps, at most " .. most .. " lines, " .. #got .. " flights")

  reset()
  fly(147)
  check("a save writes beside the file and renames it into place",
    renames[#renames] == HISTORY .. ".new -> " .. HISTORY and files[HISTORY .. ".new"] == nil, renames[#renames])
  local kept = files[HISTORY]
  renameFails[HISTORY .. ".new"] = true
  check("a save whose rename fails reports it", fly(150) == false)
  check("a failed rename leaves the previous file whole", files[HISTORY] == kept, tostring(files[HISTORY]))
  renameFails[HISTORY .. ".new"] = nil

  check("erase removes the file", tuneHistory.erase(MCU) == true and files[HISTORY] == nil)

  -- A replace cut short between parking the file as .bak and renaming .new into place leaves no
  -- file under the name, only the .bak.
  reset()
  for n = 1, 4 do fly(100 + n) end
  files[HISTORY .. ".bak"], files[HISTORY] = files[HISTORY], nil
  check("a replace cut short after parking the file: the flights are read from the .bak",
    #tuneHistory.read(MCU) == 4, #tuneHistory.read(MCU) .. " flights")
  fly(105)
  check("the next save keeps them", #tuneHistory.read(MCU) == 5 and files[HISTORY] ~= nil,
    #tuneHistory.read(MCU) .. " flights")
  fly(106)
  check("and so does the save after it, which replaces the .bak", #tuneHistory.read(MCU) == 5
    and tuneHistory.read(MCU)[1].seconds == 102, #tuneHistory.read(MCU) .. " flights")
  files[HISTORY .. ".bak"] = files[HISTORY]
  check("erase removes the .bak too, so nothing comes back after it", tuneHistory.erase(MCU) == true
    and files[HISTORY] == nil and files[HISTORY .. ".bak"] == nil and #tuneHistory.read(MCU) == 0)

  -- The replace itself: a file that is not there is never parked, and a .bak is never removed
  -- while no file stands under the name
  local AtomicFile = assert(loadfile("src/rfsuite/lib/atomic_file.lua"))()
  reset()
  files["/x.bak"] = "only copy"
  check("a replace that may not create leaves the .bak alone when the file is missing",
    AtomicFile.replace("/x", "new", false) == false and files["/x.bak"] == "only copy" and files["/x"] == nil)
  reset()
  files["/x.bak"] = "only copy"
  check("a replace that may create writes the file and leaves the .bak alone",
    AtomicFile.replace("/x", "new", true) == true and files["/x"] == "new" and files["/x.bak"] == "only copy")

  -- The file is rebuilt from what read() returned: a read that failed must not become a file
  -- holding the new flight alone.
  reset()
  fly(147)
  fly(150)
  kept = files[HISTORY]
  openFails[HISTORY] = 1
  local ok
  ok, why = fly(160)
  check("a file that cannot be opened is not written over", ok == false and why == "open"
    and files[HISTORY] == kept, tostring(why))
  check("the next save after it keeps every flight", fly(170) == true and #tuneHistory.read(MCU) == 3,
    #tuneHistory.read(MCU) .. " flights")
  files[HISTORY] = kept .. string.rep("-- padding ", 1700)
  local big = files[HISTORY]
  ok, why = fly(180)
  check("a file over the read cap is not written over", ok == false and why == "too big"
    and files[HISTORY] == big, tostring(why))
end

print("Differences from the Ethos suite: profiles, polarity, ring and relax type (#979)")
do
  reset()
  fly(147, 100, { pidProfile = 2, rateProfile = 3 })
  local a = tuneHistory.read(MCU)[1].axes[1]
  check("profiles read back, what was not known reads as unknown", a.pidProfile == 2 and a.rateProfile == 3
    and a.cyclicPolarity == nil and a.cyclicRing == nil and a.relaxType == nil)
  check("a line of unknown context writes nil", string.find(lines()[2], ',"roll",2,3,nil,nil,nil,', 1, true) ~= nil,
    lines()[2])
  fly(150, 100, { pidProfile = 2, rateProfile = 3 })
  check("context read after the save fills in the newest flight",
    tuneHistory.setContext(MCU, { cyclicPolarity = 1, cyclicRing = 80, relaxType = 1 }) == true)
  local flights = tuneHistory.read(MCU)
  local newest, older = flights[2].axes[3], flights[1].axes[3]
  check("the newest flight carries it on every axis, the older one does not", #flights == 2
    and newest.cyclicPolarity == 1 and newest.cyclicRing == 80 and newest.relaxType == 1 and newest.pidProfile == 2
    and older.cyclicPolarity == nil)

  local agg, used = tuneHistory.aggregate(flights, 1)
  check("unknown context is never combined: the newest flight counts alone", used == 1
    and agg.cyclicPolarity == 1 and agg.cyclicRing == 80 and agg.relaxType == 1 and agg.pidProfile == 2, used)

  reset()
  fly(60, 100, { pidProfile = 1, rateProfile = 1 })
  fly(60, 100, { pidProfile = 1, rateProfile = 1 })
  local _, unknownUsed = tuneHistory.aggregate(tuneHistory.read(MCU), 1)
  check("two flights of unknown context on the same tune are not combined", unknownUsed == 1, unknownUsed)

  local function pairUsed(ctxA, ctxB)
    reset()
    fly(60, 100, ctxA)
    fly(60, 100, ctxB)
    local _, n = tuneHistory.aggregate(tuneHistory.read(MCU), 1)
    return n
  end
  local base = { pidProfile = 1, rateProfile = 1, cyclicPolarity = 0, cyclicRing = 100, relaxType = 2 }
  local function with(k, v) local c = {} for kk, vv in pairs(base) do c[kk] = vv end c[k] = v return c end
  check("the same context on the same tune is combined", pairUsed(base, base) == 2)
  check("another cyclic polarity is not combined", pairUsed(base, with("cyclicPolarity", 1)) == 1)
  check("another cyclic ring is not combined", pairUsed(base, with("cyclicRing", 80)) == 1)
  check("another relax type is not combined", pairUsed(base, with("relaxType", 1)) == 1)

  -- #1166: the PID and rate profile too, and per profile: flights on other profiles are passed
  -- over, not ended at. aggregate's fourth value says the list also holds flights on other known
  -- profiles.
  local function pairOthers(ctxOld, ctxNew, fOld)
    reset()
    fly(60, fOld or 100, ctxOld)
    fly(60, 100, ctxNew)
    local _, n, _, others = tuneHistory.aggregate(tuneHistory.read(MCU), 1)
    return n, others
  end
  local n, others = pairOthers(base, base)
  check("(control) the same profiles: combined, no other profiles", n == 2 and not others,
    tostring(n) .. " " .. tostring(others))
  n, others = pairOthers(with("pidProfile", 2), base)
  check("another PID profile is not combined, and other profiles are said to be kept", n == 1 and others == true,
    tostring(n) .. " " .. tostring(others))
  n, others = pairOthers(with("rateProfile", 2), base)
  check("another rate profile is not combined, and other profiles are said to be kept", n == 1 and others == true,
    tostring(n) .. " " .. tostring(others))
  n, others = pairOthers(with("pidProfile", nil), base)
  check("an older flight of unknown PID profile is not combined, and is no other known profile",
    n == 1 and not others, tostring(n) .. " " .. tostring(others))
  n, others = pairOthers(base, with("rateProfile", nil))
  check("a newest flight of unknown rate profile counts alone", n == 1, tostring(n) .. " " .. tostring(others))
  n, others = pairOthers(with("cyclicRing", 80), base)
  check("ended by another setting on the same profiles: no other profiles", n == 1 and not others,
    tostring(n) .. " " .. tostring(others))
  local _, none, _, noneOthers = tuneHistory.aggregate({}, 1)
  check("no flights: nothing combined, no other profiles", none == 0 and not noneOthers)

  -- Per profile: P1, P2, P1 -- the flight on P2 is passed over
  local P2 = with("pidProfile", 2)
  reset()
  fly(60, 100, base)
  fly(70, 100, P2)
  fly(80, 100, base)
  local flights = tuneHistory.read(MCU)
  local _, usedP1, secP1 = tuneHistory.aggregate(flights, 1, 1, 1)
  check("P1, P2, P1: both P1 flights are combined, the P2 flight passed over", usedP1 == 2 and secP1 == 140,
    usedP1 .. " / " .. secP1)
  local aP2, usedP2, secP2 = tuneHistory.aggregate(flights, 1, 2, 1)
  check("with P2 active its own flight is shown", usedP2 == 1 and secP2 == 70 and aP2.pidProfile == 2,
    usedP2 .. " / " .. secP2)
  local _, usedP3, _, othersP3 = tuneHistory.aggregate(flights, 1, 3, 1)
  check("with a profile no flight was flown on: nothing combined, other profiles kept", usedP3 == 0 and othersP3,
    usedP3)
  local _, usedNewest = tuneHistory.aggregate(flights, 1)
  check("(control) without profiles the newest flight's are used", usedNewest == 2, usedNewest)

  -- At most five combined per profile, counted over other profiles' flights
  reset()
  for k = 1, 6 do fly(60 + k, 100, base); fly(30, 100, P2) end
  local _, usedMax = tuneHistory.aggregate(tuneHistory.read(MCU), 1, 1, 1)
  check("at most 5 flights of one profile are combined, with others between", usedMax == 5, usedMax)

  -- Kept per profile: a burst on P2 does not push P1's flights out
  reset()
  for _ = 1, 3 do fly(60, 100, base) end
  for _ = 1, 6 do fly(30, 100, P2) end
  flights = tuneHistory.read(MCU)
  local p1, p2 = 0, 0
  for _, f in ipairs(flights) do
    if f.pidProfile == 1 then p1 = p1 + 1 elseif f.pidProfile == 2 then p2 = p2 + 1 end
  end
  check("kept per profile: six P2 flights leave P1's three, and keep P2's newest five", p1 == 3 and p2 == 5,
    p1 .. " P1, " .. p2 .. " P2")

  -- At most 20 in the file: the profile with the most flights gives up its oldest
  reset()
  for pidp = 1, 5 do
    for _ = 1, 5 do fly(40 + pidp, 100, with("pidProfile", pidp)) end
  end
  flights = tuneHistory.read(MCU)
  local per = {}
  for _, f in ipairs(flights) do per[f.pidProfile] = (per[f.pidProfile] or 0) + 1 end
  check("at most 20 flights in the file; the profiles with the most flights give up their oldest, so five profiles keep four each",
    #flights == 20 and per[1] == 4 and per[2] == 4 and per[3] == 4 and per[4] == 4 and per[5] == 4,
    #flights .. " flights, P1 " .. tostring(per[1]) .. ", P5 " .. tostring(per[5]))
  check("the file stays under the read cap", #files[HISTORY] < 16384, #files[HISTORY])

  -- Read with the active profiles: other profiles' flights come back without axis tables
  reset()
  fly(60, 100, base)
  fly(70, 100, P2)
  flights = tuneHistory.read(MCU, 1, 1)
  check("a read for P1 builds no axis tables for P2's flight", #flights == 2 and flights[2].axes[1] == nil
    and flights[2].pidProfile == 2 and flights[1].axes[1] ~= nil, #flights)
  local _, filtered = tuneHistory.aggregate(flights, 1, 1, 1)
  check("(control) and still combines P1's flight", filtered == 1, filtered)
end

print("Differences from the Ethos suite: under polar cyclic Roll flies on Pitch's rates (#981)")
do
  -- Two flights, each with these rate bytes on Roll and on Pitch; how many Roll combines
  local function rollUsed(polarity, roll1, pitch1, roll2, pitch2)
    reset()
    local ctx = { pidProfile = 1, rateProfile = 1, cyclicPolarity = polarity, cyclicRing = 100, relaxType = 2 }
    for _, pair in ipairs({ { roll1, pitch1 }, { roll2, pitch2 } }) do
      local r = replies(60)
      r[1].a.rcRate, r[2].a.rcRate = pair[1], pair[2]
      clock = clock + 60
      assert(tuneHistory.save(MCU, r, ctx, clock))
    end
    local _, n = tuneHistory.aggregate(tuneHistory.read(MCU), 1)
    return n
  end
  check("polar: a Pitch rate change ends Roll's flights, though Roll's own bytes are equal",
    rollUsed(1, 24, 24, 24, 30) == 1)
  check("polar: Roll's own unused rate bytes do not end them", rollUsed(1, 24, 24, 30, 24) == 2)
  check("polar off: Roll still goes by its own rates", rollUsed(0, 24, 24, 24, 30) == 2
    and rollUsed(0, 24, 24, 30, 24) == 1)
end

print("Differences from the Ethos suite: the change journal reads past a broken line (#979)")
do
  reset()
  files[JOURNAL] = 'e(1,"tune_advisor",1,"pid_0_P",40,48)\ne(2,"tune_advisor",1,"pid_0_P",48,'
  local rows = journal.read(MCU)
  check("a torn last journal line loses that line only", type(rows) == "table" and #rows == 1
    and rows[1].new == 48, tostring(rows))
  files[JOURNAL] = 'e(1,"tune_advisor",1,"pid_0_P",40,48)\ne(2,"tune_advisor",0,"pid_0_P",48,58)\n'
    .. 'e(3,"tune_advisor",1,"pid_0_P",48,58)\n'
  rows = journal.read(MCU)
  check("a journal entry that does not validate is skipped", type(rows) == "table" and #rows == 2
    and rows[2].time == 3, tostring(rows))
  files[JOURNAL] = nil
end

print("Differences from the Ethos suite: the change journal is read in steps (#980)")
do
  -- The journal grows with every save; the page reads it a bounded number of lines per step.
  reset()
  local text = {}
  for i = 1, 100 do
    local field = ({ "pid_0_F", "pid_1_P", "pid_0_P", "pid_2_B" })[i % 4 + 1]
    text[#text + 1] = string.format('e(%d,"%s",1,"%s",%d,%d)', 1761900000 + i, i % 2 == 0 and "tune_advisor" or "pids",
      field, 50 + i, 51 + i)
  end
  text[50] = 'e(1,"pids",1,"pid_0_P",4'
  files[JOURNAL] = table.concat(text, "\n") .. "\n"
  local whole = journal.read(MCU)
  local job, steps, most = journal.readJob(MCU), 0, 0
  local got
  repeat
    local before = job.entries and #job.entries or 0
    got = journal.readStep(job)
    steps = steps + 1
    if type(job.entries) == "table" then most = math.max(most, #job.entries - before) end
  until got ~= false
  check("the journal is read a bounded number of lines per step and reads what read() reads",
    type(got) == "table" and #got == 99 and #whole == 99 and steps >= 7 and most >= 1 and most <= 16
    and got[50].time == whole[50].time and got[99].new == whole[99].new,
    steps .. " steps, at most " .. most .. " entries, " .. tostring(got and #got))

  local only = journal.readJob(MCU, { pid_0_P = true, pid_1_P = true })
  repeat got = journal.readStep(only) until got ~= false
  local wrong = 0
  for _, e in ipairs(got) do
    if e.field ~= "pid_0_P" and e.field ~= "pid_1_P" then wrong = wrong + 1 end
  end
  check("a read asked for some fields keeps only their entries", #got == 49 and wrong == 0, #got .. " entries")

  -- One walk for the three axes answers what three walks answer
  local agree = true
  local wants = {}
  for axis = 0, 2 do wants[#wants + 1] = { profile = 1, field = "pid_" .. axis .. "_P", value = 51 + 99 } end
  tuneHistory.pilotValues(whole, wants)
  for _, w in ipairs(wants) do
    agree = agree and w.value == tuneHistory.pilotValue(whole, 1, w.field, 51 + 99)
  end
  check("pilotValues walks once and answers what pilotValue answers per field", agree)

  files[JOURNAL] = string.rep('e(1,"pids",1,"pid_0_P",1,2)\n', 3000)
  local none, why = journal.read(MCU)
  check("a journal over its read cap still answers nothing and the reason", none == nil and why == "too big",
    tostring(why))
  files[JOURNAL] = nil
end

print("Differences from the Ethos suite: pilotValue follows the Tune Advisor's own entries only (#980)")
do
  local handFirst = {
    { source = "pids", profile = 1, field = "pid_0_P", old = 30, new = 40 },
    { source = "tune_advisor", profile = 1, field = "pid_0_P", old = 40, new = 48 },
    { source = "tune_advisor", profile = 1, field = "pid_0_P", old = 48, new = 58 },
  }
  check("an entry of another source ends the walk at the value it set",
    tuneHistory.pilotValue(handFirst, 1, "pid_0_P", 58) == 40)
  local handLast = {
    { source = "tune_advisor", profile = 1, field = "pid_0_P", old = 40, new = 48 },
    { source = "pids", profile = 1, field = "pid_0_P", old = 48, new = 55 },
  }
  check("a hand edit after the advice is the pilot's value", tuneHistory.pilotValue(handLast, 1, "pid_0_P", 55) == 55)
  local otherProfile = {
    { source = "tune_advisor", profile = 2, field = "pid_0_P", old = 40, new = 58 },
  }
  check("another PID profile is not followed", tuneHistory.pilotValue(otherProfile, 1, "pid_0_P", 58) == 58)
  check("no journal at all: the current value", tuneHistory.pilotValue(nil, 1, "pid_0_P", 58) == 58)
end

-- ---------------------------------------------------------------------------
print("From the review")
-- ---------------------------------------------------------------------------
do
  reset()
  fly(60, 100, CONTEXT, { P = 50 })
  fly(60, 90, CONTEXT, { P = 60 })
  local _, used = tuneHistory.aggregate(tuneHistory.read(MCU), 1)
  check("P 50 -> 60 with F 100 -> 90 is another tune: not combined", used == 1, used)
  fly(60, 90, CONTEXT, { P = 60 })
  _, used = tuneHistory.aggregate(tuneHistory.read(MCU), 1)
  check("identical tunes are combined", used == 2, used)

  reset()
  for _ = 1, 5 do fly(120, 100, CONTEXT, { fullCount = 14000 }) end
  local a, n = tuneHistory.aggregate(tuneHistory.read(MCU), 1)
  check("5 x 14000 full-stick samples sum to 70000, not capped at 16 bits", n == 5 and a.fullCount == 70000,
    tostring(a.fullCount))
end

-- ---------------------------------------------------------------------------
-- The disarm capture, on the real event runtime (bin/flight_tuning/tune_capture_rig.lua)
-- ---------------------------------------------------------------------------
-- The Ethos cases drive their task through "session.update" and a scheduler; here every step is
-- a pass of tasks/events/runtime.lua, the disarm reaches the capture through the real ondisarm
-- runner (one task per pass, so the capture is marked a few passes after the edge), and the
-- flight controller's answers are given between passes as the queue would give them. Their
-- request strings name the Tune Advisor's own requests; the two settings reads that follow a
-- saved flight's clear (a difference, below) are recorded apart and answered as they come.
local Rig = assert(loadfile("bin/flight_tuning/tune_capture_rig.lua"))()
local rig

local function fresh(opts)
  reset()
  rig = Rig.new(opts)
end

local function update(armed)
  rig.setArmed(armed)
end

-- Runs the clock forward in half-second passes for `seconds` (default 30), answering each
-- request as it goes out. `fail` maps a request name to {n = times, reason = queue reason}:
-- that many of its sends end in the error handler instead. `limit` stops after that many Tune
-- Advisor requests. Returns what was asked, e.g. "roll,pitch,yaw,clear", and the clock at each.
local function pump(fail, limit, seconds)
  local asked, times = {}, {}
  local stopAt = rig.clock + (seconds or 30)
  while rig.clock < stopAt and not (limit and #asked >= limit) do
    rig.clock = rig.clock + 0.5
    rig.pass()
    while rig.requests[1] and not (limit and #asked >= limit) do
      local msg = rig.take()
      local name = rig.name(msg)
      if name == "status" then
        rig.statusAsked[#rig.statusAsked + 1] = name
      elseif name == "rc_tuning" or name == "pid_profile" then
        rig.contextAsked[#rig.contextAsked + 1] = name
      else
        asked[#asked + 1] = name
        times[#times + 1] = rig.clock
      end
      local f = fail and fail[name]
      if f and f.n > 0 then
        f.n = f.n - 1
        msg.errorHandler(msg, f.reason)
      else
        rig.answer(msg)
      end
    end
  end
  return table.concat(asked, ","), times
end

local function flyThrough(seconds, f)
  rig.reply.seconds, rig.reply.F = seconds, f or 100
  rig.clock = rig.clock + 60
  update(true)
  update(false)
  return pump()
end

-- Disarms, then lets the start wait pass: the pass that sends the first read. The runner marks
-- the capture a few passes after the edge, so this runs half-second passes until the read is
-- out rather than one pass five seconds later.
local function disarmAndWait()
  update(true)
  update(false)
  for _ = 1, 40 do
    if rig.requests[1] then break end
    rig.clock = rig.clock + 0.5
    rig.pass()
  end
end

local function drop() rig.drop() end

print("Ethos suite: the disarm capture")
do
  fresh()
  update(false)
  update(true)
  check("nothing is asked while armed", #rig.requests == 0, #rig.requests .. " requests")
  local disarmedAt = rig.clock
  update(false)
  check("nothing is asked straight after the disarm", #rig.requests == 0, #rig.requests .. " requests")
  local asked, times = pump()
  check("a disarm reads roll, pitch and yaw, then clears the FC", asked == "roll,pitch,yaw,clear", asked)
  local spaced = times[1] ~= nil and times[1] - disarmedAt >= 5
  for i = 2, #times do spaced = spaced and times[i] - times[i - 1] >= 2 end
  check("the first read waits 5 s, and each request 2 s after the last", spaced, table.concat(times, " "))
  local r = lines()
  check("(difference, the file) a version line and one line per axis are written", #r == 4 and r[1] == "v(1)"
    and string.find(r[2], ',147,"roll",1,1,', 1, true) ~= nil and string.find(r[2], ',70,100,0,10,4,18,24,', 1, true) ~= nil
    and string.find(r[3], ',"pitch",', 1, true) ~= nil and string.find(r[4], ',"yaw",', 1, true) ~= nil,
    table.concat(r, "\n"))
  local _, commas2 = string.gsub(r[2] or "", ",", "")
  local _, commas4 = string.gsub(r[4] or "", ",", "")
  check("(difference, the file) every line carries the same values", commas2 == commas4 and commas2 > 0,
    commas2 .. " vs " .. commas4)
  local tc = rig.capture()
  check("the page is told", tc ~= nil and tc.saved == 1 and tc.savedMcu == MCU)

  asked = pump()
  check("a disarm is captured once", asked == "", asked)
  check("the page is told reading from the disarm until the clear, then idle",
    table.concat(rig.states, ",") == "idle,reading,idle", table.concat(rig.states, ","))

  local asked0 = flyThrough(0)
  check("a flight with no acro flight saves nothing and clears nothing", asked0 == "roll,pitch,yaw"
    and #lines() == 4, asked0 .. " / " .. #lines() .. " lines")

  for n = 1, 6 do flyThrough(100 + n) end
  r = lines()
  check("only the last 5 flights are kept", #r == 16 and string.find(r[2], ',102,"roll",', 1, true) ~= nil
    and string.find(r[14], ',106,"roll",', 1, true) ~= nil, #r .. " lines; first " .. tostring(r[2]))
end

do
  -- The link goes while the craft is armed and comes back with it disarmed: the runtime kept the
  -- flight across the loss and ends it in the gap (endKeptFlight) once the board says disarmed.
  fresh()
  update(true)
  rig.setLink(false)
  rig.passes(30)
  rig.session.mcu_id = nil
  rig.mspState.lastArmed = false
  rig.armedReading = { false, true }
  rig.setLink(true)
  rig.passes(100)
  check("waits for the aircraft identity", #rig.requests == 0, #rig.requests .. " requests")
  rig.session.mcu_id = MCU
  pump()
  check("a disarm during a link loss is captured on reconnect", #lines() == 4, #lines() .. " lines")
end

do
  fresh()
  disarmAndWait()
  rig.errorReply(rig.requests[1])
  drop()
  local asked = pump()
  check("firmware without the tune advisor is asked once", asked == "" and files[HISTORY] == nil, asked)
end

-- A reply this suite refuses is deterministic: the same bytes come back on every request, so
-- waiting out the link error's retry buys nothing.
do
  fresh()
  disarmAndWait()
  local t0 = rig.clock
  rig.refusedReply(rig.requests[1])
  drop()
  rig.pass()
  check("a refused reply is not asked again straight away", #rig.requests == 0, #rig.requests .. " requests")
  rig.clock = t0 + 11
  rig.pass()
  check("a refused reply is never retried", #rig.requests == 0, #rig.requests .. " requests")
  rig.clock = t0 + 17
  rig.pass()
  check("a refused reply stays refused, flight by flight", #rig.requests == 0, #rig.requests .. " requests")
  check("a refused flight is not saved", files[HISTORY] == nil, tostring(files[HISTORY]))
  disarmAndWait()
  check("the next disarm asks once", #rig.requests == 1, #rig.requests .. " requests")
end

do
  fresh()
  disarmAndWait()
  local msg = rig.requests[1]
  msg.errorHandler(msg, "max_retries")
  drop()
  rig.pass()
  check("a link error waits before asking again", #rig.requests == 0, #rig.requests .. " requests")
  local asked = pump({ clear = { n = 1, reason = "timeout" } })
  check("a clear that did not get through is sent again", asked == "roll,pitch,yaw,clear,clear"
    and #lines() == 4, asked .. " / " .. #lines() .. " lines")
end

do
  fresh()
  update(true)
  update(false)
  local asked = pump({ pitch = { n = 1, reason = "max_retries" } })
  check("a lost axis is asked again on its own", asked == "roll,pitch,pitch,yaw,clear" and #lines() == 4,
    asked .. " / " .. #lines() .. " lines")
end

-- What the pacing fixes: a reply lost on every try kept the MSP queue and the telemetry link busy
-- for as long as the model sat disarmed.
do
  fresh()
  local asked = flyThrough(147)
  check("(setup) one flight saved", asked == "roll,pitch,yaw,clear", asked)
  rig.clock = rig.clock + 60
  update(true)
  update(false)
  asked = pump({ roll = { n = 99, reason = "max_retries" } }, nil, 120)
  check("three link errors, then nothing until the next disarm", asked == "roll,roll,roll", asked)
  check("the page is told the flight was not read", rig.states[#rig.states] == "failed",
    table.concat(rig.states, ","))
  update(true)
  check("arming ends the failed note", rig.states[#rig.states] == "idle", table.concat(rig.states, ","))
  asked = flyThrough(200)
  check("the next disarm reads again", asked == "roll,pitch,yaw,clear" and #lines() == 7,
    asked .. " / " .. #lines() .. " lines")
end

do
  fresh()
  update(true)
  update(false)
  local asked = pump({ roll = { n = 5, reason = "cleared" } }, nil, 60)
  check("a cleared queue is not counted as a link error",
    asked == "roll,roll,roll,roll,roll,roll,pitch,yaw,clear", asked)
end

-- Ethos: the session publishes only when its snapshot changes, so the waits must run out on the
-- task's own clock. Here the event runtime's pass is that clock: nothing but passes go by.
do
  fresh()
  update(true)
  update(false)
  local asked = {}
  for _ = 1, 60 do
    rig.clock = rig.clock + 0.5
    rig.pass()
    while rig.requests[1] do
      local msg = rig.take()
      local name = rig.name(msg)
      if name ~= "rc_tuning" and name ~= "pid_profile" and name ~= "status" then asked[#asked + 1] = name end
      rig.answer(msg)
    end
  end
  asked = table.concat(asked, ",")
  check("a quiet session still captures, on the task's clock", asked == "roll,pitch,yaw,clear"
    and #lines() == 4, asked .. " / " .. #lines() .. " lines")
end

-- A flight controller that restarted between two reads answers with another flight
do
  fresh()
  rig.reply.seconds = 147
  disarmAndWait()
  rig.answer(rig.take())
  rig.reply.seconds = 0
  local asked = pump()
  check("axes from two flights are not saved as one", asked == "pitch,yaw,roll,pitch,yaw"
    and files[HISTORY] == nil, asked .. " / " .. tostring(files[HISTORY]))
  rig.reply.seconds = 147
end

do
  fresh()
  disarmAndWait()
  rig.answer(rig.take())
  local asked = pump({ pitch = { n = 1, reason = "cleared" } })
  check("a cleared queue drops the axes already read", asked == "pitch,roll,pitch,yaw,clear"
    and #lines() == 4, asked .. " / " .. #lines() .. " lines")
end

do
  fresh()
  local history = assert(loadfile("src/rfsuite/lib/tune_history.lua"))()
  -- The capture saves through history.step (a save in steps, one per pass); its write step is
  -- the save the Ethos case fails four times. (Difference: here the third failed write in a row
  -- ends the capture until the next disarm, see below, so it fails twice.)
  local realStep, saves = history.step, 0
  history.step = function(job)
    if job.kind == "save" and job.phase == "write" then
      saves = saves + 1
      if saves <= 2 then job.phase = "done"; return false, "write" end
    end
    return realStep(job)
  end
  rig.shared["lib/tune_history.lua"] = history
  update(true)
  update(false)
  local asked = pump(nil, nil, 60)
  check("a failed write is tried again without reading again",
    asked == "roll,pitch,yaw,clear" and saves == 3 and #lines() == 4,
    asked .. " / " .. saves .. " saves / " .. #lines() .. " lines")
end

do
  fresh()
  disarmAndWait()
  local msg = rig.requests[1]
  check("a tune read gives up after three sends", msg ~= nil and msg.maxRetries == 2, tostring(msg and msg.maxRetries))
end

do
  fresh()
  disarmAndWait()
  rig.errorReply(rig.requests[1])
  drop()
  rig.pass()
  check("firmware without the tune advisor leaves the page idle", rig.states[#rig.states] == "idle",
    table.concat(rig.states, ","))
end

-- A flight is saved and its clear fails, so a clear stays outstanding. The next flight is refused.
-- The clear must not go out now: it would erase the refused flight on the flight controller.
do
  fresh()
  update(true)
  update(false)
  local asked = pump({ clear = { n = 1, reason = "timeout" } }, 4)
  check("flight one is saved before its clear fails", asked == "roll,pitch,yaw,clear" and #lines() == 4,
    asked .. " / " .. #lines() .. " lines")
  disarmAndWait()
  rig.refusedReply(rig.requests[1])
  drop()
  asked = pump()
  check("a clear is not sent over a refused flight on the FC", asked == "", asked)
  check("the refused flight is not saved", #lines() == 4, #lines() .. " lines")
end

-- ---------------------------------------------------------------------------
print("Differences from the Ethos suite: the capture (#979)")
-- ---------------------------------------------------------------------------
do
  fresh()
  local Manifest = assert(loadfile("src/rfsuite/tasks/events/ondisarm/manifest.lua"))()
  local last = Manifest[#Manifest]
  check("the capture is the last disarm task, and the widget's alone", type(last) == "table"
    and last.name == "tune_history" and last.context == "widget", tostring(last and last.name))

  -- The disarm edge and the passes after it carry the disarm chain's own work: nothing of the
  -- capture but the runner's one call that marks it.
  for i = #rig.loads, 1, -1 do rig.loads[i] = nil end
  update(true)
  update(false)
  rig.passes(40)
  local captureModules = {
    ["tasks/msp/api/tune_advisor.lua"] = true, ["lib/tune_history.lua"] = true, ["lib/atomic_file.lua"] = true,
    ["lib/change_journal.lua"] = true, ["lib/profile.lua"] = true, ["tasks/msp/api/rc_tuning.lua"] = true,
    ["tasks/msp/api/pid_profile.lua"] = true, ["tasks/events/tune_capture.lua"] = true,
  }
  local early = {}
  for _, path in ipairs(rig.loads) do
    if captureModules[path] then early[#early + 1] = path end
  end
  local marked = 0
  for _, path in ipairs(rig.loads) do
    if path == "tasks/events/ondisarm/tasks/tune_history.lua" then marked = marked + 1 end
  end
  check("for four seconds after the disarm nothing is sent and nothing of the capture loads but its mark",
    #rig.requests == 0 and #early == 0 and marked == 1, #rig.requests .. " requests; " .. table.concat(early, " ")
    .. "; capture loaded " .. marked .. "x")
  local asked = pump()
  check("then it runs as above", asked == "roll,pitch,yaw,clear", asked)
  check("nothing is left owed once the capture is through", rig.capture().pending == false
    and rig.capture().contextPending == false)
end

do
  fresh()
  rig.session.activeProfile, rig.session.activeRateProfile = 2, 4
  local asked = flyThrough(147)
  local a = tuneHistory.read(MCU)[1].axes[1]
  check("after the clear, RC_TUNING and PID_PROFILE are read", asked == "roll,pitch,yaw,clear"
    and table.concat(rig.contextAsked, ",") == "rc_tuning,pid_profile", table.concat(rig.contextAsked, ","))
  local rc = assert(loadfile("src/rfsuite/tasks/msp/api/rc_tuning.lua"))().parse(
    assert(loadfile("src/rfsuite/tasks/msp/api/rc_tuning.lua"))().simulatorResponse)
  local pid = assert(loadfile("src/rfsuite/tasks/msp/api/pid_profile.lua"))().parse(
    assert(loadfile("src/rfsuite/tasks/msp/api/pid_profile.lua"))().simulatorResponse)
  check("the flight carries the profiles, the cyclic polarity, the cyclic ring and the relax type",
    a.pidProfile == 3 and a.rateProfile == 5 and a.cyclicPolarity == rc.cyclic_polarity
    and a.cyclicRing == rc.cyclic_ring and a.relaxType == pid.iterm_relax_type,
    tostring(a.pidProfile) .. " " .. tostring(a.rateProfile) .. " " .. tostring(a.cyclicPolarity) .. " "
    .. tostring(a.cyclicRing) .. " " .. tostring(a.relaxType))
  check("the flight carries the radio clock the change journal writes", tuneHistory.read(MCU)[1].time == rig.rtc,
    tostring(tuneHistory.read(MCU)[1].time))

  fresh()
  rig.reply.seconds, rig.reply.F = 150, 100
  rig.clock = rig.clock + 60
  update(true)
  update(false)
  pump({ rc_tuning = { n = 1, reason = "max_retries" } })
  a = tuneHistory.read(MCU)[1].axes[2]
  check("a settings read that fails leaves its values unknown, the other still counts",
    a.cyclicPolarity == nil and a.cyclicRing == nil and a.relaxType == pid.iterm_relax_type and a.pidProfile == 1,
    tostring(a.cyclicRing) .. " " .. tostring(a.relaxType))
end

do
  -- The file could not be opened at the disarm: nothing is written over it, the flight
  -- controller keeps the flight, and the next try saves it beside the others.
  fresh()
  flyThrough(140)
  flyThrough(141)
  openFails[HISTORY] = 1
  local asked = flyThrough(142)
  check("a history that cannot be read at the save is tried again, and the FC cleared only then",
    asked == "roll,pitch,yaw,clear" and #tuneHistory.read(MCU) == 3, asked .. " / " .. #tuneHistory.read(MCU) .. " flights")

  fresh()
  flyThrough(140)
  files[HISTORY] = files[HISTORY] .. string.rep("-- padding ", 1700)
  local big = files[HISTORY]
  asked = flyThrough(150)
  check("a history over the read cap is never written over, and the FC never cleared", asked == "roll,pitch,yaw"
    and files[HISTORY] == big, asked)
end

-- ---------------------------------------------------------------------------
print("The capture: a card that cannot be written (#1168)")
-- ---------------------------------------------------------------------------
do
  fresh()
  local history = assert(loadfile("src/rfsuite/lib/tune_history.lua"))()
  local realStep, writes = history.step, 0
  history.step = function(job)
    if job.kind == "save" and job.phase == "write" then
      writes = writes + 1
      job.phase = "done"
      return false, "write"
    end
    return realStep(job)
  end
  rig.shared["lib/tune_history.lua"] = history
  update(true)
  update(false)
  local asked = pump(nil, nil, 120)
  check("a write that always fails is tried three times, then not again until the next disarm",
    asked == "roll,pitch,yaw" and writes == 3, asked .. " / " .. writes .. " writes")
  check("the page is told the flight was not saved, not that it is still being read",
    rig.states[#rig.states] == "unsaved", table.concat(rig.states, ","))
  check("the flight controller is not cleared", not string.find(asked, "clear", 1, true), asked)
  local loadsBefore = #rig.loads
  rig.passes(100, 1)
  check("nothing more is loaded or asked while it waits", #rig.loads == loadsBefore and #rig.requests == 0,
    (#rig.loads - loadsBefore) .. " loads, " .. #rig.requests .. " requests")
  update(true)
  check("arming ends the note", rig.states[#rig.states] == "idle", table.concat(rig.states, ","))
  history.step = realStep
  asked = flyThrough(160)
  check("the next disarm reads again and saves once the card takes it",
    asked == "roll,pitch,yaw,clear" and #lines() == 4, asked .. " / " .. #lines() .. " lines")
end

do
  -- A history over the read cap: the same three tries, then the note
  fresh()
  flyThrough(140)
  files[HISTORY] = files[HISTORY] .. string.rep("-- padding ", 1700)
  rig.reply.seconds = 150
  rig.clock = rig.clock + 60
  update(true)
  update(false)
  local logsBefore = #rig.logs
  local asked = pump(nil, nil, 120)
  local tries = 0
  for i = logsBefore + 1, #rig.logs do
    if string.find(rig.logs[i], "cannot write the flight history", 1, true) then tries = tries + 1 end
  end
  check("a history over the read cap is tried three times, then the page says not saved",
    asked == "roll,pitch,yaw" and tries == 3 and rig.states[#rig.states] == "unsaved",
    asked .. " / " .. tries .. " tries / " .. table.concat(rig.states, ","))
end

-- ---------------------------------------------------------------------------
print("The capture: a reply is stored by the axis it names (#1169)")
-- ---------------------------------------------------------------------------
-- Answers every request as it goes out, but a pitch request with the reply to a roll request
-- `wrong` times. Returns what was asked.
local function pumpWrongPitch(wrong, seconds)
  local asked = {}
  local stopAt = rig.clock + (seconds or 30)
  while rig.clock < stopAt do
    rig.clock = rig.clock + 0.5
    rig.pass()
    while rig.requests[1] do
      local msg = rig.take()
      local name = rig.name(msg)
      if name ~= "rc_tuning" and name ~= "pid_profile" and name ~= "status" then asked[#asked + 1] = name end
      if name == "pitch" and wrong > 0 then
        wrong = wrong - 1
        msg.__errorReply = false
        msg.processReply(msg, rig.replyFor({ command = Rig.READ, payload = { 0 } }))
      else
        rig.answer(msg)
      end
    end
  end
  return table.concat(asked, ",")
end

do
  fresh()
  update(true)
  update(false)
  local asked = pumpWrongPitch(1)
  check("a reply naming another axis is not stored, and that axis is asked again",
    asked == "roll,pitch,pitch,yaw,clear", asked)
  local flight = tuneHistory.read(MCU)[1]
  local roll, pitch = Api.parse(Api.simulatorResponseFor(1)).a, Api.parse(Api.simulatorResponseFor(2)).a
  check("(setup) roll and pitch replies differ", roll.P ~= pitch.P and roll.ffCount ~= pitch.ffCount)
  check("the saved pitch line holds pitch's numbers, not roll's", flight ~= nil
    and flight.axes[2].P == pitch.P and flight.axes[2].ffCount == pitch.ffCount
    and flight.axes[1].ffCount == roll.ffCount,
    flight and (tostring(flight.axes[2].P) .. " " .. tostring(flight.axes[2].ffCount)) or "no flight")
end

do
  fresh()
  update(true)
  update(false)
  local asked = pumpWrongPitch(99, 120)
  check("replies that keep naming another axis count as link errors: three, then the next disarm",
    asked == "roll,pitch,pitch,pitch" and files[HISTORY] == nil and rig.states[#rig.states] == "failed",
    asked .. " / " .. table.concat(rig.states, ","))
end

-- ---------------------------------------------------------------------------
print("The capture: a clear owed from before an arm, a link loss or a pause is never sent (#1173)")
-- ---------------------------------------------------------------------------
-- The flight controller's numbers, modelled: a flight adds its usable seconds and an answered
-- clear empties them.
local board = { seconds = 0 }

-- pump(), answering each read with the board's numbers and emptying them on an answered clear.
-- `failClear`: that many clears end in a link error. `stopAtClear`: return with the first clear
-- still on the queue, unanswered. A message with `sendIf` is asked first, as tasks/msp/queue.lua
-- asks it before every send, and withheld when the answer is not true.
local function boardPump(failClear, stopAtClear)
  local asked = {}
  local stopAt = rig.clock + 40
  while rig.clock < stopAt do
    rig.clock = rig.clock + 0.5
    rig.pass()
    while rig.requests[1] do
      local msg = rig.requests[1]
      local name = rig.name(msg)
      if name == "clear" and stopAtClear then return table.concat(asked, ","), msg end
      rig.take()
      if msg.sendIf and msg.sendIf(msg) ~= true then
        msg.errorHandler(msg, "withheld")
      else
        if name ~= "rc_tuning" and name ~= "pid_profile" and name ~= "status" then asked[#asked + 1] = name end
        if name == "clear" and (failClear or 0) > 0 then
          failClear = failClear - 1
          msg.errorHandler(msg, "timeout")
        else
          rig.reply.seconds = board.seconds
          rig.answer(msg)
          if name == "clear" then board.seconds = 0 end
        end
      end
    end
  end
  return table.concat(asked, ",")
end

-- Drops what the queue holds, as arming or a link loss does
local function dropQueue()
  for i = #rig.requests, 1, -1 do
    local msg = table.remove(rig.requests, i)
    msg.errorHandler(msg, "cleared")
  end
end

-- `ground` seconds on the ground (default 60), a pass a second, then arms, flies `seconds`
-- (armed 20 s longer) and disarms
local function boardFly(seconds, ground)
  rig.passes(ground or 60, 1)
  dropQueue()
  update(true)
  board.seconds = board.seconds + seconds
  rig.passes(seconds + 20, 1)
  update(false)
end

local function savedSeconds()
  local out = {}
  for _, flight in ipairs(tuneHistory.read(MCU)) do out[#out + 1] = tostring(flight.seconds) end
  return table.concat(out, ",")
end

-- Like boardPump, but stops on the pass that saves the flight: the clear is owed then and waits its
-- GAP_SECONDS, not on the queue yet. Only tasks/events/runtime.lua's own drop rules (an arm, a link
-- loss, a time without passes) can give it up in that window; no queue drop is involved.
local function boardPumpUntilSaved()
  local asked = {}
  local stopAt = rig.clock + 40
  while rig.clock < stopAt and savedSeconds() == "" do
    rig.clock = rig.clock + 0.5
    rig.pass()
    while rig.requests[1] do
      local msg = rig.take()
      local name = rig.name(msg)
      if name ~= "rc_tuning" and name ~= "pid_profile" and name ~= "status" then asked[#asked + 1] = name end
      rig.reply.seconds = board.seconds
      rig.answer(msg)
    end
  end
  local cap = rig.capture()
  return table.concat(asked, ","), cap and cap.clearPending == true and rig.requests[1] == nil
end

do
  -- The pilot arms again in the moment between the save and the clear
  fresh()
  board.seconds = 0
  boardFly(140)
  local asked = boardPump(nil, true)
  check("(setup) flight one saved, its clear about to go out", asked == "roll,pitch,yaw" and savedSeconds() == "140",
    asked .. " / " .. savedSeconds())
  boardFly(60, 1)
  asked = boardPump()
  check("a clear owed from before the arm is not sent ahead of the next reading", string.sub(asked, 1, 4) == "roll",
    asked)
  -- The reading still holds flight one: both are kept, and the page leaves flight one out (#1167)
  check("the second flight is read and saved, not erased", savedSeconds() == "140,200" and board.seconds == 0,
    savedSeconds() .. " / board " .. board.seconds)
end

do
  -- The link goes while the clear is still owed, and the craft flies while it is down: the radio
  -- never sees that flight. The owed clear must not erase it when the link is back.
  fresh()
  board.seconds = 0
  boardFly(140)
  local asked, msg = boardPump(nil, true)
  check("(setup) flight one saved, its clear about to go out", asked == "roll,pitch,yaw" and msg ~= nil, asked)
  rig.setLink(false)
  dropQueue()
  rig.passes(80, 1)
  board.seconds = board.seconds + 60
  rig.setLink(true)
  asked = boardPump()
  check("a clear owed across a link loss is not sent when the link is back", asked == "" and board.seconds == 200,
    asked .. " / board " .. board.seconds)
  check("the page is not left reading", rig.capture().state == "idle", tostring(rig.capture().state))
  boardFly(30, 1)
  boardPump()
  check("the next disarm reads what the board held", savedSeconds() == "140,230" and board.seconds == 0,
    savedSeconds() .. " / board " .. board.seconds)
end

-- The same three in the window between the save and the clear going on the queue: here only the
-- runtime's drop rules stand between the owed clear and the next flight
do
  fresh()
  board.seconds = 0
  boardFly(140)
  local asked, owed = boardPumpUntilSaved()
  check("(setup) flight one saved, its clear owed and not queued yet", asked == "roll,pitch,yaw" and owed == true
    and savedSeconds() == "140", asked .. " / owed " .. tostring(owed))
  boardFly(60, 1)
  asked = boardPump()
  check("armed before the owed clear was queued: it is not sent, the next flight is read and saved",
    string.sub(asked, 1, 4) == "roll" and savedSeconds() == "140,200", asked .. " / " .. savedSeconds())

  fresh()
  board.seconds = 0
  boardFly(140)
  asked, owed = boardPumpUntilSaved()
  check("(setup) flight one saved, its clear owed and not queued yet", owed == true, asked)
  rig.setLink(false)
  rig.passes(80, 1)
  board.seconds = board.seconds + 60
  rig.setLink(true)
  asked = boardPump()
  check("a link loss before the owed clear was queued: it is not sent when the link is back",
    asked == "" and board.seconds == 200, asked .. " / board " .. board.seconds)

  fresh()
  board.seconds = 0
  boardFly(140)
  asked, owed = boardPumpUntilSaved()
  check("(setup) flight one saved, its clear owed and not queued yet", owed == true, asked)
  rig.clock = rig.clock + 200
  board.seconds = board.seconds + 120
  asked = boardPump()
  check("a time without passes before the owed clear was queued: it is not sent afterwards",
    asked == "" and board.seconds == 260, asked .. " / board " .. board.seconds)
end

do
  -- The widget runs no pass for a while (the configuration tool open stops the widgets) with a
  -- clear owed but not yet sent: the craft may have flown unseen, so it is not sent afterwards
  fresh()
  board.seconds = 0
  boardFly(140)
  boardPump(nil, true)
  dropQueue()
  rig.clock = rig.clock + 200
  board.seconds = board.seconds + 120
  local asked = boardPump()
  check("a clear owed across a time without passes is not sent", asked == "" and board.seconds == 260
    and rig.capture().state == "idle", asked .. " / board " .. board.seconds .. " / " .. tostring(rig.capture().state))
end

do
  -- The same with the clear already on the queue: the queue asks the message's sendIf before every
  -- send, and on the first pass after the pause it ticks before the events runtime has seen the gap
  fresh()
  board.seconds = 0
  boardFly(140)
  local _, msg = boardPump(nil, true)
  check("(setup) a clear on the queue", msg ~= nil and rig.name(msg) == "clear", msg and rig.name(msg))
  rig.clock = rig.clock + 200
  board.seconds = board.seconds + 120
  local allowed = msg.sendIf == nil or msg.sendIf(msg) == true
  check("a clear queued before a time without passes is withheld at its next send", not allowed, tostring(allowed))
  if not allowed then
    rig.take()
    msg.errorHandler(msg, "withheld")
  end
  local asked = boardPump()
  check("and not sent again; the board keeps the flight and the page is idle", asked == "" and board.seconds == 260
    and rig.capture().state == "idle", asked .. " / board " .. board.seconds .. " / " .. tostring(rig.capture().state))
end

do
  -- The radio's clock goes back with a clear on the queue: the queue asks its sendIf before the
  -- events runtime has seen the step
  fresh()
  board.seconds = 0
  boardFly(140)
  local _, msg = boardPump(nil, true)
  check("(setup) a clear on the queue", msg ~= nil and rig.name(msg) == "clear", msg and rig.name(msg))
  rig.clock = rig.clock - 10
  local allowed = msg.sendIf == nil or msg.sendIf(msg) == true
  check("a clear queued before the clock went back is withheld at its next send", not allowed, tostring(allowed))
end

do
  -- A link loss too short for the runtime to call the link lost still empties the queue: the
  -- clear it drops is not sent again when the link is back
  fresh()
  board.seconds = 0
  boardFly(140)
  local _, msg = boardPump(nil, true)
  check("(setup) a clear on the queue", msg ~= nil and rig.name(msg) == "clear", msg and rig.name(msg))
  rig.setLink(false)
  dropQueue()
  rig.passes(2, 0.5)
  board.seconds = board.seconds + 1
  rig.setLink(true)
  local asked = boardPump()
  check("a clear the queue dropped in a short link loss is not sent again", asked == "" and board.seconds == 141,
    asked .. " / board " .. board.seconds)
end

do
  -- A flight with nothing new, its clear dropped by a link loss: the page must be told idle
  fresh()
  board.seconds = 0
  boardFly(140)
  boardPump(3)
  boardFly(0)
  local asked = boardPump(nil, true)
  check("(setup) the same numbers read again, the clear about to go out", asked == "roll,pitch,yaw"
    and savedSeconds() == "140", asked .. " / " .. savedSeconds())
  rig.setLink(false)
  dropQueue()
  rig.passes(30, 1)
  rig.setLink(true)
  boardPump()
  check("a clear dropped with nothing else owed leaves the page idle, not reading", rig.capture().state == "idle",
    tostring(rig.capture().state))
end

do
  -- The pilot unplugs the pack before the start wait is over; the same flight controller comes
  -- back with its numbers: the flight is still owed and read then.
  fresh()
  update(true)
  update(false)
  rig.passes(10)
  rig.setLink(false)
  rig.passes(40)
  check("(setup) nothing was asked while the link was down", #rig.requests == 0, #rig.requests .. " requests")
  rig.setLink(true)
  local asked = pump()
  check("a flight still owed when the link went is read once it is back", asked == "roll,pitch,yaw,clear"
    and #lines() == 4, asked .. " / " .. #lines() .. " lines")
end

-- ---------------------------------------------------------------------------
print("The capture: the profiles a flight is saved under (#1166)")
-- ---------------------------------------------------------------------------
do
  local function savedProfiles()
    local flights = tuneHistory.read(MCU)
    local a = flights[#flights] and flights[#flights].axes[1]
    return a and (tostring(a.pidProfile) .. "/" .. tostring(a.rateProfile)) or "-"
  end

  -- No PID#/RTE# sensors; the flight controller flies PID 2 / rates 3, the session still says 1 / 1
  fresh()
  rig.status.pid, rig.status.rate = 1, 2
  local asked = flyThrough(120)
  check("without the profile sensors the profiles are read once before the save and the flight is saved under them",
    asked == "roll,pitch,yaw,clear" and #rig.statusAsked == 1 and savedProfiles() == "2/3",
    asked .. " / " .. #rig.statusAsked .. " status / saved " .. savedProfiles())
  check("the session follows, so the page sees the profiles flown", rig.session.activeProfile == 1
    and rig.session.activeRateProfile == 2, tostring(rig.session.activeProfile) .. "/" .. tostring(rig.session.activeRateProfile))

  -- A switch on the transmitter between two flights, no sensors: not combined
  fresh()
  flyThrough(120)
  rig.status.pid = 1
  flyThrough(90)
  local _, used = tuneHistory.aggregate(tuneHistory.read(MCU), 1)
  check("a profile switch between two flights without the sensors: the flights are not combined", used == 1
    and savedProfiles() == "2/1", used .. " flights, newest " .. savedProfiles())
  rig.status.pid = nil

  -- With the sensors: no read, their values
  fresh()
  rig.sensors.pid_profile, rig.sensors.rate_profile = 4, 5
  asked = flyThrough(120)
  check("with the PID# and RTE# sensors nothing more is read, the flight is saved under their profiles",
    asked == "roll,pitch,yaw,clear" and #rig.statusAsked == 0 and savedProfiles() == "4/5",
    asked .. " / " .. #rig.statusAsked .. " status / saved " .. savedProfiles())
  rig.sensors.pid_profile, rig.sensors.rate_profile = nil, nil

  -- The read fails on the link: asked again as a failed axis read is, never saved under the
  -- session's profiles, which a switch on the transmitter does not change
  fresh()
  rig.status.pid, rig.status.rate = 1, 2
  rig.reply.seconds = 120
  rig.clock = rig.clock + 60
  update(true)
  update(false)
  asked = pump({ status = { n = 1, reason = "timeout" } })
  check("a profiles read that fails once is asked again, and the flight saved under the profiles read",
    asked == "roll,pitch,yaw,clear" and #rig.statusAsked == 2 and savedProfiles() == "2/3",
    asked .. " / " .. #rig.statusAsked .. " status / saved " .. savedProfiles())

  -- It fails three times: given up until the next disarm, nothing saved and nothing cleared, so
  -- that disarm reads the flight again
  fresh()
  rig.status.pid, rig.status.rate = 1, 2
  rig.reply.seconds = 120
  rig.clock = rig.clock + 60
  update(true)
  update(false)
  asked = pump({ status = { n = 3, reason = "timeout" } }, nil, 60)
  check("a profiles read that fails three times: nothing saved under the session's profiles, nothing cleared",
    asked == "roll,pitch,yaw" and #rig.statusAsked == 3 and #tuneHistory.read(MCU) == 0
      and rig.capture().state == "failed",
    asked .. " / " .. #rig.statusAsked .. " status / " .. #tuneHistory.read(MCU) .. " saved / "
      .. tostring(rig.capture().state))

  -- The queue drops the read (a link loss, however short): the flight controller may have flown or
  -- restarted meanwhile, so the axes are read again with it, as after a dropped axis read
  fresh()
  rig.status.pid, rig.status.rate = 1, 2
  rig.reply.seconds = 120
  rig.clock = rig.clock + 60
  update(true)
  update(false)
  asked = pump({ status = { n = 1, reason = "cleared" } }, nil, 60)
  check("a profiles read the queue dropped: the axes and the profiles are read again, the flight saved under them",
    asked == "roll,pitch,yaw,roll,pitch,yaw,clear" and #rig.statusAsked == 2 and savedProfiles() == "2/3",
    asked .. " / " .. #rig.statusAsked .. " status / saved " .. savedProfiles())

  -- The same through a real link loss: the read goes out, the link drops and the queue with it,
  -- nothing is sent while it is down, and once it is back the axes and the profiles are read again.
  -- A flight flown unseen while the link was down is what the board holds then: that is saved, and
  -- the clear after it erases nothing unsaved
  fresh()
  rig.status.pid, rig.status.rate = 1, 2
  rig.reply.seconds = 120
  rig.clock = rig.clock + 60
  update(true)
  update(false)
  asked = pump(nil, 3)
  local statusMsg
  for _ = 1, 40 do
    rig.clock = rig.clock + 0.5
    rig.pass()
    if rig.requests[1] and rig.name(rig.requests[1]) == "status" then statusMsg = rig.take(); break end
  end
  check("(setup) the profiles read goes out after the three axes", asked == "roll,pitch,yaw" and statusMsg ~= nil, asked)
  rig.setLink(false)
  if statusMsg then statusMsg.errorHandler(statusMsg, "cleared") end
  rig.passes(40, 0.5)
  local sentWhileDown = #rig.requests
  rig.reply.seconds = 200
  rig.setLink(true)
  local after = pump()
  local flights = tuneHistory.read(MCU)
  local savedSecs = {}
  for i = 1, #flights do savedSecs[#savedSecs + 1] = tostring(flights[i].seconds) end
  check("a profiles read dropped by a link loss: once the link is back the axes are read again and what the board holds is saved",
    sentWhileDown == 0 and after == "roll,pitch,yaw,clear" and #rig.statusAsked == 1 and savedProfiles() == "2/3"
      and table.concat(savedSecs, ",") == "200",
    sentWhileDown .. " sent while down / " .. after .. " / " .. #rig.statusAsked .. " status after / saved "
      .. savedProfiles() .. " / seconds " .. table.concat(savedSecs, ","))

  -- Stated, the cost of reading again: the flight controller restarted while the link was down (a
  -- new pack), so its statistics are gone. The axes read again say no flight: nothing is saved and
  -- nothing is cleared, and the flight read before the gap is not kept
  fresh()
  rig.status.pid, rig.status.rate = 1, 2
  rig.reply.seconds = 120
  rig.clock = rig.clock + 60
  update(true)
  update(false)
  asked = pump(nil, 3)
  statusMsg = nil
  for _ = 1, 40 do
    rig.clock = rig.clock + 0.5
    rig.pass()
    if rig.requests[1] and rig.name(rig.requests[1]) == "status" then statusMsg = rig.take(); break end
  end
  rig.setLink(false)
  if statusMsg then statusMsg.errorHandler(statusMsg, "cleared") end
  rig.passes(40, 0.5)
  rig.reply.seconds = 0
  rig.setLink(true)
  after = pump()
  check("stated: a restart while the link was down leaves no flight to read, nothing saved and nothing cleared",
    statusMsg ~= nil and after == "roll,pitch,yaw" and #tuneHistory.read(MCU) == 0,
    after .. " / " .. #tuneHistory.read(MCU) .. " flights saved")

  -- The status module does not load (low memory): as a failed read, never the session's profiles.
  -- Nothing is saved or cleared; with the module back, the next disarm saves the flight
  fresh()
  rig.status.pid, rig.status.rate = 1, 2
  rig.shared["tasks/msp/api/status.lua"] = false
  rig.reply.seconds = 120
  rig.clock = rig.clock + 60
  update(true)
  update(false)
  asked = pump(nil, nil, 60)
  check("the status module not loading: nothing saved under the session's profiles, nothing cleared",
    asked == "roll,pitch,yaw" and #tuneHistory.read(MCU) == 0 and rig.capture().state == "failed",
    asked .. " / " .. #tuneHistory.read(MCU) .. " saved / " .. tostring(rig.capture().state))
  rig.shared["tasks/msp/api/status.lua"] = nil
  asked = flyThrough(30)
  check("(control) with the module back, the next disarm saves the flight under the profiles read",
    asked == "roll,pitch,yaw,clear" and savedProfiles() == "2/3", asked .. " / saved " .. savedProfiles())

  -- A status reply cut short before the profile bytes (their parser reads a missing byte as 0): the
  -- same reply would come back, so the flight is saved without profiles, never counted for any
  fresh()
  rig.session.activeProfile, rig.session.activeRateProfile = 2, 1
  rig.status.bytes = 20
  asked = flyThrough(120)
  check("a status reply too short for the profiles: the flight is saved without profiles, not under the session's",
    asked == "roll,pitch,yaw,clear" and #rig.statusAsked == 1 and savedProfiles() == "nil/nil",
    asked .. " / " .. #rig.statusAsked .. " status / saved " .. savedProfiles())
  rig.status.bytes = nil

  -- Dropped again and again: not a link error, so not given up on
  fresh()
  rig.status.pid, rig.status.rate = 1, 2
  rig.reply.seconds = 120
  rig.clock = rig.clock + 60
  update(true)
  update(false)
  asked = pump({ status = { n = 5, reason = "cleared" } }, nil, 120)
  local rolls = select(2, string.gsub(asked, "roll", ""))
  check("a profiles read dropped five times is still asked again, and the flight saved under the profiles read",
    rolls == 6 and string.sub(asked, -6) == ",clear" and #rig.statusAsked == 6 and savedProfiles() == "2/3",
    asked .. " / " .. #rig.statusAsked .. " status / saved " .. savedProfiles())
end

-- ---------------------------------------------------------------------------
print("The capture: a reading that holds the saved flight is not counted twice (#1167)")
-- ---------------------------------------------------------------------------
-- What the page combines on roll: flights used and their seconds
local function combined()
  local _, used, seconds = tuneHistory.aggregate(tuneHistory.read(MCU), 1)
  return used, seconds
end

local function marks()
  local n = 0
  for _, l in ipairs(lines()) do if string.sub(l, 1, 2) == "c(" then n = n + 1 end end
  return n
end

-- Optionally a normal flight of 100 s first (`three`); then flight one of 140 s, saved, with its
-- clear about to go out; then `between` and a second flight of 60 s: the board's second reading
-- holds 200 s when it was not cleared. The settings reads are answered whenever they are asked.
local function heldCase(between, three, second)
  fresh()
  board.seconds = 0
  rig.reply.releases, rig.reply.F = nil, 100
  if three then
    boardFly(100)
    boardPump()
  end
  boardFly(140)
  boardPump(between == "givenup" and 3 or nil, between ~= "givenup")
  if between == "nopass" then
    -- The widgets run no pass for a while (the configuration tool open)
    dropQueue()
    rig.clock = rig.clock + 200
    boardPump()
  elseif between == "flicker" then
    -- A link loss shorter than the radio's hold, which still empties the queue
    rig.setLink(false)
    dropQueue()
    rig.passes(2, 0.5)
    rig.setLink(true)
    boardPump()
  elseif between == "linkloss" then
    -- A link loss the radio calls one, and the link back: as far as the radio can tell a new pack
    rig.setLink(false)
    dropQueue()
    rig.passes(80, 1)
    rig.setLink(true)
    rig.passes(20, 1)
    boardPump()
  elseif type(between) == "function" then
    between()
  end
  boardFly(second or 60, 1)
  boardPump()
end

local function seen()
  local used, seconds = combined()
  return savedSeconds() .. " saved, " .. marks() .. " marks, " .. used .. " flights / " .. seconds .. " s"
end

local function logged(needle)
  for _, l in ipairs(rig.logs) do if string.find(l, needle, 1, true) then return true end end
  return false
end

do
  -- The pilot arms again in the moment between the save and the clear. Flight one's settings are
  -- never read then, so it is never combined: before, the reading that holds it ended the count
  -- there and the 100 s flight before it was left out too.
  heldCase(nil, true)
  local used, seconds = combined()
  check("a re-arm before the clear: the reading holding flight one is marked, nothing is removed",
    savedSeconds() == "100,140,200" and marks() == 1 and string.find(lines()[#lines()], ",140)", 1, true) ~= nil,
    seen())
  check("a re-arm before the clear: the page counts 100 s and the 200 s reading, 2 flights",
    used == 2 and seconds == 300, seen())
  check("the capture says so in the log", logged("containing the one before"))

  heldCase("givenup", true)
  used, seconds = combined()
  check("a clear given up after link errors: marked, and the page counts 2 flights / 300 s",
    savedSeconds() == "100,140,200" and marks() == 1 and used == 2 and seconds == 300, seen())

  -- The settings of flight one are read after the gap: before, both flights were combined, the
  -- 140 s twice
  heldCase("nopass")
  used, seconds = combined()
  check("no pass while the clear was owed: marked, the page counts 1 flight / 200 s, not 340",
    savedSeconds() == "140,200" and marks() == 1 and used == 1 and seconds == 200, seen())
  heldCase("flicker")
  used, seconds = combined()
  check("a link flicker under the hold: marked, the page counts 1 flight / 200 s, not 340",
    savedSeconds() == "140,200" and marks() == 1 and used == 1 and seconds == 200, seen())

  -- Stated, not fixed: a new link drops the evidence (a pack swap restarts the board, and a
  -- quick unplug after landing must not leave real flights out)
  heldCase("linkloss")
  used, seconds = combined()
  check("(setup) the link came up again in between", logged("session.isConnected=true"))
  check("a link lost and back: no mark, both flights counted as before (2 / 340)",
    savedSeconds() == "140,200" and marks() == 0 and used == 2 and seconds == 340, seen())

  -- Stated, not fixed: the pack swapped while the widgets did not run (the configuration tool
  -- open). The radio never saw the link go, so a restarted board's longer flight on the same tune
  -- is taken as holding the saved one: that flight is left out of the advice, nothing is removed
  heldCase(function()
    dropQueue()
    rig.clock = rig.clock + 200
    board.seconds = 0
    boardPump()
  end, false, 200)
  used, seconds = combined()
  check("a pack swapped unseen while the tool was open: marked, flight one left out, both kept",
    savedSeconds() == "140,200" and marks() == 1 and used == 1 and seconds == 200, seen())

  -- The history module cannot be loaded (low memory) at the save of a reading while a saved flight
  -- is held: the save fails as a write would, no error, and after three tries the flight is unsaved
  heldCase(function() rig.shared["lib/tune_history.lua"] = false end)
  rig.shared["lib/tune_history.lua"] = nil
  local cap = rig.capture()
  check("the history module not loading while a saved flight is held: no error, the flight reported unsaved",
    not logged("tune capture error") and cap.state == "unsaved" and savedSeconds() == "140",
    tostring(cap.state) .. " / " .. seen() .. (logged("tune capture error") and " / error logged" or ""))
end

do
  -- No mark without the evidence; each twin above marks
  fresh()
  board.seconds = 0
  boardFly(140)
  boardPump()
  boardFly(60, 1)
  boardPump()
  check("(control) a clear answered between the flights: no mark, both flights counted",
    savedSeconds() == "140,60" and marks() == 0 and select(1, combined()) == 2, seen())

  -- Another tune: the flight controller restarts its statistics, the reading holds only the new flight
  heldCase(function()
    board.seconds = 0
    rig.reply.F = 90
  end)
  check("another tune since the save: no mark", savedSeconds() == "140,60" and marks() == 0, seen())
  rig.reply.F = 100

  -- A count smaller than the saved flight's: the board started again unseen
  heldCase(function()
    board.seconds = 0
    rig.reply.releases = 1
  end)
  check("a count smaller than the saved flight's: no mark", savedSeconds() == "140,60" and marks() == 0, seen())
  rig.reply.releases = nil

  -- Not more seconds than the saved flight: the board started again unseen
  heldCase(function() board.seconds = 0 end)
  check("no more seconds than the saved flight: no mark", savedSeconds() == "140,60" and marks() == 0, seen())

  -- The page's erase between the flights: the file's newest flight is not the held one any more
  heldCase(function() tuneHistory.erase(MCU) end)
  check("an erase between the flights: no mark on the one flight left", savedSeconds() == "200" and marks() == 0,
    seen())
end

print("The history file: the mark (#1167)")
do
  -- Saved with and without the evidence; the mark is bound to the newest flight in the file
  reset()
  fly(60)
  local first = tuneHistory.read(MCU)[1]
  clock = clock + 60
  assert(tuneHistory.save(MCU, replies(90, { F = 100 }), CONTEXT, clock, { time = first.time, seconds = 60 }))
  local flights = tuneHistory.read(MCU)
  local _, used, seconds = tuneHistory.aggregate(flights, 1)
  check("a flight saved with the evidence is marked and holds the one before", #flights == 2
    and flights[2].contains ~= nil and flights[1].contains == nil and used == 1 and seconds == 90,
    #flights .. " flights, used " .. used)

  reset()
  fly(60)
  first = tuneHistory.read(MCU)[1]
  clock = clock + 60
  assert(tuneHistory.save(MCU, replies(90, { F = 100 }), CONTEXT, clock, { time = first.time, seconds = 59 }))
  check("evidence about another flight than the file's newest: no mark", marks() == 0)

  -- A clock with a fraction: the file keeps the second rounded, and the evidence still binds
  reset()
  clock = clock + 60.6
  assert(tuneHistory.save(MCU, replies(60, { F = 100 }), CONTEXT, clock))
  local fractional = clock
  clock = clock + 60
  assert(tuneHistory.save(MCU, replies(90, { F = 100 }), CONTEXT, clock, { time = fractional, seconds = 60 }))
  check("a radio time with a fraction: the evidence binds to the rounded second in the file", marks() == 1, marks())

  -- The context job and later saves keep it; the trim to five keeps it with its flight
  reset()
  fly(60)
  first = tuneHistory.read(MCU)[1]
  clock = clock + 60
  assert(tuneHistory.save(MCU, replies(90, { F = 100 }), CONTEXT, clock, { time = first.time, seconds = 60 }))
  check("(setup) marked", marks() == 1)
  assert(tuneHistory.setContext(MCU, { cyclicPolarity = 0, cyclicRing = 100, relaxType = 2 }))
  check("the context job keeps the mark with the newest flight", marks() == 1 and string.sub(lines()[#lines()], 1, 2) == "c(",
    tostring(lines()[#lines()]))
  fly(30)
  flights = tuneHistory.read(MCU)
  check("a later save keeps the mark with its flight", marks() == 1 and flights[2].contains ~= nil
    and flights[3].contains == nil, marks() .. " marks")
  fly(31) fly(32) fly(33)
  flights = tuneHistory.read(MCU)
  check("trimmed to five: the marked flight is the oldest kept, and still marked", #flights == 5
    and flights[1].seconds == 90 and flights[1].contains ~= nil and marks() == 1, #flights .. " flights")
  fly(34)
  check("trimmed past it: the mark goes with its flight", #tuneHistory.read(MCU) == 5 and marks() == 0, marks())

  -- Chained: each flight holds the one before
  reset()
  fly(60)
  for _, s in ipairs({ 90, 120 }) do
    local newest = tuneHistory.read(MCU)
    newest = newest[#newest]
    clock = clock + 60
    assert(tuneHistory.save(MCU, replies(s, { F = 100 }), CONTEXT, clock,
      { time = newest.time, seconds = newest.seconds }))
  end
  local _, chainUsed, chainSeconds = tuneHistory.aggregate(tuneHistory.read(MCU), 1)
  check("chained marks: only the newest reading counts", chainUsed == 1 and chainSeconds == 120,
    chainUsed .. " / " .. chainSeconds)

  -- The mark names its flight: once that flight is trimmed away, nothing else is left out
  reset()
  fly(60)
  local firstFlight = tuneHistory.read(MCU)[1]
  clock = clock + 60
  assert(tuneHistory.save(MCU, replies(90, { F = 100 }), CONTEXT, clock,
    { time = firstFlight.time, seconds = 60 }))
  for k = 1, 4 do fly(100 + k) end
  flights = tuneHistory.read(MCU)
  local _, trimmedUsed = tuneHistory.aggregate(flights, 1)
  check("a mark whose flight was trimmed away leaves no other flight out", #flights == 5 and flights[1].seconds == 90
    and flights[1].contains ~= nil and trimmedUsed == 5, #flights .. " flights, used " .. trimmedUsed)

  -- Flights on other profiles between: the marked flight still leaves out only the one it names
  reset()
  fly(60)
  firstFlight = tuneHistory.read(MCU)[1]
  clock = clock + 60
  assert(tuneHistory.save(MCU, replies(90, { F = 100 }), CONTEXT, clock,
    { time = firstFlight.time, seconds = 60 }))
  local otherCtx = {}
  for k, v in pairs(CONTEXT) do otherCtx[k] = v end
  otherCtx.pidProfile = (CONTEXT.pidProfile or 1) + 1
  fly(50, 100, otherCtx)
  fly(70)
  local _, interUsed, interSeconds = tuneHistory.aggregate(tuneHistory.read(MCU), 1)
  check("with another profile's flight between, only the named flight is left out", interUsed == 2
    and interSeconds == 160, interUsed .. " / " .. interSeconds)

  -- A mark after a line that does not read marks nothing
  reset()
  fly(60)
  fly(90)
  local text = files[HISTORY]
  local torn = string.gsub(text, '(f%(%d+,90,"yaw",)', 'f(x,90,"yaw",', 1)
  files[HISTORY] = torn .. "c(" .. tuneHistory.read(MCU)[1].time .. ",60)\n"
  flights = tuneHistory.read(MCU)
  check("a mark after a line that does not read marks nothing", flights[#flights].contains == nil
    and #flights == 2, tostring(flights[#flights].contains))
  files[HISTORY] = text .. "c(" .. tuneHistory.read(MCU)[1].time .. ",60)\n"
  flights = tuneHistory.read(MCU)
  check("(control) the same mark after a line that reads marks its flight", flights[#flights].contains ~= nil)
end

-- ---------------------------------------------------------------------------
print("Differences from the Ethos suite: owed work stays with its flight controller (#988)")
-- ---------------------------------------------------------------------------
do
  local OTHER = "def456"
  local OTHER_HISTORY = "/SCRIPTS/RFSUITE/user/tune/" .. OTHER .. ".lua"

  -- Flight controller A's flight is saved; before its clear goes out, B is connected. The clear
  -- would erase B's statistics, a flight B has not saved.
  fresh()
  update(true)
  update(false)
  pump(nil, 3)
  for _ = 1, 40 do
    if rig.capture().clearPending then break end
    rig.clock = rig.clock + 0.5
    rig.pass()
    -- The profiles read before the save (no PID#/RTE# here) is answered; the clear is not
    if rig.requests[1] and rig.name(rig.requests[1]) == "status" then rig.answer(rig.take()) end
  end
  check("(setup) A's flight is saved and its clear owed", rig.capture().clearPending == true and #lines() == 4)
  rig.session.mcu_id = OTHER
  local asked = pump()
  check("a clear owed to one flight controller is never sent to another", asked == ""
    and #rig.contextAsked == 0, asked .. " / " .. table.concat(rig.contextAsked, ","))
  local a = tuneHistory.read(MCU)[1].axes[1]
  check("A's flight stays saved, its settings unknown, and nothing is written for B",
    a.cyclicPolarity == nil and a.relaxType == nil and files[OTHER_HISTORY] == nil)
  check("nothing is left owed", rig.capture().clearPending == false and rig.capture().contextPending == false)
  asked = flyThrough(150)
  check("(control) B's own next flight is read, saved and cleared", asked == "roll,pitch,yaw,clear"
    and files[OTHER_HISTORY] ~= nil, asked)

  -- A's clear went through; before its settings are read, B is connected. Its settings would be
  -- written into A's flight.
  fresh()
  update(true)
  update(false)
  asked = pump(nil, 4)
  check("(setup) A's flight is saved and cleared", asked == "roll,pitch,yaw,clear"
    and rig.capture().contextPending == true, asked)
  rig.session.mcu_id = OTHER
  pump()
  a = tuneHistory.read(MCU)[1].axes[1]
  check("another flight controller's settings are never read into a saved flight", #rig.contextAsked == 0
    and a.cyclicPolarity == nil and a.cyclicRing == nil and a.relaxType == nil and files[OTHER_HISTORY] == nil,
    table.concat(rig.contextAsked, ","))
end

-- ---------------------------------------------------------------------------
print("Differences from the Ethos suite: two flights of the same length (#989)")
-- ---------------------------------------------------------------------------
do
  -- The flight time is all that tells a new flight from the same statistics read again before
  -- their clear got through; once the clear has, the next flight is a new one whatever its time.
  fresh()
  flyThrough(147)
  local asked = flyThrough(147)
  check("two flights of 147 s each are both saved", asked == "roll,pitch,yaw,clear"
    and #tuneHistory.read(MCU) == 2, asked .. " / " .. #tuneHistory.read(MCU) .. " flights")

  fresh()
  update(true)
  update(false)
  -- 40 s: the profiles read before the save adds one paced request
  asked = pump({ clear = { n = 3, reason = "timeout" } }, nil, 40)
  check("(setup) a saved flight whose clear never gets through", asked == "roll,pitch,yaw,clear,clear,clear"
    and #tuneHistory.read(MCU) == 1, asked)
  update(true)
  update(false)
  asked = pump()
  check("the same statistics read again before their clear are not saved twice, and cleared then",
    asked == "roll,pitch,yaw,clear" and #tuneHistory.read(MCU) == 1, asked .. " / " .. #tuneHistory.read(MCU) .. " flights")
end

-- ---------------------------------------------------------------------------
print("Differences from the Ethos suite: the settings read for the profiles flown (#979)")
-- ---------------------------------------------------------------------------
do
  -- The settings are read from the active profiles. Switched after the save, they are another
  -- profile's, not the flight's: they stay unknown.
  local function switchedAfterSave(field)
    fresh()
    update(true)
    update(false)
    local asked = pump(nil, 4)
    rig.session[field] = 1
    pump()
    local a = tuneHistory.read(MCU)[1].axes[1]
    return asked == "roll,pitch,yaw,clear" and a.pidProfile == 1 and a.rateProfile == 1
      and a.cyclicPolarity == nil and a.cyclicRing == nil and a.relaxType == nil and #rig.contextAsked == 0,
      table.concat(rig.contextAsked, ",") .. " / " .. tostring(a.cyclicPolarity) .. " " .. tostring(a.relaxType)
  end
  check("a PID profile switched after the save leaves the flight's settings unknown",
    switchedAfterSave("activeProfile"))
  check("so does a rate profile switched after the save", switchedAfterSave("activeRateProfile"))

  -- Switched while a read is on its way: its answer is the other profile's
  fresh()
  update(true)
  update(false)
  pump(nil, 4)
  for _ = 1, 20 do
    if rig.requests[1] then break end
    rig.clock = rig.clock + 0.5
    rig.pass()
  end
  local first = rig.requests[1] and rig.name(rig.requests[1])
  rig.session.activeRateProfile = 1
  rig.answer(rig.take())
  pump()
  local a = tuneHistory.read(MCU)[1].axes[1]
  check("a read answered after a profile switch is not used", first == "rc_tuning"
    and a.cyclicPolarity == nil and a.cyclicRing == nil and a.relaxType == nil, tostring(first) .. " / "
    .. tostring(a.cyclicPolarity) .. " " .. tostring(a.relaxType))
end

-- ---------------------------------------------------------------------------
print("Differences from the Ethos suite: the open page is told once the flight is complete (#979)")
-- ---------------------------------------------------------------------------
do
  -- The real page (app/pages/flight_tuning/tune_advisor/page.lua), opened from the dashboard in
  -- the capture's own Lua state: each pass is the capture's and then the page's. Its controls and
  -- texts are stubbed; it reads the card through the real lib/tune_history.lua.
  fresh()
  flyThrough(147)
  _G.rfsuite.palette = { text = 0, border = 0 }
  _G.SMLSIZE, _G.RIGHT = 1, 2
  rig.shared["app/pages/settings/common.lua"] = {
    pageT = function() return function(_, _, fallback) return fallback end end,
    resetPageState = assert(loadfile("src/rfsuite/app/pages/settings/common.lua"))().resetPageState,
  }
  rig.shared["ui/controls.lua"] = {
    ROW_H = 40, LABEL_H = 21, STATIC_SECTION_H = 38,
    labelY = function(y) return y + 10 end,
    appendStaticSectionHeader = function() end,
    appendComboSelect = function() return 40 end,
  }
  local Page = assert(loadfile("src/rfsuite/app/pages/flight_tuning/tune_advisor/page.lua"))()
  local ui
  for i = 1, 40 do
    local name, value = debug.getupvalue(Page.canSave, i)
    if name == "ui" then ui = value; break end
    if not name then break end
  end
  local pageCtx = { x = 0, y = 0, w = 800, h = 480, children = {}, requestRebuild = function() end }
  Page.build(pageCtx)
  -- Half-second passes: the capture, the page, then the flight controller answers
  local function run(seconds)
    local stopAt = rig.clock + seconds
    while rig.clock < stopAt do
      rig.clock = rig.clock + 0.5
      rig.pass()
      Page.wakeup(pageCtx)
      while rig.requests[1] do rig.answer(rig.take()) end
    end
  end
  run(10)
  local roll = ui.axes and ui.axes[1]
  check("(setup) the page shows the saved flight", roll ~= nil and roll.used == 1
    and roll.a.cyclicPolarity ~= nil, roll and roll.used)

  rig.reply.seconds = 150
  update(true)
  update(false)
  run(40)
  roll = ui.axes and ui.axes[1]
  check("a flight saved while the page is open is shown with its settings, without Reload",
    roll ~= nil and roll.a.cyclicPolarity ~= nil and roll.a.cyclicRing ~= nil and roll.a.relaxType ~= nil
    and roll.used == 2 and roll.seconds == 297,
    roll and (tostring(roll.used) .. " flights, " .. tostring(roll.seconds) .. " s, polarity "
    .. tostring(roll.a.cyclicPolarity)))
  Page.onClose()
  _G.rfsuite.palette = nil

  -- The same, on the capture's state alone
  fresh()
  update(true)
  update(false)
  pump(nil, 4)
  check("a reader is not told while the saved flight's settings are still to be read",
    rig.capture().saved == 0 and rig.capture().contextPending == true, rig.capture().saved)
  pump()
  check("it is told once they are in", rig.capture().saved == 1 and rig.capture().savedMcu == MCU)
  fresh()
  update(true)
  update(false)
  pump({ clear = { n = 3, reason = "timeout" } }, nil, 40)
  check("it is told too when the capture gives up before the settings are read",
    rig.capture().saved == 1 and rig.capture().contextPending == false and #rig.contextAsked == 0)
end

print(string.format("\n%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
