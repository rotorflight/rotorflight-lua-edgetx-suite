-- The battery write accepts the flat record its own parse returns, so a client can read a block and
-- write it back with every profile's capacity and cell count intact.
--   lua5.3 bin/power/verify_battery_config_flat.lua
local NAME = "battery config flat"
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local api = assert(loadfile("src/rfsuite/tasks/msp/api/battery_config.lua"))()
local source = api.simulatorResponse
equal(type(source), "table", "the module carries a sample reply")

for _, length in ipairs({ 15, 27, 81 }) do
  local raw = {}
  for i = 1, length do raw[i] = source[i] end
  local parsed = api.parse(raw)
  equal(type(parsed), "table", length .. " byte reply parses")
  local written = api.buildWritePayload(parsed)
  equal(#written, length, length .. " byte reply writes the same length")
  for i, byte in ipairs(raw) do equal(written[i], byte, length .. " byte reply keeps byte " .. i) end
end

-- A change to one flat slot reaches its own place, and the others stay.
local raw = {}
for i = 1, 81 do raw[i] = source[i] end
local parsed = api.parse(raw)
if parsed.batteryCapacity_5 ~= nil then
  local before = api.buildWritePayload(parsed)
  parsed.batteryCapacity_5 = (parsed.batteryCapacity_5 + 100) % 40000
  local after = api.buildWritePayload(parsed)
  local changed = 0
  for i = 1, #before do if before[i] ~= after[i] then changed = changed + 1 end end
  equal(changed >= 1 and changed <= 2, true, "only slot 6's two bytes change")
end
equal(parsed.batteryCapacity_5 ~= nil, true, "the 81 byte reply has flat capacity slots")

print(string.format("%s: %d checks, %d failures", NAME, checks, failures))
if failures > 0 then os.exit(1) end
