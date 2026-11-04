local function loadModule(path)
  local chunk = assert(loadScript(_G.rfsuite.paths.core .. "/" .. path, "t"))
  return chunk()
end

local Controls = loadModule("ui/controls.lua")
local DashboardLib = loadModule("app/pages/settings/dashboard/lib.lua")
local FieldsForm = loadModule("app/pages/settings/dashboard/fields_form.lua")

-- The settings page loads this file for the theme it is configuring and hands that theme
-- to the factory below, so a copy of this theme under RFSUITE/user/dashboard stores its
-- values under its own key prefix instead of this one's. The literal is the fallback for
-- a caller that passes no theme.
local THEME_PATH = "system/@srb-rc"
local THEME_DEFAULTS = {
  bec_warn = 6.5,
  esctemp_warn = 90,
  esctemp_max = 200,
}

-- The pages init.lua declares beside Look: what the tiles of each phase show, and the keys.
local PHASES = { preflight = "preflight.lua", inflight = "inflight.lua", postflight = "postflight.lua" }

local ui = {
  loaded = false,
  -- The page the settings page opened, nil for the whole form of a host without pages.
  page = nil,
  form = nil,
  config = {
    bec_warn_tenths = 65,
    esctemp_warn = 90,
    esctemp_max = 200,
  }
}

local function clamp(value, minValue, maxValue)
  if value < minValue then return minValue end
  if value > maxValue then return maxValue end
  return value
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

  ui.config.bec_warn_tenths = math.floor(((tonumber(cfg.bec_warn) or THEME_DEFAULTS.bec_warn) * 10) + 0.5)
  ui.config.esctemp_warn = tonumber(cfg.esctemp_warn) or THEME_DEFAULTS.esctemp_warn
  ui.config.esctemp_max = tonumber(cfg.esctemp_max) or THEME_DEFAULTS.esctemp_max

  ui.config.bec_warn_tenths = clamp(ui.config.bec_warn_tenths, 50, 150)
  ui.config.esctemp_max = clamp(ui.config.esctemp_max, 1, 200)
  ui.config.esctemp_warn = clamp(ui.config.esctemp_warn, 0, ui.config.esctemp_max - 1)

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
    DashboardLib.setThemeConfig(prefs, THEME_PATH, {
      bec_warn = (tonumber(ui.config.bec_warn_tenths) or 65) / 10,
      esctemp_warn = tonumber(ui.config.esctemp_warn) or THEME_DEFAULTS.esctemp_warn,
      esctemp_max = tonumber(ui.config.esctemp_max) or THEME_DEFAULTS.esctemp_max,
    }, modelPrefs)
  end

  -- The model's file is written whenever a flight controller is connected, but it carries
  -- this save's values only in the model scope: there its answer is what the save reports.
  -- In the standard scope the values went into the radio's preferences, which the page's own
  -- save writes, so a failure to rewrite the model's file is not a failure of this save.
  local modelScope = type(DashboardLib.getEditScope) == "function" and DashboardLib.getEditScope() == "model"
  if session and session.mcu_id and modelPrefs then
    local loadMod = loadScript(_G.rfsuite.paths.core .. "/lib/model_preferences.lua", "t")
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

local function getBecWarn()
  return tonumber(ui.config.bec_warn_tenths) or 65
end

local function setBecWarn(value)
  ui.config.bec_warn_tenths = clamp(tonumber(value) or 65, 50, 150)
end

local function getEscWarn()
  local maxAllowed = (tonumber(ui.config.esctemp_max) or 200) - 1
  return clamp(tonumber(ui.config.esctemp_warn) or 90, 0, maxAllowed)
end

local function setEscWarn(value)
  local maxAllowed = (tonumber(ui.config.esctemp_max) or 200) - 1
  ui.config.esctemp_warn = clamp(tonumber(value) or 90, 0, maxAllowed)
end

local function getEscMax()
  local minAllowed = (tonumber(ui.config.esctemp_warn) or 90) + 1
  return clamp(tonumber(ui.config.esctemp_max) or 200, minAllowed, 200)
end

local function setEscMax(value)
  local minAllowed = (tonumber(ui.config.esctemp_warn) or 90) + 1
  ui.config.esctemp_max = clamp(tonumber(value) or 200, minAllowed, 200)
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

  local i18n = ctx.i18n
  local becWarnLabel = "BEC Warning"
  local escWarnLabel = "ESC Warning"
  local escMaxLabel = "ESC Max"
  if i18n and i18n.t then
    local becWarnTranslated = i18n.t("widgets.dashboard.bec_warning")
    if becWarnTranslated and becWarnTranslated ~= "widgets.dashboard.bec_warning" and becWarnTranslated ~= "" then
      becWarnLabel = becWarnTranslated
    end
    local escWarnTranslated = i18n.t("widgets.dashboard.esc_warning")
    if escWarnTranslated and escWarnTranslated ~= "widgets.dashboard.esc_warning" and escWarnTranslated ~= "" then
      escWarnLabel = escWarnTranslated
    end
    local escMaxTranslated = i18n.t("widgets.dashboard.esc_max")
    if escMaxTranslated and escMaxTranslated ~= "widgets.dashboard.esc_max" and escMaxTranslated ~= "" then
      escMaxLabel = escMaxTranslated
    end
  end

  Controls.appendSectionHeader(children, x, cursorY, w, "@SRB-RC", true, function() end)
  cursorY = cursorY + Controls.SECTION_H

  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, becWarnLabel, {
    min = 50,
    max = 150,
    get = getBecWarn,
    set = setBecWarn,
    display = function(value)
      return string.format("%.1fV", (tonumber(value) or 65) / 10)
    end
  })

  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, escWarnLabel, {
    min = 0,
    max = 199,
    get = getEscWarn,
    set = setEscWarn,
    display = function(value)
      return string.format("%d°C", tonumber(value) or 90)
    end
  })

  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, escMaxLabel, {
    min = 1,
    max = 200,
    get = getEscMax,
    set = setEscMax,
    display = function(value)
      return string.format("%d°C", tonumber(value) or 200)
    end
  })
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
