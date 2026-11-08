-- Checks the start-up compile pass (src/rfsuite/lib/precompile.lua) across consecutive starts,
-- offline:
--
--   lua5.3 bin/package/verify_precompile.lua
--   lua5.3 bin/package/verify_precompile.lua --verbose
--   lua5.3 bin/package/verify_precompile.lua --module <pre-fix-precompile.lua>
--
-- The last form runs the same expectations against another copy of the module, so a pre-fix
-- source can prove the checks go red without changing the working tree.
--
-- The SD card is an in-memory file system written for this check rather than the accounting
-- stubs: those create missing parent folders on a write-open, and whether a missing folder is
-- created is exactly what one of the cases is about. Like the radio, io.open(path, "w") here
-- fails when the parent folder does not exist, mkdir() creates one level, and a successful
-- compile writes the .luac with the timestamp of its source. A source compiles when the desktop
-- Lua can parse it. These are controlled card states, not a timing measurement.
-- Exit status: 0 green, 1 failed expectations, 2 invalid arguments.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]package$") or (dir .. "/../..") end
end

local modulePath = ROOT .. "/src/rfsuite/lib/precompile.lua"
local verbose = false
local i = 1
while i <= #arg do
  if arg[i] == "--verbose" then
    verbose = true
  elseif arg[i] == "--module" and arg[i + 1] then
    i = i + 1
    modulePath = arg[i]
  else
    io.stderr:write("usage: lua5.3 bin/package/verify_precompile.lua [--verbose] [--module <file>]\n")
    os.exit(2)
  end
  i = i + 1
end

local hostIo = io
local moduleSource
do
  local f = hostIo.open(modulePath, "rb")
  if not f then
    hostIo.stderr:write("cannot read " .. modulePath .. "\n")
    os.exit(2)
  end
  moduleSource = f:read("a")
  f:close()
end

local CORE = "/SCRIPTS/RFSUITE/core"
local WIDGET = "/WIDGETS/rfsuite"
local USER = "/SCRIPTS/RFSUITE/user"
local IDENTITY = "0123456789abcdef 0.2.0"

-- The first bytes of a macOS AppleDouble file: binary, and no Lua source.
local APPLEDOUBLE = "\0\5\22\7\0\2\0\0Mac OS X        \0\2\0\0\0\9\0\0\0\50"

local VALID = "local M = {}\nreturn M\n"
local BROKEN = "local M = {\nreturn M\n"

