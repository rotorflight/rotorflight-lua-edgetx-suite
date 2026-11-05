-- Settings > Dashboard > Quick Settings: which entries the dashboard widget's quick menu shows, and
-- in which order.
--
-- One row per place in the menu, from the top, each offering every entry the menu has and a dash
-- for nothing. The entries, their default order and the stored form are not written down here:
-- they are in widgets/dashboard/quick_menu_order.lua, which the widget draws the menu from, so
-- the page cannot offer an entry the menu does not have or forget one it has.
--
-- The choice belongs to the radio and is saved in its preferences like every other Settings
-- page; no flight controller has to be connected. The widget picks it up with its reload of the
-- preferences file. An entry the pilot has chosen still hides where it does not apply -- the
-- battery prompt without a pack, the tool while armed -- because the menu asks each entry's own
-- condition on top of this list.

local M = {}

local function loadModule(path)
  local fullPath = _G.rfsuite.paths.core .. "/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  return chunk()
end

local Controls = nil
local Common = nil
local Order = nil

-- The value of a place left empty.
local NONE = ""

-- ─── State ────────────────────────────────────────────────────────────────────

-- `config[i]` is the id at place i, or NONE.
local ui = {
  loaded = false,
  dirty  = false,
  config = {},
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
  if not Order then
    Order = loadModule("widgets/dashboard/quick_menu_order.lua")
  end
  if not ui.runtime then
    ui.runtime = Common.createFormRuntime(ui)
  end
  if not t then
    t = Common.pageT("settings_dashboard_quick_menu")
  end
end

-- The places as the stored value has them: the menu's entries in its order, then empty places.
-- Read through the same function the widget reads it with, so the page shows what the menu draws.
local function copyFromPrefs(prefs)
  local dashboard = (type(prefs) == "table" and type(prefs.dashboard) == "table") and prefs.dashboard or {}
  local ids = Order.ids(dashboard[Order.KEY])
  for i = 1, #Order.OFFERED do
    ui.config[i] = ids[i] or NONE
  end
end

local function ensureLoaded(prefs)
  if ui.loaded then return end
  copyFromPrefs(prefs)
  ui.loaded = true
end

-- A title is a translation marker until the package step has resolved it; the translator
-- resolves one that is still there.
local function resolveTitle(i18n, text)
  if i18n and type(i18n.resolve) == "function" then return i18n.resolve(text) end
  return text
end

-- What every place offers: nothing, then each entry, by the title the menu draws it with.
local function placeOptions(i18n)
  local options = { { value = NONE, label = t(i18n, "none", "-") } }
  for i = 1, #Order.OFFERED do
    local id = Order.OFFERED[i]
    options[#options + 1] = { value = id, label = resolveTitle(i18n, Order.TITLES[id]) }
  end
  return options
end

-- ─── Module API ──────────────────────────────────────────────────────────────

function M.getHeaderActions()
  ensureDeps()
  return { save = true, help = true }
end

function M.onReload(ctx)
  ensureDeps()
  copyFromPrefs(ctx.preferences)
  ui.dirty = false
end

-- The places in order, empty ones skipped; Order.encode keeps an entry chosen twice at its first
-- place only, stores nothing for the default list and the empty string for an emptied menu.
function M.onSave(ctx)
  ensureDeps()
  if not ctx.preferences.dashboard then ctx.preferences.dashboard = {} end

  local ids = {}
  for i = 1, #Order.OFFERED do
    local id = ui.config[i]
    if id ~= nil and id ~= NONE then ids[#ids + 1] = id end
  end
  ctx.preferences.dashboard[Order.KEY] = Order.encode(ids)

  local ok, err = ctx.savePreferences()
  if ok then
    ui.dirty = false
    -- What was stored, read back: an entry chosen twice now shows at its first place only.
    copyFromPrefs(ctx.preferences)
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({ ok = true, title = t(ctx.i18n, "saved_title", "Saved"),
        message = t(ctx.i18n, "saved_message", "Quick Settings saved") })
    end
  else
    if ctx and type(ctx.reportSave) == "function" then
      local failed = t(ctx.i18n, "save_error_message", "Save failed")
      ctx.reportSave({ title = t(ctx.i18n, "save_error_title", "Error"),
        message = failed .. ": " .. Common.saveFailureReason(ctx.i18n, err) })
    end
  end
end

function M.build(ctx)
  ensureDeps()
  ensureLoaded(ctx.preferences)

  local children = ctx.children
  local x, w = ctx.x, ctx.w
  local i18n = ctx.i18n
  local cursorY = ctx.y

  ui.runtime.setRequestRebuild(ctx.requestRebuild)

  local options = placeOptions(i18n)
  local placeFmt = t(i18n, "place", "Position %d")
  local placeHelp = t(i18n, "help_place", "The entry in this place; the dash leaves it empty, and an entry chosen twice counts at its first place.")
  for i = 1, #Order.OFFERED do
    cursorY = cursorY + Controls.appendComboSelect(
      children, x, cursorY, w,
      string.format(placeFmt, i),
      options,
      ui.config[i],
      ui.runtime.getValueSetter(i),
      { helpText = placeHelp }
    )
  end
end

function M.onClose()
  Common.resetPageState(ui)
  Controls = nil
  Common = nil
  Order = nil
  t = nil
end

-- Asked before the page is left (ui/home.lua): true while an edit here is not saved.
function M.hasUnsavedChanges()
  return ui.dirty == true
end

return M
