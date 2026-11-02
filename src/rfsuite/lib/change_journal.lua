-- Append-only, per-flight-controller record of values committed to EEPROM.
local M = {}

local USER_ROOT = "/SCRIPTS/TOOLS/rfsuite.user"
local DATA_DIR = USER_ROOT .. "/journal"
local READ_CAP, READ_CHUNK = 65536, 4096

function M.path(mcuId)
  if mcuId == nil then return nil end
  local id = string.match(tostring(mcuId), "^%s*(.-)%s*$")
  if id == "" then return nil end
  id = string.gsub(id, "[^%w_-]", "_")
  return DATA_DIR .. "/" .. id .. ".lua"
end

local function makeDir(path)
  if type(mkdir) ~= "function" then return end
  if type(path) ~= "string" or path == "" then return end
  pcall(mkdir, path)
end

local function ensureDir()
  makeDir(USER_ROOT)
  makeDir(DATA_DIR)
end

local function fileSize(path)
  if type(fstat) ~= "function" then return nil end
  local ok, st = pcall(fstat, path)
  if not ok or type(st) ~= "table" then return nil end
  return tonumber(st.size)
end

local function endsMidLine(path, size)
  local f = io.open(path, "r")
  if not f then return false end
  local ok, last = pcall(function()
    io.seek(f, size - 1) -- luacheck: ignore 143
    return io.read(f, 1)
  end)
  io.close(f)
  return ok and type(last) == "string" and last ~= "" and last ~= "\n"
end

local function integer(value)
  if type(value) ~= "number" then return nil end
  return math.tointeger(math.floor(value))
end

local function timestamp()
  if type(_G.getRtcTime) == "function" then
    return integer(_G.getRtcTime()) or 0
  end
  if type(_G.getDateTime) ~= "function" then return 0 end
  local dt = _G.getDateTime()
  if type(dt) ~= "table" then return 0 end
  local y, m, d = integer(dt.year), integer(dt.mon), integer(dt.day)
  local h, min, sec = integer(dt.hour), integer(dt.min), integer(dt.sec)
  if not y or not m or not d or not h or not min or not sec then return 0 end
  if y < 1970 or y > 2038 or m < 1 or m > 12 or d < 1 or d > 31
      or h < 0 or h > 23 or min < 0 or min > 59 or sec < 0 or sec > 59 then return 0 end
  -- Days from civil, with integer divisions throughout: a float loses seconds at today's dates
  -- on LUA_32BITS. Guard the final addition before it could overflow a signed 32-bit integer.
  if m <= 2 then y = y - 1 end
  local era = y // 400
  local yoe = y - era * 400
  local mp = m + (m > 2 and -3 or 9)
  local doy = (153 * mp + 2) // 5 + d - 1
  local days = era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
  if days < 0 or days > 24855 then return 0 end
  local base = days * 86400
  local seconds = h * 3600 + min * 60 + sec
  if seconds > 2147483647 - base then return 0 end
  return base + seconds
end

-- The radio clock in seconds, 0 without one. The Tune Advisor's flight capture stamps each saved
-- flight with it, so a flight and a change applied after it carry times from the same clock.
M.timestamp = timestamp

local function validName(value)
  return type(value) == "string" and string.match(value, "^[%w_%.]+$") ~= nil
end

