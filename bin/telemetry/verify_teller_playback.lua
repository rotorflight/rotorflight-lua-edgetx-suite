-- Run from the repository root: lua5.3 bin/telemetry/verify_teller_playback.lua [--trace]
--
-- The adjustment teller plays through lib/audio_playback.lua, and so does lib/audio.lua. This
-- drives the teller in both of its hosts -- the background function script (src/functions/rfsbg.lua)
-- and the widget's telemetry pass (tasks/events/telemetry_bg/tasks.lua) -- with the real drain, the
-- real decoder table, the real teller and the REAL playback code; only the EdgeTX calls, the
-- preferences module, the language module and the SmartFuel task are stood in for. playFile() and
-- playNumber() record every argument they are given, io.open() answers from a list of files on the
-- card.
--
-- What it asserts:
--   * a Lua state that runs the teller and no dashboard loads lib/audio_playback.lua and never
--     lib/audio.lua;
--   * what the teller hands to playFile()/playNumber() -- path, value, unit, attribute, level --
--     for every kind of adjustment report: a name recording, a name built from words, a value
--     alone, one spoken elsewhere, a profile announcement, a value selection, a group selection
--     and the tone; in German and English, from the sound pack's own folder and from the radio's
--     language folder, and a file in neither;
--   * with lib/audio.lua loaded in the same state (the dashboard), both use ONE playback: the
--     level the volume refresh sets and the alarm window an alarm opens are what the teller sees.
-- With --trace the sequences are printed as well, so two trees can be compared line by line.
-- Exit status: 0 green, 1 a FAIL line was printed.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]telemetry$") or (dir .. "/../..") end
end
local TRACE = arg and arg[1] == "--trace"

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

local CORE = "/SCRIPTS/TOOLS/rfsuite-core/"
local FUNCTIONS = "/SCRIPTS/FUNCTIONS/"
local PASS_TICKS = 5          -- 50 ms per pass
local ADJ_FRAME_TICKS = 20    -- the firmware's fast interval for the ADJ sensor, 200 ms

local function copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = copy(v) end
  return out
end

local W = nil

