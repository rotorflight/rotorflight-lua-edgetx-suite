-- Run from the repository root: lua5.3 bin/telemetry/verify_decoder_log.lua
--
-- The log lines of the custom-telemetry decoder and the adjustment teller, at each Log Level,
-- in both of their hosts: the background function script (src/functions/rfsbg.lua) and the
-- widget's telemetry pass (tasks/events/telemetry_bg/tasks.lua). The real drain, the real decoder
-- table, the real teller and the real logger (lib/log.lua) run; what the logger prints is read.
--
-- Stand-ins, and only these: the EdgeTX calls, the audio module, the preferences module and the
-- SmartFuel task, as in verify_adjustment_teller_source.lua beside this file.
--
-- What it asserts:
--   * at the shipped level (off) neither module prints a line, and each asks the logger for the
--     level at most about once a second rather than on every pass;
--   * at debug every line names its host (`dash` or `bg`); decoding starting, a frame gap, the
--     widget standing aside for the background script and taking over again, a link reset, each
--     report from the flight controller and whether it was spoken are written, and no per-frame line;
--   * at trace one line per decoded frame names the values that changed, and the teller says what it
--     is waiting for;
--   * the state-line fragment says who decoded and how many frames and gaps it saw.
-- Exit status: 0 green, 1 a FAIL line was printed.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]telemetry$") or (dir .. "/../..") end
end

local checks, failures = 0, 0
local function check(ok, label, detail)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label .. (detail and (": " .. tostring(detail)) or ""))
  end
end

bit32 = {
  band = function(a, b) return a & b end,
  bor = function(a, b) return a | b end,
  bxor = function(a, b) return a ~ b end,
  lshift = function(a, n) return (a << n) & 0xFFFFFFFF end,
  rshift = function(a, n) return (a & 0xFFFFFFFF) >> n end,
  extract = function(a, f, w) return (a >> f) & ((1 << w) - 1) end,
  btest = function(a, b) return (a & b) ~= 0 end,
}

local realPrint = print
local CORE = "/SCRIPTS/RFSUITE/core/"
local FUNCTIONS = "/SCRIPTS/FUNCTIONS/"
local PASS_TICKS = 5          -- 50 ms per pass

local function copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = copy(v) end
  return out
end

local W = nil

