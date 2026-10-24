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
local SerialConfigApi = nil
local BoardInfoApi = nil
local PortLabels = nil
local ApiVersion = nil
local LoadingOverlay = nil
local t = nil
local portFunctions = nil
local portFunctionsById = nil
local availableFunctions = nil
local availableFunctionsKey = nil

local PORT_TYPE_DISABLED = 0
local PORT_TYPE_MSP = 1
local PORT_TYPE_GPS = 2
local PORT_TYPE_TELEM = 3
local PORT_TYPE_MAVLINK = 4
local PORT_TYPE_BLACKBOX = 5
local PORT_TYPE_CUSTOM = 6
local PORT_TYPE_AUTO = 7

local FUNCTION_MASK_RX_SERIAL = 64

local BAUD_RATES = {
  "AUTO", "9600", "19200", "38400", "57600", "115200", "230400", "250000",
  "400000", "460800", "500000", "921600", "1000000", "1500000", "2000000", "2470000"
}

local BAUD_OPTIONS = {
  [PORT_TYPE_DISABLED] = {0},
  [PORT_TYPE_MSP] = {1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 12},
  [PORT_TYPE_GPS] = {0, 1, 2, 3, 4, 5, 6, 9},
  [PORT_TYPE_TELEM] = {0},
  [PORT_TYPE_MAVLINK] = {0, 1, 2, 3, 4, 5, 6, 9},
  [PORT_TYPE_BLACKBOX] = {0, 2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15},
  [PORT_TYPE_CUSTOM] = {0},
  [PORT_TYPE_AUTO] = {0}
}

local UART_NAMES = {
  [0] = "UART1",
  [1] = "UART2",
  [2] = "UART3",
  [3] = "UART4",
  [4] = "UART5",
  [5] = "UART6",
  [6] = "UART7",
  [7] = "UART8",
  [8] = "UART9",
  [9] = "UART10",
  [20] = "USB VCP",
  [30] = "SOFTSERIAL1",
  [31] = "SOFTSERIAL2",
  [40] = "LPUART1"
}

local function newRuntime()
  return {
    readPending = false,
    requestRebuild = nil,
    lastSessionSignature = nil
  }
end

