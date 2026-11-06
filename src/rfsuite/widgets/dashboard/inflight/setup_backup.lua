-- What a radio set-up replaced, kept on the card per radio model, and how to put it back.
--
-- One plain text file per model file, parsed line by line and never compiled. It is keyed by the
-- model's FILE: the name can change while a flight controller is connected
-- (tasks/events/onconnect/tasks/model_name_sync.lua), the file does not. lib/config_store.lua cannot
-- hold it: its literal() writes scalars, and a table in an open section is dropped while the save
-- still succeeds.
--
-- A record is saved `partial` before the first write and rewritten `complete` after the last, so a
-- set-up stopped or cut off in the middle leaves a record that says so. Its restore is offered
-- whatever the model looks like, and a further set-up does not replace it: the model it would read
-- is the damaged one.
--
-- Loaded for the job that needs it and released with the page; nothing of it stays resident.

local M = {}

local VERSION_LINE = "inflight-setup 1"
local SEP = "\t"
-- A bound on what is read back: a model has at most 64 mixer lines, each well under 256 bytes.
local MAX_BYTES = 32768

-- The mixer field list comes from the caller's setup module, whichever instance of it the page holds.
local Setup = nil

function M.bind(setup)
  Setup = setup
end

local function directory()
  return _G.rfsuite.paths.user .. "/inflight-setup"
end

--- Where a model file's record lives, or nil where there is no model file to key it by.
function M.path(modelFile)
  if type(modelFile) ~= "string" or modelFile == "" then return nil end
  local name = string.gsub(modelFile, "[^%w%._%-]", "_")
  return directory() .. "/" .. name .. ".txt"
end

