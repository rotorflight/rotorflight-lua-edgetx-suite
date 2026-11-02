-- Dynamic dashboard settings menu builder
-- Reuses the dashboard settings library so menus and pages discover
-- the exact same theme set at runtime.

local function loadModule(path)
  local chunk = assert(loadScript(_G.rfsuite.paths.core .. "/" .. path, "t"))
  return chunk()
end

local DashboardLib = loadModule("app/pages/settings/dashboard/lib.lua")
local Log = loadModule("lib/log.lua")
local FALLBACK_ICON = "@pages/settings/dashboard/settings/icon.png"
local OVERRIDES_ICON = "@pages/settings/dashboard/overrides/icon.png"
local DEBUG_PREFIX = "[dashboard.builder] "

-- The build reports in ONE debug line, written when it ends, for the reason lib.lua's theme scan
-- does: opened from the dashboard, the build runs inside the widget's per-call instruction limit,
-- and a line per theme and per theme page -- built whether or not the level lets it out -- is a
-- cost that grows with every theme that ships. The list is a table only while that line is
-- wanted, so nothing is collected below the debug level.
local function logTheme(list, index, t)
  local pages = type(t.pages) == "table" and #t.pages or 0
  list[index] = pages > 0 and (tostring(t.path) .. "(" .. pages .. " pages)") or tostring(t.path)
end

