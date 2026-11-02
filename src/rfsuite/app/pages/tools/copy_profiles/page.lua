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
  isReading = false,
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
-- reply that was short. Neither is a count the board has reported.
local function reportedCount(profileType)
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
  return nil
end

-- What the lists offer: the reported count, or six until there is one.
local function profileCount(profileType)
  return reportedCount(profileType) or DEFAULT_PROFILE_COUNT
end

-- Reads MSP_STATUS for the two counts, as the connect does; RELOAD asks for them this way when
-- the connect's own read has not delivered them.
local function requestCounts()
  if state.isReading then return end
  local mspState = MspRuntime and type(MspRuntime.getState) == "function" and MspRuntime.getState()
  if not mspState or not mspState.queue then return end
  local statusApi = loadModule("tasks/msp/api/status.lua")
  if not statusApi then return end

  state.isReading = true
  mspState.queue:add({
    command = statusApi.command,
    simulatorResponse = statusApi.simulatorResponse,
    processReply = function(_, buf)
      state.isReading = false
      local parsed = statusApi.parse(buf)
      local session = getSession()
      if parsed and session then
        session.pid_profile_count = parsed.pid_profile_count
        session.control_rate_profile_count = parsed.control_rate_profile_count
      end
      if type(state.requestRebuild) == "function" then state.requestRebuild() end
    end,
    errorHandler = function() state.isReading = false end
  })
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

-- SAVE is offered only while the two lists name different profiles. A copy of a profile onto
-- itself has nothing to do, so the button is greyed out rather than asked about and then refused;
-- the header reads this when the page is built, and the two combos below rebuild it when the
-- answer changes.
function M.getHeaderActions()
  return {
    reload = not state.isSaving,
    save = not state.isSaving and state.sourceIndex ~= state.destIndex,
    help = true
  }
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
  local count = profileCount(state.profileType)
  if state.sourceIndex > count - 1 or state.destIndex > count - 1 then return nil end

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

-- The copy is written only once the board has said how many profiles of the selected kind it
-- has: the lists offer six before that, and the firmware ignores a copy onto a profile it does not
-- have while still answering it as done. The host reports a SAVE refused here.
function M.canSave()
  return reportedCount(state.profileType) ~= nil
end

function M.onReload()
  ensureDeps()
  requestCounts()
  return true
end

function M.onSave(ctx)
  if state.isSaving then return false end
  if not M.canSave() then return false, "loaded_data_missing" end
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

  -- The count can arrive after the lists were drawn with six. A choice beyond it is not sent: the
  -- lists are redrawn to the board's size, the choice is kept and shown as unknown, and the pilot
  -- picks again.
  local count = profileCount(state.profileType)
  if state.sourceIndex > count - 1 or state.destIndex > count - 1 then
    if type(state.requestRebuild) == "function" then state.requestRebuild() end
    reportRefusal(ctx, pageText(i18n, "selection_out_of_range",
      "The flight controller has fewer profiles than were offered. Check the selection and save again."))
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
  -- A choice beyond the count is not moved into range here: a copy has no undo, so a choice the
  -- pilot did not make must not reach the overwrite question. It stays, the combo shows it as
  -- unknown and will not hand it back, and M.onSave refuses it. The lists carry the profile
  -- number (1-based) so that the unknown entry names the profile the pilot chose; the state and
  -- the MSP payload stay 0-based.
  local availableProfiles = profileCount(state.profileType)

  local profileOptions = {}
  for i = 1, availableProfiles do
    profileOptions[i] = { value = i, label = tostring(i) }
  end

  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    pageText(i18n, "source_profile", "Source"),
    profileOptions,
    state.sourceIndex + 1,
    function(val)
      local wasSame = state.sourceIndex == state.destIndex
      state.sourceIndex = val - 1
      if (state.sourceIndex == state.destIndex) ~= wasSame and type(state.requestRebuild) == "function" then
        state.requestRebuild()
      end
    end
  )

  -- Destination Profile
  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    pageText(i18n, "dest_profile", "Destination"),
    profileOptions,
    state.destIndex + 1,
    function(val)
      local wasSame = state.sourceIndex == state.destIndex
      state.destIndex = val - 1
      if (state.sourceIndex == state.destIndex) ~= wasSame and type(state.requestRebuild) == "function" then
        state.requestRebuild()
      end
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
  state.isReading = false
  state.requestRebuild = nil
  state.i18n = nil
  Common = nil
  MspRuntime = nil
  Controls = nil
  t = nil
end

return M
