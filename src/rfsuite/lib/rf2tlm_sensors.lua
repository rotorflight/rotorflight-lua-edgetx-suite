-- Map of CRSF Custom Telemetry IDs to sensor definitions
local requestedSensorsById, due = ...

local function decNil(data, pos)
    return nil, pos
end

local function decU8(data, pos)
    return data[pos], pos+1
end

local function decS8(data, pos)
    local val = data[pos]
    return val < 0x80 and val or val - 0x100, pos+1
end

-- Up to three bytes are joined by arithmetic rather than bit32: the result stays below 2^24, so
-- it is the same integer on a desktop Lua and on EdgeTX, which builds Lua with 32-bit integers.
-- The four-byte decoders are left on bit32 as they were: their values can pass 2^31, which
-- that integer type does not hold, so plain arithmetic would not give the same result there.
local function decU16(data, pos)
    return data[pos]*256 + data[pos+1], pos+2
end

local function decS16(data, pos)
    local val = data[pos]*256 + data[pos+1]
    return val < 0x8000 and val or val - 0x10000, pos+2
end

-- Two 12-bit values in three bytes: the first byte carries the high nibble of each (the first
-- value's in its low four bits), the next two bytes their low eight bits. This is the layout
-- rotorflight-firmware's crsfSensorEncodeControl (src/main/telemetry/crsf.c) writes.
local function decU12U12(data, pos)
    local a = bit32.lshift(bit32.extract(data[pos],0,4),8) + data[pos+1]
    local b = bit32.lshift(bit32.extract(data[pos],4,4),8) + data[pos+2]
    return a,b,pos+3
end

local function decS12S12(data, pos)
    local a,b,ptr = decU12U12(data, pos)
    return a < 0x0800 and a or a - 0x1000, b < 0x0800 and b or b - 0x1000, ptr
end

local function decU24(data, pos)
    return data[pos]*65536 + data[pos+1]*256 + data[pos+2], pos+3
end

local function decS24(data, pos)
    local val = data[pos]*65536 + data[pos+1]*256 + data[pos+2]
    return val < 0x800000 and val or val - 0x1000000, pos+3
end

local function decU32(data, pos)
    return bit32.lshift(data[pos],24) + bit32.lshift(data[pos+1],16) + bit32.lshift(data[pos+2],8) + data[pos+3], pos+4
end

local function decS32(data, pos)
    local val,ptr = decU32(data,pos)
    return val < 0x80000000 and val or val - 0x100000000, ptr
end

local function decCellV(data, pos)
    local val,ptr = decU8(data,pos)
    return val > 0 and val + 200 or 0, ptr
end

-- Some decoders below publish their own sensors. `due` is the loader's
-- publish throttle, handed over once as the chunk's second argument rather than to every decoder
-- call, so the single-value decoders are called exactly as before. It is asked with the bytes the
-- group was decoded from, and a group it declines is not published at all. Without it -- sensor
-- registration, or a loader that passes none -- every call is made, as before.
local function decCells(data, pos)
    local cnt,val,vol
    local first = pos
    cnt,pos = decU8(data,pos)
    if due and not due(0x102F, data, first, pos + cnt) then
        return nil, pos + cnt
    end
    setTelemetryValue(0x1020, 0, 0, cnt, UNIT_RAW, 0, "Cel#")
    for i = 1, cnt
    do
        val,pos = decU8(data,pos)
        val = val > 0 and val + 200 or 0
        vol = bit32.lshift(cnt,24) + bit32.lshift(i-1, 16) + val
        setTelemetryValue(0x102F, 0, 0, vol, UNIT_CELLS, 2, "Cels")
    end
    return nil, pos
end

local function decLatLong(data, pos)
    local UNIT_GPS_LONGITUDE = 43
    local UNIT_GPS_LATITUDE = 44
    local lat,lon
    local first = pos
    lat,pos = decS32(data,pos)
    lon,pos = decS32(data,pos)
    if due and not due(0x1125, data, first, pos) then return nil, pos end
    setTelemetryValue(0x1125, 0, 0, 0, UNIT_GPS, 0, "GPS")
    setTelemetryValue(0x1125, 0, 0, lat/10, UNIT_GPS_LATITUDE)
    setTelemetryValue(0x1125, 0, 0, lon/10, UNIT_GPS_LONGITUDE)
    return nil, pos
end

local gpsAltitudeApiVersion
local gpsAltitudePrecision = 2

local function decGpsAltitude(data, pos)
    local first = pos
    local val
    val,pos = decS16(data,pos)
    if due and not due(0x1126, data, first, pos) then return nil, pos end
    local session = _G.rfsuite and _G.rfsuite.session
    local apiVersion = session and session.apiVersion
    if apiVersion ~= gpsAltitudeApiVersion then
        gpsAltitudeApiVersion = apiVersion
        -- Firmware sends S16 decimetres from MSP API 12.10, centimetres before it. The version is
        -- the session's "major.minor" string; anything unreadable keeps centimetres.
        local major, minor = string.match(tostring(apiVersion or ""), "^(%d+)%.(%d+)")
        major, minor = tonumber(major), tonumber(minor)
        local decimetres = major ~= nil and (major > 12 or (major == 12 and minor >= 10))
        gpsAltitudePrecision = decimetres and 1 or 2
    end
    -- Discovery keeps the stored precision at two decimals, including on newer firmware.
    local prec = type(requestedSensorsById) == "table" and 2 or gpsAltitudePrecision
    setTelemetryValue(0x1126, 0, 0, val, UNIT_METERS, prec, "GAlt")
    return nil, pos
end

-- The adjustment teller (tasks/events/telemetry_bg/adjustments.lua) takes the pair from here, in
-- the Lua state that decoded it, rather than reading it back from the radio's sensor list by name.
-- The last decoded pair is held on the suite's root, ahead of the publish throttle below (a
-- throttled pair is one that did not change), the way the radio holds a sensor's last value: an
-- unchanged row comes only every few seconds, and a teller loaded or reset in between still finds
-- the 0 that says nothing is being adjusted. Not during sensor discovery, which calls every
-- decoder once with zero bytes.
local function decAdjFunc(data, pos)
    local fun,val
    local first = pos
    fun,pos = decU16(data,pos)
    val,pos = decS32(data,pos)
    if requestedSensorsById == nil then
        local root = _G.rfsuite
        if root then
            local report = root.adjustmentReport
            if report == nil then
                report = {}
                root.adjustmentReport = report
            end
            report[1], report[2] = fun, val
        end
    end
    if due and not due(0x1220, data, first, pos) then return nil, pos end
    setTelemetryValue(0x1221, 0, 0, fun, UNIT_RAW, 0, "AdjF")
    setTelemetryValue(0x1222, 0, 0, val, UNIT_RAW, 0, "AdjV")
    return nil, pos
