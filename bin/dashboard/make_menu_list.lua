-- Makes widgets/dashboard/menu_list.lua from app/manifest.lua: only what the rolling menu reads, so a visit
-- to the quick menu does not hold the whole manifest. Run it after changing the manifest.
--   lua5.3 bin/dashboard/make_menu_list.lua           writes the list
--   lua5.3 bin/dashboard/make_menu_list.lua --check   exit 1 where the list is stale; changes nothing
-- Run from the repository root.

local MANIFEST = "src/rfsuite/app/manifest.lua"
local LIST = "src/rfsuite/widgets/dashboard/menu_list.lua"

-- Menus that open in the tool with their tiles. ESC & Motors: its entries depend on the ESC protocol, which
-- the widget's connect chain does not read. Nothing below such a menu goes into the list.
local TILES = { esc_motors_menu = true }

-- An entry's fields as the list writes them, in this order. `kind` and `icon` are left out where the
-- reader's default says the same.
local FIELDS = { "id", "title", "menuId", "kind", "icon", "visibleWhen", "enabledWhen", "hideWhenDisabled", "minApiVersion" }

local function quoted(value)
  if type(value) == "table" then
    local parts = {}
    for i = 1, #value do parts[i] = string.format("%q", value[i]) end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end
  if type(value) == "string" then return string.format("%q", value) end
  return tostring(value)
end

local function kindOf(manifest, entry)
  local menu = manifest.menus[entry.menuId]
  if TILES[entry.menuId] == true or (menu ~= nil and menu._dynamicThemes == true) then return "tiles" end
  if menu ~= nil and #(menu.pages or {}) > 0 then return "level" end
  return nil
end

-- The name a row's picture goes by: the motif of the manifest's own icon, else the menu it opens.
local function iconOf(entry)
  local icon = entry.icon
  if type(icon) == "string" and string.sub(icon, 1, 7) == "@pages/" then
    local name = string.gsub(string.gsub(string.sub(icon, 8), "%.png$", ""), "/", "_")
    if name ~= entry.menuId then return name end
  end
  return nil
end

local function entryLine(manifest, entry)
  local values = {
    id = entry.id,
    title = entry.title or "",
    menuId = entry.menuId,
    kind = kindOf(manifest, entry),
    icon = iconOf(entry),
    visibleWhen = entry.visibleWhen,
    enabledWhen = entry.enabledWhen,
    hideWhenDisabled = entry.hideWhenDisabled,
    minApiVersion = entry.minApiVersion,
  }
  local parts = {}
  for i = 1, #FIELDS do
    local value = values[FIELDS[i]]
    if value ~= nil then parts[#parts + 1] = FIELDS[i] .. " = " .. quoted(value) end
  end
  return "{ " .. table.concat(parts, ", ") .. " },"
end

local function entriesOf(pages)
  local kept = {}
  for i = 1, #pages do
    if pages[i].enabled ~= false then kept[#kept + 1] = pages[i] end
  end
  return kept
end

--- The list's text for a manifest.
local function render(manifest)
  local lines = {
    "-- Generated from app/manifest.lua by bin/dashboard/make_menu_list.lua. Do not edit: change the manifest",
    "-- and run that script.",
    "return {",
    "  top = {",
  }
  local below = {}
  local function take(entry)
    if kindOf(manifest, entry) == "level" then below[#below + 1] = entry.menuId end
    lines[#lines + 1] = "    " .. entryLine(manifest, entry)
  end
  for _, section in ipairs(manifest.sections) do
    local pages = entriesOf(section.pages or {})
    for i = 1, #pages do take(pages[i]) end
  end
  lines[#lines + 1] = "  },"
  lines[#lines + 1] = "  menus = {"
  local seen = {}
  local at = 1
  while below[at] ~= nil do
    local menuId = below[at]
    at = at + 1
    if not seen[menuId] then
      seen[menuId] = true
      lines[#lines + 1] = "    " .. menuId .. " = {"
      local pages = entriesOf(manifest.menus[menuId].pages)
      for i = 1, #pages do
        local entry = pages[i]
        if kindOf(manifest, entry) == "level" then below[#below + 1] = entry.menuId end
        lines[#lines + 1] = "      " .. entryLine(manifest, entry)
      end
      lines[#lines + 1] = "    },"
    end
  end
  lines[#lines + 1] = "  },"
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n") .. "\n"
end

local function loadManifest()
  _G.rfsuite = { paths = { core = "/SCRIPTS/RFSUITE/core", user = "/SCRIPTS/RFSUITE/user" } }
  return assert(loadfile(MANIFEST))()
end

local text = render(loadManifest())

if arg[1] == "--check" then
  -- The control: a change to the manifest has to change the text, or a pass below says nothing.
  local planted = loadManifest()
  local pages = planted.sections[1].pages
  pages[#pages + 1] = { id = "planted", title = "Planted", menuId = "planted_page" }
  if render(planted) == text then
    print("make_menu_list: the control failed, a new entry did not change the list")
    os.exit(1)
  end
  local file = io.open(LIST, "rb")
  local current = file and string.gsub(file:read("a"), "\r\n", "\n") or nil
  if file then file:close() end
  if current ~= text then
    print("make_menu_list: " .. LIST .. " is stale against " .. MANIFEST .. ": run lua5.3 bin/dashboard/make_menu_list.lua")
    os.exit(1)
  end
  print("make_menu_list: the list is current")
  os.exit(0)
elseif arg[1] ~= nil then
  io.stderr:write("usage: lua5.3 bin/dashboard/make_menu_list.lua [--check]\n")
  os.exit(2)
end

local file = assert(io.open(LIST, "wb"))
file:write(text)
file:close()
print("make_menu_list: wrote " .. LIST)
