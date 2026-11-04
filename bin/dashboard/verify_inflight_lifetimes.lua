-- How long the tuning overlay keeps its session and its code once it is closed
-- (widgets/dashboard/runtime.lua, releaseInflight). Every check drives the real dashboard entry
-- points and reads the result from weak references to the module tables, after full collections.
local Stubs = dofile("bin/accounting/stubs/edgetx.lua")
local FC = dofile("bin/accounting/stubs/fc.lua")
Stubs.install(arg[1] or ".")
FC.install(Stubs)
Stubs.reset()
FC.reset()
local Runtime = rfsuite.require("widgets/dashboard/runtime.lua")

local ROOT = "/SCRIPTS/RFSUITE/core/widgets/dashboard/inflight/"
local ALL = {"setup.lua", "functions.lua", "baseline.lua", "profiles.lua", "drive.lua", "input.lua",
  "prime.lua", "screen.lua"}
local VIEW = {["screen.lua"] = true, ["input.lua"] = true}

local passed, failed, checks = 0, {}, 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
local function scenario(name, run)
  local ok, err = pcall(run)
  if ok then passed = passed + 1; print("PASS " .. name)
  else failed[#failed + 1] = name .. ": " .. tostring(err); print("FAIL " .. failed[#failed]) end
end

local realGetTime, offset = getTime, 0
_G.getTime = function() return realGetTime() + offset end

local function collect()
  collectgarbage("collect")
  collectgarbage("collect")
end
local function weakModules()
  local weak = setmetatable({}, {__mode = "v"})
  for _, name in ipairs(ALL) do weak[name] = rfsuite.modules[ROOT .. name] end
  return weak
end
local function loaded(name) return rfsuite.modules[ROOT .. name] ~= nil end

-- Opens tuning through the real path and passes until the surface's modules are loaded and a
-- drive exists, so a reopening after a release is measured the same way as a first opening.
local function open(widget)
  widget.inflightFullscreen = true
  for _ = 1, 30 do
    widget._job = {kind = "control", oneShot = true, step = function() return true end}
    Stubs.tick(); widget:refresh(0, nil)
    if widget._inflight and loaded("screen.lua") and loaded("input.lua") then return end
  end
  error("the overlay did not finish loading")
end
local function newWidget()
  local widget = Runtime.new({x = 0, y = 0, w = 480, h = 320}, {})
  widget.preferences.general = {preview_inflight_tuning = true}
  widget.preferences.inflight = {enabled = true}
  widget.state.armed, widget.state.armedSeen, widget.state.fblConnected = false, true, true
  widget._foreground = true
  return widget
end
-- A session the pilot would keep: start values read and profiles known.
local function withSession(widget, board)
  local d = widget._inflight
  d.baseline, d.sessionProfiles = {identity = "kept"}, {pid = {[1] = true}, rate = {[1] = true}}
  d.board, d.phase = board, "ground"
  return d
end
-- A closed pass: the firmware's fullscreen exit, then dashboard passes that rebuild its own scene.
local function close(widget)
  widget.inflightFullscreen = nil
  Stubs.tick(); widget:refresh(nil, nil)
  for _ = 1, 3 do Stubs.tick(); widget:refresh(0, nil) end
end
-- The last dashboard built stays reachable (the battery picker's callbacks, the LVGL stub's tree),
-- so a scenario that leaves a session behind would keep the shared code loaded for the next one,
-- exactly as a second live dashboard would. Each scenario hands its session back at the end.
local function forget(widget)
  widget._inflight, widget.inflightFullscreen = nil, nil
  Stubs.tick(); widget:refresh(0, nil)
  Stubs.tick(); widget:refresh(nil, nil)
end
local function boardOnLink(answer)
  local prime = rfsuite.modules[ROOT .. "prime.lua"]
  prime.boardOnLink = function() return answer end
end

scenario("positive control: the weak-reference check sees a collection and a held table", function()
  local probe = setmetatable({}, {__mode = "v"})
  local held = {}
  probe.dropped, probe.held = {}, held
  collect()
  check(probe.dropped == nil, "an unreferenced table is collected")
  check(probe.held == held, "a referenced table survives")
end)

scenario("closing on the ground releases the view and keeps the session", function()
  local widget = newWidget()
  open(widget)
  local d = withSession(widget, nil)
  local weak = weakModules()
  close(widget)
  collect()
  check(weak["screen.lua"] == nil and weak["input.lua"] == nil, "screen.lua and input.lua are collected")
  for _, name in ipairs(ALL) do
    if not VIEW[name] then check(weak[name] ~= nil, "session code stays loaded: " .. name) end
  end
  check(widget._inflight == d and d.baseline.identity == "kept", "the session object and its start values stay")
  local driveModule = weak["drive.lua"]
  open(widget)
  check(widget._inflight == d, "reopening continues the same session object")
  check(rfsuite.modules[ROOT .. "drive.lua"] == driveModule, "reopening loads no second drive")
  check(getmetatable(d) == driveModule.Drive or getmetatable(d).__index == driveModule.Drive,
    "the session's methods are the loaded drive's")
  close(widget)
  forget(widget)
end)

scenario("closing in the air keeps the view until the landing", function()
  local widget = newWidget()
  open(widget)
  local d = withSession(widget, nil)
  widget.state.armed, d.phase, d.live = true, "live", true
  local weak = weakModules()
  close(widget)
  collect()
  check(weak["screen.lua"] ~= nil and weak["input.lua"] ~= nil, "nothing leaves while armed")
  check(widget._inflight == d and d.phase == "live", "the flight continues closed")
  widget.state.armed = false
  for _ = 1, 3 do Stubs.tick(); widget:refresh(0, nil) end
  collect()
  check(d.phase ~= "live", "positive control: the landing was observed while closed")
  check(weak["screen.lua"] == nil and weak["input.lua"] == nil, "the view leaves at the landing")
  check(widget._inflight == d and weak["drive.lua"] ~= nil, "the session stays after the landing")
  forget(widget)
end)

scenario("another board ends the session and releases all of its code", function()
  local widget = newWidget()
  open(widget)
  local d = withSession(widget, "board-A")
  boardOnLink("board-A")
  close(widget)
  check(widget._inflight == d, "control: the same board keeps the session")
  boardOnLink("board-B")
  local weak = weakModules()
  d = nil
  for _ = 1, 2 do Stubs.tick(); widget:refresh(0, nil) end
  collect()
  check(widget._inflight == nil, "the session object is released")
  for _, name in ipairs(ALL) do check(weak[name] == nil, "collected after the session ended: " .. name) end
end)

-- A session is one power cycle of the board: five seconds without a link on the ground (a battery
-- change) end it. getTime counts 10 ms ticks, so 500 ticks are the five seconds.
scenario("five seconds without a link on the ground end a closed session; in the air never", function()
  local widget = newWidget()
  open(widget)
  local d = withSession(widget, nil)
  widget.state.armed, d.phase, d.live = true, "live", true
  close(widget)
  widget.state.fblConnected = false
  offset = offset + 60000
  Stubs.tick(); widget:refresh(0, nil)
  check(widget._inflight == d, "ten minutes without a link in the air keep the session")
  widget.state.armed, d.phase = false, "ground"
  Stubs.tick(); widget:refresh(0, nil)
  offset = offset + 400
  Stubs.tick(); widget:refresh(0, nil)
  check(widget._inflight == d, "four seconds on the ground keep the session")
  widget.state.fblConnected = true
  Stubs.tick(); widget:refresh(0, nil)
  check(widget._inflight == d and d.baseline.identity == "kept", "a link back within five seconds continues the session")
  widget.state.fblConnected = false
  Stubs.tick(); widget:refresh(0, nil)
  offset = offset + 450
  Stubs.tick(); widget:refresh(0, nil)
  check(widget._inflight == d, "a link that came back restarts the five seconds")
  offset = offset + 60
  Stubs.tick(); widget:refresh(0, nil)
  check(widget._inflight == nil, "five seconds without a link on the ground end the session")
  widget.state.fblConnected = true
end)

scenario("with tuning open, the link back after five seconds on the ground starts a new session", function()
  local widget = newWidget()
  open(widget)
  local d = withSession(widget, nil)
  widget.state.fblConnected = false
  for _ = 1, 2 do Stubs.tick(); widget:refresh(0, nil) end
  offset = offset + 600
  Stubs.tick(); widget:refresh(0, nil)
  check(widget._inflight == d and d.baseline ~= nil, "while the link is gone the session stays on screen")
  widget.state.fblConnected = true
  Stubs.tick(); widget:refresh(0, nil)
  check(widget._inflight == d and d.baseline == nil and d.phase == "ground" and d.readAgain,
    "the link back after the gap ends the session and asks for a new read")
  withSession(widget, nil)
  widget.state.fblConnected = false
  Stubs.tick(); widget:refresh(0, nil)
  offset = offset + 200
  Stubs.tick(); widget:refresh(0, nil)
  widget.state.fblConnected = true
  Stubs.tick(); widget:refresh(0, nil)
  check(d.baseline ~= nil and d.baseline.identity == "kept", "control: a gap under five seconds continues the session")
  widget.state.armed, d.phase, d.live = true, "live", true
  widget.state.fblConnected = false
  Stubs.tick(); widget:refresh(0, nil)
  offset = offset + 6000
  Stubs.tick(); widget:refresh(0, nil)
  widget.state.fblConnected = true
  Stubs.tick(); widget:refresh(0, nil)
  check(d.baseline ~= nil and d.baseline.identity == "kept", "a link back in the air continues the session")
  widget.state.armed, d.phase, d.live = false, "ground", false
  close(widget)
  forget(widget)
end)

scenario("an open tool, outstanding output or a profile job hold the release back", function()
  local widget = newWidget()
  open(widget)
  local d = withSession(widget, nil)
  -- An open tool runs in place of the dashboard pass (tool_host.lua); a stand-in host lets the
  -- pass reach that branch without opening the real tool.
  local HOST = "/SCRIPTS/RFSUITE/core/widgets/dashboard/tool_host.lua"
  local realHost = rfsuite.modules[HOST]
  for _, hold in ipairs({"tool", "profileJob", "pendingSave"}) do
    if hold == "tool" then
      rfsuite.modules[HOST] = {step = function() end}
      widget._toolHost = {}
    else d[hold] = {} end
    widget.inflightFullscreen = nil
    Stubs.tick(); widget:refresh(0, nil)
    check(loaded("screen.lua"), hold .. " keeps the view")
    if hold == "tool" then
      rfsuite.modules[HOST], widget._toolHost = realHost, nil
    else d[hold] = nil end
    Stubs.tick(); widget:refresh(0, nil)
    check(not loaded("screen.lua") and widget._inflight == d, hold .. " gone: the view leaves, the session stays")
    open(widget)
  end
  close(widget)
  forget(widget)
end)

scenario("another dashboard's session keeps the shared code loaded", function()
  local a = newWidget()
  open(a)
  local session = withSession(a, nil)
  close(a)
  local b = newWidget()
  open(b)
  local weak = weakModules()
  close(b)
  collect()
  check(b._inflight == nil, "the dashboard without a session releases its drive")
  check(weak["drive.lua"] ~= nil and weak["prime.lua"] ~= nil and weak["setup.lua"] ~= nil,
    "the code of the other dashboard's session stays")
  check(a._inflight == session and getmetatable(session) ~= nil, "the other session is untouched")
  a._inflight.board = "board-A"
  boardOnLink("board-B")
  session = nil
  for _ = 1, 2 do Stubs.tick(); a:refresh(0, nil) end
  collect()
  check(a._inflight == nil and weak["drive.lua"] == nil, "the last session's end releases the code")
end)

scenario("a cancelled opening releases what it had loaded", function()
  for _, name in ipairs(ALL) do check(not loaded(name), "precondition: nothing loaded: " .. name) end
  local widget = newWidget()
  widget.inflightFullscreen = true
  for _ = 1, 3 do Stubs.tick(); widget:refresh(0, nil) end
  check(loaded("setup.lua") and widget._inflight == nil, "positive control: the opening loaded a module")
  local weak = weakModules()
  widget.inflightFullscreen = nil
  Stubs.tick(); widget:refresh(nil, nil)
  collect()
  for _, name in ipairs(ALL) do check(weak[name] == nil, "collected after a cancelled opening: " .. name) end
  open(widget)
  check(widget._inflight ~= nil, "a later opening loads again from the start")
  close(widget)
end)

scenario("a battery change during a profile job ends the session once the job is done", function()
  for _, closed in ipairs({false, true}) do
    local widget = newWidget()
    open(widget)
    local d = withSession(widget, nil)
    if closed then close(widget) end
    d.profileJob = {}
    widget.state.fblConnected = false
    Stubs.tick(); widget:refresh(0, nil)
    offset = offset + 600
    Stubs.tick(); widget:refresh(0, nil)
    widget.state.fblConnected = true
    Stubs.tick(); widget:refresh(0, nil)
    check(d.sessionExpired == true, "positive control: the gap was long enough to end the session")
    check(widget._inflight == d and d.baseline ~= nil, "the job keeps the session (" .. (closed and "closed" or "open") .. ")")
    d.profileJob = nil
    -- An open surface's pass reads the link from the MSP stub, which has no board: the link is held
    -- up by hand on the pass that matters.
    widget.state.fblConnected = true
    Stubs.tick(); widget:refresh(0, nil)
    if closed then
      check(widget._inflight == nil, "closed: the session ends once the job is done")
    else
      check(widget._inflight == d and d.baseline == nil and d.readAgain, "open: the session ends once the job is done")
      close(widget)
    end
    forget(widget)
  end
end)

-- The expiry a ground gap notes is taken on the ground only. Work still outstanding when the link
-- comes back (here a profile job) keeps it waiting, and the open surface then asserts its bank
-- selection (drive.lua, Drive:tick), which goes on keeping it waiting after the job is done. If the
-- pilot arms then, the bank is still held in the air; when it is released in flight (a profile
-- switch cleans it up), the session must not end.
local function expiredWithWorkOutstanding(widget, d)
  d.profileJob = {}
  widget.state.fblConnected = false
  Stubs.tick(); widget:refresh(0, nil)
  offset = offset + 600
  Stubs.tick(); widget:refresh(0, nil)
  widget.state.fblConnected = true
  Stubs.tick(); widget:refresh(0, nil)
  check(d.sessionExpired == true, "positive control: the gap was long enough to end the session")
  check(widget._inflight == d and d.baseline ~= nil, "the outstanding job keeps the session on the ground")
end

-- This fixture has no tuning setup, so the surface's own pass does not assert a bank: the holder is
-- handed over at the arming, and the profile switch's cleanup is the bank going back to 0.
scenario("an expiry noted on the ground is not taken in the air, and is taken on the ground after the landing", function()
  local widget = newWidget()
  open(widget)
  local d = withSession(widget, nil)
  expiredWithWorkOutstanding(widget, d)
  widget.state.armed, d.phase, d.live = true, "live", true
  d.profileJob, d.bankWritten = nil, 1
  widget.state.fblConnected = true
  Stubs.tick(); widget:refresh(0, nil)
  d.bankWritten = 0
  for _ = 1, 3 do widget.state.fblConnected = true; Stubs.tick(); widget:refresh(0, nil) end
  check(widget._inflight == d and d.baseline ~= nil and d.baseline.identity == "kept",
    "armed: the bank released in the air does not end the session")
  check(d.sessionExpired == true, "armed: the expiry is kept for the ground")
  widget.state.armed = false
  for _ = 1, 3 do widget.state.fblConnected = true; Stubs.tick(); widget:refresh(0, nil) end
  check(d.phase ~= "live", "positive control: the landing was observed")
  check(widget._inflight == d and d.baseline == nil and d.readAgain and d.sessionExpired == nil,
    "the first ground pass with nothing holding it ends the session and asks for a new read")
  close(widget)
  forget(widget)
end)

scenario("an expiry on the ground waits for this link's arm state, then ends the session as before", function()
  local widget = newWidget()
  open(widget)
  local d = withSession(widget, nil)
  expiredWithWorkOutstanding(widget, d)
  d.profileJob = nil
  widget.state.armedSeen = false
  for _ = 1, 2 do widget.state.fblConnected = true; Stubs.tick(); widget:refresh(0, nil) end
  check(d.baseline ~= nil and d.sessionExpired == true, "arm state not yet read on this link: the session is kept")
  widget.state.armedSeen = true
  widget.state.fblConnected = true
  Stubs.tick(); widget:refresh(0, nil)
  check(d.baseline == nil and d.readAgain and d.phase == "ground" and d.sessionExpired == nil,
    "on the ground, with the job done, the session ends and a new read is asked for")
  close(widget)
  forget(widget)
end)

scenario("closing tuning with an expiry pending releases the session only once this link has read the arm state", function()
  local widget = newWidget()
  open(widget)
  local d = withSession(widget, nil)
  expiredWithWorkOutstanding(widget, d)
  d.profileJob = nil
  widget.state.armedSeen = false
  local weak = weakModules()
  close(widget)
  collect()
  check(widget._inflight == d and d.baseline ~= nil and d.sessionExpired == true,
    "arm state not yet read on this link: the closed session is kept")
  check(weak["screen.lua"] == nil and weak["input.lua"] == nil, "the view leaves while the session waits")
  widget.state.armedSeen = true
  for _ = 1, 2 do Stubs.tick(); widget:refresh(0, nil) end
  check(widget._inflight ~= d, "the arm state read on the ground: the closed session is released")
  forget(widget)
end)

scenario("a closed drive with no session and an expiry pending is released without waiting for the arm state", function()
  local widget = newWidget()
  open(widget)
  local d = widget._inflight
  d.baseline, d.sessionProfiles, d.phase = nil, nil, "ground"
  d.sessionExpired = true
  widget.state.armedSeen = false
  close(widget)
  check(widget._inflight ~= d, "nothing to keep: the drive is released")
  widget.state.armedSeen = true
  forget(widget)
end)

scenario("closing during the first read releases it and its late replies answer into nothing", function()
  local widget = newWidget()
  open(widget)
  local d = widget._inflight
  local prime = {phase = "slots", done = 3, total = 40, records = {}}
  d.prime, d.baseline, d.sessionProfiles = prime, nil, nil
  close(widget)
  check(widget._inflight == nil and prime.invalidated == true, "the read in flight is invalidated as the drive goes")
  forget(widget)
end)

scenario("another dashboard's open tool, flight or job keeps the shared code", function()
  local a, b = newWidget(), newWidget()
  open(a)
  local session = withSession(a, nil)
  close(a)
  check(not loaded("screen.lua"), "positive control: a ground close alone releases the view")
  open(a)
  open(b)
  local other = b._inflight
  other.phase, other.live, b.state.armed = "live", true, true
  close(b)
  close(a)
  check(loaded("screen.lua") and loaded("input.lua"), "a dashboard closed in the air keeps the view loaded for its reopening")
  b.state.armed, other.phase, other.live = false, "ground", false
  other.board = "board-B"
  other = nil
  forget(b)
  a._inflight.board = "board-A"
  b._toolHost = {}
  boardOnLink("board-B")
  local weak = weakModules()
  session = nil
  for _ = 1, 2 do Stubs.tick(); a:refresh(0, nil) end
  collect()
  check(a._inflight == nil and weak["setup.lua"] ~= nil, "a dashboard whose tool is open keeps setup.lua for its settings page")
  b._toolHost = nil
  a.inflightFullscreen = nil
  for _ = 1, 2 do Stubs.tick(); a:refresh(nil, nil) end
  collect()
  check(weak["setup.lua"] == nil, "once the tool is closed the code goes")
end)

print(string.format("%d checks, %d scenarios passed, %d failed", checks, passed, #failed))
if #failed > 0 then os.exit(1) end
