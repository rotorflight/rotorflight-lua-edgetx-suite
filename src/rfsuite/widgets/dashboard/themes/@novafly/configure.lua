-- Einstellungsseite des NovaFly-Themes in der Rotorflight-Suite fuer EdgeTX: die Farbe des Cockpits. Sie steht in den
-- Theme-Einstellungen der Suite - als Standardwert des Senders, oder als eigener Wert des Modells, wenn die Seite in diesem
-- Bereich geoeffnet ist. Der lange Druck auf den Kopf des Cockpits schreibt denselben Wert.
local function loadModule(path)
  local chunk = assert(loadScript(_G.rfsuite.paths.core .. "/" .. path, "t"))
  return chunk()
end

local Controls = loadModule("ui/controls.lua")
local DashboardLib = loadModule("app/pages/settings/dashboard/lib.lua")
local Common = loadModule("app/pages/settings/common.lua")
local t = Common.pageT("settings_dashboard_settings")

-- Die Seite reicht das Theme, fuer das sie geoeffnet ist; eine Kopie unter user/dashboard fuehrt ihre Werte so unter ihrem
-- eigenen Schluessel. Das Literal gilt, wenn kein Theme gereicht wird
local THEME_PATH = "system/@novafly"
local THEME_NAME = "@NovaFly RC"
local FARBEN = {"blau", "tuerkis", "gruen", "gelb", "gold", "orange", "rot", "magenta", "violett", "silber"}
local FARBE_OK = {}
for i = 1, #FARBEN do FARBE_OK[FARBEN[i]] = true end
local THEME_DEFAULTS = {colour = "blau"}

local ui = {loaded = false, wahl = "blau"}

local function session()
  local s = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
  return type(s) == "table" and s or nil
end

-- der Speicher des Modells ist erst erreichbar, wenn die Kennung des FC bekannt ist; gelesen wird unter derselben Bedingung
-- wie geschrieben
local function modelStore()
  local s = session()
  return (s and s.mcu_id and type(s.modelPreferences) == "table") and s.modelPreferences or nil
end

local function loadConfig(prefs)
  if ui.loaded then return end
  local cfg = DashboardLib.getThemeConfig(prefs, THEME_PATH, THEME_DEFAULTS, modelStore())
  ui.wahl = FARBE_OK[cfg.colour] and cfg.colour or "blau"
  ui.loaded = true
end

-- Wohin der Wert geht, entscheidet der Bereich der Seite: die Standardwerte des Senders, oder die eigenen Werte dieses
-- Modells - die brauchen die Kennung des FC, ohne sie wird im Modell-Bereich nichts gespeichert
local function saveConfig(prefs)
  local s = session()
  local modelPrefs = modelStore()
  DashboardLib.setThemeConfig(prefs, THEME_PATH, {colour = ui.wahl}, modelPrefs)

  -- Die Datei des Modells wird geschrieben, sobald ein FC verbunden ist; im Standard-Bereich tragen die Werte aber in den
  -- Einstellungen des Senders, die die Seite selbst schreibt - ein Fehler beim Schreiben der Modelldatei ist dann keiner
  -- dieses Speicherns
  local modelScope = type(DashboardLib.getEditScope) == "function" and DashboardLib.getEditScope() == "model"
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
  -- Gespeichert heisst: jeder Speicher, der die Werte traegt, ist geschrieben. Was ein Speicher zurueckgibt, macht die
  -- Bibliothek zu dem Satz, den der Pilot liest
  if not ok then
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
  local wahlen = {
    {value = "blau", label = t(i18n, "novafly_colour_blue", "Blue")},
    {value = "tuerkis", label = t(i18n, "novafly_colour_turquoise", "Turquoise")},
    {value = "gruen", label = t(i18n, "novafly_colour_green", "Green")},
    {value = "gelb", label = t(i18n, "novafly_colour_yellow", "Yellow")},
    {value = "gold", label = t(i18n, "novafly_colour_gold", "Gold")},
    {value = "orange", label = t(i18n, "novafly_colour_orange", "Orange")},
    {value = "rot", label = t(i18n, "novafly_colour_red", "Red")},
    {value = "magenta", label = t(i18n, "novafly_colour_magenta", "Magenta")},
    {value = "violett", label = t(i18n, "novafly_colour_violet", "Violet")},
    {value = "silber", label = t(i18n, "novafly_colour_silver", "Silver")},
  }
  Controls.appendComboSelect(children, x, y, w, t(i18n, "novafly_colour", "Colour"), wahlen, ui.wahl,
    function(v) if FARBE_OK[v] then ui.wahl = v end end)
end

return function(ctx)
  local theme = ctx and ctx.theme
  if type(theme) == "table" and type(theme.path) == "string" and theme.path ~= "" then
    THEME_PATH = theme.path
  end
  ui.loaded = false
  return M
end
