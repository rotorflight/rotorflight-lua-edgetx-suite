-- Adjustment slots that touch the tuning pair only in part, and always-on continuous slots on the
-- value channel. Drives the real derivation (inflight/prime.lua) and the real ground screen
-- (inflight/screen.lua) against what the flight controller does with such slots
-- (fc/rc_adjustments.c, processRcAdjustments):
--   * a slot whose enable is active fires whatever the overlay names, so a slot with one channel
--     on the pair and the other elsewhere refuses the whole set, and the ground screen names it;
--   * a slot whose one channel does both jobs refuses it only when its enable window overlaps a
--     step window, since it cannot step otherwise;
--   * a continuous slot fires within a margin around its first range and never reads its second.
-- Usage: lua5.3 bin/dashboard/verify_inflight_foreign_slots.lua
local Stubs = dofile("bin/accounting/stubs/edgetx.lua")
local FC = dofile("bin/accounting/stubs/fc.lua")
Stubs.install(arg[1] or ".")
FC.install(Stubs)
Stubs.reset()
FC.reset()

local failures, checks = 0, 0
local function check(value, label)
  checks = checks + 1
  if not value then
    failures = failures + 1
    print("FAIL " .. label)
  end
end

-- The overlay's modules are loaded through the real opening path, as a pilot's first visit does.
local Runtime = rfsuite.require("widgets/dashboard/runtime.lua")
local widget = Runtime.new({x = 0, y = 0, w = 480, h = 320}, {})
widget.preferences.general = {preview_inflight_tuning = true}
widget.preferences.inflight = {enabled = true}
widget.inflightFullscreen = true
for _ = 1, 20 do
  widget._job = {kind = "control", oneShot = true, step = function() return true end}
  widget:refresh(0, nil)
  if widget._inflight then break end
end
widget._job = nil
local Prime = rfsuite.require("widgets/dashboard/inflight/prime.lua")
local Functions = rfsuite.require("widgets/dashboard/inflight/functions.lua")
local Drive = rfsuite.require("widgets/dashboard/inflight/drive.lua")
local Screen = rfsuite.require("widgets/dashboard/inflight/screen.lua")

local BANK, VALUE = 11, 12
local BANK_FIELD, VALUE_FIELD = Functions.wireToAuxField(BANK), Functions.wireToAuxField(VALUE)
local FOREIGN_FIELD, OTHER_FIELD = 3, 4 -- channels 9 and 10 (identity fields past the receiver map)
local SLOT = 40 -- outside the suggested set's slots 3 to 38

-- The suggested set on channels 11 and 12, as the board carries it after setup.
local function board(extra)
  local records = {}
  for _, slot in ipairs(Functions.standardSlots(BANK_FIELD, VALUE_FIELD, {step = 5, step_headspeed = 50})) do
    records[slot.slot0 + 1] = slot.record
  end
  records[SLOT] = extra
  return records
end
local function slot(fields)
  local record = {adjFunction = 5, enaChannel = FOREIGN_FIELD, enaRange = {start = 1300, ["end"] = 1700},
    adjChannel = VALUE_FIELD, adjRange1 = {start = 1000, ["end"] = 1100}, adjRange2 = {start = 1900, ["end"] = 2000},
    adjMin = 0, adjMax = 200, adjStep = 1}
  for key, value in pairs(fields or {}) do record[key] = value end
  return record
end

local control, controlSkipped, controlConflict = Prime.deriveSet(board(nil), nil, BANK, VALUE)
check(control ~= nil and control.placed > 0 and #controlSkipped == 0 and controlConflict == nil,
  "control: the suggested set derives with no slot skipped and none refusing it")
local upGv = control and control.rowValues[1][1].up
local upUs = upGv and Functions.gvarToUs(upGv)
check(upUs ~= nil, "control: bank 1 row 1 has an increment value")
upUs = upUs or 1900

