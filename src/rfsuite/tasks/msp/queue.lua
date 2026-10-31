local Queue = {}
Queue.__index = Queue

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, ticks = pcall(getTime)
    if ok and type(ticks) == "number" then
      return ticks / 100
    end
  end
  if type(os) == "table" and type(os.clock) == "function" then
    return os.clock()
  end
  return 0
end

local Cache = nil

local function getCache()
  if Cache == nil then
    if _G.rfsuite and _G.rfsuite.require then
      Cache = _G.rfsuite.require("tasks/msp/cache.lua") or false
    else
      local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/tasks/msp/cache.lua", "t")
      local ok, mod = pcall(chunk)
      Cache = (ok and type(mod) == "table") and mod or false
    end
  end
  return Cache or nil
end

local Env = nil

local function getEnv()
  if Env == nil then
    if _G.rfsuite and _G.rfsuite.require then
      Env = _G.rfsuite.require("lib/env.lua") or false
    else
      local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/env.lua", "t")
      local ok, mod = pcall(chunk)
      Env = (ok and type(mod) == "table") and mod or false
    end
  end
  return Env or nil
end

-- EdgeTX's instruction-limit stop. lib/log_sink.lua publishes the check; it is not loaded in every
-- Lua state this queue runs in, so the same test stands in for it when it is absent.
local function isCpuLimitError(err)
  local fn = _G.rfsuite and _G.rfsuite.isCpuLimitError
  if type(fn) == "function" then return fn(err) == true end
  return type(err) == "string" and string.find(err, "CPU limit", 1, true) ~= nil
end

local DEFAULT_RETRY_BACKOFF_SECONDS = 1.0
local DEFAULT_TIMEOUT_SECONDS = 2.0
local DEFAULT_COMMAND_INTERVAL_SECONDS = 0.25
local DEFAULT_DRAIN_AFTER_REPLY_SECONDS = 0.03
local DEFAULT_DRAIN_MAX_POLLS = 6
local QUEUE_COMPACT_THRESHOLD = 64
local EMPTY_PAYLOAD = {}

local function newQueue()
  return { first = 1, last = 0, data = {} }
end

local function qcount(q)
  return q.last - q.first + 1
end

local function qpush(q, v)
  q.last = q.last + 1
  q.data[q.last] = v
end

local function qreset(q)
  if not q then return end
  local data = q.data
  for i = q.first, q.last do
    data[i] = nil
  end
  q.first = 1
  q.last = 0
end

local function qcompact(q)
  local first = q.first
  local last = q.last
  if first <= 1 or first > last then return end

  local data = q.data
  local write = 1
  for read = first, last do
    data[write] = data[read]
    if write ~= read then
      data[read] = nil
    end
    write = write + 1
  end

  q.first = 1
  q.last = write - 1
end

local function qpop(q)
  if q.first > q.last then return nil end
  local idx = q.first
  local v = q.data[idx]
  q.data[idx] = nil
  idx = idx + 1

  if idx > q.last then
    q.first = 1
    q.last = 0
  else
    q.first = idx
    local active = q.last - q.first + 1
    if q.first > QUEUE_COMPACT_THRESHOLD and q.first > active then
      qcompact(q)
    end
  end

  return v
end

-- Commands the firmware answers as a READ that takes an argument: the request payload is an index
-- or a page, not data to store (rotorflight-firmware src/main/msp/msp.c: the read cases of
-- mspFcProcessOutCommandWithArg, and MSP_DATAFLASH_READ in mspFcProcessCommand). Left out of the
-- same function on purpose: MSP_SET_SERVO_CONFIG, MSP_REBOOT and MSP_RESET_CONF change the board,
-- and MSP_MULTIPLE_MSP runs whichever commands it is given. None of these is in the response
-- cache's list, whose key is the command alone: one of them may only go there with its argument
-- in the key, or one index would be answered with another's reply.
local READ_WITH_ARGUMENT = {
  [71] = true,  -- MSP_DATAFLASH_READ
  [116] = true, -- MSP_BOXNAMES
  [119] = true, -- MSP_BOXIDS
  [125] = true, -- MSP_GET_SERVO_CONFIG
  [137] = true, -- MSP_VTXTABLE_BAND
  [138] = true, -- MSP_VTXTABLE_POWERLEVEL
  [154] = true, -- MSP_RPM_FILTER_V2
  [156] = true, -- MSP_GET_ADJUSTMENT_RANGE
  [157] = true, -- MSP_GET_BUS_SERVO_CONFIG
  [174] = true, -- MSP_GET_MIXER_INPUT
}

