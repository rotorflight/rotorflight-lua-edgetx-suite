-- One save mechanism: writes -> EEPROM commit -> optional reboot -> reconnect -> reload.
--
-- Architectural Reboot Policy (Rotorflight 2 Lifecycle):
-- In Rotorflight 2, whether a reboot is required after saving comes down to whether hardware
-- drivers, DMA streams, timer allocations or core structures require full re-initialization
-- during board boot, vs runtime tuning parameters that are live-updated in memory:
--
-- 1. Reboot Required (Hardware drivers, DMA streams, timer allocations & core architecture):
--    - setup/ports: UART re-initialization, baud rates, DMA channels.
--    - setup/radio_config: Serial/SPI RX protocol drivers and hardware binding.
--    - setup/esc_motors (throttle, rpm, telemetry): DShot/PWM hardware timers, bidirectional
--      DShot DMA, and telemetry pin configurations.
--    - setup/alignment: Gyro/accelerometer sensor orientation matrices and low-level driver re-init.
--    - setup/configuration: Loop rates, system feature flags, and core task scheduler sizing.
--
-- 2. Conditional Reboot (Mixer structural changes vs geometry tuning):
--    - setup/mixer/swash: Reboots only if swashplate geometry type changed (swashTypeChanged).
--      Rate/direction changes are live runtime math and do not trigger a reboot.
--    - setup/mixer/tail: Reboots only if tail rotor mode changed (tailModeChanged, e.g. servo vs
--      motorized). Trims, yaw rates and limit adjustments do not trigger a reboot.
--
-- 3. No Reboot (Runtime tuning, mathematical filters & control loops):
--    - flight_tuning/advanced/filters: In RF2, gyro/D-term filter coefficients and state structures
--      are dynamically re-calculated in RAM upon MSP write without needing a reboot.
--    - flight_tuning/governor: Gains, feedforward, and target headspeed tables are active runtime tuning.
--    - flight_tuning (pids, rates, autolevel, rescue, etc.): Live in-memory updates.
--    - setup/servos (pwm, bus) & controls: Live trim/center/range updates (except servo PWM rate,
--      which takes effect at the next boot).
--    - setup/model: Profile / model metadata changes only.
--
-- Note on MSP_STATUS.reboot_required: Although MSP_STATUS carries a reboot_required flag,
-- the firmware's MSP set-handlers do not currently set it (only CMS does). Therefore, the
-- suite explicitly defines and orchestrates this reboot policy on the client side.
--
-- Every page that ends a save in MSP_EEPROM_WRITE builds its own chain of nested queue:add
-- calls, each next step queued from the previous step's processReply. The pages that
-- append MSP_REBOOT queue it with an empty processReply, so the reboot is fire-and-forget:
-- nobody waits for the flight controller to come back, the page keeps displaying values the
-- board re-derived in validateAndFixConfig() while it was booting, and the save is reported
-- finished before its longest phase has started.
--
-- A page hands this module a descriptor instead and stops owning the process:
--
--   SavePipeline.start({
--     pageId = "setup_configuration",
--     steps  = {
--       { label = "...", command = NameApi.writeCommand, payload = ... },
--       ...
--     },
--     reboot = true,                              -- or false, or function() -> boolean
--     invalidateSessionKeys = { "setup_configuration" },
--     onDone = function(result) ... end,
--   })
--
-- A step may carry `buildPayload = function() return { ... } end` instead of `payload`. It is
-- called when that step is queued -- the first step's inside start(), every later one in the
-- reply handler of the step before -- so a save of many writes builds one payload per call
-- instead of all of them in the call that handles Save, where EdgeTX's instruction limit for a
-- widget call can stop it. The step is queued by then, not when Save was pressed: the page may
-- have been left or opened again since, so the builder works from a copy the page took at Save,
-- never from the page's live state. `payload` wins when a step carries both. A builder that
-- raises or returns no table ends the save as a refused write does: at the first step start()
-- refuses with "payload" and nothing is queued; at a later step the save fails at that step's
-- label. EdgeTX's instruction-limit stop is raised on instead, before anything is changed, so
-- the queue keeps the previous write's reply handler current and runs it again on a later pass.
--
-- Progress is exposed through getProgress() and drawn by whoever is on screen, which is the
-- same split the start screen uses for the connect chain. Nothing here opens a native modal,
-- so the tool's run() and the MSP tick keep going for the whole pipeline.

