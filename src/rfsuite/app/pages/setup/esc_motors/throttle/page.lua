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
local SavePipeline = nil
local Common = nil
local MspRuntime = nil
local MotorConfigApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local ApiVersion = nil
local t = nil

local ui = {
  loaded = false,
  dirty = false,
  loading = false,
  progress = 0,
  baseTitle = nil,
  config = {
    motor_pwm_protocol = 0,
    motor_pwm_rate = 250,
    mincommand = 1000,
    minthrottle = 1070,
    maxthrottle = 2000,
    use_unsynced_pwm = 0
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
  if not MotorConfigApi then MotorConfigApi = loadModule("tasks/msp/api/motor_config.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not ApiVersion then ApiVersion = loadModule("lib/api_version.lua") end
  if not t then t = Common and Common.pageT("setup_esc_motors") or nil end
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
  if not session or type(session.setup_esc_motors_throttle) ~= "table" then return end
  local cached = session.setup_esc_motors_throttle
  ui.config.motor_pwm_protocol = tonumber(cached.motor_pwm_protocol) or 0
  ui.config.motor_pwm_rate = tonumber(cached.motor_pwm_rate) or 250
  ui.config.mincommand = tonumber(cached.mincommand) or 1000
  ui.config.minthrottle = tonumber(cached.minthrottle) or 1070
  ui.config.maxthrottle = tonumber(cached.maxthrottle) or 2000
  ui.config.use_unsynced_pwm = tonumber(cached.use_unsynced_pwm) or 0
  ui.parsedCache = cached.parsedCache or {}
end

local function queueThrottleRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not MspRuntime or not MotorConfigApi or type(MspRuntime.getState) ~= "function" then
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
    command = MotorConfigApi.command,
    simulatorResponse = MotorConfigApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = MotorConfigApi.parse(buf)
      if type(parsed) ~= "table" then return Common.failPageRead(ui) end
      if parsed then
        ui.config.motor_pwm_protocol = parsed.motor_pwm_protocol or 0
        ui.config.motor_pwm_rate = parsed.motor_pwm_rate or 250
        ui.config.mincommand = parsed.mincommand or 1000
        ui.config.minthrottle = parsed.minthrottle or 1070
        ui.config.maxthrottle = parsed.maxthrottle or 2000
        ui.config.use_unsynced_pwm = parsed.use_unsynced_pwm or 0

        ui.parsedCache = parsed

        local session = getSession()
        if session then
          session.setup_esc_motors_throttle = {
            motor_pwm_protocol = ui.config.motor_pwm_protocol,
            motor_pwm_rate = ui.config.motor_pwm_rate,
            mincommand = ui.config.mincommand,
            minthrottle = ui.config.minthrottle,
            maxthrottle = ui.config.maxthrottle,
            use_unsynced_pwm = ui.config.use_unsynced_pwm,
            parsedCache = ui.parsedCache
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

  return true, nil
end

local function queueThrottleWrite(requestRebuild)
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or not MotorConfigApi then
    return false, "msp_runtime_unavailable"
  end

  local writeData = {}
  if ui.parsedCache then
    for k, v in pairs(ui.parsedCache) do
      writeData[k] = v
    end
  end

  writeData.motor_pwm_protocol = ui.config.motor_pwm_protocol
  writeData.motor_pwm_rate = ui.config.motor_pwm_rate
  writeData.mincommand = ui.config.mincommand
  writeData.minthrottle = ui.config.minthrottle
  writeData.maxthrottle = ui.config.maxthrottle
  writeData.use_unsynced_pwm = ui.config.use_unsynced_pwm

  -- The chain that stood here cleared the dirty flag inside the REBOOT step's processReply --
  -- the moment the restart was sent, not the moment the settings were stored. It is reported at
  -- the EEPROM acknowledgement now, and everything after it belongs to the pipeline.
  return SavePipeline.start({
    pageId = "setup_esc_motors_throttle",
    steps = {
      {
        label = "MSP_SET_MOTOR_CONFIG",
        command = MotorConfigApi.writeCommand,
        payload = MotorConfigApi.buildWritePayload(writeData)
      }
    },
    reboot = true,
    invalidateSessionKeys = { "setup_esc_motors_throttle" },
    onSaved = function()
      ui.dirty = false
    end,
    onDone = function(result)
      if result.status ~= "done" then
        ui.dirty = true
      end
      if type(requestRebuild) == "function" then
        requestRebuild()
      end
    end
  })
end

local function ensureLoaded()
  if ui.loaded then return end
  -- A save whose overlay was dismissed finished without a screen. Its outcome was held back
  -- rather than raised over whatever page the user went to; claim it now that this one is open.
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if SavePipeline and type(SavePipeline.takeResult) == "function" then
    SavePipeline.takeResult("setup_esc_motors_throttle")
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
    motor_pwm_protocol = 0,
    motor_pwm_rate = 250,
    mincommand = 1000,
    minthrottle = 1070,
    maxthrottle = 2000,
    use_unsynced_pwm = 0
  }
  ui.parsedCache = {}

  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()

  queueThrottleRead(false)
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

-- Protocol numbers of the two entries that are not always present. Both sit at a fixed
-- position in the flight controller's enum once the firmware has them; only the entries
-- behind them move. See PROTOCOL_HEAD below.
local PROTO_CASTLE = 9
local PROTO_SRXL2 = 10

local function isPwmRateEnabled(proto, hasCastle, hasSrxl2)
  if proto == 0 or proto == 1 or proto == 2 or proto == 3 or proto == 4 then return true end
  if hasCastle and proto == PROTO_CASTLE then return true end
  if hasSrxl2 and proto == PROTO_SRXL2 then return true end
  return false
end

local function isMincommandEnabled(proto, hasCastle, hasSrxl2)
  if proto == 0 or proto == 1 or proto == 2 or proto == 3 or proto == 4 then return true end
  if hasCastle and proto == PROTO_CASTLE then return true end
  if hasSrxl2 and proto == PROTO_SRXL2 then return true end
  return false
end

local function isMinthrottleEnabled(proto, hasCastle, hasSrxl2)
  if proto == 0 or proto == 1 or proto == 2 or proto == 3 or proto == 4 then return true end
  if hasCastle and proto == PROTO_CASTLE then return true end
  if hasSrxl2 and proto == PROTO_SRXL2 then return true end
  return false
end

local function isMaxthrottleEnabled(proto, hasCastle, hasSrxl2)
  if proto == 0 or proto == 1 or proto == 2 or proto == 3 or proto == 4 then return true end
  if hasCastle and proto == PROTO_CASTLE then return true end
  if hasSrxl2 and proto == PROTO_SRXL2 then return true end
  return false
end

local function isUnsyncedEnabled(proto)
  if proto == 1 or proto == 2 or proto == 3 or proto == 4 then return true end
  return false
end

-- The combo writes the position in this list, so the list has to be the flight controller's
-- own protocol enum: the same entries, in the same order, and no longer than the board's.
-- Both CASTLE and SRXL2 were added in front of DISABLED as the firmware gained them, which
-- moves DISABLED's number, so the tail is appended entry by entry instead of being written
-- out twice. A conditional entry in the middle of a positional list makes its gate part of
-- the wire format: a gate one release early shifts every number from the insertion point up,
-- in both directions at once.
local PROTOCOL_HEAD = {
  "PWM", "ONESHOT125", "ONESHOT42", "MULTISHOT", "BRUSHED",
  "DSHOT150", "DSHOT300", "DSHOT600", "PROSHOT"
}

local function buildProtocolOptions(hasCastle, hasSrxl2)
  local labels = {}
  for i = 1, #PROTOCOL_HEAD do
    labels[i] = PROTOCOL_HEAD[i]
  end
  if hasCastle then labels[#labels + 1] = "CASTLE" end
  if hasSrxl2 then labels[#labels + 1] = "SRXL2" end
  labels[#labels + 1] = "DISABLED"

  local options = {}
  for idx, label in ipairs(labels) do
    options[idx] = { label = label, value = idx - 1 }
  end
  return options
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
    local titleText = "@i18n(app.loading)@"
    local msgText = pageText(i18n, "loading", "Loading throttle configuration...")
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = titleText,
      message = msgText,
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or "Throttle"
  local title = pageText(i18n, "title_throttle", displayTitle)
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
  local hasCastle = false
  local hasSrxl2 = false
  if rawApiVersion and ApiVersion then
    -- CASTLE reached the firmware while the API was already at 12.8, SRXL2 while it was at
    -- 12.9 and before the bump to 12.10. These are the two floors the Configurator gates the
    -- same list on.
    hasCastle = ApiVersion.isAtLeast(rawApiVersion, {12, 0, 8})
    hasSrxl2 = ApiVersion.isAtLeast(rawApiVersion, {12, 0, 10})
  end

  local protocolOptions = buildProtocolOptions(hasCastle, hasSrxl2)

  local proto = ui.config.motor_pwm_protocol

  -- 1. Throttle Protocol
  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    pageText(i18n, "throttle_protocol", "Throttle Protocol"),
    protocolOptions,
    proto,
    function(newVal)
      local val = tonumber(newVal) or 0
      if ui.config.motor_pwm_protocol ~= val then
        ui.config.motor_pwm_protocol = val
        ui.dirty = true
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      end
    end
  )

  -- 2. Update frequency
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "motor_pwm_rate", "Update frequency"),
    {
      min = 50,
      max = 8000,
      suffix = "Hz",
      active = function() return isPwmRateEnabled(proto, hasCastle, hasSrxl2) end,
      get = function() return ui.config.motor_pwm_rate end,
      set = function(v)
        ui.config.motor_pwm_rate = tonumber(v) or 250
        ui.dirty = true
      end
    }
  )

  -- 3. Motor Stop PWM Value
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "mincommand", "Motor Stop PWM Value"),
    {
      min = 50,
      max = 2250,
      suffix = "us",
      active = function() return isMincommandEnabled(proto, hasCastle, hasSrxl2) end,
      get = function() return ui.config.mincommand end,
      set = function(v)
        ui.config.mincommand = tonumber(v) or 1000
        ui.dirty = true
      end
    }
  )

  -- 4. 0% Throttle PWM Value
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "min_throttle", "0% Throttle PWM Value"),
    {
      min = 50,
      max = 2250,
      suffix = "us",
      active = function() return isMinthrottleEnabled(proto, hasCastle, hasSrxl2) end,
      get = function() return ui.config.minthrottle end,
      set = function(v)
        ui.config.minthrottle = tonumber(v) or 1070
        ui.dirty = true
      end
    }
  )

  -- 5. 100% Throttle PWM Value
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "max_throttle", "100% Throttle PWM Value"),
    {
      min = 50,
      max = 2250,
      suffix = "us",
      active = function() return isMaxthrottleEnabled(proto, hasCastle, hasSrxl2) end,
      get = function() return ui.config.maxthrottle end,
      set = function(v)
        ui.config.maxthrottle = tonumber(v) or 2000
        ui.dirty = true
      end
    }
  )

  -- 6. Unsynced ESC Update
  cursorY = cursorY + Controls.appendRadioSwitch(
    children, x, cursorY, w,
    pageText(i18n, "unsynced", "Unsynced ESC Update"),
    function() return ui.config.use_unsynced_pwm ~= 0 end,
    function(nextBool)
      ui.config.use_unsynced_pwm = nextBool and 1 or 0
      ui.dirty = true
    end,
    function() return isUnsyncedEnabled(proto) end
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
  if not M.canSave() then return false, "loaded_data_missing" end
  local ok, err = queueThrottleWrite(ctx and ctx.requestRebuild)
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
  local session = getSession()
  if session then
    ui.dirty = false
    loadFromSession()
    queueThrottleRead(false)
  end
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/esc_motors/throttle/help.lua")
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
  MotorConfigApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  ApiVersion = nil
  t = nil
end

-- Asked before the page is left (ui/home.lua): true while an edit here is not saved.
function M.hasUnsavedChanges()
  return ui.dirty == true
end

return M
