-- Run from the repository root: lua5.3 bin/msp/verify_uid_task_prefs_lazy.lua
-- Drive the real onconnect UID task, the real lib/model_preferences.lua and the real MSP runtime
-- on the stubbed card, and count what the task reads through loadScript.
--
-- On the ordinary connect the MSP runtime has already put the model preferences into the session.
-- The task then has no use for lib/model_preferences.lua, so a wakeup does not load it and leaves
-- the object in the session alone. Where the preferences are missing the task still loads the
-- module and resolves them, and every path still ends with the resolved flag and the completion
-- it had: preferences present, loaded, not loadable, and no UID once the runtime's read settled.
local Stubs = assert(loadfile("bin/accounting/stubs/edgetx.lua"))()
Stubs.install(".")
Stubs.reset()
Stubs.clearCard()

local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local CORE = _G.rfsuite.paths.core
local MODULE_PATH = CORE .. "/lib/model_preferences.lua"
local TASK_PATH = CORE .. "/tasks/events/onconnect/tasks/uid.lua"
local MCU_ID = "2b0022000951333438353100"

-- What the task reads, counted at the call the radio makes. `refuseModule` answers as a card
-- whose copy of the module will not load.
local moduleLoads, refuseModule = 0, false
local stubLoadScript = _G.loadScript
_G.loadScript = function(path, mode)
  if path == MODULE_PATH then
    moduleLoads = moduleLoads + 1
    if refuseModule then return nil end
  end
  return stubLoadScript(path, mode)
end

-- A fresh instance per connect, as the runner gives it: it drops the module on completion.
local function newTask()
  moduleLoads = 0
  refuseModule = false
  return assert(stubLoadScript(TASK_PATH, "t"))()
end

-- The preferences file of this board, written through the suite's own writer.
local Preferences = _G.rfsuite.require("lib/model_preferences.lua")
assert(Preferences.saveByMcuId(MCU_ID, { dashboard = { overrides = true, model_theme_preflight = "system/urban" } }),
  "model store write")
local _, storedFile = Preferences.loadByMcuId(MCU_ID, true)
assert(type(storedFile) == "string", "model store read")

local function expectResolved(task, label)
  equal(_G.rfsuite.session.modelPreferencesResolved, true, label .. ": resolved flag")
  equal(task.isComplete(), true, label .. ": task complete")
end

-- The runtime already published the preferences: the task only confirms them. The flag starts as
-- the previous link's, which the task must clear on the way through.
do
  local label = "preferences present"
  local held = { dashboard = {} }
  local task = newTask()
  _G.rfsuite.session = { mcu_id = MCU_ID, modelPreferences = held, modelPreferencesFile = "held.ini",
    modelPreferencesResolved = false }
  task.wakeup()
  equal(moduleLoads, 0, label .. ": lib/model_preferences.lua loads")
  equal(_G.rfsuite.session.modelPreferences, held, label .. ": the same preferences object")
  equal(_G.rfsuite.session.modelPreferencesFile, "held.ini", label .. ": the same preferences file")
  expectResolved(task, label)

  local loadsSoFar = moduleLoads
  _G.rfsuite.session.modelPreferencesResolved = "untouched"
  task.wakeup()
  equal(_G.rfsuite.session.modelPreferencesResolved, "untouched", label .. ": a completed task does nothing")
  equal(moduleLoads, loadsSoFar, label .. ": no load on the wakeup after completion")
end

-- The UID is known and the preferences are not: the task loads the module and reads the store.
do
  local label = "preferences missing"
  local task = newTask()
  _G.rfsuite.session = { mcu_id = MCU_ID }
  task.wakeup()
  equal(moduleLoads, 1, label .. ": lib/model_preferences.lua loads")
  local prefs = _G.rfsuite.session.modelPreferences
  equal(type(prefs), "table", label .. ": preferences resolved")
  equal(prefs and prefs.dashboard and prefs.dashboard.model_theme_preflight, "system/urban",
    label .. ": read from the board's file")
  equal(_G.rfsuite.session.modelPreferencesFile, storedFile, label .. ": modelPreferencesFile")
  expectResolved(task, label)

  -- The same instance after reset(), which clears the session's half: the module it holds is used.
  task.reset()
  equal(_G.rfsuite.session.modelPreferences, nil, label .. ": reset clears the preferences")
  equal(task.isComplete(), false, label .. ": reset reopens the task")
  _G.rfsuite.session.mcu_id = MCU_ID
  task.wakeup()
  equal(moduleLoads, 1, label .. ": no second load after reset")
  equal(type(_G.rfsuite.session.modelPreferences), "table", label .. ": resolved again after reset")
  expectResolved(task, label .. " after reset")
end

-- The module will not load: the connect sequence must not wait on it.
do
  local label = "module not loadable"
  local task = newTask()
  refuseModule = true
  _G.rfsuite.session = { mcu_id = MCU_ID }
  task.wakeup()
  equal(moduleLoads, 1, label .. ": the load was tried")
  equal(_G.rfsuite.session.modelPreferences, nil, label .. ": no preferences")
  expectResolved(task, label)
end

-- No UID: the task waits for the runtime's read and loads nothing of its own.
do
  local Runtime = _G.rfsuite.require("tasks/msp/runtime.lua")
  local label = "no UID"
  for _, id in ipairs({ false, "" }) do
    local task = newTask()
    _G.rfsuite.session = { mcu_id = id or nil, modelPreferencesResolved = true }
    Runtime.getState().uidReadSettled = false
    task.wakeup()
    equal(_G.rfsuite.session.modelPreferencesResolved, nil, label .. ": not resolved while the read is open")
    equal(task.isComplete(), false, label .. ": waiting while the read is open")
    Runtime.getState().uidReadSettled = true
    task.wakeup()
    equal(moduleLoads, 0, label .. ": lib/model_preferences.lua loads")
    equal(_G.rfsuite.session.modelPreferences, nil, label .. ": no preferences")
    expectResolved(task, label)
  end
end

Stubs.releaseCard()
if failures > 0 then
  print(string.format("%d of %d UID task checks failed", failures, checks))
  os.exit(1)
end
print(string.format("%d UID task checks, 0 failures", checks))
