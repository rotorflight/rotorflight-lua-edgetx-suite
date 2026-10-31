-- Tune Advisor flight history: what the flight controller's tune advisor measured, one record
-- per flight and axis, kept per flight controller so the page can combine several flights.
--
--   /SCRIPTS/TOOLS/rfsuite.user/tune/<mcuId>.lua
--
-- The file is Lua the suite never runs as a script: read() loads it with an environment of its
-- own, in which the only names are the two collectors below. The first line is the format
-- version, every other line one flight on one axis:
--
--   v(1)
--   f(time, seconds, "roll", pidProfile, rateProfile, cyclicPolarity, cyclicRing, relaxType,
--     <FIELDS below, in order>)
--
-- time is the radio's clock in seconds (0 without one) and seconds the flight's usable time as
-- the flight controller counted it. The five values after the axis are the context the advice
-- depends on and the reply does not carry; any of them may be nil, which means unknown.
--
-- Only the newest MAX_FLIGHTS flights are kept, since the page never looks further back. Every
-- write replaces the whole file through lib/atomic_file.lua, so a write that is cut short
-- leaves the previous file in place rather than a torn one -- under its name, or as the `.bak`
-- the replace parked it as, which is then read instead. A line that does not read is
-- skipped and the rest of the file still counts.
--
-- aggregate() combines the newest flights flown on the newest flight's tune, for one axis:
-- counts add up, ratios are averaged weighted by the count they came from. The flight
-- controller's own gains are setpoint-squared weighted, so this is an approximation across
-- flights, close when flights are alike; the stop figures combine exactly. The field set,
-- precision and arithmetic are those of the Ethos suite's lib/tune_history.lua.

local M = {}

