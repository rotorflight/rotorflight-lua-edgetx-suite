-- Run from the repository root: lua5.3 bin/msp/verify_msp_version_deps_retry.lua
-- Drive the real loader and MSP runtime with one of the API version read's modules failing to
-- load, and count how often the runtime goes back to the card for it.
local checks, failures = 0, 0
local function check(ok, label, detail)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label .. (detail and (": " .. detail) or ""))
  end
end

-- getTime() counts 10 ms ticks; the runtime is ticked every 0.1 s, as a widget pass does.
local STEP_TICKS = 10
local FAILING = "tasks/msp/api/api_version.lua"

local function newRuntime(failedLoads)
  local h = { rssi = 100, time = 1000, loads = 0, failedLoads = failedLoads, printed = 0 }
  local queue = { entries = {}, apiReads = 0 }
  function queue:add(entry)
    self.entries[#self.entries + 1] = entry
    if entry.command == 1 then self.apiReads = self.apiReads + 1 end
    return self
  end
  function queue:isProcessed()
    return #self.entries == 0
  end
  function queue:clear()
    local dropped = self.entries
    self.entries = {}
    for _, entry in ipairs(dropped) do
      if entry.errorHandler then entry.errorHandler(entry, "cleared") end
    end
  end
  function queue:processQueue()
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

  local env = setmetatable({}, { __index = _G })
  env._G = env
  env.rfsuite = { session = {} }
  env.system = { getVersion = function() return { simulation = false } end }
  env.getTime = function() return h.time end
  env.getRSSI = function() return h.rssi end
  env.getValue = function() return 0 end
  -- lib/require.lua reports every failed load on the console; count the lines instead.
  env.print = function() h.printed = h.printed + 1 end
  local stubs = {
    ["lib/sensors.lua"] = {
      isSimulator = function() return false end,
      getValue = function() return 0 end
    },
    ["lib/log.lua"] = {
      tagged = function() return function() end end,
      emitf = function() end
    },
    ["tasks/msp/protocols.lua"] = function() return "crsf" end,
    ["tasks/msp/common.lua"] = { new = function() return {} end },
    ["tasks/msp/queue.lua"] = { new = function() return queue end },
    ["tasks/msp/service.lua"] = {},
    ["tasks/msp/cache.lua"] = { clear = function() end },
    ["lib/model_preferences.lua"] = { loadByMcuId = function() return nil, nil end }
  }
  local real = {
    ["tasks/msp/runtime.lua"] = true,
    ["lib/armed.lua"] = true,
    ["tasks/msp/api/api_version.lua"] = true,
    ["tasks/msp/api/fc_version.lua"] = true,
    ["tasks/msp/api/uid.lua"] = true,
    ["lib/version.lua"] = true,
    ["lib/api_version.lua"] = true
  }
  env.loadScript = function(path)
    local relative = string.match(path, "^/SCRIPTS/TOOLS/rfsuite%-core/(.+)$")
    assert(relative, "unexpected script path: " .. tostring(path))
    if relative == FAILING then
      h.loads = h.loads + 1
      if h.failedLoads == "all" or h.loads <= h.failedLoads then
        return nil, "cannot open " .. path
      end
    end
    if stubs[relative] ~= nil then return function() return stubs[relative] end end
    assert(real[relative], "unexpected module: " .. relative)
    return assert(loadfile("src/rfsuite/" .. relative, "t", env))
  end
  h.require = assert(loadfile("src/rfsuite/lib/require.lua", "t", env))()
  h.runtime = assert(h.require("tasks/msp/runtime.lua"))
  h.state = h.runtime.getState()
  -- Begin before the first connect edge, so the first tick brings the link up.
  h.state.lastConnected = false
  h.queue = queue
  function h:tick()
    self.time = self.time + STEP_TICKS
    self.runtime.tick()
  end
  -- Ticks until the version read has an answer, or nil if it has none after `limit` ticks.
  function h:ticksToVersion(limit)
    for i = 1, limit do
      self:tick()
      if self.state.versionReadCompleted == true then return i end
    end
    return nil
  end
  return h
end

local function scenario(name, run)
  local ok, err = pcall(run)
  check(ok, name .. " runs without error", ok and nil or tostring(err))
end

-- Control: every module loads, so the read goes out on the first tick and is answered.
scenario("loads", function()
  local h = newRuntime(0)
  local ticks = h:ticksToVersion(50)
  check(ticks ~= nil and ticks <= 2, "loads: version read answered within two ticks",
    "ticks=" .. tostring(ticks))
  check(h.loads == 1, "loads: module loaded once", "loads=" .. tostring(h.loads))
  check(h.state.values.apiVersion == "12.09", "loads: API version taken from the reply",
    "apiVersion=" .. tostring(h.state.values.apiVersion))
end)

-- The module never loads: over 30 s of ticks the runtime asks for it about once a second, not
-- once per tick, and never queues a read it could not parse.
scenario("never_loads", function()
  local h = newRuntime("all")
  local ticks = h:ticksToVersion(300)
  print(string.format("never_loads: %d loads and %d loader lines in 300 ticks (30 s)", h.loads, h.printed))
  check(ticks == nil, "never_loads: no version read completes", "ticks=" .. tostring(ticks))
  check(h.queue.apiReads == 0, "never_loads: nothing queued", "apiReads=" .. tostring(h.queue.apiReads))
  check(h.loads >= 25 and h.loads <= 31, "never_loads: about one load per second, not one per tick",
    "loads=" .. tostring(h.loads))
  check(h.state.pendingVersionRead == true, "never_loads: the read stays owed")
end)

-- A failure that does not last: three failed loads, then the module is there. The read must
-- still go out and be answered, a few seconds after link-up rather than for good.
scenario("loads_after_three_failures", function()
  local h = newRuntime(3)
  local ticks = h:ticksToVersion(100)
  print(string.format("loads_after_three_failures: version read answered after %s ticks (%.1f s), %d loads",
    tostring(ticks), (ticks or 0) * STEP_TICKS / 100, h.loads))
  check(ticks ~= nil, "loads_after_three_failures: version read answered")
  check(ticks ~= nil and ticks <= 40, "loads_after_three_failures: answered within 4 s of link-up",
    "ticks=" .. tostring(ticks))
  check(h.loads == 4, "loads_after_three_failures: four loads", "loads=" .. tostring(h.loads))
  check(h.state.values.apiVersion == "12.09", "loads_after_three_failures: API version taken from the reply",
    "apiVersion=" .. tostring(h.state.values.apiVersion))
end)

-- A link that comes back starts afresh: the wait from the previous link is not carried over.
scenario("reconnect_starts_afresh", function()
  local h = newRuntime(1)
  h:tick()
  check(h.loads == 1, "reconnect_starts_afresh: first load failed", "loads=" .. tostring(h.loads))
  h.rssi = 0
  h:tick()
  h.rssi = 100
  local ticks = h:ticksToVersion(50)
  check(ticks ~= nil and ticks <= 2, "reconnect_starts_afresh: read answered at once on the new link",
    "ticks=" .. tostring(ticks))
end)

if failures > 0 then
  print(string.format("%d of %d checks failed", failures, checks))
  os.exit(1)
end
print(string.format("PASS %d checks", checks))
