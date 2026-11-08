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
-- Each frame carries the attitude (a decoder that publishes its group itself) and the battery
-- voltage in front of the armed state, so reaching it means walking past both.
--
-- What is checked:
--   connect waiting  the onconnect tasks are still active when the craft arms, and no sensor but
--                    the armed state has been published;
--   armed gate       within ARM_WITHIN_CYCLES of the first frame reporting ARMED, the MSP runtime
--                    reads the craft as armed; from that cycle on its queue is empty at the end of
--                    every cycle and no MSP request frame goes out;
--   disarm           after the frames report DISARMED again, the runtime reads disarmed;
--   system status    the same with the packed System Status word in place of the arming flags;
--   both sources     the arming flags already on the radio, then frames carrying the System Status
--                    word in front of them (lib/sensors.lua reads the arming flags);
--   after connect    the same gate, with every MSP request answered and the connect finished, as
--                    the positive control that the scenario can see an arm at all;
--   function script  while it is draining for the radio, the widget still records that telemetry
--                    is arriving (session.telemetryFrameAt) during the connect;
--   armed first      the craft armed from the first frame: no MSP request frame goes out until the
--                    disarm -- not even one another client queued meanwhile -- and after it the
--                    connect sequence runs and finishes;
--   no armed source  frames that carry neither the arming flags nor the System Status word: the
--                    first request goes out ARMED_WAIT_CYCLES (5 s) after the link came up.
--
-- The radio's getSourceValue() is installed: a row counts as current once something has written it
-- in this world, which is what the radio answers for a sensor received since the link came up.
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
-- tasks/msp/runtime.lua ARMED_STATE_WAIT_SECONDS, in 0.1 s cycles, and the pass either side of it.
local ARMED_WAIT_CYCLES = 50

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
-- frame id, then the entries: the attitude (0x1100, three signed 16-bit values), the battery
-- voltage (0x1011, 24.6 V), then the armed state -- the arming flags (0x1202, one byte) or the
-- System Status word (0x1230, four bytes, bit 0 armed).
local frameId = 0
local function pushArmFrame(armed, source)
  frameId = (frameId + 1) & 0xFF
  local f = { 0xEA, 0xC8, frameId, 0x11, 0x00, 0x00, 0x0A, 0x00, 0x14, 0x00, 0x1E, 0x10, 0x11, 0x00, 0xF6 }
  if source == "stat" then
    for _, b in ipairs({ 0x12, 0x30, 0x00, 0x00, 0x00, armed and 1 or 0 }) do f[#f + 1] = b end
  elseif source == "both" then
    -- The System Status word in front of the arming flags: lib/sensors.lua takes the arming flags.
    for _, b in ipairs({ 0x12, 0x30, 0x00, 0x00, 0x00, armed and 1 or 0, 0x12, 0x02, armed and 1 or 0 }) do
      f[#f + 1] = b
    end
  elseif source ~= "none" then
    for _, b in ipairs({ 0x12, 0x02, armed and 1 or 0 }) do f[#f + 1] = b end
  end
  Stubs.pushFrame(0x88, f)
end

-- MSP request frames the radio sent, answered or not, and the cycle the first went out in.
local mspSent = 0
local firstSentCycle = nil
local cycleNo = 0
-- Marks a radio row as received in this world (set per world in newWorld).
local markWritten = function() end

local function newWorld(answerMsp)
  Stubs.clearCard()
  Stubs.install(ROOT)
  FC.install(Stubs)
  Stubs.reset()
  FC.reset()
  FC.loadReplies(API_DIR, API_FILES)
  frameId = 0
  mspSent = 0
  firstSentCycle = nil
  cycleNo = 0

  -- The radio's sensor table: a published value is what getValue reads from then on.
  local publish = _G.setTelemetryValue
  local written = {}
  _G.setTelemetryValue = function(id, sub, instance, value, unit, prec, name)
    if type(name) == "string" and name ~= "" then
      Stubs.sensors[name] = value
      written[name] = true
    end
    return publish(id, sub, instance, value, unit, prec, name)
  end
  -- value, current: nothing for a row never received; current once written in this world.
  _G.getSourceValue = function(name)
    local v = Stubs.sensors[name]
    if v == nil then return nil end
    return v, written[name] == true
  end
  markWritten = function(name) written[name] = true end

  local fcPush = Stubs.onPush
  Stubs.onPush = function(frameType, payload)
    if frameType == 0x7A or frameType == 0x7C then
      mspSent = mspSent + 1
      if firstSentCycle == nil then firstSentCycle = cycleNo end
      if not answerMsp then return true end
    end
    return fcPush(frameType, payload)
  end

  local runtime = assert(loadfile(ROOT .. "/src/rfsuite/widgets/dashboard/runtime.lua"))()
  local widget = runtime.new({ x = 0, y = 0, w = 800, h = 458 }, {})
  local Msp = _G.rfsuite.require("tasks/msp/runtime.lua")
  assert(type(Msp) == "table" and type(Msp.getState) == "function", "msp runtime did not load")
  local Events = _G.rfsuite.require("tasks/events/runtime.lua")
  assert(type(Events) == "table", "events runtime did not load")
  return widget, Msp
end

-- One host cycle. `armed` nil pushes no frame: another Lua state is taking them.
local function cycle(widget, armed, source)
  cycleNo = cycleNo + 1
  Stubs.tick()
  if armed ~= nil then pushArmFrame(armed, source) end
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

local function scenario(name, answerMsp, expectConnectWaiting, source, armSource)
  armSource = armSource or source
  local widget, Msp = newWorld(answerMsp)
  for _ = 1, SETTLE_CYCLES do cycle(widget, false, source) end
  -- With every request answered, wait for the connect to finish before arming.
  if not expectConnectWaiting then
    for _ = 1, CONNECT_LIMIT_CYCLES do
      if onconnectActive() == false then break end
      cycle(widget, false, source)
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
  -- While the connect tasks wait, only the armed state is decoded: the voltage and the attitude in
  -- front of it are walked past and not published -- the attitude's decoder publishes its group
  -- itself unless it is told not to.
  if expectConnectWaiting then
    check(Stubs.sensors["Vbat"] == nil and Stubs.sensors["Ptch"] == nil and Stubs.sensors["Attd"] == nil,
      name .. ": no other sensor is published while the connect tasks wait",
      "Vbat = " .. tostring(Stubs.sensors["Vbat"]) .. ", Ptch = " .. tostring(Stubs.sensors["Ptch"]))
  else
    check(Stubs.sensors["Vbat"] ~= nil and Stubs.sensors["Ptch"] ~= nil,
      name .. ": the full decode runs once the connect is through",
      "Vbat = " .. tostring(Stubs.sensors["Vbat"]) .. ", Ptch = " .. tostring(Stubs.sensors["Ptch"]))
  end

  if expectConnectWaiting then
    check(mspSent > 0, name .. ": MSP requests go out before the arm", "request frames sent: " .. mspSent)
  end

  local seenAt, sentAtArm = nil, nil
  for i = 1, ARM_WITHIN_CYCLES do
    local sentBefore = mspSent
    cycle(widget, true, armSource)
    if Msp.getState().lastArmed == true then seenAt, sentAtArm = i, sentBefore break end
  end
  if verbose then
    print("     " .. name .. ": read as armed by the MSP runtime at cycle " .. tostring(seenAt))
  end
  check(seenAt ~= nil, name .. ": the MSP runtime reads the craft as armed within "
    .. ARM_WITHIN_CYCLES .. " cycles", seenAt and ("cycle " .. seenAt) or "never")

  -- From the cycle the arm was read in: the queue empty at the end of every cycle, and no request
  -- frame sent after it.
  local busyCycles = queueBusy(Msp.getState()) and 1 or 0
  sentAtArm = sentAtArm or mspSent
  for _ = 1, 30 do
    cycle(widget, true, armSource)
    if queueBusy(Msp.getState()) then busyCycles = busyCycles + 1 end
  end
  check(Msp.getState().lastArmed == true, name .. ": still armed after 3 s armed")
  check(busyCycles == 0, name .. ": nothing stays on the MSP queue while armed",
    "cycles ending with the queue busy: " .. busyCycles .. " of 31")
  check(mspSent == sentAtArm, name .. ": no MSP request is sent while armed",
    "request frames sent from the cycle the arm was read in, for 3 s: " .. (mspSent - sentAtArm))

  if seenAt ~= nil then
    local clearedAt = nil
    for i = 1, ARM_WITHIN_CYCLES do
      cycle(widget, false, armSource)
      if Msp.getState().lastArmed ~= true then clearedAt = i break end
    end
    check(clearedAt ~= nil, name .. ": the MSP runtime reads the disarm within "
      .. ARM_WITHIN_CYCLES .. " cycles", clearedAt and ("cycle " .. clearedAt) or "never")
  end
end

-- The function script draining for the radio: its liveness counter moves and it takes the frames,
-- so this state sees none of them. The widget's connect-time pass stands aside, and still keeps the
-- time telemetry was last seen arriving, as the full pass does.
local function functionScriptScenario()
  local widget = newWorld(false)
  for _ = 1, SETTLE_CYCLES do
    Stubs.shmVars[16] = (Stubs.shmVars[16] or 0) + 1
    -- The script decodes for the radio, the arming flags included.
    Stubs.sensors["ARM"] = 0
    markWritten("ARM")
    cycle(widget, nil)
  end
  check(onconnectActive() == true, "function script: the connect tasks are still waiting")
  local session = _G.rfsuite.session
  local before = tonumber(session.telemetryFrameAt)
  for _ = 1, 20 do
    Stubs.shmVars[16] = (Stubs.shmVars[16] or 0) + 1
    cycle(widget, nil)
  end
  local after = tonumber(session.telemetryFrameAt)
  check(after ~= nil and (before == nil or after > before),
    "function script: telemetry is still recorded as arriving during the connect",
    "telemetryFrameAt " .. tostring(before) .. " -> " .. tostring(after))
end

-- Armed from the first frame, every MSP request answered: nothing is sent until the disarm, and the
-- connect runs and finishes after it.
local function armedFirstScenario()
  local widget, Msp = newWorld(true)
  for i = 1, 80 do
    cycle(widget, true, "arm")
    -- Another client puts a read on the queue while the link waits: it must wait too.
    if i == 3 then Msp.enqueue({ command = 101, processReply = function() end }) end
  end
  check(Msp.getState().lastArmed == true, "armed first: the MSP runtime reads the craft as armed")
  check(mspSent == 0, "armed first: no MSP request is sent while armed", "request frames sent: " .. mspSent)
  local finished = false
  for _ = 1, CONNECT_LIMIT_CYCLES do
    cycle(widget, false, "arm")
    if mspSent > 0 and onconnectActive() == false then finished = true break end
  end
  check(mspSent > 0, "armed first: requests go out after the disarm", "request frames sent: " .. mspSent)
  check(finished, "armed first: the connect sequence finishes after the disarm")
end

-- Neither the arming flags nor the System Status word in the frames: the link waits ARMED_WAIT_CYCLES
-- for them and then connects.
local function noArmedSourceScenario()
  local widget, Msp = newWorld(true)
  for _ = 1, ARMED_WAIT_CYCLES + 30 do cycle(widget, false, "none") end
  local linkUpAt = Msp.getState().linkUpAt
  local linkCycle = linkUpAt and math.floor(linkUpAt * 10 + 0.5) or nil
  local waited = (firstSentCycle and linkCycle) and (firstSentCycle - linkCycle) or nil
  check(waited ~= nil and waited >= ARMED_WAIT_CYCLES - 1 and waited <= ARMED_WAIT_CYCLES + 1,
    "no armed source: the first request goes out 5 s after the link came up",
    "link up at cycle " .. tostring(linkCycle) .. ", first request at cycle " .. tostring(firstSentCycle))
end

scenario("connect waiting", false, true, "arm")
scenario("system status", false, true, "stat")
scenario("both sources", false, true, "arm", "both")
scenario("after connect", true, false, "arm")
functionScriptScenario()
armedFirstScenario()
noArmedSourceScenario()

Stubs.releaseCard()
if failures > 0 then
  print(failures .. " of " .. checks .. " expectations failed")
  os.exit(1)
end
print("armed gate during connect: all " .. checks .. " expectations hold")
