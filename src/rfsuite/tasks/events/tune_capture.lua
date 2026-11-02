-- Tune Advisor capture: each flight the flight controller measured, saved on the radio.
--
-- The flight controller measures the rate loop while the craft flies (tasks/msp/api/
-- tune_advisor.lua) but keeps it in RAM. After each disarm this reads all three axes, saves them
-- as one flight (lib/tune_history.lua: the last few flights per flight controller), then clears
-- the flight controller so the next flight is measured on its own. The Tune Advisor page works
-- from the saved flights. Nothing is saved for a flight with no acro flight (seconds 0). If the
-- clear never gets through before the next arm, that next flight also holds this one's data:
-- the flight controller cannot tell.
--
-- Three files, and the state of a capture in none of them:
--   * The ondisarm task tasks/events/ondisarm/tasks/tune_history.lua (last in the ondisarm
--     manifest, widget only) marks each disarm's flight owed and reports itself complete in the
--     same call, so the disarm chain is never held by it.
--   * tasks/events/runtime.lua calls tick() below on the widget's passes while a capture has
--     work, and loads this file only once the capture is due. It also marks a flight owed when a
--     flight kept across a link loss turns out to have ended in the gap (endKeptFlight): the
--     flight controller kept the numbers, so the flight is read once the link and the board's
--     identity are back.
--   * A capture runs for longer than the runner's task timeout, outlives the runner's reset when
--     the link drops, and must survive the next arm with a clear still owed, so its state is kept
--     in rfsuite.session.tuneCapture and this module holds nothing a reload would lose.
--
-- Paced so telemetry keeps flowing. Over S.Port and FBUS each 51-byte reply takes 12 telemetry
-- frames, every one a sensor frame the flight controller does not send, and it then holds
-- sensors back for another 250 ms. So the first read waits five seconds after the disarm (the
-- pilot is reading the landing numbers, and the flight statistics are read first), each later
-- request waits GAP_SECONDS after the answer before it, a failed axis is asked again on its own,
-- and after MAX_FAILURES link errors the capture waits for the next disarm. The flight
-- controller keeps the numbers, so that disarm still saves them. Every step that loads a module
-- or writes the card is a pass of its own.
--
-- Only from MSP API 12.10, the first with the command; an unknown version waits and keeps what
-- is owed. A flight controller that answers with an MSP error reply has no such command: the
-- capture stays off until the next connection.
--
-- After the flight is saved and the clear has gone through, RC_TUNING and PID_PROFILE are read
-- and the cyclic polarity, the cyclic ring and the I-term relax type are added to the flight,
-- since they change what its numbers mean; a value that could not be read stays unknown.
--
-- What the widget state can see of it, in rfsuite.session.tuneCapture:
--   state   "reading" disarmed with this flight not saved yet, or its clear still to go
--           "failed"  gave up after MAX_FAILURES; the next disarm reads it
--           "idle"    anything else
--   saved   how many flights were saved and complete (their settings added or given up), so a
--           reader can notice a new one; savedMcu: whose

local M = {}

local GAP_SECONDS = 2             -- between one answered request and the next
local RETRY_SECONDS = 5           -- after a link error, before asking again
local MAX_FAILURES = 3            -- link errors per disarm before waiting for the next one
local AXIS_COUNT = 3
local CORE = "/SCRIPTS/TOOLS/rfsuite-core/"

-- Loaded one per pass, each dropped again once its step is through, and all of them with this
-- module once the capture is idle. Held together they would be most of what the capture costs
-- in memory, for steps that never need more than one of them.
local TuneAdvisorApi, TuneHistory, ChangeJournal, RcTuningApi, PidProfileApi = nil, nil, nil, nil, nil

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, v = pcall(getTime)
    if ok and type(v) == "number" then return v / 100 end
  end
  return 0
end

-- Not kept by lib/require.lua, nor by the caching loader of a tool the dashboard hosts
-- (widgets/dashboard/tool_host.lua): these leave with this module
local function loadPlain(path)
  local utils = _G.rfsuite and _G.rfsuite.utils
  local loader = utils and utils.loadScriptUncached or loadScript
  local chunk = loader(CORE .. path, (_G.rfsuite and _G.rfsuite.loadMode) or "bt")
  if type(chunk) ~= "function" then return false end
  local ok, mod = pcall(chunk)
  if not ok or type(mod) ~= "table" then return false end
  return mod
end

local function loadShared(path)
  local req = _G.rfsuite and _G.rfsuite.require
  if type(req) == "function" then return req(path) or false end
  return loadPlain(path)
end

local function session()
  local root = _G.rfsuite
  return type(root) == "table" and type(root.session) == "table" and root.session or nil
end

local function log(message)
  local Log = loadShared("lib/log.lua")
  if type(Log) == "table" and type(Log.emit) == "function" then
    pcall(Log.emit, "rfsuite.tasks.tune_history", message, "info")
  end
