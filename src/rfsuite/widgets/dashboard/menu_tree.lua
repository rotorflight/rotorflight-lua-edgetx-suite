-- The suite's menu as lists for the rolling menu (menu_roll.lua). app/manifest.lua stays the only
-- source of what is in it; this file reads it for a visit to the quick menu and says, per entry, what
-- the menu needs to know beyond its title:
--
--   what it is   `level` (a menu of entries), `page`, or `tiles` (a menu that opens in the tool with
--                its tiles: its entries depend on what only the tool reads, or are made at runtime)
--   whether it is there at all, here: a feature switched off, or firmware too old while connected,
--                is simply absent
--   whether it works now: no flight controller and armed are passing states, so such a row stays and
--                says why
--
-- The manifest is read outside the module cache: the tool fills its runtime menus into the table it
-- caches and drops that cache entry when it closes, and neither must reach this one. It is held on
-- the visit's session, so it goes when the quick menu closes or the tool opens.

local M = {}

local requireModule = (_G.rfsuite and _G.rfsuite.require) or function(path)
  local fullPath = string.sub(path, 1, 1) == "/" and path or (_G.rfsuite.paths.core .. "/" .. path)
  local chunk = loadScript(fullPath, "t")
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local Log = requireModule("lib/log.lua")

local TAG = "rfsuite.widget.roll"

local function trace(msg)
  if Log and type(Log.wanted) == "function" and Log.wanted("trace") then
    Log.emit(TAG, msg, "trace")
  end
end

-- Menus that open in the tool with their tiles. ESC & Motors: its entries depend on the ESC protocol,
-- which the widget's connect chain does not read.
local TILES = { esc_motors_menu = true }

-- What the manifest's preference conditions read. Not views.lua's conditions: one of the same name
-- means something else there, it also asks for the overlay's own switch and for the model disarmed.
local PREFERENCES = {
  developerTools = "developer_tools",
  previewSetupWizard = "preview_setup_wizard",
  previewInflightTuning = "preview_inflight_tuning",
}

local function preference(widget, name)
  local key = PREFERENCES[name]
  local general = widget.preferences and widget.preferences.general or nil
  return key ~= nil and type(general) == "table" and general[key] == true
end

local function parseVersion(value)
  if type(value) == "table" then
    local major, minor = tonumber(value[1]), tonumber(value[2])
    if major == nil or minor == nil then return nil end
    return major, minor, tonumber(value[3]) or 0
  end
  if type(value) ~= "string" then return nil end
  local major, minor, patch = string.match(value, "^(%d+)%.(%d+)%.(%d+)$")
  if major ~= nil then return tonumber(major), tonumber(minor), tonumber(patch) end
  major, minor = string.match(value, "^(%d+)%.(%d+)$")
  if major ~= nil then return tonumber(major), 0, tonumber(minor) end
  return nil
end

--- Whether the flight controller's API version reaches `required`: true or false, or nil while the
--- version is not known.
local function reaches(required)
  local session = _G.rfsuite and _G.rfsuite.session or nil
  local major, minor, patch = parseVersion(session and session.apiVersion or nil)
  if major == nil then return nil end
  local have = { major, minor, patch }
  for i = 1, 3 do
    local a, b = have[i], tonumber(required[i]) or 0
    if a > b then return true end
    if a < b then return false end
  end
  return true
end

--- Whether a flight controller has answered: the MSP runtime's word, not the dashboard's readiness,
--- which also waits for the telemetry and has a timeout of its own.
function M.connected()
  local session = _G.rfsuite and _G.rfsuite.session or nil
  return type(session) == "table" and session.fblConnected == true
end

