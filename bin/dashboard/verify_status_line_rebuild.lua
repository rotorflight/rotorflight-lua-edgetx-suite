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
-- size that does belong to a rebuild, are the rest.
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

leg("splash", false)
leg("standby", true)

if failures > 0 then
  print(string.format("status line: %d of %d checks failed", failures, checks))
  os.exit(1)
end
print(string.format("status line: %d checks hold", checks))
