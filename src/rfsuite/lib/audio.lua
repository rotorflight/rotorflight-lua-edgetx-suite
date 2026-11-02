local Audio = {}

-- Globaler Throttle für Low-Voltage-Alarm (reload-sicher)
local function getGlobalLowVoltageAt()
  if type(_G) == "table" then
    _G.__rfsuiteLastLowVoltageAt = _G.__rfsuiteLastLowVoltageAt or 0
    return _G.__rfsuiteLastLowVoltageAt
  end
  return 0
end

local function setGlobalLowVoltageAt(val)
  if type(_G) == "table" then
    _G.__rfsuiteLastLowVoltageAt = val
  end
end

local AUDIO_PACK_BASE = "/SOUNDS/"
local AUDIO_DEFAULT_FALLBACK = "en"
local AUDIO_ROOT_BASE = "/audio/"
local localeModule = nil
-- lib/elrs_config.lua and lib/crsf.lua, loaded the first time the TX power alert is on, so a radio
-- that never switches it on never loads either.
local elrsConfigModule = nil
local audioOwnerSequence = 0
-- lib/link_rates.lua and lib/crsf.lua, loaded the first time a link headroom alert is on, so a
-- radio that never switches one on never loads either.
local linkRatesModule = nil
local crsfModule = nil

local ARM_FILE_MAP = {
  [0] = "disarm.wav",
  [1] = "armed.wav",
  [2] = "disarm.wav",
  [3] = "armed.wav"
}

-- The level set under Settings > Audio > Volume (1..5), or nil for the radio's own Wav volume.
-- EdgeTX takes it as the second argument of playFile and as the FOURTH of playNumber, after the
-- attributes (radio/src/lua/api_general.cpp); in third place it would be read as attributes.
local audio_volume = nil
local master_gvar_idx = nil
local master_gvar_last = nil
local VOL_GVAR_OFF = -1024

-- How long the master volume stays at the Alert Level after the last critical announcement. A
-- callout and the number after it take two to four seconds, and EdgeTX may still be playing the
-- announcement queued before it, so this is an estimate with a margin rather than a measured
-- length: there is no Lua query for whether the radio is still playing (radio/src/lua/api_general.cpp
-- exports play and flush calls only). A critical announcement inside the window extends it.
local BOOST_SECONDS = 8
-- When the Alert Level ends, on this Lua state's clock (nowSeconds); before it, every refresh of
-- the master volume asks for the Alert Level. 0 until the first critical announcement.
local boost_until = 0
local adjustment_quiet_until = 0

