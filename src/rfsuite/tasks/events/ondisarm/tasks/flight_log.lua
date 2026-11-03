-- Writes the flight the arm edge opened.
--
-- Runs in the widget context, like the two ondisarm tasks beside it: the tool cannot be open
-- while the craft is armed, so a flight that lands is only ever seen by a widget.
--
-- The duration is the ARMED time -- the span between the two edges by getTime() -- and not the
-- time the rotor was turning. This suite has no rotor clock, and a second definition of "flight"
-- that nothing else here agrees with would be worse than the plainer one.

local M = {}

local done = false

local function loadModule(path)
  local fullPath = _G.rfsuite.paths.core .. "/" .. path
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(fullPath, mode)
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

-- The logger and the MSP runtime are one instance per Lua state. The runner drops this module when
-- its task completes and loads it again the next time the event fires, so a bare loadScript here
-- would read and compile those files again every time; lib/require.lua hands back the loaded one.
local function loadShared(path)
  local req = _G.rfsuite and _G.rfsuite.require
  if type(req) == "function" then return req(path) end
  return loadModule(path)
end

local function logLine(message, level)
  local Log = loadShared("lib/log.lua")
  if type(Log) == "table" and type(Log.emit) == "function" then
    pcall(Log.emit, "rfsuite.tasks.flight_log", message, level or "info")
  end
end

-- The widget runtimes publish the settings into the global table on every pass, so the file is
-- only read on a state that has not got round to it yet.
local function preferences()
  local root = _G and _G.rfsuite
  if type(root) == "table" and type(root.preferences) == "table" then
    return root.preferences
  end
  local Preferences = loadModule("lib/preferences.lua")
  if type(Preferences) == "table" and type(Preferences.load) == "function" then
    local ok, prefs = pcall(Preferences.load)
    if ok and type(prefs) == "table" then return prefs end
  end
  return nil
end

local function settings()
  local prefs = preferences()
  local section = type(prefs) == "table" and prefs.flightlog or nil
  local enabled = false
  local minSeconds = 30
  if type(section) == "table" then
    enabled = section.enabled == true
    local configured = tonumber(section.min_seconds)
    if configured ~= nil and configured >= 0 then minSeconds = configured end
  end
  return enabled, minSeconds
end

-- Which pack this flight belongs to.
--
-- The model's own store answers first, re-read here rather than taken from the copy the session
-- is carrying. The dashboard's pack picker (lib/battery_pick.lua, select) records the pick in
-- this session and the store. The standalone tool runs in another Lua state: its Flight Log
-- page moves the stored choice when a pack is renamed or deleted, and that reaches the store
-- and never this session. Reading it at the disarm edge costs nothing that the line about to be
-- appended does not cost anyway, and it is the same answer the arm edge would have given: the
-- page is locked while the craft is armed, so the choice cannot have moved since take-off.
--
-- A store that has recorded a choice answers for it, "no battery" included. The session's pick
-- is the answer only where the store has none: no board id to name it by, or no choice recorded
-- in it. A pick whose store write the card refused (select logs it) loses to the older choice the
-- store still holds.
local function resolveBattery(FlightLog, session, record)
  local ModelPreferences, store
  if session.mcu_id ~= nil then
    ModelPreferences = loadModule("lib/model_preferences.lua")
    if type(ModelPreferences) == "table" and type(ModelPreferences.loadByMcuId) == "function" then
      local ok, loaded = pcall(ModelPreferences.loadByMcuId, session.mcu_id, true)
      if ok and type(loaded) == "table" then store = loaded end
      local section = store and store.flightlog or nil
      if type(section) == "table" and section.battery ~= nil then
        return FlightLog.storedBatteryId(store), store, ModelPreferences
      end
    end
  end

  if type(record.batteryId) == "string" and record.batteryId ~= "" then
    return record.batteryId, store, ModelPreferences
  end

  return FlightLog.storedBatteryId(session.modelPreferences), store, ModelPreferences
end

