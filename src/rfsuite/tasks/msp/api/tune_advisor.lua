-- EdgeTX MSP API: TUNE_ADVISOR (MSP2_GET_TUNE_ADVISOR 0x5F10, MSP2_CLEAR_TUNE_ADVISOR 0x5F11)
--
-- The flight controller's in-flight rate-loop statistics, one axis per request. The request
-- payload is U8 axis (0 roll, 1 pitch, 2 yaw); the clear command takes no payload. The reply is
-- 51 bytes, the most one CRSF frame carries (the firmware sends a reply that exactly fills a
-- frame as two), and 12 S.Port/FBUS frames.
--
-- Layout, payload version 3, as serialised by the firmware's MSP2_GET_TUNE_ADVISOR case in
-- src/main/msp/msp.c and decoded by the Ethos suite's lib/msp_tune_advisor.lua:
--
--   U8 version, U8 flags (bits 0-1 axis, bit 2 collecting, bits 3-5 rates_type),
--   U16 seconds of usable flight, then:
--     U32 P | F << 10 | B << 20, U8 iterm_relax_cutoff, U8 rc_rate, U8 s_rate  (the tune measured)
--     U16 ffCount, U8 ffGain x64, S8 ffCorr x100, U8 ffLagMs
--     3 x {U8 gain x64, U16 count}  by request 40-100, 100-200, 200+ deg/s
--     3 x {U8 gain x64, U16 count}  by |collective| <25%, 25-50%, 50%+
--     U16 fullCount, U16 fullSatCount, U8 fullRatio x100, U8 fullMaxRate in 10 deg/s
--     U16 releases, U8 bigRebounds, U8 meanRebound x100, U8 meanOvershoot x64,
--     U8 meanCounter x100, S16 meanIterm x1000
--     U16 shakeCount, U8 shakeRms x4 (deg/s)
--
-- Scaled values are decoded to plain numbers here; the firmware saturates each, and
-- bigRebounds, at its byte's range. Counts saturate at 65535. Versions 1 and 2 (67 and 71
-- bytes, every ratio 16-bit) were never in a firmware release and are refused like any other.
--
-- A reply of another version or length is refused, not decoded: a reworded record would
-- otherwise come out as plausible numbers, and the advice would be built from them. A flight
-- controller without the command answers with an MSP error; the page queues its read with
-- completeOnErrorReplyAttempt = 1 so that this error reply reaches processReply, and parse
-- refuses it too.

local Api = {
  command = 0x5F10,      -- MSP2_GET_TUNE_ADVISOR
  writeCommand = 0x5F11, -- MSP2_CLEAR_TUNE_ADVISOR
}

local PAYLOAD_VERSION = 3
local REPLY_BYTES = 51
local BAND_COUNT = 3
local RATES_TYPE_ACTUAL = 4

-- One-byte values travel as value x scale
local GAIN_SCALE = 64        -- ffGain, band gains, meanOvershoot: U8, 0..3.98
local CORR_SCALE = 100       -- ffCorr: S8, -1.27..1.27
local FRACTION_SCALE = 100   -- fullRatio, meanRebound, meanCounter: U8, 0..2.55
local RATE_STEP = 10         -- fullMaxRate: U8 in steps of 10 deg/s
local SHAKE_SCALE = 4        -- shakeRms: U8, 0..63.75 deg/s
local ITERM_SCALE = 1000     -- meanIterm: S16
local GAIN_BITS = 1024       -- P, F and B: 10 bits each of one U32

Api.REPLY_BYTES = REPLY_BYTES
Api.PAYLOAD_VERSION = PAYLOAD_VERSION

local function u8(buf, i)
  return tonumber(buf[i]) or 0
end

local function s8(buf, i)
  local v = u8(buf, i)
  if v >= 0x80 then v = v - 0x100 end
  return v
end

local function u16(buf, i)
  return u8(buf, i) | (u8(buf, i + 1) << 8)
end

local function s16(buf, i)
  local v = u16(buf, i)
  if v >= 0x8000 then v = v - 0x10000 end
  return v
end

local function u32(buf, i)
  return u16(buf, i) | (u16(buf, i + 2) << 16)
end

