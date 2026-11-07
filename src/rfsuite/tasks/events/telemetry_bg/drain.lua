-- The custom-telemetry drain: pop the flight controller's custom telemetry frames off the
-- CRSF link, decode the sensors they carry, and publish them as radio sensors.
--
-- A module of its own rather than part of tasks.lua beside it, because the work has more than
-- one possible host. Nothing here reads a clock: the caller passes the time in, since it needs
-- it for its own bookkeeping anyway and two readings of getTime() in one pass would be two
-- different answers for one moment.

local M = {}

local RFSensors = nil

local function loadModule(path, ...)
  local fullPath = _G.rfsuite.paths.core .. "/" .. path
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(fullPath, mode)
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk, ...)
  if not ok then return nil end
  return mod
end

local telemetryFrameId = 0
local telemetryFrameSkip = 0
local telemetryFrameCount = 0

-- A published sensor stays valid on the radio for TELEMETRY_SENSOR_TIMEOUT_START, so an
-- unchanged value does not have to be re-sent every frame, and every setTelemetryValue() call
-- has the firmware look the sensor up among the model's sensor slots before it stores the
-- value. (It does not mark the model dirty: the firmware does that only when the call creates
-- a sensor.) Publish on change, and refresh an unchanged sensor well inside its timeout. Same
-- contract as publishTelemetryValue() in smart.lua.
local FORCE_REFRESH_INTERVAL = 2.0

local lastPublishedValue = {}
local lastPublishedAt = {}

-- The decoder's own two counters, and they need a publisher of their own rather than the one
-- above. `publishSensorValue` throttles by CHANGE, and the frame count changes in every single
-- frame by construction -- so through that publisher it would go out at the full frame rate and
-- defeat the throttle exactly as it did before this fix. Measured rather than reasoned: over
-- 20 s at 8 frames/s the change-based publisher writes *Cnt 160 times, this one writes it 10.
--
-- So these two are RATE limited instead. The cost is that the reading can be up to
-- FORCE_REFRESH_INTERVAL stale, which is the right trade for a decoder diagnostic.
local lastCounterAt = 0

-- Up to three Lua states decode the same frames -- the function script, the dashboard and the
-- tool -- each with counters of its own, and all of them publish to the same two sensors. Each
-- state is served its own copy of every frame, so while one stands aside (another is draining,
-- or the tool has paused the function script) the frames it does not take are simply never
-- seen by it, apart from the oldest few its queue kept. When it drains again, those are stale,
-- its last frame id is older still, and its skip count is its own, not the one on the radio:
-- the ids read as a gap, and its count replaces the published one -- a jump either way, which a
-- reader of *Skp cannot tell from frames the link really lost.
--
-- So a state that resumes counts no gap for REMOTE_STALE_SECONDS -- long enough to take its
-- backlog and the step from it to the live frames -- and continues the skip count from the
-- value on the radio, so the published count moves only by what this state sees from then on.
-- Two exceptions. The radio still shows this state's own last value: its count
-- here is newer and is kept. And the counters here were reset by a lost link and no decoder
-- has published since (the frame count on the radio has not moved): the value on the radio is
-- then the previous connection's, and the count rightly starts over.
local resyncPending = true
local resyncUntil = 0
local passNow = 0
local adoptPublished = true
local resetFrameCount = nil
local lastPublishedSkip = nil
local lastWakeAt = nil

local function publishCounters(count, skip, now)
    if (now - lastCounterAt) < FORCE_REFRESH_INTERVAL then return end
    lastCounterAt = now
    lastPublishedSkip = skip
    resetFrameCount = nil
    setTelemetryValue(0xEE01, 0, 0, count, 0, 0, "*Cnt")
    setTelemetryValue(0xEE02, 0, 0, skip, 0, 0, "*Skp")
end

local function radioNumber(name)
    local ok, value = pcall(getValue, name)
    if ok and type(value) == "number" then return value end
    return nil
end

