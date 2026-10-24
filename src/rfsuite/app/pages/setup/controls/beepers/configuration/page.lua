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
local BeeperConfigApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local SavePipeline = nil
local t = nil

-- Each label is a key and fallback pair in the form the packager translates in place, so an
-- installed suite shows it in the pilot's language.
local BEEPER_FIELDS = {
  { bit = 0, labelKey = "field_gyro_calibrated", labelFallback = "Gyro calibrated" },
  { bit = 1, labelKey = "field_rx_lost", labelFallback = "RX lost" },
  { bit = 2, labelKey = "field_rx_lost_landing", labelFallback = "RX lost landing" },
  { bit = 3, labelKey = "field_disarming", labelFallback = "Disarming" },
  { bit = 4, labelKey = "field_arming", labelFallback = "Arming" },
  { bit = 5, labelKey = "field_arming_gps_fix", labelFallback = "Arming GPS fix" },
  { bit = 6, labelKey = "field_bat_crit_low", labelFallback = "Battery critical low" },
  { bit = 7, labelKey = "field_bat_low", labelFallback = "Battery low" },
  { bit = 8, labelKey = "field_gps_status", labelFallback = "GPS status" },
  { bit = 9, labelKey = "field_rx_set", labelFallback = "RX set" },
  { bit = 10, labelKey = "field_acc_calibration", labelFallback = "ACC calibration" },
  { bit = 11, labelKey = "field_acc_calibration_fail", labelFallback = "ACC calibration fail" },
  { bit = 12, labelKey = "field_ready_beep", labelFallback = "Ready beep" },
  { bit = 14, labelKey = "field_disarm_repeat", labelFallback = "Disarm repeat" },
  { bit = 15, labelKey = "field_armed", labelFallback = "Armed" },
  { bit = 16, labelKey = "field_system_init", labelFallback = "System init" },
  { bit = 17, labelKey = "field_usb", labelFallback = "USB" },
  { bit = 18, labelKey = "field_blackbox_erase", labelFallback = "Blackbox erase" },
  { bit = 21, labelKey = "field_arming_gps_no_fix", labelFallback = "Arming GPS no fix" }
}

local ui = {
  loaded = false,
  dirty = false,
  config = {
    beeper_off_flags = 0,
    dshotBeaconTone = 1,
    dshotBeaconOffFlags = 0
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
  if not BeeperConfigApi then BeeperConfigApi = loadModule("tasks/msp/api/beeper_config.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not t then t = Common and Common.pageT("setup_beepers") or nil end
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

local function isBitSet(mask, bit)
  local m = tonumber(mask or 0) or 0
  return (m & (1 << bit)) ~= 0
end

local function setBit(mask, bit, set)
  local m = tonumber(mask or 0) or 0
  local f = (1 << bit)
  if set then
    return (m | f)
  end
  return (m & (~f))
end

local function isBeeperEnabled(bit)
  local offMask = tonumber(ui.config.beeper_off_flags or 0) or 0
  return not isBitSet(offMask, bit)
end

local function setBeeperEnabled(bit, enabled)
  ui.config.beeper_off_flags = setBit(ui.config.beeper_off_flags, bit, not enabled)
end

local function loadFromSession()
  local session = getSession()
  if not session or type(session.setup_beepers) ~= "table" then return end
  ui.config.beeper_off_flags = tonumber(session.setup_beepers.beeper_off_flags) or 0
  ui.config.dshotBeaconTone = tonumber(session.setup_beepers.dshotBeaconTone) or 1
  ui.config.dshotBeaconOffFlags = tonumber(session.setup_beepers.dshotBeaconOffFlags) or 0
end

local function queueBeeperConfigRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not MspRuntime or not BeeperConfigApi or type(MspRuntime.getState) ~= "function" then
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

  queue:add({
    command = BeeperConfigApi.command,
    simulatorResponse = BeeperConfigApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = BeeperConfigApi.parse(buf)
      if type(parsed) ~= "table" then return Common.failPageRead(ui) end
      if parsed then
        ui.config.beeper_off_flags = parsed.beeper_off_flags or 0
        ui.config.dshotBeaconTone = parsed.dshotBeaconTone or 1
        ui.config.dshotBeaconOffFlags = parsed.dshotBeaconOffFlags or 0
        
        -- Sync to session
        local session = getSession()
        if session then
          if type(session.setup_beepers) ~= "table" then
            session.setup_beepers = {}
          end
          session.setup_beepers.beeper_off_flags = ui.config.beeper_off_flags
          session.setup_beepers.dshotBeaconTone = ui.config.dshotBeaconTone
          session.setup_beepers.dshotBeaconOffFlags = ui.config.dshotBeaconOffFlags
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

local function queueBeeperConfigWrite(requestRebuild)
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or not BeeperConfigApi then
    return false, "msp_runtime_unavailable"
  end

  -- The write and the EEPROM commit belong to the pipeline, not to this page: the page can be
  -- left while they are on the wire, and its close releases ui.runtime and the module handles
  -- above. So nothing below may assume the page is still open.
  local ok, err = SavePipeline.start({
    pageId = "setup_controls_beepers_configuration",
    steps = {
      {
        label = "MSP_SET_BEEPER_CONFIG",
        command = BeeperConfigApi.writeCommand,
        payload = BeeperConfigApi.buildWritePayload({
          beeper_off_flags = ui.config.beeper_off_flags,
          dshotBeaconTone = ui.config.dshotBeaconTone,
          dshotBeaconOffFlags = ui.config.dshotBeaconOffFlags
        })
      }
    },
    reboot = false,
    onSaved = function()
      ui.dirty = false
    end,
    onDone = function(result)
      ui.saving = false
      if not ui.runtime then return end
      if result.saved then queueBeeperConfigRead(true) end
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

  ui.config = {
    beeper_off_flags = 0,
    dshotBeaconTone = 1,
    dshotBeaconOffFlags = 0
  }

  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()
  queueBeeperConfigRead(false)
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
    local msgText = ui.loading and pageText(i18n, "loading", "Loading beeper configuration...") or pageText(i18n, "saving", "Saving beeper configuration...")
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = titleText,
      message = msgText,
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or "Configuration"
  local title = pageText(i18n, "configuration", displayTitle)
  if type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(title, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, title)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  for i = 1, #BEEPER_FIELDS do
    local def = BEEPER_FIELDS[i]
    local label = pageText(i18n, def.labelKey, def.labelFallback)
    
    cursorY = cursorY + Controls.appendRadioSwitch(
      children,
      x, cursorY, w,
      label,
      function()
        return isBeeperEnabled(def.bit)
      end,
      function(v)
        setBeeperEnabled(def.bit, v)
        ui.dirty = true
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      end
    )
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
  local ok, err = queueBeeperConfigWrite(ctx and ctx.requestRebuild)
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
    queueBeeperConfigRead(false)
  end
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/controls/beepers/configuration/help.lua")
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
  BeeperConfigApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  SavePipeline = nil
  t = nil
end

-- Asked before the page is left (ui/home.lua): true while an edit here is not saved.
function M.hasUnsavedChanges()
  return ui.dirty == true
end

return M
