-- Run the real flight log module's free-id selection without radio or filesystem access.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local function unexpectedIo()
  error("freeId must not access the radio or filesystem")
end
local env = setmetatable({
  loadScript = unexpectedIo,
  io = setmetatable({}, { __index = function() return unexpectedIo end }),
  rfsuite = {}
}, { __index = _G })
env._G = env
local FlightLog = assert(loadfile("src/rfsuite/lib/flight_log.lua", "t", env))()

-- A scenario error counts as a failure and does not prevent the remaining checks.
local function scenario(label, expected, run)
  local ok, actual = pcall(run)
  if not ok then actual = "error: " .. tostring(actual) end
  equal(actual, expected, label)
end

-- Id 3 has been deleted; 4 is still registered, so reserving 3 must suggest 5.
local registry = { { id = "1" }, { id = "2" }, { id = "4" } }
scenario("registry gap keeps old behaviour", "3", function()
  return FlightLog.freeId(registry)
end)
scenario("deleted id with logged flights", "5", function()
  return FlightLog.freeId(registry, { [3] = 5 })
end)
scenario("string-keyed page counts", "5", function()
  return FlightLog.freeId(registry, { ["3"] = 5 })
end)
scenario("logged id set", "5", function()
  return FlightLog.freeId(registry, { ["3"] = true })
end)
scenario("nil second argument", "3", function()
  return FlightLog.freeId(registry, nil)
end)
scenario("empty second argument", "3", function()
  return FlightLog.freeId(registry, {})
end)
scenario("registry remains unchanged", "4", function()
  return registry[3].id
end)

print("Flight log free id: " .. checks .. " checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
