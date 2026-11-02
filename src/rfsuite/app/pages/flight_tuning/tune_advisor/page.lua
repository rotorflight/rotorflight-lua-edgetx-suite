-- Flight Tuning -> Tune Advisor.
--
-- Turns the flight controller's in-flight rate-loop statistics (firmware
-- src/main/flight/tune_advisor.c) into concrete changes, one axis at a time: what was measured,
-- which setting to change (named by the page it lives on, in the units that page shows), and
-- why. The firmware only measures; the rules below are the advice, kept here so they can change
-- without a flash. The rules and their wording are the Ethos suite's Tune Advisor page
-- (rotorflight-lua-ethos-suite, app/pages/tune_advisor.lua), except where a rule below says
-- otherwise.
--
-- The statistics come from the saved flights, not from the flight controller: each flight is
-- saved after the disarm (tasks/events/tune_capture.lua) and the page combines the newest flights
-- flown on the current tune (lib/tune_history.lua). The aircraft is the session's mcu_id. The
-- flight controller is asked once, on open and on Reload, only to learn whether its firmware has
-- the tune advisor at all. Only the combined figures are kept while the page is open.
--
-- Rules, per axis:
-- - Feed-forward match (gyro / setpoint at the best delay), judged only when the ratio is
--   consistent. Above FF_HOT the heli outruns the stick: lower F and scale the rate curve up by
--   the same factor, which keeps the stick feel. Below FF_LOW, the reverse. One step is capped at
--   FF_STEP_MAX so the pilot flies and re-checks rather than jumping. The curve can only be scaled
--   exactly for Actual, Quick and Rotorflight rates; for the others the page gives a percentage
--   and applies neither. An axis with F = 0 (often the tail) gets no F advice.
-- - Full stick (roll and pitch): cyclic saturated and the rate reached well below the rate the
--   flight controller commands, so the rates are lowered toward what the heli reaches, at most
--   FF_STEP_MAX per step. The commanded rate takes the cyclic ring into account (see reachable).
-- - Polar cyclic (roll and pitch): the flight controller turns both sticks into one rate on the
--   Pitch curve, so the rate lines, their limits and the full-stick rule use the Pitch rates and
--   name the Rates page's Cyclic row.
-- - |Collective| spread is shown as a fact, last, when there is room.
-- - Shake: the heli oscillates with the stick centred, usually P too high. Less P, and nothing
--   else on that axis: an oscillation also reads as bounce-back after every stop and spoils the F
--   match. The shake is named whether or not P can be lowered.
-- - Stick releases: the rebound after a stop. I-term pushing back points at a lower I-term relax
--   cut-off, on an axis I-term relax covers; with F still off, F comes first; otherwise more P.
-- - P is never raised past P_RAISE_MAX times the pilot's own P: the value before this page's own
--   changes, followed back through the change journal (lib/tune_history.lua, pilotValue).
-- - A change whose new value is outside the range the flight controller accepts is not given at
--   all, nor any change that goes with it (F with its rates): clamping would give a different
--   change from the one the data asks for.
--
-- Cyclic polarity, cyclic ring and I-term relax type are taken from the newest flight, and only
-- when the active profiles are the ones it was flown on; otherwise the page says which profiles
-- to switch to and Save stays off.
--
-- Clear (the header's star button) erases the saved flights and resets the flight controller's
-- statistics. Save writes exactly the changes on screen through tasks/msp/save_pipeline.lua,
-- after reading the settings back and checking that the flight controller still holds the tune
-- and the profiles the flights were flown with, then records each change in the change journal.

local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Palette = _G.rfsuite and _G.rfsuite.palette or (_G.rfsuite and _G.rfsuite.require or loadModule)("ui/palette.lua")

local Common = nil
local Controls = nil
local MspRuntime = nil
local Profile = nil
local ConfirmDialog = nil
local TuneHistory = nil
local RcTuningApi = nil
local PidTuningApi = nil
local PidProfileApi = nil
local StatusApi = nil
local SavePipeline = nil
local Cache = nil
local Armed = nil
local ChangeJournal = nil
local t = nil

local AXIS_ROLL, AXIS_PITCH, AXIS_YAW = 1, 2, 3

-- Feed-forward match
local FF_MIN_COUNT = 1000       -- 10 s of usable 40-200 deg/s stick
local FF_MIN_CORR = 0.85
local FF_HOT = 1.15
local FF_LOW = 0.85
local FF_STEP_MAX = 0.2         -- change F (and rates) by at most 20% per step

-- What the flight controller accepts: P, F and B 0-1000 (PID_GAIN_MAX), the I-term relax
-- cut-off 1-100, and the rate bytes as firmware fc/rc_rates.h and cli/settings.c bound them.
local VALUE_RANGE = {
  P = { 0, 1000 }, F = { 0, 1000 }, B = { 0, 1000 },
  relaxCutoff = { 1, 100 },
  rcRate = { 1, 255 }, sRate = { 0, 255 },
}

-- rates_type values, as the Rates page numbers its tables
local RATE_TYPE_ACTUAL = 4
local RATE_TYPE_QUICK = 5
local RATE_TYPE_ROTORFLIGHT = 6

-- Which rate columns scale the whole curve linearly, per rates_type. The others (Betaflight,
-- Raceflight, KISS) get a percentage instead.
local LINEAR_ROLES = {
  [RATE_TYPE_ACTUAL] = { "rcRate", "srate" },       -- center sensitivity, max rate
  [RATE_TYPE_QUICK] = { "rcRate", "srate" },        -- rc rate, max rate
  [RATE_TYPE_ROTORFLIGHT] = { "rcRate" },           -- rate (srate is the shape)
}

-- How the Rates page shows a raw roll, pitch or yaw byte for these three types: raw * mult /
-- scale, in the decimals its formatValue gives that scale (RATE_TABLES in
-- app/pages/flight_tuning/rates/page.lua).
local RATE_DISPLAY = {
  [RATE_TYPE_ACTUAL] = { rcRate = { mult = 10, scale = 1 }, srate = { mult = 10, scale = 1 } },
  [RATE_TYPE_QUICK] = { rcRate = { mult = 1, scale = 100 }, srate = { mult = 10, scale = 1 } },
  [RATE_TYPE_ROTORFLIGHT] = { rcRate = { mult = 5, scale = 1 } },
}

-- Max rate asked at full stick (deg/s) from the raw bytes, where the type makes it direct: the
-- firmware's rate curves (fc/rc_rates.c) at full stick. Actual and Quick reach the larger of
-- their two terms.
local function maxRateAsked(rates)
  if rates.ratesType == RATE_TYPE_ACTUAL then return math.max(rates.rcRate, rates.sRate) * 10 end
  if rates.ratesType == RATE_TYPE_QUICK then return math.max(rates.sRate * 10, rates.rcRate * 2) end
  if rates.ratesType == RATE_TYPE_ROTORFLIGHT then return rates.rcRate * 5 end
  return nil
end

-- The rate the flight controller commands for one cyclic axis at full stick, the other axis
-- centred, given the rate curve's full-stick rate and cyclic_ring (firmware master,
-- src/main/flight/setpoint.c):
--   setpointInitProfile, lines 237-245: ringLimit = applyRatesCurve(axis, 1.0) * cyclic_ring / 100,
--     and 2000 deg/s when cyclic_ring is 0.
--   setpointUpdate, polar off, lines 326-341: both setpoints are divided by
--     C = sqrt((roll / ringLimit[ROLL])^2 + (pitch / ringLimit[PITCH])^2) when C > 1, so one
--     axis alone is held at min(curve(1), ringLimit).
--   setpointUpdate, polar on, lines 310-316: rate = min(applyRatesCurve(PITCH, dist),
--     ringLimit[PITCH]), the same at full stick on the Pitch curve.
-- So below a ring of 100 % full stick never asks for the curve's maximum. Both sticks in a corner
-- are held lower still (by up to 1/sqrt(2) at a ring of 100 %), and the statistics do not tell
-- those samples apart from single-axis ones: this is the largest rate full stick is ever given,
-- and the one the reached rate is measured against. An unknown ring leaves the curve's maximum.
local function reachable(asked, ring)
  if ring == nil then return asked end
  if ring == 0 then return math.min(asked, 2000) end
  return math.min(asked, asked * ring / 100)
end

