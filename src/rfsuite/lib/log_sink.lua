-- Writes the in-memory log ring to the SD card so a session can be read after the fact.
--
-- lib/log.lua keeps the last MAX_HISTORY entries in _G.rfsuite.log_history and
-- app/pages/tools/diagnostics/session_logs/page.lua renders them, but the ring is a state
-- global: it dies with the Lua state that holds it. Whatever the suite was doing when it
-- stopped responding, ran out of memory or was killed for exceeding its CPU budget is exactly
-- the part that is gone by the time anybody can look at the page.
--
-- Two files, because the Lua io library can only make one of the two promises:
--
--   * the SESSION FILE holds the ring and is written on a cadence. io.close is the only call
--     that reaches the card -- the library registers open/read/write/seek/close and no flush --
--     so "write out the pending lines" means open in append mode, write, close. That is cheap
--     at a few seconds apart and its honest promise is a loss window of one cadence, never
--     crash safety.
--
--   * the STEP FILE holds one line naming the last thing that was started, and is rewritten in
--     place at every step. It survives what the session file cannot, because it is closed
--     immediately; it stays affordable because it is truncated on every open and never grows
--     past one line, so there is no cluster chain for the filesystem to walk.
--
-- Read together they answer the question a frozen radio poses: the session file says what led
-- up to it, the step file says what was being done when it stopped.
--
-- One sink per Lua state. The suite runs in three -- the tool in its own, the dashboard widget
-- and the service widget sharing another, and the background decoder's special function in the
-- radio's script state -- and each holds a ring of its own, so each names its own pair of files
-- instead of three writers appending to one path.
--
-- The third one is the only one that keeps running when the widgets do not. A widget whose pass
-- overruns its instruction budget is not called again, so it cannot write down that it stopped;
-- the script state is yielded rather than cut off, and its step file's timestamp is what says
-- how far a radio got.
--
-- Every file of one RUN -- one power-up of the radio -- carries the same prefix, the moment the
-- radio was switched on: `2026-10-29_10-15-03_dashboard.log`, `..._tool.log`, `..._function.log`
-- and a `.step` beside each. Read side by side they are one story, and all three keep time from
-- the same getTime() clock, so their lines interleave by their first column. No state has to ask
-- another for the prefix: each one works it out as the wall clock minus the time since power-up,
-- which comes out the same in all of them, and `current.run` keeps the first answer so a second
-- of rounding cannot split one run across two prefixes. The tool started again later in the
-- same run appends to the same file, under a header line of its own.

local Sink = {}

local ROOT = _G.rfsuite.paths.user
local DIR = ROOT .. "/logs"
local RUN_FILE = DIR .. "/current.run"
local BUILD_FILE = _G.rfsuite.paths.core .. "/build.txt"

-- Bounds, and what each one bounds.
local DEFAULT_RUNS = 10      -- card space: how many runs' files are kept, unless the pilot says
local MIN_RUNS = 1
local MAX_RUNS = 50
local MAX_FILE_LINES = 5000  -- growth of one session -- one start of the state -- in its file
local STEP_MIN_INTERVAL = 0.25 -- seconds between step writes of one kind, unless forced
local STEP_KEYS_MAX = 16     -- how many kinds of step the throttle remembers before it forgets all

-- Two prefixes worked out within this many seconds of each other are the same power-up. The two
-- clocks are read a few instructions apart and each has a resolution of a second, so the answers
-- of two states differ by a second or two at most; two power-ups this close do not happen.
local RUN_TOLERANCE_SECONDS = 5

-- How long the pending lines may sit in the ring before they are written out. Longer while the
-- model is armed: appends are small, but a flight is the worst moment to ask the card for
-- anything, and the ring holds enough to bridge the gap.
local FLUSH_INTERVAL = 3.0
local FLUSH_INTERVAL_ARMED = 10.0

