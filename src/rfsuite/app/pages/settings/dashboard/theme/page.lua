local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  return chunk()
end

local Palette = _G.rfsuite and _G.rfsuite.palette or (_G.rfsuite and _G.rfsuite.require or loadModule)("ui/palette.lua")

local Common = nil
local Controls = nil
local DashboardLib = nil
local Log = nil

local M = {}

local DEBUG_PREFIX = "[dashboard.theme.page] "

-- Whether a debug line would be written, asked once where the page builds or reloads, so that a
-- line is formatted only when the log level lets it out. The callers hand over the pieces.
local debugOn = false

local function refreshDebug()
  debugOn = Log ~= nil and type(Log.wanted) == "function" and Log.wanted("debug") == true
end

local function debugLog(fmt, ...)
  if debugOn and Log then
    Log.emit("dashboard.theme.page", DEBUG_PREFIX .. string.format(fmt, ...), "debug")
  end
end

local ui = {
  loaded = false,
  dirty = false,
  config = {
    theme_preflight = nil,
    theme_inflight = nil,
    theme_postflight = nil,
    model_overrides = false,
    overrides = false,
    model_theme_preflight = "nil",
    model_theme_inflight = "nil",
    model_theme_postflight = "nil",
    theme_per_phase = false,
  },
  themes = nil,
}

ui.runtime = nil
local t = nil

local function ensureDeps()
  if not Common then
    Common = loadModule("app/pages/settings/common.lua")
  end
  if not Controls then
    Controls = loadModule("ui/controls.lua")
  end
  if not DashboardLib then
    DashboardLib = loadModule("app/pages/settings/dashboard/lib.lua")
  end
  if not Log then
    Log = loadModule("lib/log.lua")
  end
  if not ui.runtime then
    ui.runtime = Common.createFormRuntime(ui)
  end
  if not t then
    t = Common.pageT("settings_dashboard_theme")
  end
end

