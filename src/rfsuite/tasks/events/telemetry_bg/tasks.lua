local M = {}

local Drain = nil
local Smart = nil
local Adjustments = nil
local tellerStageSpent = false
local tellerAside = false

local function loadModule(path)
  local fullPath = _G.rfsuite.paths.core .. "/" .. path
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(fullPath, mode)
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local function nowSeconds()
    if type(getTime) == "function" then
        local ok, v = pcall(getTime)
        if ok and type(v) == "number" then return v / 100 end
    end
    if type(os) == "table" and type(os.clock) == "function" then return os.clock() end
    return 0
end

-- The drain is the one module here that is asked for again after a failed load, once per
-- DRAIN_RETRY_SECONDS, as drain.lua does for its own two. The loader's pcall also catches the
-- radio's instruction limit, so a failure can be a pass that ran out rather than a file that is
-- not there, and the drain is what publishes the armed state tasks/msp/runtime.lua stops on:
-- `false` for good would leave the MSP gate blind for as long as this Lua state lives.
local DRAIN_RETRY_SECONDS = 1.0
local drainRetryAt = 0
-- A failed load of the drain is logged once per streak, and its recovery once. The drain's own
-- logger cannot say it, since it is the module that did not load.
local drainLoadFailing = false

local function logDrainLoad(level, msg)
    local root = _G.rfsuite
    local L = root and root.Log
    if type(L) == "table" and type(L.emit) == "function" then
        pcall(L.emit, "rfsuite.decoder", msg, level)
    end
end

-- Whether this call is spent on the drain's load: the first call, and the first after the wait
-- that follows a failed one. Shared by both passes, so they share the wait too.
local function drainLoadStep(now)
    if Drain == false and now < drainRetryAt then return false end
    Drain = loadModule("tasks/events/telemetry_bg/drain.lua") or false
    if not Drain then
        drainRetryAt = now + DRAIN_RETRY_SECONDS
        if not drainLoadFailing then
            drainLoadFailing = true
            logDrainLoad("warn", "the telemetry decoder failed to load, asked again every 1 s")
        end
    elseif drainLoadFailing then
        drainLoadFailing = false
        logDrainLoad("info", "the telemetry decoder loaded after a failed attempt")
    end
    return true
end

