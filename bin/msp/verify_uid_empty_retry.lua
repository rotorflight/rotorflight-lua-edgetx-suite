-- Run from the repository root: lua5.3 bin/msp/verify_uid_empty_retry.lua
-- Drive the real MSP runtime, loader and UID parser through the board's answer to MSP_UID.
--
-- An answer that carries no UID (a reply too short for the parser) completes the queue entry like
-- any reply, so the queue's own retries never run. The runtime has to ask again itself, after the
-- same backoff a read the board did not answer waits out, and keep the read settled meanwhile so
-- nothing waiting on it holds the connect sequence. A later answer with a UID identifies the board
-- and loads its model preferences into the session.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

-- getTime() counts 10 ms ticks; one runtime tick per STEP_TICKS.
local STEP_TICKS = 10
local UID = 160
local UID_REPLY = { 43, 0, 34, 0, 9, 81, 51, 52, 52, 56, 53, 49 }
local EMPTY_WARN = "^UID read answered without a UID %(cmd=160%); backoff (%d+)s$"
local FAILED_WARN = "^UID read failed %(cmd=160%); backoff (%d+)s$"

local function newRuntime()
  local h = { armflags = 0, rssi = 100, time = 1000, messages = {}, loads = {}, hold = {} }
  h.replies = {
    [1] = { 0, 12, 9 },
    [3] = { 4, 6, 0 },
    [UID] = UID_REPLY
  }
  local queue = { entries = {}, sent = {} }
  function queue:add(entry)
    self.entries[#self.entries + 1] = entry
    self.sent[entry.command] = (self.sent[entry.command] or 0) + 1
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
    -- Replies arrive during processing, never inside add(), as with the real queue. A reply with
    -- the command's number and no error flag completes the entry, whatever its length.
    local head = self.entries[1]
    -- A request held unanswered stays on the queue across ticks, as one the real queue is still
    -- waiting on.
    if head and h.hold[head.command] then return end
    local entry = table.remove(self.entries, 1)
    if not entry then return end
    local reply = h.replies[entry.command]
    assert(reply ~= nil, "unexpected command: " .. tostring(entry.command))
    if reply == "no_reply" then
      -- What the real queue does once its retries for an unanswered read are spent.
      if entry.errorHandler then entry.errorHandler(entry, "max_retries") end
      return
    end
    if entry.processReply then entry.processReply(entry, reply) end
  end

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
      tagged = function()
        return function(message) h.messages[#h.messages + 1] = message end
      end
    },
    ["tasks/msp/protocols.lua"] = function() return "crsf" end,
    ["tasks/msp/common.lua"] = { new = function() return {} end },
    ["tasks/msp/queue.lua"] = { new = function() return queue end },
    ["tasks/msp/service.lua"] = {},
    ["tasks/msp/cache.lua"] = { clear = function() end },
    ["lib/model_preferences.lua"] = {
      loadByMcuId = function(mcuId)
        h.loads[#h.loads + 1] = mcuId
        return { owner = mcuId }, "prefs/" .. tostring(mcuId) .. ".ini"
      end
    }
  }
  local real = {
    ["tasks/msp/runtime.lua"] = true,
    ["lib/armed.lua"] = true,
    ["tasks/msp/api/api_version.lua"] = true,
    ["tasks/msp/api/fc_version.lua"] = true,
    ["tasks/msp/api/uid.lua"] = true,
    ["lib/version.lua"] = true,
    ["lib/api_version.lua"] = true,
    -- lib/require.lua loads it to publish rfsuite.paths before any other module.
    ["lib/paths.lua"] = true
  }
  env.loadScript = function(path)
    local relative = string.match(path, "^/SCRIPTS/TOOLS/rfsuite%-core/(.+)$")
    assert(relative, "unexpected script path: " .. tostring(path))
    if stubs[relative] ~= nil then return function() return stubs[relative] end end
    assert(real[relative], "unexpected module: " .. relative)
    return assert(loadfile("src/rfsuite/" .. relative, "t", env))
  end
  h.require = assert(loadfile("src/rfsuite/lib/require.lua", "t", env))()
  h.runtime = assert(h.require("tasks/msp/runtime.lua"))
  h.state = h.runtime.getState()
  h.state.lastConnected = false
  h.queue = queue
  h.session = env.rfsuite.session
  h.mcuId = assert(h.require("tasks/msp/api/uid.lua").parse(UID_REPLY)).mcuId
  -- Every tick also records whether the UID read was reported settled once it first was: the
  -- retry must never take that back while it waits.
  h.unsettledAfterSettle = 0
  function h:tick(count)
    for _ = 1, count or 1 do
      self.time = self.time + STEP_TICKS
      self.runtime.tick()
      if self.settledSeen and self.state.uidReadSettled ~= true then
        self.unsettledAfterSettle = self.unsettledAfterSettle + 1
      end
      if self.state.uidReadSettled == true then self.settledSeen = true end
    end
  end
  -- Ticks until the next UID request has been answered (or `limit` ticks pass).
  function h:untilUidSent(n, limit)
    for _ = 1, limit or 400 do
      if (self.queue.sent[UID] or 0) >= n and self.queue:isProcessed() then return end
      self:tick()
    end
  end
  -- Ticks until the n-th UID request is on the queue (held or not).
  function h:untilUidQueued(n, limit)
    for _ = 1, limit or 400 do
      if (self.queue.sent[UID] or 0) >= n then return end
      self:tick()
    end
  end
  function h:sent(cmd) return self.queue.sent[cmd] or 0 end
  function h:warned(pattern)
    local count, last = 0, nil
    for _, text in ipairs(self.messages) do
      local backoff = string.match(text, pattern)
      if backoff then count, last = count + 1, tonumber(backoff) end
    end
    return count, last
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

local function expectIdentified(h, eq, label)
  eq(h.state.values.mcuId, h.mcuId, label .. ": runtime holds the board's UID")
  eq(h.session.mcu_id, h.mcuId, label .. ": session holds the board's UID")
  local prefs = h.session.modelPreferences
  eq(type(prefs) == "table" and prefs.owner or nil, h.mcuId, label .. ": session holds the board's model preferences")
  eq(h.session.modelPreferencesFile, "prefs/" .. h.mcuId .. ".ini", label .. ": session names the preferences file")
end

-- The answer a board gives first carries no UID, the second does.
local function emptyThenAnswered(emptyReply)
  return function(eq)
    local h = newRuntime()
    h.replies[UID] = emptyReply
    h:untilUidSent(1)
    eq(h:sent(UID), 1, "control: the first UID request went out")
    eq(h.state.values.mcuId, nil, "empty answer: no UID held")
    eq(h.session.mcu_id, nil, "empty answer: no UID in the session")
    eq(h.state.uidReadSettled, true, "empty answer: the read is settled")
    eq(h.state.pendingUidRead, true, "empty answer: the read is owed again")
    local warns, backoff = h:warned(EMPTY_WARN)
    eq(warns, 1, "empty answer: one warning names it")
    eq(backoff, 4, "empty answer: first backoff in seconds")

    -- Inside the backoff nothing is sent again.
    h:tick(30)
    eq(h:sent(UID), 1, "inside the backoff: no second request")

    -- After it, the read goes out again; still empty, the backoff grows.
    h:untilUidSent(2)
    eq(h:sent(UID), 2, "after the backoff: the UID is asked again")
    warns, backoff = h:warned(EMPTY_WARN)
    eq(warns, 2, "second empty answer: warned again")
    eq(backoff, 6, "second empty answer: the backoff grows")
    -- The grown backoff is the one waited out, not only the one logged.
    h:tick(55)
    eq(h:sent(UID), 2, "inside the grown backoff: no third request")

    -- Now the board answers with its UID.
    h.replies[UID] = UID_REPLY
    h:untilUidSent(3)
    eq(h:sent(UID), 3, "third request: asked once more")
    expectIdentified(h, eq, "answered on the retry")
    eq(h.state.consecutiveUidFailures, 0, "answered on the retry: failure count reset")
    eq(#h.loads, 1, "answered on the retry: preferences loaded once")
    eq(h.unsettledAfterSettle, 0, "the read never went back to unsettled while it waited")
    eq(h:sent(1), 1, "the API version read was sent once")

    -- Identified: nothing further is asked.
    h:tick(400)
    eq(h:sent(UID), 3, "identified: no further UID request")
  end
end

scenario("empty_answer_retried", emptyThenAnswered({}))
scenario("short_answer_retried", emptyThenAnswered({ 43, 0, 34, 0 }))

-- A board that keeps answering without a UID is asked at most every 30 seconds.
scenario("backoff_capped", function(eq)
  local h = newRuntime()
  h.replies[UID] = {}
  local requests = 16
  for n = 1, requests do h:untilUidSent(n) end
  eq(h:sent(UID), requests, "control: every retry went out")
  local _, backoff = h:warned(EMPTY_WARN)
  eq(backoff, 30, "the backoff stops growing at 30 s")
  h:tick(290)
  eq(h:sent(UID), requests, "inside the capped backoff: no further request")
  h:untilUidSent(requests + 1, 20)
  eq(h:sent(UID), requests + 1, "after the capped backoff: asked again")
  eq(h.unsettledAfterSettle, 0, "capped: never back to unsettled")
end)

scenario("first_answer_unchanged", function(eq)
  local h = newRuntime()
  h:untilUidSent(1)
  expectIdentified(h, eq, "first answer")
  eq(h.state.uidReadSettled, true, "first answer: settled")
  eq(h.state.pendingUidRead, false, "first answer: nothing owed")
  h:tick(400)
  eq(h:sent(UID), 1, "first answer: one request in total")
  eq(h:warned(EMPTY_WARN), 0, "first answer: no warning")
  eq(h:warned(FAILED_WARN), 0, "first answer: no failure warning")
end)

scenario("failure_path_unchanged", function(eq)
  local h = newRuntime()
  h.replies[UID] = "no_reply"
  h:untilUidSent(1)
  eq(h.state.uidReadSettled, true, "no reply: settled")
  eq(h.state.pendingUidRead, true, "no reply: owed again")
  local warns, backoff = h:warned(FAILED_WARN)
  eq(warns, 1, "no reply: the failure warning")
  eq(backoff, 4, "no reply: first backoff in seconds")
  eq(h:warned(EMPTY_WARN), 0, "no reply: not reported as an empty answer")
  h:tick(30)
  eq(h:sent(UID), 1, "no reply: inside the backoff no second request")
  h.replies[UID] = UID_REPLY
  h:untilUidSent(2)
  eq(h:sent(UID), 2, "no reply: asked again after the backoff")
  expectIdentified(h, eq, "no reply, then answered")
  eq(h.unsettledAfterSettle, 0, "no reply: never back to unsettled")
end)

scenario("armed_during_backoff", function(eq)
  local h = newRuntime()
  h.replies[UID] = {}
  h:untilUidSent(1)
  eq(h.state.pendingUidRead, true, "empty answer: owed again")
  h.armflags = 1
  h:tick(100)
  eq(h.state.lastArmed, true, "control: armed")
  eq(h:sent(UID), 1, "armed past the backoff: no UID request")
  eq(h:sent(1), 1, "armed: the API version read is not sent again")
  h.replies[UID] = UID_REPLY
  h.armflags = 0
  h:untilUidSent(2)
  eq(h.state.lastArmed, false, "control: disarmed")
  eq(h:sent(UID), 2, "disarmed: the owed UID read goes out")
  eq(h:sent(1), 1, "disarmed: the API version read is still not sent again")
  expectIdentified(h, eq, "after the landing")
  eq(h.unsettledAfterSettle, 0, "armed: never back to unsettled")
end)

-- The retry stays unanswered across ticks: the read must stay settled the whole time it is on the
-- queue, not only once its answer has come back.
scenario("retry_held_stays_settled", function(eq)
  local h = newRuntime()
  h.replies[UID] = {}
  h:untilUidSent(1)
  h.replies[UID] = UID_REPLY
  h.hold[UID] = true
  h:untilUidQueued(2)
  eq(h:sent(UID), 2, "control: the retry is on the queue")
  h:tick(20)
  eq(h.queue:isProcessed(), false, "control: the retry is still unanswered")
  eq(h.state.uidReadSettled, true, "retry unanswered: still settled")
  eq(h.unsettledAfterSettle, 0, "retry unanswered: never back to unsettled on any tick")
  eq(h:sent(UID), 2, "retry unanswered: not queued a second time")
  h.hold[UID] = nil
  h:untilUidSent(2)
  expectIdentified(h, eq, "held retry answered")
end)

-- Armed while the retry is on the queue: the armed gate clears it, the read stays owed and settled,
-- the clear is not counted as a failure, and the read goes out again after disarm.
scenario("retry_cleared_by_arming", function(eq)
  local h = newRuntime()
  h.replies[UID] = {}
  h:untilUidSent(1)
  h.replies[UID] = UID_REPLY
  h.hold[UID] = true
  h:untilUidQueued(2)
  eq(h.queue:isProcessed(), false, "control: the retry is on the queue when the craft arms")
  local failuresBefore = h.state.consecutiveUidFailures
  h.armflags = 1
  h:tick(20)
  eq(h.state.lastArmed, true, "control: armed")
  eq(h.queue:isProcessed(), true, "armed: the retry was cleared from the queue")
  eq(h.state.pendingUidRead, true, "armed: the cleared read is owed again")
  eq(h.state.uidReadSettled, true, "armed: still settled")
  eq(h.state.consecutiveUidFailures, failuresBefore, "armed: the clear is not counted as a failure")
  eq(h:sent(UID), 2, "armed: no UID request while armed")
  h.hold[UID] = nil
  h.armflags = 0
  h:untilUidSent(3)
  eq(h:sent(UID), 3, "disarmed: the owed read goes out again")
  expectIdentified(h, eq, "cleared retry, then answered")
  eq(h.unsettledAfterSettle, 0, "cleared retry: never back to unsettled")
end)

if failures > 0 then
  print(string.format("%d/%d checks failed", failures, checks))
  os.exit(1)
end
print(string.format("UID empty-answer retry checks passed: %d", checks))
