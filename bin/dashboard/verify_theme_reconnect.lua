-- The dashboard's theme across a reconnect, with the real widget runtime and the real MSP runtime
-- on a scripted flight controller (bin/accounting/stubs). The link is dropped and brought back
-- through getRSSI, the board's UID answer is held back to model a slow read, and a setting saved
-- while the link is down leaves a preferences reload pending, as the pilot's sequence does.
--
-- What is checked: while the link is up and its UID read has not settled, the model's theme is not
-- released from the module cache and no other theme is resolved in its place; once the UID arrives
-- the model's theme comes back without its cached modules being read from the card again, and the
-- pending reload runs once; a UID read that settles without a UID (an empty answer, or given up
-- after its retries) lets the radio's theme in without waiting for a retry to succeed.
--
-- And the link lost on the ground: the per-model half of the preferences stamp goes with the
-- board's id, which is not a preferences change, so no reload runs in the disconnected stretch and
-- the model's theme is neither released at the disconnect nor read from the card again at the
-- reconnect; a radio setting saved while the link is down is still picked up. A change found while
-- its reload is deferred is found once, not again on every stat interval of the deferral.
--
-- And the two ends of that wait: armed before the UID read has an answer, the theme waits no longer
-- than the splash for a read that is not sent before the disarm; a board whose API version is
-- refused never connects, so the model's theme stays in hand behind its refusal screen as while the
-- link is down. And a dashboard built again while the read has no answer waits as well.
--
--   lua5.3 bin/dashboard/verify_theme_reconnect.lua [runtime.lua] [--trace]
local runtimePath = "src/rfsuite/widgets/dashboard/runtime.lua"
local trace = false
for _, a in ipairs(arg or {}) do
  if a == "--trace" then trace = true else runtimePath = a end
end

