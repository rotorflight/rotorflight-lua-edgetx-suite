-- Run from the repository root: lua5.3 bin/telemetry/verify_drain_failed_load.lua
-- Drive the real custom-telemetry drain with one of its two modules failing to load, and count
-- how often it goes back to the card for it. The same for the pass a widget runs while its connect
-- tasks hold the full one back (wakeupArmingFlags), which shares the drain's loads; and one level up,
-- telemetry_bg/tasks.lua loading drain.lua itself in either pass.
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
    local relative = string.match(path, "^/SCRIPTS/RFSUITE/core/(.+)$")
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
      local n = self.drain[self.pass or "wakeup"](self.t) or 0
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

-- The armed-state pass loads through the same wait: a module that is not on the card is asked for
-- at most once a second and nothing is taken; a load that fails once is asked for again and the
-- arming flags are published within about a second.
for _, module in ipairs({ DECODER, CRSF }) do
  local label = "armed_pass_" .. (module == DECODER and "decoder" or "crsf")
  scenario(label .. "_missing", function()
    local h = newDrain(module)
    h.pass = "wakeupArmingFlags"
    local popped = h:run(WAKEUPS)
    check((h.loads[module] or 0) <= MAX_LOADS and (h.loads[module] or 0) >= 2,
      label .. "_missing: asked for again, at most once a second", "loads=" .. tostring(h.loads[module]))
    check(popped == 0, label .. "_missing: nothing taken off the wire", "popped=" .. tostring(popped))
    check(not h:armPublished(), label .. "_missing: nothing published")
  end)
  scenario(label .. "_fails_once", function()
    local h = newDrain(module, 1, 100)
    h.pass = "wakeupArmingFlags"
    h:run(WAKEUPS)
    check(h.loads[module] == 2, label .. "_fails_once: asked for again after the failure",
      "loads=" .. tostring(h.loads[module]))
    check(h.firstPopAt ~= nil and h.firstPopAt <= 1.5, label .. "_fails_once: frames taken within about a second",
      "first pop at " .. tostring(h.firstPopAt))
    check(h:armPublished(), label .. "_fails_once: the arming flags published")
  end)
end

-- One level up: telemetry_bg/tasks.lua loading drain.lua itself, for both of its passes. A load
-- that fails once -- a file that cannot be read, or a chunk that raises as the instruction limit
-- does -- is asked for again within about a second and the drain then runs; a drain that is not on
-- the card is asked for at most once a second. `pass` is "wakeup" or "wakeupConnecting".
local DRAIN = "tasks/events/telemetry_bg/drain.lua"
local function newTasks(pass, times, raises)
  local h = { loads = {}, t = 0, drainCalls = 0 }
  local env = setmetatable({}, { __index = _G })
  env._G = env
  env.rfsuite = { loadMode = "t", paths = { core = "/CORE" } }
  env.getTime = function() return math.floor(h.t * 100 + 0.5) end
  local drain = {
    remoteAlive = function() return false end,
    wakeup = function() h.drainCalls = h.drainCalls + 1; return 0 end,
    wakeupArmingFlags = function() h.drainCalls = h.drainCalls + 1; return 0 end,
  }
  env.loadScript = function(path)
    local relative = assert(string.match(path, "^/CORE/(.+)$"), "unexpected script path: " .. tostring(path))
    h.loads[relative] = (h.loads[relative] or 0) + 1
    if relative == DRAIN then
      if times == nil or h.loads[relative] <= times then
        if raises then return function() error("CPU limit") end end
        return nil, "cannot open " .. path
      end
      return function() return drain end
    end
    return nil, "cannot open " .. path   -- smart.lua and the teller: not part of this check
  end
  local tasks = assert(loadfile("src/rfsuite/tasks/events/telemetry_bg/tasks.lua", "t", env))()
  function h:run(count)
    for _ = 1, count do
      self.t = self.t + STEP
      tasks[pass]()
      if self.drainCalls > 0 and not self.firstCallAt then self.firstCallAt = self.t end
    end
  end
  return h
end

for _, pass in ipairs({ "wakeup", "wakeupConnecting" }) do
  for _, raises in ipairs({ false, true }) do
    local label = "tasks_" .. pass .. (raises and "_drain_raises_once" or "_drain_fails_once")
    scenario(label, function()
      local h = newTasks(pass, 1, raises)
      h:run(WAKEUPS)
      check(h.loads[DRAIN] == 2, label .. ": drain.lua asked for again after the failure",
        "loads=" .. tostring(h.loads[DRAIN]))
      check(h.firstCallAt ~= nil and h.firstCallAt <= 1.5, label .. ": the drain runs within about a second",
        "first call at " .. tostring(h.firstCallAt))
    end)
  end
  local label = "tasks_" .. pass .. "_drain_missing"
  scenario(label, function()
    local h = newTasks(pass, nil, false)
    h:run(WAKEUPS)
    check((h.loads[DRAIN] or 0) <= MAX_LOADS and (h.loads[DRAIN] or 0) >= 2,
      label .. ": drain.lua asked for again, at most once a second", "loads=" .. tostring(h.loads[DRAIN]))
    check(h.drainCalls == 0, label .. ": nothing runs without it")
  end)
