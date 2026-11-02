-- Radio-wide fullscreen shortcuts. Theme choices stay in the theme's own table;
-- resolving a global override must never overwrite the keys a build will write again.
local M = {}

-- `default` is the choice a key has while the radio's preferences hold none for it: SYS opens
-- the suite's tool and TELE the quick menu, the two places a pilot on the full screen goes most,
-- and the page keys open the quick menu too -- on a theme that draws its own full screen they are
-- the key path to it, and where full screen is the quick menu they answer with it. MDL is left to
-- the theme. The defaults live here and nowhere else, so the
-- Keys page, the widget and the themes' own key pages (which mark the keys held here) cannot
-- disagree about them.
M.KEYS = {
  { id = "pageDown", pref = "key_page_down", default = "menu" },
  { id = "pageUp", pref = "key_page_up", default = "menu" },
  { id = "mdl", pref = "key_mdl", default = "theme" },
  { id = "sys", pref = "key_sys", default = "suite_tool" },
  { id = "tele", pref = "key_tele", default = "menu" },
}
M.OPTIONS = {
  { value = "theme", label = "@i18n(app.pages.settings_dashboard_keys.theme)@" },
  { value = "none", label = "@i18n(app.pages.settings_dashboard_keys.none)@" },
  { value = "menu", label = "@i18n(app.pages.settings_dashboard_keys.menu)@" },
  { value = "suite_tool", label = "@i18n(app.pages.settings_dashboard_keys.suite_tool)@" },
  { value = "flight_log", label = "@i18n(app.pages.settings_dashboard_keys.flight_log)@" },
  { value = "exit", label = "@i18n(app.pages.settings_dashboard_keys.exit)@" },
  { value = "inflight_tuning", label = "@i18n(app.pages.settings_dashboard_keys.inflight_tuning)@" },
}
local ACTIONS = {
  none = "none", menu = "openView:menu", suite_tool = "openTool",
  flight_log = "openTool:tools_flight_log_page", exit = "exitFullscreen",
  inflight_tuning = "openTuning",
}
local BY_ID = {}
for i = 1, #M.KEYS do BY_ID[M.KEYS[i].id] = M.KEYS[i] end

-- A stored choice as one of the page's values. Theme is a choice of its own, stored as one where
-- it is not the key's default; anything absent or unknown is the key's default.
function M.choice(value, name)
  if value == "theme" or (type(value) == "string" and ACTIONS[value] ~= nil) then return value end
  local entry = BY_ID[name]
  return entry and entry.default or "theme"
end

-- The choice in force for key `name` on this radio: the stored one, else the key's default.
-- Anything but "theme" holds the key for every theme.
function M.global(dashboard, name)
  local entry = BY_ID[name]
  if entry == nil then return "theme" end
  return M.choice(type(dashboard) == "table" and dashboard[entry.pref] or nil, name)
end

-- The keys a theme that declares boxes rather than drawing its own tree binds on its Keys
-- settings page: the stored setting and the choices, the host's actions. A theme that draws its
-- own tree fills `ctx.keys` itself and offers its own views besides (themes/urban/layout.lua).
-- Unbound is the default, so a key stays with what the radio-wide page and the theme's manifest
-- give it until the pilot chooses.
M.THEME_KEYS = {
  { id = "pageDown", pref = "theme_key_page_down" },
  { id = "pageUp", pref = "theme_key_page_up" },
  { id = "mdl", pref = "theme_key_mdl" },
  { id = "sys", pref = "theme_key_sys" },
  { id = "tele", pref = "theme_key_tele" },
}
M.THEME_OPTIONS = {
  { value = "none", label = "@i18n(app.pages.settings_dashboard_keys.none)@" },
  { value = "menu", label = "@i18n(app.pages.settings_dashboard_keys.menu)@" },
  { value = "suite_tool", label = "@i18n(app.pages.settings_dashboard_keys.suite_tool)@" },
  { value = "flight_log", label = "@i18n(app.pages.settings_dashboard_keys.flight_log)@" },
  { value = "exit", label = "@i18n(app.pages.settings_dashboard_keys.exit)@" },
}

-- The bindings such a theme's configuration holds, laid over its manifest's `keys`: a table in
-- the shape `resolve` reads as declared keys, or `declared` itself where the pilot bound nothing.
-- A stored Nothing is a binding too: it silences a key the manifest binds.
function M.themeBindings(config, declared)
  if type(config) ~= "table" then return declared end
  local out = nil
  for i = 1, #M.THEME_KEYS do
    local entry = M.THEME_KEYS[i]
    local action = ACTIONS[config[entry.pref]]
    if action ~= nil then
      if out == nil then
        out = {}
        if type(declared) == "table" then
          for k, v in pairs(declared) do out[k] = v end
        end
      end
      out[entry.id] = action
    end
  end
  return out or declared
end

-- The second result distinguishes a radio-wide choice from the theme's binding, and a deliberate
-- Nothing from an absent binding. A key on Theme uses `ctx.keys`, then the manifest's `keys`,
-- then nothing. Short RTN has no preference: view back/close and firmware long RTN keep ownership.
function M.resolve(dashboard, name, themeKeys, declaredKeys)
  local choice = M.global(dashboard, name)
  if choice ~= "theme" then return ACTIONS[choice], true end
  local action = type(themeKeys) == "table" and themeKeys[name] or nil
  if action == nil and type(declaredKeys) == "table" then action = declaredKeys[name] end
  return action, false
end

return M
