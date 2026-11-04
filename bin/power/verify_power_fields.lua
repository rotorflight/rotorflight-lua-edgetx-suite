-- The Power page helpers: how a live reading reads, which SmartFuel modes need a voltage, and from
-- which API version SmartFuel is offered.
--   lua5.3 bin/power/verify_power_fields.lua
local NAME = "power fields"
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local fields = assert(loadfile("src/rfsuite/lib/power_fields.lua"))()
local version = assert(loadfile("src/rfsuite/lib/api_version.lua"))()

equal(fields.reading(12340, 1000, "V"), "12.34 V", "milli units read with two decimals")
equal(fields.reading(1234, 100, "A"), "12.34 A", "centi units read with two decimals")
equal(fields.reading(0, 1000, "V"), "0.00 V", "zero stays a number")

equal(fields.needsVoltage(0), false, "OFF needs no voltage")
equal(fields.needsVoltage(1), true, "VOLTAGE needs a voltage")
equal(fields.needsVoltage(2), false, "CURRENT needs no voltage")
equal(fields.needsVoltage(3), true, "COMBINED needs a voltage")

equal(fields.supportsSmartFuel("12.0.8", version), false, "below 12.0.9 no SmartFuel")
equal(fields.supportsSmartFuel("12.0.9", version), true, "12.0.9 offers SmartFuel")
equal(fields.supportsSmartFuel("12.10", version), true, "a later version offers it")

print(string.format("%s: %d checks, %d failures", NAME, checks, failures))
if failures > 0 then os.exit(1) end
