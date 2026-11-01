-- Run from the repository root: lua5.3 bin/core/verify_require_nil_module.lua
-- Drive the real module loader (lib/require.lua) with a module whose chunk returns nothing, and
-- two real callers that take a falsy result as "not available": the battery_config event task
-- (MSP runtime) and lib/profile.lua (sensors). A table module beside them is the control that the
-- cache still works.
local checks, failures = 0, 0
local function check(ok, label)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label)
  end
end

local function upvalue(fn, wanted)
  local index = 1
  while true do
    local name, value = debug.getupvalue(fn, index)
    if not name then error("missing upvalue: " .. wanted) end
    if name == wanted then return value end
    index = index + 1
  end
end

local core = "src/rfsuite/"
local radio = "/SCRIPTS/TOOLS/rfsuite-core/"

-- Paths answered by a stand-in chunk instead of the file on disk, and how often each ran.
local standIns = {}
local runs = {}

local function standIn(relative, body)
  standIns[relative] = body
  runs[relative] = 0
end

loadScript = function(path)
  assert(string.sub(path, 1, #radio) == radio, "unexpected module path: " .. tostring(path))
  local relative = string.sub(path, #radio + 1)
  local body = standIns[relative]
  if body then
    return function()
      runs[relative] = runs[relative] + 1
      return body()
    end
  end
  return loadfile(core .. relative)
end

local function freshLoader()
  _G.rfsuite = { session = {} }
  assert(loadfile(core .. "lib/require.lua"))()
  return _G.rfsuite.require
end

-- 1. The loader itself.
do
  standIn("test/returns_nothing.lua", function() end)
  standIn("test/returns_table.lua", function() return { marker = true } end)
  local require = freshLoader()

  local first = require("test/returns_nothing.lua")
  check(not first, "a module that returns nothing hands out a falsy value (got " .. tostring(first) .. ")")
  local second = require("test/returns_nothing.lua")
  check(not second, "a second load of that module is still falsy (got " .. tostring(second) .. ")")
  check(rawget(_G.rfsuite.modules, radio .. "test/returns_nothing.lua") ~= true,
    "the module cache holds no true for a module that returned nothing")

  local tableModule = require("test/returns_table.lua")
  check(type(tableModule) == "table" and tableModule.marker == true, "a table module is handed out")
  check(require("test/returns_table.lua") == tableModule, "a table module is cached: the second load is the same table")
  check(runs["test/returns_table.lua"] == 1, "a table module runs once (ran " .. tostring(runs["test/returns_table.lua"]) .. ")")

  local missing = require("test/not_there.lua")
  check(missing == nil and _G.rfsuite.modules[radio .. "test/not_there.lua"] == nil,
    "a module that does not load is nil and not cached")
end

-- 2. The battery_config event task: an MSP runtime that loads as nothing is "no runtime", not an
-- error, and the task finishes instead of indexing the value.
do
  standIn("tasks/msp/runtime.lua", function() end)
  standIn("lib/log.lua", function()
    return { emit = function() end, emitf = function() end }
  end)
  freshLoader()

  local task = assert(loadfile(core .. "tasks/events/common/battery_config.lua"))()
  local ok, err = pcall(task.wakeup, {})
  check(ok, "battery_config wakeup with a runtime that loaded as nothing raises no error: " .. tostring(err))
  check(upvalue(task.wakeup, "done") == true, "battery_config finishes on the no-runtime path")
  check(upvalue(task.wakeup, "requestSent") == false, "battery_config sends no request without a runtime")
  local ok2, err2 = pcall(task.wakeup, {})
  check(ok2, "a second battery_config wakeup raises no error: " .. tostring(err2))

  -- Control: the same task with a runtime that is a table does reach the queue.
  local queued = {}
  standIn("tasks/msp/runtime.lua", function()
    return {
      getState = function()
        return { queue = { add = function(_, message) queued[#queued + 1] = message end } }
      end
    }
  end)
  freshLoader()
  local controlTask = assert(loadfile(core .. "tasks/events/common/battery_config.lua"))()
  local ok3, err3 = pcall(controlTask.wakeup, {})
  check(ok3, "control: battery_config wakeup with a table runtime raises no error: " .. tostring(err3))
  check(#queued == 1, "control: battery_config queues its read through a table runtime (queued " .. #queued .. ")")
end

-- 3. lib/profile.lua: sensors that load as nothing are "no live reading", and the profile falls
-- back to the session.
do
  standIn("lib/sensors.lua", function() end)
  freshLoader()
  _G.rfsuite.session.activeProfile = 2

  local Profile = assert(loadfile(core .. "lib/profile.lua"))()
  local ok, live = pcall(Profile.getLive, "pid")
  check(ok, "profile getLive with sensors that loaded as nothing raises no error: " .. tostring(live))
  check(ok and live == nil, "profile getLive has no live reading without sensors")
  local ok2, active = pcall(Profile.getActivePidProfile, 1)
  check(ok2 and active == 3, "profile falls back to the session's profile (got " .. tostring(active) .. ")")

  -- Control: sensors that are a table do give the live reading.
  standIn("lib/sensors.lua", function()
    return { getValue = function(name) if name == "pid_profile" then return 5 end end }
  end)
  freshLoader()
  local ControlProfile = assert(loadfile(core .. "lib/profile.lua"))()
  local ok3, live3 = pcall(ControlProfile.getLive, "pid")
  check(ok3 and live3 == 5, "control: profile getLive reads a table sensors module (got " .. tostring(live3) .. ")")
end

print(string.format("require nil module: %d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
