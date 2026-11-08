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
  local m = w.ask(C, function() asked = asked + 1; return true end)
  w.tick()
  equal(sends(C), 1, "sendIf true: sent")
  equal(asked, 1, "sendIf true: asked once for the send")
end

-- sendIf false at the first send: nothing goes out, the message is given up as withheld, and the
-- next message in the queue is sent.
do
  local w = world()
  local m = w.ask(C, function() return false end)
  local other = w.ask(OTHER, nil)
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

print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