local function adoptRadioSkip()
    local published = radioNumber("*Skp")
    if published == nil then return end
    if resetFrameCount ~= nil then
        local count = radioNumber("*Cnt")
        if count == nil or count == resetFrameCount then return end
    end
    published = math.floor(published)
    if published == lastPublishedSkip then return end
    telemetryFrameSkip = published
end

local function publishSensorValue(sid, value, sensor, now)
    local stale = (now - (lastPublishedAt[sid] or 0)) >= FORCE_REFRESH_INTERVAL
    if lastPublishedValue[sid] == value and not stale then return end
    setTelemetryValue(sid, 0, 0, value, sensor.unit or 0, sensor.prec or 0, sensor.name or "")
    lastPublishedValue[sid] = value
    lastPublishedAt[sid] = now
end

-- A decoder that yields several sensors cannot hand them back through its one return value, so
-- it publishes them itself -- and asks this first, with the span of bytes it decoded. Equal bytes
-- are equal values, so a group goes out on the same contract as publishSensorValue: when any of
-- it changed, or when it is due for a refresh. It goes out WHOLE, never sensor by sensor: the
-- radio forms a cell sensor's total only when the last cell arrives, and the GPS fix is three
-- calls on one id, so publishing only the parts that changed would leave the total or the fix
-- behind. What it compares against is the frame the group was last published from:
-- crossfireTelemetryPop() hands out a table of its own for every frame and nothing here writes
-- into one, so keeping a reference and an offset costs neither a copy nor an allocation.
-- `lastPublishedValue` holds that frame for a group's id, the two tables below where in it the
-- group started and how long it was.
local lastGroupFirst = {}
local lastGroupLength = {}

-- The time of the frame being decoded, set once per frame by decodeFrame: groupDue is handed to
-- the decoder module once, at load, so it cannot take the time as an argument.
local decodeNow = 0

local function groupDue(sid, data, first, last)
    local now = decodeNow
    local frame = lastPublishedValue[sid]
    if frame and lastGroupLength[sid] == last - first
        and (now - (lastPublishedAt[sid] or 0)) < FORCE_REFRESH_INTERVAL then
        local offset = lastGroupFirst[sid] - first
        local i = first
        while i < last and frame[i + offset] == data[i] do i = i + 1 end
        if i == last then return false end
    end
    lastPublishedValue[sid] = data
    lastGroupFirst[sid] = first
    lastGroupLength[sid] = last - first
    lastPublishedAt[sid] = now
    return true
end

local function decU8(data, pos)
    return data[pos], pos+1
end

local function decU16(data, pos)
    return bit32.lshift(data[pos],8) + data[pos+1], pos+2
end

local CrsfManager = nil

-- How long the drain waits before asking the loader again for one of its modules that did not
-- load, and the time before which it does not ask. The loader does not remember a failure, so
-- without the wait every wakeup asks for the file again. A retry rather than giving
-- up for good, because a load can fail without the file being broken: the loader's pcall also
-- catches the radio's instruction limit when it stops a pass while the module's chunk runs.
local LOAD_RETRY_SECONDS = 1
local loadRetryAt = 0

-- Per-pass bounds for the custom-telemetry drain. Popping a frame is a handful of C calls;
-- DECODING one is a Lua walk over every sensor it carries -- the expensive term. So the
-- drain looks at up to POP_CAP frames per wakeup to keep the queue from backing up, but
-- fully decodes only the newest DECODE_CAP of them: telemetry is values, not commands, and
-- the next frame carries the current state, so under a backlog the oldest frames are the
-- right ones to skip. Both are provisional counts, to be calibrated by offline instruction
-- accounting.
local POP_CAP = 15
local DECODE_CAP = 4

-- The cheap half: pop one frame and keep the frame counters honest. The id bookkeeping runs
-- for EVERY popped frame, decoded or not -- `*Skp` means "the link skipped", and a decode
-- the drain chose to skip must never read as a link problem.
local function popAndAccount()
    local CRSF_FRAME_CUSTOM_TELEM = 0x88
    -- CrsfManager is loaded by M.wakeup before any frame is popped.

    local data = CrsfManager.popFrame(CRSF_FRAME_CUSTOM_TELEM)
    if not data then return nil end

    local fid, ptr
    ptr = 3
    fid, ptr = decU8(data, ptr)
    if passNow >= resyncUntil then
        local delta = bit32.band(fid - telemetryFrameId, 0xFF)
        if delta > 1 then
            telemetryFrameSkip = telemetryFrameSkip + 1
        end
    end
    telemetryFrameId = fid
    telemetryFrameCount = telemetryFrameCount + 1
    return data
