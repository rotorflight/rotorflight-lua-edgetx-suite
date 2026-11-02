-- Run from the repository root: lua5.3 bin/telemetry/verify_drain_failed_load.lua
-- Drive the real custom-telemetry drain with one of its two modules failing to load, and count
-- how often it goes back to the card for it.
local checks, failures = 0, 0
local function check(ok, label, detail)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label .. (detail and (": " .. detail) or ""))
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

local DECODER = "lib/rf2tlm_sensors.lua"
local CRSF = "lib/crsf.lua"
local WAKEUPS = 100

-- One custom telemetry frame: frame id, then sensor 0x1202 (ARM) carrying one byte.
local function frame(id, armed)
  return { 0, 0, id, 0x12, 0x02, armed }
end

-- `failing` names the module that does not load; nil loads both.
local function newDrain(failing)
  local h = { loads = {}, published = {}, queued = {} }
  local env = setmetatable({}, { __index = _G })
  env._G = env
  env.bit32 = bit32
  env.rfsuite = { loadMode = "t" }
  env.getValue = function() return nil end
  env.setTelemetryValue = function(id, _, _, value)
    h.published[#h.published + 1] = { id = id, value = value }
  end
  local crsf = {
    popFrame = function()
      return table.remove(h.queued, 1)
    end
  }
  local decoder = {
    [0x1202] = { name = "ARM", dec = function(data, pos) return data[pos], pos + 1 end }
  }
  env.loadScript = function(path)
    local relative = string.match(path, "^/SCRIPTS/TOOLS/rfsuite%-core/(.+)$")
    assert(relative, "unexpected script path: " .. tostring(path))
    h.loads[relative] = (h.loads[relative] or 0) + 1
    if relative == failing then return nil, "cannot open " .. path end
    if relative == DECODER then return function() return decoder end end
    if relative == CRSF then return function() return crsf end end
    error("unexpected module: " .. relative)
  end
  h.drain = assert(loadfile("src/rfsuite/tasks/events/telemetry_bg/drain.lua", "t", env))()
  -- Wake the drain once per 0.1 s with one frame waiting each time, as a widget pass does.
  function h:run(count)
    local popped = 0
    for i = 1, count do
      self.queued[#self.queued + 1] = frame(i % 256, 1)
      popped = popped + (self.drain.wakeup(i / 10) or 0)
    end
    return popped
  end
  function h:armPublished()
    for _, entry in ipairs(self.published) do
      if entry.id == 0x1202 then return true end
    end
    return false
  end
  return h
end

local function scenario(name, run)
  local ok, err = pcall(run)
  check(ok, name .. " runs without error", ok and nil or tostring(err))
end

-- Control: both modules load once, frames are taken and the sensor reaches the radio.
scenario("both_load", function()
  local h = newDrain(nil)
  local popped = h:run(WAKEUPS)
  check(h.loads[DECODER] == 1, "both_load: decoder table loaded once", "loads=" .. tostring(h.loads[DECODER]))
  check(h.loads[CRSF] == 1, "both_load: CRSF module loaded once", "loads=" .. tostring(h.loads[CRSF]))
  check(popped > 0, "both_load: frames taken off the wire", "popped=" .. tostring(popped))
  check(h:armPublished(), "both_load: decoded sensor published")
end)

-- The decoder table does not load: it is asked for once, and the drain takes nothing.
scenario("decoder_missing", function()
  local h = newDrain(DECODER)
  local popped = h:run(WAKEUPS)
  print(string.format("decoder_missing: %d loads of the decoder table in %d wakeups",
    h.loads[DECODER] or 0, WAKEUPS))
  check(h.loads[DECODER] == 1, "decoder_missing: decoder table asked for once",
    "loads=" .. tostring(h.loads[DECODER]))
  check(popped == 0, "decoder_missing: nothing taken off the wire", "popped=" .. tostring(popped))
  check(not h:armPublished(), "decoder_missing: nothing published")
end)

-- The CRSF module does not load: it is asked for once, and the drain takes nothing.
scenario("crsf_missing", function()
  local h = newDrain(CRSF)
  local popped = h:run(WAKEUPS)
  print(string.format("crsf_missing: %d loads of the CRSF module in %d wakeups", h.loads[CRSF] or 0, WAKEUPS))
  check(h.loads[CRSF] == 1, "crsf_missing: CRSF module asked for once", "loads=" .. tostring(h.loads[CRSF]))
  check(popped == 0, "crsf_missing: nothing taken off the wire", "popped=" .. tostring(popped))
end)

-- A lost link resets the drain's link state, never the modules it holds: a module that is not
-- on the card is not asked for again because the link went.
scenario("reset_keeps_latch", function()
  local h = newDrain(DECODER)
  h:run(10)
  h.drain.reset()
  h:run(10)
  check(h.loads[DECODER] == 1, "reset_keeps_latch: decoder table still asked for once",
    "loads=" .. tostring(h.loads[DECODER]))
end)

if failures > 0 then
  print(string.format("%d of %d checks failed", failures, checks))
  os.exit(1)
end
print(string.format("PASS %d checks", checks))
