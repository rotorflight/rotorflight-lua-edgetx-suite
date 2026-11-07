-- lib/precompile.lua
-- Compiles the installed sources ahead of the first page that needs them.
--
-- Opening a page for the first time starts with EdgeTX parsing the .lua and writing the
-- .luac next to it; only then does anything run. With the suite loading in binary-or-text
-- mode (see lib/require.lua) that part can be done in advance, so this walks the installed
-- tree and compiles whatever has no usable bytecode beside it yet. It does a little of the
-- work per call, so the screen keeps drawing while it runs.
--
-- Two things make bytecode unusable, and they need different answers. A source that is newer
-- than its .luac is found per file, by comparing the two timestamps the way the loader does.
-- A source that is older cannot be found that way at all -- reinstalling an earlier release
-- is the plain case -- so the pass also keeps a stamp of the tree it last compiled and
-- rebuilds everything when that changes.

local Precompile = {}

local ROOTS = {
  _G.rfsuite.paths.core,
  "/WIDGETS/rfsuite"
}

local STAMP_PATH = _G.rfsuite.paths.user .. "/precompiled.txt"

-- What the stamp is compared against, written by the packager over the sources it packed. It
-- changes with the content rather than with the version number, so a second install of the
-- same version -- a development build, a re-cut candidate, the other locale -- is still
-- recognised as a different tree. An install carrying no such file falls back to the version,
-- which is what this pass compared against before.
--
-- Only the first STAMP_LIMIT characters of either file take part in the comparison, which is why
-- the packager writes the digest first: what a long version pushes past that bound is then the
-- half that does not tell two trees apart.
local IDENTITY_PATH = _G.rfsuite.paths.core .. "/build.txt"

-- Enough for an identity, and a bound on what a damaged file can cost to read. Both files are
-- read with it, because comparing two differently truncated strings would compare nothing.
local STAMP_LIMIT = 64

-- Listing a directory costs little next to compiling a file, so the walk is allowed to move
-- faster. Reading a timestamp sits between the two, and one directory here holds over a
-- hundred sources, so the entries of a directory are worked through across calls rather than
-- in one: all three caps apply to a single call, and whichever is reached first ends it.
-- All three are budgets rather than measured optima; they bound what one call may do. The first
-- to revisit is STATS_PER_STEP, once the cost of a timestamp on a real card has been measured.
local DIRS_PER_STEP = 8
local STATS_PER_STEP = 16
local FILES_PER_STEP = 1
local GC_EVERY = 8

-- The fields of an fstat timestamp, most significant first.
local TIME_FIELDS = { "year", "mon", "day", "hour", "min", "sec" }

local state = nil

-- Returns the chunk, or nil and the reason it did not load. Nil without a reason means there
-- was no loader to ask, which is not a failure of the file.
local function loadUncached(path, mode)
  local utils = _G.rfsuite and _G.rfsuite.utils
  local loader = utils and utils.loadScriptUncached
  if type(loader) ~= "function" then
    -- Without the uncached loader every chunk read here would be held by the chunk cache of
    -- the tool state, which is the opposite of what this pass is for.
    return nil
  end
  local ok, chunk, err = pcall(loader, path, mode)
  if not ok then
    return nil, tostring(chunk)
  end
  if chunk == nil then
    return nil, tostring(err or "no chunk")
  end
  return chunk
end

