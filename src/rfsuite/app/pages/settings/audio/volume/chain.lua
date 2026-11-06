-- app/pages/settings/audio/volume/chain.lua
-- Reads the model for the chain that lets a global variable set the radio's master volume, for the
-- Volume page's diagnosis. It reads and never writes.
--
-- EdgeTX's Volume special function cannot take a global variable as its source, so the chain has
-- three links, and the suite only knows the global variable:
--   an input whose source is GVx                      (model.getInput: `source`)
--   a logical switch a > x with a = GVx, x = -1024    (model.getLogicalSwitch: `func`, `v1`, `v2`)
--   a Volume special function switched by that logical switch, with that input as its source
--                                                     (model.getCustomFunction: `switch`, `func`, `value`)
-- Any slots will do, so all of them are searched: whatever combination forms a complete chain
-- counts. Mixes are not searched for GVx -- a mix that also uses it is the pilot's own business --
-- but every mix line is read for the switch and the source it names (see `free` below).
--
-- The encodings, from radio/src at EdgeTX 2.12:
--   * an input's `source` and a logical switch's `v1` are mix source numbers; GV n is
--     getFieldInfo("gvar1").id + n - 1, which the page already resolves for its picker.
--   * input k (0-based) as a mix source is MIXSRC_FIRST_INPUT + k (dataconstants.h: the inputs
--     are the first block after "none"; the same rule lib/model_radio.lua uses).
--   * for a logical switch on a global variable, `v2` is the raw value compared with
--     (switches.cpp, getLogicalSwitch: `y = ls->v2` once v1 is a global variable), so -1024 reads
--     back as -1024.
--   * logical switch k (0-based) as a switch is the index of "L01" + k (strhelpers.cpp names
--     them L01..L64); a NEGATIVE switch is the inverted one ("!L01"), which is not the chain.
--   * a Volume special function's source is its `value` field (functions.cpp calls
--     calcVolumeValue(CFN_PARAM(cfn)), and CFN_PARAM is all.val, which getCustomFunction
--     returns as `value`); `active` is 0 when the function is switched off.

local M = {}

-- radio/src/dataconstants.h: the same on every colour radio.
local MAX_INPUTS = 32
local MAX_LOGICAL_SWITCHES = 64
local MAX_SPECIAL_FUNCTIONS = 64

-- The value the suite writes when it lets go; the logical switch has to be false exactly then.
local RELEASE = -1024

local function api(name)
  local fn = type(model) == "table" and model[name] or nil
  if type(fn) == "function" then return fn end
  return nil
end

local function call(fn, ...)
  local ok, v = pcall(fn, ...)
  if ok then return v end
  return nil
end

-- The switch number of L01. Asked of the firmware by name; past it, the logical switches are the
-- last block of switches before ON (dataconstants.h, SWSRC_LAST_LOGICAL_SWITCH = SWSRC_LAST).
local function firstLogicalSwitch()
  if type(getSwitchIndex) == "function" then
    local idx = tonumber(call(getSwitchIndex, "L01"))
    if idx ~= nil and idx > 0 then return idx end
  end
  local last = tonumber(_G.SWSRC_LAST)
  if last ~= nil then return last - MAX_LOGICAL_SWITCHES + 1 end
  return nil
end

-- The mix source number of L01: a logical switch can be a SOURCE too (an input's source, a
-- comparison's `v1`, a special function's value), numbered in the mix source block of the logical
-- switches (dataconstants.h, MIXSRC_FIRST_LOGICAL_SWITCH), which Lua does not export by name;
-- "ls1" is its field (radio/src/lua/api_general.cpp, luaMultipleFields).
local function firstLogicalSwitchSource()
  if type(getFieldInfo) ~= "function" then return nil end
  local info = call(getFieldInfo, "ls1")
  if type(info) == "table" then return tonumber(info.id) end
  return nil
end

