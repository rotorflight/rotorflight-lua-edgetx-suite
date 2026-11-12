-- ui/home.lua, run inside the dashboard widget, draws a page it has just opened on the pass after
-- the one that builds it: that pass shows a notice and keeps the layout, and the next pass makes the
-- widgets from it with the whole instruction limit before it. A rebuild of the page while it is open
-- is drawn at once, a layout whose menu has moved on is dropped, and the tool run as a tool script
-- draws a page in the pass that builds it. Runs on the accounting stubs.
--   lua5.3 bin/ui/verify_page_draw_next_pass.lua
local NAME = "page draw next pass"
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
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
Home.init({})
for _ = 1, 40 do Stubs.tick(); Home.run(0) end

local state = assert(find(Home.run, "state"), "home state missing")
local M = assert(find(Home.run, "M"), "home module table missing")
local ensure = assert(find(Home.run, "ensurePageRegistry"), "page registry loader missing")
state.initialLoad = false

ensure()
local registry = assert(find(Home.run, "PageRegistry"), "page registry missing")

-- A page whose one row is a choice: lvgl.build reads its value through `get` while it makes it.
local MARK = "draw-next-pass row"
local builds = 0
local function testPage()
  return {
    build = function(ctx)
      builds = builds + 1
      ctx.children[#ctx.children + 1] = { type = "choice", title = MARK, values = { "a", "b" },
        get = function() return 1 end, set = function() end }
    end,
    getHeaderActions = function() return {} end
  }
end
registry.byMenuId.test_draw_a = testPage()
registry.byMenuId.test_draw_b = testPage()

local current = "test_draw_a"
local menu = state.menu
local realId, realRoot = menu.getCurrentMenuId, menu.isRoot
menu.getCurrentMenuId = function() return current end
menu.isRoot = function() return false end

-- Whether what lvgl.build was last handed holds the test page's row.
local function holds(node, depth)
  if type(node) ~= "table" or depth > 6 then return false end
  if node.title == MARK then return true end
  for _, child in pairs(node) do
    if type(child) == "table" and holds(child, depth + 1) then return true end
  end
  return false
end
local function drawn()
  local trees = Stubs.lvgl.trees
  return holds(trees[#trees], 0)
end
local function notice()
  local trees = Stubs.lvgl.trees
  local tree = trees[#trees]
  return type(tree) == "table" and type(tree[1]) == "table" and tree[1].type == "rectangle"
    and type(tree[2]) == "table" and tree[2].type == "label"
end

local function pass()
  Stubs.tick()
  Home.run(0)
end

-- Hosted: the open builds the page and shows the notice; the next pass draws it.
state.hosted = true
state.pendingBuildUI = false
M.buildUI()
equal(builds, 1, "hosted: the open builds the page")
equal(drawn(), false, "hosted: the pass that builds an opened page does not draw it")
equal(notice(), true, "hosted: that pass shows the notice")
equal(state.pendingLayout ~= nil, true, "hosted: the layout is kept for the next pass")
pass()
equal(drawn(), true, "hosted: the next pass draws the page")
equal(builds, 1, "hosted: drawing does not build the page again")
equal(state.pendingLayout, nil, "hosted: nothing is left waiting once it is drawn")

-- A rebuild while the page is open is drawn in the pass that builds it.
M.buildUI()
equal(builds, 2, "hosted: a rebuild builds the page")
equal(drawn(), true, "hosted: a rebuild is drawn at once")
equal(state.pendingLayout, nil, "hosted: a rebuild leaves nothing waiting")

-- A layout whose menu has moved on before its pass is dropped, and the new page is drawn the same way.
current = "test_draw_b"
M.buildUI()
equal(notice(), true, "hosted: a second page opened shows the notice")
current = "test_draw_a"
state.pendingBuildUI = false
local before = #Stubs.lvgl.trees
pass()
equal(drawn() and #Stubs.lvgl.trees > before, false, "hosted: a layout whose menu moved on is not drawn")
equal(state.pendingLayoutMenuId, "test_draw_a", "hosted: the screen is built again, in that pass, for where the menu is now")
pass()
equal(drawn(), true, "hosted: the page the menu moved back to is drawn on the pass after")
equal(state.pendingLayout, nil, "hosted: nothing is left waiting")

-- Closing drops a layout that has not been drawn.
current = "test_draw_b"
M.buildUI()
equal(state.pendingLayout ~= nil, true, "hosted: a page opened just before the close waits")
state.isClosing = true
pass()
equal(state.pendingLayout, nil, "hosted: the close drops it")
state.isClosing = false
state.closeTicks = nil

-- Control: the tool run as a tool script draws an opened page in the pass that builds it.
state.hosted = false
current = "test_draw_a"
state.activePageMenuId = nil
M.buildUI()
equal(drawn(), true, "tool script: an opened page is drawn in the pass that builds it (control)")
equal(state.pendingLayout, nil, "tool script: nothing is kept for a next pass (control)")

menu.getCurrentMenuId, menu.isRoot = realId, realRoot

print(string.format("%s: %d checks, %d failures", NAME, checks, failures))
if failures > 0 then os.exit(1) end
