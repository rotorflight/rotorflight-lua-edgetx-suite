-- Flight Tuning -> Tune Advisor.
--
-- Reads the flight controller's in-flight rate-loop statistics (tasks/msp/api/tune_advisor.lua,
-- firmware src/main/flight/tune_advisor.c) and turns them into concrete changes, one axis at a
-- time: what was measured, which setting to change (named by the page it lives on, in the units
-- that page shows), and why. The firmware only measures; the rules below are the advice, kept
-- here so they can change without a flash. The rules and their wording are the Ethos suite's
-- Tune Advisor page (rotorflight-lua-ethos-suite, app/pages/tune_advisor.lua).
--
-- Rules, per axis:
-- - Feed-forward match (gyro / setpoint at the best delay), judged only when the ratio is
--   consistent. Above FF_HOT the heli outruns the stick: lower F and scale the rate curve up by
--   the same factor, which keeps the stick feel. Below FF_LOW, the reverse. One step is capped
--   at FF_STEP_MAX so the pilot flies and re-checks rather than jumping. The curve can only be
--   scaled exactly for Actual, Quick and Rotorflight rates; for the others the page gives a
--   percentage. An axis with F = 0 (often the tail) gets no F advice: its PID gains set the
--   response.
-- - Full stick (roll and pitch): cyclic saturated and the rate reached well below the rate
--   asked, so the rate is suggested at what the heli reaches.
-- - Polar cyclic (roll and pitch): the rate lines and the full-stick rule use the Pitch rates
--   and name the Rates page's Cyclic row, as the flight controller does.
-- - |Collective| spread is shown as a fact, last, when there is room.
-- - Stick releases: the rebound after a stop. I-term pushing back points at a lower I-term
--   relax cut-off; with F still off, F comes first; otherwise the controller is barely braking,
--   so more P (or B).
--
-- RC tuning is read after the first advisor reply, when the active rate profile changes and
-- on Reload. It is never sent on a pass that polls and is deferred after a build like the poll.
-- Clear (the header's star button) resets the statistics on the flight controller; they also
-- reset at the next arming when the tune changed since the last arming.

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
local TuneAdvisorApi = nil
local RcTuningApi = nil
local Profile = nil
local ConfirmDialog = nil
local PidTuningApi = nil
local PidProfileApi = nil
local StatusApi = nil
local SavePipeline = nil
local Cache = nil
local Armed = nil
local ChangeJournal = nil
local t = nil

local AXIS_ROLL, AXIS_PITCH, AXIS_YAW = 1, 2, 3

local REFRESH_INTERVAL_SECONDS = 2

-- Feed-forward match
local FF_MIN_COUNT = 1000       -- 10 s of usable 40-200 deg/s stick
local FF_MIN_CORR = 0.85
local FF_HOT = 1.15
local FF_LOW = 0.85
local FF_STEP_MAX = 0.2         -- change F by at most 20% per step
local GAIN_MAX = 1000           -- firmware PID_GAIN_MAX, the limit for P and F alike

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
-- scale, in the decimals its formatValue gives that scale, and the raw range its cell takes
-- (RATE_TABLES in app/pages/flight_tuning/rates/page.lua). A suggestion stays inside that range.
local RATE_DISPLAY = {
  [RATE_TYPE_ACTUAL] = { rcRate = { mult = 10, scale = 1, min = 1, max = 100 }, srate = { mult = 10, scale = 1, min = 0, max = 100 } },
  [RATE_TYPE_QUICK] = { rcRate = { mult = 1, scale = 100, min = 1, max = 255 }, srate = { mult = 10, scale = 1, min = 0, max = 100 } },
  [RATE_TYPE_ROTORFLIGHT] = { rcRate = { mult = 5, scale = 1, min = 2, max = 200 } },
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
local CUTOFF_STEP = 0.8         -- lower cut-off = more relax, less bounce-back
local CUTOFF_MIN = 1

local MAX_ACTIONS = 3
local MAX_WHYS = 3
local PAGE_ID = "flight_tuning_tune_advisor"

-- A change is written as the path a pilot follows to it: page > row > column, or with the
-- menu in front for a page under Advanced. The names are the ones those pages show.
local PATH_FMT = "%s > %s > %s:  %s -> %s"
local ADVANCED_PATH_FMT = "%s > %s > %s > %s:  %s -> %s"

local ui = {
  loaded = false,
  generation = 0,
  selected = AXIS_ROLL,
  pending = false,
  rcTuning = nil,
  rcTuningPending = false,
  rcTuningSignature = nil,
  rcTuningProfile = nil,
  drawnProfile = nil,
  unsupported = false,      -- the flight controller refused the command: no polling until Reload
  lastPoll = 0,
  lastData = nil,
  lastSignature = nil,
  text = nil,
  view = nil,
  snapshot = nil,
  applying = false,
  applyGeneration = 0,
  status = nil,
  reportSave = nil,
  runtime = {
    requestRebuild = nil,
    builtThisPass = false,
    deferredLastPass = false
  }
}

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
  if not TuneAdvisorApi then TuneAdvisorApi = loadModule("tasks/msp/api/tune_advisor.lua") end
  if not RcTuningApi then RcTuningApi = loadModule("tasks/msp/api/rc_tuning.lua") end
  if not Profile then Profile = loadModule("lib/profile.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not t then t = Common and Common.pageT("flight_tuning_tune_advisor") or nil end
end

local function getLiveProfile()
  return Profile and Profile.getActiveRateProfile(1) or 1
end

local function buildSessionSignature()
  return tostring(getLiveProfile())
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
  if type(ui.runtime.requestRebuild) == "function" then
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
    dataFmt = pageText(i18n, "data_fmt", "%dm %02ds, %s"),
    collecting = pageText(i18n, "collecting", "collecting"),
    paused = pageText(i18n, "paused", "paused"),
    unsupported = pageText(i18n, "unsupported", "Needs newer firmware"),
    clearPrompt = pageText(i18n, "clear_prompt", "Clear the collected flight data?"),
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

    actFlyRoll = pageText(i18n, "act_fly_roll", "Fly rolls in rate mode, centre the stick after each"),
    actFlyPitch = pageText(i18n, "act_fly_pitch", "Fly flips in rate mode, centre the stick after each"),
    actFlyYaw = pageText(i18n, "act_fly_yaw", "Fly pirouettes in rate mode, centre the stick after each"),
    actRatePctUpFmt = pageText(i18n, "act_rate_pct_up_fmt", "%s > %s: all rates about %d%% higher"),
    actRatePctDownFmt = pageText(i18n, "act_rate_pct_down_fmt", "%s > %s: all rates about %d%% lower"),
    actNone = pageText(i18n, "act_none", "No change suggested"),

    whyMore = pageText(i18n, "why_more", "Data builds up while you fly in rate mode."),
    whyUneven = pageText(i18n, "why_uneven", "The response varies too much to judge. Common in 3D."),
    whyFast = pageText(i18n, "why_fast", "The heli turns faster than the stick asks for."),
    whySlow = pageText(i18n, "why_slow", "The heli turns slower than the stick asks for."),
    whyKeepFeel = pageText(i18n, "why_keep_feel", "Changing FF and the rates together keeps the stick feel."),
    whyNoF = pageText(i18n, "why_no_f", "This axis has no FF, so its PID gains set the response."),
    whyFullFmt = pageText(i18n, "why_full_fmt", "Full stick asks %d deg/s but the heli tops out at %d."),
    whyCollHighFmt = pageText(i18n, "why_coll_high_fmt", "It turns %d%% faster at high collective than at low."),
    whyCollLowFmt = pageText(i18n, "why_coll_low_fmt", "It turns %d%% faster at low collective than at high."),
    whyRelax = pageText(i18n, "why_relax", "After a stop, the I-term pushes the heli back."),
    whyFixFFmt = pageText(i18n, "why_fix_f_fmt", "Stops bounce back %d%%. Fix FF first, then check again."),
    whyBrakeFmt = pageText(i18n, "why_brake_fmt", "Stops bounce back %d%%. More P brakes them (or add B)."),
    whyOk = pageText(i18n, "why_ok", "The heli answers the stick as asked."),
    saveQuestion = pageText(i18n, "save_question", "Write these changes?"),
    reading = pageText(i18n, "reading", "Reading current settings..."),
    readFailed = pageText(i18n, "read_failed", "Could not read the current settings"),
    armed = "@i18n(app.model_armed_save_blocked)@",
    disconnected = pageText(i18n, "save_disconnected", "Connect the flight controller first."),
    noBoard = pageText(i18n, "save_no_board", "The flight controller ID is not known."),
    busy = pageText(i18n, "save_busy", "An apply is already running."),
    noChanges = pageText(i18n, "save_no_changes", "There are no writable changes for this axis."),
    noSnapshot = pageText(i18n, "save_no_snapshot", "Confirm the changes before saving."),
    changed = pageText(i18n, "save_changed", "The settings changed since the advice was worked out. Nothing was written."),
    range = pageText(i18n, "save_range", "A suggested value is out of range. Nothing was written."),
    startFailed = pageText(i18n, "save_start_failed", "Could not start the save: %s"),
    saved = pageText(i18n, "save_done", "Saved: %d change(s) written and read back."),
    differs = pageText(i18n, "save_differs", "Saved, but the read-back differs: %s"),
    notStored = pageText(i18n, "save_not_stored",
      "Saving failed. The changes are active until the flight controller restarts, then undone."),
    writeFailed = pageText(i18n, "save_write_failed",
      "Writing failed. Nothing was saved: restart the flight controller to undo any part already sent."),
    profileMoved = pageText(i18n, "save_profile_moved", "The profile changed during the save. Check both profiles."),
    unverified = pageText(i18n, "save_unverified", "Saved, but the settings could not be read back."),
    journalFailed = pageText(i18n, "journal_failed", "The change journal could not be written."),
    applied = pageText(i18n, "applied", "Applied. Fly again to check the new settings."),

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

local function round(v)
  return math.floor(v + 0.5)
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
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

-- Suggests scaling the rate curve by k (e.g. 1.25 = 25% faster everywhere)
local function rateActions(T, rates, k, act, setting)
  local roles = LINEAR_ROLES[rates.ratesType]
  if not roles then
    local pct = round(math.abs(k - 1) * 100)
    act(string.format(k > 1 and T.actRatePctUpFmt or T.actRatePctDownFmt, T.ratesPage, rates.row, pct))
    return
  end
  for _, role in ipairs(roles) do
    local raw = (role == "rcRate") and rates.rcRate or rates.sRate
    local range = RATE_DISPLAY[rates.ratesType][role]
    local newRaw = clamp(round(raw * k), range.min, range.max)
    local field = (role == "rcRate" and "rcRates_" or "rates_") .. rates.axis
    setting(string.format(PATH_FMT, T.ratesPage, rates.row, T.rateColumns[rates.ratesType][role],
      rateText(raw, rates.ratesType, role), rateText(newRaw, rates.ratesType, role)), field, "rates", raw, newRaw, "rate")
  end
end

-- How many lines rateActions() adds for this rates_type
local function rateActionCount(rates)
  local roles = LINEAR_ROLES[rates.ratesType]
  return roles and #roles or 1
end

local function matchesPolarRates(a, axis)
  local record = ui.rcTuning
  if not record or record.cyclic_polarity ~= 1 or record.rates_type ~= a.ratesType then return false end
  -- Polar and rates belong to the active rate profile. Reject mismatched rates from another
  -- profile when its switch has not been seen yet.
  if axis == AXIS_ROLL then return record.rcRates_1 == a.rcRate and record.rates_1 == a.sRate end
  if axis == AXIS_PITCH then return record.rcRates_2 == a.rcRate and record.rates_2 == a.sRate end
  return false
end

-- Fills actions/whys (cleared by the caller) for one axis; returns the Response and Stops
-- values.
--
-- A change and its reason go in together or not at all, so a reason never shows for a change
-- that was left out: a later change first checks room(). The first change (fly more, F with its
-- rates, or full-stick rates) always fits. The reasons for changes stay within MAX_WHYS; only
-- the closing |collective| fact can be cut.
local function advise(T, a, axis, actions, whys, changes)
  local rates = { ratesType = a.ratesType, rcRate = a.rcRate, sRate = a.sRate, row = T.ratesAxis[axis], axis = axis }
  if matchesPolarRates(a, axis) then
    local record = ui.rcTuning
    rates = { ratesType = record.rates_type, rcRate = record.rcRates_2, sRate = record.rates_2, row = T.ratesCyclic, axis = 2 }
  end
  local function room(n) return #actions + n <= MAX_ACTIONS end
  local function act(s) if #actions < MAX_ACTIONS then actions[#actions + 1] = s end end
  local function why(s) if #whys < MAX_WHYS then whys[#whys + 1] = s end end
  local function setting(text, field, msg, from, to, profileKind)
    if not room(1) then return end
    act(text)
    if from ~= to then
      changes[#changes + 1] = {
        key = field, field = field, msg = msg, from = from, to = to, text = text, profileKind = profileKind
      }
    end
  end
  local pidPrefix = "pid_" .. (axis - 1) .. "_"

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
    if a.F > 0 then
      local newF = clamp(round(a.F * clamp(1 / g, 1 - FF_STEP_MAX, 1 + FF_STEP_MAX)), 1, GAIN_MAX)
      local text = string.format(PATH_FMT, T.pidsPage, T.pidsAxis[axis], T.pidsF, a.F, newF)
      local roles = LINEAR_ROLES[rates.ratesType]
      local fIndex
      if roles then
        local before = #changes
        setting(text, pidPrefix .. "F", "tuning", a.F, newF, "pid")
        if #changes > before then fIndex = #changes end
      else
        act(text)
      end
      -- Keep the stick feel: F x rate is what the pilot feels
      local ratesBefore = #changes
      rateActions(T, rates, a.F / newF, act, setting)
      if fIndex and #changes - ratesBefore < #roles then
        for i = #changes, ratesBefore + 1, -1 do changes[i] = nil end
        table.remove(changes, fIndex)
      end
      why(hot and T.whyFast or T.whySlow)
      why(T.whyKeepFeel)
    else
      why(T.whyNoF)
    end
  else
    response = T.respOk
    local asked = maxRateAsked(rates)
    if axis ~= AXIS_YAW and asked and a.fullCount >= FULL_MIN_COUNT
        and a.fullSatCount >= FULL_SAT_SHARE * a.fullCount
        and a.fullMaxRate < FULL_REACH * asked and room(rateActionCount(rates)) then
      rateActions(T, rates, a.fullMaxRate / asked, act, setting)
      why(string.format(T.whyFullFmt, asked, a.fullMaxRate))
    end
  end

  -- Stops: rebound after a release
  local stops
  if a.releases < STOPS_MIN then
    stops = string.format(T.stopsMoreFmt, a.releases, STOPS_MIN)
  else
    local rebound = round(a.meanRebound * 100)
    stops = string.format(T.stopsValueFmt, rebound)
    if a.meanRebound >= REBOUND_BAD then
      -- No room for the cutoff only after F and two rate lines; F is off then, so the next
      -- branch says to fix F first.
      if a.meanIterm >= ITERM_PUSH and a.relaxCutoff > CUTOFF_MIN and room(1) then
        local cutoff = clamp(round(a.relaxCutoff * CUTOFF_STEP), CUTOFF_MIN, a.relaxCutoff - 1)
        setting(string.format(ADVANCED_PATH_FMT, T.advancedMenu, T.controllerPage, T.cutoff,
          T.controllerAxis[axis], a.relaxCutoff, cutoff),
          "iterm_relax_cutoff_" .. (axis - 1), "profile", a.relaxCutoff, cutoff, "pid")
        why(T.whyRelax)
      elseif ffOff(a) and a.F > 0 then
        why(string.format(T.whyFixFFmt, rebound))
      elseif room(1) then
        local newP = clamp(round(a.P * P_STEP), a.P + 1, GAIN_MAX)
        setting(string.format(PATH_FMT, T.pidsPage, T.pidsAxis[axis], T.pidsP, a.P, newP),
          pidPrefix .. "P", "tuning", a.P, newP, "pid")
        why(string.format(T.whyBrakeFmt, rebound))
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
  return { data = "-", response = "-", stops = "-", actions = {}, whys = {}, changes = {} }
end

local function getSession()
  return _G.rfsuite and _G.rfsuite.session or nil
end

local function appliedAxes()
  local session = getSession()
  if not session or not session.mcu_id then return nil end
  local marks = session.tuneAdvisorApplied
  if not marks or marks.mcu ~= session.mcu_id then
    marks = { mcu = session.mcu_id }
    session.tuneAdvisorApplied = marks
  end
  return marks
end

local function copy(record)
  local out = {}
  for key, value in pairs(record) do out[key] = value end
  return out
end

local function showUnsupported()
  local view = newView()
  view.data = ui.text and ui.text.unsupported or "-"
  ui.view = view
  requestRebuild()
end

local function render()
  local data = ui.lastData
  local T = ui.text
  if not data or not T or data.axis ~= ui.selected then return end

  local view = newView()
  view.data = string.format(T.dataFmt, math.floor(data.seconds / 60), data.seconds % 60,
    data.collecting and T.collecting or T.paused)
  local a, axis = data.a, ui.selected
  view.tune = {
    P = a.P, F = a.F, B = a.B, relaxCutoff = a.relaxCutoff,
    ratesType = a.ratesType, rcRate = a.rcRate, sRate = a.sRate,
    polar = matchesPolarRates(a, axis),
    pidProfile = Profile and Profile.getActivePidProfile(1) or 1,
    rateProfile = getLiveProfile(), axis = axis, seconds = data.seconds,
    mcu = getSession() and getSession().mcu_id
  }
  if view.tune.polar then
    for _, field in ipairs({ "cyclic_polarity", "rates_type", "rcRates_2", "rates_2" }) do
      view.tune[field] = ui.rcTuning[field]
    end
  end
  view.response, view.stops = advise(T, a, axis, view.actions, view.whys, view.changes)
  local marks = appliedAxes()
  if marks and marks[axis] then
    if data.seconds ~= marks[axis] then
      marks[axis] = nil
    else
      view.actions, view.whys, view.changes = { T.applied }, {}, {}
    end
  end
  ui.view = view
  requestRebuild()
end

local function apply(data)
  -- Skip the rebuild when nothing new was collected
  local a = data.a
  local signature = ((data.seconds * 2 + (data.collecting and 1 or 0)) * 4 + data.axis) * 31
    + a.ffCount + a.releases + a.fullCount + a.F + a.P + a.rcRate + a.sRate + a.ratesType + a.relaxCutoff
  if signature == ui.lastSignature then return end
  ui.lastSignature = signature
  ui.lastData = data
  render()
end

local function getQueue()
  if not MspRuntime or type(MspRuntime.getState) ~= "function" then return nil end
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then return nil end
  return queue
end

local function readRcTuning()
  if ui.rcTuningPending then return false end
  local api = RcTuningApi
  local queue = getQueue()
  if not api or not queue then return false end

  local generation = ui.generation
  local profile = getLiveProfile()
  ui.rcTuningPending = true
  queue:add({
    command = api.command,
    simulatorResponse = api.simulatorResponse,
    isWrite = false,
    processReply = function(_, buf)
      if generation ~= ui.generation then return end
      ui.rcTuningPending = false
      local record = api.parse(buf)
      if type(record) ~= "table" then return end
      local data = ui.lastData
      local shown = data and data.axis == ui.selected
      local matchedBefore = shown and matchesPolarRates(data.a, data.axis)
      local previous = ui.rcTuning
      ui.rcTuning = record
      ui.rcTuningProfile = profile
      local matchedAfter = shown and matchesPolarRates(data.a, data.axis)
      local pitchRatesChanged = matchedBefore and matchedAfter
        and (previous.rates_type ~= record.rates_type or previous.rcRates_2 ~= record.rcRates_2
          or previous.rates_2 ~= record.rates_2)
      if matchedBefore ~= matchedAfter or pitchRatesChanged then render() end
      if ui.rcTuningProfile ~= ui.drawnProfile then requestRebuild() end
    end,
    errorHandler = function()
      if generation ~= ui.generation then return end
      ui.rcTuningPending = false
      ui.rcTuningProfile = profile
      if ui.rcTuningProfile ~= ui.drawnProfile then requestRebuild() end
    end
  })
  return true
end

local poll

poll = function()
  if not ui.loaded or ui.pending or ui.unsupported or ui.applying then return end
  local api = TuneAdvisorApi
  local queue = getQueue()
  if not api or not queue then return end

  local generation = ui.generation
  local axis = ui.selected
  ui.pending = true
  queue:add({
    command = api.command,
    payload = { axis - 1 },
    isWrite = false,
    -- The flight controller's error reply is the only answer that says the firmware lacks the
    -- command, and only this field lets it reach processReply instead of being retried.
    completeOnErrorReplyAttempt = 1,
    simulatorResponse = api.simulatorResponseFor(axis),
    processReply = function(_, buf)
      if generation ~= ui.generation then return end
      ui.pending = false
      local data = api.parse(buf)
      if not data then
        -- A refusal: say so once and stop asking until Reload.
        ui.unsupported = true
        ui.lastSignature = nil
        ui.lastData = nil
        showUnsupported()
        return
      end
      if data.axis ~= ui.selected then
        poll()      -- the axis changed while this request was out
        return
      end
      apply(data)
    end,
    -- No answer at all is the link, not the firmware: keep what is on screen and let the next
    -- poll try again.
    errorHandler = function()
      if generation ~= ui.generation then return end
      ui.pending = false
    end
  })
end

local function onCleared()
  local marks = appliedAxes()
  if marks then
    for axis = AXIS_ROLL, AXIS_YAW do marks[axis] = nil end
  end
  ui.lastSignature = nil
  poll()
end

local function clear()
  local api = TuneAdvisorApi
  local queue = getQueue()
  if not api or not queue then return end
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
        ui.lastSignature = nil
        ui.lastData = nil
        showUnsupported()
        return
      end
      onCleared()
    end
  })
end

local function ensureLoaded(i18n)
  if ui.loaded then return end
  ui.generation = ui.generation + 1
  ui.loaded = true
  ui.selected = AXIS_ROLL
  ui.pending = false
  ui.unsupported = false
  ui.lastPoll = 0
  ui.rcTuning = nil
  ui.rcTuningPending = false
  ui.rcTuningSignature = nil
  ui.rcTuningProfile = nil
  ui.drawnProfile = nil
  ui.lastData = nil
  ui.lastSignature = nil
  ui.text = loadTexts(i18n)
  ui.view = newView()
end

local function onAxis(value)
  if ui.applying then return end
  ui.selected = tonumber(value) or AXIS_ROLL
  -- Each axis is its own request: fetch the new one now
  ui.lastSignature = nil
  ui.lastPoll = nowSeconds()
  poll()
end

function M.getHeaderActions()
  return { reload = not ui.applying, save = M.canSave(), help = true, star = not ui.applying }
end

function M.canSave()
  local T = ui.text
  if not T then return false, pageText(nil, "read_failed", "Could not read the current settings") end
  local state = MspRuntime and MspRuntime.getState()
  if not state or state.lastConnected ~= true then return false, T.disconnected end
  if state.lastArmed == true or (Armed and Armed.isArmed()) then return false, T.armed end
  local session = getSession()
  if not session or session.mcu_id == nil or tostring(session.mcu_id) == "" then return false, T.noBoard end
  if ui.applying then return false, T.busy end
  local view = ui.view
  if not view or not view.tune or view.tune.axis ~= ui.selected or #view.changes == 0 then return false, T.noChanges end
  return true
end

function M.getSaveConfirm(ctx)
  ui.snapshot = nil
  if not M.canSave() then return nil end
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

-- Nothing here is loaded by the opening/read chain. The RC codec is already needed by the
-- existing polar read; the other modules are needed only after Save has been confirmed.
local function ensureSaveDeps()
  if not StatusApi then StatusApi = loadModule("tasks/msp/api/status.lua") end
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

local function validateTune(snapshot, records)
  local tune, T = snapshot.tune, ui.text
  local session = getSession()
  local state = MspRuntime and MspRuntime.getState()
  if Armed.isArmed() or (state and state.lastArmed == true) then return T.armed end
  if not state or state.lastConnected ~= true or not session or session.mcu_id ~= tune.mcu
      or Profile.getActivePidProfile(1) ~= tune.pidProfile or getLiveProfile() ~= tune.rateProfile then return T.changed end
  local status = records.status
  if status.current_pid_profile_index + 1 ~= tune.pidProfile
      or status.current_control_rate_profile_index + 1 ~= tune.rateProfile then return T.changed end
  local prefix = "pid_" .. (tune.axis - 1) .. "_"
  local tuning, profile, rates = records.tuning, records.profile, records.rates
  if tuning[prefix .. "P"] ~= tune.P or tuning[prefix .. "F"] ~= tune.F or tuning[prefix .. "B"] ~= tune.B
      or profile["iterm_relax_cutoff_" .. (tune.axis - 1)] ~= tune.relaxCutoff
      or rates.rates_type ~= tune.ratesType or rates["rcRates_" .. tune.axis] ~= tune.rcRate
      or rates["rates_" .. tune.axis] ~= tune.sRate then return T.changed end
  if tune.polar then
    if rates.cyclic_polarity ~= 1 or rates.rates_type ~= tune.rates_type
        or rates.rcRates_2 ~= tune.rcRates_2 or rates.rates_2 ~= tune.rates_2 then return T.changed end
  elseif tune.axis ~= AXIS_YAW and rates.cyclic_polarity == 1 then
    return T.changed
  end
  for _, change in ipairs(snapshot.changes) do
    if records[change.msg][change.field] ~= change.from then return T.changed end
    local lo, hi = 0, GAIN_MAX
    if change.msg == "profile" then
      lo, hi = CUTOFF_MIN, 100
    elseif change.msg == "rates" then
      local role = string.match(change.field, "^rcRates_") and "rcRate" or "srate"
      local range = RATE_DISPLAY[tune.ratesType] and RATE_DISPLAY[tune.ratesType][role]
      if not range then return T.range end
      lo, hi = range.min, range.max
    end
    local value = change.to
    if type(value) ~= "number" or value ~= math.floor(value) or value < lo or value > hi then return T.range end
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
  local snapshot = ui.snapshot
  ui.snapshot = nil
  ui.reportSave = ctx and ctx.reportSave
  if not snapshot then
    local message = ui.text and ui.text.noSnapshot or pageText(nil, "save_no_snapshot", "Confirm the changes before saving.")
    finishApply(false, message)
    return false
  end
  ui.applyGeneration = ui.applyGeneration + 1
  ui.applying, ui.status = true, ui.text.reading
  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or ui.runtime.requestRebuild
  requestRebuild()
  if not ensureSaveDeps() then finishApply(false, ui.text.readFailed); return false end
  local applyGeneration = ui.applyGeneration
  local journalFailed = false
  local function markApplied()
    local active = applyGeneration == ui.applyGeneration and ui.applying
    local marks = appliedAxes()
    if marks and marks.mcu == snapshot.tune.mcu then
      local data = active and ui.lastData
      marks[snapshot.tune.axis] = data and data.axis == snapshot.tune.axis and data.seconds or snapshot.tune.seconds
      if snapshot.tune.polar then
        for _, change in ipairs(snapshot.changes) do
          if change.msg == "rates" then
            local seconds = marks[snapshot.tune.axis]
            marks[AXIS_ROLL], marks[AXIS_PITCH] = seconds, seconds
            break
          end
        end
      end
    end
  end
  local function readBack(records)
    if applyGeneration ~= ui.applyGeneration or not ui.applying then return end
    local mismatch
    local session = getSession()
    local status = records and records.status
    local sameProfile = status and session and session.mcu_id == snapshot.tune.mcu
      and status.current_pid_profile_index + 1 == snapshot.tune.pidProfile
      and status.current_control_rate_profile_index + 1 == snapshot.tune.rateProfile
      and Profile.getActivePidProfile(1) == snapshot.tune.pidProfile and getLiveProfile() == snapshot.tune.rateProfile
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
        if result.status ~= "done" then markApplied() end
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
        ui.status = ui.text.reading
        requestRebuild()
        readSettings(applyGeneration, readBack)
      end
    })
    if not started then finishApply(false, string.format(ui.text.startFailed, tostring(reason))) end
  end)
  return false