local M = {}

local function loadModule(path)
  local fullPath = _G.rfsuite.paths.core .. "/" .. path
  local chunk = loadScript(fullPath, "t")
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

-- Give-up bounds, not wait durations. PROBE is left the moment the flight controller answers,
-- so RECONNECT_TIMEOUT_SECONDS is only ever spent in full on a board that does not come back --
-- including one that was simply unplugged. ONCONNECT_TIMEOUT_SECONDS exists because the connect
-- runner's own per-task timeout cannot be relied on to bound that chain.
local RECONNECT_TIMEOUT_SECONDS = 20
local ONCONNECT_TIMEOUT_SECONDS = 15
local PROBE_INTERVAL_SECONDS = 0.5

-- Backstop for the phases that wait on a queued message coming back at all. The queue's own
-- retries and give-up normally end such a step long before this; it exists so that a message
-- dropped without either a reply or an errorHandler cannot leave a blocking overlay standing
-- for the rest of the session.
local STEP_TIMEOUT_SECONDS = 30

-- How long a SUCCESSFUL outcome stays on the notice before the notice clears itself. A save
-- that worked needs no acknowledgement -- the box says so and goes, and the button it already
-- draws stays as the earlier way out. A save that FAILED or timed out is never cleared here:
-- it stands until it is read, because an outcome that vanishes on its own leaves a failed
-- save looking exactly like a successful one.
local OUTCOME_LINGER_SECONDS = 2

local PHASE = {
  WRITE     = "write",
  COMMIT    = "commit",
  PREFLIGHT = "preflight",
  REBOOT    = "reboot",
  PROBE     = "probe",
  ONCONNECT = "onconnect",
  VERIFY    = "verify",
  RELOAD    = "reload",
}

M.PHASE = PHASE

local MspRuntime = nil
local Events = nil
local EepromApi = nil
local RebootApi = nil
local TxInfoApi = nil
local Log = nil

local function ensureDeps()
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not Events then Events = loadModule("tasks/events/runtime.lua") end
  if not EepromApi then EepromApi = loadModule("tasks/msp/api/eeprom_write.lua") end
  if not RebootApi then RebootApi = loadModule("tasks/msp/api/reboot.lua") end
  if not TxInfoApi then TxInfoApi = loadModule("tasks/msp/api/tx_info.lua") end
  if Log == nil then Log = loadModule("lib/log.lua") or false end
  return MspRuntime ~= nil
end

local function logLine(msg, level)
  if type(Log) == "table" and type(Log.emit) == "function" then
    pcall(Log.emit, "rfsuite.save", tostring(msg), level or "debug")
  end
end

-- Formats on the far side of the level gate; see lib/log.lua. Used for the lines below that
-- carry several values, so that a card at the shipped setting builds none of them.
local function logf(level, fmt, ...)
  if type(Log) == "table" and type(Log.emitf) == "function" then
    pcall(Log.emitf, "rfsuite.save", level, fmt, ...)
  end
end

-- EdgeTX's instruction-limit stop. lib/log_sink.lua publishes the check; it is not loaded in every
-- Lua state this module runs in, so the same test stands in for it when it is absent.
local function isCpuLimitError(err)
  local fn = _G.rfsuite and _G.rfsuite.isCpuLimitError
  if type(fn) == "function" then return fn(err) == true end
  return type(err) == "string" and string.find(err, "CPU limit", 1, true) ~= nil