-- 1. A slot on the value channel enabled by a third channel: the set is refused and the slot named.
do
  local derived, skipped, conflict = Prime.deriveSet(board(slot({})), nil, BANK, VALUE)
  check(derived == nil and conflict == SLOT and #skipped == 0,
    "value-channel slot with a foreign enable refuses the set and names slot " .. SLOT
      .. " (derived=" .. tostring(derived ~= nil) .. ", conflict=" .. tostring(conflict) .. ")")
  local inert = Prime.deriveSet(board(slot({adjFunction = 0})), nil, BANK, VALUE)
  check(inert ~= nil, "a slot with function 0 refuses nothing (the firmware's NONE entry sets nothing)")
  local never = Prime.deriveSet(board(slot({enaRange = {start = 1500, ["end"] = 1500}})), nil, BANK, VALUE)
  check(never ~= nil, "a foreign enable window the firmware never reads refuses nothing")
end

-- 1b. One channel doing both jobs: the firmware looks at the step windows only while the enable
-- window holds that same channel, so the slot steps only where the two overlap. Windows are half
-- open (fc/rc_modes.h, isRangeActive).
do
  local function refuses(fields)
    return select(3, Prime.deriveSet(board(slot(fields)), nil, BANK, VALUE)) == SLOT
  end
  local function ignored(fields)
    local derived, skipped, conflict = Prime.deriveSet(board(slot(fields)), nil, BANK, VALUE)
    return derived ~= nil and conflict == nil and #skipped == 0
  end
  -- The default windows: enable 1300..1700, steps 1000..1100 and 1900..2000.
  check(ignored({enaChannel = VALUE_FIELD}),
    "a slot on the value channel alone whose enable window holds none of its step windows never steps and refuses nothing")
  check(refuses({enaChannel = VALUE_FIELD, adjRange1 = {start = 1600, ["end"] = 1700}}),
    "a slot on the value channel alone whose enable window overlaps a step window refuses the set")
  check(ignored({enaChannel = VALUE_FIELD, adjRange2 = {start = 1700, ["end"] = 1800}}),
    "a step window that starts where the enable window ends never shares a value with it and refuses nothing")
  check(refuses({enaChannel = VALUE_FIELD, adjRange2 = {start = 1695, ["end"] = 1800}}),
    "control: a step window that starts 5 us inside the enable window refuses the set")
  check(ignored({enaChannel = BANK_FIELD, adjChannel = BANK_FIELD}),
    "a slot on the bank channel alone whose enable window holds none of its step windows refuses nothing")
  check(refuses({enaChannel = BANK_FIELD, adjChannel = BANK_FIELD, adjRange2 = {start = 1500, ["end"] = 2000}}),
    "a slot on the bank channel alone whose enable window overlaps a step window refuses the set")
  check(ignored({enaChannel = VALUE_FIELD, adjRange1 = {start = 1500, ["end"] = 1500},
    adjRange2 = {start = 1500, ["end"] = 1500}}),
    "a stepped slot on one channel whose step windows the firmware never reads refuses nothing")
  -- A continuous slot steps within its first range widened by MAX(5, rangeWidth / (valueWidth * 2)).
  local function continuous(adjMin, adjMax, start)
    return {enaChannel = VALUE_FIELD, adjStep = 0, adjRange1 = {start = start, ["end"] = start + 200},
      adjMin = adjMin, adjMax = adjMax}
  end
  check(refuses(continuous(0, 5, 1715)),
    "a continuous slot on one channel whose margin (20 us) reaches into its enable window refuses the set")
  check(ignored(continuous(0, 6, 1715)),
    "a continuous slot on one channel whose margin (16 us) ends exactly at its enable window refuses nothing"
      .. " (the firmware's lower bound is exclusive, so 1699 is not inside it)")
  check(ignored(continuous(0, 1000, 1715)),
    "control: the same continuous slot with a margin of 5 us stays clear of its enable window and refuses nothing")
  check(ignored(continuous(7, 7, 1400)),
    "a continuous slot on one channel with no value width never sets anything and refuses nothing")
end

