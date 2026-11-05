-- A new status line on the dashboard's connection screen rebuilds nothing. Offline:
--
--   lua5.3 bin/dashboard/verify_status_line_rebuild.lua
--   lua5.3 bin/dashboard/verify_status_line_rebuild.lua --source-root <other-checkout>
--
-- The real runtime against a stand-in compile pass whose progress moves, on the plain splash and on
-- the standby screen. A rebuild costs native memory that no Lua call gets back: lvgl.clear() leaves
-- each cleared object's wrapper allocated. What is counted is the clears. What the pilot reads is
-- checked by asking the objects themselves: the bar's size, the labels' text, no file count, and no
-- word of connecting while nothing connects. A change of the status line itself, and a new zone
-- size that does belong to a rebuild, are the rest. The line of the connect tasks is driven too, and
-- the standby screen's bar is held against its words in the narrow zones.
-- No pixels, hardware or memory are measured. Exit status: 0 green, 1 failed expectations, 2 bad CLI.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]dashboard$") or (dir .. "/../..") end
end
local root = ROOT
if #arg == 2 and arg[1] == "--source-root" then
  root = arg[2]
elseif #arg > 0 then
  io.stderr:write("usage: lua5.3 bin/dashboard/verify_status_line_rebuild.lua [--source-root <checkout>]\n")
  os.exit(2)
end

