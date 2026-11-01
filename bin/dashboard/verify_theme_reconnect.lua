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
    cached = {}, cachedReloads = 0, counting = false, instructions = 0, worstPass = 0 }
  _G.getRSSI = function() return world.linkUp and 100 or 0 end

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
  world.modelPrefs = { dashboard = { overrides = true, model_theme_preflight = "system/urban" } }
  assert(MP.saveByMcuId(world.mcuId, world.modelPrefs), "model store write")

  local Runtime = assert(loadfile(runtimePath))()
  local w = Runtime.new({ x = 0, y = 0, w = 800, h = 480 }, {})
  world.w = w

  -- Every theme resolve, counted where it happens (instrumentation only; the call goes through).
  local work = upvalue(w.background, "performBackgroundWork")
  local reloadActiveTheme, index = upvalue(work, "reloadActiveTheme")
  debug.setupvalue(work, index, function(self, ...)
    local r = reloadActiveTheme(self, ...)
    world.reloads[#world.reloads + 1] = { pass = world.pass, theme = self.themePath }
    if trace then print("    resolve " .. tostring(self.themePath) .. " at pass " .. world.pass) end
    return r
  end)
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
-- On the ground the model's theme does not survive the disconnect itself (a preferences reload in
-- the disconnected stretch has no board to load the model's half by), so only the window between
-- the link coming back and the UID is this check's; the figures are printed for the rest.
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
  expect((held.foreign or 0) == 0, tag .. ": no theme is resolved before the UID",
    tostring(held.foreign or 0) .. " resolve(s)")
  world.releaseUid()
  passes(world, 60, "uid")
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
  world.heldUid = {}
  world.holdUid = false
  passes(world, 400, "retry")
  expect(_G.rfsuite.session.mcu_id == world.mcuId, "control: a later retry identified the board",
    tostring(_G.rfsuite.session.mcu_id))
  expect(world.w.themePath == "system/urban", "timed out: a later answer brings the model's theme back",
    tostring(world.w.themePath))
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