end

--- A step's payload: its `payload`, or what its `buildPayload` returns. Returns nil and the reason
-- when the builder raised or returned no table; an instruction-limit stop is raised on.
local function stepPayload(step)
  if step.payload ~= nil or type(step.buildPayload) ~= "function" then
    return step.payload or {}
  end
  local ok, built = pcall(step.buildPayload)
  if not ok then
    if isCpuLimitError(built) then error(built, 0) end
    return nil, tostring(built)
  end
  if type(built) ~= "table" then
    return nil, "no table"
  end
  return built
end

local function getQueue()
  if not MspRuntime or type(MspRuntime.getState) ~= "function" then return nil end
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then return nil, mspState end
  return queue, mspState
end

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

-- The one active pipeline, and its state is SHARED rather than held in this file.
--
-- The tool's own loader memoizes through _G.rfsuite.require, but a page's local loadModule
-- calls loadScript directly and gets a fresh module table every time. State kept in upvalues
-- here would therefore exist once per caller: a page would start a save that the host, holding
-- a different instance, could neither draw nor hold the page for. Sharing it through _G is how
-- the rest of the suite shares state (_G.rfsuite.tasks.events, _G.rfsuite.session), and it
-- makes every instance a view of the same run.
--
-- There is one screen and one transmit slot, so a second save while one is running is refused
-- rather than interleaved. `pending` outlives a run, keyed by page, so a save the user walked
-- away from can report itself the next time that page is entered.
local function sharedState()
  _G.rfsuite = _G.rfsuite or {}
  _G.rfsuite.tasks = _G.rfsuite.tasks or {}
  local shared = _G.rfsuite.tasks.savePipeline
  if not shared then
    shared = { run = nil, pending = {}, outcome = nil, revision = 0 }
    _G.rfsuite.tasks.savePipeline = shared
  end
  return shared
end

local S = sharedState()

-- getProgress() builds a new table on every call, and whoever draws the notice asks on every run
-- of the tool. The revision lets it ask only when something it would report may have moved: it is
-- raised wherever a field getProgress() reads changes. Raising it without a visible change costs
-- one table; missing a change would leave a stale notice on screen, so when in doubt it is raised.
-- It lives in the shared state for the same reason the run does.
local function changed()
  S.revision = S.revision + 1
end

--- Does this outcome need no acknowledgement? A save that asked for a restart is a plain success
-- only once the restart was seen. An answer after the reboot proves only that the board is usable:
-- a reboot command lost on the link leaves a board that never restarted answering just the same,
-- and the settings that take effect at boot are then not in effect. Such an outcome stands like a
-- failure, so that it cannot pass for a finished restart by clearing itself.
local function clearsItself(result)
  if type(result) ~= "table" or result.status ~= "done" then return false end
  return result.reboot ~= true or result.rebootProven == true
end

