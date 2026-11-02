-- Ported PID_TUNING -> pid_tuning.lua
local Api = {
    command = 112,
    writeCommand = 202
}

local FIELD_NAMES = {
    "pid_0_P","pid_0_I","pid_0_D","pid_0_F",
    "pid_1_P","pid_1_I","pid_1_D","pid_1_F",
    "pid_2_P","pid_2_I","pid_2_D","pid_2_F",
    "pid_0_B","pid_1_B","pid_2_B",
    "pid_0_O","pid_1_O"
}

-- P and F as the Tune Advisor's simulator reply (tune_advisor.lua) measured them.
local SIM_RESPONSE = {
    70,0,  -- pid_0_P
    2,0,   -- pid_0_I
    50,0,  -- pid_0_D
    120,0, -- pid_0_F
    100,0, -- pid_1_P
    2,0,   -- pid_1_I
    50,0,  -- pid_1_D
    120,0, -- pid_1_F
    100,0, -- pid_2_P
    3,0,   -- pid_2_I
    70,0,  -- pid_2_D
    0,0,   -- pid_2_F
    0,0,   -- pid_0_B
    0,0,   -- pid_1_B
    0,0,   -- pid_2_B
    0,0,   -- pid_0_O
    0,0    -- pid_1_O
}

local function to_u16(lo, hi)
    lo = tonumber(lo) or 0
    hi = tonumber(hi) or 0
    return ((hi & 0xFF) << 8) | (lo & 0xFF)
end

local function from_u16(v)
    v = tonumber(v) or 0
    v = v & 0xFFFF
    return v & 0xFF, (v >> 8) & 0xFF
end

Api.simulatorResponse = (function()
    local t = {}
    for _, b in ipairs(SIM_RESPONSE) do t[#t+1] = b end
    return t
end)()

function Api.parse(buf)
    if type(buf) ~= "table" then return nil end
    local need = #FIELD_NAMES * 2
    if #buf < need then return nil end
    local out = {}
    local i = 1
    for _, name in ipairs(FIELD_NAMES) do
        out[name] = to_u16(buf[i], buf[i+1]); i = i + 2
    end
    return out
end

function Api.buildWritePayload(data)
    data = data or {}
    local p = {}
    for _, name in ipairs(FIELD_NAMES) do
        local lo, hi = from_u16(data[name] or 0)
        p[#p+1] = lo; p[#p+1] = hi
    end
    return p
end

return Api
