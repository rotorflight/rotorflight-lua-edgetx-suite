-- The log lines of the dashboard, its tool host, the event runner and the sensor reader, offline:
--
--   lua5.3 bin/dashboard/verify_log_lines.lua
--
-- The real modules and the real lib/log.lua, on the stub radio of bin/accounting/stubs. Lines are
-- read from the logger's own card sink (every line it was given, untruncated) or, where the case is
-- "nobody is recording", from the Session Logs ring. Each case sets the log level it is about.
--
-- Checked: the one-time "no telemetry source found" line and its re-arming by Sensors.reset();
-- the view opened / closed lines and the single warning for a view whose module does not load; the
-- tool host's instruction-limit warning, its step lines and the dropped-modules count; the single
-- warning for an object type that does not load; the event runner's raised-task warning (once per
-- attempt) and its completion line with the memory figure; and, on the real dashboard runtime
-- driven through a connect and a flight, what the milestones, the base-log lines and the build
-- lines do at each level. A direct Log.emit is read back in every case, so a silent result cannot
-- be told apart from a capture that saw nothing.
--
-- No pixels, hardware or timing are measured. Exit status: 0 green, 1 failed expectations.

local root = "."
local Stubs = assert(loadfile(root .. "/bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile(root .. "/bin/accounting/stubs/fc.lua"))()

local failures, checks = 0, 0
local function check(ok, label, detail)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    io.stdout:write("FAIL " .. label .. (detail ~= nil and (": " .. tostring(detail)) or "") .. "\n")
  end
end

local function contains(text, part)
  return type(text) == "string" and string.find(text, part, 1, true) ~= nil
end

-- ---------------------------------------------------------------------------
-- Capture
-- ---------------------------------------------------------------------------

local console = {}
local realPrint = print
_G.print = function(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  console[#console + 1] = table.concat(parts, "\t")
end

local Log

local function setLevel(level)
  _G.rfsuite.logSteps = level == "debug" or level == "trace"
  local r = _G.rfsuite
  r.preferences = r.preferences or {}
  r.preferences.general = r.preferences.general or {}
  r.preferences.general.debug_level = level
end

-- A fresh start of capture: the level, an empty ring, and a sink or none.
local function begin(level, sink)
  setLevel(level)
  _G.rfsuite.log_history = {}
  _G.rfsuite.log_sink = sink and {} or nil
  console = {}
end

local function captured()
  return _G.rfsuite.log_sink or _G.rfsuite.log_history
end

-- The captured entries whose tag matches (nil: any tag) and whose message contains `part`.
local function find(tag, part)
  local out = {}
  local list = captured()
  for i = 1, #list do
    local e = list[i]
    if (tag == nil or e.tag == tag) and (part == nil or contains(e.msg, part)) then out[#out + 1] = e end
  end
  return out
end

local function count(tag, part)
  return #find(tag, part)
end

local function world()
  Stubs.clearCard()
  Stubs.install(root)
  Stubs.reset()
  Log = assert(_G.rfsuite.require("lib/log.lua"))
  check(_G.rfsuite.Log == Log, "the logger is published on the root")
  _G.rfsuite.loadMode = nil
end

-- The control every case carries: a direct emit at the wanted level is seen, one the level does
-- not let through is not (except the levels the ring keeps at every setting).
local function control(label, level)
  local tag = "control." .. label
  Log.emit(tag, "wanted " .. level, level)
  check(count(tag, "wanted " .. level) == 1, label .. ": a direct " .. level .. " line is captured")
end

local function lua_kb(text)
  return type(text) == "string" and string.match(text, "lua (%d+) kB") ~= nil
end

-- ---------------------------------------------------------------------------
-- 1. lib/sensors.lua
-- ---------------------------------------------------------------------------

do
  local MISS = "no telemetry source found for NoSuchSource"
  local function read(Sensors)
    -- Far enough on for the search back-off of the previous miss to have run out.
    _G.getTime = (function(n) return function() n = n + 1000000; return n end end)(0)
    return Sensors.getValue("NoSuchSource")
  end

  world()
  begin("debug", true)
  control("sensors debug", "debug")
  local Sensors = assert(_G.rfsuite.require("lib/sensors.lua"))
  Sensors.reset()
  -- Without a link every source misses, and that says nothing.
  _G.rfsuite.session = { isConnected = false }
  check(read(Sensors) == nil, "sensors: an unknown source reads nil")
  check(count("rfsuite.sensors", MISS) == 0, "sensors: no miss line while not connected", count("rfsuite.sensors", MISS))
  _G.rfsuite.session.isConnected = true
  Sensors.reset()
  read(Sensors)
  check(count("rfsuite.sensors", MISS) == 1, "sensors: the miss is said once", count("rfsuite.sensors", MISS))
  local line = find("rfsuite.sensors", MISS)[1]
  check(line ~= nil and line.level == "debug", "sensors: the miss line is a debug line", line and line.level)
  read(Sensors)
  read(Sensors)
  check(count("rfsuite.sensors", MISS) == 1, "sensors: further misses say nothing", count("rfsuite.sensors", MISS))
  Sensors.reset()
  read(Sensors)
  check(count("rfsuite.sensors", MISS) == 2, "sensors: after Sensors.reset() it is said again",
    count("rfsuite.sensors", MISS))

  world()
  begin("off", true)
  control("sensors off", "error")
  Sensors = assert(_G.rfsuite.require("lib/sensors.lua"))
  Sensors.reset()
  read(Sensors)
  read(Sensors)
  check(count(nil, MISS) == 0, "sensors: nothing at off", count(nil, MISS))
  check(count("rfsuite.sensors", nil) == 0, "sensors: no sensor line of any kind at off", count("rfsuite.sensors", nil))

  -- The level is asked again after a reset: raised on the radio, it reaches the next connect.
  setLevel("debug")
  _G.rfsuite.session = { isConnected = true }
  Sensors.reset()
  read(Sensors)
  check(count("rfsuite.sensors", MISS) == 1, "sensors: a level raised before a reset is seen after it",
    count("rfsuite.sensors", MISS))
end

do
  -- A burst after a reset is spread: at most three lines in one fifth of a second, the rest later.
  world()
  begin("debug", true)
  control("sensors burst", "debug")
  _G.rfsuite.session = { isConnected = true }
  local Sensors = assert(_G.rfsuite.require("lib/sensors.lua"))
  Sensors.reset()
  local clock = 1000
  _G.getTime = function() return clock end
  local function readAll()
    for i = 1, 6 do Sensors.getValue("NoSuchSource" .. i) end
  end
  local miss = "no telemetry source found for NoSuchSource"
  readAll()
  -- At most: the module's first line, which says whether this is a simulator, shares the slot.
  check(count("rfsuite.sensors", miss) <= 3, "sensors: at most three lines in one slot", count("rfsuite.sensors", miss))
  -- One search per clock reading after the first ones, so each read has its own.
  for i = 1, 6 do
    clock = clock + 1000000
    Sensors.getValue("NoSuchSource" .. i)
  end
  check(count("rfsuite.sensors", miss) == 6, "sensors: the rest on later reads, each once", count("rfsuite.sensors", miss))
  -- A duplicate is said once and never asked again, so the limit leaves it alone. The file holds the
  -- limit's two exempt key shapes literally.
  local source = assert(io.open(root .. "/src/rfsuite/lib/sensors.lua")):read("a")
  check(string.find(source, 'string.sub(key, 1, 4) ~= "dup:"', 1, true) ~= nil, "sensors: a duplicate line is outside the limit")
end

-- ---------------------------------------------------------------------------
-- 2. widgets/dashboard/views.lua
-- ---------------------------------------------------------------------------

do
  local function newWidget()
    return { zone = { w = 800, h = 480 }, state = {}, preferences = { dashboard = {} },
      built = true, renderKey = "test" }
  end

  world()
  begin("debug", true)
  control("views debug", "debug")
  local Views = assert(_G.rfsuite.require("widgets/dashboard/views.lua"))
  local widget = newWidget()
  Views.navigate(widget, "openView:menu")
  check(count("rfsuite.widget.view", "menu opened") == 1, "views: openView says opened once",
    count("rfsuite.widget.view", "menu opened"))
  local opened = find("rfsuite.widget.view", "menu opened")[1]
  check(opened ~= nil and opened.level == "debug", "views: the opened line is a debug line", opened and opened.level)
  check(Views.top(widget) == "menu", "views: the view is on the stack")
  Views.navigate(widget, "closeView")
  check(count("rfsuite.widget.view", "menu closed") == 1, "views: closeView says closed once",
    count("rfsuite.widget.view", "menu closed"))
  check(count("rfsuite.widget.view", "press: openView menu") == 1, "views: the press itself is named")

  -- A core view whose module does not load: said once, however often it is asked for.
  local entry = Views.find(widget, "menu")
  entry.module = "widgets/dashboard/no_such_view.lua"
  entry.loaded = nil
  local before = count("rfsuite.widget", "view 'menu' did not load")
  for _ = 1, 4 do Views.load(widget, entry) end
  local warned = find("rfsuite.widget", "view 'menu' did not load")
  check(#warned - before == 1 and #warned == 1, "views: a core view that does not load warns once, not per call", #warned)
  check(warned[1] ~= nil and warned[1].level == "warn", "views: and the warning is a warn line", warned[1] and warned[1].level)
  check(count("rfsuite.widget.view", "menu module loaded") == 0, "views: no 'module loaded' line for the one that failed")

  world()
  begin("off", false)
  control("views off", "error")
  Views = assert(_G.rfsuite.require("widgets/dashboard/views.lua"))
  widget = newWidget()
  Views.navigate(widget, "openView:menu")
  Views.navigate(widget, "closeView")
  check(Views.top(widget) == nil, "views: the stack is empty again at off")
  check(count("rfsuite.widget.view", nil) == 0, "views: nothing of the view tag at off", count("rfsuite.widget.view", nil))
  entry = Views.find(widget, "menu")
  entry.module = "widgets/dashboard/no_such_view.lua"
  for _ = 1, 4 do Views.load(widget, entry) end
  check(count("rfsuite.widget", "view 'menu' did not load") == 1, "views: the load warning stands at off, once",
    count("rfsuite.widget", "view 'menu' did not load"))
end

-- ---------------------------------------------------------------------------
-- 3. widgets/dashboard/tool_host.lua
-- ---------------------------------------------------------------------------

do
  local function toolCase(level)
    world()
    begin(level, true)
    control("tool " .. level, level == "off" and "error" or level)
    local ToolHost = assert(_G.rfsuite.require("widgets/dashboard/tool_host.lua"))
    local base = _G.rfsuite.paths.core .. "/"
    local homePath = base .. "ui/home.lua"

    local runs = 0
    local home = {
      init = function() end,
      run = function()
        runs = runs + 1
        if runs == 1 then error("CPU limit reached") end
        return 2
      end,
      releasePages = function() end,
    }
    local realLoadScript = _G.loadScript
    _G.loadScript = function(path, mode)
      if path == homePath then return function() return home end end
      return realLoadScript(path, mode)
    end

    _G.rfsuite.modules[base .. "app/seed_one.lua"] = {}
    _G.rfsuite.modules[base .. "app/pages/seed_two.lua"] = {}
    _G.rfsuite.modules[base .. "ui/seed_three.lua"] = {}

    local widget = { state = {}, preferences = {} }
    check(ToolHost.request(widget, nil) == true, "tool " .. level .. ": the tool is asked for")
    ToolHost.step(widget, 0, nil)   -- load
    ToolHost.step(widget, 0, nil)   -- init
    ToolHost.step(widget, 0, nil)   -- first run: stopped at the instruction limit
    local limit = find("rfsuite.widget", "stopped at the instruction limit")
    check(#limit == 1, "tool " .. level .. ": an instruction-limit stop warns once", #limit)
    check(limit[1] ~= nil and limit[1].level == "warn" and contains(limit[1].msg, "(1/12)"),
      "tool " .. level .. ": the warning is a warn line with the count", limit[1] and limit[1].msg)

    local expected = 0
    for path in pairs(_G.rfsuite.modules) do
      if string.sub(path, 1, #(base .. "app/")) == base .. "app/" or string.sub(path, 1, #(base .. "ui/")) == base .. "ui/" then
        expected = expected + 1
      end
    end
    ToolHost.step(widget, 0, nil)   -- second run: the pilot closes it
    check(not ToolHost.isOpen(widget), "tool " .. level .. ": the tool is closed")
    _G.loadScript = realLoadScript

    local steps = find("rfsuite.widget.tool", nil)
    if level == "debug" then
      check(#steps == 3, "tool debug: the step lines are present", #steps)
      local allKb = #steps > 0
      for i = 1, #steps do
        if steps[i].level ~= "debug" or not lua_kb(steps[i].msg) then allKb = false end
      end
      check(allKb, "tool debug: every step line is a debug line carrying 'lua N kB'")
      check(count("rfsuite.widget.tool", "tool asked for") == 1, "tool debug: the request is a step")
      check(count("rfsuite.widget.tool", "tool loaded") == 1, "tool debug: the load is a step")
      local dropped = find("rfsuite.widget.tool", "tool modules dropped: ")
      check(#dropped == 1, "tool debug: one dropped-modules line", #dropped)
      local n = dropped[1] and tonumber(string.match(dropped[1].msg, "tool modules dropped: (%d+)")) or nil
      check(n ~= nil and n == expected and n >= 3, "tool debug: the count is what was dropped",
        tostring(n) .. " against " .. tostring(expected))
      check(_G.rfsuite.modules[base .. "app/seed_one.lua"] == nil, "tool debug: the dropped module is gone from the cache")
    else
      check(#steps == 0, "tool " .. level .. ": no step line", #steps)
    end
  end
  toolCase("off")
  toolCase("info")
  toolCase("debug")
end

-- ---------------------------------------------------------------------------
-- 4. widgets/dashboard/engine.lua
-- ---------------------------------------------------------------------------

do
  local function engineCase(level, typeName)
    world()
    begin(level, true)
    control("engine " .. level, level == "off" and "error" or level)
    local Engine = assert(_G.rfsuite.require("widgets/dashboard/engine.lua"))
    local theme = {
      layout = { cols = 2, rows = 1, padding = 0 },
      boxes = { { type = typeName }, { type = typeName } },
    }
    for _ = 1, 3 do Engine.build({ x = 0, y = 0, w = 800, h = 480 }, {}, theme) end
    local warned = find("rfsuite.widget.object", "object type " .. typeName .. " did not load")
    check(#warned == 1, "engine " .. level .. ": an object type that does not load warns once", #warned)
    check(warned[1] ~= nil and warned[1].level == "warn", "engine " .. level .. ": and it is a warn line",
      warned[1] and warned[1].level)
  end
  engineCase("off", "no_such_object")
  engineCase("debug", "no_such_object")
end

-- ---------------------------------------------------------------------------
-- 5. tasks/events/common/runner.lua
-- ---------------------------------------------------------------------------

do
  local TASKS_DIR = "/tasks/events/logrun/"
  local function runnerCase(level, nilAttempts)
    world()
    begin(level, true)
    control("runner " .. level, level == "off" and "error" or level)

    local now = 0
    _G.getTime = function() return now end

    local loads = 0
    local completes = false
    local realLoadScript = _G.loadScript
    _G.loadScript = function(path, mode)
      if type(path) == "string" and string.find(path, TASKS_DIR, 1, true) then
        if string.find(path, "manifest.lua", 1, true) then
          return function() return { "failing", "finishing" } end
        elseif string.find(path, "/failing.lua", 1, true) then
          return function()
            loads = loads + 1
            return {
              wakeup = function() error("task failure") end,
              isComplete = function() return false end,
            }
          end
        elseif string.find(path, "/finishing.lua", 1, true) then
          return function()
            return { wakeup = function() end, isComplete = function() return completes end }
          end
        end
        return nil
      end
      return realLoadScript(path, mode)
    end

    local Runner = assert(loadfile(root .. "/src/rfsuite/tasks/events/common/runner.lua"))()
    local runner = Runner.new("logrun")
    runner.findTasks()

    if nilAttempts then
      -- A task entry whose attempt count is absent still counts as the first attempt.
      local i = 1
      while true do
        local name, value = debug.getupvalue(runner.wakeup, i)
        if name == nil then break end
        if name == "tasksQueue" then value[1].attempts = nil end
        i = i + 1
      end
    end

    runner.wakeup({})
    runner.wakeup({})
    runner.wakeup({})
    local raised = find("rfsuite.tasks.logrun", "task failing raised")
    check(#raised == 1, "runner " .. level .. (nilAttempts and " (attempts nil)" or "") ..
      ": a task that raises is logged once for the first attempt", #raised)
    check(raised[1] ~= nil and raised[1].level == "warn" and contains(raised[1].msg, "task failure"),
      "runner " .. level .. ": the raise is a warn line carrying the message", raised[1] and raised[1].msg)

    if not nilAttempts then
      now = 2600          -- past the task timeout: the attempt ends, the module is released
      runner.wakeup({})
      check(count("rfsuite.tasks.logrun", "task failing raised") == 1,
        "runner " .. level .. ": the same attempt is not logged again when it times out")
      check(count("rfsuite.tasks.logrun", "timed out") == 1, "runner " .. level .. ": the timeout is said")
      now = 2800          -- past the back-off: the next attempt raises again
      runner.wakeup({})
      runner.wakeup({})
      check(count("rfsuite.tasks.logrun", "task failing raised") == 2,
        "runner " .. level .. ": a new attempt is logged once more", count("rfsuite.tasks.logrun", "task failing raised"))
    end

    -- A task that completes: the line with the time and the memory, at debug only.
    local finishRunner = Runner.new("logrun")
    finishRunner.findTasks()
    -- Skip the failing task by failing it out: the second one is what is under test.
    local progressed = false
    for _ = 1, 40 do
      now = now + 300000
      completes = true
      finishRunner.wakeup({})
      finishRunner.wakeup({})
      if finishRunner.getProgress().done >= 1 then progressed = true end
    end
    check(progressed, "runner " .. level .. ": a task completed")
    local done = find("rfsuite.tasks.logrun", "completed task ")
    if level == "debug" then
      check(#done >= 1, "runner debug: the completion line is present", #done)
      local line = done[1]
      check(line ~= nil and line.level == "debug" and lua_kb(line.msg)
        and string.match(line.msg, "^completed task %S+ in [%d%.]+ s, lua %d+ kB$") ~= nil,
        "runner debug: 'completed task <n> in <t> s, lua <k> kB'", line and line.msg)
    else
      check(#done == 0, "runner " .. level .. ": no completion line", #done)
    end
    _G.loadScript = realLoadScript
  end
  runnerCase("off", false)
  runnerCase("debug", false)
  runnerCase("debug", true)
end

-- ---------------------------------------------------------------------------
-- 5b. lib/require.lua and the connect's UID task
-- ---------------------------------------------------------------------------

do
  world()
  begin("off", true)
  control("require off", "error")
  local missing = "lib/no_such_module_for_this_check.lua"
  local stubLoadScript = _G.loadScript
  _G.loadScript = function(path, mode)
    local chunk, err = stubLoadScript(path, mode)
    if chunk == nil and err == nil then err = "cannot open " .. tostring(path) end
    return chunk, err
  end
  for _ = 1, 3 do _G.rfsuite.require(missing) end
  _G.loadScript = stubLoadScript
  local said = find("rfsuite.require", missing)
  check(#said == 1, "require: a load that keeps failing is said once", #said)
  check(said[1] ~= nil and said[1].level == "error", "require: and it is an error line", said[1] and said[1].level)

  -- A module that raises while it runs is asked for again too.
  world()
  begin("off", true)
  local raising = "lib/raises_for_this_check.lua"
  local stubForRaise = _G.loadScript
  _G.loadScript = function(path, mode)
    if string.find(path, raising, 1, true) then return function() error("raised on load") end end
    return stubForRaise(path, mode)
  end
  for _ = 1, 3 do _G.rfsuite.require(raising) end
  _G.loadScript = stubForRaise
  check(#find("rfsuite.require", "error executing") == 1, "require: a module that keeps raising is said once",
    #find("rfsuite.require", "error executing"))

  -- A load and a release, at debug and not at off.
  local function loadCase(level, expected)
    world()
    begin(level, true)
    control("require " .. level, level == "off" and "error" or level)
    local path = "widgets/dashboard/keys.lua"
    _G.rfsuite.clearModule(path)
    begin(level, true)
    -- The dashboard raises this a few seconds after it starts; its create and first pass run without it.
    _G.rfsuite.logModuleLoads = level == "debug"
    _G.rfsuite.require(path)
    local loaded = find("rfsuite.require", "loaded ")
    check(#loaded == expected, "require " .. level .. ": a load is said " .. expected .. " time(s)", #loaded)
    if expected > 0 then
      check(loaded[1].level == "debug" and string.find(loaded[1].msg, "lua %d+ %-> %d+ kB") ~= nil,
        "require " .. level .. ": a debug line with the figures", loaded[1].msg)
    end
    _G.rfsuite.clearModule(path)
    check(#find("rfsuite.require", "released ") == expected, "require " .. level .. ": a release is said " .. expected .. " time(s)", nil)
  end
  loadCase("off", 0)
  loadCase("debug", 1)
  _G.rfsuite.logModuleLoads = nil

  world()
  begin("info", true)
  control("uid info", "info")
  local chunk = assert(loadfile(root .. "/src/rfsuite/tasks/events/onconnect/tasks/uid.lua"))
  local task = chunk()
  _G.rfsuite.session = { mcu_id = "ABC", modelPreferences = {}, modelPreferencesFile = "held.ini" }
  task.wakeup()
  local resolved = find("rfsuite.tasks.onconnect", "model preferences: held.ini")
  check(#resolved == 1, "uid: the file the model's preferences came from is said", #resolved)
  task.wakeup()
  check(#find("rfsuite.tasks.onconnect", "model preferences:") == 1, "uid: and only once", nil)
end

-- ---------------------------------------------------------------------------
-- 5c. the widget's entry: a create that stops says so
-- ---------------------------------------------------------------------------

do
  world()
  begin("off", true)
  control("entry off", "error")
  local stubLoadScript = _G.loadScript
  _G.loadScript = function(path, mode)
    if string.find(path, "dashboard/runtime.lua", 1, true) or string.find(path, "WIDGETS/rfsuite/app.lua", 1, true) then
      return function() return { new = function() error("CPU limit reached") end } end
    end
    return stubLoadScript(path, mode)
  end
  local entry = assert(loadfile(root .. "/src/widgets/rfsuite/main.lua"))()
  local widget = entry.create({ x = 0, y = 0, w = 800, h = 480 }, {})
  _G.loadScript = stubLoadScript
  check(widget == nil, "entry: a create that raises hands out no widget", widget)
  local said = find("rfsuite.widget", "dashboard not created")
  check(#said == 1, "entry: a create that stops is said once", #said)
  check(said[1] ~= nil and said[1].level == "error" and contains(said[1].msg, "CPU limit"),
    "entry: as an error, with the reason", said[1] and said[1].msg)
end

-- ---------------------------------------------------------------------------
-- 6. widgets/dashboard/runtime.lua, through a connect and a flight
-- ---------------------------------------------------------------------------

do
  local API_DIR = "src/rfsuite/tasks/msp/api"
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

  local function flightCase(level, sink)
    Stubs.clearCard()
    Stubs.install(root)
    FC.install(Stubs)
    Stubs.reset()
    FC.reset()
    FC.loadReplies(API_DIR, listLuaFiles(API_DIR))
    Stubs.clearCard()
    Stubs.prefsStat = { size = 1 }
    for k, v in pairs({ ["Vbat"] = 24.6, ["Curr"] = 3.2, ["Capa"] = 850, ["Bat%"] = 74, ["Cel#"] = 6,
      ["Hspd"] = 0, ["RQly"] = 96, ["1RSS"] = -42, ["2RSS"] = -45, ["Thr%"] = 0, ["ARM"] = 0,
      ["ARMD"] = 0, ["Gov"] = 0 }) do Stubs.sensors[k] = v end
    _G.getRSSI = function() return 100 end
    Log = assert(_G.rfsuite.require("lib/log.lua"))
    begin(level, sink)
    local label = "runtime " .. level .. (sink and "" or ", no sink")

    local widget = assert(loadfile(root .. "/src/rfsuite/widgets/dashboard/runtime.lua"))()
      .new({ x = 0, y = 0, w = 800, h = 480 }, {})

    -- The preferences are read from the card during the run and may replace the table that holds
    -- the level; it is put back before every pass so the level is the case's own.
    local function passes(n)
      for _ = 1, n do
        setLevel(level)
        Stubs.tick()
        widget.refresh(widget, 0, nil)
      end
    end

    passes(400)
    check(widget.connectionReady == true, label .. ": the connection came up")
    Stubs.sensors["ARM"], Stubs.sensors["Gov"] = 1, 2
    passes(20)
    Stubs.sensors["Gov"], Stubs.sensors["Thr%"], Stubs.sensors["Hspd"] = 4, 40, 1800
    passes(40)
    Stubs.sensors["ARM"], Stubs.sensors["Gov"], Stubs.sensors["Thr%"], Stubs.sensors["Hspd"] = 0, 0, 0, 0
    passes(40)
    check(widget.state.hadInflightFlight == true, label .. ": the flight was seen", widget.state.hadInflightFlight)
    check(_G.rfsuite.preferences.general.debug_level == level, label .. ": the level held through the run")

    control("runtime " .. level, level == "off" and "info" or level)

    local connected = find("rfsuite.widget", "FBL connected and telemetry initialized")
    check(#connected >= 1, label .. ": the base-log line 'FBL connected and telemetry initialized' is present", #connected)
    local phases = find("rfsuite.widget", "phase ")
    local phaseLines = {}
    for i = 1, #phases do
      if string.match(phases[i].msg, "^phase %S+ %-> %S+") then phaseLines[#phaseLines + 1] = phases[i] end
    end
    local created = find("rfsuite.widget", "dashboard created")
    -- tasks/events/runtime.lua: the armed edge is a step, behind the flag the dashboard's pass raises.
    local armedEdge = find("rfsuite.events", "armed edge: running")
    if level == "debug" then
      check(#armedEdge >= 2, label .. ": the arm and the disarm edge are said", #armedEdge)
      check(armedEdge[1] ~= nil and armedEdge[1].level == "debug", label .. ": as debug lines", armedEdge[1] and armedEdge[1].level)
    else
      check(#armedEdge == 0, label .. ": the armed edge says nothing below debug", #armedEdge)
    end
    local built = count("rfsuite.reload", "LVGL BUILD SUCCESS")
    local resolved = count("rfsuite.reload", "resolveTheme:")

    if level == "off" then
      -- No sink and the log off: the milestones build nothing, and the base-log line is the bare
      -- sentence, without the memory figures.
      check(#phaseLines == 0, label .. ": the phase milestone builds nothing", #phaseLines)
      check(#created == 0, label .. ": the creation milestone builds nothing", #created)
      check(connected[1] ~= nil and connected[1].msg == "FBL connected and telemetry initialized",
        label .. ": the base-log line reaches the ring without memory", connected[1] and connected[1].msg)
      check(connected[1] ~= nil and connected[1].level == "info", label .. ": and it is an info line",
        connected[1] and connected[1].level)
      check(built == 0 and resolved == 0, label .. ": no build or theme lines", built .. "/" .. resolved)
    else
      check(#phaseLines >= 1, label .. ": a phase line is present", #phaseLines)
      local allKb = #phaseLines > 0
      for i = 1, #phaseLines do
        if phaseLines[i].level ~= "info" or not lua_kb(phaseLines[i].msg) then allKb = false end
      end
      check(allKb, label .. ": every 'phase a -> b' line is an info line carrying 'lua N kB'",
        phaseLines[1] and phaseLines[1].msg)
      check(#created >= 1 and lua_kb(created[1].msg), label .. ": the creation milestone carries 'lua N kB'",
        created[1] and created[1].msg)
      check(connected[1] ~= nil and contains(connected[1].msg, "FBL connected and telemetry initialized, lua ")
        and lua_kb(connected[1].msg), label .. ": the base-log line carries the memory while recording",
        connected[1] and connected[1].msg)
      if level == "info" then
        check(built == 0, label .. ": 'LVGL BUILD SUCCESS' is absent at info", built)
        check(resolved == 0, label .. ": 'resolveTheme:' is absent at info", resolved)
        check(count("rfsuite.reload", nil) == 0, label .. ": no line of the reload tag at info",
          count("rfsuite.reload", nil))
      else
        check(built >= 1, label .. ": 'LVGL BUILD SUCCESS' is present at debug", built)
        check(resolved >= 1, label .. ": 'resolveTheme:' is present at debug", resolved)
        local b = find("rfsuite.reload", "LVGL BUILD SUCCESS")[1]
        check(b ~= nil and b.level == "debug", label .. ": and it is a debug line", b and b.level)
      end
    end
  end
  flightCase("off", false)
  flightCase("info", true)
  flightCase("debug", true)
end

_G.print = realPrint
if failures > 0 then
  print(string.format("log lines: %d of %d checks failed", failures, checks))
  os.exit(1)
end
print(string.format("OK log lines: %d checks hold", checks))