end

--- Whether the flight controller has the command, from the MSP API version the session holds:
--- true from 12.10, false before it, nil while the version is not known.
function M.supportFor(apiVersion)
  local major, minor = string.match(tostring(apiVersion or ""), "^(%d+)%.(%d+)$")
  major, minor = tonumber(major), tonumber(minor)
  if not major or (major == 0 and minor == 0) then return nil end
  return major * 100 + minor >= 1210
end

-- A saved flight is complete once its settings are added or given up, and only then is a reader
-- told (saved, savedMcu): told at the save, the page would read the flight with its settings
-- still unknown, and nothing would tell it again.
local function announce(tc)
  local ctx = tc.context
  if ctx then
    tc.saved = (tc.saved or 0) + 1
    tc.savedMcu = ctx.mcuId
  end
end

-- The settings reads owed to a saved flight are given up: the flight stays saved, its context
-- unknown
local function dropContext(tc)
  if tc.contextPending then announce(tc) end
  tc.contextPending = false
  tc.context = nil
end

local function publishState(tc)
  local now
  if tc.pending then
    now = tc.nextAt == math.huge and "failed" or "reading"
  elseif tc.clearPending and not tc.refusedOnFc and tc.nextAt ~= math.huge then
    now = "reading"
  else
    now = "idle"
  end
  tc.state = now
end

local function waitFor(tc, seconds)
  tc.busy = false
  tc.nextAt = nowSeconds() + seconds
end

-- A link error, or replies that are not one flight. After MAX_FAILURES, nothing more until the
-- next disarm resets the count.
local function failed(tc)
  tc.failures = tc.failures + 1
  if tc.failures >= MAX_FAILURES then
    tc.busy = false
    tc.nextAt = math.huge
    -- Nothing runs again before the next disarm, which starts afresh
    dropContext(tc)
    return
  end
  waitFor(tc, RETRY_SECONDS)
end

local function clearReplies(tc)
  tc.replies = {}
  tc.saveDue = false
  tc.job = nil
end

-- The four answers a request can end in, and only the last is worth repeating.
--   "nocommand"  the flight controller's MSP error reply: this firmware has no such command.
--                Nothing to capture and nothing to clear, and the capture stays off until the
--                next connection.
--   "refused"    an answer in a layout this suite does not know (tasks/msp/api/tune_advisor.lua
--                refuses it). The same reply would come back on every request, so this flight is
--                not captured and the next disarm asks again, once. The clear is left owed on
--                purpose and not sent: the flight controller holds a real flight, and clearing it
--                would throw away data a newer suite could read.
--   "cleared"    the queue dropped the request (arming, a link loss). Not this request's fault,
--                so not counted against MAX_FAILURES. The axes already read are dropped: the
--                flight controller may have restarted, and its next answers would be another
--                flight's.
--   anything else  the link. Asked again shortly, from the axis that failed; the axes already
--                read are kept.
local function handleError(tc, reason)
  if reason == "nocommand" then
    clearReplies(tc)
    tc.busy = false
    tc.pending = false
    tc.clearPending = false
    dropContext(tc)
    tc.noCommand = true
  elseif reason == "refused" then
    clearReplies(tc)
    tc.busy = false
    tc.pending = false
    tc.refusedOnFc = true
    log("reply refused, flight not captured")
  elseif reason == "cleared" then
    clearReplies(tc)
    waitFor(tc, RETRY_SECONDS)
  else
    failed(tc)
  end
  publishState(tc)
end

local function queueOf(mspState)
  return type(mspState) == "table" and mspState.queue or nil
end

