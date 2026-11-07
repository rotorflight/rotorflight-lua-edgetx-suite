-- An ESC that reports no current limit clears the figure its own family stored, and only that one.
-- The real limit module and the real AM32, Scorpion and YGE pages run on the APIs' own parsers; only
-- the file write is counted instead of done. Run from the repository root with lua5.3.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local base = "app/pages/setup/esc_motors/esc_tools/"
local limitPath = base .. "esc_current_limit.lua"
local writes, saveAnswer = 0, true
local power = {
  save = function()
    writes = writes + 1
    if saveAnswer then return true end
    return false, "io"
  end
}

_G.rfsuite = { palette = {}, session = {} }
_G.rfsuite.paths = dofile("src/rfsuite/lib/paths.lua")

local function newSession(figure, origin)
  writes = 0
  local session = {
    mcu_id = "test",
    -- Known already, so the AM32 page asks for no motor count.
    esc4WayMotorCount = 1,
    modelPreferences = { battery = { esc_current_limit = figure, esc_current_limit_origin = origin, kept = 7 } }
  }
  _G.rfsuite.session = session
  return session
end

local function stored(session)
  local battery = session.modelPreferences.battery
  return tostring(battery.esc_current_limit) .. "/" .. tostring(battery.esc_current_limit_origin)
end

local function modulesFor(queue, extra)
  local modules = {
    ["app/pages/settings/common.lua"] = {
      pageT = function() return function(_, _, fallback) return fallback end end,
      resetPageState = function(ui) ui.loaded = false; ui.dirty = false; ui.runtime = nil end
    },
    ["ui/controls.lua"] = {},
    ["ui/loading_overlay.lua"] = {},
    ["ui/confirm_dialog.lua"] = {},
    ["tasks/msp/runtime.lua"] = { getState = function() return { queue = queue } end },
    ["app/pages/setup/power/model_preferences.lua"] = power,
    ["lib/log.lua"] = {},
  }
  for k, v in pairs(extra) do modules[k] = v end
  return modules
end

local function useModules(modules)
  function loadScript(path)
    local relative = string.match(path, "/SCRIPTS/RFSUITE/core/(.+)$")
    -- The real module. The four-way connect is a sequence with its own timers, and without its API
    -- module the AM32 page reads the block straight away.
    if relative == limitPath then return loadfile("src/rfsuite/" .. relative) end
    if relative == "tasks/msp/api/4wif_esc_fwd_prog.lua" then return nil end
    assert(modules[relative], "unexpected module: " .. tostring(path))
    return function() return modules[relative] end
  end
end

-- The module on its own.
useModules(modulesFor({}, {}))
local Limit = assert(loadfile("src/rfsuite/" .. limitPath))()

local session = newSession(60, "am32")
local ok, why = Limit.forget(session, "am32")
equal(ok, true, "forget: answers true"); equal(why, "cleared", "forget: says cleared")
equal(stored(session), "nil/nil", "forget: the family's own figure and origin go")
equal(session.modelPreferences.battery.kept, 7, "forget: the rest of the section stays")
equal(writes, 1, "forget: written once")
ok, why = Limit.forget(session, "am32")
equal(why, "unchanged", "forget: a second visit has nothing to do")
equal(writes, 1, "forget: a second visit writes nothing")

for _, other in ipairs({ { "hand" }, { "scorpion" }, { "yge" }, {} }) do
  session = newSession(60, other[1])
  ok, why = Limit.forget(session, "am32")
  local name = tostring(other[1])
  equal(why, "kept", "forget: says kept for origin " .. name)
  equal(stored(session), "60/" .. name, "forget: keeps a figure of origin " .. name)
  equal(writes, 0, "forget: writes nothing for origin " .. name)
end

session = newSession(60, "am32")
saveAnswer = false
ok, why = Limit.forget(session, "am32")
saveAnswer = true
equal(ok, false, "forget: a failed write answers false"); equal(why, "io", "forget: passes the reason on")
equal(stored(session), "60/am32", "forget: a failed write puts the figure back")

