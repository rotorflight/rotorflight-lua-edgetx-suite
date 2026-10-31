-- The Tune Advisor reply decode: payload version 3 (51 bytes) only, anything else refused.
--
-- Run from the repository root:
--     lua5.3 bin/flight_tuning/verify_tune_advisor_payload.lua
--
-- Drives the real src/rfsuite/tasks/msp/api/tune_advisor.lua. Its cases are the Ethos suite's
-- bin/tune_advisor_payload/verify_tune_advisor_payload.lua at commit 098da94426, with the same
-- names, inputs and expected results. The Ethos codec hands a reply to onData or onError
-- through its read message's processReply; this suite's api module has no message builder (the
-- page queues its own request), so deliver() below calls Api.parse and routes its result the same
-- way: a record to onData, nil plus a reason and the refused flag to onError.
--
-- The replies are the simulator's own reply, one packed here with string.pack from the
-- firmware's layout (src/main/msp/msp.c, MSP2_GET_TUNE_ADVISOR) so the decode is checked
-- against the firmware's byte order and not against itself, and variants of them.
--
-- Against the version-1 decode this replaces, the simulator reply is 67 bytes and every
-- version-3 reply is refused, so the cases for the 51-byte layout go red.

local failures, checks = 0, 0
local function check(label, ok, detail)
  checks = checks + 1
  if ok then
    print("  ok    " .. label)
  else
    failures = failures + 1
    print("FAIL " .. label)
    if detail then print("        " .. tostring(detail)) end
  end
end

local Api = assert(loadfile("src/rfsuite/tasks/msp/api/tune_advisor.lua"))()

local function copy(buf)
  local out = {}
  for i = 1, #buf do out[i] = buf[i] end
  return out
end

-- Feeds one reply through Api.parse and records what a caller's onData / onError would get.
local function deliver(buf)
  local got = { data = nil, reason = nil, refused = nil, errors = 0 }
  local data, reason, refused = Api.parse(buf)
  if data then
    got.data = data
  else
    got.errors = got.errors + 1
    got.reason = reason
    got.refused = refused
  end
  return got
end

-- The simulator reply for axis 1: the firmware's 51-byte layout, version 3.
local sim = Api.simulatorResponseFor(1)

local function bytes(packed)
  local out = {}
  for i = 1, #packed do out[i] = string.byte(packed, i) end
  return out
end

-- The firmware's layout, field by field (msp.c, MSP2_GET_TUNE_ADVISOR, payload version 3)
local LAYOUT = "<" ..
  "B B H" ..          -- version, flags (bits 0-1 axis, bit 2 collecting, bits 3-5 rates type), seconds
  "I4 B B B" ..       -- P | F << 10 | B << 20, iterm relax cutoff, rc rate, s rate
  "H B b B" ..        -- ffCount, ffGain x64, ffCorr x100, ffLagMs
  "BH BH BH" ..       -- setpoint bands: gain x64, count
  "BH BH BH" ..       -- collective bands
  "H H B B" ..        -- fullCount, fullSatCount, fullRatio x100, fullMaxRate / 10
  "H B B B B h" ..    -- releases, bigRebounds, meanRebound x100, meanOvershoot x64, meanCounter x100, meanIterm x1000
  "H B"               -- shakeCount, shakeRms x4

