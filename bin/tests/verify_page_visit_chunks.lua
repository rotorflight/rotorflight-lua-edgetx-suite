-- A page that sets visitMenu has the chunks under its own folder let go once the pilot has left
-- its area, in the loader of the tool started from the Tools menu (src/main.lua) and in the one
-- the dashboard installs for the hosted tool (widgets/dashboard/tool_host.lua). Moving between
-- the area's menu and its pages keeps them; files outside the folder and pages without the
-- declaration keep theirs. Runs from the repository root under lua5.3.
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local paths = dofile("src/rfsuite/lib/paths.lua")
local CORE = paths.core .. "/"
local WIZARD = CORE .. "app/pages/helicopter_setup/"
local WIZARD_FILE = WIZARD .. "controller.lua"
local WIZARD_STEP = WIZARD .. "steps/swash.lua"
local SHARED_FILE = CORE .. "tasks/msp/api/status.lua"
local OTHER_PAGE_FILE = CORE .. "app/pages/settings/general/helpers.lua"

-- The radio's loader: a new function for every call, counted per path, so a file read from the
-- card again shows as a second load and a kept chunk as the same function.
local reads = {}
local wizardPage = { visitMenu = "helicopter_setup_menu", closed = 0 }
function wizardPage.onClose() wizardPage.closed = wizardPage.closed + 1 end
local plainPage = { closed = 0 }
function plainPage.onClose() plainPage.closed = plainPage.closed + 1 end
local home = { init = function() end, run = function() return 0 end }

local function radioLoadScript(path)
  reads[path] = (reads[path] or 0) + 1
  if path == WIZARD .. "page.lua" then return function() return wizardPage end end
  if path == CORE .. "app/pages/settings/general/page.lua" then return function() return plainPage end end
  if path == CORE .. "ui/home.lua" then return function() return home end end
  if path == CORE .. "lib/require.lua" then return function() end end
  -- An upvalue, so every read is a function object of its own: Lua reuses a closure without
  -- upvalues, which would make every file's chunk the same object.
  return function() return { path = path } end
end

local function resetGlobals()
  reads = {}
  _G.rfsuite = { paths = paths, utils = {}, session = {} }
  _G.loadScript = radioLoadScript
end

local function collected(weak)
  collectgarbage("collect")
  collectgarbage("collect")
  return next(weak) == nil
end

