-- EdgeTX MSP API: rpm_filter_v2 (ported from Ethos)
-- Helicopter Setup reads custom notch sources to check whether the RPM filter needs a signal.

local Api = {
  command = 154,
  writeCommand = 155,
  -- One axis: 16 notches of source (u8), center (u16) and Q (u8), which is what parse() reads.
  simulatorResponse = (function()
    local t = {}
    for i = 1, 16 do
      t[#t+1] = 0; t[#t+1] = 0; t[#t+1] = 0; t[#t+1] = 0
    end
    return t
  end)()
}

local function u16_from_bytes(lo, hi)
  lo = tonumber(lo) or 0
  hi = tonumber(hi) or 0
  return ((hi & 0xFF) << 8) | (lo & 0xFF)
end

local function bytes_from_u16(v)
  v = math.floor(tonumber(v) or 0) & 0xFFFF
  return v & 0xFF, (v >> 8) & 0xFF
end

function Api.buildReadPayload(payloadData, _, _, _, axis)
  local readAxis = tonumber(axis)
  if readAxis == nil then readAxis = tonumber(payloadData and payloadData.axis) end
  if readAxis == nil then readAxis = 0 end
  return {readAxis}
end

function Api.parse(buf)
  if type(buf) ~= "table" or #buf < 64 then return nil end
  local i = 1
  local parsed = {}
  for idx = 1, 16 do
    parsed["notch_source_"..idx] = tonumber(buf[i]); i = i + 1
    parsed["notch_center_"..idx] = u16_from_bytes(buf[i], buf[i+1]); i = i + 2
    parsed["notch_q_"..idx] = tonumber(buf[i]); i = i + 1
  end
  return parsed
end

-- MSP_SET_RPM_FILTER_V2 takes the axis first and then all 16 notches of that axis, 65 bytes in
-- all; the firmware answers anything else with an error. The axis is taken the way the read takes
-- it, from `data.axis`, and defaults to the same 0.
function Api.buildWritePayload(data)
  data = data or {}
  local axis = tonumber(data.axis) or 0
  local p = {axis}
  for idx = 1, 16 do
    p[#p+1] = tonumber(data["notch_source_"..idx]) or 0
    local lo, hi = bytes_from_u16(data["notch_center_"..idx] or 0)
    p[#p+1] = lo; p[#p+1] = hi
    p[#p+1] = tonumber(data["notch_q_"..idx]) or 0
  end
  return p
end

return Api
