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
local BlackboxConfigApi = nil
local FeatureConfigApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local ApiVersion = nil
local SavePipeline = nil
local t = nil

local FEATURE_BITS = {
  gps = 7,
  governor = 26,
  esc_sensor = 27
}

-- Each label is a key and fallback pair in the form the packager translates in place, so an
-- installed suite shows it in the pilot's language.
local FIELD_DEFS = {
  { labelKey = "log_command", labelFallback = "Command", bit = 0 },
  { labelKey = "log_setpoint", labelFallback = "Setpoint", bit = 1 },
  { labelKey = "log_mixer", labelFallback = "Mixer", bit = 2 },
  { labelKey = "log_pid", labelFallback = "PID", bit = 3 },
  { labelKey = "log_attitude", labelFallback = "Attitude", bit = 4 },
  { labelKey = "log_gyro_raw", labelFallback = "Gyro Raw", bit = 5 },
  { labelKey = "log_gyro", labelFallback = "Gyro", bit = 6 },
  { labelKey = "log_acc", labelFallback = "Acc", bit = 7 },
  { labelKey = "log_mag", labelFallback = "Mag", bit = 8 },
  { labelKey = "log_alt", labelFallback = "Alt", bit = 9 },
  { labelKey = "log_battery", labelFallback = "Battery", bit = 10 },
  { labelKey = "log_rssi", labelFallback = "RSSI", bit = 11 },
  { labelKey = "log_gps", labelFallback = "GPS", bit = 12, featureBit = FEATURE_BITS.gps },
  { labelKey = "log_rpm", labelFallback = "RPM", bit = 13 },
  { labelKey = "log_motors", labelFallback = "Motors", bit = 14 },
  { labelKey = "log_servos", labelFallback = "Servos", bit = 15 },
  { labelKey = "log_vbec", labelFallback = "VBEC", bit = 16 },
  { labelKey = "log_vbus", labelFallback = "VBUS", bit = 17 },
  { labelKey = "log_temps", labelFallback = "Temps", bit = 18 },
  { labelKey = "log_esc", labelFallback = "ESC", bit = 19, apiversiongte = { 12, 0, 7 }, featureBit = FEATURE_BITS.esc_sensor },
  { labelKey = "log_bec", labelFallback = "BEC", bit = 20, apiversiongte = { 12, 0, 7 }, featureBit = FEATURE_BITS.esc_sensor },
  { labelKey = "log_esc2", labelFallback = "ESC2", bit = 21, apiversiongte = { 12, 0, 7 }, featureBit = FEATURE_BITS.esc_sensor },
  { labelKey = "log_governor", labelFallback = "Governor", bit = 22, apiversiongte = { 12, 0, 9 }, featureBit = FEATURE_BITS.governor }
}

