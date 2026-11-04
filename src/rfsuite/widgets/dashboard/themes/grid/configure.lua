-- Settings page for this theme: which value the six slots of the tile grid show, which the
-- telemetry view's tiles show, and the rest of what the theme carries.
--
-- Follows the shipped default theme's configure module: load through
-- DashboardLib.getThemeConfig, save through setThemeConfig plus the per-model store, and
-- build the form with the shared Controls helpers. The source catalog itself lives in
-- layout.lua beside the tiles that render it, so the page and the grid cannot drift apart.

local function loadModule(path)
  local chunk = assert(loadScript(_G.rfsuite.paths.core .. "/" .. path, "t"))
  return chunk()
end

local Controls = loadModule("ui/controls.lua")
local DashboardLib = loadModule("app/pages/settings/dashboard/lib.lua")
-- The radio-wide key choices, which decide whether a key is this theme's to bind at all.
local GlobalKeys = loadModule("widgets/dashboard/keys.lua")
-- Through the suite's module loader where there is one, as the theme's own modules load it: in the
-- widget's Lua state (the tool hosted there) the module then has a cache entry beside its global,
-- and the dashboard releases the two together once no widget uses this theme
-- (releaseUnusedThemes in widgets/dashboard/runtime.lua).
local function loadLayout(path)
  local requireModule = _G.rfsuite and _G.rfsuite.require
  local mod = type(requireModule) == "function" and requireModule(path) or nil
  if type(mod) == "table" then return mod end
  return loadModule(path)
end
local Layout = loadLayout("widgets/dashboard/themes/grid/layout.lua")

-- The settings page loads this file for the theme it is configuring and hands that theme to
-- the factory at the foot of this file, so a copy of this theme under rfsuite.user/dashboard
-- stores its values under its own key prefix instead of this one's. The literal is the
-- fallback for a caller that passes no theme.
local THEME_PATH = "system/grid"

-- The tile grid's slots, as many as layout.lua fills the grid from.
local SLOT_COUNT = Layout.SLOT_COUNT or 6

-- The telemetry view's tiles, on the Telemetry page: as many as layout.lua draws, from the same
-- catalogue as the slots.
local TILE_COUNT = Layout.TILE_COUNT or 12

-- The arm-state colour choice. common.lua resolves the value; this theme's default is amber and
-- grey.
local ARM_COLORS = {
  { label = "@i18n(app.pages.settings_dashboard_settings.urban_arm_amber)@", value = "amber" },
  { label = "@i18n(app.pages.settings_dashboard_settings.urban_arm_signal)@", value = "signal" },
}
local ARM_COLORS_VALID = { amber = true, signal = true }
local ARM_COLORS_DEFAULT = "amber"

-- The colour scheme: light or dark. The list and the default come from the theme itself, so
-- this page cannot offer a scheme the palettes have no colours for. The default is `light`, so
-- a page nobody has opened changes nothing.
local SCHEMES = {}
local SCHEMES_VALID = {}
for i = 1, #Layout.SCHEMES do
  SCHEMES[i] = { label = Layout.SCHEMES[i].label, value = Layout.SCHEMES[i].id }
  SCHEMES_VALID[Layout.SCHEMES[i].id] = true
end
local SCHEME_DEFAULT = Layout.DEFAULT_SCHEME

-- Everything the theme carries beyond the six slots, the scheme and the arm colours comes from
-- Layout.SETTINGS: the key, the page it is set on, the values that are valid and the default, in
-- one list that this page and the panels drawing the answers both read. A row added there
-- appears here without this file being touched, which is what stops a setting from existing on a
-- page and nowhere in the drawing, or the other way round.
--
-- The wording is the second half of the same declaration and comes from Layout.settingsLabels(),
-- which is a function for a cost reason stated there -- the widget's Lua state must not build
-- strings it never draws. This module runs in the settings tool's Lua state, so it calls it once
-- and builds the host combo's option list from the two halves together. A value the labels do
-- not cover falls back to the value itself: the page then reads oddly and works, which is the
-- right way round.
local SETTINGS = Layout.SETTINGS or {}
local SETTINGS_LABELS = (type(Layout.settingsLabels) == "function") and Layout.settingsLabels() or {}
local SETTINGS_VALID = {}
local SETTINGS_OPTIONS = {}
local SETTINGS_ROW_LABEL = {}
for i = 1, #SETTINGS do
  local entry = SETTINGS[i]
  local labels = SETTINGS_LABELS[entry.key] or {}
  local valueLabels = labels.values or {}
  local valid, options = {}, {}
  -- A number row (`min` and `max`, no `values`) has no option list: its range is the check.
  for j = 1, #(entry.values or {}) do
    local value = entry.values[j]
    valid[value] = true
    options[j] = { label = valueLabels[value] or value, value = value }
  end
  SETTINGS_VALID[entry.key] = valid
  SETTINGS_OPTIONS[entry.key] = options
  SETTINGS_ROW_LABEL[entry.key] = labels.label or entry.key
