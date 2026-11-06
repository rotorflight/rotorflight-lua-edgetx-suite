-- What a radio set-up replaced, kept on the card per radio model, and how to put it back.
--
-- One plain text file per model file, parsed line by line and never compiled. It is keyed by the
-- model's FILE: the name can change while a flight controller is connected
-- (tasks/events/onconnect/tasks/model_name_sync.lua), the file does not. lib/config_store.lua cannot
-- hold it: its literal() writes scalars, and a table in an open section is dropped while the save
-- still succeeds.
--
-- A record is saved `partial` before the first write and marked `complete` after the last, and a
-- restore marks it `partial` again before its own first write, so anything stopped or cut off in the
-- middle leaves a record that says so. Its restore is offered whatever the model looks like, and the
-- page refuses a further set-up until it has run: the model that set-up would read is the damaged one.
--
-- Loaded for the job that needs it and released with the page; nothing of it stays resident.

local M = {}

local VERSION_LINE = "inflight-setup 1"
-- The last line, so a file cut off while being written is not taken for a record.
local END_LINE = "end"
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

local function isRecord(text)
  return type(text) == "string"
    and string.sub(text, 1, #VERSION_LINE) == VERSION_LINE
    and string.sub(text, -(#END_LINE + 2)) == "\n" .. END_LINE .. "\n"
end

--- The record of a model file. FAT's rename does not replace a file, so a save deletes the old one
-- first; a power cut between the two leaves the new one under its temporary name, read back and whole.
local function readRecord(path)
  local text = readAll(path)
  if isRecord(text) then return text end
  text = readAll(path .. ".tmp")
  if isRecord(text) then return text end
  return nil
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

local function encodeMix(line)
  local values = {}
  for f = 1, #Setup.MIX_FIELDS do values[f] = clean(line[Setup.MIX_FIELDS[f]]) end
  return table.concat(values, SEP)
end

--- The same line with every field the mixer API carries spelled out, as the radio reads it back: the
-- plan's line leaves out what it does not set.
local function encodeWritten(line)
  local values = {}
  for f = 1, #Setup.MIX_FIELDS do
    local key = Setup.MIX_FIELDS[f]
    local value = line[key]
    if value == nil then
      if key == "name" then value = "" elseif key == "carryTrim" then value = false else value = 0 end
    end
    values[f] = clean(value)
  end
  return table.concat(values, SEP)
end

--- The text of a record for a plan about to be carried out, in slices: every field of every line it
-- replaces does not fit beside a widget pass in one call.
function M.newEncode(plan, modelFile)
  local enc = {
    plan = plan, done = false, channel = 1, line = 0, tail = false,
    lines = { VERSION_LINE, "state" .. SEP .. "partial", "model" .. SEP .. clean(modelFile) }
  }
  return enc
end

--- The rest of a record after the replaced lines, each a line of its own: what the set-up leaves on
-- those channels, for the state check, and the variables, logical switch and trims it changes.
local function tailItems(plan)
  local items = {}
  for i = 1, #plan.insertions do items[#items + 1] = { "W", plan.insertions[i] } end
  for i = 1, #plan.gvars do items[#items + 1] = { "G", plan.gvars[i] } end
  if plan.ls ~= nil then items[#items + 1] = { "S", plan.ls } end
  for i = 1, #plan.trims do
    local entry = plan.trims[i]
    for j = 1, #entry.indexes do items[#items + 1] = { "T", entry, entry.indexes[j] } end
  end
  return items
end

local function encodeItem(lines, item)
  local kind, entry = item[1], item[2]
  if kind == "W" then
    lines[#lines + 1] = joined("W", entry.channel) .. SEP .. encodeWritten(entry.mix)
  elseif kind == "G" then
    local before = entry.before or {}
    lines[#lines + 1] = joined("G", entry.index, before.name, before.min, before.max, before.prec,
      before.unit, before.popup)
    local after = entry.details
    lines[#lines + 1] = joined("H", entry.index, after.name, after.min, after.max, after.prec, after.unit)
  elseif kind == "S" then
    local def = entry.def
    lines[#lines + 1] = joined("S", entry.slot, def.func, def.v1, def.v2, def["and"], def.delay, def.duration)
  else
    local index = item[3]
    lines[#lines + 1] = joined("T", entry.fm, index, entry.before[index], entry.modes[index])
  end
end

--- At most `count` replaced lines of a record. Answers true once `enc.text` is there.
function M.encodeStep(enc, count)
  if enc.done then return true end
  local channels = enc.plan.channels
  local left = count or math.huge
  while enc.channel <= #channels do
    local channel = channels[enc.channel]
    if enc.line == 0 then
      if left <= 0 then return false end
      enc.lines[#enc.lines + 1] = joined("C", channel.channel, channel.removed)
      enc.line = 1
    end
    while enc.line <= #channel.lines do
      if left <= 0 then return false end
      left = left - 1
      enc.lines[#enc.lines + 1] = joined("L", channel.channel, enc.line - 1) .. SEP .. encodeMix(channel.lines[enc.line])
      enc.line = enc.line + 1
    end
    enc.channel, enc.line = enc.channel + 1, 0
  end
  if enc.items == nil then
    enc.items = tailItems(enc.plan)
    enc.itemAt = 1
  end
  while enc.itemAt <= #enc.items do
    if left <= 0 then return false end
    left = left - 1
    encodeItem(enc.lines, enc.items[enc.itemAt])
    enc.itemAt = enc.itemAt + 1
  end
  if left <= 0 then return false end
  enc.lines[#enc.lines + 1] = END_LINE
  enc.text = table.concat(enc.lines, "\n") .. "\n"
  enc.lines, enc.items, enc.plan = nil, nil, nil
  enc.done = true
  return true
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
  -- A power cut between delete and rename leaves the record only under the temporary name. It goes back
  -- under its own first: the write below truncates that name, and this may be the only copy.
  if readAll(path) == nil and isRecord(readAll(temporary)) and rename(temporary, path) ~= 0 then return false end
  local file = io.open(temporary, "w")
  if not file then return false end
  local wrote = io.write(file, text)
  io.close(file)
  if not wrote or readAll(temporary) ~= text then return false end
  if readAll(path) ~= nil and del(path) ~= 0 then return false end
  return rename(temporary, path) == 0 and readAll(path) == text
end

--- Change a record's state, leaving the rest as it is. Answers false where there is no record or it
-- could not be written; the old one stands then, or its whole copy under the temporary name.
function M.markState(modelFile, state)
  local path = M.path(modelFile)
  local text = path and readRecord(path) or nil
  if text == nil then return false end
  local head = VERSION_LINE .. "\nstate" .. SEP
  if string.sub(text, 1, #head) ~= head then return false end
  local stop = string.find(text, "\n", #head + 1, true)
  if stop == nil then return false end
  return M.saveText(modelFile, head .. state .. string.sub(text, stop))
end

--- Forget the record. The set-up it belongs to has been put back.
function M.remove(modelFile)
  local path = M.path(modelFile)
  if not path or type(del) ~= "function" then return false end
  if readAll(path .. ".tmp") ~= nil then del(path .. ".tmp") end
  if readAll(path) == nil then return true end
  return del(path) == 0
end

--- The record's state only, `partial` or `complete`, or nil where there is none.
function M.stateOf(modelFile)
  local path = M.path(modelFile)
  local text = path and readRecord(path) or nil
  if text == nil then return nil end
  return string.match(text, "\nstate\t(%a+)")
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
  local text = path and readRecord(path) or nil
  if text == nil then return nil end
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
      local mix = {}
      for i = 1, #Setup.MIX_FIELDS do
        local key, raw = Setup.MIX_FIELDS[i], f[2 + i]
        if key == "name" then mix[key] = raw or ""
        elseif key == "carryTrim" then mix[key] = (raw == "true")
        else mix[key] = numberOr(raw, 0) end
      end
      record.written[#record.written + 1] = { channel = tonumber(f[2]), mix = mix }
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
        ["and"] = tonumber(f[6]), delay = tonumber(f[7]), duration = tonumber(f[8])
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
    if not Setup.sameLine(radio.mix(entry.channel, 0), entry.mix) then return false end
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
        or tonumber(have.v2) ~= ls.v2 or (tonumber(have["and"]) or 0) ~= (ls["and"] or 0)
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
