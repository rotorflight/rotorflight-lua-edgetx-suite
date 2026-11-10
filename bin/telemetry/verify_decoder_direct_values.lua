-- Run from the repository root: lua5.3 bin/telemetry/verify_decoder_direct_values.lua
--
-- While a Lua state decodes the custom telemetry itself, lib/sensors.lua answers a source from that
-- state's decoder (tasks/events/telemetry_bg/drain.lua, valueByName) instead of reading the radio's
-- sensor back. The real telemetry task, drain, decoder table, sensor module and logger run; the
-- radio's sensor list is a stand-in that applies a calibration offset the way the radio's own sensor
-- page would, so a value read from the decoder and one read back from the sensor can be told apart.
--
-- What it asserts:
--   * decoding here: a custom value comes from the decoder, scaled by the table's precision, and the
--     radio-side offset does not reach it; a raw sensor name answers the same way;
--   * the background script decoding: the sensor is read as before;
--   * taking over again: the values this state decodes from then on answer again;
--   * a source whose list starts with a sensor that is not custom keeps its order (smartfuel);
--   * a custom sensor the flight controller does not send falls back to the sensor search (VFAS);
--   * a group (attitude) and a link reset fall back to the sensors.
-- Exit status: 0 green, 1 a FAIL line was printed.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]telemetry$") or (dir .. "/../..") end
end

local realPrint = print
local checks, failures = 0, 0
local function check(ok, label, detail)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    realPrint("FAIL " .. label .. (detail ~= nil and (": " .. tostring(detail)) or ""))
  end
end
local function near(a, b) return type(a) == "number" and type(b) == "number" and math.abs(a - b) < 1e-6 end

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
local PASS_TICKS = 5
local W = nil

