-- Tune Advisor capture: each flight the flight controller measured, saved on the radio.
--
-- The flight controller measures the rate loop while the craft flies (tasks/msp/api/
-- tune_advisor.lua) but keeps it in RAM. After each disarm this reads all three axes, saves them
-- as one flight (lib/tune_history.lua: the last few flights per flight controller), then clears
-- the flight controller so the next flight is measured on its own. The Tune Advisor page works
-- from the saved flights. Nothing is saved for a flight with no acro flight (seconds 0). If the
-- clear never gets through before the next arm, that next flight also holds this one's data:
-- the flight controller cannot tell. The clear owed then is not sent after the arm (nor across a
-- link loss or a stretch with no pass, tasks/events/runtime.lua): it would erase the next flight
-- before it is read. That reading is then saved marked as containing the saved flight, which the
-- page leaves out rather than counting twice, when this capture can tell: no clear answered and
-- no new link since that save, the same profiles and tune, more seconds and no count smaller
-- (containsHeld). Nothing saved is ever removed for it; where it cannot tell, both are kept.
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
-- controller keeps the numbers, so that disarm still saves them. A reply that names another axis
-- than the one asked for is not stored and counts as such an error. A flight that cannot be
-- written to the card is tried again RETRY_SECONDS later, and after MAX_FAILURES failed writes
-- the capture waits for the next disarm too, without clearing the flight controller. Every step
-- that loads a module or writes the card is a pass of its own.
--
-- Only from MSP API 12.10, the first with the command; an unknown version waits and keeps what
-- is owed. A flight controller that answers with an MSP error reply has no such command: the
-- capture stays off until the next connection.
--
-- Without the PID# and RTE# telemetry sensors, MSP_STATUS is read once after the axes and before
-- the save, so the flight is saved under the profiles the flight controller flies now (readProfiles);
-- a read the queue dropped starts the reading again from the first axis, a read that fails is asked
-- again as a failed axis read is (so is a status module that does not load), and a reply that cannot
-- be read saves the flight without profiles.
--
-- After the flight is saved and the clear has gone through, RC_TUNING and PID_PROFILE are read
-- and the cyclic polarity, the cyclic ring and the I-term relax type are added to the flight,
-- since they change what its numbers mean; a value that could not be read stays unknown.
--
-- What the widget state can see of it, in rfsuite.session.tuneCapture:
--   state   "reading" disarmed with this flight not saved yet, or its clear still to go
--           "failed"  gave up after MAX_FAILURES link errors; the next disarm reads it
--           "unsaved" gave up after MAX_FAILURES failed writes to the card; the next disarm
--                     reads it again, with the next flight added
--           "idle"    anything else
--   saved   how many flights were saved and complete (their settings added or given up), so a
--           reader can notice a new one; savedMcu: whose

local M = {}

local GAP_SECONDS = 2             -- between one answered request and the next
local RETRY_SECONDS = 5           -- after a link error, before asking again
local MAX_FAILURES = 3            -- link errors per disarm before waiting for the next one
local UNSEEN_SECONDS = 5          -- passes further apart than this: the craft may have flown unseen
local AXIS_COUNT = 3
local CORE = _G.rfsuite.paths.core .. "/"

-- Loaded one per pass, each dropped again once its step is through, and all of them with this
-- module once the capture is idle. Held together they would be most of what the capture costs
-- in memory, for steps that never need more than one of them.
local TuneAdvisorApi, TuneHistory, ChangeJournal, RcTuningApi, PidProfileApi = nil, nil, nil, nil, nil
local StatusApi = nil

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

local function log(message, level)
  local Log = loadShared("lib/log.lua")
  if type(Log) == "table" and type(Log.emit) == "function" then
    pcall(Log.emit, "rfsuite.tasks.tune_history", message, level or "info")
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
    if tc.nextAt ~= math.huge then
      now = "reading"
    else
      now = tc.unsaved and "unsaved" or "failed"
    end
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
  tc.profilesRead = nil
  tc.profilesUnknown = nil
  tc.saveDue = false
  tc.job = nil
end

