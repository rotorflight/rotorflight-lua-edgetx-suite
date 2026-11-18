-- Starts a flight controller's change journal (lib/change_journal.lua) afresh once it stands above
-- its ROTATE_AT, and carries the pilot's own values over into the new one.
--
-- The Tune Advisor finds the value the pilot last set by hand by following its own entries back
-- from the current value (lib/tune_history.lua pilotFold). Per profile and field, only the newest
-- unbroken chain of its own entries matters to that -- each starting at the value the one before
-- it ended at; any other entry on that profile and field ends the chain. The new journal holds one
-- line per such chain that is still open and moved the value: from where the chain started to
-- where it ended, with the time of its last entry. For every profile, field and current value the
-- fold over the new journal answers what it answers over the old one; everything else is left out.
--
-- Loaded only when the journal is due, and dropped after. It runs as a job, one step per pass:
-- the size on one step, then the whole file read READ_CHUNK bytes at a time and LINES_PER_STEP
-- lines parsed per step (never the file in one block), then the new text on one step and the
-- write on the next through lib/atomic_file.lua, which parks the journal before it as `.bak` --
-- the one earlier generation kept on the card. A journal that changed while it was read is not written: it is still above
-- ROTATE_AT, so the next try comes with the next append or the next open of the page.

local M = {}

local READ_CHUNK = 4096
local SOURCE = "tune_advisor"

local function log(level, fmt, ...)
  local Log = _G.rfsuite and _G.rfsuite.Log
  if type(Log) == "table" and type(Log.emitf) == "function" then
    pcall(Log.emitf, "rfsuite.journal_compact", level, fmt, ...)
  end
end

local function fileSize(path)
  if type(fstat) ~= "function" then return nil end
  local ok, st = pcall(fstat, path)
  if not ok or type(st) ~= "table" then return nil end
  return tonumber(st.size)
end

local function atomicFile()
  local req = _G.rfsuite and _G.rfsuite.require
  if type(req) == "function" then return req("lib/atomic_file.lua") end
  local chunk = loadScript(_G.rfsuite.paths.core .. "/lib/atomic_file.lua", (_G.rfsuite and _G.rfsuite.loadMode) or "bt")
  local ok, mod = pcall(chunk)
  return ok and type(mod) == "table" and mod or nil
end