local requireModule = (_G.rfsuite and _G.rfsuite.require) or function(path)
  local fullPath = string.sub(path, 1, 1) == "/" and path or ("/SCRIPTS/TOOLS/rfsuite-core/" .. path)
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(fullPath, mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local USER_ROOT = "/SCRIPTS/TOOLS/rfsuite.user"
local DATA_DIR = USER_ROOT .. "/tune"
local FORMAT_VERSION = 1
local MAX_FLIGHTS = 5
local AXIS_COUNT = 3
local AXIS_NAMES = { "roll", "pitch", "yaw" }
local BAND_COUNT = 3
local READ_CAP, READ_CHUNK = 16384, 4096

-- {name in the file, key in the decoded axis table, format}; band fields carry band (the band
-- table's key) and index.
local FIELDS = {
  { "p", "P", "%d" }, { "f", "F", "%d" }, { "b", "B", "%d" }, { "relax_cutoff", "relaxCutoff", "%d" },
  { "rates_type", "ratesType", "%d" }, { "rc_rate", "rcRate", "%d" }, { "s_rate", "sRate", "%d" },
  { "ff_count", "ffCount", "%d" }, { "ff_gain", "ffGain", "%.3f" }, { "ff_corr", "ffCorr", "%.3f" },
  { "ff_lag_ms", "ffLagMs", "%d" },
}
local function addBands(band, labels)
  for i = 1, BAND_COUNT do
    FIELDS[#FIELDS + 1] = { labels[i] .. "_gain", "gain", "%.3f", band = band, index = i }
    FIELDS[#FIELDS + 1] = { labels[i] .. "_count", "count", "%d", band = band, index = i }
  end
end
addBands("spBands", { "sp40", "sp100", "sp200" })
addBands("collBands", { "coll0", "coll25", "coll50" })
for _, f in ipairs({
  { "full_count", "fullCount", "%d" }, { "full_sat_count", "fullSatCount", "%d" },
  { "full_ratio", "fullRatio", "%.3f" }, { "full_max_rate", "fullMaxRate", "%d" },
  { "releases", "releases", "%d" }, { "big_rebounds", "bigRebounds", "%d" },
  { "mean_rebound", "meanRebound", "%.3f" }, { "mean_overshoot", "meanOvershoot", "%.3f" },
  { "mean_counter", "meanCounter", "%.3f" }, { "mean_iterm", "meanIterm", "%.3f" },
  { "shake_count", "shakeCount", "%d" }, { "shake_rms", "shakeRms", "%.1f" },
}) do FIELDS[#FIELDS + 1] = f end

-- The context a flight was flown in, written after the axis, nil when unknown
local CONTEXT_KEYS = { "pidProfile", "rateProfile", "cyclicPolarity", "cyclicRing", "relaxType" }
-- The tune a flight was measured with: flights are only combined when these match
local TUNE_KEYS = { "P", "F", "B", "relaxCutoff", "ratesType", "rcRate", "sRate" }
-- ...and when these are known and equal on both: they change what the same numbers mean
local MEANING_KEYS = { "cyclicPolarity", "cyclicRing", "relaxType" }

local LEAD = 3 + #CONTEXT_KEYS
local ARG_COUNT = LEAD + #FIELDS

M.MAX_FLIGHTS = MAX_FLIGHTS
M.AXIS_COUNT = AXIS_COUNT
M.TUNE_KEYS = TUNE_KEYS
M.MEANING_KEYS = MEANING_KEYS
M.CONTEXT_KEYS = CONTEXT_KEYS
M.FIELDS = FIELDS

function M.path(mcuId)
  if mcuId == nil then return nil end
  local id = string.match(tostring(mcuId), "^%s*(.-)%s*$")
  if id == "" then return nil end
  id = string.gsub(id, "[^%w_-]", "_")
  return DATA_DIR .. "/" .. id .. ".lua"
end

local function makeDir(path)
  if type(mkdir) ~= "function" then return end
  pcall(mkdir, path)
end

local function fileSize(path)
  if type(fstat) ~= "function" then return nil end
  local ok, st = pcall(fstat, path)
  if not ok or type(st) ~= "table" then return nil end
  return tonumber(st.size)
end

local function newAxis()
  local a = { spBands = {}, collBands = {} }
  for i = 1, BAND_COUNT do
    a.spBands[i] = { gain = 0, count = 0 }
    a.collBands[i] = { gain = 0, count = 0 }
  end
  for _, f in ipairs(FIELDS) do
    if not f.band then a[f[2]] = 0 end
  end
  return a
end

-- An integer is written as it is: on a radio built with 32-bit floats, adding 0.5 to today's
-- clock would round it to a float that no longer holds the second. Only a float is rounded.
local function rounded(v)
  if math.type(v) == "integer" then return v end
  return math.tointeger(math.floor(v + 0.5)) or 0
end

local function integerOrNil(v)
  if type(v) ~= "number" then return "nil" end
  return string.format("%d", rounded(v))
end

local function line(time, seconds, axis, a)
  local parts = { integerOrNil(time or 0), integerOrNil(seconds or 0), string.format("%q", AXIS_NAMES[axis]) }
  for _, k in ipairs(CONTEXT_KEYS) do parts[#parts + 1] = integerOrNil(a[k]) end
  for _, f in ipairs(FIELDS) do
    local v = f.band and a[f.band][f.index][f[2]] or a[f[2]]
    v = tonumber(v) or 0
    if f[3] == "%d" then v = rounded(v) end
    parts[#parts + 1] = string.format(f[3], v)
  end
  return "f(" .. table.concat(parts, ",") .. ")"
end

local function readText(path)
  local size = fileSize(path)
  if size and size > READ_CAP then return nil, "too big" end
  local f = io.open(path, "r")
  if not f then return nil, size ~= nil and "open" or "missing" end
  local parts, total = {}, 0
  while true do
    local ok, chunk = pcall(io.read, f, math.min(READ_CHUNK, READ_CAP + 1 - total))
    if not ok then io.close(f); return nil, tostring(chunk) end
    if chunk == nil or chunk == "" then break end
    total = total + #chunk
    if total > READ_CAP then io.close(f); return nil, "too big" end
    parts[#parts + 1] = chunk
  end
  io.close(f)
  if size ~= nil and total ~= size then return nil, "short read" end
  return table.concat(parts)
end

-- The saved flights' text. A write cut short between lib/atomic_file.lua's two renames leaves
-- no file under the name but the previous one as `.bak`: that is read instead, and the next save
-- writes it back under the name.
local function readStored(path)
  local text, reason = readText(path)
  if text or reason ~= "missing" then return text, reason end
  return readText(path .. ".bak")
end

-- A read in steps, so that no step parses more than one flight's lines: building the axis tables
-- of all five flights in one call was the dearest pass of the page's open. The file is read
-- once, then AXIS_COUNT lines are run per step with the two collectors below. Each group of
-- lines is loaded in one go; when that fails anywhere -- a torn or hand-broken line, a value
-- that is not a number -- the group is run again line by line and every line that does not
-- read is skipped. loadScript is not used: it drops the environment and can leave compiled
-- bytecode beside the file.
local LINES_PER_READ_STEP = AXIS_COUNT

local function newCollector()
  local axisByName = {}
  for i = 1, AXIS_COUNT do axisByName[AXIS_NAMES[i]] = i end
  local col = { version = nil, rows = {} }
  local env = {}
  function env.v(n)
    if type(n) ~= "number" then error("invalid version") end
    col.version = n
  end
  function env.f(...)
    local n = select("#", ...)
    if n ~= ARG_COUNT then error("invalid flight line") end
    local args = { ... }
    local axis = axisByName[args[3]]
    if type(args[1]) ~= "number" or type(args[2]) ~= "number" or not axis then error("invalid flight line") end
    local a = newAxis()
    for k = 1, #CONTEXT_KEYS do
      local v = args[3 + k]
      if v ~= nil and type(v) ~= "number" then error("invalid flight line") end
      a[CONTEXT_KEYS[k]] = v
    end
    for k, f in ipairs(FIELDS) do
      local v = args[LEAD + k]
      if type(v) ~= "number" then error("invalid flight line") end
      if f.band then a[f.band][f.index][f[2]] = v else a[f[2]] = v end
    end
    col.rows[#col.rows + 1] = { time = args[1], seconds = args[2], axis = axis, a = a }
  end
  col.env = env
  return col
end

-- Runs lines first..last of the job's text with the collectors
local function collectLines(job, first, last)
  local col, lines = job.collector, job.lines
  local rows, version, count = col.rows, col.version, #col.rows
  local chunk = load(table.concat(lines, "\n", first, last), "=tune_history", "t", col.env)
  if chunk and pcall(chunk) then return end
  for i = #rows, count + 1, -1 do rows[i] = nil end
  col.version = version
  for i = first, last do
    local before = #rows
    local lineChunk = load(lines[i], "=tune_history", "t", col.env)
    if not lineChunk or not pcall(lineChunk) then
      for k = #rows, before + 1, -1 do rows[k] = nil end
    end
  end
end

--- A read of one flight controller's saved flights in steps (see M.readStep).
function M.readJob(mcuId)
  return { kind = "read", phase = "read", mcuId = mcuId }
end

--- One step of a job from readJob(): nil while there is more to do, then what read() answers.
function M.readStep(job)
  if job.phase == "read" then
    local path = M.path(job.mcuId)
    if not path then job.phase = "done"; return {}, "mcu id" end
    local text, reason = readStored(path)
    if not text then job.phase = "done"; return {}, reason end
    local lines = {}
    for oneLine in string.gmatch(text, "[^\r\n]+") do lines[#lines + 1] = oneLine end
    job.lines, job.next, job.collector = lines, 1, newCollector()
    job.phase = "parse"
    return nil
  elseif job.phase == "parse" then
    local last = math.min(#job.lines, job.next + LINES_PER_READ_STEP - 1)
    if job.next <= last then collectLines(job, job.next, last) end
    job.next = last + 1
    if job.next <= #job.lines then return nil end
  end
  local col = job.collector
  job.phase, job.lines, job.collector = "done", nil, nil
  if not col or col.version ~= FORMAT_VERSION then return {}, "version" end

  local flights, current = {}, nil
  for _, row in ipairs(col.rows) do
    if not current or current.time ~= row.time or current.axes[row.axis] then
      current = { time = row.time, seconds = row.seconds, axes = {} }
      flights[#flights + 1] = current
    end
    current.axes[row.axis] = row.a
  end
  return flights
end

--- The saved flights for one flight controller, oldest first: {time, seconds, axes = {a, a, a}}.
--- Each axis table is shaped like a decoded reply's `a`, plus the context keys. A missing file,
--- or one of another format version, reads as no flights; the second value says why.
function M.read(mcuId)
  local job = M.readJob(mcuId)
  while true do
    local flights, reason = M.readStep(job)
    if flights ~= nil then return flights, reason end
  end
end

-- A rewrite of the file in steps, each small enough for one widget pass.
--
-- A save keeps the lines of the flights it keeps as they are and rebuilds none of them, and it
-- runs as a job the caller steps once per pass: format one new line, read the file, check a few
-- lines, write. The whole of it in one call -- every line parsed into a flight and every value
-- formatted back, five flights at a time -- cost more than twice the instructions a widget pass
-- may take, on the pass after a disarm. A line is checked exactly as read() checks it, so a line
-- read() would skip is dropped here too.
local SCAN_LINES_PER_STEP = 4

local function newScanner()
  local axisByName = {}
  for i = 1, AXIS_COUNT do axisByName[AXIS_NAMES[i]] = i end
  local sc = { version = nil, rows = {}, current = nil }
  local env = {}
  function env.v(n)
    if type(n) ~= "number" then error("invalid version") end
    sc.version = n
  end
  function env.f(...)
    if select("#", ...) ~= ARG_COUNT then error("invalid flight line") end
    local args = { ... }
    local axis = axisByName[args[3]]
    if type(args[1]) ~= "number" or type(args[2]) ~= "number" or not axis then error("invalid flight line") end
    for k = 4, LEAD do
      local v = args[k]
      if v ~= nil and type(v) ~= "number" then error("invalid flight line") end
    end
    for k = LEAD + 1, ARG_COUNT do
      if type(args[k]) ~= "number" then error("invalid flight line") end
    end
    sc.current = { time = args[1], axis = axis }
  end
  sc.env = env
  return sc
end

local function scanLine(sc, oneLine)
  sc.current = nil
  local lineChunk = load(oneLine, "=tune_history", "t", sc.env)
  if lineChunk and pcall(lineChunk) and sc.current then
    sc.current.text = oneLine
    sc.rows[#sc.rows + 1] = sc.current
  end
end

-- The scanned lines grouped into flights by read()'s rule: a new flight where the time changes
-- or an axis repeats.
local function groupRows(rows)
  local flights, current = {}, nil
  for _, row in ipairs(rows) do
    if not current or current.time ~= row.time or current.axes[row.axis] then
      current = { time = row.time, axes = {} }
      flights[#flights + 1] = current
    end
    current.axes[row.axis] = row
    current[#current + 1] = row
  end
  return flights
end

local function write(mcuId, lines)
  local path = M.path(mcuId)
  if not path then return false end
  -- Loaded only to write: reading the history never needs it
  local AtomicFile = requireModule("lib/atomic_file.lua")
  if type(AtomicFile) ~= "table" or type(AtomicFile.replace) ~= "function" then return false end
  local out = { "v(" .. FORMAT_VERSION .. ")" }
  for i = 1, #lines do out[#out + 1] = lines[i] end
  out[#out + 1] = ""
  makeDir(USER_ROOT)
  makeDir(DATA_DIR)
  return AtomicFile.replace(path, table.concat(out, "\n"), true) == true
end

-- Replaces the five context values of a checked line, leaving every other byte of it as it is
local CONTEXT_PATTERN = '^(f%([^,]*,[^,]*,"%a+",)([^,]*),([^,]*),([^,]*),([^,]*),([^,]*)(,.*)$'

local function withContext(text, context)
  local head, c1, c2, c3, c4, c5, tail = string.match(text, CONTEXT_PATTERN)
  if not head then return nil end
  local values = { c1, c2, c3, c4, c5 }
  for k, key in ipairs(CONTEXT_KEYS) do
    if context[key] ~= nil then values[k] = integerOrNil(context[key]) end
  end
  return head .. table.concat(values, ",") .. tail
end

-- The flights the job keeps, as lines, plus what it adds or changes
local function finishJob(job)
  local flights = job.scanner and job.scanner.version == FORMAT_VERSION and groupRows(job.scanner.rows) or {}
  local out = {}
  if job.kind == "save" then
    for i = math.max(1, #flights - (MAX_FLIGHTS - 1) + 1), #flights do
      local flight = flights[i]
      for j = 1, #flight do out[#out + 1] = flight[j].text end
    end
    for axis = 1, AXIS_COUNT do out[#out + 1] = job.added[axis] end
  else
    local newest = flights[#flights]
    if not newest then return false end
    for i = 1, #flights - 1 do
      local flight = flights[i]
      for j = 1, #flight do out[#out + 1] = flight[j].text end
    end
    for j = 1, #newest do
      local changed = withContext(newest[j].text, job.context)
      if not changed then return false end
      out[#out + 1] = changed
    end
  end
  return write(job.mcuId, out)
end

--- One step of a job from saveJob() or contextJob(): nil while there is more to do, true when the
--- file is written, false and a reason when it is not.
function M.step(job)
  if job.phase == "format" then
    local axis = #job.added + 1
    local reply = job.replies[axis]
    local a = reply.a
    if type(job.context) == "table" then
      a = {}
      for k, v in pairs(reply.a) do a[k] = v end
      for _, k in ipairs(CONTEXT_KEYS) do a[k] = job.context[k] end
    end
    job.added[axis] = line(job.time, job.seconds, axis, a)
    if axis == AXIS_COUNT then job.phase = "read" end
    return nil
  elseif job.phase == "read" then
    local text, reason = readStored(M.path(job.mcuId))
    if not text then
      -- Missing: started anew. Anything else: the file is left as it is.
      if reason ~= "missing" then return false, reason end
      job.phase = "write"
      return nil
    end
    local lines = {}
    for oneLine in string.gmatch(text, "[^\r\n]+") do lines[#lines + 1] = oneLine end
    job.lines, job.next, job.scanner = lines, 1, newScanner()
    job.phase = "scan"
    return nil
  elseif job.phase == "scan" then
    local lines, sc = job.lines, job.scanner
    local last = math.min(#lines, job.next + SCAN_LINES_PER_STEP - 1)
    for i = job.next, last do scanLine(sc, lines[i]) end
    job.next = last + 1
    if job.next > #lines then
      job.lines = nil
      job.phase = "write"
    end
    return nil
  end
  -- A file of another format version reads as no flights: a save starts it again
  local ok = finishJob(job)
  job.phase = "done"
  if not ok then return false, "write" end
  return true
end

--- A save in steps (see M.step): appends one flight and drops all but the newest MAX_FLIGHTS.
--- replies: the three decoded tasks/msp/api/tune_advisor.lua records, roll, pitch, yaw. context:
--- any of CONTEXT_KEYS known at the time (the rest stay unknown). time: the radio clock in
--- seconds. Nil when the replies are not three.
---
--- The file is rebuilt from the lines it holds, so a read that failed would write this one
--- flight over the ones before it. Only a file that read, is not there, or is of another format
--- version (which is started again) is replaced; a file that could not be opened or read, or is
--- over the cap, is left as it is and the step reports the failure. The caller then keeps the
--- flight controller's statistics and tries again.
function M.saveJob(mcuId, replies, context, time)
  if not M.path(mcuId) or type(replies) ~= "table" then return nil end
  for axis = 1, AXIS_COUNT do
    local reply = replies[axis]
    if type(reply) ~= "table" or type(reply.a) ~= "table" then return nil end
  end
  return { kind = "save", phase = "format", mcuId = mcuId, replies = replies, context = context,
    time = time or 0, seconds = replies[1].seconds or 0, added = {} }
end

--- A job (see M.step) that fills in context keys of the newest saved flight, for values only
--- known after it was saved. Keys absent from `context` keep what the file holds. Only the
--- newest flight's lines change; every other line is kept as it is.
function M.contextJob(mcuId, context)
  if not M.path(mcuId) or type(context) ~= "table" then return nil end
  return { kind = "context", phase = "read", mcuId = mcuId, context = context }
end

local function runJob(job)
  if not job then return false end
  while true do
    local ok, why = M.step(job)
    if ok ~= nil then return ok, why end
  end
end

--- saveJob() in one call. Returns true when written; false and, where the file could not be
--- read, the reason.
function M.save(mcuId, replies, context, time)
  return runJob(M.saveJob(mcuId, replies, context, time))
end

--- contextJob() in one call. Returns true when written.
function M.setContext(mcuId, context)
  local ok = runJob(M.contextJob(mcuId, context))
  return ok == true
end

function M.erase(mcuId)
  local path = M.path(mcuId)
  if not path or type(del) ~= "function" then return false end
  -- The .bak too: a read finding no file would bring it back
  pcall(del, path)
  pcall(del, path .. ".bak")
  pcall(del, path .. ".new")
  return fileSize(path) == nil and fileSize(path .. ".bak") == nil
end

local RATE_KEYS = { ratesType = true, rcRate = true, sRate = true }

-- The axis table whose rate bytes the flight controller flew an axis with: under polar cyclic
-- Roll follows Pitch's rates and its own go unused. Nil when a polar flight has no Pitch line.
local function ratesFlown(flight, axis)
  local a = flight.axes[axis]
  if axis == 1 and a.cyclicPolarity == 1 then return flight.axes[2] end
  return a
end

local function sameTune(flightA, flightB, axis)
  local a, b = flightA.axes[axis], flightB.axes[axis]
  for _, k in ipairs(MEANING_KEYS) do
    if a[k] == nil or b[k] == nil or a[k] ~= b[k] then return false end
  end
  local ra, rb = ratesFlown(flightA, axis), ratesFlown(flightB, axis)
  if not ra or not rb then return false end
  for _, k in ipairs(TUNE_KEYS) do
    if RATE_KEYS[k] then
      if ra[k] ~= rb[k] then return false end
    elseif a[k] ~= b[k] then
      return false
    end
  end
  return true
end

-- weighted running mean: adds value v with weight w to out[key] over total
local function addMean(out, key, v, w, total)
  if total > 0 then out[key] = out[key] + (v - out[key]) * w / total end
end

local function addBand(bands, src)
  for i = 1, BAND_COUNT do
    local b, s = bands[i], src[i]
    b.count = b.count + s.count
    addMean(b, "gain", s.gain, s.count, b.count)
  end
end

--- One axis (1 roll, 2 pitch, 3 yaw) over the newest flights on the newest flight's tune.
--- Returns the combined axis table (shaped like a decoded reply's `a`, with the newest flight's
--- context keys; all zeros with no flights), the flights used and their total seconds. Under
--- polar cyclic a Roll flight's rates are the Pitch rates it flew on, so a Pitch rate change ends
--- Roll's flights too; the table keeps Roll's own bytes.
function M.aggregate(flights, axis)
  local out = newAxis()
  local newest = flights[#flights] and flights[#flights].axes[axis]
  if not newest then return out, 0, 0 end
  for _, k in ipairs(TUNE_KEYS) do out[k] = newest[k] end
  for _, k in ipairs(CONTEXT_KEYS) do out[k] = newest[k] end

  local used, seconds, shakeSq = 0, 0, 0
  for i = #flights, math.max(1, #flights - MAX_FLIGHTS + 1), -1 do
    local a = flights[i].axes[axis]
    -- The newest flight always counts; an older one only on the same tune, in the same context
    if not a or (i < #flights and not sameTune(flights[i], flights[#flights], axis)) then break end
    used = used + 1
    seconds = seconds + flights[i].seconds

    out.ffCount = out.ffCount + a.ffCount
    addMean(out, "ffGain", a.ffGain, a.ffCount, out.ffCount)
    addMean(out, "ffCorr", a.ffCorr, a.ffCount, out.ffCount)
    addMean(out, "ffLagMs", a.ffLagMs, a.ffCount, out.ffCount)
    addBand(out.spBands, a.spBands)
    addBand(out.collBands, a.collBands)

    out.fullCount = out.fullCount + a.fullCount
    out.fullSatCount = out.fullSatCount + a.fullSatCount
    addMean(out, "fullRatio", a.fullRatio, a.fullCount, out.fullCount)
    if a.fullMaxRate > out.fullMaxRate then out.fullMaxRate = a.fullMaxRate end

    out.releases = out.releases + a.releases
    out.bigRebounds = out.bigRebounds + a.bigRebounds
    addMean(out, "meanRebound", a.meanRebound, a.releases, out.releases)
    addMean(out, "meanOvershoot", a.meanOvershoot, a.releases, out.releases)
    addMean(out, "meanCounter", a.meanCounter, a.releases, out.releases)
    addMean(out, "meanIterm", a.meanIterm, a.releases, out.releases)

    -- RMS combines exactly: the mean of the squares, weighted by count
    out.shakeCount = out.shakeCount + a.shakeCount
    shakeSq = shakeSq + (a.shakeRms * a.shakeRms - shakeSq) * (out.shakeCount > 0 and a.shakeCount / out.shakeCount or 0)
  end
  out.shakeRms = math.sqrt(shakeSq)
  out.ffLagMs = math.floor(out.ffLagMs + 0.5)
  return out, used, seconds
end

--- The value the pilot last set by hand for one setting: from the current value, follows the
--- change journal (lib/change_journal.lua entries, oldest first) back while each entry is the
--- Tune Advisor's own, on the same field and profile, and ended at the value the walk stands on.
--- Any other entry on that field and profile -- a hand edit on another page, a different value
--- -- ends the walk, so the value it set counts as the pilot's. No entry: the current value.
function M.pilotValue(entries, profile, field, value)
  if type(entries) ~= "table" then return value end
  local want = { profile = profile, field = field, value = value }
  M.pilotValues(entries, { want })
  return want.value
end

--- pilotValue() for several settings in one walk over the entries: `wants` is a list of
--- {profile, field, value}, one per field; each `value` is replaced by the pilot's own.
function M.pilotValues(entries, wants)
  if type(entries) ~= "table" then return end
  local byField, open = {}, 0
  for _, w in ipairs(wants) do
    byField[w.field] = w
    open = open + 1
  end
  for i = #entries, 1, -1 do
    local e = entries[i]
    local w = byField[e.field]
    if w and e.profile == w.profile then
      if e.source ~= "tune_advisor" or e.new ~= w.value then
        -- This setting's walk ends here
        byField[e.field] = nil
        open = open - 1
        if open == 0 then return end
      else
        w.value = e.old
      end
    end
  end
end

return M
