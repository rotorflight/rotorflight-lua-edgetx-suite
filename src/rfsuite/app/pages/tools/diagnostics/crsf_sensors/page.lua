-- Diagnostics: CRSF Sensors.
--
-- Read-only view of MSP2_GET_CRSF_SENSORS_STATUS: whether a serial port carries the CRSF Sensors
-- function, the port's receive counters, and the latest reading of each CRSF frame type the
-- flight controller decodes. It answers the wiring questions -- is the accessory heard at all, do
-- its frames arrive intact, what does it report -- so the counters have to move while the page is
-- open, and the page re-reads the status about once a second.
--
-- A moving value is not a rebuild. The value column is drawn through closures that return
-- strings formatted once per reply, so a reply repaints the numbers without rebuilding the page
-- (a rebuild would also throw the scroll position away). The page is rebuilt only when its SHAPE
-- changes: the port is enabled or not, a group starts or stops reporting, or the number of cells
-- or RPM values changes.

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

local Common = nil
local MspRuntime = nil
local StatusApi = nil
local t = nil

-- The Configurator polls the same message every 500 ms. Half that rate keeps a counter visibly
-- moving and costs the link half as many request/reply exchanges. The interval runs from one
-- request to the next, not from the reply: a reply takes a few tenths of a second over a CRSF
-- link, and counting from it would stretch every period by that much. One request is in flight
-- at a time, so a slower round trip than the interval simply sets the pace.
local POLL_INTERVAL_SEC = 1.0
-- One attempt per poll: the next poll is the retry, so a lost reply costs one interval rather
-- than the queue's whole retry ladder.
local POLL_TIMEOUT_SEC = 2.0

local ROW_H = 30

local state = {
  -- Raised on close. A reply or an error that arrives for a request made before it is ignored.
  generation = 0,
  i18n = nil,
  requestRebuild = nil,
  -- nil until the first answer, then "ok", "no_reply", "bad_reply" or "unsupported".
  status = nil,
  data = nil,
  -- The value column, formatted once per reply and read by the label closures.
  text = {},
  shape = "",
  builtShape = nil,
  pending = false,
  lastPollAt = 0,
  builtThisPass = false,
  pollDeferred = false,
}

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, value = pcall(getTime)
    if ok and type(value) == "number" then
      return value / 100
    end
  end
  return 0
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not StatusApi then StatusApi = loadModule("tasks/msp/api/crsf_sensors_status.lua") end
  if not t then t = Common and Common.pageT("diagnostics_crsf_sensors") or nil end
end

local function pageText(i18n, key, fallback)
  local obj = i18n or state.i18n
  if t then return t(obj, key, fallback) end
  return fallback
end

local function fixed(value, decimals)
  return string.format("%." .. tostring(decimals) .. "f", value)
end

local function volts(mv)
  return fixed(mv / 1000, 3) .. " V"
end

local function shapeOf(data, status)
  if status ~= "ok" or not data then
    return tostring(status)
  end
  return table.concat({
    data.enabled and "1" or "0",
    data.gps and "1" or "0",
    data.battery and "1" or "0",
    data.baro and "1" or "0",
    data.cells and tostring(data.cells.count) or "-",
    data.rpm and tostring(data.rpm.count) or "-",
  }, ":")
end

local function formatTexts(data)
  local i18n = state.i18n
  local text = state.text
  for k in pairs(text) do text[k] = nil end

  local receiving = pageText(i18n, "receiving", "Receiving")
  local noData = pageText(i18n, "no_data", "No data")

  text.link = data.enabled and pageText(i18n, "port_enabled", "Port enabled")
    or pageText(i18n, "port_disabled", "Port disabled")
  text.rx_bytes = tostring(data.rx_bytes)
  text.rx_sync = tostring(data.rx_sync)
  text.crc_ok = tostring(data.crc_ok)
  text.crc_fail = tostring(data.crc_fail)
  text.last_frame = string.format("0x%02X / %d", data.last_frame_type, data.last_frame_length)

  local gps = data.gps
  text.gps = gps and receiving or noData
  if gps then
    text.latitude = fixed(gps.latitude / 1e7, 6)
    text.longitude = fixed(gps.longitude / 1e7, 6)
    text.ground_speed = fixed(gps.groundspeed_cms / 100, 1) .. " m/s"
    text.heading = fixed(gps.heading_deg10 / 10, 1) .. "°"
    text.gps_altitude = fixed(gps.altitude_cm / 100, 1) .. " m"
    text.satellites = tostring(gps.satellites)
  end

  local battery = data.battery
  text.battery = battery and receiving or noData
  if battery then
    text.voltage = volts(battery.voltage_mv)
    text.current = fixed(battery.current_ma / 1000, 2) .. " A"
    text.capacity_used = tostring(battery.capacity_mah) .. " mAh"
    text.remaining = tostring(battery.remaining_pct) .. "%"
  end

  local baro = data.baro
  text.baro = baro and receiving or noData
  if baro then
    text.baro_altitude = fixed(baro.altitude_cm / 100, 1) .. " m"
    text.vertical_speed = fixed(baro.vertical_speed_cms / 100, 2) .. " m/s"
  end

  local cells = data.cells
  text.cells = cells and receiving or noData
  if cells then
    text.cell_count = tostring(cells.count)
    text.total_voltage = volts(cells.total_mv)
    for i = 1, cells.count do
      text["cell" .. i] = volts(cells.voltages_mv[i] or 0)
    end
  end

  local rpm = data.rpm
  text.rpm = rpm and receiving or noData
  if rpm then
    for i = 1, rpm.count do
      text["rpm" .. i] = tostring(rpm.values[i] or 0) .. " rpm"
    end
  end
