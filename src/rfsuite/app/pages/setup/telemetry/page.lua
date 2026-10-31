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
local TelemetryApi = nil
local SavePipeline = nil
local RxConfigApi = nil
local ConfirmDialog = nil
local LoadingOverlay = nil
local ApiVersion = nil
local t = nil

-- The page opens on this list of groups; a group's sensors are built only when the group is
-- opened. Each title is a complete i18n marker because the packager resolves literal keys only.
local SENSOR_GROUPS = {
  { key = "battery", title = "@i18n(app.pages.setup_telemetry.group_battery)@" },
  { key = "voltage", title = "@i18n(app.pages.setup_telemetry.group_voltage)@" },
  { key = "current", title = "@i18n(app.pages.setup_telemetry.group_current)@" },
  { key = "temps", title = "@i18n(app.pages.setup_telemetry.group_temps)@" },
  { key = "esc1", title = "@i18n(app.pages.setup_telemetry.group_esc1)@" },
  { key = "esc2", title = "@i18n(app.pages.setup_telemetry.group_esc2)@" },
  { key = "rpm", title = "@i18n(app.pages.setup_telemetry.group_rpm)@" },
  { key = "barometer", title = "@i18n(app.pages.setup_telemetry.group_barometer)@" },
  { key = "gyro", title = "@i18n(app.pages.setup_telemetry.group_gyro)@" },
  { key = "gps", title = "@i18n(app.pages.setup_telemetry.group_gps)@" },
  { key = "status", title = "@i18n(app.pages.setup_telemetry.group_status)@" },
  { key = "profiles", title = "@i18n(app.pages.setup_telemetry.group_profiles)@" },
  { key = "control", title = "@i18n(app.pages.setup_telemetry.group_control)@" },
  { key = "system", title = "@i18n(app.pages.setup_telemetry.group_system)@" },
  { key = "debug", title = "@i18n(app.pages.setup_telemetry.group_debug)@" }
}

-- The flight controller's sensor list holds 40 entries (buffer positions 13..52).
local MAX_SLOTS = 40

local SERIALRX_CRSF = 9 -- Firmware SERIALRX_CRSF enum in src/main/rx/rx.h.

