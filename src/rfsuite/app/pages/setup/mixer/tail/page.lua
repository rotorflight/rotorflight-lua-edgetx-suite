local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Controls = nil
local SavePipeline = nil
local Common = nil
local MspRuntime = nil
local MixerConfigApi = nil
local MixerInputYawApi = nil
local LoadingOverlay = nil
local LiveOverride = nil
local t = nil

local MSP_SET_MIXER_OVERRIDE = 191
local MIXER_OVERRIDE_OFF = 2501
local MIXER_OVERRIDE_ON = 0
-- MIXER_IN_STABILIZED_YAW: only the tail is held at centre while its trim is set.
local OVERRIDE_INPUTS = { 3 }
-- The trim goes out once it has been left unchanged this long, so the tail moves to the value the
-- pilot stopped at rather than through every step on the way.
local LIVE_SETTLE = 0.5


local function u16_to_s16(u)
  if u >= 0x8000 then
    return u - 0x10000
  else
    return u
  end
end

local function s16_to_u16(s)
  if s < 0 then return s + 0x10000 end
  return s
end

local function round(x)
  if x >= 0 then return math.floor(x + 0.5) end
  return math.ceil(x - 0.5)
end

local function rateToDir(u16rate)
  return (u16_to_s16(u16rate) < 0) and 0 or 1
end

local function dirSign(d)
  return (d == 0) and -1 or 1
end

