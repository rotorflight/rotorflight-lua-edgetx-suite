-- Ground-only profile transactions. One send or one reply parse is served per widget pass.
-- The return pair outlives aborts and disconnects; no new transaction can replace it.
local M = {}
local requireModule = _G.rfsuite.require
local Functions = requireModule("widgets/dashboard/inflight/functions.lua")
local Store = requireModule("widgets/dashboard/inflight/baseline.lua")
if type(Functions) ~= "table" or type(Store) ~= "table" then error("inflight/profiles.lua: dependency missing", 0) end
local CLIENT = "inflight-profiles"
local COMMANDS = { pid = {112, 94, 148, 146}, rate = {111}, global = {142, 240} }
M.COMMANDS = COMMANDS

local function api(command)
  local name = command == 101 and "status" or Functions.fieldsForCommand(command)
  return name and requireModule("tasks/msp/api/" .. name .. ".lua")
end

local function tracked(fn)
  return fn.id > 4 and fn.id ~= 82 and fn.cmd ~= nil
end
M.tracked = tracked

function M.reachable(records, status)
  local result = { pid = {}, rate = {} }
  local counts = { pid = tonumber(status.pid_profile_count), rate = tonumber(status.control_rate_profile_count) }
  local active = { pid = tonumber(status.current_pid_profile_index), rate = tonumber(status.current_control_rate_profile_index) }
  for _, kind in ipairs({"pid", "rate"}) do
    local count, current = counts[kind], active[kind]
    if not count or count < 1 or count > 6 or not current or current < 0 or current >= count then
      return nil, "profile_count"
    end
    result[kind][current + 1] = true
  end
  for _, slot in pairs(records or {}) do
    local kind = slot.adjFunction == 2 and "pid" or slot.adjFunction == 1 and "rate" or nil
    if kind then
      local lo = math.max(1, math.ceil(tonumber(slot.adjMin) or 1))
      local hi = math.min(6, counts[kind], math.floor(tonumber(slot.adjMax) or 0))
      for index = lo, hi do result[kind][index] = true end
    end
  end
  return result
end

function M.selection(kind, index)
  return (index - 1) | (kind == "rate" and 0x80 or 0)
end

local function section(kind, index)
  return kind == "global" and "global" or kind .. tostring(index)
end
M.section = section

local function bump(drive)
  drive.valueEpoch = (drive.valueEpoch or 0) + 1
end

local function statusPair(parsed)
  if type(parsed) ~= "table" then return nil end
  local pid, rate = tonumber(parsed.current_pid_profile_index), tonumber(parsed.current_control_rate_profile_index)
  local np, nr = tonumber(parsed.pid_profile_count), tonumber(parsed.control_rate_profile_count)
  if not pid or not rate or not np or not nr or np < 1 or nr < 1 or np > 6 or nr > 6
    or pid < 0 or pid >= np or rate < 0 or rate >= nr then return nil end
  return { pid = pid + 1, rate = rate + 1 }
end

local function identity(env)
  local board, uid = env.identity()
  if not board or not uid then return nil end
  return board, tostring(uid)
end