end

-- The switch that opens the link view (init.lua, `views`, the `grid_link` entry's openWhen reads
-- it as `link_switch`). It is chosen in the radio's own switch picker, the one the host's in-flight
-- tuning page uses for its interlock, and stored the way that picker hands it over: a switch
-- POSITION, a number, which the host reads as it is. 0 is no switch, the default init.lua
-- declares: until the pilot picks one, the view opens by its tap only.
--
-- Not a row of Layout.SETTINGS: those are the settings the DRAWING reads, and the page probe holds
-- each of them to a change in the picture. This one changes when a view opens and draws nothing.
local LINK_SWITCH_DEFAULT = 0

-- What the keys do in full screen (Layout.KEYS, Layout.KEY_ACTIONS): the keys, their defaults and
-- the actions come from layout.lua, which binds them; the words are this page's. Like the link
-- switch, not a row of Layout.SETTINGS -- a binding draws nothing. Each label but Nothing says
-- whose the action is, Suite or Theme, since the list mixes the dashboard's own actions with the
-- pages this theme adds; that word is part of the translated label. The labels are kept short
-- enough for the choice control's standard font on a 480 px wide screen: a longer one is drawn in
-- a smaller font, which makes the column uneven.
local KEYS = Layout.KEYS or {}
local KEY_NAMES = { pageDown = "PAGE >", pageUp = "PAGE <", mdl = "MDL", sys = "SYS", tele = "TELE" }
local KEY_ACTION_LABELS = {
  none = "@i18n(app.pages.settings_dashboard_settings.urban_key_none)@",
  menu = "@i18n(app.pages.settings_dashboard_settings.urban_key_menu)@",
  tools = "@i18n(app.pages.settings_dashboard_settings.urban_key_tools)@",
  link = "@i18n(app.pages.settings_dashboard_settings.urban_key_link)@",
  telemetry = "@i18n(app.pages.settings_dashboard_settings.urban_key_telemetry)@",
  battery = "@i18n(app.pages.settings_dashboard_settings.urban_key_battery)@",
  status = "@i18n(app.pages.settings_dashboard_settings.urban_key_status)@",
  suite_tool = "@i18n(app.pages.settings_dashboard_settings.urban_key_suite_tool)@",
  flight_log = "@i18n(app.pages.settings_dashboard_settings.urban_key_flight_log)@",
  exit = "@i18n(app.pages.settings_dashboard_settings.urban_key_exit)@",
}
local KEY_OPTIONS = {}
local KEY_VALID = {}
for i = 1, #(Layout.KEY_ACTIONS or {}) do
  local id = Layout.KEY_ACTIONS[i].id
  KEY_OPTIONS[i] = { label = KEY_ACTION_LABELS[id] or id, value = id }
  KEY_VALID[id] = true
end

local THEME_DEFAULTS = {
  arm_colors = ARM_COLORS_DEFAULT,
  scheme = SCHEME_DEFAULT,
  link_switch = LINK_SWITCH_DEFAULT,
}
for i = 1, SLOT_COUNT do
  THEME_DEFAULTS["slot" .. i] = Layout.DEFAULT_SLOTS[i]
end
for i = 1, TILE_COUNT do
  THEME_DEFAULTS["tile" .. i] = (Layout.DEFAULT_TILES or {})[i] or "none"
end
for i = 1, #SETTINGS do
  THEME_DEFAULTS[SETTINGS[i].key] = SETTINGS[i].default
end
for i = 1, #KEYS do
  THEME_DEFAULTS[KEYS[i].pref] = KEYS[i].default
end

-- The link switch picker's filters, as the firmware numbers them (radio/src/dataconstants.h,
-- SwitchTypes): the physical switches, the logical ones, and the empty entry that clears the choice.
local SW_SWITCH = 1
local SW_LOGICAL_SWITCH = 1 << 2
local SW_NONE = 1 << 20

local VALID_IDS = {}
local OPTIONS = {}
for i = 1, #Layout.SOURCES do
  local src = Layout.SOURCES[i]
  VALID_IDS[src.id] = true
  OPTIONS[i] = { label = src.label, value = src.id }
end

local ui = {
  loaded = false,
  config = {},
  -- The number rows that name a row they may not exceed, collected by loadConfig.
  capped = {}
}

