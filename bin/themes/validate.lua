-- Checks a dashboard theme that takes fullscreen (`fullscreen = "theme"` in its init.lua) for the
-- duties docs/developer/dashboard-themes.md gives it, and the views a theme registers, offline,
-- with desktop Lua 5.3.
--
--   lua5.3 bin/themes/validate.lua <theme folder> [--size 800x480|480x272]
--
-- Every phase module the theme declares is built at the fullscreen size with a recording `ctx`,
-- and every press in the tree it returns is fired. The theme is red where
--
--   * no press opens the quick menu (`openView:menu`, or the menu built through `ctx.menu`);
--   * nothing leaves fullscreen: no press with `exitFullscreen`, no `ctx.keys.exit =
--     "exitFullscreen"` -- RTN is on every radio, so that binding is a way out -- and no
--     `fullscreenExit = "longRtn"` in init.lua, the author relying on a long press on RTN;
--   * a `rectangle` lies over a node that has a press: built in fullscreen it takes the press
--     and hands it to its parent, so it swallows every press that lands on it;
--   * a press or a `ctx.keys` entry names an action that is not one of `openView:<id>`,
--     `closeView`, `done`, `exitFullscreen`, `openTool`, `openTool:<menuId>` and `none`, or a view
--     or a tool page the widget does not have;
--   * a `ctx.keys` entry is not one of the keys the widget answers -- `exit`, `pageDown`,
--     `pageUp`, `mdl`, `sys`, `tele`. Only `exit` counts as a way out: MDL, SYS and TELE are
--     not on every radio;
--   * a build raises, or returns something that is not a node list.
--
-- A tree that binds no press at all is green: the widget draws its own menu control and X over
-- it. So is a declarative theme, which cannot bind a press. A theme without the key is not
-- checked for these. Exit status 0 green, 1 red, 2 when the theme cannot be read.
--
-- The views a theme registers (`views` in init.lua) are checked whether it takes fullscreen or
-- not. Each module is built -- a fullscreen view with the recording `ctx`, its presses fired and
-- held to the rules above; a zone view without one -- and a view is red where
--
--   * an entry has no `id` or `module`, or a `where` that is not "fullscreen", "zone" or "both";
--   * its module does not load or has no build(), or a build raises;
--   * a zone view binds a press, or has no `openWhen` and so never shows;
--   * `openWhen` names a condition the widget does not have, a switch that is none of the names
--     a radio gives by default (SA to SR, SW1 to SW6, FL1 to FL4, L01 to L64), a physical switch
--     without `pos`, switch 0, or a setting its settings page -- the `configure` module and the
--     theme files it loads -- does not name, or reads a setting without a `default`. A number is
--     a stored switch position, as the widget reads it, and a `default` of 0 is "no switch";
--   * `openWhen` is a function that raises on the fixture state of a phase, or costs more than
--     CONDITION_BUDGET instructions per call on any of them.
--
-- The firmware and the widget are stubbed here, in this file: a theme is only ever called with
-- a zone, a state and a ctx, and a stub answers rather than computes. The state is a fixture of
-- typical readings, so a theme that reads something else sees nil, as it may on a radio before
-- the first telemetry. The quick menu's records a theme reaches through `ctx` are the widget's
-- own (widgets/dashboard/fullscreen_menu.lua); `ctx.run` looks the entry and the option up again
-- among them, as the widget does, refuses what the menu does not have, and records the action
-- that would follow rather than doing the work.

local USAGE = "usage: lua5.3 bin/themes/validate.lua <theme folder> [--size 800x480|480x272]"

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]themes$") or (dir .. "/../..") end
end

local folder, width, height = nil, 800, 480
do
  local i = 1
  while arg[i] do
    if arg[i] == "--size" then
      local w, h = string.match(arg[i + 1] or "", "^(%d+)x(%d+)$")
      if not w then io.stderr:write(USAGE .. "\n") os.exit(2) end
      width, height = tonumber(w), tonumber(h)
      i = i + 2
    elseif folder == nil then
      folder = string.gsub(arg[i], "[/\\]+$", "")
      i = i + 1
    else
      io.stderr:write(USAGE .. "\n")
      os.exit(2)
    end
  end
