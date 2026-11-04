-- lib/user_move.lua
-- Copies the pilot's data from the folder an earlier install kept it in to the one this install
-- uses, for a card that was updated by unpacking the archive over it.
--
-- lib/require.lua decides at the start of every Lua state which folder counts: as long as the old
-- folder exists and the new one holds no marker, rfsuite.paths.user stays the old folder and
-- rfsuite.paths.moveTo names the new one. lib/precompile.lua runs this job after its compile pass.
-- The modules keep the folder they read when they loaded, so the switch happens at the next start:
-- nothing here changes which folder the running suite uses, the data in the old folder is never
-- written or deleted, and a copy cut short by switching off just starts again at the next start.
--
-- Each file is written as <name>.new, compared with its source, and only then renamed into place.
-- The tool and the widgets are separate Lua states and can each run this job, so a job also stops
-- when it finds the marker another one wrote, and nothing it still has open can touch a finished
-- file behind that marker.
--
-- Two ways to run. On a card with no failed attempt the connection waits for the job, nothing is
-- flown and almost nothing is written, and the marker it writes last is what makes the next start
-- use the new folder. After a failed attempt the job runs behind a connection that is not held, so
-- a full card costs no wait on every start; data can change under such a copy, so it only proves
-- that the copy works now: no file takes its name, the copies are removed again, and the note then
-- says so with the clock of this radio session. The start after the next power-up copies with the
-- connection held, and a tool opened before that restart does not, because a widget of this session
-- is connected and writing to the old folder. The note goes to the old folder and an empty file is
-- enough: on a full card the new folder may not exist, and a directory entry can still fit where
-- no data does.
--
-- One unit of work per step: a few directory entries, or a few chunks copied or compared. On a radio
-- a step comes about every 0.3 s while the compile pass has just ended, so one chunk per step would
-- take minutes on a long flight log. Only the data
-- named below moves. The debug logs and reload.req are not worth the wait, and anything else in
-- the folder stays with the old folder.

local M = {}

local CHUNK = 2048
local ENTRIES_PER_STEP = 8
local CHUNKS_PER_STEP = 8
local MARKER = "moved.txt"
local NOTE = "move_failed.txt"
local TAG = "rfsuite.user_move"

local FOLDERS = { dashboard = true, flightlog = true, tune = true, journal = true, sim = true }
local FILES = {
  ["preferences.lua"] = true,
  ["preferences.ini"] = true,
  ["model_name_restore.lua"] = true,
  ["model_name_restore.ini"] = true,
  ["precompiled.txt"] = true,
}

local function log(level, fmt, ...)
  local Log = _G.rfsuite and _G.rfsuite.Log
  if type(Log) == "table" and type(Log.emitf) == "function" then
    pcall(Log.emitf, TAG, level, fmt, ...)
  end
end

-- The settings file of one flight controller is named after the board's own id, with its in-flight
-- baseline beside it (lib/model_preferences.lua, widgets/dashboard/inflight/baseline.lua). "." and
-- anything but letters, digits, "_" and "-" cannot be part of such an id.
local function isBoardFile(name)
  return string.match(name, "^[%w_%-]+%.lua$") ~= nil
    or string.match(name, "^[%w_%-]+%.ini$") ~= nil
    or string.match(name, "^[%w_%-]+%.inflight%.lua$") ~= nil
end

-- A name with no dot is taken for a folder only when fstat cannot say.
local function isFolder(info, name)
  if type(info) == "table" and type(info.attrib) == "number" then
    return math.floor(info.attrib / 16) % 2 == 1
  end
  return string.find(name, ".", 1, true) == nil
end

local function statOf(path)
  if type(fstat) ~= "function" then return nil end
  local ok, info = pcall(fstat, path)
  if ok and type(info) == "table" then return info end
  return nil
end

local function makeDir(path)
  if type(mkdir) == "function" then pcall(mkdir, path) end
end

local function remove(path)
  if type(del) == "function" then pcall(del, path) end
end

local function now()
  return type(getTime) == "function" and getTime() or 0
end