session = newSession(60, "am32")
equal(select(2, Limit.forget(session, "hand")), "unknown_origin", "forget: hand is no family")
equal(select(2, Limit.forget(session, nil)), "unknown_origin", "forget: no origin is no family")
equal(stored(session), "60/am32", "forget: a refused origin touches nothing")
equal(select(2, Limit.forget(nil, "am32")), "no_session", "forget: no session")
equal(select(2, Limit.forget({}, "am32")), "no_model_preferences", "forget: no store")
session = { modelPreferences = {} }
equal(select(2, Limit.forget(session, "am32")), "unchanged", "forget: no battery section")
equal(session.modelPreferences.battery, nil, "forget: creates no battery section")

-- The pages.
local function fieldPosition(api, name)
  local sizes = { U8 = 1, U16 = 2, U32 = 4 }
  local position = 1
  for _, field in ipairs(api.fields) do
    if field[1] == name then return position end
    position = position + assert(sizes[field[2]], field[2])
  end
  error("no field " .. name)
end

local families = {
  am32 = { dir = "am32", api = "am32", origin = "am32" },
  scorpion = { dir = "scorp", api = "scorpion", origin = "scorpion", field = "max_current" },
  yge = { dir = "yge", api = "yge", origin = "yge", field = "current_limit" },
}

