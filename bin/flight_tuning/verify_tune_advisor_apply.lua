-- The Tune Advisor page: its advice and its Save.
--
-- Run from the repository root:
--     lua5.3 bin/flight_tuning/verify_tune_advisor_apply.lua
--
-- Drives the real src/rfsuite/app/pages/flight_tuning/tune_advisor/page.lua through its own
-- build, wakeup, getSaveConfirm and onSave, with the real lib/tune_history.lua (the flights are
-- saved to the card through it), lib/change_journal.lua, lib/atomic_file.lua,
-- tasks/msp/save_pipeline.lua and the MSP codecs of tasks/msp/api/. A scripted flight controller
-- answers MSP_STATUS, MSP_PID_TUNING, MSP_PID_PROFILE and MSP_RC_TUNING from those codecs'
-- simulator replies and takes their writes; the card is in memory. Stubbed: the MSP runtime's
-- state and queue, the controls (they record what the page draws), the profile source, the
-- confirm dialog and the logger.
--
-- The cases under "Ethos suite" are the Ethos suite's bin/tune_advisor_apply/
-- verify_tune_advisor_apply.lua at commit 098da94426, with the same names, inputs and expected
-- results. The saved flight is one flight of the simulator's Tune Advisor reply, flown on the
-- profile and settings the other simulator replies describe. Where this suite's page differs in
-- form, the check reads the same thing in this suite's terms:
-- - the confirm dialog is getSaveConfirm()'s message; "each stage is shown" is the page's status
--   line (reading, checking) and the save pipeline's write and commit phases; "the progress
--   dialog closes" is the status line gone and the pipeline idle with no notice left;
-- - the Apply record is the change journal; Ethos's changes.csv rows are journal entries of the
--   Tune Advisor on the flights' PID profile;
-- - a read-back that differs is reported with the field that differs (save_differs);
-- - "the last flight is being read" is the flight capture's state in the session table, which a
--   tool opened from the dashboard shares with the capture.
-- Ethos's four pilotValue cases are in bin/flight_tuning/verify_tune_history.lua, against the
-- library function itself.
--
-- "The shake rule" carries the rule cases of an earlier check of this page (payload version 2,
-- read by polling). Its payload cases are bin/flight_tuning/verify_tune_advisor_payload.lua's;
-- its case of a shake crossing 15 deg/s between two polls has no counterpart, since the page
-- now combines saved flights instead of polling.
--
-- "Differences from the Ethos suite" pins where this page's advice is not the Ethos suite's on
-- purpose; "From the review" and "The shake rule" pin cases found in review of earlier versions.
--
-- Against a tree without lib/tune_history.lua this script stops at the first load: red.

local failures, checks = 0, 0
local function check(label, ok, detail)
  checks = checks + 1
  if ok then
    print("  ok    " .. label)
  else
    failures = failures + 1
    print("FAIL " .. label)
    if detail ~= nil then print("        " .. tostring(detail)) end
  end
end

local ROOT = "src/rfsuite/"
local MCU = "abc123"
local PAGE_PATH = "app/pages/flight_tuning/tune_advisor/page.lua"
local PIPELINE_PATH = "tasks/msp/save_pipeline.lua"

-- ---------------------------------------------------------------------------
-- The card: an in-memory filesystem answering the radio's io/fstat/mkdir/rename/del.
-- ---------------------------------------------------------------------------
-- luacheck: globals io
local files = {}
local openFails = {}           -- path -> true: opening it for reading answers nil
io.open = function(path, mode)
  mode = mode or "r"
  local m = string.sub(mode, 1, 1)
  if m == "r" then
    if files[path] == nil or openFails[path] then return nil end
    return { path = path, pos = 1 }
  end
  if m == "w" then files[path] = "" end
  if m == "a" and files[path] == nil then files[path] = "" end
  return { path = path }
end
io.read = function(f, n)
  local data = files[f.path] or ""
  if f.pos > #data then return "" end
  local chunk = string.sub(data, f.pos, f.pos + n - 1)
  f.pos = f.pos + #chunk
  return chunk
end
io.write = function(f, ...)
  for i = 1, select("#", ...) do files[f.path] = files[f.path] .. tostring((select(i, ...))) end
  return f
