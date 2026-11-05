-- Host regression checks for the Goosky ESC telemetry protocol and its ESC Tools tile.
--
--     lua5.3 bin/esc/verify_goosky.lua [repository root]
--
-- The firmware's protocol list is append-only by number: from API 12.10 it reads SRXL2 14,
-- RECORD 15, GOOSKY 16, and a board stores whatever number it is sent. So the Telemetry page is
-- built here at each API level and the numbers are read off the options it offers, not the
-- labels. The tiles run through the real manifest and the real menu registry, with the block of
-- ui/home.lua that sets their conditions.
local root = (arg and arg[1]) or "."
local function source(path) return root .. "/" .. path end

local failures, checks = 0, 0
local function check(label, ok, detail)
  checks = checks + 1
  if ok then
    print("  ok    " .. label)
  else
    failures = failures + 1
    print("  FAIL  " .. label .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
  end
end

local function readFile(path)
  local f = io.open(source(path), "rb")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

local function cardPaths()
  local chunk = loadfile(source("src/rfsuite/lib/paths.lua"))
  return chunk and chunk() or nil
end

local Palette = assert(loadfile(source("src/rfsuite/ui/palette.lua")))()
_G.rfsuite = { palette = Palette, paths = cardPaths() }
local ConfigApi = assert(loadfile(source("src/rfsuite/tasks/msp/api/esc_sensor_config.lua")))()
local TrialApi = assert(loadfile(source("src/rfsuite/tasks/msp/api/esc_sensor_trial.lua")))()
local Common = assert(loadfile(source("src/rfsuite/app/pages/settings/common.lua")))()
local ApiVersion = assert(loadfile(source("src/rfsuite/lib/api_version.lua")))()

_G.getTime = function() return 100 end
_G.COLOR_THEME_SECONDARY1 = 1
_G.SMLSIZE = 1
_G.MIDSIZE = 2

local offered = nil
local rowsWithHelp, rows = 0, 0
local function countRow(opts)
  rows = rows + 1
  if type(opts) == "table" and type(opts.helpText) == "string" and opts.helpText ~= "" then
    rowsWithHelp = rowsWithHelp + 1
  end
  return 1
end

local queued = {}
local modules = {
  ["app/pages/settings/common.lua"] = Common,
  ["ui/palette.lua"] = Palette,
  ["ui/controls.lua"] = {
    STATIC_SECTION_H = 1,
    appendStaticSectionHeader = function() end,
    appendComboSelect = function(_, _, _, _, _, options, _, _, opts)
      offered = options
      return countRow(opts)
    end,
    appendRadioSwitch = function(_, _, _, _, _, _, _, _, opts) return countRow(opts) end,
    appendNumberField = function(_, _, _, _, _, opts) return countRow(opts) end
  },
  ["tasks/msp/runtime.lua"] = {
    getState = function()
      return { queue = { add = function(_, message) queued[#queued + 1] = message end } }
    end
  },
  ["tasks/msp/api/esc_sensor_config.lua"] = ConfigApi,
  ["tasks/msp/api/esc_sensor_trial.lua"] = TrialApi,
  ["ui/loading_overlay.lua"] = { append = function() end },
  ["ui/confirm_dialog.lua"] = {},
  ["lib/api_version.lua"] = ApiVersion,
  ["lib/armed.lua"] = {
    isArmed = function() return false end,
    isUncertain = function() return false end,
    changeCount = function() return 0 end
  },
  ["tasks/msp/save_pipeline.lua"] = {
    takeResult = function() end,
    start = function() return true end
  }
}

_G.loadScript = function(path)
  local relative = string.match(path, "RFSUITE/core/(.+)$")
  local value = modules[relative]
  if not value then return nil end
  return function() return value end
end

local configReply = { 1, 0, 200, 0, 52, 18, 120, 86, 9, 30, 0, 3, 4, 5 }

-- The options the real page offers at one API level, as { label = value }.
local function optionsAt(apiVersion)
  queued, offered, rows, rowsWithHelp = {}, nil, 0, 0
  _G.rfsuite = { palette = Palette, paths = cardPaths(), session = {
    signature = "board", apiVersion = apiVersion, isConnected = true, fblConnected = true,
    setup_esc_motors_telemetry = {
      protocol = 1, half_duplex = 0, pin_swap = 0,
      voltage_correction = 0, current_correction = 0, consumption_correction = 0,
      parsedCache = ConfigApi.parse(configReply)
    }
  } }
  local page = assert(loadfile(source("src/rfsuite/app/pages/setup/esc_motors/telemetry/page.lua")))()
  page.wakeup({ requestRebuild = function() end })
  if queued[1] and queued[1].command == ConfigApi.command then
    queued[1].processReply(queued[1], configReply)
  end
  page.build({ children = {}, x = 0, y = 0, w = 600, h = 400, i18n = {}, requestRebuild = function() end })
  local byLabel, values = {}, {}
  for i = 1, #(offered or {}) do
    byLabel[offered[i].label] = offered[i].value
    values[offered[i].value] = offered[i].label
  end
  return byLabel, values, #(offered or {})
end

print("telemetry page: what each API level is offered")
do
  local at10, values10, count10 = optionsAt("12.0.10")
  check("12.10 offers GOOSKY at 16", at10.GOOSKY == 16, at10.GOOSKY)
  check("12.10 keeps RECORD at 15", at10.RECORD == 15, at10.RECORD)
  check("12.10 keeps SRXL2 at 14", at10.SRXL2 == 14, at10.SRXL2)
  check("12.10 keeps BLHELI32 at 1", at10.BLHELI32 == 1, at10.BLHELI32)
  check("12.10 has no gap in its numbers", count10 == 17 and values10[16] == "GOOSKY", count10)
  check("every row of the page has its own help", rows > 0 and rows == rowsWithHelp,
    tostring(rowsWithHelp) .. " of " .. tostring(rows))

  local at9, _, count9 = optionsAt("12.0.9")
  check("12.9 is not offered GOOSKY", at9.GOOSKY == nil, at9.GOOSKY)
  check("12.9 keeps RECORD at 14", at9.RECORD == 14, at9.RECORD)
  check("12.9 keeps its fifteen entries", count9 == 15, count9)

  local at8 = optionsAt("12.0.8")
  check("12.8 is not offered GOOSKY", at8.GOOSKY == nil, at8.GOOSKY)
  check("12.8 keeps RECORD at 13", at8.RECORD == 13, at8.RECORD)
end

-- The block of ui/home.lua that sets the conditions, from the loop to the mark it writes last,
-- run as written against the real registry.
local function homeConditionBlock()
  local home = readFile("src/rfsuite/ui/home.lua") or ""
  home = string.gsub(home, "\r\n", "\n")
  local start = string.find(home, "  for _, p in ipairs(ESC_PROTOCOLS) do", 1, true)
  local stop = string.find(home, "  if state.menu._conditionsVersion ~= initialVersion then", 1, true)
  if not start or not stop then return nil end
  local list = string.match(home, "local ESC_PROTOCOLS = %b{}")
  local text = list .. "\nlocal state, proto = ...\n" .. string.sub(home, start, stop - 1)
  return assert(load(text, "=home.lua conditions"))
end

print("ESC Tools: which tiles each protocol lights")
do
  _G.rfsuite = { palette = Palette, paths = cardPaths(), session = { apiVersion = "12.0.10" } }
  local manifest = assert(loadfile(source("src/rfsuite/app/manifest.lua")))()
  local Registry = assert(loadfile(source("src/rfsuite/app/menu_registry.lua")))()
  local menu = Registry.new(manifest, nil, {
    conditions = { fblConnected = true, modelArmed = false },
    apiVersionProvider = function() return "12.0.10" end
  })
  local block = homeConditionBlock()
  check("the condition block of ui/home.lua was found", block ~= nil)

  local byId = {}
  local tools = manifest.menus and manifest.menus.esc_tools_menu
  check("the ESC Tools menu exists", tools ~= nil)
  for _, entry in ipairs(tools and tools.pages or {}) do byId[entry.id] = entry end
  check("the Goosky tile exists", byId.goosky ~= nil)

  -- Walk to the menu the way a pilot does, so the answer is the registry's own for that tile.
  for _, section in ipairs(manifest.sections or {}) do
    for _, entry in ipairs(section.pages or {}) do
      if entry.id == "setup" then menu.openRootEntry(section.id, "setup") end
    end
  end
  menu.openEntry("esc_motors")
  menu.openEntry("esc_tools")
  check("the walk reached the ESC Tools menu", menu.getCurrentMenuId() == "esc_tools_menu", menu.getCurrentMenuId())

  local function lit(id)
    if not byId[id] then return nil end
    return menu.isEntryEnabled(id)
  end

  local function setProtocol(proto)
    if block then block({ menu = menu }, proto) end
  end

  local cases = {
    { proto = 1,  am32 = true,  goosky = true,  blheli_s = true,  bluejay = true,  flrtr = false },
    { proto = 16, am32 = true,  goosky = true,  blheli_s = false, bluejay = false, flrtr = false },
    { proto = 10, am32 = false, goosky = false, blheli_s = false, bluejay = false, flrtr = true },
    { proto = 15, am32 = false, goosky = false, blheli_s = false, bluejay = false, flrtr = false },
    { proto = 0,  am32 = false, goosky = false, blheli_s = false, bluejay = false, flrtr = false }
  }
  for _, case in ipairs(cases) do
    setProtocol(case.proto)
    for _, id in ipairs({ "am32", "goosky", "blheli_s", "bluejay", "flrtr" }) do
      check(string.format("protocol %d: %s %s", case.proto, id, case[id] and "lit" or "dark"),
        lit(id) == case[id], lit(id))
    end
  end
  setProtocol(nil)
  check("no protocol read yet: AM32 dark", lit("am32") == false, lit("am32"))
  check("no protocol read yet: Goosky dark", lit("goosky") == false, lit("goosky"))

  local goosky = byId.goosky or {}
  check("the tile is locked while armed", goosky.lockedWhileArmed == true)
  check("the tile needs no API floor: BLHELI32 on older firmware lights it", goosky.minApiVersion == nil)
  check("the page is titled for the brand",
    manifest.menus and manifest.menus.setup_esc_motors_esc_tools_goosky_page ~= nil
    and manifest.menus.setup_esc_motors_esc_tools_goosky_page.title == "Goosky Configurator")

  local icon = goosky.icon and string.match(goosky.icon, "^@pages/(.+)$")
  local iconFile = icon and io.open(source("src/rfsuite/app/pages/" .. icon), "rb")
  check("the tile's icon is in the tree", iconFile ~= nil, goosky.icon)
  if iconFile then iconFile:close() end
end

print("page registry: the Goosky id opens the AM32 page")
do
  _G.rfsuite = { palette = Palette, paths = cardPaths(), session = {} }
  local registry = assert(loadfile(source("src/rfsuite/app/pages/init.lua")))()
  local paths = registry.pagePathByMenuId or {}
  check("the id is registered", paths.setup_esc_motors_esc_tools_goosky_page ~= nil)
  check("it is the AM32 page file, not a copy",
    paths.setup_esc_motors_esc_tools_goosky_page == paths.setup_esc_motors_esc_tools_am32_page,
    paths.setup_esc_motors_esc_tools_goosky_page)
end

print("")
if failures == 0 then
  print(string.format("all %d checks passed", checks))
  os.exit(0)
end
print(string.format("%d of %d checks FAILED", failures, checks))
os.exit(1)