--- The decoded record, or nil, a reason and true when the reply is refused: another payload
--- version, another length, or the error reply of a firmware without the command. The record
--- is {version, collecting, seconds, axis (1 roll, 2 pitch, 3 yaw), a = {per-axis fields}}.
function Api.parse(buf)
  if type(buf) ~= "table" then
    return nil, "tune advisor reply missing", true
  end
  local length = #buf
  if buf[1] ~= PAYLOAD_VERSION then
    return nil, "tune advisor payload version " .. tostring(buf[1]) .. ", expected " .. PAYLOAD_VERSION, true
  end
  if length ~= REPLY_BYTES then
    return nil, "tune advisor reply is " .. length .. " bytes, expected " .. REPLY_BYTES, true
  end

  local flags = u8(buf, 2)
  local gains = u32(buf, 5)
  local function bands(first)
    local out = {}
    for i = 1, BAND_COUNT do
      local at = first + (i - 1) * 3
      out[i] = { gain = u8(buf, at) / GAIN_SCALE, count = u16(buf, at + 1) }
    end
    return out
  end

  return {
    version = u8(buf, 1),
    collecting = (flags // 4) % 2 == 1,
    seconds = u16(buf, 3),
    axis = flags % 4 + 1,
    a = {
      P = gains % GAIN_BITS,
      F = (gains // GAIN_BITS) % GAIN_BITS,
      B = (gains // (GAIN_BITS * GAIN_BITS)) % GAIN_BITS,
      ratesType = (flags // 8) % 8,
      relaxCutoff = u8(buf, 9),
      rcRate = u8(buf, 10),
      sRate = u8(buf, 11),
      ffCount = u16(buf, 12),
      ffGain = u8(buf, 14) / GAIN_SCALE,
      ffCorr = s8(buf, 15) / CORR_SCALE,
      ffLagMs = u8(buf, 16),
      spBands = bands(17),
      collBands = bands(26),
      fullCount = u16(buf, 35),
      fullSatCount = u16(buf, 37),
      fullRatio = u8(buf, 39) / FRACTION_SCALE,
      fullMaxRate = u8(buf, 40) * RATE_STEP,
      releases = u16(buf, 41),
      bigRebounds = u8(buf, 43),
      meanRebound = u8(buf, 44) / FRACTION_SCALE,
      meanOvershoot = u8(buf, 45) / GAIN_SCALE,
      meanCounter = u8(buf, 46) / FRACTION_SCALE,
      meanIterm = s16(buf, 47) / ITERM_SCALE,
      shakeCount = u16(buf, 49),
      shakeRms = u8(buf, 51) / SHAKE_SCALE,
    }
  }
end

-- Simulator fixture, one reply per axis (Actual rates, centre 180, max 240): cyclic turning
-- faster than asked with the usual stop bounce, pitch too irregular to judge, tail with little
-- data. The values are the Ethos suite's simulator fixture for the same command.
local SIM_AXES = {
  { p = 70, f = 120, b = 0, cutoff = 10, rcRate = 18, sRate = 24, ffCount = 1491, ff = 1.53, corr = 0.97, lag = 90,
    sp = { { 1.52, 1341 }, { 1.54, 163 }, { 1.03, 50 } }, coll = { { 1.24, 385 }, { 1.54, 763 }, { 1.73, 356 } },
    full = { 87, 25, 0.38, 395 }, rel = { 35, 18, 0.15, 1.47, 0.020, 0.003 }, shake = { 2410, 3.1 } },
  { p = 100, f = 120, b = 0, cutoff = 10, rcRate = 18, sRate = 24, ffCount = 1172, ff = 0.79, corr = 0.78, lag = 70,
    sp = { { 1.06, 999 }, { 0.45, 194 }, { 0, 54 } }, coll = { { 0.28, 446 }, { 1.27, 629 }, { 1.59, 118 } },
    full = { 105, 72, 0, 23 }, rel = { 10, 2, 0.09, 1.33, 0.019, 0.011 }, shake = { 1980, 2.4 } },
  { p = 100, f = 0, b = 0, cutoff = 10, rcRate = 18, sRate = 40, ffCount = 404, ff = 0.27, corr = 0.84, lag = 250,
    sp = { { 0.26, 300 }, { 0.30, 109 }, { 0, 0 } }, coll = { { 0.29, 409 }, { 0, 0 }, { 0, 0 } },
    full = { 29, 29, 0.09, 42 }, rel = { 0, 0, 0, 0, 0, 0 }, shake = { 3120, 1.2 } },
}

local function scaled(v, scale, lo, hi)
  local n = math.floor(v * scale + 0.5)
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

local simulatorResponses = {}

--- The simulator's reply for one axis (1-3), built once and kept.
function Api.simulatorResponseFor(axis)
  local cached = simulatorResponses[axis]
  if cached then return cached end
  local a = SIM_AXES[axis]
  if not a then return nil end

  local buf = {}
  local function w8(v) buf[#buf + 1] = v & 0xFF end
  local function w16(v) w8(v); w8(v >> 8) end
  local function w32(v) w16(v & 0xFFFF); w16(v >> 16) end
  local function wScaled(v, scale) w8(scaled(v, scale, 0, 255)) end

  w8(PAYLOAD_VERSION)
  w8((axis - 1) + RATES_TYPE_ACTUAL * 8)    -- not collecting
  w16(147)
  w32(a.p + a.f * GAIN_BITS + a.b * GAIN_BITS * GAIN_BITS)
  w8(a.cutoff); w8(a.rcRate); w8(a.sRate)
  w16(a.ffCount); wScaled(a.ff, GAIN_SCALE); w8(scaled(a.corr, CORR_SCALE, -128, 127)); w8(a.lag)
  for i = 1, BAND_COUNT do wScaled(a.sp[i][1], GAIN_SCALE); w16(a.sp[i][2]) end
  for i = 1, BAND_COUNT do wScaled(a.coll[i][1], GAIN_SCALE); w16(a.coll[i][2]) end
  w16(a.full[1]); w16(a.full[2]); wScaled(a.full[3], FRACTION_SCALE); wScaled(a.full[4], 1 / RATE_STEP)
  w16(a.rel[1]); w8(math.min(a.rel[2], 255))
  wScaled(a.rel[3], FRACTION_SCALE); wScaled(a.rel[4], GAIN_SCALE); wScaled(a.rel[5], FRACTION_SCALE)
  w16(scaled(a.rel[6], ITERM_SCALE, -32768, 32767) & 0xFFFF)
  w16(a.shake[1]); wScaled(a.shake[2], SHAKE_SCALE)

  simulatorResponses[axis] = buf
  return buf
end

-- The reply to a request for roll, as a plain byte table like every other api module's.
Api.simulatorResponse = Api.simulatorResponseFor(1)

return Api