local Stubs = assert(loadfile("bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile("bin/accounting/stubs/fc.lua"))()

local API_DIR = "src/rfsuite/tasks/msp/api"
local MODEL_THEME = "/themes/urban/"
local UID_COMMAND = 160

local function listLuaFiles(path)
  local pipe = assert(io.popen("ls -1 " .. path .. " 2>/dev/null"))
  local names = {}
  for name in pipe:lines() do
    if string.match(name, "%.lua$") then names[#names + 1] = name end
  end
  pipe:close()
  table.sort(names)
  return names
end

local failures, checks = 0, 0
local function expect(ok, label, detail)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label .. (detail and (": " .. detail) or ""))
  end
end

local function upvalue(fn, name)
  for i = 1, 200 do
    local key, value = debug.getupvalue(fn, i)
    if not key then break end
    if key == name then return value, i end
  end
  error("missing production upvalue: " .. name)
end

local function modelThemeModules()
  local n = 0
  for path in pairs(_G.rfsuite.modules or {}) do
    if string.find(path, MODEL_THEME, 1, true) then n = n + 1 end
  end
  return n
end

-- The widget the passes drive, with its theme resolves and preferences reloads counted where they
-- happen (instrumentation only; the calls go through). A widget built later is instrumented the
-- same way when it takes over.
local function instrument(world, w)
  world.w = w
  local work = upvalue(w.background, "performBackgroundWork")
  local reloadActiveTheme, index = upvalue(work, "reloadActiveTheme")
  debug.setupvalue(work, index, function(self, ...)
    local r = reloadActiveTheme(self, ...)
    world.reloads[#world.reloads + 1] = { pass = world.pass, theme = self.themePath }
    if trace then print("    resolve " .. tostring(self.themePath) .. " at pass " .. world.pass) end
    return r
  end)
  -- Every preferences reload that runs (it answers true), counted the same way.
  local reloadPreferencesIfNeeded, pIndex = upvalue(work, "reloadPreferencesIfNeeded")
  debug.setupvalue(work, pIndex, function(self, ...)
    local r = reloadPreferencesIfNeeded(self, ...)
    if r == true then
      world.prefReloads = world.prefReloads + 1
      if trace then print("    preferences reload at pass " .. world.pass) end
    end
    return r
  end)
end

-- One world per scenario: a fresh card, session, module cache and widget.
local function newWorld()
  Stubs.install(".")
  FC.install(Stubs)
  Stubs.reset()
  FC.reset()
  FC.loadReplies(API_DIR, listLuaFiles(API_DIR))
  Stubs.clearCard()
  Stubs.prefsStat = { size = 1 }
  -- A helicopter idling on the bench, as bin/accounting/measure.lua scripts it.
  for k, v in pairs({ ["Vbat"] = 24.6, ["Curr"] = 3.2, ["Capa"] = 850, ["Bat%"] = 74, ["Cel#"] = 6,
    ["Hspd"] = 0, ["RQly"] = 96, ["1RSS"] = -42, ["2RSS"] = -45, ["Thr%"] = 0, ["ARM"] = 0,
    ["ARMD"] = 0, ["Gov"] = 0 }) do Stubs.sensors[k] = v end

  local world = { linkUp = true, holdUid = false, emptyUid = false, heldUid = {},
    cardLoads = 0, reloads = {}, released = 0, pass = 0, builds = 0, peakKb = 0, baseKb = 0,
    cached = {}, cachedReloads = 0, counting = false, instructions = 0, worstPass = 0,
    stats = {}, statCalls = {}, prefReloads = 0 }
  _G.getRSSI = function() return world.linkUp and 100 or 0 end

  -- The stub answers one stat for every file; a path given its own here answers that instead, so
  -- the radio's preferences file can change without the model's file changing with it. Every
  -- stat is counted per path.
  local fstat = _G.fstat
  _G.fstat = function(path, ...)
    world.statCalls[path] = (world.statCalls[path] or 0) + 1
    if world.stats[path] ~= nil then return world.stats[path] end
    return fstat(path, ...)
  end

  -- The board's UID answer, held back while `holdUid` is set: the request is kept and answered
  -- when the hold is lifted, as a board that answers late does. `emptyUid` answers with nothing.
  local onPush = Stubs.onPush
  Stubs.onPush = function(frameType, payload)
    local cmd = (payload[3] and (payload[3] & 0x10) ~= 0) and ((payload[5] or 0) | ((payload[6] or 0) << 8)) or nil
    if cmd == UID_COMMAND and world.holdUid then
      world.heldUid[#world.heldUid + 1] = { frameType, payload }
      return true
    end
    if cmd == UID_COMMAND and world.emptyUid then
      local saved = FC.replies[UID_COMMAND]
      FC.replies[UID_COMMAND] = {}
      local r = onPush(frameType, payload)
      FC.replies[UID_COMMAND] = saved
      return r
    end
    return onPush(frameType, payload)
  end
  function world.releaseUid()
    world.holdUid = false
    local held = world.heldUid
    world.heldUid = {}
    for i = 1, #held do onPush(held[i][1], held[i][2]) end
  end

  -- Module reads from the card for the model's theme, wherever they come from.
  local loadScript = _G.loadScript
  _G.loadScript = function(path, ...)
    if type(path) == "string" and string.find(path, MODEL_THEME, 1, true) then
      world.cardLoads = world.cardLoads + 1
      if world.cached[path] then world.cachedReloads = world.cachedReloads + 1 end
      if trace then print("    card read " .. path .. " at pass " .. world.pass) end
    end
    return loadScript(path, ...)
  end

  -- The per-model store of the board the scripted flight controller identifies as, written
  -- through the suite's own writer. The radio's settings are the shipped defaults.
  local Uid = _G.rfsuite.require("tasks/msp/api/uid.lua")
  world.mcuId = Uid.parse(FC.replies[UID_COMMAND]).mcuId
  local MP = _G.rfsuite.require("lib/model_preferences.lua")
  world.MP = MP
  world.globalPath = MP.preferencesPath()
  world.modelPrefs = { dashboard = { overrides = true, model_theme_preflight = "system/urban" } }
  assert(MP.saveByMcuId(world.mcuId, world.modelPrefs), "model store write")

  local Runtime = assert(loadfile(runtimePath))()
  local w = Runtime.new({ x = 0, y = 0, w = 800, h = 480 }, {})
  instrument(world, w)

  -- Every scene the widget hands to LVGL, with the job that built it and the theme it was built for.
  world.trees = {}
  local build = _G.lvgl.build
  _G.lvgl.build = function(children, ...)
    local job = world.w and world.w._job
    world.trees[#world.trees + 1] = { pass = world.pass, kind = job and job.kind, children = children,
      theme = world.w and world.w.themePath, count = type(children) == "table" and #children or 0 }
    return build(children, ...)
  end
  return world
end


local function passes(world, n, label)
  for _ = 1, n do
    world.pass = world.pass + 1
    local before = modelThemeModules()
    local reloadsBefore = #world.reloads
    local builtBefore = world.w.built == true
    local fblBefore = world.w.state.fblConnected == true
    Stubs.tick()
    if world.counting then
      -- Lua VM instructions of the pass, the unit bin/accounting/measure.lua prices passes in.
      local spent = 0
      debug.sethook(function() spent = spent + 1 end, "", 1)
      world.w.refresh(world.w, nil, nil)
      debug.sethook()
      world.instructions = world.instructions + spent
      if spent > world.worstPass then world.worstPass = spent end
    else
      world.w.refresh(world.w, nil, nil)
    end
    local after = modelThemeModules()
    if after < before then world.released = world.released + (before - after) end
    if not builtBefore and world.w.built == true and world.w.connectionReady == true and world.w.theme then
      world.builds = world.builds + 1
    end
    if not fblBefore and world.w.state.fblConnected == true then
      world.resolvedAtEdge = _G.rfsuite.session.modelPreferencesResolved
    end
    local kb = collectgarbage("count")
    if kb > world.peakKb then world.peakKb = kb end
    if trace and (after ~= before or #world.reloads ~= reloadsBefore) then
      local st = _G.rfsuite.require("tasks/msp/runtime.lua").getState()
      print(string.format("  [%s %4d] fbl=%s settled=%s mcu=%s modules %d->%d theme=%s mode=%s",
        label or "", world.pass, tostring(world.w.state.fblConnected), tostring(st.uidReadSettled),
        tostring(_G.rfsuite.session.mcu_id), before, after, tostring(world.w.themePath),
        tostring(world.w.flightMode)))
    end
  end
end

local function connectAndSettle(world)
  passes(world, 400, "settle")
  expect(_G.rfsuite.session.mcu_id == world.mcuId, "control: the board identified itself",
    tostring(_G.rfsuite.session.mcu_id))
  expect(world.w.themePath == "system/urban", "control: the model's theme is on screen",
    tostring(world.w.themePath))
  expect(modelThemeModules() > 0, "control: the model's theme modules are loaded")
  world.loadedBeforeDrop = {}
  for path in pairs(_G.rfsuite.modules or {}) do
    if string.find(path, MODEL_THEME, 1, true) then world.loadedBeforeDrop[path] = true end
  end
end

-- A flight: arm, spool up under the governor, land and disarm.
local function fly(world)
  Stubs.sensors["ARM"], Stubs.sensors["Gov"] = 1, 2
  passes(world, 20, "armed")
  Stubs.sensors["Gov"], Stubs.sensors["Thr%"], Stubs.sensors["Hspd"] = 4, 40, 1800
  passes(world, 40, "flight")
  Stubs.sensors["ARM"], Stubs.sensors["Gov"], Stubs.sensors["Thr%"], Stubs.sensors["Hspd"] = 0, 0, 0, 0
  passes(world, 40, "landed")
  expect(world.w.state.hadInflightFlight == true, "control: the flight was seen",
    tostring(world.w.state.hadInflightFlight))
end

-- A setting saved while the link is down: the store is written and its file stat moves.
local function saveWhileDown(world)
  world.modelPrefs.dashboard.cfg_system_urban_scheme = "dark"
  assert(world.MP.saveByMcuId(world.mcuId, world.modelPrefs), "model store write while down")
  Stubs.prefsStat = { size = (Stubs.prefsStat.size or 1) + 1 }
end

local function reconnectWindow(world, uidPasses)
  world.released, world.cardLoads, world.reloads, world.builds = 0, 0, {}, 0
  -- The model's theme modules the module cache held before the link went down: a read of one of
  -- these from the card after the reconnect is the cost the release causes.
  world.cached, world.cachedReloads = {}, 0
  for path in pairs(world.loadedBeforeDrop or {}) do world.cached[path] = true end
  collectgarbage("collect")
  world.peakKb = collectgarbage("count")
  world.baseKb = world.peakKb
  world.counting, world.instructions, world.worstPass = true, 0, 0
  world.holdUid = true
  world.linkUp = true
  passes(world, uidPasses, "held")
  local window = { released = world.released, reloads = #world.reloads, cardLoads = world.cardLoads }
  if trace then print(string.format("  window: %d released, %d resolves", world.released, #world.reloads)) end
  for _, r in ipairs(world.reloads) do
    if r.theme ~= "system/urban" then window.foreign = (window.foreign or 0) + 1 end
  end
  return window
end

local function cost(world, tag)
  print(string.format("COUNT %s released=%d cachedReReads=%d cardReads=%d resolves=%d builds=%d "
    .. "instructions=%d worstPass=%d peakKbAboveStart=%.0f", tag, world.released, world.cachedReloads,
    world.cardLoads, #world.reloads, world.builds, world.instructions, world.worstPass, world.peakKb - world.baseKb))
  world.counting = false
end

-- 0. The issue's sequence: a flight, the pack unplugged, a setting saved while down, and the pack
-- plugged back in with the board's UID answer slow to come.
do
  if trace then print("scenario: after a flight, slow reconnect, reload pending") end
  local world = newWorld()
  connectAndSettle(world)
  fly(world)
  world.linkUp = false
  passes(world, 30, "offline")
  expect(world.w.themePath == "system/urban", "control: the model's theme stands while offline after the flight",
    tostring(world.w.themePath))
  expect(modelThemeModules() > 0, "control: the model's theme modules stay loaded while offline")
  saveWhileDown(world)
  passes(world, 30, "offline")
  local held = reconnectWindow(world, 30)
  expect(world.w.state.fblConnected == true, "control: the link is back while the UID is held")
  expect(#world.heldUid > 0, "control: the UID request was held", #world.heldUid .. " held")
  -- The session's resolved flag is the previous link's on the edge pass (the connect chain's uid
  -- task clears it only when it runs on this link), so it must not be what opens the gate.
  expect(world.resolvedAtEdge == true, "control: the previous link's resolved flag stands on the edge pass",
    tostring(world.resolvedAtEdge))
  expect(held.released == 0, "after a flight: the model's theme is not released before the UID",
    held.released .. " module(s) released")
  expect((held.foreign or 0) == 0, "after a flight: no other theme is resolved before the UID",
    tostring(held.foreign or 0) .. " foreign resolve(s)")
  expect(held.reloads == 0, "after a flight: no theme is resolved before the UID", held.reloads .. " resolve(s)")
  world.releaseUid()
  passes(world, 60, "uid")
  expect(world.w.themePath == "system/urban", "after a flight: the model's theme is back after the UID",
    tostring(world.w.themePath))
  expect(world.cachedReloads == 0, "after a flight: the model's cached theme modules are not read from the card again",
    world.cachedReloads .. " re-read(s)")
  expect(world.w.state.themeConfig and world.w.state.themeConfig.scheme == "dark",
    "after a flight: the setting saved while down is applied",
    tostring(world.w.state.themeConfig and world.w.state.themeConfig.scheme))
  expect(world.w._themeReloadPending ~= true and world.w._reloadPending ~= true,
    "after a flight: no reload is left stranded after the UID")
  expect(world.builds > 0, "control: the dashboard was built after the UID", world.builds .. " build(s)")
  -- The preferences reload left pending by the save runs once, after the UID, with both halves:
  -- run in the window it would adopt the stamp without the model's half, and the model's file
  -- appearing would signal it again.
  expect(#world.reloads == 1, "after a flight: the theme is resolved once after the UID",
    #world.reloads .. " resolve(s)")
  cost(world, "after-flight")
end

-- 1 and 2. A reconnect on the ground, with and without a setting saved while the link was down.
-- This check covers the window between the link coming back and the UID; the disconnect itself is
-- scenario 5's. The stub answers one stat for every file, so the save here moves the radio's file,
-- the model's file and the reload request together.
for _, pending in ipairs({ true, false }) do
  local tag = pending and "ground+pending" or "ground"
  if trace then print("scenario: " .. tag) end
  local world = newWorld()
  connectAndSettle(world)
  world.linkUp = false
  passes(world, 30, "down")
  if pending then saveWhileDown(world) end
  passes(world, 30, "down")
  local held = reconnectWindow(world, 30)
  expect(#world.heldUid > 0, "control: the UID request was held (" .. tag .. ")")
  expect(held.reloads == 0, tag .. ": no theme is resolved before the UID", held.reloads .. " resolve(s)")
  world.releaseUid()
  passes(world, 60, "uid")
  expect(#world.reloads > held.reloads, "control: the theme is resolved after the UID (" .. tag .. ")",
    (#world.reloads - held.reloads) .. " resolve(s)")
  expect(world.w.themePath == "system/urban", tag .. ": the model's theme is back after the UID",
    tostring(world.w.themePath))
  cost(world, tag)
end

-- 3. An empty UID answer settles the read without a UID: the radio's theme is let in.
do
  if trace then print("scenario: UID settles without a UID") end
  local world = newWorld()
  connectAndSettle(world)
  fly(world)
  world.linkUp = false
  passes(world, 60, "offline")
  world.emptyUid = true
  world.linkUp = true
  passes(world, 60, "empty")
  local st = _G.rfsuite.require("tasks/msp/runtime.lua").getState()
  expect(st.uidReadSettled == true and _G.rfsuite.session.mcu_id == nil,
    "control: the UID read settled without a UID", "settled=" .. tostring(st.uidReadSettled)
    .. " mcu=" .. tostring(_G.rfsuite.session.mcu_id))
  expect(world.w.themePath == "system/default", "settled without a UID: the radio's theme is resolved",
    tostring(world.w.themePath))
  -- A real change of theme still releases the one it replaces (the release itself is unchanged).
  expect(modelThemeModules() == 0, "settled without a UID: the model's theme modules are released",
    modelThemeModules() .. " still loaded")
end

-- 4. A UID read that times out: given up after its retries, the read is settled without a UID and
-- re-armed with a backoff. The radio's theme is let in then, without waiting for a retry to
-- succeed; a later answer still brings the model's theme back.
do
  if trace then print("scenario: UID read times out") end
  local world = newWorld()
  connectAndSettle(world)
  fly(world)
  world.linkUp = false
  passes(world, 60, "offline")
  world.holdUid = true
  world.linkUp = true
  local st = _G.rfsuite.require("tasks/msp/runtime.lua").getState()
  local settledAt = nil
  for _ = 1, 300 do
    passes(world, 1, "timeout")
    if st.uidReadSettled == true then settledAt = world.pass; break end
  end
  expect(settledAt ~= nil and _G.rfsuite.session.mcu_id == nil, "control: the UID read gave up without a UID",
    "settledAt=" .. tostring(settledAt))
  expect(st.pendingUidRead == true, "control: the UID read is re-armed after giving up")
  passes(world, 10, "timeout")
  expect(world.w.themePath == "system/default", "timed out: the radio's theme is resolved without a retry",
    tostring(world.w.themePath))
  expect(modelThemeModules() == 0, "timed out: the model's theme modules are released",
    modelThemeModules() .. " still loaded")
  world.heldUid = {}
  world.holdUid = false
  passes(world, 400, "retry")
  expect(_G.rfsuite.session.mcu_id == world.mcuId, "control: a later retry identified the board",
    tostring(_G.rfsuite.session.mcu_id))
  expect(world.w.themePath == "system/urban", "timed out: a later answer brings the model's theme back",
    tostring(world.w.themePath))
end

-- A radio setting saved: only the radio's preferences file moves, with its time.
-- Without a running clock (`second` nil) the time stays and only the size moves, so the stamp
-- cannot say which file changed and the reload reads both.
local function saveRadioSetting(world, second, size)
  world.stats[world.globalPath] = { size = size or 2, time = { year = 2026, mon = 11, day = 1, hour = 12,
    min = 0, sec = second or 0 } }
end

-- 5. The link lost on the ground, and back. Losing the link is not a preferences change: no reload
-- runs while it is down, the model's theme is not released at the disconnect, and at the
-- reconnect it comes back from the module cache. A radio setting saved while the link is down is
-- still picked up, and still leaves the model's theme alone -- also on a radio whose clock does not
-- run, where the reload cannot tell which file moved and reads both.
for _, case in ipairs({ "none", "clock", "noclock" }) do
  local radioSave = case ~= "none"
  local tag = ({ none = "ground link loss", clock = "ground link loss, radio setting saved",
    noclock = "ground link loss, radio setting saved without a clock" })[case]
  if trace then print("scenario: " .. tag) end
  local world = newWorld()
  saveRadioSetting(world, 0)
  connectAndSettle(world)
  expect((world.statCalls[world.globalPath] or 0) > 0, "control: the radio's preferences file is watched ("
    .. tag .. ")", world.globalPath)
  world.released, world.prefReloads = 0, 0
  world.linkUp = false
  passes(world, 30, "down")
  if case == "clock" then saveRadioSetting(world, 30) end
  if case == "noclock" then saveRadioSetting(world, nil, 3) end
  passes(world, 30, "down")
  expect(world.w.state.fblConnected ~= true and _G.rfsuite.session.mcu_id == nil,
    "control: the link is down and the board's id gone (" .. tag .. ")")
  local downReloads, downReleased = world.prefReloads, world.released
  expect(downReleased == 0, tag .. ": the model's theme is not released at the disconnect",
    downReleased .. " module(s) released")
  expect(world.w.themePath == "system/urban", tag .. ": the model's theme stands while the link is down",
    tostring(world.w.themePath))
  if radioSave then
    expect(downReloads == 1, tag .. ": the radio setting saved while down is reloaded, once",
      downReloads .. " reload(s)")
  else
    expect(downReloads == 0, tag .. ": losing the link runs no preferences reload", downReloads .. " reload(s)")
  end
  world.prefReloads = 0
  reconnectWindow(world, 30)
  world.releaseUid()
  passes(world, 60, "uid")
  expect(world.w.themePath == "system/urban", tag .. ": the model's theme is back after the UID",
    tostring(world.w.themePath))
  expect(world.cachedReloads == 0, tag .. ": the model's cached theme modules are not read from the card again",
    world.cachedReloads .. " re-read(s)")
  expect(world.prefReloads == 0, tag .. ": the reconnect runs no preferences reload", world.prefReloads .. " reload(s)")
  cost(world, ({ none = "ground-loss", clock = "ground-loss+radio-save", noclock = "ground-loss+radio-save-noclock" })[case])
end

-- 6. A change found while its reload is deferred is found once. After a flight the reload waits
-- for the link (the post-flight screen stays); the radio's preferences file is statted once for the
-- change and not again until the reload has run, which it does once, on the reconnect.
do
  if trace then print("scenario: deferred reload, detected once") end
  local world = newWorld()
  saveRadioSetting(world, 0)
  connectAndSettle(world)
  fly(world)
  world.linkUp = false
  passes(world, 30, "offline")
  world.prefReloads = 0
  saveRadioSetting(world, 30)
  passes(world, 15, "offline")
  expect(world.w._reloadPending == true, "control: the change was found and its reload deferred",
    tostring(world.w._reloadPending))
  local statsBefore = world.statCalls[world.globalPath] or 0
  passes(world, 60, "offline")
  local again = (world.statCalls[world.globalPath] or 0) - statsBefore
  expect(again == 0, "deferred: the pending change is not looked for again while it waits",
    again .. " stat(s) of the preferences file in 6 s")
  expect(world.prefReloads == 0, "control: the reload waited while the link was down", world.prefReloads .. " reload(s)")
  world.linkUp = true
  passes(world, 60, "back")
  expect(world.prefReloads == 1, "deferred: the reload runs once after the link is back",
    world.prefReloads .. " reload(s)")
  expect(world.w._reloadPending ~= true, "deferred: nothing is left pending after the reload")
  expect(world.w.themePath == "system/urban", "deferred: the model's theme is on screen after the reload",
    tostring(world.w.themePath))
end

-- 7. Armed before the UID read has an answer. Arming pauses MSP and takes the read off the queue;
-- it is owed again, but not sent while the board is armed, so it cannot settle before the disarm.
-- The theme waits no longer than the splash: nothing is resolved while the splash waits for the
-- startup reads, and once it gives up (its soft timeout) the radio's theme is drawn, as before this
-- change; the model's comes back once the read is answered after the disarm.
do
  if trace then print("scenario: armed before the UID") end
  local world = newWorld()
  connectAndSettle(world)
  world.linkUp = false
  passes(world, 30, "down")
  world.holdUid = true
  world.linkUp = true
  for _ = 1, 60 do
    passes(world, 1, "held")
    if #world.heldUid > 0 and world.w.state.fblConnected == true then break end
  end
  expect(#world.heldUid > 0 and world.w.state.fblConnected == true,
    "control: the link is back and the UID request is out (armed before the UID)")
  Stubs.sensors["ARM"], Stubs.sensors["Gov"] = 1, 2
  local resolvesBefore = #world.reloads
  passes(world, 60, "armed")
  local st = _G.rfsuite.require("tasks/msp/runtime.lua").getState()
  expect(st.lastArmed == true and st.uidReadSettled == false and st.pendingUidRead == true,
    "control: MSP is paused and the UID read is owed while armed", "armed=" .. tostring(st.lastArmed)
    .. " settled=" .. tostring(st.uidReadSettled) .. " pending=" .. tostring(st.pendingUidRead))
  expect(world.w.connectionReady ~= true and #world.reloads == resolvesBefore,
    "armed before the UID: no theme is resolved while the splash waits",
    (#world.reloads - resolvesBefore) .. " resolve(s), ready=" .. tostring(world.w.connectionReady))
  -- The first pass the splash gives up on: it is the soft timeout, 25 s after the wait began, and
  -- not a later event; nothing was resolved before it.
  local pendingSince = world.w.pendingSince
  local readyAt, readyElapsed, resolvesBeforeReady = nil, nil, nil
  for _ = 1, 400 do
    local resolvesSoFar = #world.reloads
    passes(world, 1, "armed")
    if world.w.connectionReady == true then
      readyAt, resolvesBeforeReady = world.pass, resolvesSoFar - resolvesBefore
      readyElapsed = _G.getTime() / 100 - (pendingSince or 0)
      break
    end
  end
  expect(readyAt ~= nil and pendingSince ~= nil and world.w.pendingSince == pendingSince
    and readyElapsed >= 25.0 and readyElapsed < 25.2,
    "armed before the UID: the splash gives up at its soft timeout, 25 s after the wait began",
    "ready at pass " .. tostring(readyAt) .. ", " .. tostring(readyElapsed) .. " s after the wait began")
  expect(resolvesBeforeReady == 0, "armed before the UID: nothing is resolved before the splash gives up",
    tostring(resolvesBeforeReady) .. " resolve(s)")
  expect(st.lastArmed == true and st.uidReadSettled == false and _G.rfsuite.session.mcu_id == nil,
    "control: still armed, the UID read unsettled and no board id when the splash gives up")
  -- And the dashboard is drawn then: a completed scene build of the radio's theme replaces the
  -- splash while the read is still owed and MSP is still paused.
  local scene = nil
  for _ = 1, 30 do
    passes(world, 1, "armed")
    for i = #world.trees, 1, -1 do
      local t = world.trees[i]
      if t.pass <= readyAt then break end
      if t.kind == "scene" then scene = t end
    end
    if scene then break end
  end
  expect(scene ~= nil and scene.theme == "system/default" and scene.count > 0,
    "armed before the UID: the radio's dashboard scene is built once the splash gives up",
    scene and (tostring(scene.theme) .. ", " .. scene.count .. " node(s) at pass " .. scene.pass) or "no scene built")
  expect(st.lastArmed == true and st.uidReadSettled == false and _G.rfsuite.session.mcu_id == nil,
    "control: still armed and the UID read unsettled when the scene is built")
  local onScreen = world.trees[#world.trees]
  expect(world.w.built == true and onScreen ~= nil and onScreen.kind == "scene",
    "armed before the UID: the scene is what LVGL holds, not the splash",
    onScreen and tostring(onScreen.kind) or "nothing built")
  expect(world.w.theme ~= nil and world.w.themePath == "system/default",
    "armed before the UID: the radio's theme is drawn once the splash gives up, not only after the disarm",
    tostring(world.w.themePath) .. ", theme " .. tostring(world.w.theme ~= nil))
  -- The request the queue dropped is never answered; the read goes out again after the disarm.
  world.heldUid = {}
  world.holdUid = false
  Stubs.sensors["ARM"], Stubs.sensors["Gov"] = 0, 0
  passes(world, 200, "disarmed")
  expect(_G.rfsuite.session.mcu_id == world.mcuId, "control: the board identified itself after the disarm",
    tostring(_G.rfsuite.session.mcu_id))
  expect(world.w.themePath == "system/urban", "armed before the UID: the model's theme is back after the disarm",
    tostring(world.w.themePath))
end

-- 8. A board whose API version is refused, plugged in after a link loss on the ground. It never
-- connects, so its connect edge never comes and the model's preferences stay in hand behind the
-- refusal screen -- nothing released, as while the link is down. A board that is accepted afterwards
-- is a connect edge like any other: it resolves its own theme, here the same model's, from the cache.
do
  if trace then print("scenario: refused board after a ground link loss") end
  local world = newWorld()
  connectAndSettle(world)
  world.released = 0
  world.linkUp = false
  passes(world, 30, "down")
  local accepted = FC.replies[1]
  FC.replies[1] = { 0, 1, 0 }
  world.linkUp = true
  passes(world, 60, "refused")
  local st = _G.rfsuite.require("tasks/msp/runtime.lua").getState()
  expect(st.unsupportedApi == true and world.w.state.fblConnected ~= true,
    "control: the board's API version is refused and it does not connect",
    "unsupported=" .. tostring(st.unsupportedApi) .. " fbl=" .. tostring(world.w.state.fblConnected))
  expect(world.released == 0, "refused board: the model's theme is held behind the refusal screen, not released",
    world.released .. " module(s) released")
  FC.replies[1] = accepted
  world.linkUp = false
  passes(world, 30, "down")
  world.cached, world.cachedReloads = {}, 0
  for path in pairs(world.loadedBeforeDrop or {}) do world.cached[path] = true end
  world.linkUp = true
  passes(world, 200, "accepted")
  expect(world.w.state.fblConnected == true and _G.rfsuite.session.mcu_id == world.mcuId,
    "control: the accepted board connected and identified itself")
  expect(world.w.themePath == "system/urban", "refused board: the accepted board's model theme is on screen",
    tostring(world.w.themePath))
  expect(world.cachedReloads == 0, "refused board: the model's theme is not read from the card again",
    world.cachedReloads .. " re-read(s)")
end

-- 9. A dashboard built while the link is up and its UID read has no answer. EdgeTX builds every
-- widget again when it loads the screens' layout again (a model selected, the screens edited); the
-- widgets share one Lua state, so the new instance -- a fresh copy of the runtime, as the widget's
-- create loads it -- meets the same MSP runtime mid-read. It resolves nothing before the UID
-- arrives, draws the splash meanwhile, and then the model's theme from the module cache.
do
  if trace then print("scenario: built during an unsettled connection") end
  local world = newWorld()
  connectAndSettle(world)
  world.linkUp = false
  passes(world, 30, "down")
  world.holdUid = true
  world.linkUp = true
  for _ = 1, 60 do
    passes(world, 1, "held")
    if #world.heldUid > 0 and world.w.state.fblConnected == true then break end
  end
  local Msp = _G.rfsuite.require("tasks/msp/runtime.lua")
  local st = Msp.getState()
  expect(#world.heldUid > 0 and Msp.isFblConnected() == true and st.uidReadSettled == false,
    "control: the link is up and its UID read has no answer when the dashboard is built again")
  -- The old instance goes, as the firmware deletes it, and a new one is built from a fresh copy.
  _G.rfsuite.dashboardWidgets[world.w] = nil
  world.reloads, world.cachedReloads = {}, 0
  world.cached = {}
  for path in pairs(world.loadedBeforeDrop or {}) do world.cached[path] = true end
  local RuntimeB = assert(loadfile(runtimePath))()
  local loads = 0
  local loadTheme, li = upvalue(RuntimeB.new, "loadThemeModuleForState")
  debug.setupvalue(RuntimeB.new, li, function(...)
    loads = loads + 1
    return loadTheme(...)
  end)
  local b = RuntimeB.new({ x = 0, y = 0, w = 800, h = 480 }, {})
  expect(loads == 0 and b.theme == nil, "built during an unsettled connection: the constructor resolves no theme",
    loads .. " theme load(s), theme " .. tostring(b.theme ~= nil) .. ", " .. tostring(b.themePath))
  instrument(world, b)
  local treesBefore = #world.trees
  passes(world, 30, "held")
  expect(#world.reloads == 0 and b.theme == nil, "built during an unsettled connection: no theme is resolved before the UID",
    #world.reloads .. " resolve(s)")
  local splash = false
  for i = treesBefore + 1, #world.trees do
    if world.trees[i].kind == "splash" then splash = true end
  end
  expect(splash and b.connectionReady ~= true, "built during an unsettled connection: the splash is drawn while it waits")
  world.releaseUid()
  passes(world, 60, "uid")
  expect(_G.rfsuite.session.mcu_id == world.mcuId, "control: the board identified itself (built during an unsettled connection)",
    tostring(_G.rfsuite.session.mcu_id))
  expect(b.themePath == "system/urban" and b.theme ~= nil, "built during an unsettled connection: the model's theme after the UID",
    tostring(b.themePath))
  local foreign = 0
  for _, r in ipairs(world.reloads) do
    if r.theme ~= "system/urban" then foreign = foreign + 1 end
  end
  expect(foreign == 0, "built during an unsettled connection: no other theme is resolved on the way",
    foreign .. " foreign resolve(s)")
  expect(world.cachedReloads == 0,
    "built during an unsettled connection: the model's cached theme modules are not read from the card again",
    world.cachedReloads .. " re-read(s)")
end

-- The memory probe's own control: an allocation it must see.
do
  collectgarbage("collect")
  local before = collectgarbage("count")
  local hold = {}
  for i = 1, 4096 do hold[i] = string.rep("x", 64) .. i end
  local after = collectgarbage("count")
  expect(after - before > 200 and #hold == 4096, "control: the memory probe sees an allocation",
    string.format("%.0f kB", after - before))
end

Stubs.releaseCard()
if failures > 0 then
  print(string.format("%d of %d theme reconnect checks failed", failures, checks))
  os.exit(1)
end
print(string.format("%d theme reconnect checks, 0 failures", checks))
