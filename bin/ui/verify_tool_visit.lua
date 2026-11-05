-- A visit to the tool from the dashboard's rolling menu: the real ui/home.lua on the accounting stubs.
--   lua5.3 bin/ui/verify_tool_visit.lua
-- What is checked: the landing is walked with the conditions as they stand, so a page that needs the
-- flight controller opens hosted; a visit the menu refuses closes the tool rather than showing its tiles, and
-- the landing of a key keeps opening the menu in that case; the back key walks the tool's levels down
-- to the edge of the visit and closes it there; a link lost on a visit closes the tool.
-- No pixels or timing are measured. Exit 0 green, 1 failed checks.

local checks, failures = 0, 0
local function check(ok, label, detail)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label .. (detail and (": " .. tostring(detail)) or ""))
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

local Home = assert(loadfile("src/rfsuite/ui/home.lua"))()

-- The answer the tool reads for "has the flight controller answered", set per case.
local connected = true
local function openWith(landing, visit)
  Home.init({ hosted = true, landing = landing, visit = visit })
  local state = assert(find(Home.run, "state"), "home state missing")
  return state
end
do
  -- Whatever the runtime module says, this is the reading under test.
  local readFbl = assert(find(Home.init, "readFblConnected"), "readFblConnected missing")
  local i = 1
  while true do
    local name, value = debug.getupvalue(readFbl, i)
    if not name then break end
    if name == "MspRuntime" then
      debug.upvaluejoin(readFbl, i, function() return value end, 1)
      debug.setupvalue(readFbl, i, { isFblConnected = function() return connected end })
    end
    i = i + 1
  end
end

local PAGE = "setup_mixer_tail_page"

local function hidden(name)
  local M = assert(find(Home.run, "M"), "home module table missing")
  return assert(find(Home.run, name) or find(Home.init, name) or find(M.buildUI, name), name .. " missing")
end

-- Connected: a page that needs the flight controller opens.
do
  connected = true
  local state = openWith(PAGE, true)
  check(state.menu.getCurrentMenuId() == PAGE, "a visit opens a flight controller page", state.menu.getCurrentMenuId())
  check(state.landingMenuId == PAGE and state.visitMenuId == PAGE, "and is the edge of the tool")
  check(state.isClosing ~= true and Home.landingRefused() == false, "and nothing refused it")
end

-- Not connected: the menu refuses it. A visit ends; never the tiles in its place.
do
  connected = false
  local state = openWith(PAGE, true)
  check(Home.landingRefused() == true and state.isClosing == true, "a refused visit closes the tool")
  check(state.menu.isRoot(), "with the menu back at its root")
end

-- A key's landing is no visit: refused, the tool opens on its menu as it always has.
do
  connected = false
  local state = openWith(PAGE, nil)
  check(Home.landingRefused() == false and state.isClosing ~= true, "a key's refused landing stays in the tool")
  check(state.visitMenuId == nil, "and has no edge")
end

-- The edge of a visit survives the pages below it, where the landing's mark alone would not.
do
  connected = true
  local MENU = "esc_motors_menu"
  local state = openWith(MENU, true)
  check(state.menu.getCurrentMenuId() == MENU, "a visit opens a menu with its tiles")
  local leave = hidden("leaveCurrentPage")
  local sync = hidden("syncActivePageModule")
  sync()
  check(state.menu.openEntry("throttle"), "a page below it opens")
  sync()
  check(state.landingMenuId == MENU, "the edge stays through the page below")
  leave()
  check(state.isClosing ~= true and state.menu.getCurrentMenuId() == MENU, "the back key steps up to the edge", state.menu.getCurrentMenuId())
  state.lastBackTick = 0
  leave()
  check(state.isClosing == true, "and closes the tool there")
end

-- Control: without a visit the mark is gone once another page is up, as it always was.
do
  connected = true
  local MENU = "esc_motors_menu"
  local state = openWith(MENU, nil)
  local sync = hidden("syncActivePageModule")
  sync()
  state.menu.openEntry("throttle")
  sync()
  check(state.landingMenuId == nil, "a key's landing mark goes with its page (control)")
end

-- A link lost on a visit closes the tool; off a visit it walks to the root.
do
  connected = true
  local state = openWith(PAGE, true)
  local lost = hidden("returnToRootOnDisconnect")
  lost()
  check(state.isClosing == true and state.menu.getCurrentMenuId() == PAGE, "a link lost on a visit closes the tool")
  state = openWith(PAGE, nil)
  state.isClosing = false
  lost()
  check(state.isClosing ~= true and state.menu.isRoot(), "off a visit it walks to the root (control)")
end

-- A save that holds the page keeps it through the lost link its restart causes.
do
  connected = true
  local state = openWith(PAGE, true)
  local lost = hidden("returnToRootOnDisconnect")
  local i = 1
  while true do
    local name, value = debug.getupvalue(lost, i)
    if not name then break end
    if name == "SavePipeline" then
      debug.upvaluejoin(lost, i, function() return value end, 1)
      debug.setupvalue(lost, i, { blocksNavigation = function() return true end, hasOutcome = function() return false end })
    end
    i = i + 1
  end
  lost()
  check(state.isClosing ~= true and state.menu.getCurrentMenuId() == PAGE, "a save holding the page keeps it through a lost link")
end

print(checks .. " checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
