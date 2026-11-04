-- Checks the move of the pilot's data to the new user folder (src/rfsuite/lib/user_move.lua,
-- lib/precompile.lua, lib/require.lua) across consecutive starts, offline:
--
--   lua5.3 bin/core/verify_user_move.lua
--
-- The SD card is an in-memory file system: io.open(path, "w") fails when the parent folder does
-- not exist, mkdir() creates one level, and a write can be made to fail or to go wrong. Only the
-- real modules decide anything. A card state, not a timing measurement.
-- Exit status: 0 green, 1 failed expectations.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir_ = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir_ then ROOT = string.match(dir_, "^(.*)[/\\]bin[/\\]core$") or (dir_ .. "/../..") end
end

local failures = 0
local function expect(label, ok)
  if not ok then
    failures = failures + 1
    print("FAIL " .. label)
  end
end

local CORE = "/SCRIPTS/RFSUITE/core"
local NEW = "/SCRIPTS/RFSUITE/user"
local OLD = "/SCRIPTS/TOOLS/rfsuite.user"

local realOpen = io.open

local function newCard()
  local card = { dirs = {}, files = {}, full = false, garble = nil, opened = 0 }
  function card.addDir(path)
    local parts = {}
    for part in string.gmatch(path, "[^/]+") do
      parts[#parts + 1] = part
      card.dirs["/" .. table.concat(parts, "/")] = true
    end
  end
  function card.put(path, data)
    card.addDir(string.match(path, "^(.*)/[^/]+$"))
    card.files[path] = data
  end
  return card
end

-- The radio's filesystem globals and io over one card. The Lua sources of the suite come from the
-- repository; everything else is on the card.
local function install(card)
  _G.fstat = function(path)
    if card.files[path] then return { size = #card.files[path], attrib = 32 } end
    if card.dirs[path] then return { size = 0, attrib = 16 } end
    return nil
  end
  _G.mkdir = function(path)
    if card.dirs[path] then return 8 end
    local parent = string.match(path, "^(.*)/[^/]+$")
    if parent ~= "" and not card.dirs[parent] then return 5 end
    card.dirs[path] = true
    return 0
  end
  _G.del = function(path)
    if card.files[path] then card.files[path] = nil; return 0 end
    return 4
  end
  _G.rename = function(from, to)
    if card.noRename then return 7 end
    if card.files[to] then return 8 end
    if not card.files[from] then return 4 end
    card.files[to], card.files[from] = card.files[from], nil
    return 0
  end
  _G.dir = function(path)
    if card.noList == path then error("cannot list " .. path) end
    local names, prefix = {}, path .. "/"
    for _, map in ipairs({ card.files, card.dirs }) do
      for full in pairs(map) do
        if string.sub(full, 1, #prefix) == prefix then
          local rest = string.sub(full, #prefix + 1)
          if not string.find(rest, "/", 1, true) then names[#names + 1] = rest end
        end
      end
    end
    table.sort(names)
    local i = 0
    return function() i = i + 1; return names[i] end
  end

  io.open = function(path, mode)
    if mode == "w" then
      local parent = string.match(path, "^(.*)/[^/]+$")
      if not card.dirs[parent] then return nil end
      if card.full and path ~= nil and string.find(path, NEW, 1, true) == 1 then return nil end
      card.files[path] = ""
      return { path = path, write = true }
    end
    if card.files[path] == nil then return nil end
    return { path = path, pos = 1 }
  end
  io.close = function() end
  io.read = function(f, n)
    local data = card.files[f.path] or ""   -- another state took the file away under this handle
    local chunk = string.sub(data, f.pos, f.pos + n - 1)
    f.pos = f.pos + #chunk
    return chunk
  end
  io.write = function(f, text)
    if card.garble and f.path == card.garble then text = string.upper(text) end
    if card.files[f.path] == nil then return f end   -- another state took the file away under this handle
    card.files[f.path] = card.files[f.path] .. text
    return f
  end
end

local function loadSource(rel)
  local f = assert(realOpen(ROOT .. "/src/rfsuite/" .. rel, "rb"))
  local source = f:read("a")
  f:close()
  return assert(load(source, "@" .. rel))
end

-- A start of one Lua state: the real lib/require.lua decides the folder, the real lib/precompile.lua
-- runs. The compile walk finds a tree of one source.
local function startState(card, opts)
  opts = opts or {}
  _G.rfsuite = { utils = {}, paths = nil, modules = {} }
  _G.getTime = function() return card.uptime or 100 end
  _G.loadScript = function(path)
    local rel = string.sub(path, #CORE + 2)
    if card.files[path] and rel ~= "lib/paths.lua" then return function() return {} end end
    return loadSource(rel)
  end
  loadSource("lib/require.lua")()
  _G.rfsuite.utils.loadScriptUncached = _G.loadScript
  local pre = loadSource("lib/precompile.lua")()
  return pre
end

local function run(pre, limit, stopAfter)
  local steps = 0
  while pre.isRunning() and steps < (limit or 100000) do
    pre.step()
    steps = steps + 1
    if stopAfter and steps >= stopAfter then return steps end
  end
  return steps
end

local BIG = string.rep("0123456789", 700)

local function oldCard()
  local card = newCard()
  card.put(CORE .. "/build.txt", "build-2\n")
  card.put(CORE .. "/init.lua", "return {}\n")
  card.put(OLD .. "/precompiled.txt", "build-1")
  card.put(OLD .. "/preferences.lua", "prefs")
  card.put(OLD .. "/3b0049.lua", "board")
  card.put(OLD .. "/3b0049.inflight.lua", "baseline")
  card.put(OLD .. "/model_name_restore.lua", "names")
  card.put(OLD .. "/flightlog/flights.csv", BIG)
  card.put(OLD .. "/flightlog/batteries.cfg.new", "cut short")
  card.put(OLD .. "/flightlog/batteries.cfg", "id=1")
  card.put(OLD .. "/dashboard/mine/init.lua", "theme")
  card.put(OLD .. "/dashboard/mine/init.luac", "bytecode")
  card.put(OLD .. "/tune/3b0049.lua", "tune")
  card.put(OLD .. "/journal/3b0049.lua", "journal")
  card.put(OLD .. "/logs/run.log", "debug")
  card.put(OLD .. "/reload.req", "1")
  card.put(OLD .. "/notes_of_the_pilot.txt", "mine")
  return card
end

local function snapshotOld(card)
  local copy = {}
  for path, data in pairs(card.files) do
    if string.sub(path, 1, #OLD) == OLD then copy[path] = data end
  end
  return copy
end

local function sameOld(card, snap, ignore)
  for path, data in pairs(snap) do
    if card.files[path] ~= data and path ~= ignore then return false end
  end
  return true
end

-- 1. A card updated by unpacking: everything named moves, nothing else, the old folder stays.
do
  local card = oldCard()
  install(card)
  local before = snapshotOld(card)
  local pre = startState(card)
  expect("old card: the state keeps using the old folder", rfsuite.paths.user == OLD)
  expect("old card: the move is pending", rfsuite.paths.moveTo == NEW)
  expect("old card: the widget's way in holds the connection", pre.startIfStale(nil) == true)
  expect("old card: the connection waits", pre.runsBehindConnection() == false)
  local _, total = 0, 0
  run(pre, 100000, 40)
  _, total = pre.getProgress()
  expect("old card: progress counts kilobytes while the data moves", total >= 13)
  run(pre)
  expect("old card: the pass ends", not pre.isRunning())
  expect("old card: a restart is asked for", pre.needsRestart() == true)
  for _, rel in ipairs({ "/preferences.lua", "/3b0049.lua", "/3b0049.inflight.lua", "/model_name_restore.lua",
                         "/flightlog/flights.csv", "/flightlog/batteries.cfg", "/dashboard/mine/init.lua",
                         "/tune/3b0049.lua", "/journal/3b0049.lua" }) do
    expect("old card: copied " .. rel, card.files[NEW .. rel] == card.files[OLD .. rel])
  end
  expect("old card: the compile stamp travels with the move", card.files[NEW .. "/precompiled.txt"] == "build-2")
  expect("old card: debug logs stay behind", card.files[NEW .. "/logs/run.log"] == nil)
  expect("old card: reload.req stays behind", card.files[NEW .. "/reload.req"] == nil)
  expect("old card: an unknown file stays behind", card.files[NEW .. "/notes_of_the_pilot.txt"] == nil)
  expect("old card: bytecode stays behind", card.files[NEW .. "/dashboard/mine/init.luac"] == nil)
  expect("old card: the marker is written", card.files[NEW .. "/moved.txt"] ~= nil)
  expect("old card: the data counts as moved", pre.movedTheData() == true)
  expect("old card: the connection stays held until the restart", pre.holdsConnectionForMove() == true)
  for path in pairs(card.files) do
    expect("old card: no .new file is left: " .. path,
      string.sub(path, 1, #NEW) ~= NEW or not string.find(path, ".new", 1, true))
  end
  expect("old card: a save cut short stays behind", card.files[NEW .. "/flightlog/batteries.cfg.new"] == nil)
  expect("old card: the old folder is untouched but for the stamp",
    sameOld(card, before, OLD .. "/precompiled.txt"))

  -- The next start uses the new folder and has nothing to do.
  local again = startState(card)
  expect("after the move: the new folder counts", rfsuite.paths.user == NEW)
  expect("after the move: nothing is pending", rfsuite.paths.moveTo == nil)
  expect("after the move: no pass, no recompile", again.startIfStale(nil) == false)
  expect("after the move: the old folder is still there", card.files[OLD .. "/preferences.lua"] == "prefs")
end

-- 2. A fresh card: no old folder, nothing pending, and no job.
do
  local card = newCard()
  card.put(CORE .. "/init.lua", "return {}\n")
  install(card)
  local pre = startState(card)
  expect("fresh card: the new folder counts", rfsuite.paths.user == NEW)
  expect("fresh card: nothing is pending", rfsuite.paths.moveTo == nil)
  expect("fresh card without a build identity: no pass", pre.startIfStale(nil) == false)
end

-- 3. Switched off in the middle: the old folder still counts, and the next start finishes the copy.
do
  local card = oldCard()
  install(card)
  local pre = startState(card)
  pre.startIfStale(nil)
  run(pre, 100000, 12)
  expect("cut short: no marker yet", card.files[NEW .. "/moved.txt"] == nil)
  local nextStart = startState(card)
  expect("cut short: the old folder still counts", rfsuite.paths.user == OLD)
  expect("cut short: the next start holds the connection again", nextStart.startIfStale(nil) == true)
  expect("cut short: and waits", nextStart.runsBehindConnection() == false)
  run(nextStart)
  expect("cut short: the copy is complete", card.files[NEW .. "/flightlog/flights.csv"] == BIG)
  expect("cut short: now the marker is there", card.files[NEW .. "/moved.txt"] ~= nil)
  expect("cut short: a restart is asked for", nextStart.needsRestart() == true)
end

-- 4. A full card: the suite stays on the old folder, says so, and the retry does not hold up.
do
  local card = oldCard()
  install(card)
  card.addDir(NEW)
  local before = snapshotOld(card)
  card.full = false
  local pre = startState(card)
  pre.startIfStale(nil)
  run(pre, 100000, 8)
  -- The stamp has gone to the old folder by now; from here on nothing fits on the new one.
  local realOpenStub = io.open
  io.open = function(path, mode)
    if mode == "w" and string.find(path, NEW, 1, true) == 1 then return nil end
    return realOpenStub(path, mode)
  end
  run(pre)
  io.open = realOpenStub
  expect("full card: the pass ends", not pre.isRunning())
  expect("full card: the connection is free again", pre.holdsConnectionForMove() == false)
  expect("full card: no marker", card.files[NEW .. "/moved.txt"] == nil)
  expect("full card: the failure is noted in the old folder", card.files[OLD .. "/move_failed.txt"] ~= nil)
  expect("full card: the screen is told", rfsuite.paths.moveFailed == true)
  expect("full card: the old folder is untouched but for the stamp", sameOld(card, before, OLD .. "/precompiled.txt"))

  card.uptime = 5000
  local retry = startState(card)
  expect("after a failure: the old folder still counts", rfsuite.paths.user == OLD)
  expect("after a failure: a retry runs", retry.startIfStale(nil) == true)
  expect("after a failure: the screen is still told", rfsuite.paths.moveFailed == true)
  expect("after a failure: it does not hold the connection", retry.runsBehindConnection() == true)
  expect("after a failure: the tool does not hold it either", retry.holdsConnectionForMove() == false)
  local _, _, finished = retry.getProgress()
  expect("after a failure: the tool's start screen does not wait on it", finished == true)
  run(retry)
  expect("retry through: no marker, data could have changed under it", card.files[NEW .. "/moved.txt"] == nil)
  expect("retry through: the note says so", string.match(card.files[OLD .. "/move_failed.txt"] or "", "^ok 5000") ~= nil)
  expect("retry through: no restart is asked for", retry.needsRestart() == false)
  expect("retry through: the screen is no longer told", rfsuite.paths.moveFailed == nil)
  expect("retry through: no copy took its name", card.files[NEW .. "/preferences.lua"] == nil)
  for path in pairs(card.files) do
    expect("retry through: no .new file is left: " .. path,
      string.sub(path, 1, #NEW) ~= NEW or not string.find(path, ".new", 1, true))
  end

  -- A tool opened before the restart: a widget of this session is connected and writing to the old
  -- folder, so this start must not hold, copy for good or write the marker.
  card.uptime = 6000
  local sameSession = startState(card)
  expect("same session: the old folder still counts", rfsuite.paths.user == OLD)
  sameSession.startIfStale(nil)
  expect("same session: it stays behind the connection", sameSession.runsBehindConnection() == true)
  expect("same session: and tells nobody of a failure", rfsuite.paths.moveFailed == nil)
  run(sameSession)
  expect("same session: no marker", card.files[NEW .. "/moved.txt"] == nil)

  -- After a power-up the clock has started again.
  card.uptime = 100
  local last = startState(card)
  expect("after the retry: the next start holds again", last.startIfStale(nil) == true)
  expect("after the retry: and waits", last.runsBehindConnection() == false)
  run(last)
  expect("after the retry: the marker is written", card.files[NEW .. "/moved.txt"] ~= nil)
end

-- 5. A copy that reads back wrong does not count.
do
  local card = oldCard()
  install(card)
  card.garble = NEW .. "/tune/3b0049.lua.new"
  local pre = startState(card)
  pre.startIfStale(nil)
  run(pre)
  expect("wrong read-back: no marker", card.files[NEW .. "/moved.txt"] == nil)
  expect("wrong read-back: noted", card.files[OLD .. "/move_failed.txt"] ~= nil)
  expect("wrong read-back: the wrong copy did not take the name", card.files[NEW .. "/tune/3b0049.lua"] == nil)
  local nextStart = startState(card)
  expect("wrong read-back: the old folder still counts", rfsuite.paths.user == OLD)
  nextStart.startIfStale(nil)
end

-- 6. A retry waits while the model is armed.
do
  local card = oldCard()
  install(card)
  card.put(OLD .. "/move_failed.txt", "size\n")
  local pre = startState(card)
  rfsuite.require = function(name)
    if name == "lib/armed.lua" then return { isArmed = function() return true end } end
  end
  pre.startIfStale(nil)
  run(pre, 500)
  expect("armed: the retry does not touch the card", card.files[NEW .. "/preferences.lua"] == nil)
  expect("armed: and is still there", pre.isRunning())
end

-- 7. A folder that cannot be listed fails the job; it does not read as an empty one.
do
  local card = oldCard()
  install(card)
  card.noList = OLD .. "/dashboard"
  local pre = startState(card)
  pre.startIfStale(nil)
  run(pre)
  expect("no listing: no marker", card.files[NEW .. "/moved.txt"] == nil)
  expect("no listing: noted", card.files[OLD .. "/move_failed.txt"] ~= nil)
  expect("no listing: the screen is told", rfsuite.paths.moveFailed == true)
end

-- 8. A rename that does not go through fails the job.
do
  local card = oldCard()
  install(card)
  card.noRename = true
  local pre = startState(card)
  pre.startIfStale(nil)
  run(pre)
  expect("no rename: no marker", card.files[NEW .. "/moved.txt"] == nil)
  expect("no rename: noted", card.files[OLD .. "/move_failed.txt"] ~= nil)
end

-- 9. Two states on one card: the one that finishes second leaves the finished folder alone.
do
  local card = oldCard()
  install(card)
  local slow = startState(card)
  local slowRfsuite = rfsuite
  slow.startIfStale(nil)
  run(slow, 100000, 12)
  local fast = startState(card)
  fast.startIfStale(nil)
  run(fast)
  expect("two states: the first to finish writes the marker", card.files[NEW .. "/moved.txt"] ~= nil)
  local flights = card.files[NEW .. "/flightlog/flights.csv"]
  _G.rfsuite = slowRfsuite
  run(slow)
  expect("two states: the second stops", not slow.isRunning())
  expect("two states: and asks for the restart", slow.needsRestart() == true)
  expect("two states: and reports the data as moved", slow.movedTheData() == true)
  expect("two states: the finished copy stands", card.files[NEW .. "/flightlog/flights.csv"] == flights and flights == BIG)
  expect("two states: no failure is noted", card.files[OLD .. "/move_failed.txt"] == nil)
end

-- 10. The other state finishes while this one is reading its copies back.
do
  local card = oldCard()
  install(card)
  local slow = startState(card)
  local slowRfsuite = rfsuite
  slow.startIfStale(nil)
  run(slow, 100000, 40)
  local fast = startState(card)
  fast.startIfStale(nil)
  run(fast)
  _G.rfsuite = slowRfsuite
  run(slow)
  expect("second state mid read-back: asks for the restart", slow.needsRestart() == true)
  expect("second state mid read-back: reports no failure", card.files[OLD .. "/move_failed.txt"] == nil)
  expect("second state mid read-back: the screen is not told", slowRfsuite.paths.moveFailed == nil)
end

-- 11. The other state finishes while this one is about to take a file's name.
do
  local card = oldCard()
  install(card)
  local slow = startState(card)
  local slowRfsuite = rfsuite
  slow.startIfStale(nil)
  while not (card.files[NEW .. "/preferences.lua.new"] ~= nil and slow.getProgress() > 0) and slow.isRunning() do
    slow.step()
  end
  local fast = startState(card)
  fast.startIfStale(nil)
  run(fast)
  local expected = {}
  for path, data in pairs(card.files) do
    if string.sub(path, 1, #NEW) == NEW then expected[path] = data end
  end
  _G.rfsuite = slowRfsuite
  run(slow)
  local same = true
  for path, data in pairs(expected) do
    if card.files[path] ~= data then same = false end
  end
  expect("late second state: the finished folder stands byte for byte", same)
end

-- 12. A state started again keeps the folder it decided on.
do
  local card = oldCard()
  install(card)
  startState(card)
  card.put(NEW .. "/moved.txt", "moved\n")
  loadSource("lib/require.lua")()
  expect("a second load of lib/require.lua keeps the folder", rfsuite.paths.user == OLD)
end

if failures > 0 then
  print(failures .. " expectations failed")
  os.exit(1)
end
print("user move: all expectations hold")