local SENSOR_CATALOG = {
  { id = 1, labelKey = "sensor_1", labelFallback = "Heartbeat", group = "system" },
  { id = 3, labelKey = "sensor_3", labelFallback = "Battery Voltage", group = "battery" },
  { id = 4, labelKey = "sensor_4", labelFallback = "Battery Current", group = "battery" },
  { id = 5, labelKey = "sensor_5", labelFallback = "Battery Consumption", group = "battery" },
  { id = 6, labelKey = "sensor_6", labelFallback = "Battery Charge Level", group = "battery" },
  { id = 7, labelKey = "sensor_7", labelFallback = "Battery Cell Count", group = "battery" },
  { id = 8, labelKey = "sensor_8", labelFallback = "Battery Cell Voltage", group = "battery" },
  { id = 9, labelKey = "sensor_9", labelFallback = "Battery Cell Voltages", group = "battery" },
  { id = 10, labelKey = "sensor_10", labelFallback = "Control (Combined)", group = "control" },
  { id = 11, labelKey = "sensor_11", labelFallback = "Pitch Control", group = "control" },
  { id = 12, labelKey = "sensor_12", labelFallback = "Roll Control", group = "control" },
  { id = 13, labelKey = "sensor_13", labelFallback = "Yaw Control", group = "control" },
  { id = 14, labelKey = "sensor_14", labelFallback = "Collective Control", group = "control" },
  { id = 15, labelKey = "sensor_15", labelFallback = "Throttle Control", group = "control" },
  { id = 17, labelKey = "sensor_17", labelFallback = "ESC1 Voltage", group = "esc1" },
  { id = 18, labelKey = "sensor_18", labelFallback = "ESC1 Current", group = "esc1" },
  { id = 19, labelKey = "sensor_19", labelFallback = "ESC1 Consumption", group = "esc1" },
  { id = 20, labelKey = "sensor_20", labelFallback = "ESC1 ERPM", group = "esc1" },
  { id = 21, labelKey = "sensor_21", labelFallback = "ESC1 Power", group = "esc1" },
  { id = 22, labelKey = "sensor_22", labelFallback = "ESC1 Throttle", group = "esc1" },
  { id = 23, labelKey = "sensor_23", labelFallback = "ESC1 Temp 1", group = "esc1" },
  { id = 24, labelKey = "sensor_24", labelFallback = "ESC1 Temp 2", group = "esc1" },
  { id = 25, labelKey = "sensor_25", labelFallback = "ESC1 BEC Voltage", group = "esc1" },
  { id = 26, labelKey = "sensor_26", labelFallback = "ESC1 BEC Current", group = "esc1" },
  { id = 27, labelKey = "sensor_27", labelFallback = "ESC1 Status", group = "esc1" },
  { id = 28, labelKey = "sensor_28", labelFallback = "ESC1 Model", group = "esc1" },
  { id = 30, labelKey = "sensor_30", labelFallback = "ESC2 Voltage", group = "esc2" },
  { id = 31, labelKey = "sensor_31", labelFallback = "ESC2 Current", group = "esc2" },
  { id = 32, labelKey = "sensor_32", labelFallback = "ESC2 Consumption", group = "esc2" },
  { id = 33, labelKey = "sensor_33", labelFallback = "ESC2 ERPM", group = "esc2" },
  { id = 36, labelKey = "sensor_36", labelFallback = "ESC2 Temp", group = "esc2" },
  { id = 41, labelKey = "sensor_41", labelFallback = "ESC2 Model", group = "esc2" },
  { id = 42, labelKey = "sensor_42", labelFallback = "ESC Voltage", group = "voltage" },
  { id = 43, labelKey = "sensor_43", labelFallback = "BEC Voltage", group = "voltage" },
  { id = 44, labelKey = "sensor_44", labelFallback = "Bus Voltage", group = "voltage" },
  { id = 45, labelKey = "sensor_45", labelFallback = "MCU Voltage", group = "voltage" },
  { id = 46, labelKey = "sensor_46", labelFallback = "ESC Current", group = "current" },
  { id = 47, labelKey = "sensor_47", labelFallback = "BEC Current", group = "current" },
  { id = 48, labelKey = "sensor_48", labelFallback = "Bus Current", group = "current" },
  { id = 49, labelKey = "sensor_49", labelFallback = "MCU Current", group = "current" },
  { id = 50, labelKey = "sensor_50", labelFallback = "ESC Temp", group = "temps" },
  { id = 51, labelKey = "sensor_51", labelFallback = "BEC Temp", group = "temps" },
  { id = 52, labelKey = "sensor_52", labelFallback = "MCU Temp", group = "temps" },
  { id = 57, labelKey = "sensor_57", labelFallback = "Heading", group = "gyro" },
  { id = 58, labelKey = "sensor_58", labelFallback = "Altitude", group = "barometer" },
  { id = 59, labelKey = "sensor_59", labelFallback = "Vario", group = "barometer" },
  { id = 60, labelKey = "sensor_60", labelFallback = "Headspeed", group = "rpm" },
  { id = 61, labelKey = "sensor_61", labelFallback = "Tailspeed", group = "rpm" },
  { id = 64, labelKey = "sensor_64", labelFallback = "Attitude (Combined)", group = "gyro" },
  { id = 65, labelKey = "sensor_65", labelFallback = "Pitch Attitude", group = "gyro" },
  { id = 66, labelKey = "sensor_66", labelFallback = "Roll Attitude", group = "gyro" },
  { id = 67, labelKey = "sensor_67", labelFallback = "Yaw Attitude", group = "gyro" },
  { id = 68, labelKey = "sensor_68", labelFallback = "Accel (Combined)", group = "gyro" },
  { id = 69, labelKey = "sensor_69", labelFallback = "Accel X", group = "gyro" },
  { id = 70, labelKey = "sensor_70", labelFallback = "Accel Y", group = "gyro" },
  { id = 71, labelKey = "sensor_71", labelFallback = "Accel Z", group = "gyro" },
  { id = 73, labelKey = "sensor_73", labelFallback = "GPS Sats", group = "gps" },
  { id = 74, labelKey = "sensor_74", labelFallback = "GPS PDOP", group = "gps" },
  { id = 75, labelKey = "sensor_75", labelFallback = "GPS HDOP", group = "gps" },
  { id = 76, labelKey = "sensor_76", labelFallback = "GPS VDOP", group = "gps" },
  { id = 77, labelKey = "sensor_77", labelFallback = "GPS Coordinates", group = "gps" },
  { id = 78, labelKey = "sensor_78", labelFallback = "GPS Altitude", group = "gps" },
  { id = 79, labelKey = "sensor_79", labelFallback = "GPS Heading", group = "gps" },
  { id = 80, labelKey = "sensor_80", labelFallback = "GPS Speed", group = "gps" },
  { id = 81, labelKey = "sensor_81", labelFallback = "GPS Home Distance", group = "gps" },
  { id = 82, labelKey = "sensor_82", labelFallback = "GPS Home Direction", group = "gps" },
  { id = 85, labelKey = "sensor_85", labelFallback = "CPU Load", group = "system" },
  { id = 86, labelKey = "sensor_86", labelFallback = "SYS Load", group = "system" },
  { id = 87, labelKey = "sensor_87", labelFallback = "RT Load", group = "system" },
  { id = 88, labelKey = "sensor_88", labelFallback = "Model ID", group = "status" },
  { id = 89, labelKey = "sensor_89", labelFallback = "Flight Mode", group = "status" },
  { id = 90, labelKey = "sensor_90", labelFallback = "Arming Flags", group = "status" },
  { id = 91, labelKey = "sensor_91", labelFallback = "Arming Disable Flags", group = "status" },
  { id = 92, labelKey = "sensor_92", labelFallback = "Rescue State", group = "status" },
  { id = 93, labelKey = "sensor_93", labelFallback = "Governor State", group = "status" },
  { id = 95, labelKey = "sensor_95", labelFallback = "PID Profile", group = "profiles" },
  { id = 96, labelKey = "sensor_96", labelFallback = "Rates Profile", group = "profiles" },
  { id = 97, labelKey = "sensor_97", labelFallback = "Battery Profile", group = "profiles" },
  { id = 98, labelKey = "sensor_98", labelFallback = "LED Profile", group = "profiles" },
  { id = 99, labelKey = "sensor_99", labelFallback = "Adjustment Function", group = "status" },
  { id = 100, labelKey = "sensor_100", labelFallback = "Debug 0", group = "debug" },
  { id = 101, labelKey = "sensor_101", labelFallback = "Debug 1", group = "debug" },
  { id = 102, labelKey = "sensor_102", labelFallback = "Debug 2", group = "debug" },
  { id = 103, labelKey = "sensor_103", labelFallback = "Debug 3", group = "debug" },
  { id = 104, labelKey = "sensor_104", labelFallback = "Debug 4", group = "debug" },
  { id = 105, labelKey = "sensor_105", labelFallback = "Debug 5", group = "debug" },
  { id = 106, labelKey = "sensor_106", labelFallback = "Debug 6", group = "debug" },
  { id = 107, labelKey = "sensor_107", labelFallback = "Debug 7", group = "debug" },
  -- Packed status words (rotorflight-firmware src/main/telemetry/status.h).
  -- minApi: firmware before MSP API 12.10 does not have them, so they are
  -- neither listed nor defaulted there (see isOffered()).
  { id = 120, labelKey = "sensor_120", labelFallback = "System Status", group = "status", minApi = { 12, 0, 10 } },
  { id = 121, labelKey = "sensor_121", labelFallback = "System Config", group = "status", minApi = { 12, 0, 10 } }
}

