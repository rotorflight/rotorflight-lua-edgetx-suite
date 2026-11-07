-- Whether the MSP runtime's armed gate fires while the connect tasks are still waiting, in the
-- dashboard widget's Lua state with no background function script running. Offline, from the
-- repository root:
--
--   lua5.3 bin/msp/verify_armed_gate_during_connect.lua
--   lua5.3 bin/msp/verify_armed_gate_during_connect.lua --verbose
--
-- The real dashboard runtime is called through widget.background, one stub clock step (0.1 s) per
-- cycle. The accounting stubs supply EdgeTX; the radio's sensor table is what setTelemetryValue
-- writes, so the ARM sensor exists only once a decoder in this Lua state has published it, as on
-- a radio whose function script is not running. The flight controller sends its custom telemetry
-- frame every cycle and answers no MSP request, so the version read stays owed and the connect
-- tasks keep waiting (onconnect/tasks/apiversion.lua) -- the window in which the drain is
-- deferred.
--
-- What is checked:
--   connect waiting  the onconnect tasks are still active when the craft arms;
--   armed gate       within ARM_WITHIN_CYCLES of the first frame reporting ARMED, the MSP runtime
--                    reads the craft as armed and its queue is empty, and it stays empty;
--   disarm           after the frames report DISARMED again, the runtime reads disarmed;
--   after connect    the same gate, with every MSP request answered and the connect finished, as
--                    the positive control that the scenario can see an arm at all.
-- Exit status: 0 green, 1 failed expectations, 2 invalid arguments.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]msp$") or (dir .. "/../..") end
end

local verbose = false
for i = 1, #arg do
  if arg[i] == "--verbose" then
    verbose = true
  else
    io.stderr:write("usage: lua5.3 bin/msp/verify_armed_gate_during_connect.lua [--verbose]\n")
    os.exit(2)
  end
end

