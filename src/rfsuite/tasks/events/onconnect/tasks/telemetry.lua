-- Task: Read TELEMETRY_CONFIG (MSP 73) on connect
local M = {}

local TelemetryApi = nil
local done = false
local pending = false

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local function getSession()
  return _G.rfsuite and _G.rfsuite.session
end

local function log(msg, level)
  local Log = loadModule("lib/log.lua")
  if Log and type(Log.emit) == "function" then
    Log.emit("rfsuite.tasks.telemetry", msg, level or "debug", true)
  end
end

function M.wakeup()
  if done or pending then return end

  local session = getSession()
  if not session or session.isConnected ~= true then
    return
  end

  log("wakeup: starting telemetry config read")

  if not TelemetryApi then
    TelemetryApi = loadModule("tasks/msp/api/telemetry_config.lua")
  end

  if not TelemetryApi then
    log("wakeup: api missing, skipping", "warn")
    done = true
    return
  end

  local msp = loadModule("tasks/msp/runtime.lua")
  local mspState = msp and type(msp.getState) == "function" and msp.getState()
  if not mspState or not mspState.queue then
    log("wakeup: msp/queue missing", "warn")
    return
  end

  pending = true
  log("wakeup: adding cmd=" .. tostring(TelemetryApi.command) .. " to queue")
  mspState.queue:add({
    command = TelemetryApi.command,
    simulatorResponse = TelemetryApi.simulatorResponse,
    processReply = function(_, buf)
      log("processReply: received bytes=" .. tostring(buf and #buf or 0))
      local parsed = TelemetryApi.parse(buf)
      if parsed then
        log("processReply: parsed config successfully")
        session.telemetry_config = parsed
        session.crsfTelemetryConfig = {
          mode = parsed.crsf_telemetry_mode,
          linkRate = parsed.crsf_telemetry_link_rate,
          linkRatio = parsed.crsf_telemetry_link_ratio
        }
        session.telemetryConfigBuffer = parsed.buffer
      else
        log("processReply: failed to parse config", "warn")
      end
      done = true
      pending = false
    end,
    errorHandler = function()
      log("errorHandler: MSP 73 failed", "warn")
      done = true
      pending = false
    end
  })
end

function M.isComplete()
  return done
end

function M.reset()
  done = false
  pending = false
end

return M
