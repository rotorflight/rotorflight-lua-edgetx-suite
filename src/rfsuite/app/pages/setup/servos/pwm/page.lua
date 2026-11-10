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
local LoadingOverlay = nil
local LiveOverride = nil
local ApiVersion = nil
local SavePipeline = nil
local t = nil

-- Reached through the global lib/log.lua publishes; absent logger, absent lines.
local function logf(level, fmt, ...)
  local Log = type(_G) == "table" and _G.rfsuite and _G.rfsuite.Log
  if type(Log) == "table" and type(Log.emitf) == "function" then
    pcall(Log.emitf, "rfsuite.servos.pwm", level, fmt, ...)
  end
end

local MSP_SET_SERVO_OVERRIDE_ALL = 196
local MSP_SET_SERVO_CENTER = 213
-- 0 holds every servo at its centre; 2001 hands them back to the flight controller.
local SERVO_OVERRIDE_CENTER = 0
local SERVO_OVERRIDE_OFF = 2001
-- A changed centre is sent at most every 200 ms while the override is on.
local LIVE_INTERVAL = 0.20

local function writeU8(payload, val)
  payload[#payload + 1] = val % 256
end

local function writeU16(payload, val)
  payload[#payload + 1] = val % 256
  payload[#payload + 1] = math.floor(val / 256) % 256
end

local function writeS16(payload, val)
  local unsigned = val
  if val < 0 then unsigned = val + 65536 end
  writeU16(payload, unsigned)
end

local ui = {
  loaded = false,
  dirty = false,
  loading = false,
  progress = 0,
  baseTitle = nil,
  -- The override, from app/pages/lib/live_override.lua, created the first time * is pressed in a
  -- visit. It holds the centre the board has for one servo, `overrideServo` (a raw index), and what
  -- went out live for it: the override holds every servo, but the selector is locked while it is
  -- on, so only the selected servo's centre is ever sent. A visit that never presses * never loads it.
  override = nil,
  overrideServo = nil,
  selectedServoIndex = 0, -- 0-indexed for editing, defaults to 0
  originalServos = nil,
  config = {
    servos = {}
  },
  mixerConfig = {
    swash_type = 0,
    tail_rotor_mode = 0
  },
  servoBusEnabled = false,
  servoCount = 0,
  servoLoaded = {},
  apiData = {},
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
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ApiVersion then ApiVersion = loadModule("lib/api_version.lua") end
  if not t then t = Common and Common.pageT("setup_servos") or nil end

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

-- The loading bar reads this on the firmware's own refresh pass, so each reply of the load
-- moves it without a rebuild of the scene.
local function loadingProgress()
  return (tonumber(ui.progress) or 0) / 100
end

local function getRcConfig(session)
  if type(session) ~= "table" then return nil end
  if type(session.setup_servos_pwm) ~= "table" then
    session.setup_servos_pwm = {}
  end
  return session.setup_servos_pwm
end

--- Snapshot one servo's values, once per visit, so a cancel can put them back. Per servo rather
--- than per table, because the paged read brings them one at a time. The snapshot is what the
--- board holds: it is dropped when a read starts and renewed when a save has completed.
local function backupOriginalServo(i)
  local s = ui.config.servos and ui.config.servos[i]
  if not s then return end
  ui.originalServos = ui.originalServos or {}
  if ui.originalServos[i] ~= nil then return end
  ui.originalServos[i] = {
    mid = s.mid,
    min = s.min,
    max = s.max,
    scaleNeg = s.scaleNeg,
    scalePos = s.scalePos,
    rate = s.rate,
    speed = s.speed,
    flags = s.flags,
    reverse = s.reverse,
    geometry = s.geometry
  }
end

--- After a completed save the board holds the saved values, so a later cancel puts those back.
local function renewOriginalServo(i)
  if ui.originalServos then ui.originalServos[i] = nil end
  backupOriginalServo(i)
end

local function loadFromSession()
  local session = getSession()
  local rcConfig = getRcConfig(session)
  if not rcConfig then return end

  ui.servoCount = rcConfig.servoCount or 0
  ui.servoLoaded = ui.servoLoaded or {}
  ui.servoBusEnabled = rcConfig.servoBusEnabled or false
  ui.mixerConfig.swash_type = rcConfig.swash_type or 0
  ui.mixerConfig.tail_rotor_mode = rcConfig.tail_rotor_mode or 0

  if type(rcConfig.servos) == "table" then
    ui.config.servos = rcConfig.servos
  end
  if type(rcConfig.apiData) == "table" then
    ui.apiData = rcConfig.apiData
  end
end

local function saveToSession()
  local session = getSession()
  local rcConfig = getRcConfig(session)
  if not rcConfig then return end

  rcConfig.servoCount = ui.servoCount
  rcConfig.servoBusEnabled = ui.servoBusEnabled
  rcConfig.swash_type = ui.mixerConfig.swash_type
  rcConfig.tail_rotor_mode = ui.mixerConfig.tail_rotor_mode
  rcConfig.servos = ui.config.servos
  rcConfig.apiData = ui.apiData
end

local function getServoTitle(i18n, idx)
  local swashType = ui.mixerConfig.swash_type or 0
  local tailMode = ui.mixerConfig.tail_rotor_mode or 0

  if swashType == 1 then -- DIRECT
    if tailMode == 0 and idx == 4 then
      return pageText(i18n, "tail", "TAIL")
    end
  elseif swashType >= 2 and swashType <= 4 then -- CPPM
    if idx == 1 then return pageText(i18n, "cyc_pitch", "CYC.PITCH") end
    if idx == 2 then return pageText(i18n, "cyc_left", "CYC.LEFT") end
    if idx == 3 then return pageText(i18n, "cyc_right", "CYC.RIGHT") end
    if tailMode == 0 and idx == 4 then
      return pageText(i18n, "tail", "TAIL")
    end
  elseif swashType == 5 or swashType == 6 then -- FPPM
    if tailMode == 0 and idx == 4 then
      return pageText(i18n, "tail", "TAIL")
    end
  end

  return pageText(i18n, "servo", "Servo") .. " " .. idx
end

local function getQueue()
  if not MspRuntime or type(MspRuntime.getState) ~= "function" then return nil end
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then return nil end
  return queue
end

local function overrideActive()
  return ui.override ~= nil and ui.override.active == true
end

-- MSP_SET_SERVO_CENTER takes the RAW servoParams index and the centre alone (API 12.09, the oldest
-- the suite connects to), so it changes nothing else of the servo's record.
local function queueCentre(queue, raw, mid, errorHandler)
  mid = math.floor(tonumber(mid) or 1500)
  queue:add({
    command = MSP_SET_SERVO_CENTER,
    payload = { raw, mid % 256, math.floor(mid / 256) % 256 },
    isWrite = true,
    processReply = function() end,
    errorHandler = errorHandler
  })
end

-- The override's record is one servo's centre as the board holds it: the snapshot of the selected
-- servo. Taken again whenever the selected servo is another one than the record is about, which
-- can only happen with nothing unsaved (the selector asks first) and the override off (the
-- selector is locked while it is on).
local function syncOverrideServo()
  if not ui.override then return false end
  local raw = ui.selectedServoIndex
  if ui.overrideServo == raw then return true end
  local orig = ui.originalServos and ui.originalServos[raw]
  if not orig then return false end
  ui.override:snapshot({ raw = raw, mid = orig.mid }, { mid = orig.mid })
  ui.overrideServo = raw
  logf("debug", "override follows servo %s", tostring(raw))
  return true
end

-- One live write of the selected servo's centre. The acknowledgement leaves the page dirty: the
-- centre is in the board's RAM only, and it stays a trial until Save writes it to EEPROM.
local function sendLive(values)
  local queue = getQueue()
  if not queue or not ui.overrideServo then return false end
  if type(queue.isProcessed) == "function" and not queue:isProcessed() then return false end
  local override = ui.override
  queueCentre(queue, ui.overrideServo, values.mid, function(_, reason)
    if override then override:writeFailed(reason) end
  end)
  return true
end

-- Reused for every live pass, so the loop allocates nothing while nothing changes.
local liveValues = {}
local function selectedCentre()
  local s = ui.config.servos and ui.config.servos[ui.selectedServoIndex]
  liveValues.mid = s and math.floor(tonumber(s.mid) or 1500) or nil
  return liveValues
end

--- Puts servo `raw`'s snapshot back on the screen and in the session copy, and, where a centre
--- went out live for it since the board's record was taken, sends that record's centre back.
--- Returns whether anything was put back.
local function rollbackServo(raw)
  local orig = ui.originalServos and ui.originalServos[raw]
  local current = ui.config.servos and ui.config.servos[raw]
  if not orig or not current then return false end
  local changed = false
  for k, v in pairs(orig) do
    if current[k] ~= v then
      current[k] = v
      changed = true
    end
  end
  if ui.override and ui.overrideServo == raw then
    local queue = getQueue()
    local sent = queue and ui.override:rollback(function(record)
      queueCentre(queue, record.raw, record.mid)
      return true
    end)
    if sent then changed = true end
  end
  return changed
end

local function rollbackChanges()
  if not ui.originalServos then return end
  local changed = false
  for raw in pairs(ui.originalServos) do
    if rollbackServo(raw) then changed = true end
  end
  if changed then saveToSession() end
end

-- Whether leaving or Reload may put back what is unsaved: not while a save is still writing, whose
-- steps a rollback would land between. Without an override in this visit nothing went out live.
local function rollbackDue()
  if not ui.dirty then return false end
  return not (ui.override ~= nil and LiveOverride ~= nil and LiveOverride.saveWriting())
end

local function ensureOverride()
  if ui.override then return ui.override end
  if not LiveOverride then LiveOverride = loadModule("app/pages/lib/live_override.lua") end
  if not LiveOverride then return nil end
  ui.override = LiveOverride.new({
    command = MSP_SET_SERVO_OVERRIDE_ALL,
    on = SERVO_OVERRIDE_CENTER,
    off = SERVO_OVERRIDE_OFF,
    cadence = "periodic",
    interval = LIVE_INTERVAL
  })
  ui.overrideServo = nil
  syncOverrideServo()
  return ui.override
end

--- Discard on the unsaved-changes question put before another servo is picked: servo `i` goes
--- back to what the board holds, which is its snapshot.
local function discardServo(i)
  if rollbackServo(i) then saveToSession() end
  ui.dirty = false
end

--- Whether this firmware has the per-servo read.
---
--- MSP_GET_SERVO_CONFIG (125) and MSP_GET_BUS_SERVO_CONFIG (157) arrived in API 12.09. Below it
--- the whole-table MSP_SERVO_CONFIGURATIONS is the only read there is.
local PAGED_READ_API = {12, 0, 9}

local function hasPagedServoReads()
  local session = getSession()
  local apiVersion = session and session.apiVersion
  if not apiVersion or apiVersion == "" or tostring(apiVersion) == "0" then
    return false
  end
  return ApiVersion and ApiVersion.isAtLeast and ApiVersion.isAtLeast(apiVersion, PAGED_READ_API)
end

--- Reads one servo's record with MSP_GET_SERVO_CONFIG (125), by RAW servoParams index.
---
--- The whole-table MSP_SERVO_CONFIGURATIONS is not used from API 12.09. With bus servos
--- configured its reply is 1 + (getServoCount() + BUS_SERVO_CHANNELS) * 16 bytes -- 353 with four
--- PWM servos, 417 with eight -- while the shared telemetry response buffer the CRSF path
--- serialises into is MSP_TLM_OUTBUF_SIZE = 320 bytes and sbufWriteU8 has no bound check, so the
--- reply is written past the end of a static buffer. Over USB that buffer is much larger and the
--- command is safe there, which is why this is not visible from the configurator.
local function queueServoRead(servoIdx, onDone)
  local function done(ok)
    if type(onDone) == "function" then onDone(ok) end
  end

  if not hasPagedServoReads() then
    done(false)
    return false
  end

  servoIdx = tonumber(servoIdx)
  if not servoIdx or servoIdx < 0 then
    done(false)
    return false
  end

  if not MspRuntime or type(MspRuntime.getState) ~= "function" then
    done(false)
    return false
  end
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    done(false)
    return false
  end

  local GetServoConfigApi = loadModule("tasks/msp/api/get_servo_config.lua")
  if not GetServoConfigApi then
    done(false)
    return false
  end

  local raw = servoIdx

  queue:add({
    command = GetServoConfigApi.command,
    payload = { raw },
    isWrite = false,
    simulatorResponse = GetServoConfigApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = GetServoConfigApi.parse(buf)
      local rec = parsed and parsed.servo_config
      if rec then
        local s = {
          mid = rec.mid,
          min = rec.min,
          max = rec.max,
          scaleNeg = rec.rneg,
          scalePos = rec.rpos,
          rate = rec.rate,
          speed = rec.speed,
          flags = rec.flags
        }
        s.reverse = (s.flags == 1 or s.flags == 3) and 1 or 0
        s.geometry = (s.flags == 2 or s.flags == 3) and 1 or 0
        ui.config.servos = ui.config.servos or {}
        ui.config.servos[raw] = s
        ui.servoLoaded[raw] = true
        backupOriginalServo(raw)
      end
      done(rec ~= nil)
    end,
    errorHandler = function()
      done(false)
    end
  })

  return true
end

--- What the whole-table read used to do at the end of a load, for one servo instead of all.
local function finishServoLoad(ok)
  ui.runtime.readComplete = ok == true
  ui.runtime.readPending = false
  ui.loading = false
  ui.dirty = false
  ui.progress = 100
  ui.loaded = true
  saveToSession()
  if type(ui.runtime.requestRebuild) == "function" then
    ui.runtime.requestRebuild()
  end
end

local function queueServosRead(isAutoReload)
  -- Only what this read brings counts as read, and that holds from here on even when no read
  -- can be queued: the records an earlier visit left in the session copy are still shown while
  -- it runs, but they are neither drawn as editable nor saved, nor what a cancel puts back.
  ui.runtime.readComplete = false
  ui.servoLoaded = {}
  ui.originalServos = nil
  -- The override takes its record again from what this read brings.
  ui.overrideServo = nil
  if ui.runtime.readPending then return false, "read_pending" end
  if not MspRuntime or type(MspRuntime.getState) ~= "function" then
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

  -- A reply the parser rejects does not stop the chain, but it leaves the read incomplete.
  local chainOk = true

  local MixerConfigApi = loadModule("tasks/msp/api/mixer_config.lua")
  local StatusApi = loadModule("tasks/msp/api/status.lua")
  local SerialConfigApi = loadModule("tasks/msp/api/serial_config.lua")
  local ServoConfigsApi = loadModule("tasks/msp/api/servo_configurations.lua")

  -- Step 1: Read MIXER_CONFIG
  queue:add({
    command = MixerConfigApi.command,
    simulatorResponse = MixerConfigApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = MixerConfigApi.parse(buf)
      if parsed then
        ui.mixerConfig.swash_type = parsed.swash_type or 0
        ui.mixerConfig.tail_rotor_mode = parsed.tail_rotor_mode or 0
      else
        chainOk = false
      end

      ui.progress = 25

      -- Step 2: Read STATUS
      queue:add({
        command = StatusApi.command,
        simulatorResponse = StatusApi.simulatorResponse,
        processReply = function(self, buf)
          local parsed = StatusApi.parse(buf)
          if parsed then
            ui.servoCount = parsed.servo_count or 0
          else
            chainOk = false
          end

          ui.progress = 50

          -- Step 3: Read SERIAL_CONFIG
          queue:add({
            command = SerialConfigApi.command,
            simulatorResponse = SerialConfigApi.simulatorResponse,
            processReply = function(self, buf)
              local parsed = SerialConfigApi.parse(buf)
              if parsed then
                local fbus_mask = 524288
                local sbus_mask = 262144
                local found = false
                for i = 1, 12 do
                  local mask = parsed["port_" .. i .. "_function_mask"]
                  if mask == fbus_mask or mask == sbus_mask then
                    found = true
                    break
                  end
                end
                ui.servoBusEnabled = found
              else
                chainOk = false
              end

              ui.progress = 75

              -- Step 4: the selected servo's own record, where the firmware has that read
              if hasPagedServoReads() then
                if not queueServoRead(ui.selectedServoIndex, function(ok)
                  finishServoLoad(ok and chainOk)
                end) then
                  finishServoLoad(false)
                end
                return
              end

              -- Step 4: Read SERVO_CONFIGURATIONS
              queue:add({
                command = ServoConfigsApi.command,
                simulatorResponse = ServoConfigsApi.simulatorResponse,
                processReply = function(self, buf)
                  local parsed = ServoConfigsApi.parse(buf)
                  if parsed then
                    ui.config.servos = {}
                    local count = parsed.servo_count or 0
                    for i = 0, count - 1 do
                      local s = {}
                      s.mid = parsed["servo_" .. (i + 1) .. "_mid"] or 1500
                      s.min = parsed["servo_" .. (i + 1) .. "_min"] or 0
                      s.max = parsed["servo_" .. (i + 1) .. "_max"] or 0
                      s.scaleNeg = parsed["servo_" .. (i + 1) .. "_rneg"] or 500
                      s.scalePos = parsed["servo_" .. (i + 1) .. "_rpos"] or 500
                      s.rate = parsed["servo_" .. (i + 1) .. "_rate"] or 333
                      s.speed = parsed["servo_" .. (i + 1) .. "_speed"] or 0
                      s.flags = parsed["servo_" .. (i + 1) .. "_flags"] or 0

                      if s.flags == 1 or s.flags == 3 then
                        s.reverse = 1
                      else
                        s.reverse = 0
                      end

                      if s.flags == 2 or s.flags == 3 then
                        s.geometry = 1
                      else
                        s.geometry = 0
                      end

                      ui.config.servos[i] = s
                      ui.servoLoaded[i] = true
                      backupOriginalServo(i)
                    end
                  else
                    chainOk = false
                  end

                  saveToSession()

                  ui.runtime.readComplete = chainOk
                  ui.runtime.readPending = false
                  ui.loading = false
                  ui.dirty = false
                  ui.progress = 100
                  ui.loaded = true
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

--- `onDone(ok)` is told once the write is over: true when the flight controller has taken the
--- record (and the EEPROM write after it), false when either was refused or never answered. It is
--- told only while the page is on the visit the save was started from.
local function queueServoWrite(servoIdx, onDone)
  if not M.canSave() then return false, "read_required" end
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline then
    return false, "msp_runtime_unavailable"
  end

  local config = ui.config.servos and ui.config.servos[servoIdx]
  if not config then return false, "config_unavailable" end

  local mid = math.floor(config.mid or 1500)
  local min = math.floor(config.min or 0)
  local max = math.floor(config.max or 0)
  local scaleNeg = math.floor(config.scaleNeg or 500)
  local scalePos = math.floor(config.scalePos or 500)
  local rate = math.floor(config.rate or 333)
  local speed = math.floor(config.speed or 0)

  local reverse = tonumber(config.reverse) or 0
  local geometry = tonumber(config.geometry) or 0
  local flags = 0
  if reverse == 0 and geometry == 0 then
    flags = 0
  elseif reverse == 1 and geometry == 0 then
    flags = 1
  elseif reverse == 0 and geometry == 1 then
    flags = 2
  elseif reverse == 1 and geometry == 1 then
    flags = 3
  end

  local payload = {}
  writeU8(payload, servoIdx)
  writeU16(payload, mid)
  writeS16(payload, min)
  writeS16(payload, max)
  writeU16(payload, scaleNeg)
  writeU16(payload, scalePos)
  writeU16(payload, rate)
  writeU16(payload, speed)
  writeU16(payload, flags)

  -- The visit this save belongs to. The page's close sets ui.runtime to nil and its next visit
  -- creates a new table, so the hooks below change this visit's state only: on another visit the
  -- snapshot and the session copy are that visit's own, from its own read.
  local visit = ui.runtime

  -- The write and the EEPROM commit belong to the pipeline, not to this page: the page can be
  -- left while they are on the wire, and its close releases ui.runtime. Its notice covers the
  -- page while the save runs, so the page puts up no overlay of its own.
  -- The override's record, when it is this servo's: the save sends what is on screen, so the live
  -- loop has nothing to send until it changes, and until the save is stored its write counts as sent.
  -- An override made for another servo earlier in the visit follows this one first: a servo is
  -- picked only with nothing unsaved, so nothing of the other one is lost by it.
  syncOverrideServo()
  local override = ui.override
  local overrideRaw = ui.overrideServo

  local ok, err = SavePipeline.start({
    pageId = "setup_servos_pwm",
    steps = {
      { label = "MSP_SET_SERVO_CONFIGURATION", command = 212, payload = payload }
    },
    reboot = false,
    onSaved = function()
      if override and overrideRaw == servoIdx then
        override:stored({ raw = servoIdx, mid = mid }, { mid = mid })
      end
      if ui.runtime ~= visit then return end
      ui.dirty = false
      renewOriginalServo(servoIdx)
      saveToSession()
    end,
    onDone = function(result)
      if result.saved ~= true and override and overrideRaw == ui.overrideServo then override:saveFailed() end
      if ui.runtime ~= visit then return end
      if type(onDone) == "function" then onDone(result.saved == true) end
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })
  if ok and override and overrideRaw == servoIdx then override:markSent({ mid = mid }) end
  return ok, err
end

--- Makes servo `val` the one on screen, reading its record first where it has not been read on
--- this visit. Only the paged route leaves a servo unread; the whole-table route brought them all.
local function selectServo(val)
  ui.selectedServoIndex = val
  if hasPagedServoReads() and not ui.servoLoaded[val] then
    ui.loading = true
    queueServoRead(val, function()
      ui.loading = false
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end)
  end
  if type(ui.runtime.requestRebuild) == "function" then
    ui.runtime.requestRebuild()
  end
end

local function ensureLoaded()
  if not ui.loaded and not ui.loading and not ui.runtime.readPending then
    local session = getSession()
    if session then
      loadFromSession()
      queueServosRead(false)
    end
  end
end

function M.wakeup(ctx)
  ensureDeps()
  ensureLoaded()

  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil

  local session = getSession()
  local signature = session and session.signature or nil
  if signature ~= ui.runtime.lastSessionSignature then
    ui.runtime.lastSessionSignature = signature
    ui.loaded = false
    queueServosRead(false)
  end

  if overrideActive() and ui.dirty and M.canSave() and syncOverrideServo() then
    ui.override:tick(selectedCentre(), sendLive)
  end
end

function M.getHeaderActions()
  return {
    save = true,
    reload = true,
    -- Switching the override on waits for this visit's read, as Save does (M.canSave below).
    -- Switching it off is always offered.
    star = overrideActive() or M.canSave(),
    help = true,
    menu = true
  }
end

-- The page is kept between visits and loadFromSession() puts the last servo records back into
-- ui.config.servos before this visit's read is even queued, so "a record is there" says nothing
-- about this visit. readComplete is set only when every reply of this visit's read parsed, and
-- ui.runtime is dropped by resetPageState() on close. servoLoaded is emptied when a read starts,
-- so it says that the selected servo's record came from this visit: picking another servo reads
-- that one outside the chain, and Save writes the selected servo's record.
-- The PWM servos are the head of the packed total MSP_STATUS reports; with bus servos on, the tail
-- is the bus channels (app/pages/setup/servos/bus/page.lua carries the two index spaces). Derived
-- here from the ui fields this visit's read sets, rather than read from a field build() stored,
-- because canSave() is asked between the pass that finishes the read and the rebuild after it,
-- where a stored count is still the previous build's -- and a Save in that window would write
-- index 0, which on a board with no PWM servo is bus servo 1.
local function pwmServoCount()
  local totalServoCount = ui.servoCount or 4
  if totalServoCount < 1 then totalServoCount = 4 end

  local session = getSession()
  local apiVersion = session and session.apiVersion
  local isAtLeast1209 = ApiVersion and ApiVersion.isAtLeast and ApiVersion.isAtLeast(apiVersion, {12, 0, 9})

  if ui.servoBusEnabled == true and isAtLeast1209
    and not (system and system.getVersion and system.getVersion().simulation)
    and totalServoCount >= 18 then
    return totalServoCount - 18
  end
  return totalServoCount
end

function M.canSave()
  -- The header is resolved before the page is built, so on the visit's first ask this has to load
  -- the API-version module itself: pwmServoCount() reads it, and without it the bus channels
  -- would not be subtracted and Save offered on a board with no PWM servo.
  ensureDeps()
  -- With no PWM servo, servo 0 is a bus servo's record: refuse the write rather than send it.
  return pwmServoCount() >= 1
    and ui.runtime ~= nil and ui.runtime.readComplete == true and not ui.runtime.readPending
    and type(ui.servoLoaded) == "table" and ui.servoLoaded[ui.selectedServoIndex] == true
end

function M.build(ctx)
  ensureDeps()
  ensureLoaded()

  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil
  ui.runtime.askUnsavedChanges = ctx and ctx.askUnsavedChanges or nil

  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local h = ctx.h
  local i18n = ctx.i18n

  if ui.loading then
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = "@i18n(app.loading)@",
      message = pageText(i18n, "loading", "Reading servos configuration..."),
      progress = loadingProgress
    })
    return
  end

  -- Determine display title
  local title = pageText(i18n, "pwm", "PWM Output")
  -- While the override is on only Center is a control. The other settings and the servo selector
  -- are drawn as text, not as disabled controls: a disabled control still takes the focus (the
  -- first control does after every rebuild, and the rotary reaches the others), and one holding
  -- the focus keeps EXIT from the tool, so the page could not be left until the rotary was turned.
  local locked = overrideActive()
  if locked then
    title = title .. " *"
  end

  if type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(title, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, title)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  local Palette = _G.rfsuite and _G.rfsuite.palette or loadModule("ui/palette.lua")
  local rowH = Controls.ROW_H or 40
  local valueX = x + math.floor(w * 0.6)
  -- A setting the override holds still: its label and value as text, nothing that takes the focus.
  local function lockedRow(labelText, valueText)
    local labelY = type(Controls.labelY) == "function" and Controls.labelY(cursorY, rowH) or cursorY
    local muted = Palette and Palette.muted or nil
    children[#children + 1] = {
      type = "label", x = x, y = labelY, w = valueX - x - 8,
      text = labelText, color = muted, font = SMLSIZE
    }
    children[#children + 1] = {
      type = "label", x = valueX, y = labelY, w = x + w - valueX - 10,
      text = valueText, color = muted, font = SMLSIZE, align = RIGHT
    }
    children[#children + 1] = {
      type = "rectangle", x = x, y = cursorY + rowH, w = w, h = 1,
      color = Palette and Palette.border or nil, filled = true
    }
    return rowH + 1
  end
  local function yesNo(value)
    if value == 1 then return pageText(i18n, "tbl_yes", "YES") end
    return pageText(i18n, "tbl_no", "NO")
  end

  -- The count is derived the same way canSave() derives it, from this visit's read (pwmServoCount
  -- above), so a Save in the pass before the rebuild is refused on the same number this draws.
  local pwmCount = pwmServoCount()

  -- Build Active Servo Combo Selector Options
  local servoOptions = {}
  for i = 1, pwmCount do
    servoOptions[#servoOptions + 1] = {
      label = getServoTitle(i18n, i),
      value = i - 1
    }
  end

  if ui.selectedServoIndex == nil or ui.selectedServoIndex >= pwmCount then
    ui.selectedServoIndex = 0
  end

  -- 1) Active Servo Dropdown
  if locked then
    cursorY = cursorY + lockedRow(pageText(i18n, "servo", "Servo"), getServoTitle(i18n, ui.selectedServoIndex + 1))
  else
    cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
      pageText(i18n, "servo", "Servo"),
      servoOptions,
      ui.selectedServoIndex,
      function(val)
        if ui.selectedServoIndex == val then return end
        if not ui.dirty then
          selectServo(val)
          return
        end
        -- Save writes the selected servo only, so an edit left on this one would be dropped by
        -- the pick. The host's unsaved-changes question comes first: Save stores this servo and
        -- then picks, Discard puts back what the board holds and then picks, Stay keeps both.
        -- Where it cannot be asked, the pick does not happen and the selector shows this servo.
        -- The answers act only on this visit: ui.runtime is dropped on close and made anew on the
        -- next visit, so a write that completes after the page has gone picks nothing.
        local from = ui.selectedServoIndex
        local visit = ui.runtime
        local asked = type(visit.askUnsavedChanges) == "function" and visit.askUnsavedChanges({
          message = pageText(i18n, "switch_unsaved_msg",
            "This servo has changes that are not saved. Picking another servo discards them."),
          saved = function()
            if ui.runtime == visit and ui.selectedServoIndex == from then selectServo(val) end
          end,
          discard = function()
            if ui.runtime == visit and ui.selectedServoIndex == from then
              discardServo(from)
              selectServo(val)
            end
          end
        })
        if not asked and type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      end,
      {
        helpText = pageText(i18n, "help_servo",
          "The servo output whose settings are shown below.")
      }
    )
  end

  -- Everything below is the selected servo's own record, so it is drawn only once that
  -- record has been read. Editing what an unfinished read left behind would write it back.
  if pwmCount < 1 or not ui.servoLoaded[ui.selectedServoIndex] then return end

  local idx = ui.selectedServoIndex
  local s = ui.config.servos[idx]

  if s then
    -- 2) Center
    cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
      pageText(i18n, "center", "Center"),
      {
        min = 50,
        max = 2250,
        step = 1,
        get = function() return s.mid or 1500 end,
        set = function(val)
          if s.mid ~= val then
            s.mid = val
            ui.dirty = true
          end
        end,
        display = function(v) return tostring(v) .. "us" end,
        suffix = "us",
        helpText = pageText(i18n, "help_center",
          "Centre position in us; the servo arm should be level there. With * on, a change moves the servo at once.")
      }
    )

    -- 3) Minimum
    if locked then
      cursorY = cursorY + lockedRow(pageText(i18n, "minimum", "Minimum"), tostring(s.min or -700) .. "us")
    else
      cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
        pageText(i18n, "minimum", "Minimum"),
        {
          min = -1000,
          max = 1000,
          step = 1,
          get = function() return s.min or -700 end,
          set = function(val)
            if s.min ~= val then
              s.min = val
              ui.dirty = true
            end
          end,
          display = function(v) return tostring(v) .. "us" end,
          suffix = "us",
          helpText = pageText(i18n, "help_minimum",
            "Lowest point of travel; it limits the negative throw so the servo arm does not bind.")
        }
      )
    end

    -- 4) Maximum
    if locked then
      cursorY = cursorY + lockedRow(pageText(i18n, "maximum", "Maximum"), tostring(s.max or 700) .. "us")
    else
      cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
        pageText(i18n, "maximum", "Maximum"),
        {
          min = -1000,
          max = 1000,
          step = 1,
          get = function() return s.max or 700 end,
          set = function(val)
            if s.max ~= val then
              s.max = val
              ui.dirty = true
            end
          end,
          display = function(v) return tostring(v) .. "us" end,
          suffix = "us",
          helpText = pageText(i18n, "help_maximum",
            "Highest point of travel; it limits the positive throw so the servo arm does not bind.")
        }
      )
    end

    -- 5) Scale Negative
    if locked then
      cursorY = cursorY + lockedRow(pageText(i18n, "scale_negative", "Scale Negative"), tostring(s.scaleNeg or 500))
    else
      cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
        pageText(i18n, "scale_negative", "Scale Negative"),
        {
          min = 100,
          max = 1000,
          step = 1,
          get = function() return s.scaleNeg or 500 end,
          set = function(val)
            if s.scaleNeg ~= val then
              s.scaleNeg = val
              ui.dirty = true
            end
          end,
          display = function(v) return tostring(v) end,
          suffix = "",
          helpText = pageText(i18n, "help_scale_negative",
            "Scaling on the negative side; typically 500 for 1520 us servos and 250 for 760 us servos.")
        }
      )
    end

    -- 6) Scale Positive
    if locked then
      cursorY = cursorY + lockedRow(pageText(i18n, "scale_positive", "Scale Positive"), tostring(s.scalePos or 500))
    else
      cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
        pageText(i18n, "scale_positive", "Scale Positive"),
        {
          min = 100,
          max = 1000,
          step = 1,
          get = function() return s.scalePos or 500 end,
          set = function(val)
            if s.scalePos ~= val then
              s.scalePos = val
              ui.dirty = true
            end
          end,
          display = function(v) return tostring(v) end,
          suffix = "",
          helpText = pageText(i18n, "help_scale_positive",
            "Scaling on the positive side; typically 500 for 1520 us servos and 250 for 760 us servos.")
        }
      )
    end

    -- 7) Rate
    if locked then
      cursorY = cursorY + lockedRow(pageText(i18n, "rate", "Rate"), tostring(s.rate or 333) .. "Hz")
    else
      cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
        pageText(i18n, "rate", "Rate"),
        {
          min = 50,
          max = 5000,
          step = 1,
          get = function() return s.rate or 333 end,
          set = function(val)
            if s.rate ~= val then
              s.rate = val
              ui.dirty = true
            end
          end,
          display = function(v) return tostring(v) .. "Hz" end,
          suffix = "Hz",
          helpText = pageText(i18n, "help_rate",
            "PWM update rate; 50 Hz for analog servos, typically 100 to 560 Hz for digital ones. Check the servo's data sheet.")
        }
      )
    end

    -- 8) Speed
    if locked then
      cursorY = cursorY + lockedRow(pageText(i18n, "speed", "Speed"), tostring(s.speed or 0) .. "ms")
    else
      cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
        pageText(i18n, "speed", "Speed"),
        {
          min = 0,
          max = 60000,
          step = 1,
          get = function() return s.speed or 0 end,
          set = function(val)
            if s.speed ~= val then
              s.speed = val
              ui.dirty = true
            end
          end,
          display = function(v) return tostring(v) .. "ms" end,
          suffix = "ms",
          helpText = pageText(i18n, "help_speed",
            "Limits the servo speed: the time in ms for 60 degrees of rotation; 0 means no limit.")
        }
      )
    end

    -- 9) Reverse
    if locked then
      cursorY = cursorY + lockedRow(pageText(i18n, "reverse", "Reverse"), yesNo(s.reverse))
    else
      cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
        pageText(i18n, "reverse", "Reverse"),
        {
          { label = pageText(i18n, "tbl_no", "NO"), value = 0 },
          { label = pageText(i18n, "tbl_yes", "YES"), value = 1 }
        },
        s.reverse or 0,
        function(val)
          if s.reverse ~= val then
            s.reverse = val
            ui.dirty = true
            if type(ui.runtime.requestRebuild) == "function" then
              ui.runtime.requestRebuild()
            end
          end
        end,
        {
          helpText = pageText(i18n, "help_reverse",
            "Reverse the servo when it moves the wrong way.")
        }
      )
    end

    -- 10) Geometry
    if locked then
      cursorY = cursorY + lockedRow(pageText(i18n, "geometry", "Geometry"), yesNo(s.geometry))
    else
      cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
        pageText(i18n, "geometry", "Geometry"),
        {
          { label = pageText(i18n, "tbl_no", "NO"), value = 0 },
          { label = pageText(i18n, "tbl_yes", "YES"), value = 1 }
        },
        s.geometry or 0,
        function(val)
          if s.geometry ~= val then
            s.geometry = val
            ui.dirty = true
            if type(ui.runtime.requestRebuild) == "function" then
              ui.runtime.requestRebuild()
            end
          end
        end,
        {
          helpText = pageText(i18n, "help_geometry",
            "Corrects the rotational geometry at the ends of travel; do not use it with linear servos.")
        }
      )
    end
  end
