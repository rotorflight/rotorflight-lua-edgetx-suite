-- OnConnect task: wait for the MSP runtime's MCU UID read and resolve the model preferences
local M = {}

local done = false
local ModelPreferences = nil
local MspRuntime = nil

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
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

function M.wakeup()
  if done then return end

  local root = _G and _G.rfsuite
  if type(root) ~= "table" then return end
  local session = root.session
  if type(session) ~= "table" then return end

  -- If MspRuntime has already resolved UID and model preferences, reuse it immediately
  if session.mcu_id and session.mcu_id ~= "" then
    if not ModelPreferences then ModelPreferences = loadModule("lib/model_preferences.lua") end
    if not session.modelPreferences and ModelPreferences and type(ModelPreferences.loadByMcuId) == "function" then
      local prefs, filePath = ModelPreferences.loadByMcuId(session.mcu_id, true)
      session.modelPreferences = prefs
      session.modelPreferencesFile = filePath
    end
    session.modelPreferencesResolved = true
    done = true
    return
  end

  -- The MSP runtime reads the UID itself on every connect (enqueueUidRead in
  -- tasks/msp/runtime.lua) and publishes it into the session together with the model
  -- preferences. A read of this task's own would repeat that request and load the preferences a
  -- second time, and what it wrote would not last: the runtime's publish() copies its own UID
  -- over session.mcu_id after every queue pass. So this task only waits until the runtime's read
  -- has an outcome. Without a UID the preferences are still marked resolved, as before, so
  -- nothing that waits on them waits for the runner's timeout instead.
  if MspRuntime == nil then
    MspRuntime = loadShared("tasks/msp/runtime.lua") or false
  end
  local msp = MspRuntime or nil
  local mspState = msp and type(msp.getState) == "function" and msp.getState()
  if not mspState or mspState.uidReadSettled ~= true then return end

  session.modelPreferencesResolved = true
  done = true
end

function M.isComplete() return done end
function M.reset() 
  done = false
  local root = _G and _G.rfsuite
  if root and type(root.session) == "table" then
    root.session.mcu_id = nil
    root.session.modelPreferences = nil
    root.session.modelPreferencesFile = nil
    root.session.modelPreferencesResolved = nil
  end
  if root and type(root.diagnostics) == "table" then root.diagnostics.mcu_id = nil end
end
return M
