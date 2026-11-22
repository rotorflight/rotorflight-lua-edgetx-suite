-- Run from the repository root: lua5.3 bin/telemetry/verify_rfsbg_errors.lua
--
-- Drives the real background function script (src/functions/rfsbg.lua) one radio cycle at a time,
-- with stand-ins for the decoder, the adjustment teller, the logger and the settings module, and
-- makes them fail. In this script state an error that leaves run() ends the script until the
-- scripts are reloaded, so every run() call here has to return.
--
-- Checked:
--   1. the decoder raising for a few cycles: run() returns, the decoder is called again on the next
--      cycle, nothing is published as decoding while it raises, one warn line names it with the
--      error, and one info line says it runs again;
--   2. the teller raising: run() returns, the decoder still decodes in the same cycle, one warn line;
--   3. the rest of the pass raising (here the state line's logger): run() returns, the decoder still
--      decodes on every cycle, one warn line, one info line on recovery;
--   4. the decoder not loading on the first pass, as a file that is not there, as a chunk that
--      raises while it runs and as the radio's loadScript raising: it is asked for again at most once
--      a second, decodes once it loads, and the failure and the recovery are logged once each;
--   5. no logger at all and every step raising: run() still returns;
--   6. nothing failing: no warn line, frames published as decoded on every cycle;
--   7. the start raising (the radio's loadScript raising for the module loader, before the logger is
--      there): run() returns, the start runs again on the next cycle and goes through, and decodes.
local checks, failures = 0, 0
local function check(ok, label, detail)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label .. (detail and (": " .. tostring(detail)) or ""))
  end
end

local CORE = "/SCRIPTS/RFSUITE/core/"
local DRAIN = "tasks/events/telemetry_bg/drain.lua"
local TELLER = "tasks/events/telemetry_bg/adjustments.lua"
local CYCLE = 10 -- getTime() ticks (10 ms each) between two run() calls: 0.1 s