local function newWorld(host, level)
  W = {
    ticks = 1000,
    frames = {},
    frameId = 0,
    adj = nil,
    nextAdjAt = 0,
    rows = {},
    passes = 0,
    spoken = {},
    shm = {},
    lines = {},
    wanted = 0,
    prefs = { audio_events = { adjustment_events = true }, general = { debug_level = level } },
  }

  _G.rfsuite = nil
  getTime = function() return W.ticks end
  getShmVar = function(id) return W.shm[id] or 0 end
  setShmVar = function(id, v) W.shm[id] = v end
  crossfireTelemetryPop = function()
    local f = table.remove(W.frames, 1)
    if f then return 0x88, f end
    return nil
  end
  setTelemetryValue = function(_, _, _, value, _, _, name)
    if name and name ~= "" then W.rows[name] = value end
  end
  getValue = function(name) return W.rows[name] end
  print = function(line) W.lines[#W.lines + 1] = tostring(line) end

  local audio = {
    adjustmentAllowed = function() return true end,
    playEventFile = function(file) W.spoken[#W.spoken + 1] = file end,
    playNumber = function(n) W.spoken[#W.spoken + 1] = "#" .. tostring(n) end,
    playRawFile = function(file) W.spoken[#W.spoken + 1] = file end,
  }
  local standIns = {
    ["lib/audio_playback.lua"] = function() return audio end,
    ["lib/preferences.lua"] = function()
      return { load = function() return copy(W.prefs) end }
    end,
    ["tasks/events/telemetry_bg/smart.lua"] = function()
      return { wakeup = function() end, reset = function() end }
    end,
  }

  loadScript = function(path)
    if string.sub(path, 1, #FUNCTIONS) == FUNCTIONS then
      return loadfile(ROOT .. "/src/functions/" .. string.sub(path, #FUNCTIONS + 1))
    end
    assert(string.sub(path, 1, #CORE) == CORE, "unexpected module path: " .. tostring(path))
    local relative = string.sub(path, #CORE + 1)
    if standIns[relative] then return standIns[relative] end
    return loadfile(ROOT .. "/src/rfsuite/" .. relative)
  end

  -- Counts the level questions put to the logger, whichever module asks.
  local function wrapLog()
    local L = _G.rfsuite and _G.rfsuite.Log
    if type(L) ~= "table" or L.__counted then return end
    local wanted = L.wanted
    L.wanted = function(lvl) W.wanted = W.wanted + 1 return wanted(lvl) end
    L.__counted = true
  end

  if host == "widget" then
    _G.rfsuite = { session = { event_context = "widget" }, preferences = W.prefs }
    assert(loadScript(CORE .. "lib/require.lua"))()
    assert(loadScript(CORE .. "lib/log.lua"))()
    wrapLog()
    W.tasks = assert(loadScript(CORE .. "tasks/events/telemetry_bg/tasks.lua"))()
    W.step = function() W.tasks.wakeup() end
  else
    W.script = assert(loadScript(FUNCTIONS .. "rfsbg.lua"))()
    W.step = function() W.script.run() wrapLog() end
  end
  return W
end

-- An ADJ row (sensor 0x1220) every 200 ms while `W.adj` is set, and an ARM row (0x1202) in every
-- frame, so the frame carries a value that does not change.
local function frame(fun, val)
  W.frameId = (W.frameId + 1) % 256
  local v = val & 0xFFFFFFFF
  return { 0xC8, 14, W.frameId, 0x12, 0x02, 0, 0x12, 0x20, (fun >> 8) & 0xFF, fun & 0xFF,
    (v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF }
end

local function pass(n)
  for _ = 1, n or 1 do
    W.ticks = W.ticks + PASS_TICKS
    W.passes = W.passes + 1
    if W.ticks >= W.nextAdjAt then
      local adj = W.adj or { 0, 0 }
      W.frames[#W.frames + 1] = frame(adj[1], adj[2])
      W.nextAdjAt = W.ticks + 20
    end
    if W.remote then
      W.remoteCount = (W.remoteCount or 0) + 1
      W.shm[16] = W.remoteCount
    end
    W.step()
  end
end

local function seconds(s) pass(math.floor(s * 100 / PASS_TICKS + 0.5)) end

local function grep(pattern)
  local n, first = 0, nil
  for _, line in ipairs(W.lines) do
    if string.find(line, pattern) then
      n = n + 1
      first = first or line
    end
  end
  return n, first
end

local function ours()
  local n = 0
  for _, line in ipairs(W.lines) do
    if string.find(line, "[rfsuite.decoder]", 1, true) or string.find(line, "[rfsuite.adjust]", 1, true) then
      n = n + 1
    end
  end
  return n
end

local function dump(limit)
  local out = {}
  for i = 1, math.min(#W.lines, limit or 12) do out[#out + 1] = W.lines[i] end
  return table.concat(out, " | ")
end

local function scenario(name, run)
  local ok, err = pcall(run)
  print = realPrint
  check(ok, name .. " runs without error", ok and nil or err)
end

-- 1. The shipped level: nothing printed, and the level asked about once a second, not per pass.
scenario("off_widget", function()
  newWorld("widget", "off")
  seconds(1)
  W.adj = { 10, 5 }
  seconds(3)
  W.adj = nil
  seconds(1)
  local printed = ours()
  local wanted, passes = W.wanted, W.passes
  print = realPrint
  check(printed == 0, "off_widget: no decoder or teller line at off", dump())
  -- Two modules (drain, teller), one question a second each over 5 s, plus their first.
  check(wanted <= 14, "off_widget: level asked at most once a second per module",
    string.format("%d questions in %d passes", wanted, passes))
  check(wanted >= 2, "off_widget: the level is asked at all", "questions=" .. wanted)
end)

-- 1b. A level raised while running reaches the decoder within about a second, and lowered again
-- silences it: the level is looked at once a second, not decided once at load.
scenario("level_change_widget", function()
  newWorld("widget", "off")
  seconds(2)
  W.prefs.general.debug_level = "debug"
  seconds(1.5)
  W.frameId = W.frameId + 1
  seconds(0.5)
  local raised = grep("dash: frame gap:")
  W.prefs.general.debug_level = "off"
  seconds(1.5)
  W.frameId = W.frameId + 1
  seconds(0.5)
  local lowered = grep("dash: frame gap:")
  print = realPrint
  check(raised == 1, "level_change_widget: a gap after raising the level is logged", dump())
  check(lowered == 1, "level_change_widget: a gap after lowering it again is not", dump())
end)

-- 2. debug in the widget: the edge lines, with the host, and no per-frame line.
scenario("debug_widget", function()
  newWorld("widget", "debug")
  seconds(1)
  W.adj = { 10, 5 }
  seconds(3)
  W.adj = nil
  seconds(1)
  -- A frame the link lost: the next id is two on.
  W.frameId = W.frameId + 1
  seconds(0.5)
  -- The background script starts draining: the widget stands aside, then takes over again.
  W.remote = true
  seconds(1)
  W.remote = false
  seconds(2)
  print = realPrint
  check(grep("%[rfsuite%.decoder%]%[debug%].* dash: decoding starts") == 1,
    "debug_widget: decoding starts, once, named dash", dump())
  check(grep("dash: report: function 10 value 5") == 1, "debug_widget: the report is logged once", dump(30))
  check(grep("dash: function 10 value 5 spoken") == 1, "debug_widget: the announcement is logged", dump(30))
  check(grep("dash: frame gap: id %d+ %-> %d+, 1 missing") >= 1, "debug_widget: the gap is logged", dump(40))
  check(grep("dash: stands aside") == 1, "debug_widget: standing aside is logged once", dump(60))
  check(grep("dash: takes over decoding") == 1, "debug_widget: taking over is logged once", dump(60))
  check(grep("dash: decoding resumes after") == 1, "debug_widget: the resume is logged", dump(60))
  check(grep("dash: frame %d+:") == 0, "debug_widget: no per-frame line at debug")
  check(grep("%[rfsuite%.adjust%]%[trace%]") == 0, "debug_widget: no teller trace at debug")
end)

-- 3. trace in the widget: one line per decoded frame, changes named, the teller's waiting.
scenario("trace_widget", function()
  newWorld("widget", "trace")
  seconds(1)
  W.adj = { 10, 5 }
  seconds(2)
  local frames = W.frameId
  print = realPrint
  local n, first = grep("dash: frame %d+: %d+ value%(s%), changed:")
  check(n >= frames - 2 and n <= frames, "trace_widget: one line per decoded frame",
    string.format("%d lines for %d frames", n, frames))
  check(grep("changed: ARM=0") >= 1, "trace_widget: the first ARM value is named", first)
  check(grep("changed: %-$") >= 1, "trace_widget: an unchanged frame says so", first)
  check(grep("dash: waiting: function 10 value 5 settles in") >= 1, "trace_widget: the teller says it waits", dump(40))
end)

-- 4. The background script at debug: named bg, and its state line carries the decoder fragment.
scenario("debug_bg", function()
  newWorld("bg", "debug")
  seconds(1)
  W.adj = { 10, 5 }
  seconds(3)
  W.adj = nil
  seconds(3)
  print = realPrint
  check(grep("bg: decoding starts") == 1, "debug_bg: decoding starts, named bg", dump())
  check(grep("bg: function 10 value 5 spoken") == 1, "debug_bg: the announcement is logged, named bg", dump(30))
  check(grep("dash:") == 0 and grep("tool:") == 0, "debug_bg: no line names another host")
  local n, line = grep("%[rfsuite%.functions%]%[info%].*state: .*decoder bg, %d+ frames, 0 gaps")
  check(n >= 1, "debug_bg: the state line says the background script decoded", line or dump(20))
end)

-- 5. The fragment for the widget's state line.
scenario("summary_widget", function()
  newWorld("widget", "off")
  seconds(2)
  local decoder = _G.rfsuite.telemetryDecoder
  check(type(decoder) == "table" and type(decoder.summary) == "function", "summary_widget: decoder registered")
  local first = decoder.summary()
  check(string.match(first, "^decoder dash, %d+ frames, 0 gaps$") ~= nil, "summary_widget: frames counted", first)
  W.remote = true
  seconds(1)
  W.frames = {}
  local aside = decoder.summary()
  check(aside == "decoder elsewhere" or string.match(aside, "^decoder dash"), "summary_widget: aside or the frames before it", aside)
  seconds(1)
  check(decoder.summary() == "decoder elsewhere", "summary_widget: standing aside reads elsewhere")
  print = realPrint
end)

print = realPrint
print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