-- A number row's stored value as a whole number inside its range, or nil for anything that is not
-- a number. Out of range is pulled to the edge rather than thrown away, the way the theme reads it
-- (Common.percent), so the page shows the step the gauge actually draws with.
local function wholeNumber(entry, value)
  local n = tonumber(value)
  if n == nil or n ~= n then return nil end
  if n < entry.min then n = entry.min end
  if n > entry.max then n = entry.max end
  return math.floor(n)
end

-- Holds every `notAbove` pair of number rows in order: a row never stands above the row it names.
-- Run after a load and after every change, so the page can neither show nor save a red step above
-- the yellow one. It walks only the rows that name one, which loadConfig collects, because every
-- page of this theme opens with a load and most of them carry no such row.
local function holdNotAbove()
  local capped = ui.capped
  for i = 1, #capped do
    local entry = capped[i]
    local cap = tonumber(ui.config[entry.notAbove])
    local value = tonumber(ui.config[entry.key])
    if cap and value and value > cap then
      ui.config[entry.key] = tostring(cap)
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
  for i = 1, SLOT_COUNT do
    local key = "slot" .. i
    local value = cfg[key]
    if type(value) ~= "string" or not VALID_IDS[value] then
      value = THEME_DEFAULTS[key]
    end
    ui.config[key] = value
  end
  for i = 1, TILE_COUNT do
    local key = "tile" .. i
    local value = cfg[key]
    if type(value) ~= "string" or not VALID_IDS[value] then
      value = THEME_DEFAULTS[key]
    end
    ui.config[key] = value
  end

  local arm = cfg.arm_colors
  if type(arm) ~= "string" or not ARM_COLORS_VALID[arm] then arm = ARM_COLORS_DEFAULT end
  ui.config.arm_colors = arm

  local scheme = cfg.scheme
  if type(scheme) ~= "string" or not SCHEMES_VALID[scheme] then scheme = SCHEME_DEFAULT end
  ui.config.scheme = scheme

  -- Same guard for every declared row, and it is the guard that matters most for the numeric
  -- ones: they are stored as text, so a file written by hand -- or by a build of this theme
  -- that offered a value this one does not -- comes back as a string nothing on the page
  -- matches. Falling back to the default is the only answer that leaves the picture defined.
  local capped = {}
  for i = 1, #SETTINGS do
    local entry = SETTINGS[i]
    local value = cfg[entry.key]
    if entry.values == nil then
      -- A number row: any number is met, pulled into its range; anything else is the default.
      local n = wholeNumber(entry, value)
      value = n and tostring(n) or entry.default
      if entry.notAbove then capped[#capped + 1] = entry end
    else
      if type(value) == "number" then value = tostring(value) end
      if type(value) ~= "string" or not SETTINGS_VALID[entry.key][value] then
        value = entry.default
      end
    end
    ui.config[entry.key] = value
  end
  ui.capped = capped
  holdNotAbove()

  -- A number, or a number as text where the preferences file hands it back that way; anything
  -- else is no choice made: no switch.
  ui.config.link_switch = tonumber(cfg.link_switch) or LINK_SWITCH_DEFAULT

  for i = 1, #KEYS do
    local entry = KEYS[i]
    local value = cfg[entry.pref]
    if type(value) ~= "string" or not KEY_VALID[value] then value = entry.default end
    ui.config[entry.pref] = value
  end
  ui.loaded = true
end

local function saveConfig(prefs)
  local session = type(_G) == "table" and _G.rfsuite and type(_G.rfsuite.session) == "table" and _G.rfsuite.session or nil
  -- Where the values land is the settings page's scope, not this module's: the library
  -- writes the radio's standard values, or this model's own ones, which need the flight
  -- controller's id -- without it the model scope saves nothing.
  local modelPrefs = session and session.mcu_id and session.modelPreferences or nil

  local values = {}
  for i = 1, SLOT_COUNT do
    local key = "slot" .. i
    values[key] = ui.config[key] or THEME_DEFAULTS[key]
  end
  for i = 1, TILE_COUNT do
    local key = "tile" .. i
    values[key] = ui.config[key] or THEME_DEFAULTS[key]
  end
  values.arm_colors = ui.config.arm_colors or ARM_COLORS_DEFAULT
  values.scheme = ui.config.scheme or SCHEME_DEFAULT
  for i = 1, #SETTINGS do
    local entry = SETTINGS[i]
    values[entry.key] = ui.config[entry.key] or entry.default
  end
  values.link_switch = tonumber(ui.config.link_switch) or LINK_SWITCH_DEFAULT
  for i = 1, #KEYS do
    local entry = KEYS[i]
    values[entry.pref] = ui.config[entry.pref] or entry.default
  end
  DashboardLib.setThemeConfig(prefs, THEME_PATH, values, modelPrefs)

  -- The model's file is written whenever a flight controller is connected, as every theme's
  -- module does, but it carries this save's values only in the model scope: there its answer is
  -- what the save reports. In the standard scope the values went into the radio's preferences,
  -- which the page's own save writes, and this save changed nothing in the model's file -- a
  -- failure to rewrite it is not a failure of this save.
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

-- The host may hand this module a page of the theme's own `pages` table on `ctx.page`, in
-- which case only that page's section is built. `ctx.page == nil` -- a host that does not
-- know the field, or a theme entry that declared none -- means the whole page, which is what
-- the module has always built. Either way the configuration is loaded and saved whole, so a
-- page is a view of the form and never a slice of the stored values.
-- The declared rows of one page, in the order Layout.SETTINGS declares them, and one loop for
-- all of them rather than a hand-written block each: every one is the same control over the same
-- kind of value, and nine blocks would be nine chances for a row to write into another row's
-- key. Answers the cursor the caller continues from.
--
-- `lead` picks the rows declared to stand ahead of the slot choices (true) or the rest (nil).
local function appendSettings(children, x, cursorY, w, page, lead)
  for i = 1, #SETTINGS do
    local entry = SETTINGS[i]
    local here = entry.page == page and (entry.lead == true) == (lead == true)
    if here and entry.values == nil then
      -- A number row. Its upper bound can move with the row it may not exceed, which a field's
      -- fixed range cannot follow, so the bound is held here: a value above the named row is
      -- taken as that row's value, and raising or lowering any row pulls down every row that
      -- names it. The field reads its value back through `get`.
      local key = entry.key
      cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, SETTINGS_ROW_LABEL[key], {
        min = entry.min,
        max = entry.max,
        suffix = (SETTINGS_LABELS[key] or {}).suffix,
        get = function() return tonumber(ui.config[key]) or tonumber(entry.default) end,
        set = function(value)
          local n = wholeNumber(entry, value)
          if n == nil then return end
          local cap = entry.notAbove and tonumber(ui.config[entry.notAbove])
          if cap and n > cap then n = cap end
          ui.config[key] = tostring(n)
          holdNotAbove()
        end,
      })
    elseif here then
      local key = entry.key
      cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
        SETTINGS_ROW_LABEL[key], SETTINGS_OPTIONS[key], ui.config[key],
        function(value)
          if type(value) == "string" and SETTINGS_VALID[key][value] then
            ui.config[key] = value
          end
        end)
    end
  end
  return cursorY
