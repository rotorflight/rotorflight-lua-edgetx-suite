-- Run from the repository root: lua5.3 bin/msp/verify_msp_resend_on_break.lua
-- Exercise the real MSP framing engine and queue when a reply breaks off (a continuation chunk
-- lost on the link), and the real MSP runtime allowing the early resend from API 12.10 on.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

bit32 = {
  band = function(a, b) return a & b end,
  bor = function(a, b) return a | b end,
  bxor = function(a, b) return a ~ b end,
  lshift = function(a, n) return (a << n) & 0xFFFFFFFF end,
  rshift = function(a, n) return (a & 0xFFFFFFFF) >> n end,
  btest = function(a, b) return (a & b) ~= 0 end,
}

local core = "src/rfsuite/"
local radio = "/SCRIPTS/RFSUITE/core/"
local h = { clock = 1000, rssi = 100, sent = {}, inbox = {} }

local transport = {
  maxTxBufferSize = 8,
  maxRxBufferSize = 58,
  mspSend = function(payload)
    local copy = {}
    for i = 1, #payload do copy[i] = payload[i] end
    h.sent[#h.sent + 1] = copy
    return true
  end,
  mspPoll = function() return table.remove(h.inbox, 1) end,
}

local fakeQueue = nil
local versionAnswer = { 0, 12, 10 }

getTime = function() return h.clock end
getRSSI = function() return h.rssi end
getValue = function() return 0 end
system = { getVersion = function() return { simulation = false } end }
_G.rfsuite = { session = {}, diagnostics = {} }

loadScript = function(path)
  assert(string.sub(path, 1, #radio) == radio, "unexpected module path: " .. tostring(path))
  local relative = string.sub(path, #radio + 1)
  if relative == "tasks/msp/transports/stub.lua" then
    return function() return transport end
  elseif relative == "tasks/msp/protocols.lua" then
    return function() return function() return "stub" end end
  elseif relative == "tasks/msp/queue.lua" and fakeQueue then
    return function() return { new = function() return fakeQueue end } end
  elseif relative == "lib/log.lua" then
    return function()
      return {
        tagged = function() return function() end end,
        emit = function() end,
        emitf = function() end,
        wanted = function() return false end
      }
    end
  elseif relative == "lib/sensors.lua" then
    return function()
      return { isSimulator = function() return false end, getValue = function() return nil end }
    end
  end
  return loadfile(core .. relative)
end
assert(loadfile(core .. "lib/require.lua"))()

local Common = assert(loadfile(core .. "tasks/msp/common.lua"))()
local Queue = assert(loadfile(core .. "tasks/msp/queue.lua"))()

-- MSPv2 reply chunks as telemetry/msp_shared.c's sendMspReply() writes them over CRSF.
local fcSeq = 0
local function reply(cmd, payload)
  local body = { 0, cmd & 0xFF, (cmd >> 8) & 0xFF, #payload & 0xFF, (#payload >> 8) & 0xFF }
  for i = 1, #payload do body[#body + 1] = payload[i] end
  local chunks, pos, first = {}, 1, true
  while true do
    local status = (fcSeq & 0x0F) | (2 << 5)
    fcSeq = fcSeq + 1
    if first then status = status | 0x10 end
    local chunk = { status }
    local room, rest = 57, #body - pos + 1
    local take = math.min(room, rest)
    for i = 0, take - 1 do chunk[#chunk + 1] = body[pos + i] end
    pos = pos + take
    chunks[#chunks + 1] = chunk
    first = false
    if rest < room then break end
  end
  return chunks
end

local function requestsFor(cmd)
  local n = 0
  for _, chunk in ipairs(h.sent) do
    if (chunk[1] & 0x10) ~= 0 and chunk[3] == (cmd & 0xFF) then n = n + 1 end
  end
  return n
end

local CMD = 120
local PAYLOAD = {}
for i = 1, 140 do PAYLOAD[i] = i & 0xFF end -- 145 bytes: three CRSF chunks

local function newCase(resendOnBreak)
  h.sent, h.inbox, h.clock = {}, {}, 1000
  local common = assert(Common.new("stub"))
  local queue = Queue.new(common, { isSimulator = false, maxRetries = 3 })
  if queue.setResendOnBreak then queue:setResendOnBreak(resendOnBreak) end
  local msg = { command = CMD, replies = 0, errors = {} }
  msg.processReply = function() msg.replies = msg.replies + 1 end
  msg.errorHandler = function(_, reason) msg.errors[#msg.errors + 1] = reason end
  queue:add(msg)
  local now = 0
  local function tick(seconds)
    now = now + (seconds or 0.01)
    h.clock = h.clock + 1
    queue:processQueue(now)
  end
  tick()
  return queue, msg, tick
end

local function broken()
  local chunks = reply(CMD, PAYLOAD)
  table.remove(chunks, 2) -- the middle chunk is lost: the sequence skips
  return chunks
end

do
  local _, msg, tick = newCase(true)
  equal(requestsFor(CMD), 1, "control: the first attempt went out")
  h.inbox = reply(CMD, PAYLOAD)
  for _ = 1, 4 do tick() end
  equal(msg.replies, 1, "control: an unbroken reply is delivered")
  equal(requestsFor(CMD), 1, "control: an unbroken reply is not asked for again")
end

do
  local queue, msg, tick = newCase(true)
  h.inbox = broken()
  for _ = 1, 3 do tick() end
  equal(requestsFor(CMD), 2, "a broken reply is asked for again within the retry window")
  equal(queue.retryCount, 2, "the early resend counts as an attempt")
  h.inbox = reply(CMD, PAYLOAD)
  for _ = 1, 4 do tick() end
  equal(msg.replies, 1, "the resend's reply is delivered")
  equal(#msg.errors, 0, "no error after the resend's reply")
end

do
  local _, _, tick = newCase(false)
  h.inbox = broken()
  for _ = 1, 3 do tick() end
  equal(requestsFor(CMD), 1, "without the firmware's support a broken reply waits for the retry window")
  tick(2.5)
  equal(requestsFor(CMD), 2, "and is asked for again once the window has passed")
end

do
  local _, msg, tick = newCase(true)
  for attempt = 1, 4 do
    h.inbox = broken()
    for _ = 1, 3 do tick() end
  end
  tick(2.5)
  tick(2.5)
  equal(requestsFor(CMD), 4, "a link that breaks every reply sends no more than maxRetries + 1 attempts")
  equal(msg.errors[1], "max_retries", "and the message ends in max_retries")
end

-- The runtime allows it from API 12.10 on ------------------------------------------------------
local function runtimeCase(answer)
  versionAnswer = answer
  h.clock, h.rssi = 1000, 100
  _G.__rfsuite_msp_runtime_module = nil
  _G.__rfsuite_msp_service_module = nil
  _G.rfsuite = { session = {}, diagnostics = {} }
  assert(loadfile(core .. "lib/require.lua"))()
  fakeQueue = { items = {}, resendOnBreak = nil }
  function fakeQueue:add(m) self.items[#self.items + 1] = m return self end
  function fakeQueue:clear()
    local items = self.items
    self.items = {}
    for _, m in ipairs(items) do if m.errorHandler then m.errorHandler(m, "cleared") end end
  end
  function fakeQueue:isProcessed() return #self.items == 0 end
  function fakeQueue:setResendOnBreak(enabled) self.resendOnBreak = enabled end
  function fakeQueue:processQueue()
    local m = table.remove(self.items, 1)
    if m and m.command == 1 then m.processReply(m, versionAnswer) end
  end
  local Runtime = assert(_G.rfsuite.require("tasks/msp/runtime.lua"))
  local function tick(n)
    for _ = 1, n or 1 do
      h.clock = h.clock + 100
      Runtime.tick()
    end
  end
  return tick
end

do
  local tick = runtimeCase({ 0, 12, 10 })
  tick(5)
  equal(fakeQueue.resendOnBreak, true, "API 12.10 allows the early resend")
  h.rssi = 0
  tick(2)
  equal(fakeQueue.resendOnBreak, false, "a disconnect turns it off")

  tick = runtimeCase({ 0, 12, 9 })
  tick(5)
  equal(fakeQueue.resendOnBreak, false, "API 12.09 keeps waiting for the retry window")
end

print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