local function listEntries(path)
  local entries = {}
  if type(dir) ~= "function" then
    return entries
  end

  local ok, iterator = pcall(dir, path)
  if not ok or type(iterator) ~= "function" then
    return entries
  end

  for name in iterator do
    if type(name) == "string" and name ~= "" and name ~= "." and name ~= ".." then
      entries[#entries + 1] = name
    end
  end

  return entries
end

local function modifiedAt(path)
  if type(fstat) ~= "function" then
    return nil
  end
  local ok, info = pcall(fstat, path)
  if not ok or type(info) ~= "table" or type(info.time) ~= "table" then
    return nil
  end
  return info.time
end

-- Compared field by field rather than as one number, because a date packed down to seconds
-- leaves the range a Lua integer is guaranteed to hold. Equal stamps are deliberately not older:
-- the loader rebuilds only where the bytecode is strictly the earlier of the two, and a fresh
-- compile leaves them equal, so the same input has to reach the same verdict here.
local function isOlder(a, b)
  for i = 1, #TIME_FIELDS do
    local key = TIME_FIELDS[i]
    local av, bv = a[key], b[key]
    if type(av) ~= "number" or type(bv) ~= "number" then
      -- fstat fills all six fields wherever it exists at all, so this cannot fire on EdgeTX. It
      -- is the default for an answer that is missing one: not older leaves the file to the loader
      -- at page open, which is also where a missing fstat leaves it.
      return false
    end
    if av ~= bv then
      return av < bv
    end
  end
  return false
end

-- EdgeTX writes a .luac carrying the timestamp of the source it was made from, and reads it
-- back only while it is not the older of the two. So bytecode standing at an earlier time
-- than its source is bytecode the loader has already given up on, and compiling it here is
-- the whole point of the pass -- otherwise that cost lands on the page that opens first.
local function isStale(source, bytecode)
  local sourceTime = modifiedAt(source)
  local bytecodeTime = modifiedAt(bytecode)
  if sourceTime == nil or bytecodeTime == nil then
    -- Nothing to compare. The loader still decides correctly when the page opens; this pass
    -- simply does not get ahead of it.
    return false
  end
  return isOlder(bytecodeTime, sourceTime)
end

local function readStampFile(path, limit)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local text = io.read(f, limit)
  io.close(f)
  if type(text) ~= "string" then
    return nil
  end
  text = (string.gsub(text, "%s", ""))
  if text == "" then
    return nil
  end
  return text
end

-- One line through the suite's logger, reached through the global it publishes so that this
-- file keeps no dependency of its own.
local function emit(level, fmt, ...)
  local Log = type(_G) == "table" and _G.rfsuite and _G.rfsuite.Log
  if type(Log) == "table" and type(Log.emitf) == "function" then
    pcall(Log.emitf, "rfsuite.precompile", level, fmt, ...)
  end
end

local function warn(fmt, ...)
  emit("warn", fmt, ...)
end

-- mkdir() is a bare global of the firmware's filesystem library and creates one level at a
-- time. Creating a folder that already exists fails harmlessly, so it is not checked first.
local function makeDir(path)
  if type(mkdir) ~= "function" then
    return
  end
  pcall(mkdir, path)
end

-- The install archive carries files only, no directory entries, so the user folder exists on
-- a fresh card only once something has saved into it -- and io.open(path, "w") does not create
-- a missing parent. Without the folder the stamp is never written, and every start forces the
-- whole pass again. The stamp is read back with the same comparison Precompile.start makes, so
-- a write that did not land is reported rather than paid for on every start.
local function writeStamp(identity)
  makeDir(string.match(STAMP_PATH, "^(.*)/[^/]+/[^/]+$"))
  makeDir(string.match(STAMP_PATH, "^(.*)/[^/]+$"))

  local f = io.open(STAMP_PATH, "w")
  if f then
    io.write(f, identity)
    io.close(f)
  end

  if readStampFile(STAMP_PATH, STAMP_LIMIT) ~= identity then
    warn("could not write the user folder's precompiled.txt, every start compiles everything")
    return false
  end
  return true
end

local function beginDirectory(path)
  local entries = listEntries(path)

  local hasBytecode = {}
  for i = 1, #entries do
    local name = entries[i]
    if string.sub(name, -5) == ".luac" then
      hasBytecode[string.sub(name, 1, -6)] = true
    end
  end

  return { path = path, entries = entries, index = 1, hasBytecode = hasBytecode }
end

-- Takes one entry of the directory being read, and returns how many timestamps that cost.
local function takeEntry(cursor)
  local name = cursor.entries[cursor.index]
  cursor.index = cursor.index + 1

  if string.sub(name, 1, 2) == "._" then
    -- macOS leaves an AppleDouble metadata file named "._<name>" beside every file it copies
    -- onto a FAT card. "._init.lua" ends in .lua but holds no source, so it never compiles and
    -- would be queued again on every start.
    return 0
  end

  if string.find(name, ".", 1, true) == nil then
    -- No directory in the installed tree carries a dot and every file has an extension, so
    -- this tells the two apart without a stat call per entry. The fourth argument makes it a
    -- plain search: as a pattern the dot would match any character and every entry would look
    -- like a file.
    state.dirs[#state.dirs + 1] = cursor.path .. "/" .. name
    return 0
  end

  if string.sub(name, -4) ~= ".lua" then
    return 0
  end

  local stem = string.sub(name, 1, -5)
  local source = cursor.path .. "/" .. name
  state.checked = state.checked + 1

  if state.force or not cursor.hasBytecode[stem] then
    state.files[#state.files + 1] = source
    return 0
  end

  if isStale(source, cursor.path .. "/" .. stem .. ".luac") then
    state.files[#state.files + 1] = source
  end
  return 2
end

local function walk()
  local dirsTaken = 0
  local statsTaken = 0

  while true do
    local cursor = state.cursor

    if cursor == nil then
      if dirsTaken >= DIRS_PER_STEP then
        return
      end
      local path = table.remove(state.dirs)
      if not path then
        state.walking = false
        emit("debug", "walk done: %d of %d sources queued", #state.files, state.checked)
        return
      end
      cursor = beginDirectory(path)
      state.cursor = cursor
      dirsTaken = dirsTaken + 1
    end

    while cursor.index <= #cursor.entries do
      statsTaken = statsTaken + takeEntry(cursor)
      if statsTaken >= STATS_PER_STEP then
        return
      end
    end

    state.cursor = nil
  end
end

local function compile()
  for _ = 1, FILES_PER_STEP do
    local path = state.files[state.done + 1]
    if not path then
      return
    end

    -- "c" compiles even when the bytecode looks newer than the source. The chunk is of no
    -- use here and is dropped, so the collector can take it back. A file that does not load
    -- is counted and reported once when the pass ends, not per file.
    local chunk, err = loadUncached(path, state.force and "tc" or "t")
    if chunk == nil and err ~= nil then
      state.failed = state.failed + 1
      if state.firstFailure == nil then
        state.firstFailure = path
        state.firstError = err
      end
    end

    state.done = state.done + 1
    if state.done % GC_EVERY == 0 then
      collectgarbage("collect")
    end
  end
end

-- The pending move of the pilot's data, if any (lib/user_move.lua). The module is loaded only
-- for such a move and goes with this pass, so a card without one holds nothing of it.
local function attachMove()
  local paths = _G.rfsuite and _G.rfsuite.paths
  if not paths or not paths.moveTo then
    return
  end
  local chunk, err = loadUncached(paths.core .. "/lib/user_move.lua", _G.rfsuite.loadMode or "bt")
  if not chunk then
    warn("could not load the move of the user folder: %s", tostring(err))
    return
  end
  state.moveModule = chunk()
  state.move = state.moveModule.new()
end

-- version is what the stamp is compared against where the install carries no build identity
-- of its own; without either the pass still fills in missing and outdated bytecode but never
-- forces a rebuild.
function Precompile.start(version)
  local built = readStampFile(IDENTITY_PATH, STAMP_LIMIT)
  local identity = built or version

  -- The widget state is one Lua state for the dashboard, the service widget and the tool opened
  -- from the dashboard, and they share this module. A pass one of them started is joined rather
  -- than begun again: starting over would throw away the walk so far, and a forced pass would
  -- compile from the beginning everything it had already compiled.
  if state ~= nil and not state.finished and state.identity == identity then
    return
  end

  local stamp = readStampFile(STAMP_PATH, STAMP_LIMIT)
  local force = identity ~= nil and stamp ~= identity

  state = {
    identity = identity,
    packaged = built ~= nil,
    force = force,
    dirs = {},
    cursor = nil,
    files = {},
    done = 0,
    failed = 0,
    checked = 0,
    firstFailure = nil,
    firstError = nil,
    walking = true,
    walked = true,
    finished = false,
    startedAt = type(getTime) == "function" and getTime() or nil,
    lastStepAt = nil
  }

  -- Why every source is rebuilt, or that only missing and outdated bytecode is filled in. Short,
  -- because the log ring keeps the first 100 characters of a line and the duration comes after it.
  local why = "not forced"
  if force then
    why = stamp == nil and "forced: no stamp" or "forced: new tree"
  end
  state.why = why
  emit("info", "pass started: whole tree, %s", why)

  for i = #ROOTS, 1, -1 do
    state.dirs[#state.dirs + 1] = ROOTS[i]
  end
  attachMove()
end

local function clockTick()
  return type(getTime) == "function" and getTime() or nil
end

-- One unit of work: a few directories while the tree is still being read, one file after
-- that. Call it once per run cycle.
function Precompile.step()
  if state == nil or state.finished then
    return
  end
  state.lastStepAt = clockTick()

  if state.walking then
    walk()
    return
  end

  if state.done < #state.files then
    compile()
    return
  end

  -- The stamp is written before the move, so the copy carries it and the next start, on the new
  -- folder, finds this tree already compiled.
  if state.force and state.identity ~= nil and state.stampWritten == nil then
    state.stampWritten = writeStamp(state.identity)
  end
  if state.move and not state.move.finished then
    state.moveModule.step(state.move)
    return
  end

  state.finished = true
  collectgarbage("collect")
  if state.walked then
    -- One line per pass, at info so that it reaches the log ring at the shipped level: how much was
    -- looked at, how much of it compiled, why, and how long it held the start (10 ms ticks).
    local now = clockTick()
    local ticks = (now and state.startedAt) and math.floor(now - state.startedAt) or -1
    emit("info", "pass done: %d checked, %d compiled, %d failed, %s, %d ticks",
      state.checked, #state.files - state.failed, state.failed, state.why or "not forced", ticks)
  end
  if state.failed > 0 then
    -- The log ring keeps the first 100 characters of a line, so the file comes first and
    -- without the core's own prefix: the deepest page path still fits, the reason may not.
    local name = state.firstFailure
    local prefix = ROOTS[1] .. "/"
    if string.sub(name, 1, #prefix) == prefix then
      name = string.sub(name, #prefix + 1)
    end
    warn("%s did not compile (%d of %d failed): %s", name, state.failed, #state.files,
      state.firstError)
  end
end

-- The way in for every start: the widgets', and the tool's, from the dashboard or from the radio's
-- tools menu. The pass runs only where the tree is not the one last compiled -- an install, an
-- update, the other locale -- and the widgets hold their connection back until it has finished, so
-- the compile does not compete with the connect chain and every page is ready when the flight
-- controller is. A tree that is already compiled costs two small file reads here and no walk at
-- all. A single source edited on the card is still compiled, by the radio's loader when a page
-- first loads it: it rebuilds the bytecode of a source newer than its .luac. start() walks the
-- whole tree to get ahead of that, which a developer can ask the tool's start for.
--
-- version is the fallback identity, as for start(); the widgets pass none, so a tree without the
-- packager's build identity starts nothing from them.
--
-- Returns true while such a pass runs, whether this call started it or another caller did.
-- Without the uncached loader nothing would actually be compiled, yet the pass would finish and
-- write the stamp, and the tool would then believe the tree compiled; so nothing starts.
function Precompile.startIfStale(version)
  if state ~= nil and not state.finished and (state.force or state.move) then
    emit("debug", "pass already running, joined")
    return true
  end

  local utils = _G.rfsuite and _G.rfsuite.utils
  if not utils or type(utils.loadScriptUncached) ~= "function" then
    emit("debug", "no pass: no uncached loader in this state")
    return false
  end
  -- The same for the listing: without dir() the walk finds nothing, and a pass that compiled
  -- nothing would still record the build as compiled and ask for a restart.
  if type(dir) ~= "function" then
    emit("debug", "no pass: no dir() in this state")
    return false
  end

  local identity = readStampFile(IDENTITY_PATH, STAMP_LIMIT) or version
  if identity == nil or readStampFile(STAMP_PATH, STAMP_LIMIT) == identity then
    -- Nothing is logged here: the widgets come through this on their first pass, which sits close to
    -- the instruction limit, and even a line the log level drops costs there. The tool says it.
    -- Nothing to compile, but the move of the pilot's data can still be owed: after a start cut
    -- short, or behind the connection after a failed attempt.
    local paths = _G.rfsuite and _G.rfsuite.paths
    if not paths or not paths.moveTo then
      return false
    end
    state = { identity = identity, force = false, dirs = {}, files = {}, done = 0, failed = 0,
      walking = false, finished = false }
    attachMove()
    return state.move ~= nil
  end

  Precompile.start(version)
  return state ~= nil and not state.finished
end

-- step() for a caller that shares the pass with others: the two widgets and the tool opened from
-- the dashboard all drive it from the same state, and a unit already taken in this clock tick is
-- not taken again, so a run cycle carries one unit however many of them call.
function Precompile.stepShared()
  if state == nil or state.finished then
    return
  end
  local now = clockTick()
  if now ~= nil and state.lastStepAt == now then
    return
  end
  Precompile.step()
end

-- True once a pass that rebuilt the whole tree has finished and recorded it. Whatever was loaded
-- before or during that pass in a Lua state that outlives it -- the widgets', above all -- is
-- still the previous build's code, and only a restart of the radio replaces it. Never true when
-- the stamp did not land: the next start would then compile everything again and ask again, for
-- ever. And only for a tree the packager stamped: a source tree copied by hand, compiled against
-- the version number, is a developer's, and is not held up for a restart.
function Precompile.needsRestart()
  if state == nil or not state.finished then
    return false
  end
  if state.move and state.move.moved then
    return true
  end
  return state.force and state.packaged and state.stampWritten == true
end

-- True once this pass has written the marker of the move, or found another start's. What is saved
-- from here until the next start would go to the old folder, and that folder no longer counts then.
function Precompile.movedTheData()
  return state ~= nil and state.move ~= nil and state.move.moved == true
end

-- True while the move runs with the connection held, and after it until the restart. The tool drives
-- the flight controller from its start screen, and what that writes now would miss the copy.
function Precompile.holdsConnectionForMove()
  if state == nil or state.move == nil or state.move.background then
    return false
  end
  return not state.finished or state.move.moved == true
end

-- True for a pass that only retries the move after a failed attempt: it runs on, and the
-- connection does not wait for it.
function Precompile.runsBehindConnection()
  return state ~= nil and not state.finished and state.move ~= nil and state.move.background
end

function Precompile.isRunning()
  return state ~= nil and not state.finished
end

function Precompile.getProgress()
  if state == nil then
    return 0, 0, true
  end
  -- While the data moves the count is kilobytes, so a long file still moves the line.
  -- A move behind the connection is not waited for, so it reports nothing to wait on.
  local move = state.move
  if move and move.background then
    return state.done, #state.files, true
  end
  if move and not move.finished and #state.files == state.done then
    return math.floor(move.done / 1024), math.floor(move.total / 1024), false
  end
  return state.done, #state.files, state.finished
end

return Precompile
