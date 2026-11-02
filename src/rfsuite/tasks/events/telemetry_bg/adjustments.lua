-- Announce in-flight adjustments: which function the pilot is changing, and its new value.
--
-- The flight controller reports an active adjustment in the custom telemetry stream as a
-- function id and a value (`AdjF` / `AdjV`, published by the `ADJ` row of the sensor table).
-- Nothing read them until now, and the switch that turns this on has been in Settings since
-- before it had an effect: `audio_events.adjustment_events`.
--
-- It runs on the telemetry pass rather than as an event runner of its own, for the same reason
-- `smart.lua` beside it does: what it reads is what the decoder in `tasks.lua` has just
-- published, so any other placement would be reading one pass behind.
--
-- The word files are already in the tree -- `SOUNDS/rf/<locale>/adj/` -- and are resolved
-- through `lib/audio.lua`, which owns the locale fallback. That module is loaded LAZILY, on the
-- first announcement rather than on the first pass, so a model that never touches an adjustment
-- never pays for it.

-- The telemetry task can load this file directly while a widget reaches it through the module
-- memoizer. loadScript creates a fresh table each time, so the Lua state's root owns this one
-- teller explicitly. Navigation and adjustment reports then share both the pending selection
-- and the report state, whichever loader arrived first.
local root = _G.rfsuite
if root and type(root.adjustmentAnnouncer) == "table" then return root.adjustmentAnnouncer end
local M = {}

local Audio = nil

-- The memoizer FIRST, so a host that has one hands over the instance it already holds -- and
-- the plain loader when it does not, or when it answers with nothing. Taking the memoizer's
-- answer as final was the first version of this and it is wrong in a way that is invisible on
-- a working card: a host without the memoizer would get nil for ever.
local function requireModule(path)
  local req = _G.rfsuite and _G.rfsuite.require
  if type(req) == "function" then
    local ok, mod = pcall(req, path)
    if ok and type(mod) == "table" then return mod end
  end
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/" .. path, mode)
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

-- How long the value has to stand still before it is announced. A pilot sweeping a pult would
-- otherwise start an announcement per step and finish none of them.
local SETTLE_SECONDS = 1.0
M.SELECTION_SETTLE_MS = 700

-- The function ids are the FIRMWARE's, `src/main/fc/rc_adjustments.h`, not a copy of the
-- sibling project's table -- which stops at 75 and therefore never announced the seven
-- governor and battery adjustments the firmware has carried since.
--
-- Each entry is the sequence of word files to play from `adj/`. Only words that exist in the
-- tree are used: an adjustment whose name cannot be spoken with them has NO entry, and the
-- teller then announces its value alone rather than announcing something else.
--
-- Ids 1-4 are the profile switches and 82 is the battery profile. They have no entry here and
-- are not announced at all, value included (SPOKEN_ELSEWHERE below): the suite already announces
-- a PID or rate profile change through its own `pid_profile` / `rate_profile` settings and a
-- battery profile change through `battery_profile`, and a second voice for the same event is
-- worse than none.
local ADJUSTMENTS
local function adjustmentWords(id)
  if not ADJUSTMENTS then
    local words = requireModule("tasks/events/telemetry_bg/adjustment_words.lua")
    if type(words) ~= "table" then error("adjustments.lua: word table missing", 0) end
    ADJUSTMENTS = words
  end
  return ADJUSTMENTS[id]
end

-- The firmware leaves 1-4 out of its report (`updateAdjustmentData` in `fc/rc_adjustments.c`),
-- but it does report 82, so without this the battery profile would be spoken twice: the value
-- here and the pack's capacity by `lib/audio.lua`.
local SPOKEN_ELSEWHERE = { [1] = true, [2] = true, [3] = true, [4] = true, [82] = true }

