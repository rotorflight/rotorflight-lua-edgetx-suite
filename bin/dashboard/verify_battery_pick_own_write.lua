-- The battery pick's own save, seen from the dashboard that made it: the real widget runtime,
-- lib/battery_pick.lua and lib/model_preferences.lua on the scripted flight controller
-- (bin/accounting/stubs), with a file stat that answers what the card really holds.
--
-- A pick records the pack in the model's store through model_preferences.saveByMcuId, which bumps
-- the reload request so that every OTHER reader of the store sees the change. The dashboard that
-- made the pick already holds the new values in memory, so it must not read the store again and
-- rebuild its theme for its own write. What is checked:
--
--   * after a pick on the ground, the dashboard that made it runs no preferences reload and no
--     theme resolve, and builds nothing for it; the pick is on the card and in the session;
--   * a save made elsewhere (the tool, another widget) is still picked up with one reload and
--     applied: well after the pick, and inside the stat interval just BEFORE the pick or just
--     AFTER it, before the dashboard has looked at the files again -- the radio's settings and the
--     model's store alike -- also where that other writer could not stat the reload request and
--     wrote it to the very size the pick had left it at;
--   * the board profile a pack belongs to is worked out once per pack when the list is loaded,
--     and once more for the pack picked, against the configuration in hand then.
--
--   lua5.3 bin/dashboard/verify_battery_pick_own_write.lua [runtime.lua] [--trace]
-- luacheck: globals io os
local runtimePath = "src/rfsuite/widgets/dashboard/runtime.lua"
local trace = false
for _, a in ipairs(arg or {}) do
  if a == "--trace" then trace = true else runtimePath = a end
end

