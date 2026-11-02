local M = {}

local function loadModule(path)
  local fullPath = _G.rfsuite.paths.core .. "/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Common = nil
local MspRuntime = nil
local Controls = nil
local Sensors = nil
local Profile = nil
local t = nil

local DEFAULT_PROFILE_COUNT = 6

local state = {
  loaded = false,
  isEditing = false,
  isSaving = false,
  requestRebuild = nil,
  lastRefreshAt = 0,
  refreshIntervalSec = 1.0,
  i18n = nil,
  pidProfileIndex = -1,
  rateProfileIndex = -1,
  -- Internal copies for UI (modified by user)
  uiPidProfileIndex = 0,
  uiRateProfileIndex = 0,
  cooldownUntil = 0,
  pendingRequest = false
}

local function logMsg(msg, level)
  local rf = _G.rfsuite
  if rf and rf.Log and type(rf.Log.emit) == "function" then
    rf.Log.emit("rfsuite.profile", msg, level or "debug")
  end
end

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, value = pcall(getTime)
    if ok and type(value) == "number" then
      return value / 100
    end
  end
  if type(os) == "table" and type(os.clock) == "function" then
    return os.clock()
  end
  return 0
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not Sensors then Sensors = loadModule("lib/sensors.lua") end
  if not Profile then Profile = loadModule("lib/profile.lua") end
  if not t then t = Common and Common.pageT("diagnostics_profile_select") or nil end
end

local function pageText(i18n, key, fallback)
  local obj = i18n or state.i18n
  if t then return t(obj, key, fallback) end
  return fallback
end

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

-- How many PID and rate profiles the board has depends on its flash size: 6 and 6, 3 and 6, or
-- 2 and 3. MSP_STATUS reports both, and this page and tasks/events/common/status.lua put them in
-- the session. Before that reply there is no field; a zero can only come from a short reply.
-- Neither is a profile the pilot can pick, so both fall back to six.
local function reportedCount(field)
  local session = getSession()
  local count = session and tonumber(session[field]) or nil
  if count and count >= 1 then return count end
  return nil
end

local function profileCount(field)
  return reportedCount(field) or DEFAULT_PROFILE_COUNT
end

-- MSP_SELECT_SETTING does not refuse an index the board does not have: it switches to the first
-- profile and answers as a success. So an index is never handed to a list or a write beyond the
-- profiles the board reports.
local function clampIndex(index, count)
  local value = tonumber(index) or 0
  if value < 0 then return 0 end
  if value > count - 1 then return count - 1 end
  return value
end

local function clampSelection()
  state.uiPidProfileIndex = clampIndex(state.uiPidProfileIndex, profileCount("pid_profile_count"))
  state.uiRateProfileIndex = clampIndex(state.uiRateProfileIndex, profileCount("control_rate_profile_count"))
end

local function reportRefusal(ctx, message)
  local report = ctx and ctx.reportSave
  if type(report) ~= "function" then return end
  local i18n = ctx.i18n
  report({
    ok = false,
    title = pageText(i18n, "help_title", "Select Profile"),
    message = message
  })
end

local function syncFromSensors()
  ensureDeps()
  if not Sensors then return false end

  local p = Sensors.getValue("pid_profile") -- returns 1-6
  local r = Sensors.getValue("rate_profile") -- returns 1-6

  local changed = false
  
  if p and p >= 1 and p <= 6 then
    local pIdx = p - 1
    if pIdx ~= state.pidProfileIndex then
      state.pidProfileIndex = pIdx
      if Profile and type(Profile.setSessionPidProfile) == "function" then
        Profile.setSessionPidProfile(pIdx)
      else
        local session = getSession()
        if session then session.activeProfile = pIdx end
      end
      if not state.isEditing and not state.isSaving and state.cooldownUntil == 0 then
        state.uiPidProfileIndex = pIdx
        changed = true
      end
    end
  end

  if r and r >= 1 and r <= 6 then
    local rIdx = r - 1
    if rIdx ~= state.rateProfileIndex then
      state.rateProfileIndex = rIdx
      if Profile and type(Profile.setSessionRateProfile) == "function" then
        Profile.setSessionRateProfile(rIdx)
      else
        local session = getSession()
        if session then session.activeRateProfile = rIdx end
      end
      if not state.isEditing and not state.isSaving and state.cooldownUntil == 0 then
        state.uiRateProfileIndex = rIdx
        changed = true
      end
    end
  end

  if not state.loaded and (p or r) then
    state.loaded = true
    changed = true
  end

  return changed