-- 2. The mirror: enabled in a bank, value on another channel.
do
  local derived, skipped, conflict = Prime.deriveSet(board(slot({enaChannel = BANK_FIELD, adjChannel = FOREIGN_FIELD})),
    nil, BANK, VALUE)
  check(derived == nil and conflict == SLOT and #skipped == 0,
    "bank-channel slot with a foreign value channel refuses the set and names slot " .. SLOT
      .. " (derived=" .. tostring(derived ~= nil) .. ", conflict=" .. tostring(conflict) .. ")")
  local swapped = select(3, Prime.deriveSet(board(slot({enaChannel = VALUE_FIELD, adjChannel = BANK_FIELD})),
    nil, BANK, VALUE))
  check(swapped == SLOT, "a slot with the two roles swapped refuses the set")
  local always = select(3, Prime.deriveSet(board(slot({enaChannel = 255, adjChannel = BANK_FIELD})), nil, BANK, VALUE))
  check(always == SLOT, "an always-on slot reading the bank channel refuses the set")
  local valueEnabled = select(3, Prime.deriveSet(board(slot({enaChannel = VALUE_FIELD, adjChannel = OTHER_FIELD})),
    nil, BANK, VALUE))
  check(valueEnabled == SLOT, "a slot enabled by the value channel that reads another channel refuses the set")
  local bankRead = select(3, Prime.deriveSet(board(slot({adjChannel = BANK_FIELD})), nil, BANK, VALUE))
  check(bankRead == SLOT, "a slot enabled by another channel that reads the bank channel refuses the set")
  local both, _, none = Prime.deriveSet(board(slot({adjChannel = OTHER_FIELD})), nil, BANK, VALUE)
  check(both ~= nil and none == nil, "a slot with both channels elsewhere refuses nothing")
end

-- 3. A continuous always-on slot on the value channel fires within the firmware's margin around
-- its first range: MAX(5, rangeWidth / (valueWidth * 2)).
do
  local start = 5 * math.ceil(upUs / 5) + 10 -- the increment value lies 10 to 15 us below it
  local function continuous(adjMin, adjMax, range2)
    return slot({enaChannel = 255, adjStep = 0, adjRange1 = {start = start, ["end"] = start + 200},
      adjRange2 = range2 or {start = 1500, ["end"] = 1500}, adjMin = adjMin, adjMax = adjMax})
  end
  local wide = Prime.deriveSet(board(continuous(0, 5)), nil, BANK, VALUE) -- margin 200 / 10 = 20
  check(wide ~= nil and wide.rowValues[1][1].up == nil,
    "an increment value inside a continuous slot's margin but outside its range is refused")
  local narrow = Prime.deriveSet(board(continuous(0, 1000)), nil, BANK, VALUE) -- margin 5
  check(narrow ~= nil and narrow.rowValues[1][1].up ~= nil,
    "control: the same value outside a continuous slot's margin stays available")
  local second = 5 * math.floor(upUs / 5)
  local far = slot({enaChannel = 255, adjStep = 0, adjRange1 = {start = 900, ["end"] = 950},
    adjRange2 = {start = second, ["end"] = second + 5}, adjMin = 0, adjMax = 1000})
  local unread = Prime.deriveSet(board(far), nil, BANK, VALUE)
  check(unread ~= nil and unread.rowValues[1][1].up ~= nil,
    "a continuous slot's second range is never read, so it refuses nothing")
  local flat = Prime.deriveSet(board(continuous(7, 7)), nil, BANK, VALUE)
  check(flat ~= nil and flat.rowValues[1][1].up ~= nil, "a continuous slot with no value width never fires")
  -- The stated case: a STEPPED always-on slot keeps refusing the rows its windows hold.
  local stepped = slot({enaChannel = 255, adjStep = 1, adjRange1 = {start = 1500, ["end"] = 1500},
    adjRange2 = {start = second, ["end"] = second + 5}})
  local held, skipped = Prime.deriveSet(board(stepped), nil, BANK, VALUE)
  check(held ~= nil and held.rowValues[1][1].up == nil and skipped[1] == SLOT,
    "a stepped always-on slot on the value channel still refuses its row and is counted as skipped")
end

