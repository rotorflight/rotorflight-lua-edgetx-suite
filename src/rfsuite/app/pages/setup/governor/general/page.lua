local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Palette = _G.rfsuite and _G.rfsuite.palette or (_G.rfsuite and _G.rfsuite.require or loadModule)("ui/palette.lua")

local Controls = nil
local Common = nil
local MspRuntime = nil
local GovernorConfigApi = nil
local FeatureConfigApi = nil
local SavePipeline = nil
local LoadingOverlay = nil
local t = nil

local ui = {
  loaded = false,
  dirty = false,
  loading = false,
  saving = false,
  progress = 0,
  baseTitle = nil,
  config = {
    gov_mode = 0,
    gov_throttle_type = 0,
    governor_idle_throttle = 10,
    governor_auto_throttle = 10,
    gov_handover_throttle = 20,
    gov_throttle_hold_timeout = 50
  },
  parsedCache = {},
  featureConfig = {},
  modeChanged = false,
  runtime = {
    readPending = false,
    requestRebuild = nil,
    lastSessionSignature = nil,
    syncHeaderTitle = nil
  }
}

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not GovernorConfigApi then GovernorConfigApi = loadModule("tasks/msp/api/governor_config.lua") end
  if not FeatureConfigApi then FeatureConfigApi = loadModule("tasks/msp/api/feature_config.lua") end
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not t then t = Common and Common.pageT("setup_governor") or nil end
end

local function pageText(i18n, key, fallback)
  if t then
    local translated = t(i18n, key, fallback)
    if translated ~= nil and translated ~= "" and translated ~= key then
      return translated
    end
  end
  return fallback
end

local function buildSessionSignature()
  local session = getSession()
  return session and session.signature or "1"
end

local function loadFromSession()
  local session = getSession()
  if not session or type(session.governor_config) ~= "table" then return end
  local cached = session.governor_config
  ui.config.gov_mode = tonumber(cached.gov_mode) or 0
  ui.config.gov_throttle_type = tonumber(cached.gov_throttle_type) or 0
  ui.config.governor_idle_throttle = tonumber(cached.governor_idle_throttle) or 10
  ui.config.governor_auto_throttle = tonumber(cached.governor_auto_throttle) or 10
  ui.config.gov_handover_throttle = tonumber(cached.gov_handover_throttle) or 20
  ui.config.gov_throttle_hold_timeout = tonumber(cached.gov_throttle_hold_timeout) or 50
  ui.parsedCache = cached
end

local function queueGovRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not MspRuntime or not GovernorConfigApi or not FeatureConfigApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  local readValid = true
  local sessionValid = type(getSession()) == "table"
  local visit = ui.runtime
  local governorData, featureData
  ui.runtime.readPending = true
  ui.runtime.readFailed = false
  if not isAutoReload then
    ui.loading = true
    ui.progress = 0
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  local function failRead()
    if not readValid then return end
    readValid = false
    if ui.runtime ~= visit then return end
    Common.failPageRead(ui)
  end

  local function finishRead()
    if ui.runtime ~= visit or not readValid or not governorData or not featureData then return end
    ui.parsedCache = governorData
    ui.featureConfig = featureData
    -- The control shows the effective mode; the read record keeps the stored mode.
    ui.config.gov_mode = (featureData.enabledFeatures & (1 << 26)) ~= 0 and governorData.gov_mode or 0
    ui.config.gov_throttle_type = governorData.gov_throttle_type or 0
    ui.config.governor_idle_throttle = governorData.governor_idle_throttle or 10
    ui.config.governor_auto_throttle = governorData.governor_auto_throttle or 10
    ui.config.gov_handover_throttle = governorData.gov_handover_throttle or 20
    ui.config.gov_throttle_hold_timeout = governorData.gov_throttle_hold_timeout or 50
    ui.modeChanged = false

    local session = getSession()
    if session then
      session.governor_config = governorData
      session.governorMode = governorData.gov_mode
      session.governorFeature = (featureData.enabledFeatures & (1 << 26)) ~= 0
    end

    ui.runtime.readPending = false
    ui.loading = false
    ui.dirty = false
    ui.progress = 100
    ui.runtime.readComplete = sessionValid
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  queue:add({
    command = GovernorConfigApi.command,
    simulatorResponse = GovernorConfigApi.simulatorResponse,
    timeout = 5.0,
    processReply = function(self, buf)
      if ui.runtime ~= visit or not readValid then return end
      governorData = GovernorConfigApi.parse(buf)
      if type(governorData) ~= "table" then return failRead() end
      finishRead()
    end,
    errorHandler = failRead
  })
  queue:add({
    command = FeatureConfigApi.command,
    simulatorResponse = FeatureConfigApi.simulatorResponse,
    timeout = 5.0,
    processReply = function(self, buf)
      if ui.runtime ~= visit or not readValid then return end
      featureData = FeatureConfigApi.parse(buf)
      if type(featureData) ~= "table" then return failRead() end
      finishRead()
    end,
    errorHandler = failRead
  })

  return true, nil
