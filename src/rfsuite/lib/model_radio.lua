-- The active model's channels, inputs and switches, for the Rotorflight model template.
--
-- Everything here reads or writes the ACTIVE EdgeTX model. Lua registers no model selection
-- function, so a write can only ever reach the model the pilot has open.

local M = {}

-- Channels the template lays out, in the order it walks them.
--
-- A channel carries a LIST of roles rather than one, on both sides, and the simplification that
-- it carries exactly one fails on real layouts in both directions: the documented blackbox
-- channel is one channel driving two mode boxes at two windows, and the throttle channel needs a
-- hold and a governor source at once. Only one role each is populated here, and the shape is a
-- list so that adding the second is data rather than a rewrite.
--
-- `kind` decides which value window is computed and what is written beside the mix:
--   condition  - one position turns a flight controller mode on, the rest leave it off
--   throttle   - two mixer lines, and the firmware has no mode box for a throttle hold at all
--   adjustment - the whole travel is mapped onto a value range, in adjustment slots
--
-- `tier` has four values and the fourth is not decoration: *required*, *recommended*, *optional*
-- and **unavailable** -- a channel the template knows about and cannot deliver today. Marking
-- such a channel *recommended* would promise something the run does not keep.
-- `input`, `inputName` and `channelName` are the layout itself rather than decoration on it. The
-- source belongs in the INPUT and the mixer line carries nothing but that input: writing the
-- switch straight into the mixer line produces the identical channel value and is not the same
-- setup, because it leaves the input list empty and the transmitter then shows nothing at the
-- place the configuration belongs to. A layout whose channels are called CH5..CH8 is one nobody
-- can check by looking, either.
--
-- The two name lengths differ and neither is generous: a colour radio stores four characters for
-- an input name and six for a channel name. These are chosen to fit rather than to be truncated
-- by the radio afterwards, because a truncated name would never again equal what the completion
-- criterion compares it against.
M.CHANNELS = {
  {
    -- A two-position switch, and the pilot names the POSITION that arms -- a safety function
    -- has no defensible default, and which end of a switch means on is the pilot's convention
    -- rather than anything the machine could settle. The channel is built so that exactly the
    -- named position reads at the top of the travel, whichever way the switch is mounted.
    channel = 5, input = 4, key = "arm", tier = "required",
    exactPositions = 2,
    inputName = "Arm", channelName = "Arming",
    roles = { { kind = "condition", box = "ARM" } }
  },
  {
    -- The one channel that carries TWO switches, and both live on its own input as
    -- ALTERNATIVE lines, the reference construction: MAX at -100 gated by the lock position,
    -- the governor switch at full weight beneath it. Expo lines are alternatives -- the first
    -- whose gate matches wins -- so the lock rules exactly one position and every other
    -- carries the governor's travel.
    channel = 6, input = 5, key = "throttle", tier = "required",
    inputName = "Thr", channelName = "Thr",
    roles = { { kind = "throttle" } }
  },
  {
    -- Profile selection is not a mode box: it is two adjustment slots, the rate profile and the
    -- pid profile, driven continuously from one three-position switch onto 1..3.
    -- Required rather than recommended, by the pilot's ruling: the three flight modes are not an
    -- extra. A required channel is settled once and carried out, which is also why its own screen
    -- no longer offers a way to switch it back off.
    channel = 7, input = 6, key = "profile", tier = "required",
    inputName = "Prof", channelName = "Prof",
    needsPositions = 3,
    roles = { { kind = "adjustment", functions = { 1, 2 }, min = 1, max = 3 } }
  },
  {
    channel = 8, input = 7, key = "rescue", tier = "recommended",
    exactPositions = 2,
    inputName = "Res", channelName = "Rescue",
    roles = { { kind = "condition", box = "RESCUE" } }
  }
}

local function callGlobal(name, ...)
  local fn = _G and _G[name]
  if type(fn) ~= "function" then return nil end
  local ok, a, b = pcall(fn, ...)
  if not ok then return nil end
  return a, b
end

local function modelApi(name)
  local model = _G and _G.model
  if type(model) ~= "table" then return nil end
  local fn = model[name]
  if type(fn) ~= "function" then return nil end
  return fn
end

