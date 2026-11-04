-- lib/user_move.lua
-- Copies the pilot's data from the folder an earlier install kept it in to the one this install
-- uses, for a card that was updated by unpacking the archive over it.
--
-- lib/require.lua decides at the start of every Lua state which folder counts: as long as the old
-- folder exists and the new one holds no marker, rfsuite.paths.user stays the old folder and
-- rfsuite.paths.moveTo names the new one. lib/precompile.lua runs this job after its compile pass.
-- The modules keep the folder they read when they loaded, so the switch happens at the next start:
-- nothing here changes which folder the running suite uses, the old folder is never written or
-- deleted, and a copy cut short by switching off just starts again at the next start.
--
-- Two ways to run. On a card with no failed attempt the connection waits for the job, nothing is
-- flown and almost nothing is written, and the marker it writes last is what makes the next start
-- use the new folder. After a failed attempt the job runs behind a connection that is not held, so
-- a full card costs no wait on every start; data can change under such a copy, so it only proves
-- that the copy works now and removes the failure note, and the next start copies again with the
-- connection held.
--
-- One unit of work per step: a directory listed, or one chunk copied or compared. Only the data
-- named below moves. The debug logs and reload.req are not worth the wait, and anything else in
-- the folder stays with the old folder.

local M = {}

local CHUNK = 2048
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

local function listNames(path)
  local names = {}
  if type(dir) ~= "function" then return names end
  local ok, iterator = pcall(dir, path)
  if not ok or type(iterator) ~= "function" then return names end
  for name in iterator do
    if type(name) == "string" and name ~= "" and name ~= "." and name ~= ".." then
      names[#names + 1] = name
    end
  end
  return names
end

local function closeAll(job)
  if job.source then io.close(job.source); job.source = nil end
  if job.target then io.close(job.target); job.target = nil end
end

local function writeSmallFile(path, text)
  local f = io.open(path, "w")
  if not f then return false end
  io.write(f, text)
  io.close(f)
  local info = statOf(path)
  return info ~= nil and tonumber(info.size) == #text
end

local function fail(job, reason, path)
  closeAll(job)
  job.finished = true
  job.failed = true
  _G.rfsuite.paths.moveFailed = true
  log("warn", "copy failed (%s) at %s; staying on %s", reason, tostring(path), job.from)
  if not job.background and not writeSmallFile(job.to .. "/" .. NOTE, reason .. "\n") then
    log("warn", "could not write %s", NOTE)
  end
end

local function finish(job)
  closeAll(job)
  job.finished = true
  if job.background then
    if type(del) == "function" then pcall(del, job.to .. "/" .. NOTE) end
    _G.rfsuite.paths.moveFailed = nil
    log("info", "retry went through; the next start moves the data")
    return
  end
  if writeSmallFile(job.to .. "/" .. MARKER, "moved\n") then
    job.moved = true
    if type(del) == "function" then pcall(del, job.to .. "/" .. NOTE) end
    _G.rfsuite.paths.moveFailed = nil
    log("info", "%d files copied to %s; the next start uses it", #job.files, job.to)
  else
    fail(job, "marker", job.to .. "/" .. MARKER)
  end
end

-- One directory of the old folder: the top level by the lists above, a listed folder whole. Bytecode
-- is left behind, since the radio writes it again beside the copied source.
local function listStep(job)
  local rel = table.remove(job.dirs)
  if rel == nil then
    job.phase = "copy"
    job.index = 1
    job.total = job.bytes * 2
    log("debug", "%d files, %d bytes to copy", #job.files, job.bytes)
    return
  end

  local fromDir = job.from .. rel
  makeDir(job.to .. rel)
  local names = listNames(fromDir)
  for i = 1, #names do
    local name = names[i]
    local path = fromDir .. "/" .. name
    local info = statOf(path)
    local folder = isFolder(info, name)
    local take
    if rel == "" then
      take = (folder and FOLDERS[name]) or (not folder and (FILES[name] or isBoardFile(name)))
    else
      take = folder or string.sub(name, -5) ~= ".luac"
    end
    if take and folder then
      job.dirs[#job.dirs + 1] = rel .. "/" .. name
    elseif take then
      local size = info and tonumber(info.size) or 0
      job.files[#job.files + 1] = { rel = rel .. "/" .. name, size = size }
      job.bytes = job.bytes + size
    end
  end
  log("trace", "listed %s: %d entries", fromDir, #names)
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
    job.source = io.open(job.from .. entry.rel, "r")
    if job.source == nil then return fail(job, "read", job.from .. entry.rel) end
    job.target = io.open(job.to .. entry.rel, "w")
    if job.target == nil then return fail(job, "write", job.to .. entry.rel) end
    log("trace", "copying %s (%d bytes)", entry.rel, entry.size)
  end

  local chunk = io.read(job.source, CHUNK)
  if chunk == nil or #chunk == 0 then
    closeAll(job)
    local info = statOf(job.to .. entry.rel)
    if info == nil or tonumber(info.size) ~= entry.size then
      return fail(job, "size", job.to .. entry.rel)
    end
    job.index = job.index + 1
    return
  end
  if not io.write(job.target, chunk) then return fail(job, "write", job.to .. entry.rel) end
  job.done = job.done + #chunk
end

local function verifyStep(job)
  local entry = job.files[job.index]
  if entry == nil then return finish(job) end

  if job.source == nil then
    job.source = io.open(job.from .. entry.rel, "r")
    job.target = io.open(job.to .. entry.rel, "r")
    if job.source == nil or job.target == nil then
      return fail(job, "read back", job.to .. entry.rel)
    end
  end

  local a = io.read(job.source, CHUNK)
  local b = io.read(job.target, CHUNK)
  if (a or "") ~= (b or "") then return fail(job, "read back", job.to .. entry.rel) end
  if a == nil or #a == 0 then
    closeAll(job)
    job.index = job.index + 1
    return
  end
  job.done = job.done + #a
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
  local job = {
    from = paths.user,
    to = paths.moveTo,
    background = statOf(paths.moveTo .. "/" .. NOTE) ~= nil,
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
  paths.moveFailed = job.background or nil
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
  else
    verifyStep(job)
  end
end

return M