local ui = {
  loaded = false,
  dirty = false,
  featureBitmap = 0,
  cfg = {
    blackbox_supported = 0,
    device = 0,
    mode = 0,
    denom = 8,
    fields = 0,
    initialEraseFreeSpaceKiB = 0,
    rollingErase = 0,
    gracePeriod = 5
  },
  runtime = {
    readPending = false,
    requestRebuild = nil,
    lastSessionSignature = nil,
    syncHeaderTitle = nil
  },
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
  if not BlackboxConfigApi then BlackboxConfigApi = loadModule("tasks/msp/api/blackbox_config.lua") end
  if not FeatureConfigApi then FeatureConfigApi = loadModule("tasks/msp/api/feature_config.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not ApiVersion then ApiVersion = loadModule("lib/api_version.lua") end
  if not t then t = Common and Common.pageT("setup_blackbox") or nil end
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

local function hasBit(mask, bit)
  local b = tonumber(bit or 0) or 0
  return (((tonumber(mask or 0) or 0) & (1 << b)) ~= 0)
end

local function setBit(mask, bit, enable)
  local m = tonumber(mask or 0) or 0
  local b = tonumber(bit or 0) or 0
  local f = (1 << b)
  if enable then
    return (m | f)
  end
  return (m & (~f))
end

local function supportsField(def, rawApiVersion)
  if def.apiversiongte and ApiVersion then
    if not ApiVersion.isAtLeast(rawApiVersion, def.apiversiongte) then
      return false
    end
  end
  if def.featureBit and not hasBit(ui.featureBitmap, def.featureBit) then
    return false
  end
  return true
end

local function canEdit()
  local supported = tonumber(ui.cfg.blackbox_supported or 0) == 1
  local device = tonumber(ui.cfg.device or 0) or 0
  local mode = tonumber(ui.cfg.mode or 0) or 0
  return ui.loaded and supported and device ~= 0 and mode ~= 0
end

local function loadFromSession()
  local session = getSession()
  if not session or type(session.blackbox) ~= "table" or type(session.blackbox.config) ~= "table" then return false end
  ui.featureBitmap = tonumber(session.blackbox.feature and session.blackbox.feature.enabledFeatures or 0) or 0
  local parsed = session.blackbox.config
  ui.cfg.blackbox_supported = tonumber(parsed.blackbox_supported or 0) or 0
  ui.cfg.device = tonumber(parsed.device or 0) or 0
  ui.cfg.mode = tonumber(parsed.mode or 0) or 0
  ui.cfg.denom = tonumber(parsed.denom or 1) or 1
  ui.cfg.fields = tonumber(parsed.fields or 0) or 0
  ui.cfg.initialEraseFreeSpaceKiB = tonumber(parsed.initialEraseFreeSpaceKiB or 0) or 0
  ui.cfg.rollingErase = tonumber(parsed.rollingErase or 0) or 0
  ui.cfg.gracePeriod = tonumber(parsed.gracePeriod or 0) or 0
  return true
end

local function queueBlackboxRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not MspRuntime or not BlackboxConfigApi or not FeatureConfigApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  local readValid = true
  ui.runtime.readPending = true
  if not isAutoReload then
    ui.loading = true
    ui.progress = 0
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  -- Queue FEATURE_CONFIG read first
  queue:add({
    command = FeatureConfigApi.command,
    simulatorResponse = FeatureConfigApi.simulatorResponse,
    processReply = function(self, buf)
      local reply = FeatureConfigApi.parse(buf)
      if type(reply) ~= "table" then return Common.failPageRead(ui) end
      ui.featureBitmap = (reply and reply.enabledFeatures) or 0

      -- Now queue BLACKBOX_CONFIG read
      queue:add({
        command = BlackboxConfigApi.command,
        simulatorResponse = BlackboxConfigApi.simulatorResponse,
        processReply = function(self2, buf2)
          local parsed = BlackboxConfigApi.parse(buf2)
          if type(parsed) ~= "table" then return Common.failPageRead(ui) end
          if parsed then
            ui.cfg.blackbox_supported = parsed.blackbox_supported or 0
            ui.cfg.device = parsed.device or 0
            ui.cfg.mode = parsed.mode or 0
            ui.cfg.denom = parsed.denom or 1
            ui.cfg.fields = parsed.fields or 0
            ui.cfg.initialEraseFreeSpaceKiB = parsed.initialEraseFreeSpaceKiB or 0
            ui.cfg.rollingErase = parsed.rollingErase or 0
            ui.cfg.gracePeriod = parsed.gracePeriod or 0

            -- Sync to session
            local session = getSession()
            if session then
              if type(session.blackbox) ~= "table" then
                session.blackbox = {}
              end
              session.blackbox.feature = { enabledFeatures = ui.featureBitmap }
              session.blackbox.config = {
                blackbox_supported = ui.cfg.blackbox_supported,
                device = ui.cfg.device,
                mode = ui.cfg.mode,
                denom = ui.cfg.denom,
                fields = ui.cfg.fields,
                initialEraseFreeSpaceKiB = ui.cfg.initialEraseFreeSpaceKiB,
                rollingErase = ui.cfg.rollingErase,
                gracePeriod = ui.cfg.gracePeriod
              }
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
    end,
    errorHandler = function(_, reason)
      readValid = false
      -- The queue drops this read (reason "cleared") when the page is left or the link goes, and
      -- the read ends there. Queuing the next one from here would file it under whatever owns the
      -- queue then, and its reply would run against a page that has been closed.
      if reason == "cleared" then
        ui.runtime.readPending = false
        ui.loading = false
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
        return
      end
      -- If feature config fails, still try to read blackbox config
      queue:add({
        command = BlackboxConfigApi.command,
        simulatorResponse = BlackboxConfigApi.simulatorResponse,
        processReply = function(self2, buf2)
          local parsed = BlackboxConfigApi.parse(buf2)
          if type(parsed) ~= "table" then return Common.failPageRead(ui) end
          if parsed then
            ui.cfg.blackbox_supported = parsed.blackbox_supported or 0
            ui.cfg.device = parsed.device or 0
            ui.cfg.mode = parsed.mode or 0
            ui.cfg.denom = parsed.denom or 1
            ui.cfg.fields = parsed.fields or 0
            ui.cfg.initialEraseFreeSpaceKiB = parsed.initialEraseFreeSpaceKiB or 0
            ui.cfg.rollingErase = parsed.rollingErase or 0
            ui.cfg.gracePeriod = parsed.gracePeriod or 0
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
    end
  })

  return true, nil
end

local function queueBlackboxWrite(requestRebuild)
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or not BlackboxConfigApi then
    return false, "msp_runtime_unavailable"
  end

  -- What is saved, taken now: the page can be left while the write is on the wire, and a page
  -- opened again starts from other values. The payload and the session copy come from here.
  local cfg = {
    blackbox_supported = ui.cfg.blackbox_supported,
    device = ui.cfg.device,
    mode = ui.cfg.mode,
    denom = ui.cfg.denom,
    fields = ui.cfg.fields,
    initialEraseFreeSpaceKiB = ui.cfg.initialEraseFreeSpaceKiB,
    rollingErase = ui.cfg.rollingErase,
    gracePeriod = ui.cfg.gracePeriod
  }

  -- The write and the EEPROM commit belong to the pipeline, not to this page: the page can be
  -- left while they are on the wire, and its close releases ui.runtime and the module handles
  -- above. So nothing below may assume the page is still open.
  local ok, err = SavePipeline.start({
    pageId = "setup_controls_blackbox_logging",
    steps = {
      {
        label = "MSP_SET_BLACKBOX_CONFIG",
        command = BlackboxConfigApi.writeCommand,
        payload = BlackboxConfigApi.buildWritePayload(cfg)
      }
    },
    reboot = false,
    onSaved = function()
      local session = getSession()
      if session then
        if type(session.blackbox) ~= "table" then
          session.blackbox = {}
        end
        session.blackbox.config = cfg
      end
      ui.dirty = false
    end,
    onDone = function(result)
      ui.saving = false
      if not ui.runtime then return end
      if result.saved then queueBlackboxRead(true) end
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

  if not ui.runtime then
    ui.runtime = {
      readPending = false,
      requestRebuild = nil,
      lastSessionSignature = nil,
      syncHeaderTitle = nil
    }
  end
  ui.loading = false
  ui.saving = false
  ui.runtime.readPending = false

  ui.cfg = {
    blackbox_supported = 0,
    device = 0,
    mode = 0,
    denom = 8,
    fields = 0,
    initialEraseFreeSpaceKiB = 0,
    rollingErase = 0,
    gracePeriod = 5
  }

  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()
  queueBlackboxRead(false)
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
    local titleText = ui.loading and "@i18n(app.loading)@" or "@i18n(app.saving)@"
    local msgText = ui.loading and pageText(i18n, "loading_logging", "Loading blackbox logging...") or pageText(i18n, "saving_logging", "Saving blackbox logging...")
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = titleText,
      message = msgText,
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or "Logging"
  local title = pageText(i18n, "title_logging", displayTitle)
  if type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(title, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, title)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  local session = getSession()
  local rawApiVersion = session and session.apiVersion

  for i = 1, #FIELD_DEFS do
    local def = FIELD_DEFS[i]
    if supportsField(def, rawApiVersion) then
      local label = pageText(i18n, def.labelKey, def.labelFallback)
      cursorY = cursorY + Controls.appendRadioSwitch(
        children, x, cursorY, w,
        label,
        function()
          return hasBit(ui.cfg.fields, def.bit)
        end,
        function(v)
          ui.cfg.fields = setBit(ui.cfg.fields, def.bit, v)
          ui.dirty = true
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end,
        function() return canEdit() end
      )
    end
  end

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
  if not M.canSave() then return false, "loaded_data_missing" end
  -- The header's Save stays reachable over the overlay. A second save beside the running one
  -- would send the same write again, with a second EEPROM write.
  if ui.saving then return false end
  local ok, err = queueBlackboxWrite(ctx and ctx.requestRebuild)
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
  -- Nothing is read under a running save; Reload works again once the save has finished.
  if ui.saving then return true end
  local session = getSession()
  if session then
    ui.dirty = false
    loadFromSession()
    queueBlackboxRead(false)
  end
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/controls/blackbox/logging/help.lua")
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
  Controls = nil
  Common = nil
  MspRuntime = nil
  BlackboxConfigApi = nil
  FeatureConfigApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  ApiVersion = nil
  SavePipeline = nil
  t = nil
end

-- Asked before the page is left (ui/home.lua): true while an edit here is not saved.
function M.hasUnsavedChanges()
  return ui.dirty == true
end

return M