local Stubs = assert(loadfile(root .. "/bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile(root .. "/bin/accounting/stubs/fc.lua"))()
Stubs.clearCard()
Stubs.install(root)
FC.install(Stubs)
Stubs.reset()
FC.reset()

local failures, checks = 0, 0
local function check(ok, label, detail)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label .. (detail ~= nil and (": " .. tostring(detail)) or ""))
  end
end

local clears = 0
local realClear = lvgl.clear
lvgl.clear = function(...)
  clears = clears + 1
  return realClear(...)
end

local PRECOMPILE = _G.rfsuite.paths.core .. "/lib/precompile.lua"
local done, running, restart = 0, true, false
_G.rfsuite.modules[PRECOMPILE] = {
  startIfStale = function() return true end,
  stepShared = function() done = done + 1 end,
  isRunning = function() return running end,
  runsBehindConnection = function() return false end,
  needsRestart = function() return restart end,
  getProgress = function() return done, 100000, false end,
}

-- The text a label shows now, whether it was built in or is read through a function.
local function shownLines(node, out, seen)
  seen = seen or {}
  if type(node) ~= "table" or seen[node] then return out end
  seen[node] = true
  if node.type == "label" then
    out[#out + 1] = type(node.text) == "function" and node.text() or node.text
  end
  for _, v in pairs(node) do
    if type(v) == "table" then shownLines(v, out, seen) end
  end
  return out
end

local function shows(text)
  local lines = shownLines(Stubs.lvgl.trees, {})
  for i = 1, #lines do
    if type(lines[i]) == "string" and string.find(lines[i], text, 1, true) then return true end
  end
  return false
end

-- The width of the bar's fill: the one rectangle whose size is read through a function.
local function barWidth(node, seen)
  seen = seen or {}
  if type(node) ~= "table" or seen[node] then return nil end
  seen[node] = true
  if node.type == "rectangle" and type(node.size) == "function"
    and (node.visible == nil or node.visible()) then
    return (node.size())
  end
  for _, v in pairs(node) do
    local w = type(v) == "table" and barWidth(v, seen) or nil
    if w then return w end
  end
  return nil
end

local function cycle(widget, n)
  for _ = 1, n do
    Stubs.tick()
    widget.refresh(widget, 0, nil)
  end
end

local function leg(name, standby)
  done, running, restart = 0, true, false
  local runtime = assert(loadfile(root .. "/src/rfsuite/widgets/dashboard/runtime.lua"))()
  local zone = { x = 0, y = 0, w = 800, h = 458 }
  local widget = runtime.new(zone, {})
  widget.preferences = widget.preferences or {}
  widget.preferences.dashboard = widget.preferences.dashboard or {}
  widget.preferences.dashboard.standby_enabled = standby
  widget.flightMode = "preflight"

  -- Settled: the first scene stands, and the pass has moved. The fill's scale is far too wide for
  -- this count to fill it, so start it where a few steps show.
  done = 20000
  cycle(widget, 120)
  local first = barWidth(Stubs.lvgl.trees)
  check(first ~= nil, name .. ": the bar stands", first)
  check(not shows("/100000"), name .. ": no file count on the screen")
  check(not shows("Connecting FBL"), name .. ": no word of connecting while nothing connects")
  check(shows("Preparing suite"), name .. ": it says what is happening")

  clears = 0
  done = done + 40000
  cycle(widget, 200)
  check(clears == 0, name .. ": a moving bar clears nothing", clears .. " clears over 20 s")
  local second = barWidth(Stubs.lvgl.trees)
  check(first ~= nil and second ~= nil and second > first, name .. ": the bar grows",
    tostring(first) .. " then " .. tostring(second))

  -- The pass ends: the same scene asks for the restart, with the bar gone.
  clears = 0
  running, restart = false, true
  cycle(widget, 60)
  check(shows("Please restart the radio"), name .. ": the restart request is shown")
  check(barWidth(Stubs.lvgl.trees) == nil, name .. ": the bar is gone")
  check(not shows("Connecting FBL"), name .. ": still no word of connecting")
  check(clears == 0, name .. ": and none of that clears anything", clears .. " clears")
  running, restart = true, false

  -- The control: something that does belong to a rebuild is seen.
  clears = 0
  widget.state.zoneW = 480
  widget.zone = { x = 0, y = 0, w = 480, h = 272 }
  cycle(widget, 40)
  check(clears > 0, name .. ": a new zone size still rebuilds", clears .. " clears")
end

-- The connect tasks say what they are doing through the same line. Their step and their count change
-- while the kind of line stays the same, so nothing may clear. Held well inside the splash's soft
-- timeout, after which the dashboard would build for a reason of its own.
local function onconnectLeg(name, standby)
  done, running, restart = 0, false, false
  local MspRuntime = assert(_G.rfsuite.require("tasks/msp/runtime.lua"))
  local Events = assert(_G.rfsuite.require("tasks/events/runtime.lua"))
  local saved = { MspRuntime.getState, MspRuntime.getProgressValues, MspRuntime.isFblConnected,
    Events.isOnconnectActive, Events.getOnconnectProgress, Events.getOnconnectPendingTaskName }
  local step, task = 1, "apiversion"
  MspRuntime.getState = function()
    return { lastConnected = true, versionReadCompleted = true, unsupportedApi = false,
      values = { apiVersion = "12.0" } }
  end
  MspRuntime.getProgressValues = function() return 1, 1 end
  MspRuntime.isFblConnected = function() return true end
  Events.isOnconnectActive = function() return true end
  Events.getOnconnectProgress = function() return { done = step - 1, total = 8 } end
  Events.getOnconnectPendingTaskName = function() return task end

  local runtime = assert(loadfile(root .. "/src/rfsuite/widgets/dashboard/runtime.lua"))()
  local widget = runtime.new({ x = 0, y = 0, w = 800, h = 458 }, {})
  widget.preferences = widget.preferences or {}
  widget.preferences.dashboard = widget.preferences.dashboard or {}
  widget.preferences.dashboard.standby_enabled = standby
  widget.flightMode = "preflight"

  cycle(widget, 60)
  check(widget.state.standbyInfoKind == "suite_loading", name .. ": the connect tasks are what it waits for",
    widget.state.standbyInfoKind)
  check(shows("(1/8)"), name .. ": the first step is on the screen")

  clears = 0
  step = 2
  cycle(widget, 30)
  check(shows("(2/8)"), name .. ": a new count reaches the label")
  check(not shows("(1/8)"), name .. ": and the old one has gone")
  local line = widget.statusLine
  step, task = 3, "not-a-known-task"
  cycle(widget, 30)
  check(shows("(3/8)") and widget.statusLine ~= line, name .. ": a new step reaches the label", widget.statusLine)
  check(widget.state.standbyInfoKind == "suite_loading", name .. ": the kind of line stayed the same",
    widget.state.standbyInfoKind)
  check(clears == 0, name .. ": neither of them clears anything", clears .. " clears")

  -- The control, in this same state: something that does belong to a rebuild is seen.
  clears = 0
  widget.state.zoneW = 480
  widget.zone = { x = 0, y = 0, w = 480, h = 272 }
  cycle(widget, 40)
  check(clears > 0, name .. ": a new zone size still rebuilds", clears .. " clears")

  MspRuntime.getState, MspRuntime.getProgressValues, MspRuntime.isFblConnected = saved[1], saved[2], saved[3]
  Events.isOnconnectActive, Events.getOnconnectProgress, Events.getOnconnectPendingTaskName = saved[4], saved[5], saved[6]
end

-- The standby screen's bar against its words: asked of the objects a zone gets. The bar's track is
-- the rectangle with a visibility and no size of its own; the fill reads its size.
local function findStatusLabel(children, text)
  for i = 1, #children do
    local c = children[i]
    if c.type == "label" and type(c.text) == "function" and c.text() == text then return c end
  end
end

local function findBarTrack(children)
  for i = 1, #children do
    local c = children[i]
    if c.type == "rectangle" and type(c.visible) == "function" and c.size == nil then return c end
  end
end

local function barBesideLine(locale, zoneW, zoneH, expectX)
  local Standby = assert(loadfile(root .. "/src/rfsuite/widgets/dashboard/standby.lua"))()
  local text = assert(loadfile(root .. "/src/rfsuite/i18n/" .. locale .. ".lua"))().app.preparing
  local name = string.format("bar at %dx%d, %s", zoneW, zoneH, locale)
  local children = Standby.build({ x = 0, y = 0, w = zoneW, h = zoneH }, function() return text end,
    function(_, fallback) return fallback end, {}, {}, {},
    { text = "", progress = function() return 0.5 end })
  local label, track = findStatusLabel(children, text), findBarTrack(children)
  check(label ~= nil, name .. ": the line stands")
  check(track ~= nil, name .. ": the bar stands")
  if label and track then
    local ends = label.x + lcd.sizeText(text, SMLSIZE)
    check(ends <= track.x, name .. ": the bar starts after the words", ends .. " against " .. track.x)
    check(track.x + track.w <= zoneW, name .. ": and ends inside the zone", track.x + track.w)
    if expectX then check(track.x == expectX, name .. ": where the words leave room, at the middle", track.x) end
  end
end

local function noRoomForBar(zoneW, zoneH)
  local Standby = assert(loadfile(root .. "/src/rfsuite/widgets/dashboard/standby.lua"))()
  local children = Standby.build({ x = 0, y = 0, w = zoneW, h = zoneH }, function() return "Preparing suite" end,
    function(_, fallback) return fallback end, {}, {}, {},
    { text = "", progress = function() return 0.5 end })
  check(findBarTrack(children) == nil, string.format("bar at %dx%d: no room, so the words stand alone", zoneW, zoneH))
  check(findStatusLabel(children, "Preparing suite") ~= nil, string.format("bar at %dx%d: the words stay", zoneW, zoneH))
end

leg("splash", false)
leg("standby", true)
onconnectLeg("splash, connect tasks", false)
onconnectLeg("standby, connect tasks", true)

for _, locale in ipairs({ "en", "de" }) do
  barBesideLine(locale, 800, 458, 400)
  barBesideLine(locale, 480, 320, 240)
  barBesideLine(locale, 480, 272, 240)
  -- Half of what is left of a 480-wide screen with sliders and both vertical trims on.
  barBesideLine(locale, 198, 244)
end
noRoomForBar(120, 244)

if failures > 0 then
  print(string.format("status line: %d of %d checks failed", failures, checks))
  os.exit(1)
end
print(string.format("status line: %d checks hold", checks))
