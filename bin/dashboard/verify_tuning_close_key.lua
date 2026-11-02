-- Checks that leaving the in-flight tuning surface builds the dashboard once, under the key of the
-- state it returns to, offline, with desktop Lua 5.3, from the repository root:
--
--   lua5.3 bin/dashboard/verify_tuning_close_key.lua
--   lua5.3 bin/dashboard/verify_tuning_close_key.lua --verbose
--
-- The tuning branch of refresh() recomputes its own key under the same 2 Hz throttle the
-- dashboard's key is computed under, and stamps it. Anything that invalidates the dashboard's key
-- while the surface is up -- here the voltage bounds moving with the cell count -- is then not
-- recomputed before the surface closes, and the surface the pilot returns to used to be built
-- under the key that was left behind, then a second time once the throttle opened.
--
-- The real widgets/dashboard/runtime.lua, views.lua, inflight/drive.lua and inflight/input.lua run
-- against the accounting stubs (bin/accounting/stubs). The one thing set by hand is the board
-- being identified (`isFblConnected` of the MSP runtime answers true): without it the surface
-- stands in its link-lost pause, where the drive is never open and a close takes another route.
-- With it the surface is the ground surface, open, as a pilot sees it before a flight. The bounds
-- move through the widget's own logic tick, from the stubbed `Cel#` sensor.
--
-- The surface is opened from the full-screen theme by the verb a key bound to in-flight tuning runs
-- (views.lua), so that theme's key was cached before the surface came up. Six ways out are
-- driven, K = 0..5 passes after the pass that moved the bounds:
--   exit     the firmware leaves fullscreen (a refresh without an event): the zone's scene
--   off      the in-flight tuning setting switched off in fullscreen: the full-screen theme
--   rtn      RTN, which the surface takes as its close: the full-screen theme
--   rtnexit  RTN, then fullscreen left on the very next pass: the zone's scene
--   rtnfs2   RTN, two fullscreen passes (the full-screen theme keyed, its build under way), then
--            fullscreen left: the zone's scene; only builds after the exit are counted
--   rtnfs6   the same with six passes (the full-screen theme built before the exit)
-- Each counts the builds that complete after the surface is left and records their keys. Expected:
-- exactly one, carrying the moved bounds. The control moves nothing and expects one build as well.
-- Three more cases check that a theme without a key of its own stays on the 2 Hz throttle, and
-- that a key of false is still told from nil (see zoneViewCase below).
-- Exit status: 0 green, 1 failed expectations, 2 invalid arguments.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]dashboard$") or (dir .. "/../..") end
end

local verbose = false
for i = 1, #arg do
  if arg[i] == "--verbose" then
    verbose = true
  else
    io.stderr:write("usage: lua5.3 bin/dashboard/verify_tuning_close_key.lua [--verbose]\n")
    os.exit(2)
  end
end