end

local function copyRecord(record)
  local copy = {}
  for k, v in pairs(record) do copy[k] = v end
  return copy
end

local function queueGovWrite(requestRebuild)
  if not SavePipeline or not GovernorConfigApi or not FeatureConfigApi then
    return false, "msp_runtime_unavailable"
  end

  -- Build on copies so a failed save is still compared with what this visit read.
  local writeData = copyRecord(ui.parsedCache)
  local writeFeatures = copyRecord(ui.featureConfig)
  if ui.modeChanged then
    writeData.gov_mode = ui.config.gov_mode
    local mask = 1 << 26
    if writeData.gov_mode > 0 then
      writeFeatures.enabledFeatures = writeFeatures.enabledFeatures | mask
    else
      writeFeatures.enabledFeatures = writeFeatures.enabledFeatures & (~mask)
    end
  end

  writeData.gov_throttle_type = ui.config.gov_throttle_type
  writeData.governor_idle_throttle = ui.config.governor_idle_throttle
  writeData.governor_auto_throttle = ui.config.governor_auto_throttle
  writeData.gov_handover_throttle = ui.config.gov_handover_throttle
  writeData.gov_throttle_hold_timeout = ui.config.gov_throttle_hold_timeout

  local featureChanged = writeFeatures.enabledFeatures ~= ui.featureConfig.enabledFeatures
  local reboot = featureChanged or writeData.gov_mode ~= ui.parsedCache.gov_mode
  local steps = {
    {
      label = "MSP_SET_GOVERNOR_CONFIG",
      command = GovernorConfigApi.writeCommand,
      payload = GovernorConfigApi.buildWritePayload(writeData)
    }
  }
  if featureChanged then
    steps[#steps + 1] = {
      label = "MSP_SET_FEATURE_CONFIG",
      command = FeatureConfigApi.writeCommand,
      payload = FeatureConfigApi.buildWritePayload(writeFeatures)
    }
  end

  local visit = ui.runtime
  local ok, err = SavePipeline.start({
    pageId = "setup_governor_general",
    steps = steps,
    reboot = reboot,
    onSaved = function()
      if ui.runtime ~= visit then return end
      ui.dirty = false
    end,
    onDone = function(result)
      if result.status == "done" then
        local session = getSession()
        if session then
          session.governor_config = writeData
          session.governorMode = writeData.gov_mode
          session.governorFeature = (writeFeatures.enabledFeatures & (1 << 26)) ~= 0
        end
      end
      if ui.runtime ~= visit then return end
      ui.saving = false
      if result.status == "done" then
        ui.parsedCache = writeData
        ui.featureConfig = writeFeatures
        ui.modeChanged = false
      else
        ui.dirty = true
      end
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })
  if not ok then return false, err end

  ui.saving = true
  ui.progress = 0
  if type(requestRebuild) == "function" then
    requestRebuild()
  end

  return true, nil
end

local function ensureLoaded()
  if ui.loaded then return end
  if SavePipeline and type(SavePipeline.takeResult) == "function" then
    SavePipeline.takeResult("setup_governor_general")
  end

  if not ui.runtime then
    ui.runtime = {
      readPending = false,
      requestRebuild = nil,
      lastSessionSignature = nil,
      syncHeaderTitle = nil
    }
  end

  ui.config = {
    gov_mode = 0,
    gov_throttle_type = 0,
    governor_idle_throttle = 10,
    governor_auto_throttle = 10,
    gov_handover_throttle = 20,
    gov_throttle_hold_timeout = 50
  }
  ui.parsedCache = {}
  ui.featureConfig = {}
  ui.modeChanged = false

  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()

  queueGovRead(false)
end

