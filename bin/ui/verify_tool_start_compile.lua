-- The configuration tool's start (ui/home.lua) and the compile pass (src/rfsuite/lib/precompile.lua):
-- a tree that is already compiled is not walked again, a new install still compiles everything and
-- connects only once that is through, a developer can ask for the whole walk or skip it, and the
-- start screen does not rebuild for every file the pass compiles. Runs the tool's own start on the
-- accounting stubs, one start per case, each in a process of its own so that no module state
-- carries over:
--   lua5.3 bin/ui/verify_tool_start_compile.lua
-- Exit status: 0 green, 1 failed expectations.

local NAME = "tool start compile"
local CORE = "/SCRIPTS/RFSUITE/core"
local WIDGET = "/WIDGETS/rfsuite"
local USER = "/SCRIPTS/RFSUITE/user"

local function caseArg()
  for i = 1, #arg do
    if arg[i] == "--case" then return arg[i + 1] end
  end
end

local CASES = { "compiled", "fresh", "changed", "full", "skip", "repaint" }

local function quote(text)
  return "'" .. string.gsub(text, "'", "'\\''") .. "'"
end

-- The parent: run every case in its own interpreter and collect what each reported.
if caseArg() == nil then
  local lua = arg[-1] or "lua5.3"
  local checks, failures = 0, 0
  for i = 1, #CASES do
    local pipe = assert(io.popen(quote(lua) .. " " .. quote(arg[0]) .. " --case " .. CASES[i] .. " 2>&1"))
    local seen = false
    for line in pipe:lines() do
      if string.sub(line, 1, 5) == "FAIL " then
        failures = failures + 1
        print(line)
      end
      local n = string.match(line, "^CHECKS (%d+)$")
      if n then
        checks = checks + tonumber(n)
        seen = true
      end
    end
    pipe:close()
    if not seen then
      failures = failures + 1
      print("FAIL case " .. CASES[i] .. ": did not report (crashed before its checks)")
    end
  end
  if failures > 0 then
    print(NAME .. ": " .. failures .. " of " .. checks .. " checks failed")
    os.exit(1)
  end
  print(NAME .. ": " .. checks .. " checks passed")
  os.exit(0)
end

-- One case.
local case = caseArg()
local checks = 0
local function expect(ok, label)
  checks = checks + 1
  if not ok then
    print("FAIL " .. case .. ": " .. label)
  end
end

