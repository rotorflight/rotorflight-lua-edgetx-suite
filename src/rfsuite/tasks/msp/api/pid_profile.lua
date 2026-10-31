-- Ported PID_PROFILE -> pid_profile.lua
local Api = {
    command = 94,
    writeCommand = 95
}

local FIELD_SPEC = {
    {"pid_mode", "U8"},
    {"error_decay_time_ground", "U8"},
    {"error_decay_time_cyclic", "U8"},
    {"error_decay_time_yaw", "U8"},
    {"error_decay_limit_cyclic", "U8"},
    {"error_decay_limit_yaw", "U8"},
    {"error_rotation", "U8"},
    {"error_limit_0", "U8"},
    {"error_limit_1", "U8"},
    {"error_limit_2", "U8"},
    {"gyro_cutoff_0", "U8"},
    {"gyro_cutoff_1", "U8"},
    {"gyro_cutoff_2", "U8"},
    {"dterm_cutoff_0", "U8"},
    {"dterm_cutoff_1", "U8"},
    {"dterm_cutoff_2", "U8"},
    {"iterm_relax_type", "U8"},
    {"iterm_relax_cutoff_0", "U8"},
    {"iterm_relax_cutoff_1", "U8"},
    {"iterm_relax_cutoff_2", "U8"},
    {"yaw_cw_stop_gain", "U8"},
    {"yaw_ccw_stop_gain", "U8"},
    {"yaw_precomp_cutoff", "U8"},
    {"yaw_cyclic_ff_gain", "U8"},
    {"yaw_collective_ff_gain", "U8"},
    {"yaw_collective_dynamic_gain", "U8"},
    {"yaw_collective_dynamic_decay", "U8"},
    {"pitch_collective_ff_gain", "U8"},
    {"angle_level_strength", "U8"},
    {"angle_level_limit", "U8"},
    {"horizon_level_strength", "U8"},
    {"trainer_gain", "U8"},
    {"trainer_angle_limit", "U8"},
    {"cyclic_cross_coupling_gain", "U8"},
    {"cyclic_cross_coupling_ratio", "U8"},
    {"cyclic_cross_coupling_cutoff", "U8"},
    {"offset_limit_0", "U8"},
    {"offset_limit_1", "U8"},
    {"bterm_cutoff_0", "U8"},
    {"bterm_cutoff_1", "U8"},
    {"bterm_cutoff_2", "U8"},
    {"yaw_inertia_precomp_gain", "U8"},
    {"yaw_inertia_precomp_cutoff", "U8"}
}

-- error_decay_gain_cyclic follows FIELD_SPEC as the next byte from MSP API 12.10 (firmware 4.7)
-- on. The read takes it whenever the reply carries it, so a shorter reply still parses. The write
-- sends it only to a flight controller that reports 12.10 or later: firmware 4.6 (API 12.9) leaves
-- a trailing byte here unread and still acknowledges the write, so the value would be dropped
-- without a word, while 4.7 reads the byte only when one is left, so a write without it keeps the
-- stored value.
local ERROR_DECAY_GAIN_CYCLIC = "error_decay_gain_cyclic"

-- The cyclic and yaw master gains (U8, percent, 25..200) follow it on firmware that has them. They
-- came without an API version change, so a 12.10 board may or may not send them, and only the
-- length of the reply tells. Every parse records that answer as `session.hasMasterGain`, and the
-- MSP runtime clears it on disconnect. The PID Controller row, its help line, the Adjustments
-- functions 83 and 84 and the write below all go by it: the PID profile pages merge each read into
-- one shared table and never remove a key, so gains read from an earlier board can still be in it
-- after a read from a board without them, and must then be neither shown nor sent.
local CYCLIC_MASTER_GAIN = "cyclic_master_gain"
local YAW_MASTER_GAIN = "yaw_master_gain"

-- The simulator answers MSP_API_VERSION with 12.9, so its reply ends before the 12.10 field. The
-- I-term relax cut-offs are the ones the Tune Advisor's simulator reply (tune_advisor.lua) carries.
local SIM_RESPONSE = {
    3,25,250,0,12,0,1,45,45,60,50,50,100,15,15,20,2,10,10,10,100,100,6,0,30,0,0,0,40,55,0,75,20,25,0,15,90,90,15,15,20,10,20
}

