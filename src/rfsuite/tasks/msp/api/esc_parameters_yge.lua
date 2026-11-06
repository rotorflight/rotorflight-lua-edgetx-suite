-- Ported ESC_PARAMETERS_YGE -> esc_parameters_yge.lua
local Api = {
    command = 217,
    writeCommand = 218,
    mspSignature = 0xA5,
    mspHeaderBytes = 2
}

local FIELD_SPEC = {
    {"esc_signature","U8"}, {"esc_command","U8"}, {"esc_model","U8"}, {"esc_version","U8"},
    {"governor","U16"}, {"lv_bec_voltage","U16"}, {"timing","U16"}, {"acceleration","U16"},
    {"gov_p","U16"}, {"gov_i","U16"}, {"throttle_response","U16"}, {"auto_restart_time","U16"},
    {"cell_cutoff","U16"}, {"active_freewheel","U16"}, {"esc_type","U16"}, {"firmware_version","U32"},
    {"serial_number","U32"}, {"unknown_1","U16"}, {"stick_zero_us","U16"}, {"stick_range_us","U16"},
    {"unknown_2","U16"}, {"motor_poll_pairs","U16"}, {"pinion_teeth","U16"}, {"main_teeth","U16"},
    {"min_start_power","U16"}, {"max_start_power","U16"}, {"unknown_3","U16"}, {"flags","U8"},
    {"unknown_4","U8"}, {"current_limit","U16"},
    -- The last eight bytes of the block. Their meaning is unknown here, as it is in the older
    -- suite this layout comes from -- but they are part of what the ESC sends and of what it
    -- expects back. The firmware sizes the payload as 2 + 2 * N from the parameter count the
    -- ESC reports in the first U16, and this fixture reports 32, so the block is 66 bytes.
    -- Without these a write is eight bytes short and the firmware reads past its end.
    {"unknown_5","U32"}, {"unknown_6","U32"}
}

-- 66 bytes, matching the field spec above. The previous fixture was 52: it left three U16s out
-- of the middle of the block -- startup response, cutoff cell voltage and active freewheel --
-- so every field from `acceleration` onwards decoded the value belonging to a later one.
-- `auto_restart_time` came out as 848, which is the esc_type, and `cell_cutoff` as 38019,
-- which is half of a firmware version.
local SIM_RESPONSE = {
    165,0,  32,0,  3,0,  55,0,  0,0,  0,0,  4,0,  3,0,  1,0,  1,0,  2,0,  3,0,  80,3,
    131,148,1,0,  30,170,0,0,
    3,0,  86,4,  22,3,  163,15,  1,0,  2,0,  2,0,  20,0,  20,0,  0,0,
    0,  0,  2,19,
    2,0,20,0,  22,0,0,0
}

-- The motor timing word is not the position of the entry the page offers. The ESC spells the
-- four automatic modes 16..19 and the six fixed advance angles 1..6, with 0 a second spelling
-- of the first automatic mode; 7..15 and everything above 19 are not values it defines. The
-- page works in list positions, so the word is decoded on the way in and encoded again on the
-- way out. The two tables are deliberately not each other's inverse: reading folds both 0 and
-- 16 onto the first automatic mode, writing spells that mode 0.
local MOTOR_TIMING_TO_UI = {
    [0] = 0, [1] = 4, [2] = 5, [3] = 6, [4] = 7, [5] = 8, [6] = 9,
    [16] = 0, [17] = 1, [18] = 2, [19] = 3
}

local MOTOR_TIMING_FROM_UI = {
    [0] = 0, [1] = 17, [2] = 18, [3] = 19, [4] = 1,
    [5] = 2, [6] = 3, [7] = 4, [8] = 5, [9] = 6
}

local function motor_timing_to_ui(raw)
    return MOTOR_TIMING_TO_UI[raw] or 0
end

local function motor_timing_from_ui(value, raw)
    -- A field still standing on the entry the ESC's own word was decoded to writes that word
    -- back rather than the canonical spelling of the same entry, so a save that changed
    -- nothing changes nothing in the ESC. The table is indexed rather than decoded here on
    -- purpose: an undefined word decodes to the first automatic mode like everything else the
    -- ESC does not define, and keeping it would mean a pilot who deliberately picks that mode
    -- leaves the undefined word in place on a page that says he changed it.
    if raw ~= nil and MOTOR_TIMING_TO_UI[raw] == value then return raw end
    return MOTOR_TIMING_FROM_UI[value] or 0
end

