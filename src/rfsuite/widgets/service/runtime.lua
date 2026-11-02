-- Runtime for the service widget.
--
-- The suite's background work -- the MSP runtime and the event runtime that drives the onconnect
-- chain and the custom telemetry decoder -- only advances while something calls into it. The tool
-- does that while it is open, and the dashboard widget does it from its own passes. A radio that
-- runs neither has no link: no custom sensors, no connect events, no session values.
--
-- This widget is that caller and nothing else. It ticks the same two runtimes the dashboard ticks
-- and draws a small status tile, so a pilot who does not want the dashboard can still have the
-- suite's background service on the model. On a model that carries the dashboard as well, the
-- dashboard does that work and this widget stands down; only its tile is still drawn.

local Runtime = {}

-- The runtimes are advanced at most this often, and the tile is repainted at most this often. The
-- tick interval is the dashboard's; the paint interval is longer because a status line does not
-- change faster than that and every rebuild costs a full LVGL tree.
local TICK_INTERVAL_SECONDS = 0.1
local UI_INTERVAL_SECONDS = 0.5

local requireModule = (_G.rfsuite and _G.rfsuite.require)
if not requireModule then
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local rChunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/require.lua", mode)
  if rChunk then
    requireModule = rChunk()
  end
end
requireModule = requireModule or function(path)
  local fullPath = string.sub(path, 1, 1) == "/" and path or ("/SCRIPTS/TOOLS/rfsuite-core/" .. path)
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(fullPath, mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local Log = requireModule("lib/log.lua")
local MspRuntime = requireModule("tasks/msp/runtime.lua")
local EventsRuntime = requireModule("tasks/events/runtime.lua")
local I18nModule = requireModule("i18n/init.lua")
local PreferencesModule = requireModule("lib/preferences.lua")
local ModelPreferences = requireModule("lib/model_preferences.lua")
local LogSink = requireModule("lib/log_sink.lua")
if LogSink and type(LogSink.configure) == "function" then
  -- This state's ring and this state's files. The tool holds a ring of its own and names its
  -- own pair, so neither state appends to a file the other one has open.
  LogSink.configure("dashboard")
end

-- Tasks read their settings from rfsuite.preferences, and that table is per Lua state: the tool
-- publishes it in the script state and the dashboard widget in the widget state. Without a
-- publisher here, a task that asks whether a feature is switched on gets nothing and behaves as
-- if it were off -- in exactly the arrangement this widget exists for. Looked at on an interval
-- rather than once, so a setting changed in the tool takes effect without a restart, and never
-- while armed. What the interval costs when nothing has changed is three fstats: see
-- refreshPreferences below.
local PREFERENCES_INTERVAL_SECONDS = 30

local function nowSeconds()
  if type(getTime) == "function" then
    local ok, value = pcall(getTime)
    if ok and type(value) == "number" then return value / 100 end
  end
  return 0
end

local function log(msg, level)
  if Log and type(Log.emit) == "function" then
    Log.emit("rfsuite.service", msg, level or "debug")
  end
end

local function session()
  if type(_G) ~= "table" or type(_G.rfsuite) ~= "table" then return nil end
  return _G.rfsuite.session
end

-- How often the usage line below is written, in seconds.
local USAGE_REPORT_INTERVAL = 5

--- Report how much of the per-pass instruction ceiling this widget is consuming.
--
-- The same instrument widgets/dashboard/runtime.lua carries, in the widget that isolates the
-- background half: this one draws a status tile and otherwise does nothing but tick the two
-- runtimes, so the figure it reports is the cost of the background work alone -- no scene
-- build and no reactive sweep of a theme is mixed into it.
--
-- EdgeTX gives the widget Lua state a fixed instruction budget per pass and stores the share
-- consumed once the call has returned; getUsage() hands that value back, so what is readable
-- here is the PREVIOUS pass's figure. It is held in a uint8_t, so a pass past 255 % wraps and
-- reads low -- which is why this reports a stream of figures rather than a single worst one.
--
-- Three figures, because each of them alone misleads: the current sample says what a settled
-- pass costs, the peak over the interval says how close the worst pass in that stretch came,
-- and the peak since load keeps the worst pass of a session from scrolling out of a card log.
--
-- Nothing here tests the debug level. Log.emitf does that, and below "trace" the line is
-- neither printed, nor put in the session ring, nor written to the card.
local function traceInstructionUsage(self)
  if type(getUsage) ~= "function" then return end
  local ok, percent = pcall(getUsage)
  if not ok then return end
  percent = tonumber(percent)
  if percent == nil then return end

  if percent > self._usageWindowPeak then self._usageWindowPeak = percent end
  if percent > self._usagePeak then self._usagePeak = percent end

  local now = nowSeconds()
  if now < self._usageReportAt then return end
  self._usageReportAt = now + USAGE_REPORT_INTERVAL

  if Log and type(Log.emitf) == "function" then
    Log.emitf("rfsuite.service", "trace",
      "instruction budget %d%% now, %d%% peak/%ds, %d%% peak since load",
      percent, self._usageWindowPeak, USAGE_REPORT_INTERVAL, self._usagePeak)
  end

  self._usageWindowPeak = -1
end

local function isArmed()
  if not MspRuntime or type(MspRuntime.getState) ~= "function" then return false end
  local runtimeState = MspRuntime.getState()
  return type(runtimeState) == "table" and runtimeState.lastArmed == true
end

-- What an fstat that ANSWERED, on a file that is not there, is recorded as. It is deliberately
-- a value and not nil: on a card where the pilot has never saved a setting there is no
-- preferences.lua at all -- lib/preferences.lua writes it only from save() -- and that is a
-- state, not a failure to look. Recording it as nil would mean re-reading a file that is known
-- not to exist every 30 s for as long as the pilot leaves the settings alone, which on this
-- widget is the default install.
local NO_PREFERENCES_FILE = "absent"

--- What the settings file looks like from the outside, as a string, or nil where that could
--- not be established.
--
-- The two are not the same answer. A file nobody could LOOK AT is not a file that has not
-- changed, and the caller treats those differently: no stamp at all means the parse happens
-- exactly as it did before this gate existed. Only the absence of `fstat` itself answers nil,
-- because that is the one case in which nothing here can tell the two apart.
--
-- `fstat` returns the modification time as a TABLE -- year, mon, day, hour, min, sec -- so
-- tostring() on it is a table address that differs on every call. The fields are what identify
-- the file, so the fields are what the stamp is built from, and the size carries the rest:
-- FAT stores seconds in two-second steps, which bounds how close together two writes can be
-- and still be told apart.
local function preferencesStamp()
  if type(fstat) ~= "function" then return nil end
  if not PreferencesModule or type(PreferencesModule.getPath) ~= "function" then return nil end

  local okPath, path = pcall(PreferencesModule.getPath)
  if not okPath or type(path) ~= "string" then return nil end

  local ok, info = pcall(fstat, path)
  if not ok then return nil end
  if type(info) ~= "table" then return NO_PREFERENCES_FILE end

  local t = info.time
  if type(t) ~= "table" then
    return tostring(info.size) .. ":" .. tostring(t)
  end
  return string.format("%s:%s-%s-%s.%s.%s.%s",
    tostring(info.size), tostring(t.year), tostring(t.mon), tostring(t.day),
    tostring(t.hour), tostring(t.min), tostring(t.sec))
end

--- Has the rotating counter beside the settings file moved since the last look?
--
-- lib/preferences.lua's save() bumps it on every write and it rotates 1..32, so it moves on
-- every save whatever the clock and whatever the new file's size -- which is the case a stamp
-- alone cannot see. It is inspected and never consumed, so every reader observes the same
-- change. Answers the sizes it read as well, so the caller only adopts them once the reload
-- has actually happened.
local function reloadSequences()
  if type(fstat) ~= "function" then return nil end
  local paths = ModelPreferences and type(ModelPreferences.reloadRequestPaths) == "function"
    and ModelPreferences.reloadRequestPaths() or nil
  if type(paths) ~= "table" then return nil end

  local seqs = {}
  for i = 1, #paths do
    local ok, info = pcall(fstat, paths[i])
    seqs[paths[i]] = (ok and type(info) == "table" and info.size) or 0
  end
  return seqs
end

--- Re-read the settings, but only when they can be shown to have moved.
--
-- Answers true when the store was actually parsed, so the caller can leave the rest of the
-- pass to the next one.
--
-- The 30 s tick is what it always was; what it costs when nothing has changed is now three
-- fstats instead of a read of the whole file, a compile of it and a merge of every schema
-- section -- lib/config_store.lua's load() holds no memo, so that is the price of every call.
-- Two signals rather than one, and they are the two the dashboard widget already watches: the
-- file's own stamp, and the counter every writer bumps. One fstat goes to the settings file
-- and one to each reload.req the user roots can hold.
--
-- Where nothing can be read at all -- no fstat -- the parse happens as it did before. A gate
-- that skipped it there would be skipping it blind, and the radio that cannot answer is
-- exactly the radio nobody can measure. This is a weaker default than the dashboard's, which
-- reloads only on a positive signal and so treats "could not measure" as "nothing changed";
-- the difference is deliberate, because the dashboard has always worked that way while this
-- widget has always re-read unconditionally, and a cost saving is not worth taking a setting
-- away from a radio that cannot be measured.
local function refreshPreferences(self, force)
  if not PreferencesModule or type(PreferencesModule.load) ~= "function" then return false end

  local now = nowSeconds()
  if not force and (now - (self._lastPreferencesLoad or 0)) < PREFERENCES_INTERVAL_SECONDS then return false end
  if not force and isArmed() then return false end
  self._lastPreferencesLoad = now

  local stamp = preferencesStamp()
  local seqs = reloadSequences()

  if not force and stamp ~= nil and self._lastPreferencesStamp ~= nil then
    local moved = (stamp ~= self._lastPreferencesStamp)
    if not moved and seqs and self._lastReloadSeqs then
      for path, seq in pairs(seqs) do
        if self._lastReloadSeqs[path] ~= seq then
          moved = true
          break
        end
      end
    end
    if not moved then return false end
  end

  local ok, prefs = pcall(PreferencesModule.load)
  if not ok or type(prefs) ~= "table" then
    -- A load that FAILED is not a load that will always fail, and this pcall catches the
    -- firmware's instruction-limit error like any other. Adopting the stamp here would record
    -- a busy pass as a pass that read the new file, and the setting the pilot just changed
    -- would then never be picked up again for the life of this Lua state. So nothing is
    -- adopted and nothing is deferred: the next 30 s tick finds the signals still moved and
    -- tries again, which is what this widget did before the gate existed.
    return false
  end

  self.preferences = prefs
  _G.rfsuite = _G.rfsuite or {}
  _G.rfsuite.preferences = prefs

  self._lastPreferencesStamp = stamp
  self._lastReloadSeqs = seqs
  return true
end

-- lib/precompile.lua while the compile pass after an install holds the connection back, false
-- once there is no such pass -- the same gate as widgets/dashboard/runtime.lua's, because this
-- widget attaches to the MSP runtime on its own and would otherwise start the connection the
-- dashboard is holding back. Either widget alone still drives the pass to its end.
local Compile = nil

local function compileHoldsConnect(self)
  if Compile == false then return false end
  if Compile == nil then
    Compile = false
    local developer = self.preferences and self.preferences.developer
    if developer and developer.precompile == false then return false end
    local Precompile = requireModule("lib/precompile.lua")
    if type(Precompile) ~= "table" or type(Precompile.startIfStale) ~= "function" then return false end
    -- No version to fall back on: the widgets act only on a tree the packager stamped with its
    -- build identity, so a source tree copied by hand never holds the connection back.
    if not Precompile.startIfStale(nil) then
      if not Precompile.isRunning() and _G.rfsuite and type(_G.rfsuite.clearModule) == "function" then
        _G.rfsuite.clearModule("lib/precompile.lua")
      end
      return false
    end
    Compile = Precompile
    log("compile pass after install: connection held until it finishes", "info")
  end
  Compile.stepShared()
  -- Held after the pass too, until the radio is restarted: see the dashboard's gate.
  if Compile.isRunning() or Compile.needsRestart() then return true end
  Compile = false
  return false
end

-- One pass of the background work: the same two calls the dashboard makes, bracketed by the same
-- event context, so tasks that behave differently in a widget see what they expect.
local function tickRuntimes(self)
  traceInstructionUsage(self)

  local now = nowSeconds()
  if self._lastWorkTick == now then return end
  self._lastWorkTick = now

  if (now - (self._lastLogicTick or 0)) < TICK_INTERVAL_SECONDS then return end
  self._lastLogicTick = now

  -- A dashboard widget on the model does all of the work below itself, on screen and off it, in
  -- this same Lua state. While it does, this widget stands down -- the settings, the card log and
  -- the runtimes alike -- and takes over once the dashboard's mark has gone stale: the dashboard
  -- taken off the model, or its script stopped. See Events.markDriving for the threshold.
  if EventsRuntime and type(EventsRuntime.isDriving) == "function"
      and EventsRuntime.isDriving("dashboard-widget") then
    if not self._standingDown then
      self._standingDown = true
      log("the dashboard widget drives the background work: standing down", "debug")
    end
    return
  end
  if self._standingDown then
    self._standingDown = nil
    log("the dashboard widget stopped driving the background work: taking over", "debug")
  end

  -- A pass that re-read the settings ends there, so the work below starts on a fresh
  -- instruction budget instead of behind the parse. The logic tick has already been taken, so
  -- this costs one 0.1 s turn of the background service, and only on a pass in which the
  -- settings actually changed.
  --
  -- widgets/dashboard/runtime.lua defers after its own reload for the same reason and in the
  -- other order: it does the link work first and returns before the theme build, because the
  -- expensive phase there comes AFTER the reload. Here the link work is the only phase there
  -- is, so deferring it is the only way to keep the parse off the pass that carries it.
  if refreshPreferences(self, false) then return end

  -- The card sink for the widget state, written by whichever widget drives the work: here only
  -- while no dashboard does (above).
  if LogSink and type(LogSink.tick) == "function" then
    pcall(LogSink.tick, isArmed())
  end

  if not MspRuntime then return end

  if compileHoldsConnect(self) then return end

  if not self.mspAttached and type(MspRuntime.attach) == "function" then
    MspRuntime.attach("service-widget")
    self.mspAttached = true
    log("service widget attached to the MSP runtime", "info")
  end

  if type(MspRuntime.tick) ~= "function" then return end

  -- Created here when it is missing, as the dashboard does: the model-name restore in the event
  -- runtime runs only in the widget context, and where the MSP runtime finds no transport it
  -- never publishes, so nothing else in this Lua state creates the table to carry the context.
  if type(_G) == "table" then
    _G.rfsuite = _G.rfsuite or {}
    _G.rfsuite.session = _G.rfsuite.session or {}
    _G.rfsuite.session.event_context = "widget"
  end
  local s = session()

  MspRuntime.tick()
  if EventsRuntime and type(EventsRuntime.wakeup) == "function" then
    pcall(EventsRuntime.wakeup)
  end

  -- The wakeup above is what FILLS the queue while the connect chain runs. Without a second
  -- turn here every request it enqueues waits for the next host tick before it is even looked
  -- at, which on a chain of a dozen serial round trips is a dozen ticks of pure waiting.
  if type(MspRuntime.pump) == "function" then
    MspRuntime.pump()
  end

  if s then s.event_context = nil end
end

-- What the tile reports. Three states, in the order a start goes through them: no link, link up
-- with the connect chain still running, and ready.
local function readStatus(self)
  local status = { link = false, tasksDone = true, done = nil, total = nil, craftName = nil }

  if MspRuntime and type(MspRuntime.getState) == "function" then
    local runtimeState = MspRuntime.getState()
    status.link = type(runtimeState) == "table" and runtimeState.lastConnected == true
    -- A refused board gets no connect chain, so the chain's progress cannot say so: without
    -- this the tile would read "Connected" for a board the suite does not talk to.
    if type(runtimeState) == "table" and runtimeState.unsupportedApi == true then
      status.refusedVersion = tostring(runtimeState.refusedApiVersion or "?")
    end
  end

  if EventsRuntime and type(EventsRuntime.isOnconnectActive) == "function" then
    if EventsRuntime.isOnconnectActive() then
      status.tasksDone = false
    end
  end
  if EventsRuntime and type(EventsRuntime.getOnconnectProgress) == "function" then
    local progress = EventsRuntime.getOnconnectProgress()
    if type(progress) == "table" and type(progress.total) == "number" and type(progress.done) == "number" then
      status.done = progress.done
      status.total = progress.total
      if progress.total > 0 and progress.done >= progress.total then
        status.tasksDone = true
      end
    end
  end

  local s = session()
  if s and type(s.modelName) == "string" and s.modelName ~= "" then
    status.craftName = s.modelName
  end

  local t = (self.i18n and type(self.i18n.t) == "function") and self.i18n.t or nil
  local mspErr = (s and s.mspLastError) or (_G.rfsuite and _G.rfsuite.diagnostics and _G.rfsuite.diagnostics.mspLastError)
  local mspErrorKind = (s and s.mspErrorKind) or (_G.rfsuite and _G.rfsuite.diagnostics and _G.rfsuite.diagnostics.mspErrorKind)
  if not status.link then
    status.text = (t and t("widgets.service.waiting_for_link")) or "Waiting for MSP link"
  elseif status.refusedVersion then
    local fmt = (t and t("widgets.service.api_unsupported")) or "MSP API %s not supported"
    status.text = string.format(fmt, status.refusedVersion)
  elseif not status.tasksDone then
    if mspErrorKind == "no_reply" or (mspErr and mspErr ~= "") then
      status.text = (t and t("widgets.service.no_msp_reply")) or "No MSP reply"
    else
      local text = (t and t("widgets.service.loading")) or "Loading data..."
      if status.total and status.total > 0 then
        local currentStep = math.min((status.done or 0) + 1, status.total)
        text = text .. " (" .. tostring(currentStep) .. "/" .. tostring(status.total) .. ")"
      end
      status.text = text
    end
  else
    status.text = (t and t("widgets.service.connected")) or "Connected"
  end

  return status
end

local function buildTile(self, status)
  local w = (self.zone and self.zone.w) or LCD_W or 320
  local h = (self.zone and self.zone.h) or LCD_H or 172
  local t = (self.i18n and type(self.i18n.t) == "function") and self.i18n.t or nil
  local title = (t and t("widgets.service.title")) or "SERVICE"

  -- Everything is placed from the top so the tile degrades on a short zone: the craft name is the
  -- first line to fall off the bottom, and it is the least important of the three.
  local titleY = math.max(2, math.floor(h * 0.08))
  local stateY = titleY + 20
  local craftY = stateY + 26

  local children = {
    {
      type = "rectangle",
      x = 0,
      y = 0,
      w = w,
      h = h,
      color = BLACK,
      filled = true
    },
    {
      type = "label",
      x = 0,
      y = titleY,
      w = w,
      text = title,
      align = CENTER,
      color = COLOR_THEME_DISABLED,
      font = SMLSIZE
    },
    {
      type = "label",
      x = 0,
      y = stateY,
      w = w,
      text = tostring(status.text),
      align = CENTER,
      color = WHITE,
      font = SMLSIZE
    }
  }

  if status.craftName and craftY + 16 <= h then
    children[#children + 1] = {
      type = "label",
      x = 0,
      y = craftY,
      w = w,
      text = status.craftName,
      align = CENTER,
      color = COLOR_THEME_DISABLED,
      font = SMLSIZE
    }
  end

  return children
end

function Runtime.new(zone, options)
  local widget = {
    zone = zone,
    options = options,
    built = false,
    renderKey = nil,
    mspAttached = false,
    _lastWorkTick = nil,
    _lastLogicTick = 0,
    _lastUIRefresh = 0,
    _lastPreferencesLoad = 0,
    _lastPreferencesStamp = nil,
    _lastReloadSeqs = nil,
    _usagePeak = -1,
    _usageWindowPeak = -1,
    _usageReportAt = 0
  }

  refreshPreferences(widget, true)

  if I18nModule and type(I18nModule.new) == "function" then
    local locale = nil
    local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
    local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/system_locale.lua", mode)
    if chunk then
      local ok, localeMod = pcall(chunk)
      if ok and type(localeMod) == "table" and type(localeMod.resolveSystemLanguage) == "function" then
        local okResolve, resolved = pcall(localeMod.resolveSystemLanguage, "en")
        if okResolve and type(resolved) == "string" and resolved ~= "" then
          locale = resolved
        end
      end
    end
    local ok, ctx = pcall(I18nModule.new, locale)
    if ok and type(ctx) == "table" then
      widget.i18n = ctx
    end
  end

  function widget.update(self, newOptions)
    self.options = newOptions
    self.built = false
  end

  -- Called when the widget is not the one on screen. The background work is the point of this
  -- widget, so it happens here as well as in refresh().
  function widget.background(self)
    tickRuntimes(self)
    return 0
  end

  function widget.refresh(self, event, touchState)
    tickRuntimes(self)

    local now = nowSeconds()
    if self.built and (now - (self._lastUIRefresh or 0)) < UI_INTERVAL_SECONDS then
      return
    end
    self._lastUIRefresh = now

    local status = readStatus(self)
    local zoneW = (self.zone and self.zone.w) or 0
    local zoneH = (self.zone and self.zone.h) or 0
    local key = tostring(status.text) .. "|" .. tostring(status.craftName) .. "|" .. tostring(zoneW) .. "x" .. tostring(zoneH)
    if self.built and key == self.renderKey then
      return
    end

    self.renderKey = key
    lvgl.clear()
    lvgl.build(buildTile(self, status))
    self.built = true
  end

  return widget
end

return Runtime
