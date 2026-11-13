-- Run from the repository root: lua5.3 bin/telemetry/verify_drain_frame_walk.lua
-- Drive the real custom-telemetry drain with the real decoder table (lib/rf2tlm_sensors.lua) and
-- frames whose entries have different widths, and read what each of its frame walks publishes:
--   decode         the full pass (M.wakeup): every entry of a frame, in order, with its value;
--   decode traced  the same pass at the trace level, which walks the frame in a twin of its own;
--   rescue         a step's adjustment report in a frame the decode cap drops, behind entries of
--                  other widths: the report alone is published, the entries in front are not;
--   armed walk     the armed-state pass (M.wakeupArmingFlags): the System Status word and the
--                  arming flags behind entries of other widths, and nothing in front of them.
-- A walk reads a sensor id, finds the row and lets its decoder say where the next entry starts, so
-- a wrong id, a skipped decoder or a wrong position shows as a missing, extra or wrong value of an
-- entry further on; each scenario ends its frame with an entry behind a group and a wide value.
-- Exit status: 0 green, 1 a FAIL line was printed.

local checks, failures = 0, 0
local function check(ok, label, detail)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label .. (detail and (" -- " .. detail) or ""))
  end
end

local bit32 = {
  band = function(a, b) return a & b end,
  bor = function(a, b) return a | b end,
  lshift = function(a, n) return (a << n) & 0xFFFFFFFF end,
  rshift = function(a, n) return (a & 0xFFFFFFFF) >> n end,
  extract = function(a, f, w) return (a >> f) & ((1 << w) - 1) end,
  btest = function(a, b) return (a & b) ~= 0 end,
}

-- Entries as the flight controller packs them: the sensor id in two bytes, then the value at the
-- width its encoder writes.
local VBAT = { 0x10, 0x11, 0x0C, 0x34 }                         -- U16  3124
local ALT = { 0x10, 0xB2, 0xFF, 0xFF, 0xFB }                    -- S24  -5
local ATTD = { 0x11, 0x00, 0x00, 0x64, 0xFF, 0x9C, 0x01, 0x2C } -- three S16: 100, -100, 300
local THR = { 0x10, 0x35, 0xFD }                                -- S8   -3
local ESCR = { 0x10, 0x44, 0x01, 0x86, 0xA0 }                   -- U24  100000
local ARMD = { 0x12, 0x03, 0x00, 0x00, 0x01, 0x02 }             -- U32  258
local CPU = { 0x11, 0x41, 0x2A }                                -- U8   42
local STAT = { 0x12, 0x30, 0x00, 0x00, 0x00, 0x01 }             -- U32  1, armed
local ARM = { 0x12, 0x02, 0x01 }                                -- U8   1, armed
local ADJ = { 0x12, 0x20, 0x00, 0x0E, 0xFF, 0xFF, 0xFF, 0x9C }  -- U16 14, then S32 -100

