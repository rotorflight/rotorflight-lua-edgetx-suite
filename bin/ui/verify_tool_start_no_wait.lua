-- The configuration tool's start (ui/home.lua) does not wait for the flight controller: with
-- nothing to compile the first frame is the menu, with a link or without one; the tiles that need
-- the flight controller are greyed out until it answers and then enable in place;
-- a compile pass still holds the start screen and the menu follows as soon as it is through; and
-- what the start screen used to say while it waited -- a failed move of the pilot's data, the
-- restart request -- is still said, once, over the menu. Runs the tool's own start on the
-- accounting stubs, one start per case, each in a process of its own so that no module state
-- carries over:
--   lua5.3 bin/ui/verify_tool_start_no_wait.lua
-- Exit status: 0 green, 1 failed expectations.

local NAME = "tool start no wait"
local CORE = "/SCRIPTS/RFSUITE/core"
local USER = "/SCRIPTS/RFSUITE/user"

local function caseArg()
  for i = 1, #arg do
    if arg[i] == "--case" then return arg[i + 1] end
  end
end

local CASES = { "nolink", "link", "pagefirst", "themesave", "linkdrop", "offlinesave", "savebeforeread", "otherfc",
  "removedtheme", "compile", "movefailed", "restart", "both" }

local function quote(text)
  return "'" .. string.gsub(text, "'", "'\\''") .. "'"
end

-- The parent: run every case in its own interpreter and collect what each reported.
if caseArg() == nil then
  local lua = arg[-1] or "lua5.3"
  local checks, failures = 0, 0
  for i = 1, #CASES do
    local pipe = assert(io.popen(quote(lua) .. " " .. quote(arg[0]) .. " --case " .. CASES[i] .. " 2>&1"))
    local seen = false
    for line in pipe:lines() do
      if string.sub(line, 1, 5) == "FAIL " then
        failures = failures + 1
        print(line)
      end
      local n = string.match(line, "^CHECKS (%d+)$")
      if n then
        checks = checks + tonumber(n)
        seen = true
      end
    end
    pipe:close()
    if not seen then
      failures = failures + 1
      print("FAIL case " .. CASES[i] .. ": did not report (crashed before its checks)")
    end
  end
  if failures > 0 then
    print(NAME .. ": " .. failures .. " of " .. checks .. " checks failed")
    os.exit(1)
  end
  print(NAME .. ": " .. checks .. " checks passed")
  os.exit(0)
end

-- One case.
local case = caseArg()
local checks = 0
local function expect(ok, label)
  checks = checks + 1
  if not ok then
    print("FAIL " .. case .. ": " .. label)
  end
end

