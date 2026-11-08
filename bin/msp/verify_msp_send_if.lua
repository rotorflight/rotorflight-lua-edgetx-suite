-- Run from the repository root: lua5.3 bin/msp/verify_msp_send_if.lua
-- Exercise the real MSP framing engine and queue with a message that carries `sendIf`: it is asked
-- before every send, and anything but true gives the message up as "withheld" with nothing sent.
-- A message without it is sent as before.
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
local h = { clock = 1000, rssi = 100, sent = {}, inbox = {}, refuse = 0 }

local transport = {
  maxTxBufferSize = 8,
  maxRxBufferSize = 58,
  mspSend = function(payload)
    -- `refuse` > 0: the transport does not take the next that many frames (its slot is busy).
    if h.refuse > 0 then h.refuse = h.refuse - 1; return false end
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

local C, OTHER = 68, 121
local function world()
  h.sent, h.inbox, h.clock = {}, {}, 1000
  local queue = Queue.new(assert(Common.new("stub")), { isSimulator = false })
  local w = { queue = queue, now = 0 }
  function w.tick(seconds)
    w.now = w.now + (seconds or 0.01)
    h.clock = math.floor(w.now * 100 + 0.5)
    queue:processQueue(w.now)
  end
  function w.ask(cmd, sendIf, extra)
    local m = { command = cmd, maxRetries = 1, timeout = 1, client = "test", errors = {}, sendIf = sendIf }
    for k, v in pairs(extra or {}) do m[k] = v end
    m.processReply = function(_, buf) m.done = true; m.value = buf and buf[1] end
    m.errorHandler = function(_, reason) m.errors[#m.errors + 1] = reason end
    queue:add(m)
    return m
  end
  function w.answer(cmd, value) h.inbox[#h.inbox + 1] = reply(cmd, value) end
  return w
end

-- Control: without sendIf the message goes out and takes its answer.
do
  local w = world()
  local m = w.ask(C, nil)
  w.tick()
  equal(sends(C), 1, "control: a message without sendIf is sent")
  w.answer(C, 7)
  w.tick()
  equal(m.value, 7, "control: and takes its answer")
end

-- sendIf true: sent as before.
do
  local w = world()
  local asked = 0
  w.ask(C, function() asked = asked + 1; return true end)
  w.tick()
  equal(sends(C), 1, "sendIf true: sent")
  equal(asked, 1, "sendIf true: asked once for the send")
end

-- sendIf false at the first send: nothing goes out, the message is given up as withheld, and the
-- next message in the queue is sent.
do
  local w = world()
  local m = w.ask(C, function() return false end)
  w.ask(OTHER, nil)
  w.tick()
  equal(sends(C), 0, "sendIf false: nothing sent")
  equal(m.errors[1], "withheld", "sendIf false: given up as withheld")
  equal(#m.errors, 1, "sendIf false: told once")
  w.tick()
  equal(sends(OTHER), 1, "sendIf false: the next message goes out")
end

-- sendIf that turns false between the first send and the resend: the resend is withheld.
do
  local w = world()
  local allow = true
  local m = w.ask(C, function() return allow end)
  w.tick()
  equal(sends(C), 1, "lapsing: the first send went out")
  allow = false
  w.tick(1.1)
  equal(sends(C), 1, "lapsing: the resend is withheld")
  equal(m.errors[1], "withheld", "lapsing: given up as withheld")
end

-- sendIf that raises: withheld, not sent.
do
  local w = world()
  local m = w.ask(C, function() error("boom") end)
  w.tick()
  equal(sends(C), 0, "sendIf raising: nothing sent")
  equal(m.errors[1], "withheld", "sendIf raising: given up as withheld")
end

-- A message that completes on silence after two sends (the reboot) stops at the withheld resend.
do
  local w = world()
  local allow = true
  local m = w.ask(C, function() return allow end, { completeAfterAttempt = 2, isWrite = true })
  w.tick()
  allow = false
  w.tick(1.1)
  w.tick(1.1)
  equal(sends(C), 1, "silent completion: only the allowed send went out")
  equal(m.done, nil, "silent completion: not completed by the withheld resend")
  equal(m.errors[1], "withheld", "silent completion: given up as withheld")
end

-- A frame the transport did not take stays in the transmit buffer; it is a send of the message too,
-- so it is not flushed once sendIf says no.
do
  local w = world()
  local allow = true
  local m = w.ask(C, function() return allow end)
  h.refuse = 1
  w.tick()
  equal(sends(C), 0, "buffered: the transport did not take the frame yet")
  allow = false
  w.tick()
  w.tick()
  equal(sends(C), 0, "buffered: the buffered frame is not flushed once withheld")
  equal(m.errors[1], "withheld", "buffered: given up as withheld")
  -- The next message sends its own bytes, nothing of the withheld one.
  local other = w.ask(OTHER, nil)
  w.tick(0.2)
  w.tick(0.2)
  equal(sends(OTHER), 1, "after a withheld message: the next one goes out")
  equal(sends(C), 0, "after a withheld message: nothing of the withheld one follows")
  w.answer(OTHER, 5)
  w.tick()
  equal(other.value, 5, "after a withheld message: the next one takes its answer")
end

-- Control for the case above: without sendIf the buffered frame is flushed on the next pass.
do
  local w = world()
  w.ask(C, nil)
  h.refuse = 1
  w.tick()
  equal(sends(C), 0, "buffered control: not taken at first")
  w.tick()
  equal(sends(C), 1, "buffered control: flushed on the next pass")
end

-- All bytes out, then sendIf turns false: the answer that arrives is still taken (nothing more is sent).
do
  local w = world()
  local allow = true
  local m = w.ask(C, function() return allow end)
  w.tick()
  equal(sends(C), 1, "answer after: the request went out")
  w.answer(C, 9)
  allow = false
  w.tick()
  equal(m.value, 9, "answer after: the answer is taken")
  equal(#m.errors, 0, "answer after: not withheld")
end

-- The reboot's two sends are out, then sendIf turns false: it still completes on silence.
do
  local w = world()
  local allow = true
  local m = w.ask(C, function() return allow end, { completeAfterAttempt = 2, isWrite = true })
  w.tick()
  w.tick(1.1)
  equal(sends(C), 2, "silent after: both sends went out")
  allow = false
  w.tick(1.1)
  equal(m.done, true, "silent after: it completes on silence")
  equal(#m.errors, 0, "silent after: not withheld")
end

-- A message with sendIf completes on its sends while a later attempt is still buffered: the buffered
-- bytes are dropped, so the next message's flush cannot send them without the predicate.
do
  local w = world()
  local allow = true
  local m = w.ask(C, function() return allow end, { completeAfterAttempt = 2, isWrite = true })
  w.tick()
  equal(sends(C), 1, "completed with bytes left: the first send went out")
  h.refuse = 5                                   -- the transport takes nothing for a while
  w.tick(1.1)
  w.tick(1.1)
  equal(m.done, true, "completed with bytes left: completes on its sends")
  allow = false
  h.refuse = 0
  w.ask(OTHER, nil)
  w.tick(0.2)
  w.tick(0.2)
  equal(sends(C), 1, "completed with bytes left: the buffered resend never goes out")
  equal(sends(OTHER), 1, "completed with bytes left: the next message goes out")
end

-- At the queue's own default timeout (2 s, no timeout on the message, as the restart's reboot):
-- one send and completion on silence, whatever the predicate says after that send.
do
  h.sent, h.inbox, h.clock = {}, {}, 1000
  local queue = Queue.new(assert(Common.new("stub")), { isSimulator = false })
  local now = 0
  local allow = true
  local m = { command = C, client = "test", isWrite = true, completeAfterAttempt = 1, errors = {},
    sendIf = function() return allow end }
  m.processReply = function() m.done = true end
  m.errorHandler = function(_, reason) m.errors[#m.errors + 1] = reason end
  queue:add(m)
  local function tick(s) now = now + s; h.clock = math.floor(now * 100 + 0.5); queue:processQueue(now) end
  tick(0.01)
  equal(sends(C), 1, "default timeout: one send")
  allow = false
  tick(0.5)
  equal(m.done, true, "default timeout: completes after its one send")
  equal(#m.errors, 0, "default timeout: not withheld")
  tick(2.5)
  equal(sends(C), 1, "default timeout: no second send")
end

-- The withheld message's handler is stopped by the instruction limit: the message stays current, the
-- next pass calls the handler again, and nothing of it is sent in between or after.
do
  local w = world()
  local calls = 0
  local m = w.ask(C, function() return false end)
  m.errorHandler = function(_, reason)
    calls = calls + 1
    m.errors[#m.errors + 1] = reason
    if calls == 1 then error("CPU limit", 0) end
  end
  local ok, err = pcall(w.tick)
  equal(ok, false, "cpu limit in withheld handler: raised on")
  equal(type(err) == "string" and string.find(err, "CPU limit", 1, true) ~= nil, true,
    "cpu limit in withheld handler: the limit error itself")
  equal(w.queue.currentMessage, m, "cpu limit in withheld handler: the message stays current")
  w.tick(0.1)
  equal(calls, 2, "cpu limit in withheld handler: the handler is called again on the next pass")
  equal(w.queue.currentMessage, nil, "cpu limit in withheld handler: then released")
  w.tick(1.1)
  w.tick(1.1)
  equal(sends(C), 0, "cpu limit in withheld handler: nothing sent")
  equal(calls, 2, "cpu limit in withheld handler: no third call")
end

-- A single-attempt message whose frame the transport refuses on the send and on the next pass's
-- flush completes on its attempt and drops the frame: nothing of it goes out later. For the restart
-- this is a reboot lost on the way, which the pipeline's clock-flag probe reports as a restart that
-- could not be confirmed; holding the frame longer would send it further from the answer it rests on.
do
  h.sent, h.inbox, h.clock = {}, {}, 1000
  local queue = Queue.new(assert(Common.new("stub")), { isSimulator = false })
  local now = 0
  local m = { command = C, client = "test", isWrite = true, completeAfterAttempt = 1, errors = {},
    sendIf = function() return true end }
  m.processReply = function() m.done = true end
  m.errorHandler = function(_, reason) m.errors[#m.errors + 1] = reason end
  queue:add(m)
  local function tick(s) now = now + s; h.clock = math.floor(now * 100 + 0.5); queue:processQueue(now) end
  h.refuse = 2
  tick(0.01)
  tick(0.01)
  equal(sends(C), 0, "refused twice: nothing went out")
  equal(m.done, true, "refused twice: completes on its attempt")
  tick(2.5)
  tick(2.5)
  equal(sends(C), 0, "refused twice: the frame is not sent later")
end

print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
