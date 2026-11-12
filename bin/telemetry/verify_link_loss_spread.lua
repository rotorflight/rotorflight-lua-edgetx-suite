-- The work after a lost link is spread over passes instead of landing in one. Offline:
--
--   lua5.3 bin/telemetry/verify_link_loss_spread.lua
--   lua5.3 bin/telemetry/verify_link_loss_spread.lua --verbose
--
-- Two pieces of work used to fall due together, about two seconds after the link went: the event
-- runtime publishes the disconnect DISCONNECT_STABLE_SECONDS (2 s) after the edge, resetting every
-- runner and re-reading the model name store; and lib/sensors.lua walks the model's sensor slots
-- SLOT_WALK_DELAY_SECONDS (also 2 s) after the first read that follows the dashboard's
-- Sensors.reset() on the same edge. The model name was put back in the same call as the publish.
--
-- What is checked:
--   slot walk    on a model with the native rows, the walk runs after a connect, does NOT run again
--                after a reset on link loss (the table has not changed), and runs again after a
--                plain reset;
--   name restore the event runtime puts a recorded model name back on the call after the one that
--                published the disconnect, never in that call, and within a few calls of it.
-- Exit status: 0 green, 1 failed expectations, 2 invalid arguments.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]telemetry$") or (dir .. "/../..") end
end

local verbose = false
for i = 1, #arg do
  if arg[i] == "--verbose" then
    verbose = true
  else
    io.stderr:write("usage: lua5.3 bin/telemetry/verify_link_loss_spread.lua [--verbose]\n")
    os.exit(2)
  end
end

