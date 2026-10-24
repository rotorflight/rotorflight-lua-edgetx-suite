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
local EscSensorConfigApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local ApiVersion = nil
local EscSensorTrialApi = nil
local Armed = nil
local t = nil
local buildSessionSignature
local loadFromSession

local ui = {
  loaded = false,
  dirty = false,
  loading = false,
  progress = 0,
  baseTitle = nil,
  config = {
    protocol = 0,
    half_duplex = 0,
    pin_swap = 0,
    voltage_correction = 0,
    current_correction = 0,
    consumption_correction = 0
  },
  parsedCache = {},
  runtime = {
    readPending = false,
    requestRebuild = nil,
    lastSessionSignature = nil,
    syncHeaderTitle = nil,
    visitGeneration = 0,
    trial = { supported = nil, active = false, pending = false, cancelRequested = false, armedEpoch = nil, state = 0,
      status = nil, nextPollAt = 0, generation = 0, mustRead = false }
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
  if not EscSensorConfigApi then EscSensorConfigApi = loadModule("tasks/msp/api/esc_sensor_config.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not ApiVersion then ApiVersion = loadModule("lib/api_version.lua") end
  if not EscSensorTrialApi then EscSensorTrialApi = loadModule("tasks/msp/api/esc_sensor_trial.lua") end
  -- The shared copy: lib/armed.lua counts arm/disarm changes per Lua state, and only the copy
  -- the tool asks on every pass sees them. A private copy would not, so where the tool's
  -- loader exists there is no fallback; a failed load is remembered as false (no retry per pass).
  if Armed == nil then
    if _G.rfsuite and _G.rfsuite.require then
      Armed = _G.rfsuite.require("lib/armed.lua") or false
    else
      Armed = loadModule("lib/armed.lua") or false
    end
  end
  if not t then t = Common and Common.pageT("setup_esc_motors") or nil end
end

local function trialBusy()
  local trial = ui.runtime and ui.runtime.trial
  return trial and (trial.active or trial.pending) or false
end

-- What the page draws from a trial reply: a reply that changes none of it needs no rebuild.
local function drawnState()
  local trial = ui.runtime.trial
  return table.concat({ tostring(trial.status), tostring(trial.active), tostring(trialBusy()),
    tostring(trial.supported), tostring(trial.mustRead), tostring(ui.dirty),
    tostring(ui.config.half_duplex), tostring(ui.config.pin_swap) }, "|")
end

local function trialAvailable()
  local session = getSession()
  local api = session and session.apiVersion
  return session and session.isConnected == true and session.fblConnected == true
    and ApiVersion and ApiVersion.isAtLeast(api, { 12, 0, 10 })
end

local function queueTrial(action, quiet)
  local trial = ui.runtime.trial
  if trial.pending or not MspRuntime or not EscSensorTrialApi then return false end
  local state = MspRuntime.getState and MspRuntime.getState()
  local queue = state and state.queue
  if not queue or type(queue.add) ~= "function" then return false end
  local session = getSession()
  local signature = buildSessionSignature()
  local generation = trial.generation
  local runtime = ui.runtime
  local armedEpoch = trial.armedEpoch
  trial.pending = true
  local message = {
    command = EscSensorTrialApi.command,
    payload = EscSensorTrialApi.buildPayload(action),
    isWrite = action ~= EscSensorTrialApi.ACTION_POLL,
    client = "setup_esc_wiring_trial",
    processReply = function(_, buf)
      if ui.runtime ~= runtime or ui.runtime.trial ~= trial then return end
      local current = ui.runtime.trial
      if current.generation ~= generation or getSession() ~= session
        or buildSessionSignature() ~= signature then return end
      if armedEpoch ~= nil and Armed and Armed.changeCount and Armed.changeCount() ~= armedEpoch then return end
      local wasActive = current.active == true
      -- What the page draws from this reply. A poll that only says "still running" changes none
      -- of it, and a rebuild for it would put the focus back on the first control every 0.5 s.
      local before = drawnState()
      current.pending = false
      local result = EscSensorTrialApi.parse(buf)
      if not result then
        if quiet then current.supported = false else current.status = "invalid" end
        current.active = false
        current.mustRead = current.mustRead or wasActive or action ~= EscSensorTrialApi.ACTION_POLL
      elseif quiet and result.state ~= 1 then
        -- The opening poll only learns that the command is supported. A finished state is
        -- kept by the flight controller until the next START or Cancel, so it belongs to an
        -- earlier run (another visit, another tool) and is not this page's result.
        current.supported = true
      else
        current.supported = true
        current.state = result.state
        current.active = result.state == 1
        if result.state == 1 then
          current.status = "running"
          current.nextPollAt = (type(getTime) == "function" and getTime() or 0) + 50
        elseif result.state == 2 then
          ui.config.half_duplex = result.half_duplex
          ui.config.pin_swap = result.pin_swap
          ui.dirty = true
          current.status = "success"
          current.mustRead = false
        elseif result.state == 3 then
          current.status = "failed"
          current.mustRead = true
        elseif result.state == 4 then
          current.status = "rejected"
        elseif result.state == 0 then
          if action == EscSensorTrialApi.ACTION_CANCEL then
            current.status = "cancelled"
            current.mustRead = true
            ui.dirty = false
            loadFromSession()
          elseif wasActive then
            current.status = "interrupted"
            current.mustRead = true
          end
        else
          current.status = "invalid"
          current.mustRead = current.mustRead or wasActive or action ~= EscSensorTrialApi.ACTION_POLL
        end
      end
      if current.cancelRequested then
        current.cancelRequested = false
        current.active = false
        current.status = "cancelling"
        current.mustRead = true
        queueTrial(EscSensorTrialApi.ACTION_CANCEL, false)
      end
      local after = drawnState()
      if after ~= before and type(ui.runtime.requestRebuild) == "function" then ui.runtime.requestRebuild() end
    end,
    errorHandler = function()
      if ui.runtime ~= runtime or ui.runtime.trial ~= trial or getSession() ~= session
        or buildSessionSignature() ~= signature then return end
      local current = ui.runtime.trial
      if current.generation ~= generation then return end
      if armedEpoch ~= nil and Armed and Armed.changeCount and Armed.changeCount() ~= armedEpoch then return end
      current.pending = false
      current.active = false
      if current.cancelRequested then
        current.cancelRequested = false
        current.status = "cancelling"
        current.mustRead = true
        if not queueTrial(EscSensorTrialApi.ACTION_CANCEL, false) then
          current.status = "interrupted"
        end
      elseif action == EscSensorTrialApi.ACTION_POLL and quiet then
        current.supported = false
      else
        current.status = "interrupted"
        current.mustRead = true
      end
      if type(ui.runtime.requestRebuild) == "function" then ui.runtime.requestRebuild() end
    end
  }
  if action ~= EscSensorTrialApi.ACTION_POLL then message.maxRetries = 0 end
  queue:add(message)
  return true
end

local function requestPageRebuild()
  if ui.runtime and type(ui.runtime.requestRebuild) == "function" then ui.runtime.requestRebuild() end
end

local function startTrial()
  local trial = ui.runtime.trial
  local known = type(Armed) == "table" and type(Armed.isArmed) == "function"
    and type(Armed.changeCount) == "function"
  local armed = known and Armed.isArmed()
  local uncertain = known and type(Armed.isUncertain) == "function" and Armed.isUncertain()
  if not known or not trialAvailable() or armed or uncertain then trial.status = "unsafe"; requestPageRebuild(); return end
  if ui.dirty or ui.runtime.readComplete ~= true or ui.config.protocol == 0 then
    trial.status = "save_first"; requestPageRebuild(); return
  end
  trial.armedEpoch = Armed and Armed.changeCount and Armed.changeCount() or nil
  trial.status = "starting"
  if not queueTrial(EscSensorTrialApi.ACTION_START, false) then
    trial.status = "interrupted"
    trial.mustRead = true
  end
  requestPageRebuild()
end

local function cancelTrial()
  local trial = ui.runtime.trial
  if not trialBusy() then return end
  trial.status = "cancelling"
  if trial.pending then
    trial.cancelRequested = true
  else
    trial.active = false
    if not queueTrial(EscSensorTrialApi.ACTION_CANCEL, false) then
      trial.status = "interrupted"
      trial.mustRead = true
    end
  end
  requestPageRebuild()
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

buildSessionSignature = function()
  local session = getSession()
  return session and session.signature or "1"
end

loadFromSession = function()
  local session = getSession()
  if not session or type(session.setup_esc_motors_telemetry) ~= "table" then return end
  local cached = session.setup_esc_motors_telemetry
  ui.config.protocol = tonumber(cached.protocol) or 0
  ui.config.half_duplex = tonumber(cached.half_duplex) or 0
  ui.config.pin_swap = tonumber(cached.pin_swap) or 0
  ui.config.voltage_correction = tonumber(cached.voltage_correction) or 0
  ui.config.current_correction = tonumber(cached.current_correction) or 0
  ui.config.consumption_correction = tonumber(cached.consumption_correction) or 0
  ui.parsedCache = cached.parsedCache or {}
end

local function queueTelemetryRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not MspRuntime or not EscSensorConfigApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  local readValid = type(getSession()) == "table"
  local runtime = ui.runtime
  local generation = runtime.visitGeneration
  ui.runtime.readPending = true
  if not isAutoReload then
    ui.loading = true
    ui.progress = 0
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  queue:add({
    command = EscSensorConfigApi.command,
    simulatorResponse = EscSensorConfigApi.simulatorResponse,
    processReply = function(self, buf)
      if ui.runtime ~= runtime or runtime.visitGeneration ~= generation then return end
      local parsed = EscSensorConfigApi.parse(buf)
      if type(parsed) ~= "table" then return Common.failPageRead(ui) end
      if parsed then
        ui.config.protocol = parsed.protocol or 0
        ui.config.half_duplex = parsed.half_duplex or 0
        ui.config.pin_swap = parsed.pin_swap or 0
        ui.config.voltage_correction = parsed.voltage_correction or 0
        ui.config.current_correction = parsed.current_correction or 0
        ui.config.consumption_correction = parsed.consumption_correction or 0

        ui.parsedCache = parsed

        local session = getSession()
        if session then
          session.setup_esc_motors_telemetry = {
            protocol = ui.config.protocol,
            half_duplex = ui.config.half_duplex,
            pin_swap = ui.config.pin_swap,
            voltage_correction = ui.config.voltage_correction,
            current_correction = ui.config.current_correction,
            consumption_correction = ui.config.consumption_correction,
            parsedCache = ui.parsedCache
          }
        end
      end

      ui.runtime.readPending = false
      ui.loading = false
      ui.dirty = false
      ui.progress = 100
      ui.runtime.readComplete = readValid
      ui.runtime.trial.mustRead = false
      ui.runtime.trial.status = nil
      ui.runtime.trial.state = 0
      ui.runtime.trial.armedEpoch = nil
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end,
    errorHandler = function()
      if ui.runtime ~= runtime or runtime.visitGeneration ~= generation then return end
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

local function queueTelemetryWrite(requestRebuild)
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or not EscSensorConfigApi then
    return false, "msp_runtime_unavailable"
  end

  local writeData = {}
  if ui.parsedCache then
    for k, v in pairs(ui.parsedCache) do
      writeData[k] = v
    end
  end

  writeData.protocol = ui.config.protocol
  writeData.half_duplex = ui.config.half_duplex
  writeData.pin_swap = ui.config.pin_swap
  writeData.voltage_correction = ui.config.voltage_correction
  writeData.current_correction = ui.config.current_correction
  writeData.consumption_correction = ui.config.consumption_correction

  -- The chain that stood here cleared the dirty flag inside the REBOOT step's processReply --
  -- which is the moment the restart was sent, not the moment the settings were stored, and the
  -- board is at its least able to confirm anything. It is reported at the EEPROM
  -- acknowledgement now, and everything after it belongs to the pipeline.
  return SavePipeline.start({
    pageId = "setup_esc_motors_telemetry",
    steps = {
      {
        label = "MSP_SET_ESC_SENSOR_CONFIG",
        command = EscSensorConfigApi.writeCommand,
        payload = EscSensorConfigApi.buildWritePayload(writeData)
      }
    },
    reboot = true,
    invalidateSessionKeys = { "setup_esc_motors_telemetry" },
    onSaved = function()
      ui.dirty = false
      local session = getSession()
      if session then
        session.esc4WayDetectedProto = ui.config.protocol
      end
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
    SavePipeline.takeResult("setup_esc_motors_telemetry")
  end

  if not ui.runtime then
    ui.runtime = {
      readPending = false,
      requestRebuild = nil,
      lastSessionSignature = nil,
      syncHeaderTitle = nil,
      visitGeneration = 0,
      trial = { supported = nil, active = false, pending = false, cancelRequested = false, armedEpoch = nil, state = 0,
        status = nil, nextPollAt = 0, generation = 0, mustRead = false }
    }
  end

  ui.config = {
    protocol = 0,
    half_duplex = 0,
    pin_swap = 0,
    voltage_correction = 0,
    current_correction = 0,
    consumption_correction = 0
  }
  ui.parsedCache = {}

  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()

  local session = getSession()
  local rawApiVersion = session and session.apiVersion
  local isSupported = rawApiVersion and ApiVersion and ApiVersion.isAtLeast(rawApiVersion, {12, 0, 6})

  if isSupported then
    queueTelemetryRead(false)
  else
    ui.loading = false
  end
end

function M.wakeup(ctx)
  ensureDeps()
  ensureLoaded()

  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil

  local signature = buildSessionSignature()
  if signature ~= ui.runtime.lastSessionSignature then
    ui.runtime.visitGeneration = ui.runtime.visitGeneration + 1
    ui.runtime.trial.generation = ui.runtime.trial.generation + 1
    ui.runtime.trial.active = false
    ui.runtime.trial.pending = false
    ui.runtime.trial.mustRead = true
    ui.runtime.trial.supported = nil
    ui.runtime.trial.cancelRequested = false
    ui.runtime.readPending = false
    ui.runtime.lastSessionSignature = signature
    ui.loaded = false
    ensureLoaded()
  end

  local trial = ui.runtime.trial
  local session = getSession()
  local armedChanged = trial.armedEpoch ~= nil and Armed and Armed.changeCount
    and Armed.changeCount() ~= trial.armedEpoch
  if trialBusy() and (armedChanged or not session or session.isConnected ~= true or session.fblConnected ~= true) then
    trial.generation = trial.generation + 1
    trial.active = false
    trial.pending = false
    trial.status = "interrupted"
    trial.mustRead = true
    requestPageRebuild()
  elseif trial.active and not trial.pending then
    local now = type(getTime) == "function" and getTime() or 0
    if now >= (trial.nextPollAt or 0) then queueTrial(EscSensorTrialApi.ACTION_POLL, false) end
  elseif ui.runtime.readComplete == true and trial.supported == nil and not trial.pending
    and trialAvailable() then
    queueTrial(EscSensorTrialApi.ACTION_POLL, true)
  end
end

local function trialStatusText(i18n, status)
  if status == "starting" then return pageText(i18n, "detect_starting", "Starting wiring detection...") end
  if status == "running" then return pageText(i18n, "detect_running", "Testing ESC telemetry wiring...") end
  if status == "success" then return pageText(i18n, "detect_success", "Wiring detected. Save to store it.") end
  if status == "failed" then return pageText(i18n, "detect_failed", "No working wiring was detected.") end
  if status == "rejected" then return pageText(i18n, "detect_rejected", "Detection was rejected by the flight controller.") end
  if status == "cancelled" then return pageText(i18n, "detect_cancelled", "Detection cancelled. Reload before saving.") end
  if status == "cancelling" then return pageText(i18n, "detect_cancelling", "Cancelling wiring detection...") end
  if status == "interrupted" then return pageText(i18n, "detect_interrupted", "Detection interrupted. Reload before saving.") end
  if status == "invalid" then return pageText(i18n, "detect_invalid", "The flight controller returned an invalid result.") end
  if status == "unsafe" then return pageText(i18n, "detect_unsafe", "Detection needs a live connection and a disarmed model.") end
  if status == "save_first" then return pageText(i18n, "detect_save_first", "Save the selected telemetry protocol before detection.") end
  return nil
end

function M.getHeaderActions()
  local session = getSession()
  local rawApiVersion = session and session.apiVersion
  local isSupported = rawApiVersion and ApiVersion and ApiVersion.isAtLeast(rawApiVersion, {12, 0, 6})

  return {
    save = isSupported == true and not trialBusy() and not ui.runtime.trial.mustRead,
    reload = isSupported == true and not trialBusy(),
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
    local titleText = "@i18n(app.loading)@"
    local msgText = pageText(i18n, "loading_telemetry", "Loading telemetry configuration...")
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = titleText,
      message = msgText,
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or "Telemetry"
  local title = pageText(i18n, "title_telemetry", displayTitle)
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
  local isSupported = rawApiVersion and ApiVersion and ApiVersion.isAtLeast(rawApiVersion, {12, 0, 6})

  if not isSupported then
    children[#children + 1] = {
      type = "label",
      x = x + 10, y = cursorY + 10,
      text = "Unsupported API version",
      color = Palette.accent,
      font = MIDSIZE
    }
    return
  end

  local hasPinSwap = ApiVersion.isAtLeast(rawApiVersion, {12, 0, 7})
  local hasCorrections = ApiVersion.isAtLeast(rawApiVersion, {12, 0, 8})
  local hasXdfly = ApiVersion.isAtLeast(rawApiVersion, {12, 0, 8})
  local hasFbus = ApiVersion.isAtLeast(rawApiVersion, {12, 0, 9})
  local hasSrxl2 = ApiVersion.isAtLeast(rawApiVersion, {12, 0, 10})

  -- These numbers are the flight controller's own protocol enum and a board stores whatever
  -- it is sent, so an entry the board does not have is not an unused label: it is a different
  -- protocol's number. The head is fixed. XDFLY, FrSky F.BUS and SRXL2 were each added in
  -- front of RECORD, which has been the last entry since before any of them, so RECORD's own
  -- number moves with them and is taken from what was appended rather than written down.
  local protocolOptions = {
    { label = "NONE", value = 0 },
    { label = "BLHELI32", value = 1 },
    { label = "HOBBYWING V4", value = 2 },
    { label = "HOBBYWING V5", value = 3 },
    { label = "SCORPION", value = 4 },
    { label = "KONTRONIK", value = 5 },
    { label = "OMP", value = 6 },
    { label = "ZTW", value = 7 },
    { label = "APD", value = 8 },
    { label = "OPENYGE", value = 9 },
    { label = "FLYROTOR", value = 10 },
    { label = "GRAUPNER", value = 11 }
  }

  local function appendProtocol(label)
    local value = #protocolOptions
    protocolOptions[value + 1] = { label = label, value = value }
  end

  if hasXdfly then appendProtocol("XDFLY") end
  if hasFbus then appendProtocol("FrSky F.BUS") end
  if hasSrxl2 then appendProtocol("SRXL2") end
  appendProtocol("RECORD")

  local proto = ui.config.protocol
  local function fieldsActive() return not trialBusy() and not ui.runtime.trial.mustRead end

  -- 1. Telemetry Protocol
  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    pageText(i18n, "telemetry_protocol", "Telemetry Protocol"),
    protocolOptions,
    proto,
    function(newVal)
      local val = tonumber(newVal) or 0
      if ui.config.protocol ~= val then
        ui.config.protocol = val
        ui.dirty = true
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      end
    end,
    { active = fieldsActive }
  )

  -- 2. Half Duplex
  cursorY = cursorY + Controls.appendRadioSwitch(
    children, x, cursorY, w,
    pageText(i18n, "half_duplex", "Half Duplex"),
    function() return ui.config.half_duplex ~= 0 end,
    function(nextBool)
      ui.config.half_duplex = nextBool and 1 or 0
      ui.dirty = true
    end,
    function() return proto ~= 0 and fieldsActive() end
  )

  -- 3. Pin Swap (if apiVersion >= 12.0.7)
  if hasPinSwap then
    cursorY = cursorY + Controls.appendRadioSwitch(
      children, x, cursorY, w,
      pageText(i18n, "pin_swap", "Pin Swap"),
      function() return ui.config.pin_swap ~= 0 end,
      function(nextBool)
        ui.config.pin_swap = nextBool and 1 or 0
        ui.dirty = true
      end,
      function() return proto ~= 0 and fieldsActive() end
    )
  end

  -- 4. Voltage Correction (if apiVersion >= 12.0.8)
  if hasCorrections then
    cursorY = cursorY + Controls.appendNumberField(
      children, x, cursorY, w,
      pageText(i18n, "voltage_correction", "Voltage Correction"),
      {
        min = -99,
        max = 125,
        suffix = "%",
        active = function() return proto ~= 0 and fieldsActive() end,
        get = function() return ui.config.voltage_correction end,
        set = function(v)
          ui.config.voltage_correction = tonumber(v) or 0
          ui.dirty = true
        end
      }
    )

    -- 5. Current Correction
    cursorY = cursorY + Controls.appendNumberField(
      children, x, cursorY, w,
      pageText(i18n, "current_correction", "Current Correction"),
      {
        min = -99,
        max = 125,
        suffix = "%",
        active = function() return proto ~= 0 and fieldsActive() end,
        get = function() return ui.config.current_correction end,
        set = function(v)
          ui.config.current_correction = tonumber(v) or 0
          ui.dirty = true
        end
      }
    )

    -- 6. Consumption Correction
    cursorY = cursorY + Controls.appendNumberField(
      children, x, cursorY, w,
      pageText(i18n, "consumption_correction", "Consumption Correction"),
      {
        min = -99,
        max = 125,
        suffix = "%",
        active = function() return proto ~= 0 and fieldsActive() end,
        get = function() return ui.config.consumption_correction end,
        set = function(v)
          ui.config.consumption_correction = tonumber(v) or 0
          ui.dirty = true
        end
      }
    )
  end


  if trialAvailable() and ui.runtime.trial.supported == true then
    local trial = ui.runtime.trial
    local statusText = trialStatusText(i18n, trial.status)
    if statusText then
      children[#children + 1] = { type = "label", x = x + 10, y = cursorY + 5,
        w = w - 20, text = statusText, color = Palette.accent, font = SMLSIZE }
      cursorY = cursorY + 30
    end
    children[#children + 1] = {
      type = "button", x = x + 10, y = cursorY + 2, w = math.floor((w - 30) / 2),
      text = pageText(i18n, "detect_wiring", "Detect wiring"),
      active = function() return not trialBusy() and not trial.mustRead end,
      press = startTrial
    }
    children[#children + 1] = {
      type = "button", x = x + 20 + math.floor((w - 30) / 2), y = cursorY + 2,
      w = math.floor((w - 30) / 2), text = pageText(i18n, "detect_cancel", "Cancel"),
      active = function() return trialBusy() end, press = cancelTrial
    }
    cursorY = cursorY + 38
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
    and not trialBusy() and not ui.runtime.trial.mustRead
end

function M.onSave(ctx)
  if not M.canSave() then return false, "loaded_data_missing" end
  local ok, err = queueTelemetryWrite(ctx and ctx.requestRebuild)
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
  if trialBusy() then return false end
  local session = getSession()
  if session then
    ui.dirty = false
    -- Ask again after the read: a capability poll that was lost does not hide the action for the
    -- rest of the visit.
    ui.runtime.trial.supported = nil
    loadFromSession()
    queueTelemetryRead(false)
  end
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/esc_motors/telemetry/help.lua")
  if type(help) == "function" then
    return help(ctx)
  end
  return { title = "Help", message = "No help available" }
end


function M.onClose()
  if ui.runtime then ui.runtime.visitGeneration = (ui.runtime.visitGeneration or 0) + 1 end
  if ui.runtime and ui.runtime.trial then
    ui.runtime.trial.generation = ui.runtime.trial.generation + 1
    ui.runtime.trial.active = false
    ui.runtime.trial.pending = false
  end
  if Common and type(Common.resetPageState) == "function" then
    Common.resetPageState(ui, {
      resetLoaded = true,
      resetDirty = true
    })
  end
  Controls = nil
  Common = nil
  MspRuntime = nil
  EscSensorConfigApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  ApiVersion = nil
  EscSensorTrialApi = nil
  Armed = nil
  t = nil
end

-- Asked before the page is left (ui/home.lua): true while an edit here is not saved.
function M.hasUnsavedChanges()
  return ui.dirty == true or trialBusy()
end

return M
