-- The in-flight tuning drive: what the overlay does to the radio, and when it is allowed to.
--
-- The flight controller's stepped adjustments are reached through two global variables that a
-- mixer line each puts on the enable and the value channel. This module owns those two writes and
-- nothing else. It never speaks MSP -- tasks/msp/runtime.lua clears its own queue on every armed
-- tick, so a write attempted in flight would be dropped without a word -- and it never writes the
-- model: mixer lines, global variable details and trim modes are CHECKED here and reported, never
-- authored.
--
-- Everything that touches the radio goes through the small table `M.radio()` returns, so the
-- state machine can be driven under a plain Lua interpreter with those functions replaced.
--
-- The safety rule the whole file is built around: the value variable is 0 whenever no pulse is
-- running and nothing is held, including after EVERY way out of the overlay. `cleanup` is cheap
-- and idempotent for exactly that reason -- it is run on every transition away rather than on the
-- one transition that happened to be observed.

local M = {}

local function t(_key, fallback)
  return fallback
end

local requireModule = (_G.rfsuite and _G.rfsuite.require)
if not requireModule then
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local rChunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/require.lua", mode)
  if rChunk then
    local ok, res = pcall(rChunk)
    if ok and type(res) == "function" then
      requireModule = res
    end
  end
end
requireModule = requireModule or function(path)
  local fullPath = string.sub(path, 1, 1) == "/" and path or ("/SCRIPTS/TOOLS/rfsuite-core/" .. path)
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(fullPath, mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local Setup = requireModule("widgets/dashboard/inflight/setup.lua")
local Functions = requireModule("widgets/dashboard/inflight/functions.lua")

-- A dependency that did not load must not leave a WORKING-LOOKING module behind.
--
-- lib/require.lua caches whatever a chunk RETURNS. Its own load of a dependency goes through
-- pcall, and a pcall catches the firmware's instruction-limit error like any other -- so a widget
-- pass that runs out of budget while one of the files above is being read leaves the require
-- answering nil, this chunk running on to its end with a nil upvalue, and the broken table cached
-- for the rest of the session. Every call into it then raises
--   ?:0: attempt to index a nil value (upvalue '?')
-- on every pass, for ever, and the widget's refresh is abandoned each time. That is what the
-- pilot's card log recorded 913 times after a start with no flight controller: the overlay's
-- modules were first loaded on the pass the connect chain and the theme reload were already
-- filling, and the load that lost the race was cached.
--
-- Raising here instead means the pcall in lib/require.lua fails, NOTHING is cached, and the next
-- pass loads the file again on a budget that may well be quieter. A missing file behaves the same
-- way and is answered by the caller, which keeps its own retry.
if type(Setup) ~= "table" or type(Functions) ~= "table" then
  error("inflight/drive.lua: a dependency did not load", 0)
end

-- Everything about what the model must LOOK like -- the store, the radio seam, the trim block,
-- the setup check -- lives in setup.lua, so that the settings page can have it without this
-- file. Re-exported here because the widget side, the screens and the probes reach for it
-- through this module and there is no reason to make them all learn a second name.
M.DEFAULTS = Setup.DEFAULTS
M.PULSE_MS = Setup.PULSE_MS
M.CHANNEL_MIN = Setup.CHANNEL_MIN
M.CHANNEL_MAX = Setup.CHANNEL_MAX
M.GVAR_MAX_INDEX = Setup.GVAR_MAX_INDEX
M.TRIM_COUNT = Setup.TRIM_COUNT
M.PROFILE_MAX = Setup.PROFILE_MAX
M.TRIM_MODE_ROWS = Setup.TRIM_MODE_ROWS
M.TRIM_MODE_NAVIGATE = Setup.TRIM_MODE_NAVIGATE
M.STEP_CHOICES = Setup.STEP_CHOICES
M.nearestStep = Setup.nearestStep
M.radio = Setup.radio
M.RADIO_KEYS = Setup.RADIO_KEYS
M.MODEL_KEYS = Setup.MODEL_KEYS
M.loadRadioSettings = Setup.loadRadioSettings
M.loadModelSettings = Setup.loadModelSettings
M.settings = Setup.settings
M.storeRadioSettings = Setup.storeRadioSettings
M.storeModelSettings = Setup.storeModelSettings
M.resolveTrims = Setup.resolveTrims
M.trimsFromList = Setup.trimsFromList
M.trimEntry = Setup.trimEntry
M.normaliseTrim = Setup.normaliseTrim
M.migrateTrims = Setup.migrateTrims
M.check = Setup.check

local logDrive = Setup.log
local boardIdentity
local SWITCH_SLICE = Setup.SWITCH_SLICE
local SWITCH_WALK_LIMIT = Setup.SWITCH_WALK_LIMIT

-- The walk is EDGE triggered: one press, one parameter. A trim held on purpose then repeats, after
-- a delay long enough that a single press can never produce two steps, at a rate a pilot can still
-- count while looking somewhere else.
local NAV_REPEAT_DELAY_TICKS = 50
local NAV_REPEAT_INTERVAL_TICKS = 33

-- ---------------------------------------------------------------------------
-- The drive
-- ---------------------------------------------------------------------------

local Drive = {}
Drive.__index = Drive

--- Which parameters the screen offers before anything has been read off the board: none.
--
-- What can be tuned is what the board carries, so the set comes from the ground read of its slot
-- table (prime.lua `applySet`) and nothing is offered until that read has completed. A set this
-- build assumed would name cells the board may hold differently, and a press on such a cell
-- steps whatever the board's slot holds.
--
-- Called again whenever the settings change, because the channels a cell is derived from are
-- settings.
function Drive:seedSet()
  self.bands = Functions.REFERENCE_BANDS
  self.bankValues = Functions.REFERENCE_BAND_GV
  self.rowValues = {}
  self.cellRecords = {}
  self.set = {}
  self.setSource = "unread"
  self.compare = nil
  self:rebuildGroups()
end

--- Whether a step on this cell would land as one step: the firmware constrains every stepped
-- result into the slot's adjMin..adjMax (fc/rc_adjustments.c), so a value standing outside them
-- jumps to the bound on the first press. Unknown value or unknown record: no verdict, no refusal.
function Drive:cellOutOfBounds(bank, row)
  local records = self.cellRecords and self.cellRecords[bank]
  local record = records and records[row]
  local id = self:functionId(bank, row)
  local value = id and self.values and self.values[id]
  if record == nil or value == nil then return false end
  local low, high = tonumber(record.adjMin), tonumber(record.adjMax)
  if low == nil or high == nil then return false end
  return value < low or value > high
end

-- Derive the flight list at layout changes only. The cell index is also the trim route's gate:
-- a hidden selector or an excluded parameter must not remain adjustable through another input.
--
-- A bank per pass (Functions.groupStep, stepped from M.tick): the whole table on the pass that
-- applies a freshly read board takes that pass past what a widget call may cost. `now` finishes it
-- at once, for a caller that needs the groups on the same call; an empty set always finishes at once.
function Drive:rebuildGroups(now)
  -- Built unfiltered, so the session picker can offer everything the board carries; the flight
  -- list is applied afterwards (Functions.filterGroups).
  self.groupWork = Functions.newGroupWork(self.set, self.rowValues, self.bankValues, nil)
  self:fenceGroups()
  if now or type(self.set) ~= "table" or next(self.set) == nil then self:finishGroups() end
end

--- While groups are being built nothing is offered: the set, its codes and its records may
-- already be the new board's while the old groups would still name the old one's cells, and a
-- press or a trim on such a cell steps whatever the new slot holds.
function Drive:fenceGroups()
  self.groups, self.groupCells = {}, {}
  self.valueMode = false
  self.groupPicker = nil
end

--- The list that decides what is offered: the pilot's choice for this session where there is one,
-- otherwise the model's flight list. An empty string means everything.
function Drive:activeList()
  if self.sessionList ~= nil then return self.sessionList end
  return self.settings and self.settings.flight_list
end

--- The session's own choice (the ground picker's Apply). nil goes back to the model's list.
function Drive:setSessionList(stored)
  self.sessionList = stored
  self:applyFilter()
end

--- Re-filters the board's groups with the active list, through the same per-pass steps.
function Drive:applyFilter()
  local work = self.groupWork
  if work ~= nil then
    -- A derivation still running (a fresh board read) filters with the active list when it gets
    -- there; one already sorted filters again. Replacing it would bring back the old cells.
    work.filtered = nil
  else
    self.groupWork = { result = self.allGroups or {} }
  end
  self:fenceGroups()
end

--- One step of a pending group derivation; answers whether there was one. The banks, the sort, the
-- filter and the take-over each take a step: measured, the filter of a restricted list and the
-- take-over together already exceed what a ground-read pass has left.
function Drive:stepGroups()
  local work = self.groupWork
  if work == nil then return false end
  if work.result == nil then
    local done, groups = Functions.groupStep(work)
    if done then work.result = groups end
    return true
  end
  if work.filtered == nil then
    work.filtered = { Functions.filterGroups(work.result, self:activeList()) }
    return true
  end
  self.groupWork = nil
  -- A picker opened over other groups starts again from the new ones.
  if self.allGroups ~= work.result then self.sessionPick = nil end
  self.allGroups = work.result
  self:takeGroups(work.filtered[1], work.filtered[2], work.filtered[3])
  return true
end

--- The filtered groups take over, and the selection is re-seated on them.
function Drive:takeGroups(groups, cells, missing)
  self.groups, self.groupCells, self.flightListMissing = groups, cells, missing
  if self.setSource == "unread" then self.flightListMissing = {} end
  local cell = self.groupCells[self.bank] and self.groupCells[self.bank][self.row]
  if cell == nil then cell = self.groups[1] and self.groups[1].entries[1] end
  self.group, self.entry = 1, 1
  if cell ~= nil then
    self.bank, self.row, self.group, self.entry = cell.bank, cell.row, cell.group, cell.index
  end
  -- What the board offers, whatever the list keeps: that is the number the ground surface states.
  local count = 0
  for _, group in ipairs(self.allGroups or {}) do count = count + #group.entries end
  self.cellCount = count
  self:countOutOfBounds()
  self.valueMode = false
  self:forgetVerdict()
  -- The row list is part of the layout, so the finished groups move the epoch.
  self.valueEpoch = (self.valueEpoch or 0) + 1
end

--- How many offered cells would jump on their first press (Drive:cellOutOfBounds), for the
-- ground surface. Counted when the groups or the read values change, never per pass.
function Drive:countOutOfBounds()
  local count = 0
  for bank, rows in pairs(self.groupCells or {}) do
    for row in pairs(rows) do
      if self:cellOutOfBounds(bank, row) then count = count + 1 end
    end
  end
  self.boundsCount = count
  return count
end

--- Store the model flight list or suggested step defaults through the suite's preference writer.
-- Ground only; the caller refuses while armed and gives each store write its own idle pass.
function M.saveFlightList(stored, steps)
  local session = _G.rfsuite and _G.rfsuite.session
  local mcu = session and session.mcu_id
  if not mcu then return false, "missing_mcu_id" end
  local MP = requireModule("lib/model_preferences.lua")
  if type(MP) ~= "table" or type(MP.saveByMcuId) ~= "function" then return false, "store" end
  local model, inflight = {}, {}
  for key, value in pairs(session.modelPreferences or {}) do model[key] = value end
  for key, value in pairs(model.inflight or {}) do inflight[key] = value end
  if steps then
    inflight.step, inflight.step_headspeed = steps.step, steps.step_headspeed
  else inflight.flight_list = stored or "" end
  model.inflight = inflight
  local ok, err = MP.saveByMcuId(mcu, model)
  if not ok then return false, err end
  session.modelPreferences = model
  return true
end

function Drive:finishGroups()
  while self.groupWork ~= nil do self:stepGroups() end
end

