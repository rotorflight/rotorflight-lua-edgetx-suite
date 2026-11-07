-- The radio set-up of in-flight tuning against a stub model: the plan and the write in slices, the
-- stop on a refused step, and the restore, field by field.
--
-- The tool opened from the dashboard runs in the widget's call, which is stopped at 20 000
-- instructions, so a slice has to fit beside the rest of that pass. The hook counts what one slice
-- spends the way the firmware bills a widget call.
debug.getmetatable("").__index = nil
local sourceRoot = arg[1] or "src"
local tmpDir = os.tmpname()
os.remove(tmpDir)
assert(os.execute("mkdir -p " .. tmpDir))

local checked = 0
local function check(value, message)
  checked = checked + 1
  if not value then
    print("FAIL " .. message)
    os.exit(1)
  end
end

-- The most a page's slice may spend: the page's own idle pass and the dashboard share the 20 000.
local SLICE_LIMIT = 6000
local PLAN_SLICE, WRITE_SLICE, PARSE_SLICE, ENCODE_SLICE = 32, 4, 8, 3

-- --------------------------------------------------------------------------- the radio
local MAX_LS, MAX_FM = 64, 9
local LS_BASE, SOURCE_LS, MIXSRC_MAX_VALUE = 200, 700, 900
local world

local function freshWorld()
  local w = { mixes = {}, inputs = {}, ls = {}, cf = {}, fm = {}, gvars = {}, timers = {}, file = "model7.yml", name = "Trainer" }
  for ch = 0, 31 do w.mixes[ch] = {} end
  for i = 0, 31 do w.inputs[i] = {} end
  for k = 0, MAX_LS - 1 do w.ls[k] = { func = 0, v1 = 0, v2 = 0, v3 = 0, ["and"] = 0, delay = 0, duration = 0, state = false, persistent = false } end
  for k = 0, 63 do w.cf[k] = { switch = 0, value = 0 } end
  for fm = 0, MAX_FM - 1 do w.fm[fm] = { switch = 0, trimsModes = { 0, 0, 0, 0, 0, 0 } } end
  for g = 0, 8 do w.gvars[g] = { name = "", min = -1024, max = 1024, prec = 1, unit = 0, popup = false } end
  for n = 0, 2 do w.timers[n] = { switch = 0 } end
  return w
end

local function copyLine(line)
  local out = {}
  for k, v in pairs(line) do out[k] = v end
  return out
end

local function fullLine(i)
  return {
    name = "L" .. i, source = i + 1, weight = 100 - i, offset = i, switch = 0, curveType = 1, curveValue = i,
    multiplex = 2, flightModes = 3, carryTrim = (i % 2 == 0), mixWarn = 1, delayPrec = 1, delayUp = 2,
    delayDown = 3, speedPrec = 1, speedUp = 4, speedDown = 5
  }
end

local refuseDeleteOn = nil

model = {
  getInfo = function() return { name = world.name, filename = world.file } end,
  getMixesCount = function(ch) return #world.mixes[ch] end,
  getMix = function(ch, line) local l = world.mixes[ch][line + 1]; return l and copyLine(l) or nil end,
  -- The firmware's getMix answers every field, whatever the insert left out.
  insertMix = function(ch, line, value)
    local stored = copyLine(value)
    for _, key in ipairs({ "offset", "curveType", "curveValue", "multiplex", "flightModes", "mixWarn", "delayPrec",
      "delayUp", "delayDown", "speedPrec", "speedUp", "speedDown" }) do
      if stored[key] == nil then stored[key] = 0 end
    end
    if stored.carryTrim == nil then stored.carryTrim = false end
    if stored.name == nil then stored.name = "" end
    table.insert(world.mixes[ch], line + 1, stored)
  end,
  deleteMix = function(ch, line)
    if refuseDeleteOn == ch then return end
    table.remove(world.mixes[ch], line + 1)
  end,
  getInputsCount = function(i) return #world.inputs[i] end,
  getInput = function(i, line) return world.inputs[i][line + 1] end,
  getLogicalSwitch = function(k) return copyLine(world.ls[k]) end,
  setLogicalSwitch = function(k, def)
    world.ls[k] = { func = 0, v1 = 0, v2 = 0, v3 = 0, ["and"] = 0, delay = 0, duration = 0, state = false, persistent = false }
    for key, value in pairs(def) do world.ls[k][key] = value end
  end,
  getCustomFunction = function(k) return world.cf[k] end,
  getFlightMode = function(fm)
    local data = world.fm[fm]
    if not data then return nil end
    return { switch = data.switch, trimsModes = copyLine(data.trimsModes) }
  end,
  setFlightMode = function(fm, data)
    for index, value in pairs(data.trimsModes) do world.fm[fm].trimsModes[index] = value end
    return 0
  end,
  getTimer = function(n) return world.timers[n] end,
  getGlobalVariableDetails = function(g) return copyLine(world.gvars[g]) end,
  setGlobalVariableDetails = function(g, details)
    for key, value in pairs(details) do world.gvars[g][key] = value end
  end,
  setGlobalVariable = function() end
}
getSwitchIndex = function(name) if name == "L01" then return LS_BASE end end
getSourceIndex = function(name) return 400 + tonumber(string.match(name, "(%d+)")) end
getSourceName = function(index) return "S" .. tostring(index) end
getSwitchName = function(index) return "SW" .. tostring(index) end
getFieldInfo = function(name) if name == "ls1" then return { id = SOURCE_LS } end end
MIXSRC_MAX = MIXSRC_MAX_VALUE
LS_FUNC_APOS = 5
function mkdir(path) return os.execute("mkdir -p " .. path) and 0 or 1 end
function del(path) return os.remove(path) and 0 or 1 end
function rename(from, to) return os.rename(from, to) and 0 or 1 end

-- The suite's reads on a radio go through the library form, and io.read takes the file first.
local realRead = io.read
io.read = function(file, count) return file:read(count) end
io.write = function(file, text) return file:write(text) end
io.close = function(file) return file:close() end