-- iterm_relax_type (firmware src/main/pg/pid.h): which axes I-term relax acts on,
-- flight/pid.c applyItermRelax: OFF none, RP roll and pitch, RPY all three.
local RELAX_OFF, RELAX_RP = 0, 1

-- Whether a lower I-term relax cut-off changes anything in flight on this axis. An unknown
-- type is taken as the firmware default, RPY.
local function relaxCovers(relaxType, axis)
  if relaxType == RELAX_OFF then return false end
  if relaxType == RELAX_RP then return axis ~= AXIS_YAW end
  return true
end

-- Collective fact
local BAND_MIN_COUNT = 300
local COLL_SPREAD = 1.25

-- Full stick
local FULL_MIN_COUNT = 100
local FULL_SAT_SHARE = 0.5
local FULL_REACH = 0.8

-- Stick releases
local STOPS_MIN = 10
local REBOUND_BAD = 0.12
local ITERM_PUSH = 0.03         -- I at release, output units
local P_STEP = 1.2
local P_RAISE_MAX = 1.5         -- P at most 50% above the pilot's own: two steps
local CUTOFF_STEP = 0.8         -- lower cut-off = more relax, less bounce-back
local CUTOFF_MIN = 1

-- Shake with the stick centred. A tuned heli holds a few deg/s there; an oscillating loop
-- tens, and its swings also read as bounce-back after every stop.
local SHAKE_MIN_COUNT = 500     -- 5 s of centred stick
local SHAKE_RMS = 15            -- deg/s

local MAX_ACTIONS = 3
local MAX_WHYS = 3
local PAGE_ID = "flight_tuning_tune_advisor"

-- The keys of a flight's tune (lib/tune_history.lua TUNE_KEYS): the flight controller must still
-- hold every one of them before anything is written.
local TUNE_KEYS = { "P", "F", "B", "relaxCutoff", "ratesType", "rcRate", "sRate" }

-- A change is written as the path a pilot follows to it: page > row > column, or with the
-- menu in front for a page under Advanced. The names are the ones those pages show.
local PATH_FMT = "%s > %s > %s:  %s -> %s"
local ADVANCED_PATH_FMT = "%s > %s > %s > %s:  %s -> %s"

local ui = {
  loaded = false,
  generation = 0,
  selected = AXIS_ROLL,
  mcu = nil,                -- the aircraft whose flights are on screen
  loadStep = nil,           -- the history read in progress: "read", "aggregate", "journal"
  readJob = nil,            -- the file read's own steps (lib/tune_history.lua readJob)
  journalJob = nil,         -- the change journal read's own steps (lib/change_journal.lua readJob)
  axesBuilt = nil,          -- the axes combined so far, one per pass
  flights = nil,            -- held only between the read and the aggregate
  axes = nil,               -- per axis {a, used, seconds, pilotP}: all the page keeps
  maxFlights = 5,
  newestHasPitch = false,
  probeOwed = false,
  probing = false,
  unsupported = false,      -- this flight controller refused the command: until another is asked
  captureState = nil,       -- the flight capture's state, when it runs in this Lua state
  seenSaved = nil,
  profileKey = nil,
  applied = {},             -- per axis: changes written since the flights were read
  text = nil,
  i18n = nil,
  view = nil,
  snapshot = nil,
  applying = false,
  applyGeneration = 0,
  status = nil,
  reportSave = nil,
  runtime = nil
}

local function newRuntime()
  return {
    requestRebuild = nil,
    builtThisPass = false,
    deferredLastPass = false,
    historyRead = false     -- this visit's read of the saved flights has finished
  }
end
ui.runtime = newRuntime()

local function nowSeconds()
  if getTime then
    local ok, value = pcall(getTime)
    if ok and type(value) == "number" then
      return value / 100
    end
  end
  return 0
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not Profile then Profile = loadModule("lib/profile.lua") end
  if not t then t = Common and Common.pageT("flight_tuning_tune_advisor") or nil end
end

local function currentProfiles()
  if not Profile then return 1, 1 end
  return Profile.getActivePidProfile(1), Profile.getActiveRateProfile(1)
end

local function pageText(i18n, key, fallback)
  if t then
    local translated = t(i18n, key, fallback)
    if translated ~= nil and translated ~= "" and translated ~= key then
      return translated
    end
  end
  return fallback
end

local function requestRebuild()
  if ui.runtime and type(ui.runtime.requestRebuild) == "function" then
    ui.runtime.requestRebuild()
  end
end

