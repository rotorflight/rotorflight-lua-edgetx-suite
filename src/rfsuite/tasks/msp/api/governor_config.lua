-- EdgeTX MSP API: governor_config (ported from Ethos)

local Api = {
  command = 142,
  writeCommand = 143,
  simulatorResponse = {
    -- matches Rotorflight Ethos >=12.0.9 layout (values from source)
    3,       -- gov_mode
    200, 0,  -- gov_startup_time
    100, 0,  -- gov_spoolup_time
    20, 0,   -- gov_tracking_time
    20, 0,   -- gov_recovery_time
    50, 0,   -- gov_throttle_hold_timeout
    0, 0,    -- spare_0
    0, 0,    -- gov_autorotation_timeout
    0, 0,    -- spare_1
    0, 0,    -- spare_2
    20,      -- gov_handover_throttle
    20,      -- gov_pwr_filter
    20,      -- gov_rpm_filter
    0,       -- gov_tta_filter
    10,      -- gov_ff_filter
    0,       -- spare_3
    50,      -- gov_d_filter
    30, 0,   -- gov_spooldown_time
    0,       -- gov_throttle_type
    0,       -- spare_4
    0,       -- spare_5
    10,      -- governor_idle_throttle
    10,      -- governor_auto_throttle
    0,       -- gov_bypass_throttle_curve_1
    10,      -- gov_bypass_throttle_curve_2
    20,      -- gov_bypass_throttle_curve_3
    30,      -- gov_bypass_throttle_curve_4
    50,      -- gov_bypass_throttle_curve_5
    60,      -- gov_bypass_throttle_curve_6
    70,      -- gov_bypass_throttle_curve_7
    80,      -- gov_bypass_throttle_curve_8
    100      -- gov_bypass_throttle_curve_9
  }
}

local function to_u16(lo, hi)
  lo = tonumber(lo) or 0
  hi = tonumber(hi) or 0
  return ((hi & 0xFF) << 8) | (lo & 0xFF)
end

local function from_u16(v)
  v = math.floor(tonumber(v) or 0) & 0xFFFF
  return v & 0xFF, (v >> 8) & 0xFF
end

function Api.parse(buf)
  if type(buf) ~= "table" then return nil end
  -- minimal expected length for the >=12.0.9 layout
  if #buf < 36 then return nil end
  local i = 1
  local out = {}
  out.gov_mode = tonumber(buf[i]); i = i + 1
  out.gov_startup_time = to_u16(buf[i], buf[i+1]); i = i + 2
  out.gov_spoolup_time = to_u16(buf[i], buf[i+1]); i = i + 2
  out.gov_tracking_time = to_u16(buf[i], buf[i+1]); i = i + 2
  out.gov_recovery_time = to_u16(buf[i], buf[i+1]); i = i + 2
  out.gov_throttle_hold_timeout = to_u16(buf[i], buf[i+1]); i = i + 2
  out.spare_0 = to_u16(buf[i], buf[i+1]); i = i + 2
  out.gov_autorotation_timeout = to_u16(buf[i], buf[i+1]); i = i + 2
  out.spare_1 = to_u16(buf[i], buf[i+1]); i = i + 2
  out.spare_2 = to_u16(buf[i], buf[i+1]); i = i + 2
  out.gov_handover_throttle = tonumber(buf[i]); i = i + 1
  out.gov_pwr_filter = tonumber(buf[i]); i = i + 1
  out.gov_rpm_filter = tonumber(buf[i]); i = i + 1
  out.gov_tta_filter = tonumber(buf[i]); i = i + 1
  out.gov_ff_filter = tonumber(buf[i]); i = i + 1
  out.spare_3 = tonumber(buf[i]); i = i + 1
  out.gov_d_filter = tonumber(buf[i]); i = i + 1
  out.gov_spooldown_time = to_u16(buf[i], buf[i+1]); i = i + 2
  out.gov_throttle_type = tonumber(buf[i]); i = i + 1
  out.spare_4 = (tonumber(buf[i]) or 0); i = i + 1
  out.spare_5 = (tonumber(buf[i]) or 0); i = i + 1
  out.governor_idle_throttle = tonumber(buf[i]); i = i + 1
  out.governor_auto_throttle = tonumber(buf[i]); i = i + 1
  -- read bypass throttle curve bytes (9 entries)
  for j = 1, 9 do
    out["gov_bypass_throttle_curve_"..j] = tonumber(buf[i]) or 0; i = i + 1
  end
  return out
end

function Api.buildWritePayload(data)
  data = data or {}
  local p = {}
  local function push(v) p[#p+1] = v end
  push(data.gov_mode or 0)
  local lo, hi = from_u16(data.gov_startup_time or 200); push(lo); push(hi)
  lo, hi = from_u16(data.gov_spoolup_time or 100); push(lo); push(hi)
  lo, hi = from_u16(data.gov_tracking_time or 10); push(lo); push(hi)
  lo, hi = from_u16(data.gov_recovery_time or 21); push(lo); push(hi)
  lo, hi = from_u16(data.gov_throttle_hold_timeout or 5); push(lo); push(hi)
  lo, hi = from_u16(data.spare_0 or 0); push(lo); push(hi)
  lo, hi = from_u16(data.gov_autorotation_timeout or 0); push(lo); push(hi)
  lo, hi = from_u16(data.spare_1 or 0); push(lo); push(hi)
  lo, hi = from_u16(data.spare_2 or 0); push(lo); push(hi)
  push(data.gov_handover_throttle or 20)
  push(data.gov_pwr_filter or 20)
  push(data.gov_rpm_filter or 20)
  push(data.gov_tta_filter or 0)
  push(data.gov_ff_filter or 10)
  push(data.spare_3 or 0)
  push(data.gov_d_filter or 50)
  lo, hi = from_u16(data.gov_spooldown_time or 100); push(lo); push(hi)
  push(data.gov_throttle_type or 0)
  push(data.spare_4 or 0)
  push(data.spare_5 or 0)
  push(data.governor_idle_throttle or 10)
  push(data.governor_auto_throttle or 10)
  for j = 1, 9 do push(data["gov_bypass_throttle_curve_"..j] or 0) end
  return p
end

--- Does writing `write` store anything other than what `read` holds? Both records are compared as
-- the bytes MSP_SET_GOVERNOR_CONFIG would carry, so a field no page shows and a value the builder
-- normalises count exactly as they would on the wire.
function Api.payloadDiffers(read, write)
  local a = Api.buildWritePayload(read)
  local b = Api.buildWritePayload(write)
  if #a ~= #b then return true end
  for i = 1, #a do
    if a[i] ~= b[i] then return true end
  end
  return false
end

return Api