-- The theme path as hex, which is how it travels inside a menu id. One call into C for the whole
-- string rather than a concatenation per byte; theme paths are folder names, far shorter than
-- anything string.byte could not return at once.
local function hexEncode(input)
  if type(input) ~= "string" or input == "" then return "" end
  return string.format(string.rep("%02x", #input), string.byte(input, 1, -1))
end

-- Every theme is reachable in two scopes, and the menu id says which: the grid of the Settings
-- tile edits the radio's standard values, the model overrides page edits the connected model's.
-- The settings page reads the scope off the id's prefix, so the two never share a cached module.
local STANDARD_SCOPE = { menuPrefix = "settings_dashboard_settings_", idPrefix = "dashboard_settings_" }
local MODEL_SCOPE = { menuPrefix = "settings_dashboard_model_", idPrefix = "dashboard_model_" }
local OVERRIDES_MENU_ID = "settings_dashboard_overrides_page"
local OVERRIDES_TITLE = "@i18n(app.modules.dashboard_overrides.name)@"

-- The grid a theme's own tile opens when the theme declares pages: one tile per page, laid out
-- like the theme grid above it. Each tile opens the same settings page under a menu id that
-- carries the page id, which is how the page knows which half of the theme it is showing.
local function buildThemePageMenu(t, token, themeIcon, menus, scope)
  local menuId = scope.menuPrefix .. token .. "_menu"
  local pages = {}

  for i = 1, #t.pages do
    local page = t.pages[i]
    local pageMenuId = scope.menuPrefix .. token .. "_" .. page.id .. "_page"
    pages[#pages + 1] = {
      id = scope.idPrefix .. token .. "_" .. page.id,
      title = page.title,
      menuId = pageMenuId,
      icon = page.iconPath or themeIcon,
      row = math.floor((i - 1) / 6) + 1,
      col = ((i - 1) % 6) + 1,
      themePath = t.path
    }
    menus[pageMenuId] = {
      title = page.title,
      pages = {},
      themePath = t.path
    }
  end

  menus[menuId] = {
    title = t.name,
    pages = pages,
    themePath = t.path
  }

  return menuId
end

-- One theme's entry in a scope's list, with the menus it opens registered beside it.
local function buildThemeEntry(t, token, index, menus, scope)
  local themeIcon = t.iconPath or FALLBACK_ICON
  local menuId
  if type(t.pages) == "table" then
    menuId = buildThemePageMenu(t, token, themeIcon, menus, scope)
  else
    menuId = scope.menuPrefix .. token .. "_page"
    menus[menuId] = {
      title = t.name,
      pages = {},
      themePath = t.path
    }
  end
  return {
    id = scope.idPrefix .. token,
    title = t.name,
    menuId = menuId,
    icon = themeIcon,
    row = math.floor((index - 1) / 6) + 1,
    col = ((index - 1) % 6) + 1,
    themePath = t.path
  }
end

-- The model overrides tile exists only while it has something to edit: a flight controller is
-- connected, so the model's store can be addressed, and overrides are on for that model and
-- allowed on this radio. Asked whenever the grid is drawn or entered, so turning overrides on
-- under Design shows the tile the next time the grid is opened.
local function modelOverridesVisible()
  local root = type(_G) == "table" and _G.rfsuite or nil
  local session = root and root.session
  if type(session) ~= "table" or session.mcu_id == nil then return false end
  local modelPrefs = session.modelPreferences
  if type(modelPrefs) ~= "table" then return false end
  local prefs = root.preferences
  local dashboard = type(prefs) == "table" and prefs.dashboard or nil
  return DashboardLib.modelOverridesActive(dashboard, modelPrefs.dashboard) == true
end

-- How many themes one step of the build takes on, both scopes each. A budget rather than a
-- measured optimum, like the caps in lib/precompile.lua: it bounds what one call may do, so the
-- step costs the same however many themes are installed, and a menu of many themes takes more
-- steps instead of a dearer one.
local THEMES_PER_STEP = 4

-- The menu, built over as many calls as it takes. Opened from the dashboard, the tool runs
-- inside the widget's per-call instruction limit, and a call stopped there leaves behind only
-- what it already stored -- so the work is cut into steps that each fit a call, and what a step
-- finishes is kept in the job rather than in the call. The first steps take the theme scan, a few
-- folder entries each (newThemeScan in app/pages/settings/dashboard/lib.lua), every later one up
-- to THEMES_PER_STEP themes. Each theme is stored by its index and the job moves past it only
-- once both of its entries are in, so a step stopped part way through repeats that one theme and
-- nothing before it.
--
-- `step()` answers true once the menu is complete, and from then on `entries` and `menus` hold
-- it; until then neither is filled, so a caller has the whole menu or none of it.
local function newThemeMenuBuild()
  local job = { entries = nil, menus = nil }
  local scan, themes, entries, modelEntries, menus, buildLog
  local nextTheme = 1

  local function finish()
    if buildLog then
      Log.emit("dashboard.builder", string.format("%sthemes=%d entries=%d: %s", DEBUG_PREFIX, #themes,
        #entries, table.concat(buildLog, ", ")), "debug")
    end
    -- `entries` last: it is what says the job is complete.
    job.menus = menus
    job.entries = entries
    return true
  end

  function job.step()
    if job.entries then return true end

    if themes == nil then
      scan = scan or DashboardLib.newThemeScan()
      if not scan.step() then return false end
      local found = DashboardLib.getConfigurableThemes(scan.themes)
      local first, firstModel, firstMenus = {}, {}, {}
      -- The overview is a page, and its theme entries are what its buttons open: the menu
      -- registry opens an entry of the current menu id's list, and that id is the page's own. Its
      -- tile comes first, ahead of the themes: it is the one tile that is about the connected
      -- model, and the grid lays out only the tiles it shows, so while it is hidden the themes
      -- start the grid.
      if #found > 0 then
        firstMenus[OVERRIDES_MENU_ID] = {
          title = OVERRIDES_TITLE,
          pages = firstModel
        }
        first[1] = {
          id = "dashboard_overrides",
          title = OVERRIDES_TITLE,
          menuId = OVERRIDES_MENU_ID,
          icon = OVERRIDES_ICON,
          row = 1,
          col = 1,
          visibleWhen = modelOverridesVisible
        }
      end
      entries, modelEntries, menus = first, firstModel, firstMenus
      buildLog = (Log and Log.wanted("debug") == true) and {} or nil
      themes = found
      if #themes == 0 then return finish() end
      return false
    end

    local last = math.min(#themes, nextTheme + THEMES_PER_STEP - 1)
    for i = nextTheme, last do
      local t = themes[i]
      local token = hexEncode(t.path)
      -- The overrides tile is entry 1, so a theme's place in the grid is one further on.
      entries[i + 1] = buildThemeEntry(t, token, i + 1, menus, STANDARD_SCOPE)
      modelEntries[i] = buildThemeEntry(t, token, i, menus, MODEL_SCOPE)
      if buildLog then logTheme(buildLog, i, t) end
      nextTheme = i + 1
    end

    if nextTheme > #themes then return finish() end
    return false
  end

  return job
end

return {
  newThemeMenuBuild = newThemeMenuBuild
}
