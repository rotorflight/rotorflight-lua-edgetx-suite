-- The configuration tool's start (ui/home.lua) and the compile pass (src/rfsuite/lib/precompile.lua):
-- a tree that is already compiled is not walked again, a new install still compiles everything, a
-- developer can ask for the whole walk, and the start screen does not rebuild for every file the pass
-- compiles. Runs the tool's own start on the accounting stubs, one start per case, each in a process
-- of its own so that no module state carries over:
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

-- The parent: run every case in its own interpreter and collect what each reported.
if caseArg() == nil then
  local lua = arg[-1] or "lua5.3"
  local checks, failures = 0, 0
  for i = 1, #CASES do
    local pipe = assert(io.popen(lua .. " " .. arg[0] .. " --case " .. CASES[i] .. " 2>&1"))
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

local Stubs = assert(loadfile("bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile("bin/accounting/stubs/fc.lua"))()
Stubs.clearCard()
Stubs.install("."); FC.install(Stubs); Stubs.reset(); FC.reset()
Stubs.installTool()

local function writeCard(path, text)
  if type(mkdir) == "function" then
    local parent = string.match(path, "^(.*)/[^/]+$")
    local parts = {}
    for part in string.gmatch(parent, "[^/]+") do
      parts[#parts + 1] = part
      mkdir("/" .. table.concat(parts, "/"))
    end
  end
  local f = assert(io.open(path, "w"))
  io.write(f, text)
  io.close(f)
end

local version = assert(loadfile("src/rfsuite/lib/version.lua"))().VERSION
local IDENTITY = "0123456789abcdef " .. tostring(version)

-- The card: the build identity the packager writes, sources standing beside their bytecode, and
-- for every case but a new install the stamp of the tree last compiled.
writeCard(CORE .. "/build.txt", IDENTITY .. "\n")
local SOURCES = case == "repaint" and 30 or 3
for i = 1, SOURCES do
  writeCard(CORE .. "/lib/m" .. i .. ".lua", "return {}\n")
  writeCard(CORE .. "/lib/m" .. i .. ".luac", "")
end
if case == "compiled" or case == "full" or case == "skip" then
  writeCard(USER .. "/precompiled.txt", IDENTITY)
elseif case == "changed" then
  writeCard(USER .. "/precompiled.txt", "fedcba9876543210 0.0.1")
end

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

if case == "compiled" then
  runFor(40)
  expect(listed == 0, "a compiled tree is walked again: " .. listed .. " directories listed")
  expect(Precompile ~= nil and not Precompile.isRunning(), "a compile pass runs on a compiled tree")
elseif case == "fresh" or case == "changed" then
  runFor(2)
  expect(Precompile ~= nil and Precompile.isRunning(), "no compile pass after an install")
  runFor(200)
  expect(listed > 0, "the install's pass did not walk the tree")
  local done, total = Precompile.getProgress()
  expect(total == SOURCES and done == total, "the install's pass did not compile every source: "
    .. tostring(done) .. "/" .. tostring(total))
  local f = io.open(USER .. "/precompiled.txt", "r")
  local stamp = f and io.read(f, 64)
  if f then io.close(f) end
  -- The module reads both files without their whitespace, and writes the stamp that way.
  expect(stamp == string.gsub(IDENTITY, "%s", ""), "the install's pass did not record the tree as compiled: "
    .. tostring(stamp))
elseif case == "full" then
  runFor(200)
  expect(listed > 0, "developer.precompile = \"full\" did not walk the tree")
  expect(Precompile ~= nil and not Precompile.isRunning(), "the requested walk did not finish")
elseif case == "skip" then
  runFor(40)
  expect(listed == 0, "developer.precompile = false still walked the tree")
elseif case == "repaint" then
  -- A pass compiling SOURCES files, one per run cycle: the start screen follows its count at most
  -- once a second (100 ticks, ten passes here), not once per file.
  -- The connect chain moves its own count on this screen meanwhile, so what is counted is how often
  -- the compile count the screen shows changes; every such change is a rebuild.
  runFor(4)
  local before = clears
  local compiling, shownChanges = 0, 0
  local shown = state.precompileDone
  while Precompile and Precompile.isRunning() and compiling < 400 do
    runFor(1)
    compiling = compiling + 1
    if state.precompileDone ~= shown then
      shown = state.precompileDone
      shownChanges = shownChanges + 1
    end
  end
  expect(compiling >= SOURCES - 4, "the pass ended before it compiled its files: " .. compiling .. " passes")
  expect(shownChanges <= math.floor(compiling / 10) + 2,
    "the compile count shown changed " .. shownChanges .. " times over " .. compiling .. " passes of compiling")
  expect(state.precompileDone == state.precompileTotal, "the bar did not reach its end")
  print(string.format("INFO repaint: %d rebuilds over %d passes of compiling", clears - before, compiling))
end

print("CHECKS " .. checks)
