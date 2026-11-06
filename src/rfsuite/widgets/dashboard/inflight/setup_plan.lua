-- The radio set-up of in-flight tuning: the plan of what it would write, and the write. Loaded by the
-- settings page for the job that needs it and released with the page; see setup.lua for the check the
-- overlay holds resident.

local M = {}

local Setup, Log = nil, nil
local TRIM_MODE_NONE, MAX_FLIGHT_MODES, MIX_WEIGHT_GVAR_BASE, MIX_MULTIPLEX_ADD
local MIX_SCAN_CHANNELS, INPUT_SCAN_COUNT, SOURCE_REF_MIN, GVAR_NAME_VALUE, GVAR_NAME_BANK

local function logWanted()
  return Log and type(Log.wanted) == "function" and Log.wanted("info")
end

local function logDrive(fmt, ...)
  if not logWanted() then return end
  local msg = tostring(fmt)
  if select("#", ...) > 0 then msg = string.format(msg, ...) end
  Log.emit("rfsuite.inflight", msg, "info")
end

-- What a variable driving this overlay has to be. The precision is the one that matters: with one
-- decimal the mixer divides the weight by ten and every step lands at a tenth of the window it was
-- aimed at, so nothing ever fires.
local GVAR_DETAIL_MIN = -100
local GVAR_DETAIL_MAX = 100
local GVAR_DETAIL_PREC = 0
local GVAR_DETAIL_UNIT = 1

