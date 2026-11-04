-- Run from the repository root: lua5.3 bin/msp/verify_msp_compact_framing.lua
-- Exercise the real MSP framing engine (tasks/msp/common.lua) in MSPv2 and in the compact
-- version 3, against replies laid out the way the firmware's telemetry/msp_shared.c lays them
-- out, and the real MSP runtime choosing the framing from the API version.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local function bytes(t, from, to)
  local out = {}
  for i = from or 1, to or #t do out[#out + 1] = string.format("%02X", t[i] or 0) end
  return table.concat(out, " ")
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
local h = { clock = 1000, rssi = 100, sent = {}, inbox = {}, accept = true }

-- A transport with CRSF's chunk sizes (8 up, 58 down) that records every chunk handed to it and
-- hands back whatever reply chunks a case queued.
local transport = {
  maxTxBufferSize = 8,
  maxRxBufferSize = 58,
  mspSend = function(payload)
    if not h.accept then return false end
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

-- Reply chunks as msp_shared.c's sendMspReply() writes them: the version bits of the request, a
-- header for that version, and a chunk sent as partial while the rest fills it exactly.
local fcSeq = 0
local function reply(version, cmd, payload, opts)
  opts = opts or {}
  local size = opts.chunk or 58
  local body = {}
  if version == 3 then
    body = { cmd & 0xFF, (cmd >> 8) & 0xFF }
    if #payload >= 0xFF then
      body[3], body[4], body[5] = 0xFF, #payload & 0xFF, (#payload >> 8) & 0xFF
    else
      body[3] = #payload
    end
  else
    body = { opts.flags or 0, cmd & 0xFF, (cmd >> 8) & 0xFF, #payload & 0xFF, (#payload >> 8) & 0xFF }
  end
  for i = 1, #payload do body[#body + 1] = payload[i] end
  local chunks, pos, first = {}, 1, true
  while true do
    local status = (fcSeq & 0x0F) | (version << 5)
    fcSeq = fcSeq + 1
    if first then
      status = status | 0x10
      if opts.error then status = status | 0x80 end
    end
    local chunk = { status }
    local room = size - 1
    local rest = #body - pos + 1
    local take = math.min(room, rest)
    for i = 0, take - 1 do chunk[#chunk + 1] = body[pos + i] end
    pos = pos + take
    chunks[#chunks + 1] = chunk
    first = false
    if rest < room then break end
  end
  return chunks
end

-- The version-mismatch answer of firmware without version 3: version bits of the request, start
-- and error bits, and an MSPv2 body for command 0 carrying one error byte.
local function mismatchReply()
  local status = 0x10 | 0x80 | (3 << 5) | (fcSeq & 0x0F)
  fcSeq = fcSeq + 1
  return { { status, 0, 0, 0, 1, 0, 0x00 } }
end

local function poll(common, limit)
  for _ = 1, limit or 8 do
    local cmd, buf, err = common.pollReply()
    if cmd then return cmd, buf, err end
  end
  return nil
end

local function newCommon()
  h.sent, h.inbox, h.accept = {}, {}, true
  return assert(Common.new("stub"))
end

-- Requests ------------------------------------------------------------------------------------
do
  local c = newCommon()
  equal(c.getProtocolVersion(), 2, "a new link starts in MSPv2")
  c.sendRequest(1, {})
  c.processTxQ()
  equal(bytes(h.sent[1]), "50 00 01 00 00 00 00 00", "MSPv2 request: version bits 2, flags, cmd, length")

  c = newCommon()
  c.setProtocolVersion(3)
  equal(c.getProtocolVersion(), 3, "version 3 can be asked for")
  c.sendRequest(1, {})
  c.processTxQ()
  equal(bytes(h.sent[1]), "70 01 00 00 00 00 00 00", "compact request: version bits 3, cmd, 8-bit length")

  c = newCommon()
  c.setProtocolVersion(3)
  local payload = {}
  for i = 1, 6 do payload[i] = i end
  c.sendRequest(0x1234, payload, { write = true })
  while c.processTxQ() do end
  equal(#h.sent, 2, "a 9-byte compact request is two 7-byte chunks")
  equal(bytes(h.sent[1]), "70 34 12 06 01 02 03 04", "compact request chunk 1 carries payload bytes")
  equal(bytes(h.sent[2], 1, 3), "61 05 06", "compact request chunk 2 continues the sequence")

  c = newCommon()
  c.setProtocolVersion(3)
  payload = {}
  for i = 1, 300 do payload[i] = i & 0xFF end
  c.sendRequest(2, payload)
  c.processTxQ()
  equal(bytes(h.sent[1], 2, 6), "02 00 FF 2C 01", "a length of 255 or more is 0xFF and a 16-bit length")

  c = newCommon()
  c.setProtocolVersion(3)
  c.sendRequest(1, {})
  h.accept = false
  equal(c.processTxQ(), true, "a refused chunk is kept")
  h.accept = true
  c.processTxQ()
  equal(bytes(h.sent[1], 1, 2), "70 01", "the kept chunk goes out unchanged on the next call")
end

-- Replies -------------------------------------------------------------------------------------
do
  local c = newCommon()
  c.sendRequest(1, {})
  c.processTxQ()
  h.inbox = reply(2, 1, { 0, 12, 10 })
  local cmd, buf, err = poll(c)
  equal(cmd, 1, "MSPv2 reply: command")
  equal(buf and bytes(buf), "00 0C 0A", "MSPv2 reply: payload")
  equal(err, false, "MSPv2 reply: no error")

  c = newCommon()
  c.setProtocolVersion(3)
  c.sendRequest(1, {})
  c.processTxQ()
  h.inbox = reply(3, 1, { 0, 12, 10 })
  cmd, buf = poll(c)
  equal(cmd, 1, "compact reply: command")
  equal(buf and bytes(buf), "00 0C 0A", "compact reply: payload")

  -- 54 payload bytes fill the first compact chunk exactly (1 status + 3 header + 54), so the
  -- firmware sends one more, empty chunk; the reply is complete on the first.
  c = newCommon()
  c.setProtocolVersion(3)
  c.sendRequest(42, {})
  c.processTxQ()
  local p = {}
  for i = 1, 54 do p[i] = i end
  h.inbox = reply(3, 42, p)
  equal(#h.inbox, 2, "an exact fit is followed by a status-only chunk")
  cmd, buf = poll(c)
  equal(cmd, 42, "exact-fit compact reply: command")
  equal(buf and #buf, 54, "exact-fit compact reply: length")

  c = newCommon()
  c.setProtocolVersion(3)
  c.sendRequest(52, {})
  c.processTxQ()
  p = {}
  for i = 1, 300 do p[i] = i & 0xFF end
  h.inbox = reply(3, 52, p)
  cmd, buf = poll(c, 16)
  equal(cmd, 52, "long compact reply: command")
  equal(buf and #buf, 300, "long compact reply: the 16-bit length is read")
  equal(buf and buf[300], 300 & 0xFF, "long compact reply: last byte")

  c = newCommon()
  c.sendRequest(1, {})
  c.processTxQ()
  h.inbox = { { 0x30, 3, 1, 0, 12, 10 } } -- version 1 start chunk
  equal(poll(c), nil, "a reply in version 1 answers nothing")
end

-- Errors in version 3 ------------------------------------------------------------------------
do
  -- A compact error reply that names its command is that command's answer.
  local c = newCommon()
  c.setProtocolVersion(3)
  c.sendRequest(217, {})
  c.processTxQ()
  h.inbox = reply(3, 217, { 1 }, { error = true })
  local cmd, _, err = poll(c)
  equal(cmd, 217, "a compact error reply keeps its command")
  equal(err, true, "a compact error reply carries the error flag")
  equal(c.getProtocolVersion(), 3, "a compact error reply leaves the framing as it is")

  -- Firmware without version 3 refuses it with an error frame for command 0. Version 3 is used
  -- only from API 12.10 (Rotorflight 4.7) on, which carries it, so that frame answers nothing of
  -- ours and the framing stays.
  c = newCommon()
  c.setProtocolVersion(3)
  c.sendRequest(1, {})
  c.processTxQ()
  h.inbox = mismatchReply()
  equal(poll(c), nil, "a refusal for command 0 is not delivered as a reply")
  equal(c.getProtocolVersion(), 3, "the framing does not change on its own")
  c.setProtocolVersion(2)
  equal(c.getProtocolVersion(), 2, "asking for MSPv2 returns to MSPv2")
end

-- The runtime chooses the framing from the API version ------------------------------------------
local function runtimeCase(answer)
  versionAnswer = answer
  h.clock, h.rssi = 1000, 100
  _G.__rfsuite_msp_runtime_module = nil
  _G.__rfsuite_msp_service_module = nil
  _G.rfsuite = { session = {}, diagnostics = {} }
  assert(loadfile(core .. "lib/require.lua"))()
  fakeQueue = { items = {} }
  function fakeQueue:add(m) self.items[#self.items + 1] = m return self end
  function fakeQueue:clear()
    local items = self.items
    self.items = {}
    for _, m in ipairs(items) do if m.errorHandler then m.errorHandler(m, "cleared") end end
  end
  function fakeQueue:isProcessed() return #self.items == 0 end
  function fakeQueue:processQueue()
    local m = table.remove(self.items, 1)
    if m and m.command == 1 then
      local common = h.state and h.state.common
      h.versionReadFraming = common and common.getProtocolVersion()
      m.processReply(m, versionAnswer)
    end
  end
  local Runtime = assert(_G.rfsuite.require("tasks/msp/runtime.lua"))
  h.state = Runtime.getState()
  local function tick(n)
    for _ = 1, n or 1 do
      h.clock = h.clock + 100
      Runtime.tick()
    end
  end
  return Runtime, tick
end

do
  local Runtime, tick = runtimeCase({ 0, 12, 10 })
  h.versionReadFraming = nil
  tick(5)
  local common = Runtime.getState().common
  equal(type(common), "table", "the runtime keeps the framing engine it created")
  equal(h.versionReadFraming, 2, "the version read goes out in MSPv2")
  equal(common and common.getProtocolVersion(), 3, "API 12.10 is offered the compact framing")
  h.rssi = 0
  tick(2)
  equal(common and common.getProtocolVersion(), 2, "a disconnect returns to MSPv2")

  Runtime, tick = runtimeCase({ 0, 12, 9 })
  tick(5)
  common = Runtime.getState().common
  equal(common and common.getProtocolVersion(), 2, "API 12.09 stays on MSPv2")
end

print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