-- Which of a logical switch's `v1` and `v2` name a switch and which a source, by its function's
-- family (radio/src/switches.cpp, lswFamily and getLogicalSwitch; the order of
-- LogicalSwitchesFunctions in myeeprom.h): a == x .. |a| < x take a source in v1 and a value in
-- v2; AND, OR, XOR take two switches; Edge one; a == b, a > b, a < b two sources; the two delta
-- functions a source; Timer none; Sticky two switches. A function this radio does not export by
-- name is read as naming nothing.
local function lsOperands(func)
  local G = _G
  local aneg, xor, edge = tonumber(G.LS_FUNC_ANEG), tonumber(G.LS_FUNC_XOR), tonumber(G.LS_FUNC_EDGE)
  local less, adiff, sticky = tonumber(G.LS_FUNC_LESS), tonumber(G.LS_FUNC_ADIFFEGREATER), tonumber(G.LS_FUNC_STICKY)
  func = tonumber(func)
  if not (func and aneg and xor and edge and less and adiff and sticky) or func <= 0 then return nil, nil end
  if func <= aneg then return "source", nil end
  if func <= xor then return "switch", "switch" end
  if func == edge then return "switch", nil end
  if func <= less then return "source", "source" end
  if func <= adiff then return "source", nil end
  if func == sticky then return "switch", "switch" end
  return nil, nil
end

-- Whether a special function's `value` is a source (radio/src/functions.cpp): Volume, Play Value
-- and Backlight always; Adjust GV when its mode is Source or Source raw (AdjustGvarFunctionParam
-- in dataconstants.h: 1 and 2), not for a constant, another variable or +/-.
local function sfValueIsSource(cf)
  local G = _G
  local func = tonumber(cf.func)
  if func == nil then return false end
  if func == tonumber(G.FUNC_VOLUME) or func == tonumber(G.FUNC_PLAY_VALUE) or func == tonumber(G.FUNC_BACKLIGHT) then
    return true
  end
  local mode = tonumber(cf.mode)
  return func == tonumber(G.FUNC_ADJUST_GVAR) and (mode == 1 or mode == 2)
end

-- EdgeTX's MAX_FLIGHT_MODES, MAX_TIMERS and MAX_OUTPUT_CHANNELS on every colour radio
-- (radio/src/dataconstants.h).
local MAX_FLIGHT_MODES = 9
local MAX_TIMERS = 3
local MAX_CHANNELS = 32