end

local function applyAnswer(status, data)
  state.status = status
  state.data = data
  if data then
    formatTexts(data)
  end
  state.shape = shapeOf(data, status)
  if state.shape ~= state.builtShape and type(state.requestRebuild) == "function" then
    state.requestRebuild()
  end
end

local function requestStatus(now)
  state.lastPollAt = now
  local mspState = MspRuntime and type(MspRuntime.getState) == "function" and MspRuntime.getState() or nil
  local queue = mspState and mspState.queue
  if not (queue and StatusApi) then return end

  local generation = state.generation
  state.pending = true
  queue:add({
    command = StatusApi.command,
    simulatorResponse = StatusApi.simulatorResponse,
    maxRetries = 0,
    timeout = POLL_TIMEOUT_SEC,
    -- A firmware without this command answers it with the MSP error flag and a one-byte error
    -- code. That is an answer, not a lost reply, so it completes the request at once and reaches
    -- processReply below instead of waiting out the timeout. The menu entry is gated on the API
    -- version that introduced the command, but a build can report that version from before the
    -- command was added.
    completeOnErrorReplyAttempt = 1,
    processReply = function(_, buf)
      if generation ~= state.generation then return end
      state.pending = false
      -- The error reply of a firmware without the command is exactly one byte. Any other short
      -- reply is a damaged one: it is reported, and the next poll asks again.
      if type(buf) ~= "table" or #buf < 1 then
        applyAnswer("no_reply", nil)
        return
      elseif #buf < StatusApi.fixedLength then
        applyAnswer(#buf == 1 and "unsupported" or "bad_reply", nil)
        return
      elseif buf[1] ~= StatusApi.payloadVersion then
        -- A record in a layout this page does not know will not change on the next poll, so it is
        -- answered like the refusal: said once, and not asked again until Reload.
        applyAnswer("unsupported", nil)
        return
      end
      local parsed = StatusApi.parse(buf)
      if parsed then
        applyAnswer("ok", parsed)
      else
        applyAnswer("bad_reply", nil)
      end
    end,
    errorHandler = function()
      if generation ~= state.generation then return end
      state.pending = false
      applyAnswer("no_reply", nil)
    end,
  })
end

-- One row: a label on the left and a value on the right, the value drawn through a closure.
local function appendRow(children, x, y, w, label, key, emphasis)
  local labelW = math.floor(w * 0.5)
  local text = state.text
  children[#children + 1] = {
    type = "label", x = x, y = y + 4, w = labelW - 10,
    text = label,
    color = emphasis and Palette.accent or Palette.text,
    font = SMLSIZE
  }
  children[#children + 1] = {
    type = "label", x = x + labelW, y = y + 4, w = w - labelW - 6,
    text = function() return text[key] or "-" end,
    color = Palette.text, align = RIGHT, font = SMLSIZE
  }
  children[#children + 1] = {
    type = "rectangle", x = x, y = y + ROW_H - 2, w = w, h = 1,
    color = Palette.accent, filled = true
  }
  return ROW_H
end

local function appendNote(children, x, y, w, message)
  children[#children + 1] = {
    type = "label", x = x, y = y + 4, w = w,
    text = message,
    color = Palette.text, font = SMLSIZE
  }
  return ROW_H
end

function M.getHeaderActions()
  return { reload = true, save = false, help = true }
end

function M.isPageOpen()
  return true
end

function M.onReload()
  -- Re-read at once rather than at the end of the interval. A request still in flight is left to
  -- finish; its answer is as fresh as a new one would be.
  state.lastPollAt = 0
  return true
end

function M.build(ctx)
  ensureDeps()
  state.requestRebuild = ctx.requestRebuild
  state.i18n = ctx.i18n
  state.builtShape = state.shape
  state.builtThisPass = true

  local i18n = ctx.i18n
  local children = ctx.children
  local x = ctx.x
  local y = ctx.y + 4
  local w = ctx.w
  local data = state.data

  if state.status ~= "ok" or not data then
    local message
    if state.status == "no_reply" then
      message = pageText(i18n, "no_reply", "No reply from the flight controller")
    elseif state.status == "bad_reply" then
      message = pageText(i18n, "bad_reply", "The reply could not be read")
    elseif state.status == "unsupported" then
      message = pageText(i18n, "unsupported", "This firmware does not support the CRSF Sensors diagnostic.")
    else
      message = pageText(i18n, "waiting", "Waiting for the flight controller")
    end
    appendNote(children, x, y, w, message)
    return
  end

  y = y + appendRow(children, x, y, w, pageText(i18n, "link", "Link"), "link", true)
  if not data.enabled then
    y = y + appendNote(children, x, y, w,
      pageText(i18n, "port_not_configured", "No serial port has the CRSF Sensors function."))
  end
  y = y + appendRow(children, x, y, w, pageText(i18n, "rx_bytes", "RX bytes"), "rx_bytes")
  y = y + appendRow(children, x, y, w, pageText(i18n, "rx_sync", "RX sync bytes"), "rx_sync")
  y = y + appendRow(children, x, y, w, pageText(i18n, "crc_ok", "CRC OK frames"), "crc_ok")
  y = y + appendRow(children, x, y, w, pageText(i18n, "crc_fail", "CRC fail"), "crc_fail")
  y = y + appendRow(children, x, y, w, pageText(i18n, "last_frame", "Last frame type/len"), "last_frame")

  y = y + appendRow(children, x, y, w, pageText(i18n, "gps", "GPS"), "gps", true)
  if data.gps then
    y = y + appendRow(children, x, y, w, pageText(i18n, "latitude", "Latitude"), "latitude")
    y = y + appendRow(children, x, y, w, pageText(i18n, "longitude", "Longitude"), "longitude")
    y = y + appendRow(children, x, y, w, pageText(i18n, "ground_speed", "Ground speed"), "ground_speed")
    y = y + appendRow(children, x, y, w, pageText(i18n, "heading", "Heading"), "heading")
    y = y + appendRow(children, x, y, w, pageText(i18n, "altitude", "Altitude"), "gps_altitude")
    y = y + appendRow(children, x, y, w, pageText(i18n, "satellites", "Satellites"), "satellites")
  end

  y = y + appendRow(children, x, y, w, pageText(i18n, "battery", "Battery"), "battery", true)
  if data.battery then
    y = y + appendRow(children, x, y, w, pageText(i18n, "voltage", "Voltage"), "voltage")
    y = y + appendRow(children, x, y, w, pageText(i18n, "current", "Current"), "current")
    y = y + appendRow(children, x, y, w, pageText(i18n, "capacity_used", "Capacity used"), "capacity_used")
    y = y + appendRow(children, x, y, w, pageText(i18n, "remaining", "Remaining"), "remaining")
  end

  y = y + appendRow(children, x, y, w, pageText(i18n, "baro", "Barometer"), "baro", true)
  if data.baro then
    y = y + appendRow(children, x, y, w, pageText(i18n, "altitude", "Altitude"), "baro_altitude")
    y = y + appendRow(children, x, y, w, pageText(i18n, "vertical_speed", "Vertical speed"), "vertical_speed")
  end

  y = y + appendRow(children, x, y, w, pageText(i18n, "cells", "Cell Voltages"), "cells", true)
  if data.cells then
    y = y + appendRow(children, x, y, w, pageText(i18n, "cell_count", "Cell count"), "cell_count")
    y = y + appendRow(children, x, y, w, pageText(i18n, "total_voltage", "Total voltage"), "total_voltage")
    local cellFmt = pageText(i18n, "cell_fmt", "Cell %d")
    for i = 1, data.cells.count do
      y = y + appendRow(children, x, y, w, string.format(cellFmt, i), "cell" .. i)
    end
  end

  y = y + appendRow(children, x, y, w, pageText(i18n, "rpm", "RPM"), "rpm", true)
  if data.rpm then
    local rpmFmt = pageText(i18n, "rpm_fmt", "Source %d")
    for i = 1, data.rpm.count do
      y = y + appendRow(children, x, y, w, string.format(rpmFmt, i), "rpm" .. i)
    end
  end
end

function M.wakeup()
  -- The pass that built the page carries no poll: it is moved to the next pass, and only once in
  -- a row, so a page that rebuilds on consecutive passes still polls on the second of them.
  if state.builtThisPass then
    state.builtThisPass = false
    if not state.pollDeferred then
      state.pollDeferred = true
      return
    end
  end
  state.pollDeferred = false

  if state.pending then return end
  -- The firmware does not change while it is connected, so a firmware without the command is
  -- asked once per visit, and again only on Reload, which clears lastPollAt.
  if state.status == "unsupported" and state.lastPollAt > 0 then return end
  local now = nowSeconds()
  if state.lastPollAt > 0 and (now - state.lastPollAt) < POLL_INTERVAL_SEC then return end
  requestStatus(now)
end

function M.paint()
end

function M.handleEvent(eventData)
  return eventData
end

function M.closePage()
  state.generation = state.generation + 1
  state.i18n = nil
  state.requestRebuild = nil
  state.status = nil
  state.data = nil
  state.text = {}
  state.shape = ""
  state.builtShape = nil
  state.pending = false
  state.lastPollAt = 0
  state.builtThisPass = false
  state.pollDeferred = false
  Common = nil
  MspRuntime = nil
  StatusApi = nil
  t = nil
end

return M