local function finish(status, extra)
  if not S.run then return end
  -- A run whose screen went away before it could be dismissed (dismissWhenStored) ends as a
  -- dismissed one, a failure before the EEPROM commit included: it is held for its page.
  if S.run.dismissRequested == true then S.run.dismissed = true end
  local result = {
    status = status,
    saved = S.run.saved == true,
    reboot = S.run.reboot == true,
    rebootProven = S.run.rebootProven,
    rtcVerified = S.run.rtcVerified,
    probeDegraded = S.run.probeDegraded == true,
    -- Whoever asked for the save is not necessarily looking any more. A caller that reports its
    -- outcome in a dialog uses this to stay quiet and let takeResult() report on re-entry
    -- instead, so a message about one page cannot appear on top of another.
    dismissed = S.run.dismissed == true,
  }
  if type(extra) == "table" then
    for k, v in pairs(extra) do result[k] = v end
  end

  local desc = S.run.desc
  local wasDismissed = S.run.dismissed == true
  S.run = nil
  changed()
  -- info rather than debug: whether a save reached the board is not a detail, and this is the
  -- one line that says it. `saved` is the pipeline's own verdict, `reboot`/`rebootProven` say
  -- whether the board was asked to restart and whether it was seen to.
  logf("info", "pipeline %s page=%s saved=%s reboot=%s proven=%s rtc=%s step=%s phase=%s",
    tostring(status), tostring(desc.pageId), tostring(result.saved), tostring(result.reboot),
    tostring(result.rebootProven), tostring(result.rtcVerified),
    tostring(result.step), tostring(result.phase))

  -- A caller that is still on screen is told at once. One whose overlay was dismissed is not:
  -- its report would land on whatever page the user moved to, so it is held until that page is
  -- entered again and claims it.
  if wasDismissed then
    S.pending[desc.pageId or ""] = { result = result, onDone = desc.onDone }
    return
  end

  -- The outcome stays on the overlay that has been reporting all along, instead of a native
  -- dialog being raised over it. A modal here is not merely untidy: it is drawn from inside the
  -- reply handler, so the overlay underneath cannot be repainted away before it appears, and
  -- while it stands the tool's run() -- and with it the MSP tick -- does not run. The overlay is
  -- already on screen, already says what the save is doing, and answers touch.
  S.outcome = { status = status, result = result }
  if clearsItself(result) then
    S.outcome.clearAt = nowSeconds() + OUTCOME_LINGER_SECONDS
  end
  if type(desc.onDone) == "function" then
    -- The callback belongs to the page, not to the pipeline, so a fault in it must not take the
    -- save down with it -- but discarding the pcall result leaves it invisible everywhere: it
    -- raises no dialog, and the outcome line above still reads "done". Report it and carry on.
    local ok, err = pcall(desc.onDone, result)
    if not ok then
      logf("warn", "onDone failed page=%s err=%s", tostring(desc.pageId), tostring(err))
    end
  end
end

local function fail(step)
  finish("failed", { step = step })
end

local function timedOut(phase)
  finish("timeout", { phase = phase })
end

--- Enter a phase and restart its backstop.
local function enter(phase)
  -- One choke point for every transition in this file, so instrumenting it here reports the
  -- whole pipeline rather than the handful of places somebody remembered to write a line in.
  -- The elapsed time is the previous phase's, which is what tells a wait apart from a stall.
  local now = nowSeconds()
  logf("debug", "phase %s -> %s after %.2fs page=%s",
    tostring(S.run.phase or "-"), tostring(phase),
    S.run.phaseStarted and (now - S.run.phaseStarted) or 0,
    tostring(S.run.desc and S.run.desc.pageId))
  S.run.phase = phase
  S.run.phaseStarted = now
  -- Also covers the step index, which queueStep sets just before it enters the write phase.
  changed()
end

local function invalidateSessionKeys()
  local keys = S.run.desc.invalidateSessionKeys
  if type(keys) ~= "table" then return end
  local session = getSession()
  if not session then return end
  for i = 1, #keys do
    session[keys[i]] = nil
  end
end

local reload, probeOnce, queueStep

--- The last phase: drop what the page cached, so the values it shows next are read back from
-- the flight controller rather than from before the reboot.
reload = function()
  enter(PHASE.RELOAD)
  invalidateSessionKeys()
  finish("done")
end

local function startOnconnectWait()
  enter(PHASE.ONCONNECT)
  -- Scoped to the connect runner, and only now that the link answers, so its tasks do not burn
  -- their retries into a dead link. Events.reset() is deliberately not used here: it clears the
  -- link state without resetting any runner, so the tasks would keep complete = true and the
  -- clock would never be re-sent -- which is the one thing this step exists for.
  if Events and type(Events.rerunOnconnect) == "function" then
    pcall(Events.rerunOnconnect)
  end
end

