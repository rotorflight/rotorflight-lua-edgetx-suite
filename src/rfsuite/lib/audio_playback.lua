-- The playback half of the announcements: a file of the sound pack found through the locale
-- folders, a number through the radio's number teller, both at the level Settings > Audio > Volume
-- sets, and the window in which an alarm keeps the advisory voices quiet.
--
-- lib/audio.lua decides WHAT is announced and WHEN, and plays through this module; so does the
-- adjustment teller (tasks/events/telemetry_bg/adjustments.lua), which needs nothing else of
-- lib/audio.lua. A Lua state that runs only the teller -- the background function script, or a
-- service widget without the dashboard -- therefore loads this module alone. Where both are
-- loaded they share this one instance through the module loader, so the level lib/audio.lua sets
-- is the level the teller speaks at, and an alarm lib/audio.lua plays keeps the teller quiet.

-- One instance per Lua state, whichever loader arrives: the module loader, or a plain load where
-- the loader answered with nothing. A second instance would keep a level and an alarm window of
-- its own, so the state's root owns this one, as it owns the adjustment teller.
local root = _G.rfsuite
if root and type(root.audioPlayback) == "table" then return root.audioPlayback end

local M = {}

local AUDIO_PACK_BASE = "/SOUNDS/"
local AUDIO_DEFAULT_FALLBACK = "en"
local localeModule = nil

-- What lib/audio.lua writes and this module reads. One table, so both halves see the same values.
local S = {
  -- The level set under Settings > Audio > Volume (1..5), or nil for the radio's own Wav volume.
  -- EdgeTX takes it as the second argument of playFile and as the FOURTH of playNumber, after the
  -- attributes (radio/src/lua/api_general.cpp); in third place it would be read as attributes.
  level = nil,
  -- Set by the first refresh of the master volume in this Lua state (lib/audio.lua,
  -- refresh_volume_state). The dashboard and the tool reach it on their audio passes; the
  -- background function script (src/functions/rfsbg.lua) and the service widget run the
  -- adjustment teller without them and never do.
  driven = false,
  -- When the Alert Level ends, on this Lua state's clock (nowSeconds); before it, every refresh of
  -- the master volume asks for the Alert Level. 0 until the first critical announcement.
  boostUntil = 0,
  -- When the alarm window that keeps adjustment names and values quiet ends.
  quietUntil = 0,
}
M.state = S

local function nowSeconds()
  if getTime then
    local ok, value = pcall(getTime)
    if ok and type(value) == "number" then
      return value / 100
    end
  end

  if os and type(os.clock) == "function" then
    return os.clock()
  end

  return 0
end
M.nowSeconds = nowSeconds

local function emitLog(opts, msg, level)
  if opts and type(opts.log) == "function" then
    opts.log(msg, level)
  end
end
M.emitLog = emitLog

-- The RF link as the radio sees it: the reading the MSP runtime's connection test takes
-- (tasks/msp/runtime.lua, isConnected), asked at the moment it matters rather than through a
-- state that is one tick behind it.
local function rf_link_up()
  local readRssi = _G.getRSSI
  if type(readRssi) ~= "function" then return true end
  local ok, rssi = pcall(readRssi)
  if not ok or type(rssi) ~= "number" then return true end
  return rssi > 0
end
M.rfLinkUp = rf_link_up

local function boost_active(now)
  return now < S.boostUntil
end
M.boostActive = boost_active

-- What Settings > Audio > Volume asks for: one mode, and whether it waits for the link
-- (lib/audio_volume.lua, which the page reads too). Loaded on the first refresh of this Lua state
-- and kept, a failed load as well, so a broken install does not reach for the card on every pass.
-- The mode number is that module's LEVEL.
local VOLUME_MODE_LEVEL = 1
local volumeRules = nil