-- Walks one loader through the area: chunks loaded, the page released towards its own menu and
-- towards another of its entries (kept), then towards the main menu (let go). `cacheOf` returns
-- the loader's chunk table where the test can see it, or nil.
local function walkArea(label)
  wizardPage.closed, plainPage.closed = 0, 0
  local registry = assert(loadfile("src/rfsuite/app/pages/init.lua"))()
  equal(type(registry.endVisits), "function", label .. " registry ends visits")
  equal(type(_G.rfsuite.utils.releaseChunksUnder), "function", label .. " loader publishes its release hook")
  if type(registry.endVisits) ~= "function" then return end

  local wizardChunk = loadScript(WIZARD_FILE, "t")
  loadScript(WIZARD_STEP, "t")
  local sharedChunk = loadScript(SHARED_FILE, "t")
  local otherChunk = loadScript(OTHER_PAGE_FILE, "t")
  equal(loadScript(WIZARD_FILE, "t"), wizardChunk, label .. " a wizard file is kept while the wizard is open")
  equal(reads[WIZARD_FILE], 1, label .. " a wizard file is read once while the wizard is open")

  equal(registry.get("helicopter_setup_page"), wizardPage, label .. " wizard page loaded")
  registry.release("helicopter_setup_page", {})
  equal(wizardPage.closed, 1, label .. " wizard page closed")
  local ended = registry.endVisits("helicopter_setup_menu")
  equal(ended, 0, label .. " back on the wizard's own menu the visit goes on")
  equal(registry.get("helicopter_setup_step_04_page"), wizardPage, label .. " a step entry opens the same page")
  registry.release("helicopter_setup_step_04_page", {})
  ended = registry.endVisits("helicopter_setup_step_05_page")
  equal(ended, 0, label .. " another entry of the same page keeps the visit")
  equal(loadScript(WIZARD_FILE, "t"), wizardChunk, label .. " moving inside the area reads nothing again")
  equal(reads[WIZARD_FILE], 1, label .. " moving inside the area reads a wizard file once")

  -- Outside the area: the main menu.
  -- Only weak references from here on; a strong one in this frame would keep the chunk alive.
  local weak = setmetatable({}, { __mode = "k" })
  local keptWeak = setmetatable({}, { __mode = "k" })
  local function watch() weak[loadScript(WIZARD_FILE, "t")] = true; keptWeak[loadScript(SHARED_FILE, "t")] = true end
  watch()
  wizardChunk, sharedChunk = nil, nil
  registry.release("helicopter_setup_step_05_page", {})
  local chunks
  ended, chunks = registry.endVisits("configuration_menu")
  equal(ended, 1, label .. " leaving the area ends the visit")
  equal(chunks, 2, label .. " the wizard folder's two chunks are let go")
  equal(collected(weak), true, label .. " a let-go wizard chunk is collectable")
  equal(collected(keptWeak), false, label .. " a shared chunk stays (control)")
  loadScript(WIZARD_FILE, "t")
  equal(reads[WIZARD_FILE], 2, label .. " the next wizard visit reads the file from the card again")
  equal(keptWeak[loadScript(SHARED_FILE, "t")], true, label .. " a file outside the folder keeps its chunk")
  equal(reads[SHARED_FILE], 1, label .. " a file outside the folder is read once")
  ended = registry.endVisits("configuration_menu")
  equal(ended, 0, label .. " an ended visit does not end twice")

  -- A page without visitMenu keeps its folder's chunks.
  equal(registry.get("settings_general_page"), plainPage, label .. " plain page loaded")
  registry.release("settings_general_page", {})
  ended = registry.endVisits("configuration_menu")
  equal(ended, 0, label .. " a page without visitMenu ends no visit")
  equal(loadScript(OTHER_PAGE_FILE, "t"), otherChunk, label .. " a page without visitMenu keeps its chunks")
end

-- 1. The tool started from the Tools menu: src/main.lua's loader.
resetGlobals()
local mainChunk = assert(loadfile("src/main.lua"))
mainChunk()
walkArea("standalone")

-- 1b. A pass stopped inside the release leaves the visit open, and the next change finishes it.
do
  resetGlobals()
  assert(loadfile("src/main.lua"))()
  local registry = assert(loadfile("src/rfsuite/app/pages/init.lua"))()
  if type(registry.endVisits) == "function" then
    loadScript(WIZARD_FILE, "t")
    registry.get("helicopter_setup_page")
    registry.release("helicopter_setup_page", {})
    local real = _G.rfsuite.utils.releaseChunksUnder
    _G.rfsuite.utils.releaseChunksUnder = function() error("stopped") end
    equal(pcall(registry.endVisits, "configuration_menu"), false, "a stopped release raises to the caller")
    _G.rfsuite.utils.releaseChunksUnder = real
    local ended, chunks = registry.endVisits("configuration_menu")
    equal(ended, 1, "the next change ends the visit a stopped release left open")
    equal(chunks, 1, "and lets go of its chunk")
  else
    equal(type(registry.endVisits), "function", "retry: registry ends visits")
  end
end

-- 2. The tool opened from the dashboard: tool_host's loader, installed on the first pass.
resetGlobals()
local stubs = {
  ["lib/log.lua"] = { emit = function() end, emitf = function() end, wanted = function() return false end },
  ["lib/armed.lua"] = { isArmed = function() return false end },
  ["tasks/msp/runtime.lua"] = { getState = function() return { queue = {} } end },
  ["tasks/msp/save_pipeline.lua"] = {},
}
_G.rfsuite.require = function(path) return stubs[path] end
_G.rfsuite.loadMode = "bt"
local Host = assert(loadfile("src/rfsuite/widgets/dashboard/tool_host.lua"))()
local widget = {}
equal(Host.request(widget), true, "hosted tool asked for")
Host.step(widget, 0)
equal(widget._toolHost and widget._toolHost.loader ~= nil, true, "hosted loader installed")
walkArea("hosted")
local hook = _G.rfsuite.utils.releaseChunksUnder
Host.abandon(widget, "test")
equal(_G.rfsuite.utils.releaseChunksUnder == nil or _G.rfsuite.utils.releaseChunksUnder ~= hook, true,
  "hosted release hook taken back when the tool closes")