--- Read MSP_TX_INFO once. Its second byte is rtcDateTimeIsSet, and the firmware derives that
-- from a RAM value which only MSP_SET_RTC sets and every reset clears -- so the same cheap read
-- serves as the pre-flight control, as the proof that the reset happened, and as the final
-- verification that the connect chain ran through.
probeOnce = function(onValue)
  local queue = getQueue()
  if not queue or not TxInfoApi then
    onValue(nil)
    return
  end
  S.run.probeOutstanding = true
  queue:add({
    command = TxInfoApi.command,
    payload = {},
    client = S.run.client,
    simulatorResponse = TxInfoApi.simulatorResponse,
    processReply = function(_, buf)
      if not S.run then return end
      S.run.probeOutstanding = false
      local parsed = TxInfoApi.parse and TxInfoApi.parse(buf) or nil
      local value = parsed and parsed.rtc_datetime_set or nil
      onValue(tonumber(value))
    end,
    errorHandler = function()
      if not S.run then return end
      S.run.probeOutstanding = false
      onValue(nil)
    end,
  })
end

local function queueReboot()
  local queue = getQueue()
  if not queue or not RebootApi then
    fail("reboot")
    return
  end
  enter(PHASE.REBOOT)
  queue:add({
    command = RebootApi.writeCommand,
    payload = RebootApi.buildWritePayload({ rebootMode = 0 }),
    isWrite = true,
    client = S.run.client,
    -- A board that is rebooting does not acknowledge the command that reboots it, so this
    -- message completes on silence rather than on a reply. Declaring that here is what lets the
    -- queue stop carrying MSP command 68 as a special case in its generic success test.
    completeAfterAttempt = 2,
    processReply = function()
      if not S.run then return end
      enter(PHASE.PROBE)
      S.run.probeDeadline = nowSeconds() + RECONNECT_TIMEOUT_SECONDS
      S.run.nextProbeAt = 0
    end,
    errorHandler = function()
      if not S.run then return end
      fail("reboot")
    end,
  })
end

local function afterCommit()
  S.run.saved = true
  if S.run.dismissRequested == true then S.run.dismissed = true end
  changed()
  if type(S.run.desc.onSaved) == "function" then
    -- Read before the call: the callback runs while S.run is still live and may end the run.
    local pageId = S.run.desc.pageId
    local ok, err = pcall(S.run.desc.onSaved)
    if not ok then
      logf("warn", "onSaved failed page=%s err=%s", tostring(pageId), tostring(err))
    end
  end

  if not S.run.reboot then
    reload()
    return
  end

  -- Pre-flight, and it is a control rather than a step: the flag has to read 1 here, or the
  -- probe cannot tell a board that rebooted from one that never went down. A board answering
  -- RTC_NOT_SUPPORTED, or not answering at all, degrades the pipeline to responsiveness-only
  -- and says so in its result instead of silently claiming a verified reboot.
  enter(PHASE.PREFLIGHT)
  probeOnce(function(value)
    if not S.run then return end
    S.run.probeDegraded = (value ~= 1)
    queueReboot()
  end)
end

local function queueCommit()
  local queue = getQueue()
  if not queue or not EepromApi then
    fail("commit")
    return
  end
  enter(PHASE.COMMIT)
  queue:add({
    command = EepromApi.command,
    payload = {},
    isWrite = true,
    client = S.run.client,
    processReply = function()
      if not S.run then return end
      afterCommit()
    end,
    errorHandler = function()
      if not S.run then return end
      fail("commit")
    end,
  })
end