local function clearBattery(FlightLog, session, record, staleId, store, ModelPreferences)
  if record.batteryId == staleId then record.batteryId = nil end
  if FlightLog.storedBatteryId(session.modelPreferences) == staleId then
    session.modelPreferences.flightlog.battery = ""
  end
  -- Without a link, the store is re-read and cleared at this board's next disarm with a link.
  if session.mcu_id == nil or FlightLog.storedBatteryId(store) ~= staleId then return end
  store.flightlog.battery = ""
  -- Follows the dashboard pack picker and model_name_sync's legacyClear store writes.
  if type(ModelPreferences) ~= "table" or type(ModelPreferences.saveByMcuId) ~= "function" then
    logLine("stale battery choice not cleared on card: model preferences unavailable", "warn")
    return
  end
  local ok, saved, reason = pcall(ModelPreferences.saveByMcuId, session.mcu_id, store)
  if not ok or saved ~= true then
    logLine("stale battery choice not cleared on card: "
      .. tostring((not ok) and saved or reason or "the card refused the write"), "warn")
  end
end

-- The flight record onto the log's statistics columns.
--
-- The record is closed by the first task of this manifest, which runs a wakeup before this one, so
-- `last` here is the flight that has just ended and `current` is already the empty one waiting for
-- the next arm. Reading `current` would log nothing.
--
-- A column the record did not take a value for is left out, and `statField` writes an empty field
-- for it. The header carries all 22 columns either way, so a partly filled row is a valid row
-- of the format rather than a new one.
--
-- Per-cell voltage needs a cell count. The flight record resolved one while the craft was armed
-- -- the flight controller's configured count, or the telemetry count where the board is set to
-- detect it (a configured 0) -- and closes the flight with it as `lastCells`, so nothing is read
-- again here. Where the record has none, the configuration the `battery_config` event task keeps
-- on the session answers, as before; where neither does, the two per-cell columns stay empty
-- rather than being divided by a guess.
--
-- `sags` is `0` rather than empty where the record could watch the pack and saw nothing, and
-- empty where it could not watch at all -- no cell count, or no minimum cell voltage from the
-- board -- and `sag_min` comes with it.
--
-- The per-profile headspeed columns are empty for a profile the flight was never flown on, and
-- for profiles 4 to 6, which the file format has no column for.
local function flightStats(session)
  local flight = type(session) == "table" and session.flight or nil
  local record = type(flight) == "table" and flight.last or nil
  if type(record) ~= "table" then return nil end

  local stats = {}
  local any = false
  local function put(column, value)
    if type(value) == "number" then
      stats[column] = value
      any = true
    end
  end

  put("mah", record.maxConsumedMah)
  put("curr_min", record.minCurrent)
  put("curr_max", record.maxCurrent)
  put("tesc_min", record.minEscTemp)
  put("tesc_max", record.maxEscTemp)
  put("vbec_min", record.minBecVoltage)
  put("vbec_max", record.maxBecVoltage)
  put("sags", record.sagCount)
  put("sag_min", record.minSagCellVoltage)
  put("hs1_min", record.minRpmP1)
  put("hs1_max", record.maxRpmP1)
  put("hs2_min", record.minRpmP2)
  put("hs2_max", record.maxRpmP2)
  put("hs3_min", record.minRpmP3)
  put("hs3_max", record.maxRpmP3)

  local cells = tonumber(flight.lastCells)
  if cells == nil or cells <= 0 then
    local config = session.batteryConfig or session.battery_config
    cells = type(config) == "table" and tonumber(config.batteryCellCount) or nil
  end
  if cells ~= nil and cells > 0 then
    if type(record.minVoltage) == "number" then put("vcel_min", record.minVoltage / cells) end
    if type(record.maxVoltage) == "number" then put("vcel_max", record.maxVoltage / cells) end
  end

  -- Nothing was recorded -- telemetry was gone for the whole armed window. `nil` rather than a
  -- table of nils, so the line stays the five-column form it has always been rather than becoming
  -- seventeen empty columns that say the same thing at more length.
  if not any then return nil end
  return stats
end

-- The data core names the step that refused, where it can tell one from another. Without a name
-- the line would read the same for a card that is full and for a card that will not say how large
-- a file on it is, and those need different things done about them.
local REFUSAL = {
  open = "the card did not open the log file",
  unmeasurable = "the card did not say how large the log file is",
  unverified = "the card did not confirm the line",
  unreadable = "the registry could not be read whole",
  toobig = "the registry is at or above the size that can be rewritten safely",
  noregistry = "the registry file is missing or empty",
  notfound = "the id is not in the registry"
}

