-- Ported RC_TUNING -> rc_tuning.lua
local Api = {
    command = 111,
    writeCommand = 204
}

local FIELD_SPEC = {
    {"rates_type", "U8"},
    {"rcRates_1", "U8"}, {"rcExpo_1", "U8"}, {"rates_1", "U8"}, {"response_time_1", "U8"}, {"accel_limit_1", "U16"},
    {"rcRates_2", "U8"}, {"rcExpo_2", "U8"}, {"rates_2", "U8"}, {"response_time_2", "U8"}, {"accel_limit_2", "U16"},
    {"rcRates_3", "U8"}, {"rcExpo_3", "U8"}, {"rates_3", "U8"}, {"response_time_3", "U8"}, {"accel_limit_3", "U16"},
    {"rcRates_4", "U8"}, {"rcExpo_4", "U8"}, {"rates_4", "U8"}, {"response_time_4", "U8"}, {"accel_limit_4", "U16"},
    {"setpoint_boost_gain_1", "U8"}, {"setpoint_boost_cutoff_1", "U8"},
    {"setpoint_boost_gain_2", "U8"}, {"setpoint_boost_cutoff_2", "U8"},
    {"setpoint_boost_gain_3", "U8"}, {"setpoint_boost_cutoff_3", "U8"},
    {"setpoint_boost_gain_4", "U8"}, {"setpoint_boost_cutoff_4", "U8"},
    {"yaw_dynamic_ceiling_gain", "U8"}, {"yaw_dynamic_deadband_gain", "U8"}, {"yaw_dynamic_deadband_filter", "U8"},
    {"cyclic_ring", "U8"}, {"cyclic_polarity", "U8"}
}

-- Actual rates without polar cyclic: the rate profile the Tune Advisor's simulator reply
-- (tune_advisor.lua) was flown on, so the two describe one helicopter.
local SIM_RESPONSE = {
    4,18,25,24,20,0,0,
    18,25,24,20,0,0,
    18,50,40,10,0,0,
    56,0,56,20,0,0,
    0,15,0,90,0,15,0,15,30,30,60,150,0
}

local function to_u16(lo, hi)
    lo = tonumber(lo) or 0
    hi = tonumber(hi) or 0
    return ((hi & 0xFF) << 8) | (lo & 0xFF)
end

-- Caps a value at the ceiling of the field it is about to be written into. The wire carries
-- one byte for a U8 field and two for a U16, and masking a larger value silently turns it into
-- an unrelated one -- 300 becomes 44, a rate the pilot never asked for. Capping keeps the
-- nearest value the field can express. Every field below is read unsigned by the flight
-- controller (MSP_SET_RC_TUNING in src/main/msp/msp.c), so flooring at zero cannot truncate a
-- negative value that would have meant something.
local function clamp_unsigned(v, ceiling)
    v = tonumber(v) or 0
    if v < 0 then v = 0 elseif v > ceiling then v = ceiling end
    return math.floor(v)
end

local function from_u16(v)
    v = clamp_unsigned(v, 0xFFFF)
    return v & 0xFF, (v >> 8) & 0xFF
end

local function expected_bytes(spec)
    local n = 0
    for _, t in ipairs(spec) do
        local typ = t[2]
        if typ == "U8" then n = n + 1
        elseif typ == "U16" then n = n + 2
        else n = n + 1 end
    end
    return n
end

Api.simulatorResponse = (function()
    local t = {}
    for _, b in ipairs(SIM_RESPONSE) do t[#t+1] = b end
    return t
end)()

function Api.parse(buf)
    if type(buf) ~= "table" then return nil end
    local need = expected_bytes(FIELD_SPEC)
    if #buf < need then return nil end
    local out = {}
    local i = 1
    for _, t in ipairs(FIELD_SPEC) do
        local name, typ = t[1], t[2]
        if typ == "U8" then out[name] = tonumber(buf[i]) or 0; i = i + 1
        elseif typ == "U16" then out[name] = to_u16(buf[i], buf[i+1]); i = i + 2
        else out[name] = tonumber(buf[i]) or 0; i = i + 1 end
    end
    return out
end

function Api.buildWritePayload(data)
    data = data or {}
    local p = {}
    for _, t in ipairs(FIELD_SPEC) do
        local name, typ = t[1], t[2]
        local val = data[name] or 0
        if typ == "U8" then p[#p+1] = clamp_unsigned(val, 0xFF)
        elseif typ == "U16" then local lo, hi = from_u16(val); p[#p+1] = lo; p[#p+1] = hi
        else p[#p+1] = clamp_unsigned(val, 0xFF) end
    end
    return p
end

return Api