function M.mixesCount(channel)
  local fn = modelApi("getMixesCount")
  if not fn then return nil end
  local ok, value = pcall(fn, channel - 1)
  if not ok then return nil end
  return tonumber(value) or 0
end

function M.getOutput(channel)
  local fn = modelApi("getOutput")
  if not fn then return nil end
  local ok, out = pcall(fn, channel - 1)
  if not ok or type(out) ~= "table" then return nil end
  return out
end

-- The sign EVERY line this template writes on a channel has to carry.
--
-- `revert` negates the whole channel after the mixer, so a channel written without accounting
-- for it delivers the mirror image of what the flight controller was told to expect. Every line
-- this file writes is linear, at offset zero and without a curve, so negating each line's weight
-- cancels the revert exactly.
--
-- It is one function because the three writers and the two read-backs have to agree: a weight
-- stored by one and interpreted by the other is the same fact twice, and two copies of it drift.
-- `nil` where the model cannot be read -- a sign that cannot be established is not guessed.
function M.outputSign(channel)
  local output = M.getOutput(channel)
  if output == nil then return nil end
  if tonumber(output.revert) ~= 0 then return -1 end
  return 1
end

-- A switch position, as the radio's own picker returns it. Positions are grouped three to a
-- switch from the first switch onward, which is what lets a single field carry both halves of
-- the answer: which switch, and which of its states.
local SWSRC_FIRST_SWITCH = 1
local POSITIONS_PER_SWITCH = 3

-- Trim, as an input carries it. The firmware stores it inverted against what Lua reads and
-- writes, so the value a script sees is the one the radio's own input editor shows: 0 is the
-- trim of the input's own stick, and -1 is no trim at all. Anything below -1 names another
-- stick's trim.
--
-- Every input this template lays out gets -1. A flight controller holds the model itself and a
-- trim under it moves the neutral the controller was calibrated against, so a trim that is one
-- click off is a craft that flies away from centre and a stick position that no longer means
-- what the board was told it means.
M.TRIM_OFF = -1

M.POSITION_MIDDLE = 1

function M.switchNumber(swsrc)
  swsrc = tonumber(swsrc)
  if swsrc == nil or swsrc < SWSRC_FIRST_SWITCH then return nil end
  return math.floor((swsrc - SWSRC_FIRST_SWITCH) / POSITIONS_PER_SWITCH)
end

function M.switchPosition(swsrc)
  swsrc = tonumber(swsrc)
  if swsrc == nil or swsrc < SWSRC_FIRST_SWITCH then return nil end
  return (swsrc - SWSRC_FIRST_SWITCH) % POSITIONS_PER_SWITCH
end

function M.firstPositionOf(swsrc)
  local number = M.switchNumber(swsrc)
  if number == nil then return nil end
  return SWSRC_FIRST_SWITCH + number * POSITIONS_PER_SWITCH
end

function M.switchPositionName(swsrc)
  return callGlobal("getSwitchName", swsrc)
end

