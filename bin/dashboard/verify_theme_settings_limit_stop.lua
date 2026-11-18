-- A theme's settings page opened from the dashboard is built inside one widget call. EdgeTX
-- (radio/src/lua/widgets.cpp, luaHook) raises "CPU limit" once per call, past the instruction
-- limit, and then lets the call run on. This check runs the real page
-- (app/pages/settings/dashboard/settings/page.lua) under a hook that does the same, with the stop
-- put at one position of the call after another (every STEP instructions), and then builds again
-- the way ui/home.lua does: after a build stopped at the limit, a fresh call, at most
-- BUILD_LIMIT_RETRIES = 3 times; after any other error, the failure page at once; after a
-- Reload, stopped or not, one build.
--
-- Two calls are stopped: the cold build of the page, and its Reload after a whole build. Wherever
-- the stop lands, the page must end up as the unstopped run draws it -- the same elements, the
-- same labels and the same values in its controls: never "This theme's settings could not be
-- loaded", never fewer rows, never a control showing another value, never the failure page.
--
-- Run from the repository root: lua5.3 bin/dashboard/verify_theme_settings_limit_stop.lua
local Stubs = assert(loadfile("bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile("bin/accounting/stubs/fc.lua"))()

-- Theme, page: the module-heavy themes' first page, two box themes' phase pages, a page with many
-- rows.
local CASES = {
  { "system/grid", "look" },
  { "system/deck", "look" },
  { "system/default", "preflight" },
  { "system/@kse4", "postflight" },
  { "system/urban", "telemetry" },
}
-- How far apart the stop positions are, in instructions: through the cold build, and through a
-- Reload, which is shorter and whose module factory takes only a few dozen instructions.
local STEP = 400
local RELOAD_STEP = 50
-- What a retry pass leaves the build: the limit less the background work the pass runs beside it.
local RETRY_BUDGET = 16000
local RETRIES = 3

local failures, checks = 0, 0
local function fail(label)
  failures = failures + 1
  print("FAIL " .. label)
end

local function world()
  Stubs.install(".")
  FC.install(Stubs)
  Stubs.reset()
  FC.reset()
  Stubs.installTool()
end

local function hex(s)
  return (string.gsub(s, ".", function(c) return string.format("%02x", string.byte(c)) end))
end

local function loadPage()
  _G.rfsuite.paths = _G.rfsuite.paths or { core = "/SCRIPTS/RFSUITE/core" }
  return assert(loadScript(_G.rfsuite.paths.core .. "/app/pages/settings/dashboard/settings/page.lua", "t"))()
end

local function newCtx(menuId)
  return {
    children = {}, x = 0, y = 40, w = 480, h = 240, armed = false,
    i18n = nil, preferences = _G.rfsuite.preferences,
    menu = { getCurrentMenuId = function() return menuId end },
    requestRebuild = function() end, requestClose = function() end,
    openPage = function() end, openHelp = function() end,
    askUnsavedChanges = function() return true end,
    refresh = function() end,
  }
end

-- What a build drew, as one string: the type, the text and, for a control, the value its getter
-- answers, of every element in order.
local function shape(children)
  local out = {}
  for i = 1, #children do
    local c = children[i]
    local item = tostring(c.type) .. ":" .. tostring(c.text or c.label or "")
    if type(c.get) == "function" then
      local ok, value = pcall(c.get)
      item = item .. "=" .. (ok and tostring(value) or "error")
    end
    out[#out + 1] = item
  end
  return table.concat(out, "|")
end

-- The firmware's hook for one widget call: one raise past `limit` instructions, then line-only.
local used, limit
local function hook(event)
  if event == "count" then
    used = used + 1
    if used > limit then
      debug.sethook(hook, "l")
      error("CPU limit")
    end
  end
end

-- The hook is set and taken off inside the protected call, so a stop that falls on the last
-- instructions of the call is still the call's own.
local function underLimit(n, fn, ...)
  local args = table.pack(...)
  used, limit = 0, n
  local ok, err = pcall(function()
    debug.sethook(hook, "", 1)
    fn(table.unpack(args, 1, args.n))
    debug.sethook()
  end)
  debug.sethook()
  return ok, err
end

local function countOf(fn, ...)
  local n = 0
  debug.sethook(function() n = n + 1 end, "", 1)
  local ok, err = pcall(fn, ...)
  debug.sethook()
  if not ok then error(err, 0) end
  return n
end

local function isStop(err)
  return string.find(tostring(err), "CPU limit", 1, true) ~= nil
end

-- A build as the host runs it after a first call that answered `ok, err`: retried while it is
-- stopped at the limit, the failure page on any other error. Answers what the page ends up showing
-- and whether any call was stopped.
local function settle(Page, menuId, ok, err, drawn)
  local stopped, tries = false, 0
  while not ok do
    if not isStop(err) then return "the failure page (" .. tostring(err) .. ")", stopped end
    stopped = true
    tries = tries + 1
    if tries > RETRIES then return "the failure page", stopped end
    local ctx = newCtx(menuId)
    ok, err = underLimit(RETRY_BUDGET, Page.build, ctx)
    drawn = shape(ctx.children)
  end
  return drawn, stopped
end

local function compare(label, at, total, drawn, reference)
  checks = checks + 1
  if drawn ~= reference then
    local what = string.find(drawn, "could not be loaded", 1, true) and "'could not be loaded'"
      or (#drawn < #reference and "less than the unstopped run (fewer rows or a control without its value)")
      or drawn
    fail(string.format("%s: stopped at %d of %d instructions, the page ends with %s", label, at, total, what))
  end
end

for _, case in ipairs(CASES) do
  local theme, page = case[1], case[2]
  local menuId = "settings_dashboard_settings_" .. hex(theme) .. "_" .. page .. "_page"
  local label = theme .. " " .. page

  -- The cold build.
  world()
  local refCtx = newCtx(menuId)
  local total = countOf(loadPage().build, refCtx)
  local reference = shape(refCtx.children)
  -- Positive control: the unstopped build draws the theme's own rows, with their values.
  checks = checks + 1
  if #refCtx.children < 8 or string.find(reference, "could not be loaded", 1, true)
    or not string.find(reference, "=", 1, true) then
    fail(label .. ": the unstopped build drew no settings (" .. #refCtx.children .. " elements)")
  end

  local anyStopped = false
  for at = STEP, total, STEP do
    world()
    local Page = loadPage()
    local ctx = newCtx(menuId)
    local ok, err = underLimit(at, Page.build, ctx)
    local drawn, stopped = settle(Page, menuId, ok, err, shape(ctx.children))
    anyStopped = anyStopped or stopped
    compare(label .. " (cold build)", at, total, drawn, reference)
  end
  -- The stop has to land inside the build at all, or nothing above was tested.
  checks = checks + 1
  if not anyStopped then fail(label .. ": no position stopped the build") end

  -- Reload after a whole build: the page's onReload under the stop, then the build the host runs.
  world()
  local Page = loadPage()
  Page.build(newCtx(menuId))
  local reloadTotal = countOf(Page.onReload, newCtx(menuId))
  local reloadCtx = newCtx(menuId)
  Page.build(reloadCtx)
  local reloaded = shape(reloadCtx.children)
  checks = checks + 1
  if reloaded ~= reference then fail(label .. ": an unstopped Reload does not draw the page as the cold build") end
  for at = RELOAD_STEP, reloadTotal, RELOAD_STEP do
    world()
    Page = loadPage()
    Page.build(newCtx(menuId))
    underLimit(at, Page.onReload, newCtx(menuId))
    local ctx = newCtx(menuId)
    local ok, err = underLimit(RETRY_BUDGET, Page.build, ctx)
    local drawn = settle(Page, menuId, ok, err, shape(ctx.children))
    compare(label .. " (Reload)", at, reloadTotal, drawn, reference)
  end
end

Stubs.releaseCard()
print(string.format("%d theme settings stop checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