end

-- Perform a one-time MSP 101 to ensure accurate startup state
local function requestInitialData()
  if state.pendingRequest then return end
  
  local msp = MspRuntime
  local mspState = msp and type(msp.getState) == "function" and msp.getState()
  if not mspState or not mspState.queue then return end

  local statusApi = loadModule("tasks/msp/api/status.lua")
  if not statusApi then return end

  logMsg("Performing one-time MSP 101 for initial state")
  state.pendingRequest = true
  mspState.queue:add({
    command = statusApi.command,
    simulatorResponse = statusApi.simulatorResponse,
    processReply = function(_, buf)
      state.pendingRequest = false
      local parsed = statusApi.parse(buf)
      if parsed then
        state.pidProfileIndex = parsed.current_pid_profile_index
        state.rateProfileIndex = parsed.current_control_rate_profile_index
        -- A choice the pilot has made, or a save that is being sent, is not replaced by what the
        -- board reports: the PID write reads uiPidProfileIndex only when the rate write is
        -- acknowledged, and this reply can land in between.
        if not state.isEditing and not state.isSaving then
          state.uiPidProfileIndex = state.pidProfileIndex
          state.uiRateProfileIndex = state.rateProfileIndex
        end
        state.loaded = true
        if Profile and type(Profile.setSessionPidProfile) == "function" then
          Profile.setSessionPidProfile(parsed.current_pid_profile_index)
          Profile.setSessionRateProfile(parsed.current_control_rate_profile_index)
        else
          local session = getSession()
          if session then
            session.activeProfile = parsed.current_pid_profile_index
            session.activeRateProfile = parsed.current_control_rate_profile_index
          end
        end
        local session = getSession()
        if session then
          session.pid_profile_count = parsed.pid_profile_count
          session.control_rate_profile_count = parsed.control_rate_profile_count
          session.status = parsed
        end
        logMsg("Initial state loaded: PID=" .. tostring(state.pidProfileIndex+1) .. " Rate=" .. tostring(state.rateProfileIndex+1))
        if type(state.requestRebuild) == "function" then state.requestRebuild() end
      end
    end,
    errorHandler = function()
      state.pendingRequest = false
    end
  })
end

function M.getHeaderActions()
  return { reload = true, save = not state.isSaving, help = true }
end

function M.isPageOpen()
  return true
end

-- Writing is held until the board has said how many profiles it has; the lists may show six
-- before that, but six is not something to send. The host reports a SAVE refused here and
-- RELOAD asks the board again.
function M.canSave()
  return reportedCount("pid_profile_count") ~= nil
    and reportedCount("control_rate_profile_count") ~= nil
end

function M.onReload()
  logMsg("Manual reload triggered")
  state.isEditing = false
  state.isSaving = false
  state.cooldownUntil = 0
  requestInitialData()
  return true
end

