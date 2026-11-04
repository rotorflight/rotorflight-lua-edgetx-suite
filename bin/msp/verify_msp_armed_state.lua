-- Run from the repository root: lua5.3 bin/msp/verify_msp_armed_state.lua
-- Exercise the real loader, MSP runtime and armed reader without a named ARM sensor.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

-- FLIGHT_CONFIRM_SECONDS in tasks/events/runtime.lua is 5 seconds; getTime uses 10 ms ticks.
local HOLD_TICKS = 500
local STEP_TICKS = 10
local PAUSED = "MSP paused while ARMED"
local RESUMED = "MSP resumed after DISARM"

local function newRuntime(armflags, failedArmedLoads)
  local h = {
    armflags = armflags,
    rssi = 100,
    time = 1000,
    messages = {},
    armedLoadAttempts = 0,
    failedArmedLoads = failedArmedLoads or 0
  }
  local queue = { entries = {}, clears = 0, apiReads = 0 }
  function queue:add(entry)
    self.entries[#self.entries + 1] = entry
    if entry.command == 1 then self.apiReads = self.apiReads + 1 end
    return self
  end
  function queue:isProcessed()
    return #self.entries == 0
  end
  function queue:clear()
    self.clears = self.clears + 1
    local dropped = self.entries
    self.entries = {}
    for _, entry in ipairs(dropped) do
      if entry.errorHandler then entry.errorHandler(entry, "cleared") end
    end
  end
  function queue:processQueue()
    -- Replies arrive during processing, never inside add(), as with the real queue.
    local entry = table.remove(self.entries, 1)
    if not entry then return end
    local replies = {
      [1] = { 0, 12, 9 },
      [3] = { 4, 6, 0 },
      [160] = { 43, 0, 34, 0, 9, 81, 51, 52, 52, 56, 53, 49 }
    }
    local reply = assert(replies[entry.command], "unexpected command: " .. tostring(entry.command))
    if entry.processReply then entry.processReply(entry, reply) end
  end

  -- A separate environment gives every scenario a fresh singleton and armed change counter.
  local env = setmetatable({}, { __index = _G })
  env._G = env
  env.rfsuite = { session = {} }
  env.system = { getVersion = function() return { simulation = false } end }
  env.getTime = function() return h.time end
  env.getRSSI = function() return h.rssi end
  env.getValue = function() return 0 end
  local stubs = {
    ["lib/sensors.lua"] = {
      isSimulator = function() return false end,
      getValue = function(name)
        assert(name == "armflags", "unexpected sensor: " .. tostring(name))
        return h.armflags
      end
    },
    ["lib/log.lua"] = {
      tagged = function(tag)
        assert(tag == "rfsuite.msp", "unexpected log tag: " .. tostring(tag))
        return function(message) h.messages[#h.messages + 1] = message end
      end
    },
    ["tasks/msp/protocols.lua"] = function() return "crsf" end,
    ["tasks/msp/common.lua"] = { new = function() return {} end },
    ["tasks/msp/queue.lua"] = { new = function() return queue end },
    ["tasks/msp/service.lua"] = {},
    ["tasks/msp/cache.lua"] = { clear = function() end },
    ["lib/model_preferences.lua"] = { loadByMcuId = function() return nil, nil end }
  }
  local real = {
    ["lib/paths.lua"] = true,
    ["tasks/msp/runtime.lua"] = true,
    ["lib/armed.lua"] = true,
    ["tasks/msp/api/api_version.lua"] = true,
    ["tasks/msp/api/fc_version.lua"] = true,
    ["tasks/msp/api/uid.lua"] = true,
    ["lib/version.lua"] = true,
    ["lib/api_version.lua"] = true
  }
  env.loadScript = function(path)
    local relative = string.match(path, "^/SCRIPTS/RFSUITE/core/(.+)$")
    assert(relative, "unexpected script path: " .. tostring(path))
    if relative == "lib/armed.lua" then
      h.armedLoadAttempts = h.armedLoadAttempts + 1
      if h.failedArmedLoads > 0 then
        h.failedArmedLoads = h.failedArmedLoads - 1
        return nil
      end
    end
    if stubs[relative] ~= nil then return function() return stubs[relative] end end
    assert(real[relative], "unexpected module: " .. relative)
    return assert(loadfile("src/rfsuite/" .. relative, "t", env))
  end
  h.require = assert(loadfile("src/rfsuite/lib/require.lua", "t", env))()
  h.runtime = assert(h.require("tasks/msp/runtime.lua"))
  h.state = h.runtime.getState()
  -- Begin before the first connect edge, without pre-initializing the transport or queue.
  h.state.lastConnected = false
  h.queue = queue
  function h:tick(count, step)
    for _ = 1, count or 1 do
      self.time = self.time + (step or STEP_TICKS)
      self.runtime.tick()
    end
  end
  function h:logged(message)
    local count = 0
    for _, text in ipairs(self.messages) do
      if text == message then count = count + 1 end
    end
    return count
  end
  return h
end

local function scenario(name, run)
  local function eq(actual, expected, label)
    equal(actual, expected, name .. " " .. label)
  end
  local ok, err = pcall(run, eq)
  eq(ok and "completed" or tostring(err), "completed", "runs without error")
end

scenario("armed_cold", function(eq)
  local h = newRuntime(1)
  h:tick(2)
  eq(h.state.lastArmed, true, "armed from armflags")
  eq(h.queue.clears >= 1, true, "queue cleared")
  eq(h:logged(PAUSED), 1, "pause logged once")
  eq(h.queue.apiReads, 0, "no API read queued")
end)

scenario("never_uncertain", function(eq)
  local h = newRuntime(nil)
  h:tick(2)
  eq(h.state.lastArmed ~= true, true, "never armed remains disarmed")
  eq(h.queue.clears, 0, "queue not cleared")
  eq(h.queue.apiReads, 1, "API read queued")
  eq(h.state.values.apiVersion, "12.09", "API reply processed")
  eq(h.require("lib/armed.lua").isUncertain(), true, "reader reports uncertainty")
end)

scenario("reconnect_armed", function(eq)
  local h = newRuntime(1)
  h:tick(2)
  h.rssi = 0
  h:tick()
  h.armflags, h.rssi = nil, 100
  h:tick(3)
  eq(h.state.lastArmed, true, "reconnect uncertainty holds armed")
  eq(h.queue.apiReads, 0, "reconnect queues no API read")
  eq(h:logged(RESUMED), 0, "reconnect does not announce disarm")
  h.armflags = 0
  h:tick(2)
  eq(h.state.lastArmed, false, "current disarm releases hold")
  eq(h:logged(RESUMED), 1, "resume logged once")
  eq(h.queue.apiReads, 1, "API read queued after disarm")
end)

scenario("stable_count", function(eq)
  local h = newRuntime(1)
  h:tick(5)
  eq(h.require("lib/armed.lua").changeCount(), 0, "stable readings count no changes")
end)

scenario("uncertain_short", function(eq)
  local h = newRuntime(1)
  h:tick(2)
  h.armflags = nil
  h:tick()
  h:tick(1, HOLD_TICKS - 1)
  eq(h.state.lastArmed, true, "still armed one clock tick before bound")
  eq(h.queue.apiReads, 0, "short uncertainty queues no API read")
  eq(h:logged(RESUMED), 0, "short uncertainty does not announce disarm")
end)

scenario("uncertain_bound", function(eq)
  local h = newRuntime(1)
  h:tick(2)
  h.armflags = nil
  h:tick()
  h:tick(HOLD_TICKS / STEP_TICKS)
  eq(h.state.lastArmed, false, "released at bound")
  eq(h.queue.apiReads, 1, "API read queued at bound")
  h:tick(2)
  eq(h.state.lastArmed, false, "still disarmed beyond bound")
  eq(h.queue.apiReads, 1, "API read remains queued only once")
  eq(h:logged(RESUMED), 1, "bound logs resume once")
end)

scenario("current_reading_resets_hold", function(eq)
  local h = newRuntime(1)
  h:tick(2)
  h.armflags = nil
  h:tick()
  h:tick(1, HOLD_TICKS - 1)
  h.armflags = 1
  h:tick()
  h.armflags = nil
  h:tick()
  h:tick(1, HOLD_TICKS - 1)
  eq(h.state.lastArmed, true, "current armed reading restarts uncertainty interval")
  eq(h.queue.apiReads, 0, "separate gaps do not add up")
  h:tick(1, 1)
  eq(h.state.lastArmed, false, "new interval releases at its own bound")
  eq(h.queue.apiReads, 1, "API read follows new bound")
end)

scenario("link_gap_resets_hold", function(eq)
  local h = newRuntime(1)
  h:tick(2)
  h.armflags = nil
  h:tick()
  h:tick(1, HOLD_TICKS - 100)
  h.rssi = 0
  h:tick()
  h:tick(1, HOLD_TICKS * 2)
  eq(h.state.lastArmed, true, "link-down time does not release armed")
  h.rssi = 100
  h:tick(3, 100)
  eq(h.state.lastArmed, true, "reconnect starts a fresh hold interval")
  eq(h.queue.apiReads, 0, "no API read during reconnect hold")
  h.armflags = 1
  h:tick(2)
  eq(h.state.lastArmed, true, "arming flags arriving within seconds preserve armed")
  eq(h:logged(RESUMED), 0, "no false disarm across long link gap")
end)

scenario("armed_load_backoff", function(eq)
  local h = newRuntime(nil, 2)
  h:tick()
  eq(h.armedLoadAttempts, 1, "first load attempted")
  h:tick(1, 399)
  eq(h.armedLoadAttempts, 1, "no retry before four seconds")
  h:tick(1, 1)
  eq(h.armedLoadAttempts, 2, "retry at four seconds")
  h:tick(1, 599)
  eq(h.armedLoadAttempts, 2, "second failure waits six seconds")
  h.armflags = 1
  h:tick(1, 1)
  eq(h.armedLoadAttempts, 3, "reader retried after second backoff")
  eq(h.state.lastArmed, true, "recovered reader observes armed")
  eq(h:logged(PAUSED), 1, "recovered reader pauses MSP")
  h:tick(5)
  eq(h.armedLoadAttempts, 3, "successful reader retained")
end)

print("MSP armed state: " .. checks .. " assertions, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