-- `payload` is given for the first step only: start() resolves it before the run exists.
queueStep = function(index, payload)
  local steps = S.run.desc.steps
  if index > #steps then
    queueCommit()
    return
  end

  local step = steps[index]
  local queue = getQueue()
  if not queue then
    fail(step.label or tostring(step.command))
    return
  end

  if payload == nil then
    local reason
    payload, reason = stepPayload(step)
    if not payload then
      logf("warn", "step payload failed page=%s step=%d err=%s", tostring(S.run.desc.pageId),
        index, tostring(reason))
      fail(step.label or tostring(step.command))
      return
    end
  end

  S.run.stepIndex = index
  enter(PHASE.WRITE)
  queue:add({
    command = step.command,
    payload = payload,
    isWrite = true,
    client = S.run.client,
    processReply = function()
      if not S.run then return end
      queueStep(index + 1)
    end,
    errorHandler = function()
      if not S.run then return end
      fail(step.label or tostring(step.command))
    end,
  })
end

--- Begin a save. Returns false and a reason when the pipeline refuses to start one.
function M.start(desc)
  -- Every refusal below says so. A save that never started is what a pilot reports as "it did
  -- not save", and until now the five paths out of this function were silent -- so the record
  -- of a refused save and the record of a save that failed on the wire looked the same:
  -- nothing at all.
  if type(desc) ~= "table" or type(desc.steps) ~= "table" then
    logf("warn", "refused reason=descriptor")
    return false, "descriptor"
  end
  if S.run then
    logf("warn", "refused reason=busy page=%s running=%s", tostring(desc.pageId),
      tostring(S.run.desc and S.run.desc.pageId))
    return false, "busy"
  end
  if not ensureDeps() then
    logf("warn", "refused reason=msp_runtime_unavailable page=%s", tostring(desc.pageId))
    return false, "msp_runtime_unavailable"
  end

  local queue, mspState = getQueue()
  if not queue then
    logf("warn", "refused reason=msp_queue_unavailable page=%s", tostring(desc.pageId))
    return false, "msp_queue_unavailable"
  end

  -- While the model is armed the firmware only marks the configuration dirty and answers the
  -- EEPROM write with an error, so a save started here would report a failure the pilot cannot
  -- act on. Refuse it in one place instead of in none.
  if mspState and mspState.lastArmed == true then
    logf("warn", "refused reason=armed page=%s", tostring(desc.pageId))
    return false, "armed"
  end

  -- The first step's payload is resolved before the run exists, so a builder that fails here is a
  -- refusal with nothing queued, and an instruction-limit stop leaves no run behind.
  local firstPayload = nil
  if #desc.steps > 0 then
    local reason
    firstPayload, reason = stepPayload(desc.steps[1])
    if not firstPayload then
      logf("warn", "refused reason=payload page=%s err=%s", tostring(desc.pageId), tostring(reason))
      return false, "payload"
    end
  end

  local reboot = desc.reboot
  if type(reboot) == "function" then
    local ok, value = pcall(reboot)
    reboot = ok and value == true
  else
    reboot = reboot == true
  end

  S.run = {
    desc = desc,
    client = desc.client or ("save:" .. tostring(desc.pageId or "page")),
    reboot = reboot,
    saved = false,
    dismissed = false,
    stepIndex = 0,
  }
  S.pending[desc.pageId or ""] = nil
  S.outcome = nil
  changed()

  logf("info", "start page=%s steps=%d reboot=%s client=%s",
    tostring(desc.pageId), #desc.steps, tostring(reboot), tostring(S.run.client))
  queueStep(1, firstPayload)
  return true
end

--- Drive the phases that wait on time rather than on a reply. Called from the run loop.
function M.wakeup()
  -- The outcome is not part of a run -- finish() clears S.run before it stores one -- so this
  -- has to happen ahead of the guard below, or a successful save's notice would never expire.
  if S.outcome and S.outcome.clearAt and nowSeconds() >= S.outcome.clearAt then
    S.outcome = nil
    changed()
  end
  if not S.run then return end
  -- The run state is shared and the module handles above are NOT: they are upvalues of THIS
  -- instance, and there is more than one. A page starts the save through its own copy, loaded
  -- with loadScript; the host drives this function through a copy the memoizer handed it. So an
  -- instance that never ran start() has every handle at nil -- and the probe below would then
  -- take its "no API module" branch, report the board unanswerable, and keep doing so until the
  -- bound expired. Measured: one MSP_TX_INFO on the wire, the pre-flight, and none after the
  -- reboot, on a board that had already come back.
  ensureDeps()
  local now = nowSeconds()

  if S.run.phase == PHASE.PROBE then
    if now > S.run.probeDeadline then
      timedOut("reconnect")
      return
    end
    if not S.run.probeOutstanding and now >= (S.run.nextProbeAt or 0) then
      S.run.nextProbeAt = now + PROBE_INTERVAL_SECONDS
      probeOnce(function(value)
        if not S.run or S.run.phase ~= PHASE.PROBE then return end
        if value == nil then
          -- Unanswered, so the board is not back yet. Keep probing until the bound.
          return
        end
        -- Answered, so the flight controller is usable again. A flag of 0 additionally proves
        -- the reset really happened; a flag of 1 means it could not be proven from here. That is
        -- not a failure -- the settings are stored -- and it is not reported as a finished
        -- restart either: see clearsItself() and the outcome the host draws for it. The error is
        -- one-sided: a GPS that sets the clock from its own date before this answer, or the connect
        -- chain re-sending it after a link drop, makes a restarted board read 1 as well, but once
        -- the pre-flight read 1, only a reset clears the flag.
        S.run.rebootProven = (not S.run.probeDegraded) and value == 0
        startOnconnectWait()
      end)
    end
    return
  end

  if S.run.phase == PHASE.ONCONNECT then
    local active = Events and type(Events.isOnconnectActive) == "function"
      and Events.isOnconnectActive() == true
    if not active then
      enter(PHASE.VERIFY)
      probeOnce(function(value)
        if not S.run then return end
        S.run.rtcVerified = (value == 1)
        reload()
      end)
      return
    end
    if (now - S.run.phaseStarted) > ONCONNECT_TIMEOUT_SECONDS then
      timedOut("onconnect")
    end
    return
  end

  if S.run.phase == PHASE.WRITE or S.run.phase == PHASE.COMMIT
    or S.run.phase == PHASE.PREFLIGHT or S.run.phase == PHASE.VERIFY then
    if (now - S.run.phaseStarted) > STEP_TIMEOUT_SECONDS then
      timedOut(S.run.phase)
    end
  end
end

function M.isActive()
  return S.run ~= nil or S.outcome ~= nil
end

--- Is a finished save still waiting to be read? The page is free to change at that point --
-- what is held is only the notice.
function M.hasOutcome()
  return S.outcome ~= nil
end

--- The page must not change under a save that reboots: whoever entered the values waits for the
-- outcome rather than walking away from a flight controller that is mid-restart. Blocking here
-- means the page does not change, not that the script is suspended -- run() and the MSP tick
-- keep going, which is the whole difference from a native modal.
--
-- From the EEPROM acknowledgement onward the settings are stored, so nothing is protected by
-- holding the user any longer and the overlay becomes dismissible; the pipeline then finishes
-- headless and reports itself the next time the page is entered.
function M.blocksNavigation()
  return S.run ~= nil and S.run.reboot == true and S.run.dismissed ~= true
end

function M.isDismissible()
  return S.run ~= nil and S.run.saved == true and S.run.dismissed ~= true
end

function M.dismiss()
  if S.outcome then
    S.outcome = nil
    changed()
    return true
  end
  if not S.run or S.run.saved ~= true then return false end
  S.run.dismissed = true
  changed()
  return true
end

--- The screen showing a save that holds the page goes away without the press that would dismiss it:
-- the tool opened from the dashboard closes when fullscreen is left or the model arms, and it cannot
-- refuse to. Such a run is dismissed as Back dismisses it -- at once if its settings are stored, else
-- the moment the EEPROM commit is acknowledged -- and one that ends before that is held for its page
-- all the same, so its outcome is reported where Back's would be: when that page is entered again.
-- A run that does not hold the page (no restart) is left alone, as Back leaves it.
function M.dismissWhenStored()
  if not M.blocksNavigation() then return false end
  if S.run.saved == true then
    S.run.dismissed = true
    changed()
  else
    S.run.dismissRequested = true
  end
  return true
end

--- The screen comes back before a dismissal asked for by dismissWhenStored could be applied (the
-- tool is opened again during the writes or the EEPROM commit): the request is withdrawn, so the
-- run reports in the notice on that screen, a failure included, instead of being held for its page.
-- A run that is already dismissed stays dismissed, as after Back.
function M.reclaim()
  if S.run and S.run.dismissed ~= true then S.run.dismissRequested = nil end
end

--- Whoever is on screen renders this; the pipeline draws nothing itself.
--
-- It also reports a FINISHED save, once, until somebody dismisses it. The outcome of a save is
-- the same subject as its progress and belongs in the same box; a second surface for it is what
-- put a native dialog on top of this one.
function M.getProgress()
  if not S.run then
    if not S.outcome then return nil end
    return {
      phase = "outcome",
      status = S.outcome.status,
      result = S.outcome.result,
      done = 1,
      total = 1,
      fraction = 1,
      indeterminate = false,
      saved = S.outcome.result and S.outcome.result.saved == true,
      dismissible = true,
      terminal = true,
    }
  end
  if S.run.dismissed == true then return nil end

  local steps = S.run.desc.steps
  local total = #steps + 1                 -- the writes, plus the EEPROM commit
  local done = S.run.stepIndex or 0
  local label = nil
  local indeterminate = false

  if S.run.phase == PHASE.WRITE then
    label = steps[S.run.stepIndex] and steps[S.run.stepIndex].label or nil
  elseif S.run.phase == PHASE.COMMIT then
    label = nil
  else
    -- Past the commit there is nothing left to count: what remains is a wait on the flight
    -- controller. The phase is reported and whoever draws it names it.
    done = total
    indeterminate = true
  end

  return {
    phase = S.run.phase,
    label = label,
    done = done,
    total = total,
    fraction = total > 0 and (done / total) or 0,
    indeterminate = indeterminate,
    saved = S.run.saved == true,
    dismissible = M.isDismissible(),
    title = S.run.desc.title,
  }
end

--- Claim the outcome of a save that finished while nobody was looking, once. Called by a page
-- when it is entered. The outcome goes into the same box a save that was watched to the end
-- reports in (see finish()), which the host draws over the page that is now on screen. The
-- callback the save was started with is still called, but the page has just reloaded, so what it
-- does to the page's own state is not what reports the outcome.
function M.takeResult(pageId)
  -- While another save runs, the box shows that save's progress, and its own finish() would
  -- replace an outcome put there now. The entry stays held for the next time the page is entered.
  if S.run then return nil end
  local key = pageId or ""
  local entry = S.pending[key]
  if type(entry) ~= "table" then return nil end
  S.pending[key] = nil
  local result = entry.result
  if type(result) == "table" then
    S.outcome = { status = result.status, result = result }
    if clearsItself(result) then
      S.outcome.clearAt = nowSeconds() + OUTCOME_LINGER_SECONDS
    end
    changed()
  end
  if type(entry.onDone) == "function" then
    local ok, err = pcall(entry.onDone, entry.result)
    if not ok then
      logf("warn", "pending onDone failed page=%s err=%s", tostring(key), tostring(err))
    end
  end
  return entry.result
end

--- Moves whenever anything getProgress() reports may have changed. A caller that redraws on a
-- change compares this number and asks getProgress() for the table only when it moved.
function M.getRevision()
  return S.revision
end

function M.reset()
  S.run = nil
  S.pending = {}
  S.outcome = nil
  changed()
end

return M