-- A message that says what it is is taken at its word. Otherwise a payload still marks a write,
-- because a write may come without the flag (the battery profile switch does, and so may any
-- rfsuite.msp caller) -- except on a command the firmware reads with an argument: there the
-- payload is the index, and taking it for a write cleared the whole response cache on every such
-- read and kept the read past its page's teardown (see Queue:clear).
local function isWriteMessage(msg)
  if msg == nil then return false end
  if msg.isWrite ~= nil then
    return msg.isWrite == true
  end
  if msg.write == true then return true end
  if type(msg.payload) ~= "table" or #msg.payload == 0 then return false end
  return not READ_WITH_ARGUMENT[msg.command]
end

-- A response buffer reaches this file as a byte table on one transport and as a string on
-- another, and a length that silently answers 0 for one of them is worse than no length.
local function bufLen(buf)
  local t = type(buf)
  if t == "string" then return #buf end
  if t == "table" then return #buf end
  return 0
end

local function detectSimulatorRuntime()
  if type(system) == "table" and type(system.getVersion) == "function" then
    local ok, info = pcall(system.getVersion)
    if ok and type(info) == "table" then
      local sim = info.simulation
      if sim ~= nil and sim ~= false and sim ~= 0 then
        return true
      end
    end
  end

  if type(getVersion) == "function" then
    local ok, _, fw = pcall(getVersion)
    if ok and type(fw) == "string" then
      local fwl = string.lower(fw)
      if string.find(fwl, "simu", 1, true) ~= nil then
        return true
      end
    end
  end

  return false
end

local function drainAfterSuccess(self, cmd)
  if cmd == nil or self.isSimulator then return end
  if not self.common or type(self.common.pollReply) ~= "function" then return end

  local deadline = nowSeconds() + (self.drainAfterReplySeconds or 0)
  local pollsLeft = self.drainMaxPolls or 0
  if pollsLeft <= 0 then return end

  -- In the widget state the drain is bounded by its poll count alone -- same reasoning as
  -- the poll loop in common.lua: instructions are billed per iteration, not per second.
  local env = getEnv()
  local countsOnly = env ~= nil and type(env.isWidget) == "function" and env.isWidget() == true

  while pollsLeft > 0 and (countsOnly or nowSeconds() < deadline) do
    local ok, rcmd, _, rerr = pcall(self.common.pollReply)
    if not ok or not rcmd then
      break
    end
    if rcmd ~= cmd or rerr then
      break
    end
    pollsLeft = pollsLeft - 1
  end
end

function Queue.new(common, opts)
  local self = setmetatable({}, Queue)
  opts = opts or {}

  self.common = common
  self.log = opts.log or function() end
  -- Beside `log`, and injected for the same reason it is: this file loads no log module.
  -- `logf` formats on the far side of the level gate, `wanted` answers whether building an
  -- argument is worth it at all, and `hex` renders a payload. All three no-op when absent, so a
  -- caller that constructs a queue without them behaves exactly as before.
  self.logf = opts.logf or function() end
  self.wanted = opts.wanted or function() return false end
  self.hex = opts.hex or function() return "-" end
  self.isSimulator = opts.isSimulator == true

  self.queue = newQueue()
  self.currentMessage = nil
  self.currentMessageStartTime = nil
  self.lastTimeCommandSent = nil

  self.retryCount = 0
  self.errorReplySeen = false
  self.maxRetries = tonumber(opts.maxRetries) or 3
  self.timeout = tonumber(opts.timeout) or DEFAULT_TIMEOUT_SECONDS
  self.retryBackoff = tonumber(opts.retryBackoff) or DEFAULT_RETRY_BACKOFF_SECONDS
  self.commandInterval = tonumber(opts.commandInterval) or DEFAULT_COMMAND_INTERVAL_SECONDS
  self.interMessageDelay = tonumber(opts.interMessageDelay) or 0

  self.drainAfterReplySeconds = tonumber(opts.drainAfterReplySeconds) or DEFAULT_DRAIN_AFTER_REPLY_SECONDS
  self.drainMaxPolls = tonumber(opts.drainMaxPolls) or DEFAULT_DRAIN_MAX_POLLS
  self._nextMessageAt = 0
  self._simDetectDone = opts.isSimulator == true
  self._simDetected = opts.isSimulator == true

  -- The owner a message is filed under when its caller does not name one, so that everything
  -- already queueing against this object keeps working untouched.
  self.defaultClient = opts.client or "default"

  return self
