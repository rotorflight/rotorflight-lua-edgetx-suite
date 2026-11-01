local function loadModule(path)
  local chunk = assert(loadScript("/SCRIPTS/TOOLS/rfsuite-core/" .. path, "t"))
  return chunk()
end

local Controls = loadModule("ui/controls.lua")
local DashboardLib = loadModule("app/pages/settings/dashboard/lib.lua")
local FieldsForm = loadModule("app/pages/settings/dashboard/fields_form.lua")

-- The settings page loads this file for the theme it is configuring and hands that theme
-- to the factory below, so a copy of this theme under rfsuite.user/dashboard stores its
-- values under its own key prefix instead of this one's. The literal is the fallback for
-- a caller that passes no theme.
local THEME_PATH = "system/@kse5"
local THEME_NAME = "@KSE5"

-- The Look page: the full scale of each ring, one section per ring. The current ring's figure is
-- the fallback: where the model has an ESC current limit on file (Setup > Power > Preferences)
-- the ring is scaled to that instead. `scale` is what a stored value is multiplied by to give the
-- integer the number field edits (10 for one decimal).
local SETTINGS = {
  { key = "rpm_max", group = "widgets.dashboard.headspeed", groupFallback = "Headspeed", label = "widgets.dashboard.max", fallback = "Max",
    default = 3000, min = 500, max = 6000, step = 50, fmt = "%d rpm" },
  { key = "current_max", group = "widgets.dashboard.current", groupFallback = "Current", label = "widgets.dashboard.max", fallback = "Max",
    default = 150, min = 10, max = 500, step = 5, fmt = "%d A" },
  { key = "temp_max", group = "widgets.dashboard.esc_temp", groupFallback = "ESC Temp", label = "widgets.dashboard.max", fallback = "Max",
    default = 100, min = 40, max = 150, step = 5, fmt = "%d°C" },
}

-- Settings that must rise strictly from first to last, each by at least one step of its field: a
-- range's minimum below its warning level below its maximum. An edit is held between its
-- neighbours, and a stored chain out of order is put back to its defaults when the page loads.
local ORDERED = {}

-- The pages init.lua declares beside Look: what the tiles of each phase show, and the keys.
local PHASES = { preflight = "preflight.lua", inflight = "inflight.lua", postflight = "postflight.lua" }

local THEME_DEFAULTS = {}
for _, s in ipairs(SETTINGS) do THEME_DEFAULTS[s.key] = s.default end

local ui = {
  loaded = false,
  -- The page the settings page opened, nil for the whole form of a host without pages.
  page = nil,
  form = nil,
  -- The edited integers, by key.
  values = {},
}

local function clamp(value, minValue, maxValue)
  if value < minValue then return minValue end
  if value > maxValue then return maxValue end
  return value
end

local SETTING_BY_KEY = {}
for _, s in ipairs(SETTINGS) do SETTING_BY_KEY[s.key] = s end

local function defaultValue(s)
  return math.floor(s.default * (s.scale or 1) + 0.5)
end

--- The range an edit of `key` may take: its own, narrowed by its neighbours in an ordered chain.
local function bounds(key)
  local s = SETTING_BY_KEY[key]
  local lo, hi = s.min, s.max
  for _, chain in ipairs(ORDERED) do
    for i = 1, #chain do
      if chain[i] == key then
        local prev, nxt = chain[i - 1], chain[i + 1]
        if prev and ui.values[prev] then lo = math.max(lo, ui.values[prev] + 1) end
        if nxt and ui.values[nxt] then hi = math.min(hi, ui.values[nxt] - 1) end
      end
    end
  end
  return lo, hi
end

local function normalizeOrder()
  for _, chain in ipairs(ORDERED) do
    local ordered = true
    for i = 2, #chain do
      if ui.values[chain[i]] <= ui.values[chain[i - 1]] then ordered = false end
    end
    if not ordered then
      for i = 1, #chain do ui.values[chain[i]] = defaultValue(SETTING_BY_KEY[chain[i]]) end
    end
  end
end

local function loadConfig(prefs)
  if ui.loaded then return end

  local session = type(_G) == "table" and _G.rfsuite and type(_G.rfsuite.session) == "table" and _G.rfsuite.session or nil
  -- The per-model store is only addressable once the flight controller's id is known, so
  -- the read is conditioned on it exactly as the save is.
  local modelPrefs = session and session.mcu_id and session.modelPreferences or nil

  local cfg = DashboardLib.getThemeConfig(prefs, THEME_PATH, THEME_DEFAULTS, modelPrefs)
  -- A page of the shared form reads again with its own defaults added, so a model's save of it
  -- can tell a choice that repeats the standard from one that deviates.
  if ui.form and ui.form.owns(ui.page) then
    local defaults = {}
    for k, v in pairs(THEME_DEFAULTS) do defaults[k] = v end
    ui.form.defaults(ui.page, cfg, defaults)
    cfg = DashboardLib.getThemeConfig(prefs, THEME_PATH, defaults, modelPrefs)
    ui.form.load(ui.page, cfg)
  end
  ui.cfg = cfg

  for _, s in ipairs(SETTINGS) do
    local scale = s.scale or 1
    local v = tonumber(cfg[s.key]) or s.default
    ui.values[s.key] = clamp(math.floor(v * scale + 0.5), s.min, s.max)
  end
  normalizeOrder()

  ui.loaded = true
end

