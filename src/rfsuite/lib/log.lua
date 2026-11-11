local Log = {}

local function isTruthy(value)
  return value == true or value == 1 or value == "1" or value == "true"
end

-- The severity ladder, ordered from quietest to most verbose. This table is the single
-- definition of it: the rank comparison below and the Log Level selector on the developer
-- settings page both derive from it, so a level is added in one place instead of several.
--
-- The names are the ones GEMINI.md documents for Log.emit and the ones
-- app/pages/tools/diagnostics/session_logs/page.lua gives a colour of its own.
-- `trace` sits below `debug` and is the level the payload dumps hang on. It is separate rather
-- than folded into `debug` so that `debug` stays exactly as loud as it has always been.
local LEVELS = { "off", "error", "warn", "info", "debug", "trace" }

local RANK = {}
for index, name in ipairs(LEVELS) do
  RANK[name] = index - 1
end

local function normalizeLevel(value)
  local text = string.lower(tostring(value or "debug"))
  if text == "warning" then return "warn" end
  if RANK[text] then return text end
  return "debug"
end

-- Every call site passes one of the ladder's names, so the table answers directly and the
-- string work in normalizeLevel runs only for a level that is mistyped or not a string.
local function debugLevelRank(level)
  return RANK[level] or RANK[normalizeLevel(level)]
end

local function configuredRankOf(value)
  if value == nil then
    return RANK.off
  end
  local text = string.lower(tostring(value))
  if text == "warning" then text = "warn" end
  -- A value this build does not know stays off. normalizeLevel falls back to "debug", which is
  -- right for a message whose level is mistyped and wrong for the switch deciding whether
  -- anything is written at all -- there it would turn an unreadable setting into the loudest one.
  return RANK[text] or RANK.off
end

-- The configured level is read on every line, and turning it into a rank is string work. The
-- rank is kept against the raw preference value it came from, so a line costs one comparison
-- and a change on the developer settings page still takes effect on the next line. `false` is
-- never a stored value, so the first read always converts.
local configuredValue, configuredRank = false, RANK.off

local function configuredDebugRank()
  local root = _G and _G.rfsuite
  local prefs = root and root.preferences
  local general = prefs and prefs.general
  local value = general and general.debug_level
  if value ~= configuredValue then
    configuredRank = configuredRankOf(value)
    configuredValue = value
  end
  return configuredRank
end

local function shouldEmitByLevel(messageLevel)
  local configured = configuredDebugRank()
  if configured == RANK.off then
    return false
  end
  return debugLevelRank(messageLevel) <= configured
end

local function isSerialDebugEnabled()
  local root = _G and _G.rfsuite
  local prefs = root and root.preferences
  local general = prefs and prefs.general
  return isTruthy(general and general.enable_serial_debug)
end

local MAX_HISTORY = 60
local MAX_MSG_LEN = 100

-- Initialize global state once
if type(_G) == "table" then
  _G.rfsuite = _G.rfsuite or {}
  _G.rfsuite.log_history = _G.rfsuite.log_history or {}
  _G.rfsuite.log_history_seq = _G.rfsuite.log_history_seq or 0
end

-- The ring is a SCREEN budget, not a buffer budget: app/pages/tools/diagnostics/session_logs is
-- its consumer, and 60 entries of 100 characters is what that page can show. Anything writing
-- the log to a card is a different consumer with a different one -- a payload dump is longer
-- than MAX_MSG_LEN by itself, and a trace fills sixty entries in well under a second. So a sink
-- is given a list of its own, untruncated and far longer, and the ring is left exactly as that
-- page expects to find it.
-- An OVERFLOW GUARD, not a working size. The sink drains this list on every write, so what it
-- normally holds is one flush interval -- a few seconds. The cap only decides how much may pile
-- up if writing stops, and it is deliberately far smaller than it looks like it could be:
-- measured in the same units the radio reports, a retained entry of a payload line costs about
-- 340 bytes, so a thousand of them is a third of a megabyte. On a small radio the whole Lua
-- budget is of that order, and a diagnostic that eats it is the problem it was built to find.
local SINK_MAX = 400

-- Whether a sink is taking lines is the EXISTENCE of the list, and not a flag in this file.
--
-- Several places load this module with a raw loadScript rather than through lib/require.lua --
-- tasks/events/common/runner.lua is one -- so more than one copy of it can be live in a single
-- Lua state, each with its own upvalues. A flag kept here is therefore true in the copy that
-- attached and false in every other, while the list itself sits in _G and is shared: the
-- symptom is a log that carries some subsystems and silently drops the rest.
local function sinkList()
  local sink = _G.rfsuite.log_sink
  return type(sink) == "table" and sink or nil
end