end

-- The expensive half: the byte walk through the per-sensor decoders. The frame id at byte 3
-- was consumed by popAndAccount, so the walk starts at byte 4.
local function decodeFrame(data, now)
    local sid, val
    decodeNow = now
    local ptr = 4
    while ptr < #data do
        sid,ptr = decU16(data, ptr)
        local sensor = RFSensors[sid]
        if sensor and type(sensor.dec) == "function" then
            val,ptr = sensor.dec(data, ptr)
            if val then
                publishSensorValue(sid, val, sensor, now)
            end
        else
            break
        end
    end
end

-- Which of EdgeTX's sixteen shared-memory slots carries the drain's liveness. The slots are a
-- static array outside every Lua state, so they are the one channel a widget and a permanent
-- script have between them; the last one is taken because the low ids are the ones a pilot's
-- own script reaches for first.
M.SHM_LIVENESS_ID = 16

-- And which one carries the DASHBOARD WIDGET's heartbeat, for whoever is watching from outside
-- that Lua state. Allocated here rather than where it is used, because the sixteen slots are a
-- radio-wide resource and a map kept in two files is a collision waiting to happen. Counting
-- down from the top for the same reason the one above does: a pilot's own script reaches for the
-- low ids first.
--
-- The slot carries `pass * 256 + usage`: the widget's pass counter in the high bits and the
-- percentage of the instruction budget its previous pass cost in the low eight. Eight bits is
-- exactly what the firmware can report -- luaGetUsage stores it in a uint8_t -- so nothing is
-- lost by packing, and one integer means one write per pass instead of two.
M.SHM_WIDGET_PASS_ID = 15
M.SHM_WIDGET_PASS_SHIFT = 256

-- How long a counter that has stopped moving still counts as alive. It has to cover the gap
-- between two turns of whatever is bumping it, and it is also how long a host keeps skipping
-- its own drain after the other side has gone away -- so it is short: a tool session pauses
-- the radio's permanent scripts for its whole length, and one stale window is the whole cost
-- of noticing that.
M.REMOTE_STALE_SECONDS = 1.0

-- The counter wraps well inside the firmware's signed int, and it never lands on zero: a slot
-- that was never written reads zero, and a writer that produced one would be indistinguishable
-- from that.
local LIVENESS_WRAP = 0x40000000

local liveness = 0
local remoteValue = nil
local remoteMovedAt = nil

--- Say that this Lua state is TAKING FRAMES OFF THE WIRE, for whoever is watching the slot.
--
-- A moving counter rather than a flag, because nothing ever clears the slots -- not a model
-- change, not the interpreter being torn down. A flag left set by a state that has since
-- disappeared would silence every other decoder on the radio for good.
--
-- The counter says that frames are being consumed here, and deliberately not that this host is
-- alive. The two come apart whenever something else in the SAME Lua state pops the wire first:
-- permanent scripts have no script manager of their own, so the firmware gives all of them one
-- shared telemetry queue, and the first one whose drain empties it leaves the rest with nothing.
-- A host that published on being called would then keep every other decoder on the radio stood
-- down while decoding nothing itself. Published on frames taken, that failure closes itself: the
-- counter stops within one stale window and whoever was standing aside resumes.
function M.publishLiveness()
    if type(setShmVar) ~= "function" then return end
    liveness = liveness + 1
    if liveness >= LIVENESS_WRAP then liveness = 1 end
    setShmVar(M.SHM_LIVENESS_ID, liveness)
end

