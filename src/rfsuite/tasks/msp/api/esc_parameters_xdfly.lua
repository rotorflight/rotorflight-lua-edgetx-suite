-- Ported ESC_PARAMETERS_XDFLY -> esc_parameters_xdfly.lua
local Api = {
    command = 217,
    writeCommand = 218,
    mspSignature = 0xA6,
    mspHeaderBytes = 2
}

local FIELD_SPEC = {
    {"esc_signature","U8"}, {"esc_command","U8"}, {"esc_version","U8"}, {"esc_model","U8"},
    {"governor","U16"}, {"cell_cutoff","U16"}, {"timing","U16"}, {"lv_bec_voltage","U16"},
    {"motor_direction","U16"}, {"gov_p","U16"}, {"gov_i","U16"}, {"acceleration","U16"},
    {"auto_restart_time","U16"}, {"hv_bec_voltage","U16"}, {"startup_power","U16"}, {"brake_type","U16"},
    {"brake_force","U16"}, {"sr_function","U16"}, {"capacity_correction","U16"}, {"motor_poles","U16"},
    {"led_color","U16"}, {"smart_fan","U16"}, {"activefields","U32"}
}

-- The flight controller sends twenty-one 16-bit parameters behind a two-byte header, so
-- the block is 44 bytes. This fixture was 28: the same values in the same order as the
-- sibling module's, with sixteen zero bytes missing from three interior runs, which left
-- the last four bytes reading as two parameters instead of as the activity mask.
local SIM_RESPONSE = {
    166, -- esc_signature
    0, -- esc_command
    23, -- esc_model
    3, -- esc_version
    0, 0, -- governor
    0, 0, -- cell_cutoff
    0, 0, -- timing
    0, 0, -- lv_bec_voltage
    0, 0, -- motor_direction
    4, 0, -- gov_p
    3, 0, -- gov_i
    0, 0, -- acceleration
    0, 0, -- auto_restart_time
    0, 0, -- hv_bec_voltage
    0, 0, -- startup_power
    0, 0, -- brake_type
    0, 0, -- brake_force
    0, 0, -- sr_function
    0, 0, -- capacity_correction
    9, 0, -- motor_poles
    0, 0, -- led_color
    0, 0, -- smart_fan
    238, 255, 1, 0 -- activefields (U32 little)
}

-- Three of the block's words are stored one below the number Rotorflight's other
-- configuration tools show for them, so the value on the page and the value on the wire are
-- not the same number. The fourth biased word, capacity_correction, is absent here on
-- purpose: the page already carries that one, in the display function of its own control.
local WIRE_OFFSET = {
    gov_p = 1,
    gov_i = 1,
    motor_poles = 1
}

local TYPE_LEN = {U8=1,S8=1,U16=2,S16=2,U24=3,U32=4,U64=8,U120=15,U128=16}

-- How many bytes FIELD_SPEC describes. A shorter reply does not fail to parse: read_unsigned
-- substitutes 0 for a byte that is not there, so the tail of the block comes out zero -- and
-- buildWritePayload writes those zeros straight back on the next save.
local PAYLOAD_LEN = 0
for _, f in ipairs(FIELD_SPEC) do PAYLOAD_LEN = PAYLOAD_LEN + (TYPE_LEN[f[2]] or 1) end

local function has_big_flag(field)
    for _, v in ipairs(field) do if v == "big" then return true end end
    return false
end

local function read_unsigned(buf,pos,len,big)
    local v = 0
    if big then for i=0,len-1 do v = v*256 + (tonumber(buf[pos+i]) or 0) end
    else local mul=1; for i=0,len-1 do v = v + (tonumber(buf[pos+i]) or 0) * mul; mul = mul*256 end end
    return v
end

local function read_signed(buf,pos,len,big)
    local v = read_unsigned(buf,pos,len,big)
    local max = 2^(len*8)
    local half = 2^(len*8-1)
    if v >= half then v = v - max end
    return v
end

local function bytes_to_string(buf,pos,len)
    local chars={}
    for i=0,len-1 do chars[#chars+1]=string.char(tonumber(buf[pos+i]) or 0) end
    local s=table.concat(chars)
    s=string.gsub(s, '%z+$','')
    s=string.gsub(s, '%s+$','')
    return s
end

local function pack_unsigned(v,len,big)
    v = tonumber(v) or 0
    local out={}
    if big then for i=len-1,0,-1 do out[#out+1]=math.floor(v/(256^i))%256 end
    else for i=0,len-1 do out[#out+1]=math.floor(v/(256^i))%256 end end
    return out
end

local function pack_string(s,len)
    s=s or ''
    local out={}
    for i=1,len do out[#out+1]=string.byte(s, i) or 0 end
    return out
end

Api.fields = FIELD_SPEC
Api.simulatorResponse = SIM_RESPONSE

function Api.parse(buf)
    if type(buf)~='table' then return nil end
    -- The flight controller sizes this block from its own parameter table and puts the ESC
    -- family it detected in the first byte. A short reply, and a reply from another family,
    -- both decode into this layout without error and both become a write on the next save.
    if #buf < PAYLOAD_LEN then return nil end
    if tonumber(buf[1]) ~= Api.mspSignature then return nil end
    local pos=1; local out={}
    for _, f in ipairs(FIELD_SPEC) do
        local name, typ = f[1], f[2]
        local len = TYPE_LEN[typ] or 1
        local big = has_big_flag(f)
        if typ=='U120' or typ=='U128' then out[name]=bytes_to_string(buf,pos,len); pos=pos+len
        elseif string.sub(typ, 1, 1)=='S' then out[name]=read_signed(buf,pos,len,big); pos=pos+len
        else out[name]=read_unsigned(buf,pos,len,big); pos=pos+len end
    end
    for name, bias in pairs(WIRE_OFFSET) do
        if out[name] ~= nil then out[name] = out[name] + bias end
    end
    return out
end

function Api.buildWritePayload(data)
    data = data or {}
    local payload={}
    for _, f in ipairs(FIELD_SPEC) do
        local name, typ = f[1], f[2]
        local len = TYPE_LEN[typ] or 1
        local big = has_big_flag(f)
        local v = data[name]
        local bias = WIRE_OFFSET[name]
        if bias then
            local n = tonumber(v)
            -- A field the caller never supplied keeps packing as zero, and a shifted value is
            -- never taken below zero: 0xFFFF is what the ESC answers a write it refused, so a
            -- word of that shape must not be built here.
            if n then
                v = n - bias
                if v < 0 then v = 0 end
            end
        end
        if typ=='U120' or typ=='U128' then local b=pack_string(v,len); for _,x in ipairs(b) do payload[#payload+1]=x end
        else local b=pack_unsigned(v or 0,len,big); for _,x in ipairs(b) do payload[#payload+1]=x end end
    end
    return payload
end

return Api