--- A drive with no history: surface closed, nothing written, no bank chosen.
function M.newDrive(radio, settings)
  local self = setmetatable({}, Drive)
  self.radio = radio or M.radio()
  self.settings = settings or M.settings(nil, nil)
  self.live = false
  self.open = false
  self.bank = 1
  self.row = 1
  self:seedSet()
  self.bankShown = nil
  self.written = 0
  self.writtenFm = nil
  self.bankWritten = nil
  self.bankFm = nil
  self.pulseCode = nil
  self.pulseUntil = nil
  self.coolUntil = 0
  self.holdRow = nil
  self.holdUp = nil
  self.holdSince = nil
  self.trimRow = nil
  self.trimUp = nil
  self.trims = nil
  self.rowTrims = nil
  self.trimsResolved = false
  self.trimScan = nil
  self.navDir = 0
  self.navNextAt = nil
  self.bankDir = 0
  self.bankNextAt = nil
  self.fastAt = nil
  self.values = {}
  -- TWO counters over the same value table, because two different readers want two different
  -- things. `valueEpoch` publishes selection/control changes and keys ground/post layouts;
  -- the retained live scene keys only structural changes. `reportEpoch` says only that a number
  -- the surface reads through a closure has moved, and no render key follows it. See the AdjF
  -- block in fastTick for why the board's own answers travel on the second one.
  self.valueEpoch = 0
  self.reportEpoch = 0
  self.profile = nil
  self.rateProfile = nil
  self.knownPid, self.knownRate = nil, nil
  self.sessionProfiles = nil
  self.profileValues = nil
  self.profilePrevious = nil
  self.changes = {pid = {}, rate = {}, global = {}}
  self.profilePaused = false
  self.profileChanged = nil
  self.profileSettleAt = nil
  self.profileBannerUntil = nil
  -- Flight phase survives a closed surface; see Drive:setPhase for its transitions.
  self.phase = nil
  self.fired = 0
  self.post = false
  self.deltaPage = 1
  self.stepRefusedUntil = nil
  self.previous = {}
  self.readAt = nil
  return self
end

-- The three phases, as the snapshot spells them.
M.PHASE_GROUND = "ground"
M.PHASE_LIVE = "live"
M.PHASE_POST = "post"

-- What this Lua state and the radio have left (lib/log.lua, Log.resources), for the lines that
-- mark the overlay coming up and going down: read against each other they say what a tuning
-- visit kept. Only built where such a line is written, which is a handful of times per flight.
local function resourcesText()
  local Log = _G.rfsuite and _G.rfsuite.Log
  if type(Log) == "table" and type(Log.resources) == "function" then
    local ok, text = pcall(Log.resources)
    if ok and type(text) == "string" then return text end
  end
  return "-"
end

--- Which of the three the overlay is in, and everything that has to happen on a transition.
--
-- Arm state chooses the surface: ground before flight, tuning while armed, comparison after
-- a flight that changed values. Closing pauses this progression without ending the session.
--
-- The consequence worth stating plainly: NOTHING STEPS ON THE GROUND. The step controls and the
-- trims are live in the `live` phase and in no other, because the ground surface carries neither
-- a row list nor a step control and a step nobody can see land is a step nobody should be able to
-- ask for.
function Drive:setPhase(phase)
  if self.phase == phase then return end
  local was = self.phase
  self.phase = phase
  self.postActionsOpen = nil
  self.groupPicker = nil
  self.valueEpoch = self.valueEpoch + 1

  if phase == M.PHASE_LIVE then
    -- A ground-to-air transition starts a new count. A same-flight reopen keeps this phase
    -- and returns above without resetting its count or selection.
    self.post = false
    if was == M.PHASE_GROUND or was == M.PHASE_POST then self.fired = 0 end
    self.deltaPage = 1
    self.valueMode = false
    -- Every flight starts at the top of the list, not at whatever cell the enable channel or an
    -- earlier flight left selected.
    local first = self.groups and self.groups[1] and self.groups[1].entries[1]
    if first ~= nil then
      self.group, self.entry = 1, 1
      self.bank, self.row = first.bank, first.row
      self:ensureBankArmed()
    end
    self:speakSelection("group")
  elseif was == M.PHASE_LIVE then
    -- The continuation across a link gap is a property of the flight it was taken in.
    self.armedThrough = nil
    self.readArmed = nil
    -- Landing clears the value. The bank may remain selected only while the surface is open;
    -- every exit clears both variables before changing the phase.
    self:cleanup(false, self.live == true)
    self.deltaPage = 1
  end
  -- `post` is the phase and nothing else: it is what tick reads on the next pass to keep the
  -- postflight surface up, and endPost is what takes it down. Written here rather than inferred,
  -- because a flag set on the transition and cleared at the bottom of the same function is how
  -- the first cut of this managed to leave the phase at `ground` after every flight.
  self.post = (phase == M.PHASE_POST)
  logDrive("phase %s -> %s, %s", tostring(was), tostring(phase), resourcesText())
end

--- Leave the postflight read-out, on any of the three things that end it.
--
-- The LIST is not dropped with it. The delta is computed against the SD baseline, and
-- that snapshot stands until a new session replaces it -- so a pilot who closes tuning
-- and reopens it finds the same list, which is the answer he expects and not a fresh empty one.
function Drive:endPost(why)
  if not self.post then return end
  self.post = false
  -- Dismissed: a later pass with no phase (the widget left and came back) must not bring it back.
  self.fired = 0
  self.valueEpoch = self.valueEpoch + 1
  logDrive("postflight ended: %s", tostring(why))
end

-- How long a refused press is said on the screen, in radio ticks. Long enough to read at arm's
-- length, short enough to be gone before the next one.
local REFUSAL_TICKS = 80

--- Publish a step refusal through the snapshot; button callbacks do not consume return reasons.
-- `ticks` overrides how long it stands, for a notice that has more to say than a refused tap.
function Drive:refuseStep(reason, now, ticks)
  if reason == "range" and self.setSource == "unread" then reason = "unread" end
  if reason == "range" and self.setSource == "unavailable" then reason = "empty" end
  self.stepRefusedReason = reason
  self.stepRefusedUntil = now + (ticks or REFUSAL_TICKS)
end

-- How long a step control may be held before the drive lets go of it on its own, counted from the
-- press. The hold ends at the button's release handler, which EdgeTX raises on LV_EVENT_RELEASED
-- and on nothing else (MomentaryButton in radio/src/gui/colorlcd/libui/button.cpp); LVGL can
-- forget a pressed object without that event -- lv_indev_wait_release() turns the release into
-- LV_EVENT_PRESS_LOST, lv_indev_reset() sends it nowhere -- and EdgeTX's touch read calls both,
-- under a backlight that is off and under a "Disable Touch" special function. Neither event
-- reaches a Lua script, so a lost release cannot be seen from here, only outlived. A held control
-- steps once per pulse and gap (see fastTick), about two steps a second, so five seconds is ten
-- steps or so -- the same bound, for the same reason, as the dashboard's limit on
-- how long a held step keeps a rebuild waiting (HOLD_DEFER_SECONDS in widgets/dashboard/runtime.lua).
-- A pilot who wants more presses again.
local HOLD_LIMIT_SECONDS = 5
local HOLD_LIMIT_TICKS = HOLD_LIMIT_SECONDS * 100

-- How long the notice that the limit ended a hold stands: the finger may still be on the button,
-- and the pilot has to be able to read why the steps stopped.
local HOLD_LIMIT_NOTICE_TICKS = 300

--- The fixed pulse length M.PULSE_MS, in ticks of the radio's 10 ms clock. The logical switch on
-- the value line ends the plateau the board sees, and a variable cleared before that switch's
-- window is over cuts the window or cancels it.
function Drive:pulseTicks()
  return math.floor((M.PULSE_MS / 10) + 0.5)
end

-- The gap at 0 after every pulse, in the same ticks; see Setup.PULSE_GAP_MS.
local GAP_TICKS = math.floor(Setup.PULSE_GAP_MS / 10 + 0.5)

--- Whether a step control or a trim owns the value variable: a magnitude on it, or a step control
-- held. A held control's variable goes back to 0 between its pulses (see fastTick), and a bank or a
-- row moved in that gap would put the next pulse on another parameter while the finger is still
-- on the one it pressed -- so the hold counts as busy from its press to its release.
function Drive:valueBusy()
  local now = self.radio.now()
  return self.written ~= 0 or self.holdRow ~= nil or self.pulseUntil ~= nil or now < (self.coolUntil or 0)
end

--- The function id sitting in the current cell, or nil when the cell carries no slot.
function Drive:functionId(bank, row)
  local bankSet = self.set and self.set[bank or self.bank]
  if type(bankSet) ~= "table" then return nil end
  return bankSet[row or self.row]
end

local function writeGvar(self, index, fm, value)
  if not index or index <= 0 then return false end
  return self.radio.setGlobalVariable(index - 1, fm, value)
end

--- Put `value` on the value variable, and remember the flight mode it went to.
--
-- The flight mode matters: model.setGlobalVariable resolves a "same as FMx" link itself, so a
-- write made in one mode and cleared in another can leave the first one standing. The clear goes
-- back to the mode the write was made in.
--
-- The BOOKKEEPING IS PESSIMISTIC, and the order of the two lines is the whole of it. A widget pass
-- is killed wherever the firmware's instruction limit happens to land, including between the write
-- and the note of it, and the two orders fail in opposite directions. Recording afterwards, a pass
-- killed in between leaves the drive believing 0 is standing when the row's magnitude is -- and
-- `cleanup(false)` then writes nothing, for ever, because it only clears what it believes it put
-- there. Recording first, the same pass leaves the drive believing a value is standing that is
-- not, and the cost of that is one redundant write of 0.
--
-- Which of the two lines comes first therefore depends on the direction. A value going ON is
-- recorded before it is written; a value going OFF is written before it is un-recorded, because
-- for a clear it is the clear itself that must not be lost.
function Drive:writeValue(value, fm)
  if self.written == value then return end
  local settings = self.settings
  if not settings or (settings.value_gvar or 0) <= 0 then
    self.written = value
    return
  end
  local mode = fm
  if mode == nil then mode = self.writtenFm end
  if mode == nil then mode = self.radio.flightMode() end
  if value ~= 0 then
    self.written = value
    self.writtenFm = mode
    -- What decides, after the flight, whether there is a delta screen at all. Counted on the
    -- WRITE and not on the board's answer: AdjF needs sensor 99 and a custom telemetry mode, and
    -- a pilot without those still moved his parameters and still wants the undo offered.
    if self.phase == M.PHASE_LIVE then self.fired = self.fired + 1 end
    writeGvar(self, settings.value_gvar, mode, value)
  else
    writeGvar(self, settings.value_gvar, mode, 0)
    self.written = 0
    self.writtenFm = nil
  end
  logDrive("value gvar %d fm %d <- %d", settings.value_gvar, mode, value)
end

--- Park the enable channel in the middle of one band's window.
--
-- Mid-band rather than an edge, so switch, mixer and receiver tolerance all fit inside the window
-- the firmware is watching.
function Drive:armBank(bank)
  local settings = self.settings
  if not settings or (settings.bank_gvar or 0) <= 0 then return false, "no_gvar" end
  local value = self.bankValues and self.bankValues[bank]
  if value == nil then return false, "no_band" end
  local fm = self.radio.flightMode()
  -- Recorded before it is written, for the reason writeValue sets out: a pass killed between the
  -- two must leave the drive believing MORE is standing than is, never less, because a cleanup
  -- only takes back what it believes it put there.
  --
  -- The flight mode is recorded with it, for the same reason the value variable's is:
  -- model.setGlobalVariable resolves a "same as FMx" link itself, so a bank armed in one mode and
  -- cleared in another leaves the first one armed. A pilot who changes flight mode with
  -- the tuning surface open would otherwise land back on the
  -- ground with the enable channel still parked in a band.
  self.bankWritten = value
  self.bankFm = fm
  writeGvar(self, settings.bank_gvar, fm, value)
  logDrive("bank gvar %d fm %d <- %d (bank %d)", settings.bank_gvar, fm, value, bank)
  return true