--- One mixer line, spelled the way the radio's own mixer page spells it, so that a line this plan
-- offers to delete can be recognised on the screen it will disappear from.
local function describeMix(radio, mix)
  if type(mix) ~= "table" then return "?" end
  local parts = {}
  parts[#parts + 1] = radio.sourceName(tonumber(mix.source)) or ("src " .. tostring(mix.source))

  local weight = tonumber(mix.weight)
  if weight ~= nil then
    if weight >= SOURCE_REF_MIN or weight <= -SOURCE_REF_MIN then
      local referenced = radio.sourceName(math.abs(weight) - SOURCE_REF_MIN)
      parts[#parts + 1] = (weight < 0 and "-" or "") .. (referenced or "src")
    else
      parts[#parts + 1] = tostring(weight) .. "%"
    end
  end

  local multiplex = tonumber(mix.multiplex)
  if multiplex == 1 then
    parts[#parts + 1] = "*"
  elseif multiplex == 2 then
    parts[#parts + 1] = "="
  else
    parts[#parts + 1] = "+"
  end

  local switchLabel = radio.switchName(tonumber(mix.switch))
  if switchLabel ~= nil then parts[#parts + 1] = switchLabel end
  return table.concat(parts, " ")
end

--- The line the overlay needs on a channel: full deflection, scaled by the variable, added, always
-- on.
--
-- The weight is the variable's source index offset by 1024, which is the SAME encoding the reader
-- answers in: api_model.cpp puts an inserted weight through luaIntToSourceNumval and reads it back
-- through sourceNumValToLuaInt, and those two are inverses. So a line written from this table is a
-- line the check reads back as correct, with no second convention in between.
local function gvarMixLine(radio, gvarIndex, switch)
  local sourceIndex = radio.sourceIndex("GV" .. tostring(gvarIndex))
  if sourceIndex == nil then return nil end
  local mixsrcMax = radio.mixsrcMax()
  if mixsrcMax == nil then return nil end
  return {
    name = "",
    source = mixsrcMax,
    weight = MIX_WEIGHT_GVAR_BASE + sourceIndex,
    offset = 0,
    switch = switch or 0,
    multiplex = MIX_MULTIPLEX_ADD,
    curveType = 0,
    curveValue = 0,
    flightModes = 0,
    carryTrim = false,
    mixWarn = 0,
    delayUp = 0,
    delayDown = 0,
    speedUp = 0,
    speedDown = 0
  }
end

--- Whether a variable already carries exactly the details the setup would write.
--
-- Compared on every field the write sets, which is more than the check looks at. The two questions
-- are different ones: the check asks whether the overlay can WORK, so it reads the precision and
-- the range; this asks whether there is anything left to write, so a variable with the right range
-- under a different name is still one write -- offered once, and then never again.
local function gvarDetailsAlreadySet(radio, index, details)
  if type(radio.globalVariableDetails) ~= "function" then return false end
  local have = radio.globalVariableDetails(index - 1)
  if type(have) ~= "table" then return false end
  if tostring(have.name or "") ~= details.name then return false end
  if tonumber(have.min) ~= details.min then return false end
  if tonumber(have.max) ~= details.max then return false end
  if tonumber(have.prec) ~= details.prec then return false end
  if tonumber(have.unit) ~= details.unit then return false end
  return true
end

--- Whether a channel already carries nothing but the line the overlay needs.
--
-- The fields M.check's own checkMixLine compares, read on the same terms: a field the reader does
-- not answer is not held against the line. That is what keeps the check and the plan from
-- disagreeing about a model neither of them can see all of -- a plan that demanded more than the
-- check reads would offer a rewrite of a model the screen above the button had just called correct.
local function channelAlreadySet(radio, channel, mix)
  if radio.mixesCount(channel) ~= 1 then return false end
  local have = radio.mix(channel, 0)
  if type(have) ~= "table" then return false end
  if tonumber(have.source) ~= tonumber(mix.source) then return false end
  if tonumber(have.weight) ~= tonumber(mix.weight) then return false end
  if tonumber(have.multiplex) ~= MIX_MULTIPLEX_ADD then return false end
  if tonumber(have.switch) ~= tonumber(mix.switch) then return false end
  if (tonumber(have.offset) or 0) ~= 0 then return false end
  if (tonumber(have.curveType) or 0) ~= 0 then return false end
  if (tonumber(have.flightModes) or 0) ~= 0 then return false end
  if Setup.mixHasTiming(have) then return false end
  return true
end

-- EdgeTX's MAX_SPECIAL_FUNCTIONS and MAX_TIMERS on every colour radio (radio/src/dataconstants.h).
local SPECIAL_FUNCTION_COUNT = 64
local TIMER_COUNT = 3

--- Note one line's references. A line's weight, offset and curve value are a number or a source: Lua
-- reads a source there as its index moved past +-1024 (datastructs_private.h, sourceNumValToLuaInt).
local function addNamed(set, value)
  value = tonumber(value)
  if value ~= nil and value ~= 0 then set[math.abs(value)] = true end
end

local function addNamedValue(named, value)
  value = tonumber(value)
  if value ~= nil and math.abs(value) >= 1024 then addNamed(named.source, math.abs(value) - 1024) end
end

local function addNamedLine(named, line)
  addNamed(named.switch, line.switch)
  addNamed(named.source, line.source)
  addNamedValue(named, line.weight)
  addNamedValue(named, line.offset)
  addNamedValue(named, line.curveValue)
end

-- The halves of the reference walk, in order. Each `read` takes the slot at `at` and answers false
-- when the half has ended early; `limit` is where it ends otherwise.
local NAMED_HALVES = {
  {
    from = 0, limit = 63,
    read = function(radio, named, k)
      local ls = radio.logicalSwitch(k)
      if ls and (tonumber(ls.func) or 0) ~= 0 then
        addNamed(named.switch, ls["and"])
        addNamed(named.switch, ls.v1) addNamed(named.source, ls.v1)
        addNamed(named.switch, ls.v2) addNamed(named.source, ls.v2)
      end
      return true
    end
  },
  {
    from = 0, limit = SPECIAL_FUNCTION_COUNT - 1,
    read = function(radio, named, k)
      local cf = radio.customFunction(k)
      if cf and (tonumber(cf.switch) or 0) ~= 0 then
        addNamed(named.switch, cf.switch)
        addNamed(named.switch, cf.value) addNamed(named.source, cf.value)
      end
      return true
    end
  },
  {
    from = 1, limit = 8,
    read = function(radio, named, fm)
      local data = radio.flightModeData(fm)
      if data then addNamed(named.switch, data.switch) end
      return true
    end
  },
  {
    from = 0, limit = TIMER_COUNT - 1,
    read = function(radio, named, n)
      local timer = radio.timer(n)
      if timer then addNamed(named.switch, timer.switch) end
      return true
    end
  }
}

--- The reference walk, resumable: every number the model's lines, switches, functions, flight modes
-- and timers hold where a logical switch can be named, as two sets of magnitudes (an inverted
-- switch, `!L01`, names the same slot): `switch`, compared with the slot's switch number, and
-- `source`, compared with its source number. Switch and source numbers are two ranges that overlap,
-- so a number is only held against the range it was read from.
--
-- Taken wider than it has to be on purpose: a logical switch's `v1`/`v2` or a special function's
-- `value` is a switch or a source only for some functions, and is counted here in both sets for
-- all of them. A number that merely looks like a logical switch costs the search one candidate; a
-- slot that IS named and is taken anyway makes whatever names it act every time a step is pulsed.
local function newNamedWalk(radio)
  return {
    radio = radio, named = { switch = {}, source = {} },
    lineHalf = "mix", at = 1, count = nil, line0 = 0, half = 0, slot = 0
  }
end

--- One slice of that walk: at most `budget` reads. Answers the reads left, and true once it is through.
local function namedWalkStep(walk, budget)
  local radio, named = walk.radio, walk.named
  local left = budget
  while walk.lineHalf ~= nil do
    local mix = walk.lineHalf == "mix"
    local limit = mix and MIX_SCAN_CHANNELS or (INPUT_SCAN_COUNT - 1)
    if mix == false and (type(radio.inputsCount) ~= "function" or type(radio.input) ~= "function") then
      walk.lineHalf = nil
      break
    end
    if walk.at > limit then
      if not mix then walk.lineHalf = nil
      else walk.lineHalf, walk.at, walk.count, walk.line0 = "input", 0, nil, 0 end
    elseif walk.count == nil then
      if left <= 0 then return 0, false end
      left = left - 1
      walk.count = mix and radio.mixesCount(walk.at) or (not mix and radio.inputsCount(walk.at)) or nil
      walk.line0 = 0
      if walk.count == nil then
        if mix then walk.lineHalf, walk.at, walk.count, walk.line0 = "input", 0, nil, 0
        else walk.lineHalf = nil end
      end
    elseif walk.line0 >= walk.count then
      walk.at, walk.count = walk.at + 1, nil
    else
      if left <= 0 then return 0, false end
      left = left - 1
      local line
      if mix then line = radio.mix(walk.at, walk.line0) else line = radio.input(walk.at, walk.line0) end
      if line then addNamedLine(named, line) end
      walk.line0 = walk.line0 + 1
    end
  end
  while true do
    if walk.half == 0 or walk.slot > NAMED_HALVES[walk.half].limit then
      walk.half = walk.half + 1
      if walk.half > #NAMED_HALVES then return left, true end
      walk.slot = NAMED_HALVES[walk.half].from
    end
    local half = NAMED_HALVES[walk.half]
    while walk.slot <= half.limit do
      if left <= 0 then return 0, false end
      left = left - 1
      half.read(radio, named, walk.slot)
      walk.slot = walk.slot + 1
    end
  end
end

--- The logical switch the value line is to be switched by, found in stages over a plan job: see
-- M.planStep. Nothing the pilot set up is ever written over. In this order: the switch the value
-- line already carries, when it is exactly the one this needs; else any slot that already is; else
-- the LAST empty slot nothing on the model names -- the rule the Volume page's chain uses for its
-- own logical switch, so the two do not reach for slots on different terms. A slot holding anything
-- else is the pilot's, and a model with no slot left is refused rather than overwritten.
--
-- `gate` is { slot, switch, create, def, gvar }: `slot` 0-based, `switch` what the mixer line holds
-- for it, `create` true where the slot is empty and has to be written.
local function gateAnswer(job, k, create)
  job.gate = {
    slot = k, switch = job.lsBase + k, create = create, def = job.gateDef, gvar = job.settings.value_gvar
  }
end

--- Refuse the plan with a reason.
local function refusePlan(job, reason)
  job.plan.refused = reason
  job.done = true
end

local PLAN_STAGES = {}

function PLAN_STAGES.start(job)
  local radio, settings, plan = job.radio, job.settings, job.plan
  local bankGvar = settings.bank_gvar or 0
  local valueGvar = settings.value_gvar or 0
  if bankGvar <= 0 or valueGvar <= 0 then return refusePlan(job, "no_gvar") end
  if bankGvar == valueGvar then return refusePlan(job, "same_gvar") end
  if settings.bank_ch == settings.value_ch then return refusePlan(job, "same_channel") end
  if type(radio.canWrite) ~= "function" or not radio.canWrite() then
    return refusePlan(job, "unsupported")
  end

  -- The value variable first, and only where a write would change something.
  local wantedGvars = {
    { index = valueGvar, role = "value", name = GVAR_NAME_VALUE },
    { index = bankGvar, role = "bank", name = GVAR_NAME_BANK }
  }
  for i = 1, #wantedGvars do
    local entry = wantedGvars[i]
    entry.details = {
      name = entry.name, min = GVAR_DETAIL_MIN, max = GVAR_DETAIL_MAX,
      prec = GVAR_DETAIL_PREC, unit = GVAR_DETAIL_UNIT
    }
    if not gvarDetailsAlreadySet(radio, entry.index, entry.details) then
      -- What the restore puts back, read before anything is written.
      entry.before = type(radio.globalVariableDetails) == "function"
        and radio.globalVariableDetails(entry.index - 1) or nil
      plan.gvars[#plan.gvars + 1] = entry
    end
  end

  -- The logical switch that times the pulse, found before anything is listed: a model with no slot
  -- for it is refused as a whole, since a value line without it is the line that steps twice.
  if type(radio.logicalSwitch) ~= "function" or type(radio.lsBase) ~= "function" then
    return refusePlan(job, "unsupported")
  end
  job.gateDef = Setup.gateDefinition(radio, valueGvar)
  job.lsBase = radio.lsBase()
  if job.gateDef == nil or job.lsBase == nil then return refusePlan(job, "unsupported") end

  if (radio.mixesCount(settings.value_ch) or 0) >= 1 then
    local mix = radio.mix(settings.value_ch, 0)
    local k = mix and Setup.lsIndexOf(radio, mix.switch)
    if k ~= nil and Setup.isGate(radio.logicalSwitch(k), job.gateDef) then
      gateAnswer(job, k, false)
      job.stage = "channels"
      return
    end
  end
  job.lsAt, job.empty = 0, {}
  job.stage = "slots"
end

function PLAN_STAGES.slots(job, left)
  local radio = job.radio
  while job.lsAt < Setup.LOGICAL_SWITCH_COUNT do
    if left <= 0 then return 0 end
    left = left - 1
    local ls = radio.logicalSwitch(job.lsAt)
    if Setup.isGate(ls, job.gateDef) then
      gateAnswer(job, job.lsAt, false)
      job.stage = "channels"
      return left
    end
    if ls and tonumber(ls.func) == 0 then job.empty[#job.empty + 1] = job.lsAt end
    job.lsAt = job.lsAt + 1
  end
  if #job.empty == 0 then return refusePlan(job, "no_ls") end
  job.walk = newNamedWalk(radio)
  job.stage = "named"
  return left
end

function PLAN_STAGES.named(job, left)
  local through
  left, through = namedWalkStep(job.walk, left)
  if not through then return 0 end
  local radio, named = job.radio, job.walk.named
  job.walk = nil
  local sourceBase = type(radio.lsSourceBase) == "function" and radio.lsSourceBase() or nil
  for j = #job.empty, 1, -1 do
    local k = job.empty[j]
    if not named.switch[job.lsBase + k] and not (sourceBase ~= nil and named.source[sourceBase + k]) then
      gateAnswer(job, k, true)
      break
    end
  end
  job.empty = nil
  if job.gate == nil then return refusePlan(job, "no_ls") end
  job.stage = "channels"
  return left
end

-- The two configured channels, and nothing else on this model is looked at, let alone written.
-- Within a channel the deletions are listed HIGHEST INDEX FIRST, which is the order they have to
-- be carried out in: deleting a line renumbers every line above it.
function PLAN_STAGES.channels(job, left)
  local radio, settings, plan = job.radio, job.settings, job.plan
  if job.gate.create then plan.ls = job.gate end
  if job.wanted == nil then
    job.wanted = {
      { channel = settings.bank_ch, gvar = settings.bank_gvar, role = "bank", switch = 0 },
      { channel = settings.value_ch, gvar = settings.value_gvar, role = "value", switch = job.gate.switch }
    }
    job.wantedAt = 1
  end
  while job.wantedAt <= #job.wanted do
    local entry = job.wanted[job.wantedAt]
    if entry.count == nil then
      if left <= 0 then return 0 end
      left = left - 1
      entry.count = radio.mixesCount(entry.channel)
      if entry.count == nil then return refusePlan(job, "unsupported") end
      entry.mix = gvarMixLine(radio, entry.gvar, entry.switch)
      if entry.mix == nil then return refusePlan(job, "unsupported") end
      -- A channel already carrying nothing but this line is not touched, and does not appear among
      -- the channels the question counts removals from either.
      entry.settled = channelAlreadySet(radio, entry.channel, entry.mix)
      if not entry.settled then
        entry.lines = {}
        entry.line0 = 0
        plan.channels[#plan.channels + 1] = {
          channel = entry.channel, role = entry.role, removed = entry.count, lines = entry.lines
        }
      end
    end
    if not entry.settled then
      while entry.line0 < entry.count do
        if left <= 0 then return 0 end
        left = left - 1
        -- Read whole: the restore puts every field back.
        local line = radio.mix(entry.channel, entry.line0)
        if line == nil then return refusePlan(job, "unsupported") end
        entry.lines[entry.line0 + 1] = line
        entry.line0 = entry.line0 + 1
      end
      for line0 = entry.count - 1, 0, -1 do
        plan.deletions[#plan.deletions + 1] = {
          channel = entry.channel, line0 = line0, was = entry.lines[line0 + 1]
        }
      end
      plan.insertions[#plan.insertions + 1] = {
        channel = entry.channel, line0 = 0, gvar = entry.gvar, role = entry.role, mix = entry.mix
      }
    end
    job.wantedAt = job.wantedAt + 1
  end
  job.stage = "trims"
  return left
end

-- A trim that still trims is a trim that moves the stick neutral the flight controller was
-- calibrated against, with the very press that is meant to move a parameter. It has to be off in
-- EVERY flight mode, not only the active one, because the pilot will fly in the others. Judged
-- the way M.check judges it, so the two cannot disagree: a mode linked to one whose trim is
-- already off trims nothing and is left as it is, link and all.
function PLAN_STAGES.trims(job, left)
  local radio, settings, plan = job.radio, job.settings, job.plan
  if settings.trims == true then
    -- One trim on two jobs is a fault no write repairs, so nothing is replaced for it.
    local claimed, twice = Setup.claimedTrims(settings, job.trims)
    if twice then return refusePlan(job, "trim_claimed_twice") end
    local byMode = Setup.flightModeTrims(radio)
    for fm = 0, MAX_FLIGHT_MODES - 1 do
      if byMode[fm] == nil then break end
      local modes, indexes, before = nil, {}, {}
      for i = 1, #claimed do
        local index = claimed[i].index
        if Setup.trimStillTrims(byMode, fm, index) then
          modes = modes or {}
          modes[index] = TRIM_MODE_NONE
          indexes[#indexes + 1] = index
          before[index] = tonumber(byMode[fm][index])
        end
      end
      if modes ~= nil then
        plan.trims[#plan.trims + 1] = { fm = fm, modes = modes, indexes = indexes, before = before }
      end
    end
  end

  -- Nothing queued means the model already is what the write would make it, and the button says so
  -- instead of putting up a confirmation for a write with no content in it.
  if #plan.gvars == 0 and #plan.deletions == 0 and #plan.insertions == 0 and #plan.trims == 0
      and plan.ls == nil then
    plan.nothing = true
  end
  plan.ok = true
  job.done = true
  return left - MAX_FLIGHT_MODES
end

--- Everything the write would do, as a list, before any of it is done, in slices.
--
-- The plan exists so that the destructive half can be READ before it is agreed to. The overlay
-- needs each of its two channels to carry nothing but its own line, and a pilot who has the
-- reference layout on those channels is about to lose thirty mixer lines -- which is a reasonable
-- thing to agree to and never a reasonable thing to discover afterwards. So the question counts the
-- lines per channel, and the plan keeps them whole for the restore.
--
-- The plan is also a COMPARATOR, and that is what keeps it from being a rewrite. Everything it
-- queues is something this model does not already carry: a variable whose details differ, a channel
-- that does not carry exactly the one line, a flight mode that still trims a claimed trim. A plan
-- that queued them unconditionally asked the pilot to confirm a delete-and-reinsert of the very
-- line its last run had written, on every press, on a model the check beside the button had just
-- called correct. When nothing is left to queue it says so through plan.nothing.
--
-- `trims` is the resolved trim block, the same one M.check takes: without it a stored trim SETTING
-- is a switch position that cannot be turned into the semantic number the firmware's trim-mode
-- table is indexed by, so no trim fault could be answered -- which is how the trim half of this
-- plan came to be unreachable for every trim the check can raise a fault about.
--
-- Taken in slices because the walk over a model does not fit in one widget call: the tool opened
-- from the dashboard stops at the instruction limit when all of it runs on one press. Nothing here
-- writes. M.newApplyJob does, and only what this returned.
function M.newPlanJob(radio, settings, trims)
  if type(radio) ~= "table" or type(settings) ~= "table" then return nil end
  return {
    radio = radio, settings = settings, trims = trims, stage = "start", done = false,
    plan = { gvars = {}, deletions = {}, insertions = {}, trims = {}, channels = {} }
  }
end

--- One slice of a plan: about `budget` reads off the model. Answers true once `job.plan` is final.
function M.planStep(job, budget)
  if type(job) ~= "table" then return true end
  local left = budget or math.huge
  -- The start stage is the only one that takes no count: it reads two variables and one line.
  while not job.done and left > 0 do
    local spent = PLAN_STAGES[job.stage](job, left)
    left = (type(spent) == "number") and spent or (left - 4)
  end
  return job.done
end

--- The whole plan at once, where nothing bounds the call.
function M.plan(radio, settings, trims)
  local job = M.newPlanJob(radio, settings, trims)
  if job == nil then return nil end
  M.planStep(job, math.huge)
  return job.plan
end

--- A channel's line as it stands, compared with one the plan put there or the backup holds, on every
-- field the mixer API carries (api_model.cpp, luaModelGetMix).
M.MIX_FIELDS = {
  "source", "weight", "offset", "switch", "curveType", "curveValue", "multiplex", "flightModes",
  "carryTrim", "mixWarn", "delayPrec", "delayUp", "delayDown", "speedPrec", "speedUp", "speedDown", "name"
}

function M.sameLine(have, wanted)
  if type(have) ~= "table" then return false end
  for i = 1, #M.MIX_FIELDS do
    local key = M.MIX_FIELDS[i]
    if tostring(have[key]) ~= tostring(wanted[key]) then return false end
  end
  return true
end

local OP_STEPS = {}

function OP_STEPS.gvar(radio, op)
  local entry = op.entry
  local ok, err = radio.setGlobalVariableDetails(entry.index - 1, entry.details)
  logDrive("setup: GV%d named %s, %s..%s prec %s -> %s", entry.index, tostring(entry.details.name),
    tostring(entry.details.min), tostring(entry.details.max), tostring(entry.details.prec), tostring(ok))
  return ok, err, "gvar", entry.index
end

function OP_STEPS.ls(radio, op)
  local ls = op.ls
  local ok, err = radio.setLogicalSwitch(ls.slot, ls.def)
  logDrive("setup: L%02d func %s, delay %s, duration %s -> %s", ls.slot + 1, tostring(ls.def.func),
    tostring(ls.def.delay), tostring(ls.def.duration), tostring(ok))
  return ok, err, "ls", ls.slot
end

function OP_STEPS.delete(radio, op)
  local entry = op.entry
  -- Deleting a line renumbers those above it, and a line index past the end is silently nothing.
  -- A count that is not the one this step expects means a step of this job has already acted, or
  -- something else has: stop rather than delete the wrong line.
  if radio.mixesCount(entry.channel) ~= entry.line0 + 1 then
    logDrive("setup: CH%d holds another count than expected before line %d", entry.channel, entry.line0 + 1)
    return false, "unexpected count", "delete", entry.channel
  end
  -- The same count can hold another line: a line the plan did not read is not in the record, so it is
  -- not this step's to delete. A restore's own deletions name no line: they clear what stands there.
  if entry.was ~= nil and not M.sameLine(radio.mix(entry.channel, entry.line0), entry.was) then
    logDrive("setup: CH%d line %d changed since the plan", entry.channel, entry.line0 + 1)
    return false, "line changed", "delete", entry.channel
  end
  local text = nil
  if logWanted() then text = describeMix(radio, radio.mix(entry.channel, entry.line0)) end
  local ok, err = radio.deleteMix(entry.channel, entry.line0)
  logDrive("setup: CH%d line %d removed (%s) -> %s", entry.channel, entry.line0 + 1, text or "?", tostring(ok))
  return ok, err, "delete", entry.channel .. ":" .. entry.line0
end

function OP_STEPS.insert(radio, op)
  local entry = op.entry
  if radio.mixesCount(entry.channel) ~= entry.line0 then
    logDrive("setup: CH%d holds another count than expected before line %d", entry.channel, entry.line0 + 1)
    return false, "unexpected count", "insert", entry.channel
  end
  local ok, err = radio.insertMix(entry.channel, entry.line0, entry.mix)
  logDrive("setup: CH%d line %d added -> %s", entry.channel, entry.line0 + 1, tostring(ok))
  return ok, err, "insert", entry.channel .. ":" .. entry.line0
end

function OP_STEPS.trim(radio, op)
  local entry = op.entry
  local ok, err = radio.setFlightMode(entry.fm, { trimsModes = entry.modes })
  logDrive("setup: flight mode %d trims -> %s", entry.fm, tostring(ok))
  return ok, err, "trim", entry.fm
end

-- After a restore: the line as it stands against the line the record holds, field by field. The
-- writers' own read-backs compare three fields; this is what makes "restored" mean all of them.
function OP_STEPS.verify(radio, op)
  local ok = M.sameLine(radio.mix(op.entry.channel, op.entry.line0), op.entry.mix)
  if not ok then
    logDrive("setup: CH%d line %d differs after the restore", op.entry.channel, op.entry.line0 + 1)
  end
  return ok, ok and nil or "differs", "verify", op.entry.channel .. ":" .. op.entry.line0
end

--- Carry out exactly what the plan listed, in the order that keeps every intermediate state safe.
--
-- The order is the point. The variables are given their range and precision FIRST, so that the
-- moment a line referring to one exists it already scales the way it is meant to. Then the channel
-- is emptied, which parks it at centre -- a channel with no mixer line is a channel at centre,
-- which is exactly where an adjustment channel belongs when nothing is being adjusted. Only then
-- is the overlay's own line inserted. The other way round would leave the old lines and the new
-- one summed on the same channel for as long as the writes take.
--
-- Taken a few steps per pass, for the same reason as the plan, and it STOPS at the first step that
-- fails: going on after a refused deletion would leave the new line beside an old one, and a line
-- naming a logical switch that refused the write would be a line that never steps. Every step's
-- result is recorded, so what was done can be reported and put back.
--
-- Across passes old lines stand with some of their neighbours already gone, for a fraction of a
-- second. That is on the ground only: the caller stops the job the moment the model arms.
function M.newApplyJob(radio, plan)
  local report = { steps = {}, written = 0, failed = 0 }
  local job = { radio = radio, plan = plan, report = report, ops = {}, at = 1, done = false }
  if type(radio) ~= "table" or type(plan) ~= "table" or plan.ok ~= true then
    report.refused = (type(plan) == "table" and plan.refused) or "no_plan"
    job.done = true
    return job
  end
  local ops = job.ops
  for i = 1, #plan.gvars do ops[#ops + 1] = { kind = "gvar", entry = plan.gvars[i] } end
  if plan.ls ~= nil then ops[#ops + 1] = { kind = "ls", ls = plan.ls } end
  for i = 1, #plan.deletions do ops[#ops + 1] = { kind = "delete", entry = plan.deletions[i] } end
  for i = 1, #plan.insertions do ops[#ops + 1] = { kind = "insert", entry = plan.insertions[i] } end
  for i = 1, #plan.trims do ops[#ops + 1] = { kind = "trim", entry = plan.trims[i] } end
  if type(plan.verify) == "table" then
    for i = 1, #plan.verify do ops[#ops + 1] = { kind = "verify", entry = plan.verify[i] } end
  end
  return job
end

--- At most `count` steps of a write. Answers true once it has finished or stopped.
function M.applyStep(job, count)
  if type(job) ~= "table" or job.done then return true end
  local report, ops = job.report, job.ops
  local left = count or math.huge
  while left > 0 and job.at <= #ops do
    local op = ops[job.at]
    local ok, err, kind, detail = OP_STEPS[op.kind](job.radio, op)
    report.steps[#report.steps + 1] = { kind = kind, detail = detail, ok = ok == true, err = err }
    job.at = job.at + 1
    left = left - 1
    if ok == true then
      report.written = report.written + 1
    else
      report.failed = report.failed + 1
      job.stopped = true
      job.done = true
      return true
    end
  end
  if job.at > #ops then job.done = true end
  return job.done
end

--- The whole write at once, where nothing bounds the call.
function M.applyPlan(radio, plan)
  local job = M.newApplyJob(radio, plan)
  M.applyStep(job, math.huge)
  return job.report
end

--- Which instance of setup.lua this works with: the overlay's where one is loaded, the page's otherwise.
function M.bind(setup, log)
  Setup, Log = setup, log
  TRIM_MODE_NONE, MAX_FLIGHT_MODES = setup.TRIM_MODE_NONE, setup.MAX_FLIGHT_MODES
  MIX_WEIGHT_GVAR_BASE, MIX_MULTIPLEX_ADD = setup.MIX_WEIGHT_GVAR_BASE, setup.MIX_MULTIPLEX_ADD
  MIX_SCAN_CHANNELS, INPUT_SCAN_COUNT = setup.MIX_SCAN_CHANNELS, setup.INPUT_SCAN_COUNT
  SOURCE_REF_MIN = setup.MIX_WEIGHT_GVAR_BASE
  GVAR_NAME_VALUE, GVAR_NAME_BANK = setup.GVAR_NAME_VALUE, setup.GVAR_NAME_BANK
end

return M