-- One custom telemetry frame: destination, origin, frame id, then the entries.
local function frame(id, entries)
  local data = { 0xEA, 0xC8, id }
  for _, e in ipairs(entries) do
    for _, b in ipairs(e) do data[#data + 1] = b end
  end
  return data
end

local function newDrain(trace)
  local h = { calls = {}, queued = {}, frames = 0, traced = 0 }
  local env = setmetatable({}, { __index = function(_, key)
    if type(key) == "string" and string.sub(key, 1, 5) == "UNIT_" then return 0 end
    return _G[key]
  end })
  env._G = env
  env.bit32 = bit32
  env.rfsuite = { loadMode = "t", paths = dofile("src/rfsuite/lib/paths.lua") }
  if trace then
    env.rfsuite.preferences = { general = { debug_level = "trace" } }
    env.rfsuite.Log = {
      wanted = function() return true end,
      emitf = function(_, _, fmt)
        if string.find(fmt, "value(s), changed", 1, true) then h.traced = h.traced + 1 end
      end,
    }
  end
  env.getValue = function() return nil end
  env.setTelemetryValue = function(id, _, _, value)
    h.calls[#h.calls + 1] = { id = id, value = value }
  end
  local crsf = { popFrame = function() return table.remove(h.queued, 1) end }
  env.loadScript = function(path, mode)
    if string.find(path, "rf2tlm_sensors.lua", 1, true) then
      return assert(loadfile("src/rfsuite/lib/rf2tlm_sensors.lua", mode, env))
    end
    if string.find(path, "crsf.lua", 1, true) then return function() return crsf end end
    error("unexpected module: " .. path)
  end
  h.env = env
  h.drain = assert(loadfile("src/rfsuite/tasks/events/telemetry_bg/drain.lua", "t", env))()
  function h:push(entries)
    self.frames = self.frames + 1
    self.queued[#self.queued + 1] = frame(self.frames % 256, entries)
  end
  -- Load both modules (one wakeup each) and end with a pass that empties the queue.
  function h:prime(pass, t)
    self.drain[pass](t); self.drain[pass](t + 0.1); self.drain[pass](t + 0.2)
    self.calls = {}
    return t + 0.2
  end
  -- The calls for the given ids, in order, as "id=value".
  function h:seen(ids)
    local want, out = {}, {}
    for _, id in ipairs(ids) do want[id] = true end
    for _, c in ipairs(self.calls) do
      if want[c.id] then out[#out + 1] = string.format("%04X=%s", c.id, tostring(c.value)) end
    end
    return table.concat(out, " ")
  end
  return h
end

local function scenario(name, run)
  local ok, err = pcall(run)
  check(ok, name .. " runs without error", ok and nil or tostring(err))
end

-- Every id a frame below can publish, groups and their members included.
local IDS = { 0x1011, 0x10B2, 0x1100, 0x1101, 0x1102, 0x1103, 0x1035, 0x1044, 0x1203, 0x1141,
  0x1230, 0x1202, 0x1221, 0x1222 }
local FULL = "1011=3124 10B2=-5 1100=0 1101=100 1102=-100 1103=300 1035=-3 1044=100000 1203=258"

scenario("decode", function()
  local h = newDrain(false)
  local t = h:prime("wakeup", 0.1)
  h:push({ VBAT, ALT, ATTD, THR, ESCR, ARMD })
  check(h.drain.wakeup(t + 0.1) == 1, "decode: the pass takes the frame")
  local seen = h:seen(IDS)
  check(seen == FULL, "decode: every entry with its value, in order", seen)
end)

scenario("decode_traced", function()
  local h = newDrain(true)
  local t = h:prime("wakeup", 0.1)
  h.traced = 0
  h:push({ VBAT, ALT, ATTD, THR, ESCR, ARMD })
  h.drain.wakeup(t + 0.1)
  check(h.traced == 1, "decode_traced: the pass took the traced walk", "trace lines " .. h.traced)
  local seen = h:seen(IDS)
  check(seen == FULL, "decode_traced: every entry with its value, in order", seen)
end)

scenario("rescue", function()
  local h = newDrain(false)
  local t = h:prime("wakeup", 0.1)
  h.env.rfsuite.adjustmentStepAt = math.floor(t * 100)
  -- 14 frames, the decode cap keeps the newest four; the report sits in the oldest, behind
  -- entries of three other widths and a group.
  h:push({ VBAT, ALT, ATTD, ADJ })
  for _ = 2, 14 do h:push({ CPU }) end
  check(h.drain.wakeup(t + 0.1) == 14, "rescue: the pass takes the backlog")
  local seen = h:seen(IDS)
  check(seen == "1221=14 1222=-100 1141=42", "rescue: the report alone from the dropped frame, then the kept frames",
    seen)
end)

scenario("armed_walk", function()
  local h = newDrain(false)
  local t = h:prime("wakeupArmingFlags", 0.1)
  h:push({ VBAT, ALT, ATTD, ESCR, STAT, ARM })
  local popped, found = h.drain.wakeupArmingFlags(t + 0.1)
  check(popped == 1 and found == "ARM", "armed_walk: the pass finds the arming flags",
    tostring(popped) .. " " .. tostring(found))
  local seen = h:seen(IDS)
  check(seen == "1230=1 1202=1", "armed_walk: the word and the flags, nothing in front of them", seen)
end)

-- Control: a frame with an entry the table does not know stops the walk there, in every walk the
-- same way -- the entries in front are published, the ones behind are not.
scenario("unknown_entry", function()
  local h = newDrain(false)
  local t = h:prime("wakeup", 0.1)
  h:push({ VBAT, { 0x7F, 0x7F, 0x00 }, THR })
  h.drain.wakeup(t + 0.1)
  local seen = h:seen(IDS)
  check(seen == "1011=3124", "unknown_entry: the walk stops at the unknown id", seen)
end)

print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