function M.onSave(ctx)
  ensureDeps()
  local i18n = ctx and ctx.i18n or state.i18n

  if state.isSaving then
    reportRefusal(ctx, pageText(i18n, "save_in_progress",
      "The previous profile change is still being sent."))
    return false
  end

  local msp = MspRuntime
  local mspState = msp and type(msp.getState) == "function" and msp.getState()
  if not mspState or not mspState.queue then
    reportRefusal(ctx, pageText(i18n, "msp_unavailable",
      "No connection to the flight controller."))
    return false
  end

  -- The counts can arrive after the lists were drawn with six. A choice beyond them is not
  -- written as some other profile: the lists are redrawn to the board's size and the pilot
  -- saves again.
  local pidBefore, rateBefore = state.uiPidProfileIndex, state.uiRateProfileIndex
  clampSelection()
  if state.uiPidProfileIndex ~= pidBefore or state.uiRateProfileIndex ~= rateBefore then
    if type(state.requestRebuild) == "function" then state.requestRebuild() end
    reportRefusal(ctx, pageText(i18n, "selection_out_of_range",
      "The flight controller has fewer profiles than were offered. Check the selection and save again."))
    return false
  end

  state.isSaving = true
  
  logMsg("Saving changes: Rate=" .. tostring(state.uiRateProfileIndex + 1) .. ", PID=" .. tostring(state.uiPidProfileIndex + 1))

  -- Start sequential write chain using CMD 210 for BOTH.
  -- 1. Write Rate Profile (Command 210, Index + 128)
  mspState.queue:add({
    command = 210,
    payload = { state.uiRateProfileIndex + 128 },
    isWrite = true,
    processReply = function()
      logMsg("Rate Profile change acknowledged (value=" .. tostring(state.uiRateProfileIndex + 129) .. ")")
      
      -- 2. Write PID Profile (Command 210, Index)
      mspState.queue:add({
        command = 210,
        payload = { state.uiPidProfileIndex },
        isWrite = true,
        processReply = function()
          logMsg("PID Profile change acknowledged (value=" .. tostring(state.uiPidProfileIndex) .. ")")
          
          state.isEditing = false
          state.isSaving = false
          -- Use a longer cooldown (4s) to ensure FC telemetry stream has switched over
          state.cooldownUntil = nowSeconds() + 4.0
          
          -- Sync internal baseline
          state.pidProfileIndex = state.uiPidProfileIndex
          state.rateProfileIndex = state.uiRateProfileIndex
          if Profile and type(Profile.setSessionPidProfile) == "function" then
            Profile.setSessionPidProfile(state.uiPidProfileIndex)
            Profile.setSessionRateProfile(state.uiRateProfileIndex)
          else
            local session = getSession()
            if session then
              session.activeProfile = state.uiPidProfileIndex
              session.activeRateProfile = state.uiRateProfileIndex
            end
          end
          
          -- Request 101 once to confirm FC state
          requestInitialData()
        end,
        errorHandler = function() state.isSaving = false end
      })
    end,
    errorHandler = function() state.isSaving = false end
  })

  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/tools/select_profile/help.lua")
  if type(help) == "function" then
    return help(ctx)
  end
  return { title = "Help", message = "No help available" }
end

function M.build(ctx)
  ensureDeps()
  state.requestRebuild = ctx.requestRebuild
  state.i18n = ctx.i18n

  local i18n = ctx.i18n
  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w

  if not state.loaded and not state.pendingRequest then
    requestInitialData()
  end

  local cursorY = y + 10
  
  -- Both lists offer the profiles the board reports, counted separately for the two kinds.
  local pidCount = profileCount("pid_profile_count")
  local rateCount = profileCount("control_rate_profile_count")
  clampSelection()

  -- PID Profile Selector
  local pidOptions = {}
  for i = 1, pidCount do pidOptions[i] = { value = i - 1, label = tostring(i) } end
  
  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    pageText(i18n, "pid_profile", "PID Profile"),
    pidOptions,
    state.uiPidProfileIndex,
    function(val)
      if val ~= state.uiPidProfileIndex then
        state.uiPidProfileIndex = val
        state.isEditing = true
      end
    end
  )
  
  -- Rate Profile Selector
  local rateOptions = {}
  for i = 1, rateCount do rateOptions[i] = { value = i - 1, label = tostring(i) } end
  
  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    pageText(i18n, "rate_profile", "Rate Profile"),
    rateOptions,
    state.uiRateProfileIndex,
    function(val)
      if val ~= state.uiRateProfileIndex then
        state.uiRateProfileIndex = val
        state.isEditing = true
      end
    end
  )

  return cursorY
end

function M.wakeup()
  if state.isSaving then return end

  local now = nowSeconds()
  if (now - state.lastRefreshAt) >= state.refreshIntervalSec then
    state.lastRefreshAt = now
    
    if state.cooldownUntil > 0 then
        if now < state.cooldownUntil then return end
        state.cooldownUntil = 0
        logMsg("Cooldown finished, resumed monitoring")
    end

    if not state.isEditing and syncFromSensors() and type(state.requestRebuild) == "function" then
      state.requestRebuild()
    end
  end
end

function M.paint()
end

function M.handleEvent(eventData)
  state.lastRefreshAt = nowSeconds() + 1.5
  return eventData
end

function M.closePage()
  state.loaded = false
  state.isEditing = false
  state.isSaving = false
  state.pendingRequest = false
  state.pidProfileIndex = -1
  state.rateProfileIndex = -1
  state.cooldownUntil = 0
  state.requestRebuild = nil
  state.i18n = nil
  Common = nil
  MspRuntime = nil
  Controls = nil
  Sensors = nil
  Profile = nil
  t = nil
end

return M
