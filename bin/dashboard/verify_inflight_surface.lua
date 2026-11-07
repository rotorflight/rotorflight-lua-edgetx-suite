-- The real dashboard entry points must revoke output before fast sampling or a build can run.
local Stubs = dofile("bin/accounting/stubs/edgetx.lua")
local FC = dofile("bin/accounting/stubs/fc.lua")
Stubs.install(arg[1] or ".")
FC.install(Stubs)
Stubs.reset()
FC.reset()
local Runtime = rfsuite.require("widgets/dashboard/runtime.lua")
local Drive = rfsuite.require("widgets/dashboard/inflight/drive.lua")
local Input = rfsuite.require("widgets/dashboard/inflight/input.lua")
local readBoard = dofile("bin/dashboard/inflight_board_fixture.lua")(rfsuite.require)
local passed, failed, checks = 0, {}, 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
local function scenario(name, run)
  local ok, err = pcall(run)
  if ok then passed = passed + 1; print("PASS " .. name)
  else failed[#failed + 1] = name .. ": " .. tostring(err); print("FAIL " .. failed[#failed]) end
end
-- The overlay's modules leave once no dashboard holds a session or shows tuning (runtime.lua,
-- releaseInflight), so each fixture loads them through the real opening path before its drive is
-- put in, and takes the module tables that are current after that load.
local function ready(widget)
  widget.inflightFullscreen = true
  for _ = 1, 20 do
    widget._job = {kind = "control", oneShot = true, step = function() return true end}
    widget:refresh(0, nil)
    if widget._inflight then break end
  end
  Drive = rfsuite.require("widgets/dashboard/inflight/drive.lua")
  Input = rfsuite.require("widgets/dashboard/inflight/input.lua")