local function getVolumeRules()
  if volumeRules ~= nil then return volumeRules or nil end
  volumeRules = false
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(_G.rfsuite.paths.core .. "/lib/audio_volume.lua", mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then volumeRules = mod end
  end
  return volumeRules or nil
end
M.volumeRules = getVolumeRules

-- The mode and the link rule for one settings table. With the rules missing nothing is driven.
local function resolve_volume_mode(prefs)
  local rules = prefs and getVolumeRules()
  if not rules then return 0, false end
  local mode = rules.mode(prefs)
  return mode, rules.connectedOnly(prefs, mode)
end
M.volumeMode = resolve_volume_mode

-- The level in a Lua state where nothing calls refresh_volume_state: the callout level only, since
-- the master-volume global variable belongs to the widget and the tool. Read on every call rather
-- than kept, because the background function script replaces its preferences table whenever it
-- reloads the file. Connected only asks the radio whether the RF link is up, because the
-- background function script keeps no connection state of its own.
local function resolve_undriven_level()
  if S.driven then return end
  local root = _G.rfsuite
  local prefs = root and root.preferences and root.preferences.audio
  local mode, connectedOnly = resolve_volume_mode(prefs)
  local v = mode == VOLUME_MODE_LEVEL and tonumber(prefs.level) or 0
  if v > 0 and not (connectedOnly and not rf_link_up()) then
    S.level = v
  else
    S.level = nil
  end
end

local function getLocaleModule()
  if localeModule then
    return localeModule
  end

  if type(_G) == "table" and type(_G.__rfsuite_system_locale_module) == "table" then
    localeModule = _G.__rfsuite_system_locale_module
    return localeModule
  end

  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(_G.rfsuite.paths.core .. "/lib/system_locale.lua", mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then
      localeModule = mod
      return localeModule
    end
  end

  return nil
end

local resolvedEventPaths = {}

local function resolveEventPath(relativePath)
  if resolvedEventPaths[relativePath] ~= nil then
    return resolvedEventPaths[relativePath] or nil
  end

  local locale = (getLocaleModule() and type(getLocaleModule().resolveSystemLanguage) == "function") and getLocaleModule().resolveSystemLanguage("en") or AUDIO_DEFAULT_FALLBACK

  -- 1. Try namespaced folder (Rotorflight standard)
  local rfPath = AUDIO_PACK_BASE .. "rf/" .. locale .. "/" .. relativePath
  local f = io.open(rfPath, "r")
  if f then
    io.close(f)
    resolvedEventPaths[relativePath] = rfPath
    return rfPath
  end

  -- 2. Fallback to standard language folder
  local localePath = AUDIO_PACK_BASE .. locale .. "/" .. relativePath
  f = io.open(localePath, "r")
  if f then
    io.close(f)
    resolvedEventPaths[relativePath] = localePath
    return localePath
  end

  -- 3. If file not found in any locale, return nil to indicate failure
  resolvedEventPaths[relativePath] = false
  return nil
end
M.resolveEventPath = resolveEventPath

-- The second value playResolvedEventFile returns when the sound pack has no such file.
local PLAY_NO_FILE = "nofile"
M.PLAY_NO_FILE = PLAY_NO_FILE

-- The files already reported missing, so a sound pack without one says so once rather than at
-- every announcement that asks for it.
local missingFileLogged = {}

--- Returns true when the file was handed to playFile; false and PLAY_NO_FILE when the sound pack
--- has no such file; false alone when playFile is missing or raised.
local function playResolvedEventFile(relativePath, opts)
  local path = resolveEventPath(relativePath)
  if not path then
    if not missingFileLogged[relativePath] then
      missingFileLogged[relativePath] = true
      emitLog(opts, "playFile: file not found for " .. tostring(relativePath), "warn")
    end
    return false, PLAY_NO_FILE
  end
  if type(playFile) == "function" then
    emitLog(opts, "playFile -> " .. tostring(path) .. (S.level and (" @" .. S.level) or ""), "debug")
    local ok, err = pcall(playFile, path, S.level)
    if not ok then emitLog(opts, "playFile error: " .. tostring(err), "error") end
    return ok
  end
  return false
end
M.playResolvedEventFile = playResolvedEventFile

local function playRawFile(path, opts)
  if type(playFile) == "function" then
    local ok, _ = pcall(playFile, path, S.level)
    return ok
  end
  return false
end
M.playRawFileAtLevel = playRawFile

--- Play one file out of the audio pack, by its path below `SOUNDS/rf/<locale>/`.
--
-- Exported because the locale fallback lives here and should live in exactly one place. The
-- adjustment teller runs on the telemetry pass, where none of lib/audio.lua's announcements are
-- reachable, and a second copy of `resolveEventPath` is the thing worth avoiding.
--
-- Returns true when a file was found and handed to playFile.
function M.playEventFile(relativePath, opts)
  if type(relativePath) ~= "string" or relativePath == "" then return false end
  resolve_undriven_level()
  return playResolvedEventFile(relativePath, opts) == true
end

-- Adjustment names and values are advisory. Leave the alarm window clear even when raising the
-- master volume is disabled; the priority belongs to the alarm, not to its volume setting.
function M.adjustmentAllowed()
  return nowSeconds() >= S.quietUntil and not boost_active(nowSeconds())
end

--- Speak a whole number through the radio's own number teller, at the level the files above
--- play at. Exported for the same caller: its words come through playEventFile, and a
--- playNumber of its own would speak the value after them at the radio's Wav volume instead.
---
--- Returns true when the call was handed to playNumber without an error.
function M.playNumber(value, unit)
  if type(playNumber) ~= "function" then return false end
  resolve_undriven_level()
  return (pcall(playNumber, value, unit or 0, 0, S.level)) == true
end

--- Play a sound file by its full path (`/SOUNDS/rf/beep.wav`), at the level the announcements play
--- at. For a page that sounds a tone of its own: the tones at the root of the pack sit in no
--- locale folder, so playEventFile cannot resolve them.
---
--- Returns true when the file was handed to playFile without an error.
function M.playRawFile(path)
  if type(path) ~= "string" or path == "" then return false end
  resolve_undriven_level()
  return playRawFile(path) == true
end

if root then root.audioPlayback = M end

return M