-- Opens the family's page on a session holding the figure, and answers its read with `reply`.
local function read(family, figure, origin, change)
  local spec = families[family]
  local apiPath = "tasks/msp/api/esc_parameters_" .. spec.api .. ".lua"
  local api = assert(loadfile("src/rfsuite/" .. apiPath))()
  local queue = { entries = {} }
  function queue:add(entry) self.entries[#self.entries + 1] = entry end
  useModules(modulesFor(queue, {
    [apiPath] = api,
    [base .. "escmfg/" .. spec.dir .. "/init.lua"] = {},
  }))
  local s = newSession(figure, origin)
  local page = assert(loadfile("src/rfsuite/" .. base .. "escmfg/" .. spec.dir .. "/page.lua"))()
  page.wakeup({ requestRebuild = function() end })
  local entry = queue.entries[#queue.entries]
  equal(entry and entry.command, api.command, family .. ": the page asks for the block")
  local reply = {}
  for i, value in ipairs(api.simulatorResponse) do reply[i] = value end
  change(reply, api)
  entry:processReply(reply)
  return s, entry
end

local function am32Byte(value)
  return function(reply) reply[47] = value end
end

local function amps(field, value)
  return function(reply, api)
    local at = fieldPosition(api, field)
    reply[at] = value % 256
    reply[at + 1] = value // 256
  end
end

for _, byte in ipairs({ 0, 101, 102, 255 }) do
  local label = "am32 byte " .. byte .. ": "
  session = read("am32", 60, "am32", am32Byte(byte))
  equal(stored(session), "nil/nil", label .. "clears AM32's figure")
  equal(writes, 1, label .. "written once")
  session = read("am32", nil, nil, am32Byte(byte))
  equal(stored(session), "nil/nil", label .. "stores nothing")
  equal(writes, 0, label .. "nothing on file, nothing written")
  session = read("am32", 60, "hand", am32Byte(byte))
  equal(stored(session), "60/hand", label .. "leaves a figure by hand")
  equal(writes, 0, label .. "by hand, nothing written")
  session = read("am32", 60, "scorpion", am32Byte(byte))
  equal(stored(session), "60/scorpion", label .. "leaves another family's figure")
  session = read("am32", 60, nil, am32Byte(byte))
  equal(stored(session), "60/nil", label .. "leaves a figure with no origin")
end

session = read("am32", 60, "am32", am32Byte(100))
equal(stored(session), "200/am32", "am32 byte 100: the highest working limit is stored")
session = read("am32", 60, "am32", am32Byte(1))
equal(stored(session), "2/am32", "am32 byte 1: the lowest working limit is stored")
session = read("am32", 60, "hand", am32Byte(40))
equal(stored(session), "80/am32", "am32 byte 40: a real limit still replaces a figure by hand")
read("am32", 80, "am32", am32Byte(40))
equal(writes, 0, "am32 byte 40: the same limit writes nothing")
session = read("am32", 60, "am32", function(reply) reply[1] = 0x53 end)
equal(stored(session), "60/am32", "am32: a block from another family says nothing")
session = read("am32", 60, "am32", function(reply) reply[47] = 0; for i = #reply, 49, -1 do reply[i] = nil end end)
equal(stored(session), "60/am32", "am32: a short block says nothing")

session = read("scorpion", 60, "scorpion", amps("max_current", 0))
equal(stored(session), "nil/nil", "scorpion 0: clears Scorpion's figure")
equal(writes, 1, "scorpion 0: written once")
session = read("scorpion", 60, "hand", amps("max_current", 0))
equal(stored(session), "60/hand", "scorpion 0: leaves a figure by hand")
session = read("scorpion", 60, "am32", amps("max_current", 0))
equal(stored(session), "60/am32", "scorpion 0: leaves another family's figure")
session = read("scorpion", 60, "scorpion", amps("max_current", 12000))
equal(stored(session), "120/scorpion", "scorpion 12000: 120 A is stored")
session = read("scorpion", 60, "scorpion", function(reply, api)
  for i = #reply, fieldPosition(api, "max_current"), -1 do reply[i] = nil end
end)
equal(stored(session), "60/scorpion", "scorpion: a block too short to carry the field says nothing")

session = read("yge", 60, "yge", amps("current_limit", 0))
equal(stored(session), "nil/nil", "yge 0 in a whole block: clears YGE's figure")
equal(writes, 1, "yge 0 in a whole block: written once")
session = read("yge", 60, "hand", amps("current_limit", 0))
equal(stored(session), "60/hand", "yge 0: leaves a figure by hand")
session = read("yge", 60, "yge", amps("current_limit", 12000))
equal(stored(session), "120/yge", "yge 12000: 120 A is stored")

-- A short reply reads the missing field as 0, and that is not the ESC saying 0.
session = read("yge", 60, "yge", function(reply, api)
  for i = #reply, fieldPosition(api, "current_limit"), -1 do reply[i] = nil end
end)
equal(stored(session), "60/yge", "yge: a block that stops before the field clears nothing")
equal(writes, 0, "yge: a block that stops before the field writes nothing")

-- A block cut short after the field: the field is real, but a partial read says nothing, least of
-- all "no limit".
session = read("yge", 60, "yge", function(reply, api)
  local at = fieldPosition(api, "current_limit")
  reply[at] = 0
  reply[at + 1] = 0
  for i = #reply, at + 2, -1 do reply[i] = nil end
end)
equal(stored(session), "60/yge", "yge: a block cut short after a 0 clears nothing")
equal(writes, 0, "yge: a block cut short after a 0 writes nothing")

-- A block that declares fewer parameters than reach the field does not carry it, however long.
session = read("yge", 60, "yge", function(reply, api)
  local at = fieldPosition(api, "current_limit")
  reply[at] = 0
  reply[at + 1] = 0
  local count = (at - 1 - api.mspHeaderBytes) // 2
  reply[3] = count % 256
  reply[4] = count // 256
end)
equal(stored(session), "60/yge", "yge: a field past the declared count clears nothing")
equal(writes, 0, "yge: a field past the declared count writes nothing")

-- A read that fails.
for family, spec in pairs(families) do
  local apiPath = "tasks/msp/api/esc_parameters_" .. spec.api .. ".lua"
  local api = assert(loadfile("src/rfsuite/" .. apiPath))()
  local queue = { entries = {} }
  function queue:add(entry) self.entries[#self.entries + 1] = entry end
  useModules(modulesFor(queue, { [apiPath] = api, [base .. "escmfg/" .. spec.dir .. "/init.lua"] = {} }))
  session = newSession(60, spec.origin)
  local page = assert(loadfile("src/rfsuite/" .. base .. "escmfg/" .. spec.dir .. "/page.lua"))()
  page.wakeup({ requestRebuild = function() end })
  local entry = queue.entries[#queue.entries]
  if entry.errorHandler then entry:errorHandler() end
  equal(stored(session), "60/" .. spec.origin, family .. ": a failed read clears nothing")
  equal(writes, 0, family .. ": a failed read writes nothing")
end

if failures > 0 then
  print(string.format("FAIL %d of %d checks", failures, checks))
  os.exit(1)
end
print(string.format("OK %d checks", checks))