end
if folder == nil then io.stderr:write(USAGE .. "\n") os.exit(2) end
local folderName = string.match(folder, "([^/\\]+)$")

-- ---------------------------------------------------------------------------
-- Stubs
-- ---------------------------------------------------------------------------

local exits = 0

local consts = {
  WHITE = 0xFFFF, BLACK = 0x0000, RED = 0xF800, GREEN = 0x07E0, YELLOW = 0xFFE0, BLUE = 0x001F,
  MAGENTA = 0xF81F, CYAN = 0x07FF, GREY = 0x8410, DARKGREY = 0x4208, LIGHTGREY = 0xC618,
  ORANGE = 0xFD20, BROWN = 0x8200, DARKGREEN = 0x0400, DARKRED = 0x8000, DARKBLUE = 0x0010,
  COLOR_THEME_PRIMARY1 = 1, COLOR_THEME_PRIMARY2 = 2, COLOR_THEME_PRIMARY3 = 3,
  COLOR_THEME_SECONDARY1 = 4, COLOR_THEME_SECONDARY2 = 5, COLOR_THEME_SECONDARY3 = 6,
  COLOR_THEME_WARNING = 7, COLOR_THEME_DISABLED = 8, COLOR_THEME_FOCUS = 9,
  COLOR_THEME_ACTIVE = 10, COLOR_THEME_EDIT = 11,
  XXLSIZE = 0x800, XLSIZE = 0x700, DBLSIZE = 0x400, MIDSIZE = 0x300, STDSIZE = 0, SMLSIZE = 0x100,
  TINSIZE = 0x200, BOLD = 0x4000, INVERS = 0x8000,
  CENTER = 0x10, LEFT = 0x20, RIGHT = 0x40, TOP = 0x01, BOTTOM = 0x02, VCENTER = 0x04,
  LCD_W = width, LCD_H = height,
}
for k, v in pairs(consts) do _G[k] = v end

local FONT = { [0x800] = { 24, 40 }, [0x700] = { 19, 32 }, [0x400] = { 14, 24 }, [0x300] = { 11, 18 },
               [0] = { 8, 14 }, [0x100] = { 6, 10 }, [0x200] = { 5, 8 } }

