local M = {}

local function loadModule(path)
  local fullPath = _G.rfsuite.paths.core .. "/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Controls = nil
local Common = nil
local MspRuntime = nil
local RcTuningApi = nil
local SavePipeline = nil
local LoadingOverlay = nil
local Sensors = nil
local Profile = nil
local t = nil

local CYCLIC_RING_DEFAULT = 150

local function newRuntime()
  return {
    readPending = false,
    requestRebuild = nil,
    fieldSetters = {},
    lastSessionSignature = nil
  }
end

local ui = {
  loaded = false,
  dirty = false,
  config = {},
  runtime = newRuntime(),
  loading = false,
  progress = 0,
  baseTitle = nil
}

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not RcTuningApi then RcTuningApi = loadModule("tasks/msp/api/rc_tuning.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not Sensors then Sensors = loadModule("lib/sensors.lua") end
  if not Profile then Profile = loadModule("lib/profile.lua") end
  if not t then t = Common and Common.pageT("flight_tuning_rates_advanced_cyclic_behaviour") or nil end
  
  if Common then
    if not ui.runtimeBase then
      ui.runtimeBase = Common.createProfileAwareRuntime({ profileType = "rate" })
    end
    if type(ui.runtime) ~= "table" then
      ui.runtime = newRuntime()
    end
    if getmetatable(ui.runtime) == nil then
      setmetatable(ui.runtime, { __index = ui.runtimeBase })
    end
  end
end

local function pageText(i18n, key, fallback)
  if t then
    local translated = t(i18n, key)
    if translated ~= nil and translated ~= "" and translated ~= key then
      return translated
    end
  end
  return fallback or key
end

local function getRcConfig(session)
  if type(session) ~= "table" then return nil end
  if type(session.rc_tuning) ~= "table" then
    session.rc_tuning = session.rcTuning or {}
  end
  session.rcTuning = session.rc_tuning
  return session.rc_tuning
end

local function loadFromSession()
  local session = getSession()
  local rcConfig = getRcConfig(session)
  if not rcConfig then return end
  for k, v in pairs(rcConfig) do
    ui.config[k] = v
  end
end

local function queueRcRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not RcTuningApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  local readValid = type(getSession()) == "table"
  ui.runtime.readPending = true
  if not isAutoReload then
    ui.loading = true
    ui.progress = 0
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  queue:add({
    command = RcTuningApi.command,
    simulatorResponse = RcTuningApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = RcTuningApi.parse(buf)
      if type(parsed) ~= "table" then return Common.failPageRead(ui) end
      if parsed then
        local session = getSession()
        if session then
          local rcConfig = getRcConfig(session)
          for k, v in pairs(parsed) do
            rcConfig[k] = v
          end
          -- A pending edit is not read over: M.canSave refuses until it is resolved.
          if not ui.dirty then
            loadFromSession()
            ui.runtime.readProfile = tonumber(ui.runtime.lastSessionSignature)
          end
          ui.runtime.readPending = false
          ui.loading = false
          ui.progress = 100
          ui.runtime.readComplete = readValid
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end
      end
    end,
    errorHandler = function()
      readValid = false
      ui.runtime.readPending = false
      ui.loading = false
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })

  return true, nil
end

local function queueRcWrite()
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or not RcTuningApi then
    return false, "msp_runtime_unavailable"
  end

  local session = getSession()
  local rcConfig = getRcConfig(session)
  
  -- Update config values in session
  rcConfig.cyclic_polarity = ui.config.cyclic_polarity
  rcConfig.cyclic_ring = ui.config.cyclic_ring

  return SavePipeline.start({
    pageId = "flight_tuning_advanced_rates_advanced_cyclic_behaviour",
    steps = {
      {
        label = "MSP_SET_RC_TUNING",
        command = RcTuningApi.writeCommand,
        payload = RcTuningApi.buildWritePayload(rcConfig)
      }
    },
    reboot = false,
    onSaved = function()
      ui.dirty = false
    end,
    onDone = function(result)
      if not ui.runtime then return end
      if result.saved then queueRcRead(true) end
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })
end

local function getLiveProfile()
  return Profile and Profile.getActiveRateProfile(1) or 1
end

local function getBaseTitle()
  return pageText(nil, "title", "Cyclic Behaviour")
end

local function buildSessionSignature()
  return tostring(getLiveProfile() or "1")
end

local function ensureLoaded()
  if ui.loaded then return end
  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()
  ui.baseTitle = getBaseTitle()
  queueRcRead(false)
end

function M.wakeup(ctx)
  ensureDeps()
  ensureLoaded()
  if type(ctx) == "table" and type(ctx.requestRebuild) == "function" then
    ui.runtime.requestRebuild = ctx.requestRebuild
  end

  -- A switch is not read over a pending edit; M.canSave refuses until Reload reads the new profile.
  -- The signature is taken over only with a read sent under it.
  local signature = buildSessionSignature()
  if signature ~= ui.runtime.lastSessionSignature and not ui.dirty and queueRcRead(false) then
    ui.runtime.lastSessionSignature = signature
  end
end

function M.getHeaderActions()
  return {
    save = true,
    reload = true,
    help = true,
    menu = true
  }
end

function M.build(ctx)
  ensureDeps()
  ensureLoaded()
  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil

  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local h = ctx.h
  local i18n = ctx.i18n
  
  if ui.loading then
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = pageText(i18n, "loading_title"),
      message = pageText(i18n, "loading_message"),
      progress = ui.progress / 100
    })
    return
  end

  local title = ui.baseTitle or getBaseTitle()
  -- The profile the values on screen were read from; a pending edit keeps it after a switch.
  local profile = ui.runtime.readProfile or getLiveProfile()
  local displayTitle = string.format("%s #%d", title, profile)

  if type(ui.runtime) == "table" and type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(title, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, displayTitle)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  cursorY = cursorY + 10

  -- 1) Polar Coordinates Switch
  local polarValue = (tonumber(ui.config.cyclic_polarity) or 0) == 1
  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w, pageText(i18n, "cyclic_polarity"), polarValue, function(nextBool)
    ui.config.cyclic_polarity = nextBool and 1 or 0
    ui.dirty = true
  end, { helpText = pageText(i18n, "help_p1") })

  -- 2) Cyclic Ring Switch
  local ringValue = tonumber(ui.config.cyclic_ring) or 0
  local ringEnabled = ringValue > 0
  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w, pageText(i18n, "cyclic_ring"), ringEnabled, function(nextBool)
    if nextBool then
      if (tonumber(ui.config.cyclic_ring) or 0) <= 0 then
        ui.config.cyclic_ring = CYCLIC_RING_DEFAULT
      end
    else
      ui.config.cyclic_ring = 0
    end
    ui.dirty = true
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end, { helpText = pageText(i18n, "help_p2") })

  -- 3) Cyclic Ring % Number Field (only if Ring is enabled)
  if ringEnabled then
    cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, pageText(i18n, "cyclic_ring_value"), {
      helpText = pageText(i18n, "help_p3"),
      min = 50,
      max = 250,
      step = 1,
      suffix = "%",
      get = function()
        return tonumber(ui.config.cyclic_ring) or CYCLIC_RING_DEFAULT
      end,
      set = function(val)
        ui.config.cyclic_ring = val
        ui.dirty = true
      end
    })
  end
