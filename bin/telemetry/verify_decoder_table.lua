-- Drives the real custom telemetry decoder table (lib/rf2tlm_sensors.lua) with fixed byte vectors
-- and checks, for every row, the returned value and its number type, the next position and every
-- setTelemetryValue call, on both of the table's paths: the suite's own load (the drain) and
-- EdgeTX's sensor discovery.
--   lua5.3 bin/telemetry/verify_decoder_table.lua
-- The expected values are literals. A single-value row is checked against a reference decoder of
-- its kind (unsigned or signed big-endian of one to four bytes, a cell voltage, no data); a row
-- that publishes a group of sensors itself is checked against the calls it made on those vectors
-- when this check was written. A decoder that raises is a failure on its own, never a value to
-- compare.
-- Exit status: 0 green, 1 failed expectations, 2 unreadable source.

local ROOT = "."
do
    local this = arg and arg[0]
    local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
    if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]telemetry$") or (dir .. "/../..") end
end

local chunk, loadErr = loadfile(ROOT .. "/src/rfsuite/lib/rf2tlm_sensors.lua")
if not chunk then io.stderr:write(tostring(loadErr) .. "\n"); os.exit(2) end

local checks, failures = 0, 0
local function check(ok, label)
    checks = checks + 1
    if not ok then
        failures = failures + 1
        print("FAIL " .. label)
    end
end

-- EdgeTX's unit constants, each answering its own name so that a call reads as the unit it names.
setmetatable(_G, { __index = function(_, key)
    if type(key) == "string" and string.sub(key, 1, 5) == "UNIT_" then return string.sub(key, 6) end
    return nil
end })