-- 4. Through the real read: the refusal reaches the drive and the ground screen names the slot.
local function texts(nodes)
  local out = {}
  for _, node in ipairs(nodes) do
    local text = node.text
    if type(text) == "function" then text = text() end
    if type(text) == "string" then out[#out + 1] = text end
  end
  return out
end
local function holds(list, wanted)
  for _, text in ipairs(list) do
    if string.find(text, wanted, 1, true) then return true end
  end
  return false
end
do
  local radio = {
    now = getTime, flightMode = function() return 0 end,
    sensor = function(name) if name == "AdjF" then return 0 elseif name == "PID#" or name == "RTE#" then return 1 end end,
    switchValue = function() return false end, channelUs = function() return nil end,
    globalVariableDetails = function() end, mixesCount = function() end, flightModeData = function() end,
    setGlobalVariable = function() return true end
  }
  local function read(extra)
    local d = Drive.newDrive(radio, Drive.settings(widget.preferences, {}))
    d._checkedAt, d._checkResult = getTime(), "ok"
    d.open, d.live, d.phase = true, false, "ground"
    widget._inflight = d
    widget.state.armed, widget.state.armedSeen, widget.state.fblConnected = false, true, true
    d.prime = {phase = Prime.PHASE_DERIVE, skipped = {},
      derivation = Prime.newDerivation(board(extra), nil, d.settings.bank_ch, d.settings.value_ch)}
    for _ = 1, 40 do
      widget._job = nil
      Prime.tick(widget, d)
      if d.prime.setApplied then break end
    end
    Drive.sample(widget)
    local nodes = {}
    Screen.buildFullscreen(nodes, widget)
    return d, texts(nodes)
  end
  local d, shown = read(slot({}))
  check(d.settings.bank_ch == BANK and d.settings.value_ch == VALUE, "fixture: the default tuning pair is channels 11 and 12")
  check(d.setSource == "conflict" and widget.state.inflight and widget.state.inflight.conflictSlot == SLOT,
    "the read publishes the refused set with slot " .. SLOT .. " (setSource=" .. tostring(d.setSource) .. ")")
  d:rebuildGroups(true)
  check(#d.groups == 0, "a refused set offers nothing to step")
  check(holds(shown, "Slot " .. SLOT .. " blocks tuning"), "the ground screen names slot " .. SLOT)
  local cd, controlShown = read(nil)
  cd:rebuildGroups(true)
  check(#cd.groups > 0, "control: the suggested set offers groups to step")
  check(cd.setSource == "board" and not holds(controlShown, "blocks tuning"),
    "control: the suggested set reads as a board set and names no slot")
  check(holds(controlShown, "parameters on the board"), "control: the ground screen shows the board's parameter count")
end

-- 5. Once the read is done, the empty-board sentence names the slot too, in full, in English and
-- German, at every supported size.
do
  local de = dofile("src/rfsuite/i18n/de.lua")
  local function german(key, fallback)
    local node = de
    for part in string.gmatch(key, "[^%.]+") do node = type(node) == "table" and node[part] or nil end
    return type(node) == "string" and node or fallback
  end
  -- The read above has ended: nothing is running on the drive the screen is built for.
  widget._inflight.prime = nil
  for _, lang in ipairs({"en", "de"}) do
    local wanted = string.format(lang == "de" and german("widgets.dashboard.inflight_fc_slot_conflict", "?")
      or "Slot %d conflicts with the tuning channels. Change it in the Configurator.", SLOT)
    for _, size in ipairs({{480, 272}, {480, 320}, {800, 480}}) do
      widget.zone = {w = size[1], h = size[2]}
      widget.i18n = {t = function(key, fallback) if lang == "de" then return german(key, fallback) end return fallback end}
      widget.state.inflight = {phase = "ground", setupVerdict = "ok", setSource = "conflict", conflictSlot = SLOT,
        prime = {phase = "done", skipped = 0}}
      local nodes = {}
      Screen.buildFullscreen(nodes, widget)
      local shown, joined = texts(nodes), nil
      for i = 1, #shown - 1 do
        if string.find(wanted, shown[i], 1, true) == 1 and shown[i] ~= "" then
          joined = shown[i] .. (shown[i + 1] ~= "" and (" " .. shown[i + 1]) or "")
          break
        end
      end
      check(joined == wanted, lang .. " " .. size[1] .. "x" .. size[2] .. ": the refused set's sentence is shown whole ("
        .. tostring(joined) .. ")")
      local emptyText = lang == "de" and german("widgets.dashboard.inflight_fc_no_functions", "?")
        or "The FC has no adjustment functions for in-flight tuning."
      local calledEmpty = false
      for _, text in ipairs(shown) do
        if text ~= "" and string.find(emptyText, text, 1, true) == 1 then calledEmpty = true end
      end
      check(not calledEmpty, lang .. " " .. size[1] .. "x" .. size[2] .. ": a refused set is not called an empty board")
    end
  end
  widget.i18n = nil
end

Stubs.releaseCard()
print(checks .. " foreign-slot checks, " .. failures .. " failed")
if failures > 0 then os.exit(1) end
