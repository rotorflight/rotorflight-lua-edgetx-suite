-- OnConnect task: Modellname via MSP auslesen
local M = {}

local done = false
local requestSent = false
local NameApi = nil
local Log = nil
local MspRuntime = nil
local ModelPreferences = nil

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

  if done then return end

  local root = _G and _G.rfsuite
  if type(root) ~= "table" then return end
  local session = root.session
  if type(session) ~= "table" then return end

  if requestSent then return end

  -- The craft name in the session is the previous board's until this read answers. The runner
  -- drops this module without its reset() once the task is complete, so nothing else clears it
  -- between two boards; it goes here, as this board's read starts, so a read that fails leaves no
  -- name rather than the previous craft's for model_name_sync to write onto the model. Not at the
  -- connect edge: a reconnect while armed runs no connect task until the disarm, and the name of
  -- the same craft has to stay for that flight.
  session.modelName = nil

  -- MSP name API laden
  if not NameApi then
    NameApi = loadModule("tasks/msp/api/name.lua")
  end
  if MspRuntime == nil then
    MspRuntime = loadShared("tasks/msp/runtime.lua") or false
  end
  local msp = MspRuntime or nil
  if not msp or not NameApi then
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
    pcall(Log.emit, "rfsuite.tasks.name", "MSP request for name (cmd=" .. tostring(NameApi.command) .. ") via queue", "debug")
  end

  mspState.queue:add({
    command = NameApi.command,
    simulatorResponse = NameApi.simulatorResponse,
    timeout = 5.0,
    -- Bounded below the task timeout in tasks/events/common/runner.lua, so this read
    -- is given up by the queue before the runner re-queues the task that owns it.
    maxRetries = 2,
    processReply = function(self, buf)
      local data = NameApi.parse(buf)
      if data and data.name then
        session.modelName = data.name
        -- Put the name into the board's own store as well, so a card can be read without a
        -- board to ask which file belongs to which helicopter. It happens HERE rather than
        -- where the store is loaded because this is the first moment the name exists: `uid`
        -- runs at the head of the manifest and loads the store, this task runs well after it,
        -- and the store is the same table the session is holding.
        --
        -- The library decides whether anything is written: an empty name and a name the file
        -- already carries write nothing, and neither does a Lua state that may not write --
        -- which is what keeps this out of the widgets, where the same task runs.
        if ModelPreferences == nil then
          ModelPreferences = loadModule("lib/model_preferences.lua") or false
        end
        if type(ModelPreferences) == "table" and type(ModelPreferences.recordModelName) == "function" then
          pcall(ModelPreferences.recordModelName, session.mcu_id, session.modelPreferences, data.name)
        end
      end
      done = true
      if type(Log) == "table" and type(Log.emit) == "function" then
        pcall(Log.emit, "rfsuite.tasks.name", "model name received: " .. tostring(data and data.name), "debug")
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
      if type(Log) == "table" and type(Log.emit) == "function" then pcall(Log.emit, "rfsuite.tasks.name", "model name read failed", "warn") end
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
