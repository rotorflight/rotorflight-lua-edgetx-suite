-- The logger's level decision, offline:
--
--   lua5.3 bin/core/verify_log_level.lua
--
-- The real lib/log.lua with a capturing print and a controllable clock. Checked: what a line
-- reaches -- the Session Logs ring, the card sink, the console -- at each level; that a change of
-- the Log Level applies from the next line on (the configured level is kept against the raw
-- preference value, so this is the case that would show a stale one); the "warning" alias, a
-- level written in capitals and an unknown value; the console opt-out; and that the ring, the sink
-- and the console carry one clock reading and the same text for one line.
--
-- No timing is measured. Exit status: 0 green, 1 failed expectations.

local root = "."

local failures, checks = 0, 0
local function check(ok, label, detail)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    io.stdout:write("FAIL " .. label .. (detail ~= nil and (": " .. tostring(detail)) or "") .. "\n")
  end
end

local console = {}
local realPrint = print
_G.print = function(line) console[#console + 1] = tostring(line) end

local ticks = 1000
_G.getTime = function() ticks = ticks + 7; return ticks end

_G.rfsuite = { preferences = { general = {} } }
local Log = assert(loadfile(root .. "/src/rfsuite/lib/log.lua"))()

local function setLevel(value)
  _G.rfsuite.preferences.general.debug_level = value
end

local function begin(level, sink)
  setLevel(level)
  _G.rfsuite.log_history = {}
  _G.rfsuite.log_sink = sink and {} or nil
  console = {}
end

local function inRing(part)
  local n = 0
  for _, e in ipairs(_G.rfsuite.log_history) do
    if string.find(e.msg, part, 1, true) then n = n + 1 end
  end
  return n
end

local function inSink(part)
  local n = 0
  for _, e in ipairs(_G.rfsuite.log_sink or {}) do
    if string.find(e.msg, part, 1, true) then n = n + 1 end
  end
  return n
end

local function onConsole(part)
  local n = 0
  for _, line in ipairs(console) do
    if string.find(line, part, 1, true) then n = n + 1 end
  end
  return n
end

-- 1. What a line reaches, level by level.
begin("debug", true)
Log.emit("t", "d1", "debug")
Log.emit("t", "x1", "trace")
check(inRing("d1") == 1 and inSink("d1") == 1 and onConsole("d1") == 1, "debug: a debug line reaches ring, sink and console")
check(inRing("x1") == 0 and inSink("x1") == 0 and onConsole("x1") == 0, "debug: a trace line reaches nothing")

begin("off", true)
Log.emit("t", "d2", "debug")
Log.emit("t", "i2", "info")
Log.emit("t", "e2", "error")
check(inRing("d2") == 0 and inSink("d2") == 0 and onConsole("d2") == 0, "off: a debug line reaches nothing")
check(inRing("i2") == 1 and inSink("i2") == 1 and onConsole("i2") == 0, "off: an info line reaches ring and sink, not the console")
check(inRing("e2") == 1 and onConsole("e2") == 0, "off: an error line reaches the ring, not the console")

begin(nil, false)
Log.emit("t", "d3", "debug")
Log.emit("t", "i3", "info")
check(inRing("d3") == 0 and onConsole("d3") == 0, "no setting: off for a debug line")
check(inRing("i3") == 1 and onConsole("i3") == 0, "no setting: the ring still keeps an info line")

-- 2. A change of the setting applies from the next line on, both ways.
begin("off", false)
Log.emit("t", "before", "debug")
setLevel("debug")
Log.emit("t", "after", "debug")
check(onConsole("before") == 0 and onConsole("after") == 1, "raised: the next line is written")
setLevel("info")
Log.emit("t", "lowered", "debug")
check(onConsole("lowered") == 0, "lowered: the next debug line is not written")
check(Log.wanted("info") == true and Log.wanted("debug") == false, "lowered: Log.wanted follows the setting")
setLevel("trace")
check(Log.wanted("trace") == true, "raised to trace: Log.wanted follows the setting")

-- 3. The alias, capitals and an unknown value.
begin("WARNING", false)
Log.emit("t", "w4", "warn")
Log.emit("t", "i4", "info")
check(onConsole("w4") == 1 and onConsole("i4") == 0, "WARNING: the alias of warn, in capitals")
begin("loudest", false)
Log.emit("t", "e5", "error")
check(onConsole("e5") == 0, "an unknown setting is off")
begin("debug", false)
Log.emit("t", "m6", "Warning")
Log.emit("t", "m7", nil)
check(onConsole("m6") == 1, "a message level in capitals is understood")
check(onConsole("m7") == 1, "a message without a level is a debug line")

-- 4. The console opt-out keeps the ring.
begin("debug", false)
Log.emit("t", "quiet", "debug", false)
check(onConsole("quiet") == 0 and inRing("quiet") == 1, "enabled=false: off the console, still in the ring")

-- 5. One line, one clock reading and one text everywhere.
begin("debug", true)
Log.emit("tag.x", "same text", "info")
local ring = _G.rfsuite.log_history[#_G.rfsuite.log_history]
local sink = _G.rfsuite.log_sink[#_G.rfsuite.log_sink]
check(ring.time == sink.time, "ring and sink carry the same clock reading", tostring(ring.time) .. " " .. tostring(sink.time))
check(ring.tag == "tag.x" and sink.tag == "tag.x" and ring.level == "info" and sink.level == "info",
  "ring and sink carry the same tag and level")
check(console[#console] == "[tag.x][info][" .. string.format("%0.1f", ring.time / 100) .. "] same text",
  "the console line carries the same clock reading", console[#console])
Log.emit("t", nil, "info")
check(_G.rfsuite.log_history[#_G.rfsuite.log_history].msg == "" and console[#console]:sub(-4) == " nil",
  "a nil message is empty in the ring and 'nil' on the console, as before")

_G.print = realPrint
if failures > 0 then
  print(string.format("log level: %d of %d checks failed", failures, checks))
  os.exit(1)
end
print(string.format("OK log level: %d checks hold", checks))