local function readAll(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local parts, size = {}, 0
  while size < MAX_BYTES do
    local piece = io.read(file, 1024)
    if type(piece) ~= "string" or piece == "" then break end
    parts[#parts + 1] = piece
    size = size + #piece
  end
  io.close(file)
  return table.concat(parts)
end

--- A name cannot carry the separator or a line break: the radio's own name fields do not offer them.
local function clean(value)
  if value == nil then return "" end
  local text = string.gsub(tostring(value), "[\t\r\n]", " ")
  return text
end

local function joined(...)
  local parts = { ... }
  for i = 1, select("#", ...) do parts[i] = clean(parts[i]) end
  return table.concat(parts, SEP)
end

--- The text of a record for a plan about to be carried out.
function M.encode(plan, state, modelFile)
  local lines = { VERSION_LINE, "state" .. SEP .. state, "model" .. SEP .. clean(modelFile) }

  for i = 1, #plan.channels do
    local channel = plan.channels[i]
    lines[#lines + 1] = joined("C", channel.channel, channel.removed)
    for line0 = 1, #channel.lines do
      local values = {}
      local line = channel.lines[line0]
      for f = 1, #Setup.MIX_FIELDS do values[f] = clean(line[Setup.MIX_FIELDS[f]]) end
      lines[#lines + 1] = joined("L", channel.channel, line0 - 1) .. SEP .. table.concat(values, SEP)
    end
  end
  -- What the set-up leaves on those channels, for the state check.
  for i = 1, #plan.insertions do
    local entry = plan.insertions[i]
    lines[#lines + 1] = joined("W", entry.channel, entry.mix.source, entry.mix.weight, entry.mix.switch)
  end
  for i = 1, #plan.gvars do
    local entry = plan.gvars[i]
    local before = entry.before or {}
    lines[#lines + 1] = joined("G", entry.index, before.name, before.min, before.max, before.prec,
      before.unit, before.popup)
    local after = entry.details
    lines[#lines + 1] = joined("H", entry.index, after.name, after.min, after.max, after.prec, after.unit)
  end
  if plan.ls ~= nil then
    local def = plan.ls.def
    lines[#lines + 1] = joined("S", plan.ls.slot, def.func, def.v1, def.v2, def.delay, def.duration)
  end
  for i = 1, #plan.trims do
    local entry = plan.trims[i]
    for j = 1, #entry.indexes do
      local index = entry.indexes[j]
      lines[#lines + 1] = joined("T", entry.fm, index, entry.before[index], entry.modes[index])
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

--- Write a record so that a power cut leaves the old one or the new one, never half of either.
-- Read back before it counts: the set-up writes nothing unless this answers true.
function M.saveText(modelFile, text)
  local path = M.path(modelFile)
  if not path or type(text) ~= "string" then return false end
  if type(rename) ~= "function" or type(del) ~= "function" or type(mkdir) ~= "function" then return false end
  -- 0 made it, 8 it was there already (FR_EXIST).
  local made = mkdir(directory())
  if made ~= 0 and made ~= 8 then return false end
  local temporary = path .. ".tmp"
  local file = io.open(temporary, "w")
  if not file then return false end
  local wrote = io.write(file, text)
  io.close(file)
  if not wrote or readAll(temporary) ~= text then return false end
  if readAll(path) ~= nil and del(path) ~= 0 then return false end
  return rename(temporary, path) == 0 and readAll(path) == text
end

--- Forget the record. The set-up it belongs to has been put back.
function M.remove(modelFile)
  local path = M.path(modelFile)
  if not path or type(del) ~= "function" then return false end
  if readAll(path) == nil then return true end
  return del(path) == 0
end

--- The record's state only, `partial` or `complete`, or nil where there is none. One small read.
function M.stateOf(modelFile)
  local path = M.path(modelFile)
  if not path then return nil end
  local file = io.open(path, "r")
  if not file then return nil end
  local head = io.read(file, 64)
  io.close(file)
  if type(head) ~= "string" then return nil end
  if string.sub(head, 1, #VERSION_LINE) ~= VERSION_LINE then return nil end
  return string.match(head, "\nstate\t(%a+)")
end

local function fieldsOf(line)
  local out, n = {}, 0
  for piece in string.gmatch(line .. SEP, "([^\t]*)\t") do
    n = n + 1
    out[n] = piece
  end
  return out
end

local function numberOr(value, fallback)
  local number = tonumber(value)
  if number == nil then return fallback end
  return number
end

--- The read of a record, line by line: parsing all of a full model's lines does not fit in a pass.
function M.newParse(modelFile)
  local path = M.path(modelFile)
  local text = path and readAll(path) or nil
  if type(text) ~= "string" or string.sub(text, 1, #VERSION_LINE) ~= VERSION_LINE then return nil end
  return {
    text = text, at = #VERSION_LINE + 2, done = false,
    record = { channels = {}, written = {}, gvars = {}, details = {}, trims = {} }
  }
end

--- At most `count` lines of a record. Answers true once it is all read.
function M.parseStep(parse, count)
  if parse.done then return true end
  local record = parse.record
  local left = count or math.huge
  while left > 0 do
    local stop = string.find(parse.text, "\n", parse.at, true)
    if stop == nil then
      parse.done = true
      parse.text = nil
      return true
    end
    local line = string.sub(parse.text, parse.at, stop - 1)
    parse.at = stop + 1
    left = left - 1
    local f = fieldsOf(line)
    local kind = f[1]
    if kind == "state" then
      record.state = f[2]
    elseif kind == "C" then
      record.channels[#record.channels + 1] = { channel = tonumber(f[2]), lines = {} }
    elseif kind == "L" then
      local mix = {}
      for i = 1, #Setup.MIX_FIELDS do
        local key, raw = Setup.MIX_FIELDS[i], f[3 + i]
        if key == "name" then mix[key] = raw or ""
        elseif key == "carryTrim" then mix[key] = (raw == "true")
        else mix[key] = numberOr(raw, 0) end
      end
      for i = 1, #record.channels do
        if record.channels[i].channel == tonumber(f[2]) then
          local lines = record.channels[i].lines
          lines[#lines + 1] = mix
        end
      end
    elseif kind == "W" then
      record.written[#record.written + 1] = {
        channel = tonumber(f[2]), source = tonumber(f[3]), weight = tonumber(f[4]), switch = tonumber(f[5])
      }
    elseif kind == "G" then
      record.gvars[#record.gvars + 1] = {
        index = tonumber(f[2]), name = f[3] or "", min = tonumber(f[4]), max = tonumber(f[5]),
        prec = tonumber(f[6]), unit = tonumber(f[7]), popup = (f[8] == "true")
      }
    elseif kind == "H" then
      record.details[#record.details + 1] = {
        index = tonumber(f[2]), name = f[3] or "", min = tonumber(f[4]), max = tonumber(f[5]),
        prec = tonumber(f[6]), unit = tonumber(f[7])
      }
    elseif kind == "S" then
      record.ls = {
        slot = tonumber(f[2]), func = tonumber(f[3]), v1 = tonumber(f[4]), v2 = tonumber(f[5]),
        delay = tonumber(f[6]), duration = tonumber(f[7])
      }
    elseif kind == "T" then
      record.trims[#record.trims + 1] = {
        fm = tonumber(f[2]), index = tonumber(f[3]), before = tonumber(f[4]), after = tonumber(f[5])
      }
    end
  end
  return false
end

--- Whether the model still carries what the set-up wrote. If anything of it has changed since, the
-- saved lines belong to a model that no longer exists, and putting them back would overwrite the
-- pilot's own later work.
function M.stillCarries(radio, record)
  for i = 1, #record.written do
    local entry = record.written[i]
    if radio.mixesCount(entry.channel) ~= 1 then return false end
    local line = radio.mix(entry.channel, 0)
    if type(line) ~= "table" or tonumber(line.source) ~= entry.source
        or tonumber(line.weight) ~= entry.weight or tonumber(line.switch) ~= entry.switch then
      return false
    end
  end
  for i = 1, #record.details do
    local entry = record.details[i]
    local have = radio.globalVariableDetails(entry.index - 1)
    if type(have) ~= "table" or tostring(have.name or "") ~= entry.name
        or tonumber(have.min) ~= entry.min or tonumber(have.max) ~= entry.max
        or tonumber(have.prec) ~= entry.prec or tonumber(have.unit) ~= entry.unit then
      return false
    end
  end
  local ls = record.ls
  if ls ~= nil then
    local have = radio.logicalSwitch(ls.slot)
    if type(have) ~= "table" or tonumber(have.func) ~= ls.func or tonumber(have.v1) ~= ls.v1
        or tonumber(have.delay) ~= ls.delay or tonumber(have.duration) ~= ls.duration then
      return false
    end
  end
  for i = 1, #record.trims do
    local entry = record.trims[i]
    local data = radio.flightModeData(entry.fm)
    local modes = type(data) == "table" and data.trimsModes or nil
    if type(modes) ~= "table" or tonumber(modes[entry.index]) ~= entry.after then return false end
  end
  return true
end

--- The restore, as a plan of the shape M.newApplyJob takes. Only what the set-up touched is written;
-- the lines standing on its channels now go, whatever a stopped set-up left there.
function M.restorePlan(radio, record)
  local plan = { ok = true, gvars = {}, deletions = {}, insertions = {}, trims = {}, verify = {}, channels = {} }
  for i = 1, #record.gvars do
    local entry = record.gvars[i]
    if entry.min ~= nil then
      plan.gvars[#plan.gvars + 1] = {
        index = entry.index,
        details = {
          name = entry.name, min = entry.min, max = entry.max, prec = entry.prec, unit = entry.unit,
          popup = entry.popup
        }
      }
    end
  end
  for i = 1, #record.channels do
    local channel = record.channels[i]
    local count = radio.mixesCount(channel.channel) or 0
    for line0 = count - 1, 0, -1 do
      plan.deletions[#plan.deletions + 1] = { channel = channel.channel, line0 = line0 }
    end
    for line0 = 1, #channel.lines do
      plan.insertions[#plan.insertions + 1] = {
        channel = channel.channel, line0 = line0 - 1, mix = channel.lines[line0]
      }
      plan.verify[#plan.verify + 1] = { channel = channel.channel, line0 = line0 - 1, mix = channel.lines[line0] }
    end
    plan.channels[#plan.channels + 1] = { channel = channel.channel, removed = #channel.lines }
  end
  -- The slot the set-up filled was empty before it, or it would have been left alone.
  if record.ls ~= nil then
    plan.ls = { slot = record.ls.slot, def = { func = 0 } }
  end
  local byMode = {}
  for i = 1, #record.trims do
    local entry = record.trims[i]
    if entry.before ~= nil then
      local mode = byMode[entry.fm]
      if mode == nil then
        mode = { fm = entry.fm, modes = {}, indexes = {} }
        byMode[entry.fm] = mode
        plan.trims[#plan.trims + 1] = mode
      end
      mode.modes[entry.index] = entry.before
      mode.indexes[#mode.indexes + 1] = entry.index
    end
  end
  return plan
end

return M