end
local function fixture(armed)
  local widget = Runtime.new({x = 0, y = 0, w = 480, h = 320}, {})
  widget.preferences.general = {preview_inflight_tuning = true}
  widget.preferences.inflight = {enabled = true}
  ready(widget)
  widget.state.armed, widget.state.armedSeen, widget.state.fblConnected = armed, true, true
  widget._foreground, widget.inflightFullscreen = true, true
  local writes = {}
  local radio = {
    now = getTime, flightMode = function() return 2 end,
    sensor = function(name) if name == "AdjF" then return 0 elseif name == "PID#" or name == "RTE#" then return 1 end end,
    switchValue = function() return false end, channelUs = function() return nil end,
    globalVariableDetails = function() end, mixesCount = function() end, flightModeData = function() end,
    setGlobalVariable = function(index, fm, value) writes[#writes + 1] = {index, fm, value}; return true end
  }
  local d = readBoard(Drive.newDrive(radio, Drive.settings(widget.preferences, {})))
  d._source, d._radioSource = widget.modelPreferences, widget.preferences
  d._checkedAt, d._checkResult = getTime(), "ok"
  d.sessionProfiles = {pid = {[1] = true}, rate = {[1] = true}}
  d.profileValues = {pid = {[1] = {}}, rate = {[1] = {}}, global = {}}
  d.profilePrevious = {pid = {}, rate = {}, global = {}}
  d:watchProfiles()
  d.open, d.live, d.phase = true, true, armed and "live" or "ground"
  d.baseline, d.primedValues = {identity = "control"}, {[18] = 100}
  widget._inflight = d
  return widget, d, writes
end
local function energize(d, writes)
  d.live, d.phase, d.open = true, "live", true
  d:ensureBankArmed()
  check(d:dispatch("step", 1, "touch"), "positive control: a visible live surface steps")
  check(d.written ~= 0 and (d.bankWritten or 0) ~= 0 and #writes > 0, "positive control: both variables are active")
end
local function cleared(d, writes, before)
  local seen = {}
  for i = before + 1, #writes do
    local write = writes[i]
    check(write[3] == 0, "every write after release loss is zero")
    check(write[2] == 2, "cleanup clears the flight mode that owns output")
    seen[write[1]] = true
  end
  check(seen[d.settings.bank_gvar - 1] and seen[d.settings.value_gvar - 1], "both next model writes are zero in the same pass: bank="
    .. tostring(d.bankWritten) .. " value=" .. tostring(d.written) .. " writes=" .. (#writes - before))
  check(not d.live and d.written == 0 and d.bankWritten == 0, "release and both outputs are cleared")
end
local function job(widget)
  widget._job = {kind = "control", oneShot = true, step = function() return true end}
end

-- The release fixtures model an already loaded surface. Exercise the normal preload path
-- once so their injected live drives use the same ready module caches as a real open visit.
do
  local widget = Runtime.new({x = 0, y = 0, w = 480, h = 320}, {})
  widget.preferences.general = {preview_inflight_tuning = true}
  widget.preferences.inflight = {enabled = true}
  widget.inflightFullscreen = true
  for _ = 1, 20 do
    job(widget); widget:refresh(0, nil)
    if widget._inflight then break end
  end
  job(widget); widget:refresh(nil, nil)
end

scenario("foreground open takes effect before a pending job", function()
  local widget, d = fixture(true)
  d.live, d.open, d.phase = false, false, "ground"
  job(widget); widget:refresh(0, nil)
  check(d.live and (d.bankWritten or 0) ~= 0 and d.phase == "live", "open is effective on this foreground pass")
end)
-- A button's press runs from the firmware's event dispatch, between two refresh calls and never
-- inside one, so it is driven here between two passes.
scenario("quick-menu opening takes effect on the first refresh after its press", function()
  local widget, d = fixture(true)
  d.live, d.open, d.phase, widget.inflightFullscreen = false, false, "ground", nil
  local Menu = rfsuite.require("widgets/dashboard/fullscreen_menu.lua")
  local entry = Menu.entry(widget, "inflight_tuning")
  check(entry and type(entry.press) == "function", "positive control: the quick menu exposes tuning")
  Menu.run(widget, entry)
  check(widget.inflightFullscreen ~= true, "armed, the menu's button refuses the press")
  widget.state.armed = false
  Menu.run(widget, entry)
  check(widget.inflightFullscreen == true, "positive control: disarmed, the button raises the flag")
  widget.state.armed = true
  job(widget)
  local released
  widget._job.step = function() released = d.live and (d.bankWritten or 0) ~= 0; return true end
  widget:refresh(0, nil)
  check(released == true, "the first refresh after the press releases, ahead of its job")
end)
-- A key bound to tuning is the opening that does arrive inside refresh: it raises the flag after
-- that pass's first release check, and is refused while armed.
scenario("bound-key opening takes effect on its own pass", function()
  -- All modules stay loaded only while a second open dashboard holds them; closed and alone, the
  -- view would leave on this pass's first release check and the opening would wait to load instead.
  local other = fixture(false)
  for _ = 1, 10 do other:refresh(0, nil) end
  local widget, d = fixture(false)
  d.live, d.open, widget.inflightFullscreen = false, false, nil
  widget.preferences.dashboard = {key_tele = "inflight_tuning"}
  local realTele = _G.EVT_TELEM_BREAK
  _G.EVT_TELEM_BREAK = 9001
  job(widget); widget:refresh(EVT_TELEM_BREAK, nil)
  _G.EVT_TELEM_BREAK = realTele
  check(widget.inflightFullscreen == true, "positive control: the bound key opened tuning")
  check(d.open == true and d.live == true and d.phase == "ground", "the key's own pass releases the surface")
  check(other.inflightFullscreen == true, "positive control: the second dashboard stayed open")
end)
scenario("setup fault and pending trims refuse output", function()
  local widget, d, writes = fixture(false)
  energize(d, writes)
  d.phase, d._checkResult = "ground", {"same_gvar"}
  local before = #writes
  d:evaluateInterlock(getTime(), true)
  cleared(d, writes, before)
  d.settings.trims, d.trimsResolved = true, false
  local scans = 0
  d.radio.switchList = function() scans = scans + 1; return {}, 1 end
  before = #writes
  d:evaluateInterlock(getTime(), true)
  check(not d.live and #writes == before and scans == 1, "a pending trim walk cannot release output")
  d:evaluateInterlock(getTime(), false)
  d:evaluateInterlock(getTime(), false)
  check(scans == 1, "closed tuning performs no trim discovery")
end)
scenario("a surface closed on a setup fault turns tuning off for the model, once and on the ground", function()
  local root, savedInfo = rfsuite, model.getInfo
  local savedSave = root.savePreferences
  local Preferences = rfsuite.require("lib/preferences.lua")
  local realSave = Preferences.save
  local saves, savedTable, toolSaves = 0, nil, 0
  model.getInfo = function() return {name = "Heli", filename = "model3.yml"} end
  Preferences.save = function(t) saves = saves + 1; savedTable = t; return realSave(t) end
  -- A tool's writer left on the global: it must not be the one that stores the dashboard's table.
  root.savePreferences = function() toolSaves = toolSaves + 1; return true end
  local ok, err = pcall(function()
    -- Closed through the real route: the close request, then the runtime's own pass, which ticks no
    -- closed surface and cleans it up instead.
    local function closeAndPass(widget)
      Input.dispatch(widget, "close", nil, "touch")
      local counted = 0
      debug.sethook(function() counted = counted + 1 end, "", 1)
      Stubs.tick(); widget:refresh(0, nil)
      debug.sethook()
      return counted
    end
    local widget, d = fixture(true)
    widget.preferences.inflight["on_model3.yml"] = "Heli"
    d.live, d._checkResult, d._checkFault = false, {"same_gvar"}, true
    closeAndPass(widget)
    check(widget.preferences.inflight["on_model3.yml"] == "Heli" and saves == 0, "not while armed")
    widget, d = fixture(false)
    widget.preferences.inflight["on_model3.yml"] = "Heli"
    d.live, d._checkResult, d._checkFault = false, {"same_gvar"}, true
    local cost = closeAndPass(widget)
    check(widget.preferences.inflight["on_model3.yml"] == nil and saves == 1, "closed on a fault, the model's key goes")
    check(savedTable == widget.preferences and toolSaves == 0, "stored from the table it was removed from")
    check(widget.preferences.inflight.enabled == false, "and the entry with it")
    print(string.format("  closing pass with the fault save: %d instructions", cost))
    check(cost < 20000, "the closing pass stays inside a widget call")
    Stubs.tick(); widget:refresh(0, nil)
    check(saves == 1, "once")
    widget, d = fixture(false)
    widget.preferences.inflight["on_model3.yml"] = "Heli"
    d.live, d._checkResult, d._checkFault = false, "ok", false
    closeAndPass(widget)
    check(widget.preferences.inflight["on_model3.yml"] == "Heli" and saves == 1, "closed without a fault, it stays on")
  end)
  debug.sethook()
  model.getInfo, root.savePreferences, Preferences.save = savedInfo, savedSave, realSave
  assert(ok, err)
end)
scenario("closed tuning performs no ground MSP work", function()
  local widget, d = fixture(false)
  widget.inflightFullscreen, d.live, d.open = nil, false, false
  local Prime = rfsuite.require("widgets/dashboard/inflight/prime.lua")
  local saved, calls = Prime.tick, 0
  Prime.tick = function() calls = calls + 1 end
  for _ = 1, 4 do Stubs.tick(); widget:refresh(0, nil) end
  Prime.tick = saved
  check(calls == 0, "quick menu and zone do not advance a ground job")
end)

for _, close in ipairs({"release", "touch", "RTN"}) do
  scenario(close .. " close and reopen repeats a refused ground setup check", function()
    local widget, d = fixture(false)
    d.live, d._checkResult, d._checkFault = false, {"same_gvar"}, true
    if close == "release" then d:evaluateInterlock(getTime(), false)
    else Input.dispatch(widget, close == "touch" and "close" or "back", nil, close == "touch" and "touch" or "key") end
    check(d._checkedAt == nil, "closing a refused surface invalidates its verdict")
    d:evaluateInterlock(getTime(), true)
    check(d.live and not d._checkFault, "repaired setup is checked again and released on reopening")
  end)
end

scenario("opening and closing take effect without a seed or delay", function()
  local widget, d, writes = fixture(false)
  d.live, d.phase, d.open = false, nil, false
  d:evaluateInterlock(getTime(), true)
  check(d.live, "first open input is immediately live")
  energize(d, writes)
  local before = #writes
  d:evaluateInterlock(getTime(), false)
  cleared(d, writes, before)
end)
for _, exit in ipairs({"firmware", "background", "radio_disabled", "preview_disabled"}) do
  scenario(exit .. " cancels a queued tuning build", function()
    local widget, d = fixture(true)
    local builds = 0
    widget.renderKey, widget._cachedTuningKey = "tuning|control", "tuning|control"
    widget._job = {kind = "tuning_fs", oneShot = true, step = function() builds = builds + 1; return true end}
    if exit == "firmware" then widget:refresh(nil, nil)
    elseif exit == "background" then widget:background()
    else
      if exit == "radio_disabled" then widget.preferences.inflight.enabled = false
      else widget.preferences.general.preview_inflight_tuning = false end
      widget:refresh(0, nil)
    end
    check(builds == 0, "a closed tuning build never executes")
    check(widget._job == nil or widget._job.kind ~= "tuning_fs", "a closed surface retains no tuning build")
    check(widget.renderKey ~= "tuning|control" and widget._cachedTuningKey == nil, "closure invalidates the tuning scene")
  end)
  scenario(exit .. " clears before a pending job and stays closed", function()
    local widget, d, writes = fixture(true)
    energize(d, writes)
    -- A value-mode scene leaves its encoder window and sensor on the widget.
    local Screen = rfsuite.require("widgets/dashboard/inflight/screen.lua")
    widget.i18n = {t = function(_, fallback) return fallback end}
    d.valueMode = true
    Drive.sample(widget)
    Screen.buildFullscreen({}, widget)
    local views = setmetatable({widget._inflightReverseNode, widget._inflightSensor}, {__mode = "v"})
    check(views[1] ~= nil and views[2] ~= nil, "positive control: the value scene holds its encoder view")
    local before, baseline, fired = #writes, d.baseline, d.fired
    job(widget)
    if exit == "firmware" then widget:refresh(nil, nil)
    elseif exit == "background" then widget:background()
    else
      if exit == "radio_disabled" then widget.preferences.inflight.enabled = false
      else widget.preferences.general.preview_inflight_tuning = false end
      widget:refresh(0, nil)
    end
    cleared(d, writes, before)
    check(not widget.inflightFullscreen, "exit consumes the visit; recovery needs a quick-menu open")
    check(d.baseline == baseline and d.fired == fired, "pause retains session and comparison")
    collectgarbage("collect"); collectgarbage("collect")
    check(widget._inflightReverseNode == nil and widget._inflightSensor == nil and views[1] == nil and views[2] == nil,
      "the closed encoder view is released with the visit")
    widget.preferences.inflight.enabled = true
    widget.preferences.general.preview_inflight_tuning = true
    widget.state.fblConnected = true
    for _ = 1, 3 do job(widget); widget:refresh(0, nil) end
    for i = before + 1, #writes do check(writes[i][3] == 0, "foreground/link/feature recovery cannot resume output") end
    check(not d:dispatch("step", 1, "touch"), "stale callback cannot step after exit")
  end)
end
scenario("link loss clears output and automatically resumes the same flight", function()
  local widget, d, writes = fixture(true)
  d.group, d.entry = 2, 3
  local cell = d.groups[2].entries[3]
  d.bank, d.row = cell.bank, cell.row
  energize(d, writes)
  local before, baseline, fired = #writes, d.baseline, d.fired
  widget.state.fblConnected = false
  job(widget); widget:refresh(0, nil)
  cleared(d, writes, before)
  check(widget.inflightFullscreen == true, "link loss preserves the fullscreen visit")
  check(d.phase == "live" and d.group == 2 and d.entry == 3, "link pause retains flight phase and selection")
  local pausedWrites = #writes
  for _ = 1, 20 do
    Stubs.tick(); job(widget); widget:refresh(0, nil)
    check(not d.live and #writes == pausedWrites, "no model write while the link remains down")
  end
  check(not d:dispatch("step", 1, "touch"), "stale step callback cannot write while disconnected")
  check(#writes == pausedWrites, "the disconnected callback leaves both variables zero")
  widget.state.fblConnected = true
  d.radio.channelUs = function() return 998 end
  job(widget); widget:refresh(0, nil)
  check(widget.inflightFullscreen and d.live and d.phase == "live", "link return automatically releases the existing visit")
  check(d.group == 2 and d.entry == 3 and d.bank == cell.bank and d.row == cell.row,
    "automatic resume preserves the same parameter despite a stale channel echo")
  check(d.baseline == baseline and d.fired == fired, "automatic resume retains the session and step count")
  for i = pausedWrites + 1, #writes do
    if writes[i][1] == d.settings.value_gvar - 1 then check(writes[i][3] == 0, "resume never replays the interrupted pulse") end
  end
  check(d.bankWritten == d.bankValues[cell.bank] and d.bankFm == 2, "automatic resume drives the retained bank in its owning flight mode")
  check(d:dispatch("step", 1, "touch") and d.fired == fired + 1, "positive control: a fresh step is accepted after automatic resume")
end)
scenario("link-lost tuning takes precedence over startup and theme reload", function()
  local widget, d = fixture(true)
  local Screen = rfsuite.require("widgets/dashboard/inflight/screen.lua")
  widget.state.fblConnected = false
  widget.theme, widget.connectionReady, widget._viewStack = nil, false, nil
  widget._themeReloadPending, widget.flightMode = true, "preflight"
  widget._lastWorkTick = getTime() / 100
  widget:refresh(0, nil)
  check(widget._job and widget._job.kind == "tuning_fs", "the disconnected visit queues tuning instead of a connection splash")
  widget:refresh(0, nil)
  check(widget._treeKind == "tuning_fs" and d.linkLost and widget.inflightFullscreen,
    "the paused fullscreen is drawn without a loaded theme")
end)
scenario("connection-state drop pauses in the same logic pass", function()
  local widget, d, writes = fixture(true)
  energize(d, writes)
  local Msp = rfsuite.require("tasks/msp/runtime.lua")
  local saved, calls = Msp.isFblConnected, 0
  Msp.isFblConnected = function() calls = calls + 1; return false end
  widget.lastFblConnected, widget._lastLogicTick, widget._lastWorkTick = true, -10000, nil
  widget._lastTelemetryReadAt = getTime() / 100
  local before = #writes
  local ok, err = pcall(function() widget:refresh(0, nil) end)
  Msp.isFblConnected = saved
  check(ok, tostring(err))
  check(calls > 0 and not widget.state.fblConnected and not widget.lastFblConnected,
    "positive control: the real logic pass observed the disconnect edge")
  cleared(d, writes, before)
  check(widget.inflightFullscreen and widget.state.inflight and widget.state.inflight.linkLost,
    "connection-state cleanup retains and publishes the disconnected visit")
end)
scenario("reconnect arm-latch reset cannot start a new flight", function()
  local widget, d, writes = fixture(true)
  d.group, d.entry = 2, 3
  local cell = d.groups[2].entries[3]
  d.bank, d.row = cell.bank, cell.row
  energize(d, writes)
  widget.state.fblConnected = false
  job(widget); widget:refresh(0, nil)
  local before = #writes
  widget.state.fblConnected, widget.state.armed, widget.state.armedSeen = true, false, false
  job(widget); widget:refresh(0, nil)
  check(not d.live and d.phase == "live" and d.group == 2 and d.entry == 3 and #writes == before,
    "unknown arm state on reconnect cannot reset the selection or release output")
  widget.state.armed, widget.state.armedSeen = true, true
  job(widget); widget:refresh(0, nil)
  check(d.live and d.group == 2 and d.entry == 3, "fresh armed telemetry automatically resumes the same flight")
end)
scenario("a link back in the air resumes on a current armed reading without an identified board", function()
  local widget, d, writes = fixture(true)
  d.group, d.entry = 2, 3
  local cell = d.groups[2].entries[3]
  d.bank, d.row = cell.bank, cell.row
  energize(d, writes)
  d.board = "12.10:board"
  local fired = d.fired
  local Msp = rfsuite.require("tasks/msp/runtime.lua")
  local values = Msp.getState().values
  local savedReading, savedMcu = Msp.armedReading, values.mcuId
  local reading = {}
  Msp.armedReading = function() return reading[1], reading[2] end
  local ok, err = pcall(function()
    -- The loss: the version read and the MCU id go with it and stay gone while armed.
    widget.state.fblConnected, widget.state.rfConnected = false, false
    values.mcuId = nil
    job(widget); widget:refresh(0, nil)
    check(d.linkLost and not d.live, "positive control: the loss pauses the surface")
    local paused = #writes
    widget.state.rfConnected = true
    for _, case in ipairs({{true, false, "a reading from before the loss"}, {false, true, "a current disarmed reading"},
        {nil, false, "no reading at all"}}) do
      reading[1], reading[2] = case[1], case[2]
      Stubs.tick(); job(widget); widget:refresh(0, nil)
      check(not d.live and d.linkLost and #writes == paused, case[3] .. " does not resume")
    end
    -- The board still reports the adjustment it held when the link went, and may send no fresh 0
    -- for a while: that must not hold the continued flight's steps back.
    local sensor, held = d.radio.sensor, cell.id
    local heldValue = d.values[held] or 100
    -- Across the gap the profile sensors read 0, which makes both profiles unknown for a while.
    local gap = true
    d.radio.sensor = function(name)
      if name == "AdjF" then return held elseif name == "AdjV" then return heldValue end
      if gap and (name == "PID#" or name == "RTE#") then return 0 end
      return sensor(name)
    end
    d:watchProfiles()
    check(d.profile == nil and d.rateProfile == nil, "positive control: the gap makes both profiles unknown")
    gap = false
    reading[1], reading[2] = true, true
    Stubs.tick(); job(widget); widget:refresh(0, nil)
    check(d.live and not d.linkLost and d.phase == "live" and d.group == 2 and d.entry == 3,
      "a current armed reading resumes the same flight and selection")
    check(d:profileRefusal() == nil, "the unidentified board does not refuse the continued flight: "
      .. tostring(d:profileRefusal()))
    check(not d.reportFence, "a link gap alone sets no report fence, also when the profiles read unknown in it")
    Stubs.tick(); d:fastTick(getTime())
    local stepped, why = d:dispatch("step", 1, "touch")
    check(stepped and d.fired == fired + 1, "a fresh step is accepted on the continued flight: " .. tostring(why))
    -- Without the continuation the same unidentified board is refused: the control for the check above.
    d.armedThrough = nil
    check(d:profileRefusal() == "board_unknown", "positive control: without the continuation the board is unknown")
    d.armedThrough = true
    -- A second loss in the same flight: the reading turns old and the surface pauses again.
    reading[2] = false
    Stubs.tick(); job(widget); widget:refresh(0, nil)
    check(not d.live and d.linkLost, "a second loss pauses again")
    -- A profile that comes back as ANOTHER known profile after an unknown stretch is an edge.
    gap = true; d:watchProfiles()
    gap = false
    local plain = d.radio.sensor
    d.radio.sensor = function(name) if name == "PID#" then return 2 end return plain(name) end
    d:watchProfiles()
    check(d.reportFence == true, "known profile 1, unknown, then known profile 2 is still fenced")
  end)
  Msp.armedReading, values.mcuId = savedReading, savedMcu
  check(ok, tostring(err))
end)
for _, armed in ipairs({true, false}) do
  scenario("link-lost surface replaces the " .. (armed and "live" or "ground") .. " scene", function()
    local widget, d = fixture(armed)
    local Screen = rfsuite.require("widgets/dashboard/inflight/screen.lua")
    local key = Screen.renderKey({phase = d.phase, live = true})
    local builds, nodes = 0, {}
    widget.i18n = {t = function(_, fallback) return fallback end}
    widget._job = {kind = "tuning_fs", oneShot = true, step = function()
      builds = builds + 1
      Screen.buildFullscreen(nodes, widget)
      return true
    end}
    widget.state.fblConnected = false
    widget:refresh(0, nil)
    check(widget.inflightFullscreen and builds == 1, "the queued tuning build draws the paused visit")
    local text, controls = false, 0
    local function walk(tree)
      for _, node in ipairs(tree) do
        local value = type(node.text) == "function" and node.text() or node.text
        if value == "No FC link" then text = true end
        if node.scrolled or node.type == "momentaryButton" then controls = controls + 1 end
        if node.children then walk(node.children) end
      end
    end
    walk(nodes)
    check(text and controls == 0, "paused surface shows the existing no-link text without tuning controls")
    check(Screen.renderKey(widget.state.inflight or {}) ~= key, "link loss changes the retained scene key in every phase")
  end)
end
for _, exit in ipairs({"firmware", "background", "radio_disabled", "preview_disabled", "touch", "RTN"}) do
  scenario(exit .. " still closes a disconnected tuning visit", function()
    local widget, d, writes = fixture(exit ~= "touch" and exit ~= "RTN")
    energize(d, writes)
    widget.state.fblConnected = false
    job(widget); widget:refresh(0, nil)
    check(widget.inflightFullscreen == true and not d.live, "positive control: link loss pauses the visit")
    local before = #writes
    if exit == "firmware" then widget:refresh(nil, nil)
    elseif exit == "background" then widget:background()
    elseif exit == "touch" or exit == "RTN" then
      check(Input.dispatch(widget, exit == "touch" and "close" or "back", nil, exit == "touch" and "touch" or "key"), "ground close accepted while disconnected")
    else
      if exit == "radio_disabled" then widget.preferences.inflight.enabled = false
      else widget.preferences.general.preview_inflight_tuning = false end
      job(widget); widget:refresh(0, nil)
    end
    check(not widget.inflightFullscreen and not d.live, "an explicit exit still ends the visit during link loss")
    widget.preferences.inflight.enabled = true
    widget.preferences.general.preview_inflight_tuning = true
    widget.state.fblConnected = true
    for _ = 1, 3 do job(widget); widget:refresh(0, nil) end
    check(not d.live and #writes == before, "link recovery cannot reopen an explicitly closed visit")
  end)
end
for _, exit in ipairs({"touch", "RTN"}) do
  scenario(exit .. " ground close retains the post-flight comparison", function()
    local widget, d, writes = fixture(false)
    energize(d, writes)
    d:setPhase("post")
    d:writeValue(50, 2)
    local before, baseline, fired = #writes, d.baseline, d.fired
    check(Input.dispatch(widget, exit == "touch" and "close" or "back", nil, exit == "touch" and "touch" or "key"), "ground close accepted")
    cleared(d, writes, before)
    check(d.post and d.phase == "post" and d.baseline == baseline and d.fired == fired, "post comparison survives close")
    job(widget); widget:refresh(0, nil)
    for i = before + 1, #writes do check(writes[i][3] == 0, "quick menu keeps both outputs at zero") end
  end)
end
scenario("air pause resumes the same group and entry", function()
  local widget, d, writes = fixture(true)
  d.group, d.entry = 2, 3
  local cell = d.groups[2].entries[3]
  d.bank, d.row = cell.bank, cell.row
  energize(d, writes)
  local baseline, fired = d.baseline, d.fired
  d.radio.channelUs = function() return 998 end
  Drive.cleanup(widget)
  widget.inflightFullscreen, d.open = true, true
  d:tick(true)
  check(d.live and d.phase == "live" and d.group == 2 and d.entry == 3
    and d.bank == cell.bank and d.row == cell.row, "reopen continues the same parameter despite a stale channel echo")
  check(d.baseline == baseline and d.fired == fired, "reopen retains the flight")
  d:tick(false)
  check(d.phase == "post", "landing after pause retains comparison")
  d:tick(true)
  check(d.group == 1 and d.entry == 1 and d.fired == 0, "next flight starts at group one, entry one")
end)
scenario("closed zone never builds a tuning surface", function()
  local widget, d = fixture(false)
  widget.inflightFullscreen = nil
  job(widget); widget:refresh(nil, nil)
  check(not d.live, "zone revokes release even if a stale live snapshot exists")
  local Screen = rfsuite.require("widgets/dashboard/inflight/screen.lua")
  check(Screen.buildZone == nil, "zone tuning builder is removed")
end)
scenario("stored switch is ignored and cannot cause a setup fault", function()
  local a = Drive.settings({inflight = {enabled = true, switch = 999}}, {})
  local b = Drive.settings({inflight = {enabled = true}}, {})
  check(a.switch == nil and b.switch == nil and Drive.DEFAULTS.switch == nil, "switch is absent from runtime settings and defaults")
  local target = {switch = 999}
  Drive.storeRadioSettings(target, Drive.loadRadioSettings({inflight = {enabled = true}}))
  check(target.switch == 999, "saving leaves the ignored stored switch untouched")
end)
scenario("ground announcements follow the global preference and save only on press", function()
  local widget, d = fixture(false)
  local Screen = rfsuite.require("widgets/dashboard/inflight/screen.lua")
  local savedPrefs, savedSave = rfsuite.preferences, rfsuite.savePreferences
  local modelPrefs = rfsuite.session.modelPreferences
  rfsuite.session.modelPreferences = {audio_events = {adjustment_events = true}}
  rfsuite.preferences = {audio_events = {adjustment_events = false}}
  local saves = 0
  rfsuite.savePreferences = function()
    saves = saves + 1
    check(rfsuite.preferences.audio_events.adjustment_events == true, "explicit save receives the enabled global preference")
    return true
  end
  local function scene()
    Drive.sample(widget)
    local nodes = {}; Screen.buildFullscreen(nodes, widget)
    local hint, enable, button
    for _, node in ipairs(nodes) do
      if node.type == "button" then button = node end
      local text = type(node.text) == "function" and node.text() or node.text
      if text == "Adjustment announcements are off" then hint = node end
      if text == "Turn on announcements" then enable = button end
    end
    return hint, enable
  end
  local hint, enable = scene()
  check(hint and enable and saves == 0 and not rfsuite.preferences.audio_events.adjustment_events,
    "opening shows the off hint and button without changing preferences, regardless of a model override")
  enable.press()
  hint, enable = scene()
  check(saves == 1 and rfsuite.preferences.audio_events.adjustment_events and not hint and not enable,
    "successful explicit save hides the hint and button")
  rfsuite.preferences, rfsuite.savePreferences = savedPrefs, savedSave
  rfsuite.session.modelPreferences = modelPrefs
end)
scenario("failed announcement save stays visible and can be retried", function()
  local widget, d = fixture(false)
  local Screen = rfsuite.require("widgets/dashboard/inflight/screen.lua")
  local savedPrefs, savedSave = rfsuite.preferences, rfsuite.savePreferences
  rfsuite.preferences = {audio_events = {adjustment_events = false}}
  rfsuite.savePreferences = function() return false, "unavailable" end
  local nodes = {}; Drive.sample(widget); Screen.buildFullscreen(nodes, widget)
  local button
  for _, node in ipairs(nodes) do
    if node.type == "button" then button = node end
    if node.text == "Turn on announcements" then button.press(); break end
  end
  nodes = {}; Screen.buildFullscreen(nodes, widget)
  local warning, hint, retry
  for _, node in ipairs(nodes) do
    local text = type(node.text) == "function" and node.text() or node.text
    if text == "Announcements were not saved" then warning = node end
    if text == "Adjustment announcements are off" then hint = node end
    if text == "Turn on announcements" then retry = node end
  end
  -- The failure takes the footer's place of the off hint: the switch is still off, and saying so twice
  -- costs a row the small screens do not have.
  check(warning and not hint and retry and not rfsuite.preferences.audio_events.adjustment_events,
    "failed save reports the warning in place of the hint and rolls back the global switch")
  rfsuite.preferences, rfsuite.savePreferences = savedPrefs, savedSave
end)
scenario("standalone widget saves announcements through the preferences module", function()
  local widget = fixture(false)
  local Screen = rfsuite.require("widgets/dashboard/inflight/screen.lua")
  local Preferences = rfsuite.require("lib/preferences.lua")
  local savedPrefs, savedSave, savedModuleSave = rfsuite.preferences, rfsuite.savePreferences, Preferences.save
  rfsuite.preferences, rfsuite.savePreferences = {audio_events = {adjustment_events = false}}, nil
  local written
  Preferences.save = function(prefs) written = prefs; return true end
  local nodes = {}; Drive.sample(widget); Screen.buildFullscreen(nodes, widget)
  local button
  for _, node in ipairs(nodes) do
    if node.type == "button" then button = node end
    if node.text == "Turn on announcements" then button.press(); break end
  end
  check(written == rfsuite.preferences and written.audio_events.adjustment_events == true,
    "widget without a tool save callback reuses Preferences.save")
  Preferences.save = savedModuleSave
  rfsuite.preferences, rfsuite.savePreferences = savedPrefs, savedSave
end)
scenario("announcement controls are absent from armed and air surfaces", function()
  local widget, d = fixture(true)
  local Screen = rfsuite.require("widgets/dashboard/inflight/screen.lua")
  local savedPrefs = rfsuite.preferences
  rfsuite.preferences = {audio_events = {adjustment_events = false}}
  for _, phase in ipairs({"ground", "live"}) do
    d.phase = phase; Drive.sample(widget)
    local nodes = {}; Screen.buildFullscreen(nodes, widget)
    for _, node in ipairs(nodes) do
      local text = type(node.text) == "function" and node.text() or node.text
      check(text ~= "Turn on announcements" and text ~= "Adjustment announcements are off",
        "armed surfaces carry no announcement switch or hint")
    end
  end
  rfsuite.preferences = savedPrefs
end)

-- Ground children are measured with the fonts' rendered boxes: the standard font's line is about
-- 20 px and runs at most 9 px a character (12 at 800x480, where it is drawn larger: "31
-- parameters on the board" measured 10.3 a character there against 7.7 at 480x320), the small
-- font 14 and 11, the middle one 30 and 16. A text wider than its box wraps on the radio onto
-- whatever is under it, so the width is checked as well as the position, and a text that is no
-- button's own caption may not touch a button.
local FONT_BOX = {[0] = {20, 9}, [SMLSIZE] = {14, 11}, [MIDSIZE] = {30, 16}}
local function charW(font, screenH)
  if (font == 0 or FONT_BOX[font] == nil) and screenH > 350 then return 12 end
  return (FONT_BOX[font] or FONT_BOX[0])[2]
end
for _, locale in ipairs({"en", "de"}) do
  local translations = assert(loadfile("src/rfsuite/i18n/" .. locale .. ".lua"))().widgets.dashboard
  for _, size in ipairs({{480, 272}, {480, 320}, {800, 480}}) do
    for _, variant in ipairs({"ready", "warnings", "empty", "reading", "failed", "crowded", "expired"}) do
      scenario("ground panel and grid " .. locale .. " " .. size[1] .. "x" .. size[2] .. " " .. variant, function()
        local widget, d = fixture(false)
        -- "expired": the crowded panel with a session end pending on top (a link gap on the ground).
        local crowded = variant == "crowded" or variant == "expired"
        d.sessionExpired = variant == "expired" or nil
        local Screen = rfsuite.require("widgets/dashboard/inflight/screen.lua")
        local savedPrefs = rfsuite.preferences
        local announcementsOn = variant == "ready" or variant == "reading"
        rfsuite.preferences = {audio_events = {adjustment_events = announcementsOn}}
        widget.zone = {w = size[1], h = size[2]}
        widget.i18n = {t = function(key, fallback)
          return translations[string.gsub(key, "^widgets%.dashboard%.", "")] or fallback
        end}
        widget.state.inflight = {phase = "ground", setupVerdict = "ok", setSource = variant == "empty" and "unavailable" or "board",
          cellCount = variant == "empty" and 0 or 36, boundsCount = (variant == "warnings" or crowded) and 2 or 0,
          prime = {phase = "done", skipped = variant == "empty" and 0 or 3},
          baseline = {timestamp = "2026-10-25 12:34:56"}}
        if variant == "warnings" or variant == "empty" or crowded then d.saveResult, d.announcementsSaveFailed = "unavailable", true end
        if variant == "failed" or crowded then
          -- The longest texts the panel shows: a three-part verdict and a refused restore; "crowded" adds
          -- every warning row and the announcements button on top.
          widget.state.inflight.setupVerdict = {"mix_missing", "gvar_range", "same_gvar"}
          widget.state.inflight.transfer = {kind = "restore", state = "refused", reason = "baseline_identity"}
          widget.state.inflight.restoreSummary = "PID 1, PID 2, RTE 1"
        end
        if variant == "reading" then
          d.profileJob = {plan = {{op = "initial"}, {op = "read", kind = "pid", index = 2}, {op = "read", kind = "rate", index = 2}},
            at = 2, original = {pid = 2, rate = 2}}
        end
        local nodes = {}; Screen.buildFullscreen(nodes, widget)
        rfsuite.preferences = savedPrefs
        local function shown(node)
          if type(node.visible) == "function" then return node.visible() end
          return node.visible ~= false
        end
        local function height(node)
          return node.h or (node.type == "label" and (FONT_BOX[node.font] or FONT_BOX[0])[1]) or 0
        end
        local function inside(node, box)
          return node.x >= box.x and node.y >= box.y and node.x + node.w <= box.x + box.w and node.y + height(node) <= box.y + box.h
        end
        local function touches(a, b)
          return not (a.x >= b.x + b.w or a.x + a.w <= b.x or a.y >= b.y + height(b) or a.y + height(a) <= b.y)
        end
        local allButtons = {}
        for _, node in ipairs(nodes) do if node.type == "button" and shown(node) then allButtons[#allButtons + 1] = node end end
        local labels, buttons, captions, captionFonts, panel, footer, footerText, modelLabel, modelValue = {}, {}, {}, {}
        for index, node in ipairs(nodes) do
          local x, y, width, tall = node.x or 0, node.y or 0, node.w or 0, height(node)
          check(x >= 0 and y >= 0 and x + width <= size[1] and y + tall <= size[2], "every ground child fits the screen")
          if node.type == "button" then buttons[#buttons + 1] = node; captions[#captions + 1] = "" end
          local text = type(node.text) == "function" and node.text() or node.text
          if node.type == "label" and text and text ~= "" and shown(node) then
            check(#text * charW(node.font, size[2]) <= width, "ground text fits its box: " .. text)
            for _, other in ipairs(labels) do
              check(not touches(node, other), "ground text children never overlap: " .. text)
            end
            labels[#labels + 1] = node
            local button = buttons[#buttons]
            local caption = button and inside(node, button)
            if caption then
              captions[#captions] = captions[#captions] == "" and text or captions[#captions] .. " " .. text
              captionFonts[#captions] = node.font
            else
              for _, other in ipairs(allButtons) do
                check(not touches(node, other), "ground text stays off the buttons: " .. text)
              end
            end
            if footer and inside(node, footer) then footerText = text end
            if text == translations.inflight_model_status then modelLabel, modelValue = node, nodes[index + 1] end
          elseif node.type == "label" and text and text ~= "" then
            local button = buttons[#buttons]
            if button and inside(node, button) then
              captions[#captions] = captions[#captions] == "" and text or captions[#captions] .. " " .. text
            end
          elseif node.type == "rectangle" and node.filled and node.h > 12 then
            if node.x > 0 then panel = node elseif y > size[2] / 2 then footer = node end
          end
        end
        check(panel and footer and panel.color == footer.color and modelLabel and modelValue
          and modelLabel.y >= panel.y and modelValue.x > modelLabel.x,
          "status values share a filled panel and the footer uses the same palette")
        local warning = d.announcementsSaveFailed and translations.inflight_announcements_failed or translations.inflight_announcements_off
        check(footerText == (announcementsOn and translations.inflight_ground_controls or warning),
          "ground footer shows the controls, the announcements warning, or a failed attempt to turn them on")
        local color = modelValue.color()
        widget.state.inflight.setupVerdict = {"mix_missing"}
        check(variant == "failed" or crowded or (color ~= modelLabel.color and modelValue.color() ~= color), "model verdict colour follows its meaning")
        local expected = {}
        if variant == "reading" then
          expected[1], expected[2] = translations.inflight_read_again, translations.inflight_restore_cancel
        else
          expected[1] = variant == "empty" and translations.inflight_fc_setup_action or translations.inflight_choose_parameters
        end
        if variant ~= "empty" then expected[#expected + 1] = translations.inflight_fc_setup_action end
        expected[#expected + 1] = translations.inflight_read_again
        if not announcementsOn then expected[#expected + 1] = translations.inflight_announcements_enable end
        expected[#expected + 1], expected[#expected + 2] = translations.inflight_restore_all, "X"
        check(#captions == #expected, "ground retains every action in encoder order")
        for index, label in ipairs(expected) do check(captions[index] == label, "ground action text is complete: " .. label) end
        check(not touches({x = 0, y = 0, w = 0, h = 0}, {x = 0, y = 0, w = 0, h = 0}), "positive control: touches is not always true")
        check(touches({x = 0, y = 0, w = 10, h = 10}, {x = 5, y = 5, w = 10, h = 10}), "positive control: overlapping boxes touch")
        -- Every action keeps at least a line of text and its margin, however much the panel holds.
        for _, button in ipairs(buttons) do
          check(button.h >= 22, "every ground action is at least a text line tall: " .. button.h)
        end
        local primaries = variant == "reading" and 2 or 1
        local primary = buttons[primaries]
        local restore = buttons[#buttons - 1]
        local first = buttons[primaries + 1]
        -- 480x272 with every warning row up has no height to spare: there the primary may equal the
        -- others, but never drops below a line of text and its margin.
        local minimum = size[2] > 350 and 48 or size[2] >= 320 and 36 or 22
        check(primary.active() and primary.h >= minimum and primary.h >= first.h and (size[2] < 300 or primary.h > first.h),
          "ground primary is active and at least as tall as the other actions, taller where there is room")
        if variant ~= "reading" then
          check(primary.color == lcd.RGB(41, 163, 224), "ground primary is accented")
        else
          check(not buttons[1].active() and not first.active() and not restore.active(),
            "while a read runs, retry waits for a held return and the other actions are shown disabled")
        end
        for index = primaries + 1, #buttons - 2 do
          local button = buttons[index]
          check(button.h == first.h and (button.w == restore.w or button.w * 2 < restore.w) and button.y + button.h < restore.y,
            "secondary cells share one height, are full or half width and end above Restore all")
        end
        check(primary.w == size[1] - primary.x * 2 and primary.w == restore.w
          and restore.h == first.h and restore.y + restore.h < footer.y and restore.color ~= first.color,
          "primary and restore are full width with restore above the footer")
        if variant == "expired" then
          local said = false
          for _, label in ipairs(labels) do
            local text = type(label.text) == "function" and label.text() or label.text
            if text == translations.inflight_session_expired then said = true end
          end
          check(said, "a pending session end is said on the ground surface")
          check(not restore.active(), "Restore all is shown disabled while the session end is pending")
          local readAgain
          for index, caption in ipairs(captions) do
            if caption == translations.inflight_read_again then readAgain = buttons[index] end
          end
          check(readAgain ~= nil and readAgain.active(), "Read again stays usable: it begins the new session")
          restore.press()
          check(d.restoreConfirm == nil, "a press on the disabled Restore all opens nothing")
        elseif variant ~= "reading" then
          check(restore.active(), "positive control: Restore all is usable with no session end pending")
        end
        local lastSecondary = buttons[#buttons - 2]
        check(restore.y - lastSecondary.y - lastSecondary.h <= (size[2] > 350 and 10 or 6),
          "ground grid uses the available space above Restore all")
        if size[2] > 350 then
          check(modelLabel.font == 0 and modelValue.font == 0 and (variant == "reading" or captionFonts[1] == MIDSIZE),
            "large ground screen uses standard status text and a larger primary caption")
          for index = primaries + 1, #buttons - 1 do
            check(captionFonts[index] == 0, "large ground secondary captions use the standard font")
          end
        end
        d.profileJob = nil
      end)
    end
  end
end

-- The button whose caption is `caption`: captions are the labels appended right after their button.
local function buttonFor(nodes, caption)
  local button
  for _, node in ipairs(nodes) do
    if node.type == "button" then button = node end
    local text = type(node.text) == "function" and node.text() or node.text
    if node.type == "label" and text == caption and button then return button end
  end
end

scenario("post-flight surface: a pending session end is said and the restores are disabled", function()
  for _, expired in ipairs({false, true}) do
    local widget, d = fixture(false)
    local Screen = rfsuite.require("widgets/dashboard/inflight/screen.lua")
    widget.zone = {w = 480, h = 320}
    d.phase, d.sessionExpired = "post", expired or nil
    widget.state.inflight = {phase = "post", setupVerdict = "ok", setSource = "board", cellCount = 36}
    local nodes = {}; Screen.buildFullscreen(nodes, widget)
    local said = false
    for _, node in ipairs(nodes) do
      local text = type(node.text) == "function" and node.text() or node.text
      if text == "Battery changed: new session at next read" then said = true end
    end
    check(said == expired, "the post-flight list says the session end is pending, and only then")
    d.postActionsOpen = {kind = "pid", index = 1}
    nodes = {}; Screen.buildFullscreen(nodes, widget)
    local all, profile = buttonFor(nodes, "Restore all"), buttonFor(nodes, "Restore profile PID 1")
    check(all and profile and buttonFor(nodes, "Read again"), "positive control: the restore menu is built")
    local function usable(button) return button.active == nil or button.active() end
    check(usable(all) == not expired and usable(profile) == not expired,
      "the restores are disabled while the session end is pending, and usable otherwise")
    profile.press()
    check((d.restoreConfirm ~= nil) == not expired, "a press on a disabled restore opens nothing")
    if d.restoreConfirm then
      nodes = {}; Screen.buildFullscreen(nodes, widget)
      d.sessionExpired = true
      local yes = buttonFor(nodes, "Restore")
      check(yes and yes.active and not yes.active(), "the confirmation's Restore is disabled once a session end is pending")
    end
  end
end)

-- The post-flight list stays up while the pack is out (no link), under one render key for the whole
-- gap, and the session's end becomes pending during that gap: the note has to follow without a rebuild.
scenario("post-flight list with the link gone: the note follows a session end the runtime notes during the gap", function()
  local widget, d = fixture(false)
  local Screen = rfsuite.require("widgets/dashboard/inflight/screen.lua")
  widget.zone = {w = 480, h = 320}
  d.phase, d.post = "post", true
  widget.state.inflight = {phase = "post", linkLost = true, setupVerdict = "ok", setSource = "board", cellCount = 36}
  local nodes = {}; Screen.buildFullscreen(nodes, widget)
  local note
  for _, node in ipairs(nodes) do
    local text = type(node.text) == "function" and node.text() or node.text
    if text == "CHANGED THIS SESSION" then note = node end
  end
  check(note ~= nil and not d.sessionExpired, "positive control: the list is built with the link gone and no end pending")
  -- The runtime's own link watch notes the end after five seconds without a link on the ground.
  local realGetTime, offset = getTime, 0
  _G.getTime = function() return realGetTime() + offset end
  widget.state.fblConnected = false
  for _ = 1, 2 do job(widget); widget:refresh(0, nil) end
  offset = offset + 600
  job(widget); widget:refresh(0, nil)
  _G.getTime = realGetTime
  check(d.sessionExpired == true, "positive control: the runtime noted the session end during the gap")
  local text = type(note.text) == "function" and note.text() or note.text
  local color = type(note.color) == "function" and note.color() or note.color
  check(text == "Battery changed: new session at next read" and color ~= nil,
    "the note already built says the session end is pending, without a rebuild")
end)

scenario("Read again on a board without a set starts the read every pending request asked for", function()
  local widget, d = fixture(false)
  local Screen = rfsuite.require("widgets/dashboard/inflight/screen.lua")
  local state = rfsuite.require("tasks/msp/runtime.lua").getState()
  local savedQueue, queued = state.queue, {}
  state.queue = {add = function(_, request) queued[#queued + 1] = request; return true end, clear = function() end}
  widget.zone = {w = 480, h = 320}
  d.setSource, d.readRequired, d._primeAutoDone, d.readAgain, d.prime = nil, true, false, true, nil
  widget.state.inflight = {phase = "ground", setupVerdict = "ok", setSource = nil, readRequired = true}
  local nodes = {}; Screen.buildFullscreen(nodes, widget)
  local button = buttonFor(nodes, "Read again")
  check(button and button.active(), "positive control: Read again is usable")
  button.press()
  state.queue = savedQueue
  check(#queued == 1 and d.prime and d.prime.phase == "rxmap", "positive control: the press started the full read")
  check(d._primeAutoDone == true and d.readAgain == nil,
    "the read the press started answers the automatic read and the ended session's request, so neither starts another")
end)

scenario("ground label column is as wide as its widest caption", function()
  local widget = fixture(false)
  local Screen = rfsuite.require("widgets/dashboard/inflight/screen.lua")
  local caption = "Model with a long caption"
  widget.zone = {w = 800, h = 480}
  widget.i18n = {t = function(key, fallback)
    return key == "widgets.dashboard.inflight_model_status" and caption or fallback
  end}
  widget.state.inflight = {phase = "ground", setupVerdict = "ok", setSource = "board", cellCount = 36}
  local nodes = {}; Screen.buildFullscreen(nodes, widget)
  local label, value, slots
  for index, node in ipairs(nodes) do
    if node.text == caption then label, value = node, nodes[index + 1] end
    if node.text == "FC slots" then slots = node end
  end
  check(label and value and slots and slots.w == label.w and value.x >= label.x + label.w,
    "every value starts right of the widest caption")
end)
scenario("ground primary caption falls back to the standard font when needed", function()
  local widget = fixture(false)
  local Screen = rfsuite.require("widgets/dashboard/inflight/screen.lua")
  local long = "Choose the parameters for this session from every group"
  widget.zone = {w = 800, h = 480}
  widget.i18n = {t = function(key, fallback)
    return key == "widgets.dashboard.inflight_choose_parameters" and long or fallback
  end}
  widget.state.inflight = {phase = "ground", setupVerdict = "ok", setSource = "board", cellCount = 36}
  local nodes = {}; Screen.buildFullscreen(nodes, widget)
  local button, caption
  for _, node in ipairs(nodes) do
    if node.type == "button" then button = node end
    if node.text == long then caption = node; break end
  end
  check(caption and caption.font == 0 and button.h >= 48,
    "a wide primary caption keeps its complete text and prominence in the standard font")
end)
scenario("ground footer uses the short controls hint when the long hint does not fit", function()
  local widget = fixture(false)
  local Screen = rfsuite.require("widgets/dashboard/inflight/screen.lua")
  local savedPrefs = rfsuite.preferences
  local long = "Rotate the encoder to select an action, then press it to open that action"
  rfsuite.preferences = {audio_events = {adjustment_events = true}}
  widget.i18n = {t = function(key, fallback)
    return key == "widgets.dashboard.inflight_ground_controls" and long or fallback
  end}
  widget.state.inflight = {phase = "ground", setupVerdict = "ok", setSource = "board", cellCount = 36}
  local nodes = {}; Screen.buildFullscreen(nodes, widget)
  rfsuite.preferences = savedPrefs
  local short, shown
  for _, node in ipairs(nodes) do
    if node.text == "Rotate / Press" then short = node end
    if node.text == long then shown = node end
  end
  check(short and not shown, "the ground footer selects the complete short controls hint")
end)

scenario("ground link loss invalidates readings before a pending build", function()
  local widget, d = fixture(false)
  d.valuesRead, d._primeAutoDone = true, true
  d.prime = {phase = "done", records = {}}
  widget.state.fblConnected = false
  job(widget); widget:refresh(0, nil)
  check(d.readRequired and not d.valuesRead and not d._primeAutoDone and d.prime.invalidated,
    "runtime pause invalidates a completed read without a ground tick")
  widget.state.fblConnected = true
  job(widget); widget:refresh(0, nil)
  check(d:profileRefusal() == "session_unread", "ground resume cannot accept retained values")
end)
scenario("retained ground rows stay unread until a fresh read succeeds", function()
  local widget, d = fixture(false)
  local Screen = rfsuite.require("widgets/dashboard/inflight/screen.lua")
  widget.state.inflight = {phase = "ground", setupVerdict = "ok", setSource = "board", cellCount = 36,
    sessionMode = "resume", baseline = {timestamp = "2026-10-25 12:34"}, prime = {phase = "done"}, readRequired = true}
  local nodes = {}; Screen.buildFullscreen(nodes, widget)
  local values = {}
  for _, node in ipairs(nodes) do
    local text = type(node.text) == "function" and node.text() or node.text
    if text then values[text] = true end
  end
  check(values["Setup not checked"] and values["Not read yet"] and values["Values not read"] and not values["Setup OK"],
    "retained model, slots and baseline never claim a current ground read")
  widget.state.inflight.readRequired = nil
  local current = false
  for _, node in ipairs(nodes) do
    if type(node.text) == "function" and node.text() == "Setup OK" then current = true end
  end
  check(current, "successful read updates the cached model row")
end)
-- The post-flight list's labels are laid out with LVGL's own line: about 41 px for the middle font
-- and 22 for the small one at 800x480, 20 and 16 for the standard and small font at 480x320. The
-- count heading has to end above the first band and the caption above the buttons.
for _, size in ipairs({{480, 272}, {480, 320}, {800, 480}}) do
  scenario("post-flight heading and caption clear the list and the buttons " .. size[1] .. "x" .. size[2], function()
    local widget, d = fixture(false)
    local Screen = rfsuite.require("widgets/dashboard/inflight/screen.lua")
    widget.zone = {w = size[1], h = size[2]}
    widget.state.inflight = {phase = "post", setupVerdict = "ok", setSource = "board", cellCount = 36}
    d.baseline = {pid1 = {["14"] = 50}}
    d.profileValues.pid[1][14] = 57
    d.changes = {pid = {[1] = {[14] = true}}, rate = {}, global = {}}
    local nodes = {}; Screen.buildFullscreen(nodes, widget)
    local large = size[2] > 350
    local lineOf = {[0] = 20, [SMLSIZE] = large and 22 or 16, [MIDSIZE] = large and 41 or 30}
    local heading, band, caption, button
    for _, node in ipairs(nodes) do
      local text = type(node.text) == "function" and node.text() or node.text
      if text == "1 parameter changed" then heading = node end
      if node.type == "rectangle" and node.filled and heading and not band and node.y > heading.y then band = node end
      if text == "CHANGED THIS SESSION" then caption = node end
      if node.type == "button" and not button then button = node end
    end
    check(heading ~= nil, "a single change is counted in the singular")
    check(heading and band and heading.y + lineOf[heading.font] <= band.y, "the count heading ends above the first band")
    check(caption and button and caption.y + lineOf[caption.font] <= button.y, "the caption ends above the buttons")
  end)
end
scenario("post-flight history remains visible through link loss and reconnect", function()
  local widget, d = fixture(false)
  local Screen = rfsuite.require("widgets/dashboard/inflight/screen.lua")
  widget.state.inflight = {phase = "post", setupVerdict = "ok", setSource = "board", cellCount = 36,
    profileText = "TUNING PID 2 / RTE 3", boundsCount = 2, readRequired = true}
  d.readRequired = true
  d.baseline = {pid1 = {["14"] = 50}}
  d.profileValues.pid[1][14] = 57
  d.changes = {pid = {[1] = {[14] = true}}, rate = {}, global = {}}
  for _, lost in ipairs({true, false}) do
    widget.state.inflight.linkLost = lost
    local nodes = {}; Screen.buildFullscreen(nodes, widget)
    local changed, values, title
    for _, node in ipairs(nodes) do
      local text = type(node.text) == "function" and node.text() or node.text
      if text == "1 parameter changed" then changed = true end
      if text == "50 -> 57  +7" then values = true end
      if text == "TUNING" then title = true end
    end
    check(changed and values and title, "post-flight list retains the flight's recorded change while readings are invalidated")
  end
  widget.state.inflight.phase, widget.state.inflight.linkLost = "ground", nil
  local nodes = {}; Screen.buildFullscreen(nodes, widget)
  local unread, title
  for _, node in ipairs(nodes) do
    local text = type(node.text) == "function" and node.text() or node.text
    if text == "Values not read" then unread = true end
    if text == "TUNING" then title = true end
    check(text ~= "TUNING PID 2 / RTE 3" and not (type(text) == "string" and string.find(text, "2 beyond", 1, true)),
      "unread ground does not label retained profiles or bounds as current")
  end
  check(unread and title, "ground surface still marks retained readings as unread")
end)
scenario("armed link resume owes a full read after landing", function()
  local widget, d = fixture(true)
  d.valuesRead, d._primeAutoDone = true, true
  widget.state.fblConnected = false
  job(widget); widget:refresh(0, nil)
  widget.state.fblConnected = true
  job(widget); widget:refresh(0, nil)
  check(d.readRequired and d:profileRefusal() == nil, "armed continuation retains permission and the full-read obligation")
  widget.state.armed = false
  job(widget); widget:refresh(0, nil)
  check(d.readRequired and not d.readArmed and d:profileRefusal() == "session_unread",
    "landing refuses the old read even when the automatic latch was set before loss")
end)
scenario("automatic link resume retains the board identity refusal", function()
  local widget, d, writes = fixture(true)
  energize(d, writes)
  d.board = "board-a"
  local Prime = rfsuite.require("widgets/dashboard/inflight/prime.lua")
  local saved, board = Prime.boardOnLink, nil
  Prime.boardOnLink = function() return board end
  widget.state.fblConnected = false
  job(widget); widget:refresh(0, nil)
  local before = #writes
  widget.state.fblConnected = true
  job(widget); widget:refresh(0, nil)
  check(widget.inflightFullscreen and d.live, "link return releases the visit while identity is pending")
  check(d:profileRefusal() == "board_unknown" and not d:dispatch("step", 1, "touch"), "pending board identity still refuses steps")
  board = "board-b"
  check(d:profileRefusal() == "session_unread" and not d:dispatch("step", 1, "touch"), "another board cannot use the previous session")
  for i = before + 1, #writes do
    if writes[i][1] == d.settings.value_gvar - 1 then check(writes[i][3] == 0, "unknown or foreign identity permits no value pulse") end
  end
  Prime.boardOnLink = saved
end)
scenario("the quick-menu entry is offered before the tuning surface was ever opened", function()
  local Views = rfsuite.require("widgets/dashboard/views.lua")
  local widget = Runtime.new({x = 0, y = 0, w = 480, h = 320}, {})
  widget.preferences.general = {preview_inflight_tuning = true}
  widget.preferences.inflight = {enabled = true}
  widget.state.inflight, widget._inflight, widget.inflightFullscreen = nil, nil, nil
  check(Views.condition("previewInflightTuning", widget) == true,
    "the entry is the only way in, so it must not wait for a snapshot only an open surface publishes")
  widget.preferences.inflight.enabled = false
  check(Views.condition("previewInflightTuning", widget) ~= true, "radio master switch off hides the entry")
  widget.preferences.inflight.enabled = true
  widget.preferences.general.preview_inflight_tuning = false
  check(Views.condition("previewInflightTuning", widget) ~= true, "preview off hides the entry")
  widget.preferences.general.preview_inflight_tuning = true
  widget.state.armed = true
  check(Views.condition("previewInflightTuning", widget) ~= true, "armed hides the entry: it opens on the ground only")
  widget.state.armed = false
  check(Views.condition("previewInflightTuning", widget) == true, "disarmed again offers the entry")
end)
scenario("a hardware key bound to in-flight tuning opens the surface", function()
  local Views = rfsuite.require("widgets/dashboard/views.lua")
  local Keys = rfsuite.require("widgets/dashboard/keys.lua")
  local widget = Runtime.new({x = 0, y = 0, w = 480, h = 320}, {})
  widget.preferences.general = {preview_inflight_tuning = true}
  widget.preferences.inflight = {enabled = true}
  widget.inflightFullscreen = nil
  local action, global = Keys.resolve({key_tele = "inflight_tuning"}, "tele", nil, nil)
  check(action == "openTuning" and global == true, "the Keys choice resolves to the open-tuning action")
  Views.navigate(widget, action)
  check(widget.inflightFullscreen == true and widget.built == false, "the bound key raises the tuning flag")
  widget.inflightFullscreen = nil
  widget.preferences.inflight.enabled = false
  Views.navigate(widget, action)
  check(widget.inflightFullscreen ~= true, "with the overlay disabled the key opens nothing")
  widget.preferences.inflight.enabled = true
  widget.state.armed = true
  Views.navigate(widget, action)
  check(widget.inflightFullscreen ~= true, "armed, the bound key opens nothing")
  widget.state.armed = false
  Views.navigate(widget, action)
  check(widget.inflightFullscreen == true, "disarmed, the same key opens the surface")
end)
-- A fresh loader per visit is essential: the earlier drive fixtures deliberately start warm.
-- loadScript observes cache misses in the shipped memoizer, including nested dependencies.
-- The host compiler is C code outside debug.sethook's count, so count module loads and overlay
-- calls independently instead of pretending these passes price the firmware's compilation.
for _, opening in ipairs({"quick_menu", "bound_key", "firmware", "background", "radio_disabled", "preview_disabled", "RTN"}) do
  scenario(opening .. " cold opening isolates each first module load", function()
    Stubs.install(arg[1] or "."); Stubs.reset(); FC.install(Stubs); FC.reset()
    local pass, loaded, wrapped = nil, {}, {}
    local realLoad, realRequire = loadScript, rfsuite.require
    _G.loadScript = function(path, ...)
      local name = string.match(path, "/widgets/dashboard/inflight/([^/]+%.lua)$")
      if name then
        if pass then pass.loads[#pass.loads + 1] = name end
        loaded[name] = (loaded[name] or 0) + 1
      end
      return realLoad(path, ...)
    end
    local observed = {
      ["drive.lua"] = {"get", "tick", "sample"}, ["prime.lua"] = {"tick"},
      ["screen.lua"] = {"renderKey", "buildFullscreen", "ready"}, ["input.lua"] = {"key"}
    }
    rfsuite.require = function(path, ...)
      local module = realRequire(path, ...)
      local name = string.match(path, "widgets/dashboard/inflight/([^/]+%.lua)$")
      if type(module) == "table" and observed[name] and not wrapped[module] then
        wrapped[module] = true
        for _, key in ipairs(observed[name]) do
          local original = module[key]
          module[key] = function(...)
            if pass then pass.work = pass.work + 1 end
            return original(...)
          end
        end
      end
      return module
    end
    local ColdRuntime = rfsuite.require("widgets/dashboard/runtime.lua")
    local Menu = rfsuite.require("widgets/dashboard/fullscreen_menu.lua")
    local widget = ColdRuntime.new({x = 0, y = 0, w = 480, h = 320}, {})
    widget.preferences.general = {preview_inflight_tuning = true}
    widget.preferences.inflight = {enabled = true}
    widget.preferences.dashboard = {key_tele = "inflight_tuning"}
    -- Opened on the ground, flown armed: the surface is offered only while disarmed.
    widget.state.armed, widget.state.armedSeen, widget.state.fblConnected = false, true, true
    local builds, writes, loadPasses = 0, 0, 0
    local realBuild, realWrite = lvgl.build, model.setGlobalVariable
    local realTele, realExit = _G.EVT_TELEM_BREAK, _G.EVT_VIRTUAL_EXIT
    lvgl.build = function(...)
      if pass then pass.work = pass.work + 1 end
      if widget.state.inflight then builds = builds + 1 end
      return realBuild(...)
    end
    model.setGlobalVariable = function(...)
      writes = writes + 1
      return realWrite(...)
    end
    local function refresh(event)
      Stubs.tick()
      widget._lastWorkTick = getTime() / 100
      pass = {loads = {}, work = 0}
      local before = writes
      local ok, err = pcall(widget.refresh, widget, event, nil)
      local result = pass
      pass = nil
      check(ok, tostring(err))
      check(#result.loads <= 1, "one first load per pass, saw " .. table.concat(result.loads, ", "))
      if #result.loads > 0 then
        loadPasses = loadPasses + 1
        check(result.work == 0, "module load shared a pass with overlay calls or a build")
        check(widget._inflight == nil and writes == before, "preloading creates no drive and writes nothing")
      end
      return result
    end
    local ok, err = pcall(function()
      for _, disabled in ipairs({"radio", "preview"}) do
        widget.inflightFullscreen = true
        if disabled == "radio" then widget.preferences.inflight.enabled = false
        else widget.preferences.general.preview_inflight_tuning = false end
        job(widget); refresh(0)
        check(next(loaded) == nil and widget._inflight == nil and writes == 0,
          "a disabled overlay with a stale open request loads nothing and writes nothing")
        check(widget.inflightFullscreen ~= true, "disabling consumes the pending visit")
        widget.preferences.inflight.enabled = true
        widget.preferences.general.preview_inflight_tuning = true
      end
      -- Positive entry controls use the real menu callback and the runtime's hardware-key route.
      job(widget); refresh(0)
      check(next(loaded) == nil, "an enabled but unopened overlay loads nothing")
      if opening ~= "bound_key" then
        local entry = Menu.entry(widget, "inflight_tuning")
        check(entry and entry.press, "positive control: tuning entry exists")
        widget.state.armed = true
        check(Menu.visible(widget, entry) ~= true, "armed, the menu does not offer the entry")
        widget.state.armed = false
        check(Menu.visible(widget, entry) == true, "disarmed, the menu offers the entry")
        Menu.run(widget, entry)
        check(next(loaded) == nil and widget._inflight == nil, "the press itself loads nothing and creates no drive")
        job(widget)
        local pending, ran = widget._job, 0
        pending.step = function() ran = ran + 1; return true end
        local first = refresh(0)
        check(#first.loads == 1 and widget._inflight == nil and writes == 0,
          "the first refresh after the press loads one module, with no drive")
        check(ran == 0 and widget._job == pending, "the queued job waits behind the first load")
      else
        _G.EVT_TELEM_BREAK = 9001
        widget.state.armed = true
        job(widget); refresh(EVT_TELEM_BREAK)
        check(widget.inflightFullscreen ~= true and next(loaded) == nil, "armed, the bound key opens and loads nothing")
        widget.state.armed = false
        job(widget); refresh(EVT_TELEM_BREAK)
      end
      check(widget.inflightFullscreen == true, "positive control: the event opened tuning")
      widget.state.armed = true
      if opening == "bound_key" then
        check(next(loaded) == nil and widget._inflight == nil, "the opening key's pass defers all first loads and drive work")
      end
      if opening ~= "quick_menu" and opening ~= "bound_key" then
        refresh(0)
        check(loadPasses == 2, "positive control: preloading has started")
        if opening == "firmware" then refresh(nil)
        elseif opening == "background" then widget:background()
        elseif opening == "RTN" then
          _G.EVT_VIRTUAL_EXIT = 9002
          refresh(EVT_VIRTUAL_EXIT)
        else
          if opening == "radio_disabled" then widget.preferences.inflight.enabled = false
          else widget.preferences.general.preview_inflight_tuning = false end
          refresh(0)
        end
        check(widget.inflightFullscreen ~= true and widget._inflight == nil and writes == 0,
          "exit cancels preloading immediately without creating a drive or writing output")
        widget.preferences.inflight.enabled = true
        widget.preferences.general.preview_inflight_tuning = true
        for _ = 1, 3 do job(widget); refresh(0) end
        check(loadPasses == 2 and widget._inflight == nil, "recovery cannot resume an abandoned preload")
        return
      end
      widget._job = nil
      for _ = 1, 40 do
        refresh(0)
        if builds > 0 then break end
      end
      check(loadPasses > 0 and builds > 0 and widget._inflight ~= nil,
        "positive control: isolated loads finish and later passes build the surface")
      for _, name in ipairs({"setup.lua", "functions.lua", "baseline.lua", "profiles.lua", "drive.lua",
          "input.lua", "prime.lua", "screen.lua"}) do
        check(loaded[name] == 1, "each overlay module loads exactly once: " .. name)
      end
      check(not loaded["fcsetup.lua"] and not loaded["fctext.lua"] and not loaded["fcsurface.lua"],
        "the separate suggested-functions dialog is not loaded by opening tuning")
      print("  cold opening: " .. loadPasses .. " isolated module-load passes; " .. builds .. " later build")
    end)
    _G.loadScript, lvgl.build, model.setGlobalVariable = realLoad, realBuild, realWrite
    _G.EVT_TELEM_BREAK, _G.EVT_VIRTUAL_EXIT = realTele, realExit
    check(ok, tostring(err))
  end)
end
Stubs.releaseCard()
print(passed .. " surface regressions passed; " .. #failed .. " failed; " .. checks .. " assertions")
assert(#failed == 0, table.concat(failed, "\n"))
