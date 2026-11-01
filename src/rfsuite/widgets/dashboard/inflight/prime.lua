-- The in-flight tuning overlay's ground half: what it reads off the flight controller before a
-- flight, and the undo it lays down before the pilot turns anything.
--
-- Everything in this file speaks MSP, and MSP is only spoken on the ground. tasks/msp/runtime.lua
-- clears its whole queue on every armed tick and pump() refuses while armed, so a read started in
-- the air is dropped without an answer and a write is lost silently. This module therefore
-- refuses to start while armed and abandons a run that is armed into -- and it treats the queue's
-- own "cleared" reason as that abandon rather than as a failure, because the clear IS the runtime
-- enforcing the same rule.
--
-- It does NOT attach a client of its own. Runtime.attach() records the id and brings the runtime
-- up, and widgets/dashboard/runtime.lua's tickMspRuntime already does both on every pass, along
-- with the tick and the pump these replies arrive on. Nothing in the queue schedules by client id
-- -- it is one FIFO, and the id is what a clear and a log line name -- so a second registration
-- would add an id that something would afterwards have to detach, and the widget has no teardown
-- point that could. The messages still carry `client`, which is the part that has an effect.
--
-- Two things are read off the board rather than assumed. The SET is the board's own adjustment
-- slot table: which parameter sits in which bank and row is whatever the pilot configured there,
-- and the documented layout is only the fallback for a board that yields nothing usable. The
-- VALUES are read by a sliced transaction for each reachable profile, so the screen
-- can show a number before the first step is made -- AdjF/AdjV only report what has just moved.

local M = {}

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

local Functions = requireModule("widgets/dashboard/inflight/functions.lua")
local Setup = requireModule("widgets/dashboard/inflight/setup.lua")
local Log = requireModule("lib/log.lua")
local Profiles
local function profileModule()
  if not Profiles then
    local module = requireModule("widgets/dashboard/inflight/profiles.lua")
    if type(module) ~= "table" then error("inflight/prime.lua: profile dependency missing", 0) end
    Profiles = module
  end
  return Profiles
end

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
if type(Functions) ~= "table" or type(Setup) ~= "table" then
  error("inflight/prime.lua: a dependency did not load", 0)
end

local function logPrime(fmt, ...)
  if not (Log and type(Log.wanted) == "function" and Log.wanted("info")) then return end
  local msg = tostring(fmt)
  if select("#", ...) > 0 then msg = string.format(msg, ...) end
  Log.emit("rfsuite.inflight", msg, "info")
end

-- The name every message of this module carries. The queue clears and logs by it; nothing
-- schedules by it.
M.CLIENT = "inflight-tuning"

-- MSP_RX_MAP, MSP_GET_ADJUSTMENT_FUNCTION_IDS and MSP_GET_ADJUSTMENT_RANGE. The whole-table read
-- (52) is deliberately absent: over CRSF its reply overruns the reassembly buffer, which is why
-- their own adjustments page reads the table one slot at a time as well.
local CMD_RX_MAP = 64
local CMD_ADJ_FUNCTION_IDS = 167
local CMD_ADJ_RANGE = 156

-- The board's table is 42 slots, the length of the 167 reply.
local SLOT_COUNT = 42

-- How many slot records one widget pass may turn into the set. The whole derivation is 7 471 VM
-- instructions on the pilot's own board (33 populated slots) against a call budget of 20 000 that
-- the LVGL reactive sweep also comes out of, so it is taken in slices; eight records is about
-- 1 800 instructions, which is the same order as the widget's other bounded work.
local DERIVE_SLICE = 8

-- How long the connect chain has to have been FINISHED before the automatic prime runs, in
-- getTime ticks of 10 ms.
--
-- The wait used to be measured from the link coming up, and two seconds of link is not the same
-- thing at all: measured against a board, the chain was still running sixteen seconds in, the
-- prime's forty-odd round trips went into the same single queue beside it, and the chain the
-- dashboard is waiting for took fifty-nine seconds instead of sixteen -- long enough for the
-- widget's own splash timeout to fire. So the chain is what is waited for, and this is only the
-- settle on top of it.
local AUTO_DELAY_TICKS = 100

-- The drive's GROUND phase, as widgets/dashboard/inflight/drive.lua spells it.
--
-- Not required from there: the two modules are loaded beside each other rather than one under the
-- other -- this one speaks MSP and the drive does not -- and one word is not worth a dependency
-- edge between them.
local DRIVE_PHASE_GROUND = "ground"

-- How many times the automatic prime is started again after a run that FAILED, within one link.
--
-- A run that was ABANDONED is retried without a limit: an abandon is the pilot arming, which is
-- allowed and which he may do as often as he likes. A FAILURE can be permanent -- a board that
-- answers an error answers it again -- so it is retried this many times and then left alone with
-- the error on the screen rather than asked the same question for the rest of the session.
local AUTO_RETRY_LIMIT = 2

-- Every read this module makes is a read, and 250 is a write with an empty payload. The queue
-- infers `isWrite` from a non-empty payload (tasks/msp/queue.lua), which is wrong for both: 156
-- carries a slot index and is still a read, 250 carries nothing and is still a write. Both are
-- therefore stated rather than inferred, everywhere below.

-- ---------------------------------------------------------------------------
-- The link
-- ---------------------------------------------------------------------------

local MspRuntime = nil
local function mspState()
  if MspRuntime == nil then
    MspRuntime = requireModule("tasks/msp/runtime.lua") or false
  end
  if MspRuntime == false or type(MspRuntime.getState) ~= "function" then return nil end
  local state = MspRuntime.getState()
  if type(state) ~= "table" then return nil end
  return state
end

--- The flight controller on this link, or nil while it has not said which one it is.
--
-- The name is `session.signature`, which tasks/msp/runtime.lua builds from the API version and the
-- MCU id and which the tool pages already keep their reads by. It is answered only while the
-- runtime holds an MCU id for THIS link: the runtime drops the id on every disconnect and sets it
-- again when the UID read answers, while the signature stays at the previous board's name across
-- the drop, so the signature alone would name the old board for the whole of that window. One form
-- only: the runtime builds the signature in the same publish that takes the id in, so an id with no
-- signature beside it is a moment that has not been published yet, and is answered as unknown.
-- The UID reply sets the id first and publishes only after the model preferences are read, so a
-- pass stopped in between leaves the new id beside the old board's signature; the id the
-- signature was last built from (`signatureMcuId`) tells the two apart.
local function boardOnLink()
  local state = mspState()
  local values = state and state.values
  if type(values) ~= "table" or values.mcuId == nil then return nil end
  if state.signatureMcuId ~= values.mcuId then return nil end
  local session = _G.rfsuite and _G.rfsuite.session or nil
  local signature = (type(session) == "table") and session.signature or nil
  return signature
end
M.boardOnLink = boardOnLink

local function queueOf()
  local state = mspState()
  if state == nil or type(state.queue) ~= "table" or type(state.queue.add) ~= "function" then return nil end
  return state.queue
end

-- The rotor is turning, whatever the arm sensor says. The thresholds are the ones
-- widgets/dashboard/runtime.lua's own computeFlightMode uses to decide that a model has left the
-- ground: a governor in one of its running states, or a head speed that nothing on a bench
-- produces. They are read straight off the telemetry state rather than through `armed`, which is
-- the point -- this is a SECOND witness and it has to be independent of the first.
local GOVERNOR_RUNNING_FROM = 4
local GOVERNOR_RUNNING_TO = 8
local RPM_RUNNING = 500

