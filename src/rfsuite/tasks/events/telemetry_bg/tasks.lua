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
    -- module that is genuinely absent stays absent cheaply.
    if Drain == nil then
        Drain = loadModule("tasks/events/telemetry_bg/drain.lua") or false
        return
    end
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
    -- With the setting off, the pass the teller would have loaded on is still spent, once, doing
    -- nothing: every later start-up step then lands on the wakeup it always had. Moved one pass
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
            elseif not tellerStageSpent then
                tellerStageSpent = true
                return
            end
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
        end
        tellerAside = true
    else
        tellerAside = false
        if Adjustments and type(Adjustments.wakeup) == "function" then
            Adjustments.wakeup()
        end
    end
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