--- Is another Lua state draining right now?
--
-- The reader is deliberately without memory of anything but the last value it saw: it has to
-- work out for itself whether the counter MOVES, because the value alone says nothing. Only a
-- host that has seen it move, recently, may leave the drain to somebody else.
function M.remoteAlive(now)
    if type(getShmVar) ~= "function" then return false end
    local value = getShmVar(M.SHM_LIVENESS_ID)
    if type(value) ~= "number" then return false end

    if remoteValue == nil then
        -- The first read records and never counts. The slot outlives the state that wrote it,
        -- so what is in it at the first read may be a leftover from a previous session.
        remoteValue = value
        return false
    end
    if value ~= remoteValue then
        remoteValue = value
        remoteMovedAt = now
    end
    return remoteMovedAt ~= nil and (now - remoteMovedAt) < M.REMOTE_STALE_SECONDS
end

-- The two modules a drain pass needs, one load per wakeup; false while either is still missing.
-- The decoder table gets a wakeup of its own, and a wakeup that loads returns without popping:
-- loading its top-level chunk costs more than a steady drain pass does, and loading it in the same
-- call as the first decode puts both into one widget pass -- the rule telemetry_bg/tasks.lua
-- follows for the modules above this one. Nothing is popped then, so the frames stay queued for
-- the next wakeup, and the caller returns 0, which keeps liveness honest: that pass took nothing
-- off the wire.
--
-- A failed load is asked for again after LOAD_RETRY_SECONDS, not on the next wakeup: the drain is
-- woken about ten times a second, and each ask can be a card read. M.reset() leaves the wait
-- alone: a lost link says nothing about what is on the card.
local function modulesReady(now)
    if not RFSensors then
        if now < loadRetryAt then return false end
        RFSensors = loadModule("lib/rf2tlm_sensors.lua", nil, groupDue)
        if not RFSensors then loadRetryAt = now + LOAD_RETRY_SECONDS end
        return false
    end

    -- The CRSF module, under the same wait, and before the resume bookkeeping in beginPass: a
    -- pass that cannot pop must not start the window in which frame ids are not yet counted as
    -- gaps, or the first frame after a late load would count as frames the link lost.
    if not CrsfManager then
        if now < loadRetryAt then return false end
        CrsfManager = loadModule("lib/crsf.lua")
        if not CrsfManager then
            loadRetryAt = now + LOAD_RETRY_SECONDS
            return false
        end
    end
    return true
end

-- A pass after a stretch in which this state took no frames is a resume (see `resyncPending`
-- above). The values on the radio are read once per resume, not per pass.
local function beginPass(now)
    if lastWakeAt ~= nil and (now - lastWakeAt) > M.REMOTE_STALE_SECONDS then
        resyncPending = true
        adoptPublished = true
    end
    lastWakeAt = now
    passNow = now
    if resyncPending then
        resyncPending = false
        resyncUntil = now + M.REMOTE_STALE_SECONDS
    end
    if adoptPublished then
        adoptPublished = false
        adoptRadioSkip()
    end
end

-- The frames one pass keeps for decoding. One table for every pass rather than a new one per
-- wakeup, because the drain is woken on every pass whether or not a frame is waiting. Reusing it
-- is safe because the list never leaves M.wakeup: decodeFrame(kept[i], now) is handed one frame,
-- never the list, and the list is neither returned nor stored anywhere else. It is emptied once
-- the frames are decoded, so no frame is held from one pass to the next, and again before a pass
-- fills it, so a pass that raised part-way through its decode cannot hand its frames to the next
-- one.
local keptFrames = {}

