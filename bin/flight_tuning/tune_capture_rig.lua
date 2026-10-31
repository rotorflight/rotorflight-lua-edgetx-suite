-- The Tune Advisor capture on the real event runtime, for bin/flight_tuning/verify_tune_history.lua
-- and verify_tune_advisor_gate.lua. Not a check of its own.
--
-- Loads the real src/rfsuite/tasks/events/runtime.lua, the real ondisarm runner
-- (tasks/events/common/runner.lua) with the real ondisarm manifest, the real capture
-- (tasks/events/ondisarm/tasks/tune_history.lua, tasks/events/tune_capture.lua) and every module
-- it loads. Stubbed: the MSP
-- runtime (its state: link, armed, a recording queue), the logger, the sensors, the other ondisarm
-- tasks (each completes on its first call), and the onconnect, onarm and telemetry runners. The
-- card is the caller's: it installs io/fstat/rename/del/mkdir before it builds a rig.
--
-- The radio's clock is `rig.clock` in seconds; getTime answers it in 10 ms ticks. A pass is one
-- call of the event runtime's wakeup, which is what the widget makes on each of its passes.

local Rig = {}

local ROOT = "src/rfsuite/"
local CORE = "/SCRIPTS/TOOLS/rfsuite-core/"
local READ, CLEAR, RC_TUNING, PID_PROFILE = 0x5F10, 0x5F11, 111, 94
local NAMES = { "roll", "pitch", "yaw" }

Rig.READ, Rig.CLEAR = READ, CLEAR

local function noop() end

local function completedTask()
  return { wakeup = noop, isComplete = function() return true end, reset = noop }
end

local function idleRunner()
  return { wakeup = noop, reset = noop, resetAllTasks = noop, active = function() return false end }
end

