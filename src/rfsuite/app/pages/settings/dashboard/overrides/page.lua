-- Settings > Dashboard > Settings > Per-Model Settings: what the connected model changes.
--
-- First, one row per theme the model draws opens that theme's settings in the model's scope.
-- Below them, the page lists every theme setting the model's own file holds, beside the standard
-- value it replaces, and lets each one -- or all of them -- be removed again. A removed override
-- is not set to anything: the model then reads the standard value, so a later change of the
-- standard reaches it.
--
-- Those buttons open entries of this page's own menu list, which the dashboard settings builder
-- fills with the model-scope theme entries. The menu registry opens an entry of the list that
-- belongs to the current menu id, and this page's id is that menu id, so opening one of them is
-- the same step a tile press takes, and going back returns here.

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  return chunk()
end

local Palette = _G.rfsuite and _G.rfsuite.palette or (_G.rfsuite and _G.rfsuite.require or loadModule)("ui/palette.lua")

local Common = nil
local Controls = nil
local DashboardLib = nil
local ConfirmDialog = nil

local M = {}

local ui = {
  loaded = false,
  dirty = false,
  config = {},
  themes = nil,
  notice = nil,
}

ui.runtime = nil
local t = nil

local NOTE_LINE_H = 24
local RESET_BTN_W = 96
local THEME_BTN_W = 240

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
  if not ui.runtime then
    ui.runtime = Common.createFormRuntime(ui)
  end
  if not t then
    t = Common.pageT("settings_dashboard_overrides")
  end
end

local function getSession()
  local session = type(_G) == "table" and _G.rfsuite and _G.rfsuite.session or nil
  if type(session) == "table" then return session end
  return nil
end

-- The model's store is addressed by the flight controller's id, so nothing can be read from it
-- or written to it without one.
local function modelStoreReady()
  local session = getSession()
  return session ~= nil and session.mcu_id ~= nil and type(session.modelPreferences) == "table"
end

local function getPreferences(ctx)
  if ctx and type(ctx.preferences) == "table" then return ctx.preferences end
  local root = type(_G) == "table" and _G.rfsuite or nil
  if root and type(root.preferences) == "table" then return root.preferences end
  return nil
end

-- The name the connected model goes by: the flight controller's craft name where it has one,
-- the name its store recorded for it, and the radio's model name otherwise.
local function connectedModelName()
  local session = getSession()
  if session then
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

local function formatValue(i18n, value)
  if type(value) == "boolean" then
    if value then return t(i18n, "value_on", "On") end
    return t(i18n, "value_off", "Off")
  end
  if type(value) == "number" then
    if value == math.floor(value) then
      return string.format("%d", value)
    end
    -- Two decimals without the trailing zeros: 18.5 rather than 18.50.
    local text = string.gsub(string.format("%.2f", value), "%.?0+$", "")
    return text
  end
  return tostring(value)
end

-- A line of text, and the height it takes. A label narrower than its text wraps rather than
-- clipping, so the advance is measured instead of assumed.
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
  return lines * NOTE_LINE_H
end

-- Writes the model's store and says on the page whether it worked, because the header's Save
-- is not involved: a reset is saved the moment it is pressed.
local function saveModel(i18n)
  local session = getSession()
  -- A module that will not load answers as saveByMcuId does when it has no store: "unavailable".
  local ok, err = false, "unavailable"
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/model_preferences.lua", "t")
  if type(chunk) == "function" then
    local loaded, MP = pcall(chunk)
    if loaded and type(MP) == "table" and type(MP.saveByMcuId) == "function" then
      ok, err = MP.saveByMcuId(session.mcu_id, session.modelPreferences)
    end
  end
  if ok then
    ui.notice = t(i18n, "reset_saved", "Saved")
  else
    ui.notice = t(i18n, "save_error_message", "Save failed") .. ": " .. Common.saveFailureReason(i18n, err, true)
  end
  ui.runtime.markDirty()
end