end

-- Six bytes: pitch and roll, then yaw and collective, as two pairs of signed 12-bit values
-- (crsfSensorEncodeControl). The firmware scales pitch, roll and collective by 1200 and yaw by
-- 800 here, where its individual rows 0x1031..0x1034 send 1200 and 2400 divided by 10 (the
-- denominators in crsf.c's sensor table) at one decimal. Two decimals, and yaw times three, give
-- the same reading on the same sensors from either path.
local function decControl(data, pos)
    local pitch, roll, yaw, coll
    local first = pos
    pitch,roll,pos = decS12S12(data,pos)
    yaw,coll,pos = decS12S12(data,pos)
    if due and not due(0x1030, data, first, pos) then return nil, pos end
    setTelemetryValue(0x1030, 0, 0, 0, UNIT_RAW, 0, "Ctrl")
    setTelemetryValue(0x1031, 0, 0, pitch, UNIT_DEGREE, 2, "CPtc")
    setTelemetryValue(0x1032, 0, 0, roll, UNIT_DEGREE, 2, "CRol")
    setTelemetryValue(0x1033, 0, 0, 3 * yaw, UNIT_DEGREE, 2, "CYaw")
    setTelemetryValue(0x1034, 0, 0, coll, UNIT_DEGREE, 2, "CCol")
    return nil, pos
end

-- The combined attitude is sent undivided, in tenths of a degree (crsfSensorEncodeAttitude), where
-- the individual rows 0x1101..0x1103 are divided by 10 first; hence one decimal here and none there.
local function decAttitude(data, pos)
    local pitch, roll, yaw
    local first = pos
    pitch,pos = decS16(data,pos)
    roll,pos = decS16(data,pos)
    yaw,pos = decS16(data,pos)
    if due and not due(0x1100, data, first, pos) then return nil, pos end
    setTelemetryValue(0x1100, 0, 0, 0, UNIT_DEGREE, 1, "Attd")
    setTelemetryValue(0x1101, 0, 0, pitch, UNIT_DEGREE, 1, "Ptch")
    setTelemetryValue(0x1102, 0, 0, roll, UNIT_DEGREE, 1, "Roll")
    setTelemetryValue(0x1103, 0, 0, yaw, UNIT_DEGREE, 1, "Yaw")
    return nil, pos
end

-- The combined acceleration is sent in hundredths of a g (crsfSensorEncodeAccel), the individual
-- rows 0x1111..0x1113 in tenths; hence two decimals here and one there.
local function decAccel(data, pos)
    local x, y, z
    local first = pos
    x,pos = decS16(data,pos)
    y,pos = decS16(data,pos)
    z,pos = decS16(data,pos)
    if due and not due(0x1110, data, first, pos) then return nil, pos end
    setTelemetryValue(0x1110, 0, 0, 0, UNIT_G, 2, "Accl")
    setTelemetryValue(0x1111, 0, 0, x, UNIT_G, 2, "AccX")
    setTelemetryValue(0x1112, 0, 0, y, UNIT_G, 2, "AccY")
    setTelemetryValue(0x1113, 0, 0, z, UNIT_G, 2, "AccZ")
    return nil, pos
end

-- A row is { sensor id, name = ..., unit = ..., prec = ..., dec = ... }. The id sits in the
-- array part on purpose: with four named fields a row's hash part holds four slots, a fifth would
-- double it to eight, and the drain keeps these rows for as long as its Lua state lives.
local sensorsById = {
   -- No data
    [0] = { 0x1000, name = "NONE", unit = UNIT_RAW, prec = 0, dec = decNil },
    -- Heartbeat (millisecond uptime % 60000)
    [1] = { 0x1001, name = "BEAT", unit = UNIT_RAW, prec = 0, dec = decU16 },

    -- Main battery voltage
    [3] = { 0x1011, name = "Vbat", unit = UNIT_VOLTS, prec = 2, dec = decU16 },
    -- Main battery current
    [4] = { 0x1012, name = "Curr", unit = UNIT_AMPS, prec = 2, dec = decU16 },
    -- Main battery used capacity
    [5] = { 0x1013, name = "Capa", unit = UNIT_MAH, prec = 0, dec = decU16 },
    -- Main battery charge / fuel level
    [6] = { 0x1014, name = "Bat%", unit = UNIT_PERCENT, prec = 0, dec = decU8 },

    -- Main battery cell count
    [7] = { 0x1020, name = "Cel#", unit = UNIT_RAW, prec = 0, dec = decU8 },
    -- Main battery cell voltage (minimum/average)
    [8] = { 0x1021, name = "Vcel", unit = UNIT_VOLTS, prec = 2, dec = decCellV },
    -- Main battery cell voltages
    [9] = { 0x102F, name = "Cels", unit = UNIT_VOLTS, prec = 2, dec = decCells },

    -- Control Combined (hires)
    [10] = { 0x1030, name = "Ctrl", unit = UNIT_RAW, prec = 0, dec = decControl },
    -- Pitch Control angle
    [11] = { 0x1031, name = "CPtc", unit = UNIT_DEGREE, prec = 1, dec = decS16 },
    -- Roll Control angle
    [12] = { 0x1032, name = "CRol", unit = UNIT_DEGREE, prec = 1, dec = decS16 },
    -- Yaw Control angle
    [13] = { 0x1033, name = "CYaw", unit = UNIT_DEGREE, prec = 1, dec = decS16 },
    -- Collective Control angle
    [14] = { 0x1034, name = "CCol", unit = UNIT_DEGREE, prec = 1, dec = decS16 },
    -- Throttle output %
    [15] = { 0x1035, name = "Thr", unit = UNIT_PERCENT, prec = 0, dec = decS8 },

    -- ESC#1 voltage
    [17] = { 0x1041, name = "EscV", unit = UNIT_VOLTS, prec = 2, dec = decU16 },
    -- ESC#1 current
    [18] = { 0x1042, name = "EscI", unit = UNIT_AMPS, prec = 2, dec = decU16 },
    -- ESC#1 capacity/consumption
    [19] = { 0x1043, name = "EscC", unit = UNIT_MAH, prec = 0, dec = decU16 },
    -- ESC#1 eRPM
    [20] = { 0x1044, name = "EscR", unit = UNIT_RPMS, prec = 0, dec = decU24 },
    -- ESC#1 PWM/Power
    [21] = { 0x1045, name = "EscP", unit = UNIT_PERCENT, prec = 1, dec = decU16 },
    -- ESC#1 throttle
    [22] = { 0x1046, name = "Esc%", unit = UNIT_PERCENT, prec = 1, dec = decU16 },
    -- ESC#1 temperature
    [23] = { 0x1047, name = "EscT", unit = UNIT_CELSIUS, prec = 0, dec = decU8 },
    -- ESC#1 / BEC temperature
    [24] = { 0x1048, name = "BecT", unit = UNIT_CELSIUS, prec = 0, dec = decU8 },
    -- ESC#1 / BEC voltage
    [25] = { 0x1049, name = "BecV", unit = UNIT_VOLTS, prec = 2, dec = decU16 },
    -- ESC#1 / BEC current
    [26] = { 0x104A, name = "BecI", unit = UNIT_AMPS, prec = 2, dec = decU16 },
    -- ESC#1 Status Flags
    [27] = { 0x104E, name = "EscF", unit = UNIT_RAW, prec = 0, dec = decU32 },
    -- ESC#1 Model Id
    [28] = { 0x104F, name = "Esc#", unit = UNIT_RAW, prec = 0, dec = decU8 },

    -- ESC#2 voltage
    [30] = { 0x1051, name = "Es2V", unit = UNIT_VOLTS, prec = 2, dec = decU16 },
    -- ESC#2 current
    [31] = { 0x1052, name = "Es2I", unit = UNIT_AMPS, prec = 2, dec = decU16 },
    -- ESC#2 capacity/consumption
    [32] = { 0x1053, name = "Es2C", unit = UNIT_MAH, prec = 0, dec = decU16 },
    -- ESC#2 eRPM
    [33] = { 0x1054, name = "Es2R", unit = UNIT_RPMS, prec = 0, dec = decU24 },
    -- ESC#2 temperature
    [36] = { 0x1057, name = "Es2T", unit = UNIT_CELSIUS, prec = 0, dec = decU8 },
    -- ESC#2 Model Id
    [41] = { 0x105F, name = "Es2#", unit = UNIT_RAW, prec = 0, dec = decU8 },

    -- Combined ESC voltage
    [42] = { 0x1080, name = "Vesc", unit = UNIT_VOLTS, prec = 2, dec = decU16 },
    -- BEC voltage
    [43] = { 0x1081, name = "Vbec", unit = UNIT_VOLTS, prec = 2, dec = decU16 },
    -- BUS voltage
    [44] = { 0x1082, name = "Vbus", unit = UNIT_VOLTS, prec = 2, dec = decU16 },
    -- MCU voltage
    [45] = { 0x1083, name = "Vmcu", unit = UNIT_VOLTS, prec = 2, dec = decU16 },

    -- Combined ESC current
    [46] = { 0x1090, name = "Iesc", unit = UNIT_AMPS, prec = 2, dec = decU16 },
    -- BEC current
    [47] = { 0x1091, name = "Ibec", unit = UNIT_AMPS, prec = 2, dec = decU16 },
    -- BUS current
    [48] = { 0x1092, name = "Ibus", unit = UNIT_AMPS, prec = 2, dec = decU16 },
    -- MCU current
    [49] = { 0x1093, name = "Imcu", unit = UNIT_AMPS, prec = 2, dec = decU16 },

    -- Combined ESC temperature
    [50] = { 0x10A0, name = "Tesc", unit = UNIT_CELSIUS, prec = 0, dec = decU8 },
    -- BEC temperature
    [51] = { 0x10A1, name = "Tbec", unit = UNIT_CELSIUS, prec = 0, dec = decU8 },
    -- MCU temperature
    [52] = { 0x10A3, name = "Tmcu", unit = UNIT_CELSIUS, prec = 0, dec = decU8 },

    -- Heading (combined gyro+mag+GPS)
    [57] = { 0x10B1, name = "Hdg", unit = UNIT_DEGREE, prec = 1, dec = decS16 },
    -- Altitude (combined baro+GPS)
    [58] = { 0x10B2, name = "Alt", unit = UNIT_METERS, prec = 2, dec = decS24 },
    -- Variometer (combined baro+GPS)
    [59] = { 0x10B3, name = "Var", unit = UNIT_METERS_PER_SECOND, prec = 2, dec = decS16 },

    -- Headspeed
    [60] = { 0x10C0, name = "Hspd", unit = UNIT_RPMS, prec = 0, dec = decU16 },
    -- Tailspeed
    [61] = { 0x10C1, name = "Tspd", unit = UNIT_RPMS, prec = 0, dec = decU16 },

    -- Attitude (hires combined)
    [64] = { 0x1100, name = "Attd", unit = UNIT_DEGREE, prec = 1, dec = decAttitude },
    -- Attitude pitch
    [65] = { 0x1101, name = "Ptch", unit = UNIT_DEGREE, prec = 0, dec = decS16 },
    -- Attitude roll
    [66] = { 0x1102, name = "Roll", unit = UNIT_DEGREE, prec = 0, dec = decS16 },
    -- Attitude yaw
    [67] = { 0x1103, name = "Yaw", unit = UNIT_DEGREE, prec = 0, dec = decS16 },

    -- Acceleration (hires combined)
    [68] = { 0x1110, name = "Accl", unit = UNIT_G, prec = 2, dec = decAccel },
    -- Acceleration X
    [69] = { 0x1111, name = "AccX", unit = UNIT_G, prec = 1, dec = decS16 },
    -- Acceleration Y
    [70] = { 0x1112, name = "AccY", unit = UNIT_G, prec = 1, dec = decS16 },
    -- Acceleration Z
    [71] = { 0x1113, name = "AccZ", unit = UNIT_G, prec = 1, dec = decS16 },

    -- GPS Satellite count
    [73] = { 0x1121, name = "Sats", unit = UNIT_RAW, prec = 0, dec = decU8 },
    -- GPS PDOP
    [74] = { 0x1122, name = "PDOP", unit = UNIT_RAW, prec = 0, dec = decU8 },
    -- GPS HDOP
    [75] = { 0x1123, name = "HDOP", unit = UNIT_RAW, prec = 0, dec = decU8 },
    -- GPS VDOP
    [76] = { 0x1124, name = "VDOP", unit = UNIT_RAW, prec = 0, dec = decU8 },
    -- GPS Coordinates
    [77] = { 0x1125, name = "GPS", unit = UNIT_RAW, prec = 0, dec = decLatLong },
    -- GPS altitude
    [78] = { 0x1126, name = "GAlt", unit = UNIT_METERS, prec = 2, dec = decGpsAltitude },
    -- GPS heading
    [79] = { 0x1127, name = "GHdg", unit = UNIT_DEGREE, prec = 1, dec = decS16 },
    -- GPS ground speed
    [80] = { 0x1128, name = "GSpd", unit = UNIT_METERS_PER_SECOND, prec = 2, dec = decU16 },
    -- GPS home distance
    [81] = { 0x1129, name = "GDis", unit = UNIT_METERS, prec = 0, dec = decU16 },
    -- GPS home direction
    [82] = { 0x112A, name = "GDir", unit = UNIT_DEGREE, prec = 0, dec = decU16 },

    -- CPU load
    [85] = { 0x1141, name = "CPU%", unit = UNIT_PERCENT, prec = 0, dec = decU8 },
    -- System load
    [86] = { 0x1142, name = "SYS%", unit = UNIT_PERCENT, prec = 0, dec = decU8 },
    -- Realtime CPU load
    [87] = { 0x1143, name = "RT%", unit = UNIT_PERCENT, prec = 0, dec = decU8 },

    -- Model ID
    [88] = { 0x1200, name = "MDL#", unit = UNIT_RAW, prec = 0, dec = decU8 },
    -- Flight mode flags
    [89] = { 0x1201, name = "Mode", unit = UNIT_RAW, prec = 0, dec = decU16 },
    -- Arming flags
    [90] = { 0x1202, name = "ARM", unit = UNIT_RAW, prec = 0, dec = decU8 },
    -- Arming disable flags
    [91] = { 0x1203, name = "ARMD", unit = UNIT_RAW, prec = 0, dec = decU32 },
    -- Rescue state
    [92] = { 0x1204, name = "Resc", unit = UNIT_RAW, prec = 0, dec = decU8 },
    -- Governor state
    [93] = { 0x1205, name = "Gov", unit = UNIT_RAW, prec = 0, dec = decU8 },

    -- Current PID profile
    [95] = { 0x1211, name = "PID#", unit = UNIT_RAW, prec = 0, dec = decU8 },
    -- Current Rate profile
    [96] = { 0x1212, name = "RTE#", unit = UNIT_RAW, prec = 0, dec = decU8 },
    -- Battery profile
    [97] = { 0x1214, name = "BAT#", unit = UNIT_RAW, prec = 0, dec = decU8 },
    -- Current LED profile
    [98] = { 0x1213, name = "LED#", unit = UNIT_RAW, prec = 0, dec = decU8 },

    -- Adjustment function
    [99] = { 0x1220, name = "ADJ", unit = UNIT_RAW, prec = 0, dec = decAdjFunc },

    -- Packed status words; bit layout in rotorflight-firmware's src/main/telemetry/status.h.
    -- System status: armed, RX link, failsafe, GPS, battery, rescue and governor state, ...
    [120] = { 0x1230, name = "STAT", unit = UNIT_RAW, prec = 0, dec = decU32 },
    -- System config: PID/rate/battery profile numbers, config and hardware state
    [121] = { 0x1231, name = "SCFG", unit = UNIT_RAW, prec = 0, dec = decU32 },

    -- Debug
    [100] = { 0xDB00, name = "DBG0", unit = UNIT_RAW, prec = 0, dec = decS32 },
    [101] = { 0xDB01, name = "DBG1", unit = UNIT_RAW, prec = 0, dec = decS32 },
    [102] = { 0xDB02, name = "DBG2", unit = UNIT_RAW, prec = 0, dec = decS32 },
    [103] = { 0xDB03, name = "DBG3", unit = UNIT_RAW, prec = 0, dec = decS32 },
    [104] = { 0xDB04, name = "DBG4", unit = UNIT_RAW, prec = 0, dec = decS32 },
    [105] = { 0xDB05, name = "DBG5", unit = UNIT_RAW, prec = 0, dec = decS32 },
    [106] = { 0xDB06, name = "DBG6", unit = UNIT_RAW, prec = 0, dec = decS32 },
    [107] = { 0xDB07, name = "DBG7", unit = UNIT_RAW, prec = 0, dec = decS32 },

    -- Smart fuel
    [118] = { 0x1015, name = "SmF%", unit = UNIT_PERCENT, prec = 0, dec = decS8 },

}

local function initializeSensors(ids)
    local data = { 0, 0, 0, 0, 0, 0, 0, 0 }
    for i = 1, #ids do
        local id = ids[i]
        if id ~= 0 and sensorsById[id] ~= nil then
            local sensor = sensorsById[id]
            local ptr = 1
            local val = sensor.dec(data, ptr)
            if val then
                setTelemetryValue(sensor[1], 0, 0, 0, sensor.unit, sensor.prec, sensor.name)
            end
        end
    end
end

local function getSensorsBySid(ids)
    local result = {}
    for i = 1, #ids do
        local id = ids[i]
        if id ~= 0 and sensorsById[id] ~= nil then
            local sensor = sensorsById[id]
            result[sensor[1]] = { name = sensor.name, unit = sensor.unit, prec = sensor.prec, dec = sensor.dec }
        end
    end
    return result
end

if type(requestedSensorsById) == "table" then
    -- Called by EdgeTX's sensor discovery
    initializeSensors(requestedSensorsById)
    return getSensorsBySid(requestedSensorsById)
else
    -- Called by the suite's telemetry_bg task: the rows themselves are handed on, keyed by sensor id
    local result = {}
    for id, sensor in pairs(sensorsById) do
        if id ~= 0 then result[sensor[1]] = sensor end
    end
    return result
end