-- Every string the page shows, resolved once per opening. The names of the settings the advice
-- points at are borrowed from the pages that show them, so the advice reads exactly like the
-- row and column it sends the pilot to, in every language those pages are translated into.
local function loadTexts(i18n)
  local pidsAxis = {
    "@i18n(app.pages.flight_tuning_pids.roll)@",
    "@i18n(app.pages.flight_tuning_pids.pitch)@",
    "@i18n(app.pages.flight_tuning_pids.yaw)@"
  }
  local ratesAxis = {
    "@i18n(app.pages.flight_tuning_rates.roll)@",
    "@i18n(app.pages.flight_tuning_rates.pitch)@",
    "@i18n(app.pages.flight_tuning_rates.yaw)@"
  }
  local controllerAxis = {
    "@i18n(app.pages.flight_tuning_advanced_pid_controller.roll)@",
    "@i18n(app.pages.flight_tuning_advanced_pid_controller.pitch)@",
    "@i18n(app.pages.flight_tuning_advanced_pid_controller.yaw)@"
  }
  local centerSens = "@i18n(app.pages.flight_tuning_rates.center_sensitivity)@"
  local maxRate = "@i18n(app.pages.flight_tuning_rates.max_rate)@"
  local rcRate = "@i18n(app.pages.flight_tuning_rates.rc_rate)@"
  local rate = "@i18n(app.pages.flight_tuning_rates.rate)@"

  return {
    pageTitle = "@i18n(app.modules.tune_advisor.name)@",
    axis = pageText(i18n, "axis", "Axis"),
    axisNames = {
      pageText(i18n, "roll", "Roll"),
      pageText(i18n, "pitch", "Pitch"),
      pageText(i18n, "yaw", "Yaw")
    },
    data = pageText(i18n, "data", "Flight data"),
    dataFlightsFmt = pageText(i18n, "data_flights_fmt", "%dm %02ds, %d/%d flights"),
    profile = pageText(i18n, "profile", "Profiles"),
    profileFmt = pageText(i18n, "profile_fmt", "PID %d, rates %d"),
    noAircraft = pageText(i18n, "no_aircraft", "Connect to a model first"),
    unsupported = pageText(i18n, "unsupported", "Needs newer firmware"),
    readingFlight = pageText(i18n, "reading_flight", "Reading the last flight..."),
    notRead = pageText(i18n, "not_read", "Last flight not read. It is read at the next disarm."),
    clearPrompt = pageText(i18n, "clear_prompt", "Erase the saved flights?"),
    response = pageText(i18n, "response", "Response"),
    stops = pageText(i18n, "stops", "Stops"),
    changes = pageText(i18n, "changes", "Suggested changes"),
    why = pageText(i18n, "why", "Why"),

    respMoreFmt = pageText(i18n, "resp_more_fmt", "Needs more flying (%d%%)"),
    respUneven = pageText(i18n, "resp_uneven", "Too uneven to judge"),
    respFastFmt = pageText(i18n, "resp_fast_fmt", "%d%% faster than asked"),
    respSlowFmt = pageText(i18n, "resp_slow_fmt", "%d%% slower than asked"),
    respOk = pageText(i18n, "resp_ok", "Matches the stick"),
    stopsMoreFmt = pageText(i18n, "stops_more_fmt", "Needs more stops (%d/%d)"),
    stopsValueFmt = pageText(i18n, "stops_value_fmt", "%d%% bounce-back"),
    stopsShakeFmt = pageText(i18n, "stops_shake_fmt", "Shaking %d deg/s"),

    actFlyRoll = pageText(i18n, "act_fly_roll", "Fly rolls in acro mode, centre the stick after each"),
    actFlyPitch = pageText(i18n, "act_fly_pitch", "Fly flips in acro mode, centre the stick after each"),
    actFlyYaw = pageText(i18n, "act_fly_yaw", "Fly pirouettes in acro mode, centre the stick after each"),
    actRatePctUpFmt = pageText(i18n, "act_rate_pct_up_fmt", "%s > %s: all rates about %d%% higher"),
    actRatePctDownFmt = pageText(i18n, "act_rate_pct_down_fmt", "%s > %s: all rates about %d%% lower"),
    actNone = pageText(i18n, "act_none", "No change suggested"),
    applyHint = pageText(i18n, "apply_hint", "Press Save to write these to the flight controller."),
    profileSwitchFmt = pageText(i18n, "profile_switch_fmt",
      "Flown on PID profile %d and rate profile %d. Switch to them to save."),
    profileUnknown = pageText(i18n, "profile_unknown",
      "The flights do not say which profiles they were flown on. Fly again to save."),

    whyMore = pageText(i18n, "why_more", "Each flight in acro mode is saved when you disarm."),
    whyUneven = pageText(i18n, "why_uneven", "The response varies too much to judge. Common in 3D."),
    whyFast = pageText(i18n, "why_fast", "The heli turns faster than the stick asks for."),
    whySlow = pageText(i18n, "why_slow", "The heli turns slower than the stick asks for."),
    whyKeepFeel = pageText(i18n, "why_keep_feel", "Changing FF and the rates together keeps the stick feel."),
    whyNoF = pageText(i18n, "why_no_f", "This axis has no FF, so its PID gains set the response."),
    whyFullFmt = pageText(i18n, "why_full_fmt", "Full stick asks %d deg/s but the heli tops out at %d."),
    whyCollHighFmt = pageText(i18n, "why_coll_high_fmt", "It turns %d%% faster at high collective than at low."),
    whyCollLowFmt = pageText(i18n, "why_coll_low_fmt", "It turns %d%% faster at low collective than at high."),
    whyRelax = pageText(i18n, "why_relax", "After a stop, the I-term pushes the heli back."),
    whyRelaxOff = pageText(i18n, "why_relax_off",
      "After a stop, the I-term pushes the heli back, but I-term relax is off for this axis."),
    whyFixFFmt = pageText(i18n, "why_fix_f_fmt", "Stops bounce back %d%%. Fix FF first, then check again."),
    whyBrakeFmt = pageText(i18n, "why_brake_fmt", "Stops bounce back %d%%. More P brakes them (or add B)."),
    whyShakeFmt = pageText(i18n, "why_shake_fmt", "Shakes %d deg/s at centre stick. Less P calms it."),
    whyShakeOnlyFmt = pageText(i18n, "why_shake_only_fmt", "Shakes %d deg/s at centre stick."),
    whyOk = pageText(i18n, "why_ok", "The heli answers the stick as asked."),
    whyLimit = pageText(i18n, "why_limit", "The change needed goes past a setting's limit."),
    whyPMaxFmt = pageText(i18n, "why_p_max_fmt", "P is already %d%% above your setting. Check the mechanics."),
    whyJournalUnread = pageText(i18n, "why_journal_unread", "The change journal could not be read, so P is not raised."),

    armed = pageText(i18n, "save_armed", "Disarm first. Nothing was saved."),
    disconnected = pageText(i18n, "save_disconnected", "Connect the flight controller first."),
    noBoard = pageText(i18n, "save_no_board", "The flight controller ID is not known."),
    busy = pageText(i18n, "save_busy", "An apply is already running."),
    noChanges = pageText(i18n, "save_no_changes", "There are no writable changes for this axis."),
    applied = pageText(i18n, "applied", "Changes saved to the flight controller. Fly again to check the new tune."),

    -- Where each change is made
    pidsPage = "@i18n(app.modules.pids.name)@",
    ratesPage = "@i18n(app.modules.rates.name)@",
    advancedMenu = "@i18n(app.modules.advanced.name)@",
    controllerPage = "@i18n(app.modules.pid_controller.name)@",
    pidsAxis = pidsAxis,
    ratesAxis = ratesAxis,
    ratesCyclic = "@i18n(app.pages.flight_tuning_rates.cyclic)@",
    controllerAxis = controllerAxis,
    pidsP = "@i18n(app.pages.flight_tuning_pids.p)@",
    pidsF = "@i18n(app.pages.flight_tuning_pids.f)@",
    cutoff = "@i18n(app.pages.flight_tuning_advanced_pid_controller.cutoff_point)@",
    rateColumns = {
      [RATE_TYPE_ACTUAL] = { rcRate = centerSens, srate = maxRate },
      [RATE_TYPE_QUICK] = { rcRate = rcRate, srate = maxRate },
      [RATE_TYPE_ROTORFLIGHT] = { rcRate = rate }
    }
  }
end

-- The texts only Save shows, resolved on the first Save of a visit rather than on every opening.
local function addSaveTexts(T, i18n)
  T.saveQuestion = pageText(i18n, "save_question", "Write these changes to the flight controller and save them?")
  T.reading = pageText(i18n, "reading", "Reading current settings...")
  T.checking = pageText(i18n, "checking", "Checking saved settings...")
  T.readFailed = pageText(i18n, "read_failed",
    "Could not read the settings from the flight controller. Nothing was changed.")
  T.noSnapshot = pageText(i18n, "save_no_snapshot", "Confirm the changes before saving.")
  T.changed = pageText(i18n, "save_changed",
    "The settings on the flight controller are not the ones these flights were flown with. Nothing was changed. Fly again with the current settings.") -- luacheck: ignore 631
  T.range = pageText(i18n, "save_range", "A suggested value is out of range. Nothing was written.")
  T.startFailed = pageText(i18n, "save_start_failed", "Could not start the save: %s")
  T.saved = pageText(i18n, "save_done", "Saved: %d change(s) written and read back.")
  T.differs = pageText(i18n, "save_differs", "Saved, but the read-back differs: %s")
  T.notStored = pageText(i18n, "save_not_stored",
    "Saving failed. The changes are active until the flight controller restarts, then undone.")
  T.writeFailed = pageText(i18n, "save_write_failed",
    "Writing failed. Nothing was saved: restart the flight controller to undo any part already sent.")
  T.profileMoved = pageText(i18n, "save_profile_moved", "The profile changed during the save. Check both profiles.")
  T.unverified = pageText(i18n, "save_unverified",
    "Saved, but reading back did not confirm it. Check the settings on PIDs, Rates and PID Controller.")
  T.journalFailed = pageText(i18n, "journal_failed", "The change journal could not be written.")
end

local function ensureSaveTexts()
  if ui.text and not ui.text.saveQuestion then addSaveTexts(ui.text, ui.i18n) end
end

local function round(v)
  return math.floor(v + 0.5)
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- Whether value is one the flight controller accepts for that tune key
local function inRange(key, value)
  local range = VALUE_RANGE[key]
  return range ~= nil and type(value) == "number" and value == math.floor(value)
    and value >= range[1] and value <= range[2]
end

-- Where a tune key lives on the flight controller: the reply it is read from and written in, its
-- field there, and whether it belongs to the PID or the rate profile. rateAxis is the rate set
-- the advice works on (2, Pitch, under polar cyclic).
local function fieldOf(key, axis, rateAxis)
  if key == "relaxCutoff" then return "profile", "iterm_relax_cutoff_" .. (axis - 1), "pid" end
  if key == "ratesType" then return "rates", "rates_type", "rate" end
  if key == "rcRate" then return "rates", "rcRates_" .. (rateAxis or axis), "rate" end
  if key == "sRate" then return "rates", "rates_" .. (rateAxis or axis), "rate" end
  return "tuning", "pid_" .. (axis - 1) .. "_" .. key, "pid"
end

local function ffJudged(a)
  return a.ffCount >= FF_MIN_COUNT and a.ffCorr >= FF_MIN_CORR
end

local function ffOff(a)
  return ffJudged(a) and (a.ffGain > FF_HOT or a.ffGain < FF_LOW)
end

-- A raw rate byte as the Rates page shows it for this rates_type
local function rateText(raw, rateType, role)
  local spec = RATE_DISPLAY[rateType] and RATE_DISPLAY[rateType][role]
  if not spec then return tostring(raw) end
  local value = raw * spec.mult / spec.scale
  if spec.scale == 100 then
    return string.format("%.2f", value)
  end
  return string.format("%.0f", value)
end

-- The tune key of a LINEAR_ROLES role
local function rateKey(role)
  return (role == "rcRate") and "rcRate" or "sRate"
end

