-- A standby screen whose key some other path cleared is not built again when nothing about it changed.
-- Offline:
--
--   lua5.3 bin/dashboard/verify_standby_key_clear.lua
--   lua5.3 bin/dashboard/verify_standby_key_clear.lua --source-root <other-checkout>
--
-- The real runtime, standing on the standby screen while the connect tasks run. Several paths drop
-- the dashboard's render key on a connect: the reconnect edge, a theme or preferences reload, the
-- voltage bounds moving, a view being invalidated. They are there for the dashboard's own scene; on
-- the standby screen each used to clear and build the same screen again. What is counted is the
-- clears. The controls: a new line of information, a new language and a new zone size still rebuild,
-- and the text the standing screen reads after a preferences reload is the full set it was built
-- with. No pixels, hardware or memory are measured. Exit status: 0 green, 1 failed expectations,
-- 2 bad CLI.

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
  io.stderr:write("usage: lua5.3 bin/dashboard/verify_standby_key_clear.lua [--source-root <checkout>]\n")
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

local function cycle(widget, n)
  for _ = 1, n do
    Stubs.tick()
    widget.refresh(widget, 0, nil)
  end
end

-- The connect tasks run, so the standby screen stands with its "preparing" line, well inside the
-- soft timeout after which the dashboard would build for a reason of its own.
local MspRuntime = assert(_G.rfsuite.require("tasks/msp/runtime.lua"))
local Events = assert(_G.rfsuite.require("tasks/events/runtime.lua"))
local connected = true
MspRuntime.getState = function()
  return { lastConnected = connected, versionReadCompleted = connected, unsupportedApi = false,
    values = { apiVersion = "12.0" } }
end
MspRuntime.getProgressValues = function() return 1, 1 end
MspRuntime.isFblConnected = function() return connected end
Events.isOnconnectActive = function() return connected end
Events.getOnconnectProgress = function() return { done = 1, total = 8 } end
Events.getOnconnectPendingTaskName = function() return "uid" end

local Views = assert(_G.rfsuite.require("widgets/dashboard/views.lua"))
local I18n = assert(_G.rfsuite.require("i18n/init.lua"))
local runtime = assert(loadfile(root .. "/src/rfsuite/widgets/dashboard/runtime.lua"))()
local widget = runtime.new({ x = 0, y = 0, w = 480, h = 320 }, {})
widget.preferences = widget.preferences or {}
widget.preferences.dashboard = widget.preferences.dashboard or {}
widget.preferences.dashboard.standby_intro_seen = true
widget.flightMode = "preflight"

cycle(widget, 80)
check(widget.state.standbyInfoKind == "suite_loading", "the standby waits for the connect tasks",
  widget.state.standbyInfoKind)
check(widget._treeKind == "standby", "the standby screen stands", widget._treeKind)
local standingKey = widget.renderKey

-- Each clear in the shape the connect makes it, then passes enough for a build to have landed.
local clearSites = {
  { "a cleared key and built flag (reconnect edge, theme load, voltage bounds)", function(w)
      w.built = false
      w.renderKey = nil
    end },
  { "an invalidated view", function(w) Views.invalidate(w) end },
  { "a forced preferences and theme reload", function(w) w.reload(w, true) end },
}
for i = 1, #clearSites do
  local name, clear = clearSites[i][1], clearSites[i][2]
  clears = 0
  clear(widget)
  cycle(widget, 20)
  check(clears == 0, name .. ": nothing is built again", clears .. " clears")
  check(widget.renderKey == standingKey and widget.built == true, name .. ": the key is the standing one again",
    tostring(widget.renderKey))
  check(widget._treeKind == "standby", name .. ": the standby still stands", widget._treeKind)
end

-- After the reload the standing screen's fields read the full text set it was built with, not the
-- smaller one the state pass refills an emptied cache with.
local cache = widget._standbyCache
check(cache ~= nil and type(cache.text) == "function", "the standing screen has a text function")
if cache and type(cache.text) == "function" then
  check(cache.text("module_clock", "MISSING") ~= "MISSING", "after the reload the text set is the full one",
    cache.text("module_clock", "MISSING"))
end

-- Control: a new language rebuilds, and the screen says it in that language.
clears = 0
widget.i18n = I18n.new("de")
widget.built = false
widget.renderKey = nil
cycle(widget, 20)
check(clears > 0, "a new language still rebuilds", clears .. " clears")
check(widget.renderKey ~= standingKey, "and the key names it", tostring(widget.renderKey))
local de = assert(loadfile(root .. "/src/rfsuite/i18n/de.lua"))()
local deLine = de.widgets and de.widgets.dashboard and de.widgets.dashboard.standby
  and de.widgets.dashboard.standby.info_suite_loading
check(type(deLine) == "string" and shows(deLine), "the line is in the new language", deLine)
widget.i18n = I18n.new("en")
widget.built = false
widget.renderKey = nil
cycle(widget, 20)

-- Control: a new line of information rebuilds.
clears = 0
connected = false
cycle(widget, 40)
check(widget.state.standbyInfoKind ~= "suite_loading", "the line moves on once the link is gone",
  widget.state.standbyInfoKind)
check(clears > 0, "a new line of information still rebuilds", clears .. " clears")

-- Control: a new zone size rebuilds.
clears = 0
widget.state.zoneW = 800
widget.zone = { x = 0, y = 0, w = 800, h = 458 }
cycle(widget, 40)
check(clears > 0, "a new zone size still rebuilds", clears .. " clears")

-- Control: a clear while the tree on screen is not the build for this key still builds: the tree is
-- forgotten, as a build of another surface does.
clears = 0
widget._treeKind, widget._treeKey = nil, nil
widget.built = false
widget.renderKey = nil
cycle(widget, 20)
check(clears > 0, "a cleared key with no standby build on record still builds", clears .. " clears")

if failures > 0 then
  print(string.format("standby key clear: %d of %d checks failed", failures, checks))
  os.exit(1)
end
print(string.format("standby key clear: %d checks hold", checks))