--- What the model holds for global variable `gv` (1-based), whose mix source number is `gvSource`.
---
--- Returns a table:
---   readable  false when this radio cannot answer (no model getters, or a constant missing); the
---             page then says so instead of reporting a fault the model may not have.
---   complete  true when one input, one logical switch and one Volume function form the chain.
---   input, ls, sf
---             the slot found for each link, 0-based, or nil. With a complete chain, the chain's.
---   lsWrongX  { slot, x } for a logical switch a > x on GVx with another x, when none has -1024.
---   sfFault   { slot, kind, source | switch } for a Volume function on one link but not the
---             other: kind "source" (switched right, `source` is what it takes instead) or
---             "switch" (right source, `switch` is what switches it instead).
---   inputSource, lsSwitch
---             the mix source of the input found and the switch of the logical switch found, for
---             the page's names.
---   warn      the conditions that let the chain be found and still not do what it should.
---   free      { input, ls, sf }: the LAST free slot of each kind, 0-based, or nil when none is free
---             -- an input with no line, a logical switch with no function, a special function with no
---             switch (EdgeTX's own CFN_EMPTY; function 0 is a real function, Override channel) -- and
---             an empty input or logical switch counts as free only while no input line, mix line,
---             logical switch, special function, flight mode or timer still names it. `inputNamed` /
---             `lsNamed` are true when an empty one was passed over for that reason.
---   lines     the input lines the model uses; EdgeTX holds 64 in all (MAX_EXPOS), and inserting
---             one more silently writes nothing.
---   gvSource, firstInput, lsBase, vpos, volume
---             the encodings this answer was read with, for the page's names and for create.lua.
function M.read(gv, gvSource)
  local result = { readable = false }
  local getInputsCount, getInput = api("getInputsCount"), api("getInput")
  local getLogicalSwitch, getCustomFunction = api("getLogicalSwitch"), api("getCustomFunction")
  local vpos, volume = tonumber(_G.LS_FUNC_VPOS), tonumber(_G.FUNC_VOLUME)
  local firstInput = tonumber(_G.MIXSRC_FIRST_INPUT)
  local lsBase = firstLogicalSwitch()
  gvSource = tonumber(gvSource)
  if not (getInputsCount and getInput and getLogicalSwitch and getCustomFunction)
    or vpos == nil or volume == nil or firstInput == nil or lsBase == nil or gvSource == nil then
    return result
  end
  result.readable = true
  result.gvSource, result.firstInput, result.lsBase = gvSource, firstInput, lsBase
  result.vpos, result.volume = vpos, volume
  local free, lines = {}, 0
  result.free = free

  -- What the model's slots name, by switch number and by mix source number: an EMPTY input or
  -- logical switch that something still names is not free -- filling it would make that something
  -- act. An inverted one (negative) names the same slot.
  local namedSwitch, namedSource = {}, {}
  local function nameSwitch(v)
    v = tonumber(v)
    if v ~= nil and v ~= 0 then namedSwitch[math.abs(v)] = true end
  end
  local function nameSource(v)
    v = tonumber(v)
    if v ~= nil and v ~= 0 then namedSource[math.abs(v)] = true end
  end
  local emptyInputs, emptyLs = {}, {}

  -- Inputs whose source is GVx: by mix source number, the first line that carries it. Every line
  -- is read for what it names.
  local inputs, firstFound = {}, nil
  for i = 0, MAX_INPUTS - 1 do
    local answer = tonumber(call(getInputsCount, i))
    local count = answer or 0
    lines = lines + count
    -- Empty only on the firmware's own answer: an input it could not count is not taken as empty.
    if answer == 0 then emptyInputs[#emptyInputs + 1] = i end
    for l = 0, count - 1 do
      local line = call(getInput, i, l)
      if type(line) == "table" then
        nameSwitch(line.switch)
        nameSource(line.source)
        if inputs[firstInput + i] == nil and tonumber(line.source) == gvSource then
          inputs[firstInput + i] = { slot = i, line = line, lines = count }
          if firstFound == nil then firstFound = firstInput + i end
        end
      end
    end
  end

  -- Every mix line names a switch and a source (model.getMixesCount, model.getMix: `switch`,
  -- `source`); a radio without either getter has no mix counted.
  local getMixesCount, getMix = api("getMixesCount"), api("getMix")
  if getMixesCount and getMix then
    for ch = 0, MAX_CHANNELS - 1 do
      for l = 0, (tonumber(call(getMixesCount, ch)) or 0) - 1 do
        local mix = call(getMix, ch, l)
        if type(mix) == "table" then
          nameSwitch(mix.switch)
          nameSource(mix.source)
        end
      end
    end
  end

  -- Logical switches a > x on GVx with x = -1024, by switch number.
  local switches, firstSwitch, wrongX = {}, nil, nil
  for k = 0, MAX_LOGICAL_SWITCHES - 1 do
    local ls = call(getLogicalSwitch, k)
    if type(ls) == "table" and tonumber(ls.func) == 0 then emptyLs[#emptyLs + 1] = k end
    if type(ls) == "table" and (tonumber(ls.func) or 0) ~= 0 then
      nameSwitch(ls["and"])
      local a, b = lsOperands(ls.func)
      if a == "switch" then nameSwitch(ls.v1) elseif a == "source" then nameSource(ls.v1) end
      if b == "switch" then nameSwitch(ls.v2) elseif b == "source" then nameSource(ls.v2) end
    end
    if type(ls) == "table" and ls.func == vpos and tonumber(ls.v1) == gvSource then
      if tonumber(ls.v2) == RELEASE then
        switches[lsBase + k] = { slot = k, ls = ls }
        if firstSwitch == nil then firstSwitch = lsBase + k end
      elseif wrongX == nil then
        wrongX = { slot = k, x = tonumber(ls.v2) }
      end
    end
  end

  -- The Volume functions: the first one that joins a found switch to a found input is the chain.
  local chain, volumes = nil, {}
  for f = 0, MAX_SPECIAL_FUNCTIONS - 1 do
    local cf = call(getCustomFunction, f)
    if type(cf) == "table" and tonumber(cf.switch) == 0 then free.sf = f end
    -- An empty one (no switch) never acts, so what it names does not count.
    if type(cf) == "table" and (tonumber(cf.switch) or 0) ~= 0 then
      nameSwitch(cf.switch)
      if sfValueIsSource(cf) then nameSource(cf.value) end
    end
    if type(cf) == "table" and cf.func == volume then
      local entry = { slot = f, cf = cf, sw = tonumber(cf.switch), src = tonumber(cf.value) }
      volumes[#volumes + 1] = entry
      if chain == nil and switches[entry.sw] and inputs[entry.src] then chain = entry end
    end
  end

  -- The flight modes and timers name switches too (model.getFlightMode, model.getTimer); a radio
  -- without either getter has none of them counted. FM0 has no switch.
  local getFlightMode, getTimer = api("getFlightMode"), api("getTimer")
  local fmSwitch = {}
  if getFlightMode then
    for fm = 1, MAX_FLIGHT_MODES - 1 do
      local mode = call(getFlightMode, fm)
      if type(mode) == "table" then
        nameSwitch(mode.switch)
        fmSwitch[fm] = tonumber(mode.switch)
      end
    end
  end
  if getTimer then
    for n = 0, MAX_TIMERS - 1 do
      local timer = call(getTimer, n)
      if type(timer) == "table" then nameSwitch(timer.switch) end
    end
  end

  -- The last empty input and logical switch that nothing names.
  local lsSource = firstLogicalSwitchSource()
  for j = #emptyInputs, 1, -1 do
    local i = emptyInputs[j]
    if namedSource[firstInput + i] then
      free.inputNamed = true
    else
      free.input = i
      break
    end
  end
  for j = #emptyLs, 1, -1 do
    local k = emptyLs[j]
    if namedSwitch[lsBase + k] or (lsSource ~= nil and namedSource[lsSource + k]) then
      free.lsNamed = true
    else
      free.ls = k
      break
    end
  end

  -- The global variable in each flight mode, as EdgeTX's getter answers it: the value the mode
  -- uses, which is FM0's while the mode keeps EdgeTX's default ("use FM0's value"). A mode with
  -- a value of its own shows only as a different value. The input and the logical switch read the
  -- ACTIVE mode's value (mixer.cpp), and the suite writes FM0's. A mode with no switch is never
  -- active (getFlightMode in edgetx.cpp): a mode the firmware answers switch 0 for is skipped, one
  -- whose switch cannot be read still counts.
  local ownModes = nil
  local getGlobalVariable = api("getGlobalVariable")
  if getGlobalVariable then
    local base = tonumber(call(getGlobalVariable, gv - 1, 0))
    if base ~= nil then
      for fm = 1, MAX_FLIGHT_MODES - 1 do
        local v = fmSwitch[fm] ~= 0 and tonumber(call(getGlobalVariable, gv - 1, fm)) or nil
        if v ~= nil and v ~= base then
          ownModes = ownModes or {}
          ownModes[#ownModes + 1] = fm
        end
      end
    end
  end

  local inputKey, switchKey
  if chain then
    result.complete = true
    inputKey, switchKey = chain.src, chain.sw
    result.sf = chain.slot
  else
    inputKey, switchKey = firstFound, firstSwitch
    -- A Volume function on one link but not the other is the fault worth naming.
    for _, entry in ipairs(volumes) do
      if switches[entry.sw] then
        result.sfFault = { slot = entry.slot, kind = "source", source = entry.src }
        break
      end
      if inputs[entry.src] then
        result.sfFault = { slot = entry.slot, kind = "switch", switch = entry.sw }
        break
      end
    end
    if switchKey == nil then result.lsWrongX = wrongX end
  end

  result.lines = lines
  local warn = {}
  result.warn = warn
  local input = inputKey and inputs[inputKey]
  if input then
    result.input, result.inputSource = input.slot, inputKey
    local line = input.line
    local weight = tonumber(line.weight)
    if weight ~= nil and weight ~= 100 then warn.weight = weight end
    local offset = tonumber(line.offset)
    if offset ~= nil and offset ~= 0 then warn.offset = offset end
    -- Every curve type leaves the value as it is at curve value 0 (curves.cpp, applyCurve).
    if (tonumber(line.curveValue) or 0) ~= 0 then warn.curve = true end
    if (tonumber(line.switch) or 0) ~= 0 then warn.inputSwitch = true end
    if (tonumber(line.flightModes) or 0) ~= 0 then warn.flightModes = true end
    -- `side` is the line's Side (radio/src/myeeprom.h, EXPO_MODE_ENABLE): bit 1 lets negative
    -- values through, bit 2 positive ones, 3 both. On one side, the other half of the global
    -- variable's span reads as 0. Firmware before EdgeTX 2.11 has no `side` and is not warned.
    local side = tonumber(line.side)
    if side ~= nil and side ~= 3 then warn.side = side end
    -- Of an input's lines, the first one whose switch and flight modes let it through is the
    -- input's value and the lines after it are not looked at (mixer.cpp, applyExpos), so
    -- another line can take the input over from the global variable's.
    if input.lines > 1 then warn.lines = input.lines end
  end
  local switch = switchKey and switches[switchKey]
  if switch then
    result.ls, result.lsSwitch = switch.slot, switchKey
    local ls = switch.ls
    if (tonumber(ls["and"]) or 0) ~= 0 then warn.andSwitch = true end
    if (tonumber(ls.delay) or 0) ~= 0 then warn.delay = true end
    if (tonumber(ls.duration) or 0) ~= 0 then warn.duration = true end
  end
  if chain then
    if tonumber(chain.cf.active) == 0 then warn.sfOff = true end
    -- Two Volume functions that are both on fight over the volume; the one further down wins.
    for _, entry in ipairs(volumes) do
      if entry ~= chain and tonumber(entry.cf.active) ~= 0 and (entry.sw or 0) ~= 0 then
        warn.secondSf = entry.slot
        break
      end
    end
  end
  local details = api("getGlobalVariableDetails")
  local gvDetails = details and call(details, gv - 1)
  if type(gvDetails) == "table" and gvDetails.popup and gvDetails.popup ~= 0 then warn.popup = true end
  -- The flight modes (1..8) with a switch whose value of GVx is not FM0's: there the chain follows
  -- that value.
  warn.gvModes = ownModes

  return result
end

-- EdgeTX's MAX_EXPOS: the input lines of all inputs together (radio/src/dataconstants.h).
local MAX_INPUT_LINES = 64

--- What creating the chain would do with the model `read` described, or why it cannot.
---
--- Returns nil when there is nothing to create (unreadable, or complete). Otherwise a table:
---   input, ls, sf  { slot, create }: the slot of each link, `create` true where the link is missing
---                  and that slot is the last free one, false where a correct link is reused.
---   blocked        nil when Create can go ahead, else why not: "input_fault", "ls_fault",
---                  "ls_wrong_x", "sf_fault" (a link exists and is faulty -- it is never changed, the
---                  check above names the fault), "no_input", "no_lines", "no_ls", "no_sf" (no free slot),
---                  "no_input_named", "no_ls_named" (no free slot, and an empty one is still named).
function M.plan(result)
  if type(result) ~= "table" or not result.readable or result.complete then return nil end
  local warn, free = result.warn or {}, result.free or {}
  local plan = {}
  if result.input then
    if warn.weight or warn.offset or warn.curve or warn.inputSwitch or warn.flightModes
      or warn.side or warn.lines then
      plan.blocked = "input_fault"
    end
    plan.input = { slot = result.input, create = false }
  elseif free.input == nil then
    plan.blocked = plan.blocked or (free.inputNamed and "no_input_named" or "no_input")
  elseif (tonumber(result.lines) or MAX_INPUT_LINES) >= MAX_INPUT_LINES then
    plan.blocked = plan.blocked or "no_lines"
  else
    plan.input = { slot = free.input, create = true }
  end
  if result.ls then
    if warn.andSwitch or warn.delay or warn.duration then plan.blocked = plan.blocked or "ls_fault" end
    plan.ls = { slot = result.ls, create = false }
  elseif result.lsWrongX then
    plan.blocked = plan.blocked or "ls_wrong_x"
  elseif free.ls == nil then
    plan.blocked = plan.blocked or (free.lsNamed and "no_ls_named" or "no_ls")
  else
    plan.ls = { slot = free.ls, create = true }
  end
  if result.sfFault then
    plan.blocked = plan.blocked or "sf_fault"
  elseif free.sf == nil then
    plan.blocked = plan.blocked or "no_sf"
  else
    plan.sf = { slot = free.sf, create = true }
  end
  return plan
end

--- True when two plans would write the same links into the same slots.
function M.samePlan(a, b)
  if type(a) ~= "table" or type(b) ~= "table" or a.blocked or b.blocked then return false end
  for _, kind in ipairs({ "input", "ls", "sf" }) do
    local x, y = a[kind], b[kind]
    if not x or not y or x.slot ~= y.slot or x.create ~= y.create then return false end
  end
  return true
end

return M
