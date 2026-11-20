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
-- rows. `fine` puts a stop on every one of the Reload's first FINE_RELOAD instructions as well,
-- where the page sets its Reload state up.
local CASES = {
  { "system/grid", "look" },
  { "system/deck", "look", fine = true },
  { "system/default", "preflight" },
  { "system/@kse4", "postflight" },
  { "system/urban", "telemetry" },
}
-- How far apart the stop positions are, in instructions: through the cold build, and through a
-- Reload, which is shorter and whose module factory takes only a few dozen instructions.
local STEP = 400
local RELOAD_STEP = 50
local FINE_RELOAD = 120
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

-- The context ui/home.lua hands a page's onReload: not the build's.
local function reloadCtx(menuId)
  return {
    i18n = nil, preferences = _G.rfsuite.preferences,
    menu = { getCurrentMenuId = function() return menuId end },
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

-- The stop positions of a Reload: every RELOAD_STEP instructions, and with `fine` every one of
-- the first FINE_RELOAD as well.
local function reloadPositions(total, fine)
  local out = {}
  if fine then
    for at = 1, math.min(FINE_RELOAD, total) do out[#out + 1] = at end
  end
  for at = RELOAD_STEP, total, RELOAD_STEP do
    if not fine or at > FINE_RELOAD then out[#out + 1] = at end
  end
  return out
end

-- How many instructions a Reload has run, counted as underLimit counts them, once the page's
-- onReload has finished its first statement: the count hook runs before the line hook of the same
-- instruction, so at the line event of the second statement that instruction is counted and not
-- yet run. A stop at `at` runs `at` instructions. From there on the page has noted the Reload.
local function notedAfter(Page, ctx)
  local n, lines, noted = 0, 0, nil
  local fn, args = Page.onReload, table.pack(ctx)
  local function lineHook(event)
    if event == "count" then
      n = n + 1
    elseif noted == nil and debug.getinfo(2, "f").func == fn then
      lines = lines + 1
      if lines == 2 then noted = n - 1 end
    end
  end
  -- The same statements as underLimit's, so the two count the same instructions.
  local ok, err = pcall(function()
    debug.sethook(lineHook, "l", 1)
    fn(table.unpack(args, 1, args.n))
    debug.sethook()
  end)
  debug.sethook()
  if not ok then error(err, 0) end
  return noted
end

-- Judges the page after one stopped Reload. A stop before the page has noted the Reload, like one
-- in ui/home.lua before it calls the page, leaves the page as it was, as though Reload had not
-- been pressed: accepted only as a leading run of positions, all of them before `noted`. After
-- that every position must end as the stored values draw the page. Answers whether the leading
-- run still goes on.
local function judgeReload(label, at, total, drawn, reference, unchanged, leading, noted)
  if leading and drawn == unchanged and at < noted then
    checks = checks + 1
    return true
  end
  compare(label, at, total, drawn, reference)
  return false
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

  -- Reload after a whole build whose controls the pilot has changed and not saved: the page's
  -- onReload under the stop, then the build the host runs. A Reload discards the changes, so the
  -- page has to end as the stored values draw it -- the cold build's reference (see judgeReload
  -- for a stop before the page has noted the Reload).
  local function builtAndEdited()
    world()
    local Page = loadPage()
    local ctx = newCtx(menuId)
    Page.build(ctx)
    local edited = 0
    for i = 1, #ctx.children do
      local c = ctx.children[i]
      if c.type == "choice" and type(c.set) == "function" and type(c.values) == "table" and #c.values > 1 then
        c.set((tonumber(c.get()) or 1) % #c.values + 1)
        edited = edited + 1
      end
    end
    return Page, edited
  end
  local noted = notedAfter(builtAndEdited(), reloadCtx(menuId))
  checks = checks + 1
  if type(noted) ~= "number" then fail(label .. ": the Reload's first statement was not seen") end
  local Page, edited = builtAndEdited()
  local editedCtx = newCtx(menuId)
  Page.build(editedCtx)
  local editedShape = shape(editedCtx.children)
  -- Control: the changes reach what a build draws, or a Reload that kept them would pass unseen.
  checks = checks + 1
  if edited == 0 or editedShape == reference then
    fail(label .. ": no control could be changed before the Reload (" .. edited .. " changed)")
  end
  local reloadTotal = countOf(Page.onReload, reloadCtx(menuId))
  local afterReload = newCtx(menuId)
  Page.build(afterReload)
  checks = checks + 1
  if shape(afterReload.children) ~= reference then
    fail(label .. ": an unstopped Reload does not draw the stored values")
  end
  local reloadStopped, leading = 0, true
  for _, at in ipairs(reloadPositions(reloadTotal, case.fine)) do
    Page = builtAndEdited()
    local okReload = underLimit(at, Page.onReload, reloadCtx(menuId))
    if not okReload then reloadStopped = reloadStopped + 1 end
    local ctx = newCtx(menuId)
    local ok, err = underLimit(RETRY_BUDGET, Page.build, ctx)
    local drawn = settle(Page, menuId, ok, err, shape(ctx.children))
    leading = judgeReload(label .. " (Reload)", at, reloadTotal, drawn, reference, editedShape, leading, noted or 0)
  end
  checks = checks + 1
  if reloadStopped == 0 then fail(label .. ": no position stopped the Reload") end
end

-- A theme whose module is made by a factory that reads its value when it runs, and that has no
-- reload of its own: the page's Reload discards an unsaved change only by running the factory
-- again. Such a module stands in for the Deck theme's configure.lua here, so the page lists and
-- finds it as that theme. A stop on any instruction of the Reload must still end with the stored
-- value drawn: a module the Reload has not yet thrown away is thrown away by the build after it.
do
  local label = "factory module without a reload of its own"
  local menuId = "settings_dashboard_settings_" .. hex("system/deck") .. "_look_page"
  local STORED = 1

  local function fixtureWorld()
    world()
    local stubLoadScript = _G.loadScript
    _G.loadScript = function(path, mode)
      if type(path) == "string" and string.find(path, "themes/deck/configure.lua", 1, true) then
        return function()
          return function()
            local value = STORED
            return {
              build = function(ctx)
                ctx.children[#ctx.children + 1] = {
                  type = "choice", label = "Fixture value", values = { "one", "two" },
                  get = function() return value end,
                  set = function(v) value = v end,
                }
              end,
            }
          end
        end
      end
      return stubLoadScript(path, mode)
    end
  end

  local function drawnBy(Page)
    local ctx = newCtx(menuId)
    Page.build(ctx)
    return shape(ctx.children), ctx.children
  end

  -- Built, and its value changed and not saved.
  local function builtAndEdited()
    fixtureWorld()
    local Page = loadPage()
    local _, children = drawnBy(Page)
    for i = 1, #children do
      if children[i].label == "Fixture value" then children[i].set(2) end
    end
    return Page
  end

  local noted = notedAfter(builtAndEdited(), reloadCtx(menuId))
  checks = checks + 1
  if type(noted) ~= "number" then fail(label .. ": the Reload's first statement was not seen") end
  fixtureWorld()
  local reference = drawnBy(loadPage())
  local Page = builtAndEdited()
  local editedShape = drawnBy(Page)
  -- Controls: the module is the one drawn, and the change reaches what a build draws.
  checks = checks + 1
  if not string.find(reference, "Fixture value=1", 1, true) or not string.find(editedShape, "Fixture value=2", 1, true) then
    fail(label .. ": the fixture module is not the one drawn (" .. reference .. " / " .. editedShape .. ")")
  end
  local reloadTotal = countOf(Page.onReload, reloadCtx(menuId))
  -- Control: an unstopped Reload runs the factory again and draws the stored value.
  checks = checks + 1
  if drawnBy(Page) ~= reference then
    fail(label .. ": an unstopped Reload does not draw the stored value")
  end

  local reloadStopped, leading, unchangedSeen = 0, true, 0
  for at = 1, reloadTotal do
    Page = builtAndEdited()
    local okReload = underLimit(at, Page.onReload, reloadCtx(menuId))
    if not okReload then reloadStopped = reloadStopped + 1 end
    local ctx = newCtx(menuId)
    local ok, err = underLimit(RETRY_BUDGET, Page.build, ctx)
    local drawn = settle(Page, menuId, ok, err, shape(ctx.children))
    leading = judgeReload(label .. " (Reload)", at, reloadTotal, drawn, reference, editedShape, leading, noted or 0)
    if leading then unchangedSeen = unchangedSeen + 1 end
  end
  -- Controls: the positions start before the page notes the Reload, and the stop lands inside it.
  checks = checks + 1
  if unchangedSeen == 0 then fail(label .. ": no position fell before the page noted the Reload") end
  checks = checks + 1
  if reloadStopped == 0 then fail(label .. ": no position stopped the Reload") end
end

Stubs.releaseCard()
print(string.format("%d theme settings stop checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