-- A card: folders, files with a modification time, and a clock that moves one second per write.
local function newCard()
  local card = { dirs = {}, files = {}, clock = 1000, mkdirAvailable = true }

  function card.now()
    card.clock = card.clock + 1
    return card.clock
  end

  function card.addDir(path)
    local parts = {}
    for part in string.gmatch(path, "[^/]+") do
      parts[#parts + 1] = part
      card.dirs["/" .. table.concat(parts, "/")] = true
    end
  end

  function card.put(path, data, time)
    card.addDir(string.match(path, "^(.*)/[^/]+$"))
    card.files[path] = { data = data, time = time or card.now() }
  end

  return card
end

-- A card with the suite unpacked onto it, as the release archive leaves it: sources only, the
-- build identity beside the core, no user folder.
local function installedCard()
  local card = newCard()
  card.addDir("/SCRIPTS/TOOLS")
  card.put(CORE .. "/build.txt", IDENTITY .. "\n", 100)
  card.put(CORE .. "/init.lua", VALID, 100)
  card.put(WIDGET .. "/main.lua", VALID, 100)
  return card
end

local function timeTable(seconds)
  -- Six fields, as fstat answers; only the order matters to the module.
  return {
    year = 2026, mon = 10, day = 22,
    hour = seconds // 3600 % 24, min = seconds // 60 % 60, sec = seconds % 60,
  }
end

-- Installs the radio's globals for one start and returns what the start recorded.
local function installGlobals(card)
  local record = { loads = {}, warnings = {}, notes = {} }

  local function parentOf(path)
    return string.match(path, "^(.*)/[^/]+$")
  end

  _G.dir = function(path)
    if not card.dirs[path] then
      error("no such folder " .. path)
    end
    local names, seen = {}, {}
    local prefix = path .. "/"
    for p in pairs(card.dirs) do
      local rest = string.sub(p, 1, #prefix) == prefix and string.sub(p, #prefix + 1) or nil
      if rest and rest ~= "" and not string.find(rest, "/", 1, true) and not seen[rest] then
        seen[rest] = true
        names[#names + 1] = rest
      end
    end
    for p in pairs(card.files) do
      if parentOf(p) == path then
        names[#names + 1] = string.sub(p, #prefix + 1)
      end
    end
    table.sort(names)
    local n = 0
    return function()
      n = n + 1
      return names[n]
    end
  end

  _G.fstat = function(path)
    local file = card.files[path]
    if not file then
      return nil
    end
    return { size = #file.data, time = timeTable(file.time) }
  end

  if card.mkdirAvailable then
    _G.mkdir = function(path)
      if card.dirs[path] then
        error("exists")
      end
      if not card.dirs[parentOf(path)] then
        error("no parent")
      end
      card.dirs[path] = true
    end
  else
    _G.mkdir = nil
  end

  _G.io = {
    open = function(path, mode)
      if mode == "r" then
        local file = card.files[path]
        return file and { data = file.data, pos = 1 } or nil
      end
      if mode == "w" then
        if not card.dirs[parentOf(path)] then
          return nil
        end
        return { path = path, out = {} }
      end
      return nil
    end,
    read = function(f, n)
      local chunk = string.sub(f.data, f.pos, f.pos + n - 1)
      f.pos = f.pos + #chunk
      return chunk
    end,
    write = function(f, s)
      f.out[#f.out + 1] = s
    end,
    close = function(f)
      if f.path then
        card.files[f.path] = { data = table.concat(f.out), time = card.now() }
      end
    end,
  }

  _G.rfsuite = {
    utils = {
      loadScriptUncached = function(path, mode)
        record.loads[#record.loads + 1] = path
        local file = card.files[path]
        if not file then
          return nil, "not found"
        end
        local chunk, err = load(file.data, "=" .. path, "t")
        if not chunk then
          return nil, err
        end
        card.files[path .. "c"] = { data = "bytecode", time = file.time }
        return chunk
      end,
    },
  }
  _G.rfsuite.paths = dofile(ROOT .. "/src/rfsuite/lib/paths.lua")

  -- The suite's own logger, so a line is judged as the log page keeps it: the ring truncates
  -- what it stores, and a stub that kept the whole line would hide that.
  local hostPrint = print
  _G.print = function() end
  assert(loadfile(ROOT .. "/src/rfsuite/lib/log.lua", "t", _G))()
  _G.print = hostPrint

  return record
end

-- One start of the configuration tool: a fresh module, run until it reports finished.
local function launch(card)
  local record = installGlobals(card)
  local chunk = assert(load(moduleSource, "=" .. modulePath, "t", _G))
  local Precompile = chunk()
  local hostPrint = print
  _G.print = function() end
  Precompile.start("0.2.0")
  local steps = 0
  while true do
    Precompile.step()
    steps = steps + 1
    local _, _, finished = Precompile.getProgress()
    if finished or steps > 10000 then
      break
    end
  end
  _G.print = hostPrint
  _G.io = hostIo
  for _, entry in ipairs(_G.rfsuite.log_history or {}) do
    if entry.tag == "rfsuite.precompile" then
      -- What the pass reports as a fault is a warning; its account of itself (how much it checked
      -- and compiled, and why) is kept apart, so a clean pass still reports nothing.
      local list = (entry.level == "warn" or entry.level == "error") and record.warnings or record.notes
      list[#list + 1] = entry.level .. " " .. entry.msg
    end
  end
  return record
end

local failures = 0

local function check(name, ok, detail)
  if ok then
    if verbose then print("ok    " .. name) end
  else
    failures = failures + 1
    print("FAIL  " .. name .. (detail and (": " .. detail) or ""))
  end
end

local function hasNote(record, text)
  for _, line in ipairs(record.notes) do
    if string.find(line, text, 1, true) then
      return true
    end
  end
  return false
end

local function hasWarning(record, text)
  for _, line in ipairs(record.warnings) do
    if string.find(line, text, 1, true) then
      return true
    end
  end
  return false
end

-- Fresh install, no user folder: the first start compiles everything and leaves the stamp, the
-- second compiles nothing.
do
  local card = installedCard()
  local first = launch(card)
  local second = launch(card)
  check("fresh install: first start compiles both sources", #first.loads == 2, #first.loads .. " loads")
  check("fresh install: the user folder is created", card.dirs[USER] == true)
  check("fresh install: the stamp is written", card.files[USER .. "/precompiled.txt"] ~= nil)
  check("fresh install: second start compiles nothing", #second.loads == 0, #second.loads .. " loads")
  check("fresh install: nothing is reported", #first.warnings == 0 and #second.warnings == 0,
    table.concat(first.warnings, "; ") .. table.concat(second.warnings, "; "))
  check("fresh install: the first pass accounts for itself, forced for want of a stamp",
    hasNote(first, "pass done: 2 checked, 2 compiled, 0 failed, forced: no stamp"),
    table.concat(first.notes, "; "))
  check("fresh install: the second pass accounts for itself, not forced",
    hasNote(second, "pass done: 2 checked, 0 compiled, 0 failed, not forced"),
    table.concat(second.notes, "; "))
end

-- The same with the user folder already there: unchanged behaviour.
do
  local card = installedCard()
  card.addDir(USER)
  local first = launch(card)
  local second = launch(card)
  check("existing user folder: first start compiles both sources", #first.loads == 2, #first.loads .. " loads")
  check("existing user folder: second start compiles nothing", #second.loads == 0, #second.loads .. " loads")
end

-- A card where the folder cannot be created: the pass still finishes, and says that its stamp
-- did not land instead of staying silent.
do
  local card = installedCard()
  card.mkdirAvailable = false
  local first = launch(card)
  check("stamp not writable: the first start compiles both sources", #first.loads == 2, #first.loads .. " loads")
  check("stamp not writable: the failed write is reported", hasWarning(first, "precompiled.txt"),
    table.concat(first.warnings, "; "))
end

-- A card the pass has already finished on: current bytecode beside every source, and the stamp.
local function compiledCard()
  local card = installedCard()
  card.addDir(USER)
  card.put(USER .. "/precompiled.txt", IDENTITY)
  card.put(CORE .. "/init.luac", "bytecode", 100)
  card.put(WIDGET .. "/main.luac", "bytecode", 100)
  return card
end

-- Copied from macOS: an AppleDouble file beside each source. Neither start queues them.
do
  local card = compiledCard()
  card.put(CORE .. "/._init.lua", APPLEDOUBLE, 100)
  card.put(WIDGET .. "/._main.lua", APPLEDOUBLE, 100)
  card.put(CORE .. "/._build.txt", APPLEDOUBLE, 100)
  local first = launch(card)
  local second = launch(card)
  check("AppleDouble files: first start loads nothing", #first.loads == 0,
    table.concat(first.loads, ", "))
  check("AppleDouble files: second start loads nothing", #second.loads == 0,
    table.concat(second.loads, ", "))
  check("AppleDouble files: nothing is reported", #first.warnings == 0 and #second.warnings == 0,
    table.concat(first.warnings, "; ") .. table.concat(second.warnings, "; "))
end

-- The filter leaves real sources to the existing checks: a new source and one changed after its
-- bytecode are compiled, beside AppleDouble files, and then left alone.
do
  local card = compiledCard()
  card.put(CORE .. "/._init.lua", APPLEDOUBLE, 100)
  card.put(CORE .. "/added.lua", VALID, 200)
  card.put(WIDGET .. "/main.lua", VALID, 300)
  local first = launch(card)
  local second = launch(card)
  local loaded = table.concat(first.loads, ", ")
  check("real sources beside AppleDouble: the new and the changed source are compiled",
    #first.loads == 2 and string.find(loaded, "added.lua", 1, true) and string.find(loaded, "main.lua", 1, true),
    loaded)
  check("real sources beside AppleDouble: then nothing", #second.loads == 0, table.concat(second.loads, ", "))
end

-- A real source that does not compile is still tried on every start, and is now reported once per
-- start, naming the file, instead of passing for finished preparation.
do
  local card = compiledCard()
  card.put(CORE .. "/broken.lua", BROKEN, 200)
  local first = launch(card)
  check("broken source: it is tried", #first.loads == 1, #first.loads .. " loads")
  check("broken source: one warning", #first.warnings == 1, table.concat(first.warnings, "; "))
  check("broken source: the warning names the file", hasWarning(first, "broken.lua"),
    table.concat(first.warnings, "; "))
end

-- The log ring keeps the first 100 characters of a line, and the longest page path in the tree
-- is 73: the file has to come first for the warning to name it.
do
  local deep = "app/pages/flight_tuning/advanced/rates_advanced/cyclic_behaviour/page.lua"
  local card = compiledCard()
  card.put(CORE .. "/" .. deep, BROKEN, 200)
  local first = launch(card)
  check("deep broken source: the stored warning names the whole path", hasWarning(first, deep),
    table.concat(first.warnings, "; "))
end

-- The widgets' side: a widget state where the dashboard, the service widget and the tool opened
-- from the dashboard share one copy of the module. Returns the module, what the start recorded,
-- a function that moves the radio's clock on by one tick, and one that puts the host back.
local function widgetState(card, withLoader)
  local record = installGlobals(card)
  if not withLoader then
    _G.rfsuite.utils = {}
  end
  local tick = 0
  _G.getTime = function() return tick end
  local chunk = assert(load(moduleSource, "=" .. modulePath, "t", _G))
  local Precompile = chunk()
  local hostPrint = print
  _G.print = function() end
  local function advance() tick = tick + 1 end
  local function close()
    _G.print = hostPrint
    _G.io = hostIo
    _G.getTime = nil
  end
  return Precompile, record, advance, close
end

local function hasWidgetApi(Precompile)
  return type(Precompile.startIfStale) == "function" and type(Precompile.stepShared) == "function"
    and type(Precompile.isRunning) == "function"
end

-- Drives a shared pass the way the widgets do, one unit per clock tick, until it ends.
local function driveShared(Precompile, advance)
  local steps = 0
  while Precompile.isRunning() and steps < 10000 do
    Precompile.stepShared()
    advance()
    steps = steps + 1
  end
end

-- Folders of pictures: the colour schemes ship each tile icon once per scheme, a hundred-odd pictures to
-- a folder. A picture costs no timestamp, so the entry loop used to take a whole folder in one call. Every
-- widget call of the pass is counted in the module's own instructions (the card's dir() here is a test
-- stand-in and is left out), and the most expensive one has to stay well under the widget's limit.
do
  local card = installedCard()
  local folders = { { "app/icons/light", 113 }, { "app/icons/dark", 113 },
    { "widgets/dashboard/theme_icons/light", 90 }, { "widgets/dashboard/theme_icons/dark", 90 } }
  for _, folder in ipairs(folders) do
    for n = 1, folder[2] do
      card.put(string.format("%s/%s/setup_esc_motors_esc_tools_escmfg_%03d_icon.png", CORE, folder[1], n), "png", 100)
    end
  end
  local Precompile, record, advance, close = widgetState(card, true)
  local source = "=" .. modulePath
  local worst, steps = 0, 0
  if hasWidgetApi(Precompile) and Precompile.startIfStale("0.2.0") then
    while Precompile.isRunning() and steps < 10000 do
      local n = 0
      debug.sethook(function()
        local info = debug.getinfo(2, "S")
        if info and info.source == source then n = n + 1 end
      end, "", 1)
      Precompile.stepShared()
      debug.sethook()
      if n > worst then worst = n end
      advance()
      steps = steps + 1
    end
  end
  close()
  check("picture folders: the pass finishes and compiles both sources", #record.loads == 2,
    #record.loads .. " loads, " .. steps .. " steps")
  check("picture folders: no call takes more than 6000 of the module's instructions", worst > 0 and worst <= 6000,
    "worst call " .. worst)
end

-- After an install the widgets run the whole pass, and it leaves the stamp the tool reads.
do
  local card = installedCard()
  local Precompile, record, advance, close = widgetState(card, true)
  local api = hasWidgetApi(Precompile)
  local started = api and Precompile.startIfStale("0.2.0")
  if started then driveShared(Precompile, advance) end
  close()
  check("widget after install: the module offers the shared entry points", api)
  check("widget after install: a pass starts", started == true)
  check("widget after install: both sources are compiled", #record.loads == 2, #record.loads .. " loads")
  check("widget after install: the stamp is written", card.files[USER .. "/precompiled.txt"] ~= nil)
  local second = launch(card)
  check("widget after install: the tool's next start compiles nothing", #second.loads == 0,
    #second.loads .. " loads")
end

-- A tree already compiled: no pass, no walk, nothing loaded, so the connection is not held.
do
  local card = compiledCard()
  card.put(CORE .. "/added.lua", VALID, 200)
  local Precompile, record, _, close = widgetState(card, true)
  local api = hasWidgetApi(Precompile)
  local started = api and Precompile.startIfStale("0.2.0")
  local running = api and Precompile.isRunning()
  close()
  check("widget on a compiled tree: no pass starts", api and started == false and running == false)
  check("widget on a compiled tree: nothing is loaded, a new source is left to the tool",
    #record.loads == 0, table.concat(record.loads, ", "))
end

-- A tree without the packager's build identity, started the way the widgets start it (no version
-- to fall back on): nothing starts, so a hand-copied source tree never holds the connection.
do
  local card = installedCard()
  card.files[CORE .. "/build.txt"] = nil
  local Precompile, record, _, close = widgetState(card, true)
  local api = hasWidgetApi(Precompile)
  local started = api and Precompile.startIfStale(nil)
  close()
  check("widget without a build identity: no pass starts", api and started == false)
  check("widget without a build identity: nothing is loaded", #record.loads == 0, #record.loads .. " loads")
end

-- Without the uncached loader nothing could be compiled, so nothing starts and no stamp claims the
-- tree compiled.
do
  local card = installedCard()
  local Precompile, record, _, close = widgetState(card, false)
  local api = hasWidgetApi(Precompile)
  local started = api and Precompile.startIfStale("0.2.0")
  close()
  check("widget without a loader: no pass starts", api and started == false)
  check("widget without a loader: no stamp is written", card.files[USER .. "/precompiled.txt"] == nil)
  check("widget without a loader: nothing is loaded", #record.loads == 0, #record.loads .. " loads")
end

-- The tool opened from the dashboard while the pass runs joins it: what was compiled is not
-- compiled again, and the pass still ends with the stamp.
do
  local card = installedCard()
  local Precompile, record, advance, close = widgetState(card, true)
  local api = hasWidgetApi(Precompile)
  local joined = false
  if api and Precompile.startIfStale("0.2.0") then
    while Precompile.isRunning() and #record.loads < 1 do
      Precompile.stepShared()
      advance()
    end
    local doneBefore = Precompile.getProgress()
    Precompile.start("0.2.0")
    local doneAfter = Precompile.getProgress()
    joined = doneBefore == 1 and doneAfter == 1
    driveShared(Precompile, advance)
  end
  close()
  check("tool joining a running pass: its progress is kept", joined)
  check("tool joining a running pass: each source is compiled once", #record.loads == 2,
    table.concat(record.loads, ", "))
  check("tool joining a running pass: the stamp is written", card.files[USER .. "/precompiled.txt"] ~= nil)
end

-- Two callers in the same clock tick take one unit between them: the tool's step and a widget's
-- shared step, then two shared steps.
do
  local card = installedCard()
  local Precompile, record, advance, close = widgetState(card, true)
  local api = hasWidgetApi(Precompile)
  local afterStep, afterShared, nextTick = -1, -1, -1
  if api and Precompile.startIfStale("0.2.0") then
    -- Walk the tree first, so that every unit after it compiles exactly one file.
    while select(2, Precompile.getProgress()) < 2 do
      Precompile.step()
      advance()
    end
    Precompile.step()
    afterStep = #record.loads
    Precompile.stepShared()
    Precompile.stepShared()
    afterShared = #record.loads
    advance()
    Precompile.stepShared()
    nextTick = #record.loads
  end
  close()
  check("callers sharing a tick: a shared step after the tool's step does nothing",
    afterStep == 1 and afterShared == 1, afterStep .. " then " .. afterShared)
  check("callers sharing a tick: the next tick takes the next unit", nextTick == 2, tostring(nextTick))
end

-- A pass that rebuilt the whole tree asks for a restart of the radio, because a state that loaded
-- modules before it keeps running them; one that only filled in a source does not, and neither
-- does one whose stamp did not land -- the next start would compile everything and ask again.
local function needsRestartAfter(card, starter)
  local Precompile, _, advance, close = widgetState(card, true)
  local answer = nil
  if type(Precompile.needsRestart) == "function" then
    starter(Precompile)
    driveShared(Precompile, advance)
    answer = Precompile.needsRestart()
  end
  close()
  return answer
end

do
  local rebuilt = needsRestartAfter(installedCard(), function(P) P.startIfStale("0.2.0") end)
  check("restart: asked after a pass that rebuilt the tree", rebuilt == true, tostring(rebuilt))

  local card = compiledCard()
  card.put(CORE .. "/added.lua", VALID, 200)
  local filled = needsRestartAfter(card, function(P) P.start("0.2.0") end)
  check("restart: not asked after a pass that only filled in a source", filled == false, tostring(filled))

  local unpackaged = installedCard()
  unpackaged.files[CORE .. "/build.txt"] = nil
  local bare = needsRestartAfter(unpackaged, function(P) P.start("0.2.0") end)
  check("restart: not asked for a tree without the packager's build identity", bare == false, tostring(bare))

  local unwritable = installedCard()
  unwritable.mkdirAvailable = false
  local noStamp = needsRestartAfter(unwritable, function(P) P.startIfStale("0.2.0") end)
  check("restart: not asked when the stamp could not be written", noStamp == false, tostring(noStamp))
end

if failures > 0 then
  print(string.format("%d expectation(s) failed against %s", failures, modulePath))
  os.exit(1)
end
print("precompile: all expectations hold against " .. modulePath)
