-- Run the real SmartFuel module with voltage sag and rising consumption in all local source modes.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local ROOT = "src/rfsuite/"
local SMART = ROOT .. "tasks/events/telemetry_bg/smart.lua"

-- Supply the radio clock, telemetry and armed state; load the real calculation helpers.
bit32 = { band = function(a, b) return a & b end }
UNIT_PERCENT, UNIT_MAH = 13, 4
function setTelemetryValue() end
function loadScript(path)
  return loadfile(ROOT .. string.gsub(path, "^/SCRIPTS/RFSUITE/core/", ""))
end
local clock = 0
function getTime() return clock end
local tele = {}
local SensorsStub = { getValue = function(name) return tele[name] end }
local mods = {}
rfsuite = {
  session = {},
  require = function(path)
    if path == "lib/sensors.lua" then return SensorsStub end
    if path == "tasks/msp/runtime.lua" then
      return { getState = function() return { lastArmed = true } end }
    end
    if path == "lib/log.lua" then return {} end
    if mods[path] == nil then mods[path] = assert(loadfile(ROOT .. path))() end
    return mods[path]
  end,
}

local scenarios = {
  {
    name = "voltage sags, consumption 0",
    feed = function(t)
      if t <= 30 then return { voltage = 24.6, consumption = 0 } end
      return { voltage = 21.6, consumption = 0 }
    end,
  },
  {
    name = "voltage high, consumption rising",
    feed = function(t)
      return { voltage = 24.6, consumption = (t <= 30) and 0 or (t - 30) * 50 }
    end,
  },
  {
    name = "BURST",
    feed = function(t)
      if t <= 30 then return { voltage = 24.6, consumption = 0 } end
      local v = 21.6
      if (t // 10) % 2 == 1 then v = v + ((t % 2 == 0) and 0.2 or -0.2) end
      return { voltage = v, consumption = 0 }
    end,
  },
  {
    name = "CAPA",
    feed = function(t)
      return { voltage = 24.6, consumption = (t <= 30) and 0 or math.min(2000, (t - 30) * 40) }
    end,
  },
  {
    name = "NOCONS",
    feed = function(t)
      if t <= 30 then return { voltage = 24.6 } end
      return { voltage = 21.6 }
    end,
  },
}

for _, scenario in ipairs(scenarios) do
  -- A module error is a counted failure, including when testing an older implementation.
  local ok, err = pcall(function()
    local results = {}
    for _, source in ipairs({ 0, 1, 2 }) do
      local Smart = assert(loadfile(SMART))()
      rfsuite.session = {
        isConnected = true,
        apiVersion = "12.08",
        battery_config = {
          batteryCellCount = 6,
          vbatmaxcellvoltage = 430,
          vbatmincellvoltage = 330,
          vbatfullcellvoltage = 410,
          batteryCapacity = 5000,
        },
        modelPreferences = { battery = { smartfuel_source = source } },
      }
      clock = 0
      local samples = {}
      for t = 1, 120 do
        clock = clock + 100
        tele = scenario.feed(t)
        Smart.wakeup()
        local sf = rfsuite.session.smartfuel
        -- Keep every tick, including missing values, so brief dropouts cannot escape the checks.
        samples[t] = { fuel = sf and sf.fuel, consumption = sf and sf.consumption }
      end
      results[source] = samples
    end

    if scenario.name == "BURST" then
      local heldVoltage, dropoutTicks = nil, 0
      for t = 1, 100 do
        local current, voltage, combined = results[0][t].fuel, results[1][t].fuel, results[2][t].fuel
        if voltage ~= nil then heldVoltage = voltage end
        if heldVoltage ~= nil then
          local expected = current and math.min(current, heldVoltage) or heldVoltage
          local matches = combined ~= nil and math.abs(combined - expected) <= 0.05
          equal(matches, true, string.format(
            "BURST t=%ds: combined=%s, held voltage/current minimum=%s within 0.05",
            t, tostring(combined), tostring(expected)))
          if voltage == nil and current ~= nil and heldVoltage < current - 0.05 then
            dropoutTicks = dropoutTicks + 1
          end
        end
      end
      equal(dropoutTicks > 0, true, "BURST exercises voltage dropouts below the current estimate")
    elseif scenario.name == "CAPA" then
      equal(type(results[0][60].fuel), "number", "CAPA current estimate is available")
      equal(type(results[1][60].consumption), "number", "CAPA voltage mode estimates consumption")
      for t = 30, 120 do
        equal(results[2][t].consumption, results[0][t].consumption,
          string.format("CAPA t=%ds: combined consumption matches current mode", t))
      end
    elseif scenario.name == "NOCONS" then
      equal(results[0][60].fuel, 0, "NOCONS current mode falls back to the raw voltage curve")
      local voltage = results[1][60].fuel
      equal(voltage ~= nil and voltage > 0 and voltage < 100, true,
        "NOCONS voltage track still has fuel after the sag")
      for t = 35, 120 do
        local expected, combined = results[1][t].fuel, results[2][t].fuel
        local matches = combined ~= nil and expected ~= nil and math.abs(combined - expected) <= 0.05
        equal(matches, true, string.format(
          "NOCONS t=%ds: combined=%s, voltage=%s within 0.05", t, tostring(combined), tostring(expected)))
      end
    end

    -- Keep the original minimum checks for feeds with both estimates and stable sample windows.
    if scenario.name ~= "BURST" and scenario.name ~= "NOCONS" then
      for i = 1, 4 do
        local t = i * 30
        local current, voltage, combined = results[0][t].fuel, results[1][t].fuel, results[2][t].fuel
        local expected = (current and voltage) and math.min(current, voltage) or (current or voltage)
        local matches = combined ~= nil and expected ~= nil and math.abs(combined - expected) <= 0.05
        equal(matches, true, string.format(
          "%s sample %d (t=%ds): combined=%s, min(current=%s, voltage=%s)=%s within 0.05",
          scenario.name, i, i * 30, tostring(combined), tostring(current), tostring(voltage), tostring(expected)))
      end
    end
  end)
  equal(ok and true or tostring(err), true, scenario.name .. " completes without error")
end

print(string.format("SmartFuel combined source: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