local function refusal(reason, fallback)
  return REFUSAL[reason] or fallback
end

function M.wakeup()
  if done then return end
  done = true

  local root = _G and _G.rfsuite
  local session = type(root) == "table" and root.session or nil
  if type(session) ~= "table" then return end

  local record = session.flightlog
  if type(record) ~= "table" or record.open ~= true then return end
  record.open = false

  local seconds = nil
  if type(record.startTicks) == "number" and type(getTime) == "function" then
    local ok, ticks = pcall(getTime)
    if ok and type(ticks) == "number" and ticks >= record.startTicks then
      seconds = math.floor((ticks - record.startTicks) / 100 + 0.5)
    end
  end
  if seconds == nil or record.startDate == nil then return end

  local enabled, minSeconds = settings()
  if not enabled then return end

  -- An arm that never became a flight -- a spool-up check, an arming test -- reaches neither the
  -- log nor a battery's cycle count, so the two stay consistent with each other. A minimum of
  -- zero logs every arm.
  if seconds < minSeconds then
    logLine(string.format("flight of %ds is below the %ds minimum, not logged", seconds, minSeconds), "debug")
    return
  end

  local FlightLog = loadModule("lib/flight_log.lua")
  if type(FlightLog) ~= "table" then
    logLine("flight not logged: the data core did not load", "warn")
    return
  end

  local batteryId, store, ModelPreferences = resolveBattery(FlightLog, session, record)
  -- A link that dropped in flight -- for a second, long before the runtime holds it to be lost --
  -- leaves no board identity until the MSP runtime reads it again after this disarm, and so no
  -- store and no in-memory copy of it to ask. The pack the store held at the arm edge is then the
  -- answer: the choice cannot move while the craft is armed.
  if batteryId == nil and session.mcu_id == nil and type(record.batteryAtArm) == "string" then
    batteryId = record.batteryAtArm
  end

  local registryData
  if batteryId ~= nil then
    local data, readErr
    local okCheck, found = pcall(function()
      data, readErr = FlightLog.readRegistry()
      if readErr ~= nil then return nil end
      return FlightLog.hasBattery(data, batteryId)
    end)
    registryData = data
    if not okCheck then
      logLine("battery registry not checked: " .. tostring(found), "warn")
    else
      if readErr == nil and not found then
        local staleId = batteryId
        batteryId = nil
        logLine("battery " .. tostring(staleId) .. " left out of the flight's line: "
          .. (data == nil and "no registry file, or an empty one" or "no pack with this id in the registry"), "warn")
        local okClear, clearErr = pcall(clearBattery, FlightLog, session, record, staleId, store, ModelPreferences)
        if not okClear then
          logLine("stale battery choice not cleared: " .. tostring(clearErr), "warn")
        end
      end
    end
  end

  local ok, written, reason = pcall(FlightLog.appendFlight, record.startDate, record.model or "",
    batteryId or "", seconds, flightStats(session))
  if not ok or written ~= true then
    -- The append verifies by the bytes the file grew, so this is a line that did not land -- a
    -- full or a missing card, or one that will not say how large a file on it is. Said out loud,
    -- because the gap it leaves explains nothing.
    logLine("flight NOT logged: " .. ((not ok) and tostring(written) or refusal(reason, "the card did not take the line")), "warn")
  else
    logLine(string.format("flight logged: %ds, battery=%s", seconds, tostring(batteryId or "-")), "info")
  end

  -- One count per pack per connection, on the first flight that was long enough to be one.
  -- Choosing a pack is not using it, and a second flight on the same charge is not a second
  -- cycle. The id is remembered rather than a flag, so swapping to another pack counts again.
  if batteryId ~= nil and record.countedFor ~= batteryId then
    record.countedFor = batteryId
    local okMark, marked, markReason = pcall(FlightLog.markUsed, batteryId, record.startDate, registryData)
    if not okMark or marked ~= true then
      logLine("battery cycle not counted for " .. tostring(batteryId) .. ": "
        .. ((not okMark) and tostring(marked) or refusal(markReason, "registry unchanged or the replace failed")), "warn")
    end
  end

  if type(collectgarbage) == "function" then
    collectgarbage("collect")
  end
end

function M.isComplete()
  return done
end

function M.reset()
  done = false
end

return M