end
io.close = function() return true end
io.seek = function(f, at) f.pos = at + 1 end
function fstat(path)
  if files[path] == nil then return nil end
  return { size = #files[path] }
end
function mkdir() return 0 end
function del(path) files[path] = nil; return 0 end
function rename(from, to)
  if files[from] == nil or files[to] ~= nil then return 8 end
  files[to], files[from] = files[from], nil
  return 0
end

SMLSIZE, RIGHT = 1, 2
local ticks = 1000
function getTime() return ticks end
_G.getRtcTime = function() return 1761900000 end

-- ---------------------------------------------------------------------------
-- The radio side: session, MSP state and queue, profile source, controls.
-- ---------------------------------------------------------------------------
local mspState = { lastConnected = true, lastArmed = false }
local queue = { entries = {} }
function queue:add(entry) self.entries[#self.entries + 1] = entry; return true end
function queue.isProcessed() return #queue.entries == 0 end
mspState.queue = queue

_G.rfsuite = { palette = { text = 0, border = 0 }, session = { mcu_id = MCU } }

local profiles = { pid = 1, rate = 1 }
local dialogs = {}
local axisSetter = nil

local stubs = {
  ["app/pages/settings/common.lua"] = {
    pageT = function() return function(_, _, fallback) return fallback end end,
    resetPageState = assert(loadfile(ROOT .. "app/pages/settings/common.lua"))().resetPageState
  },
  ["ui/controls.lua"] = {
    ROW_H = 40, LABEL_H = 21, STATIC_SECTION_H = 38,
    labelY = function(y) return y + 10 end,
    appendStaticSectionHeader = function(children, _, _, _, title)
      children[#children + 1] = { type = "label", text = title }
    end,
    appendComboSelect = function(children, _, _, _, label, _, _, setter)
      children[#children + 1] = { type = "label", text = label }
      axisSetter = setter
      return 40
    end
  },
  ["ui/confirm_dialog.lua"] = { show = function(d) dialogs[#dialogs + 1] = d; return true end },
  ["lib/profile.lua"] = {
    getActivePidProfile = function() return profiles.pid end,
    getActiveRateProfile = function() return profiles.rate end
  },
  ["tasks/msp/runtime.lua"] = { getState = function() return mspState end },
  ["tasks/msp/cache.lua"] = { clear = function() end },
  ["lib/armed.lua"] = { isArmed = function() return mspState.lastArmed == true end },
  ["lib/log.lua"] = { emit = function() end, emitf = function() end },
  ["tasks/events/runtime.lua"] = {},
  ["tasks/msp/api/reboot.lua"] = {},
  ["tasks/msp/api/tx_info.lua"] = {},
}
local real = {
  [PAGE_PATH] = true, [PIPELINE_PATH] = true,
  ["lib/tune_history.lua"] = true, ["lib/change_journal.lua"] = true, ["lib/atomic_file.lua"] = true,
  ["lib/api_version.lua"] = true,
  ["tasks/msp/api/tune_advisor.lua"] = true, ["tasks/msp/api/status.lua"] = true,
  ["tasks/msp/api/pid_tuning.lua"] = true, ["tasks/msp/api/pid_profile.lua"] = true,
  ["tasks/msp/api/rc_tuning.lua"] = true, ["tasks/msp/api/eeprom_write.lua"] = true,
}
function loadScript(path)
  local relative = string.match(path, "^/SCRIPTS/TOOLS/rfsuite%-core/(.+)$")
  if stubs[relative] then local mod = stubs[relative]; return function() return mod end end
  assert(real[relative], "unexpected module: " .. tostring(path))
  return assert(loadfile(ROOT .. relative))
end


local Api = assert(loadfile(ROOT .. "tasks/msp/api/tune_advisor.lua"))()
local TuneHistory = assert(loadfile(ROOT .. "lib/tune_history.lua"))()
local Journal = assert(loadfile(ROOT .. "lib/change_journal.lua"))()
local codecs = {
  status = assert(loadfile(ROOT .. "tasks/msp/api/status.lua"))(),
  tuning = assert(loadfile(ROOT .. "tasks/msp/api/pid_tuning.lua"))(),
  profile = assert(loadfile(ROOT .. "tasks/msp/api/pid_profile.lua"))(),
  rates = assert(loadfile(ROOT .. "tasks/msp/api/rc_tuning.lua"))(),
}
local EEPROM = 250
local BY_READ = { [codecs.tuning.command] = "tuning", [codecs.profile.command] = "profile", [codecs.rates.command] = "rates" }
local BY_WRITE = { [codecs.tuning.writeCommand] = "tuning", [codecs.profile.writeCommand] = "profile",
  [codecs.rates.writeCommand] = "rates" }

-- ---------------------------------------------------------------------------
-- The flight controller: each codec's simulator reply, decoded.
-- ---------------------------------------------------------------------------
local fc
local function resetFc()
  fc = {}
  for key, codec in pairs(codecs) do
    if key ~= "status" then fc[key] = assert(codec.parse(codec.simulatorResponse)) end
  end
end
local function statusReply()
  local buf = {}
  for i, b in ipairs(codecs.status.simulatorResponse) do buf[i] = b end
  buf[24], buf[26] = profiles.pid - 1, profiles.rate - 1
  return buf
end

-- ---------------------------------------------------------------------------
-- The saved flights. One flight of the simulator's Tune Advisor reply, flown on profile 1 / 1
-- with the simulator's cyclic polarity, cyclic ring and I-term relax type. Overrides per axis.
-- ---------------------------------------------------------------------------
local flightRatesType = nil       -- overrides the fixture's rates_type on every axis when set
local flightRollShake = nil       -- overrides roll's shake (deg/s) when set
local flightRoll = nil            -- fields overriding the fixture's roll axis when set
local flightAxes = {}             -- axis -> fields overriding it (Differences)
local flightContext = nil         -- overrides the context the flight was saved with

local function baseContext()
  return { pidProfile = 1, rateProfile = 1, cyclicPolarity = fc.rates.cyclic_polarity,
    cyclicRing = fc.rates.cyclic_ring, relaxType = fc.profile.iterm_relax_type }
end

local function saveFlight()
  local replies = {}
  for axis = 1, 3 do
    local d = assert(Api.parse(Api.simulatorResponseFor(axis)))
    if flightRatesType then d.a.ratesType = flightRatesType end
    if flightRoll and axis == 1 then for k, v in pairs(flightRoll) do d.a[k] = v end end
    if flightAxes[axis] then for k, v in pairs(flightAxes[axis]) do d.a[k] = v end end
    if flightRollShake and axis == 1 then d.a.shakeRms = flightRollShake end
    replies[axis] = d
  end
  local ctx = baseContext()
  for k, v in pairs(flightContext or {}) do ctx[k] = v end
  if flightContext and flightContext.unknownProfile then ctx.pidProfile, ctx.rateProfile = nil, nil end
  assert(TuneHistory.save(MCU, replies, ctx, 1761800000), "the flight could not be saved")
end

local function clearCard()
  for k in pairs(files) do files[k] = nil end
end

-- Journal entries of this suite's change journal: {source, profile, field, old, new}
local function journal(entries)
  local path = Journal.path(MCU)
  files[path] = nil
  if #entries > 0 then assert(Journal.append(MCU, entries), "journal append failed") end
end

-- ---------------------------------------------------------------------------
-- The page, the pipeline and the passes.
-- ---------------------------------------------------------------------------
local Page = assert(loadfile(ROOT .. PAGE_PATH))()
local Pipeline = assert(loadfile(ROOT .. PIPELINE_PATH))()
local ui
for i = 1, 40 do
  local name, value = debug.getupvalue(Page.canSave, i)
  if name == "ui" then ui = value; break end
  if not name then break end
end
assert(ui, "page state not found")

local wantBuild = false
local children = {}
local reports = {}
local seen = { statuses = {}, phases = {} }
local ctx = {
  x = 0, y = 0, w = 800, h = 480, children = children,
  requestRebuild = function() wantBuild = true end,
  reportSave = function(r) reports[#reports + 1] = r end,
}
local opened = false

local function build()
  for i = #children, 1, -1 do children[i] = nil end
  wantBuild = false
  Page.build(ctx)
end

local function note()
  if ui.status then seen.statuses[ui.status] = true end
  local progress = Pipeline.getProgress()
  if progress and progress.phase then seen.phases[progress.phase] = true end
end

-- One pass as the tool makes it: a build when one was asked for, the page's wakeup, the
-- pipeline's wakeup, then the flight controller answers the oldest request.
local function pass(reply, sent)
  ticks = ticks + 5
  if wantBuild then build() end
  Page.wakeup(ctx)
  Pipeline.wakeup()
  note()
  local m = table.remove(queue.entries, 1)
  if not m then return false end
  sent[#sent + 1] = m.command
  local custom = reply and reply(m)
  if custom == "error" then
    if m.errorHandler then m.errorHandler(m, "timeout") end
  elseif type(custom) == "table" then
    m.processReply(m, custom)
  elseif custom == "handled" then
    return true                   -- the reply function answered it itself
  elseif m.command == Api.command then
    m.processReply(m, Api.simulatorResponseFor(1))
  elseif m.command == Api.writeCommand or m.command == EEPROM then
    m.processReply(m, {})
  elseif m.command == codecs.status.command then
    m.processReply(m, statusReply())
  elseif BY_READ[m.command] then
    local key = BY_READ[m.command]
    m.processReply(m, codecs[key].buildWritePayload(fc[key]))
  elseif BY_WRITE[m.command] then
    local key = BY_WRITE[m.command]
    fc[key] = assert(codecs[key].parse(m.payload))
    m.processReply(m, {})
  else
    error("unscripted command " .. tostring(m.command))
  end
  note()
  return true
end

local function pump(reply)
  local sent = {}
  local quiet = 0
  for _ = 1, 400 do
    local busy = pass(reply, sent)
    local idle = not busy and ui.loadStep == nil and not ui.probeOwed and not ui.applying and not wantBuild
    quiet = idle and quiet + 1 or 0
    if quiet >= 3 then break end
  end
  return sent
end

-- A new visit of the page, on the flights saved by saveFlight()
local function openPage(noSave)
  if opened then Page.onClose() end
  if not noSave then
    files[TuneHistory.path(MCU)] = nil
    saveFlight()
  end
  queue.entries = {}
  build()
  opened = true
  pump()
end

local function canSave() return Page.canSave() == true end

local function lineCount(s)
  local n = 0
  for _ in string.gmatch(s, "[^\n]+") do n = n + 1 end
  return n
end

local function has(list, value)
  for _, v in ipairs(list) do if v == value then return true end end
  return false
end

local function contains(list, needle)
  for _, s in ipairs(list or {}) do
    if type(s) == "string" and string.find(s, needle, 1, true) then return true end
  end
  return false
end

local function shown(needle)
  for _, c in ipairs(children) do
    if c.type == "label" and type(c.text) == "string" and string.find(c.text, needle, 1, true) then return true end
  end
  return false
end

local function lastReport()
  return reports[#reports] or {}
end

local function snapshot()
  local out = {}
  for key, record in pairs(fc) do
    out[key] = {}
    for k, v in pairs(record) do out[key][k] = v end
  end
  return out
end

local function changedFields(before)
  local out = {}
  for key, record in pairs(before) do
    for k, v in pairs(record) do
      if fc[key][k] ~= v then out[#out + 1] = k end
    end
  end
  table.sort(out)
  return table.concat(out, ",")
end

-- Save, confirmed: the confirm text, then the save driven to its end
local function applyNow(reply)
  local confirm = Page.getSaveConfirm(ctx)
  if not confirm then return {}, nil end
  Page.onSave(ctx)
  return pump(reply), confirm
end

local function T() return ui.text end

local function resetFlights()
  flightRatesType, flightRollShake, flightRoll, flightContext = nil, nil, nil, nil
  flightAxes = {}
end

clearCard()
resetFc()

print("Ethos suite: Apply writes only the advised fields")
do
  resetFc()
  openPage()
  check("Save is enabled with changes to make", canSave())
  local before = snapshot()
  local sent, confirm = applyNow()
  check("the confirm dialog lists F and both rates and asks", confirm ~= nil and lineCount(confirm.message) == 4
    and string.find(confirm.message, T().saveQuestion, 1, true) ~= nil, confirm and confirm.message)
  check("roll F and both rates reach the FC", fc.tuning.pid_0_F == 96 and fc.rates.rcRates_1 == 23
    and fc.rates.rates_1 == 30, "F " .. tostring(fc.tuning.pid_0_F) .. ", rates " .. tostring(fc.rates.rcRates_1)
    .. "/" .. tostring(fc.rates.rates_1))
  check("no other field changes", changedFields(before) == "pid_0_F,rates_1,rcRates_1", changedFields(before))
  check("only the messages holding a change are written", has(sent, codecs.tuning.writeCommand)
    and has(sent, codecs.rates.writeCommand) and not has(sent, codecs.profile.writeCommand), table.concat(sent, ","))
  check("the write is committed, then read back", has(sent, EEPROM) and sent[#sent] == codecs.rates.command,
    table.concat(sent, ","))
  check("each stage is shown", seen.statuses[T().reading] and seen.phases.write and seen.phases.commit
    and seen.statuses[T().checking])
  check("the progress dialog closes", ui.status == nil and not Pipeline.isActive() and not Pipeline.hasOutcome())
  check("success is reported", lastReport().ok == true and lastReport().message == string.format(T().saved, 3),
    lastReport().message)
  local entries = Journal.read(MCU) or {}
  check("the change is logged with its old value", #entries == 3 and entries[1].source == "tune_advisor"
    and entries[1].field == "pid_0_F" and entries[1].old == 120 and entries[1].new == 96 and entries[1].profile == 1)
  check("Save is disabled once applied", not canSave() and ui.view.actions[1] == T().applied)
end

print("Ethos suite: A tune changed since the flights is never overwritten")
do
  openPage(true)                  -- the same flights, but the FC holds F 96 now
  local before = snapshot()
  local sent = applyNow()
  check("nothing is written", changedFields(before) == "" and not has(sent, codecs.tuning.writeCommand)
    and not has(sent, EEPROM), table.concat(sent, ","))
  check("the pilot is told why", lastReport().message == T().changed, lastReport().message)
  journal({})
end

print("Ethos suite: A profile switch during the reads stops it")
do
  resetFc()
  openPage()
  local before = snapshot()
  local sent = applyNow(function(m)
    if m.command == codecs.rates.command then profiles.pid = 2 end
  end)
  profiles.pid = 1
  check("nothing is written", changedFields(before) == "" and not has(sent, EEPROM), table.concat(sent, ","))
  check("reported as changed settings", lastReport().message == T().changed, lastReport().message)
end

print("Ethos suite: A failed or short read writes nothing")
do
  resetFc()
  openPage()
  local before = snapshot()
  local sent = applyNow(function(m) if m.command == codecs.rates.command then return "error" end end)
  check("a read error writes nothing", changedFields(before) == "" and not has(sent, codecs.tuning.writeCommand),
    table.concat(sent, ","))
  check("a read error is reported", lastReport().message == T().readFailed, lastReport().message)

  -- a short reply must not pass as a tune of zeros
  sent = applyNow(function(m) if m.command == codecs.tuning.command then return { 105, 0, 45 } end end)
  check("a short read writes nothing", changedFields(before) == "" and not has(sent, codecs.tuning.writeCommand),
    table.concat(sent, ","))
  check("a short read is reported as a failed read", lastReport().message == T().readFailed, lastReport().message)
end

print("Ethos suite: A failed write is never committed")
do
  resetFc()
  openPage()
  local sent = applyNow(function(m) if m.command == codecs.rates.writeCommand then return "error" end end)
  check("no EEPROM commit after a failed write", not has(sent, EEPROM), table.concat(sent, ","))
  check("the failed write is reported", lastReport().message == T().writeFailed, lastReport().message)
  check("after a failed write the advice is still shown, not marked as saved", ui.view.actions[1] ~= T().applied
    and #ui.view.changes == 3 and canSave(), ui.view.actions[1])
  journal({})
end

print("Ethos suite: A read-back that differs is reported")
do
  resetFc()
  openPage()
  applyNow(function(m)
    if m.command == codecs.tuning.writeCommand then
      m.processReply(m, {})       -- the FC acks but keeps its value
      return "handled"
    end
  end)
  check("reported as unconfirmed", lastReport().ok == false
    and lastReport().message == string.format(T().differs, "pid_0_F"), lastReport().message)
  journal({})
end

print("Ethos suite: Armed or offline, Save is unavailable")
do
  resetFc()
  openPage()
  mspState.lastArmed = true
  pump()
  check("disabled while armed", not canSave())
  mspState.lastArmed, mspState.lastConnected = false, false
  pump()
  check("disabled while the link is down", not canSave())
  -- The next connection reads the flight controller's id again; until then the session has none
  _G.rfsuite.session.mcu_id = nil
  pump()
  check("a link loss keeps the saved flights' advice on screen", shown("2m 27s, 1/5 flights")
    and #ui.view.changes == 3, ui.view.data)
  _G.rfsuite.session.mcu_id = MCU
  mspState.lastConnected = true
end

print("Ethos suite: While the last flight is being read, Save and erase wait")
do
  resetFc()
  openPage()
  _G.rfsuite.session.tuneCapture = { state = "reading", saved = 0 }
  pump()
  check("Save is disabled while reading", not canSave())
  check("erase is disabled while reading", Page.getHeaderActions().star == false)
  _G.rfsuite.session.tuneCapture.state = "idle"
  pump()
  check("Save comes back once the flight is in", canSave())
  check("erase comes back once the flight is in", Page.getHeaderActions().star == true)
  _G.rfsuite.session.tuneCapture.state = "failed"
  pump()
  check("a failed read leaves Save available on the saved flights", canSave())
  _G.rfsuite.session.tuneCapture = nil
end

print("Ethos suite: F is never applied without its rates")
do
  -- Betaflight rates: the rate change can only be given as a percentage
  local BETAFLIGHT = 1
  resetFc()
  fc.rates.rates_type = BETAFLIGHT
  flightRatesType = BETAFLIGHT
  openPage()
  check("nothing to apply when the rates can only be a percentage", not canSave())
  resetFlights()
end

print("Ethos suite: A shaking axis gets less P and nothing else")
do
  resetFc()
  flightRollShake = 49            -- the issue log's roll
  openPage()
  local before = snapshot()
  local _, confirm = applyNow()
  check("the confirm dialog lists P alone", confirm ~= nil and lineCount(confirm.message) == 2, confirm and confirm.message)
  check("roll P goes down one step", fc.tuning.pid_0_P == 58, "P " .. tostring(fc.tuning.pid_0_P))
  check("F and the rates are left for after the shake", changedFields(before) == "pid_0_P", changedFields(before))
  journal({})
  resetFc()
  flightRollShake = 14            -- below the shake limit: F and its rates as before
  openPage()
  _, confirm = applyNow()
  check("a calm axis gets its usual advice", confirm ~= nil and lineCount(confirm.message) == 4, confirm and confirm.message)
  resetFlights()
  journal({})
end

print("Ethos suite: Advice past a setting's limit is not given")
do
  -- Max rate 220: F 120 -> 96 would need it at 275, past the FC's 255
  resetFc()
  fc.rates.rates_1 = 220
  flightRoll = { sRate = 220 }
  openPage()
  check("neither F nor the rates are offered", not canSave())
  resetFlights()
end

print("Ethos suite: A full-stick rate cut is limited to one step")
do
  -- The response matches, but full stick reaches 100 of the 240 deg/s asked:
  -- the rates come down 20%, not to 100
  resetFc()
  flightRoll = { ffGain = 1.0, fullCount = 200, fullSatCount = 200, fullMaxRate = 100 }
  openPage()
  applyNow()
  check("the rates drop by 20%", fc.rates.rcRates_1 == 14 and fc.rates.rates_1 == 19,
    tostring(fc.rates.rcRates_1) .. "/" .. tostring(fc.rates.rates_1))
  check("F is left alone", fc.tuning.pid_0_F == 120, tostring(fc.tuning.pid_0_F))
  resetFlights()
  journal({})
end

print("Ethos suite: F is not offered when its rates round back to the same values")
do
  -- Centre sensitivity 1 and max rate 0: x1.25 rounds to 1 and 0 again
  resetFc()
  flightRoll = { rcRate = 1, sRate = 0 }
  openPage()
  check("no F change without a rate change", not canSave())
  resetFlights()
end

print("Ethos suite: P is raised at most 50% above the pilot's own P")
do
  -- The response matches and stops bounce back 20% with no I-term push: more P
  local bouncy = { ffGain = 1.0, fullCount = 0, releases = 20, meanRebound = 0.2, meanIterm = 0 }

  resetFc()
  flightRoll = bouncy
  journal({})
  openPage()
  local before = snapshot()
  applyNow()
  check("with no Apply record, P 70 -> 84", fc.tuning.pid_0_P == 84 and changedFields(before) == "pid_0_P",
    tostring(fc.tuning.pid_0_P) .. " " .. changedFields(before))

  -- The page raised the pilot's 50 twice already: 84 would be past 75
  resetFc()
  journal({
    { source = "tune_advisor", profile = 1, field = "pid_0_P", old = 50, new = 60 },
    { source = "tune_advisor", profile = 1, field = "pid_1_P", old = 50, new = 60 },
    { source = "tune_advisor", profile = 1, field = "pid_0_P", old = 60, new = 70 },
  })
  openPage()
  check("no more P past 1.5x the pilot's own", not canSave())

  -- The pilot set 70 by hand after the page's 50 -> 60: 70 is the pilot's own
  resetFc()
  journal({ { source = "tune_advisor", profile = 1, field = "pid_0_P", old = 50, new = 60 } })
  openPage()
  check("a P set by hand starts again from that P", canSave())
  journal({})
  resetFlights()
end

-- ---------------------------------------------------------------------------
print("Differences from the Ethos suite: the cyclic ring (#878)")
-- ---------------------------------------------------------------------------
do
  -- Full stick asks 240 deg/s; a ring of 60 % holds one axis at 144 (firmware flight/setpoint.c,
  -- ringLimit = curve(1) * ring / 100). The heli reaches 160, more than 80 % of 144.
  -- Stops settle (5% bounce-back), so nothing but the full-stick rule can change a setting.
  local full = { ffGain = 1.0, fullCount = 200, fullSatCount = 200, fullMaxRate = 160, meanRebound = 0.05 }
  resetFc()
  fc.rates.cyclic_ring = 60
  flightRoll = full
  openPage()
  check("a heli that reaches 80% of what the ring gives full stick gets no rate cut", not canSave()
    and #ui.view.changes == 0, table.concat(ui.view.actions, " | "))

  resetFc()
  flightRoll = full               -- control: ring 150 does not hold one axis
  openPage()
  check("the same flight at a ring of 150% gets the rate cut", canSave()
    and contains(ui.view.whys, string.format(T().whyFullFmt, 240, 160)), table.concat(ui.view.whys, " | "))

  resetFc()
  fc.rates.cyclic_ring = 60
  flightRoll = { ffGain = 1.0, fullCount = 200, fullSatCount = 200, fullMaxRate = 100, meanRebound = 0.05 }
  openPage()
  check("short of what the ring gives: one step, and the reason names the rate full stick is given",
    canSave() and contains(ui.view.whys, string.format(T().whyFullFmt, 144, 100)), table.concat(ui.view.whys, " | "))
  local sent = applyNow(function(m)
    if m.command == codecs.rates.command then fc.rates.cyclic_ring = 150 end
  end)
  check("a ring changed before the save is refused", not has(sent, EEPROM)
    and lastReport().message == T().changed, lastReport().message)

  -- Polar cyclic: the ring holds the Pitch curve (setpoint.c, rate = min(curve_pitch(dist), ringLimit))
  resetFc()
  fc.rates.cyclic_ring, fc.rates.cyclic_polarity = 60, 1
  flightRoll = full
  openPage()
  check("under polar cyclic the ring is applied to the Pitch curve", not canSave() and #ui.view.changes == 0,
    table.concat(ui.view.actions, " | "))
  resetFc()
  fc.rates.cyclic_polarity = 1    -- control: polar cyclic at a ring of 150
  openPage()
  check("under polar cyclic at a ring of 150% the Cyclic rates are cut", canSave()
    and contains(ui.view.actions, T().ratesCyclic), table.concat(ui.view.actions, " | "))
  resetFlights()
  journal({})
end

print("Differences from the Ethos suite: the pilot's own P (#980)")
do
  local bouncy = { ffGain = 1.0, fullCount = 0, releases = 20, meanRebound = 0.2, meanIterm = 0 }
  resetFc()
  flightRoll = bouncy
  -- The same two raises, on PID profile 2: not this profile's history
  journal({
    { source = "tune_advisor", profile = 2, field = "pid_0_P", old = 50, new = 60 },
    { source = "tune_advisor", profile = 2, field = "pid_0_P", old = 60, new = 70 },
  })
  openPage()
  check("advice on another PID profile is not followed: P 70 is the pilot's", canSave())

  -- A hand edit on the PIDs page after the advisor's raise: the edit is the pilot's P
  journal({
    { source = "tune_advisor", profile = 1, field = "pid_0_P", old = 50, new = 60 },
    { source = "pids", profile = 1, field = "pid_0_P", old = 60, new = 70 },
  })
  openPage()
  check("an entry from another page ends the walk: P 70 is the pilot's", canSave())

  journal({
    { source = "tune_advisor", profile = 1, field = "pid_0_P", old = 50, new = 60 },
    { source = "tune_advisor", profile = 1, field = "pid_0_P", old = 60, new = 70 },
  })
  openPage()
  check("control: the advisor's own raises on this profile cap it", not canSave()
    and contains(ui.view.whys, string.format(T().whyPMaxFmt, 40)), table.concat(ui.view.whys, " | "))

  -- The same journal, but it cannot be read: the pilot's own P cannot be told, so P is not
  -- raised at all, and the page says why. (No journal at all is no record: the Ethos case
  -- "with no Apply record, P 70 -> 84".)
  openFails[Journal.path(MCU)] = true
  openPage()
  check("a change journal that cannot be opened raises no P, and says so", not canSave()
    and contains(ui.view.whys, T().whyJournalUnread) and not contains(ui.view.actions, "->"),
    table.concat(ui.view.whys, " | "))
  openFails[Journal.path(MCU)] = nil
  files[Journal.path(MCU)] = string.rep('e(1761900000,"pids",1,"pid_2_P",1,2)\n', 2000)
  openPage()
  check("nor does one over its read cap", #files[Journal.path(MCU)] > 65536 and not canSave()
    and contains(ui.view.whys, T().whyJournalUnread), table.concat(ui.view.whys, " | "))

  -- A long journal (a thousand entries, about 40 kB) is read over many passes, and the walk
  -- still finds the advisor's own raises at its end
  local long = {}
  for i = 1, 998 do
    long[i] = string.format('e(%d,"pids",1,"pid_%d_F",%d,%d)', 1761800000 + i, i % 3, 100 + i % 7, 90 + i % 5)
  end
  long[#long + 1] = 'e(1761801000,"tune_advisor",1,"pid_0_P",50,60)'
  long[#long + 1] = 'e(1761801001,"tune_advisor",1,"pid_0_P",60,70)'
  files[Journal.path(MCU)] = table.concat(long, "\n") .. "\n"
  Page.onClose()
  opened = false
  files[TuneHistory.path(MCU)] = nil
  saveFlight()
  queue.entries = {}
  build()
  opened = true
  local journalPasses = 0
  for _ = 1, 200 do
    if ui.loadStep == "journal" then journalPasses = journalPasses + 1 end
    pass(nil, {})
  end
  check("a long journal is read over many passes and still caps P", journalPasses >= 30
    and not canSave() and contains(ui.view.whys, string.format(T().whyPMaxFmt, 40)),
    journalPasses .. " passes; " .. table.concat(ui.view.whys, " | "))
  journal({})
  resetFlights()
end

print("Differences from the Ethos suite: polar cyclic rate limits (#981)")
do
  -- Roll's own max rate 220 would need 275; under polar cyclic the flight controller uses the
  -- Pitch rates (24), which have room
  resetFc()
  fc.rates.rates_1, fc.rates.cyclic_polarity = 220, 1
  flightRoll = { sRate = 220 }
  openPage()
  check("F and the Cyclic rates are offered", canSave()
    and contains(ui.view.actions, T().ratesCyclic), table.concat(ui.view.actions, " | "))
  local before = snapshot()
  applyNow()
  check("the Pitch rate bytes are written, the Roll bytes left", changedFields(before) == "pid_0_F,rates_2,rcRates_2"
    and fc.rates.rcRates_2 == 23 and fc.rates.rates_2 == 30 and fc.rates.rates_1 == 220, changedFields(before))
  journal({})

  resetFc()
  fc.rates.rates_2, fc.rates.cyclic_polarity = 220, 1
  flightAxes[2] = { sRate = 220 }
  openPage()
  check("roll under polar cyclic is refused when the Pitch rates have no room", not canSave()
    and contains(ui.view.whys, T().whyLimit), table.concat(ui.view.whys, " | "))
  resetFlights()

  resetFc()
  openPage()
  fc.rates.cyclic_polarity = 1
  local sent = applyNow()
  check("polar cyclic switched on after the flights is refused", not has(sent, EEPROM)
    and lastReport().message == T().changed, lastReport().message)
end

print("Differences from the Ethos suite: I-term relax type (#983)")
do
  -- Stops bounce back 20% with the I-term pushing: Ethos lowers the cut-off 10 -> 8
  local pushing = { ffCount = 1500, ffCorr = 0.97, ffGain = 1.0, fullCount = 0, releases = 20,
    meanRebound = 0.2, meanIterm = 0.05, relaxCutoff = 10, shakeRms = 1 }
  resetFc()
  fc.profile.iterm_relax_type = 0
  flightRoll = pushing
  openPage()
  check("relax OFF: no cut-off advice on roll", not canSave() and not contains(ui.view.actions, "->"),
    table.concat(ui.view.actions, " | "))
  check("relax OFF: the reason says relax is off for this axis", contains(ui.view.whys, T().whyRelaxOff),
    table.concat(ui.view.whys, " | "))
  resetFlights()

  resetFc()
  fc.profile.iterm_relax_type = 1
  flightAxes[3] = pushing
  openPage()
  axisSetter(3)
  check("relax RP: no cut-off advice on yaw", not canSave() and contains(ui.view.whys, T().whyRelaxOff),
    table.concat(ui.view.whys, " | "))

  resetFc()                       -- control: RPY covers yaw
  openPage()
  axisSetter(3)
  check("relax RPY: yaw gets the cut-off advice", canSave(), table.concat(ui.view.actions, " | "))
  local before = snapshot()
  applyNow()
  check("relax RPY: yaw's cut-off is written", changedFields(before) == "iterm_relax_cutoff_2"
    and fc.profile.iterm_relax_cutoff_2 == 8, changedFields(before))
  journal({})

  resetFc()
  openPage()
  axisSetter(3)
  local sent = applyNow(function(m)
    if m.command == codecs.profile.command then fc.profile.iterm_relax_type = 1 end
  end)
  check("relax type changed to RP before the save: the cut-off is not written", not has(sent, EEPROM)
    and lastReport().message == T().changed, lastReport().message)
  resetFlights()
end

print("Differences from the Ethos suite: a shake with no P step (#985)")
do
  resetFc()
  flightRoll = { P = 1, shakeRms = 49, ffGain = 1.0 }
  openPage()
  check("the shake is the reason", contains(ui.view.whys, string.format(T().whyShakeOnlyFmt, 49)),
    table.concat(ui.view.whys, " | "))
  check("never beside 'answers the stick as asked'", not contains(ui.view.whys, T().whyOk),
    table.concat(ui.view.whys, " | "))
  check("nothing to save", not canSave())
  resetFlights()
end

print("Differences from the Ethos suite: the profiles the flights were flown on")
do
  resetFc()
  flightContext = { pidProfile = 2, rateProfile = 1 }
  openPage()
  check("flown on another PID profile: the page says which, and Save is off", not canSave()
    and ui.view.actions[1] == string.format(T().profileSwitchFmt, 2, 1), ui.view.actions[1])
  check("the profiles are named", shown(string.format(T().profileFmt, 2, 1)))

  -- The same values on both profiles: still another profile
  resetFc()
  flightContext = { pidProfile = 1, rateProfile = 2 }
  openPage()
  check("flown on another rate profile with the same values: Save is off", not canSave())

  -- Polar cyclic recorded on profile 2 is not used on profile 1
  resetFc()
  flightContext = { pidProfile = 2, rateProfile = 2, cyclicPolarity = 1 }
  openPage()
  check("polar cyclic of another profile is not used", not contains(ui.view.actions, T().ratesCyclic)
    and contains(ui.view.actions, T().ratesAxis[1]), table.concat(ui.view.actions, " | "))

  resetFc()
  flightContext = { unknownProfile = true }
  openPage()
  check("flights of unknown profiles: Save is off and the page says why", not canSave()
    and ui.view.actions[1] == T().profileUnknown, ui.view.actions[1])
  resetFlights()
end

-- ---------------------------------------------------------------------------
print("From the review")
-- ---------------------------------------------------------------------------
do
  -- F 100 hot at 1.53 on Actual 36/100: F 100 -> 80 with 36 -> 45 and 100 -> 125. Every line the
  -- screen shows is one Save writes. (Inside the flight controller's 255 the rates fit.)
  resetFc()
  fc.tuning.pid_0_F, fc.rates.rcRates_1, fc.rates.rates_1 = 100, 36, 100
  flightRoll = { F = 100, ffGain = 1.53, rcRate = 36, sRate = 100 }
  openPage()
  local lines = 0
  for _, s in ipairs(ui.view.actions) do if string.find(s, "->", 1, true) then lines = lines + 1 end end
  check("hot F at its limit, F100, gain 1.53, Actual 36/100: the screen shows exactly what Save writes",
    lines == #ui.view.changes and #ui.view.changes == 3, lines .. " lines, " .. #ui.view.changes .. " changes")
  resetFc()
  fc.tuning.pid_0_F, fc.rates.rcRates_1, fc.rates.rates_1 = 100, 36, 220
  flightRoll = { F = 100, ffGain = 1.53, rcRate = 36, sRate = 220 }
  openPage()
  check("hot F with no room in the rates, F100, gain 1.53, Actual 36/220: no proposal", not canSave()
    and not contains(ui.view.actions, "->") and contains(ui.view.whys, T().whyLimit))

  resetFc()
  flightRoll = { F = 100, ffGain = 1.2, rcRate = 1, sRate = 1 }
  openPage()
  check("F whose rates round back to the same values, F100, gain 1.2, Actual 1/1: no F", not canSave()
    and not contains(ui.view.actions, "->"),
    table.concat(ui.view.actions, " | "))

  resetFc()
  fc.rates.rcRates_1, fc.rates.rates_1 = 120, 140
  flightRoll = { rcRate = 120, sRate = 140 }
  openPage()
  applyNow()
  check("rate range: Actual 120/140 hot FF: raised to 150/175, not clamped",
    fc.rates.rcRates_1 == 150 and fc.rates.rates_1 == 175 and fc.tuning.pid_0_F == 96,
    tostring(fc.rates.rcRates_1) .. "/" .. tostring(fc.rates.rates_1))
  resetFlights()
  journal({})
end

-- ---------------------------------------------------------------------------
print("The shake rule (from the payload version 2 cases)")
-- ---------------------------------------------------------------------------
do
  -- F matches the stick and stops bounce back 15%: on its own, the stop rule raises P 50 -> 60
  local function roll(o)
    local base = { P = 50, F = 100, ffGain = 1.0, meanRebound = 0.15, meanIterm = 0.003, releases = 35,
      shakeCount = 2000, shakeRms = 49 }
    for k, v in pairs(o or {}) do base[k] = v end
    return base
  end
  resetFc()
  flightRoll = roll()
  openPage()
  check("shaking 49 deg/s: Stops shows the shake", shown("Shaking 49 deg/s"))
  check("shaking 49 deg/s: P is lowered one step", shown(":  50 -> 42"))
  check("shaking 49 deg/s: P is not raised", not shown(":  50 -> 60"))
  check("shaking 49 deg/s: the reason names the shake", shown("Shakes 49 deg/s at centre stick"))
  check("shaking 49 deg/s: P is the only change", #ui.view.changes == 1)

  flightRoll = roll({ ffGain = 1.53 })
  openPage()
  check("F off and shaking: Response still shows the mismatch", shown("53% faster than asked"))
  check("F off and shaking: F is left alone", not shown(":  100 ->"))
  check("F off and shaking: P down is the only change", shown(":  50 -> 42") and #ui.view.changes == 1)

  -- Full stick asks 720 deg/s (Actual 36/72) and the heli reaches 400 with the cyclic at its limit
  local full = { rcRate = 36, sRate = 72, fullCount = 200, fullSatCount = 150, fullMaxRate = 400 }
  flightRoll = roll({ shakeRms = 3.0, rcRate = full.rcRate, sRate = full.sRate, fullCount = full.fullCount,
    fullSatCount = full.fullSatCount, fullMaxRate = full.fullMaxRate })
  openPage()
  check("full stick short, calm: the rates come down one step (control)", shown(":  720 -> 580"))
  flightRoll = roll({ rcRate = full.rcRate, sRate = full.sRate, fullCount = full.fullCount,
    fullSatCount = full.fullSatCount, fullMaxRate = full.fullMaxRate })
  openPage()
  check("full stick short, shaking: the rates are left alone", not shown(":  720 ->"))
  check("full stick short, shaking: P down is the only change", shown(":  50 -> 42") and #ui.view.changes == 1)

  flightRoll = roll({ shakeRms = 14.9 })
  openPage()
  check("calm (14.9 deg/s): Stops shows the bounce-back", shown("15% bounce-back"))
  check("calm (14.9 deg/s): P is raised one step", shown(":  50 -> 60"))

  flightRoll = roll({ shakeCount = 499 })
  openPage()
  check("too little centred stick (499 samples): P is raised one step", shown(":  50 -> 60"))

  flightRoll = roll({ P = 1 })
  openPage()
  check("shaking with P at 1: Stops shows the shake", shown("Shaking 49 deg/s"))
  check("shaking with P at 1: no P change", not shown(":  1 ->"))
  resetFlights()
end

-- ---------------------------------------------------------------------------
print("This suite's page: opening, the saved flights and Clear")
-- ---------------------------------------------------------------------------
do
  resetFc()
  openPage()
  check("Flight data names the time and the flights combined", shown("2m 27s, 1/5 flights"))
  check("only the combined figures stay: no flights table", ui.flights == nil and ui.axes ~= nil)
  Page.onClose()
  opened = false
  queue.entries = {}
  build()
  opened = true
  pump()
  check("the page opens again after a close", canSave() and ui.runtime ~= nil and ui.runtime.historyRead == true)

  -- A second flight saved while the page is open, by the capture in this Lua state
  _G.rfsuite.session.tuneCapture = { state = "idle", saved = 0, savedMcu = MCU }
  pump()
  saveFlight()
  _G.rfsuite.session.tuneCapture.saved = 1
  pump()
  check("a flight saved while open is read in", shown("4m 54s, 2/5 flights"))
  _G.rfsuite.session.tuneCapture = nil

  Page.onStar(ctx)
  assert(dialogs[#dialogs], "clear confirmation missing").onConfirm()
  local sent = pump()
  check("Clear erases the saved flights", files[TuneHistory.path(MCU)] == nil)
  check("Clear resets the flight controller's statistics", has(sent, Api.writeCommand), table.concat(sent, ","))
  check("after Clear: no flights, fly more", shown("0m 00s, 0/5 flights") and not canSave())
  check("with no saved flight the page names no profiles the flights were flown on",
    not shown(T().profileUnknown))

  _G.rfsuite.session.mcu_id = nil
  openPage(true)
  check("no aircraft: the page says to connect", shown(T().noAircraft))
  _G.rfsuite.session.mcu_id = MCU

  openPage()
  local sentProbe = {}
  Page.onReload()
  for _ = 1, 20 do pass(function(m) if m.command == Api.command then return { 1 } end end, sentProbe) end
  check("firmware without the command: Needs newer firmware", shown(T().unsupported) and not canSave())

  -- Another flight controller is connected while the page stays open: its firmware is asked
  -- afresh, and the answer of the one before does not stand for it
  _G.rfsuite.session.mcu_id = "def456"
  local sentOther = {}
  for _ = 1, 30 do pass(nil, sentOther) end
  check("another flight controller is asked again and not shown as needing newer firmware",
    has(sentOther, Api.command) and not ui.unsupported and not shown(T().unsupported), table.concat(sentOther, ","))
  _G.rfsuite.session.mcu_id = "ghi789"
  local sentThird = {}
  for _ = 1, 30 do pass(function(m) if m.command == Api.command then return { 1 } end end, sentThird) end
  check("(control) one that refuses the command is shown as needing newer firmware", ui.unsupported
    and shown(T().unsupported))
  _G.rfsuite.session.mcu_id = MCU
end

print()
print(string.format("%d checks, %d failed", checks, failures))
os.exit(failures == 0 and 0 or 1)
