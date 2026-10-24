-- Host regression checks for Setup > ESC & Motors > Telemetry wiring detection.
local root = (arg and arg[1]) or "."
local function source(path) return root .. "/" .. path end

-- settings/common.lua and the page read the colour roles of ui/palette.lua when they load.
local Palette = assert(loadfile(source("src/rfsuite/ui/palette.lua")))()
_G.rfsuite = { palette = Palette }
local TrialApi = assert(loadfile(source("src/rfsuite/tasks/msp/api/esc_sensor_trial.lua")))()
local ConfigApi = assert(loadfile(source("src/rfsuite/tasks/msp/api/esc_sensor_config.lua")))()
local Common = assert(loadfile(source("src/rfsuite/app/pages/settings/common.lua")))()
local ApiVersion = assert(loadfile(source("src/rfsuite/lib/api_version.lua")))()
local now = 100
local armedChanges = 0
local armed = false
local queued = {}
local saveRequest = nil

_G.getTime = function() return now end
_G.COLOR_THEME_SECONDARY1 = 1
_G.SMLSIZE = 1
_G.MIDSIZE = 2

local modules = {
  ["app/pages/settings/common.lua"] = Common,
  ["ui/palette.lua"] = Palette,
  ["ui/controls.lua"] = {
    STATIC_SECTION_H = 1,
    appendStaticSectionHeader = function() end,
    appendComboSelect = function() return 1 end,
    appendRadioSwitch = function() return 1 end,
    appendNumberField = function() return 1 end
  },
  ["tasks/msp/runtime.lua"] = {
    getState = function()
      return { queue = { add = function(_, message) queued[#queued + 1] = message end } }
    end
  },
  ["tasks/msp/api/esc_sensor_config.lua"] = ConfigApi,
  ["tasks/msp/api/esc_sensor_trial.lua"] = TrialApi,
  ["ui/loading_overlay.lua"] = { append = function() end },
  ["ui/confirm_dialog.lua"] = {},
  ["lib/api_version.lua"] = ApiVersion,
  ["lib/armed.lua"] = {
    isArmed = function() return armed end,
    isUncertain = function() return false end,
    changeCount = function() return armedChanges end
  },
  ["tasks/msp/save_pipeline.lua"] = {
    takeResult = function() end,
    start = function(request) saveRequest = request; return true end
  }
}

_G.loadScript = function(path)
  local relative = string.match(path, "rfsuite%-core/(.+)$")
  local value = modules[relative]
  if not value then return nil end
  return function() return value end
end

local configReply = { 1, 0, 200, 0, 52, 18, 120, 86, 9, 30, 0, 3, 4, 5 }
local function reply(state, halfDuplex, pinSwap)
  return { state, 0, halfDuplex or 0, pinSwap or 0, 0, 0, 0, 0, 4, 1 }
end

local function newPage(apiVersion)
  queued = {}
  armed, armedChanges, now, saveRequest = false, 0, 100, nil
  _G.rfsuite = { session = {
    signature = "board", apiVersion = apiVersion or "12.0.10",
    isConnected = true, fblConnected = true,
    setup_esc_motors_telemetry = {
      protocol = 1, half_duplex = 0, pin_swap = 0,
      voltage_correction = 0, current_correction = 0, consumption_correction = 0,
      parsedCache = ConfigApi.parse(configReply)
    }
  } }
  local page = assert(loadfile(source("src/rfsuite/app/pages/setup/esc_motors/telemetry/page.lua")))()
  local ctx = { requestRebuild = function() end }
  page.wakeup(ctx)
  assert(#queued == 1 and queued[1].command == ConfigApi.command, "configuration read not queued")
  queued[1].processReply(queued[1], configReply)
  page.wakeup(ctx)
  return page, ctx
end

local function build(page)
  local children = {}
  page.build({ children = children, x = 0, y = 0, w = 600, h = 400,
    i18n = {}, requestRebuild = function() end })
  return children
end

local function press(children, text)
  for i = 1, #children do
    if children[i].type == "button" and children[i].text == text then
      children[i].press()
      return true
    end
  end
  return false
end

do
  local parsed = assert(TrialApi.parse(reply(2, 1, 1)))
  assert(parsed.state == 2 and parsed.half_duplex == 1 and parsed.pin_swap == 1)
  assert(TrialApi.parse({ 1, 2, 3, 4, 5 }) == nil)
  assert(TrialApi.buildPayload(TrialApi.ACTION_CANCEL)[1] == 2)
end

do
  local page = newPage()
  assert(#queued == 2 and queued[2].payload[1] == 0 and queued[2].isWrite == false,
    "capability poll is not an explicit read")
  queued[2].processReply(queued[2], reply(0))
  assert(press(build(page), "Detect wiring"), "Detect wiring button missing")
  local start = queued[#queued]
  assert(start.payload[1] == 1 and start.isWrite == true and start.maxRetries == 0)
  assert(page.canSave() == false and page.onReload({}) == false, "pending trial did not lock Save/Reload")
  start.processReply(start, reply(1))
  assert(page.canSave() == false and page.onReload({}) == false, "running trial did not lock Save/Reload")
  now = now + 50
  page.wakeup({ requestRebuild = function() end })
  local poll = queued[#queued]
  assert(poll.payload[1] == 0 and poll.isWrite == false and poll.maxRetries == nil)
  poll.processReply(poll, reply(2, 1, 1))
  assert(page.hasUnsavedChanges(), "successful trial did not dirty detected wiring")
  assert(page.canSave() == true and page.onSave({ requestRebuild = function() end }) == true,
    "successful trial was not saveable")
  local payload = assert(saveRequest and saveRequest.steps[1] and saveRequest.steps[1].payload)
  assert(payload[1] == 1 and payload[2] == 1 and payload[11] == 1,
    "detected Half Duplex/Pin Swap did not reach Save")
  for _, i in ipairs({ 3, 4, 5, 6, 7, 8, 9, 10, 12, 13, 14 }) do
    assert(payload[i] == configReply[i], "Save changed preserved byte " .. tostring(i))
  end
  local beforeClose = #queued
  page.onClose()
  assert(#queued == beforeClose, "page close cancelled a successful trial")
end

do
  local page = newPage()
  queued[2].processReply(queued[2], reply(0))
  press(build(page), "Detect wiring")
  queued[#queued].processReply(queued[#queued], reply(1))
  now = now + 50
  page.wakeup({ requestRebuild = function() end })
  local stale = queued[#queued]
  _G.rfsuite.session.isConnected = false
  _G.rfsuite.session.fblConnected = false
  page.wakeup({ requestRebuild = function() end })
  stale.processReply(stale, reply(2, 1, 1))
  assert(not page.hasUnsavedChanges(), "stale success survived disconnect")
end

do
  local page = newPage()
  queued[2].processReply(queued[2], reply(0))
  press(build(page), "Detect wiring")
  local start = queued[#queued]
  armed = true
  armedChanges = armedChanges + 1
  armed = false
  armedChanges = armedChanges + 1
  page.wakeup({ requestRebuild = function() end })
  start.processReply(start, reply(2, 1, 1))
  assert(not page.hasUnsavedChanges() and page.canSave() == false,
    "operation survived an arm/disarm edge")
end

do
  local page = newPage()
  queued[2].processReply(queued[2], reply(0))
  press(build(page), "Detect wiring")
  local start = queued[#queued]
  assert(press(build(page), "Cancel"), "Cancel button missing while start is pending")
  start.processReply(start, reply(2, 1, 1))
  local cancel = queued[#queued]
  assert(cancel.payload[1] == 2 and cancel.maxRetries == 0, "pending Cancel lost a raced success")
  cancel.processReply(cancel, reply(0))
  assert(not page.hasUnsavedChanges() and page.canSave() == false,
    "Cancel did not restore the saved form and require Reload")
  assert(page.onReload({}) == true, "Reload was not offered after Cancel")
  local reload = queued[#queued]
  reload.processReply(reload, configReply)
  assert(page.canSave() == true, "successful Reload did not restore Save")
end

do
  local page = newPage()
  queued[2].processReply(queued[2], reply(0))
  press(build(page), "Detect wiring")
  local start = queued[#queued]
  assert(press(build(page), "Cancel"), "Cancel button missing before lost START reply")
  local beforeError = #queued
  start.errorHandler(start)
  assert(#queued == beforeError + 1, "lost START reply did not queue one Cancel")
  local cancel = queued[#queued]
  assert(cancel.payload[1] == 2 and cancel.maxRetries == 0,
    "lost START reply queued the wrong recovery mutation")
  cancel.errorHandler(cancel)
  assert(#queued == beforeError + 1, "failed Cancel repeated a mutation")
  assert(page.canSave() == false, "unknown Cancel outcome left stale configuration saveable")
end

do
  local page, ctx = newPage()
  queued[2].processReply(queued[2], reply(0))
  press(build(page), "Detect wiring")
  local staleStart = queued[#queued]
  page.onClose()
  page.wakeup(ctx)
  local reopenedRead = queued[#queued]
  staleStart.processReply(staleStart, reply(2, 1, 1))
  assert(not page.hasUnsavedChanges(), "old callback changed a reopened page")
  reopenedRead.processReply(reopenedRead, configReply)
  assert(page.canSave() == true, "reopened page did not accept its own read")
end

do
  local page = newPage()
  queued[2].processReply(queued[2], reply(0))
  press(build(page), "Detect wiring")
  queued[#queued].processReply(queued[#queued], reply(1))
  now = now + 50
  page.wakeup({ requestRebuild = function() end })
  queued[#queued].processReply(queued[#queued], { 1, 2, 3 })
  assert(page.canSave() == false, "malformed running poll left stale configuration saveable")
end

do
  local page = newPage("12.0.9")
  assert(#queued == 1, "unsupported API sent a capability command")
  assert(not press(build(page), "Detect wiring"), "unsupported API showed Detect wiring")
end

-- Every status line the page can draw for a detection (its English fallbacks).
local STATUS_TEXTS = {
  "Starting wiring detection...", "Testing ESC telemetry wiring...", "Wiring detected. Save to store it.",
  "No working wiring was detected.", "Detection was rejected by the flight controller.",
  "Detection cancelled. Reload before saving.", "Cancelling wiring detection...",
  "Detection interrupted. Reload before saving.", "The flight controller returned an invalid result.",
  "Detection needs a live connection and a disarmed model.", "Save the selected telemetry protocol before detection."
}
local function statusLabels(children)
  local found = {}
  for i = 1, #children do
    local text = children[i].type == "label" and children[i].text or nil
    for _, status in ipairs(STATUS_TEXTS) do
      if text == status then found[#found + 1] = text end
    end
  end
  return found
end

-- The firmware keeps SUCCESS, FAILED and REJECTED until the next START or Cancel. A page
-- opened later must not take that left-over result for its own: the opening poll only
-- learns that the command is supported. IDLE is the clean control.
local heldFailures = {}
for _, held in ipairs({ { 3, "FAILED" }, { 4, "REJECTED" }, { 2, "SUCCESS" }, { 0, "IDLE" } }) do
  local ok, err = pcall(function()
    local page = newPage()
    queued[2].processReply(queued[2], reply(held[1], 1, 1))
    local children = build(page)
    assert(#statusLabels(children) == 0, "held " .. held[2] .. " showed a stale result on open: "
      .. tostring(statusLabels(children)[1]))
    assert(not page.hasUnsavedChanges(), "held " .. held[2] .. " dirtied the page on open")
    assert(page.canSave() == true, "held " .. held[2] .. " locked Save on open")
    assert(#queued == 2, "held " .. held[2] .. " queued a request on open")
    assert(press(children, "Detect wiring"), "held " .. held[2] .. " hid Detect wiring")
    assert(queued[#queued].payload[1] == 1, "held " .. held[2] .. " did not allow a new START")
  end)
  if not ok then heldFailures[#heldFailures + 1] = tostring(err) end
end
assert(#heldFailures == 0, table.concat(heldFailures, "; "))

-- A run still going when the page opens is adopted and followed to its end.
do
  local page = newPage()
  queued[2].processReply(queued[2], reply(1))
  assert(page.canSave() == false, "adopted running trial did not lock Save")
  now = now + 50
  page.wakeup({ requestRebuild = function() end })
  local poll = queued[#queued]
  assert(#queued == 3 and poll.payload[1] == 0, "adopted running trial was not polled")
  poll.processReply(poll, reply(3))
  assert(#statusLabels(build(page)) == 1 and page.canSave() == false,
    "adopted trial's FAILED end was not shown or did not require Reload")
end

-- Positive control: a run this visit started still reports FAILED and requires Reload.
do
  local page = newPage()
  queued[2].processReply(queued[2], reply(0))
  press(build(page), "Detect wiring")
  queued[#queued].processReply(queued[#queued], reply(1))
  now = now + 50
  page.wakeup({ requestRebuild = function() end })
  queued[#queued].processReply(queued[#queued], reply(3))
  assert(#statusLabels(build(page)) == 1, "own FAILED result was not shown")
  assert(page.canSave() == false, "own FAILED result left Save open")
end

-- A malformed answer to the opening poll hides the action instead of polling again.
do
  local page = newPage()
  queued[2].processReply(queued[2], { 1, 2, 3 })
  page.wakeup({ requestRebuild = function() end })
  assert(#queued == 2, "malformed capability answer was polled again")
  assert(not press(build(page), "Detect wiring"), "malformed capability answer showed Detect wiring")
end

-- The page asks the tool's shared lib/armed.lua: only that copy sees the arm/disarm changes.
do
  local asked = nil
  local shared = { isArmed = function() return false end, isUncertain = function() return false end,
    changeCount = function() return 0 end }
  local page = newPage()
  _G.rfsuite.require = function(path) asked = path; return shared end
  page.onClose()
  page.wakeup({ requestRebuild = function() end })
  assert(asked == "lib/armed.lua", "page did not take the shared lib/armed.lua")
end

-- A press that only changes the status line asks for a rebuild, or the line is never drawn.
do
  local page = newPage()
  queued[2].processReply(queued[2], reply(0))
  local rebuilds = 0
  local children = {}
  page.build({ children = children, x = 0, y = 0, w = 600, h = 400, i18n = {},
    requestRebuild = function() rebuilds = rebuilds + 1 end })
  armed = true
  press(children, "Detect wiring")
  armed = false
  assert(rebuilds > 0, "refused start did not rebuild the page")
  assert(statusLabels(build(page))[1] == "Detection needs a live connection and a disarmed model.",
    "refused start did not say why")
end

-- REJECTED changes nothing in the flight controller, so it does not ask for a Reload.
do
  local page = newPage()
  queued[2].processReply(queued[2], reply(0))
  press(build(page), "Detect wiring")
  queued[#queued].processReply(queued[#queued], reply(4))
  assert(statusLabels(build(page))[1] == "Detection was rejected by the flight controller.", "REJECTED not shown")
  assert(page.canSave() == true, "REJECTED start locked Save")
end

-- A lost capability poll does not hide the action for the rest of the visit: Reload asks again.
do
  local page = newPage()
  queued[2].errorHandler(queued[2])
  assert(not press(build(page), "Detect wiring"), "lost capability poll showed Detect wiring")
  assert(page.onReload({}) == true, "Reload refused")
  queued[#queued].processReply(queued[#queued], configReply)
  page.wakeup({ requestRebuild = function() end })
  local poll = queued[#queued]
  assert(poll.command == TrialApi.command and poll.payload[1] == 0, "Reload did not ask the capability again")
  poll.processReply(poll, reply(0))
  assert(press(build(page), "Detect wiring"), "capability answered after Reload but action hidden")
end

-- Without lib/armed.lua the page cannot tell, so it refuses to start rather than risk it.
do
  local saved = modules["lib/armed.lua"]
  modules["lib/armed.lua"] = nil
  local page = newPage()
  queued[2].processReply(queued[2], reply(0))
  local before = #queued
  local pressed = press(build(page), "Detect wiring")
  modules["lib/armed.lua"] = saved
  assert(pressed, "Detect wiring missing in the fail-closed case")
  assert(#queued == before, "start went ahead without lib/armed.lua")
  assert(statusLabels(build(page))[1] == "Detection needs a live connection and a disarmed model.",
    "refused start without lib/armed.lua did not say why")
end

-- Where the tool's shared loader exists but cannot load lib/armed.lua, a private copy is no
-- substitute (it would not see the arm/disarm changes): the start is refused.
do
  local page = newPage()
  queued[2].processReply(queued[2], reply(0))
  _G.rfsuite.require = function() return nil end
  page.onClose()
  page.wakeup({ requestRebuild = function() end })
  queued[#queued].processReply(queued[#queued], configReply)
  page.wakeup({ requestRebuild = function() end })
  assert(queued[#queued].command == TrialApi.command, "capability poll missing with a failing shared loader")
  queued[#queued].processReply(queued[#queued], reply(0))
  local before = #queued
  assert(press(build(page), "Detect wiring"), "Detect wiring missing with a failing shared loader")
  assert(#queued == before, "start went ahead on a private lib/armed.lua copy")
end

-- A held SUCCESS on open leaves the fields as read: Save writes what the board reported.
do
  local page = newPage()
  queued[2].processReply(queued[2], reply(2, 1, 1))
  assert(page.onSave({ requestRebuild = function() end }) == true, "Save refused after a held SUCCESS")
  local payload = assert(saveRequest and saveRequest.steps[1] and saveRequest.steps[1].payload)
  for i = 1, #configReply do
    assert(payload[i] == configReply[i], "held SUCCESS changed Save byte " .. tostring(i))
  end
end

-- Another flight controller answering (a new session signature) asks the capability again,
-- and a detection running there is adopted rather than left unlocked.
do
  local page = newPage()
  queued[2].processReply(queued[2], reply(0))
  _G.rfsuite.session.signature = "other board"
  page.wakeup({ requestRebuild = function() end })
  local read = queued[#queued]
  assert(read.command == ConfigApi.command, "new board did not re-read the configuration")
  read.processReply(read, configReply)
  page.wakeup({ requestRebuild = function() end })
  local poll = queued[#queued]
  assert(poll.command == TrialApi.command and poll.payload[1] == 0, "new board was not asked the capability")
  poll.processReply(poll, reply(1))
  assert(page.canSave() == false, "detection running on the new board left Save open")
end

-- A Cancel pressed while START was pending belongs to that board: when another flight
-- controller answers before the START reply, the new board's capability poll sends no Cancel.
do
  local page = newPage()
  queued[2].processReply(queued[2], reply(0))
  assert(press(build(page), "Detect wiring"), "Detect wiring missing")
  assert(press(build(page), "Cancel"), "Cancel missing while START pending")
  _G.rfsuite.session.signature = "other board"
  page.wakeup({ requestRebuild = function() end })
  queued[#queued].processReply(queued[#queued], configReply)
  page.wakeup({ requestRebuild = function() end })
  local poll = queued[#queued]
  assert(poll.command == TrialApi.command and poll.payload[1] == 0, "new board was not asked the capability")
  local before = #queued
  poll.processReply(poll, reply(0))
  page.wakeup({ requestRebuild = function() end })
  for i = before + 1, #queued do
    assert(queued[i].payload[1] ~= TrialApi.ACTION_CANCEL, "a Cancel from the old board was sent to the new one")
  end
  assert(page.canSave() == true, "old board's Cancel locked Save on the new board")
end

-- Another flight controller answering while the configuration read is in flight: the dropped
-- reply does not leave the read pending for the rest of the visit.
do
  queued = {}
  armed, armedChanges, now = false, 0, 100
  _G.rfsuite = { session = {
    signature = "board", apiVersion = "12.0.10", isConnected = true, fblConnected = true,
    setup_esc_motors_telemetry = {
      protocol = 1, half_duplex = 0, pin_swap = 0,
      voltage_correction = 0, current_correction = 0, consumption_correction = 0,
      parsedCache = ConfigApi.parse(configReply)
    }
  } }
  local page = assert(loadfile(source("src/rfsuite/app/pages/setup/esc_motors/telemetry/page.lua")))()
  page.wakeup({ requestRebuild = function() end })
  assert(#queued == 1 and queued[1].command == ConfigApi.command, "configuration read not queued")
  _G.rfsuite.session.signature = "other board"
  page.wakeup({ requestRebuild = function() end })
  assert(#queued == 2 and queued[2].command == ConfigApi.command, "new board's configuration was not read")
  queued[1].processReply(queued[1], configReply)
  queued[2].processReply(queued[2], configReply)
  page.wakeup({ requestRebuild = function() end })
  assert(queued[#queued].command == TrialApi.command, "new board was not asked the capability")
end

-- A poll that only says "still running" does not rebuild the page (a rebuild puts the focus back
-- on the first control, so Cancel could not be reached while detection runs); a change does.
do
  local page = newPage()
  queued[2].processReply(queued[2], reply(0))
  local rebuilds = 0
  local ctx = { requestRebuild = function() rebuilds = rebuilds + 1 end }
  page.wakeup(ctx)
  assert(press(build(page), "Detect wiring"), "Detect wiring missing")
  local start = queued[#queued]
  page.wakeup(ctx)                                   -- build() took its own requestRebuild
  rebuilds = 0
  start.processReply(start, reply(1))
  local afterStart = rebuilds
  assert(afterStart > 0, "the start's RUNNING answer did not rebuild the page")
  for _ = 1, 3 do
    now = now + 50
    page.wakeup(ctx)
    local poll = queued[#queued]
    assert(poll.payload[1] == 0, "running trial was not polled")
    poll.processReply(poll, reply(1))
  end
  assert(rebuilds == afterStart, "unchanged RUNNING polls rebuilt the page " .. (rebuilds - afterStart) .. " times")
  now = now + 50
  page.wakeup(ctx)
  queued[#queued].processReply(queued[#queued], reply(3))
  assert(rebuilds > afterStart, "the FAILED end did not rebuild the page")
end

print("OK: 27 ESC wiring API/lifecycle cases")