local function requestAxis(tc, queue, axis)
  local api = TuneAdvisorApi
  tc.busy = true
  queue:add({
    command = api.command,
    payload = { axis - 1 },
    isWrite = false,
    -- Three sends at most, then the error handler: a capture retried every few seconds on a
    -- link that drops replies is what the pacing above exists to avoid.
    maxRetries = 2,
    -- The error reply of a firmware without the command reaches processReply, marked by the
    -- queue, instead of being sent again.
    completeOnErrorReplyAttempt = 1,
    simulatorResponse = api.simulatorResponseFor(axis),
    processReply = function(msg, buf)
      if msg.__errorReply then handleError(tc, "nocommand"); return end
      local data = api.parse(buf)
      if not data then handleError(tc, "refused"); return end
      local replies = tc.replies
      replies[#replies + 1] = data
      if #replies < AXIS_COUNT then
        waitFor(tc, GAP_SECONDS)
      else
        tc.saveDue = true
        waitFor(tc, 0)
      end
      publishState(tc)
    end,
    errorHandler = function(_, reason)
      handleError(tc, reason == "refused" and "nocommand" or reason)
    end,
  })
end

local function sendClear(tc, queue)
  tc.busy = true
  queue:add({
    command = TuneAdvisorApi.writeCommand,
    payload = {},
    isWrite = true,
    completeOnErrorReplyAttempt = 1,
    simulatorResponse = {},
    processReply = function(msg)
      if msg.__errorReply then handleError(tc, "nocommand"); return end
      tc.clearPending = false
      -- The statistics are gone from the flight controller: its next flight is a new one, even
      -- with the same flight time as the one just saved
      if tc.clearMcu ~= nil then tc.lastSeconds[tc.clearMcu] = nil end
      tc.clearMcu = nil
      TuneAdvisorApi = nil
      waitFor(tc, tc.contextPending and GAP_SECONDS or 0)
      publishState(tc)
    end,
    errorHandler = function(_, reason)
      handleError(tc, reason == "refused" and "nocommand" or reason)
    end,
  })
end

local function activeProfiles()
  local Profile = loadShared("lib/profile.lua")
  if type(Profile) ~= "table" then return nil, nil end
  local okP, pid = pcall(Profile.getActivePidProfile)
  local okR, rate = pcall(Profile.getActiveRateProfile)
  return okP and pid or nil, okR and rate or nil
end

-- The settings are read from the active profiles, so they are the flight's only while those are
-- the profiles it was flown on; after a switch they would be another profile's.
local function flownProfilesActive(ctx)
  if ctx.flownPid == nil or ctx.flownRate == nil then return false end
  local pid, rate = activeProfiles()
  return pid == ctx.flownPid and rate == ctx.flownRate
end

-- After the clear: one read for each of the two settings the flight's numbers depend on. A read
-- that fails, or is answered after a profile switch, leaves its value unknown; only a dropped
-- request is asked again.
local function readContext(tc, queue, api, onParsed)
  tc.busy = true
  queue:add({
    command = api.command,
    isWrite = false,
    maxRetries = 2,
    simulatorResponse = api.simulatorResponse,
    processReply = function(_, buf)
      local parsed = api.parse(buf)
      if type(parsed) == "table" and flownProfilesActive(tc.context) then onParsed(parsed) end
      tc.context.step = tc.context.step + 1
      waitFor(tc, GAP_SECONDS)
    end,
    errorHandler = function(_, reason)
      if reason ~= "cleared" then tc.context.step = tc.context.step + 1 end
      waitFor(tc, reason == "cleared" and RETRY_SECONDS or GAP_SECONDS)
    end,
  })
end

-- All three axes are in: save them as one flight. Each call is one pass: a module to load, or
-- the save itself.
local function finishCapture(tc, mcuId)
  if TuneHistory == nil then TuneHistory = loadPlain("lib/tune_history.lua"); return end
  if ChangeJournal == nil then ChangeJournal = loadPlain("lib/change_journal.lua"); return end

  local replies = tc.replies
  local seconds = replies[1].seconds
  -- One flight has one flight time on every axis. Anything else is a flight controller that
  -- restarted or flew between two reads: start again.
  for i = 2, #replies do
    if replies[i].seconds ~= seconds then
      clearReplies(tc)
      failed(tc)
      return
    end
  end
  -- 0: no acro flight. Same as last time: the clear after that flight never got through and
  -- nothing new was flown.
  local saved, flown = false, nil
  if seconds > 0 and tc.lastSeconds[mcuId] ~= seconds then
    -- The save is a job of a few steps, one per pass (lib/tune_history.lua, step)
    local job = tc.job
    if not job then
      local pid, rate = activeProfiles()
      local time = ChangeJournal and ChangeJournal.timestamp and ChangeJournal.timestamp() or 0
      ChangeJournal = false       -- its clock was all the save needed of it
      job = TuneHistory and TuneHistory.saveJob(mcuId, replies, { pidProfile = pid, rateProfile = rate }, time)
      if not job then
        log("cannot write the flight history: module")
        ChangeJournal = nil
        waitFor(tc, RETRY_SECONDS)
        return
      end
      tc.job = job
      return
    end
    local ok, why = TuneHistory.step(job)
    if ok == nil then return end
    tc.job = nil
    flown = job.context
    if not ok then
      -- The replies are kept and only the write is tried again: no MSP, so not counted against
      -- MAX_FAILURES. The flight controller is not cleared, so an arm before it succeeds still
      -- leaves the numbers for the next disarm.
      log("cannot write the flight history: " .. tostring(why))
      ChangeJournal = nil         -- the next try takes the clock again
      waitFor(tc, RETRY_SECONDS)
      return
    end
    tc.lastSeconds[mcuId] = seconds
    saved = true
  end
  clearReplies(tc)
  TuneHistory, ChangeJournal = nil, nil
  tc.pending = false
  if seconds > 0 then
    tc.clearPending = true
    tc.clearMcu = mcuId
  end
  if saved then
    tc.contextPending = true
    tc.context = { mcuId = mcuId, step = 1,
      flownPid = flown and flown.pidProfile, flownRate = flown and flown.rateProfile }
  end
  waitFor(tc, GAP_SECONDS)
end

-- The context reads, then the one write that adds them to the flight
local function advanceContext(tc, queue)
  local ctx = tc.context
  -- Not the profiles the flight was flown on: its settings stay unknown
  if ctx.step < 3 and not flownProfilesActive(ctx) then ctx.step = 3 end
  if ctx.step == 1 then
    if RcTuningApi == nil then RcTuningApi = loadPlain("tasks/msp/api/rc_tuning.lua"); return end
    if not RcTuningApi then ctx.step = 2; return end
    readContext(tc, queue, RcTuningApi, function(p)
      ctx.cyclicPolarity = tonumber(p.cyclic_polarity)
      ctx.cyclicRing = tonumber(p.cyclic_ring)
    end)
  elseif ctx.step == 2 then
    RcTuningApi = nil
    if PidProfileApi == nil then PidProfileApi = loadPlain("tasks/msp/api/pid_profile.lua"); return end
    if not PidProfileApi then ctx.step = 3; return end
    readContext(tc, queue, PidProfileApi, function(p) ctx.relaxType = tonumber(p.iterm_relax_type) end)
  else
    PidProfileApi = nil
    if ctx.cyclicPolarity ~= nil or ctx.cyclicRing ~= nil or ctx.relaxType ~= nil then
      if TuneHistory == nil then TuneHistory = loadPlain("lib/tune_history.lua"); return end
      if not ctx.job then
        ctx.job = TuneHistory and TuneHistory.contextJob(ctx.mcuId, ctx) or false
        if ctx.job then return end
      end
      if ctx.job then
        local ok = TuneHistory.step(ctx.job)
        if ok == nil then return end
        if not ok then log("cannot add the settings to the saved flight") end
      end
    end
    TuneHistory = nil
    dropContext(tc)
    waitFor(tc, 0)
  end
end

--- One pass of the capture: sends the next request when one is due, or does the next step.
--- `linkUp` is the runtime's held link state. Returns true while the capture has work, so the
--- caller knows whether to keep this module loaded.
function M.tick(tc, mspState, linkUp, now)
  if type(tc) ~= "table" then return false end
  local s = session()
  local apiVersion = s and s.apiVersion
  local support = M.supportFor(apiVersion)
  if support == false or tc.noCommand then
    -- Nothing is sent, and what was owed is dropped. A version not known yet waits instead,
    -- with everything kept, so a flight still in the flight controller is read once it is.
    tc.pending, tc.clearPending, tc.busy = false, false, false
    dropContext(tc)
    publishState(tc)
    return false
  end
  -- A clear owed over a refused flight is not sent (see handleError), so it is no work either
  local work = tc.pending or (tc.clearPending and not tc.refusedOnFc) or tc.contextPending
  if not work then return tc.busy == true end
  if support ~= true or tc.busy or linkUp ~= true then return true end
  local mcuId = s and s.mcu_id
  if mcuId == nil or (type(mspState) == "table" and mspState.unsupportedApi == true) then return true end
  -- A clear and the settings reads belong to the flight controller that flew the flight. Sent to
  -- another, the clear would erase a flight it has not saved and the reads would write its
  -- settings into this one's flight: both are dropped.
  if tc.clearPending and tc.clearMcu ~= mcuId then tc.clearPending, tc.clearMcu = false, nil end
  if tc.contextPending and not (tc.context and tc.context.mcuId == mcuId) then dropContext(tc) end
  -- Given up until the next disarm: nothing to keep this module loaded for
  if now < (tc.nextAt or 0) then return tc.nextAt ~= math.huge end
  local queue = queueOf(mspState)
  if not queue then return true end

  if TuneAdvisorApi == nil then
    TuneAdvisorApi = loadPlain("tasks/msp/api/tune_advisor.lua")
    return true
  end
  if not TuneAdvisorApi then
    tc.pending, tc.clearPending = false, false
    dropContext(tc)
    publishState(tc)
    return false
  end

  if tc.pending then
    -- Another flight controller since the last answer: its axes, not these
    if #tc.replies > 0 and tc.mcuId ~= mcuId then clearReplies(tc) end
    if #tc.replies == 0 then
      tc.refusedOnFc = false
      tc.mcuId = mcuId
    end
    if tc.saveDue or #tc.replies >= AXIS_COUNT then
      finishCapture(tc, tc.mcuId)
    else
      requestAxis(tc, queue, #tc.replies + 1)
    end
  elseif tc.clearPending and not tc.refusedOnFc then
    sendClear(tc, queue)
  elseif tc.contextPending then
    advanceContext(tc, queue)
  end
  publishState(tc)
  return true
end

return M