-- Removes one override, or all of them with `key` nil, and saves. A model whose switch was only
-- inferred from the settings in its file would lose it with the last one, so the switch is
-- written down first: removing overrides is not turning them off.
local function resetOverrides(i18n, key)
  if not modelStoreReady() then
    ui.notice = t(i18n, "model_store_missing", "Connect the flight controller to change this model's settings")
    ui.runtime.markDirty()
    return
  end
  local modelPrefs = getSession().modelPreferences
  local modelDashboard = modelPrefs.dashboard
  if type(modelDashboard) == "table" and modelDashboard.overrides == nil then
    modelDashboard.overrides = DashboardLib.modelOverridesOn(modelDashboard)
  end
  DashboardLib.clearModelOverride(modelPrefs, key)
  saveModel(i18n)
end

local function offerResetAll(i18n)
  if ConfirmDialog == nil then
    ConfirmDialog = loadModule("ui/confirm_dialog.lua")
  end
  local shown = false
  if ConfirmDialog and type(ConfirmDialog.show) == "function" then
    shown = ConfirmDialog.show({
      title = t(i18n, "reset_all", "Reset all"),
      message = t(i18n, "reset_all_question", "Remove all of this model's theme settings? It then uses the standard values."),
      onConfirm = function() resetOverrides(i18n, nil) end,
      onCancel = function()
        ui.notice = t(i18n, "reset_cancelled", "Nothing was changed")
        ui.runtime.markDirty()
      end
    })
  end
  if not shown then
    -- No confirmation could be put up, so there is no answer to act on.
    ui.notice = t(i18n, "no_dialog", "This radio cannot show the confirmation.")
    ui.runtime.markDirty()
  end
end

-- One row per override: which theme and setting, the model's value, and what it replaces.
local function describeOverride(i18n, entry)
  local themeName = entry.theme and entry.theme.name or t(i18n, "unknown_theme", "Theme not installed")
  local standard
  if entry.standard ~= nil then
    standard = t(i18n, "standard", "standard") .. " " .. formatValue(i18n, entry.standard)
  else
    standard = t(i18n, "theme_default", "theme default")
  end
  return themeName .. " / " .. tostring(entry.setting) .. " = " .. formatValue(i18n, entry.value)
    .. "  (" .. standard .. ")"
end

local function appendButton(children, x, y, w, h, text, press)
  children[#children + 1] = {
    type = "button",
    x = x, y = y, w = w, h = h,
    text = text,
    press = press
  }
end