--- Whether the board is armed -- or cannot be shown not to be.
--
-- The widget's own copy is what the screen is drawn from; the MSP runtime's is what actually
-- gates the queue. Either one saying armed is enough: the two are read from the same sensor a
-- pass apart, and the cost of believing the earlier of them is a prime that starts a moment
-- later, while the cost of believing the later one is a request the runtime throws away.
--
-- It FAILS CLOSED, and that is the part worth stating. `armed` is false on a model whose arm
-- sensor was never selected in the telemetry list, exactly as it is on a model sitting disarmed
-- on the bench, and the two are not distinguishable from the flag alone. Answering "not armed"
-- there means sending MSP to a helicopter in the air. So until the sensor has answered once --
-- `armedSeen`, set by the widget's telemetry read and cleared on the reconnect edge -- everything
-- that asks this question is refused, and the ground screen says which sensor is missing rather
-- than showing buttons that would do the wrong thing.
--
-- The rotor test underneath it is the second witness. It is deliberately NOT the widget's
-- `hadInflightFlight` latch, although that is the flag this reading came from: that latch can
-- only ever be set while `armed` is already true, so it adds no independent evidence, and it
-- STAYS true from touchdown until the next arming -- which is the whole window in which a pilot
-- wants the restore this module exists to offer. The live reading refuses while the machine is
-- turning and stops refusing when it stops.
local function isArmed(widget)
  local state = widget and widget.state
  if type(state) == "table" then
    if state.armed == true then return true end
    if state.armedSeen ~= true then return true end
    local governor = tonumber(state.governor)
    if governor ~= nil and governor >= GOVERNOR_RUNNING_FROM and governor <= GOVERNOR_RUNNING_TO then
      return true
    end
    if (tonumber(state.rpm) or 0) >= RPM_RUNNING then return true end
  end
  local msp = mspState()
  return type(msp) == "table" and msp.lastArmed == true
end

--- Why the ground half is refusing, when it is not simply that the board is armed. The screen
-- turns this into a sentence; nil means the ordinary armed/disarmed reading applies.
function M.groundRefusal(widget)
  local state = widget and widget.state
  if type(state) ~= "table" then return nil end
  if state.armed == true then return nil end
  if state.armedSeen ~= true then return "no_arm_sensor" end
  return nil
end

-- The setup writer shares the ground read's rotor and arming gates.
function M.setupRefusal(widget)
  local state = widget and widget.state
  if type(state) ~= "table" or state.armedSeen ~= true then return "arm_unknown" end
  if state.armed == true then return "armed" end
  if isArmed(widget) then return "rotor_running" end
  return nil
end

local function apiModule(name)
  if type(name) ~= "string" or name == "" then return nil end
  return requireModule("tasks/msp/api/" .. name .. ".lua")
end

-- ---------------------------------------------------------------------------
-- The run
-- ---------------------------------------------------------------------------

M.PHASE_IDLE = "idle"
M.PHASE_RXMAP = "rxmap"
M.PHASE_FUNCTION_IDS = "functionIds"
M.PHASE_SLOTS = "slots"
--- The board's table is in and is being turned into the set, a slice per widget pass.
M.PHASE_DERIVE = "derive"
M.PHASE_VALUES = "values"
M.PHASE_DONE = "done"
M.PHASE_ERROR = "error"

local RUNNING = {
  [M.PHASE_RXMAP] = true, [M.PHASE_FUNCTION_IDS] = true,
  [M.PHASE_SLOTS] = true, [M.PHASE_DERIVE] = true, [M.PHASE_VALUES] = true
}

--- Whether a run is still expecting a reply.
function M.isRunning(drive)
  local prime = type(drive) == "table" and drive.prime or nil
  return type(drive) == "table" and (drive.profileJob ~= nil
    or type(prime) == "table" and not prime.invalidated and RUNNING[prime.phase] == true)
end

-- A completed session cache survives an interrupted refresh; phase alone is not evidence
-- that values exist. readAt is optional because some radios have no wall clock.
function M.hasRead(drive)
  if type(drive) ~= "table" or drive.valuesRead ~= true or drive.readRequired then return false end
  return type(drive.values) == "table" and next(drive.values) ~= nil
end

local function bump(drive)
  drive.valueEpoch = (drive.valueEpoch or 0) + 1
end

--- Everything stored for a run that is over, or whose phase has been reset under it.
--
-- Replies are stored where they arrive and parsed a pass later (see "The phases" below), so a run
-- that ends can be holding answers it will never look at.
local function dropStored(prime)
  local pending = prime.pending
  if type(pending) ~= "table" then
    prime.pending, prime.pendingHead, prime.pendingTail = {}, 1, 0
    prime.chainPaused = false
    return
  end
  for i = prime.pendingHead or 1, prime.pendingTail or 0 do pending[i] = nil end
  prime.pendingHead, prime.pendingTail = 1, 0
  prime.chainPaused = false
end

--- The reply belongs to the run that is still current, or it belongs to nothing.
--
-- A prime that was restarted, abandoned or failed leaves its messages in the queue, and their
-- callbacks close over the run they were made for. Comparing the run rather than a flag is what
-- keeps a late reply from a previous attempt out of the current one's counters.
local function stillCurrent(drive, prime)
  return type(drive) == "table" and drive.prime == prime and not prime.invalidated and RUNNING[prime.phase] == true
end

local function fail(drive, prime, reason)
  if not stillCurrent(drive, prime) then return false end
  prime.phase = M.PHASE_ERROR
  prime.error = tostring(reason or "failed")
  -- A reply already stored is a parse this run will never make. Dropping it here is what keeps
  -- the passes after a failure free of work for a run that is over.
  dropStored(prime)
  -- Counted so that the automatic run can be offered again a bounded number of times. See
  -- AUTO_RETRY_LIMIT: an abandon is not counted here, because it is not a failure of the board's.
  drive._primeFails = (drive._primeFails or 0) + 1
  bump(drive)
  logPrime("prime failed in %s: %s", tostring(prime.failedIn or "?"), prime.error)
  return false
end

--- A run given up rather than failed: the board was armed into, or the runtime cleared the queue,
-- which while armed is the same event seen from the other side. It is not an error and it is not
-- shown as one -- the pilot armed, which is allowed.
local function abandon(drive, prime, why)
  if not stillCurrent(drive, prime) then return end
  prime.phase = M.PHASE_IDLE
  prime.error = nil
  dropStored(prime)
  -- Recorded on the DRIVE and not on the run, because the run it describes is over and the two
  -- questions it answers are about the next one: whether the automatic run may start again, and
  -- what the ground surface says beside a read that is older than the last attempt at one.
  drive.primeInterrupted = true
  bump(drive)
  logPrime("prime abandoned: %s", tostring(why))
end

--- One more reply is in. The counter moves and the epoch does NOT.
--
-- This is the pilot's third radio round, and it is the failure that froze his radio rather than
-- merely slowing it. The epoch is in the widget's tuning render key, so every bump asked for the
-- whole surface to be torn down and built again -- forty-five objects, throttled to twice a second,
-- which is once per reply for a prime whose replies arrive every half second. His widget_2.log has
-- the instruction budget climbing 35 -> 60 -> 70 % of a five-second peak across a prime and then
-- stopping mid-record with no fault line at all: the firmware's LVGL sweep of the tree runs in the
-- same 20 000-instruction call and OUTSIDE the pcall the entry point wraps refresh in, so nothing
-- of ours can ever see it and the only witness is the screen.
--
-- What the pilot needs to see while a prime runs is a counter, and a counter does not need a tree.
-- The counters travel on the published snapshot, which Drive's publish swaps atomically whenever
-- they move, and the ground surface reads them through a reactive text closure -- one formatted
-- string per frame, no objects. The surface is rebuilt when the prime STARTS and when it ENDS,
-- because those change what is on it.
local function advanced(_drive, prime)
  prime.done = (prime.done or 0) + 1
end

--- One handler for every message this module sends: the queue's own clear is an abandon, and
-- everything else -- a timeout, the retry budget, a board that answered with an error -- is a
-- failure the screen names.
local function replyFailed(drive, prime, where)
  return function(_, reason)
    if reason == "cleared" then
      abandon(drive, prime, "queue cleared")
      return
    end
    prime.failedIn = where
    fail(drive, prime, reason)
  end