end

--- Assert the selected bank while the surface is open, including on ground and after landing.
-- One comparison repairs the defensive opening clear, a flight-mode change or a navigation.
-- The value channel remains zero unless a pulse owns it.
--
-- Refused, silently, while a value stands on the wire: moving the enable channel under a
-- magnitude that sits inside a step window is how one press ends up counted against another
-- parameter. The chip and the bank trim are refused for the same reason (the bank trim says so
-- on the screen, see walkTrim), and this write lands on the first pass after the pulse has gone.
function Drive:ensureBankArmed()
  local settings = self.settings
  if not settings or (settings.bank_gvar or 0) <= 0 then return false, "no_gvar" end
  local want = self.bankValues and self.bankValues[self.bank]
  if want == nil then return false, "no_band" end
  if self.bankWritten == want then return false, "armed" end
  if self:valueBusy() then return false, "busy" end
  return self:armBank(self.bank)
end

-- Compatibility entry points use the same dispatcher as touch and keys. The bank/row are still
-- the wire address; the visible walk is the current group's ordered list, without wrapping.
function Drive:navigate(up)
  return self:dispatch("function", up and 1 or -1, "trim")
end

function Drive:selectRow(row)
  local cell = self.groupCells[self.bank] and self.groupCells[self.bank][row]
  if cell == nil or cell.group ~= self.group then return false, "range" end
  return self:dispatch("select", nil, "touch", cell.index)
end

--- A press on the minus or plus control. Refused inside the cool-down, the gap after a pulse: the
-- logical switch on the value line re-arms only once it has seen the variable at 0, and the board
-- does not sample the channel for REPEAT_DELAY after a step, so two pulses closer together than
-- that would read as one plateau rather than two steps.
--
-- Refused just the same while a TRIM pulse or the cool-down after it is running. Both paths drive
-- the one value variable, so a tap inside a trim's pulse either replaces its magnitude before the
-- board has counted it -- the trim's step is lost -- or, in the same direction, stretches the
-- plateau past REPEAT_DELAY into a second step. The trim path refuses a touch pulse the same way
-- (Drive:pollTrimStep).
function Drive:startPress(row, up)
  if not self:tuning() then return false, self:profileRefusal() or "not_live" end
  local now = self.radio.now()
  if self.pulseUntil ~= nil or now < (self.coolUntil or 0) then
    -- Said on the screen rather than returned to a caller that drops it. The pilot's own report
    -- after three rounds is "sometimes no step at all", and his card log shows what that is: a
    -- tap inside the cool-down writes nothing, logs nothing and looks exactly like a control that
    -- is not wired up. The cool-down is right -- the board cannot tell two steps that close apart
    -- -- so what was missing is the sentence, not the step.
    self:refuseStep("cooling", now)
    return false, "cooling"
  end
  local code = Functions.rowCode(row or self.row, up, self.rowValues, self.bank)
  if code == nil then
    self:refuseStep("range", now)
    return false, "range"
  end
  self.stepRefusedUntil, self.stepRefusedReason = nil, nil
  self.row = row or self.row
  self.pulseCode = code
  self.pulseUntil = now + self:pulseTicks()
  self.holdRow = row or self.row
  self.holdUp = up
  self.holdSince = now
  self:writeValue(code, self.radio.flightMode())
  return true
end

--- The release of a held control. The value falls away at the end of the pulse rather than here,
-- so a control tapped faster than the flight controller's own trigger delay still produces a step.
--
-- Nothing else is needed for the next press. A hold puts its magnitude on the variable one pulse
-- at a time with the gap at 0 between them (fastTick), so whenever it is let go, either a pulse
-- is running and sets the gap when it ends, or the gap is already running.
function Drive:release()
  self.holdRow = nil
  self.holdUp = nil
  self.holdSince = nil
end

--- One tap, for a radio whose LVGL build has no momentary button: press without the hold, so the
-- pulse ends on its own timer and nothing waits for a release that never comes.
function Drive:tap(row, up)
  return self:dispatch("step", up and 1 or -1, "touch", row)
end

function Drive:press(row, up)
  return self:dispatch("step", up and 1 or -1, "touch_hold", row)
end

local Announcer = nil
local function announcer()
  if Announcer == nil then Announcer = requireModule("tasks/events/telemetry_bg/adjustments.lua") end
  return Announcer
end

function Drive:cancelSpeech()
  if Announcer and type(Announcer.cancelSelection) == "function" then Announcer.cancelSelection(self) end
end

function Drive:speakSelection(kind)
  local teller = announcer()
  local group = self.groups[self.group]
  local entry = group and group.entries[self.entry]
  if teller and type(teller.select) == "function" and entry then
    teller.select(self, kind, kind == "group" and group.id or entry.id,
      kind == "value" and self.values[entry.id] or nil, self.radio.now())
  end
end

-- One semantic route owns navigation and adjustment, regardless of the physical input. A busy
-- gesture is consumed here and never saved for later. Touch holds retain their bounded pulse
-- train; keys, encoder changes and trim edges use taps and cannot start a hold.
function Drive:dispatch(action, direction, source, index, armed)
  local now = self.radio.now()
  if action == "release" then self:release(); return true end
  -- The group picker is a scene of the live surface, not a native popup: a popup closed with RTN
  -- calls nothing back, so the scene under it could neither return the encoder's focus nor know
  -- the choice was abandoned. Opening it leaves value mode; RTN, or the title again, closes it.
  if action == "picker" then
    if self.live ~= true or self.phase ~= M.PHASE_LIVE then return false, "not_live" end
    if #self.groups < 2 then return false, "groups" end
    if self.groupPicker then
      self.groupPicker = nil
      self.valueEpoch = self.valueEpoch + 1
      return true
    end
    if self.valueMode then
      local ok, reason = self:dispatch("leave", nil, source, nil, armed)
      if not ok then return ok, reason end
    end
    self.groupPicker = true
    self.valueEpoch = self.valueEpoch + 1
    return true
  end
  if self.groupPicker and (action == "back" or action == "leave" or action == "pick") then
    self.groupPicker = nil
    self.valueEpoch = self.valueEpoch + 1
    if action ~= "pick" then return true end
    local target = tonumber(index) or self.group or 1
    -- The current group chosen again goes to its first function, as the title's menu did.
    if target == self.group then return self:dispatch("function", nil, source, 1, armed) end
    return self:dispatch("group", target - (self.group or 1), source, nil, armed)
  end
  if action == "pick" then return false, "stale" end
  -- Any other input takes the picker down first; what it asked for is then decided as usual.
  if self.groupPicker then
    self.groupPicker = nil
    self.valueEpoch = self.valueEpoch + 1
  end
  -- Armed input cannot close the surface, including before a live phase is published.
  -- RTN can still leave value mode through the common leave action.
  if (action == "close" or (action == "back" and not self.valueMode))
      and armed == true then
    return false, "armed"
  end
  if action == "close" then
    self:evaluateInterlock(now, false)
    self:cancelSpeech()
    self.valueMode = false
    self.closeRequested = true
    return true
  end
  if action == "back" then
    if self.valueMode then return self:dispatch("leave", nil, source, nil, armed) end
    return self:dispatch("close", nil, source, nil, armed)
  end
  if action == "leave" then
    if self:valueBusy() then self:refuseStep("cooling", now); return false, "busy" end
    self:release()
    if self.valueMode then
      self.valueMode = false
      self.valueEpoch = self.valueEpoch + 1
    end
    return true
  end
  if action == "step" then
    -- A native callback may run after a switch moved but before the next widget sample.
    self:watchProfiles()
    local refusal = self:profileRefusal()
    if refusal ~= nil then self:refuseStep(refusal, now); return false, refusal end
    -- AdjF/AdjV retain the last adjustment for several seconds and carry no profile id. After
    -- a profile pause, a nonzero report may still belong to the profile just left. Observe its
    -- idle boundary before another step; a timer would only guess when the old report ended.
    if self.reportFence then
      local report = self.radio.sensor("AdjF")
      if report ~= nil and report > 0 then
        self:refuseStep("report_sync", now)
        return false, "report_sync"
      end
      if report ~= 0 then return false, "report_sync" end
      self.reportFence = nil
    end
  end
  if self:valueBusy() then
    self:refuseStep("cooling", now)
    return false, "busy"
  end
  -- A sampled trim edge and a native callback can arrive in the same radio tick. They cannot
  -- both acquire the value channel, including when a second route only changes the selection.
  if self.inputAt == now and self.inputSource ~= source then return false, "input_owned" end
  if action == "group" and self.phase == M.PHASE_POST then
    return self:pageDelta(direction > 0, self.deltaPages)
  end
  if self.live ~= true or self.phase ~= M.PHASE_LIVE then return false, "not_live" end
  if action == "step" then
    local row = index or self.row
    local cell = self.groupCells[self.bank] and self.groupCells[self.bank][row]
    if cell == nil then self:refuseStep("range", now); return false, "range" end
    if self:cellOutOfBounds(self.bank, row) then self:refuseStep("bounds", now); return false, "bounds" end
    if source == "encoder" and not self.valueMode then return false, "browse" end
    local ok, reason = self:startPress(row, direction > 0)
    if ok then
      self.group, self.entry = cell.group, cell.index
      self.inputAt, self.inputSource = now, source
      if source ~= "touch_hold" then self:release() end
    end
    return ok, reason
  end
  local groupIndex, entryIndex = self.group, self.entry
  if action == "group" then
    groupIndex, entryIndex = groupIndex + direction, 1
  elseif action == "function" then
    entryIndex = index or (entryIndex + direction)
  elseif action == "select" then
    entryIndex = index or entryIndex
  else
    return false, "action"
  end
  local group = self.groups[groupIndex]
  local cell = group and group.entries[entryIndex]
  if cell == nil then
    self:refuseStep("list_end", now)
    local teller = announcer()
    if teller and type(teller.endFeedback) == "function" then teller.endFeedback() end
    return false, "list_end"
  end
  self.group, self.entry = groupIndex, entryIndex
  self.bank, self.row = cell.bank, cell.row
  self.valueMode = action == "select" or (action == "function" and self.valueMode)
  self:ensureBankArmed()
  self.inputAt, self.inputSource = now, source
  self.valueEpoch = self.valueEpoch + 1
  self:speakSelection(action == "group" and "group" or (self.valueMode and "value" or "function"))
  return true
end

--- Both variables to 0 and every pending motion dropped.
--
-- Cheap and idempotent by design: it runs on closing tuning, on leaving fullscreen, on the
-- widget going to background, on the link dropping, and once defensively when tuning opens.
-- `force` writes even when the drive believes the variables are already clear, which is what the
-- rising edge needs -- what a previous session left behind is not knowable from here.
--
-- `keepBank` leaves the enable channel alone, and exactly one caller passes it: the transition OUT
-- of the air. The value variable going to 0 there is the safety rule this whole file is built
-- around and stays unconditional. The bank variable is not a magnitude, steps nothing on its own,
-- and while the surface is still open it has to go on saying which bank the surface has selected --
-- so clearing it on the landing and writing it straight back on the next pass would be a pair of
-- model writes that cancel out.
function Drive:cleanup(force, keepBank)
  self:cancelSpeech()
  -- A contact held across an exit, loss or profile pause is not a new trim press on reopening.
  -- Keep this latch across the defensive rising-edge clear; only an observed release clears it.
  self.trimAwaitRelease = true
  self.stepRefusedUntil, self.stepRefusedReason = nil, nil
  local settings = self.settings
  local fm = self.writtenFm
  if fm == nil then fm = self.radio.flightMode() end

  self.pulseCode = nil
  self.pulseUntil = nil
  self.holdRow = nil
  self.holdUp = nil
  self.holdSince = nil
  self.trimRow = nil
  self.trimUp = nil
  self.navDir = 0
  self.navNextAt = nil
  self.bankDir = 0
  self.bankNextAt = nil

  if settings and (settings.value_gvar or 0) > 0 and (force or self.written ~= 0) then
    writeGvar(self, settings.value_gvar, fm, 0)
    logDrive("cleanup: value gvar %d fm %d <- 0", settings.value_gvar, fm)
  end
  self.written = 0
  self.writtenFm = nil

  if not keepBank then
    if settings and (settings.bank_gvar or 0) > 0 and (force or (self.bankWritten or 0) ~= 0) then
      -- The mode the bank was ARMED in, not the mode the radio happens to be in now. Cleared in the
      -- wrong one, the write goes to a different slot -- or is redirected by a "same as FMx" link --
      -- and the enable channel stays parked in a band nobody chose.
      local bankFm = self.bankFm
      if bankFm == nil then bankFm = self.radio.flightMode() end
      writeGvar(self, settings.bank_gvar, bankFm, 0)
      logDrive("cleanup: bank gvar %d fm %d <- 0", settings.bank_gvar, bankFm)
    end
    self.bankWritten = 0
    self.bankFm = nil
  end
  self.coolUntil = 0
