-- The custom-telemetry drain: pop the flight controller's custom telemetry frames off the
-- CRSF link, decode the sensors they carry, and publish them as radio sensors.
--
-- A module of its own rather than part of tasks.lua beside it, because the work has more than
-- one possible host. Nothing here reads a clock: the caller passes the time in, since it needs
-- it for its own bookkeeping anyway and two readings of getTime() in one pass would be two
-- different answers for one moment.

local M = {}

local RFSensors = nil
-- Sensor name -> sid of the decoder table, for M.customSensor: the table is keyed by sid, and a
-- reader asks by the name the radio shows. Built only once a reader has asked (a state nobody reads
-- through, such as the background function script's, never builds it), and then INDEX_PER_PASS
-- entries per drain pass (indexStep), so no single pass carries the whole table -- the pass that
-- loads the table least of all. `nameToSid` is nil until the last entry is in: a partial index must
-- not answer that a name is not a custom sensor, because readers keep that answer.
local nameToSid = nil
local INDEX_PER_PASS = 12
local indexWanted, indexPartial, indexKey = false, nil, nil

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
-- What the counters stood at when the last state-line summary was taken (M.summary). A reset
-- (M.reset) and a skip count taken over from another state move them with the counters, so the
-- summary counts only what this state saw.
local summaryFrames = 0
local summarySkips = 0

-- The decoder's own log lines. Every line names the Lua state that wrote it -- `bg` for the
-- background function script, `dash` for the widget state (the dashboard, the service widget and
-- the tool opened from the dashboard), `tool` for the tool started from the radio's Tools menu --
-- because the same code decodes in all three and they all write to the same serial port.
--
-- The level is asked once a second, not per pass: Log.wanted costs tens of instructions at the
-- shipped level, and this module runs on every pass of every host. Between two asks a pass pays
-- one comparison. Lines that are written on an edge (a take-over, a resume, a gap, a failed load)
-- and the per-frame trace line are built only behind the cached flag.
local LOG_TAG = "rfsuite.decoder"
local LOG_CHECK_SECONDS = 1.0
local Log = nil
local logCheckAt = 0
local debugOn = false
local traceOn = false
local hostName = "tool"

-- Which Lua state this is. The background function script says so itself (functions/rfsbg.lua
-- sets `rfsuite.decoderHost`); it has no session table, so the event context below would call it
-- the tool. A widget host sets the session's event context to "widget".
local function resolveHost()
    local root = _G.rfsuite
    if type(root) ~= "table" then return "tool" end
    if type(root.decoderHost) == "string" then return root.decoderHost end
    local session = root.session
    if type(session) == "table" and session.event_context == "widget" then return "dash" end
    return "tool"
end
M.resolveHost = resolveHost

-- What the level was decided from: the setting as stored and the logger. Only when either has
-- changed is the logger asked again, so the look once a second is a few table reads.
local seenLevel = nil
local seenLog = nil

local function refreshLog(now)
    logCheckAt = now + LOG_CHECK_SECONDS
    -- Read here, inside the host's work: a widget sets its event context only for the length of
    -- its background logic, so a state line written outside it would read the tool. Kept for that
    -- line and for the teller (M.host).
    hostName = resolveHost()
    local root = _G.rfsuite
    local L = root and root.Log
    local prefs = root and root.preferences
    local general = prefs and prefs.general
    local level = general and general.debug_level
    if level == seenLevel and L == seenLog then return end
    seenLevel, seenLog = level, L
    if type(L) ~= "table" or type(L.wanted) ~= "function" or type(L.emitf) ~= "function" then
        Log, debugOn, traceOn = nil, false, false
        return
    end
    Log = L
    debugOn = L.wanted("debug") == true
    traceOn = debugOn and L.wanted("trace") == true
end

--- The Lua state this decoder runs in, as its lines name it.
function M.host()
    return hostName
end

-- `fmt` is prefixed with the host here; numbers that can be fractional go in through %s or are
-- floored by the caller, since %d raises on a non-integral float.
local function logf(level, fmt, ...)
    if not Log then return end
    pcall(Log.emitf, LOG_TAG, level, "%s: " .. fmt, hostName, ...)
end

-- Reused for every traced frame rather than built per frame; emptied after each line.
local traceChanged = {}
local TRACE_MAX_CHARS = 200

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
    -- Another state's count, taken over: the summary counts only the gaps this state sees.
    summarySkips = summarySkips + (published - telemetryFrameSkip)
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

-- True while wakeupArmingFlags walks a frame only to reach the arming flags. The decoders that publish
-- a group themselves ask groupDue first, so answering false here keeps them from publishing, and from
-- touching the bookkeeping above, on a walk that is not a decode. decodeFrame clears it, so a walk
-- that raised part-way cannot leave the full pass silenced.
local walkOnly = false

-- The single-value rows a group also publishes (lib/rf2tlm_sensors.lua: decCells, decControl,
-- decAttitude, decAccel, decAdjFunc).
local GROUP_MEMBERS = {
    [0x102F] = { 0x1020 },
    [0x1030] = { 0x1031, 0x1032, 0x1033, 0x1034 },
    [0x1100] = { 0x1101, 0x1102, 0x1103 },
    [0x1110] = { 0x1111, 0x1112, 0x1113 },
    [0x1220] = { 0x1221, 0x1222 },
}

local function traceGroup(sid, frame, data, first, last)
    if frame and lastGroupLength[sid] == last - first then
        local offset = lastGroupFirst[sid] - first
        local i = first
        while i < last and frame[i + offset] == data[i] do i = i + 1 end
        if i == last then return end
    end
    local sensor = RFSensors and RFSensors[sid]
    traceChanged[#traceChanged + 1] = tostring(sensor and sensor.name or sid)
end

local function groupDue(sid, data, first, last)
    if walkOnly then return false end
    local now = decodeNow
    local frame = lastPublishedValue[sid]
    if frame and lastGroupLength[sid] == last - first
        and (now - (lastPublishedAt[sid] or 0)) < FORCE_REFRESH_INTERVAL then
        local offset = lastGroupFirst[sid] - first
        local i = first
        while i < last and frame[i + offset] == data[i] do i = i + 1 end
        if i == last then return false end
    end
    -- A group's values are published by its decoder, so the trace line names the group only, and
    -- only when its bytes changed rather than for a refresh.
    if traceOn then traceGroup(sid, frame, data, first, last) end
    -- The group publishes these single-value sensors too, so a value one of them published on its
    -- own earlier is not current any more: forgotten, and read from the radio's sensor
    -- (M.directValues). It is published again when its own row comes in a frame.
    local members = GROUP_MEMBERS[sid]
    if members then
        for i = 1, #members do lastPublishedValue[members[i]] = nil end
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
-- Which module is failing to load, so a failure is logged once per streak rather than once per
-- retry, and its recovery once.
local loadFailing = nil
local loadFailures = 0

local function loadFailed(name, now)
    loadRetryAt = now + LOAD_RETRY_SECONDS
    loadFailures = loadFailures + 1
    -- Marked as said only once it was: with no logger yet, the next failure tries again.
    if loadFailing ~= name and Log then
        loadFailing = name
        logf("warn", "%s failed to load, asked again every %d s", name, LOAD_RETRY_SECONDS)
    end
end

local function loadRecovered(name)
    if loadFailing ~= name then return end
    logf("info", "%s loaded after %d failed attempt(s)", name, loadFailures)
    loadFailing, loadFailures = nil, 0
end

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
            if debugOn then
                logf("debug", "frame gap: id %d -> %d, %d missing, %d gap(s) counted",
                    telemetryFrameId, fid, delta - 1, telemetryFrameSkip)
            end
        end
    end
    telemetryFrameId = fid
    telemetryFrameCount = telemetryFrameCount + 1
    return data
end

-- Whether the frames popped from here on arrived after the queue was last emptied. The radio keeps
-- at most a few custom frames for a script and, when that queue is full, drops the NEW one
-- (radio/src/telemetry/telemetry.cpp, pushDataToQueue), so after a stretch in which nothing popped
-- -- a link that came back, a pass that compiled instead of decoding -- the frames waiting are the
-- oldest, from before whatever happened meanwhile. A disarmed arming state from them is not taken:
-- tasks/msp/runtime.lua sends nothing to a new link until it knows the armed state, and an old
-- "disarmed" would open that to a craft armed since. An armed state is taken at once (a refusal
-- to send can only be early). Set once a pass ends with nothing left to pop; false when the module
-- starts and cleared again by M.reset(), which tasks/events/runtime.lua reaches on every link loss.
-- Not on a slow pass: the queue holds only a few frames, so a gap between passes ages them by that
-- gap and no more, and clearing it there would never let a disarm through on a slow radio. The
-- function script's drain is the exception, cleared after a gap (beginPass): there a gap is a pause.
local freshFrames = false
-- The current pass's verdict, taken at its start: frames popped in it are fresh only if an
-- earlier pass emptied the queue.
local passFresh = false

-- The arming flags' and the System Status word's sensor ids (lib/rf2tlm_sensors.lua, "ARM", "STAT").
local SID_ARMING_FLAGS = 0x1202
local SID_SYSTEM_STATUS = 0x1230

-- Whether a decoded arming flags or System Status value may be published now: an armed one always,
-- a disarmed one only from fresh frames (see freshFrames).
local function armedBit(val)
    return type(val) == "number" and bit32.btest(val, 1)
end

local function armedStateTrusted(val)
    if passFresh then return true end
    return armedBit(val)
end

-- The expensive half: the byte walk through the per-sensor decoders. The frame id at byte 3
-- was consumed by popAndAccount, so the walk starts at byte 4.
local function traceFrame(data, decoded)
    local text = table.concat(traceChanged, " ")
    for i = #traceChanged, 1, -1 do traceChanged[i] = nil end
    if #text > TRACE_MAX_CHARS then text = string.sub(text, 1, TRACE_MAX_CHARS) .. "..." end
    logf("trace", "frame %s: %d value(s), changed: %s", tostring(data[3]), decoded,
        text ~= "" and text or "-")
end

local function decodeFrame(data, now)
    local sid, val
    walkOnly = false
    decodeNow = now
    local ptr = 4
    while ptr < #data do
        sid,ptr = decU16(data, ptr)
        local sensor = RFSensors[sid]
        if sensor and type(sensor.dec) == "function" then
            val,ptr = sensor.dec(data, ptr)
            if val and (passFresh or (sid ~= SID_ARMING_FLAGS and sid ~= SID_SYSTEM_STATUS)
                    or armedStateTrusted(val)) then
                publishSensorValue(sid, val, sensor, now)
            end
        else
            break
        end
    end
end

-- decodeFrame with the per-frame trace line: the same walk, counting the values and naming those
-- it publishes. A twin rather than a branch inside decodeFrame, so that a pass at any other level
-- pays nothing per sensor for the trace.
local function decodeFrameTraced(data, now)
    local sid, val
    walkOnly = false
    decodeNow = now
    local ptr = 4
    local decoded = 0
    while ptr < #data do
        sid,ptr = decU16(data, ptr)
        local sensor = RFSensors[sid]
        if sensor and type(sensor.dec) == "function" then
            val,ptr = sensor.dec(data, ptr)
            decoded = decoded + 1
            if val and (passFresh or (sid ~= SID_ARMING_FLAGS and sid ~= SID_SYSTEM_STATUS)
                    or armedStateTrusted(val)) then
                -- Asked first so a change can be named; a refresh of an unchanged value is not one.
                local changed = lastPublishedValue[sid] ~= val
                publishSensorValue(sid, val, sensor, now)
                if changed then
                    traceChanged[#traceChanged + 1] = tostring(sensor.name or sid) .. "=" .. tostring(val)
                end
            end
        else
            break
        end
    end
    traceFrame(data, decoded)
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
-- The last answer of M.remoteAlive, for its edge line, and whether it said "another state is
-- decoding" since the last state-line summary (cleared there, so a link that went quiet while this
-- state stood aside does not keep reading "elsewhere").
local remoteLast = nil
local remoteSeen = false
-- Whether M.remoteAlive said "another state is decoding" since this state's last drain pass, for
-- beginPass's resume line: a stretch spent standing aside is not a stretch without a pass. Set
-- whatever the log level, so a level raised while standing aside still names the resume right.
local asideSincePass = false

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
    local alive = remoteMovedAt ~= nil and (now - remoteMovedAt) < M.REMOTE_STALE_SECONDS
    -- The handoff, for both of a host's passes (telemetry_bg/tasks.lua), on its edge only.
    if alive ~= remoteLast then
        -- Taking the decoding over: what this state published before it stood aside is older than
        -- what the other state published since, so it is forgotten, as a lost link forgets it
        -- (M.reset). The next frame then publishes every value it carries again, and M.directValues
        -- hands out only what this state decoded after the take-over.
        if remoteLast and not alive then
            lastPublishedValue = {}
            lastPublishedAt = {}
        end
        if now >= logCheckAt then refreshLog(now) end
        if debugOn then
            if alive then
                logf("debug", "stands aside: another Lua state is decoding")
            elseif remoteLast ~= nil then
                logf("debug", "takes over decoding: no other decoder seen for %s s",
                    tostring(M.REMOTE_STALE_SECONDS))
            end
        end
        remoteLast = alive
    end
    if alive then
        remoteSeen = true
        asideSincePass = true
    end
    return alive
end

-- INDEX_PER_PASS more entries of the name index (see nameToSid). The decoder table is never written
-- after its load, so a traversal started at the last key resumes where the last pass stopped. Every
-- entry is a table: lib/rf2tlm_sensors.lua builds them.
local function indexStep()
    local partial, n = indexPartial or {}, 0
    for sid, sensor in next, RFSensors, indexKey do
        local name = sensor.name
        if name then partial[name] = sid end
        n = n + 1
        if n == INDEX_PER_PASS then
            indexPartial, indexKey = partial, sid
            return
        end
    end
    nameToSid, indexWanted, indexPartial, indexKey = partial, false, nil, nil
    if debugOn then logf("debug", "sensor name index ready") end
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
        if RFSensors then
            loadRecovered("sensor table")
        else
            loadFailed("sensor table", now)
        end
        return false
    end

    -- The CRSF module, under the same wait, and before the resume bookkeeping in beginPass: a
    -- pass that cannot pop must not start the window in which frame ids are not yet counted as
    -- gaps, or the first frame after a late load would count as frames the link lost.
    if not CrsfManager then
        -- The MSP transport (tasks/msp/transports/crsf.lua) loads the same module first and it keeps
        -- one instance per Lua state, so take that one rather than spend a load on it.
        local shared = _G.rfsuite and _G.rfsuite.crsf_manager
        if type(shared) == "table" then
            CrsfManager = shared
            loadRecovered("CRSF module")
            return true
        end
        if now < loadRetryAt then return false end
        CrsfManager = loadModule("lib/crsf.lua")
        if not CrsfManager then
            loadFailed("CRSF module", now)
            return false
        end
        loadRecovered("CRSF module")
        return true
    end
    -- Not on a pass that loaded a module above: those are the heavier ones already.
    if indexWanted then indexStep() end
    return true
end

-- A pass after a stretch in which this state took no frames is a resume (see `resyncPending`
-- above). The values on the radio are read once per resume, not per pass.
--
-- `permanent` is the background function script's drain (M.wakeup's `decodeAll`). That script
-- runs on every cycle of the radio's script loop, so a gap of more than a second there is not a
-- slow radio: it is the script being paused, which the firmware does for as long as a standalone
-- tool is open (standalone_lua.cpp, "Pause function and mixer scripts"). A tool that does not
-- drain leaves the queue full of frames from when it opened, so the frames waiting at the resume
-- are not fresh. A widget keeps freshFrames across a gap (see freshFrames).
local function beginPass(now, permanent)
    if lastWakeAt == nil then
        if debugOn then logf("debug", "decoding starts") end
    elseif (now - lastWakeAt) > M.REMOTE_STALE_SECONDS then
        resyncPending = true
        adoptPublished = true
        if permanent then freshFrames = false end
        if debugOn then
            if asideSincePass then
                logf("debug", "decoding resumes after standing aside for %s s",
                    string.format("%.1f", now - lastWakeAt))
            else
                logf("debug", "decoding resumes after %s s without a pass",
                    string.format("%.1f", now - lastWakeAt))
            end
        end
    end
    asideSincePass = false
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
    passFresh = freshFrames
end

-- The adjustment pair (function, value) the flight controller sends after a step, and the
-- reason the cap below may not simply drop it. It is a value the board repeats only every few
-- seconds, not every frame: a pass that pops a backlog after a long one -- a surface build on the
-- pass before -- keeps the newest DECODE_CAP frames, and a step's report in one of the older ones
-- would otherwise reach neither the in-flight surface (which reads the AdjF/AdjV sensors) nor the
-- teller until the board sends it again.
local SID_ADJUSTMENT = 0x1220
local ADJ_HI, ADJ_LO = 0x12, 0x20

-- Whether a frame may carry the adjustment entry: its two id bytes anywhere past the header. A
-- byte search, not a walk, so a frame without them costs a loop over its bytes and no decoder;
-- a hit can be a value's bytes, which rescueAdjustment's walk then sorts out.
local function mayCarryAdjustment(data)
    for i = 4, #data - 1 do
        if data[i] == ADJ_HI and data[i + 1] == ADJ_LO then return true end
    end
    return false
end

-- Walk one dropped frame to its adjustment entry and decode that entry alone, published as
-- decodeFrame would; the entries in front are walked with walkOnly so none of them publishes.
-- Returns whether the entry was found.
local function rescueAdjustment(data, now)
    local ptr = 4
    walkOnly = true
    decodeNow = now
    while ptr < #data do
        local sid
        sid, ptr = decU16(data, ptr)
        local sensor = RFSensors[sid]
        if not sensor or type(sensor.dec) ~= "function" then break end
        if sid == SID_ADJUSTMENT then
            walkOnly = false
            local val
            val, ptr = sensor.dec(data, ptr)
            if val then publishSensorValue(sid, val, sensor, now) end
            return true
        end
        local _
        _, ptr = sensor.dec(data, ptr)
    end
    walkOnly = false
    return false
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
    if now >= logCheckAt then refreshLog(now) end
    if not modulesReady(now) then return 0 end
    beginPass(now, decodeAll)

    -- Pop up to POP_CAP, keep the newest DECODE_CAP in arrival order, decode only those --
    -- on a same-sensor conflict the newest value lands last. POP_CAP bounds the pass whether
    -- or not the decode is capped, so one call stays finite however far behind the queue is.
    local kept = keptFrames
    for i = #kept, 1, -1 do kept[i] = nil end
    local popped = 0
    -- The newest frame the cap drops that may carry the adjustment pair; decoded for that pair
    -- alone, ahead of the kept frames, so a newer pair among them still lands last.
    local rescue = nil
    while popped < POP_CAP do
        local data = popAndAccount()
        if not data then freshFrames = true break end
        popped = popped + 1
        kept[#kept + 1] = data
        if not decodeAll and #kept > DECODE_CAP then
            local dropped = table.remove(kept, 1)
            if mayCarryAdjustment(dropped) then rescue = dropped end
        end
    end

    if popped == 0 then return 0 end

    if rescue then
        local found = rescueAdjustment(rescue, now)
        if found then logf("debug", "pass: the adjustment report taken from a frame the cap dropped (frame %s)", tostring(rescue[3])) end
        rescue = nil
    end

    if traceOn then
        if popped > #kept then
            logf("trace", "pass: %d frame(s) popped, the newest %d decoded", popped, #kept)
        end
        for i = 1, #kept do
            decodeFrameTraced(kept[i], now)
        end
    else
        for i = 1, #kept do
            decodeFrame(kept[i], now)
        end
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

-- Where the armed state can come from in the custom telemetry frame: the arming flags ("ARM"), or the
-- packed System Status word ("STAT"), whose bit 0 lib/sensors.lua reads as armed when the model
-- carries no arming flags sensor (lib/rf2tlm_sensors.lua names both). lib/sensors.lua takes the
-- arming flags whenever the radio has them, so a walk that met the System Status word goes on to the
-- arming flags rather than stopping there.
-- Walk one frame up to the arming flags and publish them, and the System Status word on the way
-- when `withStatus`; returns whether the arming flags were found, whether the word was and whether
-- it read armed, and whether the arming flags were published. Entries are of different lengths and
-- the flight controller chooses their order, so the walk needs the decoders of the entries in
-- front; walkOnly keeps the ones that publish a group of their own from publishing.
--
-- `newerArmed`: a newer frame of this pass carried an armed System Status word. A disarmed arming
-- flags reading from this older frame then ends the search unpublished: tasks/msp/runtime.lua takes
-- the arming flags over the word, so publishing it would read a craft that has just armed as
-- disarmed until the next frame carrying the flags.
local function publishArmedSource(data, now, withStatus, newerArmed)
    local ptr = 4
    local statusFound, statusArmed = false, false
    walkOnly = true
    while ptr < #data do
        local sid
        sid, ptr = decU16(data, ptr)
        local sensor = RFSensors[sid]
        if not sensor or type(sensor.dec) ~= "function" then break end
        local val
        val, ptr = sensor.dec(data, ptr)
        if sid == SID_ARMING_FLAGS then
            walkOnly = false
            -- An untrusted disarmed reading is neither published nor the end of the search.
            if not armedStateTrusted(val) then return false, statusFound, statusArmed, false end
            if newerArmed and not armedBit(val) then return true, statusFound, statusArmed, false end
            if val then publishSensorValue(sid, val, sensor, now) end
            return true, statusFound, statusArmed, true
        elseif sid == SID_SYSTEM_STATUS and withStatus and not statusFound and armedStateTrusted(val) then
            statusFound, statusArmed = true, armedBit(val)
            if val then publishSensorValue(sid, val, sensor, now) end
        end
    end
    walkOnly = false
    return false, statusFound, statusArmed, false
end

-- The pass's frames newest first: the newest System Status word, and the newest arming flags.
-- Returns the source published last ("ARM" or "STAT"), or nil. A function of its own so that
-- M.wakeupArmingFlags can call it protected without building a closure on every pass.
local function walkNewestFirst(kept, now)
    local withStatus, newerArmed, found = true, false, nil
    for i = #kept, 1, -1 do
        local armFound, statusFound, statusArmed, armPublished =
            publishArmedSource(kept[i], now, withStatus, newerArmed)
        if statusFound then withStatus = false; newerArmed = statusArmed; found = "STAT" end
        if armFound then
            if armPublished then found = "ARM" end
            break
        end
    end
    return found
end

--- A drain pass that publishes the armed state and nothing else, for a widget host while its
-- connect sequence runs.
--
-- The full pass is held back there, to keep the connect passes clear of the decode. But
-- tasks/msp/runtime.lua stops sending while the craft is armed, and learns that from the radio's
-- ARM sensor; in a widget with the background function script not running, this state is the
-- only decoder of it. So the frames are taken off the wire and counted as in M.wakeup, and of the
-- newest DECODE_CAP of them -- newest first -- only as many are walked as it takes to find the
-- arming flags; the newest System Status word met on the way is published too.
--
-- Returns how many frames the pass took off the wire, as M.wakeup does, and which source it
-- published ("ARM" or "STAT"), or nil.
function M.wakeupArmingFlags(now)
    if now >= logCheckAt then refreshLog(now) end
    if not modulesReady(now) then return 0 end
    beginPass(now)

    local kept = keptFrames
    for i = #kept, 1, -1 do kept[i] = nil end
    local popped = 0
    while popped < POP_CAP do
        local data = popAndAccount()
        if not data then freshFrames = true break end
        popped = popped + 1
        kept[#kept + 1] = data
        if #kept > DECODE_CAP then table.remove(kept, 1) end
    end

    -- The adjustment decoder holds the pair it decodes for the teller before it asks whether to
    -- publish (lib/rf2tlm_sensors.lua, decAdjFunc), and this walk goes newest first. The pair is put
    -- back afterwards, so the teller finds what it would have found had this pass not run -- also
    -- when a decoder raises part-way through the walk: the pair is put back and the error goes on.
    local root = _G.rfsuite
    local report = root and root.adjustmentReport
    local held1, held2 = nil, nil
    if type(report) == "table" then held1, held2 = report[1], report[2] end

    local ok, found = pcall(walkNewestFirst, kept, now)
    for i = #kept, 1, -1 do kept[i] = nil end
    walkOnly = false

    if root then
        if type(report) == "table" then
            report[1], report[2] = held1, held2
        end
        root.adjustmentReport = report
    end
    if not ok then error(found, 0) end
    return popped, found
end

local DIRECT_SCALE = { 10, 100, 1000 }

--- The sensor of the custom telemetry a name stands for: its sid and the divisor its precision asks
-- for (1 for none); false for a name that is not one; nil while the decoder table is not loaded or
-- its name index not yet complete, so the question is asked again -- the first such question starts
-- the index (see nameToSid). A reader asks this once per name and keeps the answer, because the
-- table does not change.
function M.customSensor(name)
    if not nameToSid then
        indexWanted = true
        return nil
    end
    local sid = nameToSid[name]
    if sid == nil then return false end
    local prec = RFSensors[sid].prec or 0
    return sid, prec > 0 and (DIRECT_SCALE[prec] or 10 ^ prec) or 1
end

--- The values this state decoded last, by sid: a number for a single-value sensor, unscaled, as the
-- decoder took it from the frame -- before any setting of the radio's own sensor page (ratio,
-- offset, filter, unit), which belong to the radio's sensor; the flight controller is where a value
-- is calibrated --, and a frame for a group (cells, GPS, attitude, ...: a group's values are
-- published by its decoder and only its frame is kept here), so a reader tests with type. A value
-- published before this state last took over, or before a reset, is not in it (forgotten then).
-- nil while another Lua state is decoding: this state's values are then not current. One call per
-- read instead of one per candidate name; the table is replaced on a reset and on a take-over, so
-- it is asked for again on every read, never kept.
function M.directValues()
    if remoteLast then return nil end
    return lastPublishedValue
end

--- One fragment for a host's state line: who decoded since the last call, and what it saw.
--
-- `decoder <host>, N frames, G gaps` when this state took frames, `decoder elsewhere` when it
-- stood aside because another Lua state was draining, `decoder idle` when neither. Counted from
-- this state's own counters, so the background script's line and the widget's line each say what
-- their own state did. One caller per state: the counts are the difference since the last call.
function M.summary()
    local frames = telemetryFrameCount - summaryFrames
    local skips = telemetryFrameSkip - summarySkips
    summaryFrames, summarySkips = telemetryFrameCount, telemetryFrameSkip
    local aside = remoteSeen
    remoteSeen = false
    if frames > 0 then
        return string.format("decoder %s, %d frames, %d gaps", hostName, frames, skips)
    end
    if aside then return "decoder elsewhere" end
    return "decoder idle"
end

-- What a lost link invalidates, and nothing else. The liveness state above is deliberately not
-- cleared: it is what another Lua state is doing, and that state does not restart because this
-- one lost its flight controller.
function M.reset()
    summaryFrames = summaryFrames - telemetryFrameCount
    summarySkips = summarySkips - telemetryFrameSkip
    telemetryFrameId = 0
    freshFrames = false
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
    if debugOn then logf("debug", "link lost, decoder state reset") end
end

-- The state lines of the three hosts (functions/rfsbg.lua, widgets/dashboard/runtime.lua,
-- ui/home.lua) reach the summary through this, rather than each holding the module: the widget's
-- runtime has no handle on it, and the module is loaded once per Lua state by its host.
if type(_G.rfsuite) == "table" then _G.rfsuite.telemetryDecoder = M end

return M