-- 3. A stop at any instruction of a load or of the release leaves nothing kept that the release
-- can no longer find. In the dashboard's widget state the radio raises its CPU limit from an
-- instruction-count hook, so the error can land between any two writes of either function; a
-- count hook here stops the function at its 1st, 2nd, 3rd ... instruction until a pass completes.
-- After each stopped pass the area is released again, and the next load must read the file from
-- the card: a chunk kept but no longer listed would be handed back from the cache instead.
local function standaloneLoader()
  resetGlobals()
  assert(loadfile("src/main.lua"))()
  return _G.loadScript, _G.rfsuite.utils.releaseChunksUnder
end

local function hostedLoader()
  resetGlobals()
  _G.rfsuite.require = function(path) return stubs[path] end
  _G.rfsuite.loadMode = "bt"
  local host = assert(loadfile("src/rfsuite/widgets/dashboard/tool_host.lua"))()
  local w = {}
  host.request(w)
  host.step(w, 0)
  return _G.loadScript, _G.rfsuite.utils.releaseChunksUnder
end

-- Runs `fn(...)` under pcall, raising "CPU limit" at the n-th instruction executed inside `target`
-- itself (instructions of the functions it calls are not counted). Returns pcall's status.
local function stopAt(n, target, fn, ...)
  local count = 0
  debug.sethook(function()
    if debug.getinfo(2, "f").func == target then
      count = count + 1
      if count == n then error("CPU limit") end
    end
  end, "", 1)
  local ok = pcall(fn, ...)
  debug.sethook()
  return ok
end

local function sweep(label, makeLoader)
  -- The release, stopped at every instruction in turn, with the wizard file kept beforehand.
  local stopped, n = 0, 0
  repeat
    n = n + 1
    local load, release = makeLoader()
    -- The kept chunk is watched weakly, from a helper, so nothing in this frame holds it.
    local weak = setmetatable({}, { __mode = "k" })
    local function watch() weak[load(WIZARD_FILE, "t")] = true end
    watch()
    local ok = stopAt(n, release, release, WIZARD)
    if not ok then stopped = stopped + 1 end
    local kept = not collected(weak)
    equal(release(WIZARD), kept and 1 or 0,
      label .. " release stopped at instruction " .. n .. ": the next release counts only a chunk still kept")
    load(WIZARD_FILE, "t")
    equal(reads[WIZARD_FILE], 2, label .. " release stopped at instruction " .. n .. ": the next load reads the card")
  until ok or n >= 200
  equal(stopped > 0, true, label .. " release sweep stopped the release at least once (control)")
  equal(n < 200, true, label .. " release sweep reached a pass that completes (control)")

  -- A load, stopped at every instruction in turn, then the release.
  stopped, n = 0, 0
  repeat
    n = n + 1
    local load, release = makeLoader()
    local ok = stopAt(n, load, load, WIZARD_FILE, "t")
    if not ok then stopped = stopped + 1 end
    release(WIZARD)
    local before = reads[WIZARD_FILE] or 0
    load(WIZARD_FILE, "t")
    equal(reads[WIZARD_FILE], before + 1, label .. " load stopped at instruction " .. n .. ": after the release the card is read")
  until ok or n >= 200
  equal(stopped > 0, true, label .. " load sweep stopped the load at least once (control)")
  equal(n < 200, true, label .. " load sweep reached a pass that completes (control)")
end

sweep("standalone", standaloneLoader)
sweep("hosted", hostedLoader)

print("Page visit chunks: " .. checks .. " assertions, " .. failures .. " failures")
if failures > 0 then os.exit(1) end
