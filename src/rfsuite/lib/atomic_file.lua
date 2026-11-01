-- Replaces a whole file without ever leaving it truncated.
--
-- The new content is written beside the file as `.new` and its size verified, the original is
-- parked as `.bak`, and only then is the new file renamed into place. Every failure exit leaves
-- the original where it was, and a failure of the final rename leaves the data in the `.bak`.
-- A write cut short between the two renames leaves only the `.bak`; a reader that finds no file
-- under the name may read that instead: readablePath below answers which of the two to read
-- (lib/flight_log.lua reads its registry through it; lib/tune_history.lua does the same itself).
--
-- A module of its own so that a caller replacing one small file does not have to load the
-- module of another feature to do it: lib/flight_log.lua and lib/tune_history.lua both write
-- through here. The caller makes the directory; nothing here creates one.
--
-- del and rename answer an FRESULT, 0 being success. FatFS refuses a rename onto an existing
-- name, which is why the stale `.bak` is removed first.

local M = {}

local function fileSize(path)
  if type(fstat) ~= "function" then return nil end
  local ok, st = pcall(fstat, path)
  if not ok or type(st) ~= "table" then return nil end
  return tonumber(st.size)
end

local function opens(path)
  local f = io.open(path, "r")
  if not f then return false end
  io.close(f)
  return true
end

--- The path to read a file written through here from: the file itself or, when no file stands
--- under the name, the `.bak` a replace cut short between its two renames left behind. With
--- neither there it answers the name, so a missing file still reads as missing. The `.bak` is
--- left where it is; the next replace built on what was read from it writes it back under the
--- name, and only the replace after that removes it.
function M.readablePath(path)
  if opens(path) then return path end
  local bakPath = path .. ".bak"
  if opens(bakPath) then return bakPath end
  return path
end

--- Writes `content` over `path`. `allowCreate` lets a missing original through: the file is then
--- created rather than the write being refused. Returns true when the new content is in place.
function M.replace(path, content, allowCreate)
  local newPath = path .. ".new"
  local bakPath = path .. ".bak"

  local f = io.open(newPath, "w")
  if not f then return false end
  io.write(f, content)
  io.close(f)

  -- Verified before the original is touched. io.write does report a short write, but what has
  -- to hold here is that the replacement is complete on the card, and the file's size is the
  -- only thing that says so -- so it is checked whatever the write answered.
  local written = fileSize(newPath)
  if written == nil or written ~= #content then return false end
  if type(rename) ~= "function" then return false end

  -- No file under the name: nothing to park, and a `.bak` left by a replace cut short after
  -- parking may be the only copy of the data, so it is never removed here.
  local parked = fileSize(path) ~= nil
  if not parked and not allowCreate then return false end
  if parked then
    if type(del) == "function" then pcall(del, bakPath) end
    local ok, res = pcall(rename, path, bakPath)
    if not ok or res ~= 0 then return false end
  end

  local ok, res = pcall(rename, newPath, path)
  if not ok or res ~= 0 then
    if parked then pcall(rename, bakPath, path) end
    return false
  end
  return true
end

return M