-- One call as one line: integers as written, floats with an "f", so the number type is compared too.
local calls = {}
_G.setTelemetryValue = function(...)
    local n = select("#", ...)
    local parts = { ... }
    for i = 1, n do
        local v = parts[i]
        if math.type(v) == "float" then parts[i] = tostring(v) .. "f" else parts[i] = tostring(v) end
    end
    calls[#calls + 1] = table.concat(parts, ",", 1, n)
    return true
end
_G.rfsuite = { session = { apiVersion = "12.10" } }

-- id (the entry's index in the firmware's sensor list), sensor id, name, unit, precision, kind.
local ROWS = {
  { 1, 0x1001, "BEAT", "RAW", 0, "U16" },
  { 3, 0x1011, "Vbat", "VOLTS", 2, "U16" },
  { 4, 0x1012, "Curr", "AMPS", 2, "U16" },
  { 5, 0x1013, "Capa", "MAH", 0, "U16" },
  { 6, 0x1014, "Bat%", "PERCENT", 0, "U8" },
  { 7, 0x1020, "Cel#", "RAW", 0, "U8" },
  { 8, 0x1021, "Vcel", "VOLTS", 2, "CellV" },
  { 9, 0x102F, "Cels", "VOLTS", 2, "group" },
  { 10, 0x1030, "Ctrl", "RAW", 0, "group" },
  { 11, 0x1031, "CPtc", "DEGREE", 1, "S16" },
  { 12, 0x1032, "CRol", "DEGREE", 1, "S16" },
  { 13, 0x1033, "CYaw", "DEGREE", 1, "S16" },
  { 14, 0x1034, "CCol", "DEGREE", 1, "S16" },
  { 15, 0x1035, "Thr", "PERCENT", 0, "S8" },
  { 17, 0x1041, "EscV", "VOLTS", 2, "U16" },
  { 18, 0x1042, "EscI", "AMPS", 2, "U16" },
  { 19, 0x1043, "EscC", "MAH", 0, "U16" },
  { 20, 0x1044, "EscR", "RPMS", 0, "U24" },
  { 21, 0x1045, "EscP", "PERCENT", 1, "U16" },
  { 22, 0x1046, "Esc%", "PERCENT", 1, "U16" },
  { 23, 0x1047, "EscT", "CELSIUS", 0, "U8" },
  { 24, 0x1048, "BecT", "CELSIUS", 0, "U8" },
  { 25, 0x1049, "BecV", "VOLTS", 2, "U16" },
  { 26, 0x104A, "BecI", "AMPS", 2, "U16" },
  { 27, 0x104E, "EscF", "RAW", 0, "U32" },
  { 28, 0x104F, "Esc#", "RAW", 0, "U8" },
  { 30, 0x1051, "Es2V", "VOLTS", 2, "U16" },
  { 31, 0x1052, "Es2I", "AMPS", 2, "U16" },
  { 32, 0x1053, "Es2C", "MAH", 0, "U16" },
  { 33, 0x1054, "Es2R", "RPMS", 0, "U24" },
  { 36, 0x1057, "Es2T", "CELSIUS", 0, "U8" },
  { 41, 0x105F, "Es2#", "RAW", 0, "U8" },
  { 42, 0x1080, "Vesc", "VOLTS", 2, "U16" },
  { 43, 0x1081, "Vbec", "VOLTS", 2, "U16" },
  { 44, 0x1082, "Vbus", "VOLTS", 2, "U16" },
  { 45, 0x1083, "Vmcu", "VOLTS", 2, "U16" },
  { 46, 0x1090, "Iesc", "AMPS", 2, "U16" },
  { 47, 0x1091, "Ibec", "AMPS", 2, "U16" },
  { 48, 0x1092, "Ibus", "AMPS", 2, "U16" },
  { 49, 0x1093, "Imcu", "AMPS", 2, "U16" },
  { 50, 0x10A0, "Tesc", "CELSIUS", 0, "U8" },
  { 51, 0x10A1, "Tbec", "CELSIUS", 0, "U8" },
  { 52, 0x10A3, "Tmcu", "CELSIUS", 0, "U8" },
  { 57, 0x10B1, "Hdg", "DEGREE", 1, "S16" },
  { 58, 0x10B2, "Alt", "METERS", 2, "S24" },
  { 59, 0x10B3, "Var", "METERS_PER_SECOND", 2, "S16" },
  { 60, 0x10C0, "Hspd", "RPMS", 0, "U16" },
  { 61, 0x10C1, "Tspd", "RPMS", 0, "U16" },
  { 64, 0x1100, "Attd", "DEGREE", 1, "group" },
  { 65, 0x1101, "Ptch", "DEGREE", 0, "S16" },
  { 66, 0x1102, "Roll", "DEGREE", 0, "S16" },
  { 67, 0x1103, "Yaw", "DEGREE", 0, "S16" },
  { 68, 0x1110, "Accl", "G", 2, "group" },
  { 69, 0x1111, "AccX", "G", 1, "S16" },
  { 70, 0x1112, "AccY", "G", 1, "S16" },
  { 71, 0x1113, "AccZ", "G", 1, "S16" },
  { 73, 0x1121, "Sats", "RAW", 0, "U8" },
  { 74, 0x1122, "PDOP", "RAW", 0, "U8" },
  { 75, 0x1123, "HDOP", "RAW", 0, "U8" },
  { 76, 0x1124, "VDOP", "RAW", 0, "U8" },
  { 77, 0x1125, "GPS", "RAW", 0, "group" },
  { 78, 0x1126, "GAlt", "METERS", 2, "group" },
  { 79, 0x1127, "GHdg", "DEGREE", 1, "S16" },
  { 80, 0x1128, "GSpd", "METERS_PER_SECOND", 2, "U16" },
  { 81, 0x1129, "GDis", "METERS", 0, "U16" },
  { 82, 0x112A, "GDir", "DEGREE", 0, "U16" },
  { 85, 0x1141, "CPU%", "PERCENT", 0, "U8" },
  { 86, 0x1142, "SYS%", "PERCENT", 0, "U8" },
  { 87, 0x1143, "RT%", "PERCENT", 0, "U8" },
  { 88, 0x1200, "MDL#", "RAW", 0, "U8" },
  { 89, 0x1201, "Mode", "RAW", 0, "U16" },
  { 90, 0x1202, "ARM", "RAW", 0, "U8" },
  { 91, 0x1203, "ARMD", "RAW", 0, "U32" },
  { 92, 0x1204, "Resc", "RAW", 0, "U8" },
  { 93, 0x1205, "Gov", "RAW", 0, "U8" },
  { 95, 0x1211, "PID#", "RAW", 0, "U8" },
  { 96, 0x1212, "RTE#", "RAW", 0, "U8" },
  { 97, 0x1214, "BAT#", "RAW", 0, "U8" },
  { 98, 0x1213, "LED#", "RAW", 0, "U8" },
  { 99, 0x1220, "ADJ", "RAW", 0, "group" },
  { 100, 0xDB00, "DBG0", "RAW", 0, "S32" },
  { 101, 0xDB01, "DBG1", "RAW", 0, "S32" },
  { 102, 0xDB02, "DBG2", "RAW", 0, "S32" },
  { 103, 0xDB03, "DBG3", "RAW", 0, "S32" },
  { 104, 0xDB04, "DBG4", "RAW", 0, "S32" },
  { 105, 0xDB05, "DBG5", "RAW", 0, "S32" },
  { 106, 0xDB06, "DBG6", "RAW", 0, "S32" },
  { 107, 0xDB07, "DBG7", "RAW", 0, "S32" },
  { 118, 0x1015, "SmF%", "PERCENT", 0, "S8" },
  { 120, 0x1230, "STAT", "RAW", 0, "U32" },
  { 121, 0x1231, "SCFG", "RAW", 0, "U32" },
}

-- The rows that publish a group themselves, and the vectors they are driven with. Each vector
-- carries two bytes before the entry, which starts at position 3.
local GROUP_VECTORS = {
  [0x102F] = { { 0, 0, 0 }, { 0, 0, 3, 0, 0xD2, 0xFF }, { 0, 0, 2, 0x80, 0x01 } },
  [0x1030] = { { 0, 0, 0, 0, 0, 0, 0, 0 }, { 0, 0, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC },
               { 0, 0, 0xFF, 0xFF, 0xFF, 0x88, 0x00, 0x80 } },
  [0x1100] = { { 0, 0, 0, 0, 0, 0, 0, 0 }, { 0, 0, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC },
               { 0, 0, 0x80, 0x00, 0x7F, 0xFF, 0xFF, 0xFF } },
  [0x1110] = { { 0, 0, 0, 0, 0, 0, 0, 0 }, { 0, 0, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC },
               { 0, 0, 0x80, 0x00, 0x7F, 0xFF, 0xFF, 0xFF } },
  [0x1125] = { { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, { 0, 0, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0 },
               { 0, 0, 0x80, 0, 0, 0, 0x7F, 0xFF, 0xFF, 0xFF } },
  [0x1126] = { { 0, 0, 0, 0 }, { 0, 0, 0x0B, 0xB8 }, { 0, 0, 0x80, 0x00 }, { 0, 0, 0xFF, 0xFF } },
  [0x1220] = { { 0, 0, 0, 0, 0, 0, 0, 0 }, { 0, 0, 0x00, 0x0E, 0xFF, 0xFF, 0xFF, 0x9C },
               { 0, 0, 0xFF, 0xFF, 0x7F, 0xFF, 0xFF, 0xFF } },
}

-- What each of those vectors gave: the next position and the calls, in order.
local GROUP = {
  [0x102F] = {
    { pos = 4, calls = { "4128,0,0,0,RAW,0,Cel#" } },
    { pos = 7, calls = { "4128,0,0,3,RAW,0,Cel#", "4143,0,0,50331648,CELLS,2,Cels", "4143,0,0,50397594,CELLS,2,Cels", "4143,0,0,50463175,CELLS,2,Cels" } },
    { pos = 6, calls = { "4128,0,0,2,RAW,0,Cel#", "4143,0,0,33554760,CELLS,2,Cels", "4143,0,0,33620169,CELLS,2,Cels" } },
  },
  [0x1030] = {
    { pos = 9, calls = { "4144,0,0,0,RAW,0,Ctrl", "4145,0,0,0,DEGREE,2,CPtc", "4146,0,0,0,DEGREE,2,CRol", "4147,0,0,0,DEGREE,2,CYaw", "4148,0,0,0,DEGREE,2,CCol" } },
    { pos = 9, calls = { "4144,0,0,0,RAW,0,Ctrl", "4145,0,0,564,DEGREE,2,CPtc", "4146,0,0,342,DEGREE,2,CRol", "4147,0,0,-5682,DEGREE,2,CYaw", "4148,0,0,1980,DEGREE,2,CCol" } },
    { pos = 9, calls = { "4144,0,0,0,RAW,0,Ctrl", "4145,0,0,-1,DEGREE,2,CPtc", "4146,0,0,-1,DEGREE,2,CRol", "4147,0,0,-6144,DEGREE,2,CYaw", "4148,0,0,-1920,DEGREE,2,CCol" } },
  },
  [0x1100] = {
    { pos = 9, calls = { "4352,0,0,0,DEGREE,1,Attd", "4353,0,0,0,DEGREE,1,Ptch", "4354,0,0,0,DEGREE,1,Roll", "4355,0,0,0,DEGREE,1,Yaw" } },
    { pos = 9, calls = { "4352,0,0,0,DEGREE,1,Attd", "4353,0,0,4660,DEGREE,1,Ptch", "4354,0,0,22136,DEGREE,1,Roll", "4355,0,0,-25924,DEGREE,1,Yaw" } },
    { pos = 9, calls = { "4352,0,0,0,DEGREE,1,Attd", "4353,0,0,-32768,DEGREE,1,Ptch", "4354,0,0,32767,DEGREE,1,Roll", "4355,0,0,-1,DEGREE,1,Yaw" } },
  },
  [0x1110] = {
    { pos = 9, calls = { "4368,0,0,0,G,2,Accl", "4369,0,0,0,G,2,AccX", "4370,0,0,0,G,2,AccY", "4371,0,0,0,G,2,AccZ" } },
    { pos = 9, calls = { "4368,0,0,0,G,2,Accl", "4369,0,0,4660,G,2,AccX", "4370,0,0,22136,G,2,AccY", "4371,0,0,-25924,G,2,AccZ" } },
    { pos = 9, calls = { "4368,0,0,0,G,2,Accl", "4369,0,0,-32768,G,2,AccX", "4370,0,0,32767,G,2,AccY", "4371,0,0,-1,G,2,AccZ" } },
  },
  [0x1125] = {
    { pos = 11, calls = { "4389,0,0,0,GPS,0,GPS", "4389,0,0,0.0f,44", "4389,0,0,0.0f,43" } },
    { pos = 11, calls = { "4389,0,0,0,GPS,0,GPS", "4389,0,0,30541989.6f,44", "4389,0,0,-169889819.2f,43" } },
    { pos = 11, calls = { "4389,0,0,0,GPS,0,GPS", "4389,0,0,-214748364.8f,44", "4389,0,0,214748364.7f,43" } },
  },
  [0x1126] = {
    { pos = 5, calls = { "4390,0,0,0,METERS,1,GAlt" } },
    { pos = 5, calls = { "4390,0,0,3000,METERS,1,GAlt" } },
    { pos = 5, calls = { "4390,0,0,-32768,METERS,1,GAlt" } },
    { pos = 5, calls = { "4390,0,0,-1,METERS,1,GAlt" } },
  },
  [0x1220] = {
    { pos = 9, calls = { "4641,0,0,0,RAW,0,AdjF", "4642,0,0,0,RAW,0,AdjV" } },
    { pos = 9, calls = { "4641,0,0,14,RAW,0,AdjF", "4642,0,0,-100,RAW,0,AdjV" } },
    { pos = 9, calls = { "4641,0,0,65535,RAW,0,AdjF", "4642,0,0,2147483647,RAW,0,AdjV" } },
  },
}

-- What discovery registers for those rows: it calls each decoder once on zero bytes.
local DISCOVERY_GROUP = {
  [0x102F] = { "4128,0,0,0,RAW,0,Cel#" },
  [0x1030] = { "4144,0,0,0,RAW,0,Ctrl", "4145,0,0,0,DEGREE,2,CPtc", "4146,0,0,0,DEGREE,2,CRol", "4147,0,0,0,DEGREE,2,CYaw", "4148,0,0,0,DEGREE,2,CCol" },
  [0x1100] = { "4352,0,0,0,DEGREE,1,Attd", "4353,0,0,0,DEGREE,1,Ptch", "4354,0,0,0,DEGREE,1,Roll", "4355,0,0,0,DEGREE,1,Yaw" },
  [0x1110] = { "4368,0,0,0,G,2,Accl", "4369,0,0,0,G,2,AccX", "4370,0,0,0,G,2,AccY", "4371,0,0,0,G,2,AccZ" },
  [0x1125] = { "4389,0,0,0,GPS,0,GPS", "4389,0,0,0.0f,44", "4389,0,0,0.0f,43" },
  [0x1126] = { "4390,0,0,0,METERS,2,GAlt" },
  [0x1220] = { "4641,0,0,0,RAW,0,AdjF", "4642,0,0,0,RAW,0,AdjV" },
}

-- The single-value rows: byte patterns around every sign boundary, plus mixed bytes. Each vector
-- carries two bytes before the entry, which starts at position 3.
local SCALAR_VECTORS = {
    { 0xAA, 0x55, 0x00, 0x00, 0x00, 0x00, 0x00 },
    { 0xAA, 0x55, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF },
    { 0xAA, 0x55, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF },
    { 0xAA, 0x55, 0x80, 0x00, 0x00, 0x00, 0x00 },
    { 0xAA, 0x55, 0x01, 0x02, 0x03, 0x04, 0x05 },
    { 0xAA, 0x55, 0x12, 0x34, 0x56, 0x78, 0x9A },
    { 0xAA, 0x55, 0xA5, 0x5A, 0xC3, 0x3C, 0x96 },
    { 0xAA, 0x55, 0xFE, 0xDC, 0xBA, 0x98, 0x76 },
}

local WIDTH = { U8 = 1, S8 = 1, U16 = 2, S16 = 2, U24 = 3, S24 = 3, U32 = 4, S32 = 4, CellV = 1, Nil = 0 }

-- What a row of this kind returns for these bytes, as the firmware encodes them: big-endian, two's
-- complement for the signed kinds, a cell voltage as its value less 2.00 V in 10 mV, 0 for none.
local function reference(kind, data, pos)
    local width = WIDTH[kind]
    if kind == "Nil" then return nil, pos end
    local value = 0
    for i = 0, width - 1 do value = value * 256 + data[pos + i] end
    if string.sub(kind, 1, 1) == "S" and value >= 1 << (8 * width - 1) then
        value = value - (1 << (8 * width))
    end
    if kind == "CellV" then value = value > 0 and value + 200 or 0 end
    return value, pos + width
end

local function copy(vector)
    local data = {}
    for i = 1, #vector do data[i] = vector[i] end
    return data
end

local function decode(dec, vector)
    calls = {}
    local ok, value, nextPos = pcall(dec, copy(vector), 3)
    return ok, value, nextPos, calls
end

local function keyName(key)
    return math.type(key) == "integer" and string.format("0x%04X", key) or tostring(key)
end

local function finish()
    print(string.format("%d rows, %d checks, %d failures", #ROWS, checks, failures))
    os.exit(failures == 0 and 0 or 1)
end

-- 1. The suite's own load: every row, keyed by its sensor id, and nothing else.
local okLoad, rows = pcall(chunk, nil, function() return true end)
check(okLoad and type(rows) == "table", "drain load: the table loads (" .. tostring(rows) .. ")")
if not okLoad or type(rows) ~= "table" then finish() end
local okDeclined, declinedRows = pcall(chunk, nil, function() return false end)
check(okDeclined and type(declinedRows) == "table", "drain load with every group declined")
if not okDeclined or type(declinedRows) ~= "table" then finish() end

local expectedSids = {}
for _, entry in ipairs(ROWS) do expectedSids[entry[2]] = true end
for sid in pairs(rows) do
    check(expectedSids[sid] == true, "drain load: unexpected row " .. keyName(sid))
end

for _, entry in ipairs(ROWS) do
    local sid, name, unit, prec, kind = entry[2], entry[3], entry[4], entry[5], entry[6]
    local label = string.format("0x%04X %s", sid, name)
    local row = rows[sid]
    check(type(row) == "table", label .. ": row present")
    if type(row) == "table" then
        check(row.name == name, label .. ": name " .. tostring(row.name))
        check(row.unit == unit, label .. ": unit " .. tostring(row.unit))
        check(row.prec == prec, label .. ": prec " .. tostring(row.prec))
        check(type(row.dec) == "function", label .. ": decoder")
    end
    if type(row) == "table" and type(row.dec) == "function" and kind == "group" then
        for v, vector in ipairs(GROUP_VECTORS[sid]) do
            local want = GROUP[sid][v]
            local vlabel = label .. " vector " .. v
            local ok, value, nextPos, got = decode(row.dec, vector)
            check(ok, vlabel .. ": raised " .. tostring(value))
            if ok then
                check(value == nil, vlabel .. ": returns nil after publishing, got " .. tostring(value))
                check(nextPos == want.pos, vlabel .. ": position " .. tostring(nextPos) .. ", expected " .. want.pos)
                check(#got == #want.calls, vlabel .. ": " .. #got .. " calls, expected " .. #want.calls)
                for c = 1, math.max(#got, #want.calls) do
                    check(got[c] == want.calls[c], vlabel .. " call " .. c .. ": " .. tostring(got[c])
                        .. ", expected " .. tostring(want.calls[c]))
                end
            end
            -- A group the publish throttle declines publishes nothing and still moves past its bytes.
            local okNo, valueNo, posNo, gotNo = decode(declinedRows[sid].dec, vector)
            check(okNo, vlabel .. " declined: raised " .. tostring(valueNo))
            if okNo then
                check(valueNo == nil and posNo == want.pos and #gotNo == 0,
                    vlabel .. " declined: nil, position " .. want.pos .. " and no call")
            end
        end
    elseif type(row) == "table" and type(row.dec) == "function" then
        for v, vector in ipairs(SCALAR_VECTORS) do
            local wantValue, wantPos = reference(kind, vector, 3)
            local vlabel = label .. " vector " .. v
            local ok, value, nextPos, got = decode(row.dec, vector)
            check(ok, vlabel .. ": raised " .. tostring(value))
            if ok then
                check(value == wantValue and math.type(value) == math.type(wantValue),
                    vlabel .. ": " .. tostring(value) .. " (" .. tostring(math.type(value)) .. "), expected "
                    .. tostring(wantValue) .. " (" .. tostring(math.type(wantValue)) .. ")")
                check(nextPos == wantPos, vlabel .. ": position " .. tostring(nextPos) .. ", expected " .. wantPos)
                check(#got == 0, vlabel .. ": a single-value row publishes nothing itself")
            end
        end
    end
end

-- 2. EdgeTX's sensor discovery: rows of exactly the four named fields, and one registration per
-- row that decodes a value from zero bytes, in the order of the requested ids.
local requested = {}
for id = 0, 130 do requested[#requested + 1] = id end
calls = {}
local okDisc, discovered = pcall(chunk, requested)
local registered = calls
check(okDisc and type(discovered) == "table", "discovery: the table loads (" .. tostring(discovered) .. ")")
if okDisc and type(discovered) == "table" then
    local wantCalls = {}
    for _, entry in ipairs(ROWS) do
        local sid, name, unit, prec, kind = entry[2], entry[3], entry[4], entry[5], entry[6]
        local label = string.format("discovery 0x%04X %s", sid, name)
        local row = discovered[sid]
        check(type(row) == "table", label .. ": row present")
        if type(row) == "table" then
            local fields = 0
            for key in pairs(row) do
                fields = fields + 1
                check(key == "name" or key == "unit" or key == "prec" or key == "dec",
                    label .. ": field " .. tostring(key))
            end
            check(fields == 4, label .. ": " .. fields .. " fields, expected 4")
            check(row.name == name and row.unit == unit and row.prec == prec, label .. ": name, unit and prec")
        end
        if kind == "group" then
            for _, c in ipairs(DISCOVERY_GROUP[sid]) do wantCalls[#wantCalls + 1] = c end
        elseif kind ~= "Nil" then
            wantCalls[#wantCalls + 1] = string.format("%d,0,0,0,%s,%d,%s", sid, unit, prec, name)
        end
    end
    for sid in pairs(discovered) do
        check(expectedSids[sid] == true, "discovery: unexpected row " .. keyName(sid))
    end
    check(#registered == #wantCalls, "discovery: " .. #registered .. " registrations, expected " .. #wantCalls)
    for c = 1, math.max(#registered, #wantCalls) do
        check(registered[c] == wantCalls[c], "discovery call " .. c .. ": " .. tostring(registered[c])
            .. ", expected " .. tostring(wantCalls[c]))
    end
end

finish()
