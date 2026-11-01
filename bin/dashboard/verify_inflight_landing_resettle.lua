-- In-flight tuning settings that changed while the model was armed are adopted after the landing.
-- Adopting them forgets the setup verdict and the resolved trim block, and the drive must then
-- check both on the ground before it puts anything on the wire again. These scenarios drive the
-- real dashboard runtime and the real overlay modules through a flight; the flight controller link
-- (tasks/msp/runtime.lua) and the radio-side setup check (inflight/setup.lua, M.check) are the only
-- answers scripted here, because what is under test is when the check runs, not what it finds.
local Stubs = dofile("bin/accounting/stubs/edgetx.lua")
local FC = dofile("bin/accounting/stubs/fc.lua")
Stubs.install(arg[1] or ".")
FC.install(Stubs)
Stubs.reset()
FC.reset()
local Runtime = rfsuite.require("widgets/dashboard/runtime.lua")
local Msp = rfsuite.require("tasks/msp/runtime.lua")
local ROOT = "/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/inflight/"

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

-- The link as the MSP runtime reports it: the flight controller identified, and the receiver link.
local link = true
Msp.isFblConnected = function() return link end
local mspState = Msp.getState
Msp.getState = function()
  local s = mspState()
  s.lastConnected = link
  return s
end
local values = mspState().values

local STORE = "/model.ini"
local BEFORE = {inflight = {flight_list = "", step = 1}}
local CHANGED = {inflight = {flight_list = "pid_roll_p", step = 1}}

local verdicts = 0
local function newWidget()
  link = true
  values.mcuId = "UID1"
  Msp.setModelPreferences(BEFORE, STORE)
  Stubs.sensors.ARM = 0
  local widget = Runtime.new({x = 0, y = 0, w = 480, h = 320}, {})
  widget.preferences.general = {preview_inflight_tuning = true}
  widget.preferences.inflight = {enabled = true, bank_ch = 7, value_ch = 8, bank_gvar = 8, value_gvar = 9,
    trims = true, trim_mode = "rows", row_trim_1 = 1, row_trim_2 = 2}
  widget._foreground = true
  widget.inflightFullscreen = true
  for _ = 1, 30 do
    widget._job = {kind = "control", oneShot = true, step = function() return true end}
    Stubs.tick(); widget:refresh(0, nil)
    if widget._inflight and rfsuite.modules[ROOT .. "screen.lua"] then break end
  end
  check(widget._inflight ~= nil, "the overlay opened")
  rfsuite.modules[ROOT .. "setup.lua"].check = function() verdicts = verdicts + 1; return "ok" end
  return widget
end
local function forget(widget)
  widget.inflightFullscreen = nil
  Stubs.tick(); widget:refresh(nil, nil)
  widget._inflight = nil
  Stubs.tick(); widget:refresh(0, nil)
end

-- One dashboard pass. Counts every pass that leaves the drive live on the ground with the trim block
-- unresolved: output standing under settings nothing has checked.
local unchecked = 0
local function pass(widget, n)
  for _ = 1, n or 1 do
    Stubs.tick(); widget:refresh(0, nil)
    local d = widget._inflight
    if d and d.phase ~= "live" and d.live == true and d.trimsResolved ~= true then unchecked = unchecked + 1 end
  end
  return widget._inflight
end

-- Ground, then armed, with the drive live in both.
local function flight(widget)
  local d = pass(widget, 30)
  check(d.live == true and d.phase == "ground" and d.trimsResolved == true and d._checkResult == "ok",
    "positive control: live on the ground with the trims resolved and the setup checked")
  Stubs.sensors.ARM = 1
  d = pass(widget, 15)
  check(d.phase == "live" and d.live == true, "positive control: live in the air")
  return d
end

-- After the landing: the walk and the check ran again on the ground and the drive is live again.
local function settledOnTheGround(d, before)
  check(unchecked == 0, "never live on the ground with the trims unresolved (" .. unchecked .. " passes)")
  check(d.settings.flight_list == "pid_roll_p", "positive control: the changed settings were adopted")
  check(d.phase ~= "live" and d.trimsResolved == true, "the trim block was walked again on the ground")
  check(verdicts > before and d._checkResult == "ok", "the setup check ran again after the landing")
  check(d.live == true, "the drive is live again on the ground")