end

-- Polling lives here and never on the pass that built the page: a build this pass defers the
-- poll to the next one, at most once in a row.
-- RC tuning is read after the first advisor reply, on a profile change and on Reload.
-- It is never sent on a pass that polls and is deferred after a build like the poll.
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

  local now = nowSeconds()
  if not ui.pending and not ui.unsupported
      and (ui.lastPoll == 0 or now - ui.lastPoll >= REFRESH_INTERVAL_SECONDS) then
    ui.lastPoll = now
    poll()
  elseif ui.lastData ~= nil and not ui.unsupported and not ui.rcTuningPending then
    local signature = buildSessionSignature()
    if signature ~= ui.rcTuningSignature and readRcTuning() then ui.rcTuningSignature = signature end
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

  local profile = ui.rcTuningProfile or getLiveProfile()
  local headingTitle = string.format("%s #%d", T.pageTitle, profile)
  Controls.appendStaticSectionHeader(children, x, cursorY, w, headingTitle)
  cursorY = cursorY + (Controls.STATIC_SECTION_H or 38)
  ui.drawnProfile = profile

  if ui.status then cursorY = cursorY + appendText(children, x + 10, cursorY, w - 20, ui.status) end

  local axisOptions = {
    { label = T.axisNames[AXIS_ROLL], value = AXIS_ROLL },
    { label = T.axisNames[AXIS_PITCH], value = AXIS_PITCH },
    { label = T.axisNames[AXIS_YAW], value = AXIS_YAW }
  }
  cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w, T.axis, axisOptions,
    ui.selected, onAxis)

  cursorY = cursorY + appendValueRow(children, x, cursorY, w, T.data, view.data)
  cursorY = cursorY + appendValueRow(children, x, cursorY, w, T.response, view.response)
  cursorY = cursorY + appendValueRow(children, x, cursorY, w, T.stops, view.stops)
  cursorY = cursorY + 6

  cursorY = cursorY + appendSection(children, x, cursorY, w, T.changes, view.actions)
  appendSection(children, x, cursorY, w, T.why, view.whys)