rfsuite = {
  paths = { core = sourceRoot .. "/rfsuite", user = tmpDir },
  require = function(path)
    if path == "lib/log.lua" then return { wanted = function() return false end, emit = function() end } end
    return assert(loadfile(sourceRoot .. "/rfsuite/" .. path))()
  end
}
loadScript = function(path) return loadfile(path) end

local Setup = assert(loadfile(sourceRoot .. "/rfsuite/widgets/dashboard/inflight/setup.lua"))()
local Backup = assert(loadfile(sourceRoot .. "/rfsuite/widgets/dashboard/inflight/setup_backup.lua"))()
local Plan = assert(loadfile(sourceRoot .. "/rfsuite/widgets/dashboard/inflight/setup_plan.lua"))()
Plan.bind(Setup, rfsuite.require("lib/log.lua"))
Backup.bind(Plan)

local function settings(extra)
  local s = Setup.loadRadioSettings({ inflight = extra or {} })
  return s
end

--- Run `step` until it answers true, and hand back the largest count one call spent.
local function worstSlice(step)
  local worst, passes = 0, 0
  local finished = false
  while not finished do
    local count = 0
    debug.sethook(function() count = count + 1 end, "", 1)
    finished = step()
    debug.sethook()
    if count > worst then worst = count end
    passes = passes + 1
    check(passes < 1000, "a job ends")
  end
  return worst, passes
end

local function snapshot()
  local out = { mixes = {}, ls = {}, gvars = {}, fm = {} }
  for ch = 0, 31 do
    out.mixes[ch] = {}
    for i, line in ipairs(world.mixes[ch]) do out.mixes[ch][i] = copyLine(line) end
  end
  for k = 0, MAX_LS - 1 do out.ls[k] = copyLine(world.ls[k]) end
  for g = 0, 8 do out.gvars[g] = copyLine(world.gvars[g]) end
  for fm = 0, MAX_FM - 1 do out.fm[fm] = copyLine(world.fm[fm].trimsModes) end
  return out
end

local function sameTable(a, b, where)
  for k, v in pairs(a) do
    if type(v) == "table" then
      sameTable(v, b[k], where .. "." .. tostring(k))
    else
      check(b[k] == v, where .. "." .. tostring(k) .. " is " .. tostring(b[k]) .. ", was " .. tostring(v))
    end
  end
  for k in pairs(b) do check(a[k] ~= nil, where .. "." .. tostring(k) .. " is new") end
end

local function saveRecord(plan)
  local enc = Backup.newEncode(plan, world.file)
  local worst = worstSlice(function() return Backup.encodeStep(enc, ENCODE_SLICE) end)
  return Backup.saveText(world.file, enc.text), worst
end

local function runPlan(radio, config)
  local job = Plan.newPlanJob(radio, config, nil)
  local worst, passes = worstSlice(function() return Plan.planStep(job, PLAN_SLICE) end)
  return job.plan, worst, passes
end

local function runApply(radio, plan)
  local job = Plan.newApplyJob(radio, plan)
  local worst, passes = worstSlice(function() return Plan.applyStep(job, WRITE_SLICE) end)
  return job, worst, passes
end

--- The model the walk costs most on: no gate, empty slots, every other table full of references.
local function worstCaseModel()
  world = freshWorld()
  for ch = 0, 31 do
    for i = 1, 2 do world.mixes[ch][i] = fullLine(i) end
  end
  for i = 1, 30 do world.mixes[10][i] = fullLine(i) end
  for i = 1, 30 do world.mixes[11][i] = fullLine(i) end
  for i = 0, 31 do world.inputs[i][1] = { switch = 3, source = 4, weight = 1100, offset = 1101, curveValue = 1102 } end
  for k = 0, MAX_LS - 3 do world.ls[k] = { func = 1, v1 = k, v2 = k + 1, v3 = 0, ["and"] = 2, delay = 0, duration = 0, state = true, persistent = false } end
  for k = 0, 63 do world.cf[k] = { switch = k + 1, value = k } end
  for fm = 0, MAX_FM - 1 do world.fm[fm].trimsModes = { fm * 2, fm * 2, fm * 2, fm * 2, fm * 2, fm * 2 } end
end