end

-- The write carries no profile index: the board stores the record in whichever profile is active
-- when it arrives. A profile switch after the read therefore refuses Save until the page has read
-- the active profile; the second value is the reason the host shows.
function M.canSave()
  if ui.runtime == nil or ui.runtime.readComplete ~= true or ui.runtime.readPending then return false end
  if ui.runtime.readProfile == nil then return false end
  if getLiveProfile() ~= ui.runtime.readProfile then return false, "profile_changed" end
  return true
end

function M.onSave(ctx)
  if not M.canSave() then return false, "loaded_data_missing" end
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if SavePipeline and SavePipeline.isActive() then return false end
  local ok, err = queueRcWrite()
  if not ok then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        title = pageText(ctx and ctx.i18n, "save_error_title", "Error"),
        message = tostring(err or "MSP write failed")
      })
    end
    return false
  end
  return true
end

function M.onReload(ctx)
  if SavePipeline and SavePipeline.isActive() then return end
  local session = getSession()
  if session then
    loadFromSession()
    ui.dirty = false
    local signature = buildSessionSignature()
    if queueRcRead(false) then ui.runtime.lastSessionSignature = signature end
  end
  return true
end


function M.onClose()
  if Common and type(Common.resetPageState) == "function" then
    Common.resetPageState(ui, {
      resetLoaded = true,
      resetDirty = true
    })
  end
  Controls = nil
  Common = nil
  MspRuntime = nil
  RcTuningApi = nil
  SavePipeline = nil
  LoadingOverlay = nil
  Sensors = nil
  t = nil
end

M.ui = ui

-- Asked before the page is left (ui/home.lua): true while an edit here is not saved.
function M.hasUnsavedChanges()
  return ui.dirty == true
end

return M