function M.append(mcuId, entries)
  local path = M.path(mcuId)
  if not path then return false, "mcu id" end
  if type(entries) ~= "table" then return false, "entries" end
  local lines = {}
  local time = timestamp()
  for i = 1, #entries do
    local entry = entries[i]
    if type(entry) ~= "table" or not validName(entry.source) or not validName(entry.field) then
      return false, "entry"
    end
    local when = integer(entry.time == nil and time or entry.time)
    local profile, old, new = integer(entry.profile), integer(entry.old), integer(entry.new)
    if not when or not profile or profile < 1 or not old or not new then return false, "number" end
    lines[#lines + 1] = string.format("e(%d,%q,%d,%q,%d,%d)\n", when, entry.source, profile, entry.field, old, new)
  end
  if #lines == 0 then return true end
  local text = table.concat(lines)
  ensureDir()
  local before = fileSize(path)
  if before == nil then
    local created = io.open(path, "a")
    if not created then return false, "open" end
    io.close(created)
    before = fileSize(path)
    if before == nil then return false, "unmeasurable" end
  end
  if before > 0 and endsMidLine(path, before) then text = "\n" .. text end
  local f = io.open(path, "a")
  if not f then return false, "open" end
  io.write(f, text)
  io.close(f)
  local after = fileSize(path)
  if after == nil or after ~= before + #text then return false, "unverified" end
  return true
end

-- The journal grows with every save and may be read up to READ_CAP. Parsed in one go, a
-- journal of a thousand entries cost over a hundred thousand Lua instructions, far more than a
-- page's wakeup may take, so it is read as a job: the file on one step, then LINES_PER_STEP lines
-- per step. Each group of lines is loaded in one go; when that fails anywhere -- a line torn by a
-- write that was cut short, or one broken by hand -- the group is run again line by line and only
-- the lines that do not read are skipped.
local LINES_PER_STEP = 16

local function newCollector(job)
  local entries, fields = job.entries, job.fields
  return function(time, source, profile, field, old, new)
    -- Not asked for: dropped before anything else is looked at
    if fields and not fields[field] then return end
    if not integer(time) or not validName(source) or not integer(profile) or profile < 1
        or not validName(field) or not integer(old) or not integer(new) then error("invalid entry") end
    entries[#entries + 1] = { time = time, source = source, profile = profile, field = field, old = old, new = new }
  end
end

--- A read of one flight controller's journal in steps (see M.readStep). `fields`, when given, is a
--- set of field names: only their entries are kept.
function M.readJob(mcuId, fields)
  return { phase = "read", mcuId = mcuId, fields = fields }
end

--- One step of a job from readJob(): nothing while there is more to do, then what read() answers.
--- The first value is false while the job runs, so a caller can tell "more to do" (false) from
--- a failure (nil, reason) and from the entries (a table).
function M.readStep(job)
  if job.phase == "read" then
    job.phase = "done"
    local path = M.path(job.mcuId)
    if not path then return nil, "mcu id" end
    local size = fileSize(path)
    if size and size > READ_CAP then return nil, "too big" end
    local f = io.open(path, "r")
    if not f then
      if size ~= nil then return nil, "open" end
      return {}
    end
    local parts, total = {}, 0
    while true do
      local ok, chunk = pcall(io.read, f, math.min(READ_CHUNK, READ_CAP + 1 - total))
      if not ok then io.close(f); return nil, tostring(chunk) end
      if chunk == nil or chunk == "" then break end
      total = total + #chunk
      if total > READ_CAP then io.close(f); return nil, "too big" end
      parts[#parts + 1] = chunk
    end
    io.close(f)
    if size ~= nil and total ~= size then return nil, "short read" end
    job.text, job.pos, job.entries = table.concat(parts), 1, {}
    -- loadScript discards the environment and can create stale bytecode beside the journal.
    job.env = { e = newCollector(job) }
    job.phase = "parse"
    return false
  elseif job.phase == "parse" then
    local text, pos = job.text, job.pos
    local last = pos - 1
    for _ = 1, LINES_PER_STEP do
      local nextEnd = string.find(text, "\n", last + 1, true)
      if not nextEnd then last = #text; break end
      last = nextEnd
    end
    if last >= pos then
      local entries, env = job.entries, job.env
      local count = #entries
      local group = string.sub(text, pos, last)
      local chunk = load(group, "=change_journal", "t", env)
      if not (chunk and pcall(chunk)) then
        for i = #entries, count + 1, -1 do entries[i] = nil end
        for line in string.gmatch(group, "[^\r\n]+") do
          local before = #entries
          local lineChunk = load(line, "=change_journal", "t", env)
          if not lineChunk or not pcall(lineChunk) then
            for i = #entries, before + 1, -1 do entries[i] = nil end
          end
        end
      end
    end
    job.pos = last + 1
    if job.pos <= #text then return false end
    local entries = job.entries
    job.phase, job.text, job.env, job.entries = "done", nil, nil, nil
    return entries
  end
  return nil, "done"
end

--- The whole journal, oldest first: a table of entries ({} when there is no journal), or nil and
--- a reason when it is there but cannot be read ("too big", "open", "short read", ...).
function M.read(mcuId)
  local job = M.readJob(mcuId)
  while true do
    local entries, reason = M.readStep(job)
    if entries ~= false then return entries, reason end
  end
end

return M