end

-- The other two modules telemetry_bg/tasks.lua loads in its full pass: SmartFuel, and the
-- adjustment teller while adjustment announcements are on. The drain loads; `target` is the module
-- that fails `times` times (nil: always), by a file that cannot be read or, with `raises`, by a
-- chunk that raises. A module that failed once is asked for again within about a second and then
-- runs; one that is not on the card is asked for at most once a second, and the drain keeps
-- decoding meanwhile.
local SMART = "tasks/events/telemetry_bg/smart.lua"
local TELLER = "tasks/events/telemetry_bg/adjustments.lua"
local function newStages(target, times, raises, settingOff, alsoFailing)
  local h = { loads = {}, t = 0, calls = {}, lines = {} }
  local env = setmetatable({}, { __index = _G })
  env._G = env
  env.rfsuite = {
    loadMode = "t", paths = { core = "/CORE" },
    preferences = { audio_events = { adjustment_events = not settingOff } },
    Log = { emit = function(tag, msg, level) h.lines[#h.lines + 1] = level .. " " .. tag .. " " .. msg end },
  }
  h.root = env.rfsuite
  function h:count(level, text)
    local n = 0
    for _, line in ipairs(self.lines) do
      if string.sub(line, 1, #level + 1) == level .. " " and string.find(line, text, 1, true) then n = n + 1 end
    end
    return n
  end
  env.getTime = function() return math.floor(h.t * 100 + 0.5) end
  local function count(name) h.calls[name] = (h.calls[name] or 0) + 1 end
  local modules = {
    [DRAIN] = {
      remoteAlive = function() return false end,
      wakeup = function() count(DRAIN); return 0 end,
    },
    [SMART] = { wakeup = function() count(SMART) end },
    [TELLER] = { wakeup = function() count(TELLER) end },
  }
  env.loadScript = function(path)
    local relative = assert(string.match(path, "^/CORE/(.+)$"), "unexpected script path: " .. tostring(path))
    h.loads[relative] = (h.loads[relative] or 0) + 1
    local also = alsoFailing and alsoFailing[relative]
    if also and h.loads[relative] <= also then return nil, "cannot open " .. path end
    if relative == target and (times == nil or h.loads[relative] <= times) then
      if raises then return function() error("CPU limit") end end
      return nil, "cannot open " .. path
    end
    local mod = modules[relative]
    if mod == nil then return nil, "cannot open " .. path end
    return function() return mod end
  end
  local tasks = assert(loadfile("src/rfsuite/tasks/events/telemetry_bg/tasks.lua", "t", env))()
  h.tasks = tasks
  function h:run(n)
    for _ = 1, n do
      self.t = self.t + STEP
      tasks.wakeup()
      if (self.calls[target] or 0) > 0 and not self.firstCallAt then self.firstCallAt = self.t end
    end
  end
  return h
end

local LOGNAME = { [SMART] = "SmartFuel", [TELLER] = "the adjustment teller" }
local LOGTAG = { [SMART] = "rfsuite.smart", [TELLER] = "rfsuite.adjust" }
for _, target in ipairs({ SMART, TELLER }) do
  local name = target == SMART and "smart" or "teller"
  for _, raises in ipairs({ false, true }) do
    local label = "tasks_" .. name .. (raises and "_raises_once" or "_fails_once")
    scenario(label, function()
      local h = newStages(target, 1, raises)
      h:run(WAKEUPS)
      check(h.loads[target] == 2, label .. ": asked for again after the failure",
        "loads=" .. tostring(h.loads[target]))
      check(h.firstCallAt ~= nil and h.firstCallAt <= 1.5, label .. ": runs within about a second",
        "first call at " .. tostring(h.firstCallAt))
      check(h:count("warn", LOGTAG[target] .. " dash: " .. LOGNAME[target] .. " failed to load") == 1
          or h:count("warn", LOGTAG[target] .. " tool: " .. LOGNAME[target] .. " failed to load") == 1,
        label .. ": the failure logged once, under the module's own tag",
        table.concat(h.lines, " | "))
      check(h:count("info", LOGNAME[target] .. " loaded after a failed attempt") == 1,
        label .. ": the recovery logged once", table.concat(h.lines, " | "))
    end)
  end
  local label = "tasks_" .. name .. "_missing"
  scenario(label, function()
    local h = newStages(target, nil, false)
    h:run(WAKEUPS)
    local loads = h.loads[target] or 0
    check(loads >= 2 and loads <= MAX_LOADS, label .. ": asked for again, at most once a second",
      "loads=" .. tostring(loads))
    check((h.calls[DRAIN] or 0) >= WAKEUPS - 2 * MAX_LOADS, label .. ": the drain keeps decoding meanwhile",
      "drain calls=" .. tostring(h.calls[DRAIN]))
    check(h:count("warn", LOGNAME[target] .. " failed to load") == 1, label .. ": the failure logged once in 10 s",
      table.concat(h.lines, " | "))
  end)
end

-- On a host whose passes come more than a second apart, a module that stays missing is asked for
-- on at most every other pass: the drain still decodes on the passes between.
for _, target in ipairs({ SMART, TELLER }) do
  local label = "tasks_" .. (target == SMART and "smart" or "teller") .. "_missing_slow_passes"
  scenario(label, function()
    local h = newStages(target, nil, false)
    for _ = 1, 40 do
      h.t = h.t + 1.2
      h.tasks.wakeup()
    end
    check((h.calls[DRAIN] or 0) >= 15, label .. ": the drain decodes between the retries",
      "drain calls=" .. tostring(h.calls[DRAIN]) .. " loads=" .. tostring(h.loads[target]))
    check((h.loads[target] or 0) >= 15, label .. ": the module is still asked for again",
      "loads=" .. tostring(h.loads[target]))
  end)
end

-- SmartFuel missing for good and the teller failing once, on passes 1.2 s apart: SmartFuel's retry
-- gives the teller a slot, so the teller loads again and runs; SmartFuel is still asked for, and the
-- drain still decodes between the retries.
scenario("tasks_smart_missing_teller_fails_once_slow_passes", function()
  local h = newStages(SMART, nil, false, false, { [TELLER] = 1 })
  for _ = 1, 40 do
    h.t = h.t + 1.2
    h.tasks.wakeup()
  end
  check((h.loads[TELLER] or 0) >= 2, "tasks_smart_missing_teller_fails_once_slow_passes: the teller is asked for again",
    "teller loads=" .. tostring(h.loads[TELLER]) .. " smart loads=" .. tostring(h.loads[SMART]))
  check((h.calls[TELLER] or 0) > 0, "tasks_smart_missing_teller_fails_once_slow_passes: the teller runs")
  check((h.loads[SMART] or 0) >= 10, "tasks_smart_missing_teller_fails_once_slow_passes: SmartFuel still asked for",
    "smart loads=" .. tostring(h.loads[SMART]))
  check((h.calls[DRAIN] or 0) >= 15, "tasks_smart_missing_teller_fails_once_slow_passes: the drain decodes",
    "drain calls=" .. tostring(h.calls[DRAIN]))
end)

-- The same with the announcements switched off after the teller failed: SmartFuel's retry is not
-- held back for a teller that is no longer asked for.
scenario("tasks_smart_missing_teller_failed_then_off", function()
  local h = newStages(SMART, nil, false, false, { [TELLER] = 1 })
  for _ = 1, 4 do h.t = h.t + 1.2; h.tasks.wakeup() end
  h.root.preferences.audio_events.adjustment_events = false
  local before = h.loads[SMART] or 0
  for _ = 1, 30 do h.t = h.t + 1.2; h.tasks.wakeup() end
  check((h.loads[SMART] or 0) - before >= 10, "tasks_smart_missing_teller_failed_then_off: SmartFuel still asked for",
    "smart loads " .. tostring(before) .. " -> " .. tostring(h.loads[SMART]))
end)

-- With adjustment announcements off the teller is never loaded, and its stage spends one pass,
-- once: the drain runs from the fourth wakeup on.
scenario("tasks_teller_setting_off", function()
  local h = newStages(nil, nil, false, true)
  local firstDrain
  for i = 1, WAKEUPS do
    h:run(1)
    if (h.calls[DRAIN] or 0) > 0 and not firstDrain then firstDrain = i end
  end
  check((h.loads[TELLER] or 0) == 0, "tasks_teller_setting_off: the teller is not loaded",
    "loads=" .. tostring(h.loads[TELLER]))
  check(firstDrain == 4, "tasks_teller_setting_off: the drain runs from the fourth wakeup",
    "first drain at wakeup " .. tostring(firstDrain))
end)

-- A teller whose load failed is replaced by the in-flight tuning overlay's own instance as soon as
-- there is one, without a load of its own and without a recovery line.
scenario("tasks_teller_failed_then_shared", function()
  local h = newStages(TELLER, nil, false)
  h:run(5)
  local shared = { wakeup = function() h.calls.shared = (h.calls.shared or 0) + 1 end }
  h.root.adjustmentAnnouncer = shared
  local loads = h.loads[TELLER]
  h:run(WAKEUPS)
  check(h.loads[TELLER] == loads, "tasks_teller_failed_then_shared: no further load once shared",
    "loads " .. tostring(loads) .. " -> " .. tostring(h.loads[TELLER]))
  check((h.calls.shared or 0) > 0, "tasks_teller_failed_then_shared: the shared teller runs")
  check(h:count("info", "the adjustment teller loaded") == 0, "tasks_teller_failed_then_shared: no recovery line",
    table.concat(h.lines, " | "))
end)

if failures > 0 then
  print(string.format("%d of %d checks failed", failures, checks))
  os.exit(1)
end
print(string.format("PASS %d checks", checks))