end

-- The link view's switch: a label and the radio's own switch picker, laid out the way the host's
-- in-flight tuning page lays out its interlock row. Answers the cursor the caller continues from.
local function appendLinkSwitch(children, x, cursorY, w)
  local rowH = Controls.ROW_H or 40
  local pickerW = math.min(172, w)
  local labelY = (type(Controls.labelY) == "function") and Controls.labelY(cursorY, rowH) or cursorY
  local controlY = (type(Controls.controlY) == "function") and Controls.controlY(cursorY, rowH) or cursorY
  children[#children + 1] = {
    type = "label", x = x, y = labelY, w = w - pickerW - 18,
    text = "@i18n(app.pages.settings_dashboard_settings.urban_link_switch)@", color = COLOR_THEME_PRIMARY1, font = SMLSIZE
  }
  children[#children + 1] = {
    type = "switch", x = x + w - pickerW - 10, y = controlY, w = pickerW, h = rowH - 6,
    filter = SW_SWITCH | SW_LOGICAL_SWITCH | SW_NONE,
    get = function() return ui.config.link_switch or 0 end,
    set = function(value) ui.config.link_switch = tonumber(value) or 0 end
  }
  return cursorY + rowH
end

-- One row per key, in the order Layout.KEYS declares them. Every key is shown on every radio: a
-- radio without the key simply never sends it, and a model's settings stay the same across
-- radios. A key that Settings > Dashboard > Keys holds for every theme -- anything there but
-- Theme, its defaults included -- is marked so and cannot be changed here: what this page stores
-- for it would have no effect. Answers the cursor the caller continues from.
local KEY_HELD = { active = false }
local function appendKeys(children, x, cursorY, w, dashboard)
  for i = 1, #KEYS do
    local pref = KEYS[i].pref
    local label = "@i18n(app.pages.settings_dashboard_settings.urban_key)@ " .. (KEY_NAMES[KEYS[i].key] or KEYS[i].key)
    local held = GlobalKeys.global(dashboard, KEYS[i].key) ~= "theme"
    if held then label = label .. " " .. "@i18n(app.pages.settings_dashboard_settings.urban_key_global)@" end
    cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w, label,
      KEY_OPTIONS, ui.config[pref],
      function(value)
        if type(value) == "string" and KEY_VALID[value] then
          ui.config[pref] = value
        end
      end, held and KEY_HELD or nil)
  end
  return cursorY