-- opts.lang: the language the language module answers; opts.files: the card's files, by path;
-- opts.audio: the Settings > Audio > Volume table.
local function newWorld(host, opts)
  W = {
    host = host,
    ticks = 1000,
    frames = {},
    frameId = 0,
    adj = nil,
    nextAdjAt = 0,
    loads = {},
    played = {},
    probes = {},
    files = opts.files or {},
    -- A module whose first load fails (a load the module loader asks for and gets nothing).
    failOnce = opts.failOnce,
    rssi = 80,
    prefs = { audio_events = { adjustment_events = true, telemetry_lost = true }, general = {},
      audio = opts.audio or {} },
  }

  _G.rfsuite = nil
  _G.__rfsuite_system_locale_module = nil
  getTime = function() return W.ticks end
  getShmVar = function() return 0 end
  setShmVar = function() end
  getRSSI = function() return W.rssi end
  crossfireTelemetryPop = function()
    local f = table.remove(W.frames, 1)
    if f then return 0x88, f end
    return nil
  end
  setTelemetryValue = function() end
  getValue = function() return nil end
  playFile = function(path, level)
    W.played[#W.played + 1] = "file " .. tostring(path) .. " level=" .. tostring(level)
  end
  playNumber = function(value, unit, attr, level)
    W.played[#W.played + 1] = string.format("number %s unit=%s attr=%s level=%s",
      tostring(value), tostring(unit), tostring(attr), tostring(level))
  end
  io.open = function(path)
    W.probes[#W.probes + 1] = path
    if W.files[path] then return {} end
    return nil
  end
  io.close = function() end

  local standIns = {
    ["lib/preferences.lua"] = function()
      return { load = function() return copy(W.prefs) end }
    end,
    ["lib/system_locale.lua"] = function()
      return { resolveSystemLanguage = function() return opts.lang end }
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
    if W.failOnce == relative then
      W.failOnce = nil
      return nil, "injected load failure"
    end
    if standIns[relative] then return standIns[relative] end
    return loadfile(ROOT .. "/src/rfsuite/" .. relative)
  end

  if host == "rfsbg" then
    W.script = assert(loadScript(FUNCTIONS .. "rfsbg.lua"))()
    W.step = function() W.script.run() end
  else
    _G.rfsuite = { session = {}, preferences = W.prefs }
    assert(loadScript(CORE .. "lib/require.lua"))()
    -- The dashboard loads lib/audio.lua when its module loads, before its first telemetry pass.
    if host == "dashboard" then W.audio = assert(_G.rfsuite.require("lib/audio.lua")) end
    W.tasks = assert(loadScript(CORE .. "tasks/events/telemetry_bg/tasks.lua"))()
    W.step = function() W.tasks.wakeup() end
  end
  return W
end

local function frame(fun, val)
  W.frameId = (W.frameId + 1) % 256
  local v = val & 0xFFFFFFFF
  return { 0xC8, 12, W.frameId, 0x12, 0x20, (fun >> 8) & 0xFF, fun & 0xFF,
    (v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF }
end

local function pass(n)
  for _ = 1, n or 1 do
    W.ticks = W.ticks + PASS_TICKS
    if W.adj and W.ticks >= W.nextAdjAt then
      W.frames[#W.frames + 1] = frame(W.adj[1], W.adj[2])
      W.nextAdjAt = W.ticks + ADJ_FRAME_TICKS
    end
    W.step()
  end
end

local function seconds(s) pass(math.floor(s * 100 / PASS_TICKS + 0.5)) end

-- Up and idle (the function script reads its preferences on its second run), then one report
-- held for two seconds; returns what was played for it.
local function announce(fun, val)
  W.adj = { 0, 0 }
  seconds(1.0)
  W.played = {}
  W.adj = { fun, val }
  seconds(2.0)
  return W.played
end

local function same(got, want)
  if #got ~= #want then return false end
  for i = 1, #want do if got[i] ~= want[i] then return false end end
  return true
end

local function trace(label, got)
  if not TRACE then return end
  print("TRACE " .. label .. " | " .. table.concat(got, " ; "))
end

local function expect(label, got, want)
  trace(label, got)
  check(same(got, want), label .. ": played {" .. table.concat(got, " ; ") .. "}")
end

local function teller()
  return _G.rfsuite and _G.rfsuite.adjustmentAnnouncer
end

local RF = function(lang, rel) return "/SOUNDS/rf/" .. lang .. "/" .. rel end
local STD = function(lang, rel) return "/SOUNDS/" .. lang .. "/" .. rel end

local function pack(lang, rels, folder)
  local files = {}
  for _, rel in ipairs(rels) do files[(folder or RF)(lang, rel)] = true end
  return files
end

local NAMES = { "inflight/fn/14.wav", "inflight/fn/15.wav", "inflight/fn/16.wav", "adj/yaw.wav",
  "adj/collective.wav", "adj/dyn.wav", "evt/profile.wav",
  "inflight/selected.wav", "inflight/group/yaw.wav", "stat/alerts/telemetrylost.wav" }
local LEVEL3 = { volume_mode = 1, level = 3 }

-- The kinds of report, in each host that runs the teller without a dashboard, both languages.
for _, host in ipairs({ "rfsbg", "widget" }) do
  for _, lang in ipairs({ "en", "de" }) do
    local tag = host .. "/" .. lang
    newWorld(host, { lang = lang, files = pack(lang, NAMES), audio = LEVEL3 })
    expect(tag .. ": a name recording and the value", announce(14, 100),
      { "file " .. RF(lang, "inflight/fn/14.wav") .. " level=3", "number 100 unit=0 attr=0 level=3" })
    check((W.loads["lib/audio_playback.lua"] or 0) == 1,
      tag .. ": lib/audio_playback.lua is loaded once (" .. tostring(W.loads["lib/audio_playback.lua"]) .. ")")
    check(W.loads["lib/audio.lua"] == nil, tag .. ": lib/audio.lua is loaded for the teller")

    newWorld(host, { lang = lang, files = pack(lang, NAMES), audio = LEVEL3 })
    expect(tag .. ": a name built from words (id 30)", announce(30, -5), {
      "file " .. RF(lang, "adj/yaw.wav") .. " level=3", "file " .. RF(lang, "adj/collective.wav") .. " level=3",
      "file " .. RF(lang, "adj/dyn.wav") .. " level=3", "number -5 unit=0 attr=0 level=3" })

    newWorld(host, { lang = lang, files = pack(lang, NAMES), audio = LEVEL3 })
    expect(tag .. ": an id with neither, the value alone", announce(90, 7),
      { "number 7 unit=0 attr=0 level=3" })

    newWorld(host, { lang = lang, files = pack(lang, NAMES), audio = LEVEL3 })
    expect(tag .. ": the battery profile is spoken elsewhere", announce(82, 2), {})

    -- The radio's language folder when the sound pack's own has no such file.
    newWorld(host, { lang = lang, files = pack(lang, NAMES, STD), audio = {} })
    expect(tag .. ": from the language folder, at the radio's volume", announce(14, 100),
      { "file " .. STD(lang, "inflight/fn/14.wav") .. " level=nil", "number 100 unit=0 attr=0 level=nil" })
    local probes = table.concat(W.probes, " ")
    check(string.find(probes, RF(lang, "inflight/fn/14.wav"), 1, true) ~= nil,
      tag .. ": the sound pack's own folder is looked in first")

    -- Neither folder has it: the value alone, and the miss is remembered.
    newWorld(host, { lang = lang, files = {}, audio = LEVEL3 })
    local got = announce(14, 100)
    expect(tag .. ": the file in neither folder", got, { "number 100 unit=0 attr=0 level=3" })
    -- Another function's name is looked for (the positive control), and the first one's again
    -- when the pilot comes back to it -- from the remembered miss, without opening a file.
    local opened = #W.probes
    W.played = {}
    W.adj = { 16, 50 }
    seconds(2.0)
    local afterOther = #W.probes
    check(afterOther > opened, tag .. ": a name not asked for before is looked for")
    W.adj = { 14, 60 }
    seconds(2.0)
    check(#W.played > 0 and W.played[#W.played] == "number 60 unit=0 attr=0 level=3",
      tag .. ": the function returned to is announced")
    check(#W.probes == afterOther, tag .. ": a file found missing is looked for again")
  end
end

-- What the in-flight overlay asks the teller for, in the widget state that has the dashboard.
for _, lang in ipairs({ "en", "de" }) do
  local tag = "dashboard/" .. lang
  newWorld("dashboard", { lang = lang, files = pack(lang, NAMES), audio = LEVEL3 })
  seconds(1.0)
  local T = teller()
  check(T ~= nil, tag .. ": the teller is loaded")
  if T then
    W.played = {}
    T.profile({}, 3)
    expect(tag .. ": a profile", W.played,
      { "file " .. RF(lang, "evt/profile.wav") .. " level=3", "number 3 unit=0 attr=0 level=3" })
    W.played = {}
    T.select("o", "value", 14, 25, 0); T.selectionTick(100)
    expect(tag .. ": a value selection", W.played, { "file " .. RF(lang, "inflight/selected.wav") .. " level=3",
      "file " .. RF(lang, "inflight/fn/14.wav") .. " level=3", "number 25 unit=0 attr=0 level=3" })
    W.played = {}
    T.select("o", "group", "yaw", nil, 0); T.selectionTick(1000)
    expect(tag .. ": a group selection", W.played, { "file " .. RF(lang, "inflight/group/yaw.wav") .. " level=3" })
    W.played = {}
    T.endFeedback()
    expect(tag .. ": the tone", W.played, { "file /SOUNDS/rf/beep.wav level=3" })
  end
end

-- One playback for both: the level lib/audio.lua's volume refresh sets is the teller's, and the
-- alarm window an alarm opens keeps the teller quiet.
do
  newWorld("dashboard", { lang = "en", files = pack("en", NAMES),
    audio = { volume_mode = 1, level = 4, level_connected_only = true } })
  local Audio = W.audio
  local owner = { audioState = { flightArmed = true }, state = { rfConnected = false },
    preferences = W.prefs }
  Audio.refreshConnectionVolume(owner)
  expect("dashboard: the link down, connected only", announce(14, 100),
    { "file " .. RF("en", "inflight/fn/14.wav") .. " level=nil", "number 100 unit=0 attr=0 level=nil" })
  owner.state.rfConnected = true
  Audio.refreshConnectionVolume(owner)
  expect("dashboard: the link up, connected only", announce(15, 10),
    { "file " .. RF("en", "inflight/fn/15.wav") .. " level=4", "number 10 unit=0 attr=0 level=4" })

  W.adj = { 0, 0 }
  seconds(1.0)
  W.played = {}
  Audio.announceConnectionLost(owner, true, nil)
  check(#W.played == 1 and string.find(W.played[1], "telemetrylost.wav", 1, true) ~= nil,
    "dashboard: the alarm is played {" .. table.concat(W.played, " ; ") .. "}")
  W.played = {}
  W.adj = { 14, 50 }
  seconds(2.0)
  expect("dashboard: an adjustment inside the alarm window", W.played, {})
  W.adj = { 0, 0 }
  seconds(7.0)
  W.played = {}
  W.adj = { 16, 60 }
  seconds(2.0)
  expect("dashboard: an adjustment after the alarm window", W.played,
    { "file " .. RF("en", "inflight/fn/16.wav") .. " level=4", "number 60 unit=0 attr=0 level=4" })

  local okReq, playback = pcall(_G.rfsuite.require, "lib/audio_playback.lua")
  check(okReq and type(playback) == "table" and Audio.playNumber == playback.playNumber
    and Audio.playEventFile == playback.playEventFile,
    "dashboard: lib/audio.lua and the teller play through one lib/audio_playback.lua")
end

-- The module loader's first load of the playback module fails and lib/audio.lua's plain load
-- of it succeeds: the teller, which asks the loader later, still gets that same instance, so an
-- alarm lib/audio.lua plays keeps it quiet.
do
  newWorld("dashboard", { lang = "en", files = pack("en", NAMES), audio = LEVEL3,
    failOnce = "lib/audio_playback.lua" })
  local Audio = W.audio
  W.adj = { 0, 0 }
  seconds(1.0)
  local owner = { audioState = { flightArmed = true }, state = { rfConnected = true }, telemetry = {},
    preferences = W.prefs }
  check(W.failOnce == nil, "dashboard, plain load: the module loader's first load failed")
  W.played = {}
  Audio.announceConnectionLost(owner, true, nil)
  check(#W.played == 1 and string.find(W.played[1], "telemetrylost.wav", 1, true) ~= nil,
    "dashboard, plain load: the alarm is played {" .. table.concat(W.played, " ; ") .. "}")
  W.played = {}
  W.adj = { 14, 50 }
  seconds(2.0)
  expect("dashboard, plain load: an adjustment inside the alarm window", W.played, {})
  W.adj = { 0, 0 }
  seconds(7.0)
  W.played = {}
  W.adj = { 16, 60 }
  seconds(2.0)
  expect("dashboard, plain load: an adjustment after the alarm window", W.played,
    { "file " .. RF("en", "inflight/fn/16.wav") .. " level=3", "number 60 unit=0 attr=0 level=3" })
  local okReq, playback = pcall(_G.rfsuite.require, "lib/audio_playback.lua")
  check(okReq and type(playback) == "table" and Audio.playNumber == playback.playNumber,
    "dashboard, plain load: lib/audio.lua and the teller play through one lib/audio_playback.lua")
end

print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