end

--- The verdict while the trim block is still being walked: a fault list of one, so that every
-- gate that refuses on a fault refuses on it too, and a code of its own for the sentence.
M.TRIMS_PENDING = { "trims_pending" }

--- Whether the setup check still waits for the trim block. Only a configuration that drives rows
-- from the trims needs it; one that does not has nothing to wait for.
local function trimsPending(drive)
  local settings = drive.settings
  return type(settings) == "table" and settings.trims == true and drive.trimsResolved ~= true
end

--- The cached setup verdict: a list of fault codes, the string "ok", or nil for "nothing about
-- this model could be looked at".
--
-- The walk behind it reads the model's mixer lines, its global variable details and its trim
-- modes. It is taken at most once per settings change and once per ground-surface opening, and NEVER
-- while the craft is in the air: the airborne pass is the one driving the flight controller, and
-- a verdict cannot change under a pilot who is flying.
--
-- The screen reads this same cache -- see inflight/screen.lua M.checkVerdict -- so the sentence
-- on the ground surface and the refusal below are one answer and not two walks.
--
-- Not taken at all while the trims are still being resolved. Without the resolved block a trim
-- stored as a switch position cannot be turned into the number the trim-mode table is indexed by,
-- so the trim half of the check is simply not made -- and a verdict cached then let the first
-- closing after every start through on a trim that still trims. The answer in that state is
-- M.TRIMS_PENDING while the surface is open, which refuses like a fault and says why, and
-- "not checked" while it is closed; neither is cached, so the pass that completes the walk is the
-- one after which the real verdict is taken. A drive that is still live when its trims go back to
-- unresolved -- the settings moved under an open surface on the ground -- answers what it has
-- (nothing, after the forget that came with them) and takes nothing either: the new settings revoke
-- output themselves (M.get drops `live`), and the next evaluation waits for the walk.
function M.verdict(drive)
  if type(drive) ~= "table" then return nil end
  if drive.phase == M.PHASE_LIVE then return drive._checkResult end
  if trimsPending(drive) then
    if drive.live == true then return drive._checkResult end
    return (drive.open == true) and M.TRIMS_PENDING or nil
  end
  if drive._checkedAt == nil then
    drive._checkedAt = drive.radio.now()
    drive._checkResult = Setup.check(drive)
    -- What the surface shows, kept apart from the cache: a forget (the surface closed, the settings
    -- moved) empties the cache for the next pass to fill, and the published refusal stands until a
    -- verdict has actually been taken again -- rather than dropping to the theme for that one pass.
    drive._checkFault = type(drive._checkResult) == "table"
  end
  return drive._checkResult
end

--- The verdict is about a model that has just changed, so it is taken again.
function Drive:forgetVerdict()
  self._checkedAt = nil
  self._checkResult = nil
end

-- Ending a session (another board, a battery change) drops its caches and requests a new read,
-- whose start values then replace these on the SD card; a pending transaction retains its return pair.
function Drive:endSession()
  if self.profileJob then self.profileJob.cancelled = true end
  if _G.rfsuite and _G.rfsuite.inflightProfileJob == self.profileJob then _G.rfsuite.inflightProfileJob = nil end
  self.postActionsOpen = nil
  self.restoreConfirm = nil
  self.restoreResultOpen = nil
  -- The session's parameter choice and the ground dialogs belong to the session that ends.
  self.sessionList, self.sessionPick, self.sessionPickerOpen = nil, nil, nil
  self.pendingSave = nil
  self.baseline = nil
  self.sessionProfiles = nil
  self.profileValues = nil
  self.profilePrevious = nil
  self.changes = {pid = {}, rate = {}, global = {}}
  self.primedValues = nil
  self.transfer = nil
  self.values = {}
  self.previous = {}
  self.valuesRead = nil
  self.readArmed = nil
  self.readAt = nil
  self.profilePaused = false
  self.reportFence = nil
  self.valueMode = false
  self:cancelSpeech()
  self.fired = 0
  self.deltaPage = 1
  self._deltaList = nil
  self._deltaEpoch = nil
  -- The ten value reads are due, and the ground half sends them once the surface is back on the
  -- ground -- never while the feature is closed, which is what surface ownership requires.
  self.readAgain = true
  self.valueEpoch = self.valueEpoch + 1
  -- An expiry noted on the ground (widgets/dashboard/runtime.lua, inflightLinkWatch) belongs to the
  -- session ending here; left set, it would end the next session as well.
  self.sessionExpired = nil
  if _G.rfsuite then _G.rfsuite.inflightSession = nil end
  logDrive("tuning session ended: the undo, the values and the comparison go with it")
end

--- Fullscreen foreground ownership is the release, with no seed or delay in either direction.
-- A closed surface keeps the flight phase and session, but owns no output or pending input.
function Drive:evaluateInterlock(now, open)
  local wasOpen = self.open == true
  if open ~= nil then self.open = open == true end
  local settings = self.settings
  if self.open ~= true or not settings or settings.active ~= true then
    self.open, self.live = false, false
    self:cleanup(false)
    if wasOpen and self.phase ~= M.PHASE_LIVE then self:forgetVerdict() end
    return false
  end

  -- Resolve trims on their own pass before the setup check can permit output.
  if not self.live and self.phase ~= M.PHASE_LIVE and trimsPending(self) then
    self:ensureTrims()
    return false
  end

  -- A fault refuses output. An unavailable check remains unknown, as on radios that cannot
  -- expose the mixer or flight-mode data. Closing on the ground invalidates the cached check.
  if type(M.verdict(self)) == "table" then
    self.live = false
    self:cleanup(false)
    return false
  end

  if not self.live then
    -- Clear anything a previous instance may have left before selecting a bank.
    self:cleanup(true)
    self.live = true
    self.bankShown = nil
    -- A paused flight keeps its selection. Assert it before reading the channel, whose echo
    -- can still carry the cleared output or the bank from an earlier mixer frame.
    if self.phase == M.PHASE_LIVE then self:ensureBankArmed() end
    logDrive("tuning open: bank ch%d value ch%d", settings.bank_ch, settings.value_ch)
  end
  return true
end