function M.wakeup(ctx)
  ensureDeps()
  ensureLoaded()

  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil

  local signature = buildSessionSignature()
  if signature ~= ui.runtime.lastSessionSignature then
    ui.runtime.lastSessionSignature = signature
    ui.loaded = false
    ensureLoaded()
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

  if ui.loading or ui.saving then
    local titleText = ui.loading and pageText(i18n, "loading_title", "Loading") or pageText(i18n, "saving_title", "Saving")
    local msgText = ui.loading and pageText(i18n, "loading", "Loading governor configuration...") or pageText(i18n, "saving", "Saving governor configuration...")
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = titleText,
      message = msgText,
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or "General"
  local title = pageText(i18n, "general", displayTitle)
  if type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(title, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, title)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  if ui.runtime.readFailed then
    Common.appendReadFailedNotice(children, x, cursorY, w)
    return
  end

  -- Mode Options
  local modeOptions = {
    { value = 0, label = pageText(i18n, "mode_off", "OFF") },
    { value = 1, label = pageText(i18n, "mode_limit", "LIMIT") },
    { value = 2, label = pageText(i18n, "mode_direct", "DIRECT") },
    { value = 3, label = pageText(i18n, "mode_electric", "ELECTRIC") },
    { value = 4, label = pageText(i18n, "mode_nitro", "NITRO") }
  }

  -- Throttle Type Options
  local throttleTypeOptions = {
    { value = 0, label = pageText(i18n, "throttle_type_normal", "NORMAL") },
    { value = 1, label = pageText(i18n, "throttle_type_switch", "SWITCH") },
    { value = 2, label = pageText(i18n, "throttle_type_function", "FUNCTION") }
  }

  -- 1. Mode
  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    pageText(i18n, "mode", "Mode"),
    modeOptions,
    ui.config.gov_mode,
    function(newVal)
      local val = tonumber(newVal) or 0
      if ui.config.gov_mode ~= val then
        ui.config.gov_mode = val
        ui.modeChanged = true
        ui.dirty = true
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      end
    end
  )

  -- 2. Throttle type
  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    pageText(i18n, "throttle_type", "Throttle type"),
    throttleTypeOptions,
    ui.config.gov_throttle_type,
    function(newVal)
      local val = tonumber(newVal) or 0
      if ui.config.gov_throttle_type ~= val then
        ui.config.gov_throttle_type = val
        ui.dirty = true
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      end
    end
  )

  -- 3. Idle throttle (stored in 0.1%, e.g. 10 = 1.0%)
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "idle_throttle", "Idle throttle"),
    {
      min = 0,
      max = 250,
      step = 1,
      get = function() return ui.config.governor_idle_throttle end,
      set = function(v)
        ui.config.governor_idle_throttle = tonumber(v) or 0
        ui.dirty = true
      end,
      display = function(v)
        return string.format("%.1f%%", (tonumber(v) or 0) / 10)
      end
    }
  )

  -- 4. Auto throttle (stored in 0.1%, e.g. 10 = 1.0%)
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "auto_throttle", "Auto throttle"),
    {
      min = 0,
      max = 250,
      step = 1,
      get = function() return ui.config.governor_auto_throttle end,
      set = function(v)
        ui.config.governor_auto_throttle = tonumber(v) or 0
        ui.dirty = true
      end,
      display = function(v)
        return string.format("%.1f%%", (tonumber(v) or 0) / 10)
      end
    }
  )

  -- 5. Handover throttle%
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "handover_throttle", "Handover throttle%"),
    {
      min = 0,
      max = 100,
      step = 1,
      suffix = "%",
      get = function() return ui.config.gov_handover_throttle end,
      set = function(v)
        ui.config.gov_handover_throttle = tonumber(v) or 20
        ui.dirty = true
      end,
      display = function(v)
        return tostring(tonumber(v) or 0) .. "%"
      end
    }
  )

  -- 6. Throttle hold timeout (stored in 0.1s, e.g. 50 = 5.0s)
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "throttle_hold_timeout", "Throttle hold timeout"),
    {
      min = 0,
      max = 250,
      step = 1,
      get = function() return ui.config.gov_throttle_hold_timeout end,
      set = function(v)
        ui.config.gov_throttle_hold_timeout = tonumber(v) or 50
        ui.dirty = true
      end,
      display = function(v)
        return string.format("%.1fs", (tonumber(v) or 0) / 10)
      end
    }
  )

  if ui.dirty then
    children[#children + 1] = {
      type = "label",
      x = x + 16, y = cursorY + 10,
      text = pageText(i18n, "unsaved_changes", "Unsaved changes"),
      color = Palette.accent,
      font = SMLSIZE
    }
  end
end

function M.canSave()
  return ui.runtime ~= nil and ui.runtime.readComplete == true and not ui.runtime.readPending
end

function M.onSave(ctx)
  if ui.saving then return false end
  if not M.canSave() then return false, "loaded_data_missing" end
  local ok, err = queueGovWrite(ctx and ctx.requestRebuild)
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
  if ui.saving then return true end
  local session = getSession()
  if session then
    ui.dirty = false
    loadFromSession()
    queueGovRead(false)
  end
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/governor/general/help.lua")
  if type(help) == "function" then
    return help(ctx)
  end
  return { title = "Help", message = "No help available" }
end


function M.onClose()
  if Common and type(Common.resetPageState) == "function" then
    Common.resetPageState(ui, {
      resetLoaded = true,
      resetDirty = true
    })
  end
  ui.saving = false
  Controls = nil
  Common = nil
  MspRuntime = nil
  GovernorConfigApi = nil
  FeatureConfigApi = nil
  SavePipeline = nil
  LoadingOverlay = nil
  t = nil
end

-- Asked before the page is left (ui/home.lua): true while an edit here is not saved.
function M.hasUnsavedChanges()
  return ui.dirty == true
end

return M