function M.wakeup(carry)
    -- One module per wakeup: each of these pulls in a subtree of its own -- smart.lua alone
    -- reaches the sensor library, the reserve helper and the logger, and drain.lua reaches
    -- the decoder table and the CRSF multiplexer -- and loading them together puts every one
    -- of those top-level chunks into a single widget pass, which is the pass class that runs
    -- closest to the firmware's per-call instruction limit.
    --
    -- `false` rather than a retry: with `not Smart` as the test a module that cannot be
    -- loaded is asked for again on every wakeup, which is a failing card read ten times a
    -- second for as long as the radio is on. Every use below is already guarded, so a
    -- module that is genuinely absent stays absent cheaply. The drain is the exception, asked
    -- for again once a second (drainLoadStep); the stages below go on while it waits.
    if not Drain and drainLoadStep(nowSeconds()) then return end
    if Smart == nil then
        Smart = loadModule("tasks/events/telemetry_bg/smart.lua") or false
        return
    end
    -- The teller only while adjustment announcements are on, which they are not by default; the
    -- switch is read again on every pass until then, so turning it on loads it on a pass of its
    -- own. The in-flight tuning overlay may have loaded it already for its own speech, and that
    -- one instance is taken over rather than loaded again, so the step-aside reset below still
    -- reaches it.
    --
    -- With the setting off, or with the overlay's teller taken over, the pass the teller would
    -- have loaded on is still spent, once, doing nothing: every later start-up step then lands on
    -- the wakeup it always had. Moved one pass
    -- earlier, the decoder table's load meets another start-up step -- in bin/accounting
    -- `pass.startup.worst` went up by about 1 100 instructions and `unit.events.wakeup.armed`
    -- by about 900 -- for a saving of one 50 ms pass.
    if Adjustments == nil then
        local root = _G.rfsuite
        local shared = root and root.adjustmentAnnouncer
        if type(shared) == "table" then
            Adjustments = shared
        else
            local prefs = root and root.preferences
            local events = prefs and prefs.audio_events
            if events and events.adjustment_events == true then
                Adjustments = loadModule("tasks/events/telemetry_bg/adjustments.lua") or false
                return
            end
        end
        if not tellerStageSpent then
            tellerStageSpent = true
            return
        end
    end

    local now = nowSeconds()

    -- The background function script drains and tells for the whole radio while it is running,
    -- so this pass does neither: the sensors it would publish are already on the radio, and the
    -- teller would announce the same adjustment a second time. Both are dropped together, never
    -- one without the other.
    --
    -- Smart is NOT part of the handover. Its inputs are MSP-derived and its state is per Lua
    -- state, so the script has no way to compute it for this one.
    local remote = Drain and Drain.remoteAlive(now)

    local popped = 0
    if Drain and not remote then
        popped = Drain.wakeup(now) or 0
    end

    -- When the flight controller's own telemetry was last seen arriving: frames taken here, or
    -- another state's drain moving, which it does only on frames it took. lib/audio.lua reads it
    -- to hear a flight controller that has stopped sending while the RF link is still up --
    -- the receiver's link statistics keep getRSSI() above zero then, so nothing else notices.
    if remote or popped > 0 then
        local session = _G.rfsuite and _G.rfsuite.session
        if session then session.telemetryFrameAt = now end
    end

    -- Not on a pass the dashboard is spending on its telemetry read (`carry`, handed on by
    -- tasks/events/runtime.lua). SmartFuel keeps its own 1.0 s interval and wakes on the next
    -- logic tick instead, so the read that picks its value up is at most 0.4 s after the wake --
    -- the same as in every phase where the two did not coincide.
    if not carry and Smart and type(Smart.wakeup) == "function" then
        Smart.wakeup()
    end

    -- After the decode, never before it: what the teller reads is what the drain has just
    -- decoded, so the other order would announce one pass behind.
    --
    -- The teller is reset when it steps aside, so that when it takes over again it starts as a
    -- new teller does: a report still standing at that moment is one the script has already
    -- announced, and only a new teller joins it without a word.
    --
    -- The pair this state decoded last goes with it: the other state decodes from then on, and
    -- the pair held here would be out of date when this one takes over again. So the first
    -- report decoded after taking over is the one joined.
    if remote then
        if not tellerAside then
            if Adjustments and type(Adjustments.reset) == "function" then
                Adjustments.reset()
            end
            local root = _G.rfsuite
            if root then root.adjustmentReport = nil end
            if type(Drain.logEdge) == "function" then
                Drain.logEdge("stands aside: another Lua state is decoding, drain and teller paused")
            end
        end
        tellerAside = true
    else
        if tellerAside and Drain and type(Drain.logEdge) == "function" then
            Drain.logEdge("takes over decoding: no other decoder seen for 1 s")
        end
        tellerAside = false
        if Adjustments and type(Adjustments.wakeup) == "function" then
            Adjustments.wakeup()
        end
    end
end

--- The pass a widget runs while its connect tasks hold M.wakeup back (tasks/events/runtime.lua): the
-- drain module alone, publishing the armed state (the arming flags, or the System Status word) and
-- nothing else. SmartFuel and the adjustment
-- teller are not loaded or woken here; M.wakeup does both once the connect is through, and finds
-- the drain already loaded. Like M.wakeup, it stands aside while the background function script
-- is draining for the whole radio. Returns the source it published on this pass, if any.
function M.wakeupConnecting()
    local now = nowSeconds()
    if not Drain and drainLoadStep(now) then return end
    if not Drain or type(Drain.wakeupArmingFlags) ~= "function" then return end
    local remote = Drain.remoteAlive(now)
    local popped, published = 0, nil
    if not remote then popped, published = Drain.wakeupArmingFlags(now) end
    -- When the flight controller's telemetry was last seen arriving, as M.wakeup keeps it: frames
    -- taken here, or the function script's drain moving (lib/audio.lua reads it).
    if remote or (popped or 0) > 0 then
        local session = _G.rfsuite and _G.rfsuite.session
        if session then session.telemetryFrameAt = now end
    end
    return published
end

function M.reset()
    if Drain and type(Drain.reset) == "function" then
        Drain.reset()
    end
    if Smart and type(Smart.reset) == "function" then
        Smart.reset()
    end
    if Adjustments and type(Adjustments.reset) == "function" then
        Adjustments.reset()
    end
end

return M