-- A flight that could not be written: the replies are kept and only the write is tried again,
-- RETRY_SECONDS later. The flight controller is not cleared, so an arm before it succeeds still
-- leaves the numbers for the next disarm. After MAX_FAILURES failed writes (a full or
-- write-protected card, or a history file the reader refuses) nothing more until the next
-- disarm, which reads the flight controller again.
local function writeFailed(tc, why)
  tc.writeFailures = (tc.writeFailures or 0) + 1
  ChangeJournal = nil         -- the next try takes the clock again
  if tc.writeFailures >= MAX_FAILURES then
    log("cannot write the flight history: " .. tostring(why) .. "; given up until the next disarm", "warn")
    clearReplies(tc)
    TuneHistory = nil
    tc.unsaved = true
    tc.busy = false
    tc.nextAt = math.huge
    return
  end
  log("cannot write the flight history: " .. tostring(why) .. "; tried again shortly", "warn")
  waitFor(tc, RETRY_SECONDS)
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
      -- A reply carries only the command number, so a late answer to an earlier request can
      -- arrive here: stored, it would put another axis's numbers under this one
      if data.axis ~= axis then
        log(string.format("reply names axis %s, asked for %d: not stored, asked again", tostring(data.axis), axis), "warn")
        failed(tc)
        publishState(tc)
        return
      end
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
    -- Asked before every send of it: only while still owed (an arm or a link loss drops it,
    -- tasks/events/runtime.lua), and not after a stretch with no pass or a clock that went back.
    -- The queue ticks before the events runtime, so on the first pass after such a pause only this
    -- can stop a retry.
    sendIf = function()
      local seen = tc.seenAt
      if seen == nil then return tc.clearPending == true end
      local age = nowSeconds() - seen
      return tc.clearPending == true and age >= 0 and age <= UNSEEN_SECONDS
    end,
    processReply = function(msg)
      if msg.__errorReply then handleError(tc, "nocommand"); return end
      tc.clearPending = false
      -- The statistics are gone from the flight controller: its next flight is a new one, even
      -- with the same flight time as the one just saved, and contains none saved before
      if tc.clearMcu ~= nil then
        tc.lastSeconds[tc.clearMcu] = nil
        if tc.held then tc.held[tc.clearMcu] = nil end
      end
      tc.clearMcu = nil
      TuneAdvisorApi = nil
      waitFor(tc, tc.contextPending and GAP_SECONDS or 0)
      publishState(tc)
    end,
    errorHandler = function(_, reason)
      -- Withheld (see sendIf), or dropped by the queue (an arm, a link loss however short): the
      -- craft may fly before it could be sent again, so it is not owed any more
      if reason == "withheld" or reason == "cleared" then
        log("clear " .. tostring(reason) .. ": not sent again; the next disarm reads first", "debug")
        tc.clearPending, tc.clearMcu = false, nil
        waitFor(tc, tc.contextPending and GAP_SECONDS or 0)
        publishState(tc)
        return
      end
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