local Stubs = assert(loadfile(ROOT .. "/bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile(ROOT .. "/bin/accounting/stubs/fc.lua"))()

local API_DIR = ROOT .. "/src/rfsuite/tasks/msp/api"

-- How many cycles (0.1 s each) the gate may take to see an arm: the drain's three staggered module
-- loads, the decoder table's load and one frame, with room to spare. Far below the 25 s a waiting
-- connect task holds the window open.
local ARM_WITHIN_CYCLES = 40
-- Cycles before the arm: long enough for the dashboard to start and the link to be held up
-- (CONNECT_STABLE_SECONDS in tasks/events/runtime.lua), short of the version read's first timeout.
local SETTLE_CYCLES = 60
-- The most cycles an answered connect may take to finish in the control scenario.
local CONNECT_LIMIT_CYCLES = 1200

local failures, checks = 0, 0
local function check(ok, label, detail)
  checks = checks + 1
  if ok then
    if verbose then print("ok   " .. label .. (detail and ("  (" .. detail .. ")") or "")) end
  else
    failures = failures + 1
    print("FAIL " .. label .. (detail and ("  (" .. detail .. ")") or ""))
  end
end

local function apiFiles()
  local files = {}
  local p = io.popen('ls -1 "' .. API_DIR .. '"')
  for line in p:lines() do
    if string.sub(line, -4) == ".lua" then files[#files + 1] = line end
  end
  p:close()
  table.sort(files)
  return files
end
local API_FILES = apiFiles()

-- A custom telemetry frame as crossfireTelemetryPop hands it to the script: destination, origin,
-- frame id, then one entry -- the arming flags (0x1202, one byte).
local frameId = 0
local function pushArmFrame(armed)
  frameId = (frameId + 1) & 0xFF
  Stubs.pushFrame(0x88, { 0xEA, 0xC8, frameId, 0x12, 0x02, armed and 1 or 0 })
end

local function newWorld(answerMsp)
  Stubs.clearCard()
  Stubs.install(ROOT)
  FC.install(Stubs)
  Stubs.reset()
  FC.reset()
  FC.loadReplies(API_DIR, API_FILES)
  frameId = 0

  -- The radio's sensor table: a published value is what getValue reads from then on.
  local publish = _G.setTelemetryValue
  _G.setTelemetryValue = function(id, sub, instance, value, unit, prec, name)
    if type(name) == "string" and name ~= "" then Stubs.sensors[name] = value end
    return publish(id, sub, instance, value, unit, prec, name)
  end

  if not answerMsp then
    local fcPush = Stubs.onPush
    Stubs.onPush = function(frameType, payload)
      if frameType == 0x7A or frameType == 0x7C then return true end
      return fcPush(frameType, payload)
    end
  end

  local runtime = assert(loadfile(ROOT .. "/src/rfsuite/widgets/dashboard/runtime.lua"))()
  local widget = runtime.new({ x = 0, y = 0, w = 800, h = 458 }, {})
  local Msp = _G.rfsuite.require("tasks/msp/runtime.lua")
  assert(type(Msp) == "table" and type(Msp.getState) == "function", "msp runtime did not load")
  local Events = _G.rfsuite.require("tasks/events/runtime.lua")
  assert(type(Events) == "table", "events runtime did not load")
  return widget, Msp
end

local function cycle(widget, armed)
  Stubs.tick()
  pushArmFrame(armed)
  widget.background(widget)
end

-- Whether the onconnect runner still has work. tasks/events/runtime.lua keeps it here once loaded.
local function onconnectActive()
  local events = _G.rfsuite.tasks and _G.rfsuite.tasks.events
  local runner = events and events.onconnect
  if type(runner) ~= "table" or type(runner.active) ~= "function" then return nil end
  -- Asked in the widget's context, as tasks/events/runtime.lua asks it inside the widget call:
  -- outside one the session reads as the tool, whose task list is longer.
  local session = _G.rfsuite.session
  local saved = session.event_context
  session.event_context = "widget"
  local active = runner.active() == true
  session.event_context = saved
  return active
end

-- Whether anything is on the MSP queue, in flight or waiting.
local function queueBusy(state)
  local q = state.queue
  return type(q) == "table" and type(q.isProcessed) == "function" and not q:isProcessed()
end

local function scenario(name, answerMsp, expectConnectWaiting)
  local widget, Msp = newWorld(answerMsp)
  for _ = 1, SETTLE_CYCLES do cycle(widget, false) end
  -- With every request answered, wait for the connect to finish before arming.
  if not expectConnectWaiting then
    for _ = 1, CONNECT_LIMIT_CYCLES do
      if onconnectActive() == false then break end
      cycle(widget, false)
    end
  end

  local state = Msp.getState()
  local waiting = onconnectActive()
  if expectConnectWaiting then
    check(waiting == true, name .. ": the connect tasks are still waiting when the craft arms",
      "onconnect active = " .. tostring(waiting))
  else
    check(waiting == false, name .. ": the connect tasks are finished when the craft arms",
      "onconnect active = " .. tostring(waiting))
  end
  check(state.lastArmed ~= true, name .. ": disarmed before the arm", tostring(state.lastArmed))

  local seenAt, publishedAt = nil, nil
  for i = 1, ARM_WITHIN_CYCLES do
    cycle(widget, true)
    if publishedAt == nil and Stubs.sensors["ARM"] == 1 then publishedAt = i end
    if Msp.getState().lastArmed == true then seenAt = i break end
  end
  if verbose then
    print("     " .. name .. ": ARM published as 1 at cycle " .. tostring(publishedAt)
      .. ", read by the MSP runtime at cycle " .. tostring(seenAt))
  end
  check(seenAt ~= nil, name .. ": the MSP runtime reads the craft as armed within "
    .. ARM_WITHIN_CYCLES .. " cycles", seenAt and ("cycle " .. seenAt) or "never")

  local busyCycles = 0
  for _ = 1, 30 do
    cycle(widget, true)
    if queueBusy(Msp.getState()) then busyCycles = busyCycles + 1 end
  end
  check(Msp.getState().lastArmed == true, name .. ": still armed after 3 s armed")
  check(busyCycles == 0, name .. ": nothing stays on the MSP queue while armed",
    "cycles ending with the queue busy: " .. busyCycles)

  local clearedAt = nil
  for i = 1, ARM_WITHIN_CYCLES do
    cycle(widget, false)
    if Msp.getState().lastArmed ~= true then clearedAt = i break end
  end
  check(clearedAt ~= nil, name .. ": the MSP runtime reads the disarm within "
    .. ARM_WITHIN_CYCLES .. " cycles", clearedAt and ("cycle " .. clearedAt) or "never")
end

scenario("connect waiting", false, true)
scenario("after connect", true, false)

if failures > 0 then
  print(failures .. " of " .. checks .. " expectations failed")
  os.exit(1)
end
print("armed gate during connect: all " .. checks .. " expectations hold")