end

function M.onSave(ctx)
  -- `ctx.onSaved` is the host's: the pilot answered Save to the question put before another servo
  -- was picked, and the pick happens once this servo's record is stored, never before.
  -- onSave clears the unsaved flag when the write is queued; a write that is not stored puts back
  -- what the flag was, so an edit stays unsaved and an unedited servo does not become one.
  local onSaved = ctx and ctx.onSaved
  local hadEdit = ui.dirty
  local ok, err = queueServoWrite(ui.selectedServoIndex, function(stored)
    if not stored then
      if hadEdit then logf("info", "save not stored: the page stays unsaved") end
      ui.dirty = hadEdit
    elseif type(onSaved) == "function" then
      onSaved()
    end
  end)
  if not ok then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        title = pageText(ctx and ctx.i18n, "save_error_title", "Error"),
        message = tostring(err or "MSP write failed")
      })
    end
    return false
  end

  -- The shared save's notice reports how the save ended, once the flight controller has answered.
  ui.dirty = false
  return true
end

function M.onReload(ctx)
  -- The unsaved centre goes back first, while the override still holds the servos, then the
  -- override is switched off, as leaving does.
  if rollbackDue() then rollbackChanges() end
  if overrideActive() then
    ui.override:disable(getQueue())
  end
  ui.dirty = false
  -- Read the board again, after the rollback's writes: Save waits for a read of this visit, and
  -- a read that did not succeed is retried from here.
  queueServosRead(false)
  if type(ui.runtime.requestRebuild) == "function" then
    ui.runtime.requestRebuild()
  end
  return true
