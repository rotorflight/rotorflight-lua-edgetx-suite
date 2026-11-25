-- Settings page of the @NF theme in the Rotorflight suite for EdgeTX: the colour of the cockpit. It lives in the
-- suite's theme settings - as the radio's default, or as the model's own value when the page is opened in that
-- scope. The long press on the cockpit's head writes the same value.
local function loadModule(path)
  local chunk = assert(loadScript(_G.rfsuite.paths.core .. "/" .. path, "t"))
  return chunk()
end

local Controls = loadModule("ui/controls.lua")
local DashboardLib = loadModule("app/pages/settings/dashboard/lib.lua")
local Common = loadModule("app/pages/settings/common.lua")
local t = Common.pageT("settings_dashboard_settings")

local THEME_PATH = "system/@nf"   -- the page passes the theme it is opened for; a copy under user/dashboard keeps its values under its own key; the literal applies without a passed theme
local THEME_NAME = "@NF"
local COLOURS = {"blue", "turquoise", "green", "yellow", "gold", "orange", "red", "magenta", "violet", "silver"}   -- the stored values are English, like every value in the suite's settings (parts.lua COLOUR_WORDS, the same order)
local COLOUR_OK = {}
for i = 1, #COLOURS do COLOUR_OK[COLOURS[i]] = true end
local THEME_DEFAULTS = {colour = "blue"}

local ui = {loaded = false, choice = "blue"}

local function session()
  local s = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
  return type(s) == "table" and s or nil
end

local function modelStore()   -- the model's store is reachable only once the FC's id is known; reading uses the same condition as writing
  local s = session()
  return (s and s.mcu_id and type(s.modelPreferences) == "table") and s.modelPreferences or nil
end

local function loadConfig(prefs)
  if ui.loaded then return end
  local cfg = DashboardLib.getThemeConfig(prefs, THEME_PATH, THEME_DEFAULTS, modelStore())
  ui.choice = COLOUR_OK[cfg.colour] and cfg.colour or "blue"
  ui.loaded = true
end

local function saveConfig(prefs)   -- where the value goes is decided by the page's scope: the radio's defaults or the model's own values (those need the FC's id)
  local s = session()
  local modelPrefs = modelStore()
  DashboardLib.setThemeConfig(prefs, THEME_PATH, {colour = ui.choice}, modelPrefs)

  local modelScope = type(DashboardLib.getEditScope) == "function" and DashboardLib.getEditScope() == "model"   -- the model's file is written as soon as an FC is connected; in the default scope the values live in the radio's settings, an error of the model file is then not an error of this save
  if s and s.mcu_id and modelPrefs then
    local loadMod = loadScript(_G.rfsuite.paths.core .. "/lib/model_preferences.lua", "t")
    if type(loadMod) == "function" then
      local ok, MP = pcall(loadMod)
      if ok and type(MP) == "table" and type(MP.saveByMcuId) == "function" then
        local saved, err = MP.saveByMcuId(s.mcu_id, modelPrefs)
        if modelScope then return saved, err end
        return true
      end
    end
    if modelScope then return false, "unavailable" end
  end
  return true
end

local M = {}

function M.getHeaderActions()
  return {save = true, help = false}
end

function M.onReload(ctx)
  ui.loaded = false
  loadConfig(ctx.preferences)
  return true
end

function M.onSave(ctx)
  local modelOk, modelErr = saveConfig(ctx.preferences)
  local ok, err = ctx.savePreferences()
  if not ok then   -- saved means: every store that holds the values is written; the library turns the result into the sentence for the pilot
    err = DashboardLib.saveFailureReason(ctx.i18n, err)
  elseif not modelOk then
    ok, err = false, DashboardLib.saveFailureReason(ctx.i18n, modelErr, true)
  end
  if ctx and type(ctx.reportSave) == "function" then
    local i18n = ctx.i18n
    if ok then
      local title = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.saved_title") or "Saved"
      local message = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.saved_message") or "Theme settings saved"
      ctx.reportSave({ok = true, title = title, message = message})
    else
      local title = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.save_error_title") or "Error"
      local message = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.save_error_message") or "Save failed"
      ctx.reportSave({title = title, message = message .. ": " .. tostring(err)})
    end
  end
  return true
end

function M.build(ctx)
  loadConfig(ctx.preferences)
  local children, x, y, w = ctx.children, ctx.x, ctx.y, ctx.w
  local i18n = ctx.i18n
  Controls.appendSectionHeader(children, x, y, w, THEME_NAME, true, function() end)
  y = y + Controls.SECTION_H
  local choices = {
    {value = "blue", label = t(i18n, "nf_colour_blue", "Blue")},
    {value = "turquoise", label = t(i18n, "nf_colour_turquoise", "Turquoise")},
    {value = "green", label = t(i18n, "nf_colour_green", "Green")},
    {value = "yellow", label = t(i18n, "nf_colour_yellow", "Yellow")},
    {value = "gold", label = t(i18n, "nf_colour_gold", "Gold")},
    {value = "orange", label = t(i18n, "nf_colour_orange", "Orange")},
    {value = "red", label = t(i18n, "nf_colour_red", "Red")},
    {value = "magenta", label = t(i18n, "nf_colour_magenta", "Magenta")},
    {value = "violet", label = t(i18n, "nf_colour_violet", "Violet")},
    {value = "silver", label = t(i18n, "nf_colour_silver", "Silver")},
  }
  Controls.appendComboSelect(children, x, y, w, t(i18n, "nf_colour", "Colour"), choices, ui.choice,
    function(v) if COLOUR_OK[v] then ui.choice = v end end)
end

return function(ctx)
  local theme = ctx and ctx.theme
  if type(theme) == "table" and type(theme.path) == "string" and theme.path ~= "" then
    THEME_PATH = theme.path
  end
  ui.loaded = false
  return M
end