-- The radio's side: a sensor row per name, holding value / 10^prec plus the row's calibration offset.
local function newWorld()
  W = { ticks = 1000, frames = {}, frameId = 0, rows = {}, offset = { Vbat = 0.2 }, shm = {}, remote = false,
    payload = {} }
  _G.rfsuite = nil
  getTime = function() return W.ticks end
  getShmVar = function(id) return W.shm[id] or 0 end
  setShmVar = function(id, v) W.shm[id] = v end
  crossfireTelemetryPop = function()
    local f = table.remove(W.frames, 1)
    if f then return 0x88, f end
    return nil
  end
  setTelemetryValue = function(_, _, _, value, _, prec, name)
    if name and name ~= "" then
      W.rows[name] = value / (10 ^ (prec or 0)) + (W.offset[name] or 0)
    end
  end
  getValue = function(name) return W.rows[name] end
  getSourceValue = function(name)
    local v = W.rows[name]
    if v == nil then return nil end
    return v, true, true
  end
  getFieldInfo = function(name)
    if W.rows[name] == nil then return nil end
    return { id = 1, name = name }
  end
  getVersion = function() return "2.12.5", "tx16s", 2, 12, 5 end
  system = nil
  model = {}
  print = function() end

  loadScript = function(path)
    assert(string.sub(path, 1, #CORE) == CORE, "unexpected module path: " .. tostring(path))
    local relative = string.sub(path, #CORE + 1)
    if relative == "tasks/events/telemetry_bg/smart.lua" then
      return function() return { wakeup = function() end, reset = function() end } end
    end
    return loadfile(ROOT .. "/src/rfsuite/" .. relative)
  end

  _G.rfsuite = { session = {}, preferences = { general = { debug_level = "off" }, audio_events = {} } }
  assert(loadScript(CORE .. "lib/require.lua"))()
  assert(loadScript(CORE .. "lib/log.lua"))()
  W.tasks = assert(loadScript(CORE .. "tasks/events/telemetry_bg/tasks.lua"))()
  W.sensors = assert(loadScript(CORE .. "lib/sensors.lua"))()
  return W
end

-- One frame carrying the rows in W.payload: { {sid, bytes...}, ... }.
local function frame()
  W.frameId = (W.frameId + 1) % 256
  local f = { 0xC8, 0, W.frameId }
  for _, row in ipairs(W.payload) do
    for i = 1, #row do f[#f + 1] = row[i] end
  end
  f[2] = #f
  return f
end

local function pass(n)
  for _ = 1, n or 1 do
    W.ticks = W.ticks + PASS_TICKS
    W.frames[#W.frames + 1] = frame()
    if W.remote then
      W.remoteCount = (W.remoteCount or 0) + 1
      W.shm[16] = W.remoteCount
    end
    _G.rfsuite.session.event_context = "widget"
    W.tasks.wakeup()
    _G.rfsuite.session.event_context = nil
  end
end
local function seconds(s) pass(math.floor(s * 100 / PASS_TICKS + 0.5)) end

local function u16(sid, v) return { sid >> 8, sid & 0xFF, (v >> 8) & 0xFF, v & 0xFF } end
local function u8(sid, v) return { sid >> 8, sid & 0xFF, v & 0xFF } end
local function s16x3(sid, a, b, c)
  local function s(v) v = v & 0xFFFF return (v >> 8) & 0xFF, v & 0xFF end
  local a1, a2 = s(a); local b1, b2 = s(b); local c1, c2 = s(c)
  return { sid >> 8, sid & 0xFF, a1, a2, b1, b2, c1, c2 }
end

local function scenario(name, run)
  local ok, err = pcall(run)
  print = realPrint
  check(ok, name .. " runs without error", ok and nil or err)
end

-- 1. Decoding here: the decoder's value, without the radio-side offset.
scenario("decoding_here", function()
  newWorld()
  W.payload = { u16(0x1011, 2240), u16(0x10C0, 1520), u8(0x1014, 70) }
  seconds(1)
  local S = W.sensors
  check(near(W.rows.Vbat, 22.6), "decoding_here: the radio's sensor carries the offset (control)", W.rows.Vbat)
  check(near(S.getValue("voltage"), 22.4), "decoding_here: voltage is the decoded 22.40 V", S.getValue("voltage"))
  check(near(S.getValue("rpm"), 1520), "decoding_here: rpm from the decoder", S.getValue("rpm"))
  check(near(S.getValue("Hspd"), 1520), "decoding_here: a raw custom name answers too", S.getValue("Hspd"))
  -- Control without a decoder in the state: the same read gives the radio's calibrated value.
  local decoder = _G.rfsuite.telemetryDecoder
  _G.rfsuite.telemetryDecoder = nil
  check(near(S.getValue("voltage"), 22.6), "decoding_here: without the decoder the sensor answers (control)",
    S.getValue("voltage"))
  _G.rfsuite.telemetryDecoder = decoder
end)

-- 2. The background script decodes; then the widget takes over again.
scenario("remote_and_takeover", function()
  newWorld()
  W.payload = { u16(0x1011, 2240) }
  seconds(1)
  local S = W.sensors
  W.remote = true
  seconds(1)
  -- The other state publishes a new value meanwhile; the radio's row moves, this state's does not.
  W.rows.Vbat = 23.1
  check(near(S.getValue("voltage"), 23.1), "remote: the sensor is read while another state decodes",
    S.getValue("voltage"))
  W.remote = false
  -- Taking over: the frames this state decodes from then on answer again.
  W.payload = { u16(0x1011, 2280) }
  pass(25)
  check(near(S.getValue("voltage"), 22.8), "takeover: a value decoded after the take-over answers",
    S.getValue("voltage"))
end)

-- 3. A list that starts with a sensor that is not custom keeps its order; a custom sensor that is
-- not sent falls back to the search.
scenario("order_and_fallback", function()
  newWorld()
  W.payload = { u8(0x1014, 70), u16(0x10C0, 1500) }
  W.rows.SmFt = 55
  W.rows.VFAS = 23.0
  seconds(1)
  local S = W.sensors
  check(near(S.getValue("smartfuel"), 55), "order: smartfuel keeps SmFt ahead of the decoded Bat%",
    S.getValue("smartfuel"))
  check(near(S.getValue("fuel"), 70), "order: fuel is the decoded Bat%", S.getValue("fuel"))
  check(near(S.getValue("voltage"), 23.0), "fallback: Vbat not sent, VFAS answers", S.getValue("voltage"))
end)

-- 4. A group and a link reset fall back to the sensors.
scenario("group_and_reset", function()
  newWorld()
  W.payload = { s16x3(0x1100, 105, -20, 300), u16(0x1011, 2240) }
  seconds(1)
  local S = W.sensors
  check(near(S.getValue("pitch"), 10.5), "group: pitch comes from the sensor the group wrote",
    S.getValue("pitch"))
  W.payload = {}
  W.tasks.reset()
  W.rows.Vbat = 21.0
  check(near(S.getValue("voltage"), 21.0), "reset: after a link reset the sensor answers", S.getValue("voltage"))
end)

print = realPrint
print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
