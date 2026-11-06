-- Whether the craft is armed, and whether that question can be answered at all.
--
-- Shared by the tool's screens and MSP runtime. The header's Reload refuses on isArmed(), its Save
-- refuses on isArmed() and asks on isUncertain(), and the menu registry locks an entry while the
-- first one holds -- but both predicates were file-locals in ui/home.lua, so a page that draws a
-- write button of its own had nothing to ask, and every page that grew one would have grown a
-- second, weaker test with it.
--
-- tasks/msp/runtime.lua uses isArmed() for its queue and save gates, so they follow the same
-- sensor mapping as the screens. An uncertain reading counts as disarmed only for a craft never
-- read armed; a craft last read armed stays armed until a current reading says disarmed or the
-- reading stays uncertain for FLIGHT_CONFIRM_SECONDS (5 seconds) with the link up.
-- widgets/dashboard/inflight/fcsetup.lua keeps a NAMED refusal ("no_sensors", no link, armed)
-- because it has to tell the pilot which of the three it is.
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
  local chunk = loadScript(_G.rfsuite.paths.core .. "/" .. path, "t")
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

-- How often the answer to isArmed() has changed, as seen by any caller in this Lua state.
--
-- The tool (ui/home.lua, isModelArmed) and MSP runtime ask isArmed() every pass, but the tool wakes
-- a page only while the craft is NOT armed. So work a page runs across passes -- the ELRS link
-- sync's parameter walk and its paced writes -- never runs during an armed period, and on the
-- first pass after the disarm the craft reads as disarmed again: from inside that work, nothing
-- happened. The count is the witness that something did. Work that must not outlive an arming
-- notes the count when the pilot says yes and stops when it has moved; both edges count, so a
-- yes given while armed is spent by the disarm.
local lastAnswer = nil
local answerChanges = 0

local function readArmed()
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

--- Whether the flight controller reports the craft as armed.
function M.isArmed()
  local answer = readArmed()
  -- The first answer is not a change: a count that moved on it would end work that was
  -- confirmed before anybody had asked.
  if lastAnswer ~= nil and answer ~= lastAnswer then
    answerChanges = answerChanges + 1
  end
  lastAnswer = answer
  return answer
end

--- How many times the answer to isArmed() has changed so far; see the note above readArmed().
function M.changeCount()
  return answerChanges
end

--- Whether anything answers on the link: a flight controller the suite has connected to, or a receiver
-- whose signal the radio reads. A craft can be powered and spinning with its arming flags unreported, so a
-- write that must never reach a live model asks this rather than isArmed().
function M.linkUp()
  local session = _G.rfsuite and _G.rfsuite.session
  if type(session) == "table" and session.isConnected == true then return true end
  ensureSensors()
  if Sensors and type(Sensors.isSimulator) == "function" and Sensors.isSimulator() then return false end
  if type(getRSSI) == "function" then
    local ok, rssi = pcall(getRSSI)
    if ok and type(rssi) == "number" and rssi > 0 then return true end
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