local ui = {
  loaded = false,
  dirty = false,
  portsOriginal = {},
  portsWorking = {},
  boardDesign = nil,
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
  if not SerialConfigApi then SerialConfigApi = loadModule("tasks/msp/api/serial_config.lua") end
  if not BoardInfoApi then BoardInfoApi = loadModule("tasks/msp/api/board_info.lua") end
  if not PortLabels then PortLabels = loadModule("lib/port_labels.lua") end
  if not ApiVersion then ApiVersion = loadModule("lib/api_version.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not t then t = Common and Common.pageT("setup_ports") or nil end

  if type(ui.runtime) ~= "table" then
    ui.runtime = newRuntime()
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

-- The function list never changes while the page is open, and every lookup below goes through
-- it: one build of an N-port page asked for it N + 3 times per port (N + 2 for a disabled one).
-- So it is built on the first call and kept in portFunctions until onClose drops it, which is also
-- what lets a reopened page resolve the names again with the i18n it is opened with.
local function getPortFunctionsList(i18n)
  if portFunctions then return portFunctions end
  portFunctions = {
    {id = 0, excl = 0, name = pageText(i18n, "function_disabled", "Disabled"), type = PORT_TYPE_DISABLED},
    {id = 1, excl = 1, name = "MSP", type = PORT_TYPE_MSP},
    {id = 2, excl = 2, name = "GPS", type = PORT_TYPE_GPS},
    {id = 64, excl = 64, name = pageText(i18n, "function_rx_serial", "RX Serial"), type = PORT_TYPE_AUTO},
    {id = 1024, excl = 1024, name = pageText(i18n, "function_esc_sensor", "ESC Sensor"), type = PORT_TYPE_AUTO},
    {id = 128, excl = 128, name = pageText(i18n, "function_blackbox", "Blackbox"), type = PORT_TYPE_BLACKBOX},
    {id = 262144, excl = 262144, name = pageText(i18n, "function_sbus_out", "SBus Out"), type = PORT_TYPE_AUTO, minApi = {12, 0, 7}},
    {id = 524288, excl = 524288, name = pageText(i18n, "function_fbus_out", "FBus Out"), type = PORT_TYPE_AUTO, minApi = {12, 0, 9}},
    {id = 1048576, excl = 1048576, name = pageText(i18n, "function_sport_input", "S.PORT Master"), type = PORT_TYPE_AUTO, minApi = {12, 0, 9}},
    {id = 2097152, excl = 2097152, name = pageText(i18n, "function_srxl2_esc", "SRXL2 ESC"), type = PORT_TYPE_AUTO, minApi = {12, 0, 10}},
    {id = 4194304, excl = 4194304, name = pageText(i18n, "function_crsf_sensors", "CRSF Sensors"), type = PORT_TYPE_AUTO, minApi = {12, 0, 10}},
    {id = 4, excl = 4668, name = pageText(i18n, "function_telem_frsky", "Telemetry FrSky"), type = PORT_TYPE_TELEM},
    {id = 32, excl = 4668, name = pageText(i18n, "function_telem_smartport", "Telemetry SmartPort"), type = PORT_TYPE_TELEM},
    {id = 4096, excl = 4668, name = pageText(i18n, "function_telem_ibus", "Telemetry iBus"), type = PORT_TYPE_TELEM},
    {id = 8, excl = 4668, name = pageText(i18n, "function_telem_hott", "Telemetry HoTT"), type = PORT_TYPE_TELEM},
    {id = 512, excl = 4668, name = pageText(i18n, "function_telem_mavlink", "Telemetry MAVLink"), type = PORT_TYPE_MAVLINK},
    {id = 16, excl = 4668, name = pageText(i18n, "function_telem_ltm", "Telemetry LTM"), type = PORT_TYPE_TELEM}
  }
  portFunctionsById = {}
  for i = 1, #portFunctions do
    portFunctionsById[portFunctions[i].id] = portFunctions[i]
  end
  return portFunctions
end

local function getPortFunctionById(i18n, functionMask)
  getPortFunctionsList(i18n)
  return portFunctionsById[functionMask]
end

local function getPortType(i18n, functionMask)
  local f = getPortFunctionById(i18n, functionMask)
  if f then return f.type end
  return PORT_TYPE_CUSTOM
end

local function getPortExcl(i18n, functionMask)
  local f = getPortFunctionById(i18n, functionMask)
  if f then return f.excl end
  return functionMask
end

local function functionAvailable(def)
  local session = getSession()
  local rawApiVersion = session and session.apiVersion
  if not rawApiVersion then return true end

  if def.minApi and ApiVersion and type(ApiVersion.isAtLeast) == "function" then
    if not ApiVersion.isAtLeast(rawApiVersion, def.minApi) then return false end
  end
  if def.maxApi and ApiVersion and type(ApiVersion.isAtLeast) == "function" then
    if ApiVersion.isAtLeast(rawApiVersion, def.maxApi) and not (rawApiVersion == def.maxApi or (type(rawApiVersion) == "table" and rawApiVersion[1] == def.maxApi[1] and rawApiVersion[2] == def.maxApi[2] and rawApiVersion[3] == def.maxApi[3])) then
      return false
    end
  end
  return true
end

local function apiVersionKey(raw)
  if type(raw) == "table" then
    return tostring(raw[1]) .. "." .. tostring(raw[2]) .. "." .. tostring(raw[3])
  end
  return tostring(raw)
end

-- The functions this flight controller's API version offers. Which of them are available
-- depends on the version alone, so the list is filtered once and reused by every row, rather
-- than every row asking the version about every function. It is filtered again if the version
-- it was made for changes, because a page opened before the version is known offers everything.
local function getAvailableFunctions(i18n)
  local session = getSession()
  local key = apiVersionKey(session and session.apiVersion)
  if availableFunctions and availableFunctionsKey == key then return availableFunctions end
  local list = getPortFunctionsList(i18n)
  availableFunctions = {}
  for i = 1, #list do
    if functionAvailable(list[i]) then
      availableFunctions[#availableFunctions + 1] = list[i]
    end
  end
  availableFunctionsKey = key
  return availableFunctions
end

local function getActiveBaudIndex(i18n, port)
  local ptype = getPortType(i18n, port.function_mask)
  if ptype == PORT_TYPE_MSP then return port.msp_baud_index end
  if ptype == PORT_TYPE_GPS then return port.gps_baud_index end
  if ptype == PORT_TYPE_BLACKBOX then return port.blackbox_baud_index end
  if ptype == PORT_TYPE_MAVLINK then return port.telem_baud_index end
  if ptype == PORT_TYPE_CUSTOM then return port.msp_baud_index end
  return 0
end

local function setActiveBaudIndex(i18n, port, baudIndex)
  local ptype = getPortType(i18n, port.function_mask)
  if ptype == PORT_TYPE_MSP then
    port.msp_baud_index = baudIndex
  elseif ptype == PORT_TYPE_GPS then
    port.gps_baud_index = baudIndex
  elseif ptype == PORT_TYPE_BLACKBOX then
    port.blackbox_baud_index = baudIndex
  elseif ptype == PORT_TYPE_MAVLINK then
    port.telem_baud_index = baudIndex
  elseif ptype == PORT_TYPE_CUSTOM then
    port.msp_baud_index = baudIndex
  end
end

local function buildBaudChoiceTable(i18n, port)
  local ptype = getPortType(i18n, port.function_mask)
  if ptype == PORT_TYPE_DISABLED then
    return { {pageText(i18n, "function_disabled", "Disabled"), 0} }
  end
  local allowed = BAUD_OPTIONS[ptype] or BAUD_OPTIONS[PORT_TYPE_AUTO]
  local current = getActiveBaudIndex(i18n, port)
  local present = {}
  local tableData = {}

  for i = 1, #allowed do
    local idx = allowed[i]
    if BAUD_RATES[idx + 1] then
      tableData[#tableData + 1] = {BAUD_RATES[idx + 1], idx}
      present[idx] = true
    end
  end

  if BAUD_RATES[current + 1] and not present[current] then
    tableData[#tableData + 1] = {BAUD_RATES[current + 1], current}
  end

  return tableData
end

-- For each port, the functions the OTHER ports hold exclusively. Asked once per build: each
-- port's exclusivity mask is looked up once, and a row combines the others' masks.
local function getForbiddenMasks(i18n)
  local excls = {}
  local count = #ui.portsWorking
  for i = 1, count do
    excls[i] = getPortExcl(i18n, ui.portsWorking[i].function_mask)
  end
  local forbidden = {}
  for i = 1, count do
    local mask = 0
    for j = 1, count do
      if j ~= i then mask = mask | excls[j] end
    end
    forbidden[i] = mask
  end
  return forbidden
end

local function buildFunctionChoiceTable(i18n, portIndex, forbidden)
  local port = ui.portsWorking[portIndex]
  if not port then return {} end

  local tableData = {}
  local seen = {}
  local list = getAvailableFunctions(i18n)

  for i = 1, #list do
    local def = list[i]
    local allowed = ((def.id & forbidden) == 0)
    if allowed or def.id == port.function_mask then
      tableData[#tableData + 1] = {def.name, def.id}
      seen[def.id] = true
    end
  end

  if not seen[port.function_mask] then
    tableData[#tableData + 1] = {pageText(i18n, "function_custom", "Custom") .. " (" .. tostring(port.function_mask) .. ")", port.function_mask}
  end

  return tableData
end

local function shallowCopy(tbl)
  local out = {}
  for k, v in pairs(tbl) do out[k] = v end
  return out
end

local function clonePorts(ports)
  local out = {}
  for i = 1, #ports do out[i] = shallowCopy(ports[i]) end
  return out
end

local function applyReceiverGuardToWorkingCopy()
  for i = 1, #ui.portsWorking do
    if ui.portsWorking[i].receiver_locked then
      ui.portsWorking[i] = shallowCopy(ui.portsOriginal[i])
    end
  end
end

-- What a row is called.
--
-- The identifier the firmware reports is a UART number, and that is not what is written beside
-- the socket: the board says "Port A" or "S.BUS", and which UART that is depends on the board.
-- MSP_BOARD_INFO reports a board design, and the design is the key to the printed names, so a
-- row carries both -- the label the pilot can find on the machine in front of him, and the UART
-- name the firmware's CLI and the documentation use for the same socket.
--
-- The pairing is the Configurator's, which draws exactly this on its own Ports tab and falls
-- back to the bare UART name for a design it has no map for
-- (rotorflight-configurator src/js/tabs/configuration.js:475-481). A board outside those designs
-- is the normal case rather than an error, and it looks exactly as this page always has.
local function portLabel(identifier)
  local name = UART_NAMES[identifier]
  if not name then
    return pageText(nil, "port_prefix", "Port") .. " " .. tostring(identifier)
  end
  local printed = PortLabels and PortLabels.label(ui.boardDesign, identifier)
  if not printed then return name end
  return printed .. " [" .. name .. "]"
end

local function loadFromSession()
  local session = getSession()
  if not session or type(session.setup_ports) ~= "table" then return end
  local saved = session.setup_ports
  if type(saved.ports) == "table" then
    ui.portsOriginal = clonePorts(saved.ports)
    ui.portsWorking = clonePorts(saved.ports)
  end
  ui.boardDesign = saved.boardDesign
end

local function saveToSession()
  local session = getSession()
  if not session then return end
  if type(session.setup_ports) ~= "table" then
    session.setup_ports = {}
  end
  session.setup_ports.ports = clonePorts(ui.portsWorking)
  session.setup_ports.boardDesign = ui.boardDesign
end

local function queuePortsRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  if not MspRuntime or not SerialConfigApi or type(MspRuntime.getState) ~= "function" then
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

  local function finishRead()
    ui.runtime.readPending = false
    ui.loading = false
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  -- The second and last read, queued once the one below has answered: MSP_BOARD_INFO, which is
  -- what tells this page which board it is talking to and so what that board calls its sockets.
  --
  -- A failure here ends the read the same way a success does. A board that does not answer the
  -- command, or answers with a design nothing is known about, leaves every row with its plain
  -- UART name -- which is what this page showed before it asked at all, and is not a reason to
  -- withhold the port configuration the read before it already has.
  local function queueBoardInfoRead()
    if not BoardInfoApi then
      ui.progress = 100
      finishRead()
      return
    end

    queue:add({
      command = BoardInfoApi.command,
      simulatorResponse = BoardInfoApi.simulatorResponse,
      processReply = function(self, buf)
        local parsed = BoardInfoApi.parse(buf)
        ui.boardDesign = parsed and parsed.board_design or nil
        saveToSession()
        ui.progress = 100
        finishRead()
      end,
      errorHandler = function()
        ui.boardDesign = nil
        saveToSession()
        ui.progress = 100
        finishRead()
      end
    })
  end

  -- Step 1: Read SERIAL_CONFIG
  queue:add({
    command = SerialConfigApi.command,
    simulatorResponse = SerialConfigApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = SerialConfigApi.parse(buf)
      if parsed then
        local ports = {}
        local maxPorts = 12
        for i = 1, maxPorts do
          local identifier = parsed["port_" .. i .. "_identifier"]
          if identifier == nil then break end
          if identifier ~= 20 then -- Skip VCP
            local functionMask = parsed["port_" .. i .. "_function_mask"] or 0
            local port = {
              identifier = identifier,
              function_mask = functionMask,
              msp_baud_index = parsed["port_" .. i .. "_msp_baud_index"] or 0,
              gps_baud_index = parsed["port_" .. i .. "_gps_baud_index"] or 0,
              telem_baud_index = parsed["port_" .. i .. "_telem_baud_index"] or 0,
              blackbox_baud_index = parsed["port_" .. i .. "_blackbox_baud_index"] or 0,
              receiver_locked = (functionMask & FUNCTION_MASK_RX_SERIAL) ~= 0
            }
            ports[#ports + 1] = port
          end
        end
        ui.portsOriginal = clonePorts(ports)
        ui.portsWorking = clonePorts(ports)
        saveToSession()
      end

      ui.dirty = false
      ui.progress = 50
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end

      queueBoardInfoRead()
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

-- Has this port's record moved since it was read? The write replaces the whole record, so every
-- field the record carries is compared, not only the function.
local function portChanged(i)
  local working, original = ui.portsWorking[i], ui.portsOriginal[i]
  if not original or original.identifier ~= working.identifier then return true end
  return working.function_mask ~= original.function_mask
    or working.msp_baud_index ~= original.msp_baud_index
    or working.gps_baud_index ~= original.gps_baud_index
    or working.telem_baud_index ~= original.telem_baud_index
    or working.blackbox_baud_index ~= original.blackbox_baud_index
end

local function queuePortsWrite()
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or not SerialConfigApi then
    return false, "msp_runtime_unavailable"
  end

  applyReceiverGuardToWorkingCopy()

  -- One write per port that changed, in the page's order. MSP_SET_SERIAL_CONFIG stores each
  -- record into the port its identifier names and checks nothing until the EEPROM write, so
  -- rewriting a port with the values it already holds changes nothing on the board: leaving it out
  -- reaches the same configuration with fewer writes. A save with nothing changed still stores and
  -- restarts, as it always has.
  local steps = {}
  for i = 1, #ui.portsWorking do
    if portChanged(i) then
      steps[#steps + 1] = {
        label = "MSP_SET_CF_SERIAL_CONFIG",
        command = SerialConfigApi.writeCommand,
        payload = SerialConfigApi.buildWritePayload(ui.portsWorking[i])
      }
    end
  end

  -- Behaviour change worth naming: a port write that failed used to run an errorHandler whose
  -- comment says it proceeds to the next port and whose body is empty, so the chain simply
  -- stopped -- no further port, no EEPROM commit, no reboot and nothing on screen. The pipeline
  -- ends the save on a failed step and says which one.
  return SavePipeline.start({
    pageId = "setup_ports",
    steps = steps,
    reboot = true,
    invalidateSessionKeys = { "setup_ports" },
    onSaved = function()
      ui.dirty = false
    end,
    onDone = function(result)
      if result.status ~= "done" then
        ui.dirty = true
      elseif ui.loaded and type(ui.runtime) == "table" then
        -- The board has restarted and answers again, so what the rows show next is read from it
        -- rather than kept from before the save: a port the firmware refused, or a configuration
        -- it reset at the EEPROM write, then shows as the board holds it. A page closed before
        -- the save finished reads the ports when it is opened again instead.
        -- Read as an automatic reload: the rows stay on screen and are replaced when the board
        -- answers, instead of giving way to the loading screen once the save notice clears.
        queuePortsRead(true)
      end
      if ui.runtime and type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })
end

local function buildSessionSignature()
  return "1"
end

local function getBaseTitle()
  return pageText(nil, "title", "Ports")
end

local function ensureLoaded()
  if ui.loaded then return end
  -- A save whose overlay was dismissed finished without a screen. Its outcome was held back
  -- rather than raised over whatever page the user went to; claim it now that this one is open.
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if SavePipeline and type(SavePipeline.takeResult) == "function" then
    SavePipeline.takeResult("setup_ports")
  end
  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()
  ui.baseTitle = getBaseTitle()
  queuePortsRead(false)
end

local function appendPortRow(children, x, y, w, lineTitle, port, portIndex, i18n, forbidden)
  local rowH = (Controls and Controls.ROW_H) or 64
  local labelY = (Controls and Controls.labelY and Controls.labelY(y, rowH)) or (y + math.floor((rowH - 21) / 2))
  local comboY = (Controls and Controls.controlY and Controls.controlY(y, rowH)) or (y + math.floor((rowH - 32) / 2))
  local dividerY = y + rowH

  local gap = 6
  local rightPadding = 10

  local wBaud = math.floor(w * 0.28)
  local wFunc = math.floor(w * 0.42)

  local xBaud = x + w - wBaud - rightPadding
  local xFunc = xBaud - wFunc - gap

  -- Port name label
  children[#children + 1] = {
    type  = "label",
    x = x, y = labelY,
    w = xFunc - x - 8,
    text  = lineTitle,
    color = Palette.text,
    font  = SMLSIZE
  }

  -- Build choice labels/values for function select
  local functionChoices = buildFunctionChoiceTable(i18n, portIndex, forbidden)
  local functionFieldValues = {}
  local selectedFunctionIndex = 1
  for idx, opt in ipairs(functionChoices) do
    functionFieldValues[idx] = tostring(opt[1])
    if opt[2] == port.function_mask then
      selectedFunctionIndex = idx
    end
  end
  if #functionFieldValues == 0 then
    functionFieldValues[1] = ""
    selectedFunctionIndex = 1
  end

  -- Function choice dropdown select
  children[#children + 1] = {
    type  = "choice",
    x = xFunc, y = comboY,
    w = wFunc,
    title = lineTitle,
    values = functionFieldValues,
    active = function() return not port.receiver_locked end,
    get = function()
      return selectedFunctionIndex
    end,
    set = function(nextIndex)
      if port.receiver_locked then return end
      local idx = tonumber(nextIndex) or selectedFunctionIndex
      if idx < 1 then idx = 1 end
      if idx > #functionChoices then idx = #functionChoices end
      selectedFunctionIndex = idx

      local opt = functionChoices[idx]
      local value = opt and opt[2]
      if value and value ~= port.function_mask then
        port.function_mask = value

        -- Update baud rate if not allowed
        local baudChoices = buildBaudChoiceTable(i18n, port)
        local currentBaud = getActiveBaudIndex(i18n, port)
        local currentStillAllowed = false
        for b = 1, #baudChoices do
          if baudChoices[b][2] == currentBaud then
            currentStillAllowed = true
            break
          end
        end
        if not currentStillAllowed and #baudChoices > 0 then
          setActiveBaudIndex(i18n, port, baudChoices[1][2])
        end

        ui.dirty = true
        if type(ui.runtime.requestRebuild) == "function" then
          ui.runtime.requestRebuild()
        end
      end
    end
  }

  -- Build baud rate choices
  local baudChoices = buildBaudChoiceTable(i18n, port)
  local ptype = getPortType(i18n, port.function_mask)
  local baudFieldValues = {}
  local selectedBaudIndex = 1
  local currentBaud = getActiveBaudIndex(i18n, port)
  for idx, opt in ipairs(baudChoices) do
    baudFieldValues[idx] = tostring(opt[1])
    if opt[2] == currentBaud then
      selectedBaudIndex = idx
    end
  end
  if #baudFieldValues == 0 then
    baudFieldValues[1] = ""
    selectedBaudIndex = 1
  end

  -- A rate is only a control where the function offers more than one. A disabled port has no
  -- rate at all, and a function fixed at one rate (AUTO for the receiver, the ESC sensor and most
  -- telemetry) shows that rate as text: a list with a single entry is a control with nothing to
  -- choose, and it was built for every such row on every build.
  if ptype == PORT_TYPE_DISABLED then
    baudChoices = nil
  elseif #baudChoices <= 1 then
    children[#children + 1] = {
      type  = "label",
      x = xBaud + 8, y = labelY,
      w = wBaud - 8,
      text  = baudFieldValues[1],
      color = Palette.text
    }
    baudChoices = nil
  end

  -- Baud rate choice dropdown select
  if baudChoices then
    children[#children + 1] = {
      type  = "choice",
      x = xBaud, y = comboY,
      w = wBaud,
      title = lineTitle,
      values = baudFieldValues,
      active = function() return not port.receiver_locked end,
      get = function()
        return selectedBaudIndex
      end,
      set = function(nextIndex)
        if port.receiver_locked then return end
        local idx = tonumber(nextIndex) or selectedBaudIndex
        if idx < 1 then idx = 1 end
        if idx > #baudChoices then idx = #baudChoices end
        selectedBaudIndex = idx

        local opt = baudChoices[idx]
        local value = opt and opt[2]
        if value and value ~= getActiveBaudIndex(i18n, port) then
          setActiveBaudIndex(i18n, port, value)
          ui.dirty = true
        end
      end
    }
  end

  -- Divider line
  children[#children + 1] = {
    type   = "rectangle",
    x = x, y = dividerY,
    w = w, h = 1,
    color  = Palette.border, filled = true
  }

  return rowH + 1
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
    queuePortsRead(false)
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
      title = pageText(i18n, "loading_title", "Loading"),
      message = pageText(i18n, "loading", "Loading serial ports..."),
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or getBaseTitle()

  if type(ui.runtime) == "table" and type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(displayTitle, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, displayTitle)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  cursorY = cursorY + 10

  if #ui.portsWorking == 0 then
    children[#children + 1] = {
      type  = "label",
      x = x + 10, y = cursorY + 10,
      w = w - 20,
      text  = pageText(i18n, "no_ports_reported", "No serial ports reported by FC."),
      color = Palette.text,
      font  = SMLSIZE
    }
    return
  end

  local forbidden = getForbiddenMasks(i18n)
  for i = 1, #ui.portsWorking do
    local port = ui.portsWorking[i]
    local lineTitle = portLabel(port.identifier)
    if port.receiver_locked then
      lineTitle = lineTitle .. " " .. pageText(i18n, "rx_tag", "[RX]")
    end

    cursorY = cursorY + appendPortRow(children, x, cursorY, w, lineTitle, port, i, i18n, forbidden[i])
  end
end

function M.onSave(ctx)
  local ok, err = queuePortsWrite()
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
    loadFromSession()
    ui.dirty = false
    queuePortsRead(false)
  end
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/ports/help.lua")
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
  SerialConfigApi = nil
  BoardInfoApi = nil
  PortLabels = nil
  ApiVersion = nil
  LoadingOverlay = nil
  t = nil
  portFunctions = nil
  portFunctionsById = nil
  availableFunctions = nil
  availableFunctionsKey = nil
end

-- Asked before the page is left (ui/home.lua): true while an edit here is not saved.
function M.hasUnsavedChanges()
  return ui.dirty == true
end

return M