--- A rig with the link up and settled, disarmed. opts: apiVersion (default "12.10"), mcu.
function Rig.new(opts)
  opts = opts or {}
  local h = {
    clock = 1000,
    requests = {},       -- every message put on the MSP queue, oldest first, until answered
    contextAsked = {},   -- names of the RC_TUNING / PID_PROFILE reads, in order
    loads = {},          -- every path loaded through loadScript
    shared = {},         -- path -> module instance handed out on every load of that path
    logs = {},
    states = {},
    reply = { seconds = 147, F = 100 },
    rtc = 1761900000,
  }
  local mspState = { lastConnected = true, lastArmed = false, unsupportedApi = false }
  local queue = {}
  function queue.add(_, msg)
    h.requests[#h.requests + 1] = msg
    return queue
  end
  function queue.isProcessed() return #h.requests == 0 end
  mspState.queue = queue
  h.mspState = mspState
  h.armedReading = { nil, false }

  local log = {
    emit = function(_, message) h.logs[#h.logs + 1] = tostring(message) end,
    emitf = noop,
    tagged = function() return noop end,
    wanted = function() return false end,
  }
  local stubs = {
    ["tasks/msp/runtime.lua"] = function()
      return {
        getState = function() return mspState end,
        armedReading = function() return h.armedReading[1], h.armedReading[2] end,
      }
    end,
    ["lib/log.lua"] = function() return log end,
    ["lib/sensors.lua"] = function() return { getValue = function() return nil end } end,
    ["lib/model_name_store.lua"] = function()
      return { invalidate = noop, hasAny = function() return false end }
    end,
    ["tasks/events/telemetry/flight_record.lua"] = function() return { wakeup = noop, reset = noop } end,
    ["tasks/events/onconnect/tasks.lua"] = idleRunner,
    ["tasks/events/onarm/tasks.lua"] = idleRunner,
    ["tasks/events/telemetry_bg/tasks.lua"] = idleRunner,
    ["tasks/events/ondisarm/tasks/flight_record.lua"] = completedTask,
    ["tasks/events/ondisarm/tasks/flight_log.lua"] = completedTask,
    ["tasks/events/ondisarm/tasks/flight_stats.lua"] = completedTask,
    ["tasks/events/ondisarm/tasks/dataflash_summary.lua"] = completedTask,
  }

  -- Globals of the radio, replaced for every rig
  _G.getTime = function() return math.floor(h.clock * 100 + 0.5) end
  _G.getRtcTime = function() return h.rtc end
  _G.loadScript = function(path)
    local relative = string.match(path, "^/SCRIPTS/TOOLS/rfsuite%-core/(.+)$")
    assert(relative, "unexpected script path: " .. tostring(path))
    h.loads[#h.loads + 1] = relative
    if stubs[relative] then return stubs[relative] end
    if h.shared[relative] ~= nil then
      local mod = h.shared[relative]
      return function() return mod end
    end
    local chunk = loadfile(ROOT .. relative)
    return chunk
  end
  local modules = {}
  _G.rfsuite = {
    loadMode = "t",
    -- lib/require.lua publishes the radio's own loader here; the capture loads through it
    utils = { loadScriptUncached = function(...) return _G.loadScript(...) end },
    session = {
      event_context = "widget",
      mcu_id = opts.mcu or "abc123",
      apiVersion = opts.apiVersion or "12.10",
      activeProfile = 0,
      activeRateProfile = 0,
    },
    require = function(path)
      if modules[path] == nil then
        local chunk = _G.loadScript(CORE .. path)
        local mod = chunk and chunk() or false
        modules[path] = mod == nil and true or mod
      end
      return modules[path]
    end,
  }
  if opts.apiVersion == false then _G.rfsuite.session.apiVersion = nil end
  h.session = _G.rfsuite.session
  _G.__rfsuite_events_module = nil
  h.events = assert(loadfile(ROOT .. "tasks/events/runtime.lua"))()
  h.api = assert(loadfile(ROOT .. "tasks/msp/api/tune_advisor.lua"))()

  function h.capture() return h.session.tuneCapture end

  function h.recordState()
    local tc = h.session.tuneCapture
    local now = tc and tc.state or "idle"
    if h.states[#h.states] ~= now then h.states[#h.states + 1] = now end
  end

  --- One pass of the event runtime at the current clock.
  function h.pass()
    h.events.wakeup()
    h.recordState()
  end

  function h.passes(n, step)
    for _ = 1, n do
      h.clock = h.clock + (step or 0.1)
      h.pass()
    end
  end

  function h.setArmed(armed)
    mspState.lastArmed = armed == true
    h.pass()
  end

  function h.setLink(up)
    mspState.lastConnected = up == true
  end

  function h.name(msg)
    if msg.command == CLEAR then return "clear" end
    if msg.command == READ then return NAMES[(msg.payload and msg.payload[1] or 0) + 1] end
    if msg.command == RC_TUNING then return "rc_tuning" end
    if msg.command == PID_PROFILE then return "pid_profile" end
    return tostring(msg.command)
  end

  -- The bytes the flight controller answers a message with: for a Tune Advisor read, the
  -- simulator reply of that axis with this rig's flight seconds and F gain.
  function h.replyFor(msg)
    if msg.command ~= READ then return msg.simulatorResponse end
    local axis = msg.payload[1] + 1
    local src = h.api.simulatorResponseFor(axis)
    local buf = {}
    for i = 1, #src do buf[i] = src[i] end
    local s = h.reply.seconds
    buf[3], buf[4] = s & 0xFF, (s >> 8) & 0xFF
    local gains = buf[5] | (buf[6] << 8) | (buf[7] << 16) | (buf[8] << 24)
    local p, b = gains % 1024, (gains // (1024 * 1024)) % 1024
    gains = p + h.reply.F * 1024 + b * 1024 * 1024
    buf[5], buf[6], buf[7], buf[8] = gains & 0xFF, (gains >> 8) & 0xFF, (gains >> 16) & 0xFF, (gains >> 24) & 0xFF
    return buf
  end

  --- What the queue does with a reply: processReply, marked as not the error reply.
  function h.answer(msg)
    msg.__errorReply = false
    msg.processReply(msg, h.replyFor(msg))
  end

  --- The MSP error reply of a firmware without the command, as the queue hands it on.
  function h.errorReply(msg)
    msg.__errorReply = true
    msg.processReply(msg, {})
  end

  --- An answer in a layout this suite refuses: payload version 2.
  function h.refusedReply(msg)
    local buf = h.replyFor(msg)
    buf[1] = 2
    msg.__errorReply = false
    msg.processReply(msg, buf)
  end

  function h.drop()
    for i = #h.requests, 1, -1 do h.requests[i] = nil end
  end

  -- Takes the oldest request off the queue
  function h.take()
    return table.remove(h.requests, 1)
  end

  -- Settle: the link is held up after 0.6 s
  h.passes(10)
  return h
end

return Rig