-- Both buffers take the strings Log.emit has already made, and the one clock read it took.
local function addToSink(sink, tag, msg, level, now)
  sink[#sink + 1] = {
    tag = tag,
    msg = msg,
    level = level,
    time = now
  }
  if #sink > SINK_MAX then
    -- The cap is an overflow guard, not a working size: the sink empties this list every time it
    -- writes, so in normal running it holds one flush interval's worth. Dropping the oldest is
    -- still real data loss and is counted, so the file can say a gap happened.
    table.remove(sink, 1)
    _G.rfsuite.log_sink_lost = (_G.rfsuite.log_sink_lost or 0) + 1
  end
end

local function addToHistory(tag, msg, level, now)
  local m = msg
  if string.len(m) > MAX_MSG_LEN then
    m = string.sub(m, 1, MAX_MSG_LEN - 3) .. "..."
  end

  local history = _G.rfsuite.log_history
  table.insert(history, {
    tag = tag,
    msg = m,
    level = level,
    time = now
  })

  if #history > MAX_HISTORY then
    table.remove(history, 1)
  end
  
  _G.rfsuite.log_history_seq = _G.rfsuite.log_history_seq + 1
end

--- Emit one log line.
--
-- `enabled` is a console OPT-OUT: false keeps a line off the console while it still reaches
-- the ring, the sink and serial; nil and true both mean on. It exists for the call sites
-- that gate console output on a preference of their own, and it decides nothing else.
--
-- A line runs inside whichever widget pass or task emits it, and that pass has an instruction
-- budget the firmware enforces, so the work per line is done once: one level decision, one
-- clock read, one string conversion, shared by the ring, the sink and the console.
function Log.emit(tag, msg, level, enabled)
  local configured = configuredDebugRank()
  local rank = debugLevelRank(level)
  local emitByLevel = configured ~= RANK.off and rank <= configured

  -- Always buffer important logs (info/warn/error) or if debug is enabled.
  --
  -- Written as a rank comparison rather than as "anything that is not debug": with `trace` below
  -- `debug`, the old test was true for a trace line as well, which would have put every payload
  -- dump into the ring at every setting -- `off` included -- and flooded the page the ring
  -- exists for. The behaviour for the five levels that existed before is identical.
  if not (emitByLevel or rank <= RANK.info) then
    return
  end

  local now = getTime and getTime() or 0
  local t = tostring(tag or "rfsuite")
  local lvl = tostring(level or "debug")
  local m = tostring(msg or "")

  addToHistory(t, m, lvl, now)

  -- A sink writing to the card is a second consumer with a different budget, and it takes the
  -- message UNTRUNCATED. See addToSink.
  --
  -- The same test as the ring above, deliberately: gating this on emitByLevel alone would mean
  -- that at `debug_level = off` -- the state every radio ships in -- a card log came out empty,
  -- because the important levels reach the ring through the second half of that test and
  -- nothing else is emitted at all. The sink takes what the ring takes, and more when a level
  -- is chosen.
  local sink = sinkList()
  if sink then
    addToSink(sink, t, m, lvl, now)
  end

  if not emitByLevel then
    return
  end

  local emitConsole = enabled == nil or isTruthy(enabled)
  local emitSerial = type(serialWrite) == "function" and isSerialDebugEnabled()

  if not emitConsole and not emitSerial then
    return
  end

  -- The history entry already carries a timestamp and session_logs/page.lua renders it, but
  -- the console and serial line was built without one, so the same message could be read with
  -- a time on the radio and without a time everywhere else. Same clock and same format as that
  -- page, and left out when the clock is unavailable, which is what the page does too.
  local stamp = ""
  if now > 0 then
    stamp = "[" .. string.format("%0.1f", now / 100) .. "]"
  end

  local line = "[" .. t .. "][" .. lvl .. "]" .. stamp .. " " .. tostring(msg)

  if emitConsole and type(print) == "function" then
    print(line)
  end

  if emitSerial then
    pcall(serialWrite, line .. "\n")
  end
end

-- Exported so the Log Level selector on the developer settings page can offer exactly the
-- levels this module understands, instead of carrying a second list that drifts away from it.
Log.LEVELS = LEVELS

--- Would a message at this level be emitted right now?
--
-- For call sites where BUILDING the message is the expensive part -- a hex dump of a response
-- buffer is a few hundred characters that `emitf` below would still have to be handed. Those
-- sites ask first and build second.
function Log.wanted(level)
  return shouldEmitByLevel(level)
end

--- Emit, formatting only if the level passes.
--
-- The difference from Log.emit is where the string is built. `Log.emit(tag, a .. b .. c, ...)`
-- concatenates before the call, so the caller pays for a message the gate then drops -- and on
-- the MSP path that is a send and a retry apart, at `debug_level = off`, on every radio. Here
-- the caller hands over the pieces and string.format runs only on the far side of the gate.
function Log.emitf(tag, level, fmt, ...)
  if not shouldEmitByLevel(level) then
    -- The ring still wants the important levels, gate or no gate. Formatting one of those is
    -- not the cost this function exists to avoid: they are rare by definition.
    if debugLevelRank(level) <= RANK.info then
      local ok, text = pcall(string.format, fmt, ...)
      Log.emit(tag, ok and text or tostring(fmt), level, false)
    end
    return
  end

  local ok, text = pcall(string.format, fmt, ...)
  Log.emit(tag, ok and text or tostring(fmt), level)
