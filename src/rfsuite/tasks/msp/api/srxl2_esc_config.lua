-- EdgeTX MSP API: MSP2_GET_SRXL2_ESC_CONFIG / MSP2_SET_SRXL2_ESC_CONFIG
-- The SRXL2 ESC bus settings (firmware pg/srxl2_esc.h). A firmware built without
-- the SRXL2 ESC driver, or older than the message, answers the read with an error
-- reply. The flight controller applies a write at its next boot.
--
-- Read reply, payload version 1:
--   U8 version, U16 throttle_rate_hz, U8 telem_interval_frames, U8 motor2_channel
-- Write: the same three fields without the version byte; the firmware refuses any
-- other length.
local Api = {
  command = 0x5F16,
  writeCommand = 0x5F17,
  PAYLOAD_VERSION = 1,
  -- Firmware defaults (pg/srxl2_esc.c): 250 Hz, telemetry every 7 frames, motor 2 off.
  simulatorResponse = { 1, 250, 0, 7, 0 }
}

-- A reply of another payload version is not decoded: the page writes back what it
-- read, so a record laid out differently must not turn into numbers that a save
-- would store. Bytes after the version-1 fields are ignored.
function Api.parse(buf)
  if type(buf) ~= "table" or #buf < 5 then return nil end
  if tonumber(buf[1]) ~= Api.PAYLOAD_VERSION then return nil end
  return {
    throttle_rate_hz = ((tonumber(buf[3]) or 0) & 0xFF) << 8 | ((tonumber(buf[2]) or 0) & 0xFF),
    telem_interval_frames = (tonumber(buf[4]) or 0) & 0xFF,
    motor2_channel = (tonumber(buf[5]) or 0) & 0xFF
  }
end

-- Exactly four bytes. The throttle rate is the one the read returned: the firmware
-- derives it from the motor update frequency, so it is carried through unchanged.
function Api.buildWritePayload(data)
  data = data or {}
  local rate = (tonumber(data.throttle_rate_hz) or 250) & 0xFFFF
  return {
    rate & 0xFF,
    (rate >> 8) & 0xFF,
    (tonumber(data.telem_interval_frames) or 0) & 0xFF,
    (tonumber(data.motor2_channel) or 0) & 0xFF
  }
end

return Api
