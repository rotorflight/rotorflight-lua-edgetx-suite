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
-- suite's event runtime (bin/flight_tuning/tune_capture_rig.lua); its request gate is
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
-- The card: paths under /SCRIPTS/TOOLS/rfsuite.user live in `files`.
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
  local relative = string.match(path, "^/SCRIPTS/TOOLS/rfsuite%-core/(.+)$")
  assert(relative == "lib/atomic_file.lua", "unexpected module: " .. tostring(path))
  return assert(loadfile("src/rfsuite/" .. relative))
end
_G.rfsuite = nil

local Api = assert(loadfile("src/rfsuite/tasks/msp/api/tune_advisor.lua"))()
local tuneHistory = assert(loadfile("src/rfsuite/lib/tune_history.lua"))()
local journal = assert(loadfile("src/rfsuite/lib/change_journal.lua"))()

local MCU = "abc123"
local HISTORY = "/SCRIPTS/TOOLS/rfsuite.user/tune/" .. MCU .. ".lua"
local JOURNAL = "/SCRIPTS/TOOLS/rfsuite.user/journal/" .. MCU .. ".lua"
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
    tuneHistory.path("ab c/1") == "/SCRIPTS/TOOLS/rfsuite.user/tune/ab_c_1.lua"
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
      if name == "rc_tuning" or name == "pid_profile" then
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
      if name ~= "rc_tuning" and name ~= "pid_profile" then asked[#asked + 1] = name end
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
  -- the save the Ethos case fails four times.
  local realStep, saves = history.step, 0
  history.step = function(job)
    if job.kind == "save" and job.phase == "write" then
      saves = saves + 1
      if saves <= 4 then job.phase = "done"; return false, "write" end
    end
    return realStep(job)
  end
  rig.shared["lib/tune_history.lua"] = history
  update(true)
  update(false)
  local asked = pump(nil, nil, 60)
  check("a failed write is tried again without reading again, past the link-error limit",
    asked == "roll,pitch,yaw,clear" and saves == 5 and #lines() == 4,
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
print("Differences from the Ethos suite: owed work stays with its flight controller (#988)")
-- ---------------------------------------------------------------------------
do
  local OTHER = "def456"
  local OTHER_HISTORY = "/SCRIPTS/TOOLS/rfsuite.user/tune/" .. OTHER .. ".lua"

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
  asked = pump({ clear = { n = 3, reason = "timeout" } })
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
  pump({ clear = { n = 3, reason = "timeout" } })
  check("it is told too when the capture gives up before the settings are read",
    rig.capture().saved == 1 and rig.capture().contextPending == false and #rig.contextAsked == 0)
end

print(string.format("\n%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
