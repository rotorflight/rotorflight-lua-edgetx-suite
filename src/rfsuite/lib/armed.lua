-- Whether the craft is armed, and whether that question can be answered at all.
--
-- One definition for the tool's own screens. The header's Reload refuses on isArmed(), its Save
-- refuses on isArmed() and asks on isUncertain(), and the menu registry locks an entry while the
-- first one holds -- but both predicates were file-locals in ui/home.lua, so a page that draws a
-- write button of its own had nothing to ask, and every page that grew one would have grown a
-- second, weaker test with it.
--
-- Not the only definition in the repository, and deliberately so. tasks/msp/runtime.lua reads the
-- radio's own ARM source to decide whether to carry configuration traffic at all, which is a
-- question about the link rather than about a screen; and widgets/dashboard/inflight/fcsetup.lua
-- answers with a NAMED refusal ("no_sensors", no link, armed) because it has to tell the pilot
-- which of the three it is. Neither is replaced here.
--
-- isArmed() answers the question the screen needs -- "paint the warning?" -- and answers false
-- for three different reasons: not armed, no sensor, no link. That is the right default for a
-- warning, which must not stand permanently on a radio that cannot know. It is the wrong
-- default in front of a WRITE, where "cannot tell" is not "safe to proceed".
--
-- isUncertain() is that remaining case, and it is deliberately narrow. A missing sensor module
-- is a broken tool and not this question; a link that is down cannot carry the write either, so
-- the write fails on its own terms. What is left is the case worth asking about: the link is up,
-- the module is there, and the flight controller does not report the arming flags -- no bridge,
-- or no slot for them among its forty telemetry sensors.

local M = {}

local function loadModule(path)
  if _G.rfsuite and _G.rfsuite.require then
    return _G.rfsuite.require(path)
  end
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/" .. path, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Sensors = nil

local function ensureSensors()
  if not Sensors then
    Sensors = loadModule("lib/sensors.lua")
  end
  return Sensors
end

--- Whether the flight controller reports the craft as armed.
function M.isArmed()
  ensureSensors()
  if not Sensors or type(Sensors.getValue) ~= "function" then
    return false
  end
  local isSim = false
  if Sensors and type(Sensors.isSimulator) == "function" then
    isSim = Sensors.isSimulator()
  end
  if not isSim and type(getRSSI) == "function" then
    local ok, rssi = pcall(getRSSI)
    if ok and type(rssi) == "number" and rssi <= 0 then
      return false
    end
  end
  local value = Sensors.getValue("armflags")
  if value ~= nil then
    if type(value) == "number" then
      if type(bit32) == "table" and type(bit32.btest) == "function" then
        return bit32.btest(value, 1)
      end
      return value ~= 0
    end
    if type(value) == "boolean" then
      return value
    end
    if type(value) == "string" then
      local n = tonumber(value)
      if type(n) == "number" then
        return n ~= 0
      end
    end
  end
  return false
end

--- Whether the armed state cannot be established AT ALL, as opposed to being established as
-- disarmed.
function M.isUncertain()
  ensureSensors()
  if not Sensors or type(Sensors.getValue) ~= "function" then
    return false
  end
  if Sensors.getValue("armflags") ~= nil then
    return false
  end
  local isSim = type(Sensors.isSimulator) == "function" and Sensors.isSimulator() or false
  if not isSim and type(getRSSI) == "function" then
    local ok, rssi = pcall(getRSSI)
    if ok and type(rssi) == "number" and rssi <= 0 then
      return false
    end
  end
  return true
end

return M
