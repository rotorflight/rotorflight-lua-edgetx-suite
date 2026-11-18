-- A theme's settings page opened from the dashboard is built inside one widget call. EdgeTX
-- (radio/src/lua/widgets.cpp, luaHook) raises "CPU limit" once per call, past the instruction
-- limit, and then lets the call run on. This check builds the real page
-- (app/pages/settings/dashboard/settings/page.lua) cold under a hook that does the same, with
-- the stop put at every position of the build in turn, and then builds again the way ui/home.lua
-- does after a stopped build (a fresh call, at most BUILD_LIMIT_RETRIES = 3 times).
--
-- Wherever the stop lands, the page must end up as the unstopped build draws it: never with
-- "This theme's settings could not be loaded", never with fewer rows, never on the failure page.
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
-- How far apart the stop positions are, in instructions.
local STEP = 400
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
  }
end

-- What a build drew, as one string: the type and text of every element in order.
local function shape(children)
  local out = {}
  for i = 1, #children do
    local c = children[i]
    out[#out + 1] = tostring(c.type) .. ":" .. tostring(c.text or c.label or "")
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

local function underLimit(n, fn, ...)
  used, limit = 0, n
  debug.sethook(hook, "", 1)
  local ok, err = pcall(fn, ...)
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

for _, case in ipairs(CASES) do
  local theme, page = case[1], case[2]
  local menuId = "settings_dashboard_settings_" .. hex(theme) .. "_" .. page .. "_page"
  local label = theme .. " " .. page

  world()
  local refCtx = newCtx(menuId)
  local total = countOf(loadPage().build, refCtx)
  local reference = shape(refCtx.children)
  -- Positive control: the unstopped build draws the theme's own rows, not only the scope line.
  checks = checks + 1
  if #refCtx.children < 8 or string.find(reference, "could not be loaded", 1, true) then
    fail(label .. ": the unstopped build drew no settings (" .. #refCtx.children .. " elements)")
  end

  local stopped = 0
  for at = STEP, total, STEP do
    world()
    local Page = loadPage()
    local ctx = newCtx(menuId)
    local ok = underLimit(at, Page.build, ctx)
    local drawn = shape(ctx.children)
    local tries = 0
    while not ok do
      stopped = stopped + 1
      tries = tries + 1
      if tries > RETRIES then drawn = "the failure page"; break end
      ctx = newCtx(menuId)
      local err
      ok, err = underLimit(RETRY_BUDGET, Page.build, ctx)
      if not ok and not string.find(tostring(err), "CPU limit", 1, true) then
        drawn = "the failure page (" .. tostring(err) .. ")"
        break
      end
      drawn = shape(ctx.children)
    end
    checks = checks + 1
    if drawn ~= reference then
      local what = string.find(drawn, "could not be loaded", 1, true) and "'could not be loaded'"
        or (#drawn < #reference and "fewer rows than the unstopped build")
        or drawn
      fail(string.format("%s: stopped at %d of %d instructions, the page ends with %s", label, at, total, what))
    end
  end
  -- The stop has to land inside the build at all, or nothing above was tested.
  checks = checks + 1
  if stopped == 0 then fail(label .. ": no position stopped the build") end
end

Stubs.releaseCard()
print(string.format("%d theme settings stop checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