-- Every adjustment the firmware reports by a name also has the whole name as one recording, in the
-- Configurator's wording for the language (`inflight/fn/<id>.wav`), so what is spoken is what the
-- screen shows. Ids 5-29, 32-81, 83 and 84: the firmware has no 30 and 31 any more, and the
-- selectors are spoken elsewhere. The word table stays the fallback for an id outside that set.
local function nameFile(id)
  id = tonumber(id)
  if id == nil or id ~= math.floor(id) or id < 5 or id > 84 or id == 30 or id == 31 or id == 82 then return nil end
  -- A telemetry value can arrive as a float; 14.0 must still name 14.wav.
  return string.format("inflight/fn/%d.wav", math.floor(id))
end

local function speakName(audio, id)
  local file = nameFile(id)
  if file then audio.playEventFile(file); return true end
  local words = adjustmentWords(id)
  if words == nil then return false end
  for i = 1, #words do audio.playEventFile("adj/" .. words[i] .. ".wav") end
  return true
end

local state = {
  functionId = nil,
  value = nil,
  idleSeen = false,
  functionChanged = false,
  valueChanged = false,
  changedAt = nil,
}

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, v = pcall(getTime)
    if ok and type(v) == "number" then return v / 100 end
  end
  return 0
end

local function enabled()
  local root = _G and _G.rfsuite
  local prefs = root and root.preferences
  local events = prefs and prefs.audio_events
  return events ~= nil and events.adjustment_events == true
end

local function readSensor(name)
  if type(getValue) ~= "function" then return nil end
  local ok, v = pcall(getValue, name)
  if ok and type(v) == "number" then return v end
  return nil
end

-- Resolved on the first announcement rather than on the first pass, and NOT latched on a
-- failure. A latch here would trade one missed load -- the module not reachable yet on an early
-- pass -- for a teller that is silent for the rest of the session with nothing to say so. The
-- retry costs nothing that matters: it is reached once per announced adjustment, and on any host
-- with the require memoizer the second call is a table lookup.
local function ensureAudio()
  if Audio then return Audio end
  local mod = requireModule("lib/audio.lua")
  if type(mod) == "table" and type(mod.playEventFile) == "function" then
    Audio = mod
  end
  return Audio
end

-- One replaceable selection belongs to the same teller as AdjF/AdjV. Nothing is handed to the
-- firmware queue until it has rested; a newer focus drops the pending words, so a quick walk
-- across a list cannot leave a chain of obsolete names behind it. Ticks are supplied by the
-- caller, which also makes the settle boundary independent of the telemetry task's cadence.
local selection = nil
local selectionOwner = nil
-- One recording per group, with the group title the screen shows.
local GROUP_WORDS = {
  cyclic = "inflight/group/cyclic.wav", roll = "inflight/group/roll.wav", pitch = "inflight/group/pitch.wav",
  yaw = "inflight/group/yaw.wav", governor = "inflight/group/governor.wav", filter = "inflight/group/filter.wav",
  cross = "inflight/group/cross.wav", rates = "inflight/group/rates.wav", rescue = "inflight/group/rescue.wav",
  acc = "inflight/group/acc.wav", other = "inflight/group/other.wav"
}

local function allowed(audio)
  return audio ~= nil and (type(audio.adjustmentAllowed) ~= "function" or audio.adjustmentAllowed())
end

local function tone(audio)
  if audio and type(audio.playRawFile) == "function" then audio.playRawFile("/SOUNDS/rf/beep.wav") end
end

function M.select(owner, kind, id, value, ticks)
  selectionOwner = owner
  selection = { owner = owner, kind = kind, id = id, value = value,
    at = ticks + (kind == "value" and 0 or M.SELECTION_SETTLE_MS / 10) }
end

function M.cancelSelection(owner)
  if selectionOwner ~= owner then return end
  selection, selectionOwner = nil, nil
end

function M.endFeedback()
  local audio = ensureAudio()
  if allowed(audio) then tone(audio) end
end