_G.lcd = {
  RGB = function(r, g, b) return ((r // 8) << 11) | ((g // 4) << 5) | (b // 8) end,
  sizeText = function(text, font)
    local m = FONT[(font or 0) & 0xF00] or FONT[0]
    return #tostring(text or "") * m[1], m[2]
  end,
  exitFullScreen = function() exits = exits + 1 end,
}
_G.lvgl = { clear = function() end, build = function() return true end }
_G.getTime = function() return 0 end
_G.getValue = function() return nil end
_G.getFieldInfo = function() return nil end
_G.getGeneralSettings = function() return { battMin = 6.6, battMax = 8.4, battWarn = 7.0 } end
_G.getDateTime = function() return { year = 2026, mon = 1, day = 1, hour = 12, min = 0, sec = 0 } end
_G.getVersion = function() return "2.12.0", "validator", 2, 12, 0 end
_G.model = {
  getInfo = function() return { name = "Model" } end,
  getGlobalVariable = function() return 0 end,
}

local SRC_PREFIX = "/SCRIPTS/TOOLS/rfsuite-core/"
local USER_PREFIX = "/SCRIPTS/TOOLS/rfsuite.user/dashboard/"

-- A theme reaches its own files by the path the card gives them, shipped or user: both are mapped
-- onto the folder being checked. Everything else under the suite's prefix is this repository's.
local function mapPath(path)
  local rel = string.sub(path, 1, #SRC_PREFIX) == SRC_PREFIX and string.sub(path, #SRC_PREFIX + 1) or nil
  local name, file
  if rel then
    name, file = string.match(rel, "^widgets/dashboard/themes/([^/]+)/(.+)$")
    if name ~= folderName then return ROOT .. "/src/rfsuite/" .. rel end
  elseif string.sub(path, 1, #USER_PREFIX) == USER_PREFIX then
    name, file = string.match(string.sub(path, #USER_PREFIX + 1), "^([^/]+)/(.+)$")
    if name ~= folderName then return nil end
  else
    return nil
  end
  return folder .. "/" .. file
end

_G.loadScript = function(path)
  local mapped = type(path) == "string" and mapPath(path) or nil
  if mapped == nil then return nil end
  local f = io.open(mapped, "r")
  if not f then return nil end
  f:close()
  return assert(loadfile(mapped, "t"))
end

local loaded = {}
_G.rfsuite = {
  paths = dofile(ROOT .. "/src/rfsuite/lib/paths.lua"),
  loadMode = "t",
  session = {},
  require = function(path)
    if loaded[path] ~= nil then return loaded[path] or nil end
    local chunk = _G.loadScript(SRC_PREFIX .. path)
    local ok, mod = false, nil
    if chunk then ok, mod = pcall(chunk) end
    loaded[path] = (ok and mod) or false
    return loaded[path] or nil
  end,
}

-- ---------------------------------------------------------------------------
-- The fixture: the state a phase build is handed
-- ---------------------------------------------------------------------------

local function makeState(phase)
  local armed = phase == "armed" or phase == "inflight"
  return {
    zoneW = width, zoneH = height, zoneX = 0, zoneY = 0,
    flightMode = phase, themePhase = phase, armed = armed, rfConnected = phase ~= "offline",
    voltage = 24.6, fuel = 82, consumedMah = 312, rpm = 1850, current = 31.4, escTemp = 61,
    mcuTemp = 44, watts = 772, throttlePercent = 67, lq = 99, rss1 = -71, bec_voltage = 8.1,
    governor = 4, profile = 1, rateProfile = 2, batteryProfile = 1, flights = 137,
    totalFlightSeconds = 48231, flightSeconds = 245, altitude = 12.5, armDisableFlags = 0,
    batteryCellCount = 6,
    themeConfig = { v_min = 18.0, v_max = 25.2 },
    flight = { flights = 137, armed = armed, seconds = 245, lastSeconds = 301, current = {}, last = {} },
    batteryPick = { loaded = true, pending = false, candidates = {}, dismissed = false },
  }
end

-- ---------------------------------------------------------------------------
-- The recording ctx, and the actions it accepts
-- ---------------------------------------------------------------------------

local VIEWS = { menu = true, battery_pick = true, battery_profile = true }
local SIMPLE = { closeView = true, done = true, exitFullscreen = true, openTool = true, none = true }
-- The tool pages `openTool:<menuId>` may open on (TOOL_LANDINGS in widgets/dashboard/views.lua).
local TOOL_PAGES = { tools_flight_log_page = true }
-- The keys `views.key` answers from `ctx.keys` (widgets/dashboard/views.lua).
local KEY_NAMES = { exit = true, pageDown = true, pageUp = true, mdl = true, sys = true, tele = true }

-- nil when the action is one the widget knows, else why not.
local function actionProblem(after)
  if type(after) ~= "string" then return "an action that is not a string (" .. type(after) .. ")" end
  if SIMPLE[after] then return nil end
  local page = string.match(after, "^openTool:(.+)$")
  if page ~= nil then
    if TOOL_PAGES[page] then return nil end
    return "'" .. after .. "' names a tool page the widget does not open"
  end
  local id = string.match(after, "^openView:(.+)$")
  if id == nil then return "unknown action '" .. after .. "'" end
  if not VIEWS[id] then return "'" .. after .. "' names a view the widget does not have" end
  return nil
end

-- The quick menu's records, as the widget hands them out: the real fullscreen_menu.lua, asked
-- for a widget that carries the fixture state. Nothing a record does is run here -- `ctx.run`
-- records the action that would follow it -- so no message is ever queued.
local Menu = _G.rfsuite.require("widgets/dashboard/fullscreen_menu.lua")
if type(Menu) ~= "table" or type(Menu.resolve) ~= "function" then Menu = nil end

local function newCtx(log, state)
  -- A connected widget, so the rows that write to the flight controller are drawn and checked.
  local widget = { state = state, zone = { x = 0, y = 0, w = width, h = height }, preferences = { general = {} },
    connectionReady = true }
  local ctx = { keys = {} }
  ctx.action = function(after) log.actions[#log.actions + 1] = after end
  ctx.condition = function() return false end
  ctx.entries = function() return Menu and Menu.entries(widget) or {} end
  ctx.menu = function(children)
    log.menuBuilt = true
    return children
  end
  ctx.entry = function(id) return Menu and Menu.entry(widget, id) or nil end
  ctx.list = function(name) return Menu and Menu.list(widget, name) or {} end
  -- As the widget does: what a theme hands in is looked up again among the menu's own records by
  -- id, and only those are asked anything.
  ctx.visible = function(entry)
    local core = Menu and Menu.resolve(widget, entry) or nil
    return core ~= nil and Menu.visible(widget, core)
  end
  ctx.run = function(entry, option, after)
    local core, coreOption = nil, nil
    if Menu ~= nil then core, coreOption = Menu.resolve(widget, entry, option) end
    if core == nil then
      log.runs[#log.runs + 1] = "ctx.run of an entry or option the menu does not have ("
        .. tostring(type(entry) == "table" and entry.id) .. ")"
      return
    end
    if after == nil then after = (coreOption or core).after end
    log.actions[#log.actions + 1] = after
  end
  ctx.status = function() return nil end
  ctx.info = function(entry)
    local core = Menu and Menu.resolve(widget, entry) or nil
    if core ~= nil and type(core.info) == "function" then return core.info() end
    return nil
  end
  return ctx
end

-- ---------------------------------------------------------------------------
-- The tree
-- ---------------------------------------------------------------------------

-- Pre-order, in drawing order, with absolute boxes: a child's coordinates are its parent's plus
-- its own. Each item keeps its ancestors (`up`), so a check can tell a node drawn INSIDE another
-- from one drawn over it.
local function flatten(nodes, ox, oy, out, up)
  for i = 1, #nodes do
    local node = nodes[i]
    if type(node) == "table" then
      local x = ox + (tonumber(node.x) or 0)
      local y = oy + (tonumber(node.y) or 0)
      out[#out + 1] = { node = node, x = x, y = y, w = tonumber(node.w) or 0, h = tonumber(node.h) or 0, up = up }
      if type(node.children) == "table" then flatten(node.children, x, y, out, { node = node, up = up }) end
    end
  end
  return out
end

local function inside(item, node)
  local a = item.up
  while a ~= nil do
    if a.node == node then return true end
    a = a.up
  end
  return false
end

local function overlaps(a, b)
  return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
end

local function where(item)
  return string.format("%s at %d,%d %dx%d", tostring(item.node.type), item.x, item.y, item.w, item.h)
end

-- ---------------------------------------------------------------------------
-- The check
-- ---------------------------------------------------------------------------

local findings, notes = {}, {}
local function red(msg) findings[#findings + 1] = msg end
local function note(msg) notes[#notes + 1] = msg end

-- Fire every press of a built tree and check what each one asks for. Returns the number of
-- presses, whether one opened the quick menu and whether one left fullscreen.
local function checkPresses(label, tree, log)
  local flat = flatten(tree, 0, 0, {})
  local presses, opensMenu, leaves = 0, log.menuBuilt, false
  for i, item in ipairs(flat) do
    if item.node.press ~= nil then
      presses = presses + 1
      if type(item.node.press) ~= "function" then
        red(label .. ": the press of " .. where(item) .. " is not a function")
      else
        local before, exitsBefore, runsBefore = #log.actions, exits, #log.runs
        local okPress, err = pcall(item.node.press)
        if not okPress then red(label .. ": the press of " .. where(item) .. " raised: " .. tostring(err)) end
        if exits > exitsBefore then
          leaves = true
          note(label .. ": the press of " .. where(item) .. " calls lcd.exitFullScreen() itself; "
            .. "ctx.action(\"exitFullscreen\") is the documented way")
        end
        for k = before + 1, #log.actions do
          local after = log.actions[k]
          local problem = actionProblem(after)
          if problem then red(label .. ": the press of " .. where(item) .. ": " .. problem) end
          if after == "openView:menu" then opensMenu = true end
          if after == "exitFullscreen" then leaves = true end
        end
        for k = runsBefore + 1, #log.runs do
          red(label .. ": the press of " .. where(item) .. ": " .. log.runs[k])
        end
      end
      -- A rectangle built as one of the press's own children is not over it: EdgeTX hands a
      -- press a rectangle takes on to the object the rectangle was built into
      -- (radio/src/gui/colorlcd/libui/window.cpp, Window::onClicked), so it reaches the button.
      for j = i + 1, #flat do
        if flat[j].node.type == "rectangle" and overlaps(flat[j], item) and not inside(flat[j], item.node) then
          red(label .. ": " .. where(flat[j]) .. " is drawn over the press of " .. where(item)
            .. "; draw it before the pressable node, or as a line or a label")
        end
      end
    end
  end
  return presses, opensMenu, leaves
end

local function finish()
  for _, n in ipairs(notes) do print("  " .. n) end
  for _, f in ipairs(findings) do print("RED: " .. f) end
  if #findings > 0 then
    print(string.format("RED (%d finding%s)", #findings, #findings == 1 and "" or "s"))
    os.exit(1)
  end
  print("GREEN")
  os.exit(0)
end

local initChunk = loadfile(folder .. "/init.lua", "t")
if not initChunk then
  io.stderr:write("cannot read " .. folder .. "/init.lua\n")
  os.exit(2)
end
local okInit, init = pcall(initChunk)
if not okInit or type(init) ~= "table" then
  io.stderr:write(folder .. "/init.lua does not return a table\n")
  os.exit(2)
end

print(string.format("theme %s (%s), fullscreen %dx%d", folder, tostring(init.name), width, height))

-- ---------------------------------------------------------------------------
-- The theme's views (`views` in init.lua), checked whether or not the theme takes fullscreen
-- ---------------------------------------------------------------------------

-- The condition names widgets/dashboard/views.lua resolves, read off its source so that this
-- list cannot drift from it.
local CONDITION_NAMES = {}
do
  local f = io.open(ROOT .. "/src/rfsuite/widgets/dashboard/views.lua", "r")
  if f then
    for name in string.gmatch(f:read("a"), "function CONDITIONS%.([%w_]+)") do CONDITION_NAMES[name] = true end
    f:close()
  end
end

-- The switches a radio knows by the names it gives them by default: SA to SR and SW1 to SW6 (the
-- boards' switch definitions), FL1 to FL4 (the flex switches) and the logical switches L01 to
-- L64. A switch the pilot has renamed on the radio is found by that name there, but not here.
local POSITIONS = { up = true, mid = true, down = true }
-- A number, or a string that reads as one, is what the widget reads as a stored switch POSITION
-- (views.lua, switchIndex): the shape the radio's switch picker hands a setting, taken as it is
-- whatever `pos` says. `0` is the picker's "nothing chosen": no switch, so the view does not open
-- on one. As a setting's `default` that is a legitimate start; written as the switch itself it
-- only says the view never opens that way.
local function switchProblem(name, pos, isDefault)
  local position = tonumber(name)
  if position ~= nil then
    if position == 0 and not isDefault then return "names switch 0, which is no switch: the view never opens on it" end
    return nil
  end
  if type(name) ~= "string" or name == "" then return "names no switch" end
  local upper = string.upper(name)
  local logical = string.match(upper, "^L(%d+)$")
  if logical ~= nil then
    local n = tonumber(logical)
    if n < 1 or n > 64 then return "names logical switch '" .. name .. "', which is not one of L01 to L64" end
    return nil
  end
  if not (string.match(upper, "^S[A-R]$") or string.match(upper, "^SW[1-6]$") or string.match(upper, "^FL[1-4]$")) then
    return "names switch '" .. name .. "', which is none of SA to SR, SW1 to SW6, FL1 to FL4 and L01 to L64"
  end
  if pos == nil then return "names switch '" .. name .. "' without a pos: \"up\", \"mid\" or \"down\"" end
  if not POSITIONS[pos] then return "names pos '" .. tostring(pos) .. "', which is not \"up\", \"mid\" or \"down\"" end
  return nil
end

-- A setting of the theme's own is one its settings page names: assigned as a key in a table or a
-- field (`key =`, `values.key =`, never `==`) or as a quoted string, in the settings module
-- (`configure` in init.lua) or in a file of the theme's folder that module names as a `.lua`
-- path, and so on down. That is read off the source; a key the page builds from parts is not
-- seen.
--
-- Not every file of the folder: init.lua names the key in the very `openWhen` being checked, and a
-- view reading `themeConfig.key` names it as well, so a search of the whole folder would find
-- every key it is asked about and prove nothing. What proves a setting is the page that stores it.
local settingsSource = nil
if type(init.configure) == "string" then
  local parts, seen, queue = {}, { ["init.lua"] = true }, { init.configure }
  while #queue > 0 do
    local file = table.remove(queue, 1)
    if not seen[file] then
      seen[file] = true
      local f = io.open(folder .. "/" .. file, "r")
      if f then
        local text = f:read("a")
        f:close()
        parts[#parts + 1] = text
        for path in string.gmatch(text, "[\"']([^\"']-%.lua)[\"']") do
          local name = string.match(path, "([^/\\]+)$")
          if name and not seen[name] then queue[#queue + 1] = name end
        end
      end
    end
  end
  if #parts > 0 then settingsSource = "\n" .. table.concat(parts, "\n") end
end
local function namedSetting(key)
  if settingsSource == nil then return false end
  local k = string.gsub(key, "%W", "%%%0")
  return string.find(settingsSource, "[^%w_]" .. k .. "%s*=[^=]") ~= nil
    or string.find(settingsSource, "[\"']" .. k .. "[\"']") ~= nil
end

-- What a view condition may cost, in instructions per call, counted the way
-- bin/accounting/measure.lua counts (debug.sethook, one per VM instruction, the counter's own
-- empty call taken back out) on the fixture state of every phase. It is what asking the costliest
-- of the widget's own conditions costs, counted the same way on the same states:
-- `views.condition("batteryPickHasPacks", widget)` is 35 (`batteryPickPending`, the one the
-- widget asks on every fullscreen pass, 25; `previewInflightTuning` 28). So a theme's view asks no
-- more of a pass than the widget's own conditions do.
local CONDITION_BUDGET = 35

local function countCall(fn, ...)
  local n = 0
  collectgarbage("collect")
  collectgarbage("stop")
  debug.sethook(function() n = n + 1 end, "", 1)
  local ok, err = pcall(fn, ...)
  debug.sethook()
  collectgarbage("restart")
  return n, ok, err
end
local EMPTY_CALL = countCall(function() end)

local VIEW_PHASES = { "preflight", "armed", "inflight", "postflight", "offline" }

local function checkOpenWhen(label, spec)
  local kind = type(spec)
  if kind == "string" then
    if not CONDITION_NAMES[spec] then red(label .. ": openWhen '" .. spec .. "' is not a condition the widget has") end
  elseif kind == "table" then
    local switch = spec.switch
    if type(switch) == "table" then
      if type(switch.pref) ~= "string" or switch.pref == "" then
        red(label .. ": openWhen names no setting (switch.pref)")
      elseif not namedSetting(switch.pref) then
        red(label .. ": openWhen reads the setting '" .. switch.pref .. "', which "
          .. (settingsSource and ("the theme's settings page (" .. init.configure .. " and the theme files it loads) does not name")
            or "no settings module of the theme names (no configure in init.lua)"))
      end
      if switch.default == nil then
        red(label .. ": openWhen reads the setting '" .. tostring(switch.pref) .. "' and declares no default switch")
      else
        local problem = switchProblem(switch.default, spec.pos, true)
        if problem then red(label .. ": openWhen's default " .. problem) end
      end
    else
      local problem = switchProblem(switch, spec.pos)
      if problem then red(label .. ": openWhen " .. problem) end
    end
  elseif kind == "function" then
    local worst = 0
    for _, phase in ipairs(VIEW_PHASES) do
      local n, ok, err = countCall(spec, makeState(phase))
      if not ok then
        red(label .. ": openWhen raised on the " .. phase .. " state: " .. tostring(err))
        return
      end
      n = n - EMPTY_CALL
      if n > worst then worst = n end
    end
    if worst > CONDITION_BUDGET then
      red(string.format("%s: openWhen costs %d instructions per call, above the %d a view condition may cost",
        label, worst, CONDITION_BUDGET))
    else
      note(string.format("%s: openWhen costs %d instructions per call (at most %d)", label, worst, CONDITION_BUDGET))
    end
  elseif spec ~= nil then
    red(label .. ": openWhen is a " .. kind .. ", not a condition name, a switch or a function")
  end
end

local PLACES = { fullscreen = { fullscreen = true }, zone = { zone = true }, both = { fullscreen = true, zone = true } }
local WIDGET_VIEWS = { menu = true, battery_pick = true, battery_profile = true }

local themeViews = {}
if init.views ~= nil then
  if type(init.views) ~= "table" then
    red("init.lua: views is a " .. type(init.views) .. ", not a list")
  else
    local seen = {}
    for i, view in ipairs(init.views) do
      local label = "views[" .. i .. "]"
      if type(view) ~= "table" then
        red(label .. " is not a table")
      elseif type(view.id) ~= "string" or view.id == "" then
        red(label .. ": no id")
      elseif type(view.module) ~= "string" or view.module == "" then
        red(label .. " '" .. view.id .. "': no module")
      elseif PLACES[view.where or "fullscreen"] == nil then
        red(label .. " '" .. view.id .. "': where = " .. tostring(view.where) .. " is not \"fullscreen\", \"zone\" or \"both\"")
      elseif seen[view.id] then
        note(label .. " '" .. view.id .. "': an id listed before; the first entry is the one the widget takes")
      else
        seen[view.id] = true
        themeViews[#themeViews + 1] = view
        -- A press may open the theme's own fullscreen views as it opens the widget's.
        if PLACES[view.where or "fullscreen"].fullscreen then VIEWS[view.id] = true end
      end
    end
  end
end

for _, view in ipairs(themeViews) do
  local places = PLACES[view.where or "fullscreen"]
  local label = "view '" .. view.id .. "' (" .. view.module .. ")"
  local chunk = loadfile(folder .. "/" .. view.module, "t")
  local okMod, module = false, nil
  if chunk then okMod, module = pcall(chunk) end
  if not okMod or type(module) ~= "table" or type(module.build) ~= "function" then
    red(label .. ": the module does not load, or has no build() (" .. tostring(module) .. ")")
  else
    if WIDGET_VIEWS[view.id] and places.fullscreen then
      note(label .. ": draws the widget's own '" .. view.id
        .. "'; when it opens, RTN and what its presses are followed by stay the widget's")
      if view.openWhen ~= nil then note(label .. ": openWhen is not read for the look of a widget view") end
    else
      checkOpenWhen(label, view.openWhen)
      if view.openWhen == nil and places.zone then
        red(label .. ": a zone view without openWhen is never shown")
      end
    end
    if module.back ~= nil and type(module.back) ~= "function" then
      red(label .. ": back is a " .. type(module.back) .. ", not a function")
    end
    if places.fullscreen then
      local log = { actions = {}, menuBuilt = false, runs = {} }
      local state = makeState("preflight")
      if view.id == "battery_pick" then
        state.batteryPick = { loaded = true, pending = true, dismissed = false,
          candidates = { { id = "pack1", name = "Pack 1", cap = 2200, targetProfile = 0 } } }
      elseif view.id == "battery_profile" then
        state.battery_config = { hasProfileCells = true,
          batteryCapacity_0 = 2200, batteryCellCount_0 = 6, vbatwarningcellvoltage_0 = 350,
          batteryCapacity_1 = 3300, batteryCellCount_1 = 6, vbatwarningcellvoltage_1 = 350 }
        state.batteryProfile = 1
      end
      local ctx = newCtx(log, state)
      local children = {}
      local okBuild, err = pcall(module.build, children, { x = 0, y = 0, w = width, h = height }, state, ctx)
      if not okBuild then
        red(label .. ": build() raised: " .. tostring(err))
      else
        local presses = checkPresses(label, children, log)
        if presses == 0 and not WIDGET_VIEWS[view.id] then
          note(label .. ": binds no press; RTN " .. (type(module.back) == "function" and "runs its back()" or "closes it"))
        end
      end
    end
    if places.zone then
      local children = {}
      local okBuild, err = pcall(module.build, children, { x = 0, y = 0, w = width, h = height }, makeState("inflight"))
      if not okBuild then
        red(label .. ": the zone build (no ctx) raised: " .. tostring(err))
      else
        for _, item in ipairs(flatten(children, 0, 0, {})) do
          if item.node.press ~= nil then
            red(label .. ": a zone view binds no press, and " .. where(item) .. " has one")
          end
        end
      end
    end
  end
end

if init.fullscreen ~= "theme" then
  print("does not take fullscreen (no fullscreen = \"theme\" in init.lua): its fullscreen duties are not checked")
  finish()
end

local relyOnLongRtn = init.fullscreenExit == "longRtn"
if init.fullscreenExit ~= nil and not relyOnLongRtn then
  red("init.lua: fullscreenExit = " .. tostring(init.fullscreenExit) .. " is not \"longRtn\"")
end

-- The phase modules, resolved the way the widget resolves them: a refinement phase falls back
-- to the phase it refines, and a phase with no module of its own to widget.lua.
local PHASES = { "preflight", "armed", "inflight", "postflight", "offline" }
local FALLBACK = { armed = "preflight", offline = "postflight" }
local modules, order = {}, {}
for _, phase in ipairs(PHASES) do
  local key = phase
  while type(init[key]) ~= "string" and FALLBACK[key] do key = FALLBACK[key] end
  local file = type(init[key]) == "string" and init[key] or "widget.lua"
  if modules[file] == nil then
    modules[file] = { phases = {} }
    order[#order + 1] = file
  end
  local list = modules[file].phases
  list[#list + 1] = phase
end

for _, file in ipairs(order) do
  local label = file .. " [" .. table.concat(modules[file].phases, ", ") .. "]"
  local chunk = loadfile(folder .. "/" .. file, "t")
  local okMod, theme = false, nil
  if chunk then okMod, theme = pcall(chunk) end
  if not okMod or type(theme) ~= "table" then
    red(label .. ": the module does not load (" .. tostring(theme) .. ")")
  elseif type(theme.build) ~= "function" then
    if type(theme.layout) == "table" or theme.boxes ~= nil then
      note(label .. ": declarative, binds nothing; the widget draws its own menu control and X")
    else
      red(label .. ": neither build() nor layout/boxes")
    end
  else
    local log = { actions = {}, menuBuilt = false, runs = {} }
    local state = makeState(modules[file].phases[1])
    local ctx = newCtx(log, state)
    local zone = { x = 0, y = 0, w = width, h = height }
    local okBuild, tree = pcall(theme.build, zone, state, ctx)
    if not okBuild then
      red(label .. ": build() raised: " .. tostring(tree))
    elseif type(tree) ~= "table" then
      red(label .. ": build() returned " .. type(tree) .. ", not a node list")
    else
      local presses, opensMenu, leaves = checkPresses(label, tree, log)
      for name, after in pairs(ctx.keys) do
        if not KEY_NAMES[name] then
          red(label .. ": ctx.keys." .. tostring(name) .. " is not a key the widget answers")
        end
        local problem = actionProblem(after)
        if problem then red(label .. ": ctx.keys." .. tostring(name) .. ": " .. problem) end
      end
      -- Read after the build and the presses have run, which is when a theme has filled it.
      local keyExit = ctx.keys.exit == "exitFullscreen"
      if presses == 0 then
        note(label .. ": binds no press; the widget draws its own menu control and X")
      else
        if not opensMenu then
          red(label .. ": no press opens the quick menu (openView:menu, or ctx.menu)")
        end
        if not leaves and keyExit then
          note(label .. ": no press leaves fullscreen; RTN does, through ctx.keys.exit")
        elseif not leaves then
          if relyOnLongRtn then
            note(label .. ": no press leaves fullscreen; init.lua relies on a long press on RTN")
          else
            red(label .. ": nothing leaves fullscreen: bind exitFullscreen to a press or to "
              .. "ctx.keys.exit, or declare fullscreenExit = \"longRtn\" in init.lua to rely on a long press on RTN")
          end
        end
        note(string.format("%s: %d presses, %d actions", label, presses, #log.actions))
      end
    end
  end
end

finish()