print("the firmware's 51-byte reply, payload version 3")
do
  check("the layout is 51 bytes, one CRSF frame", string.packsize(LAYOUT) == 51,
    "packsize " .. string.packsize(LAYOUT))
  check("the simulator reply is 51 bytes", #sim == 51, "length " .. #sim)
  local got = deliver(copy(sim))
  check("it decodes and reaches onData", got.data ~= nil and got.errors == 0,
    "errors " .. got.errors .. ", reason " .. tostring(got.reason))
  check("a reply that decodes is not a refusal", got.refused == nil,
    "refused " .. tostring(got.refused))
  check("the simulator's tune comes back", got.data ~= nil and got.data.axis == 1 and got.data.a.P == 70
    and got.data.a.F == 120 and got.data.a.ratesType == 4 and got.data.a.rcRate == 18 and got.data.a.sRate == 24,
    got.data and ("P " .. got.data.a.P .. " F " .. got.data.a.F .. " type " .. got.data.a.ratesType))
end

print("a reply packed from the firmware's layout decodes field by field")
do
  local packed = string.pack(LAYOUT,
    3, 1 + 4 + 6 * 8, 300,                      -- version 3; pitch (axis 1), collecting, Rotorflight rates
    196 + 150 * 1024 + 25 * 1024 * 1024, 35, 50, 120,
    1500, 98, -50, 90,                         -- ffGain 98/64, ffCorr -0.50
    97, 1341, 99, 163, 66, 50,
    79, 385, 99, 763, 111, 356,
    87, 25, 38, 40,                            -- fullRatio 0.38, fullMaxRate 400
    35, 18, 15, 94, 2, -42,                    -- meanIterm -0.042
    2410, 196)                                 -- shakeRms 49
  local got = deliver(bytes(packed))
  local d = got.data
  local a = d and d.a or {}
  local function near(x, y) return x ~= nil and math.abs(x - y) < 1e-9 end
  check("it decodes", d ~= nil, tostring(got.reason))
  check("flags: axis, collecting, rates type", d ~= nil and d.axis == 2 and d.collecting == true
    and a.ratesType == 6, d and ("axis " .. d.axis .. " type " .. tostring(a.ratesType)))
  check("the packed gains: P, F, B", a.P == 196 and a.F == 150 and a.B == 25,
    tostring(a.P) .. "/" .. tostring(a.F) .. "/" .. tostring(a.B))
  check("the rest of the tune", a.relaxCutoff == 35 and a.rcRate == 50 and a.sRate == 120)
  check("feed-forward: count, gain, correlation, lag", a.ffCount == 1500 and near(a.ffGain, 98 / 64)
    and near(a.ffCorr, -0.5) and a.ffLagMs == 90, tostring(a.ffGain) .. " " .. tostring(a.ffCorr))
  check("bands: gain x64 and count", a.spBands and near(a.spBands[1].gain, 97 / 64)
    and a.spBands[3].count == 50 and near(a.collBands[3].gain, 111 / 64) and a.collBands[2].count == 763)
  check("full stick", a.fullCount == 87 and a.fullSatCount == 25 and near(a.fullRatio, 0.38)
    and a.fullMaxRate == 400, tostring(a.fullMaxRate))
  check("stops", a.releases == 35 and a.bigRebounds == 18 and near(a.meanRebound, 0.15)
    and near(a.meanOvershoot, 94 / 64) and near(a.meanCounter, 0.02) and near(a.meanIterm, -0.042),
    tostring(a.meanIterm))
  check("shake", a.shakeCount == 2410 and near(a.shakeRms, 49), tostring(a.shakeRms))
  check("seconds", d ~= nil and d.seconds == 300)
end

-- Every refusal below must be marked as one: a caller reads that flag to tell a deterministic
-- answer from a lost link.
local function checkRefused(label, got)
  check(label .. ": it is marked refused", got.refused == true,
    "refused " .. tostring(got.refused))
end

print("payload version 2 (71 bytes, before the reply was packed)")
do
  local v2 = {}
  for i = 1, 71 do v2[i] = 0 end
  v2[1] = 2
  local got = deliver(v2)
  check("onData is not called", got.data == nil)
  check("onError names the version", got.errors == 1 and type(got.reason) == "string"
    and string.find(got.reason, "version 2", 1, true) ~= nil, tostring(got.reason))
  checkRefused("version 2", got)
end

print("payload version 4 (a layout this suite does not know)")
do
  local v4 = copy(sim)
  v4[1] = 4
  local got = deliver(v4)
  check("onData is not called with a decoded record", got.data == nil,
    "decoded version " .. tostring(got.data and got.data.version))
  check("onError is called with the reason", got.errors == 1 and type(got.reason) == "string"
    and string.find(got.reason, "version 4", 1, true) ~= nil,
    "errors " .. got.errors .. ", reason " .. tostring(got.reason))
  checkRefused("version 4", got)
end

print("a truncated reply (50 bytes)")
do
  local short = copy(sim)
  short[#short] = nil
  local got = deliver(short)
  check("onData is not called", got.data == nil,
    "decoded, with the missing bytes as zeros")
  check("onError is called with the reason", got.errors == 1 and type(got.reason) == "string",
    "errors " .. got.errors)
  checkRefused("truncated", got)
end

print("a longer reply (52 bytes, the layout before bigRebounds was one byte)")
do
  local long = copy(sim)
  long[#long + 1] = 0
  local got = deliver(long)
  check("onData is not called", got.data == nil)
  check("onError is called with the reason", got.errors == 1 and type(got.reason) == "string",
    "errors " .. got.errors)
  checkRefused("longer", got)
end

print("Differences from the Ethos suite")
do
  -- Payload version 1 is the layout this suite decoded before; it was never in a firmware
  -- release and is refused like version 2.
  local v1 = {}
  for i = 1, 67 do v1[i] = 0 end
  v1[1] = 1
  local got = deliver(v1)
  check("payload version 1 (67 bytes) is refused and named", got.data == nil and got.refused == true
    and type(got.reason) == "string" and string.find(got.reason, "version 1", 1, true) ~= nil, tostring(got.reason))
  -- The page queues its read with completeOnErrorReplyAttempt = 1, so the one-byte error reply
  -- of a firmware without the command reaches the decode, which has to refuse it.
  got = deliver({ 0 })
  check("a one-byte error reply is refused", got.data == nil and got.refused == true, tostring(got.reason))
  got = deliver({ 3 })
  check("a one-byte reply that happens to read 3 is refused on its length", got.data == nil and got.refused == true
    and type(got.reason) == "string" and string.find(got.reason, "1 bytes", 1, true) ~= nil, tostring(got.reason))
  got = deliver({})
  check("an empty reply is refused", got.data == nil and got.refused == true, tostring(got.reason))
  -- The simulator answers every axis with its own 51-byte reply, each naming its axis.
  local axesOk = true
  for axis = 1, 3 do
    local d = Api.parse(Api.simulatorResponseFor(axis))
    axesOk = axesOk and d ~= nil and d.axis == axis and d.collecting == false and d.seconds == 147
  end
  check("each simulator axis decodes as itself", axesOk)
  check("the module's default simulator reply is roll's", Api.simulatorResponse == Api.simulatorResponseFor(1))
end

print(string.format("\n%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
