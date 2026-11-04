-- Run from the repository root: lua5.3 bin/telemetry/verify_adjustment_teller_source.lua
--
-- Drives the adjustment teller the way both of its hosts run it: the background function script
-- (src/functions/rfsbg.lua) and the widget's telemetry pass (tasks/events/telemetry_bg/tasks.lua),
-- each with the real drain, the real decoder table and the real teller. Frames go in through
-- crossfireTelemetryPop(); what comes out is what the teller hands to the audio module.
--
-- Stand-ins, and only these: the EdgeTX calls, the audio module (it records what would be spoken),
-- the preferences module (it answers the table the case sets), and the SmartFuel task, which the
-- widget pass loads beside the teller and which has nothing to do with it.
--
-- What it asserts:
--   * the teller announces an adjustment from the decoded frames, also on a radio whose sensor
--     list has no AdjF/AdjV rows, and reads neither of them with getValue();
--   * with adjustment announcements off, neither host loads the teller; switched on, it is loaded
--     and joins a report already standing rather than announcing it;
--   * the first-reading join, the 0 between adjustments, the 1.0 s settle and the step-aside
--     reset behave as before -- also at the flight controller's real cadence, where an unchanged
--     ADJ row comes only every 3 s: a teller loaded or reset in between still knows the last 0;
--   * the function script asks again, once a second, for a teller that did not load.
-- Exit status: 0 green, 1 a FAIL line was printed.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]telemetry$") or (dir .. "/../..") end
end

local checks, failures = 0, 0
local function check(ok, label)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label)
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

local CORE = "/SCRIPTS/RFSUITE/core/"
local FUNCTIONS = "/SCRIPTS/FUNCTIONS/"
local TELLER = "tasks/events/telemetry_bg/adjustments.lua"
local PASS_TICKS = 5          -- 50 ms per pass
local ADJ_FRAME_TICKS = 20    -- the firmware's fast interval for the ADJ sensor, 200 ms

local function copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = copy(v) end
  return out
end

local W = nil