end

function M.build(ctx)
  loadConfig(ctx.preferences)

  -- Every id init.lua declares has to stand here as well. One that does not falls through to
  -- `only == nil`, which renders the whole form on that one tile and says nothing about it.
  local pageId = ctx and ctx.page and ctx.page.id
  local only = (pageId == "look" or pageId == "layout" or pageId == "tiles" or pageId == "topbar"
    or pageId == "keys" or pageId == "telemetry") and pageId or nil

  local children = ctx.children
  local x, y, w = ctx.x, ctx.y, ctx.w
  local cursorY = y

  if only == nil or only == "look" then
    Controls.appendSectionHeader(children, x, cursorY, w,
      "@i18n(app.pages.settings_dashboard_settings.urban_page_look)@", true, function() end)
    cursorY = cursorY + Controls.SECTION_H

    cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
      "@i18n(app.pages.settings_dashboard_settings.urban_scheme)@", SCHEMES, ui.config.scheme,
      function(value)
        if SCHEMES_VALID[value] then
          ui.config.scheme = value
        end
      end)

    cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
      "@i18n(app.pages.settings_dashboard_settings.urban_arm_colors)@", ARM_COLORS, ui.config.arm_colors,
      function(value)
        if ARM_COLORS_VALID[value] then
          ui.config.arm_colors = value
        end
      end)

    cursorY = appendSettings(children, x, cursorY, w, "look")
  end

  if only == nil or only == "layout" then
    Controls.appendSectionHeader(children, x, cursorY, w,
      "@i18n(app.pages.settings_dashboard_settings.grid_page_layout)@", true, function() end)
    cursorY = cursorY + Controls.SECTION_H
    cursorY = appendSettings(children, x, cursorY, w, "layout")
  end

  if only == nil or only == "tiles" then
    Controls.appendSectionHeader(children, x, cursorY, w,
      "@i18n(app.pages.settings_dashboard_settings.grid_page_tiles)@", true, function() end)
    cursorY = cursorY + Controls.SECTION_H

    -- The grid size first: it decides how many of the slots below are drawn.
    cursorY = appendSettings(children, x, cursorY, w, "tiles", true)

    for i = 1, SLOT_COUNT do
      local key = "slot" .. i
      cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
        "@i18n(app.pages.settings_dashboard_settings.urban_tile)@ " .. i, OPTIONS, ui.config[key],
        function(value)
          if type(value) == "string" and VALID_IDS[value] then
            ui.config[key] = value
          end
        end)
    end

    cursorY = appendSettings(children, x, cursorY, w, "tiles")
  end

  if only == nil or only == "topbar" then
    Controls.appendSectionHeader(children, x, cursorY, w,
      "@i18n(app.pages.settings_dashboard_settings.urban_page_topbar)@", true, function() end)
    cursorY = cursorY + Controls.SECTION_H
    cursorY = appendSettings(children, x, cursorY, w, "topbar")
    cursorY = appendLinkSwitch(children, x, cursorY, w)
  end

  if only == nil or only == "keys" then
    Controls.appendSectionHeader(children, x, cursorY, w,
      "@i18n(app.pages.settings_dashboard_settings.urban_page_keys)@", true, function() end)
    cursorY = cursorY + Controls.SECTION_H
    cursorY = appendKeys(children, x, cursorY, w, type(ctx.preferences) == "table" and ctx.preferences.dashboard or nil)
  end

  if only == nil or only == "telemetry" then
    Controls.appendSectionHeader(children, x, cursorY, w,
      "@i18n(app.pages.settings_dashboard_settings.urban_page_telemetry)@", true, function() end)
    cursorY = cursorY + Controls.SECTION_H

    for i = 1, TILE_COUNT do
      local key = "tile" .. i
      cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
        "@i18n(app.pages.settings_dashboard_settings.urban_tile)@ " .. i, OPTIONS, ui.config[key],
        function(value)
          if type(value) == "string" and VALID_IDS[value] then
            ui.config[key] = value
          end
        end)
    end
  end
end

return function(ctx)
  local theme = ctx and ctx.theme
  if type(theme) == "table" and type(theme.path) == "string" and theme.path ~= "" then
    THEME_PATH = theme.path
  end
  return M
end
