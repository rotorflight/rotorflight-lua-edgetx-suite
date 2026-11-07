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

local CASES = { "nolink", "link", "pagefirst", "compile", "movefailed", "restart", "both" }

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
lvgl.build = function(...)
  builds = builds + 1
  if state.initialLoad then startBuilds = startBuilds + 1 end
  return realBuild(...)
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

Home.init({})
local Precompile = find(Home.run, "Precompile")

if case == "nolink" or case == "link" or case == "pagefirst" then
  expect(state.initialLoad == false, "the start screen still stands after init with nothing to compile")
  expect(builds >= 1, "init built nothing (control)")
  expect(startBuilds == 0, "the start screen was drawn " .. startBuilds .. " times with nothing to compile")
  expect(logged("not drawn") ~= nil, "the log does not say that the start screen was not drawn")
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
  -- are greyed out; then it answers, and they enable where they stand. The tool's own focus index
  -- is kept; the focus LVGL draws is not modelled by these stubs and is not checked here.
  expect(state.fblConnected == false, "the flight controller counts as connected before it answered (control)")
  expect(state.menu.isRootEntryEnabled("configuration", "setup") == false,
    "Setup is enabled before the flight controller answered")
  state.focusIndex = 3
  local MspRuntime = assert(find(Home.run, "MspRuntime"), "message runtime missing")
  MspRuntime.isFblConnected = function() return true end
  local before = builds
  runFor(3)
  expect(state.fblConnected == true, "the tool did not see the flight controller answer")
  expect(state.menu.isRootEntryEnabled("configuration", "setup") == true,
    "Setup stayed greyed out after the flight controller answered")
  expect(builds > before, "the menu was not drawn again when the flight controller answered")
  expect(state.focusIndex == 3, "the tool's focus index changed when the tiles enabled: " .. tostring(state.focusIndex))
  expect(state.initialLoad == false and startBuilds == 0, "the start screen came back")
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