-- Session feedback replaces unsettled selection speech and shares its enable/alarm guards.
local function sessionFeedback(owner, file)
  selectionOwner, selection = owner, nil
  if not enabled() then return end
  local audio = ensureAudio()
  if not allowed(audio) then return end
  audio.playEventFile(file)
end

function M.profile(owner, number)
  selectionOwner, selection = owner, nil
  if _G.rfsuite and _G.rfsuite.inflightProfileJob then return end
  if not enabled() then return end
  local audio = ensureAudio()
  if not allowed(audio) then return end
  audio.playEventFile("evt/profile.wav")
  if type(audio.playNumber) == "function" then audio.playNumber(number, 0) end
end

function M.pause(owner) sessionFeedback(owner, "inflight/paused.wav") end
function M.resumed(owner) sessionFeedback(owner, "inflight/resumed.wav") end

function M.selectionTick(ticks)
  if selection == nil or ticks < selection.at then return false end
  local pending = selection
  selection = nil
  if not enabled() then return false end
  local audio = ensureAudio()
  if not allowed(audio) then return false end
  if pending.kind == "value" then audio.playEventFile("inflight/selected.wav") end
  if pending.kind == "group" then
    local file = GROUP_WORDS[pending.id]
    if file then audio.playEventFile(file) else tone(audio) end
    return true
  end
  if not speakName(audio, pending.id) then tone(audio) end
  if pending.kind == "value" and pending.value ~= nil and type(audio.playNumber) == "function" then
    audio.playNumber(pending.value, 0)
  end
  return true
end

local function announce()
  if SPOKEN_ELSEWHERE[state.functionId] then return end
  local audio = ensureAudio()
  if not allowed(audio) then return end
  if state.functionChanged and audio then speakName(audio, state.functionId) end
  -- Through the audio module only, so the value is spoken at the same level as the words before
  -- it. Without the module there is no level to speak it at, and no words either: a bare number
  -- at the radio's own volume is not said.
  if audio and type(audio.playNumber) == "function" then
    audio.playNumber(state.value or 0, 0)
  end
end

function M.wakeup()
  if not enabled() then return end
  if M.selectionTick(nowSeconds() * 100) then return end
  if selection ~= nil then return end

  local functionId = readSensor("AdjF")
  local value = readSensor("AdjV")
  if functionId == nil or value == nil then return end

  -- Nothing is being adjusted. Do not announce, and do not remember it as a change either --
  -- the flight controller reports 0 between adjustments, and announcing that would put a
  -- spurious "0" after every one of them.
  if functionId == 0 then
    state.idleSeen = true
    return
  end

  local now = nowSeconds()

  -- The firmware reports an adjustment for 3 s after it was made, and 0 otherwise. A first
  -- reading that is not 0 is therefore an adjustment made just before this teller started or
  -- was reset, often one another Lua state's teller has already announced (the tool opening,
  -- the background function script starting, or the widget taking over from it) -- and it is
  -- joined rather than announced. Once a 0 has been read, nothing was being adjusted, so the
  -- next report is the pilot's: in the widget and the tool that is the first adjustment after
  -- every connect, since their teller is reset at each disconnect.
  if state.functionId == nil and not state.idleSeen then
    state.functionId, state.value = functionId, value
    return
  end

  if functionId ~= state.functionId then
    state.functionId = functionId
    state.functionChanged = true
    state.changedAt = now
  end
  if value ~= state.value then
    state.value = value
    state.valueChanged = true
    state.changedAt = now
  end

  if state.changedAt and (now - state.changedAt) >= SETTLE_SECONDS then
    state.changedAt = nil
    if state.functionChanged or state.valueChanged then
      announce()
    end
    state.functionChanged = false
    state.valueChanged = false
  end
end

function M.reset()
  selection, selectionOwner = nil, nil
  state.functionId = nil
  state.value = nil
  state.idleSeen = false
  state.functionChanged = false
  state.valueChanged = false
  state.changedAt = nil
end

if root then root.adjustmentAnnouncer = M end
return M