local ui = {
  loaded = false,
  dirty = false,
  loading = false,
  progress = 0,
  baseTitle = nil,
  config = {
    tail_rotor_mode = 0,
    tail_motor_idle = 0,
    tail_center_trim = 0,
    yaw_direction = 1,
    yaw_calibration = 400,
    -- Centre trim and yaw limits are the flight controller's raw numbers (see rawToField below);
    -- 1250 is the firmware's default yaw limit.
    yaw_cw_limit = 1250,
    yaw_ccw_limit = 1250
  },
  apiData = {},
  -- The override, from app/pages/lib/live_override.lua, created the first time * is pressed in a
  -- visit: it holds what the board has as far as this page knows (the read, or the last save that
  -- reached EEPROM) and what went out live. A visit that never presses * never loads it.
  override = nil,
  runtime = {
    readPending = false,
    requestRebuild = nil
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
  if not MixerConfigApi then MixerConfigApi = loadModule("tasks/msp/api/mixer_config.lua") end
  if not MixerInputYawApi then MixerInputYawApi = loadModule("tasks/msp/api/get_mixer_input_yaw.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not t then t = Common and Common.pageT("setup_mixer") or nil end

  if type(ui.runtime) ~= "table" then
    ui.runtime = {
      readPending = false,
      requestRebuild = nil
    }
  end
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

local function getRcConfig(session)
  if type(session) ~= "table" then return nil end
  if type(session.setup_mixer_tail) ~= "table" then
    session.setup_mixer_tail = {}
  end
  return session.setup_mixer_tail
end

local function loadFromSession()
  local session = getSession()
  local rcConfig = getRcConfig(session)
  if not rcConfig then return end
  ui.config.tail_rotor_mode = rcConfig.tail_rotor_mode or 0
  ui.config.tail_motor_idle = rcConfig.tail_motor_idle or 0
  ui.config.tail_center_trim = rcConfig.tail_center_trim or 0
  ui.config.yaw_direction = rcConfig.yaw_direction or 1
  ui.config.yaw_calibration = rcConfig.yaw_calibration or 400
  ui.config.yaw_cw_limit = rcConfig.yaw_cw_limit or 1250
  ui.config.yaw_ccw_limit = rcConfig.yaw_ccw_limit or 1250

  if type(rcConfig.apiData) == "table" then
    ui.apiData = rcConfig.apiData
  end
end

local function saveToSession()
  local session = getSession()
  local rcConfig = getRcConfig(session)
  if not rcConfig then return end
  rcConfig.tail_rotor_mode = ui.config.tail_rotor_mode
  rcConfig.tail_motor_idle = ui.config.tail_motor_idle
  rcConfig.tail_center_trim = ui.config.tail_center_trim
  rcConfig.yaw_direction = ui.config.yaw_direction
  rcConfig.yaw_calibration = ui.config.yaw_calibration
  rcConfig.yaw_cw_limit = ui.config.yaw_cw_limit
  rcConfig.yaw_ccw_limit = ui.config.yaw_ccw_limit
  rcConfig.apiData = ui.apiData
end

local function isTailMotorizedMode()
  return (tonumber(ui.config.tail_rotor_mode) or 0) >= 1
end

-- The centre trim and the two yaw limits are held as the flight controller stores them, and only
-- the fields convert, by the tail mode selected now: a motorised tail shows them in 0.1 % (the raw
-- number), variable pitch in 0.1 degree (raw * 24 / 100). The firmware applies the same stored
-- numbers in every tail mode -- the input limits as min/1000 and max/1000, the trim as
-- tail_center_trim/1000 -- so changing Tail Mode changes how they read, not what Save writes.
-- Converting them on the way in under the mode read and on the way out under the mode selected
-- rescaled all three on every mode change: from variable pitch to a motorised tail the default
-- limits of 1250 went out as 300, the other way as 5208.
local function rawToField(raw)
  raw = tonumber(raw) or 0
  if isTailMotorizedMode() then return raw end
  return round(raw * 24 / 100)
end

local function fieldToRaw(value)
  value = tonumber(value) or 0
  if isTailMotorizedMode() then return value end
  return round(value * 100 / 24)
end

local function copyRecord(record)
  local copy = {}
  for k, v in pairs(record) do copy[k] = v end
  return copy
end

local function getQueue()
  if not MspRuntime or type(MspRuntime.getState) ~= "function" then return nil end
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then return nil end
  return queue
end

-- The one value the live loop sends.
local function trimValues()
  return { tail_center_trim = ui.config.tail_center_trim or 0 }
end

local function overrideActive()
  return ui.override ~= nil and ui.override.active == true
end

-- A save is still writing: a step or the EEPROM commit is ahead. The pipeline queues each step from
-- the previous reply, so a rollback queued now would land between them and EEPROM could keep the
-- old value while the save reports the new one. A save that needs no restart lets the page be left
-- meanwhile (SavePipeline.blocksNavigation()). Asked of the pipeline rather than kept in a flag:
-- a dismissed save's outcome is delivered late, and a flag cleared there could stay set.
local function saveWriting()
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or type(SavePipeline.getProgress) ~= "function" then return false end
  local progress = SavePipeline.getProgress()
  local phases = SavePipeline.PHASE or {}
  return type(progress) == "table"
    and (progress.phase == (phases.WRITE or "write") or progress.phase == (phases.COMMIT or "commit"))
end

local function ensureOverride()
  if ui.override then return ui.override end
  local read = ui.apiData.MIXER_CONFIG
  if type(read) ~= "table" then return nil end
  if not LiveOverride then LiveOverride = loadModule("app/pages/lib/live_override.lua") end
  if not LiveOverride then return nil end
  ui.override = LiveOverride.new({
    command = MSP_SET_MIXER_OVERRIDE,
    inputs = OVERRIDE_INPUTS,
    on = MIXER_OVERRIDE_ON,
    off = MIXER_OVERRIDE_OFF,
    cadence = "settle",
    interval = LIVE_SETTLE
  })
  -- The record read stays as read (writes go out as copies), so it is what the board holds.
  ui.override:snapshot(read, { tail_center_trim = read.tail_center_trim or 0 })
  return ui.override
end

-- The override is offered for a variable-pitch tail only, as the board has it and as the page shows
-- it, with nothing else edited. A disarmed flight controller drives motors from motor override
-- alone (motorUpdate()), so a motorised tail would not move; and the live write carries the whole
-- MIXER_CONFIG record, so an unsaved Tail Mode would reach the board's RAM without the restart a
-- mode change needs.
local function canStartOverride()
  local read = ui.apiData.MIXER_CONFIG
  return M.canSave() and type(read) == "table" and read.tail_rotor_mode == 0
    and ui.config.tail_rotor_mode == 0 and not ui.dirty
end

-- One live write: the record read, with the trim on screen. The board applies it at once
-- (mixerInitConfig() ends the firmware's MSP_SET_MIXER_CONFIG handler) and keeps it in RAM only
-- until Save writes it to EEPROM.
local function sendLive(values)
  local queue = getQueue()
  if not queue or not MixerConfigApi then return false end
  if type(queue.isProcessed) == "function" and not queue:isProcessed() then return false end
  local read = ui.apiData.MIXER_CONFIG
  if not M.canSave() or type(read) ~= "table" then return false end
  local record = copyRecord(read)
  record.tail_center_trim = values.tail_center_trim
  local override = ui.override
  queue:add({
    command = MixerConfigApi.writeCommand,
    payload = MixerConfigApi.buildWritePayload(record),
    isWrite = true,
    processReply = function() end,
    errorHandler = function(_, reason) if override then override:writeFailed(reason) end end
  })
  return true
end

--- Leaving without Save, or Reload: a trim sent live goes back to the board's record, on screen and
--- in the session copy. The payload is built here, not in a reply, because onClose drops this
--- page's modules right after.
local function rollbackLiveChanges()
  if not ui.override or not MixerConfigApi then return false end
  local queue = getQueue()
  if not queue then return false end
  local orig = ui.override:rollback(function(record)
    queue:add({
      command = MixerConfigApi.writeCommand,
      payload = MixerConfigApi.buildWritePayload(record),
      isWrite = true,
      processReply = function() end
    })
    return true
  end)
  if not orig then return false end
  ui.apiData.MIXER_CONFIG = copyRecord(orig.record)
  ui.config.tail_center_trim = orig.values.tail_center_trim
  saveToSession()
  return true
end

local function queueTailRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not MspRuntime or not MixerConfigApi or not MixerInputYawApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  ui.runtime.readPending = true
  if not isAutoReload then
    ui.loading = true
    ui.progress = 0
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  -- Step 1: Read MIXER_CONFIG
  queue:add({
    command = MixerConfigApi.command,
    simulatorResponse = MixerConfigApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = MixerConfigApi.parse(buf)
      if type(parsed) ~= "table" then return Common.failPageRead(ui) end
      if parsed then
        ui.apiData.MIXER_CONFIG = parsed
        ui.config.tail_rotor_mode = parsed.tail_rotor_mode or 0
        ui.config.tail_motor_idle = parsed.tail_motor_idle or 0
        ui.config.tail_center_trim = parsed.tail_center_trim or 0
      end

      ui.progress = 50
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end

      -- Step 2: Read GET_MIXER_INPUT_YAW
      queue:add({
        command = MixerInputYawApi.command,
        payload = { 3 },
        simulatorResponse = MixerInputYawApi.simulatorResponse,
        processReply = function(self, buf)
          local parsed = MixerInputYawApi.parse(buf)
          if type(parsed) ~= "table" then return Common.failPageRead(ui) end
          if parsed then
            ui.apiData.GET_MIXER_INPUT_YAW = parsed
            ui.config.yaw_direction = rateToDir(parsed.rate_stabilized_yaw or 0)
            local y_cal = u16_to_s16(parsed.rate_stabilized_yaw or 0)
            ui.config.yaw_calibration = math.abs(y_cal)

            ui.config.yaw_cw_limit = math.abs(u16_to_s16(parsed.min_stabilized_yaw or 0))
            ui.config.yaw_ccw_limit = math.abs(u16_to_s16(parsed.max_stabilized_yaw or 0))
          end

          saveToSession()

          -- What the board holds as of this read: leaving without Save puts it back.
          if ui.override then ui.override:snapshot(ui.apiData.MIXER_CONFIG, trimValues()) end

          ui.runtime.readPending = false
          ui.runtime.readComplete = true
          ui.loading = false
          ui.dirty = false
          ui.progress = 100
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end,
        errorHandler = function()
          ui.runtime.readPending = false
          ui.loading = false
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end
      })
    end,
    errorHandler = function()
      ui.runtime.readPending = false
      ui.loading = false
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })

  return true, nil
end

local function queueTailWrite()
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or not MixerConfigApi or not MixerInputYawApi then
    return false, "msp_runtime_unavailable"
  end

  local pConfig = ui.apiData.MIXER_CONFIG
  local pYaw = ui.apiData.GET_MIXER_INPUT_YAW

  if not M.canSave() or not pConfig or not pYaw then
    return false, "loaded_data_missing"
  end

  -- Whether this save has to restart the flight controller is decided here, from the difference
  -- between what was read and what is about to be written. A module-level flag set when the
  -- control changed stood here instead, and it was only ever cleared on the success path: a chain
  -- that died earlier left it set, so the next save on this page restarted the board although the
  -- tail mode had not been touched.
  local tailModeChanged = pConfig.tail_rotor_mode ~= ui.config.tail_rotor_mode

  -- The save is built on copies, and the records read stay as read until it is done. Written into
  -- in place, a save that was refused or failed after MSP_SET_MIXER_CONFIG left the new tail mode
  -- in the read record, so the next Save compared the new mode with itself and did not restart
  -- the board, although only a restart applies it.
  local writeConfig = copyRecord(pConfig)
  local writeYaw = copyRecord(pYaw)

  writeConfig.tail_rotor_mode = ui.config.tail_rotor_mode
  writeConfig.tail_center_trim = ui.config.tail_center_trim or 0
  if ui.config.tail_rotor_mode >= 1 then
    writeConfig.tail_motor_idle = ui.config.tail_motor_idle
  end

  local yawRate = ui.config.yaw_calibration or 400
  writeYaw.rate_stabilized_yaw = s16_to_u16(yawRate * dirSign(ui.config.yaw_direction))
  writeYaw.min_stabilized_yaw = s16_to_u16(-math.abs(ui.config.yaw_cw_limit or 0))
  writeYaw.max_stabilized_yaw = s16_to_u16(math.abs(ui.config.yaw_ccw_limit or 0))

  local values = trimValues()
  local override = ui.override

  local ok, reason = SavePipeline.start({
    pageId = "setup_mixer_tail",
    steps = {
      {
        label = "MSP_SET_MIXER_CONFIG",
        command = MixerConfigApi.writeCommand,
        payload = MixerConfigApi.buildWritePayload(writeConfig)
      },
      {
        label = "MSP_SET_MIXER_INPUT_YAW",
        command = MixerInputYawApi.writeCommand,
        payload = MixerInputYawApi.buildWritePayload(writeYaw)
      }
    },
    reboot = tailModeChanged,
    -- The Trims page shows the same centre trim from its own copy.
    invalidateSessionKeys = { "setup_mixer_tail", "setup_mixer_trims" },
    onSaved = function()
      ui.dirty = false
      -- Stored: from now on this is what leaving without Save puts back.
      if override then override:stored(writeConfig, values) end
    end,
    onDone = function(result)
      if result.status == "done" then
        -- The board holds what was written, and the next save is compared with that.
        ui.apiData.MIXER_CONFIG = writeConfig
        ui.apiData.GET_MIXER_INPUT_YAW = writeYaw
      else
        ui.dirty = true
      end
      if ui.runtime and type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })
  -- The save sends what is on screen, so the live loop has nothing to send until it changes.
  if ok and override then override:markSent(values) end
  return ok, reason
end

local function buildSessionSignature()
  return "1"
end

local function getBaseTitle()
  return pageText(nil, "tail", "Tail Setup")
end

local function ensureLoaded()
  if ui.loaded then return end
  -- A save whose overlay was dismissed finished without a screen. Its outcome was held back
  -- rather than raised over whatever page the user went to; claim it now that this one is open.
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if SavePipeline and type(SavePipeline.takeResult) == "function" then
    SavePipeline.takeResult("setup_mixer_tail")
  end
  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()
  ui.baseTitle = getBaseTitle()
  queueTailRead(false)
end

function M.wakeup(ctx)
  ensureDeps()
  ensureLoaded()
  if type(ctx) == "table" and type(ctx.requestRebuild) == "function" then
    ui.runtime.requestRebuild = ctx.requestRebuild
  end

  local signature = buildSessionSignature()
  if signature ~= ui.runtime.lastSessionSignature then
    ui.runtime.lastSessionSignature = signature
    queueTailRead(false)
  end

  if overrideActive() and ui.dirty then
    ui.override:tick(trimValues(), sendLive)
  end
end

function M.getHeaderActions()
  return {
    save = true,
    reload = true,
    -- Offered for a variable-pitch tail with nothing else edited (canStartOverride above);
    -- switching it off is always offered.
    star = overrideActive() or canStartOverride(),
    help = true,
    menu = true
  }
end

-- The page is kept between visits and loadFromSession() puts the last records read back into
-- ui.apiData before this visit's read is even queued, so "the records are there" says nothing
-- about this visit. ui.runtime is dropped by resetPageState() on close, which makes this flag
-- the visit's own: set only when every read of the chain parsed, cleared when a read starts.
function M.canSave()
  return ui.runtime ~= nil and ui.runtime.readComplete == true and not ui.runtime.readPending
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
      title = pageText(i18n, "loading_title", "Loading"),
      message = pageText(i18n, "loading_tail", "Reading tail configuration..."),
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or getBaseTitle()
  -- While the override holds the tail, the page shows the trim and nothing else: the rest stays as
  -- read, so the live write -- the whole record -- changes nothing but the trim. The other rows are
  -- left out rather than drawn disabled: after the rebuild the focus lands on the first control, and
  -- a disabled one there holds EXIT, so the page could not be left until the rotary was turned.
  local locked = overrideActive()
  if locked then
    displayTitle = displayTitle .. " *"
  end
  -- The header reads its actions when the page is built. The first edit takes the * away, so the
  -- page is built once more when that happens rather than leaving a * that would do nothing.
  ui.runtime.starOffered = canStartOverride()
  local function afterEdit()
    if ui.runtime and ui.runtime.starOffered and not canStartOverride()
        and type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  if type(ui.runtime) == "table" and type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(displayTitle, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, displayTitle)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  cursorY = cursorY + 10

  if not locked then
    -- 1) Tail Mode
    local tailModeChoices = {
      { value = 0, label = pageText(i18n, "tbl_tail_variable_pitch", "Variable Pitch") },
      { value = 1, label = pageText(i18n, "tbl_tail_motororized_tail", "Motorized Tail") },
      { value = 2, label = pageText(i18n, "tbl_tail_bidirectional", "Bidirectional Motor") }
    }
    cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
      pageText(i18n, "tail_rotor_mode", "Tail Mode"),
      tailModeChoices,
      ui.config.tail_rotor_mode,
      function(newVal)
        if ui.config.tail_rotor_mode ~= newVal then
          ui.config.tail_rotor_mode = newVal
          -- A tail mode change starts Yaw Calibration from the value that mode is set up with, as
          -- the Rotorflight Configurator does on the same change: 100 % for a motorised or
          -- bidirectional tail, 25 % for variable pitch. The direction is kept.
          ui.config.yaw_calibration = (newVal >= 1) and 1000 or 250
          ui.dirty = true
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end
      end,
      { helpText = pageText(i18n, "help_tail_rotor_mode",
          "A tail servo (Servo 4), a tail motor (Motor 2) or a reversible tail motor; changing it restarts the flight controller on Save.") }
    )

    -- 2) Yaw Direction
    local dirChoices = {
      { value = 0, label = pageText(i18n, "tbl_reversed", "Reversed") },
      { value = 1, label = pageText(i18n, "tbl_normal", "Normal") }
    }
    cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
      pageText(i18n, "yaw_direction", "Yaw Direction"),
      dirChoices,
      ui.config.yaw_direction,
      function(newVal)
        if ui.config.yaw_direction ~= newVal then
          ui.config.yaw_direction = newVal
          ui.dirty = true
          afterEdit()
        end
      end,
      { helpText = pageText(i18n, "help_yaw_direction",
          "Reverse it when the tail moves the wrong way for a yaw input; it depends on the tail rotor direction and the servo or ESC setup.") }
    )

  end

  local isMotor = isTailMotorizedMode()

  -- 3) Tail Center Offset (Motor) / Yaw Center Trim (Servo)
  local trimLabel = isMotor and pageText(i18n, "tail_center_offset", "Tail center offset")
                            or pageText(i18n, "yaw_center_trim", "Yaw Center Trim")
  local trimMin = isMotor and -500 or -250
  local trimMax = isMotor and 500 or 250
  local trimSuffix = isMotor and "%" or "°"
  local trimHelp = isMotor
    and pageText(i18n, "help_tail_center_offset", "Tail motor throttle at zero yaw command.")
    or pageText(i18n, "help_yaw_center_trim",
      "Tail blade pitch at zero yaw command. With * on, the tail moves to it about half a second after the last change; Save stores it.")
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    trimLabel,
    {
      min = trimMin,
      max = trimMax,
      step = 1,
      get = function() return rawToField(ui.config.tail_center_trim) end,
      set = function(val)
        if rawToField(ui.config.tail_center_trim) ~= val then
          ui.config.tail_center_trim = fieldToRaw(val)
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f", (tonumber(v) or 0) / 10) .. trimSuffix end,
      suffix = trimSuffix,
      edited = afterEdit,
      helpText = trimHelp
    }
  )
  if locked then return end

  -- 4) Yaw Calibration
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "yaw_calibration", "Yaw Calibration"),
    {
      min = 200,
      max = 2000,
      step = 1,
      get = function() return ui.config.yaw_calibration or 400 end,
      set = function(val)
        if ui.config.yaw_calibration ~= val then
          ui.config.yaw_calibration = val
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f%%", (tonumber(v) or 0) / 10) end,
      suffix = "%",
      edited = afterEdit,
      helpText = pageText(i18n, "help_yaw_calibration",
        "Yaw gain matched to the tail mechanics; usually 50-150% for a servo tail, and quite different for a motorised tail.")
    }
  )

  -- 5) Yaw CW Limit
  local limitSuffix = isMotor and "%" or "°"
  local limitMax = isMotor and 2000 or 600
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "yaw_cw_limit", "Yaw CW Limit"),
    {
      min = 0,
      max = limitMax,
      step = 1,
      get = function() return rawToField(ui.config.yaw_cw_limit) end,
      set = function(val)
        if rawToField(ui.config.yaw_cw_limit) ~= val then
          ui.config.yaw_cw_limit = fieldToRaw(val)
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f", (tonumber(v) or 0) / 10) .. limitSuffix end,
      suffix = limitSuffix,
      edited = afterEdit,
      helpText = pageText(i18n, "help_yaw_cw_limit",
        "Limit for clockwise yaw: a blade angle on a servo tail, a throttle on a motorised tail.")
    }
  )

  -- 6) Yaw CCW Limit
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "yaw_ccw_limit", "Yaw CCW Limit"),
    {
      min = 0,
      max = limitMax,
      step = 1,
      get = function() return rawToField(ui.config.yaw_ccw_limit) end,
      set = function(val)
        if rawToField(ui.config.yaw_ccw_limit) ~= val then
          ui.config.yaw_ccw_limit = fieldToRaw(val)
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f", (tonumber(v) or 0) / 10) .. limitSuffix end,
      suffix = limitSuffix,
      edited = afterEdit,
      helpText = pageText(i18n, "help_yaw_ccw_limit",
        "Limit for counter-clockwise yaw: a blade angle on a servo tail, a throttle on a motorised tail.")
    }
  )

  -- 7) Tail Motor Idle (Motor mode only)
  if isMotor then
    cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
      pageText(i18n, "tail_motor_idle", "Tail Motor Idle"),
      {
        min = 0,
        max = 250,
        step = 1,
        get = function() return ui.config.tail_motor_idle or 0 end,
        set = function(val)
          if ui.config.tail_motor_idle ~= val then
            ui.config.tail_motor_idle = val
            ui.dirty = true
          end
        end,
        display = function(v) return string.format("%.1f%%", (tonumber(v) or 0) / 10) end,
        suffix = "%",
        edited = afterEdit,
        helpText = pageText(i18n, "help_tail_motor_idle",
          "Lowest throttle sent to the tail motor; set it just high enough that the motor does not stop.")
      }
    )
  end