--- The fold that decides what is carried: `add(entry)` for each entry, oldest first; `lines()`
--- answers the new journal's text. The chain rule is lib/tune_history.lua pilotFold's, for every
--- profile and field at once.
function M.carryFold()
  -- One chain per profile and field, in the order each pair first appears in the journal; a
  -- pair's line holds one value pair, so the order of the lines does not change any answer
  local chains, order = {}, {}
  local function add(e)
    -- A profile edited by hand to 1.0 is profile 1 to the fold (1.0 == 1), so it keys the same chain
    local profile = math.tointeger(e.profile) or e.profile
    local key = profile .. "/" .. e.field
    local c = chains[key]
    if e.source ~= SOURCE then
      if c then c.last = nil end
    elseif c and c.last ~= nil and c.last == e.old then
      c.last, c.time = e.new, e.time
    elseif c then
      c.first, c.last, c.time = e.old, e.new, e.time
    else
      c = { profile = profile, field = e.field, first = e.old, last = e.new, time = e.time }
      chains[key] = c
      order[#order + 1] = c
    end
  end
  local function lines()
    local open = {}
    for _, c in ipairs(order) do
      if c.last ~= nil and c.first ~= c.last then open[#open + 1] = c end
    end
    -- The reader takes a number that floors to an integer, so a line edited by hand can hold
    -- 50.5; it is carried as it reads, since that is the value the fold compares
    local function num(v)
      local i = math.tointeger(v)
      return i and tostring(i) or string.format("%.17g", v)
    end
    local out = {}
    for i, c in ipairs(open) do
      out[i] = string.format("e(%s,%q,%s,%q,%s,%s)\n", num(c.time), SOURCE, num(c.profile), c.field,
        num(c.first), num(c.last))
    end
    return table.concat(out), #out
  end
  return add, lines
end

--- A start afresh of one flight controller's journal, run by M.step. `journal` is the loaded
--- lib/change_journal.lua.
function M.job(journal, mcuId)
  return { phase = "size", journal = journal, path = journal.path(mcuId) }
end

local function finish(job, result, reason)
  job.phase, job.buf, job.parser, job.lines, job.text = "done", nil, nil, nil, nil
  return result, reason
end

--- One step: false while there is more to do, then true when the journal was started afresh, or
--- nil and a reason when it was not ("small", "size", "open", "read", "line", "changed",
--- "no gain", "write"). Whatever the answer, the journal before it is left whole.
function M.step(job)
  local phase = job.phase
  if phase == "size" then
    local path = job.path
    local size = path and fileSize(path)
    if not size then
      log("debug", "journal %s: size unknown, not started afresh", tostring(path))
      return finish(job, nil, "size")
    end
    if size <= job.journal.ROTATE_AT then return finish(job, nil, "small") end
    local add
    add, job.lines = M.carryFold()
    job.parser = job.journal.parser(add)
    job.size, job.offset, job.buf, job.pos = size, 0, "", 1
    job.phase = "fold"
    log("info", "journal %s: %d bytes, above %d; starting it afresh", path, size, job.journal.ROTATE_AT)
    return false
  elseif phase == "fold" then
    local buf, pos = job.buf, job.pos
    local want = job.journal.LINES_PER_STEP
    -- Where the group of whole lines this step parses ends
    local last, found = pos - 1, 0
    while found < want do
      local nextEnd = string.find(buf, "\n", last + 1, true)
      if not nextEnd then break end
      last, found = nextEnd, found + 1
    end
    if found == 0 and #buf - pos + 1 > READ_CHUNK then
      -- A line longer than a whole part: not one the suite wrote. The buffer is not let grow.
      log("debug", "journal %s: a line of over %d bytes at byte %d; left as it is", job.path, READ_CHUNK, job.offset)
      return finish(job, nil, "line")
    end
    if found < want and job.offset < job.size then
      -- Too few whole lines left: the next part of the file, read at its offset on this step
      local f = io.open(job.path, "r")
      if not f then
        log("debug", "journal %s: does not open at byte %d", job.path, job.offset)
        return finish(job, nil, "open")
      end
      local ok, chunk = true, nil
      if job.offset > 0 then
        local sought, err = pcall(io.seek, f, job.offset) -- luacheck: ignore 143
        ok = sought and (err == nil or err == 0)
      end
      if ok then ok, chunk = pcall(io.read, f, math.min(READ_CHUNK, job.size - job.offset)) end
      io.close(f)
      if not ok or type(chunk) ~= "string" or chunk == "" then
        log("debug", "journal %s: read at byte %d failed", job.path, job.offset)
        return finish(job, nil, "read")
      end
      job.buf = string.sub(buf, pos) .. chunk
      job.pos, job.offset = 1, job.offset + #chunk
      log("trace", "journal %s: read to byte %d of %d", job.path, job.offset, job.size)
      return false
    end
    if found == 0 then
      -- No line break left: the file's end, which may hold a last line without one
      if pos <= #buf then job.journal.parse(job.parser, string.sub(buf, pos)) end
      job.buf, job.pos = nil, nil
      job.phase = "text"
      return false
    end
    job.journal.parse(job.parser, string.sub(buf, pos, last))
    job.pos = last + 1
    return false
  elseif phase == "text" then
    -- The new journal's text on a step of its own, the write on the next
    job.text, job.count = job.lines()
    job.parser, job.lines = nil, nil
    log("trace", "journal %s: %d values to carry, %d bytes", job.path, job.count, #job.text)
    job.phase = "write"
    return false
  elseif phase == "write" then
    local path, text, count = job.path, job.text, job.count
    job.text = nil
    -- An append since the read began is not in the fold: the next try takes it in. Checked on
    -- the same step as the write, so nothing can be appended between the two.
    local size = fileSize(path)
    if size ~= job.size then
      log("info", "journal %s: changed while it was read (%s of %d bytes); left as it is", path, tostring(size), job.size)
      return finish(job, nil, "changed")
    end
    if #text >= size then
      log("info", "journal %s: %d bytes carried of %d; nothing gained, left as it is", path, #text, size)
      return finish(job, nil, "no gain")
    end
    local AtomicFile = atomicFile()
    if not (AtomicFile and AtomicFile.replace(path, text, false) == true) then
      log("debug", "journal %s: the new journal could not be put in place; the old one stands", path)
      return finish(job, nil, "write")
    end
    log("info", "journal %s: started afresh, %d bytes to %d, %d values carried", path, size, #text, count)
    return finish(job, true)
  end
  return nil, "done"
end

return M