end

-- ---------------------------------------------------------------------------
-- The board's own slot table, turned into a set
-- ---------------------------------------------------------------------------

-- Which wire channel an AUX field of a slot record names, and the inverse. Both live in
-- inflight/functions.lua, because the settings page's writer needs the inverse without loading
-- this file; re-exported here because the derivation below, the screens and the probes all reach
-- for the forward direction through this module.
M.auxToWireChannel = Functions.auxToWireChannel
M.wireToAuxField = Functions.wireToAuxField

local function windowKey(window)
  if type(window) ~= "table" then return nil end
  local from = tonumber(window.start)
  local to = tonumber(window["end"])
  if from == nil or to == nil then return nil end
  return tostring(from) .. ":" .. tostring(to), from, to
end

--- The set the board is actually configured for: which parameter answers which bank and row.
--
-- Nothing about the layout is assumed. The BANKS are the distinct enable windows the usable slots
-- name, in rising microseconds -- that is the order a switch or a variable walks them in. The
-- ROWS are the distinct INCREMENT windows, in FALLING microseconds, so row 1 is the one furthest
-- from centre: that is the row the documented layout drives with the largest trim throw, and a
-- board configured some other way still gets its own outermost pair as row 1.
--
-- A slot is usable only when it steps -- a continuous slot has no park position, so nothing on
-- this screen could leave it alone -- and when both of its channels are the ones this model
-- devotes to the pair. A slot on some other channel belongs to a switch the pilot flies with and
-- is none of the overlay's business.
--
-- Answers nil when nothing usable came back, which is what keeps the documented layout as the
-- fallback rather than replacing it with an empty table.
function M.deriveSet(records, map, bankChannel, valueChannel)
  local work = M.newDerivation(records, map, bankChannel, valueChannel)
  if work == nil then return nil, {} end
  local done, result, skipped
  repeat
    done, result, skipped = M.deriveStep(work)
  until done
  return result, skipped
end

--- The same derivation, prepared to run a SLICE at a time.
--
-- Measured on a desktop Lua with the pilot's own board -- 33 populated slots, 31 of them usable
-- -- the whole derivation costs 7 471 VM instructions. EdgeTX bills a widget call at 20 000
-- (lua_widget.cpp, MAX_INSTRUCTIONS) and the LVGL reactive sweep of the tree standing after the
-- call comes out of that same 20 000, on top of a background pass that already costs eleven and
-- a half thousand. Run whole, it therefore does not fit, and what fails is not the widget's own
-- pass: `refresh` returns and `callRefs` raises afterwards, outside the pcall the widget entry
-- point wraps everything in. On a radio that reads as `ERROR in foreground calRefs error` across
-- the frame, with nothing in any log the suite keeps, and the widget stops.
--
-- So it is taken in slices with a budget, like the trim walk in inflight/drive.lua and like the
-- scene build in widgets/dashboard/runtime.lua. The two sorts are not chunked and do not need to
-- be: they order at most `BANK_COUNT` bands and `ROW_COUNT` rows.
function M.newDerivation(records, map, bankChannel, valueChannel)
  if type(records) ~= "table" then return nil end
  return {
    records = records, map = map,
    bankCh = bankChannel, valueCh = valueChannel,
    phase = "scan", at = 0,
    usable = {}, usableSlot = {}, skipped = {}, alwaysWindows = {},
    bands = {}, bandSeen = {}, rows = {}, rowSeen = {},
    enableWindows = {}, enableSeen = {}, refusedBank = {},
    set = {}, rowValues = {}, cellRecord = {}, bankWindows = {}, cells = {}, placed = 0
  }
end

