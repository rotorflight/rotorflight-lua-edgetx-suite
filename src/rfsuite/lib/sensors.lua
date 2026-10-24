--[[
  Central sensor definition for RFSuite dashboard
  Based on RF2 telemetry sensor schema (4-character names)
  Provides unified mapping for simulator and hardware
]]--

local Sensors = {}
Sensors.sim_search_misses = {}
-- The logging core's tagged emitter, bound on first use. It cannot be bound at module scope:
-- this file is reached from contexts where lib/log.lua has not published itself yet, which is
-- what the raw loadScript that stood here was working around -- at the cost of going past
-- lib/require.lua's cache and compiling a second copy of the logger for every load of this
-- module, in "t" mode rather than the loader's own.
local taggedLog = nil

local SIM_FILE_ALIASES = {
  ["PID#"] = "pid_profile",
  ["RTE#"] = "rate_profile",
  ["BatP"] = "battery_profile",
  ["Bat%"] = "fuel",
  ["SmFt"] = "smartfuel",
  ["SmCp"] = "smartconsumption",
  ["RQly"] = "link",
  ["Vbat"] = "voltage",
  ["Vbec"] = "bec_voltage",
  ["BecV"] = "bec_voltage",
  ["Hspd"] = "rpm",
  ["EscT"] = "temp_esc",
  ["Tesc"] = "temp_esc",
  ["TescT"] = "temp_esc",
  ["TmcuT"] = "temp_mcu",
  ["Thr%"] = "throttle_percent",
  ["Thr"] = "throttle_percent",
  ["Cel#"] = "cell_count",
  ["Alt"] = "altitude",
  ["voltage"] = "voltage",
  ["fuel"] = "fuel",
  ["rpm"] = "rpm",
}

local debugEnabled = nil

-- This flag was declared false with nothing anywhere in the tree assigning it, so every call
-- site behind it was unreachable -- including the ones that say WHY a sensor did not resolve,
-- which is what a report about a missing telemetry value needs. The suite's own log level
-- decides now, so the diagnostics appear when a pilot raises it and stay silent otherwise.
--
-- Resolved ONCE rather than per call, and that is a budget decision rather than a style one.
-- These call sites sit on the sensor read path, which runs inside the widget's state pass;
-- asking `Log.wanted` each time walks the preference table and lowercases a string per sensor
-- per pass, and that showed up as ~950 instructions on `pass.state` -- over its budget on its
-- own. The cost of resolving once is that raising the log level takes effect when the module is
-- next loaded rather than immediately, which is the right trade for a diagnostic that a pilot
-- turns on deliberately and then goes flying with.
local function debugWanted()
  if debugEnabled == nil then
    local L = type(_G) == "table" and _G.rfsuite and _G.rfsuite.Log
    if type(L) ~= "table" or type(L.wanted) ~= "function" then return false end
    debugEnabled = L.wanted("debug") == true
  end
  return debugEnabled
end

local loggedSimulatorState = false
local loggedSources = {}
local simValueCache = {}
local SIM_SOURCE_RELOAD_SECONDS = 0.5

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, v = pcall(getTime)
    if ok and type(v) == "number" then
      return v / 100
    end
  end
  if os and type(os.clock) == "function" then
    return os.clock()
  end
  return 0
end

local function debugLog(key, msg)
  if not debugWanted() then return end
  if key and loggedSources[key] then return end
  if key then loggedSources[key] = true end
  if not taggedLog then
    local L = type(_G) == "table" and _G.rfsuite and _G.rfsuite.Log
    if type(L) ~= "table" or type(L.tagged) ~= "function" then return end
    taggedLog = L.tagged("rfsuite.sensors")
  end
  taggedLog(tostring(msg), "debug")
end

local fieldInfoCache = {}
local valueMisses = {}

-- A label is not unique in a model's sensor table, and EdgeTX answers a label with the FIRST slot
-- that carries it (luaFindFieldByName, radio/src/lua/api_general.cpp). The case that happens: the
-- native CRSF battery frame creates RxBt, Curr, Capa and Bat%, and a model whose sensors were
-- discovered while the flight controller was still on native telemetry keeps those four after it
-- is switched to custom telemetry -- ahead of the Rotorflight rows of the same names. Read by
-- label, Curr, Capa and Bat% are then the native rows: nothing at all if they were never received
-- in this session, their last value, frozen, if they were.
--
-- So a label the model carries in more than one slot is read from the slot the radio is receiving:
-- the first, in slot order, that getSourceValue() reports with a value and as current; failing
-- that, the first with any value; failing that, the label as before. The slot is named "telemN",
-- which EdgeTX resolves to slot N like a label, with "+" and "-" for the extremes
-- (luaMultipleFields, same file). The choice is made on every read, so it follows the radio: a
-- native row still counted as current -- the radio keeps that up to 20 s after its last value --
-- gives way to the other once it is no longer, without waiting for a reset.
--
-- Finding the slots means walking the sensor table with model.getSensor(), one table per slot. It
-- is done only on a model that carries RxBt: the radio's own receiver-battery sensor, which the
-- native frames create alongside the other three and the suite never does, so a model without it
-- cannot have the native rows and pays one getFieldInfo() per reset. On a model with it the walk
-- runs SLOT_WALK_DELAY_SECONDS after the first read following a reset, which is the connect pass,
-- and again where a sensor has appeared since (see rewalkIfTableGrew). Until the first walk every
-- label is read as before.
local NATIVE_MARKER = "RxBt"
local SLOT_WALK_DELAY_SECONDS = 2.0
-- nil: not looked at since the reset; false: no duplicate labels possible on this model; a table:
-- name -> { "telemN", ... } in slot order, for every label in two or more slots and its "+"/"-".
local duplicateNames = nil
local firstEmptySlot = nil   -- where EdgeTX puts the next new sensor, as of the walk
local slotWalkAt = nil