-- Which flight phases a theme is drawn in, as the label of its row.
local function describePhases(i18n, phases)
  if #phases >= 3 then
    return t(i18n, "phase_all", "All flight phases")
  end
  local names = {
    preflight = t(i18n, "phase_preflight", "Preflight"),
    inflight = t(i18n, "phase_inflight", "Inflight"),
    postflight = t(i18n, "phase_postflight", "Postflight"),
  }
  local parts = {}
  for i = 1, #phases do
    parts[#parts + 1] = names[phases[i]] or tostring(phases[i])
  end
  return table.concat(parts, ", ")
end

-- A form row like the settings pages draw theirs: what it is about on the left, the button that
-- opens it on the right, and a divider below. Returns the height it takes.
local function appendThemeRow(children, x, y, w, btnH, labelText, buttonText, press)
  local rowH = math.max(Controls.ROW_H or 0, btnH + 8)
  local btnW = math.min(THEME_BTN_W, w)
  local btnX = x + w - btnW - 10
  children[#children + 1] = {
    type = "label", x = x, y = Controls.labelY(y, rowH), w = btnX - x - 8,
    text = labelText, color = Palette.text, font = SMLSIZE
  }
  appendButton(children, btnX, Controls.controlY(y, rowH, btnH), btnW, btnH, buttonText, press)
  children[#children + 1] = {
    type = "rectangle", x = x, y = y + rowH, w = w, h = 1,
    color = Palette.border, filled = true
  }
  return rowH + 1
end

function M.getHeaderActions()
  -- A reset is saved when it is pressed, so the page has nothing for the header to save.
  return { save = false, reload = false, help = true }
end

function M.build(ctx)
  ensureDeps()
  ui.runtime.setRequestRebuild(ctx.requestRebuild)
  if not ui.themes then
    ui.themes = DashboardLib.listThemes()
  end

  local children = ctx.children
  local x, y, w = ctx.x, ctx.y, ctx.w
  local i18n = ctx.i18n
  local cursorY = y
  local btnH = (lvgl and lvgl.UI_ELEMENT_HEIGHT) or Controls.CTRL_H or 32

  local name = connectedModelName()
  if name then
    cursorY = cursorY + appendNote(children, x, cursorY, w, t(i18n, "model_name", "Model") .. ": " .. name)
  end

  if not modelStoreReady() then
    appendNote(children, x, cursorY, w,
      t(i18n, "model_store_missing", "Connect the flight controller to change this model's settings"))
    return
  end

  local session = getSession()

  -- The theme entries the builder registered for this page, each opening the theme's settings
  -- in the model's scope.
  local menu = ctx.menu
  local menuId = menu and menu.getCurrentMenuId and menu.getCurrentMenuId() or nil
  local def = menu and type(menu.menus) == "table" and menuId and menu.menus[menuId] or nil
  local entries = type(def) == "table" and def.pages or nil
  if type(entries) == "table" and #entries > 0 then
    Controls.appendSectionHeader(children, x, cursorY, w,
      t(i18n, "section_edit", "Edit for this model"), true, function() end)
    cursorY = cursorY + Controls.SECTION_H

    -- Only the themes this model draws are offered: a setting of any other theme would be stored
    -- and never shown. One row per theme, named by the flight phases it is drawn in.
    local prefs = getPreferences(ctx)
    local inUse = DashboardLib.themesInUse(prefs and prefs.dashboard, session.modelPreferences.dashboard)
    local rows = 0
    for i = 1, #inUse do
      local entry = nil
      for j = 1, #entries do
        if entries[j].themePath == inUse[i].path then entry = entries[j] end
      end
      if entry then
        local entryId = entry.id
        cursorY = cursorY + appendThemeRow(children, x, cursorY, w, btnH,
          describePhases(i18n, inUse[i].phases), tostring(entry.title),
          function()
            if menu.openEntry(entryId) and type(ctx.requestRebuild) == "function" then
              ctx.requestRebuild()
            end
          end)
        rows = rows + 1
      end
    end

    if rows == 0 then
      cursorY = cursorY + appendNote(children, x, cursorY, w,
        t(i18n, "no_theme_settings", "The themes this model uses have no settings."))
    end
    cursorY = cursorY + 6
  end

  local list = DashboardLib.listModelOverrides(getPreferences(ctx), session.modelPreferences, ui.themes)

  -- What the model changes, below the themes it is edited through.
  Controls.appendSectionHeader(children, x, cursorY, w,
    t(i18n, "section_different", "Different from standard"), true, function() end)
  cursorY = cursorY + Controls.SECTION_H

  if #list == 0 then
    cursorY = cursorY + appendNote(children, x, cursorY, w,
      t(i18n, "no_overrides", "This model uses the standard values."))
  else
    local labelW = w - RESET_BTN_W - 10
    local resetText = t(i18n, "reset", "Reset")
    for i = 1, #list do
      local entry = list[i]
      local rowH = appendNote(children, x, cursorY, labelW, describeOverride(i18n, entry))
      if rowH < btnH + 4 then rowH = btnH + 4 end
      local key = entry.key
      appendButton(children, x + w - RESET_BTN_W, cursorY, RESET_BTN_W, btnH, resetText,
        function() resetOverrides(i18n, key) end)
      cursorY = cursorY + rowH
    end

    local allW = math.min(240, w)
    appendButton(children, x + math.floor((w - allW) / 2), cursorY + 4, allW, btnH,
      t(i18n, "reset_all", "Reset all"),
      function() offerResetAll(i18n) end)
    cursorY = cursorY + btnH + 10
  end

  if ui.notice then
    cursorY = cursorY + appendNote(children, x, cursorY, w, ui.notice)
  end
end

function M.onClose()
  -- The module is kept by the page registry after this, so everything a visit built is dropped
  -- here and made again by the next build.
  if Common then
    Common.resetPageState(ui)
  end
  ui.themes = nil
  ui.notice = nil
  Common = nil
  Controls = nil
  DashboardLib = nil
  ConfirmDialog = nil
  t = nil
end

return M