-- The dashboard widget and the tool started from the radio's tool list each run their own copy of
-- this module, and EdgeTX never runs the two at the same time: it stops refreshing widgets while a
-- standalone script runs (radio/src/gui/colorlcd/standalone_lua.cpp). (The tool opened from the
-- dashboard runs inside the widget's own Lua state and announces nothing; it is not a second copy.)
-- The global variable may therefore have been written by the other copy while this one was paused
-- -- a tool closed while a critical announcement still holds the Alert Level leaves it there, and
-- the widget, which last wrote the Normal Level itself, would see nothing to write. So what this
-- state wrote last is trusted only while its refreshes follow each other: on the first refresh,
-- and on the first after a pause longer than this, the variable is read back and only a value
-- that differs from what it holds is written. The widget refreshes on its announcement pass while
-- it is ready (Audio.process, every 0.25 to 0.6 s) and every 0.5 s while it is not
-- (widgets/dashboard/runtime.lua); the tool on its audio tick, every 0.2 s, ready or not. A
-- tool session that can raise the volume lasts longer than this, its start alone.
local VOLUME_GAP_SECONDS = 2
-- When this Lua state last refreshed the master volume, on its clock (nowSeconds).
local volume_refreshed_at = nil

-- How long a lost connection stays eligible for a recovery announcement. Past it the pending
-- flag is dropped without a word: a model that answers again a quarter of an hour later is a
-- new flight, and "telemetry recovered" belongs to the one that was interrupted.
local CONNECTION_RECOVERY_WINDOW = 120

-- How long the flight controller's telemetry frames may stay away, with the RF link up, before
-- the model counts as lost. Rotorflight sends a sensor whose value has not changed every 3 s
-- (the slow interval of its custom telemetry sensors), and one that is changing far more often,
-- so twice the slowest default is a flight controller that has stopped sending rather than a
-- frame that is late. Well inside the 20 s after which the radio itself reports each sensor as
-- lost.
local TELEMETRY_QUIET_SECONDS = 6

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

local function is_rf_connected(self)
  if self and self.state and self.state.rfConnected ~= nil then
    return self.state.rfConnected == true
  end
  if type(_G) == "table" and _G.rfsuite and _G.rfsuite.session and _G.rfsuite.session.rfConnected ~= nil then
    return _G.rfsuite.session.rfConnected == true
  end
  return false
end

local function pct_to_vol_raw(pct)
  if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
  local raw = math.floor(pct / 100 * 2048 - 1024 + 0.5)
  if raw < -1024 then raw = -1024 elseif raw > 1024 then raw = 1024 end
  return raw
end

local function boost_active(now)
  return now < boost_until
end

-- Set by the first refresh_volume_state in this Lua state. The dashboard and the tool reach it on
-- their audio passes; the background function script (src/functions/rfsbg.lua) and the service
-- widget run the adjustment teller without them and never do.
local volume_driven = false

-- What Settings > Audio > Volume asks for: one mode, and whether it waits for the link
-- (lib/audio_volume.lua, which the page reads too). Loaded on the first refresh of this Lua state
-- and kept, a failed load as well, so a broken install does not reach for the card on every pass.
-- The two mode numbers are that module's LEVEL and MASTER.
local VOLUME_MODE_LEVEL = 1
local VOLUME_MODE_MASTER = 2
local volumeRules = nil

local function getVolumeRules()
  if volumeRules ~= nil then return volumeRules or nil end
  volumeRules = false
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/audio_volume.lua", mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then volumeRules = mod end
  end
  return volumeRules or nil
end

-- The mode and the link rule for one settings table. With the rules missing nothing is driven.
local function resolve_volume_mode(prefs)
  local rules = prefs and getVolumeRules()
  if not rules then return 0, false end
  local mode = rules.mode(prefs)
  return mode, rules.connectedOnly(prefs, mode)
end

-- Whether the board has the global variable the settings name, asked once per variable: the
-- answer cannot change while the radio runs, and the question allocates a table.
local gvar_board_checked = nil
local gvar_board_ok = false

local function master_gvar_usable(gv)
  if gv ~= gvar_board_checked then
    gvar_board_checked = gv
    local rules = getVolumeRules()
    gvar_board_ok = rules ~= nil and rules.gvarOnBoard(gv)
  end
  return gvar_board_ok
end

local function refresh_volume_state(self, isCritical, now)
  volume_driven = true
  -- The first refresh of this state, or the first after a pause: the variable may hold what the
  -- other state wrote (see VOLUME_GAP_SECONDS), so it is asked below rather than trusted.
  local stale = volume_refreshed_at == nil or now - volume_refreshed_at > VOLUME_GAP_SECONDS
  volume_refreshed_at = now
  local prefs = self and self.preferences and self.preferences.audio
  if not prefs and type(_G) == "table" and _G.rfsuite and _G.rfsuite.preferences then
    prefs = _G.rfsuite.preferences.audio
  end
  local mode, connectedOnly = resolve_volume_mode(prefs)
  local linkUp = is_rf_connected(self)

  -- Callout level: handed to playFile and playNumber, in its own mode only.
  local v = mode == VOLUME_MODE_LEVEL and tonumber(prefs.level) or 0
  if v ~= nil and v > 0 then
    if connectedOnly and not linkUp then
      audio_volume = nil
    else
      audio_volume = v
    end
  else
    audio_volume = nil
  end

  -- Master volume, through the global variable, in its own mode only.
  if type(model) ~= "table" or type(model.setGlobalVariable) ~= "function" then return end
  local gv = mode == VOLUME_MODE_MASTER and tonumber(prefs.master_gvar) or 0
  -- A variable this board does not have leaves the feature off rather than writing to nowhere.
  if gv ~= 0 and not master_gvar_usable(gv) then gv = 0 end

  if gv == 0 or (master_gvar_idx ~= nil and master_gvar_idx ~= gv - 1) then
    if master_gvar_idx ~= nil then
      pcall(model.setGlobalVariable, master_gvar_idx, 0, VOL_GVAR_OFF)
      master_gvar_idx = nil
      master_gvar_last = nil
    end
    if gv == 0 then return end
  end
  master_gvar_idx = gv - 1
  -- Every accepted write marks the model for a save, so the value already standing is not written
  -- again; a read that fails leaves nothing to compare with, and the value is written.
  if stale then
    local ok, current = pcall(model.getGlobalVariable, master_gvar_idx, 0)
    master_gvar_last = ok and tonumber(current) or nil
  end
  local pct = isCritical and (tonumber(prefs.master_alert) or 100) or (tonumber(prefs.master_normal) or 80)

  -- Connected only: the pot rules until the link is up and again once it is down, a raised level
  -- included -- every critical announcement is made with the link up, and a lost link is the
  -- radio's own announcement. Without it the level is set on the first refresh -- the dashboard
  -- or the tool starting -- and the link changes nothing, so the pot stays overridden for as long
  -- as the mode is on.
  local raw = pct_to_vol_raw(pct)
  if connectedOnly and not linkUp then raw = VOL_GVAR_OFF end
  if raw ~= master_gvar_last then
    if pcall(model.setGlobalVariable, master_gvar_idx, 0, raw) then
      master_gvar_last = raw
    end
  end
end

-- The level in a Lua state where nothing calls refresh_volume_state: the callout level only, since
-- the master-volume global variable belongs to the widget and the tool. Read on every call rather
-- than kept, because the background function script replaces its preferences table whenever it
-- reloads the file. Connected only asks the radio whether the RF link is up, because the
-- background function script keeps no connection state of its own.
local function resolve_undriven_level()
  if volume_driven then return end
  local root = _G.rfsuite
  local prefs = root and root.preferences and root.preferences.audio
  local mode, connectedOnly = resolve_volume_mode(prefs)
  local v = mode == VOLUME_MODE_LEVEL and tonumber(prefs.level) or 0
  if v > 0 and not (connectedOnly and not rf_link_up()) then
    audio_volume = v
  else
    audio_volume = nil
  end
end

-- Keyed on govState_e as the firmware numbers it (flight/governor.h, 0..9), which is what the
-- governor sensor carries. The dashboard's text object synthesises 100 and 101 for its own
-- label (widgets/dashboard/objects/text/governor.lua); neither reaches this path.
local GOVERNOR_FILE_MAP = {
  [0] = "off.wav",
  [1] = "idle.wav",
  [2] = "spoolup.wav",
  [3] = "recovery.wav",
  [4] = "active.wav",
  [5] = "thr-off.wav",
  [6] = "lost-hs.wav",
  [7] = "autorot.wav",
  [8] = "bailout.wav",
  -- GOV_STATE_BYPASS: the governor is passing the throttle straight through, which is what
  -- the pack's disabled.wav says.
  [9] = "disabled.wav"
}

-- The per-state enables under the `governor_state` master switch, one key per entry above.
-- An absent key counts as on, so a preferences.ini written before these existed announces
-- every state, as it did.
local GOVERNOR_PREF_KEYS = {
  [0] = "governor_state_off",
  [1] = "governor_state_idle",
  [2] = "governor_state_spoolup",
  [3] = "governor_state_recovery",
  [4] = "governor_state_active",
  [5] = "governor_state_thr_off",
  [6] = "governor_state_lost_hs",
  [7] = "governor_state_autorot",
  [8] = "governor_state_bailout",
  [9] = "governor_state_bypass"
}

-- How long a governor state has to stand before it is spoken. A spool-up crosses several
-- states inside a second, and the file for a state the machine has already left would
-- otherwise still be playing, or be skipped by the cooldown, when the next one is due.
local GOVERNOR_HOLD_SECONDS = 0.3

-- The `link` key's search path in lib/sensors.lua ends in 1RSS and 2RSS, and those carry an
-- RSSI in dBm rather than a link quality in percent. A percent threshold held against a
-- negative dBm reading is below itself on every sample, so the alert has to know which
-- sensor answered before it says anything.
local RSSI_LINK_SOURCES = {
  ["1RSS"] = true,
  ["2RSS"] = true
}

-- Telemetry dropouts. A file of its own with no substitute: an older pack that lacks it stays
-- silent rather than borrowing the words of another alert.
local DROPOUTS_SOUND = "stat/alerts/dropouts.wav"

-- How far the link has to climb back above a threshold before that level is left again. A
-- quality resting on the threshold otherwise alternates between two levels, and each rise
-- would speak.
local LQ_HYSTERESIS = 5
-- The TX power alert: the transmitter's power (`TPWR`) as a share of the most it may send with,
-- spoken as a percentage. Higher is worse, so its levels are lines the share climbs to, and a level
-- is left only once the share has fallen this many points below its line. The share moves in the
-- module's power steps (10, 25, 50, 100, 250 mW and so on): a share that only wobbles around a line
-- stays on its level, but a whole step down leaves it, and the climb back is a new announcement once
-- it has lasted the hold.
local TX_POWER_WARN = 60
local TX_POWER_CRITICAL = 85
local TX_POWER_HOLD = 2
local TX_POWER_HYSTERESIS = 5
-- The own maximum, in mW, where the pilot has switched it on and not chosen a value.
local TX_POWER_OWN_MAX = 100
-- The same for the link headroom alerts below, in percentage points of the headroom scale
-- (lib/link_rates.lua, LinkRates.headroom): a level is left only once the headroom has climbed
-- this far above its line. On the scale's usual span of 60 to 80 dB one point is under a dB,
-- so 5 points is a few dB -- about what a reading wanders by while the rotor turns -- and a
-- headroom riding on its line does not announce each time it dips back under it.
local LINK_HEADROOM_HYSTERESIS = 5

-- The link headroom alerts: how much of the window between the air rate's sensitivity floor and
-- a strong signal a reading still has, spoken as a percentage. One entry per alert, each with its
-- own switch, its own two levels and its own hold on Settings > Audio > Events > Link; all of them
-- take the Link page's Repeat and Haptic. `read` picks the reading in dBm off the state the caller
-- hands over. The uplink is the signal at the receiver antenna in use; the downlink is the signal
-- at the transmitter module. Both directions run at the one air rate, so they are measured against
-- the one floor.
--
-- The antenna in use is the one `ANT` names, counted from nought as ExpressLRS fills it: 1 is the
-- second antenna (`2RSS`), anything else the first (`1RSS`), and so is a link that reports no
-- `ANT` at all. Not the stronger of the two fields: a receiver with one radio and an antenna switch
-- writes only the field of the antenna it is on and leaves the other at its last value
-- (ExpressLRS 4.1.0, src/src/rx_main.cpp, getRFlinkInfo), and the frame does not say which kind
-- of receiver filled it. Where `ANT` names the second antenna and its field has no reading, there
-- is no reading this pass; the first antenna's field is not taken in its place.
local function uplinkRssi(state)
  if tonumber(state.antenna) == 1 then return tonumber(state.rss2) end
  return tonumber(state.rss1)
end

local function downlinkRssi(state)
  return tonumber(state.trss)
end

-- The signal-to-noise ratio at the receiver (`RSNR`) and at the transmitter module (`TSNR`), in
-- dB. These two entries (`snr = true`) are spoken as where the reading sits between the air rate's
-- two dynamic-power thresholds (lib/link_rates.lua, LinkRates.snrPercent): 0 % at or below the
-- one at which ExpressLRS asks for more power, 100 % at or above the one at which it asks for
-- less. Their hysteresis is one decibel on that scale (LinkRates.snrPointsPerDb) rather than
-- LINK_HEADROOM_HYSTERESIS: the SNR comes in whole dB and the window between the thresholds is
-- 1.5 to 8.5 dB wide, so one step of the reading is 12 to 67 points, and five points would let a
-- reading that flickers by one dB across a line leave and re-enter the level at every flicker.
-- A level is therefore left only once the reading is MORE than one dB above its line -- on a line
-- that sits on a whole dB, the second dB above it. On a narrow window that can be past the top of
-- the scale, so the top clears every level below 100 % (announceLinkHeadroom).
local function uplinkSnr(state)
  return tonumber(state.rsnr)
end

local function downlinkSnr(state)
  return tonumber(state.tsnr)
end

local LINK_HEADROOM_ALERTS = {
  { alertKey = "rssi", enableKey = "rssi_alert", warnKey = "rssi_warn", criticalKey = "rssi_critical",
    holdKey = "rssi_hold", sound = "stat/alerts/rssi.wav", read = uplinkRssi,
    warn = 15, critical = 8, hold = 2 },
  { alertKey = "trss", enableKey = "trss_alert", warnKey = "trss_warn", criticalKey = "trss_critical",
    holdKey = "trss_hold", sound = "stat/alerts/downlink.wav", read = downlinkRssi,
    warn = 15, critical = 8, hold = 2 },
  { alertKey = "rsnr", enableKey = "rsnr_alert", warnKey = "rsnr_warn", criticalKey = "rsnr_critical",
    holdKey = "rsnr_hold", sound = "stat/alerts/snr.wav", read = uplinkSnr, snr = true,
    warn = 30, critical = 0, hold = 2 },
  { alertKey = "tsnr", enableKey = "tsnr_alert", warnKey = "tsnr_warn", criticalKey = "tsnr_critical",
    holdKey = "tsnr_hold", sound = "stat/alerts/downlink_snr.wav", read = downlinkSnr, snr = true,
    warn = 30, critical = 0, hold = 2 },
}
-- The same for the ESC load, in percentage points of the current limit: a level is left only
-- once the load has dropped this far below its line, so a load riding on the line under a
-- steady collective does not announce every time it climbs back over it.
local ESC_LOAD_HYSTERESIS = 5
local ESC_LOAD_SOUND = "stat/alerts/escload.wav"
-- The same for the two temperature alerts, in degrees Celsius: a reading has to fall this far
-- below a level before that level is left. A sensor resting on a threshold reads a degree either
-- side of it from one frame to the next, and each rise would otherwise be a new worsening.
local TEMP_HYSTERESIS = 5

-- What separates "the pack is gone" from "the pack is low". A disconnected main battery reads
-- as no voltage at all, and the lowest a flight pack is ever taken to is far above this, so
-- nothing a discharge can reach falls inside the window.
local MAIN_POWER_LOST_VOLTS = 1.0

-- The four files this adds, each with a file of its own in both packs. None of them is borrowed
-- from an existing alert: every shipped file names a different event, and announcing a lost
-- connection in the words of a low battery is worse than saying nothing. In an older pack that
-- lacks them, the two power announcements fall back to a near enough neighbour; the two
-- connection announcements have none and stay silent there. Which pack answers is resolved
-- once per session and cached.
local CONNECTION_LOST_SOUND = "stat/alerts/telemetrylost.wav"
local CONNECTION_OK_SOUND = "stat/alerts/telemetryok.wav"
local MAIN_POWER_LOST_SOUNDS = { "stat/alerts/mainpower.wav", "stat/alerts/batteryempty.wav", "stat/alerts/lowvoltage.wav" }
local MAIN_POWER_OK_SOUNDS = { "stat/alerts/mainpowerok.wav", "evt/battery.wav" }

-- Rescue, spoken on its two edges only: out of RESCUE_STATE_OFF (0 in rotorflight-firmware
-- flight/rescue.h) into any of its phases, and back to it. The phases in between are not spoken.
-- Files of their own rather than adj/rescue.wav, which is the first word of the rescue
-- adjustment announcements.
local RESCUE_ACTIVE_SOUND = "stat/alerts/rescue_on.wav"
local RESCUE_OFF_SOUND = "stat/alerts/rescue_off.wav"

-- How long an alert whose condition still holds waits before it speaks again. Every repeating
-- alert in this file already waited exactly this long, with the number written out at each of
-- them; one constant is what lets the repeat count below mean the same thing everywhere.
local ALERT_REPEAT_SECONDS = 10

-- How long the transmitter buzzes for an alert that asks for it, and the pause after it. EdgeTX
-- takes playHaptic(duration, pause [, flags]) (radio/src/lua/api_general.cpp): there is no
-- strength argument, and hapticQueue::play (radio/src/haptic.cpp) reads the low four bits of
-- flags as a repeat count, so the alert passes no flags and buzzes once. The radio's own haptic
-- length setting lengthens the duration (getHapticLength, radio/src/haptic.h); 15 and 3 are the
-- values EdgeTX's own alarm vibration uses.
local ALERT_HAPTIC_DURATION = 15
local ALERT_HAPTIC_PAUSE = 3

-- Whether an alert repeats, and whether it buzzes, are properties of an alert CATEGORY rather
-- than of one alert: Settings > Audio > Events draws one page per category, and the alerts a
-- page switches on are the alerts its two behaviour rows govern. That is one pair of controls
-- per page instead of one pair per announcement, and it is the difference between four new
-- settings and twenty.
--
-- `repeatDefault` 0 means the alert keeps speaking for as long as its condition holds, which
-- is what every alert in this file did before these settings existed; 1 to 10 caps it at that
-- many announcements per episode and then stays quiet until the condition clears. The fuel
-- pair keeps the two keys it already had -- the ones that used to be the only alert in the
-- file with either property -- so a preferences.ini written before this reads exactly as it
-- did, and the two settings are replaced rather than joined by six more.
local ALERT_BEHAVIOUR = {
  voltage = { repeatKey = "voltage_repeat", repeatDefault = 0, hapticKey = "voltage_haptic", hapticDefault = true },
  link    = { repeatKey = "link_repeat",    repeatDefault = 0, hapticKey = "link_haptic",    hapticDefault = true },
  esc     = { repeatKey = "esc_repeat",     repeatDefault = 0, hapticKey = "esc_haptic",     hapticDefault = true },
  fuel    = { repeatKey = "fuel_repeat_below_zero", repeatDefault = 1,
              hapticKey = "fuel_haptic_below_zero", hapticDefault = false }
}

-- Which category's behaviour each alert takes. The name on the left is the key the alert
-- already uses in audioState.lastAlertAt, so a timestamp and a repeat count are filed under
-- the same name. The pack check is deliberately absent: it speaks once when the model
-- connects and is latched for the rest of the connection, so neither property has anything
-- to act on.
local ALERT_CATEGORY = {
  voltage         = "voltage",
  main_power      = "voltage",
  bec_voltage     = "voltage",
  rx_voltage      = "voltage",
  lq              = "link",
  telemetry_lost  = "link",
  tpwr            = "link",
  rssi            = "link",
  trss            = "link",
  rsnr            = "link",
  tsnr            = "link",
  dropouts        = "link",
  esc_temperature = "esc",
  mcu_temperature = "esc",
  esc_load        = "esc",
  fuel_empty      = "fuel"
}

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

local function isTruthy(value)
  return value == true or value == 1 or value == "1" or value == "true"
end

local function prefEnabled(events, key, defaultValue)
  local value = events and events[key]
  if value == nil then return defaultValue end
  return isTruthy(value)
end

local function alertBehaviour(alertKey)
  local category = ALERT_CATEGORY[alertKey]
  if not category then return nil end
  return ALERT_BEHAVIOUR[category]
end

-- How many times an alert may speak while one episode of its condition lasts. 0 is "for as
-- long as it holds"; anything above 10 is brought back to 10, which is the range the control
-- offers, so a hand-edited preferences.ini cannot ask for a number the page could not.
local function alertRepeatLimit(events, alertKey)
  local behaviour = alertBehaviour(alertKey)
  if not behaviour then return 0 end
  local limit = tonumber(events and events[behaviour.repeatKey])
  if limit == nil then return behaviour.repeatDefault end
  limit = math.floor(limit)
  if limit < 0 then return 0 end
  if limit > 10 then return 10 end
  return limit
end

local function alertHapticWanted(events, alertKey)
  local behaviour = alertBehaviour(alertKey)
  if not behaviour then return false end
  return prefEnabled(events, behaviour.hapticKey, behaviour.hapticDefault)
end

local function alertRepeatCounts(audioState)
  local counts = audioState.alertRepeats
  if type(counts) ~= "table" then
    counts = {}
    audioState.alertRepeats = counts
  end
  return counts
end

--- May an alert whose condition holds speak now?
---
--- Two questions, and the second is where each alert's own history comes in. The repeat count
--- is spent per episode. The interval is measured from the last announcement, and an alert
--- that zeroes its timestamp when its condition clears -- as the voltage, BEC and RX alerts do
--- -- therefore speaks at once when the condition returns. The link quality and temperature
--- alerts zero it on a rise into a level instead, and it is their hysteresis, not the
--- timestamp, that keeps a reading resting on a level from announcing every rise.
local function alertMaySpeak(audioState, events, alertKey, now)
  local limit = alertRepeatLimit(events, alertKey)
  if limit > 0 then
    local counts = audioState.alertRepeats
    if counts ~= nil and (counts[alertKey] or 0) >= limit then
      return false
    end
  end

  local last = tonumber(audioState.lastAlertAt and audioState.lastAlertAt[alertKey]) or 0
  if last > 0 and (now - last) < ALERT_REPEAT_SECONDS then
    return false
  end

  return true
end

--- Book an announcement that was made, and buzz if the pilot asked this category to.
---
--- `haptic` is false for an announcement whose own severity rule says no even when the
--- category is set to buzz: the link quality and the ESC and MCU temperature alerts buzz at
--- their critical level and not at their warning one, which is a distinction inside each alert
--- rather than a setting.
local function alertSpoken(audioState, events, alertKey, now, haptic)
  -- Audio.process builds this table on its first pass, and every alert but the lost-connection
  -- one is reached from inside that pass. That one is called from the caller's own loss branch.
  if type(audioState.lastAlertAt) ~= "table" then
    audioState.lastAlertAt = {}
  end
  audioState.lastAlertAt[alertKey] = now
  local counts = alertRepeatCounts(audioState)
  counts[alertKey] = (counts[alertKey] or 0) + 1
  if haptic ~= false and alertHapticWanted(events, alertKey) and type(playHaptic) == "function" then
    pcall(playHaptic, ALERT_HAPTIC_DURATION, ALERT_HAPTIC_PAUSE)
  end
end

--- The condition is over, so the next episode starts with a full repeat count.
---
--- The timestamp is deliberately left alone. Whether an alert that has just cleared may speak
--- again immediately is that alert's own decision, taken where it clears, and this function
--- must not overrule it in either direction.
---
--- On the quiet path -- an alert whose condition is NOT true clears it on every pass -- so it
--- reads the table rather than building one. There is nothing to clear before anything has
--- been counted, and a pass in which no alert fires must not pay for one.
local function alertCleared(audioState, alertKey)
  local counts = audioState.alertRepeats
  if counts ~= nil then
    counts[alertKey] = nil
  end
end

local function roundProfileValue(value)
  if type(value) ~= "number" then
    return nil
  end
  return math.floor(value + 0.5)
end

local function normalizeCellVoltage(rawValue, fallback)
  local value = tonumber(rawValue)
  if type(value) ~= "number" then
    return fallback
  end

  -- FC config often stores per-cell voltage in centi-volts (e.g. 350 => 3.50V).
  if value >= 1000 then
    value = value / 1000
  elseif value >= 100 then
    value = value / 100
  elseif value > 10 then
    value = value / 10
  end

  if value < 1.0 or value > 5.0 then
    return fallback
  end

  return value
end

local function normalizeAlertVoltage(rawValue, fallback)
  local value = tonumber(rawValue)
  if type(value) ~= "number" then
    return fallback
  end

  -- Power alert values are stored as deci-volts (e.g. 65 -> 6.5V).
  if value > 20 then
    value = value / 10
  end

  if value <= 0 then
    return fallback
  end

  return value
end

local function readBatteryPrefs()
  local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
  if not session or type(session.modelPreferences) ~= "table" then
    return nil
  end
  return session.modelPreferences.battery
end

-- The ESC's temperature levels describe the aircraft, so the model's own store wins over
-- the radio-wide default in the transmitter's own store. Reached the same way readBatteryPrefs above
-- reaches the other half of the same file.
local function readAudioEventPrefs()
  local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
  if not session or type(session.modelPreferences) ~= "table" then
    return nil
  end
  return session.modelPreferences.audio_events
end

-- The ESC's two temperature levels. They describe one aircraft's hardware, so the model's own
-- values win over the radio-wide ones, each level on its own: a model may carry a warning level
-- of its own and take the critical level from the radio. A critical level below the warning
-- level cannot be crossed second, so the higher of the two is the critical one; nothing is
-- refused over it, the pair is just ordered.
local function escTemperatureLevels(events)
  local modelEvents = readAudioEventPrefs()
  local warn = tonumber(modelEvents and modelEvents.esc_threshold)
    or tonumber(events.esc_threshold) or 90
  local critical = tonumber(modelEvents and modelEvents.esc_critical)
    or tonumber(events.esc_critical) or 110
  if critical < warn then critical = warn end
  return warn, critical
end

-- The same two levels for the flight controller's MCU, with one difference: no
-- `scope = "model"`, so both are read out of the global table only.
local function mcuTemperatureLevels(events)
  local warn = tonumber(events.mcu_threshold) or 80
  local critical = tonumber(events.mcu_critical) or 95
  if critical < warn then critical = warn end
  return warn, critical
end

local function isArmedFromState(state)
  if type(state) ~= "table" then
    return false
  end

  local armFlags = tonumber(state.armFlags or state.armflags)
  if type(armFlags) ~= "number" then
    return false
  end

  if bit32 and type(bit32.btest) == "function" then
    return bit32.btest(armFlags, 1)
  end

  return armFlags ~= 0
end

local function resetBecAverage(audioState)
  audioState.becSampleIndex = 0
  audioState.becSampleCount = 0
  audioState.becSampleSum = 0
  local samples = audioState.becSamples
  if type(samples) ~= "table" then
    samples = {}
    audioState.becSamples = samples
  end
  for i = 1, #samples do
    samples[i] = nil
  end
end

local function pushBecAverage(audioState, value)
  local samples = audioState.becSamples
  if type(samples) ~= "table" then
    samples = {}
    audioState.becSamples = samples
  end

  local size = 5
  local idx = (tonumber(audioState.becSampleIndex) or 0) + 1
  if idx > size then idx = 1 end

  local count = tonumber(audioState.becSampleCount) or 0
  local sum = tonumber(audioState.becSampleSum) or 0

  local old = samples[idx]
  if old ~= nil and count >= size then
    sum = sum - old
  elseif count < size then
    count = count + 1
  end

  samples[idx] = value
  sum = sum + value

  audioState.becSampleIndex = idx
  audioState.becSampleCount = count
  audioState.becSampleSum = sum

  if count <= 0 then
    return value
  end

  return sum / count
end

local function unitPercent()
  if type(UNIT_PERCENT) == "number" then return UNIT_PERCENT end
  return 0
end

local function unitMah()
  if type(UNIT_MAH) == "number" then return UNIT_MAH end
  return 108 -- fallback typical for OpenTX/EdgeTX
end

local function unitCelsius()
  if type(UNIT_CELSIUS) == "number" then return UNIT_CELSIUS end
  return 0
end

-- A temperature as it is spoken: in Fahrenheit where Settings > Localization says so, the unit
-- the dashboard shows it in. The reading comes in Celsius, as the flight controller reports it,
-- and the thresholds are stored and compared in Celsius as well; only the spoken number is
-- converted. Without the firmware's Fahrenheit unit it stays Celsius, so number and unit agree.
local function spokenTemperature(self, celsius)
  local localizations = self and self.preferences and self.preferences.localizations
  if tonumber(localizations and localizations.temperature_unit) == 1 and type(UNIT_FAHRENHEIT) == "number" then
    return math.floor(celsius * 9 / 5 + 32 + 0.5), UNIT_FAHRENHEIT
  end
  return math.floor(celsius + 0.5), unitCelsius()
end

local function unitVolts()
  if type(UNIT_VOLTS) == "number" then return UNIT_VOLTS end
  return 0
end

-- EdgeTX speaks a fractional value by taking the number in hundredths together with the PREC2
-- attribute: radio/src/lua/api_general.cpp documents playNumber's third argument as "PREC2
-- plays a number with two decimal places (for a number 123 it plays 1.23)". On a firmware
-- that does not export the constant there are no decimals to be had, and the caller has to
-- fall back to whole units -- which is what a zero here says.
local function precTwo()
  if type(PREC2) == "number" then return PREC2 end
  return 0
end

-- The same mechanism with one decimal place. A pack voltage is spoken as 23.4 volts rather
-- than 23.45: the second decimal of a pack reading decides nothing and costs a syllable in
-- the middle of a flight, while a per-cell voltage is judged on exactly that decimal.
local function precOne()
  if type(PREC1) == "number" then return PREC1 end
  return 0
end

local function emitLog(opts, msg, level)
  if opts and type(opts.log) == "function" then
    opts.log(msg, level)
  end
end

-- Speak a voltage through the radio's own number teller, so that the digits and the unit come
-- out in the language the pilot set on the radio rather than in the language of the sound pack.
-- `decimals` is 1 for a pack or BEC reading and 2 for a per-cell one; on a firmware that
-- exports neither precision attribute the value is rounded to whole volts rather than left
-- unsaid, which is what a zero attribute means.
local function playVoltage(volts, decimals, opts)
  if type(playNumber) ~= "function" or type(volts) ~= "number" then return end
  local attribute = (decimals == 2) and precTwo() or precOne()
  local spoken
  if attribute == 0 then
    spoken = math.floor(volts + 0.5)
  elseif decimals == 2 then
    spoken = math.floor((volts * 100) + 0.5)
  else
    spoken = math.floor((volts * 10) + 0.5)
  end
  local ok, err = pcall(playNumber, spoken, unitVolts(), attribute, audio_volume)
  if not ok then emitLog(opts, "playNumber error: " .. tostring(err), "error") end
end

-- The battery configuration read from the flight controller, or nil until it has arrived.
local function sessionBatteryConfig()
  local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
  local bc = session and (session.batteryConfig or session.battery_config) or nil
  if type(bc) ~= "table" then return nil end
  return bc
end

-- The cell count of the flight pack: the battery configuration's, and telemetry's where the
-- configuration says 0, which is the flight controller's auto-detect. Nil when neither knows,
-- so that a caller can tell "no count" apart from a count. The low-voltage line, its reset and
-- every per-cell announcement divide by this one number.
local function flightPackCells(state, batteryConfig)
  local cells = batteryConfig and tonumber(batteryConfig.batteryCellCount) or nil
  if not cells or cells <= 0 then
    cells = tonumber(state and state.batteryCellCount)
  end
  if type(cells) ~= "number" then return nil end
  cells = math.floor(cells + 0.5)
  if cells <= 0 then return nil end
  return cells
end

-- Speak a flight-pack voltage the way the pilot chose under Settings > Audio > Events > Voltage:
-- the pack's voltage with one decimal (`voltage_announce` 0, the default), or the voltage per
-- cell with two (1), which reads the same on every pack. Without a cell count there is nothing
-- to divide by, and the pack is spoken rather than nothing.
local function playPackVoltage(events, voltage, cells, opts)
  if cells and tonumber(events and events.voltage_announce) == 1 then
    playVoltage(voltage / cells, 2, opts)
  else
    playVoltage(voltage, 1, opts)
  end
end

-- How far above its line the pack has to come back before the low-voltage alert counts as
-- cleared, in volts per cell. The setting is in millivolts per cell so that one number means the
-- same on every pack; it is brought into the range the settings page offers, so a hand-edited
-- preferences file cannot ask for a reset the page could not.
local VOLTAGE_RESET_DEFAULT_MV = 100
local VOLTAGE_RESET_MIN_MV = 50
local VOLTAGE_RESET_MAX_MV = 500

local function voltageResetPerCell(events)
  local mv = tonumber(events and events.voltage_reset) or VOLTAGE_RESET_DEFAULT_MV
  if mv < VOLTAGE_RESET_MIN_MV then mv = VOLTAGE_RESET_MIN_MV end
  if mv > VOLTAGE_RESET_MAX_MV then mv = VOLTAGE_RESET_MAX_MV end
  return mv / 1000
end

-- WHO decides that the initial fuel / capacity is announced:
-- The radio preference `preferences.audio_events.initial_fuel` (default true)
-- governs this event exclusively.
local function initialFuelWanted(events)
  return prefEnabled(events, "initial_fuel", true)
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
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/system_locale.lua", mode)
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

-- The first candidate a sound pack actually carries. Every candidate is probed at most once
-- per session, because resolveEventPath caches its answer, the misses included.
local function firstResolvedSound(candidates)
  for i = 1, #candidates do
    if resolveEventPath(candidates[i]) then return candidates[i] end
  end
  return nil
end

-- Why tryPlayEventFile handed nothing over, as its second return value. A missing file has
-- nothing to play on any later pass either, because resolveEventPath caches the miss, so an
-- announcement that meets one is done with; a cooldown or a failed hand-over is worth another
-- try on the next pass. announcementDone below is that rule.
local PLAY_COOLDOWN = "cooldown"
local PLAY_NO_FILE = "nofile"
local PLAY_FAILED = "failed"

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
    emitLog(opts, "playFile -> " .. tostring(path) .. (audio_volume and (" @" .. audio_volume) or ""), "debug")
    local ok, err = pcall(playFile, path, audio_volume)
    if not ok then emitLog(opts, "playFile error: " .. tostring(err), "error") end
    return ok
  end
  return false
end

local function playRawFile(path, opts)
  if type(playFile) == "function" then
    local ok, _ = pcall(playFile, path, audio_volume)
    return ok
  end
  return false
end

local function scheduleAudioCooldown(audioState, now, seconds)
  audioState.nextAllowedAt = now + (seconds or 0.25)
end

--- Hand one file of the sound pack to EdgeTX, unless the previous file's cooldown still runs.
---
--- Returns true when the file was handed over. Otherwise false and the reason: PLAY_COOLDOWN,
--- PLAY_NO_FILE (the sound pack has no such file) or PLAY_FAILED (playFile is missing or
--- raised). A caller that only asks whether something played reads the first value as before.
local function tryPlayEventFile(audioState, now, relativePath, opts)
  if not audioState.lastAlertAt then
    audioState.lastAlertAt = { voltage = 0, esc_temperature = 0 }
  end
  if now < (audioState.nextAllowedAt or 0) then
    emitLog(opts, "cooldown active; skip " .. tostring(relativePath), "debug")
    return false, PLAY_COOLDOWN
  end

  local played, why = playResolvedEventFile(relativePath, opts)
  if not played then
    if why == PLAY_NO_FILE then
      -- Reported once per file, where the miss was found.
      return false, PLAY_NO_FILE
    end
    emitLog(opts, "failed to play " .. tostring(relativePath), "warn")
    return false, PLAY_FAILED
  end

  scheduleAudioCooldown(audioState, now, 0.25)
  emitLog(opts, "played " .. tostring(relativePath), "info")
  return true
end

--- Is an announcement done with, so that its repeat interval and repeat count may be booked?
--- Yes when its file was handed over, and yes when the sound pack has no file for it: nothing
--- will ever play, and an announcement left unbooked would be tried again on every pass for as
--- long as its condition holds. No when the cooldown refused it or the hand-over failed; then
--- it is tried again on the next pass.
local function announcementDone(played, why)
  return played == true or why == PLAY_NO_FILE
end

-- The Raise Volume switch of each alarm on its Settings > Audio > Events page, by the alarm's key.
-- The BEC and the RX voltage alert share one: Setup > Power > Alerts switches on one of the two at
-- a time. Every switch is on unless the pilot turns it off, except the one for telemetry dropouts,
-- which is off unless turned on. An alarm that is not listed never raises the volume.
local RAISE_KEYS = {
  voltage         = "voltage_raise",
  main_power      = "main_power_raise",
  bec_voltage     = "bec_rx_raise",
  rx_voltage      = "bec_rx_raise",
  lq              = "lq_raise",
  telemetry_lost  = "telemetry_lost_raise",
  tpwr            = "tpwr_raise",
  rssi            = "rssi_raise",
  trss            = "trss_raise",
  rsnr            = "rsnr_raise",
  tsnr            = "tsnr_raise",
  dropouts        = "dropouts_raise",
  esc_temperature = "esc_temperature_raise",
  mcu_temperature = "mcu_temperature_raise",
  esc_load        = "esc_load_raise",
  fuel_empty      = "fuel_empty_raise"
}
local RAISE_OFF_BY_DEFAULT = { dropouts = true }

--- Hand an alarm's file to EdgeTX, the way tryPlayEventFile does, and raise the master volume for
--- it where it is a critical announcement: an alarm's upper level, or the only level of an alarm
--- that has one.
---
--- The Alert Level is written BEFORE the file is handed over, so the announcement is heard at it,
--- and only where the file will be handed over: the cooldown tryPlayEventFile applies is open and
--- the sound pack has the file. An announcement refused for either reason therefore raises
--- nothing. Back to the Normal
--- Level BOOST_SECONDS after the last critical announcement, on a later refresh; another one inside
--- that time extends it, and since the master volume is written only when the value it should
--- carry changes, an extension writes nothing. The level written follows the Volume page's mode,
--- so outside Master volume this changes nothing at all. The caller has already decided that the
--- alarm may speak (alertMaySpeak), and the haptic is booked by the caller as before. Returns what
--- tryPlayEventFile returns, the reason included.
local function tryPlayAlertFile(self, audioState, events, now, relativePath, opts, alertKey, critical)
  if critical and now >= (audioState.nextAllowedAt or 0) and resolveEventPath(relativePath) then
    adjustment_quiet_until = now + BOOST_SECONDS
  end
  if critical and now >= (audioState.nextAllowedAt or 0) then
    local key = RAISE_KEYS[alertKey]
    if key and prefEnabled(events, key, not RAISE_OFF_BY_DEFAULT[alertKey]) and resolveEventPath(relativePath) then
      boost_until = now + BOOST_SECONDS
      refresh_volume_state(self, true, now)
    end
  end
  return tryPlayEventFile(audioState, now, relativePath, opts)
end

--- A temperature alert with a warning and a critical level, for the ESC and the MCU alike.
---
--- The shape of the link quality alert, turned the other way up because a temperature gets
--- worse by rising: a worsening is announced at once and the level it has entered gets its own
--- repeats, recovering is not announced, leaving a level costs TEMP_HYSTERESIS degrees more than
--- entering it, and only the critical level vibrates. The words are the same at both levels and
--- the temperature follows them, in the unit set under Settings > Localization.
---
--- `warn` and `critical` come ordered, from escTemperatureLevels or mcuTemperatureLevels.
local function announceTemperatureLevel(self, audioState, events, opts, now, alert, temp, warn, critical)
  local levelKey = alert.levelKey
  local alertKey = alert.alertKey
  local spoken = tonumber(audioState[levelKey]) or 0
  local level = 0
  if temp >= critical then
    level = 2
  elseif temp >= warn then
    level = 1
  end

  if level < spoken then
    if spoken >= 2 and temp >= critical - TEMP_HYSTERESIS then
      level = 2
    elseif level < 1 and spoken >= 1 and temp >= warn - TEMP_HYSTERESIS then
      level = 1
    end
  end

  if level < spoken then
    audioState[levelKey] = level
    alertCleared(audioState, alertKey)
  elseif level > 0 then
    if level > spoken then
      audioState.lastAlertAt[alertKey] = 0
      alertCleared(audioState, alertKey)
    end
    if alertMaySpeak(audioState, events, alertKey, now) then
      local played, why = tryPlayAlertFile(self, audioState, events, now, alert.sound, opts, alertKey, level >= 2)
      if announcementDone(played, why) then
        if played and type(playNumber) == "function" then
          local value, unit = spokenTemperature(self, temp)
          local ok, err = pcall(playNumber, value, unit, 0, audio_volume)
          if not ok then emitLog(opts, "playNumber error: " .. tostring(err), "error") end
        end
        -- Booked without a file as well, the level included: a level left unbooked would count
        -- as newly entered on the next pass and start over at once.
        alertSpoken(audioState, events, alertKey, now, played and level >= 2)
        audioState[levelKey] = level
      end
    end
  end
end

-- What tells the two temperature alerts apart. A table each, built once, so that a pass that
-- judges them builds nothing.
local ESC_TEMPERATURE_ALERT = { alertKey = "esc_temperature", levelKey = "escTempLevel", sound = "evt/esctemp.wav" }
local MCU_TEMPERATURE_ALERT = { alertKey = "mcu_temperature", levelKey = "mcuTempLevel", sound = "stat/alerts/mcu.wav" }

local function coarseFuelThresholds(selection)
  local sel = tonumber(selection) or 10
  if sel == 0 then return { 100, 10 } end
  if sel == 5 then return { 100, 95, 90, 85, 80, 75, 70, 65, 60, 55, 50, 45, 40, 35, 30, 25, 20, 15, 10, 5 } end
  if sel == 10 then return { 100, 90, 80, 70, 60, 50, 40, 30, 20, 10 } end
  if sel == 20 then return { 100, 80, 60, 40, 20, 10 } end
  if sel == 25 then return { 100, 75, 50, 25, 10 } end
  if sel == 50 then return { 100, 50, 10 } end
  if sel > 0 then return { sel } end
  return { 100, 90, 80, 70, 60, 50, 40, 30, 20, 10 }
end

-- The levels *Finer below* offers (Settings > Audio > Events > SmartFuel). Any other value, the
-- missing key included, is Off: the callout steps are the coarse ones alone, exactly as before
-- the setting existed. *Finer step* outside its three values reads as its default, 5 %.
local FUEL_FINER_BELOW = { [10] = true, [15] = true, [20] = true, [25] = true, [30] = true, [40] = true, [50] = true }
local FUEL_FINER_STEP = { [1] = true, [2] = true, [5] = true }

-- The list the callout last asked for, kept with the three settings it was built from: the
-- callout runs on every audio pass and its settings change only when a page is saved.
local fuelThresholdsFor = { selection = false, below = false, step = false, list = nil }

--- The levels at which the falling SmartFuel level is spoken, highest first (the crossing test
--- in Audio.process speaks the lowest one passed and relies on that order).
---
--- With *Finer below* at T and a *Finer step* of s: the coarse steps above T, then T itself,
--- then every multiple of s below T down to s. So every 20 % with finer steps of 5 % below 30 %
--- is 100, 80, 60, 40, 30, 25, 20, 15, 10, 5; with 2 % below 25 % the finer part is 25, 24, 22 … 2.
local function fuelThresholdList(selection, finerBelow, finerStep)
  local cache = fuelThresholdsFor
  if cache.list and cache.selection == selection and cache.below == finerBelow and cache.step == finerStep then
    return cache.list
  end

  local list = coarseFuelThresholds(selection)
  local below = tonumber(finerBelow)
  if below and FUEL_FINER_BELOW[below] then
    local step = tonumber(finerStep)
    if not (step and FUEL_FINER_STEP[step]) then step = 5 end
    local merged = {}
    for i = 1, #list do
      if list[i] > below then merged[#merged + 1] = list[i] end
    end
    merged[#merged + 1] = below
    local level = below - (below % step)
    if level == below then level = level - step end
    while level >= step do
      merged[#merged + 1] = level
      level = level - step
    end
    list = merged
  end

  cache.selection, cache.below, cache.step, cache.list = selection, finerBelow, finerStep, list
  return list
end

local function resolveSmartfuelModel(self)
  local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
  local batteryConfig = session and (session.batteryConfig or session.battery_config) or nil
  local batteryPrefs = session and session.modelPreferences and session.modelPreferences.battery or nil
  local modelType = tonumber(batteryPrefs and batteryPrefs.smartfuel_model_type) or 0

  local cellCount = tonumber(batteryConfig and batteryConfig.batteryCellCount) or tonumber(self.state and self.state.batteryCellCount) or 0
  local hasCapacity = false
  if batteryConfig then
    local totalCap = tonumber(batteryConfig.batteryCapacity) or 0
    if totalCap > 0 then
      hasCapacity = true
    else
      for i = 0, 5 do
        if (tonumber(batteryConfig["batteryCapacity_" .. tostring(i)]) or 0) > 0 then
          hasCapacity = true
          break
        end
      end
    end
  end

  local autoElectric = (cellCount > 0) or hasCapacity
  local isElectric = autoElectric
  if modelType == 1 then
    isElectric = true
  elseif modelType == 2 then
    isElectric = false
  end
  return isElectric, modelType, cellCount, hasCapacity
end

-- Whether the battery configuration has been read from the flight controller. A read always
-- carries batteryCellCount (0 on a board without a battery); the battery and sources pages may
-- store an empty table before it arrives, which decides nothing.
local function batteryConfigRead()
  local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
  local batteryConfig = session and (session.batteryConfig or session.battery_config) or nil
  return type(batteryConfig) == "table" and batteryConfig.batteryCellCount ~= nil
end

local function getModelName()
  if type(model) ~= "table" or type(model.getInfo) ~= "function" then
    return nil
  end
  local ok, info = pcall(model.getInfo)
  if not ok or type(info) ~= "table" then
    return nil
  end
  local name = info.name
  if type(name) ~= "string" or name == "" then
    return nil
  end
  return name
end

local function resolveModelName(modelName)
  if type(modelName) == "string" and modelName ~= "" then
    return modelName
  end
  if type(model) == "table" and type(model.getInfo) == "function" then
    local ok, info = pcall(model.getInfo)
    if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
      return info.name
    end
  end
  return nil
end

local function announceModelName(audioState, modelName, opts)
  local name = resolveModelName(modelName)
  if not name or type(name) ~= "string" or name == "" then return end

  local candidates = {
    "/SOUNDS/" .. name .. ".wav",
    "/SOUNDS/" .. string.gsub(name, " ", "_") .. ".wav",
    "SOUNDS/" .. name .. ".wav",
    "SOUNDS/" .. string.gsub(name, " ", "_") .. ".wav"
  }

  -- Als angekuendigt markieren, um endlose Fehler loops zu vermeiden
  audioState.modelAnnounced = true

  for i = 1, #candidates do
    local path = candidates[i]
    local f = io.open(path, "r")
    if f then
      io.close(f)
      emitLog(opts, "model announcement -> " .. path, "info")
      if playRawFile(path, opts) then
        return
      end
    else
      emitLog(opts, "model announcement file not found: " .. path, "debug")
    end
  end
end

local function announceProfileEvent(self, eventKey, value, soundFile, opts)
  local rounded = roundProfileValue(value)
  if rounded == nil or rounded <= 0 then
    return
  end

  local audioState = self.audioState
  local profileJob = _G.rfsuite and _G.rfsuite.inflightProfileJob
  if profileJob then
    -- Track the return pair while temporary MSP selections are deliberately silent.
    local kind = eventKey == "pid_profile" and "pid" or "rate"
    audioState.lastValues[eventKey] = profileJob.original and profileJob.original[kind] or rounded
    audioState.pendingValues[eventKey] = nil
    return
  end
  if not audioState.lastAlertAt then
    audioState.lastAlertAt = { voltage = 0, esc_temperature = 0 }
  end
  if audioState.lastValues[eventKey] == rounded then
    return
  end

  local now = nowSeconds()
  if now < (audioState.nextAllowedAt or 0) then
    return
  end

  local events = (self.preferences and self.preferences.audio_events) or nil
  if not prefEnabled(events, eventKey, true) then
    audioState.lastValues[eventKey] = rounded
    audioState.pendingValues[eventKey] = nil
    return
  end

  if audioState.initialized then
    emitLog(opts, eventKey .. " change value=" .. tostring(rounded) .. " file=" .. tostring(soundFile), "info")
    tryPlayEventFile(audioState, now, soundFile, opts)
    if type(playNumber) == "function" then
      emitLog(opts, "playNumber -> " .. tostring(rounded), "info")
      local ok, err = pcall(playNumber, rounded, 0, 0, audio_volume)
      if not ok then emitLog(opts, "playNumber error: " .. tostring(err), "error") end
    end
    audioState.lastValues[eventKey] = rounded
    audioState.pendingValues[eventKey] = nil
  else
    audioState.lastValues[eventKey] = rounded
  end
end

local function announceArmEvent(self, opts)
  local value = roundProfileValue(self.state.armFlags)
  if value == nil then return end

  local audioState = self.audioState
  if audioState.lastValues.arming_flags == value then
    return
  end

  if not audioState.initialized then
    audioState.lastValues.arming_flags = value
    return
  end

  -- Not while the previous file's cooldown runs: tryPlayEventFile would refuse the file, and a
  -- value recorded here is never tried again. Left unrecorded, the next pass announces it.
  local now = nowSeconds()
  if now < (audioState.nextAllowedAt or 0) then
    return
  end

  audioState.lastValues.arming_flags = value
  local file = ARM_FILE_MAP[value]
  if type(file) ~= "string" then return end
  tryPlayEventFile(audioState, now, "evt/" .. file, opts)
end

local function announceGovernorEvent(self, events, opts)
  local value = roundProfileValue(self.state.governor)
  if value == nil then return false end

  local audioState = self.audioState
  if audioState.lastValues.governor_state == value then
    -- Back on the state last spoken, so whatever was seen in between was a transient.
    audioState.governorPending = nil
    return false
  end

  if not audioState.initialized then
    audioState.lastValues.governor_state = value
    return false
  end

  -- A new state is a candidate first. It is spoken once it has stood for the hold time; a
  -- state that changes again before that is replaced without a word.
  local now = nowSeconds()
  if audioState.governorPending ~= value then
    audioState.governorPending = value
    audioState.governorPendingSince = now
    return false
  end
  if now - (tonumber(audioState.governorPendingSince) or now) < GOVERNOR_HOLD_SECONDS then
    return false
  end
  -- The same for a file still in its cooldown -- most often the arm announcement of this very
  -- pass, since a spool-up follows the arm. The candidate stays pending for the next pass.
  if now < (audioState.nextAllowedAt or 0) then
    return false
  end

  audioState.lastValues.governor_state = value
  audioState.governorPending = nil

  local key = GOVERNOR_PREF_KEYS[value]
  if key and not prefEnabled(events, key, true) then
    emitLog(opts, "governor state " .. tostring(value) .. " not announced: " .. key .. " is off", "debug")
    return false
  end

  local file = GOVERNOR_FILE_MAP[value]
  if type(file) ~= "string" then return false end
  return tryPlayEventFile(audioState, now, "gov/" .. file, opts)
end

-- A change between two readings of the rescue state is spoken at once, the start of a rescue
-- and its end each under a switch of its own; no repeat and no vibration. A first reading -- after
-- a connect, or after the switches were off -- is only recorded, so a rescue already under way
-- is not announced as if it had just begun. While both switches are off nothing is tracked.
--
-- `rescueWanted` tells both callers whether to read the state at all (ui/home.lua and
-- widgets/dashboard/runtime.lua): a radio that never switches this on pays no sensor search
-- for it, which on a flight controller sending neither Rescue State nor System Status is two
-- searches that find nothing.
local function announceRescueEvent(self, events, opts)
  local audioState = self.audioState
  local announceActive = prefEnabled(events, "rescue_active", false)
  local announceOff = prefEnabled(events, "rescue_off", false)
  audioState.rescueWanted = announceActive or announceOff
  if not (announceActive or announceOff) then
    audioState.lastValues.rescue = nil
    return
  end

  local value = roundProfileValue(self.state.rescue)
  if value == nil then return end
  local active = value ~= 0
  local last = audioState.lastValues.rescue
  if last == active then return end
  if last == nil then
    audioState.lastValues.rescue = active
    return
  end

  -- Left unrecorded while the previous file's cooldown runs, so the next pass speaks it.
  local now = nowSeconds()
  if now < (audioState.nextAllowedAt or 0) then return end

  audioState.lastValues.rescue = active
  if active and announceActive then
    tryPlayEventFile(audioState, now, RESCUE_ACTIVE_SOUND, opts)
  elseif not active and announceOff then
    tryPlayEventFile(audioState, now, RESCUE_OFF_SOUND, opts)
  end
end

local function announceBatteryCapacityEvent(self, opts)
  local profile = roundProfileValue(self.state.batteryProfile)
  if profile == nil or profile < 1 or profile > 6 then
    return
  end

  local configIndex = profile

  local audioState = self.audioState
  if not audioState.lastAlertAt then
    audioState.lastAlertAt = { voltage = 0, esc_temperature = 0 }
  end

  if audioState.lastValues.battery_profile == profile and audioState.batteryCapacityAnnounced then
    return
  end

  local capacity = nil
  local configReady = false
  if type(_G) == "table" and _G.rfsuite and _G.rfsuite.session then
    local bConf = _G.rfsuite.session.battery_config
    if type(bConf) == "table" then
      capacity = bConf["batteryCapacity_" .. tostring(configIndex - 1)]
      configReady = true
    end
  end

  if not configReady then
    return
  end

  -- The battery configuration arrives over MSP, so it cannot be here on the first pass, and
  -- by the time it is `initialized` is already true. `lastValues.battery_profile` is still
  -- nil at that point, which makes a value that has just ARRIVED indistinguishable from one
  -- the pilot has CHANGED. A caller whose audio state is built fresh for reasons of its own,
  -- rather than because the craft reconnected, sets this flag so the first configuration it
  -- sees is recorded instead of announced. It clears itself, so a later reconnect announces.
  if audioState.seedBatteryCapacity then
    audioState.seedBatteryCapacity = nil
    audioState.lastValues.battery_profile = profile
    audioState.batteryCapacityAnnounced = true
    return
  end

  local now = nowSeconds()
  if now < (audioState.nextAllowedAt or 0) then
    return
  end

  local events = (self.preferences and self.preferences.audio_events) or nil
  if not prefEnabled(events, "battery_profile", true) then
    audioState.lastValues.battery_profile = profile
    audioState.batteryCapacityAnnounced = true
    return
  end

  if not audioState.initialized then
    audioState.batteryCapacityAnnounced = false
    return
  end

  if capacity and capacity > 0 then
    emitLog(opts, "battery capacity change profile=" .. tostring(profile) .. " capacity=" .. tostring(capacity), "info")
    tryPlayEventFile(audioState, now, "evt/battery.wav", opts)
    if type(playNumber) == "function" then
      emitLog(opts, "playNumber -> " .. tostring(capacity) .. " mAh", "info")
      local ok, err = pcall(playNumber, capacity, unitMah(), 0, audio_volume)
      if not ok then emitLog(opts, "playNumber error: " .. tostring(err), "error") end
    end
  else
    emitLog(opts, "battery profile change value=" .. tostring(profile) .. " file=evt/battery.wav", "info")
    tryPlayEventFile(audioState, now, "evt/battery.wav", opts)
    if type(playNumber) == "function" then
      local ok, err = pcall(playNumber, configIndex, 0, 0, audio_volume)
      if not ok then emitLog(opts, "playNumber error: " .. tostring(err), "error") end
    end
  end

  audioState.lastValues.battery_profile = profile
  audioState.batteryCapacityAnnounced = true
end

-- Whether the pack the model came up with is full, judged once per connection and then latched
-- in `memo`: in flight the per-cell voltage falls past any margin, and without the latch the
-- answer would turn from a verdict on the pack that was plugged in into a reading of the
-- discharge.
--
-- true  the pack is not full: its voltage per cell is below the flight controller's full-cell
--       voltage less `events.pack_not_full_margin` millivolts
-- false the pack was judged full
-- nil   not judged yet
--
-- Nothing is judged until everything it needs is there -- a pack voltage, a cell count and a
-- battery configuration to take the full-cell voltage from -- so a missing piece costs a pass
-- and not a wrong answer. The battery configuration arrives over MSP, which is the same
-- reason the voltage alert skips until it is available.
--
-- Judged in one place, the *Pack Not Full* announcement below, which asks for it whether or not
-- the announcement is switched on, so the verdict is there for a screen to draw either way. It is
-- asked from `Audio.process` and nowhere earlier on purpose: the caller runs it only once its
-- connect chain has finished, and right after a reconnect the pack voltage the radio hands over is
-- still the previous pack's for a moment -- a verdict taken on the first reading that has a voltage
-- would be a verdict on the pack that was unplugged. resetConnectionState clears the latch, so a
-- real reconnect judges again. A screen reads the latched answer with `Audio.packVerdict`.
function Audio.packNotFull(state, memo, events)
  if type(memo) ~= "table" then
    return nil
  end
  if memo.packJudged == true then
    return memo.packNotFull
  end

  local voltage = tonumber(state and state.voltage)
  if type(voltage) ~= "number" or voltage <= 0 then
    return nil
  end

  local bc = sessionBatteryConfig()
  if not bc then
    return nil
  end

  -- A configured cell count of 0 means auto-detect, so telemetry answers instead.
  local cells = flightPackCells(state, bc)
  if not cells then
    return nil
  end

  -- Full cell voltage, not Max: Max is the top of a cell's range, which the flight controller
  -- uses to detect the cell count (4.30 V by default, above what a charged pack reads). Full is
  -- what the firmware's own "battery not full" warning compares with, and without a margin.
  local fullCell = normalizeCellVoltage(bc.vbatfullcellvoltage, 4.1)
  local margin = tonumber(events and events.pack_not_full_margin) or 0
  if margin < 0 then margin = 0 end
  local perCell = voltage / cells

  memo.packJudged = true
  memo.packNotFull = perCell < fullCell - (margin / 1000)
  -- Kept for the announcement, which speaks the reading the verdict was taken on rather than
  -- whatever the pack reads by the time it may speak.
  memo.packVoltage = voltage
  memo.packCells = cells
  memo.packFullCell = fullCell
  memo.packMargin = margin
  return memo.packNotFull
end

-- The verdict above as it stands, without judging: true, false, or nil while it has not been
-- judged on this connection. For a screen, which publishes it on its own cadence; reading it
-- costs one test.
function Audio.packVerdict(memo)
  if type(memo) ~= "table" or memo.packJudged ~= true then
    return nil
  end
  return memo.packNotFull
end

-- The announcement of the verdict above: once per connection, when the verdict is in and the
-- pilot has switched it on. `packCheckDone` latches what has been SPOKEN for this connection,
-- which is a different thing from the verdict -- the verdict stands whether or not anything was
-- said about it.
local function announcePackNotFullEvent(self, events, opts)
  local audioState = self.audioState
  if audioState.packCheckDone then
    return
  end

  local now = nowSeconds()
  if now < (audioState.nextAllowedAt or 0) then
    return
  end

  -- Judged before the switch is asked, so the verdict is there for a screen to draw with the
  -- announcement off.
  local notFull = Audio.packNotFull(self.state, audioState, events)
  if notFull == nil then
    return
  end

  if not prefEnabled(events, "pack_not_full", false) then
    return
  end

  -- The reasoning of seedInitialFuel further down, applied to this check: a caller that
  -- rebuilt its audio state has not reconnected, and the pack it would report on was judged
  -- when the craft actually came up. The flag clears itself, so a real reconnect judges again.
  if audioState.seedPackCheck then
    audioState.seedPackCheck = nil
    audioState.packCheckDone = true
    return
  end

  audioState.packCheckDone = true

  local voltage = audioState.packVoltage
  local cells = audioState.packCells
  local perCell = voltage / cells

  if not notFull then
    emitLog(opts, "pack check: full at " .. tostring(perCell) .. " V/cell over " .. tostring(cells) .. " cells", "debug")
    return
  end

  emitLog(opts, "pack not full: " .. tostring(perCell) .. " V/cell against " .. tostring(audioState.packFullCell)
    .. " V less a " .. tostring(audioState.packMargin) .. " mV margin", "info")

  -- notfull.wav is this announcement's own file. Every pack ships voltage.wav, so a pack that
  -- predates notfull.wav still says something rather than nothing, and
  -- resolveEventPath caches the answer, so the probe costs one open per session.
  local soundFile = "stat/alerts/notfull.wav"
  if not resolveEventPath(soundFile) then
    soundFile = "stat/alerts/voltage.wav"
  end

  if tryPlayEventFile(audioState, now, soundFile, opts) then
    playPackVoltage(events, voltage, cells, opts)
  end
end

-- The main pack is gone while the flight controller is still answering. That is what a backup
-- guard or a separate receiver battery is for, and it is the one power failure telemetry can
-- report at all: everything else keeps arriving, so nothing in the suite would otherwise
-- notice that the machine is now flying on its reserve.
--
-- Three things have to be true together, and the second is what keeps a model whose pack is
-- not measured at all quiet: the pack reads as gone rather than merely low, it has read a real
-- voltage at some point this connection, and a BEC voltage is there beside it -- without one
-- there is no evidence that anything is still being powered.
--
-- `memo` carries the only history the test needs, the second of the three, and it is the
-- caller's table so that it is cleared on the same edge everything else about a connection is.
function Audio.mainPowerLost(state, memo)
  local voltage = tonumber(state and state.voltage)
  if type(voltage) ~= "number" then
    return false
  end

  if voltage > MAIN_POWER_LOST_VOLTS then
    if type(memo) == "table" then memo.packVoltageSeen = true end
    return false
  end

  if not (type(memo) == "table" and memo.packVoltageSeen == true) then
    return false
  end

  local bec = tonumber(state and (state.bec_voltage or state.becVoltage))
  if type(bec) ~= "number" or bec <= 0 then
    return false
  end

  return true
end

-- Announced again every 10 seconds while the condition holds, which is the interval every
-- other repeating alert in this file uses, and once more when the pack comes back.
--
-- The three tests are Audio.mainPowerLost above, so that a screen can show the same fact this
-- announcement speaks without a second reading of it. `mainPowerLostActive` stays here and is
-- not that fact: it is set only where the sound actually played, so it says what has been
-- announced rather than what is true.
local function announceMainPowerEvent(self, events, opts, fcQuiet)
  if not prefEnabled(events, "main_power_lost", false) then
    return
  end

  local audioState = self.audioState
  -- Nothing is judged while the flight controller's frames stay away (`fcQuiet`, Audio.process):
  -- the pack and BEC readings are its last ones, and a lost pack would be announced again every
  -- interval from a reading nobody sends any more. Whatever has been announced stays as it is,
  -- so the pack coming back is still spoken once the frames do.
  if fcQuiet then
    return
  end
  local voltage = tonumber(self.state and self.state.voltage)
  if type(voltage) ~= "number" then
    return
  end

  local now = nowSeconds()
  local lost = Audio.mainPowerLost(self.state, audioState)

  if not lost then
    if voltage > MAIN_POWER_LOST_VOLTS and audioState.mainPowerLostActive then
      audioState.lastAlertAt.main_power = 0
      alertCleared(audioState, "main_power")
      -- The flag says what has been announced, so it goes only once the pack coming back has
      -- been: refused by the cooldown after another announcement in this pass, it is tried again
      -- on the next one. A sound pack with neither file has nothing to say, so that is done too.
      local soundFile = firstResolvedSound(MAIN_POWER_OK_SOUNDS)
      local played, why = false, PLAY_NO_FILE
      if soundFile then
        played, why = tryPlayEventFile(audioState, now, soundFile, opts)
      end
      if announcementDone(played, why) then
        audioState.mainPowerLostActive = false
        emitLog(opts, "main power back at " .. string.format("%.1f", voltage) .. " V", "info")
        if played then
          playPackVoltage(events, voltage, flightPackCells(self.state, sessionBatteryConfig()), opts)
        end
      end
    end
    return
  end

  local bec = tonumber(self.state and (self.state.bec_voltage or self.state.becVoltage))

  if not alertMaySpeak(audioState, events, "main_power", now) then
    return
  end

  local soundFile = firstResolvedSound(MAIN_POWER_LOST_SOUNDS)
  if not soundFile then
    return
  end

  if tryPlayAlertFile(self, audioState, events, now, soundFile, opts, "main_power", true) then
    -- The BEC voltage and not the pack's, because it is the reading that still means
    -- something: it says how much is left of whatever is keeping the receiver alive.
    playVoltage(bec, 1, opts)
    alertSpoken(audioState, events, "main_power", now)
    audioState.mainPowerLostActive = true
    emitLog(opts, "main power lost, BEC at " .. string.format("%.1f", bec) .. " V", "warn")
  end
end

-- Whether the value under `lq` may be read as a link quality in percent. Two independent
-- tests, because either can be the only one available: the caller reports which sensor the
-- search settled on, and the value has to fall inside the range a percentage has. A receiver
-- without an `RQly` sensor answers with an RSSI in dBm, which is negative and would put the
-- alert below any threshold for the whole flight.
--
-- Declining is logged once per connection. Repeating it would be several lines a second, and
-- a receiver that reports no quality does not start reporting one later in the same session.
local function linkIsQuality(self, audioState, lq, opts)
  local source = self.state and self.state.lqSource
  -- 0 is left out on purpose: it is what both callers read as "no link" -- the tool's
  -- readiness test is `lq ~= 0`, the widget's telemetry latch the same -- and it is what
  -- the link sensor reads once it has aged out, which on the widget happens while the MSP
  -- side still counts as connected. Accepting it would announce a lost link as a quality
  -- of nought, with the haptic, which is another announcement's job.
  local usable = lq > 0 and lq <= 100
  if type(source) == "string" and RSSI_LINK_SOURCES[source] then
    usable = false
  end
  if usable then
    return true
  end

  if not audioState.lqNotQualityLogged then
    audioState.lqNotQualityLogged = true
    emitLog(opts, "link quality alert off: link resolved to an RSSI rather than a percentage"
      .. " (source=" .. tostring(source) .. " value=" .. tostring(lq) .. ")", "debug")
  end
  return false
end

-- A core module, through the loader where there is one and off the card where there is not --
-- the same two routes the dashboard's own link sources load lib/link_rates.lua by
-- (widgets/dashboard/objects/common.lua, loadCoreModule).
local function loadCoreModule(path)
  if type(_G) == "table" and _G.rfsuite and type(_G.rfsuite.require) == "function" then
    local ok, mod = pcall(_G.rfsuite.require, path)
    if ok and type(mod) == "table" then return mod end
  end
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/" .. path, mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

--- What the link is running, as a row of lib/link_rates.lua, or nil.
---
--- `state` is the caller's: `rfMode` is this pass's `RFMD` reading, and the transmitter module's
--- ExpressLRS generation is asked for and kept on the same table (LinkRates.resolveGeneration),
--- which on the dashboard widget is the table its link sources keep it on, so the two share one
--- ping. Nil while the link is down, before `RFMD` has a reading, while the generation is not
--- known, and for a module that is not ExpressLRS 3.x or 4.x.
local function linkRateRow(state, rates)
  if state.rfConnected ~= true then return nil end
  local mode = tonumber(state.rfMode)
  if mode == nil then return nil end
  if not crsfModule then crsfModule = loadCoreModule("lib/crsf.lua") end
  local generation = rates.resolveGeneration(state, crsfModule, _G.crossfireTelemetryPush)
  if generation == nil then return nil end
  return rates.forMode(mode, generation)
end

--- One link headroom alert for one pass: the shape of the link quality alert, with the hold of
--- the voltage alert. A level is entered once the headroom has stayed at or below its line for
--- the hold, so a rotor-induced antenna null that is over within the hold stays quiet; a level
--- that has been entered is spoken at once rather than at the next interval, with the headroom
--- after it. Leaving a level costs `hysteresis` points above its line, recovering is not spoken,
--- and only the critical level buzzes, where the Link page's Haptic is on.
local function linkHeadroomAlert(self, audioState, events, alert, headroom, hysteresis, now, opts)
  local slots = audioState.linkHeadroom
  local slot = slots[alert.alertKey]
  if not slot then
    slot = {}
    slots[alert.alertKey] = slot
  end
  -- No reading, or no floor to hold it against: nothing to judge this pass. The hold timers are
  -- left as they are, so a single pass whose sensor read comes back empty neither restarts a hold
  -- nor counts as a recovery.
  if headroom == nil then return end

  local warn = tonumber(events[alert.warnKey]) or alert.warn
  local critical = tonumber(events[alert.criticalKey]) or alert.critical
  -- A critical level above the warning level cannot be crossed second, so the lower of the two
  -- is the critical one. Nothing is refused over it; the pair is just ordered.
  if critical > warn then critical = warn end
  local hold = tonumber(events[alert.holdKey]) or alert.hold
  if hold < 0 then hold = 0 end

  -- When the headroom last went under each line and has stayed there since.
  if headroom <= warn then
    if slot.warnSince == nil then slot.warnSince = now end
  else
    slot.warnSince = nil
  end
  if headroom <= critical then
    if slot.criticalSince == nil then slot.criticalSince = now end
  else
    slot.criticalSince = nil
  end

  local level = 0
  if slot.criticalSince ~= nil and (now - slot.criticalSince) >= hold then
    level = 2
  elseif slot.warnSince ~= nil and (now - slot.warnSince) >= hold then
    level = 1
  end

  local spoken = slot.level or 0
  if level < spoken then
    if spoken >= 2 and headroom <= critical + hysteresis then
      level = 2
    elseif level < 1 and spoken >= 1 and headroom <= warn + hysteresis then
      level = 1
    end
  end

  local key = alert.alertKey
  if level < spoken then
    slot.level = level
    alertCleared(audioState, key)
  elseif level > 0 then
    if level > spoken then
      audioState.lastAlertAt[key] = 0
      alertCleared(audioState, key)
    end
    if alertMaySpeak(audioState, events, key, now) then
      local played, why = tryPlayAlertFile(self, audioState, events, now, alert.sound, opts, key, level >= 2)
      if announcementDone(played, why) then
        if played and type(playNumber) == "function" then
          local ok, err = pcall(playNumber, headroom, unitPercent(), 0, audio_volume)
          if not ok then emitLog(opts, "playNumber error: " .. tostring(err), "error") end
        end
        alertSpoken(audioState, events, key, now, played and level >= 2)
        slot.level = level
      end
    end
  end
end

--- The link headroom alerts for one pass, called while at least one of them is on.
---
--- The rate is resolved whether or not the model is armed, so that the generation query -- one
--- device ping per connection -- has been answered by the time it is; the alerts themselves speak
--- only while armed, and disarming ends their episodes.
local function announceLinkHeadroom(self, audioState, events, enabled, now, opts)
  if not linkRatesModule then linkRatesModule = loadCoreModule("lib/link_rates.lua") end
  local rates = linkRatesModule
  if not rates then return end
  local state = self.state
  local row = linkRateRow(state, rates)

  if type(audioState.linkHeadroom) ~= "table" then audioState.linkHeadroom = {} end
  if not isArmedFromState(state) then
    if next(audioState.linkHeadroom) ~= nil then
      audioState.linkHeadroom = {}
      for i = 1, #LINK_HEADROOM_ALERTS do alertCleared(audioState, LINK_HEADROOM_ALERTS[i].alertKey) end
    end
    return
  end

  local floor = row and row.floor
  for i = 1, #LINK_HEADROOM_ALERTS do
    local alert = LINK_HEADROOM_ALERTS[i]
    if enabled[i] then
      local value, hysteresis
      if alert.snr then
        value, hysteresis = rates.snrPercent(alert.read(state), row), rates.snrPointsPerDb(row)
        -- One dB of a 1.5 dB window is 67 points: a warning level of 33 % or more plus that would
        -- lie past the top of the scale and could never be left. So at the top of the scale (at or
        -- above the threshold at which ExpressLRS asks for less power) the hysteresis is waived
        -- and every level below 100 % is left; below it, one dB holds as everywhere else.
        if value and value >= 100 then hysteresis = 0 end
      else
        value, hysteresis = rates.headroom(alert.read(state), floor), LINK_HEADROOM_HYSTERESIS
      end
      linkHeadroomAlert(self, audioState, events, alert, value, hysteresis, now, opts)
    elseif audioState.linkHeadroom[alert.alertKey] ~= nil then
      -- Switched off mid-flight: its episode ends, so switching it on again starts a new one.
      audioState.linkHeadroom[alert.alertKey] = nil
      alertCleared(audioState, alert.alertKey)
    end
  end
end

-- Which link headroom alerts are on this pass, in LINK_HEADROOM_ALERTS order. Filled by
-- Audio.process on every pass rather than built there, so a pass allocates nothing for it.
local linkHeadroomEnabled = {}

-- The two ends of the range the page offers for each setting; a hand-edited preferences file is
-- brought back inside them rather than trusted.
local function clampedSetting(events, key, default, minValue, maxValue)
  local value = tonumber(events and events[key])
  if value == nil then return default end
  value = math.floor(value)
  if value < minValue then return minValue end
  if value > maxValue then return maxValue end
  return value
end

-- Ends a telemetry dropouts episode: the next one starts with a full repeat count.
local function clearDropouts(audioState)
  audioState.dropoutsBelowSince = nil
  if audioState.dropoutsActive then
    audioState.dropoutsActive = nil
    alertCleared(audioState, "dropouts")
  end
end

--- Telemetry dropouts: the flight controller's frames are being missed too often, right now.
---
--- The source is the suite's own skipped-frame counter (`skipped_frames`), the number of gaps in
--- the frame ids of the flight controller's custom telemetry since the link came up. It is
--- cumulative, so it says that a flight HAD gaps; what is spoken is a RATE instead -- the rise of
--- the counter within the last `dropouts_window` seconds against `dropouts_count`.
---
--- The counter is published every 2 s at most, so the window is held as the readings in which it
--- rose: `audioState.dropoutSamples`, a list of `{ at = seconds, value = count }`, oldest first.
--- The baseline is the newest sample taken at or before `now - window`, or the oldest one while
--- none is that old (the first reading of this episode); everything older than the baseline is
--- dropped, so the list holds at most one entry per publication inside the window plus one.
---
--- A reading below the last one is the counter starting over (the widget's and the tool's
--- decoder reset it when the link is lost): a new start, never a negative rise and never an
--- alarm. A missing reading leaves the window as it is. Disarmed, or switched off, the window is
--- dropped, so gaps on the ground before arming are never counted into the flight.
---
--- Spoken at once when the rise reaches the count, then repeated as the link category's Repeat
--- says; re-armed once the rise within the window has stayed below the count for a whole window.
--- Recovery is not spoken, and it never vibrates: it has one level, and the link alert's lower
--- level does not vibrate either. `dropoutsWanted` tells both callers whether to read the counter
--- at all (ui/home.lua and widgets/dashboard/runtime.lua), so a radio that never switches this on
--- pays no sensor search for it.
local function announceDropoutsEvent(self, events, opts)
  local audioState = self.audioState
  local enabled = prefEnabled(events, "dropouts_alert", false)
  audioState.dropoutsWanted = enabled
  if not enabled or not isArmedFromState(self.state) then
    audioState.dropoutSamples = nil
    clearDropouts(audioState)
    return
  end

  local reading = tonumber(self.state.skippedFrames)
  if reading == nil then return end
  reading = math.floor(reading + 0.5)

  local now = nowSeconds()
  local samples = audioState.dropoutSamples
  if samples == nil or reading < samples[#samples].value then
    audioState.dropoutSamples = { { at = now, value = reading } }
    clearDropouts(audioState)
    return
  end
  if reading > samples[#samples].value then
    samples[#samples + 1] = { at = now, value = reading }
  end

  local window = clampedSetting(events, "dropouts_window", 10, 4, 60)
  local count = clampedSetting(events, "dropouts_count", 3, 1, 50)
  local since = now - window
  while #samples >= 2 and samples[2].at <= since do
    table.remove(samples, 1)
  end

  if reading - samples[1].value < count then
    -- Leaving costs a whole window below the count, as leaving a link quality level costs
    -- LQ_HYSTERESIS points. A rate resting on the count otherwise falls below and climbs back
    -- with every gap, and each climb would be a new episode, spoken at once with a full repeat
    -- count. Nothing is spoken while it holds below.
    if audioState.dropoutsActive then
      local below = audioState.dropoutsBelowSince
      if below == nil then
        audioState.dropoutsBelowSince = now
      elseif now - below >= window then
        clearDropouts(audioState)
      end
    end
    return
  end
  audioState.dropoutsBelowSince = nil

  if not audioState.dropoutsActive then
    -- Reaching the count is announced at once rather than at the next interval, with a full
    -- repeat count.
    audioState.dropoutsActive = true
    audioState.lastAlertAt.dropouts = 0
    alertCleared(audioState, "dropouts")
  end

  if not resolveEventPath(DROPOUTS_SOUND) then
    if not audioState.dropoutsSoundMissingLogged then
      audioState.dropoutsSoundMissingLogged = true
      emitLog(opts, "no " .. DROPOUTS_SOUND .. " in this sound pack; nothing is spoken", "warn")
    end
    return
  end

  if alertMaySpeak(audioState, events, "dropouts", now)
      and tryPlayAlertFile(self, audioState, events, now, DROPOUTS_SOUND, opts, "dropouts", true) then
    alertSpoken(audioState, events, "dropouts", now, false)
  end
end


-- Has the connect chain finished? Asked of the events runtime that both callers already hold in
-- the suite's module cache (ui/home.lua, widgets/dashboard/runtime.lua), with the test the
-- dashboard makes before it draws (done >= total, widgets/dashboard/runtime.lua). The tool runs
-- this module as soon as the link and a battery reading are up, which is before the chain is
-- through. Where the runtime is not in the cache there is no chain to wait for.
local EVENTS_RUNTIME_PATH = "/SCRIPTS/TOOLS/rfsuite-core/tasks/events/runtime.lua"
local function connectChainDone()
  local modules = type(_G) == "table" and _G.rfsuite and _G.rfsuite.modules or nil
  local events = type(modules) == "table" and modules[EVENTS_RUNTIME_PATH] or nil
  if type(events) ~= "table" or type(events.getOnconnectProgress) ~= "function" then return true end
  local progress = events.getOnconnectProgress()
  if type(progress) ~= "table" or type(progress.total) ~= "number" or type(progress.done) ~= "number" then
    return true
  end
  return progress.total > 0 and progress.done >= progress.total
end

local function txPowerOwner(audioState, create)
  if audioState.txPowerOwner == nil and create then
    audioOwnerSequence = audioOwnerSequence + 1
    audioState.txPowerOwner = "audio:" .. tostring(audioOwnerSequence)
  end
  return audioState.txPowerOwner
end

local function cancelTxPowerRead(audioState, reason)
  local owner = txPowerOwner(audioState, false)
  if owner and elrsConfigModule and type(elrsConfigModule.cancel) == "function" then
    elrsConfigModule.cancel(owner, reason)
  end
  audioState.txPowerRequested = nil
end

--- Lets go of the ELRS configuration provider unless the TX power alert is on, and says whether
--- it did. The dashboard asks when its standby screen closes: with the alert off nothing in this
--- Lua state needs the provider any more, so it can be unloaded, and the alert loads it afresh
--- when it is switched on. With the alert on, the provider stays, and the one instance stays
--- shared, because parameter replies carry no transaction id.
function Audio.releaseElrsConfig(events)
  if prefEnabled(events, "tpwr_alert", false) then return false end
  elrsConfigModule = nil
  return true
end

--- The transmitter module's maximum power and dynamic-power state for this connection, copied
--- from the shared ELRS configuration snapshot; `done` is set once it has answered or given up.
---
--- The module is asked over the CRSF parameter protocol, and every frame sent to it goes out in
--- place of one RC channels frame (EdgeTX radio/src/pulses/crossfire.cpp, the Lua frame is copied
--- into the slot the channels would take). So it is asked only after the connect chain, only while
--- the model is disarmed -- the suite's MSP traffic stops while armed for the same reason
--- (tasks/msp/runtime.lua) -- and one frame per audio pass. A read an arming cuts short starts again
--- after the disarm. The answer is kept for the rest of the connection. The next connection asks
--- again once it is disarmed; one that comes up while the model is still armed -- a link that dropped
--- in flight -- uses the last connection's answer until then.
---
--- The shared ELRS configuration provider serializes this read with the diagnostics page and the
--- standby screen. All three consume one completed snapshot instead of competing for 0x2B replies.
local function txPowerModuleRead(audioState, armed, now)
  local st = audioState.txPowerRead
  if st and st.done then return st end
  if armed then
    cancelTxPowerRead(audioState, "armed")
    audioState.txPowerRead = nil
    -- Armed without an answer of this connection: where the link dropped and came back in flight,
    -- the module and its settings are the ones the last connection read (Audio.resetConnectionState
    -- keeps that answer), and nothing may be sent to ask again before the disarm.
    return audioState.txPowerLast
  end
  -- Disarmed, this connection asks for itself: the module may have been changed meanwhile.
  audioState.txPowerLast = nil
  if not connectChainDone() then
    cancelTxPowerRead(audioState, "connect_chain")
    return nil
  end
  if not elrsConfigModule then elrsConfigModule = loadCoreModule("lib/elrs_config.lua") end
  if not crsfModule then crsfModule = loadCoreModule("lib/crsf.lua") end
  if not elrsConfigModule then return nil end
  local identity = elrsConfigModule.currentIdentity()
  local fresh = audioState.txPowerRequested ~= identity
  local owner = txPowerOwner(audioState, true)
  local accepted = elrsConfigModule.request(identity, { owner = owner, force = fresh })
  if not accepted then return nil end
  audioState.txPowerRequested = identity
  local snapshot = elrsConfigModule.step({
    owner = owner, identity = identity, crsf = crsfModule,
    push = _G.crossfireTelemetryPush, now = now, allow = true,
  })
  if snapshot and snapshot.status ~= "reading" then
    local max = snapshot.fields and snapshot.fields.maxPower
    local dynamic = snapshot.fields and snapshot.fields.dynamic
    local dynamicValue = nil
    if dynamic then dynamicValue = dynamic.enabled end
    st = {
      done = true,
      maxMilliwatts = max and max.milliwatts or nil,
      dynamic = dynamicValue,
    }
    audioState.txPowerRead = st
    return st
  end
  return nil
end

--- The TX power alert for one pass, called while it is on.
---
--- The power is judged as a share of the most the module may send with: the module's own Max
--- Power, or the pilot's own maximum where that is switched on. It speaks only where the module
--- has said dynamic power is on. With fixed power the module sends at its maximum all the time,
--- so a share near 100 % says nothing about the link; and where the module could not be read --
--- not ExpressLRS, no answer, a power label that is not a plain number -- there is nothing to
--- hold the reading against, and it stays silent rather than guessing.
---
--- The shape of the link quality alert with the hold of the voltage alert: a level is entered once
--- the share has stayed at or above its line for the hold, a level entered is spoken at once with
--- the share after it, leaving a level costs TX_POWER_HYSTERESIS points below its line, recovering
--- is not spoken, and only the critical level buzzes, where the Link page's Haptic is on. Armed
--- only; disarming ends the episode.
local function txPowerAlert(self, audioState, events, now, opts)
  local state = self.state
  local armed = isArmedFromState(state)
  local read = txPowerModuleRead(audioState, armed, now)

  if not armed then
    if audioState.txPower ~= nil then
      audioState.txPower = nil
      alertCleared(audioState, "tpwr")
    end
    return
  end
  local slot = audioState.txPower
  if not slot then
    slot = {}
    audioState.txPower = slot
  end

  if not (read and read.done and read.dynamic == true) then return end
  local maximum
  if prefEnabled(events, "tpwr_limit", false) then
    maximum = tonumber(events.tpwr_max) or TX_POWER_OWN_MAX
  else
    maximum = read.maxMilliwatts
  end
  local power = tonumber(state.tpwr)
  if maximum == nil or maximum <= 0 or power == nil then return end
  local share = math.floor(100 * power / maximum + 0.5)
  if share > 100 then share = 100 end

  local warn = tonumber(events.tpwr_warn) or TX_POWER_WARN
  local critical = tonumber(events.tpwr_critical) or TX_POWER_CRITICAL
  -- A critical level below the warning level cannot be reached second, so the higher of the two
  -- is the critical one. Nothing is refused over it; the pair is just ordered.
  if critical < warn then critical = warn end
  local hold = tonumber(events.tpwr_hold) or TX_POWER_HOLD
  if hold < 0 then hold = 0 end

  -- When the share last reached each line and has stayed there since.
  if share >= warn then
    if slot.warnSince == nil then slot.warnSince = now end
  else
    slot.warnSince = nil
  end
  if share >= critical then
    if slot.criticalSince == nil then slot.criticalSince = now end
  else
    slot.criticalSince = nil
  end

  local level = 0
  if slot.criticalSince ~= nil and (now - slot.criticalSince) >= hold then
    level = 2
  elseif slot.warnSince ~= nil and (now - slot.warnSince) >= hold then
    level = 1
  end

  local spoken = slot.level or 0
  if level < spoken then
    if spoken >= 2 and share >= critical - TX_POWER_HYSTERESIS then
      level = 2
    elseif level < 1 and spoken >= 1 and share >= warn - TX_POWER_HYSTERESIS then
      level = 1
    end
  end

  if level < spoken then
    -- Recovering is not announced; the next rise is, with a full repeat count.
    slot.level = level
    alertCleared(audioState, "tpwr")
  elseif level > 0 then
    if level > spoken then
      audioState.lastAlertAt.tpwr = 0
      alertCleared(audioState, "tpwr")
    end
    if alertMaySpeak(audioState, events, "tpwr", now) then
      local played, why = tryPlayAlertFile(self, audioState, events, now, "stat/alerts/txpower.wav", opts, "tpwr",
        level >= 2)
      if announcementDone(played, why) then
        if played and type(playNumber) == "function" then
          local ok, err = pcall(playNumber, share, unitPercent(), 0, audio_volume)
          if not ok then emitLog(opts, "playNumber error: " .. tostring(err), "error") end
        end
        alertSpoken(audioState, events, "tpwr", now, played and level >= 2)
        slot.level = level
      end
    end
  end
end

--- The flight controller has stopped sending. Called from `Audio.process` once its telemetry
--- frames, after at least one arrived during this connection, have stayed away for
--- TELEMETRY_QUIET_SECONDS.
---
--- `rfLinkUp` is the radio's link at that moment, and it is what keeps this out of EdgeTX's way.
--- The radio announces a lost RF LINK itself, so that half is deliberately not ours; what is ours
--- is the case the radio cannot see, where the link is there and the flight controller has
--- stopped sending. A pilot with the radio's own announcement enabled therefore never hears the
--- same event twice.
---
--- A caller's connection gate cannot decide it. The gate shuts when the link goes, through
--- getRSSI() reaching zero, and the link sensors read on that pass can still show a live link
--- for a moment longer -- which is how a plain link loss used to be announced here. And while the
--- link stays up the gate stays open on the flight controller's last readings, so it never sees
--- the case this is for.
---
--- A drop while disarmed is a normal power-off and says nothing, so the last armed state the
--- pass saw is the gate. That state and the two flags set here outlive the reset a caller does
--- when its gate shuts later on, because the recovery has to survive it.
function Audio.announceConnectionLost(self, rfLinkUp, opts)
  if type(self) ~= "table" or type(self.audioState) ~= "table" then
    return
  end

  local audioState = self.audioState
  -- Asked on every pass while the frames stay away, so everything below happens once per loss.
  if audioState.connectionLostPending then
    return
  end

  local events = (self.preferences and self.preferences.audio_events) or {}
  if not prefEnabled(events, "telemetry_lost", false) then
    return
  end
  if audioState.flightArmed ~= true then
    return
  end
  if rfLinkUp ~= true then
    emitLog(opts, "connection lost with the RF link, which the radio announces itself", "debug")
    return
  end

  local now = nowSeconds()
  audioState.connectionLostPending = true
  audioState.connectionLostAt = now
  emitLog(opts, "telemetry lost while armed, RF link still up", "info")

  if not resolveEventPath(CONNECTION_LOST_SOUND) then
    if not audioState.connectionSoundMissingLogged then
      audioState.connectionSoundMissingLogged = true
      emitLog(opts, "no " .. CONNECTION_LOST_SOUND .. " in this sound pack; nothing is spoken", "warn")
    end
    return
  end

  -- Booked through the same path as every other alert so that the pilot's haptic setting for
  -- the link category reaches it. It says itself once per loss, so nothing reads the count.
  if tryPlayAlertFile(self, audioState, events, now, CONNECTION_LOST_SOUND, opts, "telemetry_lost", true) then
    alertSpoken(audioState, events, "telemetry_lost", now)
  end
end

--- Play one file out of the audio pack, by its path below `SOUNDS/rf/<locale>/`.
--
-- Exported because the locale fallback lives here and should live in exactly one place. The
-- adjustment teller runs on the telemetry pass, where none of the rest of this module is
-- reachable, and a second copy of `resolveEventPath` is the thing worth avoiding.
--
-- Returns true when a file was found and handed to playFile.
function Audio.playEventFile(relativePath, opts)
  if type(relativePath) ~= "string" or relativePath == "" then return false end
  resolve_undriven_level()
  return playResolvedEventFile(relativePath, opts) == true
end

-- Adjustment names and values are advisory. Leave the alarm window clear even when raising the
-- master volume is disabled; the priority belongs to the alarm, not to its volume setting.
function Audio.adjustmentAllowed()
  return nowSeconds() >= adjustment_quiet_until and not boost_active(nowSeconds())
end

--- Speak a whole number through the radio's own number teller, at the level the files above
--- play at. Exported for the same caller: its words come through playEventFile, and a
--- playNumber of its own would speak the value after them at the radio's Wav volume instead.
---
--- Returns true when the call was handed to playNumber without an error.
function Audio.playNumber(value, unit)
  if type(playNumber) ~= "function" then return false end
  resolve_undriven_level()
  return (pcall(playNumber, value, unit or 0, 0, audio_volume)) == true
end

--- Play a sound file by its full path (`/SOUNDS/rf/beep.wav`), at the level the announcements play
--- at. For a page that sounds a tone of its own: the tones at the root of the pack sit in no
--- locale folder, so playEventFile cannot resolve them.
---
--- Returns true when the file was handed to playFile without an error.
function Audio.playRawFile(path)
  if type(path) ~= "string" or path == "" then return false end
  resolve_undriven_level()
  return playRawFile(path) == true
end

--- The value a master-volume percentage is written to the global variable as: 0..100 % onto
--- -1024..1024, the span the Volume special function reads. Exported for the Volume page's
--- Normal and Alarm tests, which write what the announcements' own path would.
Audio.volumeRaw = pct_to_vol_raw

--- Forget which master-volume value this Lua state wrote last, so that its next refresh writes the
--- value it wants even when that is the value it wrote before. For the Volume page's tests: a test
--- that puts the earlier value back over the same value the suite wrote meanwhile (a link coming
--- up, a critical alert) would otherwise leave the suite believing its own value still stands.
function Audio.forgetMasterVolume()
  master_gvar_last = nil
end

-- What the Volume page's tests play: a word and a number, the shape most announcements have, so
-- the level is heard on both halves of it (the level reaches playFile and playNumber alike).
local SAMPLE_FILE = "evt/battery.wav"
local SAMPLE_VALUE = 80

--- Play the sample at `level` (1..5), or at the radio's own Wav volume with `level` nil -- NOT
--- at the level the settings file holds: the page's test plays what it shows, before a save.
--- Nothing of this module's own level is touched. Returns true when the file was found and
--- handed to playFile.
function Audio.playSample(level)
  local lv = tonumber(level)
  if lv ~= nil and (lv < 1 or lv > 5) then lv = nil end
  local path = resolveEventPath(SAMPLE_FILE)
  local play, number = _G.playFile, _G.playNumber
  if not path or type(play) ~= "function" then return false end
  if not pcall(play, path, lv) then return false end
  if type(number) == "function" then pcall(number, SAMPLE_VALUE, unitPercent(), 0, lv) end
  return true
end

function Audio.resetConnectionState(audioState)
  if type(audioState) ~= "table" then
    return
  end

  local now = nowSeconds()
  if audioState.connectionLostPending then
    local lostAt = tonumber(audioState.connectionLostAt) or 0
    if lostAt <= 0 or (now - lostAt) > CONNECTION_RECOVERY_WINDOW then
      audioState.connectionLostPending = nil
      audioState.connectionLostAt = nil
    end
  end
  -- The master volume as it stands: raised while a critical announcement's time runs (it is this
  -- module's, not the connection's, so it outlives the reset), the pilot's own level otherwise.
  refresh_volume_state(nil, boost_active(now), now)

  audioState.initialized = false
  audioState.modelAnnounced = false
  audioState.governorPending = nil
  audioState.governorPendingSince = nil
  audioState.batteryCapacityAnnounced = false
  audioState.initialFuelAnnounced = false
  audioState.nextAllowedAt = 0
  audioState.nextProcessAt = 0
  audioState.fuelSeenPositive = false
  audioState.lastFuelCallout = nil
  audioState.smartfuelModelType = nil
  audioState.smartfuelCellCount = nil
  audioState.smartfuelHasCapacity = nil
  audioState.smartfuelIsElectric = nil
  audioState.smartfuelEmptySound = nil
  audioState.lqLevel = nil
  audioState.escTempLevel = nil
  audioState.mcuTempLevel = nil
  audioState.lqNotQualityLogged = nil
  audioState.linkHeadroom = nil
  audioState.escLoadLevel = nil
  audioState.escLoadWarnSince = nil
  audioState.escLoadCriticalSince = nil
  audioState.dropoutSamples = nil
  audioState.dropoutsActive = nil
  audioState.dropoutsBelowSince = nil
  audioState.dropoutsSoundMissingLogged = nil
  -- The TX power alert's episode and what the module said about its power. The pilot may have
  -- changed the module's power settings since, so the next connection asks again. The answer is
  -- kept aside for a link that comes back while the model is still armed, which may not ask
  -- (txPowerModuleRead).
  audioState.txPower = nil
  cancelTxPowerRead(audioState, "connection_reset")
  local read = audioState.txPowerRead
  if read and read.done then audioState.txPowerLast = read end
  audioState.txPowerRead = nil
  audioState.packCheckDone = false
  audioState.packJudged = false
  audioState.packNotFull = nil
  audioState.packVoltage = nil
  audioState.packCells = nil
  audioState.packFullCell = nil
  audioState.packMargin = nil
  audioState.fuelDeferUntil = nil
  audioState.packVoltageSeen = false
  audioState.mainPowerLostActive = false
  audioState.voltageLowSince = nil
  audioState.voltageCriticalSince = nil
  audioState.voltageLevel = nil
  audioState.connectionSoundMissingLogged = nil
  audioState.telemetryWatchFrom = nil
  audioState.telemetryQuiet = nil
  audioState.telemetryFrameSeen = nil

  -- `connectionLostPending`, `connectionLostAt` and `flightArmed` are deliberately NOT cleared
  -- here. Every caller runs this function at the moment the connection goes down, and a flight
  -- controller that fell silent before the link went is still owed its recovery when the link
  -- comes back; clearing them would throw that away.

  if type(audioState.lastValues) == "table" then
    for k in pairs(audioState.lastValues) do
      audioState.lastValues[k] = nil
    end
  else
    audioState.lastValues = {}
  end

  if type(audioState.pendingValues) == "table" then
    for k in pairs(audioState.pendingValues) do
      audioState.pendingValues[k] = nil
    end
  else
    audioState.pendingValues = {}
  end

  if type(audioState.lastAlertAt) == "table" then
    audioState.lastAlertAt.voltage = 0
    audioState.lastAlertAt.esc_temperature = 0
    audioState.lastAlertAt.bec_voltage = 0
    audioState.lastAlertAt.rx_voltage = 0
    audioState.lastAlertAt.flight_time = 0
    audioState.lastAlertAt.lq = 0
    audioState.lastAlertAt.mcu_temperature = 0
    audioState.lastAlertAt.rssi = 0
    audioState.lastAlertAt.trss = 0
    audioState.lastAlertAt.rsnr = 0
    audioState.lastAlertAt.tsnr = 0
    audioState.lastAlertAt.esc_load = 0
    audioState.lastAlertAt.tpwr = 0
    -- Was missing from this list while it was read by one alert only, which is why a
    -- reconnect after a main-power announcement used to carry that alert's timestamp into
    -- the new connection. The interval is now measured for every alert here.
    audioState.lastAlertAt.main_power = 0
    audioState.lastAlertAt.fuel_empty = 0
  end

  -- A new connection is a new episode of everything, so every repeat count starts over.
  if type(audioState.alertRepeats) == "table" then
    for k in pairs(audioState.alertRepeats) do
      audioState.alertRepeats[k] = nil
    end
  end
end

--- Drive the master volume, and nothing else.
--
-- The master volume is a radio-side effect rather than audio state: it has to keep following
-- the pilot's setting and the alert level whether or not the connection is up. Both callers of
-- this module reach it through the two functions above -- `Audio.process` while the
-- connection is ready, `resetConnectionState` on the edge where it goes -- and a third door
-- is what a caller that is waiting for a connection needs. The tool's audio block is that
-- caller: gating its whole pass on the edge left the variable written once per loss and then
-- not again, so a pilot who set a global variable as the master volume sat at the alert level
-- until the next connect. The dashboard widget calls it too, every 0.5 s while it is not ready,
-- so a level the tool wrote while the widget was paused does not stand until the next connect.
--
-- Whether the level is raised is not asked for: it is the time a critical announcement raised it
-- for, the same test `resetConnectionState` and `Audio.process` make, so a caller that waits ends
-- a raised level when its time is up, as they do.
function Audio.refreshConnectionVolume(self)
  if type(self) ~= "table" or type(self.audioState) ~= "table" then
    return
  end
  local now = nowSeconds()
  refresh_volume_state(self, boost_active(now), now)
end

function Audio.process(self, opts)
  if type(self) ~= "table" or type(self.audioState) ~= "table" then
    return
  end

  local audioState = self.audioState
  local now = nowSeconds()
  local zoneH = tonumber(self.state and self.state.zoneH) or tonumber(LCD_H) or 0
  local processInterval = audioState.initialized and ((zoneH > 0 and zoneH <= 176) and 0.40 or 0.25)
    or ((zoneH > 0 and zoneH <= 176) and 0.60 or 0.35)
  local nextProcessAt = tonumber(audioState.nextProcessAt) or 0
  if now < nextProcessAt then
    return
  end
  audioState.nextProcessAt = now + processInterval

  if type(audioState.lastAlertAt) ~= "table" then
    audioState.lastAlertAt = { voltage = 0, esc_temperature = 0, bec_voltage = 0, rx_voltage = 0, flight_time = 0 }
  end
  audioState.lastAlertAt.bec_voltage = tonumber(audioState.lastAlertAt.bec_voltage) or 0
  audioState.lastAlertAt.rx_voltage = tonumber(audioState.lastAlertAt.rx_voltage) or 0
  audioState.lastAlertAt.flight_time = tonumber(audioState.lastAlertAt.flight_time) or 0
  audioState.lastAlertAt.lq = tonumber(audioState.lastAlertAt.lq) or 0
  audioState.lastAlertAt.mcu_temperature = tonumber(audioState.lastAlertAt.mcu_temperature) or 0
  audioState.lastAlertAt.main_power = tonumber(audioState.lastAlertAt.main_power) or 0
  audioState.lastAlertAt.fuel_empty = tonumber(audioState.lastAlertAt.fuel_empty) or 0
  if type(audioState.lastValues) ~= "table" then
    audioState.lastValues = {
      arming_flags = nil,
      governor_state = nil,
      pid_profile = nil,
      rate_profile = nil,
      battery_profile = nil
    }
  end
  if type(audioState.pendingValues) ~= "table" then
    audioState.pendingValues = {
      pid_profile = nil,
      rate_profile = nil,
      battery_profile = nil
    }
  end
  if type(audioState.lastEnabled) ~= "table" then
    audioState.lastEnabled = { governor_state = nil }
  end
  if audioState.fuelSeenPositive ~= true then
    audioState.fuelSeenPositive = false
  end

  -- The flight controller's own telemetry, as the drain last saw it arrive
  -- (tasks/events/telemetry_bg/tasks.lua). Both callers run this function only while their
  -- connection gate is open, i.e. while the RF link is up, so frames that stay away here are a
  -- flight controller that has stopped sending. The silence is counted from the later of the
  -- last frame and the first pass of this connection, so a gate that has just opened is not
  -- taken for a silence that began before it. A Lua state with no drain never stamps the time,
  -- and then nothing is watched at all.
  --
  -- A silence counts only once a frame has been stamped during this connection. The stamp is
  -- never cleared, so on a later connection that stamps none -- a flight controller sending no
  -- custom telemetry frames, or a pass that runs before this Lua state's drain is woken -- the
  -- previous connection's stamp would otherwise read as a silence: Telemetry Lost would be
  -- announced for a flight controller that never sent anything here, and every alert held below
  -- would stay quiet for the whole connection.
  local rfSession = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
  local frameAt = rfSession and tonumber(rfSession.telemetryFrameAt) or nil
  if audioState.telemetryWatchFrom == nil then
    audioState.telemetryWatchFrom = now
  end
  if frameAt ~= nil and frameAt >= audioState.telemetryWatchFrom then
    audioState.telemetryFrameSeen = true
  end
  local fcQuiet = frameAt ~= nil and audioState.telemetryFrameSeen == true
    and (now - math.max(frameAt, audioState.telemetryWatchFrom)) >= TELEMETRY_QUIET_SECONDS
  if fcQuiet ~= (audioState.telemetryQuiet == true) then
    audioState.telemetryQuiet = fcQuiet
    if fcQuiet then
      Audio.announceConnectionLost(self, rf_link_up(), opts)
    end
  end
  -- While the frames stay away, every reading the flight controller sends -- pack voltage, BEC,
  -- ESC and MCU temperature, ESC load, and the fuel estimate built from them -- holds its last
  -- value: the radio keeps a sensor that has stopped updating for as long as the link streams. An
  -- alert judging such a reading would announce it again every interval, and a critical one
  -- would raise the master volume each time. So those alerts are not judged at all until a frame
  -- arrives: nothing is spoken and nothing they have counted is reset. The link alerts read the
  -- radio's own link statistics, which stay live, and are judged as before.

  -- A frame that arrived after the loss was announced is the recovery, and nothing else is: a
  -- gate that re-opens after the link went as well can do so on the flight controller's last
  -- readings while it is still silent. The window bounds it, so a model brought back to the
  -- bench long after it went quiet does not open with an announcement about a flight that is
  -- over.
  if audioState.connectionLostPending and frameAt ~= nil
      and frameAt > (tonumber(audioState.connectionLostAt) or 0) then
    local since = now - (tonumber(audioState.connectionLostAt) or 0)
    audioState.connectionLostPending = nil
    audioState.connectionLostAt = nil
    if since <= CONNECTION_RECOVERY_WINDOW then
      emitLog(opts, "telemetry recovered after " .. string.format("%.1f", since) .. " s", "info")
      if resolveEventPath(CONNECTION_OK_SOUND) then
        tryPlayEventFile(audioState, now, CONNECTION_OK_SOUND, opts)
      end
    else
      emitLog(opts, "telemetry back after " .. string.format("%.1f", since) .. " s, too late to call it a recovery", "debug")
    end
  end

  local events = (self.preferences and self.preferences.audio_events) or {}
  -- Raised only while the time a critical announcement raised it for runs (tryPlayAlertFile); a
  -- condition that holds without being spoken -- a sag still inside its hold, an alert whose
  -- repeats are spent -- raises nothing.
  refresh_volume_state(self, boost_active(now), now)

  local governorEnabled = prefEnabled(events, "governor_state", true)
  if audioState.lastEnabled.governor_state ~= governorEnabled then
    audioState.lastEnabled.governor_state = governorEnabled
    emitLog(opts, "governor_state enabled=" .. tostring(governorEnabled), "info")
  end

  if not audioState.modelAnnounced and prefEnabled(events, "model_announcement", false) then
    announceModelName(audioState, self.modelName, opts)
  end

  if prefEnabled(events, "arming_flags", true) then
    announceArmEvent(self, opts)
  end

  if governorEnabled then
    announceGovernorEvent(self, events, opts)
  end

  announceRescueEvent(self, events, opts)

  announceProfileEvent(self, "pid_profile", self.state.profile, "evt/profile.wav", opts)
  announceProfileEvent(self, "rate_profile", self.state.rateProfile, "evt/rates.wav", opts)
  announceBatteryCapacityEvent(self, opts)
  -- Deliberately not gated on `initialized`: the first pass after a connect carries the pack's
  -- resting voltage, which is the reading this check is about.
  announcePackNotFullEvent(self, events, opts)
  announceMainPowerEvent(self, events, opts, fcQuiet)

  if prefEnabled(events, "voltage_alert", true) then
    -- Resolve cell count: prefer MSP batteryConfig, fall back to telemetry state,
    -- then refuse to fire (no valid cell count known yet).
    local warnBase, minBase, cells
    do
      local bc = sessionBatteryConfig()
      local warnV = normalizeCellVoltage(bc and bc.vbatwarningcellvoltage, nil)
      local minV = normalizeCellVoltage(bc and bc.vbatmincellvoltage, nil)
      -- MSP batteryCellCount == 0 means auto-detect; use telemetry Cel# in that case
      cells = flightPackCells(self.state, bc)
      if warnV and warnV > 0 and cells then
        warnBase = warnV * cells
      elseif bc and cells then
        -- batteryConfig is available, use safe per-cell default (3.5V * cells)
        warnBase = 3.5 * cells
      end
      -- warnBase stays nil if batteryConfig not loaded yet → skip the alert until config available
      -- The alert's critical level: the flight controller's own minimum cell voltage, the line its
      -- Battery page calls the alarm level, with that page's default where the board sends none.
      if minV and minV > 0 and cells then
        minBase = minV * cells
      elseif bc and cells then
        minBase = 3.3 * cells
      end
    end
    if warnBase then
      local warn = warnBase
      -- A minimum above the warning line cannot be crossed second, so the lower of the two is the
      -- critical one. Nothing is refused over it; the pair is just ordered.
      local minimum = minBase or warn
      if minimum > warn then minimum = warn end
      -- The line is per cell, and so is the margin the pack has to recover by before the alert
      -- counts as cleared. A fixed margin of 0.5 V for the whole pack is 0.17 V per cell on 3S
      -- but 0.04 V on 12S, where a pack released from load can come back that far and so end the
      -- episode -- and with it the Repeat count -- at every sag.
      local reset = warn + voltageResetPerCell(events) * cells
      local voltage = tonumber(self.state.voltage)
      if type(voltage) == "number" and voltage > 0 and not fcQuiet then
        if voltage <= warn then
          -- The reading has to STAY under the line for the hold before anything is said. A pack
          -- sags under a hard collective pull and is back within a beat or two, and the alert
          -- fired on the first sample of that sag; what is worth telling the pilot is a pack
          -- that is actually down. The line itself is untouched -- it is the flight
          -- controller's own vbatwarningcellvoltage, which is where that number belongs.
          local hold = tonumber(events.voltage_hold) or 2
          if hold < 0 then hold = 0 end
          if type(audioState.voltageLowSince) ~= "number" then
            audioState.voltageLowSince = now
          end
          -- The critical level is the same announcement, entered once the reading has stayed at
          -- or under the minimum line for the same hold. It is entered the way the temperature and
          -- link quality levels are: spoken at once, with a repeat count of its own, and it raises
          -- the master volume, which the warning level does not.
          if voltage <= minimum then
            if type(audioState.voltageCriticalSince) ~= "number" then
              audioState.voltageCriticalSince = now
            end
          else
            audioState.voltageCriticalSince = nil
          end
          if (now - audioState.voltageLowSince) >= hold then
            -- Once spoken, the critical level stays until the alert ends (the reading back over
            -- the reset line): a pack that has been held under its minimum is not well again
            -- between two pulls, and a level that could be left and re-entered under a pumping
            -- collective would be announced anew at every pull.
            local spoken = tonumber(audioState.voltageLevel) or 0
            local level = 1
            if spoken >= 2 or (audioState.voltageCriticalSince ~= nil
                and (now - audioState.voltageCriticalSince) >= hold) then
              level = 2
            end
            local entered = false
            if level >= 2 and spoken < 2 then
              audioState.lastAlertAt.voltage = 0
              alertCleared(audioState, "voltage")
              entered = true
            end
            -- A throttle that survives a reload of the module, beside the per-alert interval. It
            -- lives in this Lua state's globals, and EdgeTX runs widgets in a state of their own
            -- (radio/src/lua/widgets.cpp, lua_newstate), so it does not keep the dashboard and the
            -- tool from both speaking. The step into the critical level is not held back by it:
            -- that announcement is new, not a repeat.
            local globalLast = getGlobalLowVoltageAt()
            if (entered or now - globalLast >= ALERT_REPEAT_SECONDS) and alertMaySpeak(audioState, events, "voltage", now) then
              local played, why = tryPlayAlertFile(self, audioState, events, now, "evt/lowvbat.wav", opts, "voltage",
                level >= 2)
              if announcementDone(played, why) then
                -- The value the line was crossed at. The alert said only THAT it had been
                -- crossed, and a pilot deciding whether to land now wants to know by how far.
                if played then playPackVoltage(events, voltage, cells, opts) end
                alertSpoken(audioState, events, "voltage", now, played)
                setGlobalLowVoltageAt(now)
                audioState.voltageLevel = level
              end
            end
          end
        else
          audioState.voltageLowSince = nil
          audioState.voltageCriticalSince = nil
          if voltage >= reset then
            audioState.lastAlertAt.voltage = 0
            alertCleared(audioState, "voltage")
            audioState.voltageLevel = nil
          end
        end
      end
    end
  end

  if prefEnabled(events, "esc_temperature", false) then
    local escTemp = tonumber(self.state.escTemp)
    if type(escTemp) == "number" and not fcQuiet then
      local warn, critical = escTemperatureLevels(events)
      announceTemperatureLevel(self, audioState, events, opts, now, ESC_TEMPERATURE_ALERT, escTemp, warn, critical)
    end
  end

  if prefEnabled(events, "mcu_temperature", false) then
    local mcuTemp = tonumber(self.state.mcuTemp)
    if type(mcuTemp) == "number" and not fcQuiet then
      local warn, critical = mcuTemperatureLevels(events)
      announceTemperatureLevel(self, audioState, events, opts, now, MCU_TEMPERATURE_ALERT, mcuTemp, warn, critical)
    end
  end

  -- ESC load: the current as a percentage of the limit the speed controller is set to allow.
  -- Both callers hand it over as `escLoad`, computed from the same current reading and the same
  -- limit (the per-model store's esc_current_limit), and leave it nil where either is missing --
  -- so a model with no limit on file never speaks here, and a pass that carried no current
  -- reading judges nothing rather than counting as a load of nought.
  --
  -- The shape of the link quality alert below, with the hold of the voltage alert above. A level
  -- is entered once the load has stayed at or above its line for the hold, so a punch-out that is
  -- over within a few seconds stays quiet; a level that has been entered is spoken at once rather
  -- than at the next interval. Leaving a level costs ESC_LOAD_HYSTERESIS points below its line,
  -- recovering is not spoken, and only the critical level buzzes. Radio-wide: the load is already
  -- a share of the model's own limit, so one pair of percentages means the same in every model.
  -- Armed only, because a load on the bench is not one worth being told about.
  if prefEnabled(events, "esc_load", false) then
    if not isArmedFromState(self.state) then
      if audioState.escLoadLevel ~= nil or audioState.escLoadWarnSince ~= nil
          or audioState.escLoadCriticalSince ~= nil then
        audioState.escLoadLevel = nil
        audioState.escLoadWarnSince = nil
        audioState.escLoadCriticalSince = nil
        alertCleared(audioState, "esc_load")
      end
    else
      local load = tonumber(self.state.escLoad)
      if type(load) == "number" and not fcQuiet then
        local warn = tonumber(events.esc_load_warn) or 80
        local critical = tonumber(events.esc_load_critical) or 100
        -- A critical level below the warning level cannot be reached second, so the higher of
        -- the two is the critical one. Nothing is refused over it; the pair is just ordered.
        if critical < warn then critical = warn end
        local hold = tonumber(events.esc_load_hold) or 5
        if hold < 0 then hold = 0 end

        -- When the load last went over each line and has stayed there since.
        if load >= warn then
          if audioState.escLoadWarnSince == nil then audioState.escLoadWarnSince = now end
        else
          audioState.escLoadWarnSince = nil
        end
        if load >= critical then
          if audioState.escLoadCriticalSince == nil then audioState.escLoadCriticalSince = now end
        else
          audioState.escLoadCriticalSince = nil
        end

        local level = 0
        local criticalSince = audioState.escLoadCriticalSince
        local warnSince = audioState.escLoadWarnSince
        if criticalSince ~= nil and (now - criticalSince) >= hold then
          level = 2
        elseif warnSince ~= nil and (now - warnSince) >= hold then
          level = 1
        end

        local spoken = tonumber(audioState.escLoadLevel) or 0
        if level < spoken then
          if spoken >= 2 and load >= critical - ESC_LOAD_HYSTERESIS then
            level = 2
          elseif level < 1 and spoken >= 1 and load >= warn - ESC_LOAD_HYSTERESIS then
            level = 1
          end
        end

        if level < spoken then
          audioState.escLoadLevel = level
          alertCleared(audioState, "esc_load")
        elseif level > 0 then
          if level > spoken then
            audioState.lastAlertAt.esc_load = 0
            alertCleared(audioState, "esc_load")
          end
          if alertMaySpeak(audioState, events, "esc_load", now) then
            local played, why = tryPlayAlertFile(self, audioState, events, now, ESC_LOAD_SOUND, opts, "esc_load",
              level >= 2)
            if announcementDone(played, why) then
              if played and type(playNumber) == "function" then
                local ok, err = pcall(playNumber, math.floor(load + 0.5), unitPercent(), 0, audio_volume)
                if not ok then emitLog(opts, "playNumber error: " .. tostring(err), "error") end
              end
              alertSpoken(audioState, events, "esc_load", now, played and level >= 2)
              audioState.escLoadLevel = level
            end
          end
        end
      end
    end
  end

  if prefEnabled(events, "lq_alert", false) then
    local lq = tonumber(self.state.lq)
    if type(lq) == "number" and linkIsQuality(self, audioState, lq, opts) then
      local warn = tonumber(events.lq_warn) or 70
      local critical = tonumber(events.lq_critical) or 50
      -- A critical level above the warning level cannot be crossed second, so the lower of
      -- the two is the critical one. Nothing is refused over it; the pair is just ordered.
      if critical > warn then critical = warn end

      local spoken = tonumber(audioState.lqLevel) or 0
      local level = 0
      if lq <= critical then
        level = 2
      elseif lq <= warn then
        level = 1
      end

      -- Leaving a level costs LQ_HYSTERESIS points more than entering it.
      if level < spoken then
        if spoken >= 2 and lq <= critical + LQ_HYSTERESIS then
          level = 2
        elseif level < 1 and spoken >= 1 and lq <= warn + LQ_HYSTERESIS then
          level = 1
        end
      end

      if level < spoken then
        -- Recovering is not announced; the next fall is, and it starts with a full repeat
        -- count because the level it fell from has been left.
        audioState.lqLevel = level
        alertCleared(audioState, "lq")
      elseif level > 0 then
        if level > spoken then
          -- A quality that has got worse is announced at once rather than at the next
          -- interval, and the level it has entered gets its own repeats.
          audioState.lastAlertAt.lq = 0
          alertCleared(audioState, "lq")
        end
        if alertMaySpeak(audioState, events, "lq", now) then
          local played, why = tryPlayAlertFile(self, audioState, events, now, "stat/alerts/lq.wav", opts, "lq", level >= 2)
          if announcementDone(played, why) then
            if played and type(playNumber) == "function" then
              local ok, err = pcall(playNumber, math.floor(lq + 0.5), unitPercent(), 0, audio_volume)
              if not ok then emitLog(opts, "playNumber error: " .. tostring(err), "error") end
            end
            -- The warning level does not buzz even when the category is set to, which is the
            -- distinction this alert has always drawn between its two levels.
            alertSpoken(audioState, events, "lq", now, played and level >= 2)
            audioState.lqLevel = level
          end
        end
      end
    end
  end

  -- The link headroom and SNR alerts. `linkHeadroomWanted` and `linkSnrWanted` tell both
  -- callers whether to read the sensors only these alerts use (`RFMD` for either, `ANT` and `TRSS`
  -- for the headroom, `RSNR` and `TSNR` for the SNR; ui/home.lua and
  -- widgets/dashboard/runtime.lua), so a radio with all of them off pays no search for them.
  local headroomOn, rssiOn, snrOn = false, false, false
  for i = 1, #LINK_HEADROOM_ALERTS do
    local alert = LINK_HEADROOM_ALERTS[i]
    local on = prefEnabled(events, alert.enableKey, false)
    linkHeadroomEnabled[i] = on
    if on then
      headroomOn = true
      if alert.snr then snrOn = true else rssiOn = true end
    end
  end
  audioState.linkHeadroomWanted = rssiOn
  audioState.linkSnrWanted = snrOn
  if headroomOn then
    announceLinkHeadroom(self, audioState, events, linkHeadroomEnabled, now, opts)
  elseif audioState.linkHeadroom ~= nil then
    audioState.linkHeadroom = nil
    for i = 1, #LINK_HEADROOM_ALERTS do alertCleared(audioState, LINK_HEADROOM_ALERTS[i].alertKey) end
  end
  announceDropoutsEvent(self, events, opts)
  -- The TX power alert. `txPowerWanted` tells both callers whether to read `TPWR`, which only this
  -- alert uses (ui/home.lua, widgets/dashboard/runtime.lua), so a radio with it off pays no search
  -- for it, and nothing is sent to the module.
  local txPowerOn = prefEnabled(events, "tpwr_alert", false)
  audioState.txPowerWanted = txPowerOn
  if txPowerOn then
    txPowerAlert(self, audioState, events, now, opts)
  elseif audioState.txPower ~= nil or audioState.txPowerRead ~= nil or audioState.txPowerLast ~= nil
      or audioState.txPowerRequested ~= nil then
    cancelTxPowerRead(audioState, "disabled")
    audioState.txPower = nil
    audioState.txPowerRead = nil
    audioState.txPowerLast = nil
    alertCleared(audioState, "tpwr")
  end


  do
    local batteryPrefs = readBatteryPrefs()
    local armed = isArmedFromState(self.state)
    if audioState.flightArmed ~= armed then
      audioState.flightArmed = armed
      -- A safeguard: re-evaluate the silence from the next pass, so that a quiet edge spent
      -- while disarmed cannot leave an armed model unannounced. Today the arm state arrives
      -- only with the flight controller's frames, and the first of them has already reset the
      -- edge above, so this changes no sequence that can happen now; it matters only if the
      -- arm state ever reaches this function by another route.
      audioState.telemetryQuiet = false
      if armed then
        audioState.flightTimerTriggered = false
        audioState.flightTimerStartAt = nil
      else
        audioState.flightTimerTriggered = false
        audioState.flightTimerStartAt = nil
        audioState.lastAlertAt.flight_time = 0
        resetBecAverage(audioState)
      end
    end

    if armed then
      local bec = tonumber(self.state and (self.state.bec_voltage or self.state.becVoltage))
      local alertType = tonumber(batteryPrefs and batteryPrefs.alert_type) or 0
      -- While the flight controller is silent the reading is its last one: neither judged nor
      -- averaged, and nothing the two alerts have counted is reset (fcQuiet above).
      if not fcQuiet and type(bec) == "number" and bec > 0 and (alertType == 1 or alertType == 2) then
        local avgBEC = pushBecAverage(audioState, bec)

        -- Switched on under Setup > Power > Alerts rather than here, but they are voltage
        -- announcements and take the voltage category's repeat and haptic like the rest of it.
        if alertType == 1 then
          local threshold = normalizeAlertVoltage(batteryPrefs and batteryPrefs.becalertvalue, 6.5)
          if avgBEC < threshold then
            if alertMaySpeak(audioState, events, "bec_voltage", now) then
              local played, why = tryPlayAlertFile(self, audioState, events, now, "evt/becvolt.wav", opts,
                "bec_voltage", true)
              if announcementDone(played, why) then
                alertSpoken(audioState, events, "bec_voltage", now, played)
              end
            end
          else
            audioState.lastAlertAt.bec_voltage = 0
            alertCleared(audioState, "bec_voltage")
          end
          audioState.lastAlertAt.rx_voltage = 0
          alertCleared(audioState, "rx_voltage")
        elseif alertType == 2 then
          local threshold = normalizeAlertVoltage(batteryPrefs and batteryPrefs.rxalertvalue, 7.4)
          if avgBEC < threshold then
            if alertMaySpeak(audioState, events, "rx_voltage", now) then
              local played, why = tryPlayAlertFile(self, audioState, events, now, "evt/rxvolt.wav", opts,
                "rx_voltage", true)
              if announcementDone(played, why) then
                alertSpoken(audioState, events, "rx_voltage", now, played)
              end
            end
          else
            audioState.lastAlertAt.rx_voltage = 0
            alertCleared(audioState, "rx_voltage")
          end
          audioState.lastAlertAt.bec_voltage = 0
          alertCleared(audioState, "bec_voltage")
        end
      elseif not fcQuiet then
        audioState.lastAlertAt.bec_voltage = 0
        audioState.lastAlertAt.rx_voltage = 0
        alertCleared(audioState, "bec_voltage")
        alertCleared(audioState, "rx_voltage")
      end

      local targetSeconds = tonumber(batteryPrefs and batteryPrefs.flighttime) or 0
      -- The dashboard hands over its flight record (tasks/events/telemetry/flight_record.lua),
      -- and that record is the clock this callout reads. `armed` above can come from a telemetry
      -- read that saw the ARM sensor before the record's own arm edge, and the record's copy in
      -- `flightSeconds` is refreshed on telemetry reads only; in between, that copy still holds
      -- the previous flight's duration. So with a record, nothing is judged (and nothing reset)
      -- until it is open, and its seconds are read live.
      local record = self.state and self.state.flight
      if type(record) ~= "table" then record = nil end
      local recordOpen = record == nil or record.armed == true
      if targetSeconds > 0 and recordOpen then
        local elapsed
        if record then
          elapsed = tonumber(record.seconds)
        else
          elapsed = tonumber(self.state and self.state.flightSeconds)
        end
        if type(elapsed) ~= "number" then
          if type(audioState.flightTimerStartAt) ~= "number" then
            audioState.flightTimerStartAt = now
          end
          elapsed = now - audioState.flightTimerStartAt
        else
          if type(audioState.flightTimerStartAt) ~= "number" then
            audioState.flightTimerStartAt = now - elapsed
          end
        end

        if elapsed >= targetSeconds then
          if audioState.flightTimerTriggered ~= true then
            local sound = "evt/elapsed.wav"
            if announcementDone(tryPlayEventFile(audioState, now, sound, opts)) then
              audioState.flightTimerTriggered = true
              audioState.lastAlertAt.flight_time = now
            end
          end
        else
          audioState.flightTimerTriggered = false
        end
      elseif targetSeconds <= 0 then
        audioState.flightTimerTriggered = false
      end
    else
      audioState.lastAlertAt.bec_voltage = 0
      audioState.lastAlertAt.rx_voltage = 0
      alertCleared(audioState, "bec_voltage")
      alertCleared(audioState, "rx_voltage")
    end
  end

  if prefEnabled(events, "fuel_alerts", true) then
    if self.state.fuelTelemetrySeen ~= true then
      -- Skip fuel/empty alerts until we have seen at least one real fuel telemetry sample.
      audioState.lastAlertAt.fuel_empty = 0
      alertCleared(audioState, "fuel_empty")
      audioState.lastFuelCallout = nil
      audioState.fuelSeenPositive = false
      goto fuel_alerts_done
    end

    local fuelValue = tonumber(self.state.fuel)
    if type(fuelValue) == "number" and not fcQuiet then
      if fuelValue < 0 then fuelValue = 0 end
      if fuelValue > 100 then fuelValue = 100 end
      if fuelValue > 0 then
        audioState.fuelSeenPositive = true
      end

      local isElectricModel, modelType, cellCount, hasCapacity = resolveSmartfuelModel(self)
      local emptyFuelSound = isElectricModel and "stat/alerts/lowbat.wav" or "stat/alerts/lowfuel.wav"
      if audioState.smartfuelModelType ~= modelType
        or audioState.smartfuelCellCount ~= cellCount
        or audioState.smartfuelHasCapacity ~= hasCapacity
        or audioState.smartfuelIsElectric ~= isElectricModel
        or audioState.smartfuelEmptySound ~= emptyFuelSound then
        audioState.smartfuelModelType = modelType
        audioState.smartfuelCellCount = cellCount
        audioState.smartfuelHasCapacity = hasCapacity
        audioState.smartfuelIsElectric = isElectricModel
        audioState.smartfuelEmptySound = emptyFuelSound
        emitLog(
          opts,
          "smartfuel classify modelType=" .. tostring(modelType)
            .. " cells=" .. tostring(cellCount)
            .. " hasCapacity=" .. tostring(hasCapacity)
            .. " isElectric=" .. tostring(isElectricModel)
            .. " emptySound=" .. tostring(emptyFuelSound),
          "debug"
        )
      end

      if fuelValue <= 0 and audioState.fuelSeenPositive == true then
        if alertMaySpeak(audioState, events, "fuel_empty", now) then
          local played, why = tryPlayAlertFile(self, audioState, events, now, emptyFuelSound, opts, "fuel_empty", true)
          if announcementDone(played, why) then
            alertSpoken(audioState, events, "fuel_empty", now, played)
          end
        end
      else
        audioState.lastAlertAt.fuel_empty = 0
        alertCleared(audioState, "fuel_empty")

        local currentRounded = roundProfileValue(fuelValue)
        if currentRounded and currentRounded >= 0 then
          local lastCallout = audioState.lastFuelCallout
          if lastCallout == nil then
            audioState.lastFuelCallout = currentRounded
          else
            local thresholds = fuelThresholdList(events.fuel_callout_percent, events.fuel_finer_below,
              events.fuel_finer_step)
            local lowestCrossed = nil
            for i = 1, #thresholds do
              local threshold = thresholds[i]
              if currentRounded <= threshold and lastCallout > threshold then
                lowestCrossed = threshold
              end
            end
            if lowestCrossed then
              local calloutSound = isElectricModel and "evt/battery.wav" or "stat/alerts/fuel.wav"
              local played, why = tryPlayEventFile(audioState, now, calloutSound, opts)
              if played and type(playNumber) == "function" then
                emitLog(opts, "fuel callout playNumber -> " .. tostring(lowestCrossed), "info")
                local ok, err = pcall(playNumber, lowestCrossed, unitPercent(), 0, audio_volume)
                if not ok then emitLog(opts, "playNumber error: " .. tostring(err), "error") end
              end
              -- The step is passed only once it was spoken, or once the sound pack turned out to
              -- have no file for it. Refused by the cooldown after another announcement in this
              -- pass, it is still crossed on the next one and spoken then.
              if announcementDone(played, why) then
                audioState.lastFuelCallout = currentRounded
              end
            elseif currentRounded > lastCallout then
              audioState.lastFuelCallout = currentRounded
            end
          end
        end
      end
    end
    ::fuel_alerts_done::
  else
    audioState.lastAlertAt.fuel_empty = 0
    alertCleared(audioState, "fuel_empty")
    audioState.lastFuelCallout = nil
    audioState.fuelSeenPositive = false
  end

  -- Once the callout has fired it stays fired for the session.
  if not audioState.initialFuelAnnounced and audioState.initialized and initialFuelWanted(events) then
    -- Held while the flight controller is silent, not given up: the estimate would be its last
    -- one, and the callout is still made once the frames come back.
    if self.state and self.state.fuelTelemetrySeen == true and not fcQuiet then
      local fuel = tonumber(self.state.fuel)
      -- Same reason as the battery capacity above: this announcement is meant once per
      -- connection, and a caller that rebuilds its audio state for its own reasons has not
      -- reconnected. The flag clears itself, so a real reconnect still speaks.
      if type(fuel) == "number" and audioState.seedInitialFuel then
        audioState.seedInitialFuel = nil
        audioState.initialFuelAnnounced = true
        audioState.fuelDeferUntil = nil
      elseif type(fuel) == "number" then
        local now = nowSeconds()
        if not audioState.fuelDeferUntil then
          local stabilizeDelay = 1.5
          local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
          local bc = session and (session.batteryConfig or session.battery_config) or nil
          if type(bc) == "table" and tonumber(bc.stabilize_delay) then
            local sd = tonumber(bc.stabilize_delay)
            if sd > 100 then sd = sd / 1000 end
            if sd >= 0 and sd <= 10 then stabilizeDelay = sd end
          end
          audioState.fuelDeferUntil = now + math.max(8.0, stabilizeDelay + 3.5)
        end

        local expired = now >= audioState.fuelDeferUntil
        local isReady = false
        if expired then
          isReady = true
        else
          local prevFuel = tonumber(self.state and self.state.previousSessionFuel)
          local isCarriedOver = (prevFuel ~= nil and fuel == prevFuel)
          if fuel > 0 and not isCarriedOver then
            isReady = true
          end
        end

        if isReady and now >= (audioState.nextAllowedAt or 0) then
          local isElectricModel, modelType = resolveSmartfuelModel(self)
          local calloutSound = isElectricModel and "evt/battery.wav" or "stat/alerts/fuel.wav"
          -- A sound pack without the file counts as announced once the choice of file can no
          -- longer change: the model type is set explicitly, the battery configuration has been
          -- read, or the pack carries neither file. Until then a model of undecided type may still
          -- turn out to need the other file, so it is tried again as before. Checked only when the
          -- file is missing. resolveEventPath caches its misses for as long as this module is
          -- loaded, so no later pass has anything to play either; without the latch this block
          -- would run again on every audio pass and log two warnings each time. Nothing clears
          -- resolvedEventPaths, not a reconnect and not a change of language or sound pack, so a
          -- file added to the card later is not found until the script is loaded again. The latch
          -- depends on that cache staying as it is.
          local hasSound = resolveEventPath(calloutSound) ~= nil
          local noSound = false
          if not hasSound then
            local otherSound = isElectricModel and "stat/alerts/fuel.wav" or "evt/battery.wav"
            noSound = modelType ~= 0 or batteryConfigRead() or resolveEventPath(otherSound) == nil
            if noSound then
              emitLog(opts, "no " .. calloutSound .. " in this sound pack; nothing is spoken", "warn")
            end
          end
          if noSound or tryPlayEventFile(audioState, now, calloutSound, opts) then
            if hasSound and type(playNumber) == "function" then
              -- playNumber takes an integer and raises on a number it cannot convert to one.
              -- The fuel percentage is no longer rounded on its way here, so without this the
              -- alert tone would play and the percentage behind it would go unspoken. Same
              -- rounding as the MCU temperature and the link quality above.
              local ok, err = pcall(playNumber, math.floor(fuel + 0.5), unitPercent(), 0, audio_volume)
              if not ok then emitLog(opts, "playNumber error: " .. tostring(err), "error") end
            end
            audioState.initialFuelAnnounced = true
            audioState.fuelDeferUntil = nil
            if self.state then self.state.previousSessionFuel = nil end
          end
        end
      end
    end
  end

  if not audioState.initialized then
    audioState.initialized = true
  end
end

--- Every alert's levels as the announcements above apply them, for a dashboard theme to colour the
--- same reading by: `{ on, warn, critical }` per alert, resolved and ordered the way the alert
--- itself resolves and orders them, so a theme and the voice cannot disagree about where a level
--- lies. `on` is the alert's own switch; a theme decides for itself whether it colours a reading
--- whose alert is off. Units are the alert's own: percent for the link alerts (link quality, the
--- headroom of LinkRates.headroom, the position of LinkRates.snrPercent, the share of the TX power
--- maximum), degrees Celsius for the temperatures, percent of the ESC's limit for its load.
---
--- `events` is `preferences.audio_events`; the ESC's temperature levels take the connected model's
--- own values where it has them, as the alert does. `audioState` is optional and is read for one
--- thing only: the transmitter module's Max Power, once the TX power alert has read it.
---
--- Each alert is one entry, so an alert that is removed takes its entry with it: a theme reading an
--- entry that is not there gets nil, never a placeholder.
function Audio.alertLevels(events, audioState)
  events = events or {}
  local function levels(enableKey, warn, critical, worseUp)
    -- Ordered as the alerts order them: the critical level is the one crossed second.
    if worseUp then
      if critical < warn then critical = warn end
    elseif critical > warn then
      critical = warn
    end
    return { on = prefEnabled(events, enableKey, false), warn = warn, critical = critical }
  end

  local alerts = {}
  alerts.lq = levels("lq_alert", tonumber(events.lq_warn) or 70, tonumber(events.lq_critical) or 50)
  for i = 1, #LINK_HEADROOM_ALERTS do
    local alert = LINK_HEADROOM_ALERTS[i]
    alerts[alert.alertKey] = levels(alert.enableKey, tonumber(events[alert.warnKey]) or alert.warn,
      tonumber(events[alert.criticalKey]) or alert.critical)
  end

  -- The TX power alert's levels are shares of a maximum, so the maximum comes with them: the
  -- pilot's own where Own Maximum is on, the module's Max Power once the alert has read it, and
  -- the pilot's Maximum (mW) setting until then.
  local tpwr = levels("tpwr_alert", tonumber(events.tpwr_warn) or TX_POWER_WARN,
    tonumber(events.tpwr_critical) or TX_POWER_CRITICAL, true)
  local maximum = nil
  if not prefEnabled(events, "tpwr_limit", false) and type(audioState) == "table" then
    local read = audioState.txPowerRead
    if not (type(read) == "table" and read.done) then read = audioState.txPowerLast end
    maximum = type(read) == "table" and tonumber(read.maxMilliwatts) or nil
  end
  if maximum == nil or maximum <= 0 then maximum = tonumber(events.tpwr_max) or TX_POWER_OWN_MAX end
  tpwr.max = maximum
  alerts.tpwr = tpwr

  local escWarn, escCritical = escTemperatureLevels(events)
  alerts.escTemp = levels("esc_temperature", escWarn, escCritical, true)
  local mcuWarn, mcuCritical = mcuTemperatureLevels(events)
  alerts.mcuTemp = levels("mcu_temperature", mcuWarn, mcuCritical, true)
  alerts.escLoad = levels("esc_load", tonumber(events.esc_load_warn) or 80,
    tonumber(events.esc_load_critical) or 100, true)

  alerts.skipped = {
    on = prefEnabled(events, "dropouts_alert", false),
    count = clampedSetting(events, "dropouts_count", 3, 1, 50),
    window = clampedSetting(events, "dropouts_window", 10, 4, 60),
  }
  return alerts
end

return Audio