-- Whether scaling the rate curve by k keeps every scaled byte in the range the flight controller
-- accepts. A percentage-only rates_type has nothing to check.
local function ratesFit(rates, k)
  local roles = LINEAR_ROLES[rates.ratesType]
  if not roles then return true end
  for _, role in ipairs(roles) do
    local key = rateKey(role)
    if not inRange(key, round(rates[key] * k)) then return false end
  end
  return true
end

-- Whether scaling the rate curve by k changes at least one rate byte once rounded: at very low
-- rates it can round back to the same values, and F must not change without them.
local function ratesMove(rates, k)
  local roles = LINEAR_ROLES[rates.ratesType]
  if not roles then return true end
  for _, role in ipairs(roles) do
    local key = rateKey(role)
    if round(rates[key] * k) ~= rates[key] then return true end
  end
  return false
end

-- Suggests scaling the rate curve by k (e.g. 1.25 = 25% faster everywhere); callers check
-- ratesFit() first. A percentage (no linear column for this rates_type) is only shown.
local function rateActions(T, rates, k, act, change)
  local roles = LINEAR_ROLES[rates.ratesType]
  if not roles then
    local pct = round(math.abs(k - 1) * 100)
    act(string.format(k > 1 and T.actRatePctUpFmt or T.actRatePctDownFmt, T.ratesPage, rates.row, pct))
    return
  end
  for _, role in ipairs(roles) do
    local key = rateKey(role)
    local raw = rates[key]
    local newRaw = round(raw * k)
    change(string.format(PATH_FMT, T.ratesPage, rates.row, T.rateColumns[rates.ratesType][role],
      rateText(raw, rates.ratesType, role), rateText(newRaw, rates.ratesType, role)), key, raw, newRaw)
  end
end

-- How many lines rateActions() adds for this rates_type
local function rateActionCount(rates)
  local roles = LINEAR_ROLES[rates.ratesType]
  return roles and #roles or 1
end

-- Fills actions/whys/changes (cleared by the caller) for one axis; returns the Response and
-- Stops values. changes holds what Save writes, one entry per setting line, built by the same
-- call that adds the line, so the screen and the save cannot disagree.
--
-- A change and its reason go in together or not at all, so a reason never shows for a change
-- that was left out: a later change first checks room(). The first change (fly more, F with its
-- rates, or full-stick rates) always fits. The reasons for changes stay within MAX_WHYS; only the
-- closing |collective| fact can be cut. A change that would leave the range the flight controller
-- accepts is dropped with anything tied to it, and the reasons say so once (atLimit).
--
-- rates: the rate set the advice works on ({ratesType, rcRate, sRate, row, axis}); ctx: the
-- newest flight's cyclic ring and I-term relax type where they apply (nil = unknown); pilotP:
-- the pilot's own P for this axis, nil when the change journal could not be read.
local function advise(T, a, axis, rates, ctx, pilotP, actions, whys, changes)
  local function room(n) return #actions + n <= MAX_ACTIONS end
  local function act(s) if #actions < MAX_ACTIONS then actions[#actions + 1] = s end end
  local function why(s) if #whys < MAX_WHYS then whys[#whys + 1] = s end end
  -- A setting line: callers check room() first, so it is never dropped
  local function change(text, key, from, to)
    act(text)
    if from ~= to then
      local msg, field, profileKind = fieldOf(key, axis, rates.axis)
      changes[#changes + 1] = {
        key = key, msg = msg, field = field, from = from, to = to, text = text, profileKind = profileKind
      }
    end
  end
  local limited = false
  local function atLimit()
    if not limited then limited = true; why(T.whyLimit) end
  end
  local pidPathP = function(from, to) return string.format(PATH_FMT, T.pidsPage, T.pidsAxis[axis], T.pidsP, from, to) end

  local shaking = a.shakeCount >= SHAKE_MIN_COUNT and a.shakeRms >= SHAKE_RMS

  -- Response: feed-forward match
  local response
  if a.ffCount < FF_MIN_COUNT then
    response = string.format(T.respMoreFmt, math.floor(100 * a.ffCount / FF_MIN_COUNT))
    act(axis == AXIS_ROLL and T.actFlyRoll or axis == AXIS_PITCH and T.actFlyPitch or T.actFlyYaw)
    why(T.whyMore)
  elseif a.ffCorr < FF_MIN_CORR then
    response = T.respUneven
    why(T.whyUneven)
  elseif ffOff(a) then
    local g = a.ffGain
    local hot = g > FF_HOT
    response = string.format(hot and T.respFastFmt or T.respSlowFmt, round(math.abs(g - 1) * 100))
    -- A shaking axis gets no F advice: the shake comes first (see Stops)
    if not shaking and a.F > 0 then
      local newF = round(a.F * clamp(1 / g, 1 - FF_STEP_MAX, 1 + FF_STEP_MAX))
      -- Keep the stick feel: F x rate is what the pilot feels. F is applied only with its rates,
      -- so a percentage-only rates_type applies neither, and F is not given at all when F or a
      -- rate would leave its range, or when the rates round back to the same values.
      if newF < 1 or not inRange("F", newF) or not ratesFit(rates, a.F / newF) then
        why(hot and T.whyFast or T.whySlow)
        atLimit()
      elseif not ratesMove(rates, a.F / newF) then
        why(hot and T.whyFast or T.whySlow)
      else
        local text = string.format(PATH_FMT, T.pidsPage, T.pidsAxis[axis], T.pidsF, a.F, newF)
        if LINEAR_ROLES[rates.ratesType] then change(text, "F", a.F, newF) else act(text) end
        rateActions(T, rates, a.F / newF, act, change)
        why(hot and T.whyFast or T.whySlow)
        why(T.whyKeepFeel)
      end
    elseif not shaking then
      why(T.whyNoF)
    end
  else
    response = T.respOk
    local asked = maxRateAsked(rates)
    -- Measured against the rate full stick is given, after the cyclic ring (see reachable)
    local given = asked and reachable(asked, ctx.ring)
    if not shaking and axis ~= AXIS_YAW and given and a.fullCount >= FULL_MIN_COUNT
        and a.fullSatCount >= FULL_SAT_SHARE * a.fullCount
        and a.fullMaxRate < FULL_REACH * given and room(rateActionCount(rates)) then
      local k = math.max(a.fullMaxRate / given, 1 - FF_STEP_MAX)
      local fits = ratesFit(rates, k)
      if fits then rateActions(T, rates, k, act, change) end
      why(string.format(T.whyFullFmt, round(given), a.fullMaxRate))
      if not fits then atLimit() end
    end
  end

  -- Stops: rebound after a release
  local stops
  if shaking then
    local rms = round(a.shakeRms)
    stops = string.format(T.stopsShakeFmt, rms)
    if a.P > 1 and room(1) then
      local newP = clamp(round(a.P / P_STEP), 1, a.P - 1)
      change(pidPathP(a.P, newP), "P", a.P, newP)
      why(string.format(T.whyShakeFmt, rms))
    else
      -- Nothing to lower, or no room for it: the shake is still the reason, never "answers the
      -- stick as asked" beside it.
      why(string.format(T.whyShakeOnlyFmt, rms))
    end
  elseif a.releases < STOPS_MIN then
    stops = string.format(T.stopsMoreFmt, a.releases, STOPS_MIN)
  else
    local rebound = round(a.meanRebound * 100)
    stops = string.format(T.stopsValueFmt, rebound)
    if a.meanRebound >= REBOUND_BAD then
      -- No room for the cut-off only after F and two rate lines; F is off then, so the next
      -- branch says to fix F first.
      if a.meanIterm >= ITERM_PUSH and a.relaxCutoff > CUTOFF_MIN and room(1) then
        if not relaxCovers(ctx.relaxType, axis) then
          -- The cut-off is not used on this axis: lowering it would change nothing in flight
          why(T.whyRelaxOff)
        else
          local newCutoff = math.min(round(a.relaxCutoff * CUTOFF_STEP), a.relaxCutoff - 1)
          if inRange("relaxCutoff", newCutoff) then
            change(string.format(ADVANCED_PATH_FMT, T.advancedMenu, T.controllerPage, T.cutoff,
              T.controllerAxis[axis], a.relaxCutoff, newCutoff), "relaxCutoff", a.relaxCutoff, newCutoff)
            why(T.whyRelax)
          else
            atLimit()
          end
        end
      elseif ffOff(a) and a.F > 0 then
        -- F first, unless F was at its limit: then nothing is advised here
        if not limited then why(string.format(T.whyFixFFmt, rebound)) end
      elseif room(1) then
        local newP = math.max(round(a.P * P_STEP), a.P + 1)
        if not inRange("P", newP) then
          atLimit()
        elseif pilotP == nil then
          -- The journal could not be read: how far P is above the pilot's own cannot be told
          why(T.whyJournalUnread)
        elseif newP > math.floor(pilotP * P_RAISE_MAX) then
          -- Already raised as far as this page goes; a P of 0 or 1 gets no raise
          if a.P > pilotP and pilotP > 0 then
            why(string.format(T.whyPMaxFmt, round((a.P / pilotP - 1) * 100)))
          else
            atLimit()
          end
        else
          change(pidPathP(a.P, newP), "P", a.P, newP)
          why(string.format(T.whyBrakeFmt, rebound))
        end
      end
    end
  end

  -- Least important last: a fact, no action
  if ffJudged(a) then
    local lo, hi = a.collBands[1], a.collBands[3]
    if lo.count >= BAND_MIN_COUNT and hi.count >= BAND_MIN_COUNT and lo.gain > 0 and hi.gain > 0 then
      local spread = math.max(lo.gain, hi.gain) / math.min(lo.gain, hi.gain)
      if spread >= COLL_SPREAD then
        why(string.format(hi.gain > lo.gain and T.whyCollHighFmt or T.whyCollLowFmt, round((spread - 1) * 100)))
      end
    end
  end

  if #actions == 0 then
    act(T.actNone)
    if #whys == 0 then why(T.whyOk) end
  end

  return response, stops
