-- OnConnect task: read ESC sensor config (MSP 123) to detect telemetry protocol and ESC type
local M = {}

local done = false
local requestSent = false
local EscSensorConfigApi = nil
local Log = nil
local MspRuntime = nil

local function loadModule(path)
  local fullPath = _G.rfsuite.paths.core .. "/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

-- The logger and the MSP runtime are one instance per Lua state. The runner drops this module when
-- its task completes and loads it again the next time the event fires, so a bare loadScript here
-- would read and compile those files again every time; lib/require.lua hands back the loaded one.
local function loadShared(path)
  local req = _G.rfsuite and _G.rfsuite.require
  if type(req) == "function" then return req(path) end
  return loadModule(path)
end

function M.wakeup(args)
  if Log == nil then
    Log = loadShared("lib/log.lua") or false
  end

  if done then return end

  local root = _G and _G.rfsuite
  if type(root) ~= "table" then return end
  local session = root.session
  if type(session) ~= "table" then return end

  if requestSent then return end
  requestSent = true

  if not EscSensorConfigApi then
    EscSensorConfigApi = loadModule("tasks/msp/api/esc_sensor_config.lua")
  end
  if MspRuntime == nil then
    MspRuntime = loadShared("tasks/msp/runtime.lua") or false
  end
  local msp = MspRuntime or nil
  if not msp or not EscSensorConfigApi then
    done = true
    return
  end

  local mspState = type(msp.getState) == "function" and msp.getState()
  if not mspState or not mspState.queue then
    done = true
    return
  end

  if type(Log) == "table" and type(Log.emit) == "function" then
    pcall(Log.emit, "rfsuite.tasks.esc_sensor_config", "MSP request for esc_sensor_config (cmd=" .. tostring(EscSensorConfigApi.command) .. ") via queue", "debug")
  end

  mspState.queue:add({
    command = EscSensorConfigApi.command,
    simulatorResponse = EscSensorConfigApi.simulatorResponse,
    timeout = 5.0,
    -- Bounded below the task timeout in tasks/events/common/runner.lua, so this read
    -- is given up by the queue before the runner re-queues the task that owns it.
    maxRetries = 2,
    processReply = function(self, buf)
      local data = EscSensorConfigApi.parse(buf)
      if data then
        session.esc_sensor_config = data
        local proto = tonumber(data.protocol) or 0
        session.esc4WayDetectedProto = proto
        if type(Log) == "table" and type(Log.emit) == "function" then
          pcall(Log.emit, "rfsuite.tasks.esc_sensor_config", "esc_sensor_config received (protocol=" .. tostring(proto) .. ")", "info")
        end
      end
      done = true
    end,
    errorHandler = function(msg, reason)
      -- "cleared" is the queue dropping this request, not the flight controller refusing it:
      -- nothing was sent, so the request is still owed. Leaving the task incomplete with its latch
      -- open is what lets the runner ask for it again on a later pass.
      if reason == "cleared" then
        requestSent = false
        return
      end
      done = true
      if type(Log) == "table" and type(Log.emit) == "function" then
        pcall(Log.emit, "rfsuite.tasks.esc_sensor_config", "esc_sensor_config read failed", "warn")
      end
    end
  })
end

function M.isComplete()
  return done
end

function M.reset()
  done = false
  requestSent = false
  local root = _G and _G.rfsuite
  if root and type(root.session) == "table" then
    root.session.esc_sensor_config = nil
    root.session.esc4WayDetectedProto = nil
  end
end

return M