end

function Queue:isProcessed()
  return self.currentMessage == nil and qcount(self.queue) == 0
end

function Queue:add(message)
  if message == nil then
    return self
  end
  -- A read whose answer is still valid is served without a round-trip. The reply is NOT
  -- delivered here: processQueue hands it over on a later tick, exactly where a reply off the
  -- wire is handed over, so the order and the timing a page sees do not change. Delivering it
  -- from inside add() would run processReply while the caller is still setting the page up --
  -- and every multi-read page nests its next read inside that callback.
  if message.command and not isWriteMessage(message) then
    local cache = getCache()
    local buf = cache and cache.get(message.command) or nil
    if buf then
      message.__cachedBuf = buf
    end
  end
  -- Every message records who queued it. The queue is a single FIFO because the transmit side
  -- is one slot, not because the work in it is related: the runtime's own housekeeping reads,
  -- the page on screen and any diagnostics page share it. Until now nothing in a message said
  -- which of them it belonged to, so the queue could not drop one caller's work without
  -- dropping everybody's.
  -- It is only filled in when the caller left it empty, so a caller that already tags its
  -- messages keeps its own value.
  message.client = message.client or self.defaultClient
  qpush(self.queue, message)
  self.logf("trace", "queued cmd=%s rw=%s client=%s from=%s depth=%d",
    tostring(message.command),
    isWriteMessage(message) and "W" or "R",
    tostring(message.client),
    message.__cachedBuf and "cache" or "wire",
    qcount(self.queue))
  return self
end