-- The name of the switch itself, without the position symbol the radio appends. The upper and
-- lower symbols are two bytes wide and the middle one is a single hyphen, so how much to drop
-- follows from the position rather than from guessing at the encoding.
function M.switchBaseName(swsrc)
  local name = M.switchPositionName(swsrc)
  if type(name) ~= "string" or name == "" then return nil end
  local drop = 2
  if M.switchPosition(swsrc) == M.POSITION_MIDDLE then drop = 1 end
  if #name <= drop then return nil end
  return string.sub(name, 1, #name - drop)
end

-- The mix source of the switch a position belongs to. A switch and its own source carry the
-- same name, a custom one included, so the lookup goes through the name rather than through a
-- constant Lua is never told. A nil answer means the switch cannot be expressed as a mix
-- source, and then nothing is written for it.
function M.switchSource(swsrc)
  local base = M.switchBaseName(swsrc)
  if base == nil then return nil, nil end
  local id = callGlobal("getSourceIndex", base)
  if id ~= nil then return tonumber(id), base end
  local info = callGlobal("getFieldInfo", base)
  if type(info) == "table" and info.id ~= nil then return tonumber(info.id), base end
  return nil, base
end

-- The physical switches this radio has, one entry per SWITCH rather than per position.
--
-- A channel that carries a VALUE across the whole travel -- the profile channel is the one -- is
-- answered by naming a switch: all three of its positions are spoken for, one per profile. The
-- radio's own picker only ever returns a position, so asking with it offers three spellings of
-- the same answer and then discards two of them. `minPositions` filters to switches that can
-- actually carry the function, which leaves nothing for a "this needs three positions" complaint
-- to be about.
local MAX_SWITCHES = 32

function M.switches(minPositions)
  minPositions = tonumber(minPositions) or 2
  local list = {}
  for number = 0, MAX_SWITCHES - 1 do
    local first = SWSRC_FIRST_SWITCH + number * POSITIONS_PER_SWITCH
    local count = M.switchPositionCount(first)
    local name = count and M.switchBaseName(first) or nil
    if name ~= nil and count >= minPositions then
      list[#list + 1] = { swsrc = first, name = name, positions = count }
    end
  end
  return list
end

-- The switch a mix SOURCE stands for, and it is the other half of the radio's own source picker.
--
-- That picker answers with a source id -- one entry per SWITCH rather than one per position, which
-- is the shape a channel carrying a value across the whole travel actually needs -- and the id it
-- returns is exactly what goes into the input. Everything else on this path is expressed in switch
-- POSITIONS, so the two have to meet somewhere, and this is it.
--
-- Walked rather than computed. The first id of the switch block is not a constant Lua is ever
-- told, and deriving it from one radio's numbering would be a guess that happens to hold there.
function M.switchFromSource(id)
  id = tonumber(id)
  if id == nil or id == 0 then return nil end
  for number = 0, MAX_SWITCHES - 1 do
    local first = SWSRC_FIRST_SWITCH + number * POSITIONS_PER_SWITCH
    local source = M.switchSource(first)
    if source ~= nil and source == id then
      return first, M.switchBaseName(first), M.switchPositionCount(first)
    end
  end
  return nil
end

-- How many positions this switch actually has. A two-position switch has no middle, so it
-- never rests at centre and its windows are the two ends alone.
function M.switchPositionCount(swsrc)
  local first = M.firstPositionOf(swsrc)
  if first == nil then return nil end
  local count = 0
  for offset = 0, POSITIONS_PER_SWITCH - 1 do
    if M.switchPositionName(first + offset) ~= nil then count = count + 1 end
  end
  if count == 0 then return nil end
  return count
end

-- Writing. Nothing here is called until the pilot has seen the whole list on one screen and
-- pressed once: an assistant that writes a channel per step leaves states behind that are not
-- safe on their own.
function M.clearChannel(channel)
  local fn = modelApi("deleteMix")
  if not fn then return false end
  local count = M.mixesCount(channel) or 0
  for _ = 1, count do
    local ok = pcall(fn, channel - 1, 0)
    if not ok then return false end
  end
  return true
end

local MULTIPLEX_ADD = 0

-- The throttle channel, in the REFERENCE construction: the channel is a plain one-to-one from
-- its own input, and the whole shape lives on that input's two ALTERNATIVE lines -- expo lines
-- are alternatives, the first whose gate matches wins. Line one is MAX at -100, gated by the
-- one position the pilot names as the LOCK, so exactly that position pins the motor; line two
-- is the governor switch at full weight, so every other position carries its travel -- off,
-- spool-up, flight. This is the shape the pilot's own reference models carry and the shape the
-- template's wizard writes, and having ONE construction is the point: the template proposes
-- it back instead of re-asking in different words.
function M.writeThrottleChannel(entry, lockSwsrc, govSwsrc)
  local insert = modelApi("insertMix")
  local insertInput = modelApi("insertInput")
  local deleteInput = modelApi("deleteInput")
  if not insert or not insertInput or not deleteInput then return false, "no_model_api" end
  if entry.input == nil then return false, "no_input" end
  if govSwsrc == nil or govSwsrc == 0 then return false, "no_gov" end

  -- The hold line pins the motor by forcing MAX to the BOTTOM of the travel. On a reverted
  -- channel an unsigned -100 arrives at the top of it instead -- full throttle in exactly the
  -- position the pilot named as the lock -- so this is the channel where the sign matters most.
  local sign = M.outputSign(entry.channel)
  if sign == nil then return false, "no_output" end

  local maxSource = M.plainSource("MAX")
  if maxSource == nil then return false, "no_max" end
  local govSource = M.switchSource(govSwsrc)
  if govSource == nil then return false, "no_source" end
  local mixSource = M.inputSource(entry.input)
  if mixSource == nil then return false, "no_input_source" end

  local function line(source, weight, gate, name)
    return {
      name = name or "",
      inputName = entry.inputName,
      source = source,
      weight = weight,
      offset = 0,
      switch = gate or 0,
      curveType = 0,
      curveValue = 0,
      scale = 0,
      side = 3,
      trimSource = M.TRIM_OFF,
      flightModes = 0
    }
  end

  local count = M.inputCount(entry.input) or 0
  for _ = 1, count do
    if not pcall(deleteInput, entry.input, 0) then return false, "clear_input_failed" end
  end
  if not pcall(insertInput, entry.input, 0, line(maxSource, -100 * sign, lockSwsrc, "Hold")) then
    return false, "insert_input_failed"
  end
  if not pcall(insertInput, entry.input, 1, line(govSource, 100 * sign, 0, "GOV")) then
    return false, "insert_input_failed"
  end

  if not M.clearChannel(entry.channel) then return false, "clear_failed" end
  local ok = pcall(insert, entry.channel - 1, 0, {
    source = mixSource,
    weight = 100,
    offset = 0,
    switch = 0,
    multiplex = MULTIPLEX_ADD,
    curveType = 0,
    curveValue = 0,
    flightModes = 0
  })
  if not ok then return false, "insert_failed" end
  M.setChannelName(entry.channel, entry.channelName)
  return true
end

-- A plain source by the name the firmware knows it under -- MAX is the one this file needs:
-- the reference construction pins the hold line to the top of the travel through it.
function M.plainSource(name)
  local id = callGlobal("getSourceIndex", name)
  if id ~= nil then return tonumber(id) end
  local info = callGlobal("getFieldInfo", name)
  if type(info) == "table" and info.id ~= nil then return tonumber(info.id) end
  return nil
end

-- The mix source that stands for an input. The inputs are the first block of mix sources -- the
-- enumeration opens with "none" and the input block follows it -- so input n is source n + 1. It
-- is derived rather than looked up by name because an input's NAME is something the pilot edits,
-- and a source resolved from a name would move when they rename it.
--
-- The bound is the control, and it is deliberately NOT a check that the radio knows the source.
-- The firmware only reports an input source as available while that input carries at least one
-- line, so asking for the source of an EMPTY input answers nothing -- which is precisely the
-- state every channel is in before this template lays it out. Using that as the control refused
-- the write on exactly the models the template exists for, and reported it as a channel that
-- could not be read rather than as one that is not there yet.
local MIXSRC_FIRST_INPUT = 1
local MAX_INPUTS = 32

function M.inputSource(inputIndex)
  inputIndex = tonumber(inputIndex)
  if inputIndex == nil or inputIndex < 0 or inputIndex >= MAX_INPUTS then return nil end
  return MIXSRC_FIRST_INPUT + inputIndex
end

function M.inputCount(inputIndex)
  local fn = modelApi("getInputsCount")
  if not fn then return nil end
  local ok, value = pcall(fn, inputIndex)
  if not ok then return nil end
  return tonumber(value) or 0
end

function M.setChannelName(channel, name)
  local fn = modelApi("setOutput")
  if not fn or type(name) ~= "string" then return false end
  local current = M.getOutput(channel)
  local value = { name = name }
  if current then
    value.min = tonumber(current.min)
    value.max = tonumber(current.max)
    value.offset = tonumber(current.offset)
    value.ppmCenter = tonumber(current.ppmCenter)
    value.symetrical = tonumber(current.symetrical)
    value.revert = tonumber(current.revert)
    -- `model.setOutput` clears the whole output before it applies the table, so a field left out
    -- here is erased rather than left as it was. `getOutput` reports the curve only where one is
    -- set, in the numbering `setOutput` takes back.
    value.curve = tonumber(current.curve)
  end
  return pcall(fn, channel - 1, value)
end

return M
