-- The dashboard's loading screen, its standby screen and the tool's start screen draw in the colour
-- scheme the pilot has chosen. Offline:
--
--   lua5.3 bin/dashboard/verify_start_scheme.lua
--   lua5.3 bin/dashboard/verify_start_scheme.lua --source-root <other-checkout>
--
-- The real runtime and the real ui/home.lua on the accounting stubs, with what stands in the LVGL tree
-- read back: every colour a screen holds is a colour of that scheme, the page is the scheme's page, the
-- logo is the scheme's logo and that file exists, and a change saved through lib/preferences.lua, as the
-- settings page saves it, reaches a screen that is standing and rebuilds it. No pixels, hardware or memory
-- are measured. Exit status: 0 green, 1 failed, 2 bad CLI.

local root = "."
if #arg == 2 and arg[1] == "--source-root" then
  root = arg[2]
elseif #arg > 0 then
  io.stderr:write("usage: lua5.3 bin/dashboard/verify_start_scheme.lua [--source-root <checkout>]\n")
  os.exit(2)
end

local failures, checks = 0, 0
local function check(ok, label, detail)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label .. (detail ~= nil and (": " .. tostring(detail)) or ""))
  end
end

local Stubs = assert(loadfile(root .. "/bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile(root .. "/bin/accounting/stubs/fc.lua"))()
Stubs.clearCard()
Stubs.install(root)
FC.install(Stubs)
Stubs.reset()
FC.reset()

local Schemes = assert(loadfile(root .. "/src/rfsuite/lib/color_schemes.lua"))()
local NAMES = { "light", "dark" }
local allowed, expectedPage, expectedLogo = {}, {}, {}
do
  -- 0xRRGGBB through the stubbed lcd.RGB. Taken before colors() converts in place.
  local raw = {}
  for _, name in ipairs(NAMES) do
    raw[name] = {}
    for role, rgb in pairs(Schemes.SCHEMES[name]) do raw[name][role] = rgb end
  end
  for _, name in ipairs(NAMES) do
    allowed[name] = {}
    for _, rgb in pairs(raw[name]) do allowed[name][lcd.RGB(rgb)] = true end
    expectedPage[name] = lcd.RGB(raw[name].page)
    expectedLogo[name] = Schemes.LOGOS and Schemes.LOGOS[name] or "?"
    local file = io.open(root .. "/src/rfsuite/widgets/dashboard/gfx/" .. expectedLogo[name], "rb")
    check(file ~= nil, name .. ": its logo file exists", expectedLogo[name])
    if file then file:close() end
  end
  check(expectedLogo.light ~= expectedLogo.dark, "the schemes have a logo each")
end

-- Every colour and image file of what stands in the tree. A colour read through a function is asked.
local function walk(node, found, seen)
  if type(node) ~= "table" or seen[node] then return end
  seen[node] = true
  if node.type ~= nil then
    local color = node.color
    if type(color) == "function" then color = color() end
    if color ~= nil then found.colors[#found.colors + 1] = { color = color, type = node.type } end
    if node.type == "image" then found.images[#found.images + 1] = tostring(node.file) end
    if node.type == "rectangle" and node.filled == true and found.page == nil then found.page = color end
    found.nodes = found.nodes + 1
  end
  for key, value in pairs(node) do
    if type(value) == "table" and key ~= "parent" then walk(value, found, seen) end
  end
end

local function standing()
  local found = { colors = {}, images = {}, nodes = 0 }
  walk(Stubs.lvgl.trees, found, {})
  return found
end

local function holdsScheme(name, label, wantLogo)
  local found = standing()
  check(found.nodes > 1, label .. ": something stands", found.nodes)
  check(found.page == expectedPage[name], label .. ": the background is the scheme's page",
    string.format("%s against %s", tostring(found.page), tostring(expectedPage[name])))
  for i = 1, #found.colors do
    local entry = found.colors[i]
    check(allowed[name][entry.color] == true, label .. ": a " .. entry.type .. " draws a colour of the scheme",
      entry.color)
  end
  if wantLogo then
    local hit = false
    for i = 1, #found.images do
      if string.find(found.images[i], "/" .. expectedLogo[name], 1, true) then hit = true end
    end
    check(hit, label .. ": the scheme's logo", table.concat(found.images, ","))
  end
end

local clears = 0
local realClear = lvgl.clear
lvgl.clear = function(...)
  clears = clears + 1
  return realClear(...)
end

local PRECOMPILE = _G.rfsuite.paths.core .. "/lib/precompile.lua"
_G.rfsuite.modules[PRECOMPILE] = {
  startIfStale = function() return true end,
  stepShared = function() end,
  isRunning = function() return true end,
  runsBehindConnection = function() return false end,
  needsRestart = function() return false end,
  getProgress = function() return 20000, 100000, false end,
}

local function cycle(widget, n, event)
  for _ = 1, n do
    Stubs.tick()
    widget.refresh(widget, event, nil)
  end
end

local Preferences = assert(_G.rfsuite.require("lib/preferences.lua"))
local saves = 0

-- What the settings page does: the whole table written, and the widget told by the reload request.
local function save(name)
  local prefs = Preferences.load()
  prefs.general.color_scheme = name
  assert(Preferences.save(prefs))
  -- The stubs' fstat answers this for every file, so the widget sees the file's status move.
  saves = saves + 1
  Stubs.prefsStat = { size = saves, time = { year = 2026, mon = 11, day = 6, hour = 12, min = 0, sec = saves % 60 } }
end

local function widgetLeg(label, standby, zone, event)
  for _, name in ipairs(NAMES) do
    save(name)
    local runtime = assert(loadfile(root .. "/src/rfsuite/widgets/dashboard/runtime.lua"))()
    local widget = runtime.new(zone, {})
    widget.flightMode = "preflight"
    -- The splash stands where the standby's build was given up.
    if not standby then widget._jobFaults.standby = 99 end
    cycle(widget, 120, event)
    check((widget._standbyModule ~= nil) == standby, label .. ", " .. name .. ": the screen under test stands")
    holdsScheme(name, label .. ", " .. name, zone.h >= 100)

    -- The pilot saves the other scheme while the screen stands.
    local other = name == "light" and "dark" or "light"
    clears = 0
    save(other)
    cycle(widget, 60, event)
    -- The reload gives every job its tries back, so the standby would stand again.
    if not standby then widget._jobFaults.standby = 99 end
    cycle(widget, 60, event)
    check((widget._standbyModule ~= nil) == standby, label .. ", " .. name .. " to " .. other .. ": still the screen under test")
    check(clears > 0, label .. ", " .. name .. ": a saved scheme rebuilds the screen", clears)
    holdsScheme(other, label .. ", " .. name .. " to " .. other, zone.h >= 100)
  end
end

-- An event is what makes a refresh full screen, and only full screen carries the tool control.
widgetLeg("splash, full screen 800x480", false, { x = 0, y = 0, w = 800, h = 480 }, 0)
widgetLeg("splash, 480x272 zone", false, { x = 0, y = 0, w = 480, h = 272 }, nil)
widgetLeg("standby, full screen 480x272", true, { x = 0, y = 0, w = 480, h = 272 }, 0)
widgetLeg("standby, 800x458 zone", true, { x = 0, y = 0, w = 800, h = 458 }, nil)
widgetLeg("standby, 480x320 zone", true, { x = 0, y = 0, w = 480, h = 320 }, nil)
widgetLeg("standby, low zone", true, { x = 0, y = 0, w = 240, h = 68 }, nil)

-- The two roles only the start screen read are gone with it, and the tool's other panel roles stay.
do
  local Palette = assert(loadfile(root .. "/src/rfsuite/ui/palette.lua"))()
  check(Palette.panelProgressTrack == nil and Palette.panelProgressFill == nil, "the start screen's old roles are gone")
  check(Palette.panel ~= nil and Palette.panelText ~= nil, "the notices' panel roles remain")
end

-- The tool's start screen, on its own Lua state's preferences.
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

_G.rfsuite.modules[PRECOMPILE] = nil
Stubs.installTool()
local Home = assert(loadfile(root .. "/src/rfsuite/ui/home.lua"))()
Home.init({})
Stubs.tick()
Home.run(0)
local state = assert(find(Home.run, "state"), "home state missing")
local M = assert(find(Home.run, "M"), "home module table missing")
for _, name in ipairs(NAMES) do
  state.initialLoad = true
  save(name, false)
  state.preferences = Preferences.load()
  state.precompileDone, state.precompileTotal = 3, 8
  Stubs.lvgl.trees = {}
  M.buildUI(true)
  holdsScheme(name, "tool start, " .. name, true)
end

print(string.format("verify_start_scheme: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
