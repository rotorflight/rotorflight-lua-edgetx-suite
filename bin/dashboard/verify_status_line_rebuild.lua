-- A new status line on the dashboard's connection screen rebuilds nothing. Offline:
--
--   lua5.3 bin/dashboard/verify_status_line_rebuild.lua
--   lua5.3 bin/dashboard/verify_status_line_rebuild.lua --source-root <other-checkout>
--
-- The real runtime against a stand-in compile pass whose count moves, so the line changes the way it
-- does during a pass, on the plain splash and on the standby screen. A rebuild costs native memory
-- that no Lua call gets back: lvgl.clear() leaves each cleared object's wrapper allocated. What is
-- counted is the clears. What the pilot reads is checked by asking the label that shows the line.
-- A change that does belong to a rebuild, a new zone size, is the control that the clears are seen.
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
local done = 0
_G.rfsuite.modules[PRECOMPILE] = {
  startIfStale = function() return true end,
  stepShared = function() done = done + 1 end,
  isRunning = function() return true end,
  runsBehindConnection = function() return false end,
  needsRestart = function() return false end,
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

local function countOnScreen()
  local lines = shownLines(Stubs.lvgl.trees, {})
  for i = 1, #lines do
    local n = type(lines[i]) == "string" and string.match(lines[i], "%((%d+)/100000%)")
    if n then return tonumber(n) end
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
  done = 0
  local runtime = assert(loadfile(root .. "/src/rfsuite/widgets/dashboard/runtime.lua"))()
  local zone = { x = 0, y = 0, w = 800, h = 458 }
  local widget = runtime.new(zone, {})
  widget.preferences = widget.preferences or {}
  widget.preferences.dashboard = widget.preferences.dashboard or {}
  widget.preferences.dashboard.standby_enabled = standby
  widget.flightMode = "preflight"

  -- Settled: the first scene stands, and the line has had time to carry a count.
  cycle(widget, 120)
  local first = countOnScreen()
  check(first ~= nil, name .. ": the count is on the screen", first)

  clears = 0
  cycle(widget, 200)
  check(clears == 0, name .. ": a moving count clears nothing", clears .. " clears over 20 s")
  local second = countOnScreen()
  check(first ~= nil and second ~= nil and second > first, name .. ": the label shows the new count",
    tostring(first) .. " then " .. tostring(second))

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