local Stubs = assert(loadfile(ROOT .. "/bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile(ROOT .. "/bin/accounting/stubs/fc.lua"))()

-- A helicopter on the bench, six cells, rotor stopped (the ground half refuses MSP while the
-- rotor turns). Raw channel 11 sits in the first band of the bank channel.
local SENSORS = {
  ["Vbat"] = 24.6, ["Curr"] = 3.2, ["Capa"] = 850, ["Bat%"] = 74, ["Cel#"] = 6,
  ["Hspd"] = 0, ["RQly"] = 96, ["1RSS"] = -42, ["2RSS"] = -45, ["PID#"] = 1, ["RTE#"] = 1,
  ["ARM"] = 0, ["ARMD"] = 0, ["Gov"] = 0, ["AdjF"] = 14, ["AdjV"] = 100,
  ["ch11"] = -1028, ["ch12"] = 0,
}

local function newWidget()
  Stubs.install(ROOT)
  FC.install(Stubs)
  Stubs.reset()
  FC.reset()
  for k, v in pairs(SENSORS) do Stubs.sensors[k] = v end
  -- RTN's release, as the firmware exports it (radio/src/keys.h); the stubs install it only for the
  -- tool's world.
  _G.EVT_VIRTUAL_EXIT = 0x0201
  local Msp = _G.rfsuite.require("tasks/msp/runtime.lua")
  Msp.isFblConnected = function() return true end
  local Runtime = _G.rfsuite.require("widgets/dashboard/runtime.lua")
  local w = Runtime.new({ x = 0, y = 0, w = 800, h = 458 }, {})
  w.preferences = w.preferences or {}
  w.preferences.dashboard = { theme_preflight = "system/default" }
  w.preferences.general = w.preferences.general or {}
  w.preferences.general.preview_inflight_tuning = true
  w.preferences.inflight = {
    enabled = true, bank_ch = 11, value_ch = 12, bank_gvar = 1, value_gvar = 2, pulse_ms = 150,
    trims = true, trim_mode = "rows", nav_trim = 2, adj_trim = 4,
    row_trim_1 = 2, row_trim_2 = 4, row_trim_3 = 1, row_trim_4 = 3, row_trim_5 = 5, row_trim_6 = 6,
  }
  return w
end

-- One pass of the host: the clock moves 100 ms, the firmware calls refresh. Returns what the pass
-- completed: the kind and key of a build that finished on it, or nil.
local function pass(w, event)
  Stubs.tick()
  local job = w._job
  w.refresh(w, event, nil)
  if job ~= nil and job.oneShot ~= true and w._job == nil and w._treeKind == job.kind and w.built then
    return job.kind, w._treeKey
  end
  return nil
end

local function runCase(path, K, move)
  local w = newWidget()
  -- The dashboard settles: connect chain, theme load, first scene.
  local settled = false
  for i = 1, 1200 do
    pass(w, nil)
    if i > 50 and w.connectionReady == true and w._job == nil and w.built
        and type(w.renderKey) == "string" and string.find(w.renderKey, "preflight|", 1, true) == 1 then
      settled = true
      break
    end
  end
  if not settled then return nil, "the dashboard never settled (key " .. tostring(w.renderKey) .. ")" end
  local cells0 = w.state.themeConfig and w.state.themeConfig._boundsCells
  if cells0 ~= 6 then return nil, "positive control: the settled bounds are not for 6 cells: " .. tostring(cells0) end

  -- Fullscreen: the theme's own full-screen layer comes up first, and every fullscreen pass carries
  -- an event. Tuning is then opened from there the way a key bound to it opens it.
  for _ = 1, 20 do pass(w, 0) end
  if type(w.renderKey) ~= "string" or string.find(w.renderKey, "fs_theme|", 1, true) ~= 1 then
    return nil, "positive control: the full-screen theme is not on screen (key " .. tostring(w.renderKey) .. ")"
  end
  local Views = _G.rfsuite.require("widgets/dashboard/views.lua")
  Views.navigate(w, "openTuning")
  if w.inflightFullscreen ~= true then return nil, "positive control: the bound key did not open tuning" end
  for _ = 1, 60 do pass(w, 0) end
  if type(w.renderKey) ~= "string" or string.find(w.renderKey, "tuning|fs|ground|", 1, true) ~= 1
      or not (w._inflight and w._inflight.open == true) then
    return nil, "positive control: the open ground surface is not on screen (key " .. tostring(w.renderKey) .. ")"
  end

  local want = move and 12 or 6
  if move then Stubs.sensors["Cel#"] = 12; Stubs.sensors["Vbat"] = 49.2 end
  local moved = false
  for _ = 1, 40 do
    pass(w, 0)
    local config = w.state.themeConfig
    if config and config._boundsCells == want then moved = true; break end
  end
  if not moved then return nil, "positive control: the bounds never reached " .. want .. " cells" end
  for _ = 1, K do pass(w, 0) end
  if type(w.renderKey) ~= "string" or string.find(w.renderKey, "tuning|", 1, true) ~= 1 then
    return nil, "positive control: the tuning surface was not on screen when it was left"
  end

  local event = 0
  if path == "exit" then
    event = nil
  elseif path == "off" then
    w.preferences.inflight.enabled = false
  elseif path == "rtn" or path == "rtnexit" or path == "rtnfs2" or path == "rtnfs6" then
    local kind, key = pass(w, _G.EVT_VIRTUAL_EXIT)
    if w.inflightFullscreen ~= nil then return nil, "positive control: RTN did not close the surface" end
    if kind == "scene" or kind == "fs_theme" then return nil, "a build completed on the RTN pass: " .. tostring(key) end
    if path == "rtnexit" then event = nil end
    if path == "rtnfs2" or path == "rtnfs6" then
      for _ = 1, (path == "rtnfs2" and 2 or 6) do pass(w, 0) end
      event = nil
    end
  end

  local builds = {}
  for _ = 1, 30 do
    local kind, key = pass(w, event)
    if kind == "scene" or kind == "fs_theme" then builds[#builds + 1] = kind .. " " .. tostring(key) end
  end
  if w.inflightFullscreen ~= nil then return nil, "positive control: the surface was not left" end
  return builds, nil, "|" .. want .. "|"
end

local failures, cases = 0, 0
for _, path in ipairs({ "exit", "off", "rtn", "rtnexit", "rtnfs2", "rtnfs6" }) do
  for _, move in ipairs({ true, false }) do
    for K = 0, 5 do
      cases = cases + 1
      local label = string.format("%s %s K=%d", path, move and "bounds-moved" or "control", K)
      local builds, err, cellsMark = runCase(path, K, move)
      local ok, why = false, err
      if builds ~= nil then
        if #builds ~= 1 then
          why = string.format("%d builds after the surface closed, expected 1: %s", #builds, table.concat(builds, " ; "))
        elseif not string.find(builds[1], cellsMark, 1, true) then
          why = "the one build was keyed on bounds other than the current ones: " .. builds[1]
        else
          ok = true
        end
      end
      if not ok then failures = failures + 1 end
      if verbose or not ok then
        print((ok and "PASS " or "FAIL ") .. label .. (ok and (": " .. builds[1]) or (": " .. tostring(why))))
      end
    end
  end
end

-- A theme with a build and no key of its own -- a pilot's theme can be one -- computes a key of
-- nil on every pass that asks. Computing the key at once when the cached one is nil must not
-- ask that theme on every pass: the throttle would then be stamped on every zone pass, and the
-- zone views' conditions, asked on each stamp, would run at the pass rate instead of 2 Hz. The
-- theme is served from the user directory; its one zone view counts the calls of its condition
-- over PASSES zone passes (100 ms each). The control is the same theme with a key, which the
-- throttle holds to the same count. A third theme's key is nil while it settles and turns false
-- after that: a key of false is a key like any other, so the scene is built once more.
local PASSES = 50
local function zoneViewCase(variant)
  Stubs.install(ROOT)
  FC.install(Stubs)
  Stubs.reset()
  FC.reset()
  for k, v in pairs(SENSORS) do Stubs.sensors[k] = v end
  local asks = 0
  local manifest = { name = "Zone view test",
    views = { { id = "zv", module = "zv.lua", where = "zone",
      openWhen = function() asks = asks + 1; return true end } } }
  local theme = { build = function() return {} end }
  local flipped = nil
  if variant == "key" then theme.renderKey = function() return "zv-test" end end
  if variant == "flip" then theme.renderKey = function() return flipped end end
  local zoneView = { build = function() end }
  local prefix = "/SCRIPTS/TOOLS/rfsuite.user/dashboard/zv-test/"
  local realLoadScript = _G.loadScript
  _G.loadScript = function(path, mode)
    if path == prefix .. "init.lua" then return function() return manifest end end
    if path == prefix .. "widget.lua" then return function() return theme end end
    if path == prefix .. "zv.lua" then return function() return zoneView end end
    return realLoadScript(path, mode)
  end
  local Runtime = _G.rfsuite.require("widgets/dashboard/runtime.lua")
  local w = Runtime.new({ x = 0, y = 0, w = 800, h = 458 }, {})
  w.preferences = w.preferences or {}
  w.preferences.dashboard = { theme_preflight = "user/zv-test" }
  local settled = false
  for i = 1, 1200 do
    pass(w, nil)
    if i > 50 and w.connectionReady == true and w._job == nil and w.built
        and w.themePath == "user/zv-test" and w._zoneView ~= nil then
      settled = true
      break
    end
  end
  _G.loadScript = realLoadScript
  if not settled then
    return nil, "positive control: the theme's zone view never came up (theme " .. tostring(w.themePath) .. ")"
  end
  asks = 0
  if variant == "flip" then flipped = false end
  local stamps, last, builds = 0, w._lastUIRefresh, 0
  for _ = 1, PASSES do
    if pass(w, nil) == "scene" then builds = builds + 1 end
    if w._lastUIRefresh ~= last then stamps, last = stamps + 1, w._lastUIRefresh end
  end
  return asks, stamps, builds
end

-- The throttle opens every fifth pass; a margin of two either way for the phase it starts in.
local lo, hi = PASSES // 5 - 2, PASSES // 5 + 2
local LABELS = { nokey = "zone view, theme without a key", key = "zone view, theme with a key (control)",
  flip = "zone view, theme key from nil to false" }
for _, variant in ipairs({ "nokey", "key", "flip" }) do
  cases = cases + 1
  local label = LABELS[variant]
  local asks, stamps, builds = zoneViewCase(variant)
  local wantBuilds = variant == "flip" and 1 or 0
  local ok, why = false, stamps
  if asks ~= nil then
    if asks < lo or asks > hi or stamps < lo or stamps > hi then
      why = string.format("the condition was asked %d times and the throttle stamped %d times in %d passes, expected %d..%d",
        asks, stamps, PASSES, lo, hi)
    elseif builds ~= wantBuilds then
      why = string.format("%d scene builds in %d passes, expected %d", builds, PASSES, wantBuilds)
    else
      ok = true
    end
  end
  if not ok then failures = failures + 1 end
  if verbose or not ok then
    print((ok and "PASS " or "FAIL ") .. label .. ": " ..
      (ok and string.format("%d asks, %d stamps, %d builds in %d passes", asks, stamps, builds, PASSES) or tostring(why)))
  end
end
Stubs.releaseCard()
print(string.format("%d cases, %d failures", cases, failures))
os.exit(failures == 0 and 0 or 1)