end

local function newView()
  return { data = "-", profile = "-", response = "-", stops = "-", actions = {}, whys = {}, changes = {} }
end

local function getSession()
  return _G.rfsuite and _G.rfsuite.session or nil
end

local function sessionMcu()
  local session = getSession()
  local id = session and session.mcu_id
  if id == nil or tostring(id) == "" then return nil end
  return id
end

-- The flight capture's state, where it runs in this Lua state (a tool opened from the dashboard):
-- "reading" from the disarm until the flight is saved, "failed" when it gave up until the next
-- disarm. A tool started on its own never sees it.
local function captureState()
  local session = getSession()
  local capture = session and session.tuneCapture
  return capture and capture.state or nil
end

local function copy(record)
  local out = {}
  for key, value in pairs(record) do out[key] = value end
  return out
end

-- What the advice for one axis rests on: the rate set, the context and whether Save may write it.
-- The context comes from the newest flight and counts only when the active profiles are the
-- ones it was flown on; otherwise it is unknown and `blocked` says why Save stays off.
local function adviceBasis(T, axis)
  local entry = ui.axes[axis]
  local a = entry.a
  local pid, rate = currentProfiles()
  local ctx, blocked = {}, nil
  if (entry.used or 0) == 0 then
    -- No flight saved: nothing was flown on any profile, and there is nothing to save.
  elseif a.pidProfile == nil or a.rateProfile == nil then
    blocked = T.profileUnknown
  elseif a.pidProfile ~= pid or a.rateProfile ~= rate then
    blocked = string.format(T.profileSwitchFmt, a.pidProfile, a.rateProfile)
  else
    ctx.polar = a.cyclicPolarity == 1
    ctx.ring = a.cyclicRing
    ctx.relaxType = a.relaxType
  end
  local rates = { ratesType = a.ratesType, rcRate = a.rcRate, sRate = a.sRate, row = T.ratesAxis[axis], axis = axis }
  if ctx.polar and axis ~= AXIS_YAW then
    -- Under polar cyclic the flight controller ignores the Roll rates: both axes follow Pitch's.
    local p = ui.newestHasPitch and ui.axes[AXIS_PITCH].a
    if not p then
      ensureSaveTexts()
      blocked = blocked or T.changed
      ctx.polar = false
    else
      rates = { ratesType = p.ratesType, rcRate = p.rcRate, sRate = p.sRate, row = T.ratesCyclic, axis = AXIS_PITCH }
    end
  end
  return a, rates, ctx, blocked, pid, rate
end

