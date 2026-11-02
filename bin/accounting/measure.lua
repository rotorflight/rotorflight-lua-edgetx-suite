-- Offline instruction accounting for the dashboard and service widget passes.
--
-- Runs the shipped sources against the stubs in stubs/ under debug.sethook(..., "count") --
-- the mechanism the firmware bills a widget call with -- and checks every measured row
-- against the table in budgets.lua. See README.md for why the gate is off-radio.
--
--   lua5.3 bin/accounting/measure.lua              report only
--   lua5.3 bin/accounting/measure.lua --check      gate: non-zero exit on any breach
--   lua5.3 bin/accounting/measure.lua --self-test  proves the gate can go red
--   lua5.3 bin/accounting/measure.lua --phases     the arm and disarm edges at every phase
--
-- Nothing here reads a wall clock, and no pcall swallows a failure: a stub that is missing
-- or a source that raises fails the run, because in a measurement a silence is a zero that
-- reads as "cheap".

local ROOT = "."
local HERE = "bin/accounting"

do
  local this = arg and arg[0]
  if type(this) == "string" then
    local dir = string.match(this, "^(.*)[/\\][^/\\]*$")
    if dir then
      HERE = dir
      ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]accounting$") or (dir .. "/../..")
    end
  end
end

local Stubs = assert(loadfile(HERE .. "/stubs/edgetx.lua"))()
local FC = assert(loadfile(HERE .. "/stubs/fc.lua"))()
local Budgets = assert(loadfile(HERE .. "/budgets.lua"))()

-- The card this run is given is emptied before anything is measured. The suite addresses its
-- settings by absolute card path, and under the stubs that used to mean the host's own
-- /SCRIPTS -- so a run that died on a control it could not satisfy left a settings file
-- behind, and the next run read it. Nothing on the host can reach the measurement now, and
-- nothing the measurement writes survives it.
Stubs.clearCard()

local API_DIR = ROOT .. "/src/rfsuite/tasks/msp/api"
local THEMES_DIR = ROOT .. "/src/rfsuite/widgets/dashboard/themes"
local OBJECTS_DIR = ROOT .. "/src/rfsuite/widgets/dashboard/objects"

local ZONE = { x = 0, y = 0, w = 800, h = 458 }