-- Whether both profiles come from the telemetry right now (PID#, RTE#). Without these sensors
-- the session holds what the flight controller reported at connect, which a switch on the
-- transmitter does not change.
local function profilesLive()
  local Profile = loadShared("lib/profile.lua")
  if type(Profile) ~= "table" or type(Profile.getLive) ~= "function" then return false end
  local okP, pid = pcall(Profile.getLive, "pid")
  local okR, rate = pcall(Profile.getLive, "rate")
  return okP and pid ~= nil and okR and rate ~= nil
end

-- Without the profile sensors: one MSP_STATUS read after the axes and before the save, so the
-- flight is saved under the profiles the flight controller flies now, and the session -- what
-- the Tune Advisor page takes for the active profiles -- follows a switch made on the
-- transmitter. A read the queue dropped (a link loss, however short) is "cleared" as a dropped axis
-- read is (handleError): the flight controller may have flown or restarted meanwhile, so the axes
-- are read again before anything is saved or cleared. A read that fails on the link counts as a
-- failed axis read does (failed): asked again RETRY_SECONDS later, and after MAX_FAILURES nothing more
-- until the next disarm, with nothing saved and nothing cleared, so that disarm reads the flight
-- again. The session's profiles are never taken instead: a switch on the transmitter does not
-- change them. A reply that cannot be read would come back the same, so the flight is saved
-- without profiles; such a flight is never combined with any.
-- The rate profile index is byte 26 of MSP_STATUS (tasks/msp/api/status.lua). Its parser reads a
-- missing byte as 0, so a reply cut shorter would name PID 1 and rates 1: it is taken as not
-- understood instead.
local STATUS_PROFILE_BYTES = 26

local function readProfiles(tc, queue)
  tc.busy = true
  local api = StatusApi
  queue:add({
    command = api.command,
    isWrite = false,
    maxRetries = 2,
    simulatorResponse = api.simulatorResponse,
    processReply = function(_, buf)
      local p = type(buf) == "table" and #buf >= STATUS_PROFILE_BYTES and api.parse(buf) or nil
      local pid = p and tonumber(p.current_pid_profile_index)
      local rate = p and tonumber(p.current_control_rate_profile_index)
      if pid and rate then
        local Profile = loadShared("lib/profile.lua")
        if type(Profile) == "table" then
          pcall(Profile.setSessionPidProfile, pid)
          pcall(Profile.setSessionRateProfile, rate)
        end
        log(string.format("profiles read for the save: PID %s, rates %s", tostring(pid + 1), tostring(rate + 1)),
          "debug")
      else
        log("profile read not understood; the flight is saved without profiles", "warn")
        tc.profilesUnknown = true
      end
      tc.profilesRead = true
      StatusApi = nil
      waitFor(tc, GAP_SECONDS)
      publishState(tc)
    end,
    errorHandler = function(_, reason)
      StatusApi = nil
      if reason == "cleared" then
        log("profile read dropped by the queue; the axes are read again", "debug")
        handleError(tc, "cleared")
        return
      end
      log("profile read failed (" .. tostring(reason) .. "); asked again", "info")
      failed(tc)
      publishState(tc)
    end,
  })
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

-- The counts the flight controller only ever adds to until its statistics are reset
-- (src/main/flight/tune_advisor.c): a reading that holds a saved flight has none smaller than it.
-- Not ffCount, which is the count of the best feedforward lag, and that lag can move.
local GROWING = { "fullCount", "fullSatCount", "releases", "bigRebounds", "shakeCount" }

-- What a later reading is checked against (held): per axis the tune bytes and the counts, in one
-- array, with the profiles, the radio time and the seconds the flight was saved with
local function heldOf(replies, tuneKeys, pid, rate, time, seconds)
  local v, n = {}, 0
  for axis = 1, AXIS_COUNT do
    local a = replies[axis].a
    for _, k in ipairs(tuneKeys) do n = n + 1; v[n] = a[k] end
    for _, k in ipairs(GROWING) do n = n + 1; v[n] = a[k] or 0 end
    for i = 1, 3 do
      n = n + 1; v[n] = a.spBands[i].count
      n = n + 1; v[n] = a.collBands[i].count
    end
  end
  return { pid = pid, rate = rate, time = time, seconds = seconds, v = v }
end

-- Whether this reading holds the held flight as well: the flight controller was not cleared
-- since it was saved (a clear the board answered drops it, and so does a new link -- a pack
-- swapped restarts the board), it flew on the same profiles and tune (any change restarts its
-- statistics), it counts more seconds, and none of its counts is smaller. False and the first
-- test that failed otherwise.
local function containsHeld(held, replies, tuneKeys, pid, rate, seconds)
  if not held then return false, "no saved flight held" end
  if pid == nil or rate == nil or pid ~= held.pid or rate ~= held.rate then return false, "profiles" end
  if seconds <= held.seconds then return false, "seconds" end
  local v, n = held.v, 0
  for axis = 1, AXIS_COUNT do
    local a = replies[axis].a
    for _, k in ipairs(tuneKeys) do
      n = n + 1
      if a[k] ~= v[n] then return false, "tune" end
    end
    for _, k in ipairs(GROWING) do
      n = n + 1
      if (a[k] or 0) < v[n] then return false, "count" end
    end
    for i = 1, 3 do
      n = n + 1
      if a.spBands[i].count < v[n] then return false, "count" end
      n = n + 1
      if a.collBands[i].count < v[n] then return false, "count" end
    end
  end
  return true
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
      -- The flight controller's answer could not be read: no profiles rather than the session's
      if tc.profilesUnknown then pid, rate = nil, nil end
      local time = ChangeJournal and ChangeJournal.timestamp and ChangeJournal.timestamp() or 0
      ChangeJournal = false       -- its clock was all the save needed of it
      -- A flight saved before and not cleared off the board since: this reading may hold it too
      local held = tc.held and tc.held[mcuId]
      local previous = nil
      if held then
        local contains, why = containsHeld(held, replies, TuneHistory.TUNE_KEYS, pid, rate, seconds)
        if contains then
          previous = { time = held.time, seconds = held.seconds }
          log(string.format("reading of %s s holds the saved %s s flight: the board was not cleared", seconds,
            held.seconds), "debug")
        else
          log("the saved flight is not held in this reading (" .. tostring(why) .. ")", "debug")
        end
      end
      job = TuneHistory and TuneHistory.saveJob(mcuId, replies, { pidProfile = pid, rateProfile = rate }, time,
        previous)
      if not job then
        writeFailed(tc, "module")
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
      -- No MSP, so not counted against the link errors' MAX_FAILURES; its own count instead
      writeFailed(tc, why)
      return
    end
    tc.lastSeconds[mcuId] = seconds
    tc.held = tc.held or {}
    tc.held[mcuId] = heldOf(replies, TuneHistory.TUNE_KEYS, flown and flown.pidProfile, flown and flown.rateProfile,
      job.time, seconds)
    if job.marked then
      log("flight saved as containing the one before it, which the advice now leaves out", "info")
    end
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
      if tc.profilesRead or profilesLive() then
        finishCapture(tc, tc.mcuId)
      elseif StatusApi == nil then
        StatusApi = loadPlain("tasks/msp/api/status.lua")
      elseif StatusApi then
        readProfiles(tc, queue)
      else
        -- No status module (low memory): as a failed read, loaded again on the next try, and
        -- never the session's profiles in its place
        log("status module not loaded; the profiles are asked again", "info")
        StatusApi = nil
        failed(tc)
      end
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