local function render()
  local T = ui.text
  if not T then return end
  local view = newView()
  ui.view = view
  if ui.unsupported then
    view.data = T.unsupported
  elseif not ui.mcu then
    view.data = T.noAircraft
  elseif captureState() == "reading" then
    -- The advice would change in a few seconds: show none until it does
    view.data = T.readingFlight
  elseif ui.axes then
    local axis = ui.selected
    local entry = ui.axes[axis]
    local a, rates, ctx, blocked, pid, rate = adviceBasis(T, axis)
    view.data = string.format(T.dataFlightsFmt, math.floor(entry.seconds / 60), entry.seconds % 60,
      entry.used, ui.maxFlights)
    if a.pidProfile ~= nil and a.rateProfile ~= nil then
      view.profile = string.format(T.profileFmt, a.pidProfile, a.rateProfile)
    end
    local actions, whys = {}, {}
    view.response, view.stops = advise(T, a, axis, rates, ctx, entry.pilotP, actions, whys, view.changes)
    local tune = {
      axis = axis, mcu = ui.mcu, pidProfile = pid, rateProfile = rate,
      polar = ctx.polar == true, ring = ctx.ring, relaxType = ctx.relaxType, rateAxis = rates.axis,
      cyclicType = rates.ratesType, cyclicRc = rates.rcRate, cyclicS = rates.sRate,
      asked = maxRateAsked(rates)
    }
    for _, k in ipairs(TUNE_KEYS) do tune[k] = a[k] end
    view.tune = tune
    view.blocked = blocked
    if ui.applied[axis] then
      -- The advice was for the tune just replaced: nothing to do but fly
      view.changes = {}
      view.actions = { T.applied }
    else
      view.actions, view.whys = actions, whys
      if blocked then
        table.insert(view.actions, 1, blocked)
      elseif #view.changes > 0 then
        view.actions[#view.actions + 1] = T.applyHint
      end
    end
    if captureState() == "failed" then table.insert(view.actions, 1, T.notRead) end
  end
  requestRebuild()
end

local function getQueue()
  if not MspRuntime or type(MspRuntime.getState) ~= "function" then return nil end
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then return nil end
  return queue
end

-- Starts this visit's read of the saved flights. The read runs as steps on the page's wakeups
-- (readHistoryStep): the history module, the file, its lines a flight at a time, then the three
-- axes combined one per pass, then the change journal for the pilot's own P a few lines per pass.
-- Nothing can be saved until it has finished.
local function queueHistoryRead()
  ui.runtime.historyRead = false
  ui.mcu = sessionMcu()
  ui.axes, ui.axesBuilt, ui.flights, ui.readJob, ui.journalJob = nil, nil, nil, nil, nil
  for axis = AXIS_ROLL, AXIS_YAW do ui.applied[axis] = nil end
  local session = getSession()
  local capture = session and session.tuneCapture
  ui.seenSaved = capture and capture.saved or nil
  ui.loadStep = ui.mcu and "read" or nil
  ui.probeOwed = true
end

local function readHistoryStep()
  local step = ui.loadStep
  if step == "read" then
    -- The module on one pass and the file on the next: together they were the dearest step
    if not TuneHistory then
      TuneHistory = loadModule("lib/tune_history.lua")
      if not TuneHistory then ui.loadStep = nil end
      return
    end
    ui.maxFlights = TuneHistory.MAX_FLIGHTS or ui.maxFlights
    -- The file on one pass, then at most one flight's lines per pass
    if not ui.readJob then ui.readJob = TuneHistory.readJob(ui.mcu) end
    local flights = TuneHistory.readStep(ui.readJob)
    if flights == nil then return end
    ui.flights, ui.readJob = flights, nil
    ui.loadStep = "aggregate"
  elseif step == "aggregate" then
    -- One axis per pass: all three in one were the dearest pass of the open
    local flights = ui.flights or {}
    local axes = ui.axesBuilt
    if not axes then
      axes = {}
      ui.axesBuilt = axes
      local newest = flights[#flights]
      ui.newestHasPitch = newest ~= nil and newest.axes[AXIS_PITCH] ~= nil
    end
    local axis = #axes + 1
    local a, used, seconds = TuneHistory.aggregate(flights, axis)
    axes[axis] = { a = a, used = used, seconds = seconds, pilotP = a.P }
    if axis < AXIS_YAW then return end
    ui.axes, ui.axesBuilt, ui.flights = axes, nil, nil
    ui.loadStep = "journal"
  elseif step == "journal" then
    -- The pilot's own P, per axis, on the PID profile the flights were flown on. The journal
    -- grows with every save, so it is read like the flights: the module and the job on one pass,
    -- then a bounded number of its lines per pass, keeping only the entries for P.
    if not ui.journalJob then
      if not ChangeJournal then ChangeJournal = loadModule("lib/change_journal.lua") end
      if ChangeJournal and type(ChangeJournal.readJob) == "function" then
        ui.journalJob = ChangeJournal.readJob(ui.mcu, { pid_0_P = true, pid_1_P = true, pid_2_P = true })
        return
      end
    end
    local entries = nil
    if ui.journalJob then
      entries = ChangeJournal.readStep(ui.journalJob)
      if entries == false then return end
      ui.journalJob = nil
    end
    -- No journal is no record: the current P is the pilot's. A journal that is there but cannot
    -- be read leaves it unknown (nil), and P is then not raised. One walk for the three axes.
    local pid = currentProfiles()
    local wants = {}
    for axis = AXIS_ROLL, AXIS_YAW do
      local a = ui.axes[axis].a
      wants[axis] = { profile = a.pidProfile or pid, field = "pid_" .. (axis - 1) .. "_P", value = a.P }
    end
    if type(entries) == "table" then TuneHistory.pilotValues(entries, wants) end
    for axis = AXIS_ROLL, AXIS_YAW do
      ui.axes[axis].pilotP = type(entries) == "table" and wants[axis].value or nil
    end
    -- Neither module is needed again until Clear or Save
    TuneHistory, ChangeJournal = nil, nil
    ui.loadStep = nil
    ui.runtime.historyRead = true
    collectgarbage("collect")
    render()
  end
end

-- One request, on open and on Reload: whether the firmware has the command at all. The flight
-- controller's error reply, or a reply of another layout, means it does not.
local function probe()
  -- Loaded for the request alone, which holds it until the answer; the build does not need it,
  -- and Clear loads it again
  local api = loadModule("tasks/msp/api/tune_advisor.lua")
  local queue = getQueue()
  if not api then ui.probeOwed = false; return end
  if not queue then return end
  ui.probeOwed = false
  ui.probing = true
  local generation = ui.generation
  queue:add({
    command = api.command,
    payload = { 0 },
    isWrite = false,
    -- Only this field lets the error reply reach processReply instead of being retried
    completeOnErrorReplyAttempt = 1,
    simulatorResponse = api.simulatorResponseFor(AXIS_ROLL),
    processReply = function(_, buf)
      if generation ~= ui.generation then return end
      ui.probing = false
      local supported = api.parse(buf) ~= nil
      if supported == ui.unsupported then
        ui.unsupported = not supported
        render()
      end
    end,
    -- No answer at all is the link, not the firmware: the saved flights do not need it
    errorHandler = function()
      if generation ~= ui.generation then return end
      ui.probing = false
    end
  })
end

local function clear()
  local mcu = ui.mcu
  if not mcu then return end
  if not TuneHistory then TuneHistory = loadModule("lib/tune_history.lua") end
  if TuneHistory then TuneHistory.erase(mcu) end
  TuneHistory = nil
  local api = loadModule("tasks/msp/api/tune_advisor.lua")
  local queue = getQueue()
  if api and queue and not ui.unsupported then
    local generation = ui.generation
    queue:add({
      command = api.writeCommand,
      payload = {},
      isWrite = true,
      completeOnErrorReplyAttempt = 1,
      simulatorResponse = {},
      processReply = function(_, buf)
        if generation ~= ui.generation then return end
        -- The acknowledgement carries no bytes; the error reply of a firmware without the
        -- command carries one.
        if type(buf) == "table" and #buf > 0 then
          ui.unsupported = true
          render()
        end
      end
    })
  end
  queueHistoryRead()
  ui.probeOwed = false
  render()
end

local function ensureLoaded(i18n)
  if ui.loaded then return end
  ui.generation = ui.generation + 1
  ui.loaded = true
  if type(ui.runtime) ~= "table" then ui.runtime = newRuntime() end
  ui.selected = AXIS_ROLL
  ui.unsupported = false
  ui.probing = false
  ui.captureState = captureState()
  ui.profileKey = nil
  ui.i18n = i18n
  ui.text = loadTexts(i18n)
  ui.view = newView()
  queueHistoryRead()
  if not ui.mcu then ui.view.data = ui.text.noAircraft end
end

local function onAxis(value)
  if ui.applying then return end
  ui.selected = tonumber(value) or AXIS_ROLL
  render()
end

function M.getHeaderActions()
  return {
    reload = not ui.applying, save = M.canSave(), help = true,
    star = not ui.applying and captureState() ~= "reading"
  }
end

function M.canSave()
  local T = ui.text
  if not T then return false, pageText(nil, "save_no_changes", "There are no writable changes for this axis.") end
  if not (ui.runtime and ui.runtime.historyRead == true) then return false, T.noChanges end
  local state = MspRuntime and MspRuntime.getState()
  if not state or state.lastConnected ~= true then return false, T.disconnected end
  if state.lastArmed == true or (Armed and Armed.isArmed()) then return false, T.armed end
  local session = getSession()
  if not session or session.mcu_id == nil or tostring(session.mcu_id) == "" then return false, T.noBoard end
  if ui.applying then return false, T.busy end
  if ui.unsupported or captureState() == "reading" then return false, T.noChanges end
  local view = ui.view
  if not view or not view.tune or view.tune.axis ~= ui.selected or #view.changes == 0 then return false, T.noChanges end
  if view.blocked then return false, view.blocked end
  return true
end

function M.getSaveConfirm(ctx)
  ui.snapshot = nil
  if not M.canSave() then return nil end
  ensureSaveTexts()
  local view = ui.view
  local snapshot = { tune = copy(view.tune), changes = {} }
  local lines = {}
  for i, change in ipairs(view.changes) do
    snapshot.changes[i] = copy(change)
    lines[i] = change.text
  end
  ui.snapshot = snapshot
  return { title = ui.text.pageTitle, message = table.concat(lines, "\n") .. "\n\n" .. ui.text.saveQuestion, always = true }
end

local function finishApply(ok, message)
  local report = ui.reportSave
  ui.applying, ui.snapshot, ui.status, ui.reportSave = false, nil, nil, nil
  ui.readStarted, ui.readTimeout = nil, nil
  requestRebuild()
  if type(report) == "function" then
    local title = ui.text and ui.text.pageTitle or pageText(nil, "title", "Tune Advisor")
    report({ ok = ok, title = title, message = message })
  end
end

-- Nothing here is loaded by the opening chain; these are needed only after Save was confirmed.
local function ensureSaveDeps()
  if not StatusApi then StatusApi = loadModule("tasks/msp/api/status.lua") end
  if not RcTuningApi then RcTuningApi = loadModule("tasks/msp/api/rc_tuning.lua") end
  if not PidTuningApi then PidTuningApi = loadModule("tasks/msp/api/pid_tuning.lua") end
  if not PidProfileApi then PidProfileApi = loadModule("tasks/msp/api/pid_profile.lua") end
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not Cache then Cache = loadModule("tasks/msp/cache.lua") end
  if not Armed then Armed = loadModule("lib/armed.lua") end
  if not ChangeJournal then ChangeJournal = loadModule("lib/change_journal.lua") end
  return StatusApi and PidTuningApi and PidProfileApi and RcTuningApi and SavePipeline and Cache and Armed
end

-- Serialize fresh reads, preserving the reply buffers independently of the queue/cache.
local function readSettings(applyGeneration, onRead)
  local queue = getQueue()
  local specs = {
    { key = "status", api = StatusApi, minBytes = 27 },
    { key = "tuning", api = PidTuningApi }, { key = "profile", api = PidProfileApi }, { key = "rates", api = RcTuningApi }
  }
  local records, buffers = {}, {}
  local function readNext(index)
    if applyGeneration ~= ui.applyGeneration or not ui.applying then return end
    local spec = specs[index]
    if not spec then ui.readStarted, ui.readTimeout = nil, nil; onRead(records, buffers); return end
    if not queue then ui.readStarted = nil; onRead(nil, nil, spec.key); return end
    ui.readStarted = nowSeconds()
    local function failed()
      if applyGeneration ~= ui.applyGeneration or not ui.applying then return end
      ui.readStarted, ui.readTimeout = nil, nil
      onRead(nil, nil, spec.key)
    end
    ui.readTimeout = failed
    queue:add({
      command = spec.api.command,
      isWrite = false,
      processReply = function(_, buf)
        if applyGeneration ~= ui.applyGeneration or not ui.applying then return end
        if spec.minBytes and (type(buf) ~= "table" or #buf < spec.minBytes) then failed(); return end
        local record = spec.api.parse(buf)
        if not record then failed(); return end
        records[spec.key], buffers[spec.key] = record, copy(buf)
        readNext(index + 1)
      end,
      errorHandler = function()
        if applyGeneration ~= ui.applyGeneration or not ui.applying then return end
        failed()
      end
    })
  end
  Cache.clear()
  readNext(1)
end

-- The flight controller must still hold the tune and the context the advice was worked out for,
-- and every change must start from the value it names and land inside the setting's range.
local function validateTune(snapshot, records)
  local tune, T = snapshot.tune, ui.text
  local session = getSession()
  local state = MspRuntime and MspRuntime.getState()
  if Armed.isArmed() or (state and state.lastArmed == true) then return T.armed end
  local pid, rate = currentProfiles()
  if not state or state.lastConnected ~= true or not session or session.mcu_id ~= tune.mcu
      or pid ~= tune.pidProfile or rate ~= tune.rateProfile then return T.changed end
  local status = records.status
  if status.current_pid_profile_index + 1 ~= tune.pidProfile
      or status.current_control_rate_profile_index + 1 ~= tune.rateProfile then return T.changed end
  -- The newest flight's tune, field by field, on the axis's own bytes
  for _, key in ipairs(TUNE_KEYS) do
    local msg, field = fieldOf(key, tune.axis)
    if records[msg][field] ~= tune[key] then return T.changed end
  end
  local rates, profile = records.rates, records.profile
  if tune.axis ~= AXIS_YAW then
    -- Polar cyclic decides which rate bytes the advice is about, and the cyclic ring what full
    -- stick is given
    if (rates.cyclic_polarity == 1) ~= tune.polar then return T.changed end
    if tune.polar and (rates.rates_type ~= tune.cyclicType or rates.rcRates_2 ~= tune.cyclicRc
        or rates.rates_2 ~= tune.cyclicS) then return T.changed end
  end
  for _, change in ipairs(snapshot.changes) do
    if records[change.msg][change.field] ~= change.from then return T.changed end
    if not inRange(change.key, change.to) then return T.range end
    if change.key == "relaxCutoff" and not relaxCovers(profile.iterm_relax_type, tune.axis) then
      return T.changed
    end
    if (change.key == "rcRate" or change.key == "sRate") and tune.asked
        and reachable(tune.asked, rates.cyclic_ring) ~= reachable(tune.asked, tune.ring) then
      return T.changed
    end
  end
end

local function buildSteps(snapshot, records, buffers)
  local steps = {}
  local specs = {
    { key = "tuning", api = PidTuningApi, label = "MSP_SET_PID_TUNING" },
    { key = "profile", api = PidProfileApi, label = "MSP_SET_PID_PROFILE" },
    { key = "rates", api = RcTuningApi, label = "MSP_SET_RC_TUNING" }
  }
  for _, spec in ipairs(specs) do
    local payload, baseline
    for _, change in ipairs(snapshot.changes) do
      if change.msg == spec.key then
        if not payload then
          payload = copy(buffers[spec.key])
          baseline = spec.api.buildWritePayload(records[spec.key])
          if #baseline > #payload then return nil end
          for i = 1, #baseline do if baseline[i] ~= payload[i] then return nil end end
        end
        local modified = copy(records[spec.key])
        modified[change.field] = change.to
        local encoded = spec.api.buildWritePayload(modified)
        if #encoded ~= #baseline then return nil end
        local changed = false
        for i = 1, #baseline do
          if encoded[i] ~= baseline[i] then payload[i] = encoded[i]; changed = true end
        end
        if not changed then return nil end
      end
    end
    if payload then steps[#steps + 1] = { label = spec.label, command = spec.api.writeCommand, payload = payload } end
  end
  return steps
end

function M.onSave(ctx)
  if ui.applying then return false end
  ensureSaveTexts()
  local snapshot = ui.snapshot
  ui.snapshot = nil
  ui.reportSave = ctx and ctx.reportSave
  if not snapshot then
    local message = ui.text and ui.text.noSnapshot or pageText(nil, "save_no_snapshot", "Confirm the changes before saving.")
    finishApply(false, message)
    return false
  end
  -- Only what this visit read and shows can be written
  if not M.canSave() then return finishApply(false, select(2, M.canSave())) or false end
  ui.applyGeneration = ui.applyGeneration + 1
  ui.applying, ui.status = true, ui.text.reading
  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or ui.runtime.requestRebuild
  requestRebuild()
  if not ensureSaveDeps() then finishApply(false, ui.text.readFailed); return false end
  local applyGeneration = ui.applyGeneration
  local generation = ui.generation
  local journalFailed = false
  local function markApplied()
    -- Only on the visit that saved: a later visit reads the flights again
    if generation ~= ui.generation then return end
    ui.applied[snapshot.tune.axis] = true
    if snapshot.tune.polar then
      for _, change in ipairs(snapshot.changes) do
        if change.msg == "rates" then
          ui.applied[AXIS_ROLL], ui.applied[AXIS_PITCH] = true, true
          break
        end
      end
    end
  end
  local function readBack(records)
    if applyGeneration ~= ui.applyGeneration or not ui.applying then return end
    local mismatch
    local session = getSession()
    local status = records and records.status
    local pid, rate = currentProfiles()
    local sameProfile = status and session and session.mcu_id == snapshot.tune.mcu
      and status.current_pid_profile_index + 1 == snapshot.tune.pidProfile
      and status.current_control_rate_profile_index + 1 == snapshot.tune.rateProfile
      and pid == snapshot.tune.pidProfile and rate == snapshot.tune.rateProfile
    local message
    if not records then
      message = ui.text.unverified
    elseif not sameProfile then
      message = ui.text.profileMoved
    else
      for _, change in ipairs(snapshot.changes) do
        if records[change.msg][change.field] ~= change.to then
          mismatch = change.field
          break
        end
      end
      message = mismatch and string.format(ui.text.differs, mismatch) or string.format(ui.text.saved, #snapshot.changes)
    end
    if journalFailed then message = message .. " " .. ui.text.journalFailed end
    finishApply(records ~= nil and sameProfile and mismatch == nil, message)
  end
  readSettings(applyGeneration, function(records, buffers)
    if applyGeneration ~= ui.applyGeneration or not ui.applying then return end
    if not records then finishApply(false, ui.text.readFailed); return end
    local refusal = validateTune(snapshot, records)
    if refusal then finishApply(false, refusal); return end
    local steps = buildSteps(snapshot, records, buffers)
    if not steps then finishApply(false, ui.text.changed); return end
    ui.status = nil
    local journal = ChangeJournal
    local started, reason = SavePipeline.start({
      pageId = PAGE_ID,
      steps = steps,
      reboot = false,
      onSaved = function()
        -- A save without reboot can commit after the page closes, so record it regardless.
        local active = applyGeneration == ui.applyGeneration and ui.applying
        markApplied()
        local entries = {}
        for i, change in ipairs(snapshot.changes) do
          local profile = change.profileKind == "pid" and snapshot.tune.pidProfile or snapshot.tune.rateProfile
          entries[i] = { source = "tune_advisor", profile = profile, field = change.field, old = change.from, new = change.to }
        end
        local appended = journal and journal.append(snapshot.tune.mcu, entries)
        if active then
          journalFailed = not appended
          render()
        end
      end,
      onDone = function(result)
        if applyGeneration ~= ui.applyGeneration or not ui.applying then return end
        if result.status ~= "done" then
          if type(SavePipeline.hasOutcome) == "function" and SavePipeline.hasOutcome() then SavePipeline.dismiss() end
          local commit = result.step == "commit" or result.phase == "commit"
          render()
          finishApply(false, commit and ui.text.notStored or ui.text.writeFailed)
          return
        end
        -- The page reports the verified result. Retire the pipeline's success notice so it
        -- cannot hide that report or announce completion while the read-back is still pending.
        if type(SavePipeline.hasOutcome) == "function" and SavePipeline.hasOutcome() then SavePipeline.dismiss() end
        ui.status = ui.text.checking
        requestRebuild()
        readSettings(applyGeneration, readBack)
      end
    })
    if not started then finishApply(false, string.format(ui.text.startFailed, tostring(reason))) end
  end)
  return false
end

-- Background work lives here and never on the pass that built the page: a build this pass
-- defers it to the next one, at most once in a row. Each pass does at most one of: a step of
-- the history read, the support probe, or a look at what changed in the session.
function M.wakeup(ctx)
  if not ui.loaded then return end
  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or ui.runtime.requestRebuild
  if ui.applying then
    -- Backstop for a request dropped without a handler, e.g. a simulator message without simulatorResponse.
    if ui.readStarted and nowSeconds() - ui.readStarted > 30 then
      if ui.readTimeout then ui.readTimeout() end
    end
    return
  end

  if ui.runtime.builtThisPass and not ui.runtime.deferredLastPass then
    ui.runtime.builtThisPass = false
    ui.runtime.deferredLastPass = true
    return
  end
  ui.runtime.builtThisPass = false
  ui.runtime.deferredLastPass = false

  if ui.loadStep then
    readHistoryStep()
    return
  end
  if ui.probeOwed and not ui.probing and ui.mcu then
    probe()
    return
  end

  -- The aircraft, the flight capture and the profiles: field tests only, no file is read here.
  -- A link loss clears the session's mcu_id until the next connection reads it again; the saved
  -- flights do not need the link, so only another flight controller changes what is shown.
  local mcu = sessionMcu()
  if mcu ~= nil and mcu ~= ui.mcu then
    -- Another flight controller: whether its firmware has the command is asked afresh
    ui.unsupported = false
    queueHistoryRead()
    render()
    return
  end
  local session = getSession()
  local capture = session and session.tuneCapture
  if capture then
    if capture.saved ~= ui.seenSaved then
      ui.seenSaved = capture.saved
      if capture.savedMcu == ui.mcu then
        queueHistoryRead()
        ui.probeOwed = false
      end
    end
    if capture.state ~= ui.captureState then
      ui.captureState = capture.state
      render()
      return
    end
  end
  if ui.axes then
    local pid, rate = currentProfiles()
    local key = pid * 16 + rate
    if key ~= ui.profileKey then
      if ui.profileKey ~= nil then render() end
      ui.profileKey = key
    end
  end
end

-- One line of text that may wrap, and the height it takes
local function appendText(children, x, y, w, text, color)
  children[#children + 1] = {
    type = "label", x = x, y = y, w = w, text = text, color = color or Palette.text, font = SMLSIZE
  }
  local lineH = Controls.LABEL_H or 21
  if type(Controls.estimateWrappedTextHeight) == "function" then
    local total = Controls.estimateWrappedTextHeight(text, w, SMLSIZE)
    local one = Controls.estimateWrappedTextHeight("Ag", w, SMLSIZE)
    if type(total) == "number" and type(one) == "number" and one > 0 then
      return math.max(1, math.floor(total / one + 0.5)) * (one + 4)
    end
  end
  return lineH + 4
end

local function appendValueRow(children, x, y, w, label, value)
  local rowH = Controls.ROW_H or 40
  local labelY = Controls.labelY(y, rowH)
  local labelW = math.floor(w * 0.42)
  children[#children + 1] = {
    type = "label", x = x + 10, y = labelY, w = labelW - 10,
    text = label, color = Palette.text, font = SMLSIZE
  }
  children[#children + 1] = {
    type = "label", x = x + labelW, y = labelY, w = w - labelW - 10,
    text = value, color = Palette.text, align = RIGHT, font = SMLSIZE
  }
  children[#children + 1] = {
    type = "rectangle", x = x, y = y + rowH, w = w, h = 1, color = Palette.border, filled = true
  }
  return rowH + 1
end

local function appendSection(children, x, y, w, title, items)
  if #items == 0 then return 0 end
  local cursorY = y
  Controls.appendStaticSectionHeader(children, x, cursorY, w, title)
  cursorY = cursorY + (Controls.STATIC_SECTION_H or 38) + 4
  for i = 1, #items do
    cursorY = cursorY + appendText(children, x + 10, cursorY, w - 20, items[i])
  end
  return cursorY - y + 6
end

function M.build(ctx)
  ensureDeps()
  if not Common or not Controls then return end
  local i18n = ctx and ctx.i18n
  ensureLoaded(i18n)
  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil
  ui.runtime.builtThisPass = true

  local T = ui.text
  local view = ui.view or newView()
  local children = ctx.children
  local x, y, w = ctx.x, ctx.y, ctx.w
  local cursorY = y

  Controls.appendStaticSectionHeader(children, x, cursorY, w, T.pageTitle)
  cursorY = cursorY + (Controls.STATIC_SECTION_H or 38)

  if ui.status then cursorY = cursorY + appendText(children, x + 10, cursorY, w - 20, ui.status) end

  local axisOptions = {
    { label = T.axisNames[AXIS_ROLL], value = AXIS_ROLL },
    { label = T.axisNames[AXIS_PITCH], value = AXIS_PITCH },
    { label = T.axisNames[AXIS_YAW], value = AXIS_YAW }
  }
  cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w, T.axis, axisOptions,
    ui.selected, onAxis, { helpText = pageText(i18n, "help_axis",
      "Roll, Pitch or Yaw: the flight data, the advice and Save below are for this axis only."), helpTitle = T.axis })

  cursorY = cursorY + appendValueRow(children, x, cursorY, w, T.data, view.data)
  cursorY = cursorY + appendValueRow(children, x, cursorY, w, T.profile, view.profile)
  cursorY = cursorY + appendValueRow(children, x, cursorY, w, T.response, view.response)
  cursorY = cursorY + appendValueRow(children, x, cursorY, w, T.stops, view.stops)
  cursorY = cursorY + 6

  cursorY = cursorY + appendSection(children, x, cursorY, w, T.changes, view.actions)
  appendSection(children, x, cursorY, w, T.why, view.whys)
end

function M.onReload()
  if ui.applying then return false end
  ui.snapshot = nil
  -- Ask again, e.g. after a firmware update, and read the flights again
  ui.unsupported = false
  queueHistoryRead()
  render()
  return false
end

function M.onStar(ctx)
  if ui.applying or captureState() == "reading" then return false end
  ensureDeps()
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not ConfirmDialog or not ui.text then return false end
  ConfirmDialog.show({
    title = ui.text.pageTitle,
    message = ui.text.clearPrompt,
    onConfirm = function()
      clear()
    end
  })
  return true
end

function M.onClose()
  ui.generation = ui.generation + 1
  ui.applyGeneration = ui.applyGeneration + 1
  ui.mcu, ui.loadStep, ui.readJob, ui.journalJob, ui.flights, ui.axes = nil, nil, nil, nil, nil, nil
  ui.axesBuilt = nil
  ui.probeOwed, ui.probing, ui.unsupported = false, false, false
  ui.captureState, ui.seenSaved, ui.profileKey = nil, nil, nil
  for axis = AXIS_ROLL, AXIS_YAW do ui.applied[axis] = nil end
  ui.text, ui.i18n = nil, nil
  ui.view = nil
  ui.snapshot, ui.status, ui.reportSave = nil, nil, nil
  ui.applying, ui.readStarted, ui.readTimeout = false, nil, nil
  if Common and type(Common.resetPageState) == "function" then
    -- Drops ui.runtime with this visit's flags; ensureLoaded makes a new one on the next open
    Common.resetPageState(ui)
  else
    ui.loaded = false
    ui.runtime = nil
  end
  Common = nil
  Controls = nil
  MspRuntime = nil
  Profile = nil
  ConfirmDialog = nil
  TuneHistory = nil
  RcTuningApi, PidTuningApi, PidProfileApi, SavePipeline = nil, nil, nil, nil
  StatusApi = nil
  Cache, Armed, ChangeJournal = nil, nil, nil
  t = nil
end

return M