local TYPE_LEN = {U8=1,S8=1,U16=2,S16=2,U24=3,U32=4,U64=8,U120=15,U128=16}

local function has_big_flag(field)
    for _, v in ipairs(field) do if v == "big" then return true end end
    return false
end

local function read_unsigned(buf,pos,len,big)
    local v=0
    if big then for i=0,len-1 do v=v*256+(tonumber(buf[pos+i]) or 0) end
    else local mul=1; for i=0,len-1 do v=v+(tonumber(buf[pos+i]) or 0)*mul; mul=mul*256 end end
    return v
end

local function read_signed(buf,pos,len,big)
    local v=read_unsigned(buf,pos,len,big)
    local max=2^(len*8); local half=2^(len*8-1)
    if v>=half then v=v-max end; return v
end

local function bytes_to_string(buf,pos,len)
    local chars={}
    for i=0,len-1 do chars[#chars+1]=string.char(tonumber(buf[pos+i]) or 0) end
    local s=table.concat(chars)
    s=string.gsub(s, '%z+$','')
    s=string.gsub(s, '%s+$','')
    return s
end

-- EdgeTX builds Lua with 32-bit integers and single-precision floats.
-- Use integer operations: division can round U32 values >=2^24 before byte extraction.
local function pack_unsigned(v,len,big)
    v=tonumber(v) or 0
    local n=math.tointeger(v) or math.tointeger(math.floor(v)) or 0
    local out={}
    if big then for i=len-1,0,-1 do out[#out+1]=(n>>(8*i))&0xFF end
    else for i=0,len-1 do out[#out+1]=(n>>(8*i))&0xFF end end
    return out
end

local function pack_string(s,len)
    s=s or ''; local out={}
    for i=1,len do out[#out+1]=string.byte(s, i) or 0 end; return out
end

Api.fields = FIELD_SPEC
Api.simulatorResponse = SIM_RESPONSE

function Api.parse(buf)
    if type(buf)~='table' then return nil end
    -- The flight controller puts the ESC family it detected in the first byte of the block.
    -- A reply from another family decodes into this layout without error, the page adopts it
    -- as the ESC's state, and a save writes it back; refuse it instead, which the caller
    -- already treats as 'no data'.
    -- OpenYGE sizes the block from its declared parameter count. Keep decoding compatible
    -- with the tools page, but expose coverage so transactions can reject truncated reads.
    if tonumber(buf[1]) ~= Api.mspSignature then return nil end
    local count = #buf >= 4 and read_unsigned(buf,3,2,false) or nil
    local declaredBytes = count and Api.mspHeaderBytes + 2 * count or 0
    local pos=1; local out={_parameterCount=count, _receivedBytes=#buf, _present={},
        _complete=count ~= nil and #buf >= declaredBytes, _tail={}}
    for _, f in ipairs(FIELD_SPEC) do
        local name, typ = f[1], f[2]
        local len = TYPE_LEN[typ] or 1; local big = has_big_flag(f)
        out._present[name] = pos + len - 1 <= math.min(#buf, declaredBytes)
        if typ=='U120' or typ=='U128' then out[name]=bytes_to_string(buf,pos,len); pos=pos+len
        elseif string.sub(typ, 1, 1)=='S' then out[name]=read_signed(buf,pos,len,big); pos=pos+len
        else out[name]=read_unsigned(buf,pos,len,big); pos=pos+len end
    end
    for i=pos,math.min(#buf,declaredBytes) do out._tail[#out._tail+1]=buf[i] end
    out.timing_raw = out.timing
    out.timing = motor_timing_to_ui(out.timing)
    return out
end

function Api.buildWritePayload(data)
    data=data or {}; local payload={}
    for _, f in ipairs(FIELD_SPEC) do
        local name, typ = f[1], f[2]; local len = TYPE_LEN[typ] or 1; local big = has_big_flag(f)
        local v = data[name]
        if name=='timing' then v = motor_timing_from_ui(v, data.timing_raw) end
        if typ=='U120' or typ=='U128' then local b=pack_string(v,len); for _,x in ipairs(b) do payload[#payload+1]=x end
        else local b=pack_unsigned(v or 0,len,big); for _,x in ipairs(b) do payload[#payload+1]=x end end
    end
    if data._parameterCount then
        local length = Api.mspHeaderBytes + 2 * data._parameterCount
        for i=#payload,length+1,-1 do payload[i]=nil end
        for _,b in ipairs(data._tail or {}) do payload[#payload+1]=b end
    end
    return payload
end

return Api