-- How many held lines one tick formats and writes. Formatting is the Lua cost of a write -- about
-- forty instructions a line -- and it is billed to whichever widget pass ticks the sink, so a full
-- list of SINK_MAX lines in one call would take most of that pass. A longer backlog goes out one
-- batch per tick instead, on the ticks that follow.
local FLUSH_BATCH_LINES = 50

local function nowSeconds()
  if type(getTime) ~= "function" then return 0 end
  local ok, value = pcall(getTime)
  if ok and type(value) == "number" then return value / 100 end
  return 0
end

local function preferences()
  if type(_G) ~= "table" or type(_G.rfsuite) ~= "table" then return nil end
  local prefs = _G.rfsuite.preferences
  return type(prefs) == "table" and prefs.general or nil
end

local function isEnabled()
  local general = preferences()
  return type(general) == "table" and general.log_to_card == true
end

local function logModule()
  if type(_G) ~= "table" or type(_G.rfsuite) ~= "table" then return nil end
  local mod = _G.rfsuite.Log
  return type(mod) == "table" and mod or nil
end

-- The list this drains is the logger's SINK list, not the ring behind the Session Logs page.
-- The ring is that page's budget -- sixty entries capped at a hundred characters -- and a
-- payload line is longer than the cap by itself, while a trace fills sixty entries in well
-- under a second. lib/log.lua fills the sink list only while one is attached, untruncated.
local function ring()
  if type(_G) ~= "table" or type(_G.rfsuite) ~= "table" then return nil, 0 end
  local list = _G.rfsuite.log_sink
  if type(list) ~= "table" then return nil, 0 end
  return list, tonumber(_G.rfsuite.log_sink_seq) or 0
end

-- Everything that touches the card goes through these two, so a card that is missing, full or
-- write protected degrades to "no log" instead of taking the caller down with it.
local function writeFile(path, mode, text)
  local ok, handle = pcall(io.open, path, mode)
  if not ok or not handle then return false end
  local okWrite, res = pcall(io.write, handle, text)
  pcall(io.close, handle)
  return okWrite and res ~= nil and res ~= false
end

local function readFile(path)
  local ok, handle = pcall(io.open, path, "r")
  if not ok or not handle then return nil end
  local okRead, text = pcall(io.read, handle, 64)
  pcall(io.close, handle)
  if okRead then return text end
  return nil
end

-- `mkdir` is a bare global, not `os.mkdir`. EdgeTX registers the filesystem library flat in the
-- global namespace -- `dir`, `fstat`, `del`, `chdir`, `mkdir`, `rename`, the same way this suite
-- already reaches `fstat` in src/widgets/rfsuite/main.lua -- and there is no `os` table in the
-- interpreter at all. It returns an FRESULT: 0 is success and 8 is "already exists", so nothing
-- here has to tell the two apart. Introduced in 2.11, which is the floor this suite already
-- requires for LVGL.
local function ensureDir()
  if type(mkdir) ~= "function" then return end
  pcall(mkdir, ROOT)
  pcall(mkdir, DIR)
end

local function integer(value)
  if type(value) ~= "number" then return nil end
  return math.tointeger(math.floor(value))
end

-- The wall clock as seconds since 1970, or nil where the radio cannot say. getRtcTime() answers
-- that directly; the fallback is lib/change_journal.lua's days-from-civil over getDateTime().
-- Integer arithmetic throughout: on a radio a float holds seconds at today's dates only to the
-- nearest few minutes.
local function wallSeconds()
  if type(getRtcTime) == "function" then
    local ok, value = pcall(getRtcTime)
    local seconds = ok and integer(value) or nil
    if seconds and seconds > 0 then return seconds end
  end
  if type(getDateTime) ~= "function" then return nil end
  local ok, dt = pcall(getDateTime)
  if not ok or type(dt) ~= "table" then return nil end
  local y, m, d = integer(dt.year), integer(dt.mon), integer(dt.day)
  local h, mi, s = integer(dt.hour), integer(dt.min), integer(dt.sec)
  if not (y and m and d and h and mi and s) or y < 1970 or y > 2037 or m < 1 or m > 12 then return nil end
  if m <= 2 then y = y - 1 end
  local era = y // 400
  local yoe = y - era * 400
  local doy = (153 * (m + (m > 2 and -3 or 9)) + 2) // 5 + d - 1
  local days = era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
  return days * 86400 + h * 3600 + mi * 60 + s