-- Whether an entry is on the menu at all, as far as the widget can tell now.
local function exists(widget, entry)
  if entry.enabled == false then return false end
  local visibleWhen = entry.visibleWhen
  if visibleWhen ~= nil and not preference(widget, visibleWhen) then return false end
  -- An entry that disappears where its own condition does not hold.
  if entry.hideWhenDisabled == true and type(entry.enabledWhen) == "string"
    and PREFERENCES[entry.enabledWhen] ~= nil and not preference(widget, entry.enabledWhen) then
    return false
  end
  if entry.minApiVersion ~= nil and M.connected() and reaches(entry.minApiVersion) == false then return false end
  return true
end

-- The name a row's icon goes by: the motif of the manifest's own, else the menu it opens.
local function iconName(entry)
  local icon = entry.icon
  if type(icon) == "string" and string.sub(icon, 1, 7) == "@pages/" then
    return (string.gsub(string.gsub(string.sub(icon, 8), "%.png$", ""), "/", "_"))
  end
  return entry.menuId
end

local function loadManifest()
  local path = _G.rfsuite.paths.core .. "/app/manifest.lua"
  local chunk = loadScript(path, (_G.rfsuite and _G.rfsuite.loadMode) or "t")
  if chunk == nil then
    if Log and type(Log.emit) == "function" then Log.emit(TAG, "the manifest did not load", "warn") end
    return nil
  end
  local ok, manifest = pcall(chunk)
  if not ok or type(manifest) ~= "table" then
    if Log and type(Log.emit) == "function" then Log.emit(TAG, "the manifest did not run", "warn") end
    return nil
  end
  return manifest
end

--- The tree for this visit, read on the first call.
function M.of(widget, session)
  local tree = session.tree
  if tree ~= nil then return tree end
  tree = { manifest = loadManifest(), lists = {} }
  session.tree = tree
  trace("tree loaded " .. tostring(tree.manifest ~= nil))
  return tree
end

--- Forget the lists made so far: what is there may have changed since they were made.
function M.refresh(tree)
  tree.lists = {}
end

local function resolveTitle(widget, title)
  local i18n = widget.i18n
  if i18n and type(i18n.resolve) == "function" then return i18n.resolve(title) end
  return title
end

local function rowsOf(widget, tree, pages, inherited)
  local rows = {}
  local menus = tree.manifest.menus
  for i = 1, #pages do
    local entry = pages[i]
    if exists(widget, entry) then
      local menu = menus and menus[entry.menuId] or nil
      local kind = "page"
      if TILES[entry.menuId] == true or (menu ~= nil and menu._dynamicThemes == true) then
        kind = "tiles"
      elseif menu ~= nil and #(menu.pages or {}) > 0 then
        kind = "level"
      end
      local needsFc = inherited == true or entry.enabledWhen == "fblConnected"
        or (entry.minApiVersion ~= nil and reaches(entry.minApiVersion) ~= true)
      rows[#rows + 1] = {
        id = entry.id,
        title = resolveTitle(widget, entry.title or ""),
        menuId = entry.menuId,
        kind = kind,
        needsFc = needsFc,
        -- What is below inherits only the entry's own condition: a version gate is about this entry.
        below = inherited == true or entry.enabledWhen == "fblConnected",
        icon = iconName(entry),
        tree = true,
      }
    end
  end
  return rows
end

--- The top of the suite's menu: the sections' entries in their order.
function M.top(widget, tree)
  local lists = tree.lists
  if lists.top ~= nil then return lists.top end
  local pages = {}
  local sections = tree.manifest and tree.manifest.sections or {}
  for i = 1, #sections do
    local list = sections[i].pages or {}
    for k = 1, #list do pages[#pages + 1] = list[k] end
  end
  lists.top = rowsOf(widget, tree, pages, false)
  return lists.top
end

--- What a row of `kind` level holds; nil for any other row.
function M.children(widget, tree, row)
  if row.kind ~= "level" or tree.manifest == nil then return nil end
  local lists = tree.lists
  local rows = lists[row.menuId]
  if rows == nil then
    local menu = tree.manifest.menus[row.menuId]
    rows = rowsOf(widget, tree, menu.pages or {}, row.below)
    lists[row.menuId] = rows
  end
  return rows
end

return M