-- ---------------------------------------------------------------------------
-- Directory listing. `ls -1` is the one external call in the measurement itself;
-- everything else here is the interpreter. Sorted, because two hosts must
-- enumerate in one order. (The card the run is given in stubs/edgetx.lua shells
-- out to `mkdir` and `rmdir` as well, to make and to empty that directory.)
-- ---------------------------------------------------------------------------
local function listDir(path)
  local pipe = io.popen("ls -1 " .. path .. " 2>/dev/null")
  if not pipe then error("accounting: cannot list " .. path) end
  local names = {}
  for name in pipe:lines() do names[#names + 1] = name end
  pipe:close()
  table.sort(names)
  return names
end

local function listLuaFiles(path)
  local out = {}
  for _, name in ipairs(listDir(path)) do
    if string.match(name, "%.lua$") then out[#out + 1] = name end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- The counter.
-- ---------------------------------------------------------------------------

--- Instructions billed to one call.
--
-- The collector is stopped across the measured section: the events runtime runs a full
-- collection when the connect chain finishes, and a GC step would land in the count
-- wherever the allocator happens to be. The firmware's own incremental collection is part
-- of what the budget margin covers.
--
-- The hook advances one counter for the whole run rather than one per call, so a section inside
-- a measured call -- a tool page's build, below -- can be read off it as a difference, and a
-- section outside one can install the same hook for itself and be read off it the same way.
local tally = 0
local function bill() tally = tally + 1 end

local function count(fn, ...)
  -- One pass of the host clock per measured call. The stub's clock does not run by itself.
  Stubs.tick()
  local n = tally
  collectgarbage("collect")
  collectgarbage("stop")
  debug.sethook(bill, "", 1)
  local ok, err = pcall(fn, ...)
  debug.sethook()
  collectgarbage("restart")
  if not ok then error(err, 0) end
  return tally - n
end

--- What one call of an empty closure costs through the loop the sweep is replayed in.
--
-- The firmware walks LVGL's reactive references in C; this check calls the collected
-- function fields in a plain Lua loop, and the loop is not free. Measured here, subtracted
-- from every sweep row, and compared against budgets.lua -- a run whose control has
-- drifted is measuring something else, and every sweep row it prints is wrong by that
-- difference.
local function sweepControl(iterations)
  local refs = {}
  local empty = function() end
  for i = 1, iterations do refs[i] = empty end
  local total = count(function()
    for i = 1, #refs do refs[i]() end
  end)
  return total / iterations
end

--- Call every reactive reference in `refs` once, with the loop's own cost taken back out.
local function sweepCost(refs, control)
  if #refs == 0 then return 0, 0 end
  local total = count(function()
    for i = 1, #refs do refs[i]() end
  end)
  return math.max(0, math.floor(total - control * #refs + 0.5)), #refs
end

--- Collect every function field of a node tree, the way the lvgl stub does at build time.
local function collectRefs(node, refs)
  for _, v in pairs(node) do
    if type(v) == "function" then
      refs[#refs + 1] = v
    elseif type(v) == "table" then
      collectRefs(v, refs)
    end
  end
  return refs
end

-- ---------------------------------------------------------------------------
-- The world, rebuilt per scenario so no measurement inherits another's caches.
-- ---------------------------------------------------------------------------

-- The sensor set a settled dashboard reads, under the four-character names
-- lib/sensors.lua searches for. Values are a helicopter idling on the bench: they only
-- have to be plausible and constant, because a value that moved would move the render key
-- and put a rebuild into a pass being measured for something else.
local SENSORS = {
  ["Vbat"] = 24.6, ["Curr"] = 3.2, ["Capa"] = 850, ["Bat%"] = 74,
  ["SmFt"] = 74, ["SmCp"] = 850, ["Cel#"] = 6,
  ["Hspd"] = 1750, ["RQly"] = 96, ["1RSS"] = -42, ["2RSS"] = -45,
  ["Vbec"] = 8.1, ["EscT"] = 48, ["Tmcu"] = 39, ["Thr%"] = 12,
  ["PID#"] = 1, ["RTE#"] = 1, ["BatP"] = 1, ["ARM"] = 0, ["ARMD"] = 0,
  ["Gov"] = 4, ["Alt"] = 1.5, ["Ptch"] = 0, ["Roll"] = 0, ["Yaw"] = 0,
}

local World = { sensorIds = {} }

function World.reset()
  Stubs.install(ROOT)
  FC.install(Stubs)
  Stubs.reset()
  FC.reset()
  for k, v in pairs(SENSORS) do Stubs.sensors[k] = v end
end

function World.require(path)
  return _G.rfsuite.require(path)
end

-- The custom telemetry frames, built the way the flight controller builds them.
--
-- Every entry carries its value at the width the firmware's encoder writes, read off the encoder
-- column of the sensor table in rotorflight-firmware's src/main/telemetry/crsf.c -- and NOT off the
-- decoders in lib/rf2tlm_sensors.lua. A width taken from a decoder agrees with that decoder by
-- construction, so a decoder that reads the wrong number of bytes would walk a fixture built from
-- itself to the end and price a frame the firmware never sends. checkTelemetryFrames below walks
-- every frame with the repository's decoders and fails the run unless each one is consumed to its
-- last byte.
local CELL_COUNT = 6
local CELL_BYTE = 210 -- 4.10 V: the encoder sends a cell as its voltage less 2.00 V, in 10 mV
local WIRE_WIDTH = {
  [0x1000] = 0,                                                 -- Nil
  [0x1001] = 2,                                                 -- U16
  [0x1011] = 2, [0x1012] = 2, [0x1013] = 2, [0x1014] = 1,       -- U16 U16 U16 U8
  [0x1020] = 1, [0x1021] = 1,                                   -- U8 CellVolt
  [0x102F] = 1 + CELL_COUNT,                                    -- Cells: the count, then a byte per cell
  [0x1030] = 6,                                                 -- Control: two pairs of 12-bit values
  [0x1031] = 2, [0x1032] = 2, [0x1033] = 2, [0x1034] = 2,       -- S16
  [0x1035] = 1,                                                 -- S8
  [0x1041] = 2, [0x1042] = 2, [0x1043] = 2, [0x1044] = 3,       -- U16 U16 U16 U24
  [0x1045] = 2, [0x1046] = 2, [0x1047] = 1, [0x1048] = 1,       -- U16 U16 U8 U8
  [0x1049] = 2, [0x104A] = 2, [0x104E] = 4, [0x104F] = 1,       -- U16 U16 U32 U8
  [0x1051] = 2, [0x1052] = 2, [0x1053] = 2, [0x1054] = 3,       -- U16 U16 U16 U24
  [0x1057] = 1, [0x105F] = 1,                                   -- U8
  [0x1080] = 2, [0x1081] = 2, [0x1082] = 2, [0x1083] = 2,       -- U16
  [0x1090] = 2, [0x1091] = 2, [0x1092] = 2, [0x1093] = 2,       -- U16
  [0x10A0] = 1, [0x10A1] = 1, [0x10A3] = 1,                     -- U8
  [0x10B1] = 2, [0x10B2] = 3, [0x10B3] = 2,                     -- S16 S24 S16
  [0x10C0] = 2, [0x10C1] = 2,                                   -- U16
  [0x1100] = 6,                                                 -- Attitude: three S16
  [0x1101] = 2, [0x1102] = 2, [0x1103] = 2,                     -- S16
  [0x1110] = 6,                                                 -- Accel: three S16
  [0x1111] = 2, [0x1112] = 2, [0x1113] = 2,                     -- S16
  [0x1121] = 1, [0x1122] = 1, [0x1123] = 1, [0x1124] = 1,       -- U8
  [0x1125] = 8,                                                 -- LatLong: two S32
  [0x1126] = 2, [0x1127] = 2, [0x1128] = 2, [0x1129] = 2,       -- S16 S16 U16 U16
  [0x112A] = 2,                                                 -- S16
  [0x1141] = 1, [0x1142] = 1, [0x1143] = 1,                     -- U8
  [0x1200] = 1, [0x1201] = 2, [0x1202] = 1, [0x1203] = 4,       -- U8 U16 U8 U32
  [0x1204] = 1, [0x1205] = 1,                                   -- U8
  [0x1211] = 1, [0x1212] = 1, [0x1213] = 1, [0x1214] = 1,       -- U8
  [0x1220] = 6,                                                 -- AdjFunc: U16 then S32
  [0x1230] = 4, [0x1231] = 4,                                   -- U32 (newer firmware)
  [0xDB00] = 4, [0xDB01] = 4, [0xDB02] = 4, [0xDB03] = 4,       -- S32
  [0xDB04] = 4, [0xDB05] = 4, [0xDB06] = 4, [0xDB07] = 4,       -- S32
}
-- In the decoder table, but sent by no firmware: the suite's own SmartFuel sensor. Left out of the
-- frames, because the drain never meets it on a link.
local NOT_ENCODED = { [0x1015] = true }

-- crsfSendCustomTelemetry (crsf.c) opens a frame with six header bytes and appends entries while
-- more than CRSF_CUSTOM_TELEMETRY_MIN_SPACE (32) of its CRSF_FRAME_SIZE_MAX (64, rx/crsf_protocol.h)
-- bytes are left; an entry that would leave no byte for the CRC goes into the next frame. So every
-- sensor is sent once per cycle of a dozen or so frames, not all of them in one.
local FRAME_SIZE_MAX, FRAME_HEADER, FRAME_MIN_SPACE = 64, 6, 32

local function packTelemetryFrames(sensorIds)
  local frames, entries, used = {}, {}, FRAME_HEADER
  for _, sid in ipairs(sensorIds) do
    if not NOT_ENCODED[sid] then
      local width = WIRE_WIDTH[sid]
      if width == nil then
        error(string.format("accounting: sensor 0x%04X has a decoder but no wire width here; "
          .. "add the width its firmware encoder writes", sid))
      end
      local size = 2 + width
      if #entries > 0 and (FRAME_SIZE_MAX - used <= FRAME_MIN_SPACE or FRAME_SIZE_MAX - used - size < 1) then
        frames[#frames + 1] = entries
        entries, used = {}, FRAME_HEADER
      end
      local bytes = {}
      if sid == 0x102F then
        bytes[1] = CELL_COUNT
        for i = 1, CELL_COUNT do bytes[i + 1] = CELL_BYTE end
      else
        for i = 1, width do bytes[i] = 0 end
      end
      entries[#entries + 1] = { sid = sid, bytes = bytes }
      used = used + size
    end
  end
  if #entries > 0 then frames[#frames + 1] = entries end
  return frames
end

-- The cycle for the sensor list the run was given, packed once.
local cycleFor, cycle = nil, nil

-- One custom telemetry frame, as the radio hands it to the script: the destination, the origin
-- and the frame id, then the entries -- without the sync, length, type and CRC bytes. Consecutive
-- frame ids walk the cycle, so a backlog carries consecutive frames of it. A fresh table every
-- time, as crossfireTelemetryPop hands out: the drain keeps a reference to a frame it published a
-- group from.
local function buildTelemetryFrame(frameId, sensorIds)
  if cycleFor ~= sensorIds then
    cycle, cycleFor = packTelemetryFrames(sensorIds), sensorIds
  end
  local frame = { 0xEA, 0xC8, frameId & 0xFF }
  for _, entry in ipairs(cycle[frameId % #cycle + 1]) do
    frame[#frame + 1] = (entry.sid >> 8) & 0xFF
    frame[#frame + 1] = entry.sid & 0xFF
    for _, b in ipairs(entry.bytes) do frame[#frame + 1] = b end
  end
  return frame
end

--- Walk every frame of the cycle the way the drain does, with the repository's decoders, and fail
-- unless each entry is consumed at the width its encoder wrote and each frame to its last byte.
-- Returns the number of frames in the cycle and the fewest and most entries one of them carries.
local function checkTelemetryFrames(sensorIds, decoders)
  buildTelemetryFrame(0, sensorIds)
  local fewest, most = math.huge, 0
  for index = 1, #cycle do
    local frame = buildTelemetryFrame(index - 1, sensorIds)
    if #frame + 4 > FRAME_SIZE_MAX then
      error(string.format("accounting: telemetry frame %d is %d bytes on the wire, over the %d the firmware sends",
        index, #frame + 4, FRAME_SIZE_MAX))
    end
    local ptr, entries = 4, 0
    while ptr <= #frame do
      local sid = (frame[ptr] << 8) + frame[ptr + 1]
      local sensor = decoders[sid]
      if type(sensor) ~= "table" or type(sensor.dec) ~= "function" then
        error(string.format("accounting: telemetry frame %d: no decoder for sensor 0x%04X", index, sid))
      end
      local ok, res, nextPtr = pcall(sensor.dec, frame, ptr + 2)
      if not ok or nextPtr ~= ptr + 2 + WIRE_WIDTH[sid] then
        local what = ok and string.format("consumed %d bytes", (tonumber(nextPtr) or ptr + 2) - ptr - 2)
          or ("raised (" .. tostring(res) .. ")")
        error(string.format("accounting: telemetry frame %d: the decoder for sensor 0x%04X %s where its "
          .. "firmware encoder writes %d; the frame is not decoded as it is sent", index, sid, what,
          WIRE_WIDTH[sid]))
      end
      ptr = nextPtr
      entries = entries + 1
    end
    fewest, most = math.min(fewest, entries), math.max(most, entries)
  end
  return #cycle, fewest, most
end

-- What "the allowance fully drawn" means for a STATE pass: the drain finds a full backlog
-- waiting and decodes its cap out of it, and the MSP poll loop finds a reply on every poll
-- instead of running out of work early. tasks.lua pops at most POP_CAP per wakeup.
local FRAME_BACKLOG = 15

local function feedLink(sensorIds, frameId)
  for i = 1, FRAME_BACKLOG do
    Stubs.pushFrame(0x88, buildTelemetryFrame(frameId + i, sensorIds))
  end
end

-- The frame type feedLink pushes: a custom telemetry frame, as against a flight controller's MSP
-- response, which arrives on the same queue and is what a prime is waiting for.
local FRAME_TELEMETRY = 0x88

--- Put the link back to the backlog feedLink models, before a pass that is about to be measured.
--
-- feedLink tops the stub's frame queue up on every pass and nothing takes back what the pass did
-- not read, so the leftovers grow for as long as a scenario runs -- five figures by the end of a
-- long one. Nothing reads them until an MSP request is outstanding. Then the CRSF transport walks
-- maxFramesPerPoll frames per poll and mspPollSlicePolls polls per call, on BOTH turns the widget
-- pass gives the queue, and a pile that never runs out is what makes those caps reachable:
-- fifteen thousand instructions of polling that a radio does not pay, because a radio's queue
-- holds a pass's worth of frames and the loop runs out of frames long before it runs out of caps.
--
-- Leaving them in is what made pass.tuning.state measure 12 730 or 24 107 for identical code --
-- the difference was not the work the pass did, but whether the prime happened to have a request
-- outstanding while the pile was deep. So the scenario that drives the overlay -- the only one
-- here that runs several hundred passes with MSP requests in flight -- holds the queue at one
-- pass's worth before every pass it drives. The flight controller's own replies are kept: the
-- oldest telemetry is what a queue that overflows drops.
local function holdLinkBacklog()
  local frames = Stubs.telemetryFrames
  local surplus = #frames - FRAME_BACKLOG
  if surplus <= 0 then return end
  local kept, n = {}, 0
  for i = 1, #frames do
    local frame = frames[i]
    if surplus > 0 and frame.command == FRAME_TELEMETRY then
      surplus = surplus - 1
    else
      n = n + 1
      kept[n] = frame
    end
  end
  Stubs.telemetryFrames = kept
end

-- The frame type the flight controller stub answers with.
local FRAME_MSP_REPLY = 0x7B

--- A link that answers between two passes instead of inside the call that asked.
--
-- stubs/fc.lua answers at the wire and synchronously: it decodes the frame the transport pushed
-- and queues the reply before crossfireTelemetryPush has returned. A board answers milliseconds
-- later, so its reply is always already waiting when a pass polls -- and a widget pass polls the
-- MSP queue (Runtime.tick) BEFORE it drains custom telemetry, so the poll is always what sees it.
-- Answered synchronously, the reply instead lands between those two, and the drain is what finds
-- it: lib/crsf.lua buffers a frame only for a frame type its OWN instance has been asked for, and
-- the drain and the MSP transport each load that file for themselves, so a reply the drain reaches
-- first is discarded rather than handed on. Every retry of that request then goes out from the
-- same place and is lost the same way.
--
-- That is why a prime in this world used to stop wherever it happened to stop, and why the same
-- code measured 12 730 or 24 107: the rows depended on how far the run had got, not on what the
-- pass did. Holding the replies for one pass is the link the rest of this file already assumes.
local heldReplies = {}
local realPushFrame = Stubs.pushFrame

local function installDeferredLink()
  realPushFrame = Stubs.pushFrame
  Stubs.pushFrame = function(command, data)
    if command == FRAME_MSP_REPLY then
      heldReplies[#heldReplies + 1] = { command = command, data = data }
      return
    end
    return realPushFrame(command, data)
  end
end

local function removeDeferredLink()
  Stubs.pushFrame = realPushFrame
  for i = #heldReplies, 1, -1 do heldReplies[i] = nil end
end

--- Deliver what the flight controller answered during the previous pass.
local function releaseReplies()
  local n = #heldReplies
  if n == 0 then return end
  for i = 1, n do realPushFrame(heldReplies[i].command, heldReplies[i].data) end
  for i = n, 1, -1 do heldReplies[i] = nil end
end

-- ---------------------------------------------------------------------------
-- Pass classification. The dispatcher in widgets/dashboard/runtime.lua decides what a
-- pass does from the job slot BEFORE the call, so that is where the class is read.
-- ---------------------------------------------------------------------------
local function passClass(widget)
  local job = widget._job
  if not job then return "state" end
  if job.kind == "splash" then return "splash" end
  if job.kind == "standby" then return "standby" end
  if job.kind == "menu" then return "menu" end
  if job.kind == "tuning" or job.kind == "tuning_fs" then return "tuning" end
  if job.swap then return "swap" end
  if job.build then return "build" end
  return "prepare"
end

--- Drive a dashboard widget until it has settled: link up, connect chain done, scene built.
--
-- Everything before that is the cold start, which loads several dozen modules and is
-- reported as a row of its own rather than folded into the steady-state numbers.
--
-- The tail also has to outlast the one-time announcements a fresh connection makes.
-- Those are spaced by their own cooldowns, so how many passes after the swap the last
-- of them lands depends on which of them ran at all. With a tail of 20, silencing one
-- moves a later one into the first measured pass, where it reads as +2892 instructions
-- of steady-state cost that no pass on a radio pays: on an otherwise untouched tree,
-- forcing the initial fuel announcement off takes pass.state from 11460 to 14352 at a
-- tail of 20, and leaves it at 10706 once the tail is long enough to cover it. A tail
-- of 31 is the first that clears it, so 40 keeps ten passes of margin.
local SETTLE_TAIL = 40

-- The pass budgets handed to settle() and to the prime loop below are ten times what they were
-- under the per-call clock. Nothing waits longer in seconds: a pass is now worth a fixed 100 ms of
-- clock rather than however many ticks that pass happened to ask for, so the same elapsed time is
-- reached in about ten times the passes. The budgets are a guard against a loop that never
-- finishes, so they are scaled with the clock rather than tuned to a run.
--
-- A free-form theme -- one whose module has a build function -- builds its whole tree in the
-- prepare pass and never swaps (sceneJobStep in widgets/dashboard/runtime.lua), so for it the
-- first scene is on screen after the prepare pass that left the job slot empty and the widget
-- built. That test is only taken for a theme with a build function, so a chunked theme settles
-- on its swap exactly as before.
--
-- The job step runs under the widget's pcall, which logs what it caught and rebuilds on the
-- next pass. A build that raises on every pass therefore looks like one that never settles, so
-- the widget's log ring is read after each pass -- outside the count -- and the error names it.
--
-- `uncounted` drives the same passes without the hook, for a scenario that prices nothing in its
-- settle: the hook and the collection before every counted pass are most of what a pass costs
-- here in time, and the cold-start figures it would return are thrown away.
local function settle(widget, sensorIds, maxPasses, uncounted)
  local coldWorst = 0
  local startupWorst = {}
  local sceneAt = nil
  local raised, lastRaise = 0, nil
  for i = 1, maxPasses do
    feedLink(sensorIds, i)
    local before = passClass(widget)
    local theme = widget.theme
    local freeForm = before == "prepare" and widget._job.kind == "scene"
      and type(theme) == "table" and type(theme.build) == "function"
    local logSeq = _G.rfsuite.log_history_seq or 0
    local n = 0
    if uncounted then
      Stubs.tick()
      widget.refresh(widget, nil, nil)
    else
      n = count(widget.refresh, widget, nil, nil)
    end
    if n > coldWorst then coldWorst = n end
    if n > (startupWorst[before] or 0) then startupWorst[before] = n end
    if before == "swap" then sceneAt = sceneAt or i end
    if freeForm and widget._job == nil and widget.built then sceneAt = sceneAt or i end
    local history = _G.rfsuite.log_history or {}
    local added = (_G.rfsuite.log_history_seq or 0) - logSeq
    for k = math.max(1, #history - added + 1), #history do
      local msg = history[k].msg
      if string.find(msg, "job step error (", 1, true) == 1 then raised, lastRaise = raised + 1, msg end
    end
    -- The first scene on screen, plus a tail: the pass after a swap still carries the
    -- module loads the first build pulled in, and those belong to the cold start.
    if sceneAt and i >= sceneAt + SETTLE_TAIL then return coldWorst, i, startupWorst end
  end
  if raised > 0 then
    error(string.format("accounting: the dashboard's job step raised on %d of %d passes, so no "
      .. "scene settled; the last error: %s", raised, maxPasses, lastRaise))
  end
  error("accounting: the dashboard never settled in " .. maxPasses .. " passes")
end

--- Force the next STATE pass to enqueue a scene build: a render key that has moved.
local function invalidate(widget)
  widget._cachedRenderKey = nil
  widget._cachedTuningKey = nil
  widget.renderKey = nil
  widget._lastUIRefresh = 0
  widget.built = false
end

--- Run one scenario: a widget on `themePath`, settled, then `passes` measured passes.
local function runScenario(themePath, passes)
  World.reset()
  local sensorIds = World.sensorIds
  local Runtime = World.require("widgets/dashboard/runtime.lua")
  local widget = Runtime.new(ZONE, {})
  widget.preferences = widget.preferences or {}
  widget.preferences.dashboard = { theme_preflight = themePath }

  local coldWorst, settlePasses, startupWorst = settle(widget, sensorIds, 4000)

  local worst = {}
  for i = 1, passes do
    feedLink(sensorIds, i)
    -- Every third pass, move the render key so the build and swap classes keep occurring.
    if i % 3 == 0 then invalidate(widget) end
    local class = passClass(widget)
    local n = count(widget.refresh, widget, nil, nil)
    if n > (worst[class] or 0) then worst[class] = n end
  end

  return {
    theme = themePath,
    worst = worst,
    coldWorst = coldWorst,
    settlePasses = settlePasses,
    startupWorst = startupWorst,
    refs = Stubs.lvgl.refs,
    widget = widget,
  }
end

local function bytes(value)
  local out = {}; for i = 1, #value do out[#out + 1] = string.byte(value, i) end
  out[#out + 1] = 0; return out
end
local function append(out, values) for i = 1, #values do out[#out + 1] = values[i] end end
local function elrsInfo(count)
  local out = { 0xEA, 0xEE }; append(out, bytes("ELRS TX"))
  append(out, { 0x45, 0x4C, 0x52, 0x53, 0, 0, 0, 1, 0, 4, 1, 0, count }); return out
end
local function elrsField(id, name, options, selected, unit)
  local out = { 0xEA, 0xEE, id, 0, 0, 9 }; append(out, bytes(name)); append(out, bytes(table.concat(options, ";")))
  append(out, { selected, 0, #options - 1, 0 }); append(out, bytes(unit or "")); return out
end

local function runStandbyScenario(layout, gps, elrsReplies, expectedTiles)
  World.reset()
  local savedGps = _G.getTxGPS
  _G.getTxGPS = function() return gps end
  local fields = {
    elrsField(1, "Packet Rate", { "D250", "500Hz" }, 1),
    elrsField(2, "Telem Ratio", { "Std", "Race", "Off", "1:128" }, 3),
    elrsField(3, "Max Power", { "25", "1000" }, 1, "mW"),
    elrsField(4, "Dynamic", { "Off", "Dyn", "AUX9" }, 2),
  }
  Stubs.onPush = function(command, data)
    if not elrsReplies then return true end
    if command == 0x28 then Stubs.pushFrame(0x29, elrsInfo(#fields))
    elseif command == 0x2C and fields[data[3]] then Stubs.pushFrame(0x2B, fields[data[3]]) end
    return true
  end
  local Runtime = World.require("widgets/dashboard/runtime.lua")
  local widget = Runtime.new(ZONE, {})
  widget.preferences = widget.preferences or {}
  widget.preferences.dashboard = { theme_preflight = "system/default", standby_enabled = true, standby_layout = layout }
  local worst, raised = {}, 0
  for i = 1, 120 do
    local class = passClass(widget)
    local logSeq = _G.rfsuite.log_history_seq or 0
    local n = count(widget.refresh, widget, 0, nil)
    if n > (worst[class] or 0) then worst[class] = n end
    local history = _G.rfsuite.log_history or {}
    local added = (_G.rfsuite.log_history_seq or 0) - logSeq
    for k = math.max(1, #history - added + 1), #history do
      if string.find(history[k].msg, "job step error (", 1, true) == 1 then raised = raised + 1 end
    end
  end
  _G.getTxGPS = savedGps
  if widget.state.fblConnected == true then error("accounting: standby scenario unexpectedly connected to an FC") end
  if widget._treeKind ~= "standby" or not widget.built then error("accounting: standby scene was not built") end
  if raised > 0 or (widget._jobFaults.standby or 0) > 0 then error("accounting: standby build raised") end
  if expectedTiles then
    local tree = Stubs.lvgl.trees[#Stubs.lvgl.trees] or {}
    local tiles = 0
    for i = 1, #tree do
      local node = tree[i]
      if node.type == "rectangle" and node.rounded == 7 then tiles = tiles + 1 end
    end
    if widget._standbyCache.valueOverflow or tiles ~= expectedTiles then
      error("accounting: standby scene rendered " .. tostring(tiles) .. " of " .. tostring(expectedTiles)
        .. " expected tiles (overflow=" .. tostring(widget._standbyCache.valueOverflow) .. ")")
    end
  end
  local control = sweepControl(1000)
  local sweep, refs = sweepCost(Stubs.lvgl.refs, control)
  return { worst = worst, sweep = sweep, refs = refs }
end

--- Run one scenario ARMED, with telemetry that moves between passes.
--
-- Every steady-state row of this report is measured disarmed and against a frozen sensor set,
-- which is the right shape for what those rows price. It does mean that two things are never
-- entered in a measured pass: the derived half of the telemetry read, which runs only where a
-- value has actually changed, and everything a flight costs -- the record of the flight's own
-- statistics among it. A row measured there would be a zero that reads as free.
--
-- So: arm the model, and move the values a flight moves. The arm edge itself is settled out
-- first, because the widget changes flight mode on it and reloads the theme behind it, and that
-- is a build rather than the steady state this measures.
local function runArmedScenario(themePath, passes)
  World.reset()
  local sensorIds = World.sensorIds
  local Runtime = World.require("widgets/dashboard/runtime.lua")
  local widget = Runtime.new(ZONE, {})
  widget.preferences = widget.preferences or {}
  widget.preferences.dashboard = { theme_preflight = themePath }

  settle(widget, sensorIds, 400)

  Stubs.sensors["ARM"] = 1
  for i = 1, SETTLE_TAIL do
    feedLink(sensorIds, 10000 + i)
    widget.refresh(widget, nil, nil)
  end

  local worst = {}
  local eventsWorst = 0
  local Events = World.require("tasks/events/runtime.lua")
  local session = _G.rfsuite.session
  for i = 1, passes do
    feedLink(sensorIds, 20000 + i)
    -- What a flight does to the values the record tracks. A sensor set that does not move
    -- leaves telemetryChanged false, and then this scenario measures the same thing as the
    -- disarmed rows above.
    local k = i % 8
    Stubs.sensors["Hspd"] = 1500 + k * 100
    Stubs.sensors["Curr"] = 10 + k
    Stubs.sensors["Vbat"] = 23 + k / 10
    Stubs.sensors["EscT"] = 40 + k
    Stubs.sensors["Thr%"] = 20 + k * 5

    local class = passClass(widget)
    local n = count(widget.refresh, widget, nil, nil)
    if n > (worst[class] or 0) then worst[class] = n end

    session.event_context = "widget"
    local e = count(Events.wakeup)
    session.event_context = nil
    if e > eventsWorst then eventsWorst = e end
  end

  Stubs.sensors["ARM"] = 0
  return worst, eventsWorst
end

--- The armed scenario again, with the arm or the disarm moved across the cadence grid.
--
-- The widget's work is a set of periodic items -- the 0.5 s telemetry read, the flight record's
-- 0.5 s sample, SmartFuel's 1 s wake, the audio pass -- and an arm or disarm edge lands on
-- whichever of them fall on the same pass. So a run with the edge at one fixed pass prices one
-- phase of that grid, and moving the edge by a pass can move the figure by thousands (#440).
-- This settles, runs `armPad` disarmed passes, arms for 240 passes with the values moving, flies
-- for 120, runs `disarmPad` more, disarms, and runs 240 post-flight passes. It hands back every
-- counted pass, so the edge windows can be read off at each phase.
--
-- Only widget.refresh is called per pass. runArmedScenario also calls Events.wakeup between
-- passes, and that would run anything a widget pass has left for the next tick.
local function runPhaseScenario(themePath, armPad, disarmPad)
  World.reset()
  local sensorIds = World.sensorIds
  local Runtime = World.require("widgets/dashboard/runtime.lua")
  local widget = Runtime.new(ZONE, {})
  widget.preferences = widget.preferences or {}
  widget.preferences.dashboard = { theme_preflight = themePath }

  settle(widget, sensorIds, 400)

  local passes = {}

  local function moving(i, throttle)
    local k = i % 8
    Stubs.sensors["Hspd"] = 1500 + k * 100
    Stubs.sensors["Curr"] = 10 + k
    Stubs.sensors["Vbat"] = 23 + k / 10
    Stubs.sensors["EscT"] = 40 + k
    Stubs.sensors["Thr%"] = throttle + k
  end

  local function drive(tag, passCount, frameBase, perPass)
    for i = 1, passCount do
      holdLinkBacklog()
      releaseReplies()
      feedLink(sensorIds, frameBase + i)
      if perPass then perPass(i) end
      local class = passClass(widget)
      local readAt = widget._lastTelemetryReadAt
      local audioAt = widget.audioState and widget.audioState.nextProcessAt
      local n = count(widget.refresh, widget, nil, nil)
      passes[#passes + 1] = {
        tag = tag, i = i, class = class, n = n,
        read = widget._lastTelemetryReadAt ~= readAt,
        -- Audio.process moves its own throttle stamp when it runs past the throttle.
        audio = (widget.audioState and widget.audioState.nextProcessAt) ~= audioAt,
      }
    end
  end

  installDeferredLink()
  drive("pre", armPad, 39000)
  Stubs.sensors["Gov"] = 2
  Stubs.sensors["ARM"] = 1
  drive("armed", 240, 40000, function(i) moving(i, 20) end)
  Stubs.sensors["Gov"] = 4
  drive("inflight", 120, 41000, function(i) moving(i, 40) end)
  drive("pad", disarmPad, 41500, function(i) moving(i, 40) end)
  Stubs.sensors["ARM"] = 0
  Stubs.sensors["Gov"] = 0
  Stubs.sensors["Thr%"] = 0
  drive("post", 240, 42000)
  removeDeferredLink()

  return passes
end

--- The worst pass and the sum of the passes `first`..`last` of one section of a phase run.
local function phaseWindow(passes, tag, first, last)
  local w = { worst = 0, at = 0, read = false, sum = 0 }
  for _, p in ipairs(passes) do
    if p.tag == tag and p.i >= first and p.i <= last then
      w.sum = w.sum + p.n
      if p.n > w.worst then
        w.worst, w.at, w.read = p.n, p.i, p.read
      end
    end
  end
  return w
end

--- Every counted pass of a phase run, summed, and how many of them ran the announcements.
local function runTotal(passes)
  local total, audio = 0, 0
  for _, p in ipairs(passes) do
    total = total + p.n
    if p.audio then audio = audio + 1 end
  end
  return total, audio
end

-- ---------------------------------------------------------------------------
-- The tool's pages, opened inside the dashboard the way a pilot opens them.
--
-- The dashboard does not start the tool script: widgets/dashboard/tool_host.lua loads ui/home.lua
-- into the widget's own Lua state and drives it from widget.refresh for as long as it is open. So a
-- page opened there is built inside a widget call, and a widget call is stopped at the instruction
-- limit the rest of this file prices against. The tool script is not: a call there is yielded once
-- it has held the interpreter for a task period, which is why the page rows are measured hosted.
--
-- What is gated is the page's BUILD -- the instructions inside its module's build, the one call
-- that lays its whole screen out. It is the part of opening a page the host cannot spread over
-- passes: it runs inside a single widget call, and every attempt at it is the same deterministic
-- code, so a page whose build alone needs more than a call is allowed does not finish building
-- hosted, whichever pass it is tried on. It is also the one figure here that does not move with
-- the cadence grid the rest of the pass sits on; the --pages report prints it beside the worst
-- pass, which does.
-- ---------------------------------------------------------------------------

local TOOL_PAGE_ROOT = "/SCRIPTS/TOOLS/rfsuite-core/app/pages/"

-- The switches a pilot sets under the general settings to reach the developer pages and the
-- preview features. The pages behind them ship, so they are priced like every other page.
local TOOL_CONDITIONS = { "developerTools", "previewSetupWizard", "previewFlightLog", "previewInflightTuning" }

-- How many passes an open may take, and how many in a row it has to stay quiet -- no build, nothing
-- outstanding on the link, nothing waiting to be redrawn -- before the page counts as settled. Most
-- pages build more than once while they open, so the open is not over when the first build is,
-- and the row takes the dearest build of the open.
local PAGE_PASSES = 400
local PAGE_QUIET = 10

--- An upvalue of `fn` by name, or an error that names it.
local function upvalue(fn, name)
  local i = 1
  while true do
    local found, value = debug.getupvalue(fn, i)
    if found == nil then break end
    if found == name then return value end
    i = i + 1
  end
  error("accounting: `" .. name .. "` is no longer an upvalue of ui/home.lua's run, and the page "
    .. "driver reads the tool's menu state through it")
end

--- The presses that lead from the tool's start menu to `menuId`, and the menu each of them opens,
--- or nil where no menu leads there.
--
-- Read off the manifest the tool builds its menus from, breadth first, so a page reached from
-- more than one menu is reached by the shortest way. The first press is a tile of the start menu,
-- named by its section; every press after it is a tile of the menu the one before it opened.
-- The theme and the page of it the theme settings page is priced on (openToolPageActual).
local SETTINGS_THEME = "system/default"
local SETTINGS_PAGE = "preflight"

local function pathTo(manifest, menuId)
  local queue, seen = {}, {}
  for _, section in ipairs(manifest.sections or {}) do
    for _, entry in ipairs(section.pages or {}) do
      queue[#queue + 1] = { presses = { { section = section.id, card = entry.id } }, opens = { entry.menuId } }
    end
  end
  local head = 1
  while head <= #queue do
    local node = queue[head]
    head = head + 1
    local opened = node.opens[#node.opens]
    if opened == menuId then return node.presses, node.opens end
    if opened ~= nil and not seen[opened] then
      seen[opened] = true
      local menu = manifest.menus and manifest.menus[opened]
      for _, entry in ipairs(menu and menu.pages or {}) do
        local presses, opens = { table.unpack(node.presses) }, { table.unpack(node.opens) }
        presses[#presses + 1] = entry.id
        opens[#opens + 1] = entry.menuId
        queue[#queue + 1] = { presses = presses, opens = opens }
      end
    end
  end
  return nil
end

--- Open one of the tool's pages in a settled dashboard and price it.
--
-- The world is the reference dashboard, settled as every other scenario here settles it, with the
-- tool's own firmware surface added (stubs/edgetx.lua, installTool). The tool is opened through
-- the host exactly as a press on the dashboard opens it, and every press after that is a tile
-- press: the target is parked in the tool's own `pendingMenuOpen`, which is all a press does
-- (ui/home.lua, getCardPressHandler), and the next pass opens it. From the host's request on, the
-- flight controller answers between passes and the link holds one pass's worth of telemetry, as
-- in the in-flight tuning scenario.
--
-- `pad` passes are driven on the page's parent menu before the press, which moves the open across
-- the cadence grid. `counted` counts every pass of the open rather than the build alone, for the
-- worst pass and the total the --pages report prints. `fault` is the self-test's: it breaks the
-- run in one of the ways the controls below exist to catch, and is nil everywhere else.
--
-- Answers { build, builds, worst, total, passes, served, empty } for a page that was priced, and
-- { skipped = reason } for one that cannot be opened in this world. A page that should have opened
-- and did not is an error, never a skip.
local function openToolPageActual(theme, menuId, pagePath, pad, counted, fault, escPage, prepare)
  World.reset()
  Stubs.installTool()
  -- A link that never delivers what the flight controller answers, as a link left over from an
  -- earlier world would: the connect chain asks and is never told.
  if fault == "unanswered" then
    local deliver = Stubs.pushFrame
    Stubs.pushFrame = function(command, data)
      if command ~= FRAME_MSP_REPLY then return deliver(command, data) end
    end
  end

  -- The build, counted on the hook's own counter. The page module is wrapped where the registry
  -- loads it, so its build is the module's own; the wrapper's call into it and back is billed with
  -- it, a handful of instructions, and every other load pays one table comparison. Inside a pass
  -- that is being counted the build is read off that pass's hook; in a pass that is not, the
  -- wrapper hooks the build alone, and both read the same instructions.
  local builds = { worst = 0, count = 0, declared = nil }
  local pageBuild
  local function measured(hooked, before, ...)
    local spent = tally - before
    if not hooked then debug.sethook() end
    builds.count = builds.count + 1
    if spent > builds.worst then builds.worst = spent end
    return ...
  end
  local stubLoad = _G.loadScript
  local pageFile = TOOL_PAGE_ROOT .. pagePath
  _G.loadScript = function(path, mode)
    local chunk = stubLoad(path, mode)
    if chunk == nil or path ~= pageFile then return chunk end
    return function(...)
      local module = chunk(...)
      builds.declared = type(module) == "table" and type(module.build) == "function"
      if builds.declared then
        local build = module.build
        pageBuild = build
        module.build = function(...)
          local hooked = debug.gethook() ~= nil
          if not hooked then debug.sethook(bill, "", 1) end
          return measured(hooked, tally, build(...))
        end
      end
      return module
    end
  end

  local Runtime = World.require("widgets/dashboard/runtime.lua")
  local widget = Runtime.new(ZONE, {})
  widget.preferences = widget.preferences or {}
  widget.preferences.dashboard = { theme_preflight = theme }
  settle(widget, World.sensorIds, 4000, true)
  -- The dashboard's settle is what connects the link, and the tool shares that connection rather
  -- than making its own. A world that settled without it would price every page on the screen of
  -- a radio with no flight controller.
  local session = _G.rfsuite.session
  if session.isConnected ~= true or session.mcu_id == nil then
    error("accounting: the dashboard settled without a connected flight controller (isConnected="
      .. tostring(session.isConnected) .. ", mcu_id=" .. tostring(session.mcu_id) .. ")")
  end
  if prepare then prepare(session) end
  installDeferredLink()

  local ToolHost = World.require("widgets/dashboard/tool_host.lua")
  if not ToolHost.request(widget) then error("accounting: the dashboard refused to open the tool") end

  local Msp = World.require("tasks/msp/runtime.lua")
  local function linkIdle()
    return Msp.getState().queue:isProcessed() and #heldReplies == 0
  end
  local function linkState()
    return string.format("%d replies the flight controller sent are held off the link, the queue is %s",
      #heldReplies, Msp.getState().queue:isProcessed() and "idle" or "busy")
  end

  -- One pass of the widget with the tool open. The event is 0 and never nil: nil is the firmware
  -- saying fullscreen was left, and the host closes the tool on it.
  local frame = 0
  local function pass(counting)
    frame = frame + 1
    holdLinkBacklog()
    if fault ~= "held" then releaseReplies() end
    feedLink(World.sensorIds, 50000 + frame)
    if counting or pagePath == "settings/dashboard/inflight/page.lua" then return count(widget.refresh, widget, 0, nil) end
    Stubs.tick()
    widget.refresh(widget, 0, nil)
    return 0
  end

  -- The host loads ui/home.lua on one pass and initialises it on the next.
  pass(false)
  pass(false)
  local host = widget._toolHost
  local home = host and host.home
  if type(home) ~= "table" or host.phase ~= "run" then
    error("accounting: the tool host did not bring ui/home.lua up (phase " .. tostring(host and host.phase) .. ")")
  end
  local state = upvalue(home.run, "state")
  for _, condition in ipairs(TOOL_CONDITIONS) do state.menu.setCondition(condition, true) end
  if pagePath == "settings/dashboard/standby/page.lua" then
    state.preferences.dashboard = state.preferences.dashboard or {}
    state.preferences.dashboard.standby_layout = "clock+date+tx_battery+model/"
      .. "timer1+timer2+timer3+uptime/tx_battery+model+timer1+timer2"
  elseif pagePath == "settings/dashboard/overrides/page.lua" then
    -- One model setting differs from the radio's standard, so the overview draws its list.
    -- These tables belong to this world: World.reset replaces the session and module loader,
    -- and the next ui/home.lua creates its own state and preferences, even after a failed open.
    -- The card survives that reset; opening this page does not save these seeded values.
    state.preferences.dashboard.model_overrides = true
    state.preferences.dashboard.cfg_system_default_link_colors = false
    session.modelPreferences.dashboard = { overrides = true, cfg_system_default_link_colors = true }
  end

  local function settled(want)
    local quiet = 0
    for _ = 1, PAGE_PASSES do
      pass(false)
      local idle = linkIdle() and not state.pendingBuildUI and state.pendingMenuOpen == nil
        and state.initialLoad == false
      quiet = (idle and state.menu.getCurrentMenuId() == want) and quiet + 1 or 0
      if quiet >= PAGE_QUIET then return true end
    end
    return false
  end

  if not settled(nil) then
    error("accounting: the tool never left its start screen for its menu in " .. PAGE_PASSES .. " passes; "
      .. linkState())
  end
  if state.fblConnected ~= true then
    error("accounting: the tool came up without a connected flight controller")
  end

  local presses, opens = pathTo(state.manifest, menuId)
  -- The menu the press lands on. A page reached through a tile the tool builds at run time opens
  -- under that tile's own id rather than its file's.
  local landing = menuId
  if presses == nil and pagePath == "settings/dashboard/overrides/page.lua" then
    -- Entering Settings builds its dynamic tiles; the model's overview is the first one.
    presses, opens = pathTo(state.manifest, "settings_dashboard_settings_menu")
    if presses ~= nil then
      presses[#presses + 1] = "dashboard_overrides"
      opens[#opens + 1] = menuId
    end
  elseif presses == nil and pagePath == "settings/dashboard/settings/page.lua" then
    -- The theme settings page opens from a theme's tile in Settings (app/lib/dashboard_builder.lua),
    -- under an id carrying the theme's path in hex. Priced on the reference theme's Before flight
    -- page: the theme's pages grid, then the page that reads a phase module and lists its tiles.
    presses, opens = pathTo(state.manifest, "settings_dashboard_settings_menu")
    if presses ~= nil then
      local token = string.format(string.rep("%02x", #SETTINGS_THEME), string.byte(SETTINGS_THEME, 1, -1))
      landing = "settings_dashboard_settings_" .. token .. "_" .. SETTINGS_PAGE .. "_page"
      presses[#presses + 1] = "dashboard_settings_" .. token
      opens[#opens + 1] = "settings_dashboard_settings_" .. token .. "_menu"
      presses[#presses + 1] = "dashboard_settings_" .. token .. "_" .. SETTINGS_PAGE
      opens[#opens + 1] = landing
    end
  end
  if presses == nil then
    removeDeferredLink()
    return { skipped = "no menu leads to it" }
  end
  for i = 1, #presses - 1 do
    state.pendingMenuOpen = presses[i]
    if not settled(opens[i]) then
      error("accounting: the press towards " .. menuId .. " never reached " .. tostring(opens[i]) .. "; "
        .. linkState())
    end
  end

  local last = presses[#presses]
  local enabled
  if #presses == 1 then
    enabled = state.menu.isRootEntryEnabled(last.section, last.card)
  else
    enabled = state.menu.isEntryEnabled(last)
  end
  if not enabled then
    removeDeferredLink()
    return { skipped = "its tile is disabled in this world" }
  end

  for _ = 1, pad or 0 do pass(false) end

  -- The press, and the open it causes.
  if fault ~= "stay" then state.pendingMenuOpen = last end
  local served = FC.served
  local unanswered = {}
  for cmd, n in pairs(FC.unanswered) do unanswered[cmd] = n end
  local worst, total, passes, quiet = 0, 0, 0, 0
  local noticeAccepted = not escPage
  for i = 1, PAGE_PASSES do
    local before = builds.count
    local n = pass(counted)
    -- The ESC settings are behind a safety notice. Press its real button so the row
    -- includes the settings build rather than pricing only the notice.
    if not noticeAccepted and builds.count > 0 then
      local tree = Stubs.lvgl.trees[#Stubs.lvgl.trees]
      local children = tree and tree[1] and tree[1].children or {}
      for _, node in ipairs(children) do
        if node.type == "button" and node.text == "OK" and type(node.press) == "function" then
          node.press()
          noticeAccepted = true
          break
        end
      end
      if not noticeAccepted then error("accounting: ESC safety notice has no acknowledgement button") end
    end
    passes = i
    total = total + n
    if n > worst then worst = n end
    local idle = linkIdle() and not state.pendingBuildUI and state.pendingMenuOpen == nil
    quiet = (idle and builds.count == before) and quiet + 1 or 0
    if quiet >= PAGE_QUIET and (builds.count > 0 or builds.declared == false) then break end
  end
  local here = state.menu.getCurrentMenuId()
  local link = linkState()
  served = FC.served - served
  local empty = {}
  for cmd, n in pairs(FC.unanswered) do
    local asked = n - (unanswered[cmd] or 0)
    if asked > 0 then empty[#empty + 1] = string.format("%d(x%d)", cmd, asked) end
  end
  table.sort(empty)
  removeDeferredLink()

  -- The controls. A page priced anywhere but on itself prices that other screen; a page whose
  -- replies never reached it prices the screen it shows while it waits; and a build that raised
  -- is priced up to the raise. Each would be a plausible number with nothing in the row to say so.
  if here ~= landing then
    error("accounting: " .. landing .. " did not open; the tool is on " .. tostring(here)
      .. ", and a row measured there would price that screen")
  end
  if builds.declared == false then
    return { skipped = "it has no build of its own; the tool draws it as a menu" }
  end
  if state.pageBuildFailed ~= nil then
    error("accounting: the build of " .. menuId .. " raised; the tool shows its failure page")
  end
  if builds.count == 0 then
    error("accounting: " .. menuId .. " opened without its build being counted")
  end
  if quiet < PAGE_QUIET then
    error(string.format("accounting: %s never settled in %d passes; %s", menuId, PAGE_PASSES, link))
  end

  return {
    build = builds.worst, builds = builds.count, worst = worst, total = total, passes = passes,
    served = served, empty = empty,
  }
end

-- The Tune Advisor's tile needs MSP API 12.10, and the simulator replies report 12.9, so the page
-- has a world of its own: the same replies with the API version at 12.10, and five flights saved
-- for the connected flight controller, which is the most the page reads and combines on its open.
-- The flights are the Tune Advisor's simulator reply, saved through the page's own history module
-- with the profiles and settings the other simulator replies describe. They are written to a card
-- of this world's own, so no later page can find them.
local TUNE_ADVISOR_PAGE = "flight_tuning/tune_advisor/page.lua"
local TUNE_ADVISOR_FLIGHTS = 5

local function openTuneAdvisorPage(theme, menuId, pagePath, pad, counted, fault)
  local versionApi = assert(loadfile(API_DIR .. "/api_version.lua"))()
  local replies, cardRoot = FC.replies, Stubs.cardRoot
  FC.replies = {}
  for command, reply in pairs(replies) do FC.replies[command] = reply end
  FC.replies[versionApi.command] = { 0, 12, 10 }

  local function seedFlights(session)
    local History = World.require("lib/tune_history.lua")
    local Advisor = World.require("tasks/msp/api/tune_advisor.lua")
    local Profile = World.require("lib/profile.lua")
    local rcApi = assert(loadfile(API_DIR .. "/rc_tuning.lua"))()
    local profileApi = assert(loadfile(API_DIR .. "/pid_profile.lua"))()
    local rc = assert(rcApi.parse(FC.replies[rcApi.command]))
    local pid = assert(profileApi.parse(FC.replies[profileApi.command]))
    local context = {
      pidProfile = Profile.getActivePidProfile(1), rateProfile = Profile.getActiveRateProfile(1),
      cyclicPolarity = rc.cyclic_polarity, cyclicRing = rc.cyclic_ring, relaxType = pid.iterm_relax_type,
    }
    -- The stubs' fstat answers for the preference files only; the history checks each file it
    -- writes by its size, so the seeding has a stat of the card for as long as it writes.
    local stubStat = _G.fstat
    _G.fstat = function(path)
      local f = io.open(path, "rb")
      if not f then return nil end
      local size = f:seek("end")
      f:close()
      return { size = size }
    end
    for flight = 1, TUNE_ADVISOR_FLIGHTS do
      local axes = {}
      for axis = 1, 3 do axes[axis] = assert(Advisor.parse(Advisor.simulatorResponseFor(axis))) end
      local saved, why = History.save(session.mcu_id, axes, context, 1761800000 + flight * 600)
      if saved ~= true then
        _G.fstat = stubStat
        error("accounting: the Tune Advisor's flights could not be saved on this world's card: " .. tostring(why))
      end
    end
    _G.fstat = stubStat
  end

  Stubs.cardRoot = cardRoot .. "/tune-advisor-page"
  local ok, page = pcall(openToolPageActual, theme, menuId, pagePath, pad, counted, fault, nil, seedFlights)
  -- Restore the shared replies and card even when opening the page fails.
  FC.replies = replies
  Stubs.releaseCard()
  Stubs.cardRoot = cardRoot
  if not ok then error(page, 0) end
  return page
end

local function openToolPage(theme, menuId, pagePath, pad, counted, fault)
  local protocol, apiName
  if pagePath == TUNE_ADVISOR_PAGE then
    return openTuneAdvisorPage(theme, menuId, pagePath, pad, counted, fault)
  elseif pagePath == "setup/esc_motors/esc_tools/escmfg/flrtr/page.lua" then
    protocol, apiName = 10, "esc_parameters_flyrotor"
  elseif pagePath == "setup/esc_motors/esc_tools/escmfg/yge/page.lua" then
    protocol, apiName = 9, "esc_parameters_yge"
  else
    return openToolPageActual(theme, menuId, pagePath, pad, counted, fault)
  end

  -- The command is shared by ESC families, so its default reply is not this page's.
  local sensorApi = assert(loadfile(API_DIR .. "/esc_sensor_config.lua"))()
  local escApi = assert(loadfile(API_DIR .. "/" .. apiName .. ".lua"))()
  local replies, cardRoot = FC.replies, Stubs.cardRoot
  FC.replies = {}
  for command, reply in pairs(replies) do FC.replies[command] = reply end
  local sensorReply = { table.unpack(sensorApi.simulatorResponse) }
  sensorReply[1] = protocol
  FC.replies[sensorApi.command] = sensorReply
  FC.replies[escApi.command] = escApi.simulatorResponse

  -- A YGE read remembers its current limit in the model's preference file. Give these
  -- worlds their own card so a later page cannot inherit that saved limit or origin.
  Stubs.cardRoot = cardRoot .. "/esc-page"
  local ok, page = pcall(openToolPageActual, theme, menuId, pagePath, pad, counted, fault, true)
  -- Restore the shared replies and card even when opening the page fails.
  FC.replies = replies
  Stubs.releaseCard()
  Stubs.cardRoot = cardRoot
  if not ok then error(page, 0) end
  return page
end

-- ---------------------------------------------------------------------------
-- Report and gate
-- ---------------------------------------------------------------------------

local rows = {}
local rowIndex = {}
local notes = {}

local function addRow(name, measured, extra)
  if rowIndex[name] then error("accounting: duplicate row " .. name) end
  rowIndex[name] = true
  rows[#rows + 1] = { name = name, measured = measured, extra = extra }
end

local function note(fmt, ...)
  notes[#notes + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
end

local args = {}
for _, a in ipairs(arg or {}) do args[a] = true end
local checking = args["--check"] == true
local selfTest = args["--self-test"] == true

------------------------------------------------------------------------------
-- Inventory: what the gate has to cover, read off the tree rather than a list.
------------------------------------------------------------------------------
World.reset()

local apiFiles = listLuaFiles(API_DIR)
local indexed = FC.loadReplies(API_DIR, apiFiles)

local themes = {}
for _, name in ipairs(listDir(THEMES_DIR)) do
  local probe = io.open(THEMES_DIR .. "/" .. name .. "/init.lua", "r")
  if probe then
    probe:close()
    themes[#themes + 1] = name
  end
end
if #themes == 0 then error("accounting: no shipped theme found under " .. THEMES_DIR) end

-- Object modules on disk: objects/<type>.lua, and objects/<type>/<subtype>.lua where the
-- type has a folder of its own.
local objectFiles = listLuaFiles(OBJECTS_DIR)

-- The tool's pages, by the id a menu opens them under, from the registry the tool loads them
-- through (app/pages/init.lua). Read off that table rather than off the manifest, so a page that
-- no menu leads to is still in the inventory and the report names it. An id the registry derives
-- while the tool runs -- a theme's own settings pages -- is not in it.
local ToolPages = World.require("app/pages/init.lua")
if type(ToolPages) ~= "table" or type(ToolPages.pagePathByMenuId) ~= "table" then
  error("accounting: app/pages/init.lua did not load as the tool's page registry")
end
local toolPages = {}
for menuId in pairs(ToolPages.pagePathByMenuId) do toolPages[#toolPages + 1] = menuId end
table.sort(toolPages)
if #toolPages == 0 then error("accounting: the tool's page registry lists no page") end
local toolPagePaths = {}
for _, menuId in ipairs(toolPages) do toolPagePaths[menuId] = ToolPages.pagePathByMenuId[menuId] end

-- The sensor id list the telemetry frames carry, from the repository's own decoder table.
local RFSensors = World.require("lib/rf2tlm_sensors.lua")
if type(RFSensors) ~= "table" then error("accounting: lib/rf2tlm_sensors.lua did not load") end
local sensorIds = {}
for sid in pairs(RFSensors) do
  if type(sid) == "number" then sensorIds[#sensorIds + 1] = sid end
end
table.sort(sensorIds)
if #sensorIds == 0 then error("accounting: no sensor decoders found") end
World.sensorIds = sensorIds
local telemetryCycle, telemetryFewest, telemetryMost = checkTelemetryFrames(sensorIds, RFSensors)
local telemetryShape = string.format("%d to %d sensors per frame, a cycle of %d frames",
  telemetryFewest, telemetryMost, telemetryCycle)

local control = sweepControl(2000)

------------------------------------------------------------------------------
-- Pass classes, on the reference theme.
------------------------------------------------------------------------------
local reference = "system/default"

------------------------------------------------------------------------------
-- --pages: every tool page opened at every phase of the cadence grid, and nothing else.
--
-- A report, not a gate: no row is added and nothing is checked. The gated rows below price a
-- page's build, which the grid does not move; what the grid does move is everything else in the
-- pass that builds and in the passes around it -- the host's step, the MSP tick, the events
-- runner, a telemetry read -- so the worst pass of an open depends on which pass the press lands
-- on. This opens every page twenty times, the press moved by one 100 ms pass each, and prints per
-- page the build's range (a build that moves here depends on the phase, and its row is a reading
-- of phase 0), the range of the open's worst pass with the phase its maximum was found at, and the
-- largest total of an open. Hosted only, as the rows are. The run takes minutes rather than
-- seconds.
--
-- There is no sweep column. The lvgl stub collects every function field of a tree as a reactive
-- reference, which holds for a dashboard theme and not for a page: a page's tree carries its press
-- and change handlers as function fields too, and replaying those would act on the page.
------------------------------------------------------------------------------
if args["--pages"] then
  local PHASES = 20
  print("offline instruction accounting -- tool pages, hosted, over the cadence grid")
  print(string.format("  interpreter        %s, count hook at 1 instruction", _VERSION))
  print(string.format("  phases             %d, the press moved by one 100 ms pass each", PHASES))
  print("")
  print(string.format("  %-58s %13s %13s %5s %8s", "page", "build", "worst pass", "phase", "total"))
  for _, menuId in ipairs(toolPages) do
    local first = openToolPage(reference, menuId, toolPagePaths[menuId], 0, true)
    if first.skipped then
      print(string.format("  %-58s not opened: %s", menuId, first.skipped))
    else
      local buildLo, buildHi = first.build, first.build
      local worstLo, worstHi, worstAt, totalHi = first.worst, first.worst, 0, first.total
      for k = 1, PHASES - 1 do
        local page = openToolPage(reference, menuId, toolPagePaths[menuId], k, true)
        if page.build < buildLo then buildLo = page.build end
        if page.build > buildHi then buildHi = page.build end
        if page.worst < worstLo then worstLo = page.worst end
        if page.worst > worstHi then worstHi, worstAt = page.worst, k end
        if page.total > totalHi then totalHi = page.total end
      end
      print(string.format("  %-58s %6d-%-6d %6d-%-6d %5d %8d", menuId, buildLo, buildHi,
        worstLo, worstHi, worstAt, totalHi))
    end
  end
  Stubs.releaseCard()
  return
end

local base = runScenario(reference, 240)

addRow("pass.state", base.worst.state or 0)
addRow("pass.job.prepare", base.worst.prepare or 0)
addRow("pass.job.build", base.worst.build or 0)
addRow("pass.swap", base.worst.swap or 0)
-- The splash pass only ever happens while the widget is NOT ready, so its only home is
-- the startup window. A row measured on a window where the class never occurs would be a
-- zero that reads as free.
addRow("pass.splash", base.startupWorst.splash or base.worst.splash or 0)
addRow("pass.startup.worst", base.coldWorst, base.settlePasses .. " passes to settle")

-- The background half of a STATE pass, as the widget calls it: the onconnect runner, the
-- custom-telemetry drain and the arm/disarm edges in one. It is the largest single term in
-- a STATE pass, so it gets a row of its own rather than being visible only as the
-- difference between two other rows. Measured on the world the reference scenario left
-- standing, which is the only one with a settled link in it.
do
  local Events = World.require("tasks/events/runtime.lua")
  local session = _G.rfsuite.session
  local worst = 0
  for i = 1, 120 do
    feedLink(World.sensorIds, 5000 + i)
    session.event_context = "widget"
    local n = count(Events.wakeup)
    session.event_context = nil
    if n > worst then worst = n end
  end
  addRow("unit.events.wakeup", worst)
end

------------------------------------------------------------------------------
-- The armed pass, with telemetry that moves. See runArmedScenario.
------------------------------------------------------------------------------
do
  local armedWorst, armedEvents = runArmedScenario(reference, 240)
  addRow("pass.state.armed", armedWorst.state or 0, "armed, telemetry moving between passes")
  addRow("unit.events.wakeup.armed", armedEvents, "same wakeup, armed and moving")
end

------------------------------------------------------------------------------
-- --phases: the arm and disarm edges at every phase of the cadence grid, and nothing else.
--
-- A report, not a gate: no row is added and nothing is checked. Ten phases cover the 1 s grid
-- at the 100 ms pass clock. The arm is moved with the disarm at phase 0, and the disarm with the
-- arm at phase 0, so the phase-0 run serves both. Windows: the first 16 armed passes (the arm
-- edge), armed passes 21-240 (steady armed), and the first 16 post-flight passes (the disarm
-- edge). Each prints its worst pass, the pass it was, whether that pass ran the telemetry read,
-- and the window's sum, so work carried to another pass shows as a total and not only as a peak;
-- the arm and disarm tables also print the whole run's sum, every pass after the settle, and how
-- many of those passes ran the announcements.
------------------------------------------------------------------------------
if args["--phases"] then
  local PHASES = 10
  local budget = Budgets.rows["pass.state.armed"]
  local target = budget and budget.target or 0
  local windows = { arm = {}, steady = {}, disarm = {} }
  for k = 0, PHASES - 1 do
    local armRun = runPhaseScenario(reference, k, 0)
    windows.arm[k] = phaseWindow(armRun, "armed", 1, 16)
    windows.arm[k].run, windows.arm[k].audio = runTotal(armRun)
    windows.steady[k] = phaseWindow(armRun, "armed", 21, 240)
    local disarmRun = (k == 0) and armRun or runPhaseScenario(reference, 0, k)
    windows.disarm[k] = phaseWindow(disarmRun, "post", 1, 16)
    windows.disarm[k].run, windows.disarm[k].audio = runTotal(disarmRun)
  end

  print("offline instruction accounting -- phase sweep")
  print(string.format("  interpreter        %s, count hook at 1 instruction", _VERSION))
  print(string.format("  phases             %d, the edge moved by one 100 ms pass each", PHASES))
  print(string.format("  target             %d (pass.state.armed)", target))
  print("")
  local order = {
    { "arm", "arm: armed passes 1-16" },
    { "steady", "steady: armed passes 21-240" },
    { "disarm", "disarm: post-flight passes 1-16" },
  }
  for _, o in ipairs(order) do
    local key, title = o[1], o[2]
    print("  " .. title)
    print(string.format("  %5s %9s %6s %5s %10s %11s %6s", "phase", "worst", "pass", "read", "sum", "run", "audio"))
    local lo, hi, over, total = nil, 0, 0, 0
    for k = 0, PHASES - 1 do
      local w = windows[key][k]
      print(string.format("  %5d %9d %6d %5s %10d %11s %6s", k, w.worst, w.at, w.read and "R" or "-", w.sum,
        w.run and tostring(w.run) or "", w.audio and tostring(w.audio) or ""))
      lo = (lo == nil or w.worst < lo) and w.worst or lo
      if w.worst > hi then hi = w.worst end
      if target > 0 and w.worst > target then over = over + 1 end
      total = total + w.sum
    end
    print(string.format("  worst %d-%d, over %d in %d of %d phases, window sums %d",
      lo, hi, target, over, PHASES, total))
    print("")
  end
  -- The rest of the report is not what was asked for, and nothing in it depends on this.
  return
end

------------------------------------------------------------------------------
-- Every shipped theme: worst pass plus the full sweep of the tree it leaves.
------------------------------------------------------------------------------
local boxTypes = {}
local boxFixtures = {}

local function harvestBoxes(run)
  local Utils = World.require("widgets/dashboard/objects/common.lua")
  local themeModule = run.widget.theme
  if type(themeModule) ~= "table" then return end
  local boxes = Utils.resolveValue(themeModule.boxes, nil, run.widget.state)
  local headerBoxes = Utils.resolveValue(themeModule.header_boxes, nil, run.widget.state)
  for _, list in ipairs({ boxes, headerBoxes }) do
    if type(list) == "table" then
      for _, box in ipairs(list) do
        local typ = box.type or "text"
        local sub = box.subtype
        local key = (sub ~= nil) and (typ .. "/" .. tostring(sub)) or typ
        if boxFixtures[key] == nil then
          boxTypes[#boxTypes + 1] = key
          boxFixtures[key] = { box = box, from = run.theme }
        end
      end
    end
  end
end

for _, theme in ipairs(themes) do
  local run = (theme == "default") and base or runScenario("system/" .. theme, 160)
  local worstPass = 0
  for _, n in pairs(run.worst) do
    if n > worstPass then worstPass = n end
  end
  local sweep, refCount = sweepCost(run.refs, control)
  addRow("theme." .. theme, worstPass + sweep,
    string.format("worst pass %d + sweep %d over %d refs", worstPass, sweep, refCount))
  harvestBoxes(run)
end

-- Every object module on disk that no shipped theme happens to declare still needs a row:
-- it is shipped, so it can be reached.
for _, file in ipairs(objectFiles) do
  local typ = string.gsub(file, "%.lua$", "")
  if typ ~= "common" then
    local subdir = OBJECTS_DIR .. "/" .. typ
    local subtypes = listLuaFiles(subdir)
    if #subtypes > 0 then
      for _, sub in ipairs(subtypes) do
        local key = typ .. "/" .. string.gsub(sub, "%.lua$", "")
        if boxFixtures[key] == nil then
          boxTypes[#boxTypes + 1] = key
          boxFixtures[key] = {}
        end
      end
    elseif boxFixtures[typ] == nil then
      boxTypes[#boxTypes + 1] = typ
      boxFixtures[typ] = {}
    end
  end
end
table.sort(boxTypes)

-- The standby screen: no flight controller, each composition on a fresh world. Placed after
-- every row that is measured on the world the reference scenario left standing.
do
  local largest = runStandbyScenario("clock+date+tx_battery+model/"
    .. "timer1+timer2+timer3+uptime/tx_battery+model+timer1+timer2", nil, true, 12)
  local composite = runStandbyScenario("elrs+elrs/elrs+elrs/elrs+elrs", nil, true, 6)
  local gps = runStandbyScenario("clock+date+tx_battery+model/"
    .. "timer1+timer2+timer3+uptime/tx_gps", {
    fix = true, numsat = 12, lat = 52.12345, lon = 13.54321,
    alt = 1234, speed = 56, heading = 2712, hdop = 85,
  }, false, 9)
  local elrsNoReply = runStandbyScenario("elrs", nil, false, 1)
  local elrsReady = runStandbyScenario("elrs", nil, true, 1)
  local batteries = runStandbyScenario("tx_battery+tx_battery+tx_battery+tx_battery/"
    .. "tx_battery+tx_battery+tx_battery+tx_battery/"
    .. "tx_battery+tx_battery+tx_battery+tx_battery", nil, false, 12)
  local runs = { largest, composite, gps, elrsNoReply, elrsReady, batteries }
  local build, state, sweep, refs = 0, 0, 0, 0
  for i = 1, #runs do
    build = math.max(build, runs[i].worst.standby or 0); state = math.max(state, runs[i].worst.state or 0)
    sweep = math.max(sweep, runs[i].sweep); refs = math.max(refs, runs[i].refs)
  end
  addRow("pass.standby.build", build,
    "12-field simple and repeated layouts, six ELRS fields, detailed GPS, ELRS ready and no-response states")
  addRow("pass.standby.state", state, "cached no-FC snapshot and provider step")
  addRow("sweep.standby", sweep, refs .. " reactive references")
end

------------------------------------------------------------------------------
-- Per box type: one render, and one sweep of what that render collected.
------------------------------------------------------------------------------
World.reset()
do
  local Runtime = World.require("widgets/dashboard/runtime.lua")
  local widget = Runtime.new(ZONE, {})
  local Engine = World.require("widgets/dashboard/engine.lua")
  local Derived = World.require("widgets/dashboard/derived.lua")
  local state = widget.state
  Derived.build(state, widget.boxSources)

  for _, key in ipairs(boxTypes) do
    local fixture = boxFixtures[key]
    local box = fixture.box
    if box == nil then
      local typ, sub = string.match(key, "^([^/]+)/(.+)$")
      box = { col = 1, row = 1, colspan = 1, rowspan = 1, type = typ or key, subtype = sub }
      note("box type %s is declared by no shipped theme; measured on a minimal fixture", key)
    end
    local theme = { layout = { cols = 1, rows = 1, padding = 0 }, boxes = { box } }
    -- Warm the object wrapper first: loading its module is a cold-start cost, not a render.
    Engine.build(ZONE, state, theme)
    local build = Engine.beginBuild(ZONE, state, theme)
    addRow("box." .. key, count(Engine.stepBuild, build, state, 1))

    local refs = collectRefs(build.nodes, {})
    local sweep = sweepCost(refs, control)
    addRow("sweep." .. key, sweep, #refs .. " refs")
  end
end

------------------------------------------------------------------------------
-- Per unit: the telemetry drain, the MSP poll quantum, the largest parse.
------------------------------------------------------------------------------
--- Hand every frame of the cycle through once, one frame a call, so that each sensor has been
-- published before anything is measured. A sensor's first publication is cold-start cost, as the
-- function script's warm-up below says of its own; with only one frame of the cycle in a warm-up,
-- the measured call would publish what the other frames carry for the first time, where a steady
-- link with these constant values publishes nothing. The frame ids end on 0 modulo 256, as the
-- warm-up's do, so the backlog that follows (ids from 1) reads as the next frames, not a skip.
local function primeTelemetryCycle(handle)
  buildTelemetryFrame(0, sensorIds)
  for id = 257 - #cycle, 256 do
    Stubs.telemetryFrames = {}
    Stubs.pushFrame(0x88, buildTelemetryFrame(id, sensorIds))
    handle()
    if #Stubs.telemetryFrames ~= 0 then
      error(string.format("accounting: frame %d of the cycle was not consumed while priming the drain",
        id % #cycle))
    end
  end
end

--- Warm telemetry_bg's staggered lazy loads, and prove they are warm.
--
-- tasks.lua loads at most one module per wakeup and RETURNS, so a fixed number of warm-up calls
-- is a number that goes stale the moment another module joins that chain -- and the symptom is
-- silent: the measured call returns on a load instead of draining, and the row reports the load.
-- A consumed frame is not the end of the chain either: smart.lua, once loaded, takes its own five
-- modules one per wakeup, and those wakeups drain as well -- so a warm-up that stopped at the first
-- consumed frame left one of smart.lua's loads in whichever call came next, the measured one.
-- Warm until a call consumes a frame AND calls no loader, and fail where none ever does. The calls
-- are counted by wrapping loadScript and rfsuite.require for the warm-up only: every loader on
-- this chain looks both up when it calls them, so nothing keeps the wrapper afterwards. (A call to
-- rfsuite.require that its cache answers counts too: a module that called it on every wakeup would
-- keep the warm-up from ever ending, and the run would fail here rather than measure a load.)
-- Then every frame of the cycle goes through once, so the measured call publishes no sensor for
-- the first time either.
local function warmTelemetryBg(Events)
  local loads = 0
  local loadScriptWas, requireWas = _G.loadScript, _G.rfsuite.require
  _G.loadScript = function(...)
    loads = loads + 1
    return loadScriptWas(...)
  end
  _G.rfsuite.require = function(...)
    loads = loads + 1
    return requireWas(...)
  end
  local warm = false
  for _ = 1, 20 do
    loads = 0
    Stubs.telemetryFrames = {}
    Stubs.pushFrame(0x88, buildTelemetryFrame(0, sensorIds))
    Events.wakeup()
    if #Stubs.telemetryFrames == 0 and loads == 0 then
      warm = true
      break
    end
  end
  _G.loadScript, _G.rfsuite.require = loadScriptWas, requireWas
  if not warm then
    error("accounting: telemetry_bg never consumed a frame without calling a loader; "
      .. "the drain row would measure a load")
  end
  primeTelemetryCycle(Events.wakeup)
end

World.reset()
do
  local Events = World.require("tasks/events/telemetry_bg/tasks.lua")
  warmTelemetryBg(Events)
  for i = 1, FRAME_BACKLOG do
    Stubs.pushFrame(0x88, buildTelemetryFrame(i, sensorIds))
  end
  addRow("unit.telemetry.drain", count(Events.wakeup),
    FRAME_BACKLOG .. " frames queued, " .. telemetryShape)
end

-- The same wakeup while the background function script is draining: the liveness counter in the
-- shared-memory slot moves, so this pass leaves the drain and the adjustment teller to that
-- script and does only what stays its own. The difference against the row above is what the
-- widget gains by handing over.
World.reset()
do
  local Events = World.require("tasks/events/telemetry_bg/tasks.lua")
  local Drain = World.require("tasks/events/telemetry_bg/drain.lua")
  warmTelemetryBg(Events)

  -- The liveness reader's FIRST read only records, so the pass that establishes the handover is
  -- not the pass to measure: bump, spend a pass on it, bump again, then measure.
  Drain.publishLiveness()
  Events.wakeup()
  Drain.publishLiveness()

  for i = 1, FRAME_BACKLOG do
    Stubs.pushFrame(0x88, buildTelemetryFrame(i, sensorIds))
  end
  local queued = #Stubs.telemetryFrames
  local billed = count(Events.wakeup)
  -- The control this row cannot do without: a pass that drained after all would still produce a
  -- plausible number, and it would be the number of the row above under a different name.
  if #Stubs.telemetryFrames ~= queued then
    error("accounting: the handoff row drained the queue; it is measuring the wrong pass")
  end
  addRow("unit.telemetry.handoff", billed,
    FRAME_BACKLOG .. " frames queued, left to the background script")
end

-- The background script's own pass. It is the host the drain moves to, and it is billed
-- differently -- a call there is yielded on a task period rather than cut off at an instruction
-- count -- so it decodes the whole backlog. What that costs belongs in this table beside the
-- widget's capped pass rather than in nobody's.
World.reset()
do
  -- By the path the installed tree carries it under, through the stub's own remap, so the
  -- script is reached here the way it is reached on a radio.
  local script = assert(loadScript("/SCRIPTS/FUNCTIONS/rfsbg.lua", "bt"))()
  if type(script) ~= "table" or type(script.run) ~= "function" then
    error("accounting: src/functions/rfsbg.lua does not return a run function")
  end
  -- The first run only loads. After it, run until a run takes a frame off the queue: the drain
  -- loads its decoder table on a run of its own, and the first run that drains also pulls in the
  -- CRSF multiplexer and publishes every sensor for the first time. All of that is cold-start
  -- cost, and a fixed number of warm-up runs goes stale the moment that chain grows -- the same
  -- reason warmTelemetryBg above counts to a consumed frame rather than to a number.
  script.run()
  local warmed = false
  for _ = 1, 10 do
    Stubs.telemetryFrames = {}
    Stubs.pushFrame(0x88, buildTelemetryFrame(0, sensorIds))
    script.run()
    if #Stubs.telemetryFrames == 0 then
      warmed = true
      break
    end
  end
  if not warmed then
    error("accounting: the function script never consumed a frame; the row would measure a load")
  end
  -- One frame of the cycle published only that frame's sensors; the rest of the cycle once more,
  -- so the backlog below publishes none of them for the first time.
  primeTelemetryCycle(script.run)

  for i = 1, FRAME_BACKLOG do
    Stubs.pushFrame(0x88, buildTelemetryFrame(i, sensorIds))
  end
  local queued = #Stubs.telemetryFrames
  local billed = count(script.run)
  if #Stubs.telemetryFrames >= queued then
    error("accounting: the function script drained nothing; the row would measure an idle pass")
  end
  addRow("pass.function", billed, FRAME_BACKLOG .. " frames queued, every one decoded")
end

World.reset()
do
  local Msp = World.require("tasks/msp/runtime.lua")
  Msp.attach("accounting")
  for _ = 1, 20 do Msp.tick() end
  addRow("unit.msp.pump", count(Msp.pump))
end

do
  local widest, widestFile = nil, nil
  for _, file in ipairs(apiFiles) do
    local mod = assert(loadfile(API_DIR .. "/" .. file))()
    if type(mod) == "table" and type(mod.simulatorResponse) == "table"
      and type(mod.parse) == "function" then
      if widest == nil or #mod.simulatorResponse > #widest.simulatorResponse then
        widest, widestFile = mod, file
      end
    end
  end
  if widest == nil then error("accounting: no API module carries both a payload and a parser") end
  addRow("unit.msp.parse.max", count(widest.parse, widest.simulatorResponse),
    widestFile .. ", " .. #widest.simulatorResponse .. " bytes")
end

------------------------------------------------------------------------------
-- The in-flight tuning overlay: the pass that drives it, the pass a reply lands on, and the
-- builds of its two screens.
--
-- Settle the dashboard with tuning closed, then open its fullscreen visit from the quick
-- menu flag. Every tuning pass carries a non-nil event, as the firmware does in fullscreen.
-- The zone keeps the theme and has no tuning build.
-- The first 30 opening passes below are warm-up, not tuning rows. The loadScript stub uses
-- host loadfile: its C compiler is outside the Lua instruction hook, and it writes no .luac.
-- verify_inflight_surface.lua checks cold first-load isolation independently of these counts.
--
-- The ground half is measured as a window of its own, between the prime starting and the prime
-- being finished, and everything after it is measured with the prime DONE. Both halves of that
-- are deliberate: a pass that parses a reply and a pass that does not are different passes, and
-- a row that sometimes contains one and sometimes does not is a row nobody can reproduce.
------------------------------------------------------------------------------
World.reset()
do
  local Runtime = World.require("widgets/dashboard/runtime.lua")
  local widget = Runtime.new(ZONE, {})
  widget.preferences = widget.preferences or {}
  widget.preferences.dashboard = { theme_preflight = reference }
  -- The preview gate and radio master switch must both be on to measure the overlay.
  --
  -- The preview switch is the pilot saying he wants an unfinished feature on the radio; the
  -- [inflight] section's own `enabled` is the overlay's master switch, and the rest of that
  -- section is the radio's half of the settings -- the two channels and
  -- variables, the pulse length and the trims. See widgets/dashboard/inflight/setup.lua.
  widget.preferences.general = widget.preferences.general or {}
  widget.preferences.general.preview_inflight_tuning = true
  widget.preferences.inflight = {
    enabled = true, bank_ch = 11, value_ch = 12,
    bank_gvar = 1, value_gvar = 2, pulse_ms = 150, trims = true,
    trim_mode = "rows", nav_trim = 2, adj_trim = 4,
    row_trim_1 = 2, row_trim_2 = 4, row_trim_3 = 1,
    row_trim_4 = 3, row_trim_5 = 5, row_trim_6 = 6
  }

  -- The enable channel, as a raw reading: 998 microseconds, the middle of the first band.
  Stubs.sensors["ch11"] = -1028
  Stubs.sensors["ch12"] = 0
  -- A machine that is NOT turning. The sensor set above is a helicopter with its governor in the
  -- active state and the head at 1750 rpm, which is the right world for the dashboard rows and the
  -- wrong one for this scenario: the overlay's ground half refuses to speak MSP while the rotor is
  -- turning, whatever the arm flag says, so a prime priced in that world would be a prime that
  -- never starts. The bench is what a prime and a profile copy actually happen on.
  Stubs.sensors["Gov"] = 0
  Stubs.sensors["Hspd"] = 0
  -- The board reporting its last adjustment, which is the branch a CRSF link actually takes.
  Stubs.sensors["AdjF"] = 14
  Stubs.sensors["AdjV"] = 100
  Stubs.sensors["PID#"] = 1
  -- STATUS and telemetry must describe the same profiles for a session read. Keep the canned
  -- payload's width and parser, changing only its rate index to match this scenario's sensor.
  local savedTuningStatus = FC.replies[101]
  local tuningStatus = {}
  for i = 1, #savedTuningStatus do tuningStatus[i] = savedTuningStatus[i] end
  tuningStatus[24] = Stubs.sensors["PID#"] - 1
  tuningStatus[26] = Stubs.sensors["RTE#"] - 1
  tuningStatus[25], tuningStatus[27] = 6, 6
  FC.replies[101] = tuningStatus
  local mutationCommands = {[250] = true}
  for _, name in ipairs({"pid_tuning", "pid_profile", "governor_profile", "rescue_profile", "rc_tuning", "governor_config", "acc_trim"}) do
    mutationCommands[World.require("tasks/msp/api/" .. name .. ".lua").writeCommand] = true
  end
  -- The board carries the two profile selectors and, after them, the standard set on the overlay's
  -- two channels (11/12): what the live surface can tune is derived from these slots, so a board
  -- without them would price an empty list.
  local selectorIds = {2, 1}
  for index = 3, 42 do selectorIds[index] = 0 end
  local slotReplies = {}
  do
    local Functions = World.require("widgets/dashboard/inflight/functions.lua")
    local FcSetup = World.require("widgets/dashboard/inflight/fcsetup.lua")
    local ena, adj = Functions.wireToAuxField(11, {}), Functions.wireToAuxField(12, {})
    for _, slot in ipairs(Functions.standardSlots(ena, adj, { step = 5, step_headspeed = 50 })) do
      local bytes = FcSetup.encodeSlot(slot.slot0, slot.record)
      table.remove(bytes, 1)
      slotReplies[slot.slot0] = bytes
      selectorIds[slot.slot0 + 1] = slot.record.adjFunction
    end
  end
  FC.dynamicReply = function(command, payload)
    if command == 53 then
      local bytes = {}
      for index = 2, #payload do bytes[index - 1] = payload[index] end
      slotReplies[payload[1]], selectorIds[payload[1] + 1] = bytes, bytes[1]
      return {}
    end
    if command == 167 then return selectorIds end
    if command == 156 then
      return slotReplies[payload[1]] or {payload[1] == 0 and 2 or 1, 255, 0, 0, 1, 236, 246, 10, 20, 1, 0, 6, 0, 0}
    end
    if mutationCommands[command] then return {} end
  end
  FC.profileSelection = function(value)
    if (value & 0x80) ~= 0 then tuningStatus[26] = value & 0x7f
    else tuningStatus[24] = value end
  end

  settle(widget, World.sensorIds, 4000)

  -- The per-model store, as the widget reads it.
  --
  -- Written after the settle, and written where the MSP runtime keeps it rather than only on the
  -- session: that runtime republishes its own copy onto the session on every publish, so a store
  -- put only on the session is overwritten by the next one and the overlay measures as switched
  -- off -- which is what a first run of this driver did, silently, with a zero in the row.
  local store = {
    inflight = {
      -- The set is always derived from the board's own slots (the FC stub above carries the standard
      -- layout), so no layout setting is staged. An earlier comparison of the two former layouts was
      -- taken on a stub carrying only the two profile selectors, where the derivation applied nothing.
      step = 5, step_headspeed = 50
    }
  }
  _G.rfsuite.session.modelPreferences = store
  do
    local Msp = World.require("tasks/msp/runtime.lua")
    local mspState = (type(Msp) == "table" and type(Msp.getState) == "function") and Msp.getState() or nil
    if type(mspState) == "table" and type(mspState.values) == "table" then
      mspState.values.modelPreferences = store
    end
  end

  -- From here on the flight controller answers between passes rather than inside the push, and
  -- the link is held at one pass's worth of telemetry. Both are properties of this check rather
  -- than of the suite, and both are what make the rows below reproducible; see their comments.
  installDeferredLink()

  -- The quick-menu visit is the release after the dashboard has settled.
  widget.inflightFullscreen = true

  -- Swapping the store is a change the widget reacts to -- it compares what a rebuild would
  -- read and reloads the theme when that moved -- so the passes right after the swap carry a
  -- theme load that belongs to this driver rather than to the overlay. They are spent here,
  -- before anything is measured.
  for i = 1, 30 do
    holdLinkBacklog()
    releaseReplies()
    feedLink(World.sensorIds, 900 + i)
    Stubs.tick()
    widget.refresh(widget, 0, nil)
  end

  local drive = widget._inflight
  if drive == nil then error("accounting: the tuning overlay never built a drive") end
  -- Both halves reached the drive. The radio's settings are re-read from the card by the widget's
  -- own preference reload, so a stage that the settle above quietly replaced would leave the rows
  -- pricing an overlay that is switched off -- which is a zero in the row rather than an error.
  if drive.settings.radio_enabled ~= true or drive.settings.active ~= true then
    error("accounting: the tuning overlay settled with radio_enabled="
      .. tostring(drive.settings.radio_enabled)
      .. " active=" .. tostring(drive.settings.active))
  end

  ----------------------------------------------------------------------------
  -- The GROUND HALF, priced as the window it occupies.
  --
  -- The overlay reads the board before a flight: the receiver map, the slot table one record at a
  -- time, and nine value reads. Each of those replies is parsed on a widget pass, and
  -- widgets/dashboard/inflight/prime.lua parses AT MOST ONE PER PASS -- which is the only reason
  -- the cost of a reply can be written down as a row at all. So the window is driven pass by pass
  -- from the run starting to the run reporting itself done, and the check below is the bound's own
  -- positive control: the run's completed-reply counter may never move by more than one in a pass.
  --
  -- Nothing is faked into the run. The widget's own tick starts it, the flight controller stub
  -- answers at the wire, and the number of passes it takes is printed on the row so a run that
  -- took a different number of them is visible rather than silently equivalent.
  ----------------------------------------------------------------------------
  local primeWorst = {}
  local primePasses = 0
  local primePeak = ""
  local Prime = World.require("widgets/dashboard/inflight/prime.lua")
  local Functions = World.require("widgets/dashboard/inflight/functions.lua")
  if type(Prime) ~= "table" or type(Functions) ~= "table" then
    error("accounting: the overlay's ground half did not load")
  end

  for i = 1, 4000 do
    holdLinkBacklog()
    releaseReplies()
    feedLink(World.sensorIds, 5000 + i)
    local prime = drive.prime
    local phase = type(prime) == "table" and prime.phase or nil
    if phase == Prime.PHASE_DONE then break end
    if phase == Prime.PHASE_ERROR then
      error("accounting: the prime failed with " .. tostring(prime.error))
    end
    local doneBefore = (type(prime) == "table" and prime.done) or 0
    local banksBefore = drive.groupWork and drive.groupWork.bank
    local class = passClass(widget)
    local n = count(widget.refresh, widget, 0, nil)
    -- The group table is built a bank per pass; more than one in a pass is the bound gone.
    local banksAfter = drive.groupWork and drive.groupWork.bank
    if banksBefore and banksAfter and banksAfter - banksBefore > 1 then
      error("accounting: one pass built more than one bank of the in-flight groups")
    end
    -- Only the passes the run itself occupies are counted and priced. Before the widget's own
    -- tick starts it there is a settle to wait out, and those passes are the dashboard's.
    if type(prime) == "table" then
      primePasses = primePasses + 1
      if n > (primeWorst[class] or 0) then
        primeWorst[class] = n
        if class == "state" then primePeak = "read pass " .. i .. " " .. tostring(phase) end
      end
    end
    local after = drive.prime
    if type(after) == "table" and type(prime) == "table" and after == prime then
      local step = (after.done or 0) - doneBefore
      if step > 1 then
        error(string.format(
          "accounting: one pass completed %d replies, so the overlay's per-pass bound is gone", step))
      end
    end
  end
  if type(drive.prime) ~= "table" or drive.prime.phase ~= Prime.PHASE_DONE then
    error("accounting: the prime never finished in 4000 passes")
  end
  if primePasses < #Functions.VALUE_READS then
    error(string.format(
      "accounting: the prime finished in %d passes, fewer than its %d value reads -- a pass parsed "
      .. "more than one reply", primePasses, #Functions.VALUE_READS))
  end

  local profileReplies = drive.prime.done or 0

  -- Price the same sliced job during a verified restore of all six PID/rate profiles.
  assert(Prime.restore(widget, drive), "accounting: restore-all control did not start")
  for i = 1, 6000 do
    holdLinkBacklog(); releaseReplies(); feedLink(World.sensorIds, 7000 + i)
    if not drive.profileJob then break end
    local before = drive.prime.done or 0
    local class = passClass(widget)
    local n = count(widget.refresh, widget, 0, nil)
    primePasses = primePasses + 1
    if n > (primeWorst[class] or 0) then
      primeWorst[class] = n
      if class == "state" then
        local job = drive.profileJob
        local op = job and job.plan[job.at]
        primePeak = "restore pass " .. i .. " " .. tostring(op and op.op)
      end
    end
    assert((drive.prime.done or 0) - before <= 1, "accounting: restore parsed multiple replies")
  end
  assert(not drive.profileJob and drive.transfer.state == "ok", "accounting: restore did not verify")
  assert(drive.transfer.results.pid6 == "ok" and drive.transfer.results.rate6 == "ok"
    and drive.transfer.results.global == "ok", "accounting: full-profile restore targets missing")
  drive.restoreResultOpen = nil
  profileReplies = drive.prime.done or profileReplies

  ----------------------------------------------------------------------------
  -- THE LIVE SURFACE, which since the phase machine is the ARMED one.
  --
  -- One fullscreen visit, three phases, and the drive picks between them off the widget's own
  -- arm reading: the ground read-out before a flight, the tuning surface in the air, the delta
  -- after a flight that moved something. All three are the same job kind and their worst pass is
  -- one row, so all three are driven here -- and the state has to be SET rather than assumed,
  -- because a driver that armed nothing would have priced the ground surface three times over
  -- and the row would have looked exactly the same.
  --
  -- The arm flag is moved on the SENSOR and not on the state: the widget's telemetry read puts
  -- the sensor back over anything written there.
  ----------------------------------------------------------------------------
  local worst = {}
  Stubs.sensors["ARM"] = 1
  -- The arming itself is spent before anything is measured, for the same reason the store swap
  -- above is: the widget's own flight mode moves to `inflight` on that edge and it reloads the
  -- theme, which is a dashboard cost that happens once and belongs to no overlay row. Measured,
  -- it lands on the second pass of the loop and is worth about four thousand instructions.
  for i = 1, 30 do
    holdLinkBacklog()
    releaseReplies()
    feedLink(World.sensorIds, 800 + i)
    Stubs.tick()
    widget.refresh(widget, 0, nil)
  end
  for i = 1, 240 do
    holdLinkBacklog()
    releaseReplies()
    feedLink(World.sensorIds, i)
    if i % 3 == 0 then invalidate(widget) end
    local class = passClass(widget)
    local n = count(widget.refresh, widget, 0, nil)
    if n > (worst[class] or 0) then worst[class] = n end
  end
  if drive.phase ~= "live" then
    error("accounting: the live surface was priced in phase " .. tostring(drive.phase))
  end

  -- The same surface in fullscreen. `event` is an integer there and nil everywhere else, so this
  -- is also the only place any row in this file exercises the interactive path.
  for i = 1, 60 do
    holdLinkBacklog()
    releaseReplies()
    feedLink(World.sensorIds, 1000 + i)
    invalidate(widget)
    local class = passClass(widget)
    local n = count(widget.refresh, widget, 0, nil)
    if n > (worst[class] or 0) then worst[class] = n end
  end

  -- Retained live scenes must survive a dispatcher navigation and a telemetry publication.
  -- Exercise the actual Runtime key/build path, then include the 64-row value ladder's build
  -- and reactive sweep in the same tuning budgets as the other overlay surfaces.
  local Input = World.require("widgets/dashboard/inflight/input.lua")
  local tuningBuilds, savedBuild = 0, lvgl.build
  lvgl.build = function(nodes)
    tuningBuilds = tuningBuilds + 1
    return savedBuild(nodes)
  end
  local function livePass()
    holdLinkBacklog()
    releaseReplies()
    feedLink(World.sensorIds, 1200)
    local class = passClass(widget)
    local n = count(widget.refresh, widget, 0, nil)
    if n > (worst[class] or 0) then worst[class] = n end
  end
  for i = 1, 4 do livePass() end
  local retainedTrees = tuningBuilds
  local entryBefore = drive.entry
  assert(Input.dispatch(widget, "function", 1, "encoder"), "accounting: browse control did not navigate")
  for i = 1, 8 do livePass() end
  assert(drive.entry == entryBefore + 1, "accounting: browse selection was lost")
  assert(tuningBuilds == retainedTrees, "accounting: a function detent rebuilt the live sensor")
  assert(Input.dispatch(widget, "select", nil, "encoder"), "accounting: value mode control did not select")
  for i = 1, 8 do livePass() end
  assert(drive.valueMode, "accounting: value ladder was not reached")
  assert(tuningBuilds == retainedTrees + 1, "accounting: mode change built "
    .. tostring(tuningBuilds - retainedTrees) .. " trees, expected exactly one; phase="
    .. tostring(drive.phase) .. " key=" .. tostring(widget.renderKey))
  local ladderButtons = 0
  local valueTree = Stubs.lvgl.trees[#Stubs.lvgl.trees]
  for _, node in ipairs(valueTree or {}) do
    if node.type == "box" and node.scrolled then
      for _, child in ipairs(node.children or {}) do
        if child.type == "button" then ladderButtons = ladderButtons + 1 end
      end
    end
  end
  assert(ladderButtons == Input.LADDER_ROWS + 5, "accounting: split value ladder, both resting touch copies and all three guards were not built")
  retainedTrees = tuningBuilds
  local pageEntry = drive.entry
  local savedNext, savedPrevious = _G.EVT_VIRTUAL_NEXT_PAGE, _G.EVT_VIRTUAL_PREV_PAGE
  _G.EVT_VIRTUAL_NEXT_PAGE, _G.EVT_VIRTUAL_PREV_PAGE = 516, 515
  assert(Input.key(widget, EVT_VIRTUAL_NEXT_PAGE), "accounting: PAGE was not consumed")
  for i = 1, 8 do livePass() end
  assert(drive.valueMode and drive.entry == pageEntry + 1, "accounting: PAGE did not select the next value function")
  assert(tuningBuilds == retainedTrees, "accounting: value PAGE rebuilt the sensor")
  assert(Input.key(widget, EVT_VIRTUAL_PREV_PAGE), "accounting: previous PAGE was not consumed")
  for i = 1, 8 do livePass() end
  assert(drive.valueMode and drive.entry == pageEntry and tuningBuilds == retainedTrees,
    "accounting: previous PAGE lost value selection or rebuilt")
  _G.EVT_VIRTUAL_NEXT_PAGE, _G.EVT_VIRTUAL_PREV_PAGE = savedNext, savedPrevious
  local reportedId = drive:functionId(drive.bank, drive.row)
  Stubs.sensors["AdjF"] = 0
  for i = 1, 8 do livePass() end
  assert(not drive.reportFence, "accounting: idle report did not release the transaction fence")
  Stubs.sensors["AdjF"], Stubs.sensors["AdjV"] = reportedId, 123
  for i = 1, 8 do livePass() end
  assert(drive.values[reportedId] == 123, "accounting: value report control did not publish")
  assert(tuningBuilds == retainedTrees, "accounting: a value report rebuilt the sensor")
  assert(Input.dispatch(widget, "leave", nil, "encoder"), "accounting: value mode control did not leave")
  for i = 1, 8 do livePass() end
  lvgl.build = savedBuild

  ----------------------------------------------------------------------------
  -- THE OTHER TWO SURFACES, on the same budget row.
  --
  -- Both are reached by DISARMING with the tuning surface still open, which is the pilot's whole flow:
  -- the delta after a flight that fired a step, the ground read-out after one that did not. They
  -- are two different trees and they are one job kind, so their worst pass goes into the same
  -- `pass.job.tuning` as the live surface's -- named here rather than given a row of its own,
  -- because a budget per tree would be three budgets for one dispatcher slot.
  ----------------------------------------------------------------------------

  -- Twelve parameters away from the snapshot the backup was taken with, which is more than a
  -- 272-pixel zone holds and therefore more than one page. Written straight onto the drive rather
  -- than stepped in over MSP: what is being priced is the BUILD of that list, and how the numbers
  -- got there does not change its shape.
  local changed = {
    14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29,
    39, 40, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 63, 66, 75, 80
  }
  local baseline = {}
  for _, id in ipairs(changed) do
    baseline[tostring(id)] = 50
    drive.profileValues.pid[drive.profile][id] = 62
    drive.changes.pid[drive.profile][id] = true
    drive.values[id] = 62
  end
  drive.baseline["pid" .. drive.profile] = baseline
  drive.primedValues = baseline
  drive.setSource = "board"
  -- A flight that asked for a step, which is what earns the delta screen at all.
  drive.fired = 1

  Stubs.sensors["ARM"] = 0
  -- and the DISARM is spent the same way the arming was: the widget's flight mode moves to
  -- postflight on that edge and reloads the theme behind the overlay. Priced into a tuning row it
  -- put four to six thousand instructions of somebody else's work on this feature's budget.
  for i = 1, 30 do
    holdLinkBacklog()
    releaseReplies()
    feedLink(World.sensorIds, 2800 + i)
    Stubs.tick()
    widget.refresh(widget, 0, nil)
  end
  for i = 1, 60 do
    holdLinkBacklog()
    releaseReplies()
    feedLink(World.sensorIds, 3000 + i)
    drive.valueEpoch = drive.valueEpoch + 1
    widget.inflightFullscreen = true
    invalidate(widget)
    local class = passClass(widget)
    local n = count(widget.refresh, widget, 0, nil)
    if n > (worst[class] or 0) then worst[class] = n end
  end

  -- What was actually built, read back off the recorder. A surface that had quietly fallen back
  -- to the dashboard scene -- or to the wrong phase -- would have measured a plausible number for
  -- the wrong tree, and the row would have looked exactly the same.
  if drive.phase ~= "post" then
    error("accounting: the postflight surface was priced in phase " .. tostring(drive.phase))
  end
  do
    local tree = Stubs.lvgl.trees[#Stubs.lvgl.trees]
    local buttons, deltaRows, paged = 0, 0, false
    for _, node in ipairs(tree or {}) do
      if node.type == "button" then buttons = buttons + 1 end
      if type(node.text) == "string" then
        if string.find(node.text, " -> ", 1, true) then deltaRows = deltaRows + 1 end
        if string.find(node.text, "/", 1, true) and #node.text <= 5 then paged = true end
      end
    end
    -- Close, continue tuning, the restore menu and both touch paging controls; a list that runs
    -- beyond one screen; and the page counter that says so.
    if buttons ~= 5 then error("accounting: the postflight surface built " .. buttons .. " buttons, not 5") end
    if deltaRows < 4 then error("accounting: the delta list built only " .. deltaRows .. " rows") end
    if not paged then error("accounting: the delta list was not measured over more than one page") end
    -- The restore menu's button, found by its caption: Continue tuning comes first.
    local entry, last
    for _, node in ipairs(tree) do
      if node.type == "button" then last = node end
      if node.text == "Restore..." then entry = last end
    end
    if not entry then error("accounting: the postflight surface has no restore menu") end
    entry.press()
    if not drive.postActionsOpen then error("accounting: postflight restore entry did not open its actions") end
    for i = 1, 30 do
      holdLinkBacklog()
      releaseReplies()
      feedLink(World.sensorIds, 3100 + i)
      invalidate(widget)
      local class = passClass(widget)
      local n = count(widget.refresh, widget, 0, nil)
      if n > (worst[class] or 0) then worst[class] = n end
    end
    local actions, labels = {}, {}
    for _, node in ipairs(Stubs.lvgl.trees[#Stubs.lvgl.trees] or {}) do
      if node.type == "button" then actions[#actions + 1] = node end
      if type(node.text) == "string" then labels[node.text] = true end
    end
    if #actions ~= 5 or not labels["Restore all"] or not labels["Read again"]
      or not labels["Restore profile PID " .. drive.profile] or not labels["Back to changes"] then
      error("accounting: postflight menu did not retain all/read/profile/back and Close")
    end
    actions[4].press()
    if drive.postActionsOpen then error("accounting: postflight Back did not dismiss its actions") end
  end

  -- and the GROUND read-out, which is what the same disarmed state shows after a flight that
  -- moved nothing. Four status lines and three actions, so it is the cheaper of the two -- priced
  -- anyway, because "cheaper" is a reading and not an assumption.
  drive.post = false
  drive.fired = 0
  for i = 1, 60 do
    holdLinkBacklog()
    releaseReplies()
    feedLink(World.sensorIds, 4000 + i)
    drive.prime = { phase = "slots", done = 20, total = 53, skipped = {} }
    drive.valueEpoch = drive.valueEpoch + 1
    widget.inflightFullscreen = true
    invalidate(widget)
    local class = passClass(widget)
    local n = count(widget.refresh, widget, 0, nil)
    if n > (worst[class] or 0) then worst[class] = n end
  end
  if drive.phase ~= "ground" then
    error("accounting: the ground surface was priced in phase " .. tostring(drive.phase))
  end
  do
    local tree = Stubs.lvgl.trees[#Stubs.lvgl.trees]
    local buttons, reactive = 0, 0
    for _, node in ipairs(tree or {}) do
      if node.type == "button" then buttons = buttons + 1 end
      if type(node.text) == "function" then reactive = reactive + 1 end
    end
    -- The close box plus choose parameters, set up suggested functions, read again, turn on
    -- announcements (adjustment announcements are off by default, so the priced surface carries the
    -- button) and restore all, the secondaries shown disabled while the run is on; and the three
    -- lines that move while it runs without anything rebuilding.
    if buttons ~= 6 then error("accounting: the ground surface built " .. buttons .. " buttons, not 6") end
    if reactive < 3 then error("accounting: the ground surface built " .. reactive .. " reactive lines") end
  end

  -- and the PARAMETER PICKER the ground surface opens: a page of six toggles over the board's
  -- groups, rebuilt on every toggle and page turn, so its build is priced on the same row.
  drive.prime = nil
  drive.sessionPickerOpen, drive.sessionPick = true, nil
  for i = 1, 60 do
    holdLinkBacklog()
    releaseReplies()
    feedLink(World.sensorIds, 4100 + i)
    drive.valueEpoch = drive.valueEpoch + 1
    widget.inflightFullscreen = true
    invalidate(widget)
    local class = passClass(widget)
    local n = count(widget.refresh, widget, 0, nil)
    if n > (worst[class] or 0) then worst[class] = n end
  end
  do
    local tree = Stubs.lvgl.trees[#Stubs.lvgl.trees]
    local toggles = 0
    for _, node in ipairs(tree or {}) do
      if node.type == "button" and type(node.text) == "string" and string.find(node.text, "^%[") then toggles = toggles + 1 end
    end
    if toggles == 0 then error("accounting: the parameter picker built no toggles") end
    -- Priced over a finished board: no group work pending and the board's groups in place.
    if drive.groupWork ~= nil or type(drive.allGroups) ~= "table" or #drive.allGroups == 0 then
      error("accounting: the parameter picker was priced before the board's groups were built")
    end
  end
  drive.sessionPickerOpen, drive.sessionPick = nil, nil

  -- Suggested-functions setup is driven through the same widget dispatcher and deferred wire.
  -- Every plan page is built, then the confirmed write and full read-back run to the idle save.
  -- Use the narrow display so the essential plan still exercises its whole-entry page break.
  widget.zone = {x = 0, y = 0, w = 480, h = 272}
  drive.prime = {phase = "done"}
  for index = 3, 38 do selectorIds[index] = 83 end
  drive.fcSetupOpen = true
  drive.valueEpoch = drive.valueEpoch + 1
  local setupWorst, setupBuild, setupPasses, planPages = 0, 0, 0, 0
  local setupPeak = ""
  local sawWrite, sawVerify, sawSave = false, false, false
  for i = 1, 1800 do
    holdLinkBacklog()
    releaseReplies()
    feedLink(World.sensorIds, 4200 + i)
    local state = drive.fcSetup
    if state then
      if state.phase == "choices" then state.request = "read"
      elseif state.phase == "plan" and state.pages then
        if state.page < #state.pages then
          state.page = state.page + 1
          drive.valueEpoch = drive.valueEpoch + 1
          planPages = planPages + 1
        else state.request = "write" end
      elseif state.phase == "error" then error("accounting: setup failed: " .. tostring(state.error)) end
      local run = state.run
      if run then
        sawWrite = sawWrite or run.phase == "writing"
        sawVerify = sawVerify or run.phase == "verify"
      end
      sawSave = sawSave or state.phase == "saving"
    end
    local class = passClass(widget)
    local n = count(widget.refresh, widget, 0, nil)
    setupPasses = i
    if class == "tuning" then setupBuild = math.max(setupBuild, n)
    elseif n > setupWorst then
      setupWorst = n
      setupPeak = "pass " .. i .. " " .. tostring(state and state.phase)
        .. "/" .. tostring(state and state.run and state.run.phase)
    end
    if not drive.fcSetupOpen then break end
  end
  assert(not drive.fcSetupOpen and sawWrite and sawVerify and sawSave and planPages > 0,
    "accounting: setup incomplete: phase=" .. tostring(drive.fcSetup and drive.fcSetup.phase)
      .. " write=" .. tostring(sawWrite) .. " verify=" .. tostring(sawVerify)
      .. " save=" .. tostring(sawSave) .. " pages=" .. planPages .. " passes=" .. setupPasses)
  assert(_G.rfsuite.modules["/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/inflight/fcsetup.lua"] == nil,
    "accounting: closed setup retained its writer")
  widget.zone = ZONE
  addRow("pass.job.tuning_setup", setupBuild, "all suggested-functions surfaces through widget build dispatcher")
  addRow("pass.tuning.setup", setupWorst, setupPasses .. " passes, peak " .. setupPeak)

  removeDeferredLink()

  addRow("pass.tuning.state", worst.state or 0)
  addRow("pass.tuning.prime", primeWorst.state or 0,
    string.format("%d replies over %d passes, six PID/rate profiles + verified restore, one parse per pass",
      profileReplies, primePasses) .. "; peak " .. primePeak)
  addRow("pass.job.tuning", math.max(worst.tuning or 0, primeWorst.tuning or 0),
    "64-row value ladder + guards included; navigation/report builds 0/0, mode builds 1")
  FC.dynamicReply = nil
  FC.profileSelection = nil
  FC.replies[101] = savedTuningStatus
end

------------------------------------------------------------------------------
-- The service widget's background pass: the pure background half, no build.
--
-- The window has to be longer than the slowest cadence in the code it measures, or the row
-- cannot contain the pass that cadence lands in. widgets/service/runtime.lua looks at the
-- settings store every PREFERENCES_INTERVAL_SECONDS, which is 30 s; at the stub clock's 0.1 s
-- per pass, 600 passes are 60 s and hold that look twice. At 200 passes the window ended at
-- 20 s, before the first one.
--
-- The block counts the looks it drove and refuses a window that held fewer than two: moving
-- the stub clock's step, the warm-up or the interval would otherwise shorten the window again
-- and leave the row measuring a cheaper pass with --check still green.
--
-- Every pass starts from one pass's worth of frames, as the other blocks that run the drain
-- do: over 600 passes feedLink alone piles up thousands, and the drain would be priced on
-- running down a backlog a radio's queue never holds.
------------------------------------------------------------------------------
World.reset()
do
  local SERVICE_PASSES = 600
  local Service = World.require("widgets/service/runtime.lua")
  local widget = Service.new({ x = 0, y = 0, w = 200, h = 100 }, {})
  local worst, worstAt = 0, 0
  local lastLoad, looks = widget._lastPreferencesLoad, 0
  for i = 1, SERVICE_PASSES do
    holdLinkBacklog()
    feedLink(World.sensorIds, i)
    local n = count(widget.background, widget)
    if widget._lastPreferencesLoad ~= lastLoad then
      lastLoad = widget._lastPreferencesLoad
      looks = looks + 1
    end
    if i > 60 and n > worst then worst, worstAt = n, i end
  end
  if looks < 2 then
    error(string.format("accounting: the service window held %d settings look(s), expected 2 -- "
      .. "pass.service would be measuring a cheaper pass than the one it bounds", looks))
  end
  addRow("pass.service", worst, string.format("worst at pass %d of %d", worstAt, SERVICE_PASSES))
end

------------------------------------------------------------------------------
-- The tool's pages, hosted: the build of every page the dashboard can open. See openToolPage.
--
-- One phase, the press on the first pass after the parent menu has settled: the build does not
-- move with the phase (--pages shows it per page), and the rest of the pass, which does, is not
-- what these rows price. A page that cannot be opened in this world is named in a note and gets
-- no row; one that should open and does not fails the run. A command a page asked for and the
-- flight controller stub had no payload for is named in a note per page: the header's
-- "answered empty" line reads the world that ran last, and it keeps reading the one it read before
-- these worlds were added after it.
------------------------------------------------------------------------------
local pageReads = {}
do
  local unanswered = FC.unanswered
  for _, menuId in ipairs(toolPages) do
    local page = openToolPage(reference, menuId, toolPagePaths[menuId], 0, false)
    if page.skipped then
      note("page %s has no row: %s", menuId, page.skipped)
    else
      addRow("page." .. menuId .. ".build", page.build, page.builds .. (page.builds == 1 and " build" or " builds"))
      if page.served > 0 then pageReads[#pageReads + 1] = menuId end
      if #page.empty > 0 then
        note("page %s: answered empty %s", menuId, table.concat(page.empty, " "))
      end
    end
  end
  FC.unanswered = unanswered
end

------------------------------------------------------------------------------
-- Check and report.
------------------------------------------------------------------------------
-- The card is emptied and then handed back here rather than at the end of the file: nothing
-- below reads it, and from here on every exit runs through here, os.exit in the self-test
-- included. Emptied rather than removed, because the self-test below writes to the card after
-- this point; the release that gives the name back happens on the way out of every exit below.
Stubs.clearCard()

-- The card is handed back on every exit from here on, which is why the release is installed
-- here rather than written before each os.exit: there are five exits in the tail, and the next
-- one added would otherwise leave a card behind in the temp folder. Nothing the measured tree
-- loads calls os.exit, so the wrapper is invisible to the measurement -- if that ever changes,
-- this is the line to look at.
do
  local realExit = os.exit
  os.exit = function(code)
    Stubs.releaseCard()
    realExit(code)
  end
end


local unanswered = {}
for cmd, n in pairs(FC.unanswered) do
  unanswered[#unanswered + 1] = string.format("%d(x%d)", cmd, n)
end
table.sort(unanswered)

local collisions = {}
for cmd, files in pairs(FC.collisions) do
  collisions[#collisions + 1] = string.format("%d(%s)", cmd, table.concat(files, ","))
end
table.sort(collisions)

print("offline instruction accounting")
print(string.format("  interpreter        %s, count hook at 1 instruction", _VERSION))
print(string.format("  sweep control      %.3f instructions per reference (budgets.lua %.3f)",
  control, Budgets.sweepControl))
print(string.format("  api replies        %d of %d modules indexed", indexed, #apiFiles))
print(string.format("  themes             %d: %s", #themes, table.concat(themes, " ")))
print(string.format("  box types          %d", #boxTypes))
if #unanswered > 0 then
  print("  answered empty     " .. table.concat(unanswered, " "))
end
if #collisions > 0 then
  print("  command claimed by more than one module, first wins: " .. table.concat(collisions, " "))
end
for _, n in ipairs(notes) do print("  note               " .. n) end
print("")

local failures = {}
local warnings = {}

if math.abs(control - Budgets.sweepControl) > Budgets.sweepControlTolerance then
  failures[#failures + 1] = string.format(
    "sweep control %.3f is outside %.3f +/- %.3f: this run is measuring itself differently",
    control, Budgets.sweepControl, Budgets.sweepControlTolerance)
end

-- The self-test drives BOTH ways the check can go red -- a row over its target and a row
-- with no budget at all -- because a gate never seen red is a loop that never ran with a
-- badge on it. It fails unless both mechanisms fire.
local poisoned = selfTest and rows[1] and rows[1].name or nil
local hidden = selfTest and rows[2] and rows[2].name or nil
if hidden then Budgets.rows[hidden] = nil end

-- The same two for the tool's pages. Their rows are added last, so the two above never reach one,
-- and a page row that cannot go red is a row nobody has seen gate anything.
local pageRows = {}
for _, row in ipairs(rows) do
  if string.find(row.name, "^page%.") then pageRows[#pageRows + 1] = row.name end
end
local poisonedPage = selfTest and pageRows[1] or nil
local hiddenPage = selfTest and pageRows[2] or nil
if hiddenPage then Budgets.rows[hiddenPage] = nil end

print(string.format("  %-32s %9s %9s %7s", "row", "measured", "target", "margin"))
for _, row in ipairs(rows) do
  local budget = Budgets.rows[row.name]
  local target = budget and budget.target
  if poisoned == row.name or poisonedPage == row.name then target = 1 end
  local marginText = "-"
  if target and target > 0 then
    marginText = string.format("%.0f%%", 100 * (target - row.measured) / target)
  end
  -- A target that was moved off the figure first written down says so on every run.
  -- Otherwise a re-apportioned budget reads exactly like the original one.
  local extra = row.extra
  if budget and budget.proposed and budget.proposed ~= target then
    local moved = string.format("re-apportioned from %d", budget.proposed)
    extra = extra and (moved .. ", " .. extra) or moved
  end
  print(string.format("  %-32s %9d %9s %7s%s",
    row.name, row.measured, target and tostring(target) or "MISSING", marginText,
    extra and ("   " .. extra) or ""))
  if target == nil then
    -- A tool page reaches this line the first time a menu leads to it in the run's world, which is
    -- the pull request that adds it or the one that enables its tile here. The row it needs is a
    -- measurement, and the run already has it.
    local hint = string.find(row.name, "^page%.") and " -- a new tool page: --emit prints its row" or ""
    failures[#failures + 1] = row.name .. " has no row in budgets.lua" .. hint
  elseif row.measured > target then
    failures[#failures + 1] = string.format("%s: %d instructions over a target of %d",
      row.name, row.measured, target)
  elseif row.measured > target * 0.9 then
    -- A flag to widen the row, not a build failure: the row is still inside its ceiling,
    -- and turning a thin margin into a red build would make the honest answer -- write
    -- down what it costs -- the expensive one.
    warnings[#warnings + 1] = string.format(
      "%s: %d is within 10%% of its target of %d, so this is a margin to widen, not a pass to celebrate",
      row.name, row.measured, target)
  end
end

-- The other half of the coverage rule: a row nothing measures is a target nothing
-- enforces, and a removed box type or theme leaves exactly that behind.
local orphans = {}
for name in pairs(Budgets.rows) do
  if not rowIndex[name] then orphans[#orphans + 1] = name end
end
table.sort(orphans)
for _, name in ipairs(orphans) do
  failures[#failures + 1] = name .. " has a budget row but nothing measured it"
end

-- A PR that adds a box type or a theme needs its cost row, and the number in it has to be
-- a measurement rather than a guess. This prints the table body ready to paste; the
-- targets it suggests carry the same margin the rows above are read with.
if args["--emit"] then
  print("")
  print("-- budgets.lua rows, emitted from this run")
  print(string.format("sweepControl = %.3f,", control))
  print("rows = {")
  for _, row in ipairs(rows) do
    local budget = Budgets.rows[row.name]
    local target = (budget and budget.target) or (math.ceil(row.measured / 0.8 / 50) * 50)
    print(string.format("  [%q] = { target = %d, measured = %d },", row.name, target, row.measured))
  end
  print("}")
end

print("")
for _, w in ipairs(warnings) do print("WARN: " .. w) end
if selfTest then
  -- The card first: a card that is written to the wrong directory, whose deepest directory
  -- was never made, or that is not emptied leaves every row below exactly as it was, so
  -- the report cannot see any of it. Proved on the gate, then on the card.
  local cardFailures = Stubs.selfTest()
  for _, f in ipairs(cardFailures) do print("(self-test) card: " .. f) end
  if #cardFailures > 0 then
    print("SELF-TEST FAILED: the card this run is given does not behave")
    os.exit(1)
  end
  local function saw(name, kind)
    if name == nil then return false end
    for _, f in ipairs(failures) do
      if string.find(f, name, 1, true) and string.find(f, kind, 1, true) then return true end
    end
    return false
  end
  for _, f in ipairs(failures) do print("(self-test) " .. f) end
  if not saw(poisoned, "over a target") then
    print("SELF-TEST FAILED: a target poisoned to 1 did not turn the check red")
    os.exit(1)
  end
  if not saw(hidden, "no row in budgets.lua") then
    print("SELF-TEST FAILED: a row with its budget removed did not turn the check red")
    os.exit(1)
  end
  if not saw(poisonedPage, "over a target") then
    print("SELF-TEST FAILED: a tool page's target poisoned to 1 did not turn the check red")
    os.exit(1)
  end
  if not saw(hiddenPage, "no row in budgets.lua") then
    print("SELF-TEST FAILED: a tool page with its budget removed did not turn the check red")
    os.exit(1)
  end

  -- The page driver's own controls, each driven red once on a page that reads from the flight
  -- controller. Every one of these runs would otherwise end in a plausible number: a page whose
  -- replies are held off the link builds the screen it shows while it waits; a world whose connect
  -- chain was never answered prices every page on the screen of a radio with no flight controller;
  -- and a press that never lands prices the menu the tool stayed on. The runs are pcall'ed here
  -- and nowhere else, and the run is restored after each so the next starts on a clean link.
  local readingPage = pageReads[1]
  if readingPage == nil then
    print("SELF-TEST FAILED: no tool page read from the flight controller, so the link controls cannot be driven")
    os.exit(1)
  end
  local plainPush = Stubs.pushFrame
  for _, case in ipairs({
    { fault = "held", expect = "held off the link" },
    { fault = "unanswered", expect = "without a connected flight controller" },
    { fault = "stay", expect = "did not open" },
  }) do
    local ok, err = pcall(openToolPage, reference, readingPage, toolPagePaths[readingPage], 0, false, case.fault)
    removeDeferredLink()
    Stubs.pushFrame = plainPush
    print(string.format("(self-test) page %s, %s: %s", readingPage, case.fault, ok and "priced" or tostring(err)))
    if ok or not string.find(tostring(err), case.expect, 1, true) then
      print("SELF-TEST FAILED: the page driver's '" .. case.fault .. "' control did not stop the run")
      os.exit(1)
    end
  end
  print("SELF-TEST PASSED: the card behaves, a breached target and a missing budget row turn the check red "
    .. "for a pass row and for a tool page, and the page driver refuses a held link, an unanswered connect "
    .. "and a press that never landed")
  os.exit(0)
end

if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL: " .. f) end
  print(string.format("%d row(s) over budget or unaccounted", #failures))
  if checking then os.exit(1) end
else
  print(string.format("%d rows, 0 failures", #rows))
end

-- The green path ends the file rather than exiting, so the wrapper above never sees it. A
-- --check that passes is the common case, and leaving a card behind on every one of them is
-- how a temp directory fills up.
Stubs.releaseCard()