end

function M.onReload()
  if ui.applying then return false end
  ui.snapshot = nil
  -- Ask again, e.g. after a firmware update
  ui.rcTuningSignature = nil
  ui.unsupported = false
  ui.lastSignature = nil
  ui.lastPoll = nowSeconds()
  poll()
  return false
end

function M.onStar(ctx)
  if ui.applying then return false end
  ensureDeps()
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
  ui.loaded = false
  ui.generation = ui.generation + 1
  ui.applyGeneration = ui.applyGeneration + 1
  ui.pending = false
  ui.rcTuning = nil
  ui.rcTuningPending = false
  ui.rcTuningSignature = nil
  ui.rcTuningProfile = nil
  ui.drawnProfile = nil
  ui.unsupported = false
  ui.lastData = nil
  ui.lastSignature = nil
  ui.text = nil
  ui.view = nil
  ui.snapshot, ui.status, ui.reportSave = nil, nil, nil
  ui.applying, ui.readStarted, ui.readTimeout = false, nil, nil
  ui.runtime.requestRebuild = nil
  ui.runtime.builtThisPass = false
  ui.runtime.deferredLastPass = false
  Common = nil
  Controls = nil
  MspRuntime = nil
  TuneAdvisorApi = nil
  RcTuningApi = nil
  Profile = nil
  ConfirmDialog = nil
  PidTuningApi, PidProfileApi, SavePipeline = nil, nil, nil
  StatusApi = nil
  Cache, Armed, ChangeJournal = nil, nil, nil
  t = nil
end

return M