local DEFAULT_SENSORS = {
  3, 4, 5, 6, 7, 15, 23, 25, 43, 60, 85, 90, 91, 93, 95, 96, 97, 99, 120, 121
}

local NOT_AT_SAME_TIME = {
  [10] = { 11, 12, 13, 14 },
  [64] = { 65, 66, 67 },
  [68] = { 69, 70, 71 }
}

local CONFLICTING_WITH = {}
for parentId, subIds in pairs(NOT_AT_SAME_TIME) do
  for i = 1, #subIds do
    CONFLICTING_WITH[subIds[i]] = parentId
  end
end

local CRSF_NATIVE_CATALOG_IDS = {
  [58] = true,
  [64] = true,
  [89] = true
}

local SENSOR_BY_ID = {}
local SENSOR_IDS = {}
local SENSOR_BY_GROUP = {}
for i = 1, #SENSOR_CATALOG do
  local item = SENSOR_CATALOG[i]
  SENSOR_BY_ID[item.id] = item
  SENSOR_IDS[#SENSOR_IDS + 1] = item.id
  SENSOR_BY_GROUP[item.group] = SENSOR_BY_GROUP[item.group] or {}
  SENSOR_BY_GROUP[item.group][#SENSOR_BY_GROUP[item.group] + 1] = item
end

local function newRuntime()
  return {
    readPending = false,
    readComplete = false,
    requestRebuild = nil,
    boolGetters = {},
    boolSetters = {},
    activeGetters = {},
    groupOpeners = {}
  }
end

local ui = {
  loaded = false,
  dirty = false,
  -- nil shows the list of groups; a group key shows that group's sensors.
  group = nil,
  -- The live count is formatted when a sensor changes, never in the label's own getter,
  -- which LVGL polls on every refresh.
  countText = "",
  countOver = false,
  countFormat = "%d / %d",
  countOverFormat = "%d / %d",
  config = {},
  telemetryBuffer = nil,
  crsfTelemetryMode = nil,
  serialrxProvider = nil,
  nativeLockedIds = {},
  runtime = newRuntime(),
  loading = false,
  progress = 0
}

ui.runtimeBase = nil

local function ensureRuntime()
  if type(ui.runtime) ~= "table" then
    ui.runtime = newRuntime()
  end
end

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not TelemetryApi then TelemetryApi = loadModule("tasks/msp/api/telemetry_config.lua") end
  if not RxConfigApi then RxConfigApi = loadModule("tasks/msp/api/rx_config.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ApiVersion then ApiVersion = loadModule("lib/api_version.lua") end
  if not ui.runtimeBase then
    ui.runtimeBase = Common.createFormRuntime(ui)
    -- onClose leaves ui.runtime nil while the module stays in the page cache, so a re-entry
    -- arrives here without one. It has to be the page's own runtime: activeGetters exists only
    -- there, not on the shared base.
    ensureRuntime()
    setmetatable(ui.runtime, { __index = ui.runtimeBase })
  end
  if not t then t = Common and Common.pageT("setup_telemetry") or nil end
end

local function pageText(i18n, key, fallback)
  if t then return t(i18n, key, fallback) end
  return fallback
end

local function copyBuffer(buf)
  local out = {}
  if type(buf) ~= "table" then return out end
  for i = 1, #buf do
    out[i] = tonumber(buf[i]) or 0
  end
  return out
end

local function clearConfig()
  for i = 1, #SENSOR_IDS do
    ui.config[SENSOR_IDS[i]] = false
  end
end

local function markDirty()
  ui.dirty = true
end

local function countSelected()
  local count = 0
  for i = 1, #SENSOR_IDS do
    if ui.config[SENSOR_IDS[i]] == true then
      count = count + 1
    end
  end
  return count
end

local function isNativeLocked(sensorId)
  return ui.serialrxProvider == SERIALRX_CRSF and ui.crsfTelemetryMode == 0 and ui.nativeLockedIds and ui.nativeLockedIds[sensorId] == true
end

local function extractNativeLockedIds(cfg, buffer)
  local locked = {}
  if ui.serialrxProvider ~= SERIALRX_CRSF or ui.crsfTelemetryMode ~= 0 then
    return locked
  end
  if cfg then
    for i = 1, 40 do
      local sensorId = tonumber(cfg["telem_sensor_slot_" .. tostring(i)])
      if sensorId and CRSF_NATIVE_CATALOG_IDS[sensorId] then
        locked[sensorId] = true
      end
    end
  elseif buffer and #buffer >= 52 then
    for pos = 13, 52 do
      local sensorId = tonumber(buffer[pos])
      if sensorId and CRSF_NATIVE_CATALOG_IDS[sensorId] then
        locked[sensorId] = true
      end
    end
  end
  return locked
end

-- A catalog entry with minApi is only offered (listed and defaulted) when the
-- connected firmware's API version reaches it. Before the session knows the
-- version it is not offered.
local function isOffered(id)
  local item = SENSOR_BY_ID[id]
  if not item then return false end
  if not item.minApi then return true end
  local session = getSession()
  local rawApiVersion = type(session) == "table" and session.apiVersion or nil
  return ApiVersion ~= nil and ApiVersion.isAtLeast(rawApiVersion, item.minApi)
end

local function applyDefaults()
  clearConfig()
  for i = 1, #DEFAULT_SENSORS do
    local id = DEFAULT_SENSORS[i]
    if isOffered(id) then
      ui.config[id] = true
    end
  end
  if ui.crsfTelemetryMode == 0 and ui.nativeLockedIds then
    for id in pairs(ui.nativeLockedIds) do
      ui.config[id] = true
    end
  end
  markDirty()
end

local function loadFromSession()
  local session = getSession()
  local cfg = (type(session) == "table" and type(session.telemetry_config) == "table") and session.telemetry_config or nil
  local rxConfig = type(session) == "table" and session.rx_config or nil
  ui.serialrxProvider = type(rxConfig) == "table" and tonumber(rxConfig.serialrx_provider) or nil

  if cfg and type(cfg.buffer) == "table" then
    ui.telemetryBuffer = copyBuffer(cfg.buffer)
  else
    ui.telemetryBuffer = nil
  end

  if cfg and cfg.crsf_telemetry_mode ~= nil then
    ui.crsfTelemetryMode = tonumber(cfg.crsf_telemetry_mode)
  elseif ui.telemetryBuffer and #ui.telemetryBuffer >= 8 then
    ui.crsfTelemetryMode = tonumber(ui.telemetryBuffer[8])
  else
    ui.crsfTelemetryMode = nil
  end

  ui.nativeLockedIds = extractNativeLockedIds(cfg, ui.telemetryBuffer)

  clearConfig()

  local hasSlots = false
  if cfg then
    for i = 1, 40 do
      local sensorId = tonumber(cfg["telem_sensor_slot_" .. tostring(i)])
      if sensorId and sensorId ~= 0 then
        hasSlots = true
        if SENSOR_BY_ID[sensorId] then
          ui.config[sensorId] = true
        end
      end
    end
  end

  if not hasSlots then
    for i = 1, #DEFAULT_SENSORS do
      local id = DEFAULT_SENSORS[i]
      if isOffered(id) then
        ui.config[id] = true
      end
    end
  end

  if ui.crsfTelemetryMode == 0 and ui.nativeLockedIds then
    for id in pairs(ui.nativeLockedIds) do
      ui.config[id] = true
    end
  end
end

local function queueTelemetryRead()
  ensureRuntime()
  if ui.runtime.readPending then
    return false, "read_pending"
  end
  ui.runtime.readComplete = false
  if not TelemetryApi or not RxConfigApi or not MspRuntime or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local session = getSession()
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  local telemetryApi = TelemetryApi
  local rxConfigApi = RxConfigApi
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  local readValid = type(session) == "table"
  local readFailed = false
  local repliesPending = 2
  local telemetryConfig = nil
  local rxConfig = nil
  ui.runtime.readPending = true
  ui.runtime.readFailed = false
  ui.loading = true
  ui.progress = 0

  local function failRead()
    if readFailed then return end
    readFailed = true
    ui.runtime.readComplete = false
    ui.runtime.readPending = false
    ui.loading = false
    ui.progress = 1
    if Common and Common.failPageRead then
      Common.failPageRead(ui)
    end
  end

  -- Both reads are queued together; only their combined result rebuilds the page.
  local function finishRead()
    if readFailed then return end
    repliesPending = repliesPending - 1
    ui.progress = (2 - repliesPending) / 2
    if repliesPending > 0 then return end
    ui.runtime.readPending = false
    ui.loading = false
    if type(session) == "table" then
      session.telemetry_config = telemetryConfig
      session.rx_config = rxConfig
    end
    ui.serialrxProvider = tonumber(rxConfig.serialrx_provider)
    if telemetryConfig.crsf_telemetry_mode ~= nil then
      ui.crsfTelemetryMode = tonumber(telemetryConfig.crsf_telemetry_mode)
    end
    if not ui.dirty then
      loadFromSession()
    elseif telemetryConfig.buffer then
      ui.telemetryBuffer = copyBuffer(telemetryConfig.buffer)
      ui.nativeLockedIds = extractNativeLockedIds(telemetryConfig, ui.telemetryBuffer)
      if ui.crsfTelemetryMode == 0 and ui.nativeLockedIds then
        for id in pairs(ui.nativeLockedIds) do
          ui.config[id] = true
        end
      end
    end
    ui.runtime.readComplete = readValid
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  queue:add({
    command = telemetryApi.command,
    simulatorResponse = telemetryApi.simulatorResponse,
    timeout = 5.0,
    processReply = function(_, buf)
      if readFailed then return end
      telemetryConfig = telemetryApi.parse and telemetryApi.parse(buf) or nil
      if type(telemetryConfig) ~= "table" then return failRead() end
      finishRead()
    end,
    errorHandler = failRead
  })
  queue:add({
    command = rxConfigApi.command,
    simulatorResponse = rxConfigApi.simulatorResponse,
    timeout = 5.0,
    processReply = function(_, buf)
      if readFailed then return end
      rxConfig = type(buf) == "table" and #buf >= 1 and rxConfigApi.parse and rxConfigApi.parse(buf) or nil
      if type(rxConfig) ~= "table" then return failRead() end
      finishRead()
    end,
    errorHandler = failRead
  })

  return true, nil
end

local function ensureLoaded()
  ensureRuntime()
  if ui.loaded then return end
  -- A save whose overlay was dismissed finished without a screen (the restart can outlast the
  -- page). Its outcome was held back rather than raised over another page; claim it now.
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if SavePipeline and type(SavePipeline.takeResult) == "function" then
    SavePipeline.takeResult("setup_telemetry")
  end
  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  queueTelemetryRead()
end

-- Whether a catalog sensor is written on save. A native-locked sensor always is; a child
-- whose parent is native-locked is displayed off and inactive, so it never is -- what is
-- written matches what is shown.
local function isSelected(id)
  if isNativeLocked(id) then
    return true
  end
  if ui.config[id] ~= true then
    return false
  end
  local parentId = CONFLICTING_WITH[id]
  return not (parentId and isNativeLocked(parentId))
end

local function collectSelectedSensors()
  local selected = {}
  for i = 1, #SENSOR_IDS do
    local id = SENSOR_IDS[i]
    if isSelected(id) then
      selected[#selected + 1] = id
    end
  end
  return selected
end

-- Slots holding a sensor this page does not list (e.g. native CRSF telemetry ids 2, 72, 108,
-- 109). Save keeps them where they are, so they take slots from the 40 as well.
local function countUnmanagedSlots()
  local count = 0
  if type(ui.telemetryBuffer) == "table" then
    for pos = 13, 52 do
      local origId = tonumber(ui.telemetryBuffer[pos]) or 0
      if origId ~= 0 and not SENSOR_BY_ID[origId] then
        count = count + 1
      end
    end
  end
  return count
end

-- The number of slots a save would fill. The live count and the save check both use it, so
-- the number on screen and the number that refuses a save cannot disagree.
local function countSlotsInUse(selected)
  return #(selected or collectSelectedSensors()) + countUnmanagedSlots()
end

local function refreshCount()
  local used = countSlotsInUse()
  ui.countOver = used > MAX_SLOTS
  ui.countText = string.format(ui.countOver and ui.countOverFormat or ui.countFormat, used, MAX_SLOTS)
end

local function countSelectedInGroup(groupKey)
  local items = SENSOR_BY_GROUP[groupKey]
  local count = 0
  if items then
    for i = 1, #items do
      if isSelected(items[i].id) then
        count = count + 1
      end
    end
  end
  return count, items and #items or 0
end

local function buildWritePayload(selected)
  local payload = copyBuffer(ui.telemetryBuffer)
  if #payload < 52 then
    for i = #payload + 1, 52 do payload[i] = 0 end
  end

  local pending = {}
  for i = 1, #selected do
    pending[selected[i]] = true
  end

  for pos = 13, 52 do
    local origId = tonumber(payload[pos]) or 0
    if origId ~= 0 and not SENSOR_BY_ID[origId] then
      -- Unmanaged sensor slot (e.g. native CRSF telemetry ids 2, 72, 108, 109):
      -- preserve exactly where it was.
    elseif pending[origId] then
      -- Keep the first slot of each selected sensor; later duplicates become free.
      pending[origId] = nil
    else
      payload[pos] = 0
    end
  end

  -- Fill only free slots, without moving existing sensors or their per-slot intervals.
  local index = 1
  for pos = 13, 52 do
    if payload[pos] == 0 then
      while index <= #selected and not pending[selected[index]] do
        index = index + 1
      end
      payload[pos] = selected[index] or 0
      index = index + 1
    end
  end

  return payload
end

local function queueTelemetryWrite(payload)
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or not TelemetryApi then
    return false, "msp_runtime_unavailable"
  end

  local session = getSession()
  local telemetryApi = TelemetryApi

  return SavePipeline.start({
    pageId = "setup_telemetry",
    steps = {
      {
        label = "MSP_SET_TELEMETRY_CONFIG",
        command = telemetryApi.writeCommand,
        payload = payload
      }
    },
    -- The flight controller builds its telemetry sensor schedule (CRSF custom and native,
    -- S.Port, legacy sensors) and picks the CRSF telemetry mode only at start-up, so a
    -- telemetry write takes effect after a restart, as Rotorflight Configurator's Receiver
    -- tab does it.
    reboot = true,
    onSaved = function()
      -- The pipeline can finish after the page closes, so update the session first.
      if type(session) == "table" and type(telemetryApi.parse) == "function" then
        session.telemetry_config = telemetryApi.parse(payload)
      end
      if not ui.runtime then return end
      ui.telemetryBuffer = copyBuffer(payload)
      ui.dirty = false
    end,
    onDone = function(result)
      if not ui.runtime then return end
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })
end

local function getBoolGetter(sensorId)
  local getter = ui.runtime.boolGetters[sensorId]
  if getter then return getter end

  getter = function()
    if isNativeLocked(sensorId) then
      return true
    end
    local parentId = CONFLICTING_WITH[sensorId]
    if parentId and isNativeLocked(parentId) then
      return false
    end
    return ui.config[sensorId] == true
  end
  ui.runtime.boolGetters[sensorId] = getter
  return getter
end

local function getBoolSetter(sensorId)
  local setter = ui.runtime.boolSetters[sensorId]
  if setter then return setter end

  setter = function(value)
    if isNativeLocked(sensorId) then
      return
    end
    local parentId = CONFLICTING_WITH[sensorId]
    if parentId and isNativeLocked(parentId) then
      return
    end

    local enabled = value == true
    if ui.config[sensorId] == enabled then return end

    ui.config[sensorId] = enabled
    local conflicts = NOT_AT_SAME_TIME[sensorId]
    if enabled and type(conflicts) == "table" then
      for i = 1, #conflicts do
        ui.config[conflicts[i]] = false
      end
    end
    if enabled and parentId then
      ui.config[parentId] = false
    end

    markDirty()
    -- No rebuild: the count label reads ui.countText through its getter.
    refreshCount()
  end
  ui.runtime.boolSetters[sensorId] = setter
  return setter
end

local function getActiveGetter(sensorId)
  local getter = ui.runtime.activeGetters[sensorId]
  if getter then return getter end

  getter = function()
    if isNativeLocked(sensorId) then
      return false
    end
    local parentId = CONFLICTING_WITH[sensorId]
    if parentId and isNativeLocked(parentId) then
      return false
    end
    return true
  end
  ui.runtime.activeGetters[sensorId] = getter
  return getter
end

local function getGroupOpener(groupKey)
  local opener = ui.runtime.groupOpeners[groupKey]
  if opener then return opener end

  opener = function()
    ui.group = groupKey
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end
  ui.runtime.groupOpeners[groupKey] = opener
  return opener
end

local function countTextGetter()
  return ui.countText
end

local function countColorGetter()
  if ui.countOver then
    return Palette.warning
  end
  return Palette.text
end

-- One line showing how many of the 40 slots a save would fill. Text and colour are getters,
-- so a toggle updates it without rebuilding the page.
local function appendCountLine(children, x, y, w)
  children[#children + 1] = {
    type = "label",
    x = x,
    y = y + 4,
    w = w,
    text = countTextGetter,
    color = countColorGetter,
    font = SMLSIZE
  }
  return (Controls and Controls.LABEL_H or 20) + 10
end

-- Back from a group returns to the list of groups; from the list it leaves the page.
function M.onBack()
  if ui.group ~= nil then
    ui.group = nil
    return true
  end
  return false
end

function M.getHeaderActions()
  ensureDeps()
  return {
    save = true,
    reload = true,
    star = true,
    help = true,
    menu = true
  }
end


function M.onReload()
  ensureDeps()
  ui.loaded = false
  ensureLoaded()
  return false
end

function M.onStar(ctx)
  ensureDeps()
  ensureLoaded()

  local function applyAndRefresh()
    applyDefaults()
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  if ConfirmDialog and type(ConfirmDialog.show) == "function" then
    local shown = ConfirmDialog.show({
      title = pageText(ctx and ctx.i18n, "set_defaults_title", "Telemetry Sensors"),
      message = pageText(ctx and ctx.i18n, "set_defaults_msg", "Load default telemetry sensors?"),
      onConfirm = applyAndRefresh,
      onCancel = function() end,
      onFallback = applyAndRefresh
    })
    if shown then
      return false
    end
  end

  applyAndRefresh()
  return true
end

function M.canSave()
  return ui.runtime ~= nil
    and ui.runtime.readComplete == true
    and not ui.runtime.readPending
    and type(ui.telemetryBuffer) == "table"
    and #ui.telemetryBuffer >= 52
end

function M.onSave(ctx)
  if not M.canSave() then return false, "loaded_data_missing" end
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if SavePipeline and SavePipeline.isActive() then return false end
  ensureDeps()
  ensureLoaded()

  local selected = collectSelectedSensors()
  if countSlotsInUse(selected) > MAX_SLOTS then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        title = pageText(ctx and ctx.i18n, "save_error_title", "Error"),
        message = pageText(ctx and ctx.i18n, "too_many_sensors", "No more than 40 telemetry sensors can be enabled.")
      })
    end
    return false
  end

  local payload = buildWritePayload(selected)
  local ok, err = queueTelemetryWrite(payload)
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

function M.build(ctx)
  ensureDeps()
  ensureLoaded()
  if ui.runtime and ui.runtime.setRequestRebuild then
    ui.runtime.setRequestRebuild(ctx and ctx.requestRebuild or nil)
  else
    ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil
  end

  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local i18n = ctx.i18n
  local h = ctx.h or 200

  local cursorY = y

  ui.countFormat = pageText(i18n, "count_format", "Sensors: %d / %d")
  ui.countOverFormat = pageText(i18n, "count_over_format", "Sensors: %d / %d - more than 40 cannot be saved")
  refreshCount()

  local groupItems = ui.group and SENSOR_BY_GROUP[ui.group] or nil
  if ui.group ~= nil and not groupItems then
    ui.group = nil
  end

  if groupItems then
    -- One group: its title, the live count, and only this group's sensors.
    local groupTitle = ui.group
    for g = 1, #SENSOR_GROUPS do
      if SENSOR_GROUPS[g].key == ui.group then
        groupTitle = SENSOR_GROUPS[g].title
        break
      end
    end
    Controls.appendStaticSectionHeader(children, x, cursorY, w, groupTitle)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 38)
    cursorY = cursorY + appendCountLine(children, x, cursorY, w)

    for i = 1, #groupItems do
      local item = groupItems[i]
      local sensorId = item.id
      if isOffered(sensorId) then
        cursorY = cursorY + Controls.appendRadioSwitch(
          children,
          x,
          cursorY,
          w,
          pageText(i18n, item.labelKey, item.labelFallback),
          getBoolGetter(sensorId),
          getBoolSetter(sensorId),
          getActiveGetter(sensorId),
          {
            helpText = pageText(i18n, "sensor_help", "Select whether the flight controller sends this sensor; native CRSF sensors are locked on."),
            helpTitle = pageText(i18n, item.labelKey, item.labelFallback)
          }
        )
      end
    end
  end

  if not groupItems and ui.serialrxProvider == SERIALRX_CRSF and ui.crsfTelemetryMode ~= nil then
    local modeTitle = ui.crsfTelemetryMode == 0
      and pageText(i18n, "mode_native", "CRSF Telemetry: Native")
      or pageText(i18n, "mode_custom", "CRSF Telemetry: Custom")

    if Controls and type(Controls.appendStaticSectionHeader) == "function" then
      Controls.appendStaticSectionHeader(children, x, cursorY, w, modeTitle)
      cursorY = cursorY + (Controls.STATIC_SECTION_H or 38)
    end

    if ui.crsfTelemetryMode == 0 then
      local warnText = pageText(i18n, "native_mode_warn", "Native CRSF mode active. The flight controller sends standard CRSF frames for the native sensors listed in these slots, which is why they cannot be switched off here. Additional sensors require Custom mode.")
      local textH = (Controls and Controls.estimateWrappedTextHeight) and Controls.estimateWrappedTextHeight(warnText, w, SMLSIZE) or 16
      children[#children + 1] = {
        type = "label",
        x = x,
        y = cursorY + 2,
        w = w,
        text = warnText,
        color = Palette.warning,
        font = SMLSIZE
      }
      cursorY = cursorY + textH + 8
    end
  end

  if not groupItems then
    -- The list of groups: the live count, then one row per group with how many of its
    -- sensors are on. The chevron opens the group.
    cursorY = cursorY + appendCountLine(children, x, cursorY, w)
    local countW = 70
    local countX = x + w - 30 - 8 - countW
    for g = 1, #SENSOR_GROUPS do
      local group = SENSOR_GROUPS[g]
      local on, total = countSelectedInGroup(group.key)
      if total > 0 then
        local groupCount = string.format("%d / %d", on, total)
        Controls.appendSectionHeader(children, x, cursorY, w, group.title, false, getGroupOpener(group.key))
        children[#children + 1] = {
          type = "label",
          x = countX,
          y = cursorY + 6,
          w = countW,
          text = groupCount,
          color = on > 0 and Palette.text or Palette.muted,
          align = RIGHT,
          font = SMLSIZE
        }
        cursorY = cursorY + Controls.SECTION_H
      end
    end
  end

  if ui.loading then
    local title = pageText(i18n, "loading_title", "Loading")
    local message = pageText(i18n, "loading_message", "Reading telemetry config")
    if LoadingOverlay then
      LoadingOverlay.append(children, {
        x = x,
        y = y,
        w = w,
        h = h,
        title = title,
        message = message,
        progress = ui.progress
      })
    end
  end
end

function M.onClose()
  if type(ui.runtime) == "table" then
    setmetatable(ui.runtime, nil)
  end
  if Common and Common.resetPageState then
    Common.resetPageState(ui, {
      tablesToWipe = { "runtime" }
    })
  else
    ui.loaded = false
    ui.dirty = false
  end
  ui.runtimeBase = nil
  -- The module stays cached after close, so a re-entry would otherwise open on the group
  -- that was open when the page was left.
  ui.group = nil
  ui.countText = ""
  ui.countOver = false
  ui.loading = false
  ui.progress = 0
  ui.crsfTelemetryMode = nil
  ui.serialrxProvider = nil
  ui.telemetryBuffer = nil
  ui.nativeLockedIds = {}
  Controls = nil
  Common = nil
  MspRuntime = nil
  TelemetryApi = nil
  SavePipeline = nil
  RxConfigApi = nil
  ConfirmDialog = nil
  LoadingOverlay = nil
  t = nil
end

-- Asked before the page is left (ui/home.lua): true while an edit here is not saved.
function M.hasUnsavedChanges()
  return ui.dirty == true
end

return M