--- The radio's trim block, resolved once and kept. Re-resolved when the settings change, because
-- the walk that finds it is not free and nothing else moves it.
--
-- The walk is taken a slice at a time and answers nil until it is complete, so no single pass can
-- be killed by it -- and the cursor is advanced BEFORE the slice is asked for, so a pass that is
-- killed inside it anyway loses that slice rather than starting the same walk again on the next
-- pass, for ever. That ordering is the whole defect this function was rewritten for: with the
-- state written after the work, a walk that overruns the instruction limit is retried by every
-- following pass and the widget never gets past it.
--
-- The epoch is bumped on the pass that completes the walk, because the row list carries a marker
-- per trim and that marker becomes knowable exactly then.
function Drive:ensureTrims()
  if self.trimsResolved then
    if type(self.trims) ~= "table" then return nil end
    return self.trims
  end

  local scan = self.trimScan
  if scan == nil then
    scan = { list = {}, from = nil }
    self.trimScan = scan
  end

  local slice, resumeAt = self.radio.switchList(scan.from, SWITCH_SLICE)
  scan.from = resumeAt
  if type(slice) == "table" then
    for i = 1, #slice do
      scan.list[#scan.list + 1] = slice[i]
    end
  end
  if resumeAt ~= nil and #scan.list < SWITCH_WALK_LIMIT then return nil end

  self.trims = M.trimsFromList(scan.list)
  self.trimsResolved = true
  self.trimScan = nil
  -- A store written before the trims were picked with the radio's own picker holds semantic
  -- indices, 1..6. The walk is the first moment anything here can say what those mean, so the
  -- conversion happens on the pass that completes it. Nothing is written to the card from the
  -- widget: this is an in-memory reading of an old file, and the settings page's next save is
  -- what puts the new form on it.
  if type(self.trims) == "table" then Setup.migrateTrims(self.settings, self.trims) end
  self.valueEpoch = self.valueEpoch + 1
  if type(self.trims) ~= "table" then return nil end
  return self.trims
end

--- Whether a step may be asked for at all: the overlay up AND the machine in the air.
--
-- One function rather than a test spelled at each control, because every one of them has to agree
-- and a control that forgot the phase would be a step taken on a screen showing no rows.
function Drive:tuning()
  return self.live == true and self.phase == M.PHASE_LIVE and self:profileRefusal() == nil
end

-- Permission follows completed ground membership, independent of reopening tuning.
function Drive:profileRefusal()
  if self.profileBusy or self.restorePending then return "profile_reading" end
  if self.readRequired and not (self.readArmed and self.phase == M.PHASE_LIVE) then return "session_unread" end
  if self.sessionProfiles == nil then return "session_unread" end
  if self.board then
    if not boardIdentity then boardIdentity = requireModule("widgets/dashboard/inflight/prime.lua") end
    local board = boardIdentity.boardOnLink()
    -- A link that came back in the air has no identified board until landing, and the widget
    -- vouches for this flight with an armed reading taken since (armedThrough).
    if board == nil and not (self.armedThrough and self.phase == M.PHASE_LIVE) then return "board_unknown" end
    if board == nil then board = self.board end
    if board ~= self.board then return "session_unread" end
  end
  if self.profile == nil or self.rateProfile == nil then return "profile_unknown" end
  if not self.sessionProfiles.pid[self.profile] then return "pid_unread" end
  if not self.sessionProfiles.rate[self.rateProfile] then return "rate_unread" end
  return nil
end

-- Keep the existing flat value view for the renderer and dispatcher. The owning caches remain
-- per profile; a report changes its owner as well as this view without moving the layout epoch.
function Drive:activateProfiles()
  self.values, self.previous, self.primedValues = {}, {}, {}
  local cache, history, baseline = self.profileValues, self.profilePrevious, self.baseline
  if not cache then return end
  for _, kind in ipairs({"pid", "rate", "global"}) do
    local index = kind == "pid" and self.profile or self.rateProfile
    local values = kind == "global" and cache.global or cache[kind][index]
    local old = history and (kind == "global" and history.global or history[kind][index])
    local name = kind == "global" and "global" or kind .. tostring(index)
    local start = baseline and baseline[name]
    for id, value in pairs(values or {}) do
      self.values[id] = value
      self.previous[id] = old and old[id]
      self.primedValues[id] = start and start[tostring(id)]
    end
  end
end

function Drive:navigateMode()
  local settings = self.settings
  return settings ~= nil and settings.trim_mode == M.TRIM_MODE_NAVIGATE
end

-- Optional walk trims follow the same groups and functions as the flying surface. Their edge
-- clocks remain independent of the adjustment trim; a refused walk never queues an adjustment.
function Drive:navigateRow(up)
  return self:dispatch("function", up and 1 or -1, "trim")
end

function Drive:navigateBank(up)
  return self:dispatch("group", up and 1 or -1, "trim")
end

--- One walk trim, read as an EDGE with a repeat clock of its own. One press moves one step,
-- however long the pass takes; held on purpose it repeats, after a delay no single press reaches.
local function walkTrim(self, now, trim, dirKey, nextKey, step)
  local direction = 0
  if self.radio.switchValue(trim.plus) == true then
    direction = 1
  elseif self.radio.switchValue(trim.minus) == true then
    direction = -1
  end

  if direction ~= self[dirKey] then
    self[dirKey] = direction
    if direction ~= 0 then
      -- A walk or bank step is refused while a value stands on the wire ("busy"), and the edge is
      -- booked either way, so the press is spent. Said on the screen with the line every other
      -- step that comes too soon gets, rather than looking like a trim that is not wired up. Once,
      -- at the press: a held trim's repeats do not move the refusal's deadline.
      local _, reason = step(self, direction > 0)
      if reason == "busy" then self:refuseStep("cooling", now) end
      self[nextKey] = now + NAV_REPEAT_DELAY_TICKS
    else
      self[nextKey] = nil
    end
    return
  end

  if direction ~= 0 and self[nextKey] ~= nil and now >= self[nextKey] then
    -- A trim refused at the press and held on walks here once the step is off the wire, which can
    -- be before the refusal's line has run out: the line goes with the step it no longer describes.
    local ok = step(self, direction > 0)
    if ok == true and self.stepRefusedReason == "cooling" then
      self.stepRefusedUntil, self.stepRefusedReason = nil, nil
    end
    self[nextKey] = now + NAV_REPEAT_INTERVAL_TICKS
  end
end

--- The two walk trims: one steps the bank, one steps the row inside it.
--
-- The bank is polled FIRST. Both refuse while a value is standing on the variable, and a pilot
-- who presses the two together means the bank -- the row he lands on is chosen by the bank step
-- anyway, so reading the row first would make the pair depend on which one his thumb reached a
-- millisecond earlier.
function Drive:pollNavigate(now)
  local settings = self.settings
  if not settings or settings.trims ~= true or not self:navigateMode() then return end
  local trims = self:ensureTrims()
  if trims == nil then return end

  local bankTrim = Setup.trimEntry(trims, settings.bank_trim)
  if bankTrim ~= nil then
    walkTrim(self, now, bankTrim, "bankDir", "bankNextAt", Drive.navigateBank)
  end

  local navTrim = Setup.trimEntry(trims, settings.nav_trim)
  if navTrim ~= nil then
    walkTrim(self, now, navTrim, "navDir", "navNextAt", Drive.navigateRow)
  end
end

--- The walk trim, out on the ground, paging the delta list.
--
-- The same trim and the same edge-and-repeat clock the walk uses in the air; only what it steps
-- is different. `deltaPages` is put on the drive by the screen that laid the list out, because how
-- many rows fit is a property of the surface and not of the drive -- and until a postflight surface
-- has been built there is nothing to page.
function Drive:pollDeltaPaging(now)
  local settings = self.settings
  if not settings or settings.trims ~= true then return end
  local pages = math.floor(tonumber(self.deltaPages) or 0)
  if pages < 2 then return end
  local trims = self:ensureTrims()
  if trims == nil then return end
  local navTrim = Setup.trimEntry(trims, settings.nav_trim)
  if navTrim == nil then return end
  walkTrim(self, now, navTrim, "navDir", "navNextAt", function(drive, up)
    drive:pageDelta(up, pages)
  end)
end

--- Which row a held trim is asking for, read once per pass.
--
-- In `rows` mode every assigned trim is a row of its own. In `navigate` mode ONE trim adjusts and
-- it always means the selected row; every other trim, the walk trim included, is inert here.
function Drive:pollTrims()
  local settings = self.settings
  if not settings or settings.trims ~= true then return nil, nil end
  local trims = self:ensureTrims()
  if trims == nil then return nil, nil end

  if self:navigateMode() then
    local trim = Setup.trimEntry(trims, settings.adj_trim)
    if trim then
      if self.radio.switchValue(trim.plus) == true then return self.row, true end
      if self.radio.switchValue(trim.minus) == true then return self.row, false end
    end
    return nil, nil
  end

  -- M.get clears this route when settings change and the trim block must be walked again.
  -- Resolve the six row assignments after the sliced trim walk and legacy migration finish.
  -- Keep the sampling order and cadence; only the repeated stored-position lookup goes away.
  local rowTrims = self.rowTrims
  if rowTrims == nil then
    rowTrims = {}
    for row = 1, Functions.ROW_COUNT do
      rowTrims[row] = Setup.trimEntry(trims, settings.rowTrim and settings.rowTrim[row])
    end
    self.rowTrims = rowTrims
  end

  -- The row with the largest magnitude wins when two trims are held at once. It is a choice
  -- rather than a reading: the shipped template SUMS its trims onto the value channel, and a sum
  -- of two lands outside every window, so two trims there produce no step at all.
  for row = 1, Functions.ROW_COUNT do
    local trim = rowTrims[row]
    if trim then
      if self.radio.switchValue(trim.plus) == true then return row, true end
      if self.radio.switchValue(trim.minus) == true then return row, false end
    end
  end
  return nil, nil
end

--- The adjust trim is an edge, never a held level. A contact sampled down on consecutive
-- passes is still one press, even when a different parameter has been highlighted meanwhile.
-- Book the edge before dispatching: an input refused during a pulse or its gap cannot fire
-- later when the gap expires. A release only permits a new edge; it never shortens the pulse.
--
-- The dispatcher uses the same pulse and cooldown as touch and encoder input, immediately
-- releasing the hold state for a trim. Only an explicit touch hold keeps that state and starts
-- another pulse. A sampled trim therefore cannot repeat, freeze a scene waiting for a native
-- release, or overlap a touch pulse. Neither an edge nor an AdjV moves the layout epoch.
function Drive:pollTrimStep(_now)
  local row, up = self:pollTrims()
  if self.trimAwaitRelease then
    if row == nil then self.trimAwaitRelease = false end
    return
  end

  -- Everything happens at an edge. A trim that reads the same as on the last pass -- held, or let
  -- go and pressed again between two passes -- has had its answer already.
  --
  -- The edge is the TRIM's, not the row it lands on. In `rows` mode the two are one thing, each row
  -- having a trim of its own. In `navigate` mode the one adjust trim answers whichever row is
  -- selected, and the selection can move while it is held -- a group trim step or a tap on another parameter -- so an edge keyed on the row read each of those as a new press and
  -- stepped the new row without the trim coming up. There `trimRow` holds 0 for "the adjust trim"
  -- instead, never a row number.
  local key = row
  if row ~= nil and self:navigateMode() then key = 0 end
  if key == self.trimRow and up == self.trimUp then return end
  self.trimRow, self.trimUp = key, up

  -- Let go. The magnitude does not fall away here: a pulse still running owns it until its own
  -- clock says otherwise, and that is the whole of what makes a short press step at all.
  if row == nil then return end

  self:dispatch("step", up and 1 or -1, "trim", row)
end

--- The fast half of a pass: what the board is reporting and what the pilot's thumb is doing.
--
-- Split out of `tick` because the two clocks are not the same one. The widget's background half
-- runs on a 100 ms logic tick while the firmware calls the widget every 50 ms, and neither of the
-- things in here can wait for the slower clock. The value on the screen is the board's answer to
-- the step the pilot has just asked for, and it is the only thing that tells him the step landed;
-- the trims are momentary contacts, and a press that begins and ends between two logic ticks is a
-- press nothing ever saw. Both are cheap -- two telemetry reads and a handful of switch reads, no
-- allocation and no model call -- and none of it runs while the surface is closed.
--
-- Guarded on the radio's own clock, so a pass that runs the whole tick as well as this one does
-- the work once rather than twice.
function Drive:fastTick(now)
  if self.fastAt == now then return end
  self.fastAt = now
  local _, refusal = self:watchProfiles()
  local tuning = self.live == true and self.phase == M.PHASE_LIVE and refusal == nil
  if self.stepRefusedUntil ~= nil and now >= self.stepRefusedUntil then
    self.stepRefusedUntil, self.stepRefusedReason = nil, nil
  end

  -- The last adjustment the board reports having made. AdjF reads 0 between adjustments, so a
  -- non-zero reading is a fresh one and its value belongs to that function.
  local adjF = refusal == nil and self.radio.sensor("AdjF")
  if self.reportFence and refusal == nil and adjF == 0 then self.reportFence = nil end
  if adjF and adjF > 0 and not self.reportFence and refusal == nil then
    local adjV = self.radio.sensor("AdjV")
    if adjV ~= nil and self.values[adjF] ~= adjV then
      -- Where this parameter stood BEFORE the step the board has just reported. It is what the
      -- live surface shows beside the value, and it is the only number that tells a pilot whether
      -- the step that just landed went the way he asked -- the primed value is where the flight
      -- started and says nothing about the last press.
      self.previous[adjF] = self.values[adjF]
      self.values[adjF] = adjV
      local kind = Functions.scopeOf(adjF) or "global"
      local index = kind == "pid" and self.profile or self.rateProfile
      local owner = kind == "global" and self.profileValues.global or self.profileValues[kind][index]
      local histories = self.profilePrevious
      local history
      if kind == "global" then history = histories.global else
        histories[kind][index] = histories[kind][index] or {}
        history = histories[kind][index]
      end
      history[adjF], owner[adjF] = self.previous[adjF], adjV
      local changed
      if kind == "global" then changed = self.changes.global else
        self.changes[kind][index] = self.changes[kind][index] or {}
        changed = self.changes[kind][index]
      end
      -- Only differences need to be visited when the post-flight scene is built.
      changed[adjF] = self.primedValues[adjF] ~= nil and self.primedValues[adjF] ~= adjV or nil
      -- The REPORT counter and not the layout epoch, and that one word is the whole of this fix.
      --
      -- The board answers a step 300-400 ms after the press, which is while the pulse that asked
      -- for it is still standing on the value variable. The layout epoch used to be in the live
      -- render key, so bumping it here tore the live surface down and built it again inside the
      -- pulse window -- and the pass that ENDS the pulse is a widget pass. EdgeTX hands those out
      -- in fixed slots from its menus task and never catches up (radio/src/tasks.cpp,
      -- MENU_TASK_PERIOD; the call site is LuaWidget::refresh in lua_widget.cpp): a pass that
      -- overruns its slot loses the next ones rather than running twice, so the clear arrived
      -- late, the magnitude stood on the wire past the firmware's own repeat window, and the
      -- board counted a second step the pilot never asked for.
      --
      -- Nothing a report carries is layout. The value, the value it stepped from and the six row
      -- values are all read off the snapshot by closures, so a fresh snapshot is published, the
      -- numbers follow the board on the next frame, and the tree is left standing.
      self.reportEpoch = self.reportEpoch + 1
    end
  end

  -- The postflight list is paged with the walk trim, and it is the ONLY thing a trim does out
  -- there: a phase with no rows and no step controls must not have a thumb writing a magnitude.
  if self.phase == M.PHASE_POST then
    self:pollDeltaPaging(now)
    return
  end

  -- The pilot's thumb and the pilot's finger must not both be writing the same variable, and the
  -- trims are read through a touch pulse rather than suspended by it: a trim press nobody read was
  -- lost without a word, and one held across the pulse was first seen after it and stepped inside
  -- the touch's cool-down. Each trim path refuses for itself instead -- the adjust trim while the
  -- touch control owns the variable (Drive:pollTrimStep), the walk and bank trims while any value
  -- stands on it (walkTrim). Only once the trim block is resolved, though: until then no trim can
  -- be read at all, and the walk that resolves it is kept off while a touch pulse or hold owns the
  -- variable, as it always was.
  local touching = (self.pulseUntil ~= nil) or (self.holdRow ~= nil)
  if tuning and (self.trimsResolved or not touching) then
    self:pollNavigate(now)
    self:pollTrimStep(now)
  end

  if self.pulseUntil ~= nil and now >= self.pulseUntil then
    self.pulseUntil = nil
    self.pulseCode = nil
    self.coolUntil = now + GAP_TICKS
  end
  -- A hold that has outlived HOLD_LIMIT_SECONDS is let go here, whether or not its release was
  -- ever reported, and the magnitude falls away below on the same pass. A release that does arrive
  -- afterwards finds nothing held and changes nothing.
  -- A hold with no start recorded is treated as an old one: only press() sets both.
  if self.holdRow ~= nil and (self.holdSince == nil or now - self.holdSince >= HOLD_LIMIT_TICKS) then
    logDrive("hold on row %s ended after %d s without a release", tostring(self.holdRow), HOLD_LIMIT_SECONDS)
    self:release()
    self:refuseStep("hold_limit", now, HOLD_LIMIT_NOTICE_TICKS)
  end

  -- A held control repeats one pulse at a time. The logical switch on the value line ends every
  -- plateau after 200 ms however long the variable stands, so a magnitude simply left on the wire
  -- would step once and never again; it goes back to 0 for the gap, and the next pulse is a new
  -- plateau the board counts once. The repeat is the pulse plus the gap plus however late the
  -- passes run, slower and less even than the board's own 200 ms, and every step is exactly one.
  if tuning and self.holdRow ~= nil and self.pulseUntil == nil and now >= (self.coolUntil or 0) then
    local code = Functions.rowCode(self.holdRow, self.holdUp, self.rowValues, self.bank)
    if code ~= nil then
      self.pulseCode = code
      self.pulseUntil = now + self:pulseTicks()
    end
  end

  local want = 0
  if self.pulseUntil ~= nil then
    want = self.pulseCode or 0
  end

  if want ~= self.written then
    self:writeValue(want, want ~= 0 and self.radio.flightMode() or nil)
  end
  if Announcer and type(Announcer.selectionTick) == "function" then Announcer.selectionTick(now) end
end

-- Profile edges end every pulse/hold and fence the FC's held report before changing owners.
function Drive:watchProfiles()
  local pid, rate = self.radio.sensor("PID#"), self.radio.sensor("RTE#")
  if pid == nil or pid <= 0 then pid = nil end
  if rate == nil or rate <= 0 then rate = nil end
  local oldPid, oldRate = self.profile, self.rateProfile
  local changed = oldPid ~= pid or oldRate ~= rate
  self.profile, self.rateProfile = pid, rate
  local refusal = self:profileRefusal()
  local wasPaused = self.profilePaused
  self.profilePaused = refusal ~= nil
  if changed then
    -- The fence is for a change between two KNOWN profiles: a report the board still holds from
    -- the old one must not be credited to the new one. A profile that only turns unknown is no
    -- such edge -- the sensors read 0 across a link loss -- and fencing it would leave the steps
    -- of a flight that continues after the gap waiting for an AdjF of 0 the board need not send.
    -- Output still stops while the profile is unknown.
    if pid ~= nil and rate ~= nil then
      if self.knownPid ~= nil and (self.knownPid ~= pid or self.knownRate ~= rate) then
        self:cleanup(false)
        self.reportFence = true
      end
      self.knownPid, self.knownRate = pid, rate
    elseif oldPid ~= nil or oldRate ~= nil then
      self:cleanup(false)
    end
    self:cancelSpeech()
    self:activateProfiles()
    self.reportEpoch = self.reportEpoch + 1
    local teller = announcer()
    if self.phase == M.PHASE_LIVE and not self.profileBusy and teller and type(teller.profile) == "function" then
      local events = (self._radioSource or _G.rfsuite.preferences or {}).audio_events or {}
      if pid and pid ~= oldPid and events.pid_profile == false then teller.profile(self, pid) end
      if rate and rate ~= oldRate and events.rate_profile == false then teller.profile(self, rate) end
    end
  end
  if self.phase == M.PHASE_LIVE and not self.profileBusy and self.sessionProfiles then
    local teller = announcer()
    if refusal and (changed or not wasPaused) then
      if teller and type(teller.pause) == "function" then teller.pause(self) end
    elseif not refusal and wasPaused then
      if teller and type(teller.resumed) == "function" then teller.resumed(self) end
    end
  end
  return changed, refusal
end

--- One pass of the drive. Everything with a cost is behind `live`; a widget whose pilot has the
-- surface closed performs no sensor or switch read.
function Drive:tick(armed)
  local now = self.radio.now()
  local wasLive = self.live
  self:evaluateInterlock(now)
  if not self.live then
    if wasLive then self.valueEpoch = self.valueEpoch + 1 end
    return false
  end

  -- Which of the three surfaces this pass belongs to. Armed is the pivot and everything else
  -- follows from what the last flight did: a flight that moved nothing lands back on the ground
  -- read-out, and only one that asked for a step earns the delta.
  --
  -- `armed` is the widget's own copy of the ARM sensor's bit 0. It is passed in rather than read
  -- here because the drive touches no telemetry it does not have to, and because the ground half
  -- already has a stricter reading of the same fact for the writes it makes.
  if armed == true then
    if self.restoreConfirm or self.sessionPickerOpen then
      -- Ground dialogs close on arming: nothing they offer may run while the model is armed.
      self.restoreConfirm, self.sessionPickerOpen, self.sessionPick = nil, nil, nil
      self.valueEpoch = self.valueEpoch + 1
    end
    self:setPhase(M.PHASE_LIVE)
  elseif self.phase == M.PHASE_LIVE or (self.phase == nil and self.fired > 0) then
    -- The disarm. The delta is worth a screen only if this drive actually asked for a step: a
    -- flight nobody tuned lands back on the ground read-out and not on an empty list.
    self:setPhase((self.fired > 0) and M.PHASE_POST or M.PHASE_GROUND)
  elseif self.post then
    self:setPhase(M.PHASE_POST)
  else
    self:setPhase(M.PHASE_GROUND)
  end

  -- What the enable channel is actually doing. Read rather than assumed, so a six-position switch
  -- wired straight to it shows the right bank without the overlay having written anything, and a
  -- missing mixer line is visible as a bank that does not move.
  local shown = Functions.usToBand(self.radio.channelUs(self.settings.bank_ch), self.bands)
  if shown ~= self.bankShown then
    self.bankShown = shown
    self.valueEpoch = self.valueEpoch + 1
  end
  -- The reading is ADOPTED only while the drive has put nothing on the variable itself. Once it
  -- has, the selection is what the wire is being driven from and the channel is an echo of it --
  -- one frame behind, on a radio whose mixer and channel output do not run on this pass's clock.
  -- Adopting that echo would let a lagging frame drag the selection back into the band it has just
  -- left, and the assertion below would then write the wrong bank rather than repair it. So the two
  -- do not overlap: the wire is believed where nothing of ours drives it, the selection everywhere
  -- else. `bankShown` is unaffected either way -- what the channel carries is still shown, which is
  -- how a missing mixer line stays visible.
  if shown ~= nil and shown ~= self.bank and (self.bankWritten or 0) == 0 then
    self.bank = shown
  end

  -- All phases name a bank, and only an open surface with a passing setup gate reaches here.
  self:ensureBankArmed()

  self:fastTick(now)
  return true
end

--- One page of the delta list forward or back, wrapping, from the walk trim.
--
-- The postflight list is the one screen a pilot reads standing beside the machine, and on a
-- 272-pixel radio it holds four or five rows of a list that can be twenty long. The trim that
-- walks the parameters in the air walks the pages here -- the same thumb, the same gesture, and
-- nothing new to remember.
function Drive:pageDelta(up, pages)
  local total = math.floor(tonumber(pages) or 0)
  if total < 1 then return false end
  local page = (self.deltaPage or 1) + (up and 1 or -1)
  if page < 1 or page > total then return false, "list_end" end
  if page == self.deltaPage then return false end
  self.deltaPage = page
  self.valueEpoch = self.valueEpoch + 1
  return true
end


-- ---------------------------------------------------------------------------
-- The widget's side
-- ---------------------------------------------------------------------------

local function settingsSignature(settings)
  if type(settings) ~= "table" then return "" end
  local rows = settings.rowTrim or {}
  return table.concat({
    tostring(settings.radio_enabled),
    tostring(settings.bank_ch),
    tostring(settings.value_ch), tostring(settings.bank_gvar), tostring(settings.value_gvar),
    tostring(settings.trims), tostring(settings.flight_list),
    tostring(settings.trim_mode), tostring(settings.nav_trim), tostring(settings.bank_trim),
    tostring(settings.adj_trim),
    tostring(rows[1]), tostring(rows[2]), tostring(rows[3]),
    tostring(rows[4]), tostring(rows[5]), tostring(rows[6])
  }, "|")
end

-- How often the per-model store is stat'ed, in radio ticks. One second, which is the cadence the
-- widget's own preference watcher already runs its stat at.
local STORE_STAT_TICKS = 100

--- What the PER-MODEL store looks like on the card right now: its size and its modification time,
-- as one string.
--
-- A STATE and not a signal, and the difference is the whole of why this exists. A signal is
-- consumed by whoever reads it first; a state is not, so a pass killed by the instruction limit
-- between reading this and acting on it changes nothing -- the next pass sees the same difference
-- and does the work then.
--
-- `fstat` returns the modification time as a TABLE (api_filesystem.cpp), so it is spelled out
-- field by field: tostring() on it is an ADDRESS, different on every call, and a stamp built that
-- way never equals the previous one.
local function storeStamp(path)
  if type(path) ~= "string" or type(_G.fstat) ~= "function" then return nil end
  local ok, info = pcall(_G.fstat, path)
  if not ok or type(info) ~= "table" then return nil end
  local time = info.time
  local parts = tostring(info.size)
  if type(time) == "table" then
    parts = parts .. ":" .. string.format("%04d-%02d-%02d %02d:%02d:%02d", time.year, time.mon, time.day,
      time.hour, time.min, time.sec)
  end
  return parts
end

--- The per-model store, re-read off the card when the file on the card has moved.
--
-- WHY THE OVERLAY DOES ITS OWN. The guard was written against a module-level cache in
-- lib/model_preferences.lua that nothing invalidated: the tool that saves the settings file runs
-- in a different Lua state (`lsWidgets` is its own `lua_newstate`, not a coroutine of the main
-- one), so a save refreshed the TOOL's copy of that cache while the widget's still held the file
-- as it stood at connect, and the widget's own preference watcher handed back a brand-new table
-- containing the old content. That cache is gone -- `loadByMcuId` reads the disk on every call.
--
-- The guard stays for two reasons that outlive it. It is the path the overlay's
-- settings-to-widget behaviour was measured on, and it does not depend on the runtime's own
-- reload, which is deliberately held back while armed, while the widget is off-screen and after a
-- flight with no link -- the states the overlay is live in.
--
-- So the overlay looks at the file itself. One `fstat` a second while the feature is enabled; on a
-- change, one forced read that goes to the disk. Nothing of theirs is touched and
-- `widget.modelPreferences` is left exactly where it was -- their theme reload still reads what it
-- always read -- because a fix that reached into their state would be a second writer of it.
--
-- THIS GUARD IS THE MODEL HALF'S ALONE. The radio's settings live in the radio's own preferences
-- file, and the runtime already watches that one and hands the new table down; opening a second
-- watcher on it would be the very duplication the paragraph above refuses. Only the per-model
-- store is stat'ed here.
--
-- Answers the table to settle from, or nil for "use what the widget was given".
local function freshPreferences(widget)
  local settings = widget._inflight and widget._inflight.settings
  if settings ~= nil and settings.radio_enabled ~= true then return nil end

  local session = _G.rfsuite and _G.rfsuite.session
  local mcuId = type(session) == "table" and session.mcu_id or nil
  if mcuId == nil then return nil end

  local clock = _G.getTime
  local now = (type(clock) == "function") and (tonumber(clock()) or 0) or 0
  if widget._inflightStoreAt ~= nil and (now - widget._inflightStoreAt) < STORE_STAT_TICKS then
    return widget._inflightPrefs
  end
  widget._inflightStoreAt = now

  -- The path, resolved once per model and kept. It is a function of the MCU id alone -- the
  -- store is named after it -- and resolving it walks every candidate root and builds a string,
  -- which is not work to do once a second for an answer that cannot have changed.
  local path = widget._inflightStorePath
  if path == nil or widget._inflightStoreFor ~= mcuId then
    local MPath = requireModule("lib/model_preferences.lua")
    path = (type(MPath) == "table" and type(MPath.buildPath) == "function") and MPath.buildPath(mcuId) or false
    widget._inflightStorePath = path
    widget._inflightStoreFor = mcuId
  end
  if path == false then return widget._inflightPrefs end
  local stamp = storeStamp(path)
  -- No stamp at all: no file, or a firmware without fstat. Neither is a change, and re-reading on
  -- every pass because nothing can be measured is how a guard becomes the cost it was avoiding.
  if stamp == nil then return widget._inflightPrefs end
  if stamp == widget._inflightStamp then return widget._inflightPrefs end

  -- The FIRST reading seeds and reads nothing. What the widget was handed at start-up came off
  -- the card a moment earlier -- the runtime loads the store on the connect -- so there is
  -- nothing to correct yet, and forcing a read here puts a whole file parse on a cold-start pass.
  -- Measured on a radio: three runs out of three raised `CPU limit` in this function about
  -- thirteen seconds in, on the pass this seed replaces. A stamp is a state, so a seed loses
  -- nothing: the next real change still differs from it.
  local seeding = (widget._inflightStamp == nil)
  widget._inflightStamp = stamp
  if seeding then return widget._inflightPrefs end

  local MP = requireModule("lib/model_preferences.lua")
  if type(MP) ~= "table" or type(MP.loadByMcuId) ~= "function" then return widget._inflightPrefs end
  local prefs = MP.loadByMcuId(mcuId, true)
  if type(prefs) ~= "table" then return widget._inflightPrefs end
  widget._inflightPrefs = prefs
  Setup.log("store re-read: %s", tostring(path))
  return prefs
end

--- The drive belonging to this widget, constructed on first use and re-settled whenever the
-- per-model store has been re-read.
--
-- A different TABLE is not a different setting. The store arrives here as a fresh table several
-- times per second -- the MSP runtime republishes its own copy on every publish -- so the identity
-- test is the cheap path taken on almost every pass, and the section is parsed and its signature
-- built only when the table really was replaced. Without it every pass paid for both, which is the
-- same trap widgets/dashboard/runtime.lua documents for its own theme reload.
function M.get(widget)
  if type(widget) ~= "table" then return nil end
  -- The overlay's own copy where the file has moved under the widget's, and the widget's
  -- otherwise. See freshPreferences: the widget's copy is only refreshed by the runtime's own
  -- reload, and that reload is held back in the very states the overlay runs in.
  local prefs = freshPreferences(widget) or widget.modelPreferences
  -- The radio's half, exactly as the runtime publishes it. Nothing of the overlay watches that
  -- file: widgets/dashboard/runtime.lua re-reads it on its own signal and hands the new table
  -- down, and that reload is deliberately held back while the craft is armed -- so a radio
  -- setting changed in the air is adopted once it has landed. That is the clock the theme and the
  -- preview switch already run on, and the overlay does not open a second one beside it.
  local radioPrefs = widget.preferences
  local drive = widget._inflight
  if drive ~= nil and drive._source == prefs and drive._radioSource == radioPrefs then
    return drive
  end

  local settings = M.settings(radioPrefs, prefs)
  local signature = settingsSignature(settings)
  if drive == nil then
    drive = M.newDrive(nil, settings)
    drive._signature = signature
    widget._inflight = drive
  elseif drive._signature ~= signature and ((widget.state and widget.state.armed == true)
      or (drive.live == true and drive.phase == M.PHASE_LIVE)) then
    -- Adopted after landing, like the radio's own settings: a change in the air would rebuild the
    -- offered groups and leave the list empty for the passes the rebuild takes. The sources are not
    -- recorded, so the comparison runs again on every call until the flight has ended.
    return drive
  elseif drive._signature ~= signature then
    local old = drive.settings or {}
    local channelsChanged = old.bank_ch ~= settings.bank_ch or old.value_ch ~= settings.value_ch
    drive:cleanup(false)
    drive.settings = settings
    drive.rowTrims = nil
    drive._signature = signature
    -- and the setup verdict with it: a changed channel, variable or trim is a different question
    -- for the walk, and the answer gates the drive as well as filling the line on the screen.
    drive:forgetVerdict()
    -- The refusal shown goes too: with the trims to walk again the next verdict can be a while
    -- coming, and the old one describes settings that are gone.
    drive._checkFault = nil
    drive.trimsResolved = false
    -- and with it whatever a walk in progress had collected: a half-read list belongs to the
    -- settings it was started under.
    drive.trimScan = nil
    drive.live = false
    -- A set derived under other channels names parameters no window on the new ones reaches, so
    -- it goes and the board has to be read again. Any other change keeps the board's set and only
    -- rebuilds the offered groups (the flight list may be what changed).
    if channelsChanged then drive:seedSet() else drive:rebuildGroups() end
  end
  drive._source = prefs
  drive._radioSource = radioPrefs
  return drive
end

--- The snapshot the screen's reactive closures read.
--
-- Rebuilt as a FRESH table whenever anything on it moved, and reused otherwise: a closure holds
-- the widget and reads mid-sweep, so the swap has to be atomic. Nothing here is a probe, which is
-- the whole point -- the closures never reach past this table.
--
-- It is published on `state.inflight` rather than inside `state.derived`, because
-- widgets/dashboard/derived.lua assigns a brand new table to `state.derived` on every telemetry
-- read and anything parked there would vanish with it.
local function publish(widget, drive)
  local state = widget.state
  if type(state) ~= "table" then return end
  local snapshot = state.inflight
  local epoch = drive.valueEpoch
  -- The board's own answers, which move numbers and no layout. They have to be in the guard --
  -- the closures read this table and a stale one would leave the pilot looking at the value
  -- before his step -- and they must NOT be in the widget's render key; see fastTick.
  local reportEpoch = drive.reportEpoch
  -- Whether a control is being HELD, which is the one thing on here that no epoch bump reports:
  -- a press and a release both leave the value cache alone. It is on the snapshot because the
  -- widget's render key must not move while a finger is down -- the rebuild would delete the very
  -- object that reports the release -- so the guard below has to notice it changing.
  local holding = (drive.holdRow ~= nil)
  -- And how far the ground half has got, which since the pilot's third radio round is the OTHER
  -- thing no epoch bump reports. A prime used to move the epoch on every reply, and the epoch is
  -- in the widget's render key -- so a prime tore the surface down and built it again once per
  -- reply while its replies were being parsed, which is the mechanism behind a frozen radio and an
  -- instruction budget at 70 % of its five-second peak. The counters travel here instead and the
  -- surface reads them through a closure, so the number moves and the tree does not.
  local prime = drive.prime
  local primePhase, primeDone = nil, nil
  if type(prime) == "table" then primePhase, primeDone = prime.phase, prime.done end
  -- Whether the surface is open and refused because the trims are still being walked -- or have
  -- just been, and the verdict they wait for is taken on the next pass (Drive:evaluateInterlock), so
  -- the surface does not drop to the theme for the one pass in between. Read off the drive rather
  -- than through M.verdict, which would take the check on this very pass.
  local trimsChecking = drive.live ~= true and drive.phase ~= M.PHASE_LIVE
    and drive.open == true and type(drive.settings) == "table" and drive.settings.trims == true
    and (trimsPending(drive) or drive._checkedAt == nil)
  -- And whether the surface has a refusal to show. Neither opening the surface nor a verdict being
  -- taken moves an epoch -- the first verdict after the walk is taken on a pass after the snapshot
  -- was built -- so the guard below watches the answer itself.
  local setupFault = drive._checkFault == true or trimsChecking
  local setupVerdict = trimsChecking and M.TRIMS_PENDING or drive._checkResult
  if type(snapshot) == "table" and snapshot.epoch == epoch
    and snapshot.reportEpoch == reportEpoch
    and snapshot.setupFault == setupFault
    and snapshot.setupVerdict == setupVerdict
    and snapshot.live == drive.live
    and snapshot.linkLost == (drive.linkLost == true)
    and snapshot.bank == drive.bank and snapshot.row == drive.row
    and snapshot.holding == holding
    and snapshot.phase == drive.phase
    and snapshot.group == drive.group and snapshot.entry == drive.entry
    and snapshot.valueMode == drive.valueMode and snapshot.profilePaused == drive.profilePaused
    and snapshot.groupPicker == (drive.groupPicker == true)
    and snapshot.primePhase == primePhase and snapshot.primeDone == primeDone
    and snapshot.stepRefusedReason == drive.stepRefusedReason then
    return
  end

  -- The ground half's progress, summarised rather than handed over. Its own table is mutated in
  -- place as replies arrive, and everything published here is read from a tree that is being
  -- built -- so what travels is a copy of the counters, taken at the moment of the swap.
  --
  -- `skipped` travels as a COUNT and not as the list it is kept as. The list is the run's own and
  -- goes on being appended to; a snapshot holding a reference to it is not a snapshot, and the
  -- screen wants the number anyway -- how many of the board's slots the overlay cannot drive is a
  -- fact the pilot needs, and it was being published in a form the screen never showed.
  local primeState = nil
  if type(prime) == "table" then
    primeState = {
      phase = prime.phase,
      done = prime.done,
      total = prime.total,
      error = prime.error,
      skipped = #(prime.skipped or {})
    }
  end

  local transfer = drive.transfer
  local transferState = nil
  if type(transfer) == "table" then
    transferState = { kind = transfer.kind, state = transfer.state, reason = transfer.reason, results = transfer.results }
  end

  local activeId = drive:functionId(drive.bank, drive.row)
  local activeValue = activeId and drive.values[activeId]
  local function profileNumber(value) return value ~= nil and tostring(value) or "?" end
  local group = drive.groups[drive.group]
  local groupRows = drive._groupRows
  -- Ground progress changes counters, not row values. Reuse their snapshot until a report,
  -- profile activation or group change actually changes what those rows display.
  if groupRows == nil or drive._rowsGroup ~= group or drive._rowsValues ~= drive.values
    or drive._rowsStart ~= drive.primedValues or drive._rowsReport ~= reportEpoch then
    groupRows = {}
    if group then
      for i = 1, #group.entries do
        local cell = group.entries[i]
        local value = drive.values[cell.id]
        local start = drive.primedValues and drive.primedValues[cell.id]
        groupRows[i] = { differenceText = start ~= nil and value ~= nil and value ~= start and string.format("%+d", value - start) or "", id = cell.id, name = cell.name, bank = cell.bank, row = cell.row,
          value = value, valueText = value ~= nil and tostring(math.floor(value + 0.5)) or "--" }
      end
    end
    drive._groupRows, drive._rowsGroup, drive._rowsValues = groupRows, group, drive.values
    drive._rowsStart, drive._rowsReport = drive.primedValues, reportEpoch
  end
  if drive._profileListSource ~= drive.sessionProfiles then
    drive._profileListSource = drive.sessionProfiles
    local names = {}
    for _, kind in ipairs({"pid", "rate"}) do
      local indices = {}
      for index = 1, 6 do
        if drive.sessionProfiles and drive.sessionProfiles[kind][index] then indices[#indices + 1] = tostring(index) end
      end
      names[#names + 1] = (kind == "pid" and "PID " or "RTE ") .. table.concat(indices, ",")
    end
    drive._profileListText = t("widgets.dashboard.inflight_read_profiles", "Read") .. " " .. table.concat(names, " / ")
  end
  local restoreSummary = {}
  if transfer and transfer.results and transfer.state ~= "busy" then
    for _, kind in ipairs({"pid", "rate", "global"}) do
      for index = 1, kind == "global" and 1 or 6 do
        local key = kind == "global" and "global" or kind .. index
        local result = transfer.results[key]
        if result then
          local label = kind == "global" and t("widgets.dashboard.inflight_global", "Global")
            or (kind == "pid" and "PID " or "RTE ") .. index
          restoreSummary[#restoreSummary + 1] = label .. ": " .. (result == "ok"
            and t("widgets.dashboard.inflight_result_ok", "OK") or t("widgets.dashboard.inflight_result_failed", "failed/pending"))
        end
      end
    end
  end
  state.inflight = {
    restoreSummary = table.concat(restoreSummary, "; "),
    epoch = epoch,
    -- The report counter travels beside the layout epoch so that the guard above reads one flat
    -- table. Nothing in the widget's render key may ever be derived from it.
    reportEpoch = reportEpoch,
    -- The model's setup check can refuse output. Its answer is on
    -- the snapshot because the widget decides from the snapshot alone which surface a pass
    -- belongs to, and a refusal has to reach a surface that can say so. A closing refused while
    -- the trims are being walked is that refusal too: its surface says the trims are being checked.
    setupFault = setupFault,
    setupVerdict = setupVerdict,
    live = drive.live,
    linkLost = drive.linkLost == true,
    -- Which of the three surfaces this is. It is on the snapshot AND in the widget's render key,
    -- because a phase change is a different screen and not a different number on the same one.
    phase = drive.phase,
    group = drive.group,
    entry = drive.entry,
    groups = drive.groups,
    groupRows = groupRows,
    valueMode = drive.valueMode,
    groupPicker = drive.groupPicker == true,
    -- Bumped by the encoder sensor before a ladder half runs out; part of the live scene key.
    ladderEpoch = drive.ladderEpoch,
    profilePaused = drive.profilePaused,
    profileRefusal = drive:profileRefusal(),
    restorePending = drive.restorePending,
    baseline = drive.baseline and drive.baseline.meta,
    profileText = t("widgets.dashboard.inflight_title", "TUNING") .. " PID " .. profileNumber(drive.profile)
      .. " / RTE " .. profileNumber(drive.rateProfile),
    pauseActive = t("widgets.dashboard.inflight_active_profiles", "Active PID / Rate") .. " "
      .. profileNumber(drive.profile) .. " / " .. profileNumber(drive.rateProfile),
    pauseSession = drive.baseline and drive._profileListText
      or t("widgets.dashboard.inflight_baseline_missing", "No complete SD baseline"),
    activeComparison = activeValue ~= nil and drive.primedValues and drive.primedValues[activeId] ~= nil
      and (t("widgets.dashboard.inflight_start", "Start") .. " " .. tostring(drive.primedValues[activeId])
        .. " / " .. string.format("%+d", activeValue - drive.primedValues[activeId])) or "",
    activeValueText = activeValue ~= nil and tostring(math.floor(activeValue + 0.5)) or "--",
    -- True exactly while a step control is held down. The widget reads it and leaves the render
    -- key alone while it is true; see M.release above for what a rebuild would cost here.
    holding = holding,
    bank = drive.bank,
    row = drive.row,
    activeId = activeId,
    activeName = activeId and Functions.shortName(activeId) or nil,
    stepRefusedReason = drive.stepRefusedReason,
    profile = drive.profile,
    rateProfile = drive.rateProfile,
    prime = primeState,
    -- The two scalars the guard above compares. They are the same numbers primeState carries; a
    -- copy of them sits here so that the guard reads one flat table rather than reaching into a
    -- nested one that may be nil.
    primePhase = primePhase,
    primeDone = primeDone,
    -- Which of the two layouts the rows above came from: the board's own slot table once the
    -- prime has read it, the documented one until then and whenever the board's yields nothing
    -- usable. It is on the screen because a set that silently fell back to the reference layout
    -- and a set that came off this board look exactly alike otherwise.
    setSource = drive.setSource,
    -- For the ground surface: how many cells the board offers, how many of them would jump on the
    -- first press, and whether the last read continued the stored session or started one.
    cellCount = drive.cellCount,
    boundsCount = drive.boundsCount,
    sessionMode = drive.sessionMode,
    readRequired = drive.readRequired,
    transfer = transferState
  }
end

--- One pass, called from the widget's background half.
-- Whether a ground read is between its first and last reply: phases other than idle, done and error.
local function primeBusy(drive)
  local phase = type(drive.prime) == "table" and drive.prime.phase or nil
  return phase ~= nil and phase ~= "idle" and phase ~= "done" and phase ~= "error"
end

function M.tick(widget, drive)
  drive = drive or M.get(widget)
  if drive == nil then return false end
  if drive.settings.active ~= true or drive.open ~= true then
    drive:evaluateInterlock(drive.radio.now(), false)
    if widget.state and widget.state.inflight ~= nil then widget.state.inflight = nil end
    return false
  end
  if drive.fcWorked then
    drive.fcWorked = nil
    publish(widget, drive)
    return false
  end
  local grouped = not drive.fcSetupOpen and drive:stepGroups()
  if widget.state and widget.state.armed == true
      and (drive.restoreConfirm or drive.sessionPickerOpen) then
    -- Ground dialogs close on arming, whether tuning is open or closed: nothing they offer may run
    -- while the model is armed.
    drive.restoreConfirm, drive.sessionPickerOpen, drive.sessionPick = nil, nil, nil
    drive.valueEpoch = drive.valueEpoch + 1
  end
  local state = widget.state
  local session = _G.rfsuite and _G.rfsuite.session
  local pending = drive.pendingSave
  if pending ~= nil and session and session.mcu_id ~= pending.mcu then
    -- Asked on another board: never written into this one's store.
    drive.pendingSave = nil
    if pending.steps and drive.fcSurface then drive.fcSurface.saved(widget, drive, false, "board_changed") end
  elseif pending ~= nil and not grouped and not primeBusy(drive)
      and drive.profileJob == nil and type(state) == "table" and state.armedSeen == true
      and state.armed ~= true then
    -- The model-default save on a pass that does nothing else (no group step, no profile job),
    -- with the model known to be disarmed: the store writer serialises the whole store.
    drive.pendingSave = nil
    local ok, err = M.saveFlightList(pending.list, pending.steps)
    drive.saveResult = ok and "ok" or tostring(err or "failed")
    drive.valueEpoch = drive.valueEpoch + 1
    if pending.steps and drive.fcSurface then drive.fcSurface.saved(widget, drive, ok, err) end
    publish(widget, drive)
    return false
  end
  if drive.fcSetupOpen then publish(widget, drive); return false end
  -- A setup fault refuses output and still publishes the fullscreen refusal.
  if type(M.verdict(drive)) == "table" then
    drive:evaluateInterlock(drive.radio.now())
    publish(widget, drive)
    return false
  end
  -- The two profile sensors, watched whether or not the overlay is up and gated on the link
  -- rather than on surface ownership: the pilot changes a profile with his own switch, at any time,
  -- and what the overlay believes about a value is only ever true of the profile it was read
  -- from. Two getValue calls on the widget's logic tick.
  if widget.state ~= nil and widget.state.fblConnected == true and drive.live ~= true then
    drive:watchProfiles()
  end
  local live = drive:tick(widget.state.armed == true)
  publish(widget, drive)
  return live == true
end

--- The fast half of a pass, called from the widget's FOREGROUND half on every pass.
--
-- The widget's background work runs on a 100 ms logic tick and a build pass skips it altogether,
-- which is the right cadence for reading telemetry into a dashboard and the wrong one for a
-- tuning surface: the pilot's own report is that the value lags and that a trim press often does
-- nothing. Both come off the same clock. So the two things that must not wait -- the board's
-- AdjF/AdjV report and the trims -- are polled here instead, at the firmware's own 50 ms widget
-- cadence, and everything else stays where it was.
--
-- Costs one table lookup and one boolean test unless the overlay is live, and never constructs a
-- drive: a widget that has not run the overlay this session has nothing to sample.
function M.sample(widget)
  if type(widget) ~= "table" then return false end
  local drive = widget._inflight
  if drive == nil or (drive.open ~= true and drive.live ~= true) then return false end
  if drive.live == true then drive:fastTick(drive.radio.now()) end
  publish(widget, drive)
  return drive.live == true
end

--- The held control let go, from a caller that is about to destroy the object which would have
-- reported the release itself.
--
-- EdgeTX raises a momentary button's release handler on LV_EVENT_RELEASED and on nothing else
-- (lua_lvgl_widget.cpp, MomentaryButton::customEventHandler), and an object that is deleted while
-- the finger is still down never receives that event. So a rebuild -- lvgl.clear() drops the whole
-- tree -- would take the release with it and leave the drive writing the row's magnitude with
-- nothing left in the world able to take it back. The rebuild path lets go here instead.
--
-- Answers whether there was a hold to let go, so a caller can tell the two cases apart.
function M.release(widget)
  if type(widget) ~= "table" then return false end
  local drive = widget._inflight
  if drive == nil or drive.holdRow == nil then return false end
  drive:release()
  return true
end

-- A link gap invalidates current readings even when the same board returns. The flight may
-- continue while armed, but its next ground pass must read the complete board again.
function Drive:invalidateRead()
  if not self.readRequired then
    self.readArmed = self.phase == M.PHASE_LIVE
    self.valueEpoch = self.valueEpoch + 1
  end
  self.readRequired, self.valuesRead, self.compare = true, nil, nil
  self._primeAutoDone, self._primeLinkSince, self._primeFails = false, nil, nil
  local session = _G.rfsuite and _G.rfsuite.session
  if session then session.inflightSlots = nil end
  if self.prime then self.prime.invalidated = true end
  if self.profileJob then self.profileJob.linkLost = true end
end

--- Revoke output during telemetry loss without advancing the flight phase from missing arm data.
function M.pause(widget)
  if type(widget) ~= "table" then return end
  local drive = widget._inflight
  if drive == nil then return end
  if not drive.linkLost then drive:invalidateRead() end
  drive:evaluateInterlock(drive.radio.now(), false)
  if drive.fcSurface then drive.fcSurface.close(widget, drive) end
  drive.valueMode = false
  drive.groupPicker = nil
  drive.linkLost = true
  -- No report fence here. A report held across the gap belongs to the profile it was taken in, and
  -- a profile that changed during the gap is fenced by watchProfiles on its own edge. A fence that
  -- waits for AdjF to read 0 would refuse every step for as long as the board sends no fresh 0.
  publish(widget, drive)
end

--- Revoke surface ownership without ending the flight or its post-flight comparison.
function M.cleanup(widget)
  if type(widget) ~= "table" then return end
  local drive = widget._inflight
  if drive == nil then return end
  drive:evaluateInterlock(drive.radio.now(), false)
  if drive.fcSurface then drive.fcSurface.close(widget, drive) end
  drive.valueMode = false
  drive.groupPicker = nil
  drive.linkLost = nil
  -- Observe landing even while closed. Reopening during this flight keeps PHASE_LIVE and
  -- its selection; entering it from ground/post on the next arming starts at the first entry.
  if drive.phase == M.PHASE_LIVE and widget.state and widget.state.armed == false then
    drive:setPhase(drive.fired > 0 and M.PHASE_POST or M.PHASE_GROUND)
    drive:forgetVerdict()
  end
  if widget.state then widget.state.inflight = nil end
end

M.Drive = Drive

return M
