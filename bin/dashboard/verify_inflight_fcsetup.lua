-- Suggested-functions flow against a queued FC. Every reply and store operation has a pass.
debug.getmetatable("").__index = nil
local checked, loaded, cache, cleared = 0, {}, {}, {}
local sourceRoot = arg[1] or "src"
local armed, board, connected, sent, stores, fresh = false, "board-a", true, {}, {}, 0
local outstanding, records = nil, {}
local function check(value, message) checked = checked + 1; assert(value, message) end
local queue = {}
function queue:add(message)
  check(not armed and connected, "no MSP while armed or disconnected")
  check(outstanding == nil, "only one MSP reply outstanding")
  sent[#sent + 1] = message.command
  outstanding = message
end
function queue:clear(client)
  if outstanding and outstanding.client == client then outstanding = nil end
end
getTime = function() return 1000 end
getRSSI = function() return connected and 100 or 0 end
local fakePrime = {
  boardOnLink = function() return connected and board or nil end,
  start = function(_, _, continuing) check(continuing, "fresh ground read continues the session"); fresh = fresh + 1 end,
  isRunning = function() return false end,
  groundRefusal = function() return armed and "armed" or nil end
}
rfsuite = {session = {mcu_id = "mcu-a", apiVersion = {12, 0, 9},
  modelPreferences = {inflight = {step = 2, step_headspeed = 25, flight_list = "18"}}}}
rfsuite.clearModule = function(path) cleared[#cleared + 1] = path; cache[path] = nil end
rfsuite.require = function(path)
  loaded[#loaded + 1] = path
  if path == "lib/log.lua" then return {wanted = function() return false end} end
  if path == "lib/sensors.lua" then return {getValue = function() return armed and 1 or 0 end} end
  if path == "tasks/msp/runtime.lua" then return {getState = function() return {queue = queue} end} end
  if path == "lib/model_preferences.lua" then return {saveByMcuId = function(mcu, prefs)
    check(outstanding == nil, "store write has no request outstanding")
    stores[#stores + 1] = {mcu = mcu, prefs = prefs}; return true
  end} end
  if path == "widgets/dashboard/inflight/prime.lua" then return fakePrime end
  if not cache[path] then cache[path] = assert(loadfile(sourceRoot .. "/rfsuite/" .. path))() end
  return cache[path]
end
local Drive = rfsuite.require("widgets/dashboard/inflight/drive.lua")
local Setup = rfsuite.require("widgets/dashboard/inflight/setup.lua")
SMLSIZE, MIDSIZE, DBLSIZE, XXLSIZE, LEFT, RIGHT, CENTER = 1, 2, 3, 4, 0, 1, 2
BLACK, WHITE, BLUE, RED, GREEN, YELLOW = 0, 1, 2, 3, 4, 5
lvgl = {SCROLL_VER = 12}
local Screen = rfsuite.require("widgets/dashboard/inflight/screen.lua")
local function translate(_, fallback) return fallback end
local function view(count)
  local drive = Drive.newDrive(nil, Setup.settings({inflight = {enabled = true}}, {}))
  drive.open = true
  drive.phase, drive._checkResult, drive._checkedAt = "ground", "ok", 1000
  local widget = {_inflight = drive, i18n = {t = translate}, zone = {w = 480, h = 272},
    state = {armed = false, armedSeen = true, fblConnected = true,
      inflight = {setSource = "board", cellCount = count, prime = {phase = "done"}, phase = "ground"}}}
  return widget, drive
end
local function build(widget)
  local nodes = {}; Screen.buildFullscreen(nodes, widget)
  -- lvgl.build raises "number expected, got function" for a function in a geometry field; a live
  -- geometry goes through `pos` or `size`.
  for _, node in ipairs(nodes) do
    for _, key in ipairs({"x", "y", "w", "h"}) do
      check(node[key] == nil or type(node[key]) == "number", "build node " .. key .. " is a number")
    end
  end
  return nodes
end
local function action(nodes, text)
  local button
  for index, node in ipairs(nodes) do
    if node.type == "button" then button = node end
    if node.type == "label" then
      local caption = type(node.text) == "function" and node.text() or node.text
      if caption == text then return button end
      local following = nodes[index + 1]
      if following and following.type == "label" and following.x == node.x then
        local tail = type(following.text) == "function" and following.text() or following.text
        if type(caption) == "string" and type(tail) == "string" and caption .. " " .. tail == text then return button end
      end
    end
  end
end
local function setupTitle(nodes)
  local count = 0
  for _, node in ipairs(nodes) do
    if node.type == "label" and node.text == "Set up suggested functions" then count = count + 1 end
    check(node.text ~= "Set up the flight controller" and node.text ~= "Suggested functions", "no alternate setup title")
  end
  check(count == 1, "every setup surface has the action label as its one title")
end
local widget, drive = view(0)
local groundNodes = build(widget)
local primary = action(groundNodes, "Set up suggested functions")
local oldRead = action(groundNodes, "Read again")
check(primary and oldRead and primary.active() and primary.w == widget.zone.w - primary.x * 2
  and primary.h > oldRead.h and primary.color == BLUE,
  "empty board offers an active full-width accented primary taller than secondary cells")
local full = view(36)
local nodes = build(full)
local secondary, choose = action(nodes, "Set up suggested functions"), action(nodes, "Choose parameters")
check(secondary and choose and secondary.h < choose.h and secondary.color ~= choose.color,
  "populated board offers setup as a secondary action")
check(not (secondary.h == primary.h and secondary.color == primary.color), "control: secondary cannot masquerade as primary")
for _, path in ipairs(loaded) do check(not string.find(path, "fcsetup", 1, true), "normal ground build never loads fcsetup") end
primary.press()
oldRead.press()
check(fresh == 0, "stale ground read callback cannot start a job behind setup")
local Surface = rfsuite.require("widgets/dashboard/inflight/fcsurface.lua")
drive.fcSurface = Surface
setupTitle(build(widget))
Surface.tick(widget, drive, fakePrime)
check(drive.fcSetup.step == 2 and drive.fcSetup.step_headspeed == 25, "choices start at model defaults")
setupTitle(build(widget))
-- The intro names what is replaced; with it, every choice row still ends above the bottom actions.
do
  local de = assert(loadfile(sourceRoot .. "/rfsuite/i18n/de.lua"))()
  local function german(key, fallback)
    local node = de
    for part in string.gmatch(key, "[^%.]+") do node = type(node) == "table" and node[part] or nil end
    return type(node) == "string" and node or fallback
  end
  local savedT, savedZone = widget.i18n.t, widget.zone
  for _, lang in ipairs({{"en", translate}, {"de", german}}) do
    for _, size in ipairs({{480, 272}, {480, 320}, {800, 480}}) do
      widget.i18n.t, widget.zone = lang[2], {w = size[1], h = size[2]}
      local nodes, lowest, actionsY = build(widget), 0, nil
      local nextText = lang[2]("widgets.dashboard.inflight_fc_next", "Next")
      for index, node in ipairs(nodes) do
        if node.type == "label" and node.text == nextText then actionsY = nodes[index - 1].y end
      end
      for _, node in ipairs(nodes) do
        if node.type == "button" and node.y ~= actionsY then lowest = math.max(lowest, node.y + node.h) end
      end
      check(actionsY and lowest <= actionsY,
        string.format("%s choices fit above the actions at %dx%d (%d > %s)", lang[1], size[1], size[2],
          lowest, tostring(actionsY)))
    end
  end
  widget.i18n.t, widget.zone = savedT, savedZone
end
local oldChoice = action(build(widget), "1")
oldChoice.press()
check(drive.fcSetup.step == 1, "focusable choice callback selects a step")
action(build(widget), "2").press()
local function reply()
  local message = outstanding
  if not message then return end
  outstanding = nil
  local command, payload, data = message.command, message.payload, {}
  if command == 64 then data = {0, 1, 2, 3}
  elseif command == 167 then for index = 1, 42 do data[index] = 0 end
  elseif command == 53 then
    data = {}; records[payload[1]] = {}
    for index = 2, #payload do records[payload[1]][index - 1] = payload[index] end
  elseif command == 156 then data = assert(records[payload[1]]) end
  message.processReply(nil, data)
end
local function pass()
  reply()
  local before = #sent
  local worked = Surface.tick(widget, drive, fakePrime)
  check(#sent - before <= 1, "at most one request per setup pass")
  drive.fcWorked = worked
  return worked
end
local function untilPhase(phase)
  for _ = 1, 500 do if drive.fcSetup.phase == phase then return end; pass() end
  error("setup never reached " .. phase .. ": " .. tostring(drive.fcSetup.error))
end
local oldNext = action(build(widget), "Next")
oldNext.press()
untilPhase("plan")
check(#sent == 2 and #stores == 0, "plan reads exactly two replies and writes nothing")
oldNext.press(); oldChoice.press()
check(drive.fcSetup.request == nil and drive.fcSetup.step == 2,
  "stale choice and Next callbacks cannot change the planned run")
-- Confirm follows the essential plan; technical prerequisites belong to the documentation.
nodes = build(widget)
setupTitle(nodes)
local Text = rfsuite.require("widgets/dashboard/inflight/fctext.lua")
local function normalized(value) return string.gsub(string.gsub(value, "%s+", " "), "^%s*(.-)%s*$", "%1") end
local function wholePlan()
  local state = drive.fcSetup
  state.page, state.pages = 1, nil
  build(widget)
  for _, entry in ipairs(Text.question(state.run.plan, translate)) do
    local seen = 0
    for _, page in ipairs(state.pages) do
      if string.find(normalized(table.concat(page, " ")), normalized(entry), 1, true) then seen = seen + 1 end
    end
    check(seen == 1, "plan sentences and slot entries stay whole on one page")
  end
  for page = 1, #state.pages do
    state.page = page
    local pageNodes = build(widget)
    setupTitle(pageNodes)
    for _, node in ipairs(pageNodes) do
      check(not string.find(tostring(node.text), "sensor 99", 1, true)
        and not string.find(tostring(node.text), "Only the function", 1, true), "technical notes leave the plan")
    end
  end
  check(#state.pages <= 2, "essential plan takes at most two pages at 480x272")
end
wholePlan()
local originalPlan = drive.fcSetup.run.plan
local Fc = rfsuite.require("widgets/dashboard/inflight/fcsetup.lua")
local sample = Fc.newRun({bank_ch = 11, value_ch = 12, step = 2, step_headspeed = 25})
sample.map, sample.functionIds = {}, {}
for index = 1, 42 do sample.functionIds[index] = 83 end
drive.fcSetup.run.plan = Fc.buildPlan(sample)
wholePlan()
local entries = Text.question(drive.fcSetup.run.plan, translate)
check(string.find(entries[1], "Adjustment slots written: 36", 1, true)
  and string.find(entries[2], "Of them already in use: 36", 1, true), "write and overwrite counts precede entries")
local named = 0
for _, entry in ipairs(entries) do if string.find(entry, "^  %d+: .* %-> ") then named = named + 1 end end
check(named == 6 and entries[10] == "  ... 30", "six overwritten slots are named and the rest counted")
check(entries[3] == "Slot: now -> new", "the overwrite list is headed by its reading")
-- Numbered from 1 like the Adjustments page: the first standard slot (wire index 2) reads 3.
check(string.find(entries[1], "(3..38)", 1, true) and string.find(entries[4], "^  3: "), "slot numbers count from 1")
local savedQuestion = Text.question
Text.question = function()
  local first, second = {}, {}
  for index = 1, 6 do
    first[index] = string.format("First sentence line %d.", index)
    second[index] = string.format("Second sentence line %d.", index)
  end
  return {table.concat(first, "\n"), table.concat(second, "\n")}
end
wholePlan()
Text.question = savedQuestion
drive.fcSetup.run.plan, drive.fcSetup.pages, drive.fcSetup.page = originalPlan, nil, 1
nodes = build(widget)
while not action(nodes, "Confirm") do action(nodes, ">").press(); nodes = build(widget) end
local oldConfirm = action(nodes, "Confirm")
oldConfirm.press(); oldConfirm.press(); pass()
oldConfirm.press(); oldChoice.press()
check(drive.fcSetup.request == nil and drive.fcSetup.step == 2,
  "repeated confirmation and stale choices cannot restart a write or change its saved defaults")
untilPhase("saving")
setupTitle(build(widget))
check(action(build(widget), "Cancel") == nil, "verified success offers no Cancel button")
local Input = rfsuite.require("widgets/dashboard/inflight/input.lua")
check(Input.dispatch(widget, "back", nil, "encoder") and drive.fcSetup and drive.fcSetup.phase == "saving" and drive.pendingSave,
  "hardware Back cannot cancel a verified write or its idle save")
check(drive.fcSetup.run.report.verdict == "match" and drive.fcSetup.run.written == 36,
  "confirmed setup writes and verifies all suggested slots")
check(#stores == 0 and drive.pendingSave, "verification schedules but does not perform a store write")
local savedGet = Drive.get
Drive.get = function() return drive end
Drive.tick(widget)
check(#stores == 0, "control: work pass refuses an early store write")
Surface.tick(widget, drive, fakePrime)
Drive.tick(widget)
check(#stores == 1 and stores[1].prefs.inflight.step == 2 and stores[1].prefs.inflight.step_headspeed == 25,
  "next idle pass stores both selected steps")
check(action(build(widget), "Cancel") == nil, "saved result offers no Cancel button")
check(stores[1].prefs.inflight.flight_list == "18", "step save retains model flight list")
Surface.tick(widget, drive, fakePrime)
check(fresh == 1 and drive.fcSetupOpen == nil and drive.fcSurface == nil,
  "success closes setup, drops board set and requests fresh ground read")
check(cache["widgets/dashboard/inflight/fcsetup.lua"] == nil, "closed setup releases memoized fcsetup")
Drive.get = savedGet

local function interrupted(reason)
  sent, records, outstanding = {}, {}, nil
  widget, drive = view(0)
  drive.fcSetupOpen, drive.fcSurface = true, rfsuite.require("widgets/dashboard/inflight/fcsurface.lua")
  Surface = drive.fcSurface
  Surface.tick(widget, drive, fakePrime)
  drive.fcSetup.request = "read"; untilPhase("plan")
  drive.fcSetup.request = "write"; pass()
  check(outstanding and outstanding.command == 53, "positive control: a slot write is outstanding")
  if reason == "armed" then armed, widget.state.armed = true, true
  elseif reason == "board_changed" then board = "board-b"
  else connected, widget.state.fblConnected = false, false end
  local before = #sent
  for _ = 1, 5 do pass() end
  check(drive.fcSetup.phase == "error" and drive.fcSetup.error == reason and #sent == before,
    reason .. " cancels mid-write without another MSP request")
  check(outstanding == nil, "cancel clears the outstanding client")
  Surface.close(widget, drive)
  check(cache["widgets/dashboard/inflight/fcsetup.lua"] == nil, "interrupted surface releases fcsetup")
  armed, board, connected = false, "board-a", true
end
interrupted("armed"); interrupted("board_changed"); interrupted("no_link")

-- Identity loss after verification must also cancel the deferred model write.
widget, drive = view(0)
drive.fcSetupOpen, drive.fcSurface = true, rfsuite.require("widgets/dashboard/inflight/fcsurface.lua")
Surface = drive.fcSurface
Surface.tick(widget, drive, fakePrime)
drive.fcSetup.phase = "saving"
drive.fcSetup.run = {board = board}
drive.pendingSave = {mcu = "mcu-a", steps = {step = 5, step_headspeed = 50}}
board = "board-b"
Surface.tick(widget, drive, fakePrime)
check(drive.fcSetup.error == "board_changed" and drive.pendingSave == nil,
  "board change between verification and idle save cancels the model write")
Surface.close(widget, drive)
board = "board-a"

-- Progress-only publication retains row snapshots; reports, profile values and starts refresh them.
local function upvalue(fn, key)
  for index = 1, 100 do
    local name, value = debug.getupvalue(fn, index)
    if name == key then return value end
  end
  error("missing upvalue " .. key)
end
local publish = upvalue(Drive.tick, "publish")
widget, drive = view(1)
drive.groups, drive.group = {{entries = {{id = 18, name = "Pitch P", bank = 1, row = 1}}}}, 1
drive.values, drive.primedValues = {[18] = 10}, {[18] = 5}
publish(widget, drive)
local firstRows = widget.state.inflight.groupRows
drive.prime = {phase = "slots", done = 1}
publish(widget, drive)
check(widget.state.inflight.groupRows == firstRows, "ground counters reuse unchanged row snapshot")
drive.values[18], drive.reportEpoch = 20, drive.reportEpoch + 1
publish(widget, drive)
check(widget.state.inflight.groupRows ~= firstRows and widget.state.inflight.groupRows[1].value == 20,
  "control: a report refreshes row values and differences")
drive.primedValues, drive.valueEpoch = {[18] = 20}, drive.valueEpoch + 1
publish(widget, drive)
check(widget.state.inflight.groupRows[1].differenceText == "", "new starts refresh cached differences")

widget, drive = view(0)
drive.fcSetupOpen, drive.fcSurface = true, rfsuite.require("widgets/dashboard/inflight/fcsurface.lua")
drive.fcSurface.tick(widget, drive, fakePrime)
local Input = rfsuite.require("widgets/dashboard/inflight/input.lua")
EVT_VIRTUAL_EXIT = 42
check(Input.key(widget, 42) and drive.fcSetupOpen == nil, "hardware RTN cancels the setup surface")
check(cache["widgets/dashboard/inflight/fcsetup.lua"] == nil, "hardware close releases setup writer")
local RealPrime = assert(loadfile(sourceRoot .. "/rfsuite/widgets/dashboard/inflight/prime.lua"))()
check(RealPrime.setupRefusal(widget) == nil, "setup shares the positive disarmed ground gate")
widget.state.rpm = 500
check(RealPrime.setupRefusal(widget) == "rotor_running", "running rotor refuses setup")
widget.state.rpm, widget.state.armedSeen = 0, false
check(RealPrime.setupRefusal(widget) == "arm_unknown", "unseen arming state refuses setup")
print(checked .. " setup action, plan/write/verify, idle save, identity, armed and loader checks passed")
for _, path in ipairs(cleared) do print("loader released " .. path) end