end

--- A logger bound to one tag.
--
-- For a module that logs under a single tag: the closure carries the tag and the default
-- level, so the module states its tag once and the logging policy -- the default level,
-- the console flag, the gate -- stays in this file instead of drifting at call sites.
function Log.tagged(tag)
  return function(msg, level)
    Log.emit(tag, msg, level or "debug")
  end
end

--- A buffer as hex, for a payload line. Bounded, and it says when it truncated.
--
-- Only ever called behind Log.wanted: this allocates in proportion to the buffer and there is
-- no point paying for it on a card that is not tracing.
function Log.hex(buf, limit)
  if type(buf) ~= "string" then
    if type(buf) == "table" then
      local parts = {}
      local n = math.min(#buf, limit or #buf)
      for i = 1, n do parts[i] = string.format("%02X", (tonumber(buf[i]) or 0) % 256) end
      local text = table.concat(parts, " ")
      if #buf > n then text = text .. string.format(" ...(%d more)", #buf - n) end
      return text
    end
    return "-"
  end

  local n = #buf
  local take = limit and math.min(n, limit) or n
  local parts = {}
  for i = 1, take do parts[i] = string.format("%02X", string.byte(buf, i)) end
  local text = table.concat(parts, " ")
  if take < n then text = text .. string.format(" ...(%d more)", n - take) end
  return text
end

--- Is anybody going to read an informational line right now?
--
-- True while the level lets `info` through, or while a card sink is taking lines -- the sink
-- takes info lines at every level. A periodic line asks this first, so that with the log off
-- it neither builds its text nor pushes the ring's last sixty entries out one by one.
function Log.recording()
  if shouldEmitByLevel("info") then return true end
  return type(_G.rfsuite) == "table" and type(_G.rfsuite.log_sink) == "table"
end

--- What this Lua state and the radio have left, as one fragment of a log line.
--
-- `lua` is collectgarbage("count") of THIS state only -- the dashboard and the service widget
-- share one state, the tool started from the Tools menu and the background script each have
-- their own. `free` is getAvailableMemory(): the radio's general heap, which every Lua state and
-- most native allocations draw from, but not LVGL's own pool, which no Lua call can read. The
-- simulator answers that call with a constant 1000 bytes, so a figure under MEM_FREE_FLOOR_KB is
-- printed as "-" rather than as a measurement. `cpu` and `ui` exist from EdgeTX 2.12.5 on:
-- getCpuLoad() is the share of time the radio was not idle (nil in the simulator), and
-- lvgl.getPerf() the LVGL frame rate and the share of time spent rendering. A radio without
-- them gets a line without them.
local MEM_FREE_FLOOR_KB = 4

function Log.resources()
  local luaKb = 0
  if type(collectgarbage) == "function" then
    local ok, value = pcall(collectgarbage, "count")
    if ok and type(value) == "number" then luaKb = math.floor(value + 0.5) end
  end

  local free = "-"
  if type(getAvailableMemory) == "function" then
    local ok, bytes = pcall(getAvailableMemory)
    local kb = ok and type(bytes) == "number" and math.floor(bytes / 1024 + 0.5) or nil
    if kb and kb >= MEM_FREE_FLOOR_KB then free = tostring(kb) end
  end

  local text = string.format("lua %d kB, free %s kB", luaKb, free)

  if type(getCpuLoad) == "function" then
    local ok, load = pcall(getCpuLoad)
    if ok and type(load) == "number" then
      text = text .. string.format(", cpu %d%%", math.floor(load + 0.5))
    end
  end

  if type(lvgl) == "table" and type(lvgl.getPerf) == "function" then
    local ok, fps, load = pcall(lvgl.getPerf)
    if ok and type(fps) == "number" and type(load) == "number" then
      text = text .. string.format(", ui %d fps / %d%%", math.floor(fps + 0.5), math.floor(load + 0.5))
    end
  end

  return text
end

--- Tell the logger a card sink is taking lines, so it starts filling the sink's own list.
--
-- The list is SEEDED from the ring rather than started empty. Whatever the ring holds at this
-- moment is the part of the session that happened before anybody attached -- and on a start
-- that is the whole start-up sequence, which is when it is worth the most. Those seeded entries
-- carry the ring's truncation because that is where they were kept; everything after this call
-- does not.
function Log.attachSink()
  local sink = {}
  local history = _G.rfsuite.log_history
  if type(history) == "table" then
    for i = 1, #history do sink[i] = history[i] end
  end
  _G.rfsuite.log_sink = sink
  _G.rfsuite.log_sink_lost = 0
end

--- Stop filling it, and drop what is in it: nothing is going to read it.
function Log.detachSink()
  _G.rfsuite.log_sink = nil
  _G.rfsuite.log_sink_lost = nil
end

if type(_G) == "table" then
  _G.rfsuite = _G.rfsuite or {}
  _G.rfsuite.Log = Log
end

return Log