-- --------------------------------------------------------------------------- the plan, in slices
do
  worstCaseModel()
  local radio = Setup.radio()
  local config = settings()
  local plan, worst, passes = runPlan(radio, config)
  print(string.format("plan, worst-case model: %d passes, worst slice %d instructions", passes, worst))
  check(plan.ok == true, "the worst-case model gets a plan")
  check(worst <= SLICE_LIMIT, "a plan slice stays under the limit, " .. worst)
  check(passes > 1, "the walk does not take one pass")
  check(plan.ls ~= nil and plan.ls.slot == MAX_LS - 1, "the gate takes the last empty slot nothing names")
  check(#plan.channels == 2 and plan.channels[1].removed == 30, "the plan counts the lines per channel")
  check(#plan.deletions == 60 and plan.deletions[1].line0 == 29, "deletions run highest first")

  -- The whole plan at once gives the same answer: the standalone tool's and the old call's.
  local whole = Plan.plan(radio, config, nil)
  check(#whole.deletions == #plan.deletions and whole.ls.slot == plan.ls.slot, "plan() is the same plan")

  -- A slot something names is not taken.
  world.cf[0] = { switch = LS_BASE + MAX_LS - 1, value = 0 }
  local named = Plan.plan(radio, config, nil)
  check(named.ls.slot == MAX_LS - 2, "a named slot is left alone, got " .. tostring(named.ls.slot))
end

-- --------------------------------------------------------------------------- refusals and comparator
do
  world = freshWorld()
  local radio = Setup.radio()
  local refused = Plan.plan(radio, settings({ bank_gvar = 3, value_gvar = 3 }), nil)
  check(refused.ok ~= true and refused.refused == "same_gvar", "the same variable twice is refused")
  for k = 0, MAX_LS - 1 do world.ls[k] = { func = 1, v1 = 1, v2 = 1, v3 = 0, ["and"] = 0, delay = 0, duration = 0 } end
  local full = Plan.plan(radio, settings(), nil)
  check(full.refused == "no_ls", "no free slot is refused")

  world = freshWorld()
  local config = settings()
  local plan = runPlan(radio, config)
  runApply(radio, plan)
  local again = runPlan(radio, config)
  check(again.nothing == true, "a model set up has nothing left to write")
end

-- --------------------------------------------------------------------------- the write stops
do
  world = freshWorld()
  for i = 1, 3 do world.mixes[10][i] = fullLine(i) end
  for i = 1, 3 do world.mixes[11][i] = fullLine(i) end
  local radio = Setup.radio()
  local plan = runPlan(radio, settings())
  refuseDeleteOn = 10
  local job = runApply(radio, plan)
  refuseDeleteOn = nil
  check(job.stopped == true and job.report.failed == 1, "a refused deletion stops the write")
  check(#world.mixes[10] == 3, "nothing goes on after it")
  check(#world.mixes[11] == 3, "the next channel is untouched")
  for i = 1, 3 do check(world.mixes[10][i].name == "L" .. i, "the lines stand") end

  -- A step of this job that has already acted is not repeated on another line.
  world = freshWorld()
  for i = 1, 3 do world.mixes[10][i] = fullLine(i) end
  local plan2 = runPlan(radio, settings())
  table.remove(world.mixes[10], 3)
  local job2 = runApply(radio, plan2)
  check(job2.stopped == true, "an unexpected line count stops the write")
  check(#world.mixes[10] == 2, "and deletes nothing")
end

-- --------------------------------------------------------------------------- the record and the restore
do
  worstCaseModel()
  world.gvars[4] = { name = "OLD", min = -50, max = 60, prec = 1, unit = 1, popup = true }
  local radio = Setup.radio()
  local config = settings({ trims = true, trim_mode = "rows" })
  local before = snapshot()
  local plan = runPlan(radio, config)
  check(Backup.stateOf(world.file) == nil, "no record before a set-up")

  local saved, encodeWorst = saveRecord(plan)
  print(string.format("record, 60 lines: worst encode slice %d instructions", encodeWorst))
  check(saved, "the record is saved")
  check(encodeWorst <= SLICE_LIMIT, "an encode slice stays under the limit, " .. encodeWorst)
  check(Backup.stateOf(world.file) == "partial", "it says partial until the end")
  local _, worst = runApply(radio, plan)
  print(string.format("write, 60 deletions: worst slice %d instructions", worst))
  check(worst <= SLICE_LIMIT, "a write slice stays under the limit, " .. worst)
  check(#world.mixes[10] == 1 and #world.mixes[11] == 1, "each channel carries one line")
  check(Backup.markState(world.file, "complete"), "the record is marked")
  check(Backup.stateOf(world.file) == "complete", "it says complete")

  local parse = Backup.newParse(world.file)
  local parseWorst = worstSlice(function() return Backup.parseStep(parse, PARSE_SLICE) end)
  print(string.format("record, 60 lines: worst parse slice %d instructions", parseWorst))
  check(parseWorst <= SLICE_LIMIT, "a parse slice stays under the limit, " .. parseWorst)
  check(Backup.stillCarries(radio, parse.record), "the model carries what was written")

  local restore = Backup.restorePlan(radio, parse.record)
  local job, restoreWorst = runApply(radio, restore)
  print(string.format("restore: worst slice %d instructions", restoreWorst))
  check(restoreWorst <= SLICE_LIMIT, "a restore slice stays under the limit, " .. restoreWorst)
  check(job.stopped ~= true, "the restore completes, " .. tostring(job.report.steps[#job.report.steps].err))
  sameTable(before, snapshot(), "model")
  check(Backup.remove(world.file) and Backup.stateOf(world.file) == nil, "the record is gone after a restore")
end

-- --------------------------------------------------------------------------- when the restore is not offered
do
  world = freshWorld()
  local radio = Setup.radio()
  local config = settings()
  local plan = runPlan(radio, config)
  check(saveRecord(plan), "saved")
  runApply(radio, plan)
  check(Backup.markState(world.file, "complete"), "marked")
  local function record()
    local parse = Backup.newParse(world.file)
    Backup.parseStep(parse, math.huge)
    return parse.record
  end
  check(Backup.stillCarries(radio, record()), "unchanged model: offered")
  world.mixes[10][2] = fullLine(9)
  check(not Backup.stillCarries(radio, record()), "another line on a channel: not offered")
  table.remove(world.mixes[10], 2)
  check(Backup.stillCarries(radio, record()), "put back: offered again")
  local offset = world.mixes[10][1].offset
  world.mixes[10][1].offset = 7
  check(not Backup.stillCarries(radio, record()), "any field of the line changed: not offered")
  world.mixes[10][1].offset = offset
  world.gvars[4].min = -90
  check(not Backup.stillCarries(radio, record()), "a changed variable: not offered")
  check(Backup.newParse("other.yml") == nil and Backup.stateOf("other.yml") == nil, "a record belongs to its model file")

  -- Marking a record leaves the rest of it, and a restore that starts marks it partial again.
  check(Backup.markState(world.file, "partial") and Backup.stateOf(world.file) == "partial", "the mark moves")
  check(Backup.markState("other.yml", "partial") == false, "no record, no mark")

  -- A power cut between deleting the old file and the rename leaves the new one under its temporary
  -- name, and that is the record. One cut off while being written is not.
  local path = Backup.path(world.file)
  check(os.rename(path, path .. ".tmp"), "stage the temporary name")
  check(Backup.stateOf(world.file) == "partial", "the whole temporary copy is the record")
  local cut = assert(io.open(path .. ".tmp", "r"))
  local whole = cut:read("a")
  cut:close()
  local short = assert(io.open(path .. ".tmp", "w"))
  short:write(string.sub(whole, 1, #whole - 8))
  short:close()
  check(Backup.stateOf(world.file) == nil, "a temporary copy cut off is not a record")
  check(Backup.remove(world.file), "and is removed with it")

  -- A name the suite cannot put in a file name still gives one path.
  check(string.find(Backup.path("a b/c.yml"), "a_b_c.yml", 1, true) ~= nil, "the path is safe")
end

-- --------------------------------------------------------------------------- on per radio model
do
  world = freshWorld()
  local key = Setup.modelOnKey(world.file)
  check(key == "on_" .. world.file, "the key is the model file's")
  check(Setup.modelOnKey(nil) == nil, "no model file, no key")
  local Preferences = rfsuite.require("lib/preferences.lua")
  local function settled(section)
    local prefs = { general = { preview_inflight_tuning = true }, inflight = section }
    Preferences.settleInflight(prefs)
    return prefs
  end
  -- The key holds the model's own name, so a model that later gets the same file name is not on.
  local plainRequire = rfsuite.require
  local pendingName = nil
  local storeReads = 0
  rfsuite.require = function(path)
    if path == "lib/model_name_store.lua" then
      storeReads = storeReads + 1
      return { pending = function() return pendingName end }
    end
    return plainRequire(path)
  end
  check(settled({ [key] = world.name }).inflight.enabled == true, "on for this radio model")
  check(storeReads == 0, "a matching name reads no name store")
  check(settled({ on_other = world.name }).inflight.enabled == false, "on for another model is off here")
  check(settled({ enabled = true }).inflight.enabled == false, "the former radio-wide flag does not carry over")
  check(settled({ [key] = true }).inflight.enabled == false, "a key from before the name was stored is off")
  check(settled({ [key] = "Deleted model" }).inflight.enabled == false, "another model with this file name is off")
  local ownName = world.name
  world.name = "Trainer 2"
  check(settled({ [key] = ownName }).inflight.enabled == false, "a renamed model is off")
  pendingName = ownName
  check(settled({ [key] = ownName }).inflight.enabled == true, "on while a craft's name stands in the model's place")
  check(storeReads > 0, "the name store is read when the names differ")
  pendingName = "Someone else"
  check(settled({ [key] = ownName }).inflight.enabled == false, "the store's name has to match as well")
  world.name = ownName
  pendingName = nil
  rfsuite.require = plainRequire
  local Views = assert(loadfile(sourceRoot .. "/rfsuite/widgets/dashboard/views.lua"))()
  local function widget(section) return { state = {}, preferences = settled(section) } end
  check(Views.condition("previewInflightTuning", widget({ [key] = world.name })) == true, "the entry is there")
  check(Views.condition("previewInflightTuning", widget({})) ~= true, "never switched on: no entry")
  check(Views.condition("previewInflightTuning", widget({ on_other = world.name })) ~= true, "on for another model: no entry")
  check(Views.condition("previewInflightTuning", widget({ [key] = "Deleted model" })) ~= true, "a reused file name: no entry")
end

-- --------------------------------------------------------------------------- guards
do
  local function plainConfig(extra)
    local s = { bank_gvar = 4, value_gvar = 5 }
    for k, v in pairs(extra or {}) do s[k] = v end
    return settings(s)
  end
  local function recordFile() return Backup.path(world.file) end
  local function readFile(path)
    local f = io.open(path, "r")
    local text = f:read("a")
    f:close()
    return text
  end
  local function writeFile(path, text)
    local f = io.open(path, "w")
    f:write(text)
    f:close()
  end

  -- Two jobs on one trim: nothing a write repairs, so nothing is replaced.
  world = freshWorld()
  for i = 1, 3 do world.mixes[10][i] = fullLine(i) end
  local twice = plainConfig({ trims = true })
  twice.trim_mode = Setup.TRIM_MODE_NAVIGATE
  twice.nav_trim, twice.adj_trim = 1, 1
  local refused = runPlan(Setup.radio(), twice)
  check(refused.ok ~= true and refused.refused == "trim_claimed_twice", "two jobs on one trim refuse the plan")
  check(Plan.newApplyJob(Setup.radio(), refused).done == true, "and nothing can be applied from it")

  -- A delay on a line that is otherwise the set-up's is a line to write, in the plan and in the check.
  world = freshWorld()
  local plain = plainConfig()
  runApply(Setup.radio(), (runPlan(Setup.radio(), plain)))
  check(runPlan(Setup.radio(), plain).nothing == true, "a line just written leaves nothing to write")
  world.mixes[plain.value_ch - 1][1].speedUp = 20
  check(runPlan(Setup.radio(), plain).nothing ~= true, "a slow-up is something to write")
  check(Setup.mixHasTiming({ delayDown = 1 }) and not Setup.mixHasTiming({ source = 1 }), "timing is read on its terms")

  -- A line replaced after the plan, with the count the same: it stops there and deletes nothing more.
  world = freshWorld()
  for i = 1, 3 do world.mixes[10][i] = fullLine(i) end
  local plan = runPlan(Setup.radio(), plain)
  saveRecord(plan)
  local replaced = fullLine(9)
  world.mixes[10][3] = replaced
  local job = runApply(Setup.radio(), plan)
  check(job.stopped == true, "a line changed since the plan stops the write")
  check(#world.mixes[10] == 3 and world.mixes[10][3].name == replaced.name, "and is not deleted")
  Backup.remove(world.file)

  -- A record that lost lines between intact first and last lines.
  world = freshWorld()
  for i = 1, 3 do world.mixes[10][i] = fullLine(i) end
  plan = runPlan(Setup.radio(), plain)
  saveRecord(plan)
  local function parsed()
    local parse = Backup.newParse(world.file)
    Backup.parseStep(parse)
    return parse.record
  end
  check(Backup.isWhole(parsed()), "a record as saved is whole")
  local text = readFile(recordFile())
  local function without(prefix, once)
    local kept, dropped = {}, false
    for line in string.gmatch(text, "([^\n]*)\n") do
      if string.sub(line, 1, #prefix) == prefix and not (once and dropped) then dropped = true
      else kept[#kept + 1] = line end
    end
    return table.concat(kept, "\n") .. "\n"
  end
  writeFile(recordFile(), without("L\t", true))
  check(not Backup.isWhole(parsed()), "one saved line missing is seen")
  writeFile(recordFile(), without("C\t"))
  check(not Backup.isWhole(parsed()), "a channel missing is seen")
  writeFile(recordFile(), without("H\t", true))
  check(not Backup.isWhole(parsed()), "a variable's other half missing is seen")
  writeFile(recordFile(), (string.gsub(text, "\nL\t([^\n]*)\t[^\t\n]*\n", "\nL\t%1\n", 1)))
  check(not Backup.isWhole(parsed()), "a line short of a field is seen")
  writeFile(recordFile(), (string.gsub(text, "\nL\t(%d+)\t(%d+)\t(%d+)\t(%-?%d+)\t", "\nL\t%1\t%2\t%3\t\t", 1)))
  check(not Backup.isWhole(parsed()), "a saved value emptied is seen by the count")
  writeFile(recordFile(), (string.gsub(text, "\nL\t(%d+)\t(%d+)\t(%d+)\t(%-?%d)(%d*)\t", "\nL\t%1\t%2\t%3\tx%5\t", 1)))
  check(not Backup.isWhole(parsed()), "a saved value that is no number is seen")
  writeFile(recordFile(), (string.gsub(text, "\nG\t(%d)", "\nG\tx", 1)))
  check(not Backup.isWhole(parsed()), "a variable's index that is no number is seen")
  writeFile(recordFile(), text)
  check(Backup.markState(world.file, "complete") and Backup.isWhole(parsed()), "marking a record keeps it whole")
  text = readFile(recordFile())
  writeFile(recordFile(), without("S\t", true))
  check(not Backup.isWhole(parsed()), "any line missing is seen by the count")
  writeFile(recordFile(), (string.gsub(text, "\nG\t(%d+)\t[^\n]*", "\nG\t%1\tOLD", 1)))
  check(not Backup.isWhole(parsed()), "a variable cut short is seen")
  writeFile(recordFile(), without("N\t"))
  check(Backup.isWhole(parsed()), "a record from before the count still reads")
  -- Such a record has only its own declarations to go by.
  local counted = text
  text = without("N\t")
  writeFile(recordFile(), without("L\t", true))
  check(not Backup.isWhole(parsed()), "without the count, one saved line missing is seen")
  writeFile(recordFile(), without("C\t"))
  check(not Backup.isWhole(parsed()), "without the count, a channel missing is seen")
  writeFile(recordFile(), without("H\t", true))
  check(not Backup.isWhole(parsed()), "without the count, a variable's other half missing is seen")
  writeFile(recordFile(), (string.gsub(text, "\nL\t([^\n]*)\t[^\t\n]*\n", "\nL\t%1\n", 1)))
  check(not Backup.isWhole(parsed()), "without the count, a line short of a field is seen")
  writeFile(recordFile(), (string.gsub(text, "\nG\t(%d+)\t[^\n]*", "\nG\t%1\tOLD", 1)))
  check(not Backup.isWhole(parsed()), "without the count, a variable cut short is seen")
  text = counted
  writeFile(recordFile(), text)

  -- A temporary copy that cannot be deleted is read as the record, so the record is not gone.
  writeFile(recordFile() .. ".tmp", text)
  local realDel = del
  del = function(path)
    if string.sub(path, -4) == ".tmp" then return 1 end
    return realDel(path)
  end
  check(Backup.remove(world.file) == false, "a temporary copy that stays is said")
  check(Backup.stateOf(world.file) ~= nil, "and the record is still there")
  del = realDel
  check(Backup.remove(world.file) == true and Backup.stateOf(world.file) == nil, "removed once the card lets it")

  -- The set-up does not write popup, so a restore leaves what the pilot has put there since.
  world = freshWorld()
  plan = runPlan(Setup.radio(), plain)
  saveRecord(plan)
  runApply(Setup.radio(), plan)
  world.gvars[plain.bank_gvar - 1].popup = true
  local restore = Backup.restorePlan(Setup.radio(), parsed())
  runApply(Setup.radio(), restore)
  check(world.gvars[plain.bank_gvar - 1].popup == true, "a later popup survives the restore")
  check(world.gvars[plain.bank_gvar - 1].min == -1024, "the variable's range is back")
  Backup.remove(world.file)
end

-- --------------------------------------------------------------------------- the link
do
  local Armed = assert(loadfile(sourceRoot .. "/rfsuite/lib/armed.lua"))()
  local realSession, realRssi = rfsuite.session, getRSSI
  rfsuite.session = { isConnected = false }
  getRSSI = function() return 0 end
  check(Armed.linkUp() == false, "nothing on the link")
  getRSSI = function() return 40 end
  check(Armed.linkUp() == true, "a receiver answers")
  getRSSI = function() return 0 end
  rfsuite.session.isConnected = true
  check(Armed.linkUp() == true, "a flight controller is connected")
  rfsuite.session, getRSSI = realSession, realRssi
end

-- --------------------------------------------------------------------------- the page's job
do
  SMLSIZE, MIDSIZE, CENTER = 1, 2, 0
  COLOR_THEME_PRIMARY1, COLOR_THEME_SECONDARY1, COLOR_THEME_SECONDARY2 = 1, 2, 3
  lvgl = { UI_ELEMENT_HEIGHT = 32 }
  local armedNow, linkNow, armCount, saves = false, false, 0, 0
  local stubs = {
    ["lib/env.lua"] = { isWidget = function() return true end },
    ["lib/armed.lua"] = {
      isArmed = function() return armedNow end,
      linkUp = function() return linkNow end,
      changeCount = function() return armCount end
    },
    ["lib/model_name_store.lua"] = { pending = function() return "Own name" end }
  }
  local plain = rfsuite.require
  local cached = {}
  rfsuite.require = function(path)
    if stubs[path] then return stubs[path] end
    if not cached[path] then cached[path] = plain(path) end
    return cached[path]
  end
  loadScript = function(path)
    local relative = string.sub(path, #rfsuite.paths.core + 2)
    if stubs[relative] then return function() return stubs[relative] end end
    return loadfile(path)
  end
  switches = function() return function() return nil end, nil, 0 end
  getSwitchValue = function() return 0 end

  local Page = assert(loadfile(sourceRoot .. "/rfsuite/app/pages/settings/dashboard/inflight/page.lua"))()
  Page.getHeaderActions()

  local prefs, saveFails
  local ctx
  local function fresh()
    world = freshWorld()
    for i = 1, 3 do world.mixes[10][i] = fullLine(i) end
    for i = 1, 4 do world.mixes[11][i] = fullLine(i + 3) end
    prefs, saveFails, armedNow, linkNow, armCount, saves = { general = {}, inflight = {} }, false, false, false, 0, 0
    ctx = { preferences = prefs, children = {}, x = 0, y = 62, w = 800, h = 418, i18n = nil,
      requestRebuild = function() end,
      savePreferences = function() saves = saves + 1; return not saveFails end }
    Backup.remove(world.file)
  end
  local function build()
    ctx.children = {}
    Page.build(ctx)
  end
  local function pass(n)
    for _ = 1, n or 1 do Page.wakeup(ctx); Page.wakeup(ctx) end
    build()
  end
  local function find(text)
    for _, node in ipairs(ctx.children) do
      if node.type == "button" and node.text == text then return node end
    end
    return nil
  end
  local function press(text)
    local node = find(text)
    check(node ~= nil, "the button " .. text .. " is there")
    node.press()
    build()
  end
  local function labels()
    local out = {}
    for _, node in ipairs(ctx.children) do
      if node.type == "label" and type(node.text) == "string" then out[#out + 1] = node.text end
    end
    return table.concat(out, " | ")
  end
  local function open()
    Page.onReload(ctx)
    build()
    pass(40)
  end
  local function until_button(text)
    for _ = 1, 200 do
      if find(text) then return true end
      pass(1)
    end
    return false
  end
  local key = Setup.modelOnKey("model7.yml")

  -- A set-up: the question, the write, the switch on, the restore on offer, the name the model has.
  fresh()
  open()
  check(string.find(labels(), "Own name", 1, true) ~= nil, "the line names the model's own name")
  check(find("Restore previous setup") == nil, "no restore without a record")
  press("Set up radio")
  check(until_button("Set up"), "the question comes up")
  check(string.find(labels(), "CH11 3 lines", 1, true) ~= nil, "the question counts the lines")
  check(#world.mixes[10] == 3, "nothing is written before the answer")
  press("Set up")
  check(Backup.stateOf(world.file) == nil or Backup.stateOf(world.file) == "partial", "no complete record yet")
  check(until_button("Close"), "the result comes up")
  check(#world.mixes[10] == 1 and Backup.stateOf(world.file) == "complete", "written, record complete")
  check(prefs.inflight[key] == nil and prefs.inflight.enabled ~= true, "the set-up turns nothing on")
  check(saves == 1 and prefs.inflight.bank_ch == 11, "and saves the page's values")
  check(string.find(labels(), "switch on this page", 1, true) ~= nil, "the result says what is next")
  press("Close")
  pass(40)
  check(find("Restore previous setup") ~= nil, "the restore is on offer")

  -- The switch: greyed until the check passes, on for this model alone, stored by the page's save.
  local function theSwitch()
    local seen = false
    for _, node in ipairs(ctx.children) do
      if node.type == "label" and node.text == "In-flight tuning on this radio model" then seen = true
      elseif seen and node.type == "toggle" then return node end
    end
  end
  check(theSwitch() ~= nil, "the switch is drawn")
  theSwitch().set(true)
  Page.onSave(ctx)
  check(prefs.inflight[key] == "Own name", "the switch stores this model's key with its own name")
  check(prefs.inflight.on_other == nil, "and no other model's")
  theSwitch().set(false)
  Page.onSave(ctx)
  check(prefs.inflight[key] == nil, "off removes it")
  theSwitch().set(true)
  Page.onSave(ctx)

  -- Nothing left to write: the button says so and still leaves the switch as it is.
  open()
  press("Set up radio")
  check(until_button("Close"), "nothing to write")
  check(string.find(labels(), "nothing to write", 1, true) ~= nil, "says so")
  check(prefs.inflight[key] == "Own name", "the switch stays on")
  press("Close")

  -- The restore: marked partial before its first write, cut off, offered again, and it switches off.
  pass(40)
  press("Restore previous setup")
  check(until_button("Restore"), "the restore asks")
  press("Restore")
  for _ = 1, 10 do
    if Backup.stateOf(world.file) == "partial" then break end
    Page.wakeup(ctx)
  end
  check(Backup.stateOf(world.file) == "partial" and #world.mixes[10] == 1, "a restore marks the record before it writes")
  Page.onClose()
  Page.getHeaderActions()
  open()
  check(find("Restore previous setup") ~= nil, "a restore cut off is offered again")
  press("Set up radio")
  check(until_button("Close"), "a set-up over it is refused")
  check(string.find(labels(), "cut off", 1, true) ~= nil, "and says why")
  press("Close")
  pass(40)
  press("Restore previous setup")
  check(until_button("Restore"), "asks again")
  press("Restore")
  check(until_button("Close"), "restored")
  check(Backup.stateOf(world.file) == nil and #world.mixes[10] == 3 and #world.mixes[11] == 4, "the lines are back")
  check(prefs.inflight[key] == nil, "the restore turns it off for this model")
  press("Close")

  -- Armed: refused at the press, and an arm and disarm during the write stops it.
  fresh()
  open()
  armedNow = true
  press("Set up radio")
  check(string.find(labels(), "armed", 1, true) ~= nil, "refused while armed")
  check(Backup.stateOf(world.file) == nil, "no record")
  press("Close")
  armedNow = false
  press("Set up radio")
  check(until_button("Set up"), "asks")
  press("Set up")
  for _ = 1, 50 do
    if Backup.stateOf(world.file) ~= nil then break end
    Page.wakeup(ctx); Page.wakeup(ctx)
  end
  build()
  check(Backup.stateOf(world.file) == "partial", "the record is there before the write")
  armCount = armCount + 2
  check(until_button("Close"), "stops")
  check(string.find(labels(), "Stopped", 1, true) ~= nil, "says it stopped")
  check(Backup.stateOf(world.file) == "partial", "the record stays partial")
  check(prefs.inflight[key] == nil, "a stopped set-up does not turn it on")
  press("Close")

  -- A switch that cannot be saved is said, not hidden.
  fresh()
  saveFails = true
  open()
  press("Set up radio")
  check(until_button("Set up"), "asks")
  press("Set up")
  check(until_button("Close"), "done")
  check(string.find(labels(), "could not be saved", 1, true) ~= nil, "a failed save of the switch is said")
  Page.onClose()
  Backup.remove(world.file)
  Page.getHeaderActions()

  local function readRecordFile()
    local f = io.open(Backup.path(world.file), "r")
    local text = f and f:read("a") or nil
    if f then f:close() end
    return text
  end
  local function setUp()
    open()
    press("Set up radio")
    check(until_button("Set up"), "asks")
    press("Set up")
    check(until_button("Close"), "done")
    press("Close")
  end

  -- Two jobs on one trim from the page: the button says so, and no line goes.
  fresh()
  prefs.inflight = { trims = true, trim_mode = Setup.TRIM_MODE_NAVIGATE, nav_trim = 1, adj_trim = 1 }
  open()
  press("Set up radio")
  check(until_button("Close"), "answers without asking")
  check(find("Set up") == nil and string.find(labels(), "two different trims", 1, true) ~= nil, "says which fault")
  check(#world.mixes[10] == 3 and #world.mixes[11] == 4, "no line goes")
  check(prefs.inflight.enabled ~= true, "and it does not turn tuning on")
  press("Close")
  Page.onClose()
  Page.getHeaderActions()

  -- An arm and disarm after the answer, before the record: the record of the last set-up stands.
  fresh()
  setUp()
  local first = readRecordFile()
  world.mixes[11][2] = fullLine(8)
  press("Set up radio")
  check(until_button("Set up"), "asks again")
  press("Set up")
  armCount = armCount + 2
  check(until_button("Close"), "stops")
  check(string.find(labels(), "Nothing was changed", 1, true) ~= nil, "says nothing changed")
  check(readRecordFile() == first, "the last set-up's record is not replaced")
  check(#world.mixes[11] == 2, "nothing written")
  press("Close")
  Page.onClose()
  Page.getHeaderActions()

  -- A restore whose record cannot be removed: said, and neither offered again nor in the next set-up's way.
  fresh()
  setUp()
  check(until_button("Restore previous setup"), "restore on offer")
  press("Restore previous setup")
  check(until_button("Restore"), "asks")
  press("Restore")
  -- The record is marked `partial` while the lines are still the set-up's; the card refuses once they are back.
  local realDel, refused = del, false
  del = function(path)
    if not refused and #world.mixes[10] == 3 and #world.mixes[11] == 4 then
      refused = true
      return 1
    end
    return realDel(path)
  end
  check(until_button("Close"), "restored")
  check(refused, "the card refused the removal")
  del = realDel
  check(string.find(labels(), "could not be deleted", 1, true) ~= nil, "a record left on the card is said")
  check(#world.mixes[10] == 3 and #world.mixes[11] == 4, "the lines are back")
  check(Backup.stateOf(world.file) ~= "partial", "and it no longer says cut off")
  press("Close")
  Page.onClose()
  Page.getHeaderActions()

  -- A finished set-up's record, the model changed while the page stood open: nothing restored.
  fresh()
  setUp()
  check(until_button("Restore previous setup"), "restore on offer")
  world.ls[63] = { func = 1, v1 = 1, v2 = 1, v3 = 0, ["and"] = 0, delay = 0, duration = 0, state = false, persistent = false }
  press("Restore previous setup")
  check(until_button("Close"), "answers without asking")
  check(string.find(labels(), "nothing was restored", 1, true) ~= nil, "says the model changed")
  check(world.ls[63].func == 1, "the changed switch stands")
  check(Backup.stateOf(world.file) ~= nil, "the record stays")
  press("Close")
  Page.onClose()
  Page.getHeaderActions()
  Backup.remove(world.file)

  -- A damaged record: nothing changes, it goes, and a set-up is possible again.
  fresh()
  setUp()
  check(until_button("Restore previous setup"), "restore on offer")
  local text = readRecordFile()
  local f = io.open(Backup.path(world.file), "w")
  f:write((string.gsub(text, "\nL\t[^\n]*", "", 1)))
  f:close()
  press("Restore previous setup")
  check(until_button("Close"), "answers without asking")
  check(string.find(labels(), "damaged", 1, true) ~= nil, "says it is damaged")
  check(#world.mixes[10] == 1 and #world.mixes[11] == 1, "nothing was changed")
  check(Backup.stateOf(world.file) == nil, "the record is gone")
  press("Close")
  Page.onClose()
  Page.getHeaderActions()

  -- What a whole page wakeup spends on the model the walk costs most on, the page's own stages included.
  do
    worstCaseModel()
    prefs, saveFails, armedNow, linkNow, armCount, saves = { general = {}, inflight = { trims = true } }, false, false, false, 0, 0
    ctx.preferences = prefs
    Backup.remove(world.file)
    open()
    local function worstWakeup(done)
      local worst = 0
      for _ = 1, 400 do
        if done() then break end
        for _ = 1, 2 do
          local count = 0
          debug.sethook(function() count = count + 1 end, "", 1)
          Page.wakeup(ctx)
          debug.sethook()
          if count > worst then worst = count end
        end
        build()
      end
      return worst
    end
    press("Set up radio")
    local planWorst = worstWakeup(function() return find("Set up") ~= nil end)
    check(find("Set up") ~= nil, "the plan asks on the worst-case model: " .. labels())
    press("Set up")
    local writeWorst = worstWakeup(function() return find("Close") ~= nil end)
    press("Close")
    check(until_button("Restore previous setup"), "restore on offer")
    press("Restore previous setup")
    local readWorst = worstWakeup(function() return find("Restore") ~= nil end)
    check(find("Restore") ~= nil, "the restore asks")
    press("Restore")
    local restoreWorst = worstWakeup(function() return find("Close") ~= nil end)
    print(string.format("page wakeup, worst-case model: plan %d, write %d, restore read %d, restore write %d instructions",
      planWorst, writeWorst, readWorst, restoreWorst))
    local PAGE_LIMIT = 8000
    check(planWorst <= PAGE_LIMIT and writeWorst <= PAGE_LIMIT, "a set-up's page wakeup stays under the limit")
    check(readWorst <= PAGE_LIMIT and restoreWorst <= PAGE_LIMIT, "a restore's page wakeup stays under the limit")
    press("Close")
    Page.onClose()
    Page.getHeaderActions()
    Backup.remove(world.file)
  end

  -- With anything on the link neither job starts, and one running stops.
  fresh()
  open()
  linkNow = true
  press("Set up radio")
  check(string.find(labels(), "flight controller is connected", 1, true) ~= nil, "a set-up is refused on a link")
  check(#world.mixes[10] == 3 and Backup.stateOf(world.file) == nil, "nothing written, no record")
  press("Close")
  linkNow = false
  press("Set up radio")
  check(until_button("Set up"), "asks with the link down")
  press("Set up")
  for _ = 1, 50 do
    if Backup.stateOf(world.file) ~= nil then break end
    Page.wakeup(ctx); Page.wakeup(ctx)
  end
  linkNow = true
  check(until_button("Close"), "stops")
  check(string.find(labels(), "Stopped", 1, true) ~= nil, "a link coming up stops the write")
  check(#world.mixes[10] > 0, "with lines left")
  press("Close")
  check(find("Restore previous setup") ~= nil or until_button("Restore previous setup"), "restore on offer")
  press("Restore previous setup")
  check(string.find(labels(), "flight controller is connected", 1, true) ~= nil, "a restore is refused on a link")
  press("Close")
  linkNow = false
  Page.onClose()
  Page.getHeaderActions()
  Backup.remove(world.file)

  -- The model changed while the restore's question stood: nothing restored.
  fresh()
  setUp()
  check(until_button("Restore previous setup"), "restore on offer")
  press("Restore previous setup")
  check(until_button("Restore"), "asks")
  world.ls[63] = { func = 1, v1 = 1, v2 = 1, v3 = 0, ["and"] = 0, delay = 0, duration = 0, state = false, persistent = false }
  press("Restore")
  check(until_button("Close"), "answers")
  check(string.find(labels(), "nothing was restored", 1, true) ~= nil, "says the model changed")
  check(#world.mixes[10] == 1 and world.ls[63].func == 1, "nothing was touched")
  press("Close")
  Page.onClose()
  Page.getHeaderActions()
  Backup.remove(world.file)

  -- A damaged record the card will not let go is named, not called discarded.
  fresh()
  setUp()
  check(until_button("Restore previous setup"), "restore on offer")
  do
    local damaged = readRecordFile()
    local f = io.open(Backup.path(world.file), "w")
    f:write((string.gsub(damaged, "\nL\t[^\n]*", "", 1)))
    f:close()
    local realDel = del
    del = function() return 1 end
    press("Restore previous setup")
    check(until_button("Close"), "answers")
    del = realDel
    check(string.find(labels(), "could not be deleted", 1, true) ~= nil, "says it could not be deleted")
    check(#world.mixes[10] == 1, "nothing changed")
  end
  press("Close")
  Page.onClose()
  Page.getHeaderActions()
  Backup.remove(world.file)

  -- A slow-up on the value line: the check says so, and the button can answer it.
  fresh()
  setUp()
  open()
  check(string.find(labels(), "Mixer line missing or wrong", 1, true) == nil, "a line just written passes the check")
  world.mixes[11][1].speedUp = 20
  open()
  check(string.find(labels(), "Mixer line missing or wrong", 1, true) ~= nil, "a line with a slow-up does not")
  Page.onClose()
  Page.getHeaderActions()
  Backup.remove(world.file)

  -- The trims switch changes what the check claims, so the verdict is read again.
  fresh()
  setUp()
  prefs.inflight.trim_mode = Setup.TRIM_MODE_NAVIGATE
  prefs.inflight.nav_trim, prefs.inflight.adj_trim = 1, 1
  open()
  check(string.find(labels(), "two different trims", 1, true) == nil, "with the trims off there is no such fault")
  local function nodeAfter(labelText, wanted)
    local seen = false
    for _, node in ipairs(ctx.children) do
      if node.type == "label" and node.text == labelText then seen = true
      elseif seen and wanted(node) then return node end
    end
    return nil
  end
  local header = nodeAfter("Rows and trims", function(node) return node.type == "button" end)
  check(header ~= nil, "the trims section has a header")
  header.press()
  build()
  pass(40)
  local trimsSwitch = nodeAfter("Drive rows from the trims", function(node) return node.type == "toggle" end)
  check(trimsSwitch ~= nil, "the trims switch is drawn")
  trimsSwitch.set(true)
  pass(40)
  check(string.find(labels(), "two different trims", 1, true) ~= nil, "switched on, the verdict names the fault")
  Page.onClose()
  Backup.remove(world.file)
end

os.execute("rm -rf " .. tmpDir)
io.read = realRead
print(string.format("radio set-up: %d checks passed", checked))
