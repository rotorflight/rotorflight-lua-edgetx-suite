local M = {}

local function loadModule(path)
  local fullPath = _G.rfsuite.paths.core .. "/" .. path
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
local SavePipeline = nil
local GovernorFields = nil
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
    gov_startup_time = 200,
    gov_spoolup_time = 100,
    gov_spooldown_time = 30,
    gov_tracking_time = 20,
    gov_recovery_time = 20
  },
  parsedCache = {},
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
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not GovernorFields then GovernorFields = loadModule("lib/governor_fields.lua") end
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
  ui.config.gov_startup_time = tonumber(cached.gov_startup_time) or 200
  ui.config.gov_spoolup_time = tonumber(cached.gov_spoolup_time) or 100
  ui.config.gov_spooldown_time = tonumber(cached.gov_spooldown_time) or 30
  ui.config.gov_tracking_time = tonumber(cached.gov_tracking_time) or 20
  ui.config.gov_recovery_time = tonumber(cached.gov_recovery_time) or 20
  ui.parsedCache = cached
end

local function queueGovRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not MspRuntime or not GovernorConfigApi or type(MspRuntime.getState) ~= "function" then
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
    command = GovernorConfigApi.command,
    simulatorResponse = GovernorConfigApi.simulatorResponse,
    timeout = 5.0,
    processReply = function(self, buf)
      local parsed = GovernorConfigApi.parse(buf)
      if type(parsed) ~= "table" then return Common.failPageRead(ui) end
      if parsed then
        ui.config.gov_startup_time = parsed.gov_startup_time or 200
        ui.config.gov_spoolup_time = parsed.gov_spoolup_time or 100
        ui.config.gov_spooldown_time = parsed.gov_spooldown_time or 30
        ui.config.gov_tracking_time = parsed.gov_tracking_time or 20
        ui.config.gov_recovery_time = parsed.gov_recovery_time or 20
        ui.parsedCache = parsed

        local session = getSession()
        if session then
          session.governor_config = parsed
          session.governorMode = parsed.gov_mode
        end
      end

      ui.runtime.readPending = false
      ui.loading = false
      ui.dirty = false
      ui.progress = 100
      ui.runtime.readComplete = readValid
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
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