local function refreshThemes(forceRefresh)
  ensureDeps()
  ui.themes = DashboardLib.listThemes(forceRefresh == true)
  debugLog("refreshThemes count=%s", ui.themes and #ui.themes or 0)
end

-- Every selection except the general theme may legitimately be unset: a per-model theme that
-- is not given falls through to the general one, and a phase override that is not given falls
-- through to the theme of its own context.
local OPTIONAL_THEME_KEYS = {
  "theme_inflight",
  "theme_postflight",
  "model_theme_preflight",
  "model_theme_inflight",
  "model_theme_postflight",
}

local function ensureValidSelections()
  local defaultPath = DashboardLib.getDefaultThemePath(ui.themes)
  if not defaultPath then return end

  if not DashboardLib.getThemeByPath(ui.themes, ui.config.theme_preflight) then
    ui.config.theme_preflight = defaultPath
  end

  for i = 1, #OPTIONAL_THEME_KEYS do
    local key = OPTIONAL_THEME_KEYS[i]
    local value = ui.config[key]
    if value ~= "nil" and not DashboardLib.getThemeByPath(ui.themes, value) then
      ui.config[key] = "nil"
    end
  end
end

-- Per-model preferences are keyed by the flight controller's MCU id, so the
-- model override can only be stored while a flight controller is connected.
local function hasModelStore()
  if type(_G) ~= "table" or not _G.rfsuite then return false end
  if type(_G.rfsuite.session) ~= "table" then return false end
  return _G.rfsuite.session.mcu_id ~= nil
end

-- The name the connected model goes by: the flight controller's craft name where it has one,
-- the name its store recorded for it, and the radio's model name otherwise.
local function connectedModelName()
  local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
  if type(session) == "table" then
    if type(session.modelName) == "string" and session.modelName ~= "" then
      return session.modelName
    end
    local craft = type(session.modelPreferences) == "table" and session.modelPreferences.craft or nil
    if type(craft) == "table" and type(craft.name) == "string" and craft.name ~= "" then
      return craft.name
    end
  end
  if type(model) == "table" and type(model.getInfo) == "function" then
    local ok, info = pcall(model.getInfo)
    if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
      return info.name
    end
  end
  return nil
end

local function ensureLoaded(prefs)
  if ui.loaded then return end

  if not ui.themes then
    refreshThemes(false)
  end
  local defaultPath = DashboardLib.getDefaultThemePath(ui.themes)
  local src = (prefs and prefs.dashboard) or {}

  local modelSrc = nil
  if type(_G) == "table" and _G.rfsuite and type(_G.rfsuite.session) == "table" and type(_G.rfsuite.session.modelPreferences) == "table" then
    if _G.rfsuite.session.modelPreferences.dashboard then
      modelSrc = _G.rfsuite.session.modelPreferences.dashboard
    end
  end

  -- What the two switches show is what the dashboard does with them (lib.lua). An absent radio
  -- switch allows overrides, and is shown as whatever the connected model already does, so a
  -- card written before the switch existed opens on a page that matches what it draws; with no
  -- model to ask, it is shown off.
  local modelOverridesOn = DashboardLib.modelOverridesOn(modelSrc)
  local allowed
  if src.model_overrides ~= nil then
    allowed = src.model_overrides == true
  elseif hasModelStore() then
    allowed = modelOverridesOn
  else
    allowed = false
  end
  -- An inferred switch is only a picture of it; saving the page for another reason must not
  -- turn that picture into a decision (see saveToPreferences).
  ui.modelOverridesInferred = src.model_overrides == nil
  ui.modelOverridesShown = allowed

  ui.config.theme_preflight = src.theme_preflight or defaultPath
  ui.config.theme_inflight = src.theme_inflight or "nil"
  ui.config.theme_postflight = src.theme_postflight or "nil"
  ui.config.theme_per_phase = src.theme_per_phase == true
  ui.config.model_overrides = allowed
  ui.config.overrides = modelOverridesOn
  ui.config.model_theme_preflight = (modelSrc and modelSrc.model_theme_preflight) or "nil"
  ui.config.model_theme_inflight = (modelSrc and modelSrc.model_theme_inflight) or "nil"
  ui.config.model_theme_postflight = (modelSrc and modelSrc.model_theme_postflight) or "nil"

  ui.loaded = true
end

local function getThemeId(path)
  local fallback = DashboardLib.getThemeIdByPath(ui.themes, DashboardLib.getDefaultThemePath(ui.themes), 1)
  return DashboardLib.getThemeIdByPath(ui.themes, path, fallback)
end

local function getOptionalThemeId(path)
  if path == nil or path == "" or path == "nil" then return 0 end
  local fallback = DashboardLib.getThemeIdByPath(ui.themes, DashboardLib.getDefaultThemePath(ui.themes), 1)
  return DashboardLib.getThemeIdByPath(ui.themes, path, fallback)
end

local function setThemeFromId(key, id)
  local theme = DashboardLib.getThemeById(ui.themes, id)
  if not theme then return end
  if ui.config[key] ~= theme.path then
    ui.config[key] = theme.path
    ui.runtime.markDirty()
  end
end

local function setOptionalThemeFromId(key, id)
  local numeric = tonumber(id) or 0
  local nextPath = "nil"
  if numeric ~= 0 then
    local theme = DashboardLib.getThemeById(ui.themes, numeric)
    if not theme then return end
    nextPath = theme.path
  end
  if ui.config[key] ~= nextPath then
    ui.config[key] = nextPath
    ui.runtime.markDirty()
  end
end

-- The two phase rows are identical in both sections and differ only in the key prefix they
-- write to: "theme_" for the general context, "model_theme_" for the connected model.
local function appendPhaseOverrides(children, x, y, w, i18n, prefix, options, active)
  local used = 0

  used = used + Controls.appendComboSelect(
    children, x, y + used, w,
    t(i18n, "theme_inflight_override", "Inflight Override"),
    options,
    getOptionalThemeId(ui.config[prefix .. "inflight"]),
    function(id) setOptionalThemeFromId(prefix .. "inflight", id) end,
    { active = active }
  )

  used = used + Controls.appendComboSelect(
    children, x, y + used, w,
    t(i18n, "theme_postflight_override", "Postflight Override"),
    options,
    getOptionalThemeId(ui.config[prefix .. "postflight"]),
    function(id) setOptionalThemeFromId(prefix .. "postflight", id) end,
    { active = active }
  )

  return used
end

local function saveToPreferences(prefs)
  if not prefs.dashboard then prefs.dashboard = {} end
  prefs.dashboard.theme_preflight = ui.config.theme_preflight
  prefs.dashboard.theme_inflight = ui.config.theme_inflight
  prefs.dashboard.theme_postflight = ui.config.theme_postflight
  prefs.dashboard.theme_per_phase = ui.config.theme_per_phase == true
  -- Once written, the switch is the answer and nothing is inferred. An absent one is written only
  -- when the pilot changed it: with no flight controller connected it is shown off, and writing
  -- that picture back would switch off every model that already carries its own values.
  if not (ui.modelOverridesInferred and (ui.config.model_overrides == true) == (ui.modelOverridesShown == true)) then
    prefs.dashboard.model_overrides = ui.config.model_overrides == true
    ui.modelOverridesInferred = false
  end
  -- Ensure legacy model_override keys are not stored in global preferences
  prefs.dashboard.model_override = nil
  prefs.dashboard.model_theme_preflight = nil
  prefs.dashboard.model_theme_inflight = nil
  prefs.dashboard.model_theme_postflight = nil

  -- Nothing per-model to write is a success; anything attempted has to report.
  local modelOk, modelErr = true, nil

  if type(_G) == "table" and _G.rfsuite and type(_G.rfsuite.session) == "table" then
    local session = _G.rfsuite.session
    if session.mcu_id then
      if type(session.modelPreferences) ~= "table" then session.modelPreferences = {} end
      if type(session.modelPreferences.dashboard) ~= "table" then session.modelPreferences.dashboard = {} end
      local mDashboard = session.modelPreferences.dashboard

      -- `model_override` mirrors the switch because a build that predates `overrides` reads
      -- that key. Switching off keeps the model's theme choice: it is ignored until the switch
      -- is turned on again, exactly as its theme settings are.
      mDashboard.overrides = ui.config.overrides == true
      mDashboard.model_override = ui.config.overrides == true
      mDashboard.model_theme_preflight = ui.config.model_theme_preflight
      mDashboard.model_theme_inflight = ui.config.model_theme_inflight
      mDashboard.model_theme_postflight = ui.config.model_theme_postflight

      -- Save model preferences using ModelPreferences module
      modelOk, modelErr = false, "unavailable"
      local loadMod = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/model_preferences.lua", "t")
      if type(loadMod) == "function" then
        local loaded, MP = pcall(loadMod)
        if loaded and type(MP) == "table" and type(MP.saveByMcuId) == "function" then
          modelOk, modelErr = MP.saveByMcuId(session.mcu_id, session.modelPreferences)
        end
      end
    end
  end

  return modelOk ~= false, modelErr
end

function M.getHeaderActions()
  ensureDeps()
  return { save = true, help = true }
end


function M.onReload(ctx)
  ensureDeps()
  refreshDebug()
  ui.loaded = false
  ui.dirty = false
  ui.themes = nil
  if DashboardLib and type(DashboardLib.invalidateThemeCache) == "function" then
    DashboardLib.invalidateThemeCache()
  end
  ensureLoaded(ctx.preferences)
  return true
end

local function reportSaveError(ctx, err)
  if ctx and type(ctx.reportSave) == "function" then
    ctx.reportSave({
      title = t(ctx.i18n, "save_error_title", "Error"),
      message = t(ctx.i18n, "save_error_message", "Save failed") .. ": " .. err
    })
  end
end

function M.onSave(ctx)
  ensureDeps()
  -- The page saves into two stores. Both have to be believed before the save
  -- is reported as done, and a failure in either one has to be shown -- as the
  -- sentence the library maps the store's answer to, never the token or path itself.
  local modelOk, modelErr = saveToPreferences(ctx.preferences)
  local ok, err = ctx.savePreferences()
  if not ok then
    reportSaveError(ctx, DashboardLib.saveFailureReason(ctx.i18n, err))
  elseif not modelOk then
    reportSaveError(ctx, DashboardLib.saveFailureReason(ctx.i18n, modelErr, true))
  else
    -- Both stores, because this page reports a save as done only when both were believed.
    ui.dirty = false
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        ok = true,
        title = t(ctx.i18n, "saved_title", "Saved"),
        message = t(ctx.i18n, "saved_message", "Theme settings saved")
      })
    end
  end
  return true