--- One slice. Answers `done, result, skipped`; `result` is nil until the last slice, and nil at
-- the end means nothing usable came back -- which is what keeps the documented layout as the
-- fallback rather than replacing it with an empty table.
function M.deriveStep(work, budget)
  if type(work) ~= "table" then return true, nil, {} end
  local taken = 0

  if work.phase == "scan" then
    -- Classify and collect in one walk. A slot is usable only when it steps -- a continuous slot
    -- has no park position -- and when both of its channels are the ones this model devotes to
    -- the pair. A slot on some other channel belongs to a switch the pilot flies with.
    while work.at < SLOT_COUNT do
      if budget ~= nil and taken >= budget then return false, nil, nil end
      work.at = work.at + 1
      taken = taken + 1
      local slot = work.at
      local record = work.records[slot]
      if type(record) == "table" and (tonumber(record.adjFunction) or 0) ~= 0 then
        local enableCh = M.auxToWireChannel(record.enaChannel, work.map)
        local valueCh = M.auxToWireChannel(record.adjChannel, work.map)
        if (tonumber(record.enaChannel) or 0) >= Functions.AUX_FIELD_COUNT and valueCh == work.valueCh then
          -- An out-of-range enable field is always active (fc/rc_adjustments.c).
          work.skipped[#work.skipped + 1] = slot
          for _, range in ipairs({record.adjRange1, record.adjRange2}) do
            local low, high = Functions.windowBounds(range)
            if low ~= nil then work.alwaysWindows[#work.alwaysWindows + 1] = {low = low, high = high, slot = record} end
          end
        elseif enableCh == work.bankCh and valueCh == work.valueCh then
          -- Every enable window of the pair, stepped or continuous: the board runs each slot
          -- whose window holds the bank channel (fc/rc_adjustments.c), and a continuous one then
          -- sets its parameter from the value channel, so a parked bank value inside its window
          -- reaches it too. The id is not checked against this build's table on purpose: a newer
          -- firmware can carry a function the table does not name yet, and it still fires.
          local enableKey = windowKey(record.enaRange)
          local continuous = (tonumber(record.adjStep) or 0) <= 0
          local seen = enableKey ~= nil and work.enableSeen[enableKey] or nil
          if seen ~= nil then
            if continuous then seen.continuous = true end
          elseif enableKey ~= nil then
            local low, high = Functions.windowBounds(record.enaRange)
            local window = { key = enableKey, low = low, high = high, continuous = continuous }
            work.enableSeen[enableKey] = window
            if low ~= nil then work.enableWindows[#work.enableWindows + 1] = window end
          end
          if (tonumber(record.adjStep) or 0) > 0 then
            work.usable[#work.usable + 1] = record
            work.usableSlot[#work.usable] = slot
            local bandKey, bandFrom, bandTo = windowKey(record.enaRange)
            if bandKey ~= nil and work.bandSeen[bandKey] == nil then
              work.bandSeen[bandKey] = true
              work.bands[#work.bands + 1] = { key = bandKey, min = bandFrom, max = bandTo }
            end
            local rowKey, rowFrom, rowTo = windowKey(record.adjRange2)
            if rowKey ~= nil and work.rowSeen[rowKey] == nil then
              work.rowSeen[rowKey] = true
              work.rows[#work.rows + 1] = { key = rowKey, min = rowFrom, max = rowTo }
            end
          else
            work.skipped[#work.skipped + 1] = slot
          end
        end
      end
    end
    if #work.usable == 0 then return true, nil, work.skipped end
    work.phase = "order"
    return false, nil, nil
  end

  if work.phase == "order" then
    -- The BANKS are the distinct enable windows, in rising microseconds -- the order a switch or
    -- a variable walks them in. The ROWS are the distinct increment windows in FALLING
    -- microseconds, so row 1 is the one furthest from centre: the row the documented layout
    -- drives with the largest trim throw, and a board configured some other way still gets its
    -- own outermost pair as row 1.
    table.sort(work.bands, function(a, b)
      if a.min ~= b.min then return a.min < b.min end
      return a.max < b.max
    end)
    table.sort(work.rows, function(a, b)
      if a.min ~= b.min then return a.min > b.min end
      return a.max > b.max
    end)

    work.bandIndex, work.rowIndex = {}, {}
    work.outBands, work.bankValues = {}, {}
    for i = 1, #work.bands do
      if i > Functions.BANK_COUNT then break end
      work.bandIndex[work.bands[i].key] = i
      work.outBands[i] = { min = work.bands[i].min, max = work.bands[i].max }
      work.bankValues[i] = Functions.bandMidGv(work.outBands[i])
    end
    for i = 1, #work.rows do
      if i > Functions.ROW_COUNT then break end
      work.rowIndex[work.rows[i].key] = i
    end
    work.phase = "park"
    work.at = 0
    return false, nil, nil
  end

  if work.phase == "park" then
    -- A bank is offered only when the value that parks it enables that bank and no other. The
    -- middle of a window is clamped to the channel's travel (functions.lua, bandMidGv), so a
    -- window that starts past 2012 us is parked inside whichever window holds 2012 us, and two
    -- overlapping windows can share their middle. Either way every press would step a slot of the
    -- OTHER window while the screen names this bank's parameters. The test is the firmware's own,
    -- start inclusive and end exclusive (isRangeActive, fc/rc_modes.h), against every enable
    -- window of the pair; a continuous slot on the bank's OWN window fails it as well, since every
    -- pulse in that bank would also move the continuous parameter. A bank that fails it is refused
    -- rather than moved: its slots are counted as skipped and its cells stay empty, so no step can
    -- be aimed at it.
    --
    -- One bank is one unit of the budget although it walks every window of the pair. Counted on a
    -- desktop Lua, a full table of 42 distinct windows puts its worst slice at 2 680 instructions,
    -- below the 2 830 of the place slice on the documented 36-slot board.
    while work.at < #work.outBands do
      if budget ~= nil and taken >= budget then return false, nil, nil end
      work.at = work.at + 1
      taken = taken + 1
      local bank = work.at
      local band = work.bands[bank]
      local value = work.bankValues[bank]
      local us = value ~= nil and Functions.gvarToUs(value) or nil
      local low, high = Functions.windowBounds({ start = band.min, ["end"] = band.max })
      local ok = us ~= nil and low ~= nil and us >= low and us < high
      if ok then
        for i = 1, #work.enableWindows do
          local window = work.enableWindows[i]
          if (window.key ~= band.key or window.continuous) and us >= window.low and us < window.high then
            ok = false
            break
          end
        end
      end
      if not ok then
        work.bankValues[bank] = nil
        work.refusedBank[bank] = true
        logPrime("bank %d refused: its parked value does not enable window %s..%s alone",
          bank, tostring(band.min), tostring(band.max))
      end
    end
    work.phase = "place"
    work.at = 0
    return false, nil, nil
  end

  if work.phase == "place" then
    while work.at < #work.usable do
      if budget ~= nil and taken >= budget then return false, nil, nil end
      work.at = work.at + 1
      taken = taken + 1
      local record = work.usable[work.at]
      local bank = work.bandIndex[windowKey(record.enaRange) or ""]
      local row = work.rowIndex[windowKey(record.adjRange2) or ""]
      if bank ~= nil and work.refusedBank[bank] then
        -- A refused bank's slot is one the overlay cannot drive, which is what `skipped` counts.
        work.skipped[#work.skipped + 1] = work.usableSlot[work.at]
        bank = nil
      end
      if bank ~= nil then
        -- Both windows of every usable slot of the bank, placed or not, as the board reads them:
        -- the cross-check below has to see them all, because the board fires every slot whose
        -- window holds the value.
        local windows = work.bankWindows[bank] or {}
        work.bankWindows[bank] = windows
        local low, high = Functions.windowBounds(record.adjRange1)
        if low ~= nil then windows[#windows + 1] = { low = low, high = high, slot = record, down = true } end
        low, high = Functions.windowBounds(record.adjRange2)
        if low ~= nil then windows[#windows + 1] = { low = low, high = high, slot = record, down = false } end
      end
      if bank ~= nil and row ~= nil then
        work.set[bank] = work.set[bank] or {}
        -- The first slot names a cell it shares. Two slots on the same window pair are a
        -- configuration the board answers by stepping BOTH, so the cross-check below refuses the
        -- step rather than guessing which of the two names the pilot meant.
        if work.set[bank][row] == nil then
          work.set[bank][row] = math.floor(tonumber(record.adjFunction) or 0)
          work.rowValues[bank] = work.rowValues[bank] or {}
          work.rowValues[bank][row] = {
            up = Functions.windowCode(record.adjRange2),
            down = Functions.windowCode(record.adjRange1)
          }
          work.cellRecord[bank] = work.cellRecord[bank] or {}
          work.cellRecord[bank][row] = record
          work.cells[#work.cells + 1] = { bank = bank, row = row }
          work.placed = work.placed + 1
        end
      end
    end
    if work.placed == 0 then return true, nil, work.skipped end
    work.phase = #work.alwaysWindows > 0 and "always" or "cross"
    work.at = 0
    return false, nil, nil
  end

  if work.phase == "always" then
    -- Copy one window to each bank per unit, separately from placement and cross-checking.
    while work.at < #work.alwaysWindows do
      if budget ~= nil and taken >= budget then return false, nil, nil end
      work.at, taken = work.at + 1, taken + 1
      for _, windows in pairs(work.bankWindows) do windows[#windows + 1] = work.alwaysWindows[work.at] end
    end
    work.phase, work.at = "cross", 0
    return false, nil, nil
  end

  if work.phase == "cross" then
    -- A value the board would read as a SECOND slot of the same bank is refused. The flight
    -- controller visits every slot whose enable window is active and fires each one whose window
    -- holds the channel value, decrement window first (fc/rc_adjustments.c), so a value aimed at
    -- one window that also sits inside another would step two parameters at once -- the very
    -- thing this map exists to rule out. The row says it cannot be stepped instead.
    while work.at < #work.cells do
      local cell = work.cells[work.at + 1]
      local windows = work.bankWindows[cell.bank]
      -- Charge extra windows against the slice: always-active slots can enlarge every bank.
      local cost = math.ceil(#windows / (Functions.ROW_COUNT * 2))
      if budget ~= nil and (taken >= budget or (taken > 0 and taken + cost > budget)) then return false, nil, nil end
      work.at, taken = work.at + 1, taken + cost
      local values = work.rowValues[cell.bank][cell.row]
      local own = work.cellRecord[cell.bank][cell.row]
      local usUp = values.up ~= nil and Functions.gvarToUs(values.up) or nil
      local usDown = values.down ~= nil and Functions.gvarToUs(values.down) or nil
      for i = 1, #windows do
        local window = windows[i]
        local foreign = window.slot ~= own
        -- The slot's own increment window holds its increment value by construction; its own
        -- decrement window holding it is a decrement, because the board tests that one first.
        if usUp ~= nil and (foreign or window.down) and usUp >= window.low and usUp < window.high then
          values.up, usUp = nil, nil
        end
        if usDown ~= nil and foreign and usDown >= window.low and usDown < window.high then
          values.down, usDown = nil, nil
        end
      end
    end
    return true, { bands = work.outBands, bankValues = work.bankValues, records = work.cellRecord,
                   set = work.set, rowValues = work.rowValues, placed = work.placed }, work.skipped
  end

  return true, nil, work.skipped
end

--- What the finished derivation does to the drive. Called on the slice that completed it.
local function applySet(drive, prime, derived, skipped)
  prime.skipped = skipped or {}
  if derived == nil then
    drive.rowValues = {}
    drive.cellRecords = {}
    drive.set = {}
    drive.setSource = "unavailable"
    drive:rebuildGroups()
    bump(drive)
    logPrime("slot table yielded nothing usable; custom steps are unavailable")
    return
  end

  drive.bands = derived.bands
  drive.bankValues = derived.bankValues
  drive.set = derived.set
  drive.rowValues = derived.rowValues
  -- Each cell's own slot record: its step and its bounds are the board's, not a table of ours.
  drive.cellRecords = derived.records or {}
  drive.setSource = "board"
  drive:rebuildGroups()
  -- The one place inside a run that must move the epoch. Everything else a prime does travels on
  -- the snapshot and is read by a closure, but the SET is the row list itself -- six names built
  -- into the tree -- and a tree built from the documented layout cannot show the board's.
  bump(drive)
  logPrime("slot table gave %d cell(s) over %d band(s)", derived.placed, #derived.bands)

  -- The selection may be pointing at a cell the board's own table does not have.
  if drive:functionId(drive.bank, drive.row) == nil then
    for bank = 1, Functions.BANK_COUNT do
      for row = 1, Functions.ROW_COUNT do
        if drive:functionId(bank, row) ~= nil then
          drive.bank, drive.row = bank, row
          return
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- The phases
--
-- A reply is STORED when it arrives and PARSED on a later widget pass, at most one per pass.
--
-- The firmware bills a widget call at 20 000 VM instructions (lua_widget.cpp, MAX_INSTRUCTIONS)
-- and the LVGL reactive sweep of the tree standing after the call comes out of the same 20 000,
-- on top of a background pass that already costs eleven and a half thousand. One reply of this
-- run parses for between 42 and 933 of those, so the question is not what a reply costs but how
-- many of them one pass can be made to carry -- and the answer used to be "as many as the link
-- delivers". The widget pass gives the MSP queue two turns (Runtime.tick and Runtime.pump,
-- widgets/dashboard/runtime.lua), a read the queue finds in its cache completes with no round
-- trip at all, and a retry can still be answered after its replacement has gone out. A bounded
-- pass may not rest on none of that happening.
--
-- So `processReply` copies the bytes, stores them and returns, and `M.tick` -- once per widget
-- pass -- parses exactly one stored reply. The worst pass carries one parse however the link
-- behaves.
--
-- What does NOT move is the request that follows. The next command is known from the run's own
-- cursor for every phase but one -- only the function-id reply says which slots are worth reading
-- -- so the chain is continued from the ARRIVAL, in the same queue turn it was continued from
-- before. That keeps the wire timing the one this module was measured with against a board: the
-- request goes out on the queue's second turn of the same pass, and its answer is picked up by
-- the first turn of the next one. Moving the send to the parse instead would put every request on
-- the first turn, where the custom-telemetry drain runs between the send and the second turn --
-- and lib/crsf.lua buffers a frame only for a type its OWN instance has been asked for, while the
-- drain and the MSP transport load that file separately and hold an instance each.
--
-- The copy is not avoidable. tasks/msp/common.lua reassembles every reply into one table and
-- clears it when the next reply's first frame arrives; the queue hands that same table to
-- `processReply` and to its read cache. The MSP runtime's own periodic reads share that
-- transport, so between the pass a reply lands on and the pass that parses it the buffer can
-- already hold somebody else's answer. A copy is a fraction of a parse -- one element loop over a
-- reply of 1 to 43 bytes, 17 to 143 instructions against 42 to 933 -- which is what makes the
-- trade worth making.
-- ---------------------------------------------------------------------------

--- How many replies may wait for their parse at once, before the chain waits for the parse.
--
-- A pass parses one reply and gives the queue two turns, so a link that answered both of them
-- would store two replies for every one parsed and the backlog would grow for the whole run.
-- Past this depth the arrival does not ask for the next command; the parse does, which is one
-- reply in flight per parse and cannot grow. On a link that answers one request per pass -- which
-- is every real one, and the offline check in bin/accounting too -- the depth never reaches it.
local PENDING_CHAIN_LIMIT = 1

--- The bytes of a reply, kept away from the transport's own buffer. See above.
local function copyBuf(buf)
  if type(buf) ~= "table" then return buf end
  local out = {}
  for i = 1, #buf do out[i] = buf[i] end
  return out
end

--- How many stored replies are waiting for their parse.
local function pendingDepth(prime)
  return (prime.pendingTail or 0) - (prime.pendingHead or 1) + 1
end

--- Put a reply's bytes and the context its parse needs at the tail of the run's parse queue.
--
-- Head and tail are counters rather than a table length: a queue drained to empty on most passes
-- must not allocate a fresh table to say so.
local function stash(prime, record)
  local tail = prime.pendingTail + 1
  prime.pendingTail = tail
  prime.pending[tail] = record
end

-- Assigned below the senders: the two halves of a reply, one on arrival and one on the parse.
local arrived, chain

--- The reply handler every message this module sends carries: copy, store, ask for the next.
--
-- A fresh record is built for every reply rather than the template being stored again, so a
-- handler that fires twice -- a late answer to a retry, an answer off the wire beside one out of
-- the read cache -- stores two replies with two buffers instead of two references to one buffer
-- that both read whichever answer arrived last.
local function stashHandler(widget, drive, prime, template)
  return function(_, buf)
    if not stillCurrent(drive, prime) then return end
    local record = {
      kind = template.kind, command = template.command, api = template.api,
      fields = template.fields, slot = template.slot, buf = copyBuf(buf)
    }
    stash(prime, record)
    arrived(widget, drive, prime, record)
  end
end

-- Profile transactions share the prime's existing arm, link and FC identity gates.
local function profileEnvironment()
  return {
    armed = isArmed, queue = queueOf,
    identity = function()
      local state = mspState()
      return boardOnLink(), state and state.values and state.values.mcuId
    end
  }
end

local function startValues(widget, drive, prime)
  prime.phase = M.PHASE_VALUES
  local ok, reason = profileModule().begin(widget, drive, profileEnvironment(), prime.refresh and "refresh" or prime.auto and "auto" or "new")
  if not ok then fail(drive, prime, reason) end
  return ok, reason
end

--- The slot table is in: enter the phase that turns it into a set or into a verdict.
--
-- Reached from two places, and the second one is the case an empty board found: when 167 says no
-- slot at all carries a function there is nothing to read with 156, and a run that only ever
-- entered this phase from the last slot record would sit in the slot phase for ever -- no request
-- out, no reply due, no error. A flight controller with nothing configured is exactly the board
-- this feature exists to offer a set to.
local function startDerive(drive, prime)
  -- The settings picker reuses this completed ground read without sending its own MSP.
  local session = _G.rfsuite and _G.rfsuite.session
  if session then
    session.inflightSlots = { mcu = session.mcu_id, records = prime.records, map = prime.map,
      bank = drive.settings.bank_ch, value = drive.settings.value_ch }
  end
  prime.phase = M.PHASE_DERIVE
  -- What can be tuned is what the board carries: the set is always derived from its own slots.
  -- The standard layout survives only as what *Set up the flight controller* writes.
  prime.derivation = M.newDerivation(prime.records, prime.map,
    drive.settings.bank_ch, drive.settings.value_ch)
end

--- One slice of the work that turns the board's slot table into something, taken from the widget's
-- own pass rather than from a reply. In the custom layout that is the SET; in the standard layout
-- the set is already known and what is derived is the verdict on the board.
--
-- Answers true while the prime is in this phase, so the caller knows the pass has been spent.
local function stepDerivation(widget, drive)
  local prime = drive.prime
  if type(prime) ~= "table" or prime.phase ~= M.PHASE_DERIVE then return false end

  -- The derivation's last slice, applying the set (it rebuilds the groups and moves the layout
  -- epoch) and starting the values (the profile job and the SD baseline) each take a pass of their
  -- own. Measured on a full standard board: the three in one pass cost about 23 000 instructions
  -- and the first two still 21 600, against the 20 000 a widget call is stopped at.
  if prime.setApplied then
    prime.setApplied = nil
    startValues(widget, drive, prime)
    return true
  end
  if prime.derived ~= nil then
    local derived = prime.derived
    prime.derived = nil
    applySet(drive, prime, derived.set, derived.skipped)
    prime.setApplied = true
    return true
  end
  if type(prime.derivation) ~= "table" then
    -- Nothing to work on: fall through to the values as if the table had yielded nothing.
    applySet(drive, prime, nil, prime.skipped)
    prime.setApplied = true
    return true
  end
  local done, derived, skipped = M.deriveStep(prime.derivation, DERIVE_SLICE)
  if not done then return true end
  prime.derivation = nil
  prime.derived = { set = derived, skipped = skipped }
  return true
end

local function sendSlot(widget, drive, prime)
  local queue = queueOf()
  if queue == nil then
    prime.failedIn = "slots"
    return fail(drive, prime, "no_link")
  end

  local slot = prime.slotList[prime.slotAt]
  if slot == nil then return true end

  local api = prime.rangeApi
  queue:add({
    command = CMD_ADJ_RANGE,
    -- The slot index is 0-based on the wire, and this payload does not make the message a write:
    -- it carries which slot to answer for, and the queue is told so rather than left to infer it.
    payload = { slot - 1 },
    isWrite = false,
    simulatorResponse = api.simulatorResponse,
    client = M.CLIENT,
    processReply = stashHandler(widget, drive, prime,
      { kind = "slot", command = CMD_ADJ_RANGE, api = api, slot = slot }),
    errorHandler = replyFailed(drive, prime, "slots")
  })
  return true
end

local function sendFunctionIds(widget, drive, prime)
  local queue = queueOf()
  if queue == nil then
    prime.failedIn = "functionIds"
    return fail(drive, prime, "no_link")
  end
  local api = apiModule("get_adjustment_function_ids")
  if api == nil then
    prime.failedIn = "functionIds"
    return fail(drive, prime, "no_api")
  end

  queue:add({
    command = CMD_ADJ_FUNCTION_IDS,
    isWrite = false,
    simulatorResponse = api.simulatorResponse,
    client = M.CLIENT,
    processReply = stashHandler(widget, drive, prime,
      { kind = "functionIds", command = CMD_ADJ_FUNCTION_IDS, api = api }),
    errorHandler = replyFailed(drive, prime, "functionIds")
  })
  return true
end

local function sendRxMap(widget, drive, prime)
  local queue = queueOf()
  if queue == nil then
    prime.failedIn = "rxmap"
    return fail(drive, prime, "no_link")
  end
  local api = apiModule("rx_map")
  if api == nil then
    prime.failedIn = "rxmap"
    return fail(drive, prime, "no_api")
  end

  queue:add({
    command = CMD_RX_MAP,
    isWrite = false,
    simulatorResponse = api.simulatorResponse,
    client = M.CLIENT,
    processReply = stashHandler(widget, drive, prime,
      { kind = "rxmap", command = CMD_RX_MAP, api = api }),
    errorHandler = replyFailed(drive, prime, "rxmap")
  })
  return true
end

--- Ask the board for whatever the run's cursor now points at.
--
-- Called on a reply's arrival, and by a parse that found the arrival had held the chain back. The
  -- The last slot reply must be parsed before derivation; profile reads have their own job.
chain = function(widget, drive, prime)
  prime.chainPaused = false
  local phase = prime.phase
  if phase == M.PHASE_FUNCTION_IDS then
    return sendFunctionIds(widget, drive, prime)
  end
  if phase == M.PHASE_SLOTS then
    if prime.slotList[prime.slotAt] == nil then return false end
    return sendSlot(widget, drive, prime)
  end
  return false
end

--- What a reply does the moment it arrives. Nothing here decodes anything.
--
-- The cursor moves and the next command goes out, which is the half that has to stay in the queue
-- turn the reply landed on; the function-id reply is the one exception, because what comes after
-- it is not known until it has been parsed.
arrived = function(widget, drive, prime, record)
  local kind = record.kind
  if kind == "rxmap" then
    prime.phase = M.PHASE_FUNCTION_IDS
  elseif kind == "slot" then
    prime.slotAt = prime.slotAt + 1
  elseif kind == "values" then
    prime.valueAt = prime.valueAt + 1
  end
  advanced(drive, prime)

  if kind == "functionIds" then return end
  if pendingDepth(prime) > PENDING_CHAIN_LIMIT then
    prime.chainPaused = true
    return
  end
  chain(widget, drive, prime)
end

-- ---------------------------------------------------------------------------
-- The parses. One of these runs per widget pass, and never two.
-- ---------------------------------------------------------------------------

local function parseRxMap(widget, drive, prime, record)
  -- A receiver that does not answer its map is not fatal: without it AUX1 is taken to be the
  -- sixth channel, which is where every documented setup puts it. Nothing waits for this: the
  -- map is not read until the whole slot table has been.
  prime.map = record.api.parse(record.buf)
  if prime.chainPaused then chain(widget, drive, prime) end
end

local function parseFunctionIds(widget, drive, prime, record)
  local parsed = record.api.parse(record.buf)
  local ids = type(parsed) == "table" and parsed.adjustment_function_ids or nil
  if type(ids) ~= "table" then
    prime.failedIn = "functionIds"
    fail(drive, prime, "no_function_ids")
    return
  end
  -- Only the slots that name a function are read in full. An empty slot has nothing in its
  -- record worth 14 bytes and a round trip, and on this transport that is the whole cost.
  prime.slotList = {}
  for slot = 1, SLOT_COUNT do
    if (tonumber(ids[slot]) or 0) ~= 0 then prime.slotList[#prime.slotList + 1] = slot end
  end
  prime.slotAt = 1
  prime.rangeApi = apiModule("get_adjustment_range")
  if prime.rangeApi == nil then
    prime.failedIn = "slots"
    fail(drive, prime, "no_api")
    return
  end
  -- The estimate the run started with was the whole table; now the length is known.
  prime.total = 2 + #prime.slotList + #Functions.VALUE_READS
  if #prime.slotList == 0 then
    -- Nothing to read: the board carries no adjustment at all. Straight to the phase that would
    -- otherwise have been entered by the last slot record.
    startDerive(drive, prime)
    return
  end
  prime.phase = M.PHASE_SLOTS
  -- This is the one reply whose arrival could not ask for the next command, so its parse does.
  chain(widget, drive, prime)
end

local function parseSlot(widget, drive, prime, record)
  local parsed = record.api.parse(record.buf)
  local decoded = type(parsed) == "table" and parsed.adjustment_range or nil
  if type(decoded) == "table" then prime.records[record.slot] = decoded end

  if prime.slotList[prime.slotAt] == nil and pendingDepth(prime) <= 0 then
    -- The board's table is in AND every record of it is decoded. Turning it into the set does not
    -- happen here: it is the most expensive single thing this module does and the pass that just
    -- parsed a reply cannot carry it. The prime enters a phase of its own and the next tick takes
    -- the first slice.
    startDerive(drive, prime)
  elseif prime.chainPaused then
    chain(widget, drive, prime)
  end
end

--- Parse ONE stored reply, and no more, however many are waiting.
--
-- Answers true when the pass was spent here, so the caller stops at it.
local function takeReply(widget, drive)
  local prime = drive.prime
  if type(prime) ~= "table" then return false end
  local head = prime.pendingHead
  if head == nil or head > prime.pendingTail then return false end

  local record = prime.pending[head]
  prime.pending[head] = nil
  prime.pendingHead = head + 1
  -- Drained: the counters go back to where a fresh run starts them, so a long prime does not
  -- walk them upward for a whole session.
  if prime.pendingHead > prime.pendingTail then
    prime.pendingHead, prime.pendingTail = 1, 0
  end

  -- A run that was restarted, abandoned or failed since the reply landed keeps none of it. The
  -- pass still counts as spent: discarding a stored reply is what this pass did.
  if not stillCurrent(drive, prime) or type(record) ~= "table" then return true end

  local kind = record.kind
  if kind == "slot" then
    parseSlot(widget, drive, prime, record)
  elseif kind == "functionIds" then
    parseFunctionIds(widget, drive, prime, record)
  elseif kind == "rxmap" then
    parseRxMap(widget, drive, prime, record)
  end
  return true
end

--- Read the receiver map and slot table, then start the multi-profile transaction.
--
-- Refused while armed and without a link. The counters start at the whole table's length and are
-- corrected down once 167 has said how many slots actually carry a function.
function M.start(widget, drive, automatic)
  if type(widget) ~= "table" or type(drive) ~= "table" then return false, "no_drive" end
  if type(widget.state) ~= "table" then return false, "armed" end
  if isArmed(widget) then return false, "armed" end
  if M.isRunning(drive) then return false, "reading" end
  if queueOf() == nil then return false, "no_link" end
  -- A session whose end is still pending ends as this read begins, so the read begins a new one --
  -- also when it is interrupted before its values (Drive:takeExpiry). A profile job still running
  -- belongs to that session and finishes first, as profiles.begin requires. Without a link nothing is
  -- read, and the session is kept for the list on screen until the link is back.
  if drive.sessionExpired then
    if widget.state.fblConnected ~= true then return false, "no_link" end
    if drive.profileJob ~= nil then return false, "reading" end
    drive:takeExpiry()
  end

  local prime = {
    phase = M.PHASE_RXMAP,
    auto = automatic == true,
    done = 0,
    total = 2 + SLOT_COUNT + #Functions.VALUE_READS,
    records = {},
    skipped = {},
    slotList = {},
    slotAt = 1,
    valueAt = 1,
    mapped = 0,
    unmapped = 0,
    pending = {},
    pendingHead = 1,
    pendingTail = 0,
    chainPaused = false
  }
  drive.prime = prime
  -- The verdict on the board belongs to the table that produced it, and this run is about to read
  -- that table again. Leaving the old one up would show a board as matching while its own answer
  -- was still on the wire.
  drive.compare = nil
  -- The wait the pass gate counts belongs to the run that is starting.
  widget._primeSkips = nil
  drive.profileChanged = nil
  drive.primeInterrupted = nil
  bump(drive)
  logPrime("prime started")
  local ok = sendRxMap(widget, drive, prime)
  if ok then
    -- A full read, whoever asked for it, answers every read still asked for: the link's automatic
    -- read and the one an ended session asks for. A run that fails or is armed into is offered
    -- again by M.tick's retry, as before.
    drive.readAgain = nil
    drive._primeAutoDone = true
  end
  return ok
end

-- Refresh uses the completed slot table and existing session membership. Each transaction
-- owns fresh callback identity, so late replies cannot be adopted by a later run.
function M.refreshValues(widget, drive)
  if type(widget) ~= "table" or type(drive) ~= "table" then return false, "no_drive" end
  if type(widget.state) ~= "table" then return false, "armed" end
  if isArmed(widget) then return false, "armed" end
  if M.isRunning(drive) then return false, "reading" end
  if drive.readRequired then return M.start(widget, drive, true) end
  local previous = drive.prime
  if type(previous) ~= "table" or type(previous.records) ~= "table" then
    return M.start(widget, drive)
  end
  if queueOf() == nil then return false, "no_link" end
  local prime = {
    phase = M.PHASE_IDLE,
    refresh = drive.sessionProfiles ~= nil,
    done = 0,
    total = #Functions.VALUE_READS,
    records = previous.records,
    skipped = previous.skipped,
    slotList = previous.slotList,
    slotAt = previous.slotAt,
    rangeApi = previous.rangeApi,
    map = previous.map,
    valueAt = 1,
    mapped = 0,
    unmapped = 0,
    pending = {},
    pendingHead = 1,
    pendingTail = 0,
    chainPaused = false
  }
  drive.prime = prime
  -- The wait this gate counts belongs to the run that is starting, not to the one before it.
  widget._primeSkips = nil
  return startValues(widget, drive, prime)
end

-- ---------------------------------------------------------------------------
-- The undo
-- ---------------------------------------------------------------------------

--- Restores are identity-checked SD transactions, with the original pair always returned.
function M.transferRefusal(widget, drive)
  if isArmed(widget) then return "armed" end
  if M.isRunning(drive) then return "reading" end
  if queueOf() == nil then return "no_link" end
  local board = boardOnLink()
  if board == nil then return "reading" end
  if board ~= drive.board then return "baseline_identity" end
  if not drive.baseline then return "baseline_missing" end
  return nil
end

function M.restore(widget, drive, target)
  -- A session whose end is still pending (a link gap on the ground) has stale start values: they are
  -- not written back. The board is read again instead, and that read begins a new session.
  local expired = type(drive) == "table" and drive.sessionExpired
  local refusal = not expired and M.transferRefusal(widget, drive) or nil
  local ok, reason = false, refusal
  if expired then ok, reason = M.refreshValues(widget, drive)
  elseif not refusal then ok, reason = profileModule().begin(widget, drive, profileEnvironment(), "restore", target) end
  if not ok then
    drive.transfer = {kind = "restore", state = "refused", reason = reason}
    bump(drive)
  end
  return ok, reason
end

function M.retryReturn(drive)
  return profileModule().retryReturn(drive)
end

-- ---------------------------------------------------------------------------
-- The delta
-- ---------------------------------------------------------------------------

--- Every parameter whose cached value has moved away from the snapshot, largest change first.
--
-- Cached against BOTH of the drive's counters, the way the setup check is cached against the
-- clock: the list is built into the tree rather than read by a closure, so it is wanted once per
-- rebuild and a rebuild happens exactly when the layout epoch moves. The report counter is in the
-- key as well because it is the one that moves when the board answers -- a last step reported just
-- after the disarm moves the values without moving the layout epoch, and a list cached against
-- that epoch alone would show the flight one step short.
--
-- Answers nil when there is no snapshot to measure against, which is a different thing from an
-- empty list and is said differently on screen. A second return value names the reason where there
-- is one to name: today the reference belonging to another profile, which is a refusal to compare
-- rather than an absence of anything to compare.
function M.delta(drive)
  local baseline, values = drive.baseline, drive.profileValues
  if not baseline or not values then return nil end
  if drive._deltaEpoch == drive.valueEpoch and drive._deltaReport == drive.reportEpoch and drive._deltaList then
    return drive._deltaList
  end
  local list = {}
  local changes = drive.changes or {pid = {}, rate = {}, global = {}}
  for _, kind in ipairs({"pid", "rate", "global"}) do
    local profiles = kind == "global" and {global = changes.global} or changes[kind]
    for profile, ids in pairs(profiles) do
      local current = kind == "global" and values.global or values[kind][profile]
      local reference = baseline[profileModule().section(kind, profile)] or {}
      for id in pairs(ids) do
        local value = current[id]
        local was = reference[tostring(id)]
        if was ~= nil and was ~= value then
          list[#list + 1] = {id = id, name = Functions.nameOf(id), old = was, new = value,
            difference = value - was, size = math.abs(value - was), group = Functions.groupOf(id),
            scope = kind, profile = profile}
        end
      end
    end
  end
  local order = {pid = 1, rate = 2, global = 3}
  table.sort(list, function(a, b)
    if a.scope ~= b.scope then return order[a.scope] < order[b.scope] end
    if a.profile ~= b.profile then return a.profile < b.profile end
    if a.group ~= b.group then return a.group < b.group end
    return Functions.parameterOrder(a.id) < Functions.parameterOrder(b.id)
  end)
  drive._deltaEpoch, drive._deltaReport, drive._deltaList = drive.valueEpoch, drive.reportEpoch, list
  return list
end

-- ---------------------------------------------------------------------------
-- The widget's side
-- ---------------------------------------------------------------------------

-- What the previous pass may have cost before this one refuses to parse anything.
--
-- The pilot's widget_5.log ends mid-prime -- record 3 of the automatic run right after connect --
-- on the ORDINARY dashboard with the interlock open and a heavy theme, on passes his own trace
-- reports at 84 to 93 per cent of the instruction budget. So keeping the prime from REBUILDING the
-- surface is not enough on a radio like that: the parse itself, priced at up to 933 instructions
-- for a value reply and 151 for a slot record, plus the firmware's sweep of whatever tree is
-- standing, lands on passes that are already close to the limit at start-up.
--
-- A pass killed by that limit is invisible to every sink in the tree -- the sweep runs outside the
-- pcall the entry point wraps refresh in -- so the only witness is a log that stops.
local PARSE_USAGE_LIMIT = 70

-- and how long the gate may hold a run up before it takes a slice anyway.
--
-- Stated rather than left open, because a widget that sits above the limit for ever would leave a
-- prime waiting for ever, and "Priming 3/44" on the screen with nothing moving is a worse answer
-- than one slow slice. At the widget's 50 ms cadence this is five seconds.
local PARSE_SKIP_LIMIT = 100

--- Whether this pass has room for the one piece of optional work the ground half does.
--
-- Two things are asked, and the first is an INVARIANT restated rather than a new rule: the
-- dispatcher in widgets/dashboard/runtime.lua serves a pending job and returns before it reaches
-- the background half at all, so a job pass cannot get here today. It is checked anyway, because
-- what it protects is a build sharing a call with a parse, and that is worth more than the two
-- table reads it costs.
--
-- The second is what the last pass actually cost. Answers false to skip.
--
-- The skips are counted as a TOTAL for the run being held up and not as a streak, and that is the
-- difference between an escape that fires and one that cannot. A streak was reset by every cheap
-- pass, so a widget alternating between an expensive pass and a cheap one -- which is the ordinary
-- shape of a dashboard that rebuilds something on one pass in two -- skipped every other pass for
-- as long as the run lasted and never came within reach of the limit. With no run in progress there
-- is nothing being held up, so the streak reading is kept for that case: it is what lets the
-- automatic run start at all on a widget that never comes below the limit.
function M.passHasRoom(widget, drive)
  if widget._job ~= nil then return false end

  local last = tonumber(widget._usageLast)
  if last == nil or last <= PARSE_USAGE_LIMIT then
    if drive == nil or not M.isRunning(drive) then widget._primeSkips = nil end
    return true
  end

  local skips = (widget._primeSkips or 0) + 1
  if skips >= PARSE_SKIP_LIMIT then
    widget._primeSkips = nil
    logPrime("prime: %d busy pass(es) waited out, taking a slice anyway at %d%%", skips, last)
    return true
  end
  widget._primeSkips = skips
  return false
end

-- A different identified board ends cached membership and layout. A pending transaction is
-- handled before this edge and can only return to its own board.
local function boardChanged(drive, board)
  drive:endSession()
  drive.readRequired = true
  drive.prime = nil
  drive.readAgain = nil
  drive.primeInterrupted = nil
  drive:seedSet()
  drive.profile = nil
  drive.rateProfile = nil
  drive.profileChanged = nil
  drive.profileSettleAt = nil
  drive.profileBannerUntil = nil
  drive._primeAutoDone = false
  drive._primeLinkSince = nil
  drive._primeFails = nil
  drive.board = board
  logPrime("another flight controller answered: the tuning session ended, the board is read again")
end

--- One pass of the ground half.
--
-- Costs two table reads while armed or disconnected, which is what it does for the whole of a
-- flight. The automatic run fires once per connect, and only after the link has stood for long
-- enough that the connect chain is no longer competing for the same queue.
function M.tick(widget, drive)
  if type(widget) ~= "table" or type(drive) ~= "table" then return end
  if type(widget.state) ~= "table" then return end
  if widget.state.fblConnected ~= true then drive:invalidateRead() end

  if drive.fcSetupOpen then
    if drive.fcSurface == nil then
      if widget.state.armed == true then
        drive.fcSetupOpen = nil
        drive.valueEpoch = drive.valueEpoch + 1
        return
      end
      drive.fcWorked = true
      drive.fcSurface = requireModule("widgets/dashboard/inflight/fcsurface.lua")
      collectgarbage("collect")
      return
    end
    drive.fcWorked = drive.fcSurface.tick(widget, drive, M)
    return
  end

  if drive.profileJob ~= nil then
    local job = drive.profileJob
    local board = (job.suspended or job.linkLost) and boardOnLink()
    if board and board ~= job.identity then
      profileModule().drop(drive)
      if job.original then logPrime("original profile return is still owed to flight controller %s", job.identity) end
      boardChanged(drive, board)
      return
    end
    profileModule().tick(widget, drive, M.passHasRoom(widget, drive))
    return
  end

  if isArmed(widget) then
    if M.isRunning(drive) then abandon(drive, drive.prime, "armed") end
    drive._primeLinkSince = nil
    return
  end

  if drive.prime and drive.prime.invalidated then drive.prime = nil end

  if widget.state.fblConnected ~= true then
    if M.isRunning(drive) then abandon(drive, drive.prime, "no_link") end
    drive._primeLinkSince = nil
    drive._primeAutoDone = false
    -- The retry budget is per link session, like the latch above it: a new board is a new answer
    -- to the question of whether it can be read at all.
    drive._primeFails = nil
    return
  end

  -- A reconnect to the same UID keeps its SD baseline; another board starts separately.
  local board = boardOnLink()
  if board ~= nil and board ~= drive.board then
    if drive.board == nil then
      drive.board = board
    else
      boardChanged(drive, board)
    end
  end

  -- Neither the parse below nor the derivation slice after it may go on a pass that is already
  -- expensive. See M.passHasRoom: the pilot's widget_5.log stops mid-prime on an ordinary
  -- dashboard with a heavy theme, on passes his own trace puts at 84 to 93 per cent.
  --
  -- Everything ABOVE this line stays unconditional. The armed check, the abandon and the link
  -- check are what keep MSP away from a helicopter in the air, and they are three table reads.
  if not M.passHasRoom(widget, drive) then return end

  -- One stored reply, parsed here rather than where it arrived, and never more than one however
  -- many the link delivered into the same pass. This is the bound the whole section above exists
  -- for; the derivation slice below is the same rule for the one piece of work no reply drives.
  if takeReply(widget, drive) then return end

  -- The derivation is the one part of a prime that no reply drives, so it is stepped here. It
  -- comes before the auto-start gates below, which return as soon as a run has been started.
  if stepDerivation(widget, drive) then return end

  -- The connect chain owns the queue until it says otherwise. `tasksDone` is the widget's own
  -- reading of that (widgets/dashboard/runtime.lua, updateConnectionState): the onconnect runner
  -- is idle and the MSP progress is complete. Only the AUTOMATIC run is held here -- a pilot who
  -- asks for a prime from the ground screen still gets one straight away.
  if widget.state.tasksDone == false then
    drive._primeLinkSince = nil
    return
  end

  -- Reopening a closed ground session rereads the slot table and starts a new baseline.
  if drive.readAgain == true and drive.phase == DRIVE_PHASE_GROUND and not M.isRunning(drive) then
    if M.start(widget, drive) then
      drive.readAgain = nil
      logPrime("the session was opened again: the value reads are sent")
      return
    end
  end

  -- Failed runs consume the existing per-link retry budget; armed aborts wait for ground.
  if drive._primeAutoDone == true and not M.isRunning(drive) then
    local phase = (type(drive.prime) == "table") and drive.prime.phase or nil
    if phase == M.PHASE_IDLE and drive.primeInterrupted == true then
      drive._primeAutoDone = false
    elseif phase == M.PHASE_ERROR and (drive._primeFails or 0) <= AUTO_RETRY_LIMIT then
      drive._primeAutoDone = false
    end
  end

  local now = drive.radio.now()
  if drive._primeLinkSince == nil then drive._primeLinkSince = now end
  if drive._primeAutoDone == true then return end
  if (now - drive._primeLinkSince) < AUTO_DELAY_TICKS then return end
  if M.isRunning(drive) then return end

  drive._primeAutoDone = true
  M.start(widget, drive, true)
end

return M
