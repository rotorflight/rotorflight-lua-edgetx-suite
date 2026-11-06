-- Run from the repository root: lua5.3 bin/msp/verify_msp_reply_after_retransmit.lua
-- Exercise the real MSP framing engine and queue with a reply that arrives after its request was
-- resent, given up or cleared: it names only its command, so it must not complete the next request
-- with that command.
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

-- One MSPv2 reply chunk as telemetry/msp_shared.c's sendMspReply() writes it over CRSF.
local fcSeq = 0
local function reply(cmd, value)
  local status = (fcSeq & 0x0F) | (2 << 5) | 0x10
  fcSeq = fcSeq + 1
  return { status, 0, cmd & 0xFF, (cmd >> 8) & 0xFF, 1, 0, value }
end

local function sends(cmd)
  local n = 0
  for _, chunk in ipairs(h.sent) do
    if (chunk[1] & 0x10) ~= 0 and chunk[3] == (cmd & 0xFF) then n = n + 1 end
  end
  return n
end

local C, OTHER = 120, 121
local function world()
  h.sent, h.inbox, h.clock = {}, {}, 1000
  local queue = Queue.new(assert(Common.new("stub")), { isSimulator = false })
  local w = { queue = queue, now = 0 }
  function w.tick(seconds)
    w.now = w.now + (seconds or 0.01)
    h.clock = math.floor(w.now * 100 + 0.5)
    queue:processQueue(w.now)
  end
  function w.ask(cmd, maxRetries, requestId)
    local m = { command = cmd, maxRetries = maxRetries, timeout = 1, client = "test", requestId = requestId, errors = {} }
    m.processReply = function(_, buf) m.value = buf[1] end
    m.errorHandler = function(_, reason) m.errors[#m.errors + 1] = reason end
    queue:add(m)
    return m
  end
  function w.answer(cmd, value) h.inbox[#h.inbox + 1] = reply(cmd, value) end
  return w
end

-- The defect: a resend crosses a slow reply, so the first answer completes the request and the
-- second arrives while the next request with that command is out.
do
  local w = world()
  local first = w.ask(C, 1)
  w.tick()
  equal(sends(C), 1, "control: the first request went out")
  w.tick(1.1)
  equal(sends(C), 2, "control: the request was sent again")
  w.answer(C, 11)
  w.tick()
  equal(first.value, 11, "the first answer completes the request")
  local second = w.ask(C, 1)
  w.tick()
  equal(sends(C), 2, "the next request with that command waits for the window")
  w.answer(C, 11)
  w.tick()
  equal(second.value, nil, "the second answer to the old request completes nothing")
  w.tick(1.1)
  equal(sends(C), 3, "the waiting request goes out after the window")
  w.answer(C, 22)
  w.tick()
  equal(second.value, 22, "and takes its own answer")
  equal(#second.errors, 0, "and has no error")
end

-- The same after a request that was given up: no answer in the window is not no answer.
do
  local w = world()
  local first = w.ask(C, 0)
  w.tick()
  w.tick(1.1)
  w.tick()
  equal(first.errors[1], "max_retries", "control: the request was given up")
  local second = w.ask(C, 0)
  w.tick()
  equal(sends(C), 1, "after giving up, the next request with that command waits")
  w.answer(C, 11)
  w.tick()
  equal(second.value, nil, "and a late answer completes nothing")
  w.tick(1.1)
  equal(sends(C), 2, "then it goes out")
end

-- The same after a sent request was cleared, and after one was cancelled.
do
  local w = world()
  w.ask(C, 1)
  w.tick()
  w.queue:clear("test")
  local second = w.ask(C, 1)
  w.tick()
  equal(sends(C), 1, "after a clear of a sent request the next one waits")
  w.answer(C, 11)
  w.tick()
  equal(second.value, nil, "a late answer to the cleared request completes nothing")
  w.tick(1.1)
  equal(sends(C), 2, "and then it goes out")
  w.answer(C, 22)
  w.tick()
  equal(second.value, 22, "and takes its own answer")

  -- A clear after a pause counts from the clear, not from the last pass.
  w = world()
  w.ask(C, 1)
  w.tick()
  h.clock = h.clock + 500
  w.now = w.now + 5
  w.queue:clear("test")
  w.ask(C, 1)
  w.tick()
  equal(sends(C), 1, "a clear after a pause still keeps the command quiet")

  w = world()
  w.ask(C, 1, 7)
  w.tick()
  w.queue:cancel("test", 7)
  local afterCancel = w.ask(C, 1)
  w.tick()
  equal(sends(C), 1, "after a cancel of a sent request the next one waits")
  w.answer(C, 11)
  w.tick()
  equal(afterCancel.value, nil, "a late answer to the cancelled request completes nothing")
  w.tick(1.1)
  equal(sends(C), 2, "and then it goes out")
end

-- A request that completes on silence leaves its command with the transport.
do
  local w = world()
  local first = w.ask(C, 2)
  first.completeAfterAttempt = 2
  w.tick()
  w.tick(1.1)
  w.tick()
  equal(sends(C), 2, "control: sent twice and completed on silence")
  local second = w.ask(C, 1)
  w.tick()
  equal(sends(C), 2, "the next request waits")
  w.answer(C, 11)
  w.tick()
  equal(second.value, nil, "a reply cannot complete a request that has not been sent")
end

-- A late reply that arrives while nothing is being asked is read and dropped in the window.
do
  local w = world()
  local first = w.ask(C, 0)
  w.tick()
  w.tick(1.1)
  w.tick()
  equal(first.errors[1], "max_retries", "control: given up")
  for _ = 1, 8 do h.inbox[#h.inbox + 1] = { 0 } end
  w.answer(C, 11)
  for _ = 1, 4 do w.tick() end
  equal(#h.inbox, 0, "the transport is read while the window is open and nothing is asked")
  w.tick(1.1)
  local second = w.ask(C, 0)
  w.tick()
  w.tick()
  equal(sends(C), 2, "after the window the next request goes out")
  equal(second.value, nil, "and the old reply is gone")
end

-- A long timeout does not hold everything behind it for as long.
do
  local w = world()
  local long = w.ask(C, 0)
  long.timeout = 15
  w.tick()
  w.tick(15.1)
  w.tick()
  equal(long.errors[1], "max_retries", "control: given up after its long timeout")
  w.ask(C, 0)
  w.tick()
  equal(sends(C), 1, "the next request waits")
  w.tick(2.1)
  equal(sends(C), 2, "for no longer than the capped window")
end

-- What must not wait.
do
  local w = world()
  local first = w.ask(C, 1)
  w.tick()
  w.answer(C, 11)
  w.tick()
  equal(first.value, 11, "control: answered at the first send")
  w.ask(C, 1)
  w.tick()
  equal(sends(C), 2, "a request answered at its first send holds nothing back")

  w = world()
  w.ask(C, 1)
  w.tick()
  w.tick(1.1)
  w.answer(C, 11)
  w.tick()
  local other = w.ask(OTHER, 1)
  w.tick()
  equal(sends(OTHER), 1, "another command goes out at once")
  w.answer(C, 11)
  w.answer(OTHER, 33)
  w.tick()
  w.tick()
  equal(other.value, 33, "and the late answer does not touch it")

  w = world()
  local armed = w.ask(C, 0)
  w.tick()
  w.tick(1.1)
  w.tick()
  equal(armed.errors[1], "max_retries", "control: the command is kept quiet")
  w.tick(1.1)
  w.ask(C, 2)
  w.tick()
  equal(sends(C), 2, "control: the next request has gone out")
  w.queue.quietUntil = { [C] = w.now + 100 }
  w.tick(1.1)
  equal(sends(C), 3, "a resend of a request already out does not wait")

  w = world()
  w.ask(C, 1)
  w.queue:clear("test")
  w.ask(C, 1)
  w.tick()
  equal(sends(C), 1, "a request cleared before it was sent holds nothing back")
end

print(string.format("verify_msp_reply_after_retransmit: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