local function saveConfig(prefs)
  local session = type(_G) == "table" and _G.rfsuite and type(_G.rfsuite.session) == "table" and _G.rfsuite.session or nil
  -- Where the values land is the settings page's scope, not this module's: the library
  -- writes the radio's standard values, or this model's own ones, which need the flight
  -- controller's id -- without it the model scope saves nothing.
  local modelPrefs = session and session.mcu_id and session.modelPreferences or nil

  -- A page saves what it shows and nothing else: the shared form's page its own values, Look
  -- (or the whole form, on a host without pages) the theme's.
  if ui.form and ui.form.owns(ui.page) then
    DashboardLib.setThemeConfig(prefs, THEME_PATH, ui.form.save(), modelPrefs)
  else
    local values = {}
    for _, s in ipairs(SETTINGS) do
      values[s.key] = (tonumber(ui.values[s.key]) or s.default) / (s.scale or 1)
    end
    DashboardLib.setThemeConfig(prefs, THEME_PATH, values, modelPrefs)
  end

  -- The model's file is written whenever a flight controller is connected, but it carries
  -- this save's values only in the model scope: there its answer is what the save reports.
  -- In the standard scope the values went into the radio's preferences, which the page's own
  -- save writes, so a failure to rewrite the model's file is not a failure of this save.
  local modelScope = type(DashboardLib.getEditScope) == "function" and DashboardLib.getEditScope() == "model"
  if session and session.mcu_id and modelPrefs then
    local loadMod = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/model_preferences.lua", "t")
    if type(loadMod) == "function" then
      local ok, MP = pcall(loadMod)
      if ok and type(MP) == "table" and type(MP.saveByMcuId) == "function" then
        local saved, err = MP.saveByMcuId(session.mcu_id, modelPrefs)
        if modelScope then return saved, err end
        return true
      end
    end
    -- saveByMcuId's own word for a store that will not load; onSave turns it into a sentence.
    if modelScope then return false, "unavailable" end
  end
  return true
end

local M = {}

function M.getHeaderActions()
  return { save = true, help = false }
end

function M.onReload(ctx)
  ui.loaded = false
  loadConfig(ctx.preferences)
  return true
end

function M.onSave(ctx)
  local modelOk, modelErr = saveConfig(ctx.preferences)
  local ok, err = ctx.savePreferences()
  -- Saved only when every store that carries this save's values was written. A store answers a
  -- refused write with a token or with the card's own error text, which names the file's path;
  -- the pilot reads the sentence the library maps either to.
  if not ok then
    err = DashboardLib.saveFailureReason(ctx.i18n, err)
  elseif not modelOk then
    ok, err = false, DashboardLib.saveFailureReason(ctx.i18n, modelErr, true)
  end
  if ok then
    ui.dirty = false
    if ctx and type(ctx.reportSave) == "function" then
      local i18n = ctx.i18n
      local title = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.saved_title") or "Saved"
      local message = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.saved_message") or "Theme settings saved"
      ctx.reportSave({ ok = true, title = title, message = message })
    end
  else
    if ctx and type(ctx.reportSave) == "function" then
      local i18n = ctx.i18n
      local title = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.save_error_title") or "Error"
      local message = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.save_error_message") or "Save failed"
      ctx.reportSave({ title = title, message = message .. ": " .. err })
    end
  end
  return true
end

local function settingText(i18n, key, fallback)
  if i18n and i18n.t then
    local text = i18n.t(key)
    if text and text ~= key and text ~= "" then return text end
  end
  return fallback
end

function M.build(ctx)
  ui.page = ctx and ctx.page and ctx.page.id or nil
  loadConfig(ctx.preferences)
  if ui.form and ui.form.owns(ui.page) then
    local dashboard = type(ctx.preferences) == "table" and ctx.preferences.dashboard or nil
    ui.form.build(ui.page, ctx.children, ctx.x, ctx.y, ctx.w, ui.cfg, dashboard)
    return
  end

  local children = ctx.children
  local x, y, w = ctx.x, ctx.y, ctx.w
  local cursorY = y

  if #SETTINGS == 0 then
    Controls.appendSectionHeader(children, x, cursorY, w, THEME_NAME, true, function() end)
    return
  end

  local group = nil
  for _, s in ipairs(SETTINGS) do
    if s.group ~= group then
      group = s.group
      Controls.appendSectionHeader(children, x, cursorY, w, settingText(ctx.i18n, s.group, s.groupFallback), true, function() end)
      cursorY = cursorY + Controls.SECTION_H
    end
    local scale = s.scale or 1
    cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, settingText(ctx.i18n, s.label, s.fallback), {
      min = s.min,
      max = s.max,
      step = s.step,
      get = function() return ui.values[s.key] or defaultValue(s) end,
      set = function(value)
        local lo, hi = bounds(s.key)
        ui.values[s.key] = clamp(tonumber(value) or defaultValue(s), lo, hi)
      end,
      display = function(value)
        return string.format(s.fmt, (tonumber(value) or s.default * scale) / scale)
      end
    })
  end
end

return function(ctx)
  local theme = ctx and ctx.theme
  if type(theme) == "table" and type(theme.path) == "string" and theme.path ~= "" then
    THEME_PATH = theme.path
  end
  -- The phase modules are read from where this file was loaded, so a copy of the theme on the
  -- card lists its own tiles.
  local folder = type(theme) == "table" and type(theme.configurePath) == "string"
    and string.match(theme.configurePath, "^(.*/)[^/]*$") or nil
  if folder then ui.form = FieldsForm.new(folder, PHASES) end
  ui.page = ctx and ctx.page and ctx.page.id or nil
  return M
end