--- Drop queued work and report it to whoever queued it.
--
-- With no argument everything goes, exactly as before: a disconnect, an unsupported API version
-- or an arm event invalidate every request in flight whoever it belongs to.
--
-- With a client id only that client's messages go and the rest keep their place in the FIFO.
-- That is what lets one caller give up, or go away, without taking work with it that belongs to
-- a caller which had nothing to do with the failure.
--
-- opts.keepWrites leaves that client's writes where they are and drops only its reads. A read is
-- wanted because something is on screen to show it, so it stops being wanted the moment that
-- something is gone; a write is a change the pilot asked the flight controller to make, and it
-- stays wanted whether or not anybody is still looking. Dropping one silently would report a
-- save that never left the radio.
function Queue:clear(clientId, opts)
  local handlers = {}
  local keepWrites = type(opts) == "table" and opts.keepWrites == true
  -- What was in flight and what was queued when the clear arrived, said BEFORE anything is
  -- dropped. Read afterwards this is the difference between "the board never answered" and
  -- "something else took the request away" -- and those two look identical from a page, which
  -- is how a Save that was destroyed by a queue-wide clear once read as a Save that failed.
  local depthBefore = qcount(self.queue)
  local inFlight = self.currentMessage and self.currentMessage.command or nil

  if clientId == nil then
    if self.currentMessage and type(self.currentMessage.errorHandler) == "function" then
      handlers[#handlers + 1] = { fn = self.currentMessage.errorHandler, msg = self.currentMessage }
    end

    while qcount(self.queue) > 0 do
      local msg = qpop(self.queue)
      if msg and type(msg.errorHandler) == "function" then
        handlers[#handlers + 1] = { fn = msg.errorHandler, msg = msg }
      end
    end

    qreset(self.queue)
    self.currentMessage = nil
    self.currentMessageStartTime = nil
    self.lastTimeCommandSent = nil
    self.retryCount = 0
    self._nextMessageAt = 0
    if self.common and self.common.clearTxBuf then
      self.common.clearTxBuf()
    end
    if self.common and self.common.clearRxBuf then
      self.common.clearRxBuf()
    end
  else
    -- The message being transmitted is only abandoned when it is this client's. Its chunks are
    -- dropped with it, or the next message would send what is left of them.
    if self.currentMessage and self.currentMessage.client == clientId
      and not (keepWrites and isWriteMessage(self.currentMessage)) then
      if type(self.currentMessage.errorHandler) == "function" then
        handlers[#handlers + 1] = { fn = self.currentMessage.errorHandler, msg = self.currentMessage }
      end
      self.currentMessage = nil
      self.currentMessageStartTime = nil
      self.lastTimeCommandSent = nil
      self.retryCount = 0
      if self.common and self.common.clearTxBuf then
        self.common.clearTxBuf()
      end
      if self.common and self.common.clearRxBuf then
        self.common.clearRxBuf()
      end
    end

    local kept = newQueue()
    while qcount(self.queue) > 0 do
      local msg = qpop(self.queue)
      if msg then
        if msg.client == clientId and not (keepWrites and isWriteMessage(msg)) then
          if type(msg.errorHandler) == "function" then
            handlers[#handlers + 1] = { fn = msg.errorHandler, msg = msg }
          end
        else
          qpush(kept, msg)
        end
      end
    end
    qreset(self.queue)
    self.queue = kept
  end

  -- warn, not debug: a clear is never routine from the point of view of whatever was queued.
  -- Every one of those handlers is somebody being told their request will not be answered.
  --
  -- Only when there was something to tell. tasks/msp/runtime.lua clears the queue on EVERY
  -- tick while the model is armed, as the gate that keeps configuration traffic off the link
  -- in flight, and that queue is empty on all but the first of those ticks. A line for each
  -- of them is formatted at every debug level -- warn ranks above info, so lib/log.lua builds
  -- the string and files it in the ring even at "off" -- and it lands in the widget's
  -- foreground pass at the logic-tick rate for the whole flight. An empty clear abandons
  -- nobody, so it has nothing to say.
  if depthBefore > 0 or inFlight ~= nil then
    self.logf("warn", "queue cleared client=%s keepWrites=%s inflight=%s depth=%d->%d dropped=%d",
      clientId == nil and "ALL" or tostring(clientId), tostring(keepWrites),
      inFlight and tostring(inFlight) or "-", depthBefore, qcount(self.queue), #handlers)
  end

  for i = 1, #handlers do
    pcall(handlers[i].fn, handlers[i].msg, "cleared")
  end
end

--- Drop one message, named by the client that queued it and the id it was given.
--
-- Clearing by client is the right tool when a caller goes away; it is the wrong one when a
-- caller is still there and has changed its mind about a single request -- a page that has
-- moved on from the read it started, for instance. Both arguments are required, so one client
-- cannot cancel another's work by guessing an id.
--
-- Returns true when something was dropped. A message already being transmitted is abandoned
-- like any other, and its chunks go with it, or the next message would send what is left of
-- them.
function Queue:cancel(clientId, requestId)
  if clientId == nil or requestId == nil then
    return false
  end

  local handler = nil
  local found = false

  local current = self.currentMessage
  if current and current.client == clientId and current.requestId == requestId then
    found = true
    if type(current.errorHandler) == "function" then
      handler = current.errorHandler
    end
    self.currentMessage = nil
    self.currentMessageStartTime = nil
    self.lastTimeCommandSent = nil
    self.retryCount = 0
    if self.common and self.common.clearTxBuf then
      self.common.clearTxBuf()
    end
    if self.common and self.common.clearRxBuf then
      self.common.clearRxBuf()
    end
  end

  local kept = newQueue()
  while qcount(self.queue) > 0 do
    local msg = qpop(self.queue)
    if msg then
      if msg.client == clientId and msg.requestId == requestId then
        found = true
        if type(msg.errorHandler) == "function" then
          handler = msg.errorHandler
        end
      else
        qpush(kept, msg)
      end
    end
  end
  qreset(self.queue)
  self.queue = kept

  if handler then
    pcall(handler, nil, "cancelled")
  end
  return found
end

function Queue:processQueue(now)
  now = tonumber(now) or nowSeconds()
  local simulatorMode = self.isSimulator == true
  if not simulatorMode then
    if self._simDetectDone then
      simulatorMode = self._simDetected == true
    else
      simulatorMode = detectSimulatorRuntime()
      self._simDetected = simulatorMode == true
      self._simDetectDone = true
    end
  end
  if simulatorMode and not self.isSimulator then
    self.isSimulator = true
  end

  if self:isProcessed() then
    return
  end

  if not self.currentMessage then
    if self.interMessageDelay > 0 and now < self._nextMessageAt then
      return
    end
    self.currentMessage = qpop(self.queue)
    self.currentMessageStartTime = nil
    self.lastTimeCommandSent = nil
    self.retryCount = 0
    -- Kept on the queue, not on the message: a caller may add the same message table again,
    -- and what the board answered last time says nothing about this time.
    self.errorReplySeen = false
    self.writeHeld = false
  end

  local msg = self.currentMessage
  if not msg then return end

  -- A read that add() found in the cache is completed here and never sent. Same shape as the
  -- success path below: processReply gets the buffer, the slot is released, the inter-message
  -- delay still applies. Nothing is put back in the cache -- it came from there.
  if msg.__cachedBuf then
    local buf = msg.__cachedBuf
    msg.__cachedBuf = nil
    msg.buf = buf
    msg.__retryCount = 0
    -- Said as `cache`, and never as a reply: this buffer did not go out and nothing came back
    -- for it. A trace that reported it as wire traffic would record a stale answer as a fresh
    -- one, which is the one thing a payload trace must not do.
    if self.wanted("trace") then
      self.logf("trace", "rx cmd=%s src=cache len=%s client=%s %s",
        tostring(msg.command), tostring(bufLen(buf)), tostring(msg.client), self.hex(buf))
    end
    -- A handler belongs to whoever queued the message -- often a page that has closed since --
    -- and the message is released whatever the handler does. Called bare, a raise left the
    -- message current: an answered request was sent again, a message given up was given up
    -- again on every call, and everything queued behind it waited. The same holds for the
    -- simulator and wire replies below and for the errorHandler where a message is given up.
    -- EdgeTX's instruction-limit stop is the exception: it is raised on, as before, so the message
    -- stays current and is handled again on a later pass.
    if type(msg.processReply) == "function" then
      local ok, herr = pcall(msg.processReply, msg, buf)
      if not ok then
        if isCpuLimitError(herr) then error(herr, 0) end
        self.logf("warn", "reply handler raised cmd=%s rw=%s client=%s src=cache err=%s",
          tostring(msg.command), isWriteMessage(msg) and "W" or "R", tostring(msg.client),
          tostring(herr))
      end
    end
    self.currentMessage = nil
    self.currentMessageStartTime = nil
    self.lastTimeCommandSent = nil
    if self.interMessageDelay > 0 then
      self._nextMessageAt = now + self.interMessageDelay
    end
    return
  end

  local retryDelay = tonumber(msg.retryBackoff) or tonumber(msg.retryDelay) or self.retryBackoff
  local timeoutSeconds = tonumber(msg.timeout) or self.timeout
  local commandInterval = tonumber(msg.commandInterval) or self.commandInterval
  local maxRetries = tonumber(msg.maxRetries) or self.maxRetries

  -- Nothing is sent in the simulator, so every message is answered here or not at all. A write
  -- that carries no simulatorResponse gets an empty reply, which is what the board answers a
  -- write with. A read without one cannot be answered: it ends through its errorHandler with
  -- "no_simulator_response", so a caller waiting for it is told, and the warn line keeps the
  -- missing fixture visible. Dropping either with no callback left the caller waiting for ever.
  if simulatorMode then
    local simBuf = msg.simulatorResponse
    if not simBuf and isWriteMessage(msg) then simBuf = {} end
    if not simBuf then
      msg.__retryCount = self.retryCount
      -- Called as the give-up path below calls it: under pcall, an instruction-limit stop raised on.
      if type(msg.errorHandler) == "function" then
        local ok, herr = pcall(msg.errorHandler, msg, "no_simulator_response")
        if not ok then
          if isCpuLimitError(herr) then error(herr, 0) end
          self.logf("warn", "error handler raised cmd=%s rw=R client=%s reason=no_simulator_response err=%s",
            tostring(msg.command), tostring(msg.client), tostring(herr))
        end
      end
      self.logf("warn", "no simulator response cmd=%s client=%s",
        tostring(msg.command), tostring(msg.client))
      self.currentMessage = nil
      self.currentMessageStartTime = nil
      self.lastTimeCommandSent = nil
      return
    end

    if not self.lastTimeCommandSent or (self.lastTimeCommandSent + retryDelay < now) then
      self.lastTimeCommandSent = now
      self.retryCount = self.retryCount + 1
      msg.__retryCount = self.retryCount
      msg.buf = simBuf
      -- The third source, and it is tagged for the same reason `cache` is. This buffer is the
      -- api module's own simulatorResponse constant, or the empty reply of a write that has none:
      -- nothing was sent and no board answered. A line calling it a reply would say the transport
      -- works on a card where the transport was never used.
      if self.wanted("trace") then
        self.logf("trace", "rx cmd=%s src=sim len=%s client=%s %s",
          tostring(msg.command), tostring(bufLen(msg.buf)), tostring(msg.client),
          self.hex(msg.buf))
      end
      if type(msg.processReply) == "function" then
        local ok, herr = pcall(msg.processReply, msg, msg.buf)
        if not ok then
          if isCpuLimitError(herr) then error(herr, 0) end
          self.logf("warn", "reply handler raised cmd=%s rw=%s client=%s src=sim err=%s",
            tostring(msg.command), isWriteMessage(msg) and "W" or "R", tostring(msg.client),
            tostring(herr))
        end
      end
      self.currentMessage = nil
      self.currentMessageStartTime = nil
      self.lastTimeCommandSent = nil
      if self.interMessageDelay > 0 then
        self._nextMessageAt = now + self.interMessageDelay
      end
    end
    return
  end

  -- Flush any pending TX fragments before checking for replies.
  if self.common and type(self.common.processTxQ) == "function" then
    self.common.processTxQ()
  end

  local pollOk, cmd, buf, err
  if self.common and type(self.common.pollReply) == "function" then
    pollOk, cmd, buf, err = pcall(self.common.pollReply)
  else
    pollOk = true
  end

  -- A poll that raised counts as a poll that brought no reply. Returning here instead kept the
  -- message out of the retry and give-up logic below for as long as the transport kept raising:
  -- nothing was sent again, its errorHandler never ran and the queue behind it never moved.
  -- On a failed pcall the second value is the error, so it is said here and then dropped.
  -- A write already handed to the transport is the exception: the raise says nothing about
  -- whether the board received and stored it, so it is held -- not sent again, but its current
  -- reply window is waited out. A reply in that window completes it as usual; otherwise it is
  -- given up below, on the path a message takes when its retries run out, and the queue moves
  -- on. A write that completes on silence (completeAfterAttempt, the reboot) is not held: it is
  -- meant to go out more than once, so it keeps the retries a silent board gives it.
  if not pollOk then
    self.logf("warn", "poll error cmd=%s rw=%s client=%s err=%s", tostring(msg.command),
      isWriteMessage(msg) and "W" or "R", tostring(msg.client), tostring(cmd))
    cmd, buf, err = nil, nil, nil
    if self.retryCount > 0 and isWriteMessage(msg) and not msg.completeAfterAttempt then
      self.writeHeld = true
    end
  end

  if cmd then
    self.lastTimeCommandSent = nil
  end

  -- An error reply is still retried, not taken as final: the firmware answers some reads with
  -- one while it fetches the data (MSP_ESC_PARAMETERS until the ESC has delivered its
  -- parameters), and a later attempt gets the answer. It is remembered so that a message given
  -- up after its retries says the board refused it, not that the board never answered.
  if cmd == msg.command and err then
    self.errorReplySeen = true
  end

  if cmd == msg.command and err and msg.retryOnErrorReply == true then
    self.lastTimeCommandSent = now
    return
  end

  -- completeAfterAttempt says the message completes on SILENCE once it has been sent that many
  -- times. The two fields above cannot express it: both require an error reply to have arrived,
  -- and a command whose whole effect is that the board stops answering never sends one. This
  -- replaces the hardcoded `msg.command == 68` that stood here, which put one caller's protocol
  -- knowledge -- the reboot -- inside the generic success test, and pinned it to a fixed retry
  -- count that has no relation to the transport's own maxRetries.
  local success = (cmd == msg.command and not err)
    or (cmd == msg.command and err and msg.completeOnErrorReplyAttempt and self.retryCount >= msg.completeOnErrorReplyAttempt)
    or (msg.completeAfterAttempt and self.retryCount >= msg.completeAfterAttempt)

  if success then
    msg.buf = buf
    -- `src=wire` is the counterpart of the `src=cache` line above, and the pair is the point:
    -- read on its own, neither says whether the bytes came off the transport or out of a table.
    local elapsed = msg.__sentAt and (now - msg.__sentAt) or -1
    if self.wanted("trace") then
      self.logf("trace", "rx cmd=%s src=wire len=%s client=%s attempt=%d dt=%.2f err=%s %s",
        tostring(cmd), tostring(bufLen(buf)), tostring(msg.client), self.retryCount, elapsed,
        tostring(err), self.hex(buf))
    end
    local cache = getCache()
    if cache and not isWriteMessage(msg) then
      cache.put(msg.command, buf, msg.__cacheKey)
    end
    if type(msg.processReply) == "function" then
      msg.__retryCount = self.retryCount
      -- Whether these bytes are the board's error reply, which completeOnErrorReplyAttempt lets
      -- through to processReply. The bytes alone cannot say it: an error reply carries the
      -- command's own number, and its payload can be any length, so a reader that has to tell
      -- "this firmware has no such command" from "an answer in a layout I do not know" reads it
      -- here. Every other success path completes on a reply without the error flag.
      msg.__errorReply = err and true or false
      local ok, herr = pcall(msg.processReply, msg, msg.buf)
      if not ok then
        if isCpuLimitError(herr) then error(herr, 0) end
        self.logf("warn", "reply handler raised cmd=%s rw=%s client=%s src=wire err=%s",
          tostring(msg.command), isWriteMessage(msg) and "W" or "R", tostring(msg.client),
          tostring(herr))
      end
    end
    if not simulatorMode then
      drainAfterSuccess(self, msg.command)
    end
    self.currentMessage = nil
    self.currentMessageStartTime = nil
    self.lastTimeCommandSent = nil
    if self.interMessageDelay > 0 then
      self._nextMessageAt = now + self.interMessageDelay
    end
    return
  end


  -- Patch: Ein neuer Request (Retry) darf erst nach Ablauf von timeout gesendet werden
  local canSendByInterval = not self.lastTimeCommandSent or (self.lastTimeCommandSent + commandInterval < now)
  local canSendByTimeout = (self.currentMessageStartTime == nil) or ((now - self.currentMessageStartTime) >= timeoutSeconds)

  if canSendByInterval and canSendByTimeout and self.retryCount <= maxRetries and not self.writeHeld then
    local payload = msg.payload or EMPTY_PAYLOAD
    local okSend = self.common and type(self.common.sendRequest) == "function"
      and self.common.sendRequest(msg.command, payload, { write = isWriteMessage(msg) })
    if okSend then
      if isWriteMessage(msg) then
        -- The moment a mutation leaves the radio, anything held may be stale -- so the cache is
        -- dropped on the SEND and not on the acknowledgement. A write whose reply is missed is
        -- still a write the board may have stored, and hanging this on success left a page
        -- showing pre-write values after a Save that had gone out five times.
        -- Which read a write invalidates is not worked out here either: the write carries its
        -- own command number (11 against 10 for the craft name) and the pairing lives in the
        -- api/ modules. A save is rare; the whole cache goes.
        local cache = getCache()
        if cache then cache.clear() end
      elseif msg.__cacheKey == nil then
        -- The cache key as the request leaves: the reply is kept only if it still holds then.
        local cache = getCache()
        msg.__cacheKey = cache and cache.keyFor(msg.command) or false
      end
      self.lastTimeCommandSent = now
      self.currentMessageStartTime = now -- Timeout-Fenster für jeden Retry neu setzen
      self.retryCount = self.retryCount + 1
      -- When this message FIRST went out, kept apart from currentMessageStartTime, which every
      -- retry resets. The reply line reports the distance from here, so a slow answer and a
      -- fast answer to a fourth attempt do not read alike.
      msg.__sentAt = msg.__sentAt or now
      if self.wanted("trace") then
        self.logf("trace", "tx cmd=%s rw=%s client=%s attempt=%d/%d len=%s %s",
          tostring(msg.command), isWriteMessage(msg) and "W" or "R", tostring(msg.client),
          self.retryCount, maxRetries + 1, tostring(bufLen(payload)), self.hex(payload))
      elseif self.retryCount > 1 then
        -- Every request and every reply is TRACE: at DEBUG they were most of a log. A request
        -- that is being sent AGAIN is the exception -- a retry is the start of a failure, and
        -- DEBUG is where the steps towards one are kept.
        self.logf("debug", "tx cmd=%s rw=%s client=%s attempt=%d/%d len=%s",
          tostring(msg.command), isWriteMessage(msg) and "W" or "R", tostring(msg.client),
          self.retryCount, maxRetries + 1, tostring(bufLen(payload)))
      end

      if self.common and type(self.common.processTxQ) == "function" then
        self.common.processTxQ()
      end
    end
  end

  -- Only give up after all retries have been versucht
  -- ... and not before the last of them has had a reply window of its own. Without the second
  -- condition the final attempt is transmitted and declared failed inside the same processQueue
  -- call: the send block above raises retryCount past maxRetries, this test sees the new value
  -- immediately, and the message is abandoned before the flight controller could physically have
  -- answered. So the last retry is not a retry -- it is a send whose reply is never waited for,
  -- and a link that answers slowly loses the one attempt that would have succeeded.
  if (self.retryCount > maxRetries or self.writeHeld)
    and (self.currentMessageStartTime == nil
         or (now - self.currentMessageStartTime) > timeoutSeconds) then
    msg.__retryCount = self.retryCount
    -- The one place a message is given up after its retries, so its reason is decided here:
    -- "refused" when the board answered this command with an error reply on any attempt,
    -- "max_retries" when no attempt was answered at all. A write held after a raising poll
    -- (writeHeld, above) is given up here as well once its reply window has passed, with the
    -- same two reasons.
    local reason = self.errorReplySeen and "refused" or "max_retries"
    if type(msg.errorHandler) == "function" then
      local ok, herr = pcall(msg.errorHandler, msg, reason)
      if not ok then
        if isCpuLimitError(herr) then error(herr, 0) end
        self.logf("warn", "error handler raised cmd=%s rw=%s client=%s reason=%s err=%s",
          tostring(msg.command), isWriteMessage(msg) and "W" or "R", tostring(msg.client), reason,
          tostring(herr))
      end
    end
    self.logf("warn", "%s cmd=%s rw=%s client=%s attempts=%d%s",
      reason == "refused" and "refused" or "max retries",
      tostring(msg.command), isWriteMessage(msg) and "W" or "R", tostring(msg.client), self.retryCount,
      self.writeHeld and " (write held after a poll error)" or "")
    -- Only the message that ran out of retries is given up. Clearing the whole queue here ran
    -- the errorHandler of every other message waiting -- and this one's a second time, since it
    -- has just been called above -- so a single unanswered command took down work belonging to
    -- callers that had nothing to do with it. The transmit buffer is still cleared, because the
    -- chunks of a message being abandoned must not be left for the next.
    self.currentMessage = nil
    self.currentMessageStartTime = nil
    self.lastTimeCommandSent = nil
    if self.common and self.common.clearTxBuf then
      self.common.clearTxBuf()
    end
    if self.common and self.common.clearRxBuf then
      self.common.clearRxBuf()
    end
    if self.interMessageDelay > 0 then
      self._nextMessageAt = now + self.interMessageDelay
    end
    return
  end
end

return Queue