end

function M.onSave(ctx)
  local ok, err = queueTailWrite()
  if not ok then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        title = pageText(ctx and ctx.i18n, "save_error_title", "Error"),
        message = tostring(err or "MSP write failed")
      })
    end
    return false
  end

  -- Nothing is announced here. This function has only QUEUED the save: the writes, the commit
  -- and -- on this page -- the restart are all still ahead of it, and a dialog saying the
  -- settings are saved would be a claim it cannot make. It was also drawn on TOP of the
  -- overlay that reports the save, from a place where that overlay could not be repainted away
  -- first, and while a native dialog stands the tool's run() does not run at all. The pipeline
  -- reports the outcome in the overlay, once, when it knows it.
  return true
end

function M.onReload(ctx)
  local session = getSession()
  if session then
    -- Before the read, so the read is queued behind the rollback and shows the board's value.
    if ui.dirty and not saveWriting() then rollbackLiveChanges() end
    loadFromSession()
    ui.dirty = false
    queueTailRead(false)
  end
  return true
end

function M.onStar(ctx)
  local switchingOn = not overrideActive()
  if switchingOn and not canStartOverride() then return false end
  if not ensureOverride() then return false end

  local i18n = ctx and ctx.i18n
  local title
  local message
  if switchingOn then
    title = pageText(i18n, "enable_tail_override", "Enable tail override")
    message = pageText(i18n, "enable_tail_override_message",
      "The flight controller holds the yaw input at centre while the trim is set. Changes are sent live; Save stores them.\n\nOnly the trim is shown while it is on.")
  else
    title = pageText(i18n, "disable_tail_override", "Disable tail override")
    message = pageText(i18n, "disable_tail_override_message", "Return the yaw input to the flight controller.")
  end

  ui.override:confirm({
    title = title,
    message = message,
    uncertainText = pageText(i18n, "override_armed_unknown",
      "The flight controller does not report whether it is armed. Make sure the rotors cannot spin."),
    onConfirm = function()
      local override = ui.override
      if not override then return end
      if not override.active then
        -- Checked again: Yes comes later than the press, and the page may have changed since.
        if not canStartOverride() then return end
        override:enable(getQueue())
      else
        override:disable(getQueue())
      end
      if ui.runtime and type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })
  return true
end

function M.onClose()
  -- An unsaved trim sent live is taken back first, while the override still holds the tail.
  -- Queued ahead of the override write on purpose: should the close end before every write is
  -- out, a lost override write leaves a board that refuses to arm, a lost rollback a trial trim
  -- the model would fly with. A save still writing is not undone here (saveWriting above).
  if ui.dirty and not saveWriting() then rollbackLiveChanges() end
  if overrideActive() then
    ui.override:disable(getQueue())
  end
  ui.override = nil
  if Common and type(Common.resetPageState) == "function" then
    Common.resetPageState(ui, {
      resetLoaded = true,
      resetDirty = true
    })
  end
  Controls = nil
  Common = nil
  MspRuntime = nil
  MixerConfigApi = nil
  MixerInputYawApi = nil
  LoadingOverlay = nil
  LiveOverride = nil
  t = nil
end

-- Asked before the page is left (ui/home.lua): true while an edit here is not saved.
function M.hasUnsavedChanges()
  return ui.dirty == true
end

return M