--- One drain pass: pop what is waiting, decode it, publish what changed.
--
-- Returns how many frames the pass took off the wire. A caller that publishes liveness needs
-- that number rather than the fact that it was called: a host can be running perfectly and
-- receiving nothing, and the two have to be told apart by whoever is deciding whether to leave
-- the drain to it.
--
-- `decodeAll` lifts DECODE_CAP. It is for a host whose long call is yielded rather than killed
-- -- the radio's script state, where a permanent script runs -- and there dropping the older
-- frames of a backlog buys nothing. A call billed against a hard per-call ceiling keeps the cap.
function M.wakeup(now, decodeAll)
    if not modulesReady(now) then return 0 end
    beginPass(now)

    -- Pop up to POP_CAP, keep the newest DECODE_CAP in arrival order, decode only those --
    -- on a same-sensor conflict the newest value lands last. POP_CAP bounds the pass whether
    -- or not the decode is capped, so one call stays finite however far behind the queue is.
    local kept = keptFrames
    for i = #kept, 1, -1 do kept[i] = nil end
    local popped = 0
    while popped < POP_CAP do
        local data = popAndAccount()
        if not data then break end
        popped = popped + 1
        kept[#kept + 1] = data
        if not decodeAll and #kept > DECODE_CAP then
            table.remove(kept, 1)
        end
    end

    if popped == 0 then return 0 end

    for i = 1, #kept do
        decodeFrame(kept[i], now)
    end
    for i = #kept, 1, -1 do kept[i] = nil end
    -- Published unconditionally, and that is deliberate: the sibling project creates the
    -- same two sensors and treats a missing `*Cnt` as "the pilot deleted the telemetry
    -- sensors", so a radio carrying both suites needs them to keep meaning what they mean.
    -- A pilot who does not want the two rows can delete them on the telemetry page; outside
    -- a discovery window nothing here creates them again. Once per wakeup: the publisher
    -- rate-limits itself, and per-frame publication was redundancy, not information.
    publishCounters(telemetryFrameCount, telemetryFrameSkip, now)
    return popped
end

-- The arming flags' sensor id in the custom telemetry frame (lib/rf2tlm_sensors.lua, "ARM").
local SID_ARMING_FLAGS = 0x1202

-- Walk one frame up to the arming flags and publish them; true when the frame carried them.
-- Entries are of different lengths and the flight controller chooses their order, so the walk
-- needs the decoders of the entries in front of the flags; nothing else is published.
local function publishArmingFlags(data, now)
    local ptr = 4
    while ptr < #data do
        local sid
        sid, ptr = decU16(data, ptr)
        local sensor = RFSensors[sid]
        if not sensor or type(sensor.dec) ~= "function" then return false end
        local val
        val, ptr = sensor.dec(data, ptr)
        if sid == SID_ARMING_FLAGS then
            if val then publishSensorValue(sid, val, sensor, now) end
            return true
        end
    end
    return false
end

--- A drain pass that publishes the arming flags and nothing else, for a widget host while its
-- connect sequence runs.
--
-- The full pass is held back there, to keep the connect passes clear of the decode. But
-- tasks/msp/runtime.lua stops sending while the craft is armed, and learns that from the radio's
-- ARM sensor; in a widget with the background function script not running, this state is the
-- only decoder of it. So the frames are taken off the wire and counted as in M.wakeup, and of the
-- newest DECODE_CAP of them -- newest first -- only as many are walked as it takes to find the
-- flags.
--
-- Returns how many frames the pass took off the wire, as M.wakeup does.
function M.wakeupArmingFlags(now)
    if not modulesReady(now) then return 0 end
    beginPass(now)

    local kept = keptFrames
    for i = #kept, 1, -1 do kept[i] = nil end
    local popped = 0
    while popped < POP_CAP do
        local data = popAndAccount()
        if not data then break end
        popped = popped + 1
        kept[#kept + 1] = data
        if #kept > DECODE_CAP then table.remove(kept, 1) end
    end

    for i = #kept, 1, -1 do
        if publishArmingFlags(kept[i], now) then break end
    end
    for i = #kept, 1, -1 do kept[i] = nil end
    return popped
end

-- What a lost link invalidates, and nothing else. The liveness state above is deliberately not
-- cleared: it is what another Lua state is doing, and that state does not restart because this
-- one lost its flight controller.
function M.reset()
    telemetryFrameId = 0
    resyncPending = true
    adoptPublished = true
    lastPublishedSkip = nil
    resetFrameCount = radioNumber("*Cnt") or false
    telemetryFrameSkip = 0
    telemetryFrameCount = 0
    lastPublishedValue = {}
    lastPublishedAt = {}
    lastGroupFirst = {}
    lastGroupLength = {}
    lastCounterAt = 0
end

return M