-- What the failure note says: the clock reading of a retry that went through, or nil. getTime counts
-- from power-up, so a later reading means the same radio session.
local function retryPassedAt(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = io.read(f, 32)
  io.close(f)
  return tonumber(string.match(text or "", "^ok (%d+)"))
end

local function closeAll(job)
  if job.source then io.close(job.source); job.source = nil end
  if job.target then io.close(job.target); job.target = nil end
end

local function finishedElsewhere(job)
  closeAll(job)
  job.finished = true
  job.moved = true
  log("info", "another start has finished the move to %s", job.to)
end

local function fail(job, reason, path)
  -- Another Lua state finishing first takes the copies this job was working on: its move stands.
  if statOf(job.to .. "/" .. MARKER) ~= nil then return finishedElsewhere(job) end
  closeAll(job)
  job.finished = true
  job.failed = true
  _G.rfsuite.paths.moveFailed = true
  log("warn", "copy failed (%s) at %s; staying on %s", reason, tostring(path), job.from)
  if not job.background then
    local f = io.open(job.from .. "/" .. NOTE, "w")
    if f then
      io.write(f, reason .. "\n")
      io.close(f)
    end
    if statOf(job.from .. "/" .. NOTE) == nil then
      log("warn", "could not write %s", NOTE)
    end
  end
end

local function finish(job)
  closeAll(job)
  job.finished = true
  if job.background then
    local f = io.open(job.from .. "/" .. NOTE, "w")
    if f then
      io.write(f, "ok " .. tostring(now()) .. "\n")
      io.close(f)
    end
    _G.rfsuite.paths.moveFailed = nil
    log("info", "retry went through; the start after a restart moves the data")
    return
  end
  local path = job.to .. "/" .. MARKER
  local f = io.open(path, "w")
  if f then
    io.write(f, "moved\n")
    io.close(f)
  end
  if statOf(path) == nil then
    return fail(job, "marker", path)
  end
  job.moved = true
  remove(job.from .. "/" .. NOTE)
  _G.rfsuite.paths.moveFailed = nil
  log("info", "%d files copied to %s; the next start uses it", #job.files, job.to)
end

-- A few entries of a directory of the old folder per step: each costs an fstat, and a card can hold
-- many boards or themes. The top level goes by the lists above, a listed folder whole. Bytecode is
-- left behind, since the radio writes it again beside the copied source. A directory that cannot be
-- listed fails the job rather than reading as an empty one.
local function listStep(job)
  local cursor = job.cursor
  if cursor == nil then
    local rel = table.remove(job.dirs)
    if rel == nil then
      job.phase = "copy"
      job.index = 1
      job.total = job.bytes * 2
      log("debug", "%d files, %d bytes to copy", #job.files, job.bytes)
      return
    end
    local ok, iterator = false, nil
    if type(dir) == "function" then ok, iterator = pcall(dir, job.from .. rel) end
    if not ok or type(iterator) ~= "function" then
      return fail(job, "list", job.from .. rel)
    end
    makeDir(job.to .. rel)
    job.cursor = { rel = rel, next = iterator }
    log("trace", "listing %s", job.from .. rel)
    return
  end

  local rel = cursor.rel
  for _ = 1, ENTRIES_PER_STEP do
    local name = cursor.next()
    if name == nil then
      job.cursor = nil
      return
    end
    if type(name) == "string" and name ~= "" and name ~= "." and name ~= ".." then
      local info = statOf(job.from .. rel .. "/" .. name)
      local folder = isFolder(info, name)
      local take
      if rel == "" then
        take = (folder and FOLDERS[name]) or (not folder and (FILES[name] or isBoardFile(name)))
      else
        -- A .new is what a save cut short left behind, and the name the copy uses on its way.
        take = folder or (string.sub(name, -5) ~= ".luac" and string.sub(name, -4) ~= ".new")
      end
      if take and folder then
        job.dirs[#job.dirs + 1] = rel .. "/" .. name
      elseif take then
        local size = info and tonumber(info.size) or 0
        job.files[#job.files + 1] = { rel = rel .. "/" .. name, size = size }
        job.bytes = job.bytes + size
      end
    end
  end
end

local function copyStep(job)
  local entry = job.files[job.index]
  if entry == nil then
    job.phase = "verify"
    job.index = 1
    log("debug", "all files copied, reading them back")
    return
  end

  if job.source == nil then
    if statOf(job.to .. "/" .. MARKER) ~= nil then return finishedElsewhere(job) end
    job.source = io.open(job.from .. entry.rel, "r")
    if job.source == nil then return fail(job, "read", job.from .. entry.rel) end
    job.target = io.open(job.to .. entry.rel .. ".new", "w")
    if job.target == nil then return fail(job, "write", job.to .. entry.rel) end
    log("trace", "copying %s (%d bytes)", entry.rel, entry.size)
  end

  for _ = 1, CHUNKS_PER_STEP do
    local chunk = io.read(job.source, CHUNK)
    if chunk == nil or #chunk == 0 then
      closeAll(job)
      local info = statOf(job.to .. entry.rel .. ".new")
      if info == nil or tonumber(info.size) ~= entry.size then
        return fail(job, "size", job.to .. entry.rel)
      end
      job.index = job.index + 1
      return
    end
    if not io.write(job.target, chunk) then return fail(job, "write", job.to .. entry.rel) end
    job.done = job.done + #chunk
  end
end

-- The copy compared whole; only now does the file take its name.
local function install(job, entry)
  if statOf(job.to .. "/" .. MARKER) ~= nil then return finishedElsewhere(job) end
  local path = job.to .. entry.rel
  remove(path)
  local result = type(rename) == "function" and rename(path .. ".new", path)
  if result ~= 0 then return fail(job, "rename", path) end
  log("trace", "%s in place", entry.rel)
end

local function verifyStep(job)
  local entry = job.files[job.index]
  if entry == nil then
    if statOf(job.to .. "/" .. MARKER) ~= nil then return finishedElsewhere(job) end
    if job.background then
      job.phase = "clean"
      job.index = 1
      return
    end
    return finish(job)
  end

  if job.source == nil then
    job.source = io.open(job.from .. entry.rel, "r")
    job.target = io.open(job.to .. entry.rel .. ".new", "r")
    if job.source == nil or job.target == nil then
      return fail(job, "read back", job.to .. entry.rel)
    end
  end

  for _ = 1, CHUNKS_PER_STEP do
    local a = io.read(job.source, CHUNK)
    local b = io.read(job.target, CHUNK)
    if (a or "") ~= (b or "") then return fail(job, "read back", job.to .. entry.rel) end
    if a == nil or #a == 0 then
      closeAll(job)
      job.index = job.index + 1
      if not job.background then return install(job, entry) end
      return
    end
    job.done = job.done + #a
  end
end

-- A retry takes its copies away again, a few per step: it only had to show that they fit.
local function cleanStep(job)
  for _ = 1, ENTRIES_PER_STEP do
    local entry = job.files[job.index]
    if entry == nil then return finish(job) end
    remove(job.to .. entry.rel .. ".new")
    job.index = job.index + 1
  end
end

local function armed()
  local rfsuite = _G.rfsuite
  local Armed = rfsuite and type(rfsuite.require) == "function" and rfsuite.require("lib/armed.lua")
  return type(Armed) == "table" and type(Armed.isArmed) == "function" and Armed.isArmed() == true
end

--- A job for the pending move, or nil when no move is pending.
function M.new()
  local paths = _G.rfsuite and _G.rfsuite.paths
  if not paths or not paths.moveTo then return nil end
  local notePath = paths.user .. "/" .. NOTE
  local noted = statOf(notePath) ~= nil
  local passedAt = noted and retryPassedAt(notePath) or nil
  local job = {
    from = paths.user,
    to = paths.moveTo,
    background = noted and (passedAt == nil or now() >= passedAt),
    phase = "list",
    dirs = { "" },
    files = {},
    index = 1,
    bytes = 0,
    done = 0,
    total = 0,
    finished = false,
    failed = false,
    moved = false,
  }
  paths.moveFailed = (job.background and passedAt == nil) or nil
  log("info", "moving the pilot's data from %s to %s%s", job.from, job.to,
    job.background and " behind the connection, after an earlier failure" or "")
  return job
end

--- One unit of work. A job running behind the connection waits while the model is armed.
function M.step(job)
  if job.finished or (job.background and armed()) then return end
  if job.phase == "list" then
    listStep(job)
  elseif job.phase == "copy" then
    copyStep(job)
  elseif job.phase == "clean" then
    cleanStep(job)
  else
    verifyStep(job)
  end
end

return M
