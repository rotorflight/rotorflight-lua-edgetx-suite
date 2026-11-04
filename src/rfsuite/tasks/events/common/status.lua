-- Shared task: Read MSP_STATUS (101) and initialize session active profile state
local M = {}

local done = false
local requestSent = false
local statusApi = nil
local Log = nil
local Profile = nil
local MspRuntime = nil

local function loadModule(path)
  local fullPath = _G.rfsuite.paths.core .. "/" .. path
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(fullPath, mode)
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
  if Profile == nil then
    Profile = loadModule("lib/profile.lua") or false
  end

  if done then return end

  local root = _G and _G.rfsuite
  if type(root) ~= "table" then return end
  local session = root.session
  if type(session) ~= "table" then return end

  if requestSent then return end

  -- Load MSP status API
  if not statusApi then
    statusApi = loadModule("tasks/msp/api/status.lua")
  end
  if MspRuntime == nil then
    MspRuntime = loadShared("tasks/msp/runtime.lua") or false
  end
  local msp = MspRuntime or nil
  if not msp or not statusApi then
    done = true
    return
  end

  local mspState = type(msp.getState) == "function" and msp.getState()
  if not mspState or not mspState.queue then
    done = true
    return
  end

  requestSent = true

  if type(Log) == "table" and type(Log.emit) == "function" then
    pcall(Log.emit, "rfsuite.tasks.status", "MSP request for status (cmd=" .. tostring(statusApi.command) .. ") via queue", "debug")
  end

  mspState.queue:add({
    command = statusApi.command,
    simulatorResponse = statusApi.simulatorResponse,
    timeout = 5.0,
    -- Bounded below the task timeout in tasks/events/common/runner.lua, so this read
    -- is given up by the queue before the runner re-queues the task that owns it.
    maxRetries = 2,
    processReply = function(self, buf)
      local parsed = statusApi.parse(buf)
      if parsed then
        if Profile and type(Profile.setSessionPidProfile) == "function" then
          Profile.setSessionPidProfile(parsed.current_pid_profile_index)
          Profile.setSessionRateProfile(parsed.current_control_rate_profile_index)
        else
          session.activeProfile = parsed.current_pid_profile_index
          session.activeRateProfile = parsed.current_control_rate_profile_index
        end
        session.pid_profile_count = parsed.pid_profile_count
        session.control_rate_profile_count = parsed.control_rate_profile_count
        session.status = parsed
      end
      done = true
      if type(Log) == "table" and type(Log.emit) == "function" then
        pcall(Log.emit, "rfsuite.tasks.status", "status received: PID profile=" .. tostring(parsed and parsed.current_pid_profile_index) .. ", Rate profile=" .. tostring(parsed and parsed.current_control_rate_profile_index), "debug")
      end
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
      if type(Log) == "table" and type(Log.emit) == "function" then pcall(Log.emit, "rfsuite.tasks.status", "status read failed", "warn") end
    end
  })
end

function M.isComplete()
  return done
end

function M.reset()
  done = false
  requestSent = false
end

return M