end

scenario("positive control: the counter sees a drive left live with its trims unresolved", function()
  local widget = newWidget()
  local d = pass(widget, 30)
  unchecked = 0
  d.trimsResolved, d.phase, d.live = false, "ground", true
  local was = d.evaluateInterlock
  d.evaluateInterlock = function() return true end
  pass(widget, 1)
  d.evaluateInterlock = was
  check(unchecked > 0, "the counter counts")
  unchecked = 0
  forget(widget)
end)

scenario("settings changed in the air, landing with the link up: checked again on the ground", function()
  local widget = newWidget()
  flight(widget)
  local d
  Msp.setModelPreferences(CHANGED, STORE)
  d = pass(widget, 10)
  check(d.settings.flight_list == "", "in the air the change waits for the landing")
  local before = verdicts
  unchecked = 0
  Stubs.sensors.ARM = 0
  d = pass(widget, 40)
  settledOnTheGround(d, before)
  forget(widget)
end)

scenario("link lost in the air and back after the landing, nothing changed: live again on the ground", function()
  local widget = newWidget()
  flight(widget)
  local d
  link, values.mcuId, values.modelPreferences = false, nil, nil
  d = pass(widget, 20)
  check(d.live ~= true, "positive control: the link loss revoked output")
  Stubs.sensors.ARM = 0
  pass(widget, 10)
  unchecked = 0
  link, values.mcuId = true, "UID1"
  Msp.setModelPreferences(BEFORE, STORE)
  d = pass(widget, 40)
  check(unchecked == 0, "never live on the ground with the trims unresolved")
  check(d.phase ~= "live" and d.live == true and d.trimsResolved == true and d._checkResult == "ok",
    "live again on the ground with the trims resolved and the setup checked")
  forget(widget)
end)

scenario("settings changed in the air, link lost, landed while it was gone: checked again on the ground", function()
  local widget = newWidget()
  flight(widget)
  local d
  Msp.setModelPreferences(CHANGED, STORE)
  d = pass(widget, 10)
  check(d.settings.flight_list == "", "in the air the change waits for the landing")
  link, values.mcuId, values.modelPreferences = false, nil, nil
  d = pass(widget, 20)
  check(d.live ~= true and d.phase == "live", "positive control: paused in the air")
  Stubs.sensors.ARM = 0
  pass(widget, 10)
  local before = verdicts
  unchecked = 0
  -- The board is identified again and its store, with the change in it, is published again.
  link, values.mcuId = true, "UID1"
  Msp.setModelPreferences(CHANGED, STORE)
  d = pass(widget, 40)
  settledOnTheGround(d, before)
  forget(widget)
end)

scenario("store changed while the link was gone in the air, adopted at the reconnect: checked again on the ground", function()
  local widget = newWidget()
  flight(widget)
  local d
  link, values.mcuId, values.modelPreferences = false, nil, nil
  d = pass(widget, 20)
  check(d.live ~= true and d.phase == "live", "positive control: paused in the air")
  Stubs.sensors.ARM = 0
  pass(widget, 10)
  local before = verdicts
  unchecked = 0
  link, values.mcuId = true, "UID1"
  Msp.setModelPreferences(CHANGED, STORE)
  d = pass(widget, 40)
  settledOnTheGround(d, before)
  forget(widget)
end)

-- Whatever the route into it, a drive found live on the ground with its trims unresolved gives its
-- output up, walks and checks before it goes live again. The state is put in directly here.
scenario("a drive live on the ground with its trims unresolved drops output, walks and checks first", function()
  local widget = newWidget()
  local d = pass(widget, 30)
  check(d.live == true and d.phase == "ground", "positive control: live on the ground")
  local before = verdicts
  d.trimsResolved, d.trimScan = false, nil
  d:forgetVerdict()
  unchecked = 0
  Stubs.tick(); widget:refresh(0, nil)
  check(d.live ~= true, "the next pass gives the output up")
  d = pass(widget, 20)
  check(unchecked == 0, "not live again before the walk")
  check(d.trimsResolved == true and verdicts > before and d._checkResult == "ok" and d.live == true,
    "walked, checked and live again")
  forget(widget)
end)

print(string.format("%d passed, %d failed, %d checks", passed, #failed, checks))
if #failed > 0 then os.exit(1) end
