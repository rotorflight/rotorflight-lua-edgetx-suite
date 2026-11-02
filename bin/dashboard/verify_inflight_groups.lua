-- EdgeTX exposes string functions without a string-method metatable.
debug.getmetatable("").__index = nil
-- Offline groups, session ownership and semantic input checks. The native LVGL focus/scroll
-- delivery is outside this fixture; callbacks are injected exactly where the Lua API exposes them.
local cache, sounds, numbers, writes = {}, {}, {}, {}
local ticks, pid, rate = 1000, 1, 2
local audioAllowed = true
local inputTraces, debugInput = {}, false
_G.rfsuite = { preferences = { audio_events = { adjustment_events = true } }, require = function(path)
  if path == "lib/log.lua" then return {
    wanted = function() return debugInput end,
    emit = function(tag, message) if tag == "rfsuite.inflight.input" then inputTraces[#inputTraces + 1] = message end end
  } end
  if path == "lib/audio.lua" then return {
    adjustmentAllowed = function() return audioAllowed end,
    playEventFile = function(path) sounds[#sounds + 1] = path end,
    playRawFile = function(path) sounds[#sounds + 1] = path end,
    playNumber = function(value) numbers[#numbers + 1] = value end
  } end
  assert(not string.find(path, "tasks/msp", 1, true), "the drive reached MSP")
  if not cache[path] then cache[path] = assert(loadfile("src/rfsuite/" .. path))() end
  return cache[path]
end }
getTime = function() return ticks end
local Drive = rfsuite.require("widgets/dashboard/inflight/drive.lua")
local Functions = cache["widgets/dashboard/inflight/functions.lua"]
local Setup = cache["widgets/dashboard/inflight/setup.lua"]
local Input = rfsuite.require("widgets/dashboard/inflight/input.lua")
local Announcer = rfsuite.require("tasks/events/telemetry_bg/adjustments.lua")
local checked = 0
local function check(value, message)
  checked = checked + 1
  assert(value, message)
end
check(assert(loadfile("src/rfsuite/tasks/events/telemetry_bg/adjustments.lua"))() == Announcer,
  "direct telemetry loader and widget memoizer share one announcer")
local radio = {
  now = function() return ticks end,
  sensor = function(name) if name == "AdjF" then return 0 elseif name == "PID#" then return pid elseif name == "RTE#" then return rate end end,
  switchValue = function() return false end,
  flightMode = function() return 0 end,
  setGlobalVariable = function(index, fm, value) writes[#writes + 1] = { index, fm, value }; return true end,
  channelUs = function() return 998 end,
  globalVariableDetails = function() end, mixesCount = function() end, flightModeData = function() end
}
-- What the ground read leaves on the drive for a board written from the standard set: the set is
-- derived from the board's own slots (prime.lua applySet), never assumed.
local BoardPrime = rfsuite.require("widgets/dashboard/inflight/prime.lua")
local function readBoard(d, mutate)
  local ena = Functions.wireToAuxField(d.settings.bank_ch, nil)
  local adj = Functions.wireToAuxField(d.settings.value_ch, nil)
  local records = {}
  for _, slot in ipairs(Functions.standardSlots(ena, adj, { step = 5, step_headspeed = 50 })) do
    records[slot.slot0 + 1] = slot.record
  end
  if mutate then mutate(records) end
  local derived = BoardPrime.deriveSet(records, nil, d.settings.bank_ch, d.settings.value_ch)
  d.bands, d.bankValues, d.set, d.rowValues = derived.bands, derived.bankValues, derived.set, derived.rowValues
  d.cellRecords, d.setSource = derived.records, "board"
  d:rebuildGroups(true)
  return d
end
local function drive(mutate)
  local d = Drive.newDrive(radio, Drive.settings({ inflight = { enabled = true } },
    { inflight = { enabled = true } }))
  check(#d.groups == 0 and d.setSource == "unread", "nothing is tunable before the board has been read")
  readBoard(d, mutate)
  d.sessionProfiles = {pid = {[1] = true}, rate = {[2] = true}}
  d.profileValues = {pid = {[1] = {}}, rate = {[2] = {}}, global = {}}
  d.profilePrevious = {pid = {}, rate = {}, global = {}}
  d:watchProfiles()
  d.reportFence = nil
  d.open, d.live, d.phase = true, true, "live"
  return d
end

-- A cell whose current value lies outside its own slot's bounds would jump on the first press
-- (the firmware constrains a stepped result into adjMin..adjMax): it is refused until the board is
-- set up again. A board written with the documented 10..200 on the rescue hover collective.
do
  local narrow = readBoard(Drive.newDrive(radio, Drive.settings({ inflight = { enabled = true } },
    { inflight = { enabled = true } })), function(records)
      for _, record in pairs(records) do
        if record.adjFunction == 40 then record.adjMin, record.adjMax = 10, 200 end
      end
    end)
  narrow.sessionProfiles = {pid = {[1] = true}, rate = {[2] = true}}
  narrow.profileValues = {pid = {[1] = {}}, rate = {[2] = {}}, global = {}}
  narrow.profilePrevious = {pid = {}, rate = {}, global = {}}
  narrow:watchProfiles()
  narrow.reportFence = nil
  narrow.live, narrow.phase = true, "live"
  local bank, row
  for b, rows in pairs(narrow.set) do for r, id in pairs(rows) do if id == 40 then bank, row = b, r end end end
  check(bank ~= nil, "the derived set carries the rescue hover collective")
  narrow.bank = bank
  narrow.values[40] = 600
  local fired = narrow.fired
  check(not narrow:dispatch("step", -1, "touch", row) and narrow.stepRefusedReason == "bounds" and narrow.fired == fired,
    "a value outside its slot's bounds refuses the step")
  ticks = ticks + 50
  narrow.values[40] = 150
  check(narrow:dispatch("step", -1, "touch", row) and narrow.fired == fired + 1,
    "control: inside the bounds the same cell steps")
  narrow:cleanup(false)
end
local d = drive()
check(not d.settings.trims, "trims must be opt-in")
check(#d.groups == 6 and d.groups[1].id == "roll" and d.groups[2].id == "pitch", "standard group order")
local order = { 18, 19, 20, 21, 57, 60 }
for i = 1, #order do check(d.groups[1].entries[i].id == order[i], "PID term order") end
local count = 0
for _, group in ipairs(d.groups) do
  check(group.scopes.pid, "standard group's scope")
  for _, cell in ipairs(group.entries) do
    count = count + 1
    check(Functions.STANDARD_SET[cell.bank][cell.row] == cell.id and #cell.name > 1, "cell address and full name")
  end
end
check(count == 36, "all standard driveable cells are present")
local armedPhase = d.phase
d.open, d.live, d.phase = false, false, "ground"
local groundWrites = #writes
check(not d:dispatch("group", 1, "key") and #writes == groundWrites, "PAGE cannot arm a bank with the surface closed")
d.open, d.live, d.phase = true, true, armedPhase
local set = { { 1, 82, 250, 5, 14, 4 }, { 64, 3, 2 } }
local windows = { { { up = 5 }, { up = 5 }, { down = -5 }, { up = 10 }, { up = 15 }, { up = 20 } },
  { { up = 5 }, { up = 10 }, { up = 15 } } }
local groups = Functions.deriveGroups(set, windows, { 10, 20 })
check(#groups == 4 and groups[1].id == "pitch" and groups[2].id == "rates"
  and groups[3].id == "acc" and groups[4].id == "other", "custom groups, unknown id and excluded selectors")
check(groups[4].entries[1].id == 250 and groups[2].scopes.rate, "unknown and rate scope")
windows[1][3] = {}
groups = Functions.deriveGroups(set, windows, { 10, 20 })
check(#groups == 3, "a cell with no safe direction is absent")
local cyclic = Functions.deriveGroups({ { 83, 18, 14 } }, nil, { 10 })
check(#cyclic == 3 and cyclic[1].id == "cyclic" and cyclic[1].entries[1].id == 83
  and cyclic[2].id == "roll" and cyclic[3].id == "pitch", "Cyclic precedes Roll/Pitch when FC has its slot")
check(Functions.groupOf(83) == 1 and groups[1].id ~= "cyclic", "Cyclic is absent without a driveable slot")
local missing
groups, _, missing = Functions.deriveGroups(set, windows, { 10, 20 }, "5,250")
check(#groups == 1 and groups[1].id == "rates" and missing[1] == 250, "flight list retains missing ids")
d.flightListMissing = missing
local verdict = Setup.check(d)
check(verdict[1] == "flight_list_missing" and verdict.missing[1] == 250, "missing flight-list parameter is a setup fault")
d.flightListMissing = {}

-- A positive pulse beside every refusal proves that the fixture really reaches the writer.
local ok = d:dispatch("step", 1, "touch")
check(ok and d.written ~= 0, "positive step control")
local before = #writes
check(not d:dispatch("function", 1, "key") and #writes == before, "no navigation during a pulse")
pid = 3
local accepted, reason = d:dispatch("step", 1, "touch")
-- Finish a busy pulse first; the fast path also checks profiles and cancels it immediately.
d:fastTick(ticks + 1)
check(d.written == 0 and d.profilePaused, "profile change clears a standing pulse")
accepted, reason = d:dispatch("step", 1, "touch")
check(not accepted and reason == "pid_unread", "distinct PID refusal")
pid, rate = 1, 4
accepted, reason = d:dispatch("step", 1, "touch")
check(not accepted and reason == "rate_unread", "distinct rate refusal")
rate = nil
accepted, reason = d:dispatch("step", 1, "touch")
check(not accepted and reason == "profile_unknown", "unknown profile refuses")
rate = 2
accepted, reason = d:dispatch("step", 1, "touch")
check(accepted and not d.profilePaused and d:tuning(), "read profile resumes without closing and reopening tuning")
check(sounds[#sounds] == "inflight/resumed.wav", "returning to a read profile requests resumed clip")
d:cleanup(false)
local trimHeld = true
d.pollTrims = function() if trimHeld then return d.row, true end end
before = d.fired
d:pollTrimStep(ticks)
check(d.fired == before, "trim held across cleanup cannot queue a step")
trimHeld = false; d:pollTrimStep(ticks)
trimHeld = true; ticks = ticks + 1; d:pollTrimStep(ticks)
check(d.fired == before + 1, "trim release and fresh press reach the common pulse")
d:cleanup(false)

local held = drive()
ticks = ticks + 1
check(held:press(held.row, true), "touch hold starts one pulse")
local firstPulse = held.fired
ticks = ticks + 31; held:fastTick(ticks)
check(held.written == 0 and held.holdRow ~= nil, "held target observes the zero gap")
check(not held:dispatch("group", 1, "key"), "navigation cannot move under a held target")
ticks = ticks + 15; held:fastTick(ticks)
check(held.fired == firstPulse + 1, "deliberate touch hold repeats after the gap")
held:release()
ticks = ticks + 31; held:fastTick(ticks)
check(held.written == 0 and held.holdRow == nil, "release leaves no held repetition")

local fenced = drive()
local sensorBeforeFence = radio.sensor
local reportedFunction, reportedValue = 14, 199
radio.sensor = function(name)
  if name == "AdjF" then return reportedFunction elseif name == "AdjV" then return reportedValue end
  return sensorBeforeFence(name)
end
fenced.profileValues.pid[1][14] = 100
fenced:activateProfiles()
pid = 3; ticks = ticks + 1; fenced:fastTick(ticks)
pid = 1; ticks = ticks + 1; fenced:fastTick(ticks)
check(fenced.values[14] == 100, "returning profiles cannot adopt a stale foreign report while paused")
-- Acknowledge the profiles as reopening tuning does; the report fence is independent.
fenced.profilePaused = false
ticks = ticks + 1; fenced:fastTick(ticks)
accepted, reason = fenced:dispatch("step", 1, "touch")
check(not accepted and reason == "report_sync" and fenced.values[14] == 100,
  "a held foreign AdjF refuses steps after acknowledgement")
reportedFunction = 0; ticks = ticks + 1; fenced:fastTick(ticks)
check(fenced:dispatch("step", 1, "touch"), "AdjF idle permits a fresh session step")
reportedFunction, reportedValue = 14, 105
ticks = ticks + 1; fenced:fastTick(ticks)
check(fenced.values[14] == 105, "fresh report after idle updates the session cache")
fenced:cleanup(false)
radio.sensor = sensorBeforeFence

local owner = {}
sounds, numbers = {}, {}
Announcer.select(owner, "function", 14, nil, 0)
check(not Announcer.selectionTick(69) and #sounds == 0, "selection does not speak before 700 ms")
Announcer.select(owner, "group", "roll", nil, 69)
check(not Announcer.selectionTick(70) and #sounds == 0, "a newer selection drops the pending name")
check(Announcer.selectionTick(139) and #sounds == 1 and sounds[1] == "inflight/group/roll.wav", "settled group speaks once")
check(not Announcer.selectionTick(200) and #sounds == 1, "settled selection is consumed")
Announcer.select(owner, "value", 14, 77, 200)
check(Announcer.selectionTick(200) and numbers[1] == 77 and sounds[2] == "inflight/selected.wav"
  and sounds[3] == "inflight/fn/14.wav", "selected cue before the whole name and the value")
Announcer.select(owner, "function", 18, nil, 200)
Announcer.cancelSelection(owner)
check(not Announcer.selectionTick(1000), "close cancels unsettled speech")
Announcer.select(owner, "function", 18, nil, 1000)
audioAllowed = false
before = #sounds
check(not Announcer.selectionTick(1070) and #sounds == before, "critical alarm has priority")
audioAllowed = true
Announcer.select(owner, "group", "other", nil, 1100)
check(Announcer.selectionTick(1170) and sounds[#sounds] == "inflight/group/other.wav", "Other uses its group clip")
for _, group in ipairs(Functions.GROUPS) do
  local n = #sounds
  Announcer.select(owner, "group", group.id, nil, 1200)
  local file = "inflight/group/" .. group.id .. ".wav"
  check(Announcer.selectionTick(1270) and #sounds == n + 1 and sounds[#sounds] == file, "group clip: " .. group.id)
  for _, lang in ipairs({ "en", "de" }) do
    check(io.open("src/rfsuite/audio/" .. lang .. "/" .. file, "rb") ~= nil, "group recording exists: " .. lang .. " " .. file)
  end
end
-- Every named function speaks its whole name from one recording that exists in both languages;
-- an id outside that set keeps the word composition.
for _, fn in ipairs(Functions.FUNCTIONS) do
  if not Functions.SELECTORS[fn.id] then
    local n = #sounds
    Announcer.select(owner, "function", fn.id, nil, 1300)
    local file = "inflight/fn/" .. fn.id .. ".wav"
    check(Announcer.selectionTick(1370) and #sounds == n + 1 and sounds[#sounds] == file, "name recording: " .. fn.id)
    for _, lang in ipairs({ "en", "de" }) do
      check(io.open("src/rfsuite/audio/" .. lang .. "/" .. file, "rb") ~= nil, "name recording exists: " .. lang .. " " .. file)
    end
  end
end
do
  local n = #sounds
  Announcer.select(owner, "function", 14.0, nil, 1380)
  check(Announcer.selectionTick(1450) and sounds[n + 1] == "inflight/fn/14.wav", "a float id still names its integer recording")
end
do
  local n = #sounds
  Announcer.select(owner, "function", 30, nil, 1400)
  check(Announcer.selectionTick(1470) and #sounds > n + 1 and string.sub(sounds[n + 1], 1, 4) == "adj/",
    "control: an id without a recording still uses the word composition")
end
for name, file in pairs({ pause = "paused", resumed = "resumed" }) do
  local n, countNumbers = #sounds, #numbers
  Announcer[name](owner, 1, 2, ticks)
  check(#sounds == n + 1 and sounds[#sounds] == "inflight/" .. file .. ".wav" and #numbers == countNumbers,
    "session clip: " .. name)
  audioAllowed = false; Announcer[name](owner)
  check(#sounds == n + 1, "alarm suppresses " .. name)
  audioAllowed = true
  rfsuite.preferences.audio_events.adjustment_events = false; Announcer[name](owner)
  check(#sounds == n + 1, "setting suppresses " .. name)
  rfsuite.preferences.audio_events.adjustment_events = true
end

for _, preference in ipairs({false, true}) do
  rfsuite.preferences.audio_events.adjustment_events = preference
  sounds, numbers = {}, {}
  Announcer.endFeedback()
  check(#sounds == 1 and sounds[1] == "/SOUNDS/rf/beep.wav", "list-end tone ignores the speech preference")
  Announcer.select(owner, "group", "roll", nil, 0)
  check(Announcer.selectionTick(70) == preference and #sounds == (preference and 2 or 1),
    "group speech retains the adjustment preference")
  Announcer.select(owner, "value", 14, 77, 70)
  check(Announcer.selectionTick(70) == preference and #numbers == (preference and 1 or 0),
    "selected cue, name and value retain the adjustment preference")
end
rfsuite.preferences.audio_events.adjustment_events = true

d = drive()
local widget = { _inflight = d, state = {} }
d.valueMode = true
local encoder = Input.sensor(widget, 40, Input.LADDER_ROWS, true)
Input.ready(widget)
local function scroll(row) return encoder.scrolled(0, (row - 1) * 40) end
check(scroll(33), "one scrolled row starts one pulse")
local fired = d.fired
check(not scroll(33) and d.fired == fired, "duplicate callback does not step")
check(not scroll(34) and d.fired == fired, "same-tick busy callback does not step")
ticks = ticks + 1
check(not scroll(35) and d.fired == fired, "busy detent is spent")
ticks = ticks + 31; d:fastTick(ticks)
check(not scroll(36) and d.fired == fired, "cooldown detent is spent")
ticks = ticks + 16; d:fastTick(ticks)
check(d.fired == fired, "no queued detent fires after cooldown")
check(not scroll(46) and d.fired == fired, "a jump never expands into multiple steps or a single step")
check(scroll(45) and d.fired == fired + 1 and d.written < 0, "one row backward asks for one negative step after re-baselining")
ticks = ticks + 31; d:fastTick(ticks)
ticks = ticks + 16; d:fastTick(ticks)
encoder.press(45)()
check(not d.valueMode, "press leaves value mode without native editing")
d:cleanup(false)
_G.EVT_VIRTUAL_EXIT, _G.EVT_VIRTUAL_NEXT_PAGE, _G.EVT_VIRTUAL_PREV_PAGE = 513, 516, 515
d.valueMode = true
ticks = ticks + 1
local valueGroup = d.group
local valueEntry = d.entry
for _, entry in ipairs(d.groups[d.group].entries) do d.values[entry.id] = entry.id + 100 end
local beforePageSounds, beforePageNumbers = #sounds, #numbers
check(Input.key(widget, 516) and d.valueMode and d.group == valueGroup and d.entry == valueEntry + 1,
  "PAGE next selects the next stepped function inside the current group")
check(Announcer.selectionTick(ticks) and sounds[beforePageSounds + 1] == "inflight/selected.wav"
  and #numbers == beforePageNumbers + 1 and numbers[#numbers] == d:functionId() + 100,
  "PAGE uses selected cue/name/current-value speech")
ticks = ticks + 1
check(Input.key(widget, 515) and d.valueMode and d.entry == valueEntry, "PAGE previous keeps value mode")
ticks = ticks + 1
check(Input.key(widget, 515) and d.entry == valueEntry and d.stepRefusedReason == "list_end", "PAGE first end does not wrap")
check(d:dispatch("step", 1, "encoder"), "PAGE busy control starts a pulse")
local stepped = d:functionId()
check(Input.key(widget, 516) and d:functionId() == stepped and d.valueMode, "PAGE refused during pulse")
ticks = ticks + 31; d:fastTick(ticks)
check(Input.key(widget, 516) and d:functionId() == stepped, "PAGE refused during cooldown")
ticks = ticks + 16; d:fastTick(ticks)
check(d:functionId() == stepped, "busy PAGE is never replayed")
check(Input.key(widget, 516) and d:functionId() ~= stepped and d.valueMode, "new PAGE after cooldown works")
ticks = ticks + 1
check(d:dispatch("step", 1, "encoder") and d:functionId() ~= stepped, "new PAGE target is stepped")
d:cleanup(false)
ticks = ticks + 50; d:fastTick(ticks)
local lastEntry = #d.groups[d.group].entries
check(d:dispatch("function", nil, "key", lastEntry), "select last function for end control")
check(Input.key(widget, 516) and d.entry == lastEntry and d.stepRefusedReason == "list_end" and d.valueMode,
  "PAGE last end does not wrap or leave value mode")
check(Input.key(widget, 513) and not d.valueMode and d.open and d.live, "RTN leaves value mode only")
check(Input.key(widget, 513) and d.open and d.live, "duplicate RTN cannot leave two levels")
ticks = ticks + 1
local exits = 0
lcd = { exitFullScreen = function() exits = exits + 1 end }
lcd.exitFullScreen()
check(exits == 1, "positive fullscreen exit stub control")
exits = 0
check(Input.key(widget, 516) and d.group == valueGroup + 1, "PAGE changes group in browse")
widget._job = { kind = "tuning_fs" }
widget.state.armed = true
check(d.live and d.phase == "live", "close controls run in the air")
check(Input.key(widget, 513) and d.open and d.live and widget._job ~= nil and exits == 0 and d.live,
  "RTN from browse in the air is consumed and does not close")
check(not d:dispatch("close", nil, "touch", nil, true) and d.live and exits == 0, "a close request in the air is refused")
local liveGroup = d.group
d:setPhase(nil); d:setPhase("live")
check(d.group == 1 and d.entry == 1 and d.bank == d.groups[1].entries[1].bank and liveGroup ~= 1,
  "a new flight starts at the first function of the first group")
d:setPhase("ground")
widget.state.armed = false
ticks = ticks + 1
local groundCloseAccepted = Input.key(widget, 513)

-- Profile select/read/restore and SD persistence have their own FC/file fixture.
local originalRequire = rfsuite.require
local Prime = {delta = function() return {} end, groundRefusal = function() end}
-- Build the real surface at all supported sizes. Reactive text is retained across an AdjV
-- publication; its layout epoch and object tree must stay unchanged while the number moves.
SMLSIZE, MIDSIZE, DBLSIZE, XXLSIZE = 1, 2, 3, 4
BLACK, WHITE, BLUE, RED, GREEN, YELLOW = 0, 1, 2, 3, 4, 5
LEFT, RIGHT, CENTER = 0, 1, 2
VCENTER = 4
lvgl = { SCROLL_VER = 12, momentaryButton = function() end }
local Screen = rfsuite.require("widgets/dashboard/inflight/screen.lua")
local function walk(nodes, fn)
  for _, node in ipairs(nodes) do
    fn(node)
    if node.children then walk(node.children, fn) end
  end
end

-- Closing is a surface transition; armed input and the session survive intermediate layouts.
do
  local failures, passed = {}, 0
  local function regression(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1 else failures[#failures + 1] = name .. ": " .. tostring(err) end
    print((ok and "PASS " or "FAIL ") .. name .. (ok and "" or ": " .. tostring(err)))
  end
  regression("ground RTN closes only tuning and cancels build", function()
    check(groundCloseAccepted and not d.open and not d.live and widget._job == nil and exits == 0,
      "RTN on the ground stays fullscreen")
  end)
  local function viewFor(instance, armed)
    local view = {_inflight = instance, inflightFullscreen = true, state = {armed = armed}, zone = {w = 480, h = 272}}
    Drive.sample(view)
    return view
  end
  for _, source in ipairs({"key", "touch"}) do
    for _, action in ipairs({"close", "back"}) do
      regression("ground " .. source .. " " .. action .. " stays fullscreen", function()
        local instance = drive()
        instance:setPhase("ground")
        local view = viewFor(instance, false)
        view._job, view.built, view.renderKey = {kind = "tuning_fs"}, true, "tuning"
        local beforeExits = exits
        check(Input.dispatch(view, action, nil, source), "ground close accepted")
        check(exits == beforeExits and view.inflightFullscreen == nil and view._job == nil
          and not view.built and view.renderKey == nil and view.state.inflight == nil,
          "close returns to the fullscreen base view and cancels the overlay build")
      end)
    end
  end
  regression("ground close retains session and clears outputs", function()
    local instance = drive()
    instance.primedValues, instance.baseline = {[18] = 100}, {pid1 = {[18] = 100}}
    instance.profileValues.pid[1][18] = 105
    check(instance:ensureBankArmed() and instance.bankWritten ~= 0, "positive bank output control")
    check(instance:dispatch("step", 1, "touch"), "positive output control")
    instance:setPhase("ground")
    instance.valueMode = true
    local view = viewFor(instance, false)
    local beforeWrites, steps, baseline = #writes, instance.fired, instance.baseline
    instance:speakSelection("group")
    check(Input.dispatch(view, "close", nil, "touch"), "ground X accepted")
    check(instance.baseline == baseline and instance.primedValues[18] == 100
      and instance.profileValues.pid[1][18] == 105 and instance.fired == steps, "start values and steps retained")
    check(#writes > beforeWrites and writes[#writes][3] == 0 and instance.written == 0
      and instance.bankWritten == 0 and not instance.valueMode, "cleanup clears both outputs and value mode")
    check(not Announcer.selectionTick(ticks + 100), "close cancels pending selection speech")
  end)
  local function setState(instance, phase)
    instance:setPhase((phase == "live" or phase == "post") and phase or "ground")
    if phase == "busy" then instance.profileJob = {plan = {}, at = 1}
    elseif phase == "setup" then
      instance.fcSetupOpen = true
      instance.fcSurface = {close = function() instance.fcSetupOpen = false end}
    elseif phase == "restore" then instance.restoreConfirm = {all = true} end
  end
  for _, phase in ipairs({"ground", "live", "post", "busy", "setup", "restore"}) do
    for _, source in ipairs({"key", "touch"}) do
      for _, action in ipairs({"close", "back"}) do
        regression("armed " .. phase .. " " .. source .. " " .. action .. " refused", function()
          local instance = drive()
          setState(instance, phase)
          local view = viewFor(instance, true)
          local beforeWrites = #writes
          local ok = Input.dispatch(view, action, nil, source)
          check(not ok and not instance.closeRequested and instance.open and instance.live
            and (phase ~= "setup" or instance.fcSetupOpen)
            and view.inflightFullscreen and #writes == beforeWrites, "armed browse cannot close")
          check(not instance:dispatch(action, nil, source, nil, true), "drive guard refuses armed close directly")
        end)
      end
      regression("armed " .. phase .. " " .. source .. " back leaves value mode", function()
        local instance = drive()
        setState(instance, phase)
        instance.valueMode = true
        local view = viewFor(instance, true)
        check(Input.dispatch(view, "back", nil, source) and not instance.valueMode
          and instance.open and instance.live and view.inflightFullscreen, "RTN leaves only value mode")
      end)
    end
  end
  for _, substate in ipairs({"busy", "browse", "value", "setup", "post", "restore", "results"}) do
    regression("armed " .. substate .. " has no X or close hint", function()
      local instance = drive()
      local view = viewFor(instance, true)
      if substate == "busy" then instance.profileJob = {plan = {}, at = 1}; view.state.inflight.phase = "ground"
      elseif substate == "value" then instance.valueMode = true; view.state.inflight.valueMode = true
      elseif substate == "setup" then instance.fcSetupOpen = true; view.state.inflight.phase = "ground"
      elseif substate == "post" then instance:setPhase("post"); view.state.inflight.phase = "post"
      elseif substate == "restore" then instance.restoreConfirm = {all = true}
      elseif substate == "results" then instance.restoreResultOpen = 1 end
      local nodes, closes, hints = {}, 0, 0
      Screen.buildFullscreen(nodes, view)
      walk(nodes, function(node)
        local text = type(node.text) == "function" and node.text() or node.text
        if text == "X" then closes = closes + 1 end
        if type(text) == "string" and string.find(text, "RTN close", 1, true) then hints = hints + 1 end
      end)
      check(closes == 0 and hints == 0, "armed tree contains no close control or hint")
    end)
  end
  regression("post-flight read-out survives close and reopen", function()
    local instance = drive()
    instance.fired, instance.primedValues = 3, {[18] = 100}
    instance:setPhase("post")
    instance.deltaPage = 2
    local view = viewFor(instance, false)
    check(Input.dispatch(view, "close", nil, "touch"), "post close accepted")
    check(instance.post and instance.fired == 3 and instance.primedValues[18] == 100, "post comparison retained on close")
    -- The quick menu raises only this flag; a normal drive tick republishes the read-out.
    view.inflightFullscreen = true
    instance.open = true
    instance._checkedAt, instance._checkResult = ticks, "ok"
    Drive.tick(view, instance)
    check(view.state.inflight.phase == "post" and instance.post and instance.deltaPage == 2,
      "reopening republishes the same post-flight read-out")
    local nodes, saved = {}, false
    Screen.buildFullscreen(nodes, view)
    walk(nodes, function(node) if node.text == "RTN close / Board has saved" then saved = true end end)
    check(saved, "reopened post surface renders its footer")
  end)
  regression("ground surface close retains session", function()
    local instance = drive()
    instance:setPhase("ground")
    instance.primedValues, instance.baseline = {[18] = 100}, {pid1 = {[18] = 100}}
    local baseline = instance.baseline
    instance._checkedAt, instance._checkResult = ticks, "ok"
    instance:evaluateInterlock(ticks, false)
    check(not instance.live and instance.bankWritten == 0, "surface close clears the live output")
    check(instance.baseline == baseline and instance.primedValues[18] == 100, "surface close retains start values")
  end)
  print(passed .. " close regressions passed; " .. #failures .. " failed")
  check(#failures == 0, table.concat(failures, "\n"))
end

-- Ground actions use the published slot/session scalars.
do
  local savedStart, savedRefresh, savedRetry = BoardPrime.start, BoardPrime.refreshValues, BoardPrime.retryReturn
  local savedRefusal, savedRunning = BoardPrime.groundRefusal, BoardPrime.isRunning
  local starts, refreshes, retries, refusal = 0, 0, 0, nil
  local startedWidget, startedDrive
  BoardPrime.start = function(view, instance)
    starts = starts + 1; startedWidget, startedDrive = view, instance
  end
  BoardPrime.refreshValues = function() refreshes = refreshes + 1 end
  BoardPrime.retryReturn = function() retries = retries + 1 end
  BoardPrime.groundRefusal = function() return refusal end
  BoardPrime.isRunning = function() return false end
  local function textOf(node)
    local text = type(node.text) == "function" and node.text() or node.text
    return type(text) == "string" and string.gsub(text, "\n", " ") or ""
  end
  local function action(nodes, label)
    local button
    for index, node in ipairs(nodes) do
      if node.type == "button" then button = node end
      if node.type == "label" then
        local text, following = textOf(node), nodes[index + 1]
        if text == label then return button, node end
        if following and following.type == "label" and following.x == node.x
          and text .. " " .. textOf(following) == label then return button, node end
      end
    end
  end
  for _, size in ipairs({ { 480, 272 }, { 480, 320 }, { 800, 480 } }) do
    local instance = drive()
    instance.phase, instance._checkedAt, instance._checkResult = "ground", ticks, "ok"
    local snap = {phase = "ground", setupVerdict = "ok", setSource = "board", cellCount = 36, boundsCount = 2,
      prime = {skipped = 3}, baseline = {timestamp = "2026-10-25 12:34"}}
    local translations = 0
    local view = {_inflight = instance, state = {armed = false, inflight = snap},
      zone = {w = size[1], h = size[2]}, i18n = {t = function(_, fallback)
        translations = translations + 1; return fallback
      end}}
    local nodes = {}
    Screen.buildFullscreen(nodes, view)
    local modelLine, slotsLine, sessionLine, warning
    -- A wrapped status row is two labels; its second line is the label right after it.
    local secondOf = {}
    for index, node in ipairs(nodes) do
      local text = textOf(node)
      local nextNode = nodes[index + 1]
      if nextNode and nextNode.type == "label" and nextNode.x == node.x and (nextNode.y or 0) > (node.y or 0) then
        secondOf[node] = nextNode
      end
      if text == "Model" then modelLine = nextNode end
      if text == "FC slots" then slotsLine = nextNode end
      if text == "Session" then sessionLine = nextNode end
      if string.find(text, "2 beyond the FC limits:", 1, true) == 1 then warning = node end
    end
    local plainTextOf = textOf
    local function rowText(node)
      local second = secondOf[node] and plainTextOf(secondOf[node]) or ""
      return plainTextOf(node) .. (second ~= "" and (" " .. second) or "")
    end
    check(modelLine and slotsLine and sessionLine and warning, "ground has three status lines and the FC bounds warning")
    check(textOf(modelLine) == "Setup OK" and string.find(rowText(slotsLine), "36 parameters on the board", 1, true),
      "model verdict and parameter count come from the current snapshot")
    check(rowText(sessionLine) == "Start values 12:34", "the session names the time its start values were read")
    -- One line per status, placed by the standard font's measured line.
    local statusH = 20 + (size[2] > 350 and 6 or 0)
    check(slotsLine.y - modelLine.y == statusH and sessionLine.y - slotsLine.y == statusH
      and warning.y - sessionLine.y == statusH, "each status takes one measured line at every supported size")
    check(not secondOf[modelLine] and not secondOf[slotsLine] and not secondOf[sessionLine],
      "statuses that fit take no second line")
    check(string.find(rowText(slotsLine), "(3 skipped)", 1, true), "the slot status retains the skipped count")
    check(string.find(rowText(warning), "set up the FC again", 1, true), "bounds warning includes the remedy")
    check(warning.color ~= slotsLine.color, "FC bounds warning uses a warning colour")
    local choose, chooseLabel = action(nodes, "Choose parameters")
    local read = action(nodes, "Read again")
    local restore = action(nodes, "Restore all")
    check(choose and read and restore and choose.active() and choose.visible() and chooseLabel.visible(),
      "usable board exposes the primary and all ground actions")
    check(not action(nodes, "Reset start values"), "every session reads its own start values: no reset action")
    local setup = action(nodes, "Set up suggested functions")
    check(choose.w == restore.w and setup and setup.h == read.h and choose.y + choose.h < setup.y
      and (setup.y < read.y or (setup.y == read.y and setup.x + setup.w < read.x)) and read.y + read.h < restore.y and restore.color ~= read.color,
      "primary is full width, secondary actions follow in focus order with one height, restore stays below")
    for _, node in ipairs(nodes) do
      local text = type(node.text) == "function" and node.text() or node.text
      local height = node.h or (node.type == "label" and (node.font == MIDSIZE and 30 or node.font == SMLSIZE and 14 or 20) *
        (1 + select(2, string.gsub(text or "", "\n", ""))) or 0)
      check((node.y or 0) + height <= size[2], "ground geometry stays inside every supported height")
    end
    local before = translations
    for _ = 1, 3 do slotsLine.text(); sessionLine.text(); warning.text() end
    snap.prime, snap.baseline = {skipped = 3}, {timestamp = "2026-10-25 12:34"}
    slotsLine.text(); sessionLine.text(); warning.text()
    check(translations == before, "unchanged scalar inputs reuse cached ground strings even with fresh snapshot tables")
    snap.baseline.timestamp = "2026-10-25 13:45"
    check(rowText(sessionLine) == "Start values 13:45", "session cache tracks the stored timestamp")
    for _, case in ipairs({{"unread", 36, false}, {"unavailable", 36, false}, {"board", 0, false}, {"board", 1, true}}) do
      snap.setSource, snap.cellCount = case[1], case[2]
      check(choose.active() == case[3] and choose.visible() == case[3] and chooseLabel.visible() == case[3],
        "primary visibility and activity require board slots and a positive count")
      local rebuilt = {}
      Screen.buildFullscreen(rebuilt, view)
      local button, label = action(rebuilt, "Choose parameters")
      check(button and button.active() == case[3] and button.visible() == case[3] and label.visible() == case[3],
        "initial scene applies the same picker availability")
      if case[1] == "unread" then
        check(rowText(slotsLine) == "Not read yet", "unread board offers no documented set")
      elseif case[1] == "unavailable" then
        check(string.find(rowText(slotsLine), "No usable slots on the board", 1, true), "unusable board explains the empty set")
      end
    end
    snap.boundsCount = 0
    check(warning.text() == "", "retained warning clears when no values exceed FC limits")
    snap.baseline, snap.prime = nil, {phase = "idle"}
    check(rowText(sessionLine) == "Values not read", "session explains that start values have not been read")
    snap.prime = {phase = "error", error = "no_link"}
    check(rowText(sessionLine) == "Reading failed: No FC link", "session retains read refusal text")
    snap.transfer = {state = "error", reason = "baseline_identity"}
    check(string.find(rowText(sessionLine), "Restore refused/failed:", 1, true) == 1,
      "session retains backup refusal text")
    snap.transfer = nil
    local epoch = instance.valueEpoch
    view._tuningKeyDirty = nil; choose.press()
    check(instance.sessionPickerOpen and instance.valueEpoch == epoch + 1 and view._tuningKeyDirty,
      "Choose parameters opens the session picker and requests a rebuild")
    instance.sessionPickerOpen = nil
    local readBefore = refreshes
    read.press()
    check(refreshes == readBefore + 1, "Read again still refreshes the current session")
    instance.restorePending = true
    local retryBefore = retries
    read.press()
    check(retries == retryBefore + 1 and refreshes == readBefore + 1, "Read again retries a pending return")
    instance.restorePending = nil
    restore.press()
    check(instance.restoreConfirm and instance.restoreConfirm.all, "Restore all still opens its existing target confirmation")
    instance.restoreConfirm = nil
    for _, blocked in ipairs({"armed", "no_arm_sensor"}) do
      view.state.armed, refusal = blocked == "armed", blocked == "no_arm_sensor" and blocked or nil
      local locked = {}; Screen.buildFullscreen(locked, view)
      check(not action(locked, "Choose parameters")
        and not action(locked, "Read again") and not action(locked, "Restore all"), "armed/missing-arm scenes retain no ground actions")
      if blocked == "no_arm_sensor" then
        -- The arm state comes from Arming Flags (90) or System Status (120); 99 is Adjustment Function.
        local hint
        for _, node in ipairs(locked) do
          local text = textOf(node)
          if string.find(text, "arm state", 1, true) then hint = text end
        end
        check(hint and string.find(hint, "90", 1, true) and string.find(hint, "120", 1, true)
          and not string.find(hint, "99", 1, true), "the missing-arm hint names the arming sensors")
      end
    end
    for _, locale in ipairs({"en", "de"}) do
      local text = assert(loadfile("src/rfsuite/i18n/" .. locale .. ".lua"))().widgets.dashboard.inflight_ground_no_arm
      check(text and string.find(text, "90", 1, true) and string.find(text, "120", 1, true)
        and not string.find(text, "99", 1, true), "the missing-arm hint names the arming sensors in " .. locale)
    end
    view.state.armed, refusal = false, nil
    check(Screen.buildZone == nil, "the dashboard zone has no tuning builder")
  end
  BoardPrime.start, BoardPrime.refreshValues, BoardPrime.retryReturn = savedStart, savedRefresh, savedRetry
  BoardPrime.groundRefusal, BoardPrime.isRunning = savedRefusal, savedRunning
end

-- After landing a read or restore takes the whole screen, so the post-flight list it was started from
-- is still there when it ends; that busy scene keeps its geometry while the job reads, returns and saves.
for _, size in ipairs({ { 480, 272 }, { 480, 320 }, { 800, 480 } }) do
  for _, restoring in ipairs({ false, true }) do
    local job = {
      at = 1, original = { pid = 1, rate = 2 },
      plan = {
        { op = "read", kind = "pid", index = 2 },
        { op = "returnSelect", kind = "pid", index = 1 },
        { op = "returnCheck", kind = "rate", index = 2 },
        { op = "returnStatus" },
        { op = "eeprom" },
        { op = "savedStatus" },
        { op = "persistVerify", kind = "pid", index = 2 },
        { op = "persistDone" }
      }
    }
    local instance = { profileJob = job }
    if restoring then instance.transfer = { state = "busy", kind = "restore" } end
    local view = { _inflight = instance, state = { inflight = { phase = "post" } },
      zone = { w = size[1], h = size[2] } }
    local nodes = {}
    Screen.buildFullscreen(nodes, view)
    local bar, step, current, title, cancel, cancelLabel, retry, retryLabel
    for i, node in ipairs(nodes) do
      if node.type == "rectangle" and type(node.size) == "function" then bar = node end
      if node.type == "label" then
        local text = type(node.text) == "function" and node.text() or node.text
        if text == "Step 1 of 8" then step = node end
        if text == "PID profile 2: reading values" then current = node end
        if text == (restoring and "Restoring" or "Reading") then title = node end
        if text == "Cancel" then cancel, cancelLabel = nodes[i - 1], node end
        if text == "Read again" then retry, retryLabel = nodes[i - 1], node end
        check(text ~= "Profile read/return pending", "busy screen omits the static pending line")
      end
    end
    check(bar and step and current and title and cancel and retry, "busy scene has title, bar, steps and actions")
    check(title.font == (size[2] > 350 and DBLSIZE or MIDSIZE), "busy title uses the large font")
    check(title.y < bar.y and bar.y + bar.h < step.y and step.y < current.y and current.y < cancel.y,
      "busy rows and bottom action fit at every supported size")
    local background
    for _, node in ipairs(nodes) do
      if node.type == "rectangle" and node ~= bar and node.x == bar.x and node.y == bar.y then background = node end
    end
    check(background and background.w == size[1] - bar.x * 2 and background.h == bar.h,
      "progress background spans the content width")
    local fill, height = bar.size()
    check(fill == 0 and height == bar.h, "progress starts empty")
    if restoring then
      check(cancel.type == "button" and not cancel.active() and not cancel.visible() and not cancelLabel.visible(),
        "a restore offers no Cancel: stopping between its writes would leave half-restored values")
    else
      check(cancel.type == "button" and cancel.active() and cancel.visible() and cancelLabel.visible(),
        "read operation enables and shows Cancel")
    end
    check(not retry.active() and not retry.visible() and not retryLabel.visible(), "Read again is hidden during reading")
    job.at = 2
    check(step.text() == "Step 2 of 8" and current.text() == "Back to PID 1 / RTE 2",
      "retained step labels change from reading to the original profile pair")
    check(bar.size() == math.floor(background.w / 8), "retained progress bar follows the completed operation count")
    for at = 2, #job.plan do
      job.at = at
      local expected = at <= 4 and "Back to PID 1 / RTE 2"
        or at == 7 and "PID profile 2: checking values" or "Saving on the flight controller"
      check(current.text() == expected, "plain-language caption for " .. job.plan[at].op)
      check(not cancel.active() and not cancel.visible() and not cancelLabel.visible(),
        "Cancel is unavailable during " .. job.plan[at].op)
      cancel.press()
      check(not job.cancelled, "a stale Cancel press cannot abort a return or save")
    end
    check(current.text() == "Saving on the flight controller", "save stage has a plain-language caption")
    job.at = #job.plan + 1
    check(bar.size() == background.w and step.text() == "Step 8 of 8", "completed progress stays within the bar and step count")
    job.at = 1
    check(cancel.active() == not restoring and current.text() == "PID profile 2: reading values",
      "read operation re-enables Cancel, a restore never")
    job.returnBlocked, job.error = true, "no_link"
    check(retry.active() and retry.visible() and retryLabel.visible()
      and not cancel.active() and not cancel.visible() and not cancelLabel.visible(),
      "blocked return shows only Read again")
    local warning
    walk(nodes, function(node)
      if node.type == "label" and type(node.text) == "function" and node.text() == "No FC link" then warning = node end
    end)
    check(warning and warning.y > current.y and warning.y + 14 <= cancel.y, "blocked-return warning fits its reserved row")
    cancel.press()
    check(not job.cancelled, "blocked return rejects a stale Cancel press")
    job.returnBlocked = nil
    check(warning.text() == "" and not retry.active() and cancel.active() == not restoring,
      "warning and actions react when the return unblocks")
    cancel.press()
    check(job.cancelled == (not restoring or nil), "pressing Cancel requests cancellation of a read only")

    local cases = {
      { "initial", nil, nil, "Reading the active profiles" },
      { "select", "pid", 3, "PID profile 3: reading values" },
      { "status", "rate", 4, "Rate profile 4: reading values" },
      { "read", "global", nil, "Global values: reading" },
      { "write", "pid", 3, "PID profile 3: writing values" },
      { "write", "rate", 4, "Rate profile 4: writing values" },
      { "write", "global", nil, "Global values: writing values" },
      { "verify", "pid", 3, "PID profile 3: checking values" },
      { "persistVerify", "rate", 4, "Rate profile 4: checking values" },
      { "verify", "global", nil, "Global values: checking values" },
      { "targetDone", "global", nil, "Global values: checking values" }
    }
    for _, case in ipairs(cases) do
      job.plan[1] = { op = case[1], kind = case[2], index = case[3] }
      check(current.text() == case[4], "reactive caption for " .. case[1])
    end
    -- The SD session check runs before the first message; its caption must not claim a connect.
    job.plan[1] = { op = "initial" }
    job.validation = {}
    check(current.text() == "Checking the saved session", "reactive caption while the saved session is checked")
    job.validation = nil
    check(current.text() == "Reading the active profiles", "caption follows the end of the session check")
    instance.profileJob = nil
    check(not cancel.active() and not retry.active(), "old actions cannot operate on a finished job")
  end
end

-- On the ground the same job runs inside the ground surface: the session row names it and its step,
-- a bar and a caption follow it in the panel, the actions stay on screen and only the primary place
-- changes -- Cancel while a read may stop, Read again while the return is held.
do
local savedRetry, savedRunning, savedRefusal = BoardPrime.retryReturn, BoardPrime.isRunning, BoardPrime.groundRefusal
local retries = 0
BoardPrime.retryReturn = function() retries = retries + 1 end
BoardPrime.isRunning = function() return false end
BoardPrime.groundRefusal = function() return nil end
for _, size in ipairs({ { 480, 272 }, { 480, 320 }, { 800, 480 } }) do
  for _, restoring in ipairs({ false, true }) do
    local job = {
      at = 1, original = { pid = 1, rate = 2 },
      plan = {
        { op = "read", kind = "pid", index = 2 },
        { op = "returnSelect", kind = "pid", index = 1 },
        { op = "eeprom" },
        { op = "persistDone" }
      }
    }
    local instance = drive()
    instance.phase, instance.profileJob = "ground", job
    if restoring then instance.transfer = { state = "busy", kind = "restore" } end
    local view = { _inflight = instance, state = { armed = false, inflight = { phase = "ground", setupVerdict = "ok",
      setSource = "board", cellCount = 36, prime = { phase = "done" } } }, zone = { w = size[1], h = size[2] } }
    local nodes = {}
    Screen.buildFullscreen(nodes, view)
    local bar, session, current, cancel, cancelLabel, retry, retryLabel, setup, restore
    for i, node in ipairs(nodes) do
      if node.type == "rectangle" and type(node.size) == "function" then bar = node end
      if node.type == "label" then
        local text = type(node.text) == "function" and node.text() or node.text
        if text == (restoring and "Restoring" or "Reading") .. " - Step 1 of 4" then session = node end
        if text == "PID profile 2: reading values" then current = node end
        if text == "Cancel" then cancel, cancelLabel = nodes[i - 1], node end
        if text == "Read again" and not retry then retry, retryLabel = nodes[i - 1], node end
        if text == "Set up suggested functions" then setup = nodes[i - 1] end
        if text == "Restore all" then restore = nodes[i - 1] end
      end
    end
    check(bar and session and current and cancel and retry and setup and restore,
      "ground progress has its step in the session row, a bar, a caption and the actions")
    check(session.y < bar.y and bar.y + bar.h <= current.y and current.y < retry.y and retry.y == cancel.y,
      "ground progress sits in the panel above the actions")
    check(not setup.active() and not restore.active(), "the other ground actions are shown but disabled while it runs")
    check(bar.size() == 0, "ground progress starts empty")
    if restoring then
      check(not cancel.active() and not cancel.visible() and not cancelLabel.visible(),
        "a restore on the ground offers no Cancel either")
    else
      check(cancel.active() and cancel.visible() and cancelLabel.visible(), "a ground read offers Cancel")
    end
    check(not retry.active() and not retry.visible() and not retryLabel.visible(), "Read again waits for a held return")
    job.at = 2
    check(session.text() == (restoring and "Restoring" or "Reading") .. " - Step 2 of 4"
      and current.text() == "Back to PID 1 / RTE 2" and bar.size() > 0, "the panel follows the job")
    check(not cancel.active(), "no Cancel during the return to the original profiles")
    job.returnBlocked, job.error = true, "no_link"
    check(retry.active() and retry.visible() and retryLabel.visible() and current.text() == "No FC link"
      and current.color() ~= session.color, "a held return shows why and offers Read again")
    retry.press()
    check(retries > 0, "Read again on the ground retries the held return")
    job.returnBlocked, job.at = nil, 1
    if not restoring then
      cancel.press()
      check(job.cancelled, "Cancel on the ground requests cancellation of the read")
    end
    instance.profileJob = nil
    check(not cancel.active() and not retry.active(), "the job's actions cannot act on a finished job")
  end
end
BoardPrime.retryReturn, BoardPrime.isRunning, BoardPrime.groundRefusal = savedRetry, savedRunning, savedRefusal
end

-- Model the source-backed non-editing encoder group: creation order, wrapping and immediate
-- scroll-to-view of a focused full-height child. A fully visible child emits no scroll event.
-- Sensor-only controls omit the containing widget; nativeRoot retains it as a group member.
EVT_VIRTUAL_ENTER = 514
local function nativeScene(nodes, view, counts, tall)
  counts.scenes = counts.scenes + 1
  local scene = { focus = {}, boxes = {}, at = 0, scrolls = 0 }
  local function build(list, parent)
    for _, node in ipairs(list) do
      local object = { node = node, parent = parent }
      if node.type == "box" then
        object.y, object.h = 0, node.h
        object.contentH = 0
        for _, child in ipairs(node.children or {}) do
          object.contentH = math.max(object.contentH, (child.y or 0) + (child.h or 0))
        end
        if node.scrolled then
          if not scene.sensor then
            counts.sensors = counts.sensors + 1
            scene.sensor = object
          else scene.reverse = object end
          if tall then object.h = (Input.LADDER_ROWS + 4) * node.h end
        end
        scene.boxes[#scene.boxes + 1] = object
      end
      if node.type == "button" or node.type == "momentaryButton" then
        scene.focus[#scene.focus + 1] = object
      end
      if node.children then build(node.children, node.type == "box" and object or parent) end
    end
  end
  build(nodes)
  function scene:scroll(box, y)
    y = math.max(0, math.min(y, math.max(0, box.contentH - box.h)))
    if box.y == y then return end
    box.y = y
    if box.node.scrolled then
      self.scrolls = self.scrolls + 1
      box.node.scrolled(0, y)
      box.node.scrolled(0, y) -- The bench delivers a second callback at the same position.
    end
  end
  function scene:focusAt(at)
    if counts.nativeRoot then
      -- Widget::setFullscreen adds the widget itself before the constructed controls.
      -- It remains a group member when native focus leaves it for a sensor button.
      self.at = at % (#self.focus + 1)
      if self.at == 0 then return end
    else
      self.at = (at - 1) % #self.focus + 1
    end
    local object = self.focus[self.at]
    local box = object.parent
    if box then
      local y = object.node.y
      if object.node.pos then local _; _, y = object.node.pos() end
      if y < box.y then self:scroll(box, y)
      elseif y + object.node.h > box.y + box.h then self:scroll(box, y + object.node.h - box.h) end
    end
  end
  function scene:sweep()
    for _, box in ipairs(self.boxes) do
      if box.node.scrollTo then
        local _, y = box.node.scrollTo()
        self:scroll(box, y)
      end
    end
  end
  function scene:rotate(direction)
    self:sweep()
    if self.at == 0 then self:focusAt(direction > 0 and 1 or #self.focus)
    else self:focusAt(self.at + direction) end
  end
  function scene:press()
    if self.at == 0 then return Input.key(view, EVT_VIRTUAL_ENTER) end
    return self.focus[self.at].node.press()
  end
  function scene:tapSensor()
    local box=self.reverse or self.sensor
    self:sweep()
    for _, object in ipairs(self.focus) do
      if object.parent==box then
        local y=object.node.y
        if object.node.pos then local _; _,y=object.node.pos() end
        if y<=box.y+box.h/2 and y+object.node.h>box.y+box.h/2 then return object.node.press() end
      end
    end
    error("topmost sensor window has no selected-row touch target")
  end
  scene:sweep()
  Screen.ready(view)
  return scene
end

-- Touch controls take native focus away from the ladder. Only a completed touch may rebuild
-- the scene; a held button must survive until release, even when its step was refused.
for _, valueMode in ipairs({true, false}) do
  local instance = drive()
  instance.valueMode = valueMode
  local view = {_inflight = instance, state = {armed = true}, zone = {w = 480, h = 320}}
  local counts, nodes, scene = {scenes = 0, sensors = 0, nativeRoot = true}
  local function render()
    Drive.sample(view)
    nodes = {}
    Screen.buildFullscreen(nodes, view)
    scene = nativeScene(nodes, view, counts)
    view._tuningKeyDirty = nil
  end
  local function touch(text)
    for index, object in ipairs(scene.focus) do
      local node = object.node
      if node.text == text or (node.children and node.children[1] and node.children[1].text == text) then
        scene:focusAt(index)
        node.press()
        return node
      end
    end
    error("touch control missing: " .. text)
  end
  local function returned(epoch, key)
    check(instance.ladderEpoch == epoch + 1 and view._tuningKeyDirty,
      "one completed live touch requests exactly one ladder rebuild")
    check(view._inflightSensor.index == nil, "touch still fences the first sensor return")
    render()
    check(Screen.renderKey(view.state.inflight) ~= key and scene.at == 0,
      "the touch rebuild republishes the live key and restores native root focus")
  end
  render()
  if valueMode then
    local epoch, valueEpoch = instance.ladderEpoch or 0, instance.valueEpoch
    local key, fired = Screen.renderKey(view.state.inflight), instance.fired
    local plus = touch("+")
    check(instance.fired == fired + 1 and instance.holdRow ~= nil, "touch hold starts a pulse")
    check((instance.ladderEpoch or 0) == epoch and instance.valueEpoch == valueEpoch,
      "touch hold press preserves the held scene")
    Drive.sample(view)
    check(Screen.renderKey(view.state.inflight) == key, "a held touch keeps the live render key")
    plus.release()
    check(instance.holdRow == nil and instance.valueEpoch == valueEpoch + 1,
      "release ends the hold and republishes the snapshot once")
    returned(epoch, key)
    epoch, key = instance.ladderEpoch, Screen.renderKey(view.state.inflight)
    plus = touch("+")
    check(instance.fired == fired + 1 and instance.stepRefusedReason == "cooling",
      "control: a second held press during the pulse is refused")
    check(instance.ladderEpoch == epoch, "a refused held press also waits for release")
    plus.release()
    returned(epoch, key)
    epoch, key = instance.ladderEpoch, Screen.renderKey(view.state.inflight)
    check(not Input.dispatch(view, "step", 1, "touch"), "a plain touch step is refused during cooling")
    returned(epoch, key)
    ticks = ticks + 31; instance:fastTick(ticks)
    ticks = ticks + 16; instance:fastTick(ticks)
    epoch, fired = instance.ladderEpoch, instance.fired
    scene:rotate(1); scene:sweep()
    check(instance.fired == fired + 1 and instance.ladderEpoch == epoch,
      "the first encoder detent after touch steps once without rebuilding away from the ladder end")
    ticks = ticks + 31; instance:fastTick(ticks)
    ticks = ticks + 16; instance:fastTick(ticks)
  end
  local epoch, key = instance.ladderEpoch or 0, Screen.renderKey(view.state.inflight)
  local entry = instance.entry
  ticks = ticks + 1; touch(">")
  check(instance.entry == entry + 1, "control: the plain touch arrow changes the function")
  returned(epoch, key)
  local group = instance.group
  -- The group picker is a scene of its own: no native popup, whose RTN calls nothing back and
  -- left the encoder walking a focus list under it.
  local function picker()
    local buttons = 0
    for _, object in ipairs(scene.focus) do
      if object.node.press and object.parent == nil then buttons = buttons + 1 end
    end
    return buttons
  end
  instance.valueMode = valueMode; instance.valueEpoch = instance.valueEpoch + 1
  ticks = ticks + 47; instance:fastTick(ticks); render()
  epoch, key = instance.ladderEpoch, Screen.renderKey(view.state.inflight)
  ticks = ticks + 1; touch(instance.groups[instance.group].name)
  check(instance.groupPicker and not instance.valueMode, "the title opens the group picker and leaves value mode")
  returned(epoch, key)
  check(view._inflightSensor == nil and scene.sensor == nil and picker() == #instance.groups + 1,
    "the picker draws one button per group and the title, and no ladder sensor: " .. picker())
  ticks = ticks + 1; Input.key(view, EVT_VIRTUAL_EXIT)
  check(not instance.groupPicker and instance.group == group, "RTN closes the picker and keeps the group")
  render()
  check(scene.sensor ~= nil and scene.at == 0, "the closed picker rebuilds the list with native root focus")
  local entry2 = instance.entry
  scene:rotate(1); scene:sweep()
  ticks = ticks + 1; scene:rotate(1); scene:sweep()
  check(instance.entry ~= entry2, "the encoder walks the functions again after RTN closed the picker")
  -- The encoder chooses inside the picker: walk to the last group and press.
  epoch, key = instance.ladderEpoch, Screen.renderKey(view.state.inflight)
  ticks = ticks + 1; touch(instance.groups[instance.group].name)
  render()
  for _ = 1, #instance.groups do scene:rotate(1) end
  ticks = ticks + 1; scene:press()
  check(not instance.groupPicker and instance.group == #instance.groups and instance.entry == 1,
    "an encoder press in the picker jumps straight to that group")
  render()
  check(scene.sensor ~= nil, "the chosen group's list is drawn again")
  -- The current group chosen again goes to its first function; a choice after landing does nothing.
  ticks = ticks + 1; Input.dispatch(view, "function", 1, "touch"); render()
  touch(instance.groups[instance.group].name); render()
  ticks = ticks + 1; Input.dispatch(view, "pick", nil, "touch", instance.group)
  check(instance.entry == 1 and not instance.groupPicker, "choosing the current group selects its first function")
  render(); touch(instance.groups[instance.group].name)
  local landed = instance.group
  instance:setPhase("ground")
  check(not instance.groupPicker and not Input.dispatch(view, "pick", nil, "touch", 1) and instance.group == landed,
    "landing takes the picker down and a late choice does nothing")
  instance:cleanup(false)
end

for _, surface in ipairs({{"ground", false}, {"ground", true}, {"post", false}, {"post", true}, {"live", false}}) do
  local instance = drive()
  instance.phase, instance.live = surface[1], surface[2]
  local view = {_inflight = instance}
  local epoch = instance.ladderEpoch
  for _, action in ipairs({"step", "function", "group"}) do
    Input.dispatch(view, action, 1, "touch")
    Input.dispatch(view, action, 1, "touch_hold")
    Input.dispatch(view, "release", nil, "touch_hold")
    check(instance.ladderEpoch == epoch, "touch does not rebuild a non-live surface: " .. instance.phase)
  end
  instance:cleanup(false)
end

for _, directions in ipairs({{1, 1, -1, -1, 1}, {-1, 1, 1, -1, -1, 1}}) do
  local instance = drive()
  instance.valueMode = true
  local view = {_inflight = instance, state = {armed = true}, zone = {w = 800, h = 480}}
  Drive.sample(view)
  local nodes, counts = {}, {scenes = 0, sensors = 0}
  Screen.buildFullscreen(nodes, view)
  local scene = nativeScene(nodes, view, counts)
  for _, direction in ipairs(directions) do
    local fired = instance.fired
    scene:rotate(direction); scene:sweep()
    check(instance.fired == fired + 1 and instance.written * direction > 0,
      "fresh value ladder handles every detent across its entry seam")
    ticks = ticks + 31; instance:fastTick(ticks)
    ticks = ticks + 16; instance:fastTick(ticks)
  end
end

-- This uses the same scene-key function as Runtime and counts actual sensor constructions.
-- The source control ensures that a detached helper cannot conceal a Runtime key regression.
do
  local file = assert(io.open("src/rfsuite/widgets/dashboard/runtime.lua", "rb"))
  local source = file:read("a"); file:close()
  check(string.find(source, '.. "|" .. inflightScreen().renderKey(snapshot)', 1, true), "Runtime uses the tested structural scene key")
end

for _, size in ipairs({ { 480, 272 }, { 480, 320 }, { 800, 480 } }) do
  pid, rate = 1, 2
  local instance = drive()
  local view = { _inflight = instance, state = { armed = true }, zone = { w = size[1], h = size[2] } }
  ticks = ticks + 1
  Drive.sample(view)
  local browse = {}
  Screen.buildFullscreen(browse, view)
  local counts = { scenes = 0, sensors = 0 }
  local scene = nativeScene(browse, view, counts)
  local key = Screen.renderKey(view.state.inflight)
  local function render()
    Drive.sample(view)
    local nextKey = Screen.renderKey(view.state.inflight)
    if nextKey ~= key then
      key = nextKey
      local nodes = {}
      Screen.buildFullscreen(nodes, view)
      scene = nativeScene(nodes, view, counts)
    end
    scene:sweep()
  end
  check(scene.at == 0, "native focus starts outside the sensor")
  local browseBox = scene.sensor
  debugInput = true
  local traceBefore = #inputTraces
  scene:rotate(1); render()
  check(instance.entry == 2 and counts.sensors == 1 and scene.sensor == browseBox,
    "forward browse detent retains sensor and selects/announces function")
  check(Announcer.selectionTick(ticks + 70), "browse detent schedules settled announcement")
  ticks = ticks + 1
  scene:rotate(-1); render()
  check(instance.entry == 1 and counts.sensors == 1, "backward browse detent retains sensor")
  -- Jump directly between real rows, independently of the guarded native wrap.
  local beforeEntry, beforeFired = instance.entry, instance.fired
  browseBox.node.scrolled(0, 5 * browseBox.node.h)
  render()
  check(instance.entry == beforeEntry and instance.fired == beforeFired
    and instance.stepRefusedReason == "list_end", "browse wrap/jump gives end feedback and keeps selection")
  browseBox.node.scrolled(0, browseBox.node.h)
  scene:press(); render()
  check(instance.valueMode and counts.sensors == 2, "one press selects value mode and builds its ladder")
  local valueBox = scene.sensor
  local atBuild = counts.sensors
  ticks = ticks + 1
  scene:rotate(1); render()
  check(instance.fired == beforeFired + 1 and counts.sensors == atBuild and scene.sensor == valueBox,
    "one value detent steps once without rebuilding")
  local firstPulse = instance.fired
  scene:rotate(1); render()
  check(instance.fired == firstPulse, "native busy detent is spent")
  ticks = ticks + 31; render()
  ticks = ticks + 16; render()
  check(instance.fired == firstPulse, "native refusal has no queued replay")
  scene:rotate(-1); render()
  check(instance.fired == firstPulse + 1 and instance.written < 0, "native backward detent steps down")
  ticks = ticks + 31; render()
  ticks = ticks + 16; render()
  for _, direction in ipairs({1, 1, -1, -1, 1, -1, -1, 1, 1}) do
    local fired = instance.fired
    scene:rotate(direction); render()
    check(instance.fired == fired + 1 and instance.written * direction > 0,
      "each value detent including a direction reversal steps once")
    check(counts.sensors == atBuild and scene.sensor == valueBox, "value reversals retain both sensor windows")
    ticks = ticks + 31; render()
    ticks = ticks + 16; render()
  end
  -- A box tall enough to show every row is the negative control beside the working sensor.
  local tallNodes = {}
  Screen.buildFullscreen(tallNodes, view)
  local tallScene = nativeScene(tallNodes, view, counts, true)
  beforeFired = instance.fired
  tallScene:rotate(1)
  check(tallScene.scrolls == 0 and instance.fired == beforeFired, "tall value box has no scrolled and no step")
  -- Restore a real scene, then jump to a row inside the end margin: no step, and a rebuild of the
  -- live scene is requested instead of moving the ladder in place.
  local valueNodes = {}
  Screen.buildFullscreen(valueNodes, view)
  scene = nativeScene(valueNodes, view, counts)
  key = Screen.renderKey(view.state.inflight)
  local sensor = view._inflightSensor
  local buildsBeforeEdge = counts.sensors
  local epochBefore = instance.ladderEpoch or 0
  for i, object in ipairs(scene.focus) do
    if object.parent == scene.reverse and object.node.y == 4 * scene.sensor.node.h then scene:focusAt(i); break end
  end
  check(sensor.rebuildRequested and (instance.ladderEpoch or 0) == epochBefore + 1 and instance.fired == beforeFired,
    "edge jump re-baselines and requests a ladder rebuild without a step")
  render()
  check(counts.sensors == buildsBeforeEdge + 1 and view._inflightSensor ~= sensor and instance.valueMode,
    "the rebuild builds a fresh value ladder and keeps value mode")
  for _, direction in ipairs({-1, -1, 1, 1, -1}) do
    local fired = instance.fired
    scene:rotate(direction); render()
    check(instance.fired == fired + 1 and instance.written * direction > 0,
      "each value detent after a ladder rebuild steps once")
    ticks = ticks + 31; render()
    ticks = ticks + 16; render()
  end
  beforeFired = instance.fired
  -- Retained callbacks from a replaced box cannot dispatch anything.
  valueBox.node.scrolled(0, 34 * valueBox.node.h)
  check(instance.fired == beforeFired, "replaced sensor callbacks are stale")
  -- A guard before the control boundary makes leaving/returning observable and harmless.
  local guardAt
  for i, object in ipairs(scene.focus) do
    if object.parent == scene.sensor and object.node.y == (Input.LADDER_ROWS + 2) * scene.sensor.node.h then guardAt = i end
  end
  scene:focusAt(guardAt)
  check(view._inflightSensor.rebuildRequested, "reaching a guard row requests a ladder rebuild")
  scene:sweep() -- settle the inactive window's acknowledged reset before counting
  beforeFired = instance.fired
  local scrolls = scene.scrolls
  scene:rotate(1)
  check(scene.scrolls == scrolls and instance.fired == beforeFired, "moving focus onto touch controls emits no sensor event or step")
  scene:rotate(-1)
  scene:rotate(-1)
  check(instance.fired == beforeFired, "return from controls through a guard cannot step")
  -- A pointer press bypasses the creation-order guards. Refused touch actions must still fence
  -- re-entry, including the dangerous case where its scroll delta happens to be exactly one.
  check(not Input.dispatch(view, "group", -instance.group, "touch"), "out-of-range pointer navigation is refused")
  local currentRow = view._inflightSensor.row
  local adjacent = currentRow < Input.LADDER_ROWS and currentRow + 1 or currentRow - 1
  scene.sensor.node.scrolled(0, (adjacent - 1) * scene.sensor.node.h)
  check(instance.fired == beforeFired, "a pointer control press fences a one-row return to the value sensor")
  scene:press(); render()
  check(not instance.valueMode, "one ladder press leaves value mode")
  local tallBrowseNodes = {}
  Screen.buildFullscreen(tallBrowseNodes, view)
  local tallBrowse = nativeScene(tallBrowseNodes, view, counts, true)
  beforeEntry = instance.entry
  tallBrowse:rotate(1)
  check(tallBrowse.scrolls == 0 and instance.entry == beforeEntry, "tall browse box has no scrolled and no navigation")
  local scrollTraces, pressTraces = 0, 0
  for i = traceBefore + 1, #inputTraces do
    local line = inputTraces[i]
    if string.find(line, "scrolled y=", 1, true) then
      scrollTraces = scrollTraces + 1
      check(string.find(line, " row=", 1, true) and string.find(line, " delta=", 1, true)
        and string.find(line, " result=", 1, true), "every scroll trace includes row, delta and decision")
    end
    if string.find(line, "press row=", 1, true) then pressTraces = pressTraces + 1 end
  end
  check(scrollTraces > 10 and pressTraces == 2, "scroll delivery and both mode presses are debug-traced")
  debugInput = false
  local rows = 0
  walk(browse, function(node)
    if node.type == "button" and node.text == "" and node.h == (size[2] > 350 and 80 or 56) then
      rows = rows + 1
      check(node.borderPad==0, "selected row retains its native padding request")
      local insetX, insetY = size[1] >= 800 and 10 or 8, size[1] >= 800 and 5 or 4
      local outline, name, value = node.children[1], node.children[2], node.children[4]
      check(outline.x + insetX == 0 and outline.y + insetY == 0
        and outline.w == node.w and outline.h == node.h and outline.rounded == 6,
        "single accent outline covers the native row border")
      check(value.x + insetX + value.w <= node.w - 16, "selected value reserves right-edge clearance beyond neighbour values")
      check(name.y == 0 and value.y == 0 and name.align == VCENTER and value.align == RIGHT + VCENTER,
        "native font metrics vertically centre selected labels")
    end
    check(node.type ~= "page", "the tuning surface must not consume PAGE in a native page")
  end)
  check(rows == 8, "six full-name browse rows and both resting touch copies at " .. size[1] .. "x" .. size[2])
  local closeLabels = 0
  walk(browse, function(node) if node.type == "label" and node.text == "X" then closeLabels = closeLabels + 1 end end)
  check(view.state.inflight.live == true and closeLabels == 0, "the surface in the air carries no Close")
  local groundView = { _inflight = drive(), state = { armed = false }, zone = view.zone }
  Drive.sample(groundView)
  groundView.state.inflight.phase = "ground" -- the fixture's radio reports armed; the screen reads the snapshot
  local ground, groundCloses = {}, 0
  Screen.buildFullscreen(ground, groundView)
  walk(ground, function(node) if node.type == "label" and node.text == "X" then groundCloses = groundCloses + 1 end end)
  check(groundView.state.inflight.phase ~= "live" and groundCloses == 1, "control: the ground surface keeps its Close")
  -- The arrows walk the functions of the group; the bare group title opens the group menu.
  do
    local touchDrive = drive()
    local touchView = { _inflight = touchDrive, state = { armed = true }, zone = view.zone }
    Drive.sample(touchView)
    local nodes, arrows, titleButton, selectedValue = {}, {}, nil, nil
    Screen.buildFullscreen(nodes, touchView)
    local groupName = touchDrive.groups[touchDrive.group].name
    walk(nodes, function(node)
      if node.type == "button" and (node.text == "<" or node.text == ">") then arrows[node.text] = node end
      if node.type == "button" and node.text == groupName then titleButton = node end
      if node.type == "label" and node.font == (size[2] > 350 and XXLSIZE or DBLSIZE) then selectedValue = node end
    end)
    check(arrows["<"] and arrows[">"] and titleButton, "arrows and a group title without a count are drawn")
    check(selectedValue ~= nil, "the selected row's value uses the larger font")
    local g0, e0 = touchDrive.group, touchDrive.entry
    check(#touchDrive.groups[g0].entries > e0, "fixture group has a next function")
    ticks = ticks + 1; arrows[">"].press()
    check(touchDrive.group == g0 and touchDrive.entry == e0 + 1, "the right arrow selects the next function of the group")
    ticks = ticks + 1; arrows["<"].press()
    check(touchDrive.group == g0 and touchDrive.entry == e0, "the left arrow selects the previous function")
    ticks = ticks + 1; arrows["<"].press()
    check(touchDrive.entry == e0 and touchDrive.stepRefusedReason == "list_end", "the arrows stop at the first function")
    ticks = ticks + 1; arrows[">"].press()
    touchView._inflightSensor = touchView._inflightSensor or {}
    touchView._inflightSensor.index = 3
    ticks = ticks + 1; titleButton.press()
    check(touchView._inflightSensor.index == nil, "opening the group picker fences the next sensor return")
    check(touchDrive.groupPicker == true, "the group title opens the group picker")
    Drive.sample(touchView)
    local pickerNodes, cells = {}, 0
    Screen.buildFullscreen(pickerNodes, touchView)
    walk(pickerNodes, function(node)
      if node.type == "button" and node.text ~= groupName and node.press then cells = cells + 1 end
      if node.type == "button" then
        check((node.y or 0) + (node.h or 0) <= size[2], "every picker button fits the screen")
      end
    end)
    check(cells >= #touchDrive.groups - 1, "the picker offers every group: " .. cells)
    ticks = ticks + 1; Input.dispatch(touchView, "pick", nil, "touch", #touchDrive.groups)
    check(#touchDrive.groups < 2 or (touchDrive.group == #touchDrive.groups and touchDrive.entry == 1),
      "a picker choice jumps straight to that group")
  end
  for _, node in ipairs(browse) do
    check((node.x or 0) >= 0 and (node.y or 0) >= 0 and (node.w or 1) > 0
      and (node.h or 1) > 0 and (node.y or 0) + (node.h or 1) <= size[2], "top-level geometry fits")
  end
  instance.valueMode = true; instance.valueEpoch = instance.valueEpoch + 1
  ticks = ticks + 1; Drive.sample(view)
  local value = {}
  Screen.buildFullscreen(value, view)
  scene = nativeScene(value, view, counts)
  key = Screen.renderKey(view.state.inflight)
  local sensorBeforeReport, buildsBeforeReport = scene.sensor, counts.sensors
  local sensorBox, valueGetter
  walk(value, function(node)
    check(node.type ~= "numberEdit", "NumberEdit cannot receive touch or encoder focus")
    if node.type == "box" and node.scrolled then sensorBox = node end
    if node.type == "label" and node.font == XXLSIZE and type(node.text) == "function" then valueGetter = node.text end
  end)
  check(sensorBox and valueGetter and valueGetter() == "--", "scroll sensor and large unknown value")
  local epoch = instance.valueEpoch
  local activeId = view.state.inflight.activeId
  local oldSensor = radio.sensor
  radio.sensor = function(name) if name == "AdjF" then return activeId elseif name == "AdjV" then return 123 end; return oldSensor(name) end
  ticks = ticks + 1; Drive.sample(view)
  render()
  check(instance.valueEpoch == epoch and valueGetter() == "123", "AdjV updates the retained large label without a layout change")
  check(counts.sensors == buildsBeforeReport and scene.sensor == sensorBeforeReport,
    "value report builds zero sensor boxes")
  instance.primedValues[activeId] = 120
  instance.reportEpoch = instance.reportEpoch + 1
  ticks = ticks + 1; Drive.sample(view); render()
  local comparisonGetter
  walk(value, function(node)
    if node.type == "label" and type(node.text) == "function" and node.text() == "Start 120 / +3" then comparisonGetter = node.text end
  end)
  check(comparisonGetter and counts.sensors == buildsBeforeReport and scene.sensor == sensorBeforeReport,
    "session start comparison updates inside the retained scene")
  local largeY, comparisonY
  for _, node in ipairs(value) do
    if node.text==valueGetter then largeY=node.y end
    if node.text==comparisonGetter then comparisonY=node.y end
  end
  check(comparisonY-largeY >= (size[2]>350 and 100 or 66), "large value and start/difference line do not overlap")
  instance.primedValues[activeId] = nil
  instance.reportEpoch = instance.reportEpoch + 1
  ticks = ticks + 1; Drive.sample(view); render()
  check(comparisonGetter() == "" and counts.sensors == buildsBeforeReport,
    "unknown baseline hides the comparison without rebuilding")
  pid = 3
  ticks = ticks + 1; Drive.sample(view)
  check(instance.profileValues.pid[1][activeId] == 123 and instance.values[activeId] == nil, "another profile's report preserves its owner and clears the active view")
  local paused = {}
  Screen.buildFullscreen(paused, view)
  local pauseText = false
  walk(paused, function(node) if type(node.text) == "string" and string.find(node.text, "PAUSED", 1, true) == 1 then pauseText = true end end)
  check(pauseText, "paused surface is visible")
  radio.sensor = oldSensor
end

-- Tiny flight lists still have observable boundaries: a two-row wrap has a delta of one,
-- so the guard must intervene before it can masquerade as a legitimate reverse detent.
for _, flightList in ipairs({ "18", "18,19" }) do
  pid, rate = 1, 2
  local instance = drive()
  instance.settings.flight_list = flightList
  instance:rebuildGroups(true)
  local view = { _inflight = instance, state = { armed = true }, zone = { w = 480, h = 272 } }
  ticks = ticks + 1; Drive.sample(view)
  local nodes, counts = {}, { scenes = 0, sensors = 0 }
  Screen.buildFullscreen(nodes, view)
  local scene = nativeScene(nodes, view, counts)
  local size = #instance.groups[1].entries
  if size == 2 then
    scene:rotate(1)
    check(instance.entry == 2, "two-function group supports a forward detent")
    scene:rotate(-1)
    check(instance.entry == 1, "two-function group supports a backward detent")
    scene:rotate(1)
  end
  local selected = instance.entry
  scene:rotate(1)
  check(instance.entry == selected and instance.stepRefusedReason == "list_end",
    "tiny group end guard prevents a one-row wrap")
  scene.sensor.node.scrolled(0, scene.sensor.node.h / 2)
  local _, dragY = scene.sensor.node.scrollTo()
  check(dragY == scene.sensor.node.h / 2 and instance.entry == selected,
    "fractional touch drag is retained without navigation")
end

for _, size in ipairs({{480,272}, {480,320}, {800,480}}) do
  do
    pid,rate=1,2
    local instance=drive()
    local view={_inflight=instance,state={armed=true},zone={w=size[1],h=size[2]}}
    ticks=ticks+50; Drive.sample(view)
    local nodes,counts={},{scenes=0,sensors=0}
    Screen.buildFullscreen(nodes,view)
    nativeScene(nodes,view,counts):tapSensor()
    check(instance.valueMode and instance.fired==0,"initial selected-row touch reaches the matching resting target")
    ticks=ticks+1; Drive.sample(view)
    nodes={}; Screen.buildFullscreen(nodes,view)
    nativeScene(nodes,view,counts):tapSensor()
    check(not instance.valueMode and instance.fired==0,"initial value-name touch leaves through the matching resting target")
  end
  for _, direction in ipairs({-1, 1}) do
    pid, rate = 1, 2
    local instance = drive()
    local view = {_inflight=instance, state={armed=true}, zone={w=size[1], h=size[2]}}
    ticks=ticks+50; Drive.sample(view)
    local nodes, counts = {}, {scenes=0, sensors=0}
    Screen.buildFullscreen(nodes, view)
    local scene = nativeScene(nodes, view, counts)
    check(scene.at==0 and scene.sensor and scene.reverse, "both encoder entry windows start outside native focus")
    if direction<0 then
      local soundCount = #sounds
      scene:rotate(-1)
      check(instance.entry==1 and instance.stepRefusedReason=="list_end" and #sounds==soundCount+1,
        "first negative browse detent gives one end tone")
      scene:rotate(-1)
      check(instance.entry==1 and instance.stepRefusedReason=="list_end", "first-row guard cannot leave the sensor silently")
    end
    scene:press()
    check(instance.valueMode and instance.fired==0, "ENTER immediately after build or at the first-row guard selects without stepping")
    ticks=ticks+1; Drive.sample(view)
    nodes={}; Screen.buildFullscreen(nodes, view)
    scene=nativeScene(nodes, view, counts)
    scene:rotate(direction)
    check(instance.fired==1 and instance.written*direction>0, "first value detent in either direction steps exactly once")
    check(counts.sensors==2, "first-input handling creates only the two mode scenes")
    instance:cleanup(false)
  end
end

-- Keep this whole-widget regression distinct from the sensor-only positive controls above.
-- Native root focus supplies ENTER, but no sensor scroll or signed encoder callback.
for _, preference in ipairs({false, true}) do
  rfsuite.preferences.audio_events.adjustment_events = preference
  local instance = drive()
  instance.group, instance.entry = 1, 1
  local view = {_inflight = instance, state = {armed = true}, zone = {w = 800, h = 480}}
  Drive.sample(view)
  local nodes, counts = {}, {scenes = 0, sensors = 0}
  Screen.buildFullscreen(nodes, view)
  local scene = nativeScene(nodes, view, counts)
  local soundCount, numberCount = #sounds, #numbers
  scene:rotate(-1)
  check(#sounds == soundCount + 1 and sounds[#sounds] == "/SOUNDS/rf/beep.wav" and #numbers == numberCount,
    "first browse boundary gives only the end tone with either speech preference")
  Input.key(view, EVT_VIRTUAL_PREV_PAGE)
  check(#sounds == soundCount + 2 and sounds[#sounds] == "/SOUNDS/rf/beep.wav", "PAGE group boundary always gives the end tone")
  instance.valueMode, instance.entry = true, #instance.groups[instance.group].entries
  Input.key(view, EVT_VIRTUAL_NEXT_PAGE)
  check(#sounds == soundCount + 3 and sounds[#sounds] == "/SOUNDS/rf/beep.wav" and #numbers == numberCount,
    "PAGE function boundary always gives only the end tone")
  instance:cleanup(false)
end
rfsuite.preferences.audio_events.adjustment_events = true
audioAllowed = false
local soundCount = #sounds
Announcer.endFeedback()
check(#sounds == soundCount, "end feedback retains the critical-alarm guard")
audioAllowed = true

print(checked .. " sensor, audio, safety and geometry checks passed before whole-widget reversals")
-- Known EdgeTX limit (docs/dashboard/inflight-tuning.md): in full screen the widget itself is a
-- focus-group member, so a detent that moves focus onto it reaches no Lua callback, and the detent
-- back off it scrolls nothing when its target is already in view. Expect only detents to or from the
-- widget to be lost, every other one to step once, and none to step twice.
local missedDetents, rootDetents = 0, 0
for _, case in ipairs({
  {name = "forward", directions = {1, 1, -1, -1, 1}},
  {name = "reverse", directions = {-1, 1, 1}},
  {name = "rebuild", directions = {-1, 1, 1}, rebuild = true}
}) do
  local instance = drive()
  instance.valueMode = true
  local view = {_inflight = instance, state = {armed = true}, zone = {w = 800, h = 480}}
  Drive.sample(view)
  local nodes, counts = {}, {scenes = 0, sensors = 0, nativeRoot = true}
  Screen.buildFullscreen(nodes, view)
  local scene = nativeScene(nodes, view, counts)
  if case.rebuild then
    for i, object in ipairs(scene.focus) do
      if object.parent == scene.reverse and object.node.y == 4 * scene.sensor.node.h then scene:focusAt(i); break end
    end
    check(view._inflightSensor.rebuildRequested, "whole-widget fixture reaches a ladder rebuild")
    Drive.sample(view)
    nodes = {}
    Screen.buildFullscreen(nodes, view)
    scene = nativeScene(nodes, view, counts)
    check(scene.at == 0, "after the rebuild the native focus is back on the widget")
  end
  for _, direction in ipairs(case.directions) do
    local fired, from = instance.fired, scene.at
    scene:rotate(direction); scene:sweep()
    local stepped = instance.fired == fired + 1 and instance.written * direction > 0
    check(instance.fired <= fired + 1, "a whole-widget detent never steps twice")
    if scene.at == 0 then
      rootDetents = rootDetents + 1
      check(instance.fired == fired, "a detent onto the native root reaches no step")
    elseif from ~= 0 then
      check(stepped, "a detent between sensor buttons steps exactly once")
    end
    if not stepped then
      missedDetents = missedDetents + 1
      check(scene.at == 0 or from == 0, "only a detent to or from the native root is lost")
    end
    print("whole-widget " .. case.name .. " direction=" .. direction .. " focus=" .. scene.at
      .. " pulses=" .. (instance.fired - fired))
    ticks = ticks + 31; instance:fastTick(ticks)
    ticks = ticks + 16; instance:fastTick(ticks)
  end
  instance:cleanup(false)
end
check(rootDetents > 0 and missedDetents >= rootDetents,
  "the whole-widget fixture reaches the native root and loses its detent there")


-- The endless ladder: one direction for far longer than a half has rows. With the rebuild honoured
-- the encoder never reaches a touch control and every detent steps at most once; without it (the
-- control) the walk leaves the ladder, which is the defect the rebuild exists for.
local function sensorObject(scene)
  local object = scene.focus[scene.at]
  return object == nil or (object.parent ~= nil and object.parent.node.scrolled ~= nil)
end
for _, case in ipairs({ { name = "rebuild honoured", honour = true }, { name = "control, rebuild ignored", honour = false } }) do
  for _, direction in ipairs({ -1, 1 }) do
    local instance = drive()
    instance.valueMode = true
    local view = {_inflight = instance, state = {armed = true}, zone = {w = 480, h = 320}}
    Drive.sample(view)
    local nodes, counts = {}, {scenes = 0, sensors = 0, nativeRoot = true}
    Screen.buildFullscreen(nodes, view)
    local scene = nativeScene(nodes, view, counts)
    local key = Screen.renderKey(view.state.inflight)
    local left, steps, functions = false, 0, 0
    for _ = 1, 100 do
      local fired, entry, group = instance.fired, instance.entry, instance.group
      scene:rotate(direction)
      Drive.sample(view)
      local nextKey = Screen.renderKey(view.state.inflight)
      if case.honour and nextKey ~= key then
        key = nextKey
        nodes = {}
        Screen.buildFullscreen(nodes, view)
        scene = nativeScene(nodes, view, counts)
      end
      check(instance.fired <= fired + 1, "a ring detent never steps twice")
      steps = steps + (instance.fired - fired)
      if instance.entry ~= entry or instance.group ~= group then functions = functions + 1 end
      if not sensorObject(scene) then left = true end
      ticks = ticks + 31; instance:fastTick(ticks)
      ticks = ticks + 16; instance:fastTick(ticks)
    end
    if case.honour then
      check(not left and functions == 0, "the encoder never leaves the ladder (" .. direction .. ")")
      check(counts.sensors >= 4 and counts.sensors <= 6, "a rebuild about every 28 detents (" .. counts.sensors .. " builds)")
      check(steps >= 100 - counts.sensors, "at most one detent per rebuild is lost (" .. steps .. " steps)")
    else
      check(left, "control: without the rebuild the encoder walks out of the ladder (" .. direction .. ")")
    end
    print("ring " .. case.name .. " direction=" .. direction .. " builds=" .. counts.sensors .. " steps=" .. steps
      .. " left=" .. tostring(left))
    instance:cleanup(false)
  end
end
-- The ground parameter picker: everything the board carries, six rows a page; Apply filters this
-- session only, Save also stores the model's list, Cancel changes nothing.
do
  local pd = drive()
  pd.live, pd.phase = false, "ground"
  local view = { _inflight = pd, state = { inflight = { phase = "ground" } }, zone = { w = 480, h = 320 } }
  local function scene()
    local nodes = {}
    Screen.buildFullscreen(nodes, view)
    local rows, buttons = {}, {}
    walk(nodes, function(node)
      if node.type == "button" and type(node.text) == "string" and string.find(node.text, "^%[") then rows[#rows + 1] = node end
      if node.type == "button" then buttons[#buttons + 1] = node end
    end)
    local labels = {}
    walk(nodes, function(node) if node.type == "label" and type(node.text) == "string" then labels[node.text] = node end end)
    return nodes, rows, buttons, labels
  end
  local total = 0
  for _, group in ipairs(pd.allGroups) do total = total + #group.entries end
  pd.sessionPickerOpen = true
  local _, rows, buttons, labels = scene()
  check(#rows == math.min(6, #pd.allGroups[1].entries) and string.find(rows[1].text, "[x]", 1, true),
    "the picker shows the first group's rows, all chosen")
  rows[1].press()
  _, rows = scene()
  check(string.find(rows[1].text, "[  ]", 1, true) and pd.sessionPick.wanted[pd.allGroups[1].entries[1].id] == nil,
    "a tap un-chooses a parameter")
  local function pressLabel(text)
    -- appendAction puts the button right before its label in the tree.
    local nodes = scene()
    for i, node in ipairs(nodes) do
      if node.type == "label" and node.text == text and nodes[i - 1] and nodes[i - 1].type == "button" then return nodes[i - 1].press() end
    end
    error("no action labelled " .. text)
  end
  pressLabel("Cancel")
  check(pd.sessionPickerOpen == nil and pd.sessionList == nil, "Cancel closes and keeps the offered list")
  pd.sessionPickerOpen = true
  _, rows = scene()
  rows[1].press()
  pressLabel("Apply")
  check(#pd.groups == 0, "while the filter is pending nothing is offered")
  pd:finishGroups()
  local offered = 0
  for _, group in ipairs(pd.groups) do offered = offered + #group.entries end
  check(pd.sessionList ~= nil and pd.sessionList ~= "" and offered == total - 1 and pd.sessionPickerOpen == nil,
    "Apply keeps the choice for the session: one parameter fewer is offered")
  pd.sessionPickerOpen = true
  scene()
  pressLabel("Save default")
  check(type(pd.pendingSave) == "table" and pd.pendingSave.list == pd.sessionList and pd.sessionPickerOpen == nil,
    "Save default queues the session's choice as the model's list for the next pass")
  pd:setSessionList(nil)
  pd:finishGroups()
  offered = 0
  for _, group in ipairs(pd.groups) do offered = offered + #group.entries end
  check(offered == total, "control: without a session choice everything the board carries is offered")
end

-- While the groups are rebuilt nothing is offered, so no press or trim can address a cell of the
-- previous derivation.
do
  local fd = drive()
  local row = fd.row
  fd:rebuildGroups()
  check(fd.groupWork ~= nil and next(fd.groupCells) == nil and #fd.groups == 0, "a pending rebuild offers no cell")
  local fired = fd.fired
  check(not fd:dispatch("step", 1, "trim", row) and fd.fired == fired, "a step during a pending rebuild is refused")
  fd:finishGroups()
  check(#fd.groups > 0, "control: the finished rebuild offers the cells again")
  -- A session choice applied while a fresh derivation runs keeps that derivation.
  fd:rebuildGroups()
  local work = fd.groupWork
  fd:setSessionList("14")
  check(fd.groupWork == work and work.result == nil, "a re-filter keeps the derivation in progress")
  fd:finishGroups()
  check(#fd.groups == 1 and fd.groups[1].entries[1].id == 14 and #fd.groups[1].entries == 1,
    "the derivation finishes with the session choice applied")
  fd:cleanup(false)
end

-- Value mode: plus and minus stacked on the right, plus on top, in two different colours.
for _, size in ipairs({ { 480, 272 }, { 480, 320 }, { 800, 480 } }) do
  local vd = drive()
  vd.valueMode = true
  local view = { _inflight = vd, state = { armed = true }, zone = { w = size[1], h = size[2] } }
  Drive.sample(view)
  local nodes, steps = {}, {}
  Screen.buildFullscreen(nodes, view)
  walk(nodes, function(node)
    if node.type == "momentaryButton" or (node.type == "button" and node.children and node.children[1]
        and (node.children[1].text == "+" or node.children[1].text == "-")) then
      steps[node.children[1].text] = node
    end
  end)
  local plus, minus = steps["+"], steps["-"]
  check(plus and minus and plus.x == minus.x and plus.x + plus.w <= size[1] and plus.x > size[1] / 2,
    "step targets share the right-hand column at " .. size[1] .. "x" .. size[2])
  check(plus.y + plus.h <= minus.y and plus.color ~= minus.color and plus.w >= size[1] * 0.35,
    "plus above minus, large, in a different colour")
  check(minus.y + minus.h <= size[2], "the step column fits the height")
  local fired = vd.fired
  plus.press()
  check(vd.fired == fired + 1 and vd.written > 0, "the upper target steps up")
  vd:cleanup(false)
end

-- Browse mode past both list ends: end feedback, the selection stays in the group, and the
-- encoder never walks into the arrows or the title.
for _, direction in ipairs({ 1, -1 }) do
  local instance = drive()
  local view = {_inflight = instance, state = {armed = true}, zone = {w = 480, h = 320}}
  Drive.sample(view)
  local nodes, counts = {}, {scenes = 0, sensors = 0, nativeRoot = true}
  Screen.buildFullscreen(nodes, view)
  local scene = nativeScene(nodes, view, counts)
  local key = Screen.renderKey(view.state.inflight)
  local group, left = instance.group, false
  for _ = 1, 20 do
    scene:rotate(direction)
    Drive.sample(view)
    local nextKey = Screen.renderKey(view.state.inflight)
    if nextKey ~= key then
      key = nextKey
      nodes = {}
      Screen.buildFullscreen(nodes, view)
      scene = nativeScene(nodes, view, counts)
    end
    if not sensorObject(scene) then left = true end
    ticks = ticks + 1
  end
  local last = direction > 0 and #instance.groups[group].entries or 1
  check(not left and instance.group == group and instance.entry == last and instance.valueMode == false,
    "browse past the list end stays on the last entry and never leaves the list (" .. direction .. ")")
end

-- Always-active adjustment slots share the value channel in every bank.
do
  for _, enable in ipairs({255, Functions.AUX_FIELD_COUNT}) do
    local instance = drive(function(records)
      records[42] = {adjFunction = 5, enaChannel = enable,
        adjChannel = Functions.wireToAuxField(12), adjStep = 1,
        adjRange1 = {start = 0, ["end"] = 0}, adjRange2 = records[5].adjRange2}
    end)
    for bank, rows in pairs(instance.rowValues) do
      for row = 1, Functions.ROW_COUNT do
        check((rows[row].up ~= nil) == (row ~= 3), "always-active window refuses only row three up in every bank")
      end
    end
    instance.bank, instance.row = 1, 3
    check(not instance:dispatch("step", 1, "touch", 3), "always-active row three refuses an up pulse")
    local derived, skipped = BoardPrime.deriveSet({[1] = {adjFunction = 5, enaChannel = enable,
      adjChannel = Functions.wireToAuxField(12), adjStep = 1}}, nil, 11, 12)
    check(derived == nil and skipped[1] == 1, "always-active slot is skipped rather than named as a bank")
    check(Functions.auxToWireChannel(enable) == nil, "out-of-range AUX field never names a channel")
  end
  local control = drive()
  control.bank, control.row = 1, 3
  check(control.rowValues[1][3].up ~= nil and control:dispatch("step", 1, "touch", 3),
    "control: row three steps without the always-active slot")
  control:cleanup(false)
end

-- Full slot tables with always-active windows retain a bounded derivation slice.
do
  local peak = 0
  for _, crowded in ipairs({false, true}) do
    local records = {}
    for _, slot in ipairs(Functions.standardSlots(5, 6, {step=5, step_headspeed=50})) do records[slot.slot0 + 1] = slot.record end
    local own = records[3]
    if crowded then records = {[3]=own, [4]=records[4], [5]=records[5], [6]=records[6], [7]=records[7], [8]=records[8]} end
    for slot = 1, 42 do
      if not records[slot] then records[slot] = {adjFunction=5, enaChannel=255, adjChannel=6, adjStep=1,
        adjRange1={start=1499, ["end"]=1500}, adjRange2={start=1500, ["end"]=1501}} end
    end
    local work = BoardPrime.newDerivation(records, nil, 11, 12)
    local done, result
    repeat
      local count = 0
      debug.sethook(function() count = count + 1 end, "", 1)
      done, result = BoardPrime.deriveStep(work, 8)
      debug.sethook()
      peak = math.max(peak, count)
      check(count <= 3500, "full-table always-active derivation stays below 3500 instructions per slice")
    until done
    check(result ~= nil and #work.skipped == (crowded and 36 or 6), "full table retains its usable cells and counts always-active slots")
  end
  print("always-active derivation peak: " .. peak .. " VM instructions per slice")
end

-- A widget interruption in the air must retain the flight's step count, even through landing.
do
  for _, background in ipairs({false, true}) do
    for _, stepped in ipairs({true, false}) do
      local instance = drive()
      instance.open, instance._checkedAt, instance._checkResult = true, ticks, "ok"
      if stepped then check(instance:dispatch("step", 1, "touch"), "interrupted-flight positive step") end
      if background then
        Drive.cleanup({_inflight = instance})
      else
        instance.open = false; instance:tick(true)
        check(not instance.live, "surface closes while armed")
      end
      instance.open = true; instance:tick(true)
      check(instance.live and instance.phase == "live", "interrupted flight resumes in the air")
      instance:tick(false)
      check(instance.phase == (stepped and "post" or "ground"), "landing retains only a flight that stepped")
      instance:cleanup(false)
    end
  end
  local instance = drive()
  instance:dispatch("step", 1, "touch")
  Drive.cleanup({_inflight = instance})
  instance.open = true; instance:tick(false)
  check(instance.phase == "post", "landing while backgrounded retains the post-flight list on reopening")
  instance:cleanup(false)
end

-- Ground status reads the latest published verdict without rebuilding the scene.
do
  local instance = drive()
  instance.phase, instance._checkedAt = "ground", ticks
  instance._checkResult, instance._checkFault = {"mix_missing", "gvar_range"}, true
  local view = {_inflight = instance, state = {}, zone = {w = 800, h = 480}}
  Drive.sample(view)
  local nodes = {}; Screen.buildFullscreen(nodes, view)
  local line
  for index, node in ipairs(nodes) do
    local text = type(node.text) == "function" and node.text() or node.text
    if text == "Model" then line = nodes[index + 1] end
  end
  check(line ~= nil, "two-fault scene has a model status line")
  local function text() return type(line.text) == "function" and line.text() or line.text end
  check(string.find(text(), "Mixer", 1, true) and string.find(text(), "Variable", 1, true), "both setup faults are named")
  local epoch = instance.valueEpoch
  instance:forgetVerdict(); instance._checkResult, instance._checkedAt = {"gvar_range"}, ticks
  Drive.sample(view)
  check(not string.find(text(), "Mixer", 1, true) and string.find(text(), "Variable", 1, true),
    "repairing one fault updates the standing model sentence")
  check(instance.valueEpoch == epoch, "verdict-only publication does not rebuild the scene")
  instance:forgetVerdict(); instance._checkResult, instance._checkedAt, instance._checkFault = "ok", ticks, false
  Drive.sample(view)
  check(text() == "Setup OK", "control: all repaired produces setup OK")
  instance.phase, instance.live, instance.open = nil, false, true
  instance:tick(true)
  check(instance.phase == "live", "all repaired permits the live phase")
end

-- Existing compact SD stamps are made readable only for display; a session names its start time.
do
  local instance = drive()
  instance.phase = "ground"
  local snap = {phase="ground", setupVerdict="ok", baseline={timestamp="20261025123456"}}
  local view = {_inflight=instance, state={inflight=snap}, zone={w=800,h=480}}
  local nodes = {}; Screen.buildFullscreen(nodes,view)
  local session
  for index, node in ipairs(nodes) do
    local text = type(node.text) == "function" and node.text() or node.text
    if text == "Session" then session = nodes[index + 1] end
  end
  check(session and session.text() == "Start values 12:34", "compact timestamp displays the start time in minutes")
  check(snap.baseline.timestamp == "20261025123456", "stored compact timestamp stays compatible")
  snap.baseline.timestamp = "2026-10-25 12:34:56"
  check(session.text() == "Start values 12:34", "control: existing separated timestamp displays the same minute precision")
  snap.baseline.timestamp = "clock unavailable"
  check(string.find(session.text(), "clock unavailable", 1, true), "non-date timestamp text is retained in full")
end

-- The channel reader accepts raw EdgeTX units, including the overlap with microseconds.
do
  for _, raw in ipairs({-1200, -1024, 0, 700, 998, 1024, 1200}) do
    check(Functions.channelRawToUs(raw) == math.floor(1500 + raw * 0.5 + 0.5), "raw channel conversion across its complete range")
  end
  for _, raw in ipairs({-1201, 1201, 1500, 2300, 2301, "unknown"}) do
    check(Functions.channelRawToUs(raw) == nil, "values outside the raw range are refused")
  end
end

print(checked .. " grouped tuning checks passed; positive pulse, sound and exit controls included")