end

-- A line of explanation, and the height it takes. A label narrower than its text wraps rather
-- than clipping, so the advance is measured instead of assumed.
local function appendNote(children, x, y, w, text)
  children[#children + 1] = {
    type = "label", x = x, y = y, w = w, text = text, color = Palette.text, font = SMLSIZE
  }
  local lines = 1
  if type(Controls.estimateWrappedTextHeight) == "function" then
    local total = Controls.estimateWrappedTextHeight(text, w, SMLSIZE)
    local one = Controls.estimateWrappedTextHeight("Ag", w, SMLSIZE)
    if type(total) == "number" and type(one) == "number" and one > 0 then
      lines = math.floor((total / one) + 0.5)
      if lines < 1 then lines = 1 end
    end
  end
  return lines * 24
end

function M.build(ctx)
  ensureDeps()
  refreshDebug()
  ensureLoaded(ctx.preferences)
  if not ui.themes then
    refreshThemes(false)
  end
  ensureValidSelections()
  ui.runtime.setRequestRebuild(ctx.requestRebuild)

  debugLog("build theme count=%s preflight=%s inflight=%s postflight=%s", ui.themes and #ui.themes or 0, ui.config.theme_preflight, ui.config.theme_inflight, ui.config.theme_postflight)
  if type(ui.themes) == "table" then
    for i = 1, #ui.themes do
      local theme = ui.themes[i]
      debugLog("option[%s] name=%s path=%s", i, theme.name, theme.path)
    end
  end

  local children = ctx.children
  local x, y, w = ctx.x, ctx.y, ctx.w
  local i18n = ctx.i18n
  local cursorY = y

  if not ui.themes or #ui.themes == 0 then
    children[#children + 1] = {
      type = "label",
      x = x,
      y = y + 10,
      w = w,
      text = t(i18n, "no_themes_found", "No dashboard themes found"),
      color = Palette.text,
      font = SMLSIZE
    }
    return
  end

  local themeOptions = DashboardLib.buildThemeOptions(ui.themes)
  local modelOptions = DashboardLib.buildModelThemeOptions(ui.themes, t(i18n, "model_disabled", "Disabled"))
  local overrideOptions = DashboardLib.buildModelThemeOptions(ui.themes, t(i18n, "theme_use_context", "Use theme above"))
  local perPhase = ui.config.theme_per_phase == true

  Controls.appendSectionHeader(children, x, cursorY, w,
    t(i18n, "section_dashboard_theme", "Dashboard Theme"), true, function() end)
  cursorY = cursorY + Controls.SECTION_H

  -- One theme for everything that is not the connected model. It carries all three flight
  -- phases, which it declares and switches between itself.
  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    t(i18n, "theme", "Theme"),
    themeOptions,
    getThemeId(ui.config.theme_preflight),
    function(id) setThemeFromId("theme_preflight", id) end
  )

  if perPhase then
    cursorY = cursorY + appendPhaseOverrides(children, x, cursorY, w, i18n, "theme_", overrideOptions, nil)
  end

  cursorY = cursorY + 10
  Controls.appendSectionHeader(children, x, cursorY, w,
    t(i18n, "section_model_overrides", "Per-Model Settings"), true, function() end)
  cursorY = cursorY + Controls.SECTION_H

  cursorY = cursorY + appendNote(children, x, cursorY, w,
    t(i18n, "model_overrides_note",
      "Lets each model use its own theme and theme settings. Stored on the SD card for the connected flight controller."))

  -- The radio's switch. Off, every model draws the theme and the settings above, whatever its
  -- own file holds.
  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    t(i18n, "model_overrides", "Allow per-model settings"),
    ui.runtime.getBoolGetter("model_overrides"),
    ui.runtime.getBoolSetter("model_overrides")
  )

  if ui.config.model_overrides == true then
    if not hasModelStore() then
      cursorY = cursorY + appendNote(children, x, cursorY, w,
        t(i18n, "model_overrides_unavailable",
          "Connect a flight controller to set this model's own theme and theme settings"))
    else
      local name = connectedModelName()
      if name then
        cursorY = cursorY + appendNote(children, x, cursorY, w,
          t(i18n, "model_name", "Model") .. ": " .. name)
      end

      -- The connected model's switch, and below it the model's theme for all three phases.
      cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
        t(i18n, "model_overrides_this", "Own settings for this model"),
        ui.runtime.getBoolGetter("overrides"),
        ui.runtime.getBoolSetter("overrides")
      )

      if ui.config.overrides == true then
        cursorY = cursorY + Controls.appendComboSelect(
          children, x, cursorY, w,
          t(i18n, "theme", "Theme"),
          modelOptions,
          getOptionalThemeId(ui.config.model_theme_preflight),
          function(id) setOptionalThemeFromId("model_theme_preflight", id) end
        )

        if perPhase then
          cursorY = cursorY + appendPhaseOverrides(children, x, cursorY, w, i18n, "model_theme_", overrideOptions, nil)
        end
      end
    end
  end

  cursorY = cursorY + 10
  Controls.appendSectionHeader(children, x, cursorY, w,
    t(i18n, "section_advanced", "Advanced"), true, function() end)
  cursorY = cursorY + Controls.SECTION_H

  -- Off, the page offers one theme per context and nothing else. On, each context gains the
  -- two overrides that let a phase be drawn by a different theme than the one above it.
  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    t(i18n, "theme_per_phase", "Per-Phase Themes"),
    ui.runtime.getBoolGetter("theme_per_phase"),
    ui.runtime.getBoolSetter("theme_per_phase")
  )
end

function M.onClose()
  Common.resetPageState(ui)
  -- The theme list is kept: listing it loads every theme's init.lua and looks for its icon, and
  -- the library's own cache goes with the library below, so dropping it here made every visit
  -- list the theme folders again. They are listed again once the registry drops this module,
  -- or by M.onReload.
  Controls = nil
  Common = nil
  DashboardLib = nil
  Log = nil
  t = nil
end

-- Asked before the page is left (ui/home.lua): true while an edit here is not saved.
function M.hasUnsavedChanges()
  return ui.dirty == true
end

return M
