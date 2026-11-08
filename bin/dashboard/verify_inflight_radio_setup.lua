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
  -- The mismatch path with the real name store and no record on the card, first in its state: what a
  -- preferences reload costs while a connected craft's name stands in the model's place.
  world.name = "Craft name"
  local counted = 0
  debug.sethook(function() counted = counted + 1 end, "", 1)
  local off = settled({ [key] = ownName }).inflight.enabled
  debug.sethook()
  world.name = ownName
  check(off == false, "with no record in the name store a different name stays off")
  print(string.format("settle with a name mismatch, real name store, first load: %d instructions", counted))
  -- And with the record there, as model_name_sync leaves it, read from the card in a fresh state.
  local NameStore = plainRequire("lib/model_name_store.lua")
  check(NameStore.remember(ownName) ~= false, "the name store takes the record")
  NameStore.invalidate()
  world.name = "Craft name"
  counted = 0
  debug.sethook(function() counted = counted + 1 end, "", 1)
  local on = settled({ [key] = ownName }).inflight.enabled
  debug.sethook()
  check(on == true, "with the record, the model's own name keeps it on under the craft's name")
  print(string.format("settle with the craft's name standing in, record read from the card: %d instructions", counted))
  NameStore.forget()
  world.name = ownName
  local Views = assert(loadfile(sourceRoot .. "/rfsuite/widgets/dashboard/views.lua"))()
  local function widget(section) return { state = {}, preferences = settled(section) } end
  check(Views.condition("previewInflightTuning", widget({ [key] = world.name })) == true, "the entry is there")
  check(Views.condition("previewInflightTuning", widget({})) ~= true, "never switched on: no entry")
  check(Views.condition("previewInflightTuning", widget({ on_other = world.name })) ~= true, "on for another model: no entry")
  check(Views.condition("previewInflightTuning", widget({ [key] = "Deleted model" })) ~= true, "a reused file name: no entry")
end

-- --------------------------------------------------------------------------- the page's job
do
  SMLSIZE, MIDSIZE, CENTER = 1, 2, 0
  COLOR_THEME_PRIMARY1, COLOR_THEME_SECONDARY1, COLOR_THEME_SECONDARY2 = 1, 2, 3
  lvgl = { UI_ELEMENT_HEIGHT = 32 }
  local armedNow, armCount, saves = false, 0, 0
  local stubs = {
    ["lib/env.lua"] = { isWidget = function() return true end },
    ["lib/armed.lua"] = { isArmed = function() return armedNow end, changeCount = function() return armCount end },
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
    prefs, saveFails, armedNow, armCount, saves = { general = {}, inflight = {} }, false, false, 0, 0
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
  Page.wakeup(ctx); Page.wakeup(ctx)
  check(Backup.stateOf(world.file) == "partial", "a restore marks the record before it writes")
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
  Page.wakeup(ctx); Page.wakeup(ctx); build()
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
end

os.execute("rm -rf " .. tmpDir)
io.read = realRead
print(string.format("radio set-up: %d checks passed", checked))
