-- The switch to a model's own dashboard theme at connect, with the real widget runtime and the real
-- MSP runtime on a scripted flight controller (bin/accounting/stubs). The radio's theme and the
-- model's own are written to the card through the suite's own writers, the widget is built on the
-- radio's theme, and the link comes up from cold, as on a radio switched on with the model's
-- receiver bound.
--
-- What is checked: the widget ends on the model's theme, and no scene is built for it before the
-- readings its boxes name are collected, nor without every reading its module declares; the readings
-- are collected with the first snapshot of them; the pass that reads the model's preferences off the card
-- does not also load the theme's modules; and no pass both loads the theme's modules and collects
-- those readings and builds the first snapshot of them. The same holds where the theme is changed
-- while connected -- a model theme saved from the tool, which reloads the preferences and then the
-- theme -- and there exactly one scene is built for the new theme.
--
--   lua5.3 bin/dashboard/verify_theme_switch_passes.lua [runtime.lua] [--trace]
local runtimePath = "src/rfsuite/widgets/dashboard/runtime.lua"
local trace = false
for _, a in ipairs(arg or {}) do
  if a == "--trace" then trace = true else runtimePath = a end
end

local Stubs = assert(loadfile("bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile("bin/accounting/stubs/fc.lua"))()

local API_DIR = "src/rfsuite/tasks/msp/api"
local RADIO_THEME = "system/urban"
local MODEL_THEME = "system/deck"
local LATER_THEME = "system/grid"
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
  end
end

-- The folder of a theme path as the card paths spell it: "system/deck" -> "/themes/deck/".
local function themeFolder(themePath)
  return "/themes/" .. string.match(themePath, "^[^/]+/(.+)$") .. "/"
end

local function newWorld()
  Stubs.install(".")
  FC.install(Stubs)
  Stubs.reset()
  FC.reset()
  FC.loadReplies(API_DIR, listLuaFiles(API_DIR))
  Stubs.clearCard()
  -- What fstat answers for the preference files and their reload request; a save moves it.
  Stubs.prefsStat = { size = 1 }
  -- A helicopter idling on the bench, as bin/accounting/measure.lua scripts it.
  for k, v in pairs({ ["Vbat"] = 24.6, ["Curr"] = 3.2, ["Capa"] = 850, ["Bat%"] = 74, ["Cel#"] = 6,
    ["Hspd"] = 0, ["RQly"] = 96, ["1RSS"] = -42, ["2RSS"] = -45, ["Thr%"] = 0, ["ARM"] = 0,
    ["ARMD"] = 0, ["Gov"] = 0 }) do Stubs.sensors[k] = v end
  _G.getRSSI = function() return 100 end

  local world = { pass = 0, loads = {}, modelLoad = {}, sources = {}, snapshot = {}, builds = {}, count = {} }

  -- Which theme's modules a pass reads from the card. A theme module's own chunk is what costs:
  -- loading a theme runs its phase module and every shared file that one requires.
  local loadScript = _G.loadScript
  _G.loadScript = function(path, ...)
    if type(path) == "string" then
      local folder = string.match(path, "(/themes/[^/]+/)")
      if folder and not string.find(path, "/init.lua", 1, true) then
        world.loads[world.pass] = world.loads[world.pass] or {}
        world.loads[world.pass][folder] = true
      end
    end
    return loadScript(path, ...)
  end

  -- Both stores, written through the suite's own writers before the widget exists.
  local Preferences = _G.rfsuite.require("lib/preferences.lua")
  local prefs = Preferences.load()
  prefs.dashboard = prefs.dashboard or {}
  prefs.dashboard.theme_preflight = RADIO_THEME
  assert(Preferences.save(prefs) ~= false, "radio store write")
  local Uid = _G.rfsuite.require("tasks/msp/api/uid.lua")
  world.mcuId = Uid.parse(FC.replies[UID_COMMAND]).mcuId
  world.MP = _G.rfsuite.require("lib/model_preferences.lua")
  assert(world.MP.saveByMcuId(world.mcuId,
    { dashboard = { overrides = true, model_theme_preflight = MODEL_THEME } }), "model store write")

  local Runtime = assert(loadfile(runtimePath))()
  world.w = Runtime.new({ x = 0, y = 0, w = 800, h = 480 }, {})

  -- Every scene the widget hands to LVGL, with the theme it was built for and the readings that
  -- theme had collected when it was built.
  local build = _G.lvgl.build
  _G.lvgl.build = function(children, ...)
    local w = world.w
    local job = w and w._job
    if job and (job.kind == "scene" or job.build or job.swap) then
      -- The readings the module declares, which the list collected for it has to hold.
      local declared = w.theme and w.theme.sources
      if type(declared) == "function" then
        local ok, list = pcall(declared, nil, w.state)
        declared = ok and list or nil
      end
      local have, missing, named = {}, {}, 0
      for _, src in ipairs(w.boxSources or {}) do have[src] = true end
      for _, src in ipairs(type(declared) == "table" and declared or {}) do
        named = named + 1
        if not have[src] then missing[#missing + 1] = tostring(src) end
      end
      world.builds[#world.builds + 1] = { pass = world.pass, theme = w.themePath, sources = w.boxSources,
        declared = named, missing = missing }
    end
    return build(children, ...)
  end
  return world
end

-- One pass of the radio, with its Lua VM instructions counted (the unit bin/accounting/measure.lua
-- prices passes in), what it read from the card, and whether it collected a theme's readings.
local function passes(world, n, label)
  for _ = 1, n do
    world.pass = world.pass + 1
    local w = world.w
    local sourcesBefore = w.boxSources
    local derivedBefore = w.state and w.state.derived
    local prefsBefore = _G.rfsuite.session.modelPreferences
    local keyBefore = w.renderKey
    Stubs.tick()
    local spent = 0
    debug.sethook(function() spent = spent + 1 end, "", 1)
    w.refresh(w, nil, nil)
    debug.sethook()
    world.count[world.pass] = spent
    if w.boxSources ~= sourcesBefore then
      world.sources[world.pass] = w.themePath
      world.snapshot[world.pass] = (w.state.derived ~= derivedBefore)
    end
    local prefs = _G.rfsuite.session.modelPreferences
    if prefs ~= prefsBefore and type(prefs) == "table" then world.modelLoad[world.pass] = true end
    if trace and w.renderKey ~= keyBefore and keyBefore ~= nil then
      print(string.format("    key at pass %d: %s -> %s", world.pass, tostring(keyBefore), tostring(w.renderKey)))
    end
    if trace and (world.loads[world.pass] or world.sources[world.pass] or world.modelLoad[world.pass]) then
      local folders = {}
      for f in pairs(world.loads[world.pass] or {}) do folders[#folders + 1] = f end
      print(string.format("  [%s %4d] %6d instr  theme=%-14s modules=%s sources=%s prefs=%s", label,
        world.pass, spent, tostring(w.themePath), table.concat(folders, ","),
        tostring(world.sources[world.pass] ~= nil), tostring(world.modelLoad[world.pass] == true)))
    end
  end
end

-- No pass both loads `themePath`'s modules and collects its readings; none both reads the model's
-- preferences and loads the modules. Answers the pass the modules were loaded on.
local function checkPasses(world, themePath, first, last, label)
  local folder = themeFolder(themePath)
  local loadedAt, collectedAt = nil, nil
  for p = first, last do
    local loaded = world.loads[p] and world.loads[p][folder]
    if loaded then
      loadedAt = loadedAt or p
      expect(world.sources[p] == nil, label .. ": the pass that loads the theme's modules does not also"
        .. " collect its readings", "pass " .. p .. ", " .. tostring(world.count[p]) .. " instructions")
      expect(not world.modelLoad[p], label .. ": the pass that reads the model's preferences does not"
        .. " also load the theme's modules", "pass " .. p .. ", " .. tostring(world.count[p]) .. " instructions")
    end
    if world.sources[p] == themePath then collectedAt = collectedAt or p end
  end
  expect(loadedAt ~= nil, "control (" .. label .. "): the theme's modules were loaded")
  expect(collectedAt ~= nil, "control (" .. label .. "): the theme's readings were collected")
  expect(collectedAt == nil or world.snapshot[collectedAt] == true, label .. ": the pass that collects the"
    .. " theme's readings also builds the first snapshot of them", "pass " .. tostring(collectedAt))
  return loadedAt, collectedAt
end

-- The scenes built for `themePath` from pass `first` on: none before its readings were collected
-- (`collectedAt`), and with `one`, exactly one. A scene is counted by the pass its build started on;
-- the passes of one build follow each other.
local function checkBuilds(world, themePath, first, collectedAt, one, label)
  local scenes, early, last = 0, 0, nil
  local named, missing = 0, {}
  for _, b in ipairs(world.builds) do
    if b.pass >= first and b.theme == themePath then
      named = math.max(named, b.declared)
      for _, m in ipairs(b.missing) do missing[#missing + 1] = m end
      if trace then print(string.format("    build pass %d theme %s", b.pass, tostring(b.theme))) end
      if last == nil or b.pass > last + 1 then scenes = scenes + 1 end
      last = b.pass
      if collectedAt == nil or b.pass < collectedAt then early = early + 1 end
    end
  end
  expect(scenes >= 1, "control (" .. label .. "): a scene is built for the theme")
  if one then
    expect(scenes == 1, label .. ": one scene is built for the theme", scenes .. " scenes")
  end
  expect(early == 0, label .. ": no scene is built before the theme's readings are collected",
    early .. " build passes before")
  expect(named > 0, "control (" .. label .. "): the theme's module declares readings of its own")
  expect(#missing == 0, label .. ": every scene is built with the readings the module declares",
    "missing " .. table.concat(missing, ","))
end

-- Case 1: from cold. The radio's theme stands from the build; the model's replaces it at connect.
do
  local world = newWorld()
  expect(world.w.themePath == RADIO_THEME, "control: the widget starts on the radio's theme",
    tostring(world.w.themePath))
  passes(world, 300, "cold")
  expect(_G.rfsuite.session.mcu_id == world.mcuId, "control: the board identified itself",
    tostring(_G.rfsuite.session.mcu_id))
  expect(world.w.themePath == MODEL_THEME, "cold: the widget ends on the model's theme",
    tostring(world.w.themePath))
  expect(world.w.built == true, "cold: the model's theme is built", tostring(world.w.built))
  local _, collectedAt = checkPasses(world, MODEL_THEME, 1, world.pass, "cold")
  -- Not one scene here: a theme's own key moves once the first readings have settled after the
  -- connect (Deck's does), which builds it again whatever the switch did.
  checkBuilds(world, MODEL_THEME, 1, collectedAt, false, "cold")

  -- Case 2: connected, the model's theme changed from the tool. The store is written as the
  -- Design page writes it; the widget finds it by the reload request and reloads.
  local from = world.pass + 1
  assert(world.MP.saveByMcuId(world.mcuId,
    { dashboard = { overrides = true, model_theme_preflight = LATER_THEME } }), "model store rewrite")
  Stubs.prefsStat = { size = Stubs.prefsStat.size + 1 }
  passes(world, 80, "saved")
  expect(world.w.themePath == LATER_THEME, "saved: the widget moves to the theme saved",
    tostring(world.w.themePath))
  local _, laterCollectedAt = checkPasses(world, LATER_THEME, from, world.pass, "saved")
  checkBuilds(world, LATER_THEME, from, laterCollectedAt, true, "saved")
end

Stubs.releaseCard()
print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