local function add(plan, op, kind, index, command)
  plan[#plan + 1] = { op = op, kind = kind, index = index, command = command }
end

local function targetPlan(plan, kind, index, restore)
  if kind ~= "global" then add(plan, "select", kind, index) end
  add(plan, "status", kind, index, 101)
  for _, command in ipairs(COMMANDS[kind]) do
    add(plan, "read", kind, index, command)
  end
  if restore then
    for _, command in ipairs(COMMANDS[kind]) do
      add(plan, "status", kind, index, 101)
      add(plan, "write", kind, index, command)
    end
    add(plan, "status", kind, index, 101)
    for _, command in ipairs(COMMANDS[kind]) do add(plan, "verify", kind, index, command) end
  end
  add(plan, "status", kind, index, 101)
  add(plan, "targetDone", kind, index)
end

local function returnPlan(job)
  job.planBuild = nil
  job.plan, job.at, job.returning, job.returned = {}, 1, true, nil
  add(job.plan, "returnSelect", "pid", job.original.pid)
  add(job.plan, "returnSelect", "rate", job.original.rate)
  if job.wrote and not job.saveIssued then
    -- Saving reinitializes continuous adjustment slots. Return to the original pair before
    -- the single save, so the channel-selected pair can be observed without a false failure.
    add(job.plan, "returnCheck", nil, nil, 101)
    add(job.plan, "eeprom", nil, nil, 250)
    add(job.plan, "savedStatus", nil, nil, 101)
    if not job.error then
      for _, target in ipairs(job.targets) do
        if target.kind ~= "global" then add(job.plan, "select", target.kind, target.index) end
        add(job.plan, "status", target.kind, target.index, 101)
        for _, command in ipairs(COMMANDS[target.kind]) do
          add(job.plan, "persistVerify", target.kind, target.index, command)
        end
        add(job.plan, "status", target.kind, target.index, 101)
        add(job.plan, "persistDone", target.kind, target.index)
      end
      add(job.plan, "returnSelect", "pid", job.original.pid)
      add(job.plan, "returnSelect", "rate", job.original.rate)
    end
  end
  add(job.plan, "returnStatus", nil, nil, 101)
end

local function cancelRequest(job)
  job.serial = job.serial + 1
  job.reply, job.waiting = nil, false
  if job.queue and type(job.queue.clear) == "function" then job.queue:clear(CLIENT) end
end

local function abort(drive, job, reason)
  if _G.rfsuite.inflightProfileJob == job then _G.rfsuite.inflightProfileJob = nil end
  if job.store then Store.cancel(job.store); job.store = nil end
  cancelRequest(job)
  job.validation = nil
  job.error = job.error or reason
  if job.currentTarget then
    job.results[job.currentTarget] = reason
  end
  drive.restorePending = job.original ~= nil
  if job.original then returnPlan(job) else job.finished = true end
  bump(drive)
end

function M.busy(drive)
  return drive.profileJob ~= nil
end

function M.begin(widget, drive, env, mode, target)
  if M.busy(drive) then return false, "reading" end
  if env.armed(widget) then return false, "armed" end
  if not widget.state.fblConnected or not env.queue() then return false, "no_link" end
  local board, uid = identity(env)
  if not board then return false, "reading" end
  local baseline, recovery
  -- A session is one power cycle of the board. Its start values are read when it begins; within it
  -- (a short link gap, a link back in the air) the read continues the session from its stored
  -- values. A drive that holds no session -- a new start, a radio restart, a session ended by a
  -- battery change -- begins a new one, whatever an earlier session left on the card. The session
  -- is the board's, not the widget's: while another dashboard in this Lua state holds one for this
  -- board (rfsuite.inflightSession), a drive without one joins it rather than replacing its file.
  -- An expiry still pending (the link was gone for the gap on the ground, and work held when it came
  -- back kept the session from ending) means the board is in a new state: that session ends here and
  -- this read begins a new one, never a continuation of it -- for the automatic read and Read again
  -- alike (a restore asked for meanwhile is turned into this read by prime.lua, M.restore, so the
  -- stale start values are not written back). This read is the one Drive:endSession asks for, so no
  -- second one is requested. A parameter choice of the ended session may already have filtered the
  -- groups, so they are filtered again without it.
  if drive.sessionExpired and (mode == "auto" or mode == "refresh") then
    local chosen = drive.sessionList
    drive:endSession()
    drive.readAgain = nil
    if chosen ~= nil then drive:applyFilter() end
    if drive.phase == "post" then drive:setPhase("ground") end
    if mode == "refresh" then mode = "new" end
  end
  if mode == "auto" then
    local root = _G.rfsuite
    if drive.baseline == nil and not (type(root) == "table" and root.inflightSession == uid) then
      mode = "new"
    else
      local reason
      baseline, reason, recovery = Store.load(uid, board, true)
      if baseline or recovery then mode = "resume"
      elseif reason == "baseline_missing" then mode = "new"
      else return false, reason end
    end
  end
  if mode == "restore" or mode == "resume" then
    local reason
    if not baseline and not recovery then baseline, reason, recovery = Store.load(uid, board, true) end
    if not baseline and not recovery then return false, reason end
    -- A complete schema, not just the requested profile, must be present before any write.
    if baseline and target and type(baseline[section(target.kind, target.index)]) ~= "table" then
      return false, "profile_unread"
    end
  end
  if mode == "refresh" then baseline = drive.baseline end
  local job = { mode = mode, target = target, identity = board, uid = uid, baseline = baseline,
    at = 1, plan = {{op = "initial", command = 101}}, serial = 0, results = {}, records = {}, targets = {}, targetRecords = {},
    values = { global = {}, pid = {}, rate = {} }, changes = {global = {}, pid = {}, rate = {}},
    env = env, prime = drive.prime,
    validation = baseline and M.newValidation(baseline), validationPurpose = "input", recovery = recovery }
  drive.profileJob = job
  drive.profileBusy = true
  _G.rfsuite.inflightProfileJob = job
  drive.transfer = mode == "restore" and {kind = mode, state = "busy", results = job.results} or nil
  drive:cleanup(false)
  drive.reportFence = true
  bump(drive)
  return true
end

function M.newValidation(data)
  return {data = data, last = nil, field = 1, pidCount = 0, rateCount = 0, pidMask = 0, rateMask = 0}
end

local function rangeError(fn, value)
  return {kind = "firmware_range", name = fn.name, value = value}
end

-- The fields a section of each kind is checked for, built once. Walking the whole function table
-- for every section spent most passes on fields of another scope: a full baseline took 135 passes,
-- which at the widget's cadence is about ten seconds in front of the first profile read.
local scopeFields, building
-- Answers true once the lists are complete; sorts CHECKS_PER_PASS entries per call.
local function buildScopeFields(perPass)
  building = building or {lists = {pid = {}, rate = {}, global = {}}, at = 1}
  local functions = Functions.FUNCTIONS
  for _ = 1, perPass do
    local fn = functions[building.at]
    if not fn then
      scopeFields, building = building.lists, nil
      return true
    end
    local list = building.lists[Functions.scopeOf(fn.id) or "global"]
    if list and tracked(fn) then list[#list + 1] = fn end
    building.at = building.at + 1
  end
  return false
end

-- Sixteen checks per pass: about a thousand instructions, and a full baseline in about 30 passes.
local CHECKS_PER_PASS = 16

function M.validateStep(work)
  local data = work.data
  if not work.started then
    if type(data) ~= "table" or type(data.meta) ~= "table" or data.meta.version ~= 1
      or type(data.meta.timestamp) ~= "string" or type(data.meta.identity) ~= "string"
      or type(data.meta.uid) ~= "string" or type(data.meta.masterGains) ~= "boolean" then return true, false end
    work.started = true
  end
  -- The lists are built once per session, a slice per pass, in passes that check nothing else.
  if not scopeFields then buildScopeFields(CHECKS_PER_PASS); return false end
  for _ = 1, CHECKS_PER_PASS do
    if not work.name then
      local name, values = next(data, work.last)
      if name == "meta" then work.last = name; name, values = next(data, name) end
      if not name then
        return true, type(data.global) == "table" and work.pidCount > 0 and work.rateCount > 0
          and work.pidCount == data.meta.pidCount and work.rateCount == data.meta.rateCount
          and work.pidMask == data.meta.pidMask and work.rateMask == data.meta.rateMask
      end
      if type(name) ~= "string" then return true, false end
      local kind = name == "global" and "global" or string.match(name, "^(pid)%d$") or string.match(name, "^(rate)%d$")
      local index = tonumber(string.match(name, "(%d)$"))
      if not kind or (index and (index < 1 or index > 6)) or type(values) ~= "table" then return true, false end
      if kind ~= "global" then
        work[kind .. "Count"] = work[kind .. "Count"] + 1
        work[kind .. "Mask"] = work[kind .. "Mask"] | (1 << (index - 1))
      end
      work.name, work.kind, work.values, work.field = name, kind, values, 1
      work.fields = scopeFields[kind]
    end
    local fn = work.fields[work.field]
    if not fn then
      work.last, work.name = work.name, nil
    else
      if fn.id < 83 or data.meta.masterGains then
        local value = work.values[tostring(fn.id)]
        if type(value) ~= "number" or value ~= value or value ~= math.floor(value) then return true, false end
        if value < (fn.fwMin or fn.min) or value > (fn.fwMax or fn.max) then return true, false, rangeError(fn, value) end
      end
      work.field = work.field + 1
    end
  end
  return false
end

-- Synchronous convenience for offline inspection; widget jobs use one validateStep per pass.
function M.complete(data)
  local work = M.newValidation(data)
  while true do local done, valid = M.validateStep(work); if done then return valid end end
end

local function buildPlan(job, drive, parsed)
  local reachable, reason = M.reachable(job.prime.records, parsed)
  if not reachable then return reason end
  job.original = statusPair(parsed)
  job.expected = { pid = job.original.pid, rate = job.original.rate }
  job.plan, job.at = {}, 1
  if job.mode == "refresh" then
    if not drive.sessionProfiles then return "session_unread" end
    reachable = drive.sessionProfiles
  elseif job.mode == "restore" or job.mode == "resume" then
    if job.mode == "restore" then reachable = { pid = {}, rate = {} } end
    for name in pairs(job.baseline) do
      local kind, n = string.match(name, "^(%a+)(%d)$")
      if reachable[kind] then reachable[kind][tonumber(n)] = true end
    end
    for kind, profiles in pairs(reachable) do
      local count = kind == "pid" and parsed.pid_profile_count or parsed.control_rate_profile_count
      for index in pairs(profiles) do
        if index > count then return "profile_count" end
        if not job.baseline[section(kind, index)] then job.extendBaseline = true end
      end
    end
  end
  job.reachable = reachable
  job.planBuild = 1
  return nil
end

-- Build one target per pass. A full restore spans every profile and must leave room for the
-- dashboard's telemetry drain and the fullscreen input path on the same widget call.
local function buildPlanStep(job)
  for position = job.planBuild, 13 do
    local kind = position <= 6 and "pid" or position <= 12 and "rate" or "global"
    local index = kind ~= "global" and (position - 1) % 6 + 1 or nil
    local reachable = kind == "global" or job.reachable[kind][index]
    if reachable and (not job.target or (job.target.kind == kind and (kind == "global" or job.target.index == index))) then
      targetPlan(job.plan, kind, index, job.mode == "restore")
      job.planBuild = position + 1
      return
    end
  end
  job.planBuild = nil
  if job.prime then
    local replies = job.mode == "restore" and 6 or 4
    for _, op in ipairs(job.plan) do if op.op ~= "targetDone" then replies = replies + 1 end end
    job.prime.total = (job.prime.done or 0) + replies
  end
  if job.mode == "restore" then
    for _, op in ipairs(job.plan) do
      if op.op == "targetDone" then
        job.results[section(op.kind, op.index)] = "not_restored"
        job.targets[#job.targets + 1] = {kind = op.kind, index = op.index}
      end
    end
  end
end

local function fieldsInto(job, op, parsed)
  local _, fields = Functions.fieldsForCommand(op.command)
  local values, changes
  if op.kind == "global" then values, changes = job.values.global, job.changes.global else
    job.values[op.kind][op.index] = job.values[op.kind][op.index] or {}
    values = job.values[op.kind][op.index]
    job.changes[op.kind][op.index] = job.changes[op.kind][op.index] or {}
    changes = job.changes[op.kind][op.index]
  end
  local base = job.baseline and job.baseline[section(op.kind, op.index)]
  for _, fn in ipairs(fields) do
    if tracked(fn) then
      local value = tonumber(parsed[fn.field])
      if fn.id >= 83 and value ~= nil and job.baseline and not job.baseline.meta.masterGains then
        return "baseline_incomplete"
      end
      if fn.id >= 83 and value == nil and not (job.baseline and job.baseline.meta.masterGains) then
        -- Master gains were added without an API-version change; reply length declares them.
      else
        if not value or value ~= value then return "baseline_incomplete" end
        if value < (fn.fwMin or fn.min) or value > (fn.fwMax or fn.max) then return rangeError(fn, value) end
        values[fn.id] = value
        changes[fn.id] = base and base[tostring(fn.id)] ~= value or nil
        if fn.id >= 83 then job.masterGains = true end
      end
    end
  end
end

local function parseReply(drive, job, op, reply)
  if reply.error then return reply.error end
  if op.op == "select" or op.op == "returnSelect" then
    job.expected[op.kind] = op.index
    return
  end
  if op.op == "write" then return end
  if op.op == "eeprom" then
    for name, result in pairs(job.results) do
      if result == "ram_ok" then
        job.results[name] = "saved"
        job.verification[name].saved = true
      end
    end
    return
  end
  local module = api(op.command)
  local parsed = module and module.parse(reply.buf)
  if type(parsed) ~= "table" then return "invalid_reply" end
  if op.command == 101 then
    local pair = statusPair(parsed)
    if not pair then return "profile_count" end
    if op.op == "initial" then
      return buildPlan(job, drive, parsed)
    end
    local expected = (op.op == "returnStatus" or op.op == "savedStatus") and job.original or job.expected
    if pair.pid ~= expected.pid or pair.rate ~= expected.rate then return "profile_changed" end
    if op.op == "returnStatus" then job.returned = true; drive.restorePending = nil end
    return
  end
  if op.op == "verify" or op.op == "persistVerify" then
    local expected = op.op == "verify" and job.records[op.command]
      or job.targetRecords[section(op.kind, op.index)][op.command]
    for field, value in pairs(expected) do
      if parsed[field] ~= value then return "verify_failed" end
    end
  end
  local reason = fieldsInto(job, op, parsed)
  if reason then return reason end
  if op.op == "read" and job.mode == "restore" then
    local _, fields = Functions.fieldsForCommand(op.command)
    local base = job.baseline[section(op.kind, op.index)]
    for _, fn in ipairs(fields) do
      if tracked(fn) and base[tostring(fn.id)] ~= nil then parsed[fn.field] = base[tostring(fn.id)] end
    end
    -- All other parsed fields retain the just-read FC record, never a simulator default.
    job.records[op.command] = parsed
  end
end

local function send(widget, drive, job, op)
  local env = job.env
  if env.armed(widget) then return "armed" end
  local queue = env.queue()
  if not queue then return "no_link" end
  local payload, command, simulator, write = nil, op.command, nil, false
  if op.op == "select" or op.op == "returnSelect" then
    command, payload, write, simulator = 210, {M.selection(op.kind, op.index)}, true, {}
  elseif op.op == "eeprom" then
    payload, write, simulator = {}, true, {}
    job.saveIssued = true
  elseif op.op == "write" then
    local module = api(command)
    if not module or not module.writeCommand or type(module.buildWritePayload) ~= "function" then return "no_api" end
    payload = module.buildWritePayload(job.records[command])
    command, write, simulator = module.writeCommand, true, {}
  else
    local module = api(command)
    if not module or type(module.parse) ~= "function" then return "no_api" end
    simulator = module.simulatorResponse
    -- MSP selections precede telemetry updates. A telemetry-keyed response cache can still
    -- name the previous profile, so transaction reads must reach the FC.
    local cache = requireModule("tasks/msp/cache.lua")
    if cache and cache.keyFor(command) then cache.clear(command) end
  end
  job.serial = job.serial + 1
  local serial = job.serial
  job.waiting, job.queue = true, queue
  if op.op == "write" then job.wrote = true end
  queue:add({ command = command, payload = payload, isWrite = write, client = CLIENT,
    simulatorResponse = simulator,
    processReply = function(_, buf)
      if drive.profileJob ~= job or job.serial ~= serial or job.linkLost or not job.waiting then return end
      local copy = {}
      for i = 1, #(buf or {}) do copy[i] = buf[i] end
      job.reply = {buf = copy}
      job.waiting = false
    end,
    errorHandler = function(_, reason)
      if drive.profileJob ~= job or job.serial ~= serial or job.linkLost or not job.waiting then return end
      job.reply, job.waiting = {error = reason or "failed"}, false
    end })
end

local function snapshotStep(job, drive)
  if not job.data then
    local stamp = drive.radio.clock and drive.radio.clock() or "clock unavailable"
    if type(_G.getDateTime) == "function" then
      local dt = _G.getDateTime()
      if dt then stamp = string.format("%04d-%02d-%02d %02d:%02d:%02d", dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec) end
    end
    job.data = {meta = {version = 1, identity = job.identity, uid = job.uid,
      craft = tostring((_G.rfsuite.session or {}).modelName or ""), timestamp = stamp,
      ticks = drive.radio.now(), pidCount = 0, rateCount = 0, pidMask = 0, rateMask = 0,
      masterGains = job.masterGains == true}}
    if job.mode == "resume" then
      -- Keep the original session metadata and start values; only new sections come from the FC.
      for key, value in pairs(job.baseline.meta) do job.data.meta[key] = value end
      job.data.meta.pidCount, job.data.meta.rateCount = 0, 0
      job.data.meta.pidMask, job.data.meta.rateMask = 0, 0
    end
    job.snapKind, job.snapIndex = 1, 0
    return
  end
  local kind = ({"pid", "rate", "global"})[job.snapKind]
  if not kind then
    job.validation, job.validationPurpose = M.newValidation(job.data), "output"
    return
  end
  local index, values
  if kind == "global" and job.snapIndex == 0 then index, values = 1, job.values.global
  elseif kind ~= "global" then
    local last = job.snapIndex
    if last == 0 then last = nil end
    index, values = next(job.values[kind], last)
  end
  if not index then job.snapKind, job.snapIndex = job.snapKind + 1, 0; return end
  local out = job.mode == "resume" and job.baseline[section(kind, index)] or nil
  if not out then
    out = {}
    for id, value in pairs(values) do out[tostring(id)] = value end
  end
  job.data[section(kind, index)] = out
  if kind ~= "global" then
    job.data.meta[kind .. "Count"] = job.data.meta[kind .. "Count"] + 1
    job.data.meta[kind .. "Mask"] = job.data.meta[kind .. "Mask"] | (1 << (index - 1))
  end
  job.snapIndex = index
end

local function finish(drive, job)
  if job.cancelled then job.error = job.error or "cancelled" end
  if not job.error then
    if job.mode == "new" or job.mode == "resume" then
      drive.baseline, drive.sessionProfiles = job.data or job.baseline, job.reachable
      drive.profileValues, drive.changes = job.values, job.changes
      drive.profilePrevious = {pid = {}, rate = {}, global = {}}
    elseif job.mode == "refresh" then drive.profileValues, drive.changes = job.values, job.changes
    end
    drive.valuesRead, drive.primeInterrupted = true, nil
    if job.mode == "new" or job.mode == "resume" then drive.readRequired, drive.readArmed = nil, nil end
    drive.readAt = drive.radio.clock and drive.radio.clock() or nil
    if job.mode == "new" or job.mode == "resume" then
      drive.sessionMode = job.mode
      _G.rfsuite.inflightSession = job.uid
    end
    -- New start values end the session, and its parameter choice with it.
    if job.mode == "new" and drive.sessionList ~= nil then drive:setSessionList(nil) end
    if job.mode ~= "restore" then drive:activateProfiles(); drive:countOutOfBounds() end
  elseif job.mode ~= "restore" then
    drive.primeInterrupted = true
    drive._primeFails = (drive._primeFails or 0) + 1
  end
  if job.prime then
    -- Restore failures belong to the transfer result. They must not trigger the prime's
    -- automatic read retry and replace the results before the pilot can inspect them.
    job.prime.phase = job.mode == "restore" and "done" or job.error and "error" or "done"
    job.prime.error = job.mode ~= "restore" and job.error or nil
  end
  if job.mode == "restore" then
    if drive.profileValues then
      for _, kind in ipairs({"pid", "rate", "global"}) do
        for index = 1, kind == "global" and 1 or 6 do
          if job.results[section(kind, index)] == "ok" then
            if kind == "global" then
              drive.profileValues.global, drive.changes.global = job.values.global, job.changes.global
            else
              drive.profileValues[kind][index], drive.changes[kind][index] = job.values[kind][index], job.changes[kind][index]
            end
          end
        end
      end
      drive:activateProfiles()
    end
    drive.transfer = {kind = "restore", state = job.error and "error" or "ok", reason = job.error,
      results = job.results, verification = job.verification}
    drive.restoreResultOpen = 1
  end
  drive.profileJob, drive.profileBusy, drive.restorePending = nil, nil, nil
  if job.returned then drive.profile, drive.rateProfile = job.original.pid, job.original.rate end
  if _G.rfsuite.inflightProfileJob == job then _G.rfsuite.inflightProfileJob = nil end
  bump(drive)
end

function M.retryReturn(drive)
  local job = drive.profileJob
  if job and job.returnBlocked then job.returnBlocked = nil; return true end
  return false
end

function M.drop(drive)
  local job = drive.profileJob
  if not job then return end
  if job.store then Store.cancel(job.store) end
  cancelRequest(job)
  if _G.rfsuite.inflightProfileJob == job then _G.rfsuite.inflightProfileJob = nil end
  drive.profileJob, drive.profileBusy, drive.restorePending = nil, nil, nil
end

function M.tick(widget, drive, hasRoom)
  local job = drive.profileJob
  if not job then return false end
  local env = job.env
  if job.linkLost then
    if not job.suspended then abort(drive, job, "no_link") end
    job.linkLost, job.suspended = nil, true
    return true
  end
  local blocked = env.armed(widget) or not widget.state.fblConnected
  local board, uid = identity(env)
  if blocked or board ~= job.identity or uid ~= job.uid then
    if not job.suspended then abort(drive, job, env.armed(widget) and "armed" or "no_link") end
    job.suspended = true
    return true
  end
  if job.suspended then job.suspended, job.returnBlocked = nil, nil end
  _G.rfsuite.inflightProfileJob = job
  if job.cancelled and not job.error then abort(drive, job, "cancelled"); return true end
  if job.returnBlocked then return true end
  if hasRoom == false then return true end
  if job.recovery then
    local done, data, reason = Store.loadStep(job.recovery, job.uid, job.identity)
    if done then
      job.recovery = nil
      if data and job.target and type(data[section(job.target.kind, job.target.index)]) ~= "table" then
        reason, data = "profile_unread", nil
      end
      if data then job.baseline = data else job.error, job.finished = reason, true end
    end
    return true
  end
  if job.validation then
    local done, valid, reason = M.validateStep(job.validation)
    if done then
      job.validation = nil
      if not valid then job.error, job.finished = reason or "baseline_incomplete", true
      elseif job.validationPurpose == "output" then
        local reason
        job.store, reason = Store.begin(job.uid, job.data)
        if not job.store then job.error, job.finished = reason, true end
      end
    end
    return true
  end
  if job.planBuild then buildPlanStep(job); return true end
  if job.finished then finish(drive, job); return true end
  if job.store then
    local done, reason = Store.step(job.store)
    if done then
      if reason then Store.cancel(job.store) end
      job.store = nil; job.error = reason; job.finished = true
    end
    return true
  end
  if job.reply then
    local op, reply = job.plan[job.at], job.reply
    job.reply = nil
    if op.op ~= "initial" then job.at = job.at + 1 end
    local reason = parseReply(drive, job, op, reply)
    if reason then
      if job.returning and (not op.kind or op.op == "returnSelect") then
        cancelRequest(job)
        job.error = job.error or reason
        returnPlan(job)
        job.returnBlocked, drive.restorePending = true, true
        bump(drive)
      else abort(drive, job, reason) end
    end
    if job.prime then job.prime.done = (job.prime.done or 0) + 1 end
    return true
  end
  if job.waiting then return true end
  local op = job.plan[job.at]
  if not op then
    if not job.returning then returnPlan(job); drive.restorePending = true; return true end
    if not job.returned then abort(drive, job, "profile_changed"); return true end
    if (job.mode == "new" or job.extendBaseline) and not job.error then
      snapshotStep(job, drive)
    else job.finished = true end
    return true
  end
  if op.op == "targetDone" or op.op == "persistDone" then
    local name = section(op.kind, op.index)
    if job.mode == "restore" and op.op == "targetDone" then
      job.targetRecords[name], job.records = job.records, {}
      job.results[name] = "ram_ok"
      job.verification = job.verification or {}
      job.verification[name] = {ram = true, saved = false, readBack = false}
    else
      job.results[name] = "ok"
      if op.op == "persistDone" then job.verification[name].readBack = true end
    end
    job.at = job.at + 1
    return true
  end
  job.currentTarget = op.kind and section(op.kind, op.index) or nil
  local reason = send(widget, drive, job, op)
  if reason then abort(drive, job, reason) end
  return true
end

return M