local Stubs = assert(loadfile(ROOT .. "/bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile(ROOT .. "/bin/accounting/stubs/fc.lua"))()

Stubs.clearCard()
Stubs.install(ROOT)
FC.install(Stubs)
Stubs.reset()
FC.reset()

local failures = 0
local checks = 0
local function check(ok, label, detail)
  checks = checks + 1
  if ok then
    if verbose then print("ok   " .. label .. (detail and ("  (" .. detail .. ")") or "")) end
  else
    failures = failures + 1
    print("FAIL " .. label .. (detail and ("  (" .. detail .. ")") or ""))
  end
end

-- A model whose sensors were discovered on native telemetry first: RxBt and the native Curr in
-- slots 1-2 (0 based), the Rotorflight rows after them, a second Curr in slot 5, then empty slots.
local SLOTS = { "RxBt", "Curr", "Vbat", "Hspd", "RQly", "Curr" }
for i = #SLOTS + 1, 60 do SLOTS[i] = "" end
local linkUp = true
local values = { RxBt = 7.9, Vbat = 24.6, Hspd = 1750, RQly = 96 }
local slotValues = { [2] = nil, [6] = 3.2 }  -- telemN, 1 based: the native Curr never received
local walkReads = 0
_G.model.getSensor = function(i)
  walkReads = walkReads + 1
  local name = SLOTS[i + 1]
  if name == nil then return nil end
  return { name = name, id = i }
end
_G.getFieldInfo = function(name)
  if name == "RxBt" or values[name] ~= nil or name == "Curr" then return { id = name, name = name } end
  return nil
end
local function sourceValue(name)
  local slot = tonumber(string.match(name, "^telem(%d+)$") or "")
  if slot then
    local v = slotValues[slot]
    if v == nil and SLOTS[slot] ~= "Curr" then v = values[SLOTS[slot]] end
    if v == nil then return nil end
    return v, linkUp
  end
  if name == "Curr" then return nil end  -- the label answers with its first slot: the silent native row
  local v = values[name]
  if v == nil then return nil end
  return v, linkUp
end
_G.getSourceValue = sourceValue
_G.getValue = function(name) return (sourceValue(name)) end

local Sensors = _G.rfsuite.require("lib/sensors.lua")
assert(type(Sensors) == "table" and type(Sensors.getValue) == "function", "lib/sensors.lua did not load")

local function seconds(s, read)
  for _ = 1, math.floor(s * 10 + 0.5) do
    Stubs.tick()
    if Sensors.passBegins then Sensors.passBegins() end
    read()
  end
end
local function readCurrent() return Sensors.getValue("current") end


-- 1. Connected: the walk runs about two seconds after the first read.
Sensors.reset()
walkReads = 0
local last
seconds(5, function() last = readCurrent() end)
check(walkReads > 0, "the slot walk runs after a connect", walkReads .. " slot read(s)")

-- 2. The link is lost: the dashboard resets with "link_lost" and keeps reading.
linkUp = false
Sensors.reset("link_lost")
walkReads = 0
seconds(4, function() last = readCurrent() end)
check(walkReads == 0, "no slot walk after a reset on link loss", walkReads .. " slot read(s)")

-- 3. The link is back: a plain reset walks the table again.
linkUp = true
Sensors.reset()
walkReads = 0
seconds(5, function() last = readCurrent() end)
check(walkReads > 0, "the slot walk runs again after a plain reset", walkReads .. " slot read(s)")

-- 4. The event runtime: the model name restore is not in the call that publishes the disconnect.
do
  local Events = _G.rfsuite.require("tasks/events/runtime.lua")
  local Msp = _G.rfsuite.require("tasks/msp/runtime.lua")
  local Store = _G.rfsuite.require("lib/model_name_store.lua")
  assert(type(Events) == "table" and type(Events.wakeup) == "function", "events runtime did not load")
  assert(type(Msp) == "table" and type(Msp.getState) == "function", "MSP runtime did not load")
  assert(type(Store) == "table" and type(Store.remember) == "function", "model name store did not load")

  -- The restore runs in the widget context only, which the widget's pass sets.
  _G.rfsuite.session = _G.rfsuite.session or {}
  _G.rfsuite.session.event_context = "widget"
  _G.model.setInfo = function(info) Stubs.modelInfo.name = info.name end

  local mspState = { lastConnected = true, lastArmed = false, armedKnown = true }
  Msp.getState = function() return mspState end
  _G.rfsuite.session = _G.rfsuite.session or {}

  local published, restored = {}, {}
  local Log = _G.rfsuite.require("lib/log.lua")
  local realEmit = Log.emit
  local call = 0
  Log.emit = function(tag, msg, level, enabled)
    if msg == "session.isConnected=false" then published[#published + 1] = call end
    if type(msg) == "string" and string.find(msg, "model name put back", 1, true) == 1 then restored[#restored + 1] = call end
    return realEmit(tag, msg, level, enabled)
  end

  for _ = 1, 20 do call = call + 1; Stubs.tick(); Events.wakeup() end
  -- The craft name is on the model now, and the store remembers the model's own.
  Store.remember("Bench")
  Stubs.modelInfo.name = "Craft"
  mspState.lastConnected = false
  for _ = 1, 40 do call = call + 1; Stubs.tick(); Events.wakeup() end
  Log.emit = realEmit

  check(#published == 1, "the disconnect is published once", #published .. " time(s)")
  check(#restored == 1, "the model name is put back once", #restored .. " time(s)")
  if #published == 1 and #restored == 1 then
    check(restored[1] ~= published[1], "the name is not put back in the call that published the disconnect",
      "published in call " .. published[1] .. ", restored in call " .. restored[1])
    check(restored[1] > published[1] and restored[1] <= published[1] + 3, "the name is put back within three calls after it",
      "published in call " .. published[1] .. ", restored in call " .. restored[1])
  end
  check(Stubs.modelInfo.name == "Bench", "the model carries its own name again", tostring(Stubs.modelInfo.name))
end

if failures > 0 then
  print(string.format("%d of %d checks failed", failures, checks))
  os.exit(1)
end
print(string.format("link loss spread: %d checks passed", checks))