local function walkSlots()
  local getSensor = type(model) == "table" and model.getSensor or nil
  if type(getSensor) ~= "function" then
    duplicateNames, firstEmptySlot = false, nil
    return
  end
  local names, slotsOf = {}, {}
  firstEmptySlot = nil
  local i = 0
  local sensor = getSensor(i)
  while sensor ~= nil do
    local label = sensor.name
    if label == nil or label == "" then
      if firstEmptySlot == nil then firstEmptySlot = i end
    else
      local slots = slotsOf[label]
      if slots == nil then
        slotsOf[label] = { i }
      else
        slots[#slots + 1] = i
        if #slots == 2 then names[label] = true end
      end
    end
    i = i + 1
    sensor = getSensor(i)
  end
  local labels = {}
  for label in pairs(names) do labels[#labels + 1] = label end
  for _, label in ipairs(labels) do
    local slots = slotsOf[label]
    local plain, high, low = {}, {}, {}
    for k = 1, #slots do
      local slotName = "telem" .. (slots[k] + 1)
      plain[k], high[k], low[k] = slotName, slotName .. "+", slotName .. "-"
    end
    names[label], names[label .. "+"], names[label .. "-"] = plain, high, low
    if debugWanted() then debugLog("dup:" .. label, label .. " is carried by " .. table.concat(plain, ", ")) end
  end
  duplicateNames = names
end

local function findDuplicates()
  if slotWalkAt == nil then
    local getFInfo = _G.getFieldInfo
    local marker = type(getFInfo) == "function" and getFInfo(NATIVE_MARKER) or nil
    if type(marker) ~= "table" then
      duplicateNames = false
      return
    end
    slotWalkAt = nowSeconds() + SLOT_WALK_DELAY_SECONDS
    return
  end
  if nowSeconds() >= slotWalkAt then walkSlots() end
end

-- The name `name` is read under: itself, or the slot of that label the radio is receiving.
local function slotName(name)
  local duplicates = duplicateNames
  if duplicates then
    local slots = duplicates[name]
    if slots == nil then return name end
    local getSrcV = _G.getSourceValue
    if type(getSrcV) ~= "function" then return name end
    local held = nil
    for i = 1, #slots do
      local ok, value, current = pcall(getSrcV, slots[i])
      if ok and value ~= nil then
        if current ~= false then return slots[i] end
        held = held or slots[i]
      end
    end
    return held or name
  end
  if duplicates == nil then findDuplicates() end
  return name
end

-- A sensor created after the walk is not in it. EdgeTX puts a new sensor into the lowest empty slot
-- (availableTelemetryIndex, radio/src/telemetry/telemetry_sensors.cpp), so that slot no longer
-- being empty is how one is noticed without walking the table on every read -- the suite's own
-- decoder creates the Rotorflight rows on the first frame that carries them, which on a model
-- meeting custom telemetry for the first time comes after the walk. Asked only on a model that was
-- walked, and only where a row that was never received has just been refused, which is during a
-- search or the re-try of a first name, never on the read of an adopted source.
local function rewalkIfTableGrew()
  if not duplicateNames or firstEmptySlot == nil then return end
  local sensor = model.getSensor(firstEmptySlot)
  if type(sensor) ~= "table" or sensor.name == nil or sensor.name == "" then return end
  walkSlots()
end

-- The clock is only needed here while a miss is on record: it is compared against that record's
-- 1 s window, and it stamps a new miss. A name that answers, which is the steady case for every
-- adopted source, is read without it, and its record is cleared once it answers again.
--
-- `now` is the caller's clock reading, or nil where the caller has not needed one yet. A search
-- after Sensors.reset() tries every name on a source's list, so Sensors.getValue reads the clock
-- once for the search and hands it to every candidate. A miss of the name returns the reading it
-- used as a second value, so a caller that goes on to search does not read the clock a second
-- time. That reading is taken when the miss is found rather than when the call began, which
-- differs only where the 10 ms clock ticks inside the call; the waits measured from it (this
-- window, and the search gate in Sensors.getValue) can then end one call earlier or later.
local function readTelemetryValue(name, now)
  if type(name) ~= "string" then return nil end
  local getV = _G.getValue
  if type(getV) ~= "function" then return nil end

  local missedAt = valueMisses[name]
  if missedAt then
    now = now or nowSeconds()
    if now - missedAt < 1.0 then return nil, now end
  end

  local getFInfo = _G.getFieldInfo
  if type(getFInfo) == "function" then
    local info = fieldInfoCache[name]
    if not info then
      info = getFInfo(name)
      if type(info) == "table" and info.id ~= nil then
        fieldInfoCache[name] = info
      else
        now = now or nowSeconds()
        valueMisses[name] = now
        return nil, now
      end
    end
  end

  -- `false` is the steady state of a model that cannot carry duplicate labels; it skips the call.
  local readName = name
  if duplicateNames ~= false then readName = slotName(name) end
  local ok, value = pcall(getV, readName)
  if ok and type(value) == "number" then
    if missedAt then valueMisses[name] = nil end
    return value
  end

  now = now or nowSeconds()
  valueMisses[name] = now
  return nil, now
end

-- Whether the radio is still receiving this sensor -- asked before a path is adopted, whatever
-- the value. getValue() cannot answer it: it hands back the last value of a sensor that has
-- stopped arriving, and 0 for one never received since the model was loaded or while the link
-- is down, and either is a plausible reading. getSourceValue() returns three values: the value
-- (nothing at all for a sensor never received since the model was loaded), then whether the
-- sensor is still current, then whether it arrived within the last 320 ms. The second is the
-- answer. The radio clears it per sensor once that sensor has been silent for 20 seconds -- the
-- same timeout that raises "Sensor lost" -- and for every sensor once the radio stops counting
-- the link as streaming, a second after its last frame. The next value that arrives sets it again.
-- The first value alone only says that something arrived at some point, which stays true across a
-- dropped link and a stopped sensor alike.
--
-- The 20 seconds are the radio's resolution and cannot be shortened from here: a sensor that
-- stopped less than 20 seconds ago still reads as current. That includes a row a script has
-- written without anything having arrived -- rf2tlm_sensors.lua's initializeSensors() writes 0
-- into every row of the list it is handed, which this tree never does (the drain passes no list)
-- but a background script of RFTool does on a model that carries it -- so such a row is taken for
-- 20 seconds after it was written and refused after that. The suite's own decoder publishes an
-- unchanged value again from the next frame that carries it once FORCE_REFRESH_INTERVAL has passed
-- (tasks/events/telemetry_bg/drain.lua), so a value that simply holds still, in frames that keep
-- arriving, never reads as stopped.
--
-- Only asked where a path is adopted or the first name is re-tried, never on the read of a path
-- already adopted, so a settled source costs nothing. That also means a sensor which stops after
-- it was adopted keeps answering its last value until the next Sensors.reset().
--
-- A name with a trailing "+" or "-" is the session maximum or minimum the radio keeps for that
-- sensor. The radio reports the base sensor's state for it, but an extreme stays a valid figure
-- after the sensor has stopped, so for those only "has it arrived" is asked.
--
-- The second result says that the radio HAS the row and it is not current -- it arrived once and
-- has stopped, or the link is down -- as opposed to a row never received. The search uses it to
-- keep such a source on the short retry: it is the case that comes back by itself.
--
-- A getSourceValue() that returns only the value leaves the second result nil, which is taken as
-- current, so the test then falls back to "has it arrived since the model was loaded".
--
-- It asks the slot the name is read from (slotName above): for a label the model carries twice,
-- that is the row the radio is receiving, so a silent row of the same label does not decide it. A
-- row never received there has the slot table looked at again, in case the row the radio receives
-- was created after the walk.
local function telemetryValueIsLive(name)
  local getSrcV = _G.getSourceValue
  if type(getSrcV) ~= "function" then return true end
  local readName = name
  if duplicateNames ~= false then readName = slotName(name) end
  local ok, value, current = pcall(getSrcV, readName)
  if not ok then return true end
  if value == nil and duplicateNames then rewalkIfTableGrew() end
  if value == nil then return false end
  if current ~= false then return true end
  local last = string.sub(name, -1)
  if last == "+" or last == "-" then return true end
  return false, true
end

local SIM_SENSOR_PATHS = {
  "/SCRIPTS/TOOLS/rfsuite-core/sim/sensors/",
  "/SCRIPTS/TOOLS/rfsuite.user/sim/sensors/",
  "/SCRIPTS/rfsuite-core/sim/sensors/",
  "SCRIPTS/TOOLS/rfsuite-core/sim/sensors/",
  "/rfsuite-core/sim/sensors/",
  "rfsuite-core/sim/sensors/",
}
local function readSimSensorFile(name, source)
  if type(name) ~= "string" or name == "" then return nil end

  local now = nowSeconds()
  -- Negativ-Cache wieder aktivieren um CPU Last bei fehlenden Dateien zu senken
  if (Sensors.sim_search_misses[name] or 0) > 0 and (now - Sensors.sim_search_misses[name]) < 2.0 then
    return nil
  end

  local function tryReadFile(filePath)
    local cached = simValueCache[filePath]
    if cached then
      if cached.exists then
        local v = cached.v
        -- Führe das gecachte Skript aus, um dynamische Werte (math.random) zu erhalten
        if cached.chunk then
          local ok, result = pcall(cached.chunk)
          if ok and type(result) == "number" then
            v = result
          end
        end
        
        -- Source-Reload deutlich drosseln, um Telemetrie-Flapping im Simulator zu vermeiden.
        if (now - cached.t) > SIM_SOURCE_RELOAD_SECONDS then
          -- Drosselung: Maximal ein Skript-Reload pro Tick, um CPU-Spitzen zu vermeiden
          if Sensors.sim_last_reload ~= now then
            Sensors.sim_last_reload = now
            local chunk = loadScript(filePath, "t")
            if chunk then
              cached.chunk = chunk
            else
              -- Datei wurde evtl. gelöscht
              local f = io.open(filePath, "r")
              if not f then cached.exists = false end
              if f then io.close(f) end
            end
            cached.t = now
          end
        end
        return v, true
      else
        -- Datei existierte beim letzten Check nicht, 2 Sekunden lang ignorieren
        if (now - cached.t) <= 2.0 then
          return nil, false
        end
      end
    end

    -- Erst mit io.open prüfen ob die Datei existiert um -E- Log-Spam von loadScript zu vermeiden
    local f = io.open(filePath, "r")
    if not f then 
      simValueCache[filePath] = { t = now, exists = false, v = nil }
      return nil, false 
    end
    io.close(f)

    -- Datei existiert, nun als Lua-Skript ausführen und cachen
    local chunk = loadScript(filePath, "t")
    local v = nil
    if chunk then
      local ok, result = pcall(chunk)
      if ok and type(result) == "number" then
        v = result
      end
    end
    simValueCache[filePath] = { t = now, exists = true, v = v, chunk = chunk }
    return v, true
  end

  -- 1. Bereits erfolgreichen Pfad probieren (O(1))
  -- ... (rest of the logic)


  local activePath = Sensors.sim_active_paths and Sensors.sim_active_paths[name]
  if activePath then
    local v, hit = tryReadFile(activePath)
    if hit then return v end
  end

  -- 2. Kandidatenliste aufbauen
  -- Drosselung: Nur ein intensiver Suchlauf nach fehlenden Dateien pro Tick, um CPU-Limit zu vermeiden
  if Sensors.sim_last_search == now then
    return nil
  end
  Sensors.sim_last_search = now

  local candidates = {}
  local seenCands = {}
  local function addCandidate(value)
    if type(value) ~= "string" or value == "" or seenCands[value] then return end
    candidates[#candidates + 1] = value
    seenCands[value] = true
  end

  addCandidate(name)
  addCandidate(string.lower(name))
  if source then
    addCandidate(source)
    addCandidate(string.lower(source))
    addCandidate(SIM_FILE_ALIASES[source])
  end
  addCandidate(SIM_FILE_ALIASES[name])

  -- 3. In Pfaden suchen
  for p = 1, #SIM_SENSOR_PATHS do
    local base = SIM_SENSOR_PATHS[p]
    for i = 1, #candidates do
      local filePath = base .. candidates[i] .. ".lua"
      local v, hit = tryReadFile(filePath)
      if hit and v ~= nil then
        Sensors.sim_active_paths = Sensors.sim_active_paths or {}
        Sensors.sim_active_paths[name] = filePath
        debugLog("sim-hit:" .. name, "sim file hit " .. filePath .. " = " .. tostring(v))
        return v
      end
    end
  end

  -- Füge Jitter hinzu, damit nicht alle Sensoren im exakt gleichen Tick ablaufen
  Sensors.sim_search_misses[name] = now + (math.random() * 2.0)
  return nil
end

local function normalizeSimValue(name, value)
  if type(value) ~= "number" then return value end
  
  -- Wenn der Wert bereits Nachkommastellen hat, ist er bereits skaliert (z.B. return 25.2)
  if value % 1 ~= 0 then return value end
  
  -- Wenn es ein Integer ist (z.B. return 2520), skalieren wir ihn anhand der Metadaten
  local meta = Sensors.getMetadata(name)
  local prec = meta and tonumber(meta.prec) or 0
  if prec > 0 then
    return value / (10 ^ prec)
  end
  
  return value
end

-- Sensor definitions: 4-char name → metadata
-- ... (rest of Sensors.map)
Sensors.map = {
-- ... (rest of metadata)
  -- Flight Control
  ARM  = { label = "Arm Flags", unit = "raw", prec = 0, fallback = 0 },
  Gov  = { label = "Governor", unit = "raw", prec = 0, fallback = 0 },
  STAT = { label = "System Status", unit = "raw", prec = 0, fallback = 0 },
  SCFG = { label = "System Config", unit = "raw", prec = 0, fallback = 0 },

  -- Power System
  Vbat = { label = "Main Voltage", unit = "V", prec = 2, fallback = 24.2 },
  Curr = { label = "Current", unit = "A", prec = 2, fallback = 0 },
  Capa = { label = "Consumption", unit = "mAh", prec = 0, fallback = 0 },
  ["Bat%"] = { label = "Fuel", unit = "%", prec = 0, fallback = 100 },
  Vbec = { label = "BEC Voltage", unit = "V", prec = 2, fallback = 8.0 },
  SmFt = { label = "Smart Fuel", unit = "%", prec = 0, fallback = 100 },
  SmCp = { label = "Smart Consumption", unit = "mAh", prec = 0, fallback = 0 },

  -- Flight Profiles
  ["PID#"] = { label = "PID Profile", unit = "raw", prec = 0, fallback = 1 },
  ["RTE#"] = { label = "Rate Profile", unit = "raw", prec = 0, fallback = 1 },
  BatP = { label = "Battery Profile", unit = "raw", prec = 0, fallback = 1 },

  -- Speeds / RPM
  Hspd = { label = "Headspeed", unit = "rpm", prec = 0, fallback = 0 },
  Tspd = { label = "Tailspeed", unit = "rpm", prec = 0, fallback = 0 },
  -- Percent, not dB: the radio creates this sensor itself and declares it UNIT_PERCENT
  -- (EdgeTX, radio/src/telemetry/crossfire.cpp, crossfireSensors, LINK_ID subId 2). TQly
  -- below is the same quantity in the other direction.
  RQly = { label = "Link Quality", unit = "%", prec = 0, fallback = 0 },

  -- Attitude
  Ptch = { label = "Pitch", unit = "°", prec = 1, fallback = 0 },
  Roll = { label = "Roll", unit = "°", prec = 1, fallback = 0 },
  Yaw  = { label = "Yaw", unit = "°", prec = 1, fallback = 0 },

  -- Temperature
  TescT = { label = "ESC Temp", unit = "°C", prec = 0, fallback = 25 },
  TmcuT = { label = "MCU Temp", unit = "°C", prec = 0, fallback = 25 },

  -- Other
  ["Thr%"] = { label = "Throttle %", unit = "%", prec = 0, fallback = 0 },
  Alt  = { label = "Altitude", unit = "m", prec = 1, fallback = 0 },
  ["Cel#"] = { label = "Cell Count", unit = "raw", prec = 0, fallback = 6 },

  -- The link statistics, which are the RADIO's sensors rather than the flight controller's:
  -- the CRSF driver creates them from the link frames, so they exist on every model flown on
  -- a Crossfire or ELRS link. Several are named elsewhere in the tree -- RSS1_SOURCES in the
  -- dashboard and in ui/home.lua, the log graph's link template, the announcement list -- but
  -- as names only, and none of them had a row here saying what unit they are in.
  -- lib/rf2tlm_sensors.lua is the table for the flight controller's custom telemetry and
  -- covers none of these. Names and units are EdgeTX's own,
  -- radio/src/telemetry/crossfire.cpp (crossfireSensors), with the spellings in
  -- radio/src/translations/untranslated.h on 2.12 and radio/src/telemetry/sensor_names.h
  -- on main; every one of them is whole numbers. The units are those of 2.12.3 and later,
  -- which declare the three RSSI rows in dBm where 2.12.2 and earlier said dB. TPWR is
  -- declared twice there, in mW from the link frame and in dBm from the extended one; the row
  -- keeps mW, the unit of the frame every link sends.
  --
  -- They carry no label and no fallback, unlike the rows above, because nothing in the tree
  -- reads either field off a row of this table (getMetadata's one caller reads prec). A label
  -- matters most: lib/ has no route to the translations, so an English label here would ship
  -- as English in every locale the moment something did read it. A theme naming one of these
  -- as a source titles its own tile, in its own translated string.
  ["1RSS"] = { unit = "dBm", prec = 0 },
  ["2RSS"] = { unit = "dBm", prec = 0 },
  RSNR = { unit = "dB", prec = 0 },
  ANT  = { unit = "raw", prec = 0 },
  RFMD = { unit = "raw", prec = 0 },
  TPWR = { unit = "mW", prec = 0 },
  TRSS = { unit = "dBm", prec = 0 },
  TQly = { unit = "%", prec = 0 },
  TSNR = { unit = "dB", prec = 0 },
  -- The four the extended link frames add, which only some modules send.
  RRSP = { unit = "%", prec = 0 },
  RPWR = { unit = "dBm", prec = 0 },
  TRSP = { unit = "%", prec = 0 },
  TFPS = { unit = "Hz", prec = 0 },
}

-- Aliases: dashboard/internal names → 4-char sensor names
Sensors.aliases = {
  voltage = "Vbat",
  rpm = "Hspd",
  link = "RQly",
  -- The number of gaps in the frame ids of the flight controller's custom telemetry since the
  -- link came up, which the suite counts and publishes itself (tasks/events/telemetry_bg/drain.lua,
  -- publishCounters). No row in Sensors.map: it is a counter of the suite's own, not a reading.
  skipped_frames = "*Skp",
  fuel = "Bat%",
  smartfuel = "SmFt",
  smartconsumption = "SmCp",
  consumption = "Capa",
  current = "Curr",
  bec_voltage = "Vbec",
  pid_profile = "PID#",
  rate_profile = "RTE#",
  battery_profile = "BatP",
  battery_cell_count = "Cel#",
  armdisableflags = "ARMD",
  throttle_percent = "Thr%",
  altitude = "Alt",
  pitch = "Ptch",
  roll = "Roll",
  yaw = "Yaw",
  armflags = "ARM",
  governor = "Gov",
  rescue = "Resc",
  system_status = "STAT",
  system_config = "SCFG",
}

Sensors.search_paths = {
  voltage = { "Vbat", "VFAS", "voltage", "VBAT" },
  fuel = { "Bat%", "Fuel", "fuel" },
  smartfuel = { "SmFt", "Smart Fuel", "smartfuel", "Bat%", "fuel" },
  rpm = { "Hspd", "RPM", "rpm" },
  link = { "RQly", "LQ", "Link", "link_quality", "1RSS", "2RSS" },
  skipped_frames = { "*Skp" },
  current = { "Curr", "Current", "current" },
  bec_voltage = { "Vbec", "BecV", "BECV", "bec_voltage" },
  pid_profile = { "PID#", "PIDP", "PidP", "PID Profile", "PID" },
  rate_profile = { "RTE#", "RateP", "RTPR", "Rate Profile", "Rate" },
  battery_profile = { "BAT#", "BatP", "BatProfile", "Battery Profile" },
  battery_cell_count = { "Cel#", "cell_count", "cells", "Cells", "battery_cell_count" },
  throttle_percent = { "Thr%", "Thr", "Throttle", "throttle", "throttle_percent" },
  altitude = { "Alt", "Altitude", "altitude" },
  pitch = { "Ptch", "Pitch", "pitch" },
  roll = { "Roll", "roll" },
  yaw = { "Yaw", "yaw" },
  armflags = { "ARM", "Arm", "ARMF", "ArmF", "armflags" },
  armdisableflags = { "ARMD", "ArmD", "arming_disable_flags", "armdisableflags" },
  smartconsumption = { "SmCp", "Smart Consumption", "smartconsumption", "Capa", "consumption" },
  governor = { "Gov", "Governor", "governor" },
  rescue = { "Resc", "rescue" },
  -- CRSF names them STAT/SCFG (lib/rf2tlm_sensors.lua); S.Port sensors are
  -- named by EdgeTX after their appId.
  system_status = { "STAT", "5140", "system_status" },
  system_config = { "SCFG", "5141", "system_config" },
  temp_esc = { "EscT", "Tesc", "ESC_TMP", "TescT", "ESC Temp", "temp_esc" },
  temp_mcu = { "Tmcu", "TmcuT", "temp_mcu" }
}

-- Detect if running in simulator
local isSimulatorCached = nil
function Sensors.isSimulator()
  if isSimulatorCached ~= nil then return isSimulatorCached end
  
  -- EdgeTX 2.10+
  if type(system) == "table" and type(system.getVersion) == "function" then
    local ok, info = pcall(system.getVersion)
    if ok and type(info) == "table" and info.simulation then
      isSimulatorCached = true
      return true
    end
  end

  -- Fallback für ältere Versionen
  if getVersion then
    local ok, _, fw = pcall(getVersion)
    if ok and type(fw) == "string" then
      isSimulatorCached = (string.sub(fw, -4) == "simu")
      return isSimulatorCached
    end
  end
  isSimulatorCached = false
  return false
end

-- Resolve alias to 4-char sensor name
-- Memoised: the answer depends only on the source string and on Sensors.map / Sensors.aliases,
-- both of which are written once as literals and only read afterwards --
-- and getValue resolves a name on every read -- about twenty-five of them per background pass of
-- the dashboard widget. `false` records a name that resolves to nothing, so a miss is answered
-- from the table instead of running the pattern again.
local resolvedNames = {}

local function resolveNameUncached(source)
  if type(source) ~= "string" then return nil end
  local baseSource, suffix = string.match(source, "^(.-)([+-])$")
  if baseSource and suffix then
    if Sensors.aliases[baseSource] then
      return Sensors.aliases[baseSource] .. suffix
    end
    if Sensors.map[baseSource] then
      return baseSource .. suffix
    end
  end
  if Sensors.aliases[source] then
    return Sensors.aliases[source]
  end
  if Sensors.map[source] then
    return source
  end
  return nil
end

function Sensors.resolveName(source)
  if type(source) ~= "string" then return nil end
  local memo = resolvedNames[source]
  if memo ~= nil then
    if memo == false then return nil end
    return memo
  end
  local resolved = resolveNameUncached(source)
  if resolved == nil then resolvedNames[source] = false else resolvedNames[source] = resolved end
  return resolved
end

-- Get sensor metadata by 4-char name or alias
function Sensors.getMetadata(source)
  local name = Sensors.resolveName(source)
  if name then
    local meta = Sensors.map[name]
    if meta then
      return meta
    end

    local baseName = string.match(name, "^(.-)[+-]$")
    if baseName then
      return Sensors.map[baseName]
    end
  end
  return nil
end

-- How long a source that answered nowhere is left alone before its whole name search runs
-- again. It used to be a flat 2 s, and a radio that carries no sensor for a source -- no
-- altimeter, no BEC voltage, no ESC temperature -- pays that search for the whole flight.
-- readTelemetry in widgets/dashboard/runtime.lua asks for every source in one pass, so all of
-- those searches expire on the same boundary and land in the same pass together. The wait
-- doubles with each further miss up to the cap below, which leaves the first retry exactly where
-- it was and makes the steady state of an absent source fifteen times rarer.
--
-- Bounded rather than permanent, because a sensor can still appear: EdgeTX adds one when its
-- first frame arrives, and the suite publishes SmFt and SmCp itself from
-- tasks/events/telemetry_bg/smart.lua. Both happen shortly after the link comes up, and both
-- edges of that link call Sensors.reset() below, which puts every source back on the first wait.
local SEARCH_MISS_SECONDS = 2.0
local SEARCH_MISS_MAX_SECONDS = 30.0
-- How many sources may start their FIRST search in one pass; see the throttle in Sensors.getValue.
-- Like the repeated-search throttle beside it, the count is keyed on the clock reading, so a pass
-- that outlasts one 10 ms clock tick gets a fresh count for the rest of it.
local FIRST_SEARCHES_PER_PASS = 4
-- Module-local, like fieldInfoCache and valueMisses above and unlike Sensors.active_paths: it is
-- a timer of this file's own and nothing outside reads it. Sensors.reset() clears it.
local searchWaits = {}

local readValue

-- Readings the packed status words also carry (rotorflight-firmware
-- src/main/telemetry/status.h). When the dedicated sensor is not there, the
-- value is taken from System Status / System Config instead, so firmware that
-- only sends the packed words still drives arm state, governor, rescue and profiles.
-- armflags is reduced to its ARMED bit, the only bit its readers use.
local DERIVED = {
  armflags        = { word = "system_status", shift = 0,  mask = 0x1 },
  governor        = { word = "system_status", shift = 25, mask = 0xF },
  rescue          = { word = "system_status", shift = 21, mask = 0x7 },
  pid_profile     = { word = "system_config", shift = 0,  mask = 0x7 },
  rate_profile    = { word = "system_config", shift = 3,  mask = 0x7 },
  battery_profile = { word = "system_config", shift = 6,  mask = 0x7 },
}

function Sensors.getValue(source)
  local value = readValue(source)
  if value ~= nil then return value end

  local derived = DERIVED[source]
  if not derived then return nil end
  local word = readValue(derived.word)
  if type(word) ~= "number" then return nil end
  return bit32.band(bit32.rshift(math.floor(word), derived.shift), derived.mask)
end

readValue = function(source)
  if type(source) ~= "string" then return nil end

  if not loggedSimulatorState then
    loggedSimulatorState = true
    debugLog(nil, "simulator detected = " .. tostring(Sensors.isSimulator()))
  end

  local resolved = Sensors.resolveName(source)

  -- In simulator mode we prefer file-based values so widget updates follow the sensor tool.
  if Sensors.isSimulator() then
    if resolved then
      local simValue = readSimSensorFile(resolved, source)
      if type(simValue) == "number" then
        local normalized = normalizeSimValue(resolved, simValue)
        if debugWanted() then debugLog("sim-use:" .. source, "using sim value " .. resolved .. " = " .. tostring(normalized)) end
        return normalized
      end
    end

    local simDirect = readSimSensorFile(source, source)
    if type(simDirect) == "number" then
      local normalized = normalizeSimValue(source, simDirect)
      if debugWanted() then debugLog("sim-direct-use:" .. source, "using sim direct value " .. source .. " = " .. tostring(normalized)) end
      return normalized
    end

    local paths = Sensors.search_paths[source]
    if paths then
      for i = 1, #paths do
        local simPathValue = readSimSensorFile(paths[i], source)
        if type(simPathValue) == "number" then
          local normalized = normalizeSimValue(paths[i], simPathValue)
          if debugWanted() then debugLog("sim-search-hit:" .. source, "using sim search value " .. paths[i] .. " = " .. tostring(normalized)) end
          return normalized
        end
      end
    end
    
    -- WICHTIG: Im Simulator kein Hardware-Fallback!
    return nil
  end

  -- At most one clock reading for the whole call, taken where it is first needed and handed to
  -- every candidate after that. A source adopted on its primary name that answers needs none
  -- while no miss is on record for that name.
  local now

  local activePath = Sensors.active_paths and Sensors.active_paths[source]
  if activePath then
    local paths = Sensors.search_paths[source]
    local primaryPath = paths and paths[1]
    if primaryPath and activePath ~= primaryPath then
      now = nowSeconds()
      Sensors.probe_times = Sensors.probe_times or {}
      local lastProbe = Sensors.probe_times[source] or 0
      if now - lastProbe >= 3.0 then
        Sensors.probe_times[source] = now
        local primaryVal = readTelemetryValue(primaryPath, now)
        if type(primaryVal) == "number" and telemetryValueIsLive(primaryPath) then
          Sensors.active_paths = Sensors.active_paths or {}
          Sensors.active_paths[source] = primaryPath
          if debugWanted() then debugLog("telemetry-promote:" .. source, "promoted " .. primaryPath .. " = " .. tostring(primaryVal)) end
          return primaryVal
        end
      end
    end

    local val, readAt = readTelemetryValue(activePath, now)
    if type(val) == "number" then
      if debugWanted() then debugLog("telemetry-hit-cached:" .. source, "hit " .. activePath .. " = " .. tostring(val)) end
      return val
    end
    now = now or readAt or nowSeconds()
  else
    now = nowSeconds()
  end

  Sensors.search_misses = Sensors.search_misses or {}
  if now - (Sensors.search_misses[source] or 0) < (searchWaits[source] or SEARCH_MISS_SECONDS) then
    return nil
  end

  local previousWait = searchWaits[source]

  -- One REPEATED search per pass. readTelemetry asks for every source in one pass, so all of the
  -- absent ones would otherwise search in the same pass -- and that pass is the one against the
  -- firmware's per-call instruction limit. This is the throttle the simulator half of this file
  -- has always applied to its own searches, for the same reason (Sensors.sim_last_search above).
  --
  -- FIRST searches are limited too, to FIRST_SEARCHES_PER_PASS. They are the searches of a source
  -- with no miss on record: after Sensors.reset() that is every source, and later it is any source
  -- whose last search found it. Without a limit the next read after a reset searches every
  -- source's whole list in one pass. On connect that pass also carries the connect chain, and with
  -- CRSF custom telemetry every sensor already exists but carries no value until the suite's own
  -- decoder publishes it, so every candidate of every list is paid for. A source held back here
  -- has not missed and is not marked: it is simply searched at the next read, so everything the
  -- radio carries is resolved within a few reads of the reset rather than in the first one.
  --
  -- `armflags` is not held back. It is the one source whose absence reads as "not armed", and
  -- the widget asks for it after five others, so a cap would delay the arming state by a read
  -- after every reset. Its list is short, and before the limit it was searched on the first read.
  if previousWait ~= nil then
    if Sensors.last_search == now then return nil end
    Sensors.last_search = now
  elseif source ~= "armflags" then
    if Sensors.first_search_at ~= now then
      Sensors.first_search_at = now
      Sensors.first_searches = 0
    end
    if Sensors.first_searches >= FIRST_SEARCHES_PER_PASS then return nil end
    Sensors.first_searches = Sensors.first_searches + 1
  end

  -- Taken away for the duration of the search and written back only by the miss tail below, so
  -- that every path which adopts a source and returns clears the back-off on its way out.
  searchWaits[source] = nil

  -- Whether a candidate was refused only because the radio is not receiving it right now.
  local stale = false
  local live, old

  local paths = Sensors.search_paths[source]
  if paths then
    for i = 1, #paths do
      local val = readTelemetryValue(paths[i], now)
      if type(val) == "number" then
        live, old = telemetryValueIsLive(paths[i])
        if live then
          Sensors.active_paths = Sensors.active_paths or {}
          Sensors.active_paths[source] = paths[i]
          if debugWanted() then debugLog("telemetry-hit:" .. source, "hit " .. paths[i] .. " = " .. tostring(val)) end
          return val
        end
        stale = stale or old == true
      end
    end
  end

  if resolved then
    -- The alias is the first search path for most sources, so without this test the loop above
    -- rejects a dead sensor and this retries the same name and adopts it for the session.
    local value = readTelemetryValue(resolved, now)
    if type(value) == "number" then
      live, old = telemetryValueIsLive(resolved)
      if live then
        Sensors.active_paths = Sensors.active_paths or {}
        Sensors.active_paths[source] = resolved
        if debugWanted() then debugLog("telemetry-hit:" .. source, "telemetry hit " .. resolved .. " = " .. tostring(value)) end
        return value
      end
      stale = stale or old == true
    end
  end

  local direct = readTelemetryValue(source, now)
  if type(direct) == "number" then
    live, old = telemetryValueIsLive(source)
    if live then
      Sensors.active_paths = Sensors.active_paths or {}
      Sensors.active_paths[source] = source
      if debugWanted() then debugLog("telemetry-direct-hit:" .. source, "telemetry direct hit " .. source .. " = " .. tostring(direct)) end
      return direct
    end
    stale = stale or old == true
  end

  -- A source whose only rows are ones the radio is not receiving right now -- the link is down,
  -- or the flight controller stopped sending -- stays on the first wait instead of doubling. It
  -- is the case that comes back by itself, and the configuration tool forgets its choices only on
  -- the edge where its connection stops being ready, so a doubled wait would hold the link
  -- quality it waits for off for up to SEARCH_MISS_MAX_SECONDS after the link has returned.
  Sensors.search_misses[source] = now
  if previousWait == nil or stale then
    searchWaits[source] = SEARCH_MISS_SECONDS
  else
    local wait = previousWait * 2
    if wait > SEARCH_MISS_MAX_SECONDS then wait = SEARCH_MISS_MAX_SECONDS end
    searchWaits[source] = wait
  end
  return nil
end

-- Opt-in live reads for configuration feedback. Keep the existing getValue
-- contract (including held readings) unchanged for dashboard consumers.
local function liveValue(source)
  if type(source) ~= "string" or type(_G.getSourceValue) ~= "function" then return nil end
  readValue(source)
  local path = Sensors.active_paths and Sensors.active_paths[source]
  if not path then return nil end
  if duplicateNames ~= false then path = slotName(path) end
  local ok, value, current = pcall(_G.getSourceValue, path)
  if ok and current == true and type(value) == "number" then return value end
  return nil
end

function Sensors.getLiveValue(source)
  local value = liveValue(source)
  if value ~= nil then return value end
  local derived = DERIVED[source]
  if not derived then return nil end
  local word = liveValue(derived.word)
  if type(word) ~= "number" or word < 0 or word > 0x7fffffff or word % 1 ~= 0 then return nil end
  return (word >> derived.shift) & derived.mask
end

-- Flush cached sensor paths and miss / probe timers (e.g. on model disconnect/reconnect).
function Sensors.reset()
  if Sensors.active_paths then
    for k in pairs(Sensors.active_paths) do
      Sensors.active_paths[k] = nil
    end
  end
  if Sensors.search_misses then
    for k in pairs(Sensors.search_misses) do
      Sensors.search_misses[k] = nil
    end
  end
  for k in pairs(searchWaits) do
    searchWaits[k] = nil
  end
  if Sensors.probe_times then
    for k in pairs(Sensors.probe_times) do
      Sensors.probe_times[k] = nil
    end
  end
  Sensors.last_search = nil
  Sensors.first_search_at = nil
  Sensors.first_searches = nil
  if fieldInfoCache then
    for k in pairs(fieldInfoCache) do
      fieldInfoCache[k] = nil
    end
  end
  -- `valueMisses` is a module-local table initialised at declaration time and therefore
  -- never nil.  The guard is added purely for style consistency with the blocks above.
  if valueMisses then
    for k in pairs(valueMisses) do
      valueMisses[k] = nil
    end
  end
  duplicateNames = nil
  firstEmptySlot = nil
  slotWalkAt = nil
end

-- Get all 4-char sensor names (for tool enumeration)
function Sensors.getAllNames()
  local names = {}
  for name, _ in pairs(Sensors.map) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

return Sensors
