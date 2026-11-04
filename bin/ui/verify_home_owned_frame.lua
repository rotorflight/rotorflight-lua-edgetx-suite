-- ui/home.lua leaves its frame and its disconnect handling to a page that asks for it: no header over a
-- page with hideSuiteFrame, a body from the top under the armed strip, and no return to the root on a
-- link loss for a page with handlesDisconnect. Any other page keeps the host's. Runs on the accounting stubs.
--   lua5.3 bin/ui/verify_home_owned_frame.lua
local NAME = "home owned frame"
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
local returnToRoot = assert(find(Home.run, "returnToRootOnDisconnect"), "disconnect handler missing")
local ensure = assert(find(Home.run, "ensurePageRegistry"), "page registry loader missing")
local Header = assert(find(M.buildUI, "Header"), "header module missing")
state.initialLoad = false

ensure()
local registry = assert(find(Home.run, "PageRegistry"), "page registry missing")
local built
local owned = { hideSuiteFrame = true, handlesDisconnect = true,
  build = function(ctx) built = ctx end, getHeaderActions = function() return {} end }
local plain = { build = function(ctx) built = ctx end, getHeaderActions = function() return {} end }
registry.byMenuId.test_owned = owned
registry.byMenuId.test_plain = plain

local headers = 0
local append = Header.appendToLayout
Header.appendToLayout = function(...) headers = headers + 1; return append(...) end

local current = "test_owned"
local menu = state.menu
local realId, realRoot = menu.getCurrentMenuId, menu.isRoot
menu.getCurrentMenuId = function() return current end
menu.isRoot = function() return false end

local function draw()
  built, headers = nil, 0
  Stubs.lvgl.trees = {}
  M.buildUI()
end

draw()
equal(headers, 0, "a page that owns its frame gets no header")

current = "test_plain"
draw()
equal(headers, 1, "any other page keeps the header (control)")

-- The disconnect: a page that handles it stays; any other goes back to the root.
local active = find(Home.run, "getActivePageModule")
equal(type(active), "function", "the active page reader exists")
local closed = 0
local help = find(returnToRoot, "closeHelpDialogIfOpen")
equal(type(help), "function", "the help closer exists")
current = "test_owned"
local function setActive(page)
  for i = 1, 200 do
    local name = debug.getupvalue(returnToRoot, i)
    if not name then break end
    if name == "getActivePageModule" then
      debug.setupvalue(returnToRoot, i, function() return page end)
      return true
    end
  end
end
equal(setActive(owned), true, "the page reader can be set for this check")
state.pendingMenuOpen = "kept"
returnToRoot()
equal(state.pendingMenuOpen, "kept", "a page that handles the disconnect stays where it is")
setActive(plain)
returnToRoot()
equal(state.pendingMenuOpen, nil, "any other page goes back to the root (control)")

menu.getCurrentMenuId, menu.isRoot = realId, realRoot

print(string.format("%s: %d checks, %d failures", NAME, checks, failures))
if failures > 0 then os.exit(1) end