end

function M.onStar(ctx)
  if not overrideActive() and not M.canSave() then return false end
  if not ensureOverride() then return false end

  local i18n = ctx and ctx.i18n
  local title
  local message

  if not overrideActive() then
    title = pageText(i18n, "enable_servo_override", "Enable servo override")
    message = pageText(i18n, "enable_servo_override_msg", "Servo override allows you to 'trim' your servo center point in real time.")
  else
    title = pageText(i18n, "disable_servo_override", "Disable servo override")
    message = pageText(i18n, "disable_servo_override_msg", "Return control of the servos to the flight controller.")
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
        -- Checked again: Yes comes later than the press, and the page may have closed since.
        if not M.canSave() or not syncOverrideServo() then return end
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
  -- An unsaved centre sent live is taken back first, while the override still holds the servos.
  -- Queued ahead of the override write on purpose: should the close end before every write is out,
  -- a lost override write leaves a board that refuses to arm, a lost rollback a trial centre the
  -- model would fly with. A save still writing is not undone here (rollbackDue above).
  if rollbackDue() then
    rollbackChanges()
  elseif ui.dirty then
    logf("debug", "close: a save is still writing, nothing put back")
  end
  if overrideActive() then
    ui.override:disable(getQueue())
  end
  ui.override = nil
  ui.overrideServo = nil
  ui.dirty = false
  if Common and type(Common.resetPageState) == "function" then
    Common.resetPageState(ui, {
      resetLoaded = true,
      resetDirty = true,
      resetConfig = true,
      resetApiData = true
    })
  end
  Controls = nil
  Common = nil
  MspRuntime = nil
  LoadingOverlay = nil
  LiveOverride = nil
  ApiVersion = nil
  SavePipeline = nil
  t = nil
end

return M
