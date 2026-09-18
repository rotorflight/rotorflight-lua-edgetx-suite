local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Common = nil
local MspRuntime = nil
local Controls = nil
local t = nil

-- The firmware builds fewer profile banks on a target with 256 kB of flash or less, and its copy
-- handler simply refuses an index beyond them, so a bank the board does not have produces a save
-- that reports success and copies nothing. This is what to offer where the flight controller has
-- not said how many it has -- which is the case until its status reply has been read, when the
-- session carries no count at all.
local DEFAULT_PROFILE_COUNT = 6

local state = {
  profileType = 0, -- 0=PID, 1=Rate
  sourceIndex = 0,
  destIndex = 0,
  isSaving = false,
  requestRebuild = nil,
  i18n = nil
}

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not t then t = Common and Common.pageT("tools_copy_profiles") or nil end
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

-- MSP_STATUS carries both counts and tasks/events/common/status.lua puts them in the session on
-- every connect. Before that reply arrives there is no field at all; a zero can only come from a
-- reply that was short. Neither is a profile the pilot can pick, so both fall back.
local function profileCount(profileType)
  local session = getSession()
  local count = nil
  if session then
    if profileType == 1 then
      count = tonumber(session.control_rate_profile_count)
    else
      count = tonumber(session.pid_profile_count)
    end
  end
  if count and count >= 1 then return count end
  return DEFAULT_PROFILE_COUNT
end

local function clampIndex(index, count)
  local value = tonumber(index) or 0
  if value < 0 then return 0 end
  if value > count - 1 then return count - 1 end
  return value
end

local function reportRefusal(ctx, message)
  local report = ctx and ctx.reportSave
  if type(report) ~= "function" then return end
  report({
    ok = false,
    title = pageText(ctx and ctx.i18n, "title", "Copy Profile"),
    message = message
  })
end

function M.getModuleTitle()
  return "Copy Profile"
end

function M.getHeaderActions()
  return { reload = false, save = not state.isSaving, help = true }
end

function M.isPageOpen()
  return true
end

-- The destination profile's tune is overwritten and cannot be read back off the board afterwards,
-- so the pilot is asked what is about to be lost rather than only whether to save -- and asked it
-- whether or not the save confirmation is switched on. The host raises the question; the write
-- still happens in M.onSave below, behind the host's own re-checks.
function M.getSaveConfirm(ctx)
  ensureDeps()
  if state.sourceIndex == state.destIndex then return nil end

  local i18n = ctx and ctx.i18n or state.i18n
  local typeLabel = pageText(i18n, "profile_type_pid", "PID")
  if state.profileType == 1 then
    typeLabel = pageText(i18n, "profile_type_rate", "Rate")
  end

  return {
    always = true,
    title = pageText(i18n, "msgbox_save", "Copy Profile"),
    message = string.format(
      pageText(i18n, "msgbox_msg",
        "Overwrite %s profile %d with profile %d? This cannot be undone."),
      typeLabel, state.destIndex + 1, state.sourceIndex + 1)
  }
end

function M.onSave(ctx)
  if state.isSaving then return false end
  ensureDeps()

  local i18n = ctx and ctx.i18n or state.i18n
  if state.sourceIndex == state.destIndex then
    reportRefusal(ctx, pageText(i18n, "warn_same_profile",
      "Source and destination profiles are the same."))
    return false
  end

  local msp = MspRuntime
  local mspState = msp and type(msp.getState) == "function" and msp.getState()
  if not mspState or not mspState.queue then
    reportRefusal(ctx, pageText(i18n, "msp_unavailable",
      "No connection to the flight controller."))
    return false
  end

  state.isSaving = true

  -- MSP 183: { type, destination, source }
  local payload = { state.profileType, state.destIndex, state.sourceIndex }

  mspState.queue:add({
    command = 183,
    payload = payload,
    isWrite = true,
    simulatorResponse = {},
    processReply = function()
      -- Now save to EEPROM
      local eepromApi = loadModule("tasks/msp/api/eeprom_write.lua")
      mspState.queue:add({
        command = eepromApi.writeCommand,
        payload = {},
        isWrite = true,
        processReply = function()
          state.isSaving = false
          if type(state.requestRebuild) == "function" then state.requestRebuild() end
        end,
        errorHandler = function() state.isSaving = false end
      })
    end,
    errorHandler = function() state.isSaving = false end
  })

  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/tools/copy_profiles/help.lua")
  if type(help) == "function" then
    return help(ctx)
  end
  return {
    title = pageText(ctx.i18n, "help_title", "Copy Profile"),
    message = pageText(ctx.i18n, "help_p1", "Copy settings.")
  }
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

  local cursorY = y + 10
  
  -- Type: PID / Rate
  local typeOptions = {
    { value = 0, label = pageText(i18n, "profile_type_pid", "PID") },
    { value = 1, label = pageText(i18n, "profile_type_rate", "Rate") }
  }
  
  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    pageText(i18n, "profile_type", "Type"),
    typeOptions,
    state.profileType,
    function(val)
      if state.profileType == val then return end
      state.profileType = val
      -- PID and rate profiles are counted separately by the firmware, so the two lists below are
      -- built again for the type that is selected now.
      if type(state.requestRebuild) == "function" then state.requestRebuild() end
    end
  )

  -- Source Profile
  local availableProfiles = profileCount(state.profileType)
  state.sourceIndex = clampIndex(state.sourceIndex, availableProfiles)
  state.destIndex = clampIndex(state.destIndex, availableProfiles)

  local profileOptions = {}
  for i = 1, availableProfiles do
    profileOptions[i] = { value = i - 1, label = tostring(i) }
  end
  
  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    pageText(i18n, "source_profile", "Source"),
    profileOptions,
    state.sourceIndex,
    function(val)
      state.sourceIndex = val
    end
  )

  -- Destination Profile
  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    pageText(i18n, "dest_profile", "Destination"),
    profileOptions,
    state.destIndex,
    function(val)
      state.destIndex = val
    end
  )

  return cursorY
end

function M.wakeup()
end

function M.paint()
end

function M.handleEvent(eventData)
  return eventData
end

function M.closePage()
  state.isSaving = false
  state.requestRebuild = nil
  state.i18n = nil
  Common = nil
  MspRuntime = nil
  Controls = nil
  t = nil
end

return M
