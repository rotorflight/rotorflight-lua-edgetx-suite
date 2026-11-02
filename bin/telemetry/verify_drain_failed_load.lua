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
local WAKEUPS = 100      -- one every 0.1 s: 10 s
local STEP = 0.1
-- At most one ask per second over the 10 s, plus the first.
local MAX_LOADS = 11

-- One custom telemetry frame: frame id, then sensor 0x1202 (ARM) carrying one byte.
local function frame(id, armed)
  return { 0, 0, id, 0x12, 0x02, armed }
end

-- `failing` names the module that does not load, `times` how many loads of it fail (nil: all);
-- `failing` nil loads both. `raises` makes a failing load a chunk that raises while it runs, as
-- the radio's instruction limit does, instead of a file that cannot be read.
local function newDrain(failing, times, firstId, raises)
  local h = { loads = {}, published = {}, queued = {}, t = 0, frames = (firstId or 1) - 1 }
  local env = setmetatable({}, { __index = _G })
  env._G = env
  env.bit32 = bit32
  env.rfsuite = { loadMode = "t", paths = dofile("src/rfsuite/lib/paths.lua") }
  env.getValue = function() return nil end
  env.setTelemetryValue = function(id, _, _, value)
    h.published[#h.published + 1] = { id = id, value = value, t = h.t }
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
    if relative == failing and (times == nil or h.loads[relative] <= times) then
      if raises then return function() error("CPU limit") end end
      return nil, "cannot open " .. path
    end
    if relative == DECODER then return function() return decoder end end
    if relative == CRSF then return function() return crsf end end
    error("unexpected module: " .. relative)
  end
  h.drain = assert(loadfile("src/rfsuite/tasks/events/telemetry_bg/drain.lua", "t", env))()
  -- Wake the drain once per 0.1 s with one frame waiting each time, as a widget pass does. The
  -- clock runs on across calls.
  function h:run(count)
    local popped = 0
    for _ = 1, count do
      self.t = self.t + STEP
      self.frames = self.frames + 1
      self.queued[#self.queued + 1] = frame(self.frames % 256, 1)
      local n = self.drain.wakeup(self.t) or 0
      if n > 0 and not self.firstPopAt then self.firstPopAt = self.t end
      popped = popped + n
    end
    return popped
  end
  function h:lastPublished(id)
    local value
    for _, entry in ipairs(self.published) do
      if entry.id == id then value = entry.value end
    end
    return value
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

-- The decoder table does not load: it is asked for at most once a second, and the drain takes
-- nothing.
scenario("decoder_missing", function()
  local h = newDrain(DECODER)
  local popped = h:run(WAKEUPS)
  print(string.format("decoder_missing: %d loads of the decoder table in %d wakeups (%.0f s)",
    h.loads[DECODER] or 0, WAKEUPS, WAKEUPS * STEP))
  check((h.loads[DECODER] or 0) <= MAX_LOADS, "decoder_missing: decoder table asked for at most once a second",
    "loads=" .. tostring(h.loads[DECODER]))
  check((h.loads[DECODER] or 0) >= 2, "decoder_missing: decoder table asked for again",
    "loads=" .. tostring(h.loads[DECODER]))
  check(popped == 0, "decoder_missing: nothing taken off the wire", "popped=" .. tostring(popped))
  check(not h:armPublished(), "decoder_missing: nothing published")
end)

-- The CRSF module does not load: the same.
scenario("crsf_missing", function()
  local h = newDrain(CRSF)
  local popped = h:run(WAKEUPS)
  print(string.format("crsf_missing: %d loads of the CRSF module in %d wakeups (%.0f s)",
    h.loads[CRSF] or 0, WAKEUPS, WAKEUPS * STEP))
  check((h.loads[CRSF] or 0) <= MAX_LOADS, "crsf_missing: CRSF module asked for at most once a second",
    "loads=" .. tostring(h.loads[CRSF]))
  check((h.loads[CRSF] or 0) >= 2, "crsf_missing: CRSF module asked for again",
    "loads=" .. tostring(h.loads[CRSF]))
  check(popped == 0, "crsf_missing: nothing taken off the wire", "popped=" .. tostring(popped))
end)

-- A load that fails once and then succeeds -- the loader's pcall also catches the radio's
-- instruction limit -- does not switch decoding off: frames are taken again within about a
-- second of the failure. The link's frame ids start at 100 and run without a gap, so the skip
-- counter must stay at 0: the late first frame is not a frame the link lost.
for _, case in ipairs({ { DECODER, false }, { CRSF, false }, { DECODER, true }, { CRSF, true } }) do
  local module, raises = case[1], case[2]
  local label = (module == DECODER and "decoder" or "crsf") .. (raises and "_raises_once" or "_fails_once")
  scenario(label, function()
    local h = newDrain(module, 1, 100, raises)
    h:run(WAKEUPS)
    print(string.format("%s: %d loads, first frame taken at %.1f s", label, h.loads[module] or 0,
      h.firstPopAt or -1))
    check(h.loads[module] == 2, label .. ": asked for again after the failure",
      "loads=" .. tostring(h.loads[module]))
    check(h.firstPopAt ~= nil and h.firstPopAt <= 1.5, label .. ": frames taken within about a second",
      "first pop at " .. tostring(h.firstPopAt))
    check(h:armPublished(), label .. ": decoded sensor published")
    local skp = h:lastPublished(0xEE02)
    check(skp == 0, label .. ": no frame counted as skipped", "*Skp=" .. tostring(skp))
  end)
end

-- Control for the skip check above: a real gap in the link's frame ids, after the drain has been
-- taking frames for a while, is counted.
scenario("gap_counted", function()
  local h = newDrain(nil, nil, 100)
  h:run(30)
  h.frames = h.frames + 5
  h:run(30)
  local skp = h:lastPublished(0xEE02)
  check(skp ~= nil and skp >= 1, "gap_counted: a gap in the frame ids counts as skipped", "*Skp=" .. tostring(skp))
end)

-- A lost link resets the drain's link state, not the wait: a module that is not on the card is
-- not asked for again because the link went.
scenario("reset_keeps_wait", function()
  local h = newDrain(DECODER)
  h:run(3)
  h.drain.reset()
  h:run(3)
  check(h.loads[DECODER] == 1, "reset_keeps_wait: decoder table asked for once in 0.6 s across a reset",
    "loads=" .. tostring(h.loads[DECODER]))
end)

if failures > 0 then
  print(string.format("%d of %d checks failed", failures, checks))
  os.exit(1)
end
print(string.format("PASS %d checks", checks))