local Stubs = assert(loadfile("bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile("bin/accounting/stubs/fc.lua"))()

local API_DIR = "src/rfsuite/tasks/msp/api"
local UID_COMMAND = 160

local function listLuaFiles(path)
  local pipe = assert(io.popen("ls -1 " .. path .. " 2>/dev/null"))
  local names = {}
  for name in pipe:lines() do
    if string.match(name, "%.lua$") then names[#names + 1] = name end
  end
  pipe:close()
  table.sort(names)
  return names
end

local failures, checks = 0, 0
local function expect(ok, label, detail)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label .. (detail and (": " .. detail) or ""))
  elseif trace then
    print("  ok   " .. label .. (detail and (" (" .. detail .. ")") or ""))
  end
end

local function upvalue(fn, name)
  for i = 1, 200 do
    local key, value = debug.getupvalue(fn, i)
    if not key then break end
    if key == name then return value, i end
  end
  error("missing production upvalue: " .. name)
end

-- The registry the pick offers: two packs for every model, as in the issue's field log, with the
-- capacities the scripted board publishes for its profiles 1 and 2 (bin/accounting/stubs/fc.lua
-- answers MSP_BATTERY_CONFIG with 1000, 1300, ... mAh at 6S).
local REGISTRY = table.concat({
  "# test registry",
  "id=p1000;name=Pack 1000;cap=1000;cells=6;models=*",
  "id=p1300;name=Pack 1300;cap=1300;cells=6;models=*",
  "",
}, "\n")

local function newWorld(requestSize)
  Stubs.install(".")
  FC.install(Stubs)
  Stubs.reset()
  FC.reset()
  FC.loadReplies(API_DIR, listLuaFiles(API_DIR))
  Stubs.clearCard()
  for k, v in pairs({ ["Vbat"] = 24.6, ["Curr"] = 3.2, ["Capa"] = 850, ["Bat%"] = 74, ["Cel#"] = 6,
    ["Hspd"] = 0, ["RQly"] = 96, ["1RSS"] = -42, ["2RSS"] = -45, ["Thr%"] = 0, ["ARM"] = 0,
    ["ARMD"] = 0, ["Gov"] = 0 }) do Stubs.sensors[k] = v end

  local world = { pass = 0, prefReloads = 0, resolves = 0, builds = 0, matched = 0,
    instructions = 0, worstPass = 0, peakKb = 0, counting = false, written = {} }
  _G.getRSSI = function() return 100 end

  -- The card's own file stat: the size the file has, and a modification time that moves with
  -- every write, one second per pass -- a radio whose clock runs. Every write goes through
  -- io.open with a write mode or through os.rename, and both are remapped onto the card by the
  -- stubs, so wrapping them here sees every write a module makes.
  local open, rename = io.open, os.rename
  io.open = function(path, mode)
    if type(path) == "string" and mode and string.find(mode, "[wa+]") then world.written[path] = world.pass end
    return open(path, mode)
  end
  os.rename = function(from, to)
    local ok, err = rename(from, to)
    if ok and type(to) == "string" then world.written[to] = world.pass end
    return ok, err
  end
  _G.fstat = function(path)
    if type(path) ~= "string" then return nil end
    local f = open(path, "rb")
    if not f then return nil end
    local ok, size = pcall(f.seek, f, "end")
    f:close()
    local t = world.written[path] or 0
    return { size = (ok and tonumber(size)) or 0,
      time = { year = 2026, mon = 11, day = 2, hour = 12, min = t // 60, sec = t % 60 } }
  end

  -- The radio's settings with the flight log on, and the registry, written before the widget
  -- starts, as the tool would have left them.
  local Preferences = _G.rfsuite.require("lib/preferences.lua")
  local prefs = Preferences.load()
  prefs.flightlog.enabled = true
  -- A pick also moves the board onto the pack's profile: the path that works the profile out.
  prefs.flightlog.set_fc_profile = true
  assert(Preferences.save(prefs), "radio settings write")
  local FlightLog = _G.rfsuite.require("lib/flight_log.lua")
  if type(FlightLog.ensureDir) == "function" then pcall(FlightLog.ensureDir, FlightLog.dataPath()) end
  local f = assert(io.open(FlightLog.registryPath(), "w"), "registry write")
  f:write(REGISTRY)
  f:close()

  local Uid = _G.rfsuite.require("tasks/msp/api/uid.lua")
  world.mcuId = Uid.parse(FC.replies[UID_COMMAND]).mcuId
  local MP = _G.rfsuite.require("lib/model_preferences.lua")
  world.MP = MP
  world.modelPrefs = { dashboard = { overrides = true, model_theme_preflight = "system/urban" } }
  assert(MP.saveByMcuId(world.mcuId, world.modelPrefs), "model store write")
  -- The reload request at a given size before the widget starts: 32 is the top of its rotation,
  -- so the next bump writes 1 -- the size a writer that cannot stat the request writes too.
  if requestSize then
    local req = assert(io.open(MP.reloadRequestPath(), "w"), "reload request write")
    req:write(string.rep("x", requestSize))
    req:close()
  end

  -- Every "target profile ... matched" line the pick logs.
  local Log = _G.rfsuite.require("lib/log.lua")
  local emit = Log.emit
  Log.emit = function(tag, msg, ...)
    if trace and tag == "rfsuite.battery_pick" then print("    bp " .. tostring(msg) .. " at pass " .. world.pass) end
    if tag == "rfsuite.battery_pick" and string.find(tostring(msg), "matched on", 1, true) then
      world.matched = world.matched + 1
      if trace then print("    log " .. tostring(msg) .. " at pass " .. world.pass) end
    end
    return emit(tag, msg, ...)
  end

  local Runtime = assert(loadfile(runtimePath))()
  local w = Runtime.new({ x = 0, y = 0, w = 800, h = 480 }, {})
  world.w = w

  -- Preferences reloads that ran, and theme resolves, counted where they happen; the calls go
  -- through.
  local work = upvalue(w.background, "performBackgroundWork")
  local reloadActiveTheme, index = upvalue(work, "reloadActiveTheme")
  debug.setupvalue(work, index, function(self, ...)
    world.resolves = world.resolves + 1
    if trace then print("    resolve " .. tostring(self.themePath) .. " at pass " .. world.pass) end
    return reloadActiveTheme(self, ...)
  end)
  local reloadPreferencesIfNeeded, pIndex = upvalue(work, "reloadPreferencesIfNeeded")
  debug.setupvalue(work, pIndex, function(self, ...)
    local r = reloadPreferencesIfNeeded(self, ...)
    if r == true then
      world.prefReloads = world.prefReloads + 1
      if trace then print("    preferences reload at pass " .. world.pass) end
    end
    return r
  end)

  -- Every tree handed to LVGL.
  local build = _G.lvgl.build
  _G.lvgl.build = function(children, ...)
    world.builds = world.builds + 1
    if trace then
      local job = world.w and world.w._job
      print("    build " .. tostring(job and job.kind) .. " at pass " .. world.pass)
    end
    return build(children, ...)
  end
  return world
end

local function passes(world, n)
  for _ = 1, n do
    world.pass = world.pass + 1
    Stubs.tick()
    if world.counting then
      local spent = 0
      debug.sethook(function() spent = spent + 1 end, "", 1)
      world.w.refresh(world.w, nil, nil)
      debug.sethook()
      world.instructions = world.instructions + spent
      if spent > world.worstPass then world.worstPass = spent end
      local kb = collectgarbage("count")
      if kb > world.peakKb then world.peakKb = kb end
    else
      world.w.refresh(world.w, nil, nil)
    end
  end
end

-- Connect, read the board, and wait until the pick's list is loaded and the prompt is up.
local function connectAndLoad(world)
  passes(world, 400)
  local session = _G.rfsuite.session
  expect(session.mcu_id == world.mcuId, "control: the board identified itself", tostring(session.mcu_id))
  expect(world.w.themePath == "system/urban", "control: the model's theme is on screen", tostring(world.w.themePath))
  local pick = world.w.state.batteryPick
  expect(pick.loaded == true and #pick.candidates == 2, "control: the pick's list is loaded with both packs",
    tostring(pick.loaded) .. ", " .. #pick.candidates .. " pack(s)")
  expect(pick.pending == true, "control: the prompt is up", tostring(pick.pending))
end

local function window(world)
  world.prefReloads, world.resolves, world.builds, world.matched = 0, 0, 0, 0
end

local function storedPack(world)
  local prefs = world.MP.loadByMcuId(world.mcuId, true)
  return prefs and prefs.flightlog and prefs.flightlog.battery
end

-- A save of the model's store made outside this dashboard: the tool's settings page, say. With
-- `blindRequest` the writer's stat of the reload request fails, so it writes the request at 1.
local function foreignSave(world, blindRequest)
  local copy = world.MP.loadByMcuId(world.mcuId, true)
  copy.dashboard.cfg_system_urban_scheme = "dark"
  local stat = _G.fstat
  if blindRequest then
    _G.fstat = function(path)
      if type(path) == "string" and string.find(path, "reload.req", 1, true) then return nil end
      return stat(path)
    end
  end
  local ok = world.MP.saveByMcuId(world.mcuId, copy)
  _G.fstat = stat
  assert(ok, "foreign save")
end

-- A save of the radio's settings made outside this dashboard.
local function foreignRadioSave(world, minSeconds)
  local Preferences = _G.rfsuite.require("lib/preferences.lua")
  local prefs = Preferences.load()
  prefs.flightlog.min_seconds = minSeconds
  assert(Preferences.save(prefs), "foreign radio settings save")
end

-- 1. The issue's sequence: connect, the prompt, the pilot picks a pack. Nothing else happens.
do
  if trace then print("scenario: pick on connect") end
  local world = newWorld()
  connectAndLoad(world)
  expect(world.matched == 2, "the list's load works out each pack's profile once", world.matched .. " line(s) for 2 packs")
  expect(world.w.state.batteryPick.candidates[2].targetProfile == 1, "control: the 1300 pack matches profile 2",
    tostring(world.w.state.batteryPick.candidates[2].targetProfile))
  passes(world, 30)
  window(world)
  collectgarbage("collect")
  local kbBefore = collectgarbage("count")
  world.counting, world.instructions, world.worstPass, world.peakKb = true, 0, 0, kbBefore
  _G.rfsuite.batteryPick.select("p1300")
  passes(world, 60)
  world.counting = false
  collectgarbage("collect")
  print(string.format("COUNT pick instructions=%d worstPass=%d reloads=%d resolves=%d builds=%d matched=%d "
    .. "peakKbAboveStart=%.0f retainedKb=%.1f", world.instructions, world.worstPass, world.prefReloads,
    world.resolves, world.builds, world.matched, world.peakKb - kbBefore, collectgarbage("count") - kbBefore))
  expect(storedPack(world) == "p1300", "control: the pick is on the card", tostring(storedPack(world)))
  expect(_G.rfsuite.session.flightlog and _G.rfsuite.session.flightlog.batteryId == "p1300",
    "control: the pick is in the session")
  expect(world.w.state.batteryPick.pending == false, "control: the prompt is answered")
  expect(world.w.state.batteryPick.applied == "queued" or world.w.state.batteryPick.applied == "skipped",
    "control: the pick reached the profile write", tostring(world.w.state.batteryPick.applied))
  expect(world.prefReloads == 0, "own pick: the dashboard does not reload its preferences",
    world.prefReloads .. " reload(s)")
  expect(world.resolves == 0, "own pick: the theme is not resolved again", world.resolves .. " resolve(s)")
  -- The one build left is the zone without the prompt, which the answer changes; the second pick
  -- below, with no prompt up, shows that nothing else is built.
  expect(world.builds <= 1, "own pick: nothing but the answered prompt is built", world.builds .. " build(s)")
  expect(world.matched == 1, "control: the picked pack's profile is worked out once at the pick",
    world.matched .. " line(s)")
  expect(world.w._reloadPending == nil, "own pick: no reload is left pending", tostring(world.w._reloadPending))

  -- 2. Then a save from elsewhere: it is still picked up, once.
  window(world)
  foreignSave(world)
  passes(world, 40)
  expect(world.prefReloads == 1, "a model store save from elsewhere after the pick is reloaded once",
    world.prefReloads .. " reload(s)")
  expect(world.w.state.themeConfig and world.w.state.themeConfig.scheme == "dark",
    "a model store save from elsewhere after the pick is applied",
    tostring(world.w.state.themeConfig and world.w.state.themeConfig.scheme))
  expect(storedPack(world) == "p1300", "control: the foreign save kept the pick", tostring(storedPack(world)))

  -- And a second pick, after that reload: still its own write.
  window(world)
  _G.rfsuite.batteryPick.select("p1000")
  passes(world, 40)
  expect(storedPack(world) == "p1000", "control: the second pick is on the card", tostring(storedPack(world)))
  expect(world.prefReloads == 0, "a second own pick: no reload", world.prefReloads .. " reload(s)")
  expect(world.resolves == 0 and world.builds == 0, "a second own pick: no theme resolve and no build",
    world.resolves .. " resolve(s), " .. world.builds .. " build(s)")
end

-- 3. A save from elsewhere inside the stat interval around the pick, before the dashboard has
-- looked at the files again: the pick's own write must not hide it. Just before the pick and just
-- after it, for the radio's settings and for the model's store; and once more where the writer
-- after the pick could not stat the reload request and wrote it at 1 -- the size the pick had just
-- left it at, from the top of its rotation. A model save just before the pick has its content
-- written over by the pick from memory, as it always has, so there only the reload is checked.
local CASES = {
  { which = "radio", order = "before" },
  { which = "model", order = "before" },
  { which = "radio", order = "after" },
  { which = "model", order = "after" },
  { which = "model", order = "after", blind = true, requestSize = 32 },
}
for _, case in ipairs(CASES) do
  local name = case.which .. " save " .. case.order .. " the pick" .. (case.blind and ", request not stat-able" or "")
  if trace then print("scenario: " .. name) end
  local world = newWorld(case.requestSize)
  connectAndLoad(world)
  passes(world, 30)
  -- Right after the dashboard's look at the files, so that the save and the pick both land before
  -- the next one (one look per second, ten passes at the stub clock).
  local statAt = world.w._lastPrefsStatAt
  for _ = 1, 20 do
    passes(world, 1)
    if world.w._lastPrefsStatAt ~= statAt then break end
  end
  statAt = world.w._lastPrefsStatAt
  window(world)
  local function foreign()
    if case.which == "radio" then foreignRadioSave(world, 45) else foreignSave(world, case.blind) end
  end
  if case.order == "before" then foreign() end
  _G.rfsuite.batteryPick.select("p1000")
  for _ = 1, 5 do
    passes(world, 1)
    if world.w._batteryPickRequest == nil then break end
  end
  if case.order == "after" then foreign() end
  expect(world.w._batteryPickRequest == nil and world.w._lastPrefsStatAt == statAt,
    "control: the pick and the save landed before the next look at the files (" .. name .. ")",
    tostring(statAt) .. " -> " .. tostring(world.w._lastPrefsStatAt))
  expect(storedPack(world) == "p1000", "control: the pick is on the card (" .. name .. ")", tostring(storedPack(world)))
  passes(world, 40)
  expect(world.prefReloads == 1, "a " .. name .. " is reloaded once", world.prefReloads .. " reload(s)")
  if case.which == "radio" then
    expect(world.w.preferences and world.w.preferences.flightlog.min_seconds == 45,
      "a " .. name .. " is applied",
      tostring(world.w.preferences and world.w.preferences.flightlog.min_seconds))
  elseif case.order == "after" then
    expect(world.w.state.themeConfig and world.w.state.themeConfig.scheme == "dark",
      "a " .. name .. " is applied",
      tostring(world.w.state.themeConfig and world.w.state.themeConfig.scheme))
  end
end

-- 4. The board's battery configuration replaced after the list was loaded, with the 1300 mAh
-- capacity moved from profile 2 to profile 3: the pick works the profile out again, once, against
-- the configuration in hand, because a new configuration is what can turn a capacity into a profile.
do
  if trace then print("scenario: battery configuration replaced") end
  local world = newWorld()
  connectAndLoad(world)
  local cfg = {}
  for k, v in pairs(_G.rfsuite.session.battery_config) do cfg[k] = v end
  cfg.batteryCapacity_1, cfg.batteryCapacity_2 = cfg.batteryCapacity_2, cfg.batteryCapacity_1
  _G.rfsuite.session.battery_config = cfg
  passes(world, 2)
  window(world)
  _G.rfsuite.batteryPick.select("p1300")
  passes(world, 5)
  expect(world.matched == 1, "replaced configuration: worked out once for the pick", world.matched .. " line(s)")
  expect(world.w.state.batteryPick.candidates[2].targetProfile == 2,
    "replaced configuration: the picked pack takes the profile the new configuration gives",
    tostring(world.w.state.batteryPick.candidates[2].targetProfile))
end

-- The instruction probe's own control: a loop it must count.
do
  local spent = 0
  debug.sethook(function() spent = spent + 1 end, "", 1)
  local x = 0
  for i = 1, 1000 do x = x + i end
  debug.sethook()
  expect(spent > 1000 and x > 0, "control: the instruction probe counts", spent .. " instructions")
end

-- The memory probe's own control: an allocation it must see.
do
  collectgarbage("collect")
  local before = collectgarbage("count")
  local hold = {}
  for i = 1, 4096 do hold[i] = string.rep("x", 64) .. i end
  local after = collectgarbage("count")
  expect(after - before > 200 and #hold == 4096, "control: the memory probe sees an allocation",
    string.format("%.0f kB", after - before))
end

Stubs.releaseCard()
if failures > 0 then
  print(string.format("%d of %d battery pick own-write checks failed", failures, checks))
  os.exit(1)
end
print(string.format("%d battery pick own-write checks, 0 failures", checks))