-- One script, fresh, over its own stand-ins. `o` says what fails:
--   drainLoadFails = n   the first n loads of the decoder fail
--   drainLoadRaises      ...as a chunk that raises rather than a file that is missing
--   loadScriptRaises = n the first n loadScript calls for the decoder raise
--   requireRaises = n    the first n loadScript calls for the module loader raise (init() makes that
--                        call itself, unguarded, so the error leaves init())
--   noLog                the logger does not load
--   teller               adjustment announcements are on, so the teller is loaded
local function newScript(o)
  o = o or {}
  local h = { clock = 1000, lines = {}, loads = {}, wakeups = 0, liveness = 0, tells = 0,
    drainRaise = false, tellerRaise = false, recordingRaise = false }

  local Log = {
    emitf = function(tag, level, fmt, ...)
      h.lines[#h.lines + 1] = { tag = tag, level = level, text = string.format(fmt, ...) }
    end,
    emit = function(tag, msg, level)
      h.lines[#h.lines + 1] = { tag = tag, level = level, text = msg }
    end,
    wanted = function() return false end,
    recording = function()
      if h.recordingRaise then error("simulated: not enough memory") end
      return false
    end,
    resources = function() return "heap -" end,
  }
  local drain = {
    wakeup = function()
      h.wakeups = h.wakeups + 1
      if h.drainRaise then error("simulated: not enough memory") end
      return 2
    end,
    publishLiveness = function() h.liveness = h.liveness + 1 end,
    summary = function() return "decoder -" end,
  }
  local teller = {
    wakeup = function()
      h.tells = h.tells + 1
      if h.tellerRaise then error("simulated: teller failed") end
    end,
  }
  local prefs = { general = {}, audio_events = { adjustment_events = o.teller == true } }

  local env = setmetatable({}, { __index = _G })
  env._G = env
  env.getTime = function() return h.clock end
  env.loadScript = function(path)
    local rel = string.match(path, "^" .. CORE .. "(.+)$")
    assert(rel, "unexpected script path: " .. tostring(path))
    h.loads[rel] = (h.loads[rel] or 0) + 1
    if rel == "lib/require.lua" then
      if o.requireRaises and h.loads[rel] <= o.requireRaises then error("simulated: not enough memory") end
      return function() end
    end
    if rel == "lib/log.lua" then
      if o.noLog then return nil end
      return function() return Log end
    end
    if rel == "lib/preferences.lua" then
      return function() return { load = function() return prefs, true end } end
    end
    if rel == DRAIN then
      if o.loadScriptRaises and h.loads[rel] <= o.loadScriptRaises then error("simulated: not enough memory") end
      if o.drainLoadFails and h.loads[rel] <= o.drainLoadFails then
        if o.drainLoadRaises then return function() error("simulated: chunk raised") end end
        return nil
      end
      return function() return drain end
    end
    if rel == TELLER then return function() return teller end end
    return nil -- every other module: not there, which the script already allows for
  end

  local chunk = assert(loadfile("src/functions/rfsbg.lua", "t", env))
  local script = chunk()
  h.run = function()
    local ok, err = pcall(script.run)
    h.clock = h.clock + CYCLE
    return ok, err
  end
  h.count = function(level, pattern)
    local n = 0
    for _, l in ipairs(h.lines) do
      if l.level == level and string.find(l.text, pattern, 1, true) then n = n + 1 end
    end
    return n
  end
  return h
end

local function runAll(h, n, label)
  for i = 1, n do
    local ok, err = h.run()
    check(ok, label .. ": run() returned on cycle " .. i, err)
  end
end

-- 1. the decoder raising for three cycles
do
  local h = newScript()
  runAll(h, 3, "decoder raises")            -- init, then two good cycles
  local w0, l0 = h.wakeups, h.liveness
  check(w0 == 2 and l0 == 2, "decoder raises: two good cycles decoded before", w0 .. "/" .. l0)
  h.drainRaise = true
  runAll(h, 3, "decoder raises")
  check(h.wakeups == w0 + 3, "decoder raises: called again on every cycle", h.wakeups - w0)
  check(h.liveness == l0, "decoder raises: nothing published as decoding while it raises", h.liveness - l0)
  check(h.count("warn", "background decoder failed") == 1, "decoder raises: one warn line")
  check(h.count("warn", "not enough memory") == 1, "decoder raises: the warn line carries the error")
  h.drainRaise = false
  runAll(h, 3, "decoder raises")
  check(h.liveness == l0 + 3, "decoder raises: published again once it decodes", h.liveness - l0)
  check(h.count("info", "background decoder recovered after 3 failure(s)") == 1,
    "decoder raises: one recovery line with the count")
  check(h.count("warn", "background decoder failed") == 1, "decoder raises: still one warn line")
  -- a second streak is logged again
  h.drainRaise = true
  runAll(h, 1, "decoder raises again")
  check(h.count("warn", "background decoder failed") == 2, "decoder raises: a new streak is logged again")
end

-- 2. the teller raising
do
  local h = newScript({ teller = true })
  runAll(h, 3, "teller raises")             -- init; the next cycle loads the teller
  h.tellerRaise = true
  local w0 = h.wakeups
  runAll(h, 4, "teller raises")
  check(h.tells >= 4, "teller raises: called again on every cycle", h.tells)
  check(h.wakeups == w0 + 4, "teller raises: the decoder still decodes", h.wakeups - w0)
  check(h.count("warn", "background teller failed") == 1, "teller raises: one warn line")
  h.tellerRaise = false
  runAll(h, 1, "teller raises")
  check(h.count("info", "background teller recovered") == 1, "teller raises: one recovery line")
end

-- 3. the rest of the pass raising
do
  local h = newScript()
  runAll(h, 2, "pass raises")
  h.recordingRaise = true
  local w0 = h.wakeups
  runAll(h, 5, "pass raises")
  check(h.wakeups == w0 + 5, "pass raises: the decoder still decodes on every cycle", h.wakeups - w0)
  check(h.count("warn", "background pass failed") == 1, "pass raises: one warn line")
  h.recordingRaise = false
  runAll(h, 1, "pass raises")
  check(h.count("info", "background pass recovered after 5 failure(s)") == 1, "pass raises: one recovery line")
end

-- 4. the decoder not loading on the first pass: missing, and a chunk that raises
for _, how in ipairs({ "missing", "chunk raises", "loadScript raises" }) do
  local label = "decoder load " .. how
  local h = newScript(how == "loadScript raises" and { loadScriptRaises = 4 }
    or { drainLoadFails = 4, drainLoadRaises = how == "chunk raises" })
  runAll(h, 21, label)                       -- 2 s: init plus one ask a second
  check(h.loads[DRAIN] == 3, label .. ": asked for at most once a second", h.loads[DRAIN])
  check(h.wakeups == 0, label .. ": nothing decoded while it does not load", h.wakeups)
  check(h.count("warn", "background decoder load failed") == 1, label .. ": one warn line")
  runAll(h, 25, label)                       -- the fifth load succeeds
  check(h.loads[DRAIN] == 5, label .. ": loaded once it can be, then not asked for again", h.loads[DRAIN])
  check(h.wakeups > 0 and h.liveness == h.wakeups, label .. ": decodes once loaded", h.wakeups)
  check(h.count("info", "background decoder load recovered after 4 failure(s)") == 1, label .. ": one recovery line")
  check(h.count("warn", "background decoder load failed") == 1, label .. ": still one warn line")
end

-- 5. no logger, everything raising
do
  local h = newScript({ noLog = true, teller = true })
  runAll(h, 3, "no logger")             -- init; the next cycle loads the teller
  check(h.tells >= 1, "no logger: the teller runs before the failures", h.tells)
  local w0, t0 = h.wakeups, h.tells
  h.drainRaise, h.tellerRaise = true, true
  runAll(h, 5, "no logger")
  check(h.wakeups == w0 + 5, "no logger: the decoder is called on every cycle", h.wakeups - w0)
  check(h.tells == t0 + 5, "no logger: the teller is called on every cycle", h.tells - t0)
  check(#h.lines == 0, "no logger: nothing written anywhere", #h.lines)
end

-- 6. nothing failing
do
  local h = newScript()
  runAll(h, 11, "clean")
  check(h.wakeups == 10 and h.liveness == 10, "clean: decoded and published on every cycle",
    h.wakeups .. "/" .. h.liveness)
  check(h.count("warn", "") == 0, "clean: no warn line")
  check(h.loads[DRAIN] == 1, "clean: the decoder is loaded once", h.loads[DRAIN])
end

-- 7. the start raising
do
  local h = newScript({ requireRaises = 1 })
  runAll(h, 1, "start raises")
  check(h.wakeups == 0 and (h.loads[DRAIN] or 0) == 0, "start raises: the failed start went no further",
    tostring(h.loads[DRAIN]))
  runAll(h, 1, "start raises")              -- the start again, and through
  check(h.loads["lib/require.lua"] == 2 and h.loads[DRAIN] == 1, "start raises: the start ran again",
    tostring(h.loads["lib/require.lua"]) .. "/" .. tostring(h.loads[DRAIN]))
  check(h.count("warn", "") == 0, "start raises: no line, there was no logger when it failed")
  runAll(h, 3, "start raises")
  check(h.wakeups == 3 and h.liveness == 3, "start raises: decodes after the start went through",
    h.wakeups .. "/" .. h.liveness)
end

print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