local function newWorld(host, opts)
  opts = opts or {}
  W = {
    host = host,
    ticks = 1000,
    frames = {},
    frameId = 0,
    adj = nil,              -- { fun, val } while the flight controller reports one
    nextAdjAt = 0,
    rows = {},              -- the radio's sensor list, by name
    allowRows = opts.allowRows ~= false,
    reads = {},             -- getValue() calls by name
    loads = {},             -- loadScript() calls by core-relative path
    loadPass = {},          -- the host pass each path was first loaded on
    tellerFailPasses = {},  -- the host pass of each attempt that found the teller missing
    passes = 0,
    spoken = {},
    shm = {},
    prefs = { audio_events = { adjustment_events = opts.enabled == true }, general = {} },
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
  setTelemetryValue = function(id, sub, inst, value, unit, prec, name)
    if not W.allowRows and (name == "AdjF" or name == "AdjV") then return end
    if name and name ~= "" then W.rows[name] = value end
  end
  getValue = function(name)
    W.reads[name] = (W.reads[name] or 0) + 1
    return W.rows[name]
  end

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
    W.loads[relative] = (W.loads[relative] or 0) + 1
    W.loadPass[relative] = W.loadPass[relative] or W.passes
    if relative == TELLER and W.failTeller then
      -- One attempt may ask twice (the memoizer, then the plain load), so a pass is one attempt.
      local fails = W.tellerFailPasses
      if fails[#fails] ~= W.passes then fails[#fails + 1] = W.passes end
      return nil
    end
    if standIns[relative] then return standIns[relative] end
    return loadfile(ROOT .. "/src/rfsuite/" .. relative)
  end

  if host == "widget" then
    _G.rfsuite = { session = {}, preferences = W.prefs }
    assert(loadScript(CORE .. "lib/require.lua"))()
    W.tasks = assert(loadScript(CORE .. "tasks/events/telemetry_bg/tasks.lua"))()
    W.step = function() W.tasks.wakeup() end
  else
    W.script = assert(loadScript(FUNCTIONS .. "rfsbg.lua"))()
    W.step = function() W.script.run() end
  end
  return W
end

local function frame(fun, val)
  W.frameId = (W.frameId + 1) % 256
  local v = val & 0xFFFFFFFF
  return { 0xC8, 12, W.frameId, 0x12, 0x20, (fun >> 8) & 0xFF, fun & 0xFF,
    (v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF }
end

-- One host pass. The flight controller's ADJ row goes out every 200 ms while `W.adj` is set.
local function pass(n)
  for _ = 1, n or 1 do
    W.ticks = W.ticks + PASS_TICKS
    W.passes = W.passes + 1
    if W.adj and W.ticks >= W.nextAdjAt then
      W.frames[#W.frames + 1] = frame(W.adj[1], W.adj[2])
      W.nextAdjAt = W.ticks + (W.adjEvery or ADJ_FRAME_TICKS)
    end
    if W.remote then
      W.remoteCount = (W.remoteCount or 0) + 1
      W.shm[16] = W.remoteCount
    end
    W.step()
  end
end

local function seconds(s) pass(math.floor(s * 100 / PASS_TICKS + 0.5)) end

local function adjReads()
  return (W.reads["AdjF"] or 0) + (W.reads["AdjV"] or 0)
end

local function said(file)
  for i = 1, #W.spoken do if W.spoken[i] == file then return true end end
  return false
end

local function tellerLoaded()
  return (W.loads[TELLER] or 0) > 0 or (_G.rfsuite and _G.rfsuite.adjustmentAnnouncer) ~= nil
end

local HOSTS = { "rfsbg", "widget" }

-- Starting a host, and the loads it does one pass at a time. The function script reads its
-- preferences on its second run; the widget pass loads one module per wakeup.
local function warm()
  seconds(1.0)
end

for _, host in ipairs(HOSTS) do
  -- The decoded pair is what is announced, also where the radio holds no AdjF/AdjV row (deleted,
  -- never discovered, or the model's sensor list full), and nothing reads the two by name.
  newWorld(host, { enabled = true, allowRows = false })
  W.adj = { 0, 0 }
  warm()
  local readsBefore = adjReads()
  W.adj = { 14, 100 }
  seconds(2.0)
  check(said("inflight/fn/14.wav") and said("#100"),
    host .. ": the teller announces the adjustment the decoder took from the frames")
  check(adjReads() == 0, host .. ": the teller reads AdjF/AdjV by name ("
    .. adjReads() .. " getValue calls, " .. (adjReads() - readsBefore) .. " of them in 40 passes)")

  -- A value below zero is spoken with its sign.
  newWorld(host, { enabled = true })
  W.adj = { 0, 0 }
  warm()
  W.adj = { 14, -100 }
  seconds(2.0)
  check(said("inflight/fn/14.wav") and said("#-100"), host .. ": a negative adjustment is announced with its sign")

  -- The value has to stand still for 1.0 s before it is spoken, and the 0 the flight controller
  -- reports between adjustments is never spoken.
  newWorld(host, { enabled = true })
  W.adj = { 0, 0 }
  warm()
  W.adj = { 14, 100 }
  seconds(0.6)
  W.adj = { 14, 101 }
  seconds(0.6)
  check(#W.spoken == 0, host .. ": a value that has not stood for 1.0 s is not spoken")
  seconds(1.0)
  check(said("#101") and not said("#100"), host .. ": the settled value is spoken, the passing one is not")
  local count = #W.spoken
  W.adj = { 0, 0 }
  seconds(2.0)
  check(#W.spoken == count, host .. ": the 0 between adjustments is not spoken")
  -- Only function 0 is the idle report: an adjustment whose new value is 0 is spoken, value included.
  W.adj = { 15, 0 }
  seconds(2.0)
  check(said("inflight/fn/15.wav") and said("#0"), host .. ": an adjustment to the value 0 is announced")

  -- A report already standing when the teller starts is joined, not announced.
  newWorld(host, { enabled = true })
  W.adj = { 14, 100 }
  seconds(3.0)
  check(#W.spoken == 0, host .. ": a report standing at start is joined, not announced")
  W.adj = { 0, 0 }
  seconds(1.0)
  W.adj = { 15, 7 }
  seconds(2.0)
  check(said("inflight/fn/15.wav") and said("#7"), host .. ": the next adjustment after a 0 is announced")

  -- Announcements off: the teller is not loaded at all. Switched on, it is loaded, joins a report
  -- that is standing at that moment, and announces the next one.
  newWorld(host, { enabled = false })
  W.adj = { 0, 0 }
  seconds(3.0)
  check(not tellerLoaded(), host .. ": the teller is loaded while adjustment announcements are off")
  W.adj = { 14, 100 }
  seconds(1.0)
  W.prefs.audio_events.adjustment_events = true
  -- The function script reads its preferences every 30 s; the widget's table is the live one.
  seconds(host == "rfsbg" and 31.0 or 1.0)
  check(tellerLoaded(), host .. ": the teller is loaded once adjustment announcements are on")
  seconds(2.0)
  check(#W.spoken == 0, host .. ": a report standing when announcements are switched on is joined")
  W.adj = { 0, 0 }
  seconds(1.0)
  W.adj = { 15, 7 }
  seconds(2.0)
  check(said("inflight/fn/15.wav") and said("#7"),
    host .. ": the first adjustment after switching on is announced")
  -- Switched off again: silent, and still loaded (a module cannot be given back).
  W.prefs.audio_events.adjustment_events = false
  seconds(host == "rfsbg" and 31.0 or 1.0)
  local before = #W.spoken
  W.adj = { 0, 0 }
  seconds(1.0)
  W.adj = { 16, 3 }
  seconds(2.0)
  check(#W.spoken == before, host .. ": nothing is announced once switched off again")
end

-- Widget only: while another Lua state drains, the widget's teller steps aside and is reset, so on
-- taking over it joins a report that is standing then -- the other state has announced it.
do
  newWorld("widget", { enabled = true })
  W.adj = { 0, 0 }
  warm()
  W.remote = true
  seconds(2.0)
  W.adj = { 14, 100 }
  seconds(2.0)
  check(#W.spoken == 0, "widget: the teller announces while another state drains")
  W.remote = false
  W.frames = {}
  seconds(3.0)
  check(#W.spoken == 0, "widget: a report standing when the widget takes over is joined")
  W.adj = { 0, 0 }
  seconds(1.0)
  W.adj = { 20, 5 }
  seconds(2.0)
  check(said("inflight/fn/20.wav") and said("#5"), "widget: the next adjustment after taking over is announced")
end

-- Widget only: a reset (a lost link) while a report stands joins it, as a teller that starts
-- then does; the next adjustment after a 0 is announced.
do
  newWorld("widget", { enabled = true })
  W.adj = { 0, 0 }
  warm()
  W.adj = { 14, 100 }
  seconds(0.5)
  W.tasks.reset()
  W.adj = nil
  seconds(2.5)
  W.adj = { 14, 100 }
  seconds(2.0)
  check(#W.spoken == 0, "widget: a report standing across a reset is joined")
  W.adj = { 0, 0 }
  seconds(1.0)
  W.adj = { 15, 7 }
  seconds(2.0)
  check(said("inflight/fn/15.wav"), "widget: the next adjustment after a reset is announced")
end

-- The flight controller's real cadence for the ADJ row: an unchanged report goes out at the slow
-- interval (3 s, `rotorflight-firmware` telemetry/crsf.c, ADJFUNC 200/3000), a changed one at
-- once. A pilot who adjusts within those 3 s after the teller was loaded, or reset by a lost
-- link, is announced: the 0 the radio last decoded already said that nothing was being adjusted.
local IDLE_TICKS = 300
local function idle()
  W.adj, W.adjEvery = { 0, 0 }, IDLE_TICKS
end
local function adjust(fun, val)
  W.adj, W.adjEvery, W.nextAdjAt = { fun, val }, ADJ_FRAME_TICKS, 0
end
-- Until the host both has the teller and has taken the setting in (the function script only with
-- its next preferences reload).
local function untilOn(limitSeconds)
  local function on()
    local prefs = _G.rfsuite and _G.rfsuite.preferences
    local events = type(prefs) == "table" and prefs.audio_events or nil
    return tellerLoaded() and type(events) == "table" and events.adjustment_events == true
  end
  local passes = math.floor(limitSeconds * 100 / PASS_TICKS)
  for _ = 1, passes do
    if on() then return true end
    pass()
  end
  return on()
end

for _, host in ipairs(HOSTS) do
  newWorld(host, { enabled = false })
  idle()
  seconds(4.0)
  W.prefs.audio_events.adjustment_events = true
  local loaded = untilOn(35.0)
  check(loaded, host .. ": the teller is loaded once switched on (slow ADJ cadence)")
  seconds(0.5)
  adjust(14, 100)
  seconds(2.0)
  check(said("inflight/fn/14.wav") and said("#100"),
    host .. ": an adjustment made within 3 s of switching on, after an idle 0, is announced")

  -- The same with the adjustment decoded on the very next pass after the one that loaded it.
  newWorld(host, { enabled = false })
  idle()
  seconds(4.0)
  W.prefs.audio_events.adjustment_events = true
  untilOn(35.0)
  adjust(14, 100)
  seconds(2.0)
  check(said("inflight/fn/14.wav") and said("#100"),
    host .. ": an adjustment decoded on the pass after the teller's load is announced")
end

-- Widget only: the overlay loaded the teller while announcements were off and nothing was being
-- adjusted; a report standing when they are switched on is still joined, and the next one spoken.
do
  newWorld("widget", { enabled = false })
  W.adj = { 0, 0 }
  seconds(2.0)
  _G.rfsuite.require(TELLER)
  seconds(0.5)
  W.adj = { 14, 100 }
  seconds(1.0)
  W.prefs.audio_events.adjustment_events = true
  seconds(2.0)
  check(#W.spoken == 0, "widget: a report standing when switched on is joined, also by the overlay's teller")
  W.adj = { 0, 0 }
  seconds(1.0)
  W.adj = { 15, 7 }
  seconds(2.0)
  check(said("inflight/fn/15.wav") and said("#7"),
    "widget: the overlay's teller announces the next adjustment once switched on")
end

-- Widget only: the decoder table loads on the same pass whether the teller was loaded, taken over
-- from the in-flight overlay, or not loaded at all.
do
  local function decoderPass(enabled, overlayFirst)
    newWorld("widget", { enabled = enabled })
    if overlayFirst then _G.rfsuite.require(TELLER) end
    W.adj = { 0, 0 }
    seconds(2.0)
    return W.loadPass["lib/rf2tlm_sensors.lua"]
  end
  local on, off, adopted = decoderPass(true, false), decoderPass(false, false), decoderPass(false, true)
  check(on ~= nil and on == off and on == adopted, "widget: the decoder table loads on the same start-up pass "
    .. "(on " .. tostring(on) .. ", off " .. tostring(off) .. ", overlay first " .. tostring(adopted) .. ")")
end

do
  newWorld("widget", { enabled = true })
  idle()
  seconds(4.0)
  W.tasks.reset()
  seconds(0.5)
  adjust(14, 100)
  seconds(2.0)
  check(said("inflight/fn/14.wav") and said("#100"),
    "widget: an adjustment made within 3 s of a reset, after an idle 0, is announced")
end

-- The settle is 1.0 s from the first decoded row of the new value: nothing before, the value at
-- the first pass after. The row is decoded on the first pass after adjust(); twenty passes of 50 ms
-- later, on pass 21, it has stood 1.0 s -- so pass 20 is silent and pass 21 speaks.
for _, host in ipairs(HOSTS) do
  newWorld(host, { enabled = true })
  W.adj = { 0, 0 }
  warm()
  adjust(14, 100)
  pass(1)
  pass(19)
  check(#W.spoken == 0, host .. ": nothing is spoken before the value has stood 1.0 s")
  pass(1)
  check(said("#100"), host .. ": the value is spoken on the first pass at which it has stood 1.0 s")
end

-- Widget only: taking over from another Lua state while a report stands, when its next row is
-- the slow one (3 s). The other state has announced it (and published it to the radio); the pair
-- this state decoded before stepping aside is not taken for the current one.
do
  newWorld("widget", { enabled = true })
  idle()
  seconds(4.0)
  W.remote = true
  seconds(2.0)
  adjust(14, 100)
  W.rows.AdjF, W.rows.AdjV = 14, 100
  seconds(0.3)
  W.adjEvery = IDLE_TICKS
  seconds(1.0)
  W.remote = false
  W.frames = {}
  W.nextAdjAt = W.ticks + IDLE_TICKS
  seconds(5.0)
  check(#W.spoken == 0,
    "widget: a report standing at takeover is joined, also when its next row comes 3 s later")
end

-- Widget only: a teller the in-flight tuning overlay has already loaded is taken over, not
-- loaded a second time, and it is reset when the widget steps aside, as before.
do
  newWorld("widget", { enabled = false })
  local announcer = _G.rfsuite.require(TELLER)
  check(type(announcer) == "table", "widget: the overlay's load of the teller")
  local loads = W.loads[TELLER] or 0
  W.adj = { 0, 0 }
  seconds(2.0)
  check((W.loads[TELLER] or 0) == loads, "widget: the teller the overlay holds is loaded a second time")
  announcer.select("overlay", "group", "cyclic", nil, W.ticks)
  W.remote = true
  seconds(2.0)
  W.remote = false
  W.prefs.audio_events.adjustment_events = true
  seconds(2.0)
  check(not said("inflight/group/cyclic.wav"),
    "widget: a selection pending when the widget stepped aside survived the reset")
end

-- The function script only: a teller that did not load is asked for again once a second -- not on
-- every run, and not never -- and once it loads, it announces.
do
  newWorld("rfsbg", { enabled = true })
  W.failTeller = true
  W.adj = { 0, 0 }
  seconds(2.0)
  local loads = W.loads[TELLER] or 0
  W.failTeller = false
  seconds(1.5)
  check(_G.rfsuite.adjustmentAnnouncer ~= nil and loads > 0 and loads <= 6,
    "rfsbg: a teller that did not load is asked for again once a second (" .. loads .. " loads in 2 s, "
    .. (_G.rfsuite.adjustmentAnnouncer and "loaded" or "never loaded") .. " after)")
  -- The attempts themselves are one second apart (TELLER_RETRY_SECONDS in src/functions/rfsbg.lua):
  -- 20 passes of 50 ms, or 21 where the float sum of the retry time lands just past a pass.
  local fails, gaps, spaced = W.tellerFailPasses, {}, true
  for i = 2, #fails do
    local gap = fails[i] - fails[i - 1]
    gaps[#gaps + 1] = tostring(gap)
    if gap < 20 or gap > 21 then spaced = false end
  end
  check(#fails >= 2 and spaced,
    "rfsbg: the attempts on a teller that did not load are one second apart (" .. #fails
    .. " attempts in 2 s, gaps in passes: " .. (#gaps > 0 and table.concat(gaps, ",") or "none") .. ")")
  W.adj = { 14, 100 }
  seconds(2.0)
  check(said("inflight/fn/14.wav") and said("#100"), "rfsbg: a teller loaded after a failed load announces")
end

-- The decoder itself (lib/rf2tlm_sensors.lua): the suite's own load holds every decoded ADJ pair
-- for the state's teller, also one the publish throttle declines; EdgeTX's sensor discovery, which
-- calls every decoder once with zero bytes, holds nothing.
do
  newWorld("widget", { enabled = true })
  local function held()
    local r = _G.rfsuite.adjustmentReport
    return type(r) == "table" and (tostring(r[1]) .. "/" .. tostring(r[2])) or tostring(r)
  end
  local chunk = assert(loadfile(ROOT .. "/src/rfsuite/lib/rf2tlm_sensors.lua"))
  local data = { 0x00, 0x0E, 0xFF, 0xFF, 0xFF, 0x9C }
  local sensors = chunk(nil, function() return false end)
  local _, pos = sensors[0x1220].dec(data, 1)
  check(pos == 7, "decoder: the ADJ row is six bytes")
  check(held() == "14/-100", "decoder: a decoded pair the throttle declines is still held for the teller ("
    .. held() .. ")")
  -- And one it lets through is still published as the two sensors, for the in-flight tuning overlay.
  W.allowRows, W.rows = true, {}
  chunk(nil, function() return true end)[0x1220].dec(data, 1)
  check(W.rows.AdjF == 14 and W.rows.AdjV == -100, "decoder: the ADJ pair is published as AdjF and AdjV ("
    .. tostring(W.rows.AdjF) .. "/" .. tostring(W.rows.AdjV) .. ")")
  _G.rfsuite.adjustmentReport = nil
  local discovered = chunk({ 99 })
  check(type(discovered[0x1220]) == "table", "decoder: discovery returns the ADJ row")
  check(_G.rfsuite.adjustmentReport == nil, "decoder: sensor discovery holds a pair for the teller")
end

print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