local function find(fn, wanted, seen)
  seen = seen or {}
  if seen[fn] then return nil end
  seen[fn] = true
  local nested = {}
  for i = 1, 200 do
    local name, value = debug.getupvalue(fn, i)
    if not name then break end
    if name == wanted then return value end
    if type(value) == "function" then nested[#nested + 1] = value end
  end
  for i = 1, #nested do
    local found = find(nested[i], wanted, seen)
    if found ~= nil then return found end
  end
end

local Stubs = assert(loadfile("bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile("bin/accounting/stubs/fc.lua"))()
Stubs.clearCard()
Stubs.install("."); FC.install(Stubs); Stubs.reset(); FC.reset()
Stubs.installTool()
-- No telemetry link: the receiver reports no RSSI.
if case == "nolink" then
  _G.getRSSI = function() return 0, 45, 42 end
end

local function writeCard(path, text)
  local parent = string.match(path, "^(.*)/[^/]+$")
  local parts = {}
  for part in string.gmatch(parent, "[^/]+") do
    parts[#parts + 1] = part
    mkdir("/" .. table.concat(parts, "/"))
  end
  local f = assert(io.open(path, "w"))
  io.write(f, text)
  io.close(f)
end

local version = assert(loadfile("src/rfsuite/lib/version.lua"))().VERSION
local IDENTITY = "0123456789abcdef " .. tostring(version)

-- The card: the build identity the packager writes and a few real sources beside their bytecode;
-- every case but the two that compile carries the stamp of the tree last compiled.
writeCard(CORE .. "/build.txt", IDENTITY .. "\n")
local names = {}
local pipe = assert(io.popen("ls -1 src/rfsuite/lib"))
for name in pipe:lines() do
  if string.sub(name, -4) == ".lua" and #names < 3 then names[#names + 1] = name end
end
pipe:close()
table.sort(names)
for i = 1, #names do
  writeCard(CORE .. "/lib/" .. names[i], "-- listed only\n")
  writeCard(CORE .. "/lib/" .. string.sub(names[i], 1, -5) .. ".luac", "")
end
if case ~= "compile" and case ~= "restart" and case ~= "both" then
  writeCard(USER .. "/precompiled.txt", IDENTITY)
end

local Home = assert(loadfile("src/rfsuite/ui/home.lua"))()
local state = assert(find(Home.run, "state"), "home state missing")

-- Every scene the tool builds, and how many of them were the start screen: the start screen is
-- the build made while state.initialLoad holds.
local builds, startBuilds = 0, 0
local realBuild = lvgl.build
-- The texts of the last scene built, nested children included: what was on screen after it.
local lastTexts = {}
-- The tiles of the last scene built, by the text under them: the button (its `active` and `press`)
-- and the grey cover drawn over a disabled one. A tile is a button followed by its own children.
local lastTiles = {}
local function collectTexts(children, into)
  if type(children) ~= "table" then return end
  local button, cover = nil, nil
  for i = 1, #children do
    local child = children[i]
    if type(child) == "table" then
      if child.type == "button" then button, cover = child, nil end
      if child.type == "rectangle" and button and type(child.visible) == "function" then cover = child end
      if type(child.text) == "string" then
        into[child.text] = true
        if child.type == "label" and button then
          lastTiles[child.text] = { button = button, cover = cover, label = child }
          button, cover = nil, nil
        end
      end
      collectTexts(child.children, into)
    end
  end
end
lvgl.build = function(children, ...)
  builds = builds + 1
  if state.initialLoad then startBuilds = startBuilds + 1 end
  lastTexts = {}
  lastTiles = {}
  collectTexts(children, lastTexts)
  return realBuild(children, ...)
end

local function logged(text)
  for _, entry in ipairs(_G.rfsuite.log_history or {}) do
    if entry.tag == "rfsuite.ui" and string.find(entry.msg, text, 1, true) then return entry.msg end
  end
end

local function runFor(passes)
  for _ = 1, passes do
    Stubs.tick()
    Home.run(0)
  end
end

if case == "movefailed" or case == "both" then
  -- An earlier start could not move the pilot's data (lib/user_move.lua sets this).
  _G.rfsuite.paths.moveFailed = true
end

-- The radio's clock moves while init runs; the stubs' clock stands still between ticks. For one case
-- it moves by one tick per reading during init, so the start screen's line can show a duration.
local realGetTime = _G.getTime
if case == "nolink" and type(realGetTime) == "function" then
  local moved = 0
  _G.getTime = function()
    moved = moved + 1
    return realGetTime() + moved
  end
end
Home.init({})
_G.getTime = realGetTime
local Precompile = find(Home.run, "Precompile")

local PAGE_CASES = { themesave = true, linkdrop = true, offlinesave = true, savebeforeread = true, otherfc = true,
  removedtheme = true }
if case == "nolink" or case == "link" or case == "pagefirst" or PAGE_CASES[case] then
  expect(state.initialLoad == false, "the start screen still stands after init with nothing to compile")
  expect(builds >= 1, "init built nothing (control)")
  expect(startBuilds == 0, "the start screen was drawn " .. startBuilds .. " times with nothing to compile")
  expect(logged("not drawn") ~= nil, "the log does not say that the start screen was not drawn")
  if case == "nolink" then
    -- The line measures from the start of init to the moment the start screen is left, not from the
    -- start to itself.
    local line = logged("not drawn") or ""
    local ticks = tonumber(string.match(line, "after (%d+) ticks"))
    expect(ticks ~= nil and ticks > 0, "the start screen's line reports " .. tostring(ticks) .. " ticks with the clock moving: " .. line)
  end
  runFor(5)
  expect(startBuilds == 0, "the start screen was drawn after init")
  expect(state.menu and state.menu.isRoot(), "the tool is not on its menu")
  expect(state.mspAttached == true, "the tool did not attach to the message runtime behind the menu")
  -- The connection is driven from behind the menu: the message runtime keeps being ticked.
  local MspRuntime = find(Home.run, "MspRuntime")
  local ticks = 0
  if MspRuntime and type(MspRuntime.tick) == "function" then
    local realTick = MspRuntime.tick
    MspRuntime.tick = function(...)
      ticks = ticks + 1
      return realTick(...)
    end
  end
  runFor(20)
  expect(ticks > 0, "the message runtime is not ticked behind the menu")
end

if case == "link" then
  -- The handshake does not complete in this world, so the tiles that need the flight controller
  -- are greyed out; then it answers, and they enable where they stand: the tile objects drawn
  -- before are the ones that answer the firmware afterwards, with no build in between. A build
  -- clears the scene, and the firmware's wheel focus with it; that focus is not modelled by these
  -- stubs, so what is checked is that no build happens and that the same tiles report the change.
  expect(state.fblConnected == false, "the flight controller counts as connected before it answered (control)")
  expect(state.menu.isRootEntryEnabled("configuration", "setup") == false,
    "Setup is enabled before the flight controller answered")
  local setup = lastTiles["Setup"]
  local tools = lastTiles["Tools"]
  expect(setup ~= nil and tools ~= nil, "the Setup and Tools tiles were not found on the menu (instrument)")
  local function active(tile) return tile ~= nil and type(tile.button.active) == "function" and tile.button.active() end
  local function covered(tile) return tile ~= nil and tile.cover ~= nil and tile.cover.visible() == true end
  expect(active(setup) == false, "the Setup tile can take the focus before the flight controller answered")
  expect(covered(setup), "the Setup tile is not greyed out before the flight controller answered")
  expect(active(tools) == true and not covered(tools), "the Tools tile is not enabled without a flight controller (control)")
  local opened = false
  if setup and type(setup.button.press) == "function" then
    setup.button.press()
    opened = not state.menu.isRoot()
    if opened then state.menu.goBack() end
  end
  expect(not opened, "a press on the greyed-out Setup tile opened its menu")
  state.focusIndex = 3
  local MspRuntime = assert(find(Home.run, "MspRuntime"), "message runtime missing")
  MspRuntime.isFblConnected = function() return true end
  local before = builds
  runFor(3)
  expect(state.fblConnected == true, "the tool did not see the flight controller answer")
  expect(state.menu.isRootEntryEnabled("configuration", "setup") == true,
    "Setup stayed greyed out after the flight controller answered")
  expect(builds == before, "the menu was drawn again when the flight controller answered ("
    .. (builds - before) .. " builds), which clears the wheel focus")
  expect(active(setup) == true, "the Setup tile drawn before the answer does not take the focus after it")
  expect(not covered(setup), "the Setup tile drawn before the answer is still greyed out after it")
  expect(state.focusIndex == 3, "the tool's focus index changed when the tiles enabled: " .. tostring(state.focusIndex))
  expect(state.initialLoad == false and startBuilds == 0, "the start screen came back")
  -- And back: the link is lost, and the tiles grey out where they stand.
  MspRuntime.isFblConnected = function() return false end
  before = builds
  runFor(3)
  expect(state.fblConnected == false, "the tool did not see the flight controller go (control)")
  expect(builds == before and active(setup) == false and covered(setup),
    "the Setup tile did not grey out in place when the flight controller went")
  -- Opened from the dashboard a pass can be stopped at the instruction limit in the middle of the
  -- change: the next pass has to finish it, although the change itself is not seen again.
  local realGroups = state.menu.getRootGroups
  state.menu.getRootGroups = function()
    state.menu.getRootGroups = realGroups
    error("instruction limit (simulated)")
  end
  MspRuntime.isFblConnected = function() return true end
  local stopped = not pcall(runFor, 1)
  expect(stopped, "the simulated stop did not happen (instrument)")
  state.menu.getRootGroups = realGroups
  runFor(2)
  expect(state.fblConnected == true, "the tool did not see the flight controller answer after the stop (control)")
  expect(active(setup) == true and not covered(setup),
    "a change stopped at the instruction limit left the Setup tile greyed out")
  -- Stopped earlier, as the condition itself is set: the next pass has to set it.
  local realSet = state.menu.setCondition
  state.menu.setCondition = function(key, value)
    state.menu.setCondition = realSet
    if key == "fblConnected" then error("instruction limit (simulated)") end
    return realSet(key, value)
  end
  MspRuntime.isFblConnected = function() return false end
  stopped = not pcall(runFor, 1)
  expect(stopped, "the second simulated stop did not happen (instrument)")
  state.menu.setCondition = realSet
  runFor(2)
  expect(state.menu.isRootEntryEnabled("configuration", "setup") == false and active(setup) == false,
    "a change stopped as the condition was set left the Setup tile enabled with the flight controller gone")
  -- Stopped right after the condition was set, and the link goes back before the next pass: the
  -- next pass has to follow the link as it is then, not the change as it was begun.
  realSet = state.menu.setCondition
  state.menu.setCondition = function(key, value)
    state.menu.setCondition = realSet
    realSet(key, value)
    if key == "fblConnected" then error("instruction limit (simulated)") end
  end
  MspRuntime.isFblConnected = function() return true end
  stopped = not pcall(runFor, 1)
  expect(stopped, "the third simulated stop did not happen (instrument)")
  state.menu.setCondition = realSet
  MspRuntime.isFblConnected = function() return false end
  runFor(2)
  expect(state.menu.isRootEntryEnabled("configuration", "setup") == false and active(setup) == false
    and state.fblConnected == false,
    "a change stopped after the condition was set, with the link gone again, left the Setup tile enabled")
  -- Stopped inside the registry's own setter, right after it writes the value: whatever the setter
  -- has not done by then has to be done by the next pass. The conditions table is put behind a
  -- proxy that writes the value and then stops, once.
  local registry = state.menu
  local backing = registry.conditions
  local proxy = setmetatable({}, {
    __index = backing,
    __newindex = function(_, key, value)
      backing[key] = value
      if key == "fblConnected" then
        registry.conditions = backing
        error("instruction limit (simulated)")
      end
    end
  })
  registry.conditions = proxy
  MspRuntime.isFblConnected = function() return true end
  stopped = not pcall(runFor, 1)
  expect(stopped, "the fourth simulated stop did not happen (instrument)")
  registry.conditions = backing
  runFor(2)
  expect(registry.isRootEntryEnabled("configuration", "setup") == true and active(setup) == true
    and state.fblConnected == true,
    "a change stopped inside the registry's setter left the Setup tile greyed out")
  -- The ESC protocol conditions: a pass stopped part-way through them, and a protocol that goes
  -- back to the one applied before, must still end with the conditions set for it.
  local session = _G.rfsuite.session
  session.esc4WayDetectedProto = 1
  runFor(2)
  expect(state.menu.conditions.escProto1 == true, "protocol 1 did not set its condition (control)")
  session.esc4WayDetectedProto = nil
  local escSet = state.menu.setCondition
  state.menu.setCondition = function(key, value)
    escSet(key, value)
    if key == "escProto3" then
      state.menu.setCondition = escSet
      error("instruction limit (simulated)")
    end
  end
  stopped = not pcall(runFor, 1)
  state.menu.setCondition = escSet
  expect(stopped and state.menu.conditions.escProto1 == false, "the simulated stop in the ESC conditions did not happen (instrument)")
  session.esc4WayDetectedProto = 1
  runFor(2)
  expect(state.menu.conditions.escProto1 == true,
    "a stopped pass and a protocol back to the one applied before left its condition off")
  -- A build of anything else drops the record of the tiles, so a later change draws the menu.
  state.helpContent = "help"
  state.helpPageTitle = "Help"
  Home.requestRebuild(false)
  runFor(2)
  expect(state.rootDrawn == nil, "the root tiles stay recorded under another scene")
end

if case == "pagefirst" then
  -- A page that reads the flight controller's identity, opened before the flight controller has
  -- answered: it has to come up without it and keep running when the identity arrives behind it.
  local PAGE = "settings_dashboard_theme_page"
  state.pendingPageOpen = PAGE
  runFor(5)
  expect(state.activePageMenuId == PAGE, "the Theme page did not open before the flight controller answered: "
    .. tostring(state.activePageMenuId))
  local session = _G.rfsuite.session
  expect(session ~= nil and session.mcu_id == nil, "the identity is there before the flight controller answered (control)")
  local MspRuntime = assert(find(Home.run, "MspRuntime"), "message runtime missing")
  MspRuntime.isFblConnected = function() return true end
  session.mcu_id = "0123456789abcdef"
  session.modelPreferences = { dashboard = {} }
  runFor(10)
  expect(state.fblConnected == true, "the tool did not see the flight controller answer")
  expect(state.activePageMenuId == PAGE, "the Theme page was left when the flight controller answered")
  local crash = nil
  for _, entry in ipairs(_G.rfsuite.log_history or {}) do
    if string.find(entry.msg, "Crash in", 1, true) then crash = entry.msg end
  end
  expect(crash == nil, "a page hook crashed: " .. tostring(crash))
  expect(state.pageBuildFailed == nil, "the Theme page failed to build: " .. tostring(state.pageBuildFailed))
end

if PAGE_CASES[case] then
  -- The model's own theme settings, on the card for this flight controller before the tool opens.
  -- The Theme page is opened before the flight controller has answered; then it answers, and the
  -- pilot presses Save. What the page writes for the model has to be what the model's file held,
  -- not the defaults the page showed while it had no model to read.
  local MCU = "0123456789abcdef"
  local MP = assert(_G.rfsuite.require("lib/model_preferences.lua"), "model preferences module missing")
  local Lib = assert(_G.rfsuite.require("app/pages/settings/dashboard/lib.lua"), "dashboard library missing")
  local themes = Lib.listThemes() or {}
  local own = themes[#themes] and themes[#themes].path
  expect(type(own) == "string" and own ~= "", "no installed theme to pick for the model (instrument)")
  local seeded = MP.loadByMcuId(MCU, true) or {}
  seeded.dashboard = { overrides = true, model_override = true, model_theme_preflight = own }
  local okSeed = MP.saveByMcuId(MCU, seeded)
  expect(okSeed ~= false, "the model's file could not be written (instrument)")

  -- Save as the header's button does it: the tool hands the page's Save to the header.
  local Header = assert(_G.rfsuite.require("ui/header.lua"), "header module missing")
  local pressSave = nil
  local realAppend = Header.appendToLayout
  Header.appendToLayout = function(lyt, hctx)
    if type(hctx) == "table" and type(hctx.onSave) == "function" then pressSave = hctx.onSave end
    return realAppend(lyt, hctx)
  end

  -- Wherever a start screen still stands, it is waited out first, as a pilot would: the case is
  -- about the page, and on a tool that waits for the connection it is reached the same way once
  -- the flight controller comes later.
  for _ = 1, 100 do
    if not state.initialLoad then break end
    runFor(1)
  end
  local PAGE = "settings_dashboard_theme_page"
  state.pendingPageOpen = PAGE
  runFor(5)
  expect(state.activePageMenuId == PAGE, "the Theme page did not open (control)")
  -- The identity arrives behind the open page. The message runtime is stopped here so that its
  -- own publish does not overwrite the identity this case hands the session.
  local MspRuntime = assert(find(Home.run, "MspRuntime"), "message runtime missing")
  MspRuntime.tick = function() end
  MspRuntime.isFblConnected = function() return true end
  local session = _G.rfsuite.session
  -- The id first, the model's stored settings a few passes later, as the connection delivers them.
  -- The page writes the session's table for the model, its dashboard section included, so a key
  -- only the session's table carries shows in the file exactly when the page wrote the model's file.
  local function deliverModel()
    session.mcu_id = MCU
    runFor(3)
    local loaded = MP.loadByMcuId(MCU, true)
    if type(loaded.dashboard) ~= "table" then loaded.dashboard = {} end
    loaded.dashboard.written_by_save = "yes"
    session.modelPreferences = loaded
    runFor(5)
  end
  -- The page's own state, as its combos leave it (setOptionalThemeFromId).
  local function pageState()
    local PageRegistry = find(Home.run, "PageRegistry") or find(Home.init, "PageRegistry")
    local page = PageRegistry and PageRegistry.byMenuId and PageRegistry.byMenuId[PAGE]
    local pageUi = page and type(page.build) == "function" and find(page.build, "ui")
    expect(type(pageUi) == "table" and type(pageUi.config) == "table", "the page's own state was not found (instrument)")
    return type(pageUi) == "table" and type(pageUi.config) == "table" and pageUi or nil
  end
  local function fileOf(mcu)
    local loaded = MP.loadByMcuId(mcu, true) or {}
    return loaded.dashboard or {}
  end

  if case == "savebeforeread" then
    -- The identity and the model's settings arrive, and Save is pressed in that same pass, before
    -- the page has read them: what the page holds are the defaults it showed without a model, and
    -- they must not reach the model's file.
    expect(type(pressSave) == "function", "the header's Save was not found (instrument)")
    session.mcu_id = MCU
    local loaded = MP.loadByMcuId(MCU, true)
    if type(loaded.dashboard) ~= "table" then loaded.dashboard = {} end
    loaded.dashboard.written_by_save = "yes"
    session.modelPreferences = loaded
    if pressSave then pressSave() end
    runFor(10)
    local dash = fileOf(MCU)
    expect(dash.written_by_save == nil, "Save wrote the model's file before the page had read it")
    expect(dash.overrides == true and dash.model_theme_preflight == own,
      "the model's file changed under a Save made before the page read it: overrides="
      .. tostring(dash.overrides) .. ", theme=" .. tostring(dash.model_theme_preflight))
  end

  if case ~= "savebeforeread" then
    deliverModel()
    expect(session.mcu_id == MCU and type(session.modelPreferences) == "table",
      "the identity did not stay in the session (instrument)")
  end

  if case == "otherfc" then
    -- Another flight controller, with settings of its own, is identified while the page still holds
    -- the first one's, and Save is pressed before the page has read the second: nothing of the first
    -- one's may reach the second one's file.
    local MCU_B = "fedcba9876543210"
    local seededB = MP.loadByMcuId(MCU_B, true) or {}
    local otherTheme = themes[1] and themes[1].path
    expect(otherTheme ~= nil and otherTheme ~= own, "no second theme for the second model (instrument)")
    seededB.dashboard = { overrides = false, model_override = false, model_theme_preflight = otherTheme }
    expect(MP.saveByMcuId(MCU_B, seededB) ~= false, "the second model's file could not be written (instrument)")
    session.mcu_id = MCU_B
    local loadedB = MP.loadByMcuId(MCU_B, true)
    loadedB.dashboard.written_by_save = "yes"
    session.modelPreferences = loadedB
    if pressSave then pressSave() end
    runFor(10)
    local dashB = fileOf(MCU_B)
    expect(dashB.written_by_save == nil, "Save wrote the second model's file with the first one's settings")
    expect(dashB.overrides == false and dashB.model_theme_preflight == otherTheme,
      "the second model's file changed: overrides=" .. tostring(dashB.overrides)
      .. ", theme=" .. tostring(dashB.model_theme_preflight))
    local dashA = fileOf(MCU)
    expect(dashA.written_by_save == nil and dashA.model_theme_preflight == own,
      "the first model's file changed although its flight controller was gone")
  end

  if case == "removedtheme" then
    -- The model's file names a theme that is no longer installed; the page drops it to "nil" when it
    -- draws. That is not the pilot's edit: a Save with the link gone must not report the model's
    -- settings as not saved.
    local pageUi = pageState()
    local MCU_C = "00112233aabbccdd"
    local seededC = MP.loadByMcuId(MCU_C, true) or {}
    seededC.dashboard = { overrides = true, model_override = true, model_theme_preflight = "system/no_such_theme" }
    expect(MP.saveByMcuId(MCU_C, seededC) ~= false, "the model's file could not be written (instrument)")
    -- Another flight controller is identified, so the page reads its model half and draws it.
    session.mcu_id = nil
    session.modelPreferences = nil
    runFor(3)
    session.mcu_id = MCU_C
    session.modelPreferences = MP.loadByMcuId(MCU_C, true)
    runFor(5)
    expect(pageUi ~= nil and pageUi.config.model_theme_preflight == "nil",
      "the page did not drop the missing theme (control): " .. tostring(pageUi and pageUi.config.model_theme_preflight))
    session.mcu_id = nil
    session.modelPreferences = nil
    runFor(5)
    state.saveOutcome = nil
    if pressSave then pressSave() end
    runFor(10)
    local message = state.saveOutcome and tostring(state.saveOutcome.message) or ""
    expect(string.find(message, "Connect the flight controller", 1, true) == nil,
      "a theme the page dropped by itself was reported as an unsaved model edit: " .. message)
    expect(pageUi ~= nil and pageUi.dirty == false, "the page stayed unsaved after a Save with nothing edited")
  end

  if case == "offlinesave" then
    -- The pilot picks another theme for the model, the link drops, and Save is pressed with no
    -- flight controller identified: the model's half cannot be written, so the page must not report
    -- the save as done and must stay unsaved.
    local pageUi = pageState()
    local edited = themes[1] and themes[1].path
    expect(edited ~= nil and edited ~= own, "no second theme to pick (instrument)")
    if pageUi then
      pageUi.config.model_theme_preflight = edited
      pageUi.dirty = true
    end
    session.mcu_id = nil
    session.modelPreferences = nil
    runFor(5)
    expect(type(pressSave) == "function", "the header's Save was not found (instrument)")
    state.saveOutcome = nil
    if pressSave then pressSave() end
    runFor(10)
    local dash = fileOf(MCU)
    expect(dash.written_by_save == nil and dash.model_theme_preflight == own,
      "the model's file changed with no flight controller identified (control)")
    expect(pageUi ~= nil and pageUi.dirty == true, "the model's unsaved pick no longer counts as unsaved after Save")
    local outcome = state.saveOutcome
    local message = outcome and tostring(outcome.message) or ""
    expect(string.find(message, "Connect the flight controller", 1, true) ~= nil,
      "Save did not say that the model's settings were not saved: " .. message)
    -- The same flight controller comes back, and Save now writes the pick.
    deliverModel()
    state.saveOutcome = nil
    if pressSave then pressSave() end
    runFor(10)
    dash = fileOf(MCU)
    expect(dash.model_theme_preflight == edited, "the pick was not written once the flight controller was back: "
      .. tostring(dash.model_theme_preflight))
    expect(pageUi ~= nil and pageUi.dirty == false, "the page stayed unsaved after the pick was written")
  end

  local edited = nil
  if case == "linkdrop" then
    -- The pilot picks another theme for the model and has not saved yet: the page's own state, as
    -- its combo leaves it (setOptionalThemeFromId).
    local PageRegistry = find(Home.run, "PageRegistry") or find(Home.init, "PageRegistry")
    local page = PageRegistry and PageRegistry.byMenuId and PageRegistry.byMenuId[PAGE]
    local pageUi = page and type(page.build) == "function" and find(page.build, "ui")
    expect(type(pageUi) == "table" and type(pageUi.config) == "table", "the page's own state was not found (instrument)")
    edited = themes[1] and themes[1].path
    expect(edited ~= nil and edited ~= own, "no second theme to pick (instrument)")
    if type(pageUi) == "table" and type(pageUi.config) == "table" then
      pageUi.config.model_theme_preflight = edited
      pageUi.dirty = true
    end
    -- The link drops for a moment and comes back to the same flight controller: the connection
    -- clears the id and the model's settings, then delivers them again.
    local OWN = "Own settings for this model"
    expect(lastTexts[OWN] == true, "the model's controls were not on screen before the drop (control)")
    session.mcu_id = nil
    session.modelPreferences = nil
    runFor(5)
    expect(lastTexts[OWN] ~= true, "the model's controls stayed on screen with no flight controller identified")
    deliverModel()
    expect(lastTexts[OWN] == true, "the model's controls did not come back with the same flight controller")
  end
  if case == "themesave" or case == "linkdrop" then
    expect(state.fblConnected == true and state.activePageMenuId == PAGE, "the page was left when the flight controller answered")
    expect(type(pressSave) == "function", "the header's Save was not found (instrument)")
    if pressSave then pressSave() end
    runFor(10)
    local after = MP.loadByMcuId(MCU, true) or {}
    local dash = after.dashboard or {}
    expect(dash.written_by_save == "yes", "Save did not write the model's file at all (the model half was skipped)")
    expect(dash.overrides == true, "Save switched the model's own settings off: overrides=" .. tostring(dash.overrides))
    local wanted = edited or own
    expect(dash.model_theme_preflight == wanted, "the model's theme after Save is " .. tostring(dash.model_theme_preflight)
      .. ", expected " .. tostring(wanted) .. (edited and " (the pilot's unsaved pick)" or " (the model's own)"))
  end
end

if case == "compile" or case == "restart" or case == "both" then
  -- A new install: the pass holds the start screen, with the link up, and the menu follows as soon
  -- as it is through, without waiting for a flight controller that never answers here.
  expect(state.initialLoad == true, "a compile pass does not hold the start screen")
  expect(Precompile ~= nil and Precompile.isRunning(), "no compile pass after an install (control)")
  local passes = 0
  while Precompile.isRunning() and passes < 300 do
    runFor(1)
    passes = passes + 1
    if Precompile.isRunning() then
      expect(state.initialLoad == true, "the start screen left while the pass was running")
    end
  end
  expect(not Precompile.isRunning(), "the pass did not finish")
  local after = 0
  while state.initialLoad and after < 100 do
    runFor(1)
    after = after + 1
  end
  expect(state.initialLoad == false and after <= 2,
    "the start screen stood " .. after .. " passes after the pass was through")
  expect(logged("(compile pass done)") ~= nil, "the log does not say why the start screen left")
  expect(startBuilds >= 1, "the start screen was never drawn while compiling (control)")
end

-- The notices drawn over the menu, by kind: the one on screen and the Close it carries. A notice
-- that comes back after its Close shows up here again, so "once" is countable.
local notices = { current = nil, press = nil, drawn = {} }
do
  local LoadingOverlay = _G.rfsuite.require("ui/loading_overlay.lua")
  expect(type(LoadingOverlay) == "table" and type(LoadingOverlay.appendNotice) == "function",
    "the notice module was not found (instrument)")
  local realNotice = LoadingOverlay.appendNotice
  LoadingOverlay.appendNotice = function(lyt, opts)
    local msg = type(opts) == "table" and opts.message or ""
    local kind = (string.find(msg, "not moved", 1, true) and "moved")
      or (string.find(msg, "updated and prepared", 1, true) and "restart") or nil
    if kind then
      if notices.current ~= kind then notices.drawn[#notices.drawn + 1] = kind end
      notices.current = kind
      notices.press = opts.press
    end
    return realNotice(lyt, opts)
  end
end
local function closeNotice()
  local press = notices.press
  notices.current, notices.press = nil, nil
  if press then press() end
  runFor(5)
end

if case == "restart" or case == "both" or case == "movefailed" then
  Home.requestRebuild(false)
  runFor(3)
end

if case == "restart" then
  -- The pass rebuilt a packaged tree, so the radio has to be restarted once; the request is the
  -- screen that follows the start screen.
  expect(state.restartNoticeVisible == true, "the restart request did not follow the pass")
  expect(notices.current == "restart", "the restart request was not drawn: " .. tostring(notices.current))
  closeNotice()
  expect(notices.current == nil, "a notice came back after Close: " .. tostring(notices.current))
  expect(state.moveFailedNoticeVisible == false, "a failed move is told although nothing failed")
end

if case == "movefailed" then
  expect(state.initialLoad == false, "the start screen still stands after init (control)")
  expect(state.moveFailedNoticeVisible == true, "the failed move is not told over the menu")
  expect(notices.current == "moved", "no notice saying that the settings were not moved: " .. tostring(notices.current))
  local before = builds
  closeNotice()
  expect(notices.current == nil, "the failed-move notice came back after Close")
  expect(state.moveFailedNoticeVisible == false, "Close did not dismiss the notice")
  expect(builds > before, "nothing was drawn after Close (control)")
  expect(state.isClosing ~= true and state.shouldExit ~= true, "the tool closes after the notice")
  expect(#notices.drawn == 1, "notices drawn: " .. table.concat(notices.drawn, ","))
end

if case == "both" then
  -- A rebuilding pass AND a failed move: the restart request first, the failed move after its Close,
  -- each once, and the tool stays open.
  expect(notices.current == "restart", "the restart request did not come first: " .. tostring(notices.current))
  closeNotice()
  expect(notices.current == "moved", "the failed move was not told after the restart request: "
    .. tostring(notices.current))
  closeNotice()
  expect(notices.current == nil, "a notice came back: " .. tostring(notices.current))
  expect(table.concat(notices.drawn, ",") == "restart,moved", "notices drawn: " .. table.concat(notices.drawn, ","))
  expect(state.shouldExit ~= true, "the tool closes although no data was moved")
end

print("CHECKS " .. checks)