local function queueGovWrite(requestRebuild)
  if not SavePipeline or not GovernorConfigApi then
    return false, "msp_runtime_unavailable"
  end

  -- Built on a copy, so a save that is refused or fails is still compared with what this visit read.
  local writeData = {}
  for k, v in pairs(ui.parsedCache or {}) do
    writeData[k] = v
  end

  writeData.gov_startup_time = ui.config.gov_startup_time
  writeData.gov_spoolup_time = ui.config.gov_spoolup_time
  writeData.gov_spooldown_time = ui.config.gov_spooldown_time
  writeData.gov_tracking_time = ui.config.gov_tracking_time
  writeData.gov_recovery_time = ui.config.gov_recovery_time

  local visit = ui.runtime
  local ok, err = SavePipeline.start({
    pageId = "setup_governor_time",
    steps = {
      {
        label = "MSP_SET_GOVERNOR_CONFIG",
        command = GovernorConfigApi.writeCommand,
        payload = GovernorConfigApi.buildWritePayload(writeData)
      }
    },
    -- The firmware copies these values into the running governor only at start-up
    -- (governorInit()); MSP_SET_GOVERNOR_CONFIG stores them and nothing more. So a save that
    -- changes one restarts the flight controller, and a save that changes nothing does not.
    reboot = GovernorConfigApi.payloadDiffers(ui.parsedCache, writeData),
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
        end
      end
      if ui.runtime ~= visit then return end
      ui.saving = false
      if result.status == "done" then
        ui.parsedCache = writeData
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
    SavePipeline.takeResult("setup_governor_time")
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
    gov_startup_time = 200,
    gov_spoolup_time = 100,
    gov_spooldown_time = 30,
    gov_tracking_time = 20,
    gov_recovery_time = 20
  }
  ui.parsedCache = {}

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

  -- A save whose notice was dismissed is held for its page instead of reported (save_pipeline.lua
  -- finish()). While this page stays open it claims that result here, or it would stay on its
  -- Saving overlay, with Save and Reload refused, until it is opened again.
  if ui.saving and SavePipeline and type(SavePipeline.takeResult) == "function" then
    SavePipeline.takeResult("setup_governor_time")
  end

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
    local msgText = ui.loading and pageText(i18n, "loading_message", "Reading governor configuration...") or pageText(i18n, "saving_message", "Saving governor configuration...")
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = titleText,
      message = msgText,
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or "Ramp Time"
  local title = pageText(i18n, "time", displayTitle)
  if type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(title, M.getHeaderActions())
  end

  -- A row's ? opens its line in the tool's help view, titled with the row's label.
  local openHelp = ctx.openHelp
  local function onRowHelp(text, label)
    if type(openHelp) == "function" and type(text) == "string" and text ~= "" then openHelp(text, label) end
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, title)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  -- 1. Startup time (stored in 0.1s, e.g. 200 = 20.0s)
  local label = pageText(i18n, "startup_time", "Startup time")
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    label,
    {
      helpText = pageText(i18n, "help_startup_time",
        "The ramp for throttle changes below handover, at idle, such as starting the motor."),
      helpTitle = label,
      onHelp = onRowHelp,
      min = 0,
      max = 600,
      step = 1,
      get = function() return ui.config.gov_startup_time end,
      set = function(v)
        ui.config.gov_startup_time = tonumber(v) or 200
        ui.dirty = true
      end,
      display = function(v)
        return string.format("%.1f", (tonumber(v) or 0) / 10)
      end
    }
  )

  -- 2. Spoolup time (stored in 0.1s, e.g. 100 = 10.0s)
  label = pageText(i18n, "spoolup_time", "Spoolup time")
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    label,
    {
      helpText = pageText(i18n, "help_spoolup_time",
        "The throttle ramp from idle up to the target headspeed; long enough to be gentle on the drivetrain, about 10 s."),
      helpTitle = label,
      onHelp = onRowHelp,
      min = GovernorFields.gov_spoolup_time.min,
      max = GovernorFields.gov_spoolup_time.max,
      step = GovernorFields.gov_spoolup_time.step,
      get = function() return ui.config.gov_spoolup_time end,
      set = function(v)
        ui.config.gov_spoolup_time = tonumber(v) or 100
        ui.dirty = true
      end,
      display = GovernorFields.seconds
    }
  )

  -- 3. Spooldown time (stored in 0.1s, e.g. 30 = 3.0s)
  label = pageText(i18n, "spooldown_time", "Spooldown time")
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    label,
    {
      helpText = pageText(i18n, "help_spooldown_time",
        "The ramp for throttle reductions at idle."),
      helpTitle = label,
      onHelp = onRowHelp,
      min = GovernorFields.gov_spooldown_time.min,
      max = GovernorFields.gov_spooldown_time.max,
      step = GovernorFields.gov_spooldown_time.step,
      get = function() return ui.config.gov_spooldown_time end,
      set = function(v)
        ui.config.gov_spooldown_time = tonumber(v) or 30
        ui.dirty = true
      end,
      display = GovernorFields.seconds
    }
  )

  -- 4. Tracking time (stored in 0.1s, e.g. 20 = 2.0s)
  label = pageText(i18n, "tracking_time", "Tracking time")
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    label,
    {
      helpText = pageText(i18n, "help_tracking_time",
        "The ramp for changes of the target headspeed in flight, such as a profile switch."),
      helpTitle = label,
      onHelp = onRowHelp,
      min = 0,
      max = 100,
      step = 1,
      get = function() return ui.config.gov_tracking_time end,
      set = function(v)
        ui.config.gov_tracking_time = tonumber(v) or 20
        ui.dirty = true
      end,
      display = GovernorFields.seconds
    }
  )

  -- 5. Recovery time (stored in 0.1s, e.g. 20 = 2.0s)
  label = pageText(i18n, "recovery_time", "Recovery time")
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    label,
    {
      helpText = pageText(i18n, "help_recovery_time",
        "The ramp for fast spool-ups in flight: recovery after throttle hold or a fallback, and autorotation bailout."),
      helpTitle = label,
      onHelp = onRowHelp,
      min = GovernorFields.gov_recovery_time.min,
      max = GovernorFields.gov_recovery_time.max,
      step = GovernorFields.gov_recovery_time.step,
      get = function() return ui.config.gov_recovery_time end,
      set = function(v)
        ui.config.gov_recovery_time = tonumber(v) or 20
        ui.dirty = true
      end,
      display = GovernorFields.seconds
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
  local help = loadModule("app/pages/setup/governor/time/help.lua")
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
  SavePipeline = nil
  GovernorFields = nil
  LoadingOverlay = nil
  t = nil
end

-- Asked before the page is left (ui/home.lua): true while an edit here is not saved.
function M.hasUnsavedChanges()
  return ui.dirty == true
end

return M
