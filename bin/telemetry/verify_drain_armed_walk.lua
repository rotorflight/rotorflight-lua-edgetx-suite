-- Run from the repository root: lua5.3 bin/telemetry/verify_drain_armed_walk.lua
-- Drive the real custom-telemetry drain with hand-made frames and read what it publishes as the
-- armed state:
--   newer status   in the armed-state pass (wakeupArmingFlags), a newer frame's armed System Status
--                  word is not followed by an older frame's disarmed arming flags; the control
--                  with a disarmed word publishes the older flags as before;
--   paused script  the background function script's drain (M.wakeup with decodeAll) does not take
--                  a disarmed reading from the frames waiting after a pause of more than a second,
--                  and takes one again from the next pass; the control is the widget's drain, which
--                  keeps taking it across the same gap (a slow radio);
--   decoder raises the armed-state pass puts the adjustment pair back when a decoder raises during
--                  its walk, and lets the error through; the control is a walk that does not raise.
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

local ARM, STAT, ADJ, BOOM = 0x1202, 0x1230, 0x1220, 0x12FF

-- One custom telemetry frame: destination, origin, frame id, then (sensor id, one byte) entries.
local function frame(id, entries)
  local data = { 0, 0, id }
  for _, e in ipairs(entries) do
    data[#data + 1] = (e[1] >> 8) & 0xFF
    data[#data + 1] = e[1] & 0xFF
    data[#data + 1] = e[2]
  end
  return data
end

local function newDrain()
  local h = { published = {}, queued = {}, frames = 0 }
  local env = setmetatable({}, { __index = _G })
  env._G = env
  env.bit32 = bit32
  env.rfsuite = { loadMode = "t", paths = dofile("src/rfsuite/lib/paths.lua") }
  env.getValue = function() return nil end
  env.setTelemetryValue = function(id, _, _, value)
    h.published[#h.published + 1] = { id = id, value = value }
  end
  local crsf = { popFrame = function() return table.remove(h.queued, 1) end }
  local function oneByte(data, pos) return data[pos], pos + 1 end
  local decoder = {
    [ARM] = { name = "ARM", dec = oneByte },
    [STAT] = { name = "STAT", dec = oneByte },
    -- The adjustment decoder writes the teller's pair before anything decides about publishing,
    -- as lib/rf2tlm_sensors.lua's decAdjFunc does.
    [ADJ] = { name = "ADJ", dec = function(data, pos)
      local report = env.rfsuite.adjustmentReport
      if type(report) == "table" then report[1], report[2] = data[pos], data[pos] end
      return data[pos], pos + 1
    end },
    [BOOM] = { name = "BOOM", dec = function() error("decoder raised") end },
  }
  env.loadScript = function(path)
    if string.find(path, "rf2tlm_sensors.lua", 1, true) then return function() return decoder end end
    if string.find(path, "crsf.lua", 1, true) then return function() return crsf end end
    error("unexpected module: " .. path)
  end
  h.env = env
  h.drain = assert(loadfile("src/rfsuite/tasks/events/telemetry_bg/drain.lua", "t", env))()
  function h:push(entries)
    self.frames = self.frames + 1
    self.queued[#self.queued + 1] = frame(self.frames % 256, entries)
  end
  function h:published_values(id)
    local values = {}
    for _, e in ipairs(self.published) do
      if e.id == id then values[#values + 1] = e.value end
    end
    return values
  end
  -- Load both modules (one wakeup each) and end with a pass that empties the queue, so the
  -- frames pushed afterwards count as fresh.
  function h:prime(pass, t)
    self.drain[pass](t); self.drain[pass](t + 0.1); self.drain[pass](t + 0.2)
    return t + 0.2
  end
  return h
end

local function scenario(name, run)
  local ok, err = pcall(run)
  check(ok, name .. " runs without error", ok and nil or tostring(err))
end

-- newer status: older frame ARM=0, newer frame STAT armed, both in one fresh pass.
scenario("newer_status_armed", function()
  local h = newDrain()
  local t = h:prime("wakeupArmingFlags", 0.1)
  h:push({ { ARM, 0 } })
  h:push({ { STAT, 1 } })
  local popped, found = h.drain.wakeupArmingFlags(t + 0.1)
  check(popped == 2, "newer_status_armed: both frames taken", "popped=" .. tostring(popped))
  local stat = h:published_values(STAT)
  check(#stat == 1 and stat[1] == 1, "newer_status_armed: the armed System Status word is published")
  check(#h:published_values(ARM) == 0, "newer_status_armed: the older disarmed arming flags are not",
    "ARM published " .. #h:published_values(ARM) .. " time(s)")
  check(found == "STAT", "newer_status_armed: the pass reports the System Status word", tostring(found))
end)

-- Control: the newer word disarmed too -- the older flags are published as before.
scenario("newer_status_disarmed", function()
  local h = newDrain()
  local t = h:prime("wakeupArmingFlags", 0.1)
  h:push({ { ARM, 0 } })
  h:push({ { STAT, 0 } })
  local _, found = h.drain.wakeupArmingFlags(t + 0.1)
  local arm = h:published_values(ARM)
  check(#arm == 1 and arm[1] == 0, "newer_status_disarmed: the older disarmed arming flags are published")
  check(found == "ARM", "newer_status_disarmed: the pass reports the arming flags", tostring(found))
end)

-- Control: an older ARM armed behind a newer armed word is published (only a disarm is held back).
scenario("newer_status_older_armed", function()
  local h = newDrain()
  local t = h:prime("wakeupArmingFlags", 0.1)
  h:push({ { ARM, 1 } })
  h:push({ { STAT, 1 } })
  h.drain.wakeupArmingFlags(t + 0.1)
  local arm = h:published_values(ARM)
  check(#arm == 1 and arm[1] == 1, "newer_status_older_armed: the older armed arming flags are published")
end)

-- paused script: a pass with nothing waiting, then frames from before a 5 s gap.
for _, case in ipairs({ { "paused_script", true }, { "widget_gap", nil } }) do
  local label, decodeAll = case[1], case[2]
  scenario(label, function()
    local h = newDrain()
    local t = 0.1
    h.drain.wakeup(t, decodeAll); h.drain.wakeup(t + 0.1, decodeAll); h.drain.wakeup(t + 0.2, decodeAll)
    t = t + 0.2
    h:push({ { ARM, 0 } })
    h:push({ { ARM, 0 } })
    t = t + 5.0
    h.drain.wakeup(t, decodeAll)
    local after = #h:published_values(ARM)
    if decodeAll then
      check(after == 0, label .. ": no disarm taken from the frames waiting after the pause",
        "ARM published " .. after .. " time(s)")
    else
      check(after >= 1, label .. ": the widget's drain takes the disarm across the gap (slow radio)",
        "ARM published " .. after .. " time(s)")
    end
    if decodeAll then
      -- The next pass's frames are fresh again: the disarm is taken.
      h:push({ { ARM, 0 } })
      h.drain.wakeup(t + 0.1, decodeAll)
      check(#h:published_values(ARM) > after, label .. ": the next pass takes a disarm again")
      -- An armed reading is taken from the waiting frames at once.
      h:push({ { ARM, 1 } })
      h.drain.wakeup(t + 6.0, decodeAll)
      local arm = h:published_values(ARM)
      check(arm[#arm] == 1, label .. ": an armed reading after a pause is taken at once")
    end
  end)
end

-- decoder raises: an adjustment entry, then an entry whose decoder raises, in the newest frame.
scenario("decoder_raises", function()
  local h = newDrain()
  local t = h:prime("wakeupArmingFlags", 0.1)
  local report = { 14, 100 }
  h.env.rfsuite.adjustmentReport = report
  h:push({ { ADJ, 7 }, { BOOM, 0 } })
  local ok, err = pcall(h.drain.wakeupArmingFlags, t + 0.1)
  check(not ok and string.find(tostring(err), "decoder raised", 1, true) ~= nil,
    "decoder_raises: the error goes on to the caller", tostring(err))
  check(h.env.rfsuite.adjustmentReport == report and report[1] == 14 and report[2] == 100,
    "decoder_raises: the adjustment pair is put back", tostring(report[1]) .. "," .. tostring(report[2]))
  -- The next pass is unaffected.
  h:push({ { ARM, 1 } })
  local _, found = h.drain.wakeupArmingFlags(t + 0.2)
  check(found == "ARM", "decoder_raises: the next pass publishes the arming flags", tostring(found))
end)

-- Control: the same walk without the raise also leaves an existing pair as it found it.
scenario("existing_report_kept", function()
  local h = newDrain()
  local t = h:prime("wakeupArmingFlags", 0.1)
  local report = { 14, 100 }
  h.env.rfsuite.adjustmentReport = report
  h:push({ { ADJ, 7 }, { ARM, 0 } })
  h.drain.wakeupArmingFlags(t + 0.1)
  check(h.env.rfsuite.adjustmentReport == report and report[1] == 14 and report[2] == 100,
    "existing_report_kept: the adjustment pair is as it was")
end)

if failures > 0 then
  print(string.format("%d of %d checks failed", failures, checks))
  os.exit(1)
end
print(string.format("PASS %d checks", checks))
