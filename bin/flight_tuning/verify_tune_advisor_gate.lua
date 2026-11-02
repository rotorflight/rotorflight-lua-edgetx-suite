-- The Tune Advisor capture asks only a flight controller that has the command.
--
-- Run from the repository root:
--     lua5.3 bin/flight_tuning/verify_tune_advisor_gate.lua
--
-- The claim: the disarm capture (src/rfsuite/tasks/events/tune_capture.lua) sends
-- no Tune Advisor request to a flight controller below MSP API 12.10, which has no such command,
-- and none while the version is not known yet. From 12.10 a disarm sends the capture read. A
-- flight controller that answers with the MSP error reply is not asked again until the next
-- connection.
--
-- What it drives:
--   * the capture's supportFor() on MSP API version strings, as tasks/msp/api/api_version.lua
--     formats them ("12.09");
--   * the real capture through the real event runtime and ondisarm runner
--     (bin/flight_tuning/tune_capture_rig.lua), with a recording MSP queue;
--   * the real tasks/msp/queue.lua, for the mark it puts on an error reply.
--
-- The cases under "Ethos suite" are the Ethos suite's bin/tune_advisor_gate/verify_tune_advisor_gate.lua
-- at commit 098da94426 with this suite's values: the Ethos suite gates on the firmware version
-- (4.7.0), this suite on the MSP API version the flight controller reports (12.10, first sent
-- by firmware 4.7.0). Its "4.7.0 with a snapshot suffix" case has no counterpart: the API version
-- is two bytes on the wire, never a string with a suffix. Its simulator case is a difference,
-- below.
--
-- Against a tree without the capture this script stops at the first load: red.

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
  return ok
end

-- luacheck: globals io
-- An empty card: nothing in these cases gets as far as a save
io.open = function() return nil end
function fstat() return nil end
function mkdir() return 0 end
function del() return 0 end
function rename() return 1 end

local CAPTURE = "src/rfsuite/tasks/events/tune_capture.lua"
local capture = assert(loadfile(CAPTURE))()

-- ---------------------------------------------------------------------------
print("Ethos suite: version support")
-- ---------------------------------------------------------------------------
check("12.09 (firmware 4.6.0) has no Tune Advisor", capture.supportFor("12.09") == false)
check("12.08 has no Tune Advisor", capture.supportFor("12.08") == false)
check("11.99 has no Tune Advisor", capture.supportFor("11.99") == false)
check("12.10 (firmware 4.7.0) has the Tune Advisor", capture.supportFor("12.10") == true)
check("12.11 has the Tune Advisor", capture.supportFor("12.11") == true)
check("12.9 has no Tune Advisor (numeric, not text, compare)", capture.supportFor("12.9") == false)
check("13.00 has the Tune Advisor", capture.supportFor("13.00") == true)
check("unknown version is nil", capture.supportFor(nil) == nil)
check("unparseable version is nil", capture.supportFor("garbage") == nil)

-- ---------------------------------------------------------------------------
print("Ethos suite: the disarm capture sends nothing without the command")
-- ---------------------------------------------------------------------------
local Rig = assert(loadfile("bin/flight_tuning/tune_capture_rig.lua"))()
local rig = Rig.new({ apiVersion = "12.09" })

local function reads()
  local n = 0
  for _, msg in ipairs(rig.requests) do
    if msg.command == Rig.READ or msg.command == Rig.CLEAR then n = n + 1 end
  end
  return n
end

-- One flight: arm, then disarm, then ten seconds of passes -- past the start wait, after which
-- the first read goes out. Nothing is answered, so a capture that started sends one request.
local function flightWith(apiVersion)
  rig.drop()
  rig.session.apiVersion = apiVersion
  rig.clock = rig.clock + 60
  rig.setArmed(true)
  rig.setArmed(false)
  rig.passes(20, 0.5)
  return reads()
end

local sent = flightWith("12.09")
check("12.09: a disarm sends no Tune Advisor request", sent == 0, "requests sent: " .. sent)
check("12.09: a second disarm also sends nothing", flightWith("12.09") == 0)
check("version not known yet: a disarm sends nothing", flightWith(nil) == 0)
sent = flightWith("12.10")
check("12.10: a disarm sends the capture read", sent == 1, "requests sent: " .. sent)

-- ---------------------------------------------------------------------------
print("Differences from the Ethos suite (#982)")
-- ---------------------------------------------------------------------------
do
  -- The simulator answers MSP_API_VERSION with its own fixture, and the gate reads that like
  -- any flight controller's: the Ethos suite opens it whatever its version says.
  local ApiVersion = assert(loadfile("src/rfsuite/tasks/msp/api/api_version.lua"))()
  local simulated = ApiVersion.parse(ApiVersion.simulatorResponse)
  check("the simulator is gated on the API version its fixture reports",
    capture.supportFor(simulated.version) == (simulated.major * 100 + simulated.minor >= 1210), simulated.version)
end

do
  -- The error reply latches the capture off for the connection: a firmware without the command
  -- answers every request with it, and each would only be a failed request per disarm.
  rig = Rig.new({ apiVersion = "12.10" })
  sent = flightWith("12.10")
  rig.errorReply(rig.requests[1])
  check("(setup) the first disarm asks", sent == 1, sent)
  check("an error reply latches the capture off: the next disarm sends nothing", flightWith("12.10") == 0)
  check("nor does the one after it", flightWith("12.10") == 0)

  -- A new connection: the link held down past the runtime's disconnect hold, then up again
  rig.setLink(false)
  rig.passes(30)
  rig.setLink(true)
  rig.passes(10)
  check("the next connection asks again", flightWith("12.10") == 1)

  -- An answer in a layout this suite cannot read is not the error reply and latches nothing
  rig.refusedReply(rig.requests[1])
  check("an answer in an unknown layout does not latch: the next disarm asks", flightWith("12.10") == 1)
end

do
  -- The mark comes from the real queue: completeOnErrorReplyAttempt hands the error reply to
  -- processReply, and only __errorReply tells it from an answer.
  _G.rfsuite = nil
  _G.loadScript = function(path)
    local relative = string.match(path, "^/SCRIPTS/TOOLS/rfsuite%-core/(.+)$")
    return assert(loadfile("src/rfsuite/" .. relative))
  end
  local Queue = assert(loadfile("src/rfsuite/tasks/msp/queue.lua"))()
  local wire = { cmd = nil, buf = nil, err = nil }
  local common = {
    sendRequest = function() return true end,
    pollReply = function()
      local cmd, buf, err = wire.cmd, wire.buf, wire.err
      wire.cmd = nil
      return cmd, buf, err
    end,
  }
  local q = Queue.new(common, {})
  local seen = {}
  local function message()
    return {
      command = 0x5F10, payload = { 0 }, isWrite = false, completeOnErrorReplyAttempt = 1,
      processReply = function(msg) seen[#seen + 1] = msg.__errorReply end,
    }
  end
  q:add(message())
  q:processQueue(1)
  wire.cmd, wire.buf, wire.err = 0x5F10, {}, true
  q:processQueue(2)
  q:add(message())
  q:processQueue(3)
  wire.cmd, wire.buf, wire.err = 0x5F10, { 3 }, false
  q:processQueue(4)
  check("the queue marks the error reply it hands on, and only that", seen[1] == true and seen[2] == false,
    tostring(seen[1]) .. " " .. tostring(seen[2]))
end

print(string.format("\n%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