-- lib/api_version.lua decides the write gate, as it decides the page's row and its help line, so
-- the three give one answer for every form of session.apiVersion it accepts. It is loaded on the
-- first write rather than when this file loads, so opening a page that reads the profile does not
-- pay for it; lib/require.lua hands back the copy the MSP runtime has normally loaded already.
-- The modules under tasks/msp/api/ are leaf decoders that load nothing; this one is the exception
-- on purpose, because its write gate needs the predicate the rest of the suite shares.
local ApiVersion = nil

local function loadApiVersion()
    if ApiVersion == nil then
        local root = _G and _G.rfsuite
        local req = root and root.require
        local mod = nil
        if type(req) == "function" then
            mod = req("lib/api_version.lua")
        else
            local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/api_version.lua", (root and root.loadMode) or "bt")
            if type(chunk) == "function" then
                local ok, res = pcall(chunk)
                if ok then mod = res end
            end
        end
        ApiVersion = (type(mod) == "table" and type(mod.isAtLeast) == "function") and mod or false
    end
    return ApiVersion or nil
end

-- Without a version the session reports, the byte is not sent.
local function sessionApiAtLeast12_10()
    local root = _G and _G.rfsuite
    local session = root and root.session
    local raw = type(session) == "table" and session.apiVersion or nil
    if raw == nil then return false end
    local V = loadApiVersion()
    return V ~= nil and V.isAtLeast(raw, { 12, 0, 10 }) == true
end

local function sessionHasMasterGain()
    local root = _G and _G.rfsuite
    local session = root and root.session
    return type(session) == "table" and session.hasMasterGain == true
end

local function expected_bytes(spec)
    local n = 0
    for _, f in ipairs(spec) do
        local typ = f[2]
        if typ == "U8" or typ == "S8" then n = n + 1
        elseif typ == "U16" or typ == "S16" then n = n + 2
        else n = n + 1 end
    end
    return n
end

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
    local need = expected_bytes(FIELD_SPEC)
    if #buf < need then return nil end
    local out = {}
    local i = 1
    for _, t in ipairs(FIELD_SPEC) do
        local name, typ = t[1], t[2]
        if typ == "U8" then out[name] = tonumber(buf[i]) or 0; i = i + 1
        elseif typ == "S8" then local v = tonumber(buf[i]) or 0; if v >= 128 then v = v - 256 end; out[name] = v; i = i + 1
        elseif typ == "U16" then out[name] = to_u16(buf[i], buf[i+1]); i = i + 2
        else out[name] = tonumber(buf[i]) or 0; i = i + 1 end
    end
    if #buf > need then
        out[ERROR_DECAY_GAIN_CYCLIC] = tonumber(buf[need + 1]) or 0
    end
    local hasMasterGain = #buf >= need + 3
    if hasMasterGain then
        out[CYCLIC_MASTER_GAIN] = tonumber(buf[need + 2]) or 0
        out[YAW_MASTER_GAIN] = tonumber(buf[need + 3]) or 0
    end
    local root = _G and _G.rfsuite
    if type(root) == "table" and type(root.session) == "table" then
        root.session.hasMasterGain = hasMasterGain
    end
    return out
end

function Api.buildWritePayload(data)
    data = data or {}
    local p = {}
    for _, t in ipairs(FIELD_SPEC) do
        local name, typ = t[1], t[2]
        local val = data[name] or 0
        if typ == "U8" or typ == "S8" then p[#p+1] = val & 0xFF
        elseif typ == "U16" then local lo, hi = from_u16(val); p[#p+1] = lo; p[#p+1] = hi
        else p[#p+1] = val & 0xFF end
    end
    local gain = data[ERROR_DECAY_GAIN_CYCLIC]
    if type(gain) == "number" and sessionApiAtLeast12_10() then
        p[#p+1] = math.floor(gain) & 0xFF
        -- Only behind the decay gain, which the firmware reads first, and only while this link's
        -- last reply carried the master gains.
        local cyclic, yaw = data[CYCLIC_MASTER_GAIN], data[YAW_MASTER_GAIN]
        if type(cyclic) == "number" and type(yaw) == "number" and sessionHasMasterGain() then
            p[#p+1] = math.floor(cyclic) & 0xFF
            p[#p+1] = math.floor(yaw) & 0xFF
        end
    end
    return p
end

return Api
