-- Checks that the quick menu's ERASE BLACKBOX asks before it erases, offline, with desktop
-- Lua 5.3, from the repository root:
--
--   lua5.3 bin/dashboard/verify_erase_confirm.lua               the checks; exit 1 on any failure
--   lua5.3 bin/dashboard/verify_erase_confirm.lua --verbose     and one line per case
--   lua5.3 bin/dashboard/verify_erase_confirm.lua --self-test   proves the checks can go red
--
-- Erasing the flight controller's blackbox cannot be undone, and on the quick menu it sits one
-- tap from the flight line. The row therefore carries a `confirm` (fullscreen_menu.lua,
-- BUILD.erase_blackbox) and M.run holds its press behind it (views.confirm): tapping the row
-- raises the confirmation view (confirm_menu.lua) and queues NOTHING; ERASE performs the press
-- and leaves full screen; CANCEL -- and a short press on RTN, through the view's `back` --
-- performs nothing and puts the menu back. A question that cannot be raised leaves the press
-- unperformed, never performed unguarded.
--
-- What is REAL: widgets/dashboard/views.lua, fullscreen_menu.lua, confirm_menu.lua and
-- battery_profile_menu.lua, loaded from the tree. What is STUBBED: the firmware (lvgl is not reached here, lcd.RGB and
-- lcd.exitFullScreen, and the theme colour and font globals) and the flight controller side
-- (tasks/msp/runtime.lua and the two dataflash API modules), so a press is judged by what it
-- queues and whether it leaves full screen, not by anything a radio would do.
--
-- Exit status: 0 green, 1 red, 2 when the tree cannot be read.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]dashboard$") or (dir .. "/../..") end
end

local verbose, selfTest = false, false
for i = 1, #arg do
  if arg[i] == "--verbose" then
    verbose = true
  elseif arg[i] == "--self-test" then
    selfTest = true
  else
    io.stderr:write("usage: lua5.3 bin/dashboard/verify_erase_confirm.lua [--verbose] [--self-test]\n")
    os.exit(2)
  end
end

local SRC = ROOT .. "/src/rfsuite/"
local CORE = "/SCRIPTS/RFSUITE/core/"

local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

-- ---------------------------------------------------------------------------
-- Stubs
-- ---------------------------------------------------------------------------

-- The theme colour and font globals a build reads. The values are irrelevant; they only have to
-- be non-nil where the code does `X or fallback`, so a drawn node is built rather than skipped.
for name, value in pairs({
  MIDSIZE = 1, SMLSIZE = 2,
  COLOR_THEME_PRIMARY1 = 11, COLOR_THEME_PRIMARY2 = 12, COLOR_THEME_PRIMARY3 = 13,
  COLOR_THEME_SECONDARY1 = 14, COLOR_THEME_SECONDARY2 = 15, COLOR_THEME_WARNING = 16,
  COLOR_THEME_DISABLED = 17, DARKGREY = 3, RED = 4, WHITE = 5, BLACK = 0,
}) do
  _G[name] = value
end