end

-- Seconds since 1970 back to `YYYY-MM-DD_HH-MM-SS` (civil-from-days), the shape a file manager
-- sorts in time order.
local function stampText(seconds)
  local days = seconds // 86400
  local rest = seconds - days * 86400
  local z = days + 719468
  local era = z // 146097
  local doe = z - era * 146097
  local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
  local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
  local mp = (5 * doy + 2) // 153
  local d = doy - (153 * mp + 2) // 5 + 1
  local m = mp + (mp < 10 and 3 or -9)
  local y = yoe + era * 400 + (m <= 2 and 1 or 0)
  return string.format("%04d-%02d-%02d_%02d-%02d-%02d",
    y, m, d, rest // 3600, (rest % 3600) // 60, rest % 60)
end

-- When this power-up began, in seconds since 1970: the wall clock less the time the radio has
-- been on. getTime() counts 10 ms ticks from power-up and is the clock every line is stamped with.
local function runStart()
  local wall = wallSeconds()
  if not wall or type(getTime) ~= "function" then return nil end
  local ok, ticks = pcall(getTime)
  ticks = ok and integer(ticks) or nil
  if not ticks then return nil end
  return wall - ticks // 100
end

local function runsToKeep()
  local general = preferences()
  local value = type(general) == "table" and integer(tonumber(general.log_runs)) or nil
  if not value then return DEFAULT_RUNS end
  if value < MIN_RUNS then return MIN_RUNS end
  if value > MAX_RUNS then return MAX_RUNS end
  return value
end

-- Delete the files of every run but the newest `keep`, the current one included. Only names in
-- this sink's own scheme are touched -- `<prefix>_<state>.log` and `.step` -- so a file the pilot
-- or an older release put into the folder stays where it is. Runs once per power-up, by whichever
-- state starts the run, and walks one directory of a few dozen names. `current` counts as one of
-- the kept runs although nothing of it is on the card yet: its first file is written after this.
local function pruneRuns(keep, current)
  if type(dir) ~= "function" or type(del) ~= "function" then return end
  local okDir, iterator = pcall(dir, DIR)
  if not okDir or type(iterator) ~= "function" then return end

  local files, prefixes, seen = {}, { current }, { [current] = true }
  for name in iterator do
    local prefix = type(name) == "string"
      and string.match(name, "^(%d%d%d%d%-%d%d%-%d%d_%d%d%-%d%d%-%d%d)_%a+%.%a+$") or nil
    if prefix then
      files[#files + 1] = { name = name, prefix = prefix }
      if not seen[prefix] then
        seen[prefix] = true
        prefixes[#prefixes + 1] = prefix
      end
    end
  end
  if #prefixes <= keep then return end

  table.sort(prefixes)
  local drop = {}
  for i = 1, #prefixes - keep do drop[prefixes[i]] = true end
  for i = 1, #files do
    if drop[files[i].prefix] then pcall(del, DIR .. "/" .. files[i].name) end
  end
end

-- The prefix of this power-up's files. The first state to ask writes it down; a state asking
-- later in the same run finds it and takes it as it stands, so two states never disagree about a
-- second. A radio that cannot tell the time gets the prefix of the clock's zero, which still
-- keeps the run's files together and still sorts.
local function resolveRun()
  local start = runStart()
  local text = readFile(RUN_FILE)
  if type(text) == "string" then
    local storedStart, storedPrefix = string.match(text, "^(%-?%d+) (%S+)")
    storedStart = tonumber(storedStart)
    if start and storedStart and math.abs(start - storedStart) <= RUN_TOLERANCE_SECONDS then
      return storedPrefix
    end
  end

  local prefix = stampText(start or 0)
  writeFile(RUN_FILE, "w", tostring(start or 0) .. " " .. prefix .. "\n")
  pruneRuns(runsToKeep(), prefix)
  return prefix
end

local function buildIdentity()
  local text = readFile(BUILD_FILE)
  return type(text) == "string" and string.match(text, "^(%S+)") or nil
end

local function languageName()
  local i18n = type(_G.rfsuite) == "table" and _G.rfsuite.i18n or nil
  if type(i18n) == "table" and type(i18n.getLocale) == "function" then
    local ok, lang = pcall(i18n.getLocale)
    if ok and type(lang) == "string" and lang ~= "" then return lang end
  end
  local general = preferences()
  local lang = type(general) == "table" and general.language or nil
  return type(lang) == "string" and lang ~= "" and lang or nil
end

-- Which radio, which build and which run wrote the file. A layout or a memory question is
-- unanswerable without it, and a log without it cannot be told from one written on a different
-- transmitter or by a different build. Written at the start of every session, so a file the tool
-- appended to twice in one run carries the line twice, each where its session begins.
local function headerLine(name, run)
  local parts = { "-- rfsuite diagnostics log", "state=" .. tostring(name), "run=" .. tostring(run) }

  local wall = wallSeconds()
  if wall then parts[#parts + 1] = "started=" .. stampText(wall) end
  if type(getTime) == "function" then
    local ok, ticks = pcall(getTime)
    if ok and type(ticks) == "number" then parts[#parts + 1] = string.format("uptime=%.1f", ticks / 100) end
  end

  local w = tonumber(LCD_W)
  local h = tonumber(LCD_H)
  if w and h then parts[#parts + 1] = "lcd=" .. tostring(w) .. "x" .. tostring(h) end

  if type(getVersion) == "function" then
    local ok, version, radio = pcall(getVersion)
    if ok then
      if type(version) == "string" then parts[#parts + 1] = "fw=" .. version end
      if type(radio) == "string" then parts[#parts + 1] = "radio=" .. radio end
    end
  end

  -- Which release wrote the file, taken from lib/version.lua. This read used to go to
  -- `_G.rfsuite.config.version`, and nothing in the tree ever sets `_G.rfsuite.config`, so the
  -- field was silently absent from every log ever written -- and a log that cannot say which
  -- version produced it answers no question that depends on the code having changed. The module
  -- is a table of constants and is asked for once, on the path that builds this line.
  if type(_G) == "table" and type(_G.rfsuite) == "table" and type(_G.rfsuite.require) == "function" then
    local ok, Version = pcall(_G.rfsuite.require, "lib/version.lua")
    if ok and type(Version) == "table" and type(Version.VERSION) == "string" then
      parts[#parts + 1] = "suite=" .. Version.VERSION
    end
  end

  -- The version is too coarse to name a build: every development build between two releases
  -- carries the same one. The packager's identity (bin/package/build_package.py,
  -- write_build_identity) is a digest of the packaged sources, so it differs whenever they do.
  local build = buildIdentity()
  if build then parts[#parts + 1] = "build=" .. build end

  local lang = languageName()
  if lang then parts[#parts + 1] = "lang=" .. lang end

  return table.concat(parts, " ") .. "\n"
end

local function formatEntry(entry)
  local seconds = (tonumber(entry.time) or 0) / 100
  -- The same clock and the same shape session_logs/page.lua puts in front of a line, so a file
  -- and the page read alike.
  return string.format("[%0.1f][%s][%s] %s\n",
    seconds, tostring(entry.tag or "rfsuite"), tostring(entry.level or "debug"), tostring(entry.msg or ""))
end

local state = nil

-- The watermark starts at zero and needs no carrying between sessions. The list this drains is
-- created by Log.attachSink and dropped by Log.detachSink, so a second session in the same Lua
-- state gets a fresh one -- and attachSink seeds it from the ring, so the lines that were
-- emitted before anybody attached are in it rather than lost. An earlier version of this kept a
-- watermark across sessions for that reason; with a list of its own there is nothing to carry.

local function startSession()
  -- Ask the logger to start filling the sink list BEFORE the watermark below is taken, or the
  -- first lines of the session are counted as pending without ever having been stored.
  local Log = logModule()
  if Log and type(Log.attachSink) == "function" then
    Log.attachSink()
  end

  ensureDir()
  local name = Sink.name or "state"
  local run = resolveRun()
  local base = DIR .. "/" .. run .. "_" .. name

  state = {
    path = base .. ".log",
    -- The header is HELD rather than written. A Lua state that has nothing to say should leave
    -- no file behind: an empty one is noise on the card, and it makes a pilot ask why a state
    -- they did not think was running has a log of its own. The first thing that actually has to
    -- be written appends it to the file -- at its top for the first session of the run, as the
    -- start of the next one for a tool opened again.
    pendingHeader = headerLine(name, run),
    stepPath = base .. ".step",
    lines = 0,
    capped = false,
    lastFlush = nowSeconds(),
    -- The first write is not made to wait for the interval. Whatever is already in the ring
    -- when a session opens is the start-up sequence, and a start is one of the things this
    -- exists to explain -- there is no point holding it back for three seconds.
    firstFlushDone = false,
    -- True while a backlog longer than one batch is being written out, one batch per tick. Only
    -- a write that reached the card sets it, so a card that refuses is asked once an interval.
    draining = false,
    -- When each kind of step was last written. One remembered kind was not enough: two callers
    -- with different kinds that alternate -- the event runner and the dashboard's job pass during
    -- the connect sequence -- each found the other's kind and rewrote the file on every call.
    stepAt = {},
    stepKeys = 0,
    stepCount = 0
  }
  return true
end

local function endSession()
  state = nil
  -- Nothing is going to read it now, and a list that keeps filling with nobody draining it is
  -- the diagnostic becoming the problem.
  local Log = logModule()
  if Log and type(Log.detachSink) == "function" then
    Log.detachSink()
  end
end

-- Take everything the ring has gained since the last call and hand it back as one string.
--
-- log_history_seq counts insertions and the ring drops its oldest entry when it is full, so the
-- difference between the two is data that existed and was overwritten before it could be
-- written out. A gap that does not announce itself makes every later reading of the file wrong,
-- so it is counted and it goes into the file.
-- The watermark is NOT advanced here. A write that fails must not take the lines with it, so
-- the caller commits it once the bytes are on the card.
-- Everything the logger has buffered since the last write, as one string -- and the list is NOT
-- emptied here. The caller clears it once the bytes are on the card, so a write that fails
-- leaves the lines where they are instead of taking them with it.
--
-- Draining rather than keeping a watermark is what bounds the memory: the list holds one flush
-- interval, not a cap's worth. Measured, a retained entry of a payload line is about 340 bytes,
-- so keeping two thousand of them would have been two thirds of a small radio's whole Lua
-- budget -- for lines that had already been written.
--
-- `limit` takes only the oldest that many entries; the rest keep their place for the next call.
-- Without it, everything held is taken.
local function pendingText(limit)
  local list = ring()
  if not list then return nil end

  local held = #list
  local lost = tonumber(_G.rfsuite.log_sink_lost) or 0
  if held == 0 and lost == 0 then return nil end

  local take = held
  if limit and take > limit then take = limit end

  local parts = {}
  if lost > 0 then
    parts[#parts + 1] = string.format("[----][rfsuite.log][warn] %d line(s) lost (buffer overflow before flush)\n", lost)
  end
  for index = 1, take do
    local entry = list[index]
    if type(entry) == "table" then
      parts[#parts + 1] = formatEntry(entry)
    end
  end

  if #parts == 0 then return nil end
  return table.concat(parts), #parts, take
end

--- Called only once the bytes are on the card: drop what was written, and only that much.
--
-- `written` is the count this flush took. Anything the logger appended while the write was in
-- progress keeps its place, which is why this removes from the front rather than emptying. One
-- move and a tail clear rather than table.remove(list, 1) per line, which shifts every remaining
-- entry down on each call.
local function commit(written)
  local list = ring()
  if not list then return end
  local held = #list
  local count = math.min(written or 0, held)
  table.move(list, count + 1, held, 1)
  for index = held - count + 1, held do
    list[index] = nil
  end
  _G.rfsuite.log_sink_lost = 0
end

-- Put the held header into the file the first time anything has to go into it. `a` creates the
-- file for the first session of a run and appends to it for a later one, so a tool opened twice
-- in one run leaves one file with two sessions in it rather than overwriting the first.
local function openIfNeeded()
  if not state.pendingHeader then return true end
  if not writeFile(state.path, "a", state.pendingHeader) then
    return false
  end
  state.pendingHeader = nil
  return true
end

-- Write out at most `limit` held lines, or all of them without one. Returns true only when the
-- write reached the card and more than `limit` lines are still held -- the one case in which the
-- next tick should not wait for the interval.
--
-- `extra` is one more line written after the held ones -- a fault's own line. It goes through
-- the same count and the same cap as everything else, so no caller can grow the file past it.
local function flush(limit, extra)
  if state.capped then return false end

  local text, count, seq = pendingText(limit)
  if extra then
    text = (text or "") .. extra
    count = (count or 0) + 1
  end
  if not text then return false end
  if not openIfNeeded() then return false end

  if state.lines + count > MAX_FILE_LINES then
    -- Stop rather than truncate in place: a file that keeps its beginning and says where it
    -- stopped can be read, one that silently drops its middle cannot.
    if writeFile(state.path, "a", text .. "[----][rfsuite.log][warn] session file cap reached, logging to card stopped\n") and seq then
      commit(seq)
    end
    state.capped = true
    -- Nothing will be written to this file again, so the logger stops filling the list. Left
    -- attached, it would sit at its overflow guard for the rest of the session, held in this Lua
    -- state for nobody. The session itself stays, capped, so the next tick does not open a new
    -- file; turning the option off and on again is what starts one.
    local Log = logModule()
    if Log and type(Log.detachSink) == "function" then
      Log.detachSink()
    end
    return false
  end

  if not writeFile(state.path, "a", text) then return false end
  if seq then commit(seq) end
  state.lines = state.lines + count

  local list = ring()
  return limit ~= nil and list ~= nil and #list > limit
end

-- Bring the session up on whichever call comes first. The tick is the usual one, but a step or
-- a fault can arrive before it -- and the first build of a screen is exactly the moment worth
-- having on the card.
local function ensureSession()
  if state then return true end
  if not isEnabled() then return false end
  return startSession()
end

--- Name this state's files. The first name given in a Lua state is the one it keeps.
--
-- The module is one instance per state, and more than one caller in a state names it: the
-- dashboard and the service widget, and the configuration tool when it is opened from the
-- dashboard and runs in the dashboard's state. A later name used to win, so a tool opened from
-- the dashboard turned the dashboard's files into `tool` files for the rest of the run.
function Sink.configure(name)
  if Sink.name == nil then
    Sink.name = tostring(name or "state")
  end
end

--- Advance the sink. Cheap and silent while the option is off, which is its shipped state.
--
-- `armed` only lengthens the interval; it never stops the writing. A flight is when a log is
-- worth the most, and the appends are small enough to keep making them.
--
-- A tick writes at most FLUSH_BATCH_LINES. While a longer backlog is going out the interval is
-- not waited for, so it drains one batch per tick; after a write that failed it is, so a card
-- that refuses the file is asked once an interval rather than on every tick.
function Sink.tick(armed)
  if not isEnabled() then
    if state then endSession() end
    return
  end

  if not ensureSession() then return end

  local now = nowSeconds()
  local interval = armed and FLUSH_INTERVAL_ARMED or FLUSH_INTERVAL
  if state.firstFlushDone and not state.draining and (now - state.lastFlush) < interval then return end
  state.firstFlushDone = true
  state.lastFlush = now
  state.draining = flush(FLUSH_BATCH_LINES)
end

--- Record what is being started, in a file that is closed again immediately.
--
-- This is the half that survives a stop with no return: the session file's pending lines are
-- still in memory when the state freezes, this line is on the card. Keep the label short and
-- keep it a fact -- it is read next to a radio that is not responding.
--- `key` groups steps that are the SAME KIND for throttling purposes, and defaults to the label.
--
-- It exists because "a label that differs is news" is defeated by any label carrying a counter:
-- a progress line like `precompile 47/312` is new on every single call, so the interval never
-- applies and the file is rewritten as fast as the caller loops. Measured on a card: 870 writes
-- in a minute, which is the shape of exactly the defect this feature must not become. A caller
-- with a counter passes a constant key, keeps the count in the label, and is throttled like
-- anything else -- the file still says where the pass is, just not more often than the interval.
function Sink.step(label, force, key)
  if not ensureSession() then return end

  local text = tostring(label)
  local group = tostring(key or text)
  local now = nowSeconds()
  -- The interval throttles each kind of step on its own clock, so a caller repeating itself is
  -- held back however many other kinds arrive in between, and a new kind is written at once.
  local last = state.stepAt[group]
  if not force and last and (now - last) < STEP_MIN_INTERVAL then
    return
  end
  if not last then
    -- A caller whose labels are all new keys would grow this table for the whole session; past a
    -- handful of kinds it starts over, which costs at most one extra write per kind.
    if state.stepKeys >= STEP_KEYS_MAX then
      state.stepAt = {}
      state.stepKeys = 0
    end
    state.stepKeys = state.stepKeys + 1
  end
  state.stepAt[group] = now
  state.stepCount = state.stepCount + 1

  local memKb = 0
  if type(collectgarbage) == "function" then
    local ok, value = pcall(collectgarbage, "count")
    if ok and type(value) == "number" then memKb = math.floor(value + 0.5) end
  end

  writeFile(state.stepPath, "w", string.format("[%0.1f] #%d %s lua_kb=%d\n",
    now, state.stepCount, text, memKb))
end

--- A fault the caller has caught, written out before anything else is attempted.
--
-- Called from the places that already hold the error string. The forced flush is the point:
-- what led to the fault is in the ring, and a state that has just raised may not get another
-- tick.
--
-- The session file's cap holds here too. A fault can repeat on every pass, so a write that
-- bypassed the count would grow the file without bound; past the cap the step file above is
-- where the fault is recorded.
function Sink.fault(context, err)
  if not ensureSession() then return end
  Sink.step("fault: " .. tostring(context), true)

  -- A fault is reason enough to create the file even if nothing else has been written yet;
  -- flush opens it with the extra line alone when nothing is held.
  flush(nil, string.format("[%0.1f][rfsuite.fault][error] %s: %s\n",
    nowSeconds(), tostring(context), tostring(err)))
end

--- True if the error is an EdgeTX CPU-limit kill.
function Sink.isCpuLimitError(err)
  return type(err) == "string" and string.find(err, "CPU limit", 1, true) ~= nil
end

--- Last chance to write, on a shutdown the caller controls.
function Sink.shutdown()
  if not state then return end
  flush()
  endSession()
end

-- Published so any file can leave a step without taking a dependency on this module, the same
-- way lib/log.lua publishes itself. The step file is the only thing that survives a call which
-- never returns, so the places that most need to write one -- a task being started, a page being
-- built -- are exactly the leaf files that should not be loading modules.
if type(_G) == "table" then
  _G.rfsuite = _G.rfsuite or {}
  _G.rfsuite.logStep = function(label, force, key)
    return Sink.step(label, force, key)
  end
  _G.rfsuite.logFault = function(context, err)
    return Sink.fault(context, err)
  end
  _G.rfsuite.isCpuLimitError = function(err)
    return Sink.isCpuLimitError(err)
  end
end

return Sink
