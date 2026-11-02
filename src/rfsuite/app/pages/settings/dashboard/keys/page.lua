-- Settings > Dashboard > Keys. These are radio preferences, including while offline.
local function loadModule(path)
  return assert(loadScript(_G.rfsuite.paths.core .. "/" .. path, "t"))()
end
local M = {}
local Controls, Common, Keys, t
local LABELS = {
  pageDown = "@i18n(app.pages.settings_dashboard_keys.page_down)@",
  pageUp = "@i18n(app.pages.settings_dashboard_keys.page_up)@",
  mdl = "@i18n(app.pages.settings_dashboard_keys.mdl)@",
  sys = "@i18n(app.pages.settings_dashboard_keys.sys)@",
  tele = "@i18n(app.pages.settings_dashboard_keys.tele)@",
}
local ui = { loaded = false, dirty = false, config = {} }

local function ensureDeps()
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Keys then Keys = loadModule("widgets/dashboard/keys.lua") end
  if not ui.runtime then ui.runtime = Common.createFormRuntime(ui) end
  if not t then t = Common.pageT("settings_dashboard_keys") end
end

local function copyFromPrefs(prefs)
  local dashboard = type(prefs) == "table" and prefs.dashboard or nil
  for i = 1, #Keys.KEYS do
    local entry = Keys.KEYS[i]
    ui.config[entry.pref] = Keys.global(dashboard, entry.id)
  end
  ui.loaded = true
end

function M.getHeaderActions()
  ensureDeps()
  return { save = true, help = true }
end

function M.onReload(ctx)
  ensureDeps()
  copyFromPrefs(ctx.preferences)
  ui.dirty = false
end

function M.onSave(ctx)
  ensureDeps()
  ctx.preferences.dashboard = ctx.preferences.dashboard or {}
  -- A key's default is stored as no entry at all, so a later release can change a default for
  -- every pilot who never chose; any other choice, Theme included, is stored as chosen.
  for i = 1, #Keys.KEYS do
    local entry = Keys.KEYS[i]
    local value = Keys.choice(ui.config[entry.pref], entry.id)
    if value == entry.default then value = nil end
    ctx.preferences.dashboard[entry.pref] = value
  end
  local ok, err = ctx.savePreferences()
  if ok then
    ui.dirty = false
    copyFromPrefs(ctx.preferences)
  end
  if type(ctx.reportSave) == "function" then
    if ok then
      ctx.reportSave({ ok = true, title = t(ctx.i18n, "saved_title", "Saved"),
        message = t(ctx.i18n, "saved_message", "Keys saved") })
    else
      ctx.reportSave({ title = t(ctx.i18n, "save_error_title", "Error"),
        message = t(ctx.i18n, "save_error_message", "Save failed") .. ": " .. Common.saveFailureReason(ctx.i18n, err) })
    end
  end
end

function M.build(ctx)
  ensureDeps()
  if not ui.loaded then copyFromPrefs(ctx.preferences) end
  ui.runtime.setRequestRebuild(ctx.requestRebuild)
  local y = ctx.y
  for i = 1, #Keys.KEYS do
    local entry = Keys.KEYS[i]
    y = y + Controls.appendComboSelect(ctx.children, ctx.x, y, ctx.w, LABELS[entry.id],
      Keys.OPTIONS, ui.config[entry.pref], ui.runtime.getValueSetter(entry.pref))
  end
end

function M.hasUnsavedChanges() return ui.dirty == true end

function M.onClose()
  Common.resetPageState(ui)
  Controls, Common, Keys, t = nil, nil, nil, nil
end

return M