-- What a press did: the messages it queued and whether it left full screen.
local adds, exits = {}, 0
local QUEUE = {}
function QUEUE:add(msg) adds[#adds + 1] = msg end

_G.lcd = {
  RGB = function(r, g, b) if g == nil then return r end return (r * 65536) + (g * 256) + b end,
  exitFullScreen = function() exits = exits + 1 end,
}

-- The modules the menu's press reaches. Real where the widget's own behaviour is what is being
-- checked; stubbed where the radio or the card would answer.
local cache = {}
local STUBS = {
  ["lib/log.lua"] = function() return nil end,
  ["tasks/msp/runtime.lua"] = function()
    return { getState = function() return { queue = QUEUE } end }
  end,
  ["tasks/msp/api/dataflash_erase.lua"] = function()
    return { writeCommand = 71, buildWritePayload = function() return {} end }
  end,
  ["tasks/msp/api/dataflash_summary.lua"] = function()
    return { command = 70, simulatorResponse = {}, parse = function() return nil end }
  end,
  ["tasks/msp/api/battery_profile.lua"] = function()
    return { writeCommand = 1, buildWritePayload = function() return {} end }
  end,
  ["tasks/msp/api/eeprom_write.lua"] = function()
    return { writeCommand = 250, buildWritePayload = function() return {} end }
  end,
}

local function requireStub(path)
  local full = string.sub(path, 1, 1) == "/" and path or (CORE .. path)
  if cache[full] ~= nil then return cache[full] end
  local rel = string.sub(full, 1, #CORE) == CORE and string.sub(full, #CORE + 1) or full
  local factory = STUBS[rel]
  local mod
  if factory then
    local ok, result = pcall(factory)
    mod = ok and result or nil
  else
    local chunk = loadfile(SRC .. rel)
    if chunk then
      local ok, result = pcall(chunk)
      mod = ok and result or nil
    end
  end
  cache[full] = mod
  return mod
end

_G.rfsuite = _G.rfsuite or {}
_G.rfsuite.require = requireStub

local function loadTreeModule(rel)
  if readFile(SRC .. rel) == nil then
    io.stderr:write("cannot read " .. SRC .. rel .. "\n")
    os.exit(2)
  end
  local mod = requireStub(rel)
  if type(mod) ~= "table" then
    io.stderr:write("cannot load " .. rel .. "\n")
    os.exit(2)
  end
  return mod
end

local Views = loadTreeModule("widgets/dashboard/views.lua")
local Menu = loadTreeModule("widgets/dashboard/fullscreen_menu.lua")
local Confirm = loadTreeModule("widgets/dashboard/confirm_menu.lua")
local ProfilePage = loadTreeModule("widgets/dashboard/battery_profile_menu.lua")

-- ---------------------------------------------------------------------------
-- The cases
-- ---------------------------------------------------------------------------

local function newWidget()
  -- Every confirmation-flow case models a connected widget: its FC-side modules are stubbed
  -- above, and the product offers FC writes only after the connection chain is ready.
  return {
    zone = { w = 800, h = 480 }, state = {}, connectionReady = true,
    built = true, renderKey = "test",
  }
end

local function resetWorld()
  adds = {}
  exits = 0
  _G.rfsuite.session = nil
end

local function buttonsOf(children)
  local out = {}
  for i = 1, #children do
    local node = children[i]
    if type(node) == "table" and node.type == "button" then out[#out + 1] = node end
  end
  return out
end

-- The row carries the question at all.
local function caseRowCarriesQuestion(menu)
  resetWorld()
  _G.rfsuite.session = { dataflash = { used = 50, total = 100 } }
  local w = newWidget()
  local entry = menu.entry(w, "erase_blackbox")
  if type(entry) ~= "table" then return "the menu has no erase_blackbox entry" end
  local c = entry.confirm
  if type(c) ~= "table" then return "the erase row carries no confirm" end
  for _, key in ipairs({ "title", "message", "confirmLabel", "cancelLabel" }) do
    if type(c[key]) ~= "string" or c[key] == "" then return "confirm." .. key .. " is missing" end
  end
  if c.detail ~= "50% used" then
    return "confirm.detail is " .. tostring(c.detail) .. ', expected "50% used"'
  end
  return nil
end

-- Tapping the row raises the question and does nothing else.
local function casePressIsHeld(menu)
  resetWorld()
  local w = newWidget()
  local entry = menu.entry(w, "erase_blackbox")
  menu.run(w, entry)
  if #adds ~= 0 then
    return "the tap queued " .. #adds .. " message(s) before the question was answered"
  end
  if exits ~= 0 then return "the tap left full screen before the question was answered" end
  if Views.top(w) ~= "confirm" then
    return "the confirmation is not on top (top is " .. tostring(Views.top(w)) .. ")"
  end
  if Views.pendingConfirm(w) == nil then return "no press is waiting for an answer" end
  return nil
end

-- CANCEL performs nothing and puts the menu back.
local function caseCancelRunsNothing(menu)
  resetWorld()
  local w = newWidget()
  menu.run(w, menu.entry(w, "erase_blackbox"))
  local children = {}
  Confirm.build(children, w)
  local buttons = buttonsOf(children)
  if #buttons ~= 2 then return #buttons .. " buttons on the question, expected 2 (CANCEL and ERASE)" end
  buttons[1].press()
  if #adds ~= 0 then return "CANCEL queued " .. #adds .. " message(s)" end
  if exits ~= 0 then return "CANCEL left full screen" end
  if Views.top(w) == "confirm" then return "CANCEL left the question on top" end
  if Views.pendingConfirm(w) ~= nil then return "CANCEL left a press waiting" end
  return nil
end

-- ERASE performs the press and leaves full screen.
local function caseAgreePerforms(menu)
  resetWorld()
  local w = newWidget()
  menu.run(w, menu.entry(w, "erase_blackbox"))
  local children = {}
  Confirm.build(children, w)
  local buttons = buttonsOf(children)
  if #buttons ~= 2 then return #buttons .. " buttons on the question, expected 2 (CANCEL and ERASE)" end
  buttons[2].press()
  if #adds ~= 2 then
    return "ERASE queued " .. #adds .. " message(s), expected 2 (the erase, then the summary read)"
  end
  if adds[1].command ~= 71 then
    return "the first queued command is " .. tostring(adds[1].command) .. ", expected 71 (dataflash erase)"
  end
  if adds[2].command ~= 70 then
    return "the second queued command is " .. tostring(adds[2].command) .. ", expected 70 (dataflash summary)"
  end
  if exits ~= 1 then return "ERASE left full screen " .. exits .. " time(s), expected once" end
  if Views.pendingConfirm(w) ~= nil then return "ERASE left a press waiting" end
  return nil
end

-- A question that cannot be raised refuses the press rather than erasing unguarded.
local function caseNoQuestionRefuses(menu)
  resetWorld()
  local w = newWidget()
  -- A registry without the confirmation view: views.confirm cannot raise the question.
  w._viewRegistry = { { id = "menu", module = "widgets/dashboard/fullscreen_menu.lua" } }
  menu.run(w, menu.entry(w, "erase_blackbox"))
  if #adds ~= 0 then return "the tap erased although no question could be raised" end
  if exits ~= 0 then return "the tap left full screen although no question could be raised" end
  return nil
end

-- An offline widget neither offers the row nor accepts a stale press on it. The record is built
-- first to model a menu that was already on screen when the connection stopped being ready.
local function caseOfflineHidesAndRefuses(menu)
  resetWorld()
  local w = newWidget()
  local entry = menu.entry(w, "erase_blackbox")
  w.connectionReady = nil
  if menu.visible(w, entry) then return "the erase row is visible while offline" end
  menu.run(w, entry)
  if #adds ~= 0 then return "an offline press queued " .. #adds .. " message(s)" end
  if exits ~= 0 then return "an offline press left full screen" end
  if Views.pendingConfirm(w) ~= nil then return "an offline press raised a confirmation" end
  return nil
end

-- The battery profile page takes its presses itself, past the row's own condition, and a key or a
-- lost link can leave it on screen before the connection is ready: a press there queues nothing.
local function caseProfilePressNeedsReadyConnection(menu)
  resetWorld()
  local w = newWidget()
  w.state.battery_config = { batteryCapacity_0 = 1000 }
  local entry = menu.entry(w, "battery_profile")
  if entry == nil then return "no battery profile entry" end
  local options = entry.options(w)
  if #options ~= 1 then return "expected one profile option, got " .. #options end
  options[1].press(function() end)
  if #adds == 0 then return "a connected press queued nothing, so the case cannot see a refusal" end
  resetWorld()
  w.connectionReady = nil
  options[1].press(function() end)
  if #adds ~= 0 then return "a press before the connection is ready queued " .. #adds .. " message(s)" end
  return nil
end

local function labelTexts(children)
  local out = {}
  for i = 1, #children do
    local node = children[i]
    if type(node) == "table" and node.type == "label" then out[node.text or ""] = true end
  end
  return out
end

-- Since such a press queues nothing, the page draws its profiles before the connection is ready
-- as it does while armed: boxes without a press, and a foot line that says why. The header's back
-- and close boxes are its only buttons then. Not ready wins over armed, whose state is the last
-- one read and is not cleared when the link drops.
local function caseProfilePageInertBeforeReady(_, page)
  page = page or ProfilePage
  resetWorld()
  local w = newWidget()
  w.state.battery_config = { batteryCapacity_0 = 1000, batteryCapacity_1 = 2000 }
  w.state.batteryProfile = 1
  w.state.connectionReady = true
  local children = {}
  page.build(children, w)
  if #buttonsOf(children) ~= 4 then
    return "a connected page has " .. #buttonsOf(children) .. " buttons, expected 4 (back, close, two profiles)"
  end
  local readyKey = page.renderKey(w)
  local foot = "CHANGEABLE ONLY WHEN CONNECTED"
  for _, armed in ipairs({ false, true }) do
    w.connectionReady = nil
    w.state.connectionReady = nil
    w.state.armed = armed
    children = {}
    page.build(children, w)
    local n = #buttonsOf(children)
    if n ~= 2 then
      return "armed=" .. tostring(armed) .. ": a page before the connection is ready has " .. n
        .. " buttons, expected 2 (back and close)"
    end
    if not labelTexts(children)[foot] then
      return "armed=" .. tostring(armed) .. ": the foot line does not say " .. foot
    end
  end
  w.state.armed = nil
  if page.renderKey(w) == readyKey then return "the page's render key ignores the connection" end
  return nil
end

-- Agreeing closes the question before the work's own action runs, so a theme's `after` -- handed
-- in through ctx.run -- acts on the surface the press was written for, the menu, and not on the
-- question that was on top of it.
local function caseAgreeClosesQuestionFirst(menu)
  local expected = {
    { after = nil,                     top = nil },            -- the row's own `done`
    { after = "none",                  top = "menu" },
    { after = "closeView",             top = nil },
    { after = "openView:battery_pick", top = "battery_pick" },
  }
  for _, e in ipairs(expected) do
    resetWorld()
    local w = newWidget()
    w._viewBase = {}
    Views.navigate(w, "openView:menu")
    Views.bind(w).run({ id = "erase_blackbox" }, nil, e.after)
    local children = {}
    Confirm.build(children, w)
    local buttons = buttonsOf(children)
    if #buttons ~= 2 then return "the question has " .. #buttons .. " buttons, expected 2" end
    buttons[2].press()
    local top = Views.top(w)
    if top ~= e.top then
      return "after=" .. tostring(e.after) .. ": the view on top is " .. tostring(top)
        .. ", expected " .. tostring(e.top)
    end
  end
  return nil
end

-- A `choice` entry's own `confirm` guards its options too: running an option raises the question
-- and performs nothing until it is answered.
local function caseChoiceConfirmGuardsOptions(menu)
  resetWorld()
  local w = newWidget()
  local ran = 0
  local entry = {
    id = "choice_demo", kind = "choice", after = "none",
    confirm = { title = "Q", message = "m", confirmLabel = "YES", cancelLabel = "NO" },
  }
  local option = { press = function() ran = ran + 1 end, after = "none" }
  menu.run(w, entry, option)
  if ran ~= 0 then return "a choice entry's confirm did not hold its option's press" end
  if Views.top(w) ~= "confirm" then
    return "the choice entry's confirm raised no question (top is " .. tostring(Views.top(w)) .. ")"
  end
  return nil
end

local CASES = {
  { id = "the row carries a question",              fn = caseRowCarriesQuestion },
  { id = "a tap is held until it is answered",       fn = casePressIsHeld },
  { id = "CANCEL runs nothing",                      fn = caseCancelRunsNothing },
  { id = "ERASE performs the press",                 fn = caseAgreePerforms },
  { id = "an unraisable question refuses the press", fn = caseNoQuestionRefuses },
  { id = "offline hides and refuses the erase row",  fn = caseOfflineHidesAndRefuses },
  { id = "a profile press needs a ready connection",  fn = caseProfilePressNeedsReadyConnection },
  { id = "the profile page is inert before ready",    fn = caseProfilePageInertBeforeReady },
  { id = "agreeing closes the question first",       fn = caseAgreeClosesQuestionFirst },
  { id = "a choice confirm guards its options",      fn = caseChoiceConfirmGuardsOptions },
}

local function runChecks(menu, quiet)
  local failures, passes = {}, 0
  for i = 1, #CASES do
    local case = CASES[i]
    local ok, result = pcall(case.fn, menu)
    local bad
    if not ok then
      bad = "raised: " .. tostring(result)
    else
      bad = result
    end
    if bad == nil then
      passes = passes + 1
    else
      failures[#failures + 1] = { case = case.id, detail = bad }
    end
    if verbose and not quiet then
      print(string.format("%s %-38s %s", bad == nil and "PASS" or "FAIL", case.id, bad or ""))
    end
  end
  return failures, passes
end

-- ---------------------------------------------------------------------------
-- The self-test: an unguarded row must turn the checks red
-- ---------------------------------------------------------------------------

if selfTest then
  local real, _ = runChecks(Menu, true)
  if #real > 0 then
    print("SELF-TEST FAILED: the checks are red on the unbroken tree:")
    for _, f in ipairs(real) do print("  " .. f.case .. ": " .. f.detail) end
    os.exit(1)
  end

  local path = SRC .. "widgets/dashboard/fullscreen_menu.lua"
  local source = readFile(path)
  if source == nil then io.stderr:write("cannot read " .. path .. "\n"); os.exit(2) end
  local mutated, n = string.gsub(source, "confirm = confirm,", "confirm = nil,", 1)
  if n ~= 1 then
    print("SELF-TEST FAILED: the row's confirm field was found " .. n .. " times, expected once")
    os.exit(1)
  end
  local chunk, err = load(mutated, "@mutant/fullscreen_menu.lua")
  if not chunk then print("SELF-TEST FAILED: the broken copy did not load: " .. tostring(err)); os.exit(1) end
  local ok, Mutant = pcall(chunk)
  if not ok or type(Mutant) ~= "table" then
    print("SELF-TEST FAILED: the broken copy did not return a module: " .. tostring(Mutant))
    os.exit(1)
  end

  local held = casePressIsHeld(Mutant)
  if held == nil then
    print("SELF-TEST FAILED: a row that erases without asking passed 'a tap is held'")
    os.exit(1)
  end
  print("(self-test) an unguarded erase went red: " .. held)

  -- A profile page that draws live buttons before the connection is ready must turn its case red.
  local pagePath = SRC .. "widgets/dashboard/battery_profile_menu.lua"
  local pageSource = readFile(pagePath)
  if pageSource == nil then io.stderr:write("cannot read " .. pagePath .. "\n"); os.exit(2) end
  local pageMutated, pn = string.gsub(pageSource, "local inert = armed or notReady", "local inert = armed", 1)
  if pn ~= 1 then
    print("SELF-TEST FAILED: the page's inert condition was found " .. pn .. " times, expected once")
    os.exit(1)
  end
  local pageChunk, pageErr = load(pageMutated, "@mutant/battery_profile_menu.lua")
  if not pageChunk then print("SELF-TEST FAILED: the broken page did not load: " .. tostring(pageErr)); os.exit(1) end
  local pok, MutantPage = pcall(pageChunk)
  if not pok or type(MutantPage) ~= "table" then
    print("SELF-TEST FAILED: the broken page did not return a module: " .. tostring(MutantPage))
    os.exit(1)
  end
  local live = caseProfilePageInertBeforeReady(Menu, MutantPage)
  if live == nil then
    print("SELF-TEST FAILED: a page with live buttons before the connection is ready passed")
    os.exit(1)
  end
  print("(self-test) a live page before ready went red: " .. live)
  print(string.format("SELF-TEST PASSED: removing the confirmation turns '%s' red", CASES[2].id))
  os.exit(0)
end

-- ---------------------------------------------------------------------------
-- The checks
-- ---------------------------------------------------------------------------

print(string.format("%d cases on the erase row", #CASES))
local failures, passes = runChecks(Menu, false)
if #failures > 0 then
  for _, f in ipairs(failures) do print("FAIL: " .. f.case .. ": " .. f.detail) end
  print(string.format("%d case(s) failed, %d passed", #failures, passes))
  os.exit(1)
end
print(string.format("%d cases, 0 failures", passes))