local function find(fn, wanted, seen)
  seen = seen or {}
  if seen[fn] then return nil end
  seen[fn] = true
  local nested = {}
  for i = 1, 200 do
    local name, value = debug.getupvalue(fn, i)
    if not name then break end
    if name == wanted then return value end
    if type(value) == "function" then nested[#nested + 1] = value end
  end
  for i = 1, #nested do
    local found = find(nested[i], wanted, seen)
    if found ~= nil then return found end
  end
end

-- Real sources of the suite, by name: the walk lists the card, and the stubs' loader answers a
-- core path from the repository, so a card file named like a real source compiles for real.
local function realSources(count)
  local names = {}
  local pipe = assert(io.popen("ls -1 src/rfsuite/lib"))
  for name in pipe:lines() do
    if string.sub(name, -4) == ".lua" and #names < count then names[#names + 1] = name end
  end
  pipe:close()
  table.sort(names)
  return names
end

local Stubs = assert(loadfile("bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile("bin/accounting/stubs/fc.lua"))()
Stubs.clearCard()
Stubs.install("."); FC.install(Stubs); Stubs.reset(); FC.reset()
Stubs.installTool()

local function writeCard(path, text)
  local parent = string.match(path, "^(.*)/[^/]+$")
  local parts = {}
  for part in string.gmatch(parent, "[^/]+") do
    parts[#parts + 1] = part
    mkdir("/" .. table.concat(parts, "/"))
  end
  local f = assert(io.open(path, "w"))
  io.write(f, text)
  io.close(f)
end

local version = assert(loadfile("src/rfsuite/lib/version.lua"))().VERSION
local IDENTITY = "0123456789abcdef " .. tostring(version)

-- The card: the build identity the packager writes, sources standing beside their bytecode, and
-- for the cases of a compiled tree the stamp of the tree last compiled.
writeCard(CORE .. "/build.txt", IDENTITY .. "\n")
local sources = realSources(case == "repaint" and 30 or 3)
for i = 1, #sources do
  writeCard(CORE .. "/lib/" .. sources[i], "-- listed only\n")
  writeCard(CORE .. "/lib/" .. string.sub(sources[i], 1, -5) .. ".luac", "")
end
if case == "compiled" or case == "full" then
  writeCard(USER .. "/precompiled.txt", IDENTITY)
elseif case == "changed" then
  writeCard(USER .. "/precompiled.txt", "fedcba9876543210 0.0.1")
end
-- "skip" has no stamp: without the developer's skip this card would be compiled.

-- The developer section, as a pilot would put it into preferences.lua by hand.
local developer = nil
if case == "full" then developer = { precompile = "full" } end
if case == "skip" then developer = { precompile = false } end
if developer then
  local Prefs = _G.rfsuite and _G.rfsuite.require and _G.rfsuite.require("lib/preferences.lua")
  assert(type(Prefs) == "table" and type(Prefs.load) == "function", "preferences module missing")
  local load = Prefs.load
  Prefs.load = function(...)
    local prefs = load(...)
    if type(prefs) == "table" then prefs.developer = developer end
    return prefs
  end
end

-- What the walk lists: every dir() call under the two roots it starts from.
local listed = 0
local realDir = _G.dir
_G.dir = function(path)
  if type(path) == "string" and (string.sub(path, 1, #CORE) == CORE or string.sub(path, 1, #WIDGET) == WIDGET) then
    listed = listed + 1
  end
  return realDir(path)
end

-- Every rebuild of the start screen clears the screen first.
local clears = 0
local realClear = lvgl.clear
lvgl.clear = function(...)
  clears = clears + 1
  return realClear(...)
end

-- The pass's own account of itself, from the log ring.
local function passLine()
  for _, entry in ipairs(_G.rfsuite.log_history or {}) do
    if entry.tag == "rfsuite.precompile" and string.find(entry.msg, "pass done:", 1, true) then
      return entry.msg
    end
  end
end

local Home = assert(loadfile("src/rfsuite/ui/home.lua"))()
Home.init({})
local state = assert(find(Home.run, "state"), "home state missing")

local function runFor(passes)
  for _ = 1, passes do
    Stubs.tick()
    Home.run(0)
  end
end

local Precompile = find(Home.run, "Precompile")

-- Runs until the pass has finished; true when it did within the limit. Records whether the tool
-- attached to the flight controller's message runtime while the pass was still running.
local attachedDuringPass = false
local function runPass(limit)
  for _ = 1, limit do
    if not (Precompile and Precompile.isRunning()) then return true end
    runFor(1)
    if Precompile.isRunning() and state.mspAttached then attachedDuringPass = true end
  end
  return not (Precompile and Precompile.isRunning())
end

if case == "compiled" then
  for _ = 1, 200 do
    if not state.initialLoad then break end
    runFor(1)
  end
  -- The tool attaches on its first pass behind the menu; with nothing to compile the start screen
  -- is already gone before that pass.
  runFor(3)
  expect(listed == 0, "a compiled tree is walked again: " .. listed .. " directories listed")
  expect(Precompile ~= nil and not Precompile.isRunning(), "a compile pass runs on a compiled tree")
  expect(state.mspAttached == true, "the tool did not attach to the message runtime (control)")
  local left = nil
  for _, entry in ipairs(_G.rfsuite.log_history or {}) do
    if entry.tag == "rfsuite.ui" and string.find(entry.msg, "start screen left after", 1, true) then left = entry.msg end
  end
  expect(left ~= nil and state.initialLoad == false, "the start screen's end is not in the log: " .. tostring(left))
  local said = false
  for _, entry in ipairs(_G.rfsuite.log_history or {}) do
    if entry.tag == "rfsuite.ui" and string.find(entry.msg, "compile pass: none", 1, true) then said = true end
  end
  expect(said, "the tool does not say that no compile pass was needed")
elseif case == "fresh" or case == "changed" then
  runFor(1)
  expect(Precompile ~= nil and Precompile.isRunning(), "no compile pass after an install")
  expect(runPass(300), "the install's pass did not finish")
  expect(listed > 0, "the install's pass did not walk the tree")
  local line = passLine() or "(no line)"
  local n = #sources
  expect(string.find(line, string.format("%d checked, %d compiled, 0 failed", n, n), 1, true) ~= nil,
    "the install's pass did not compile every source: " .. line)
  local f = io.open(USER .. "/precompiled.txt", "r")
  local stamp = f and io.read(f, 64)
  if f then io.close(f) end
  -- The module reads both files without their whitespace, and writes the stamp that way.
  expect(stamp == string.gsub(IDENTITY, "%s", ""), "the install's pass did not record the tree as compiled: "
    .. tostring(stamp))
  expect(not attachedDuringPass, "the tool attached to the message runtime while the pass was running")
  runFor(3)
  expect(state.mspAttached == true, "the tool did not attach once the pass was through")
elseif case == "full" then
  expect(runPass(300), "the requested walk did not finish")
  expect(listed > 0, "developer.precompile = \"full\" did not walk the tree")
  local line = passLine() or "(no line)"
  expect(string.find(line, "0 compiled, 0 failed, not forced", 1, true) ~= nil,
    "the requested walk on a compiled tree is not an unforced one: " .. line)
elseif case == "skip" then
  runFor(40)
  expect(listed == 0, "developer.precompile = false still walked the tree")
elseif case == "repaint" then
  -- A pass compiling thirty files, one per run cycle: the start screen follows its count at most
  -- once a second (100 ticks, ten passes here), not once per file. Every change of the count shown
  -- is a rebuild; the connection is held meanwhile, so nothing else rebuilds the screen.
  local before = clears
  local compiling = 0
  local shownChanges = 0
  local shown = state.precompileDone
  while Precompile and Precompile.isRunning() and compiling < 400 do
    runFor(1)
    compiling = compiling + 1
    if state.precompileDone ~= shown then
      shown = state.precompileDone
      shownChanges = shownChanges + 1
    end
  end
  local rebuilt = clears - before
  expect(not Precompile.isRunning(), "the pass did not finish")
  expect(compiling >= #sources, "the pass ended before it compiled its files: " .. compiling .. " passes")
  expect(shownChanges <= math.floor(compiling / 10) + 2,
    "the compile count shown changed " .. shownChanges .. " times over " .. compiling .. " passes of compiling")
  expect(rebuilt <= math.floor(compiling / 10) + 4,
    "the start screen rebuilt " .. rebuilt .. " times over " .. compiling .. " passes of compiling")
  expect(state.precompileDone == state.precompileTotal, "the count shown did not reach its end")
  local left = false
  for _ = 1, 400 do
    runFor(1)
    if not state.initialLoad then left = true break end
  end
  expect(left, "the start screen did not leave after the pass")
  print(string.format("INFO repaint: %d rebuilds over %d passes of compiling", rebuilt, compiling))
end

print("CHECKS " .. checks)
