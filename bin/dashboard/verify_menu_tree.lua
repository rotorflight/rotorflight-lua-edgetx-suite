-- Checks the rolling menu's way through the suite's menu, offline, with desktop Lua 5.3, from the
-- repository root:
--
--   lua5.3 bin/dashboard/verify_menu_tree.lua               the checks; exit 1 on any failure
--   lua5.3 bin/dashboard/verify_menu_tree.lua --self-test   proves the checks can go red
--
-- What is REAL: widgets/dashboard/menu_roll.lua, menu_roll_sources.lua, menu_tree.lua, fullscreen_menu.lua, views.lua,
-- menu_look.lua and app/manifest.lua, loaded from the tree. What is STUBBED: the firmware and the tool,
-- which is judged by the page it was asked to open.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]dashboard$") or (dir .. "/../..") end
end
local SRC = ROOT .. "/src/rfsuite/"
local MUTABLE = {
  ["widgets/dashboard/menu_roll.lua"] = true,
  ["widgets/dashboard/menu_roll_sources.lua"] = true,
  ["widgets/dashboard/menu_tree.lua"] = true,
  ["widgets/dashboard/views.lua"] = true,
}

local selfTest = false
for i = 1, #arg do
  if arg[i] == "--self-test" then
    selfTest = true
  else
    io.stderr:write("usage: lua5.3 bin/dashboard/verify_menu_tree.lua [--self-test]\n")
    os.exit(2)
  end
end

for name, value in pairs({
  MIDSIZE = 1, SMLSIZE = 2, CENTER = 1, LEFT = 0, RIGHT = 2, DARKGREY = 3, RED = 4, WHITE = 5, BLACK = 0, BLUE = 6,
  COLOR_THEME_PRIMARY1 = 11, COLOR_THEME_PRIMARY3 = 13, COLOR_THEME_SECONDARY1 = 14, COLOR_THEME_DISABLED = 17,
  EVT_VIRTUAL_ENTER = 101, EVT_VIRTUAL_EXIT = 102,
  EVT_TOUCH_FIRST = 111, EVT_TOUCH_SLIDE = 112, EVT_TOUCH_BREAK = 113, EVT_TOUCH_TAP = 114,
}) do
  _G[name] = value
end

local now, opened = 0, {}
_G.getTime = function() return now end
_G.lcd = {
  RGB = function(r, g, b) if g == nil then return r end return (r * 65536) + (g * 256) + b end,
  sizeText = function(text) return #tostring(text) * 8, 16 end,
  exitFullScreen = function() end,
}
_G.lvgl = { SCROLL_VER = 12 }

local function loadWorld(mutate)
  local cache = {}
  local STUBS = {
    ["lib/log.lua"] = function() return nil end,
    ["tasks/msp/runtime.lua"] = function() return { getState = function() return { queue = { add = function() end } } end } end,
    ["widgets/dashboard/tool_host.lua"] = function()
      return {
        request = function(widget, page, visit)
          opened[#opened + 1] = { page = page, visit = visit }
          return true
        end,
      }
    end,
  }
  local function requireStub(path)
    if cache[path] ~= nil then return cache[path] end
    local mod
    if STUBS[path] then
      mod = STUBS[path]()
    else
      local f = assert(io.open(SRC .. path, "rb"))
      local text = string.gsub(f:read("a"), "\r\n", "\n")
      f:close()
      if mutate and MUTABLE[path] then text = mutate(text) end
      mod = assert(load(text, "@" .. path))()
    end
    cache[path] = mod
    return mod
  end
  _G.rfsuite = {
    require = requireStub,
    session = { fblConnected = true, apiVersion = "12.10" },
    paths = { core = string.sub(SRC, 1, -2), user = "/none" },
  }
  _G.loadScript = function(path) return loadfile(path) end
  return requireStub("widgets/dashboard/views.lua"), requireStub("widgets/dashboard/fullscreen_menu.lua"), requireStub
end

local failures, cases = 0, 0
local quiet = false
local function check(label, cond)
  cases = cases + 1
  if not cond then
    failures = failures + 1
    if not quiet then print("FAIL " .. label) end
  end
end

local function newWidget()
  return {
    zone = { w = 800, h = 480 }, connectionReady = true, built = true, renderKey = "test",
    state = { armed = false, connectionReady = true, batteryProfile = 2,
      battery_config = { batteryCapacity_0 = 2000, batteryCapacity_1 = 3000 } },
    preferences = { general = { menu_style = "rotary" }, dashboard = {} },
  }
end

local function run(mutate)
  local Views, Menu, req = loadWorld(mutate)
  local Roll = req("widgets/dashboard/menu_roll.lua")
  local Tree = req("widgets/dashboard/menu_tree.lua")

  local function build(w)
    local children = {}
    Menu.build(children, w)
    return children
  end
  local function open()
    opened = {}
    _G.rfsuite.session.fblConnected = true
    _G.rfsuite.session.apiVersion = "12.10"
    local w = newWidget()
    w._viewBase = "theme"
    Views.navigate(w, "openView:menu")
    build(w)
    return w, Views.topRoll(w)
  end
  local function rowId(level) return level.rows[level.index].id end
  local function moveTo(level, id)
    for i = 1, #level.rows do
      if level.rows[i].id == id then level.index = i; return true end
    end
    return false
  end
  local function find(rows, id)
    for i = 1, #rows do if rows[i].id == id then return rows[i], i end end
    return nil
  end
  -- MAIN MENU, Setup, and on into its Mixer's list where there is one: the wheel's way there.
  local function toSetup(w, r)
    moveTo(r.levels[1], "tool")
    Roll.press(w); build(w)
    moveTo(r.levels[2], "setup")
    Roll.press(w); build(w)
  end

  -- MAIN MENU previews the top level on the right, in the manifest's order.
  do
    local w, r = open()
    moveTo(r.levels[1], "tool")
    local right = r.levels[2]
    build(w)
    right = r.levels[2]
    check("MAIN MENU previews the suite's top level", right ~= nil and right.rows[1].id == "flight_tuning" and right.rows[2].id == "setup")
    check("in the manifest's order, the system section after", find(right.rows, "tools") ~= nil and find(right.rows, "settings") ~= nil)
    check("the preview takes no focus", r.focus == 1)
    check("opening it opens nothing", #opened == 0)
  end

  -- a press on a right row that leads to a list shifts both columns.
  do
    local w, r = open()
    toSetup(w, r)
    check("the columns shifted", r.base == 2 and r.focus == 2)
    check("left: the level just left, that row in the middle", rowId(r.levels[2]) == "setup")
    check("right: the new level", r.levels[3] ~= nil and #r.levels[3].rows > 3)
    check("nothing opened on the way", #opened == 0)
  end

  -- A page: the tool opens on it, as a visit.
  do
    local w, r = open()
    toSetup(w, r)
    check("the model page is on this level", moveTo(r.levels[3], "model"))
    Roll.press(w)
    check("a press opens that page", #opened == 1 and opened[1].page == "setup_model_page" and opened[1].visit == true)
    check("the place is kept on the widget", type(w._rollPlace) == "table" and w._rollPlace.ids[3] == "model")
    check("the session went with the visit", Views.topRoll(w) == nil)
    Views.toolClosed(w, "back")
    build(w)
    local back = Views.topRoll(w)
    check("RTN comes back as an explicit view", Views.top(w) == "menu")
    check("to the same place", back.base == 2 and back.focus == 2 and rowId(back.levels[3]) == "model"
      and rowId(back.levels[2]) == "setup" and rowId(back.levels[1]) == "tool")
    check("the bookmark is spent", w._rollPlace == nil)
  end

  -- the close decides.
  do
    local w, r = open()
    toSetup(w, r)
    moveTo(r.levels[3], "model")
    Roll.press(w)
    Views.toolClosed(w, "forget")
    check("armed or full screen left: the place is forgotten", w._rollPlace == nil and Views.top(w) == nil)
  end
  do
    local w, r = open()
    toSetup(w, r)
    moveTo(r.levels[3], "model")
    Roll.press(w)
    Views.toolClosed(w, "failed")
    build(w)
    local back = Views.topRoll(w)
    check("a page that did not open returns too", Views.top(w) == "menu" and rowId(back.levels[3]) == "model")
    check("and says so", back.couldNotOpen == true)
  end
  do
    -- The row gone meanwhile: the nearest level above, and no other row under the press.
    local w, r = open()
    moveTo(r.levels[1], "tool")
    Roll.press(w); build(w)
    moveTo(r.levels[2], "logs")
    Roll.press(w)
    check("the logs page opened", opened[1].page == "logs_page")
    w._rollPlace.ids[2] = "no_such_row"
    Views.toolClosed(w, "back")
    build(w)
    local back = Views.topRoll(w)
    check("a row gone puts the wheel on the level above", back.base == 1 and back.focus == 1 and rowId(back.levels[1]) == "tool")
  end

  -- one RTN takes back one ENTER.
  do
    local w, r = open()
    toSetup(w, r)
    Roll.back(w); build(w)
    check("from the right at depth the focus goes left, nothing shifts", r.base == 2 and r.focus == 1 and rowId(r.levels[2]) == "setup")
    Roll.back(w); build(w)
    check("from the left at depth both columns shift back, focus stays left", r.base == 1 and r.focus == 1 and rowId(r.levels[1]) == "tool")
    check("and the level left shows on the right in its place", r.levels[2] ~= nil and rowId(r.levels[2]) == "setup")
    Roll.press(w); build(w)
    check("a press goes back into it on that row", r.focus == 2 and rowId(r.levels[2]) == "setup")
    Roll.back(w); build(w)
    local closed = false
    local source = r.source
    local before = source.back
    source.back = function() closed = true end
    Roll.back(w)
    source.back = before
    check("from the left on the first level the menu closes", closed)
  end

  -- ESC & Motors and the theme settings open as tiles.
  do
    local w, r = open()
    toSetup(w, r)
    local esc = find(r.levels[3].rows, "esc_motors")
    check("ESC & Motors is a row that opens in the tool", esc ~= nil and esc.kind == "tiles")
    moveTo(r.levels[3], "esc_motors")
    Roll.press(w)
    check("a press opens it, not a list", opened[1] ~= nil and opened[1].page == "esc_motors_menu")
  end
  do
    local w, r = open()
    moveTo(r.levels[1], "tool")
    Roll.press(w); build(w)
    moveTo(r.levels[2], "settings")
    Roll.press(w); build(w)
    moveTo(r.levels[3], "dashboard")
    Roll.press(w); build(w)
    local row = find(r.levels[4].rows, "dashboard_settings")
    check("the theme settings are a row that opens in the tool", row ~= nil and row.kind == "tiles")
  end

  -- what is absent, and what is grey, with its reason.
  do
    local w, r = open()
    moveTo(r.levels[1], "tool")
    build(w)
    local rows = r.levels[2].rows
    check("the wizards are absent with their preview off", find(rows, "wizards") == nil)
    check("the developer tools are absent with their switch off", find(rows, "developer") == nil)
    w.preferences.general.preview_setup_wizard = true
    w.preferences.general.developer_tools = true
    build(w)
    rows = r.levels[2].rows
    check("and there with them on", find(rows, "wizards") ~= nil and find(rows, "developer") ~= nil)
  end
  do
    -- Literal `enabled = false` stays absent, whatever else holds.
    local w, r = open()
    toSetup(w, r)
    Roll.back(w); Roll.back(w); build(w)
    Roll.press(w); build(w)
    moveTo(r.levels[2], "settings")
    Roll.press(w); build(w)
    local rows = r.levels[3] and r.levels[3].rows or {}
    check("Shortcuts stays absent", find(rows, "shortcuts") == nil and #rows > 0)
  end
  do
    local w, r = open()
    moveTo(r.levels[1], "tool")
    Roll.press(w); build(w)
    moveTo(r.levels[2], "setup")
    local source = r.source
    local setup = r.levels[2].rows[r.levels[2].index]
    check("Setup works while connected", source.off(setup) ~= true and source.reason(setup) == nil)
    _G.rfsuite.session.fblConnected = false
    check("without a connection it is grey", source.off(setup) == true)
    check("with the reason", source.reason(setup) == "Needs the flight controller")
    check("Logs still works", source.off(find(r.levels[2].rows, "logs")) ~= true)
    local index = r.levels[2].index
    Roll.press(w)
    check("a press on the grey row does nothing", #opened == 0 and r.base == 1 and r.focus == 2 and r.levels[2].index == index)
    w.state.armed = true
    check("armed: every row is grey", source.off(find(r.levels[2].rows, "logs")) == true)
    check("armed outranks the connection in the words", source.reason(setup) == "Not while armed")
    w.state.armed = false
    _G.rfsuite.session.fblConnected = true
  end
  do
    -- Ancestors reach their descendants: Flight Tuning's rows repeat no condition of their own.
    local w, r = open()
    moveTo(r.levels[1], "tool")
    Roll.press(w); build(w)
    moveTo(r.levels[2], "flight_tuning")
    Roll.press(w); build(w)
    local source = r.source
    local level = r.levels[3]
    check("a Flight Tuning row works while connected", source.off(level.rows[1]) ~= true)
    _G.rfsuite.session.fblConnected = false
    check("and inherits its root's condition", source.off(level.rows[1]) == true)
    _G.rfsuite.session.fblConnected = true
  end
  do
    -- A version gate: grey without a connection, absent when known too old, and unknown is passing.
    local w, r = open()
    toSetup(w, r)
    Roll.back(w); Roll.back(w); build(w)
    Roll.press(w); build(w)
    moveTo(r.levels[2], "tools")
    Roll.press(w); build(w)
    moveTo(r.levels[3], "diagnostics")
    Roll.press(w); build(w)
    local rows = r.levels[4].rows
    check("the gated page is there at this version", find(rows, "crsf_sensors") ~= nil)
    _G.rfsuite.session.apiVersion = "12.09"
    build(w)
    check("too old while connected: absent", find(r.levels[4].rows, "crsf_sensors") == nil)
    _G.rfsuite.session.apiVersion = nil
    build(w)
    local row = find(r.levels[4].rows, "crsf_sensors")
    check("unknown while connected is passing: there and grey", row ~= nil and row.needsFc == true)
    _G.rfsuite.session.fblConnected = false
    _G.rfsuite.session.apiVersion = "12.09"
    build(w)
    row = find(r.levels[4].rows, "crsf_sensors")
    check("without a connection a gated row is grey", row ~= nil and r.source.off(row) == true)
    _G.rfsuite.session.fblConnected = true
    _G.rfsuite.session.apiVersion = nil
    -- An entry with a version gate and no other condition: unknown is a passing state for it too.
    local tree = Views.session(w).tree
    local pages = tree.manifest.menus.tools_menu.pages
    pages[#pages + 1] = { id = "gated", title = "G", menuId = "gated_page", minApiVersion = { 12, 0, 10 } }
    Tree.refresh(tree)
    row = find(Tree.children(w, tree, { kind = "level", menuId = "tools_menu" }), "gated")
    check("a version gate alone: unknown is grey", row ~= nil and row.needsFc == true)
    pages[#pages] = nil
    _G.rfsuite.session.apiVersion = "12.10"
  end

  -- a lost link keeps the place, on every level.
  do
    local w, r = open()
    toSetup(w, r)
    moveTo(r.levels[3], "model")
    _G.rfsuite.session.fblConnected = false
    build(w)
    check("the place stays through a lost link", r.base == 2 and r.focus == 2 and rowId(r.levels[3]) == "model")
    Roll.press(w)
    check("and the grey row opens nothing", #opened == 0)
    local session = Views.acrossReconnect(w)
    check("a reconnect keeps the roll", session ~= nil and session.rolls.menu == r and session[1].id == "menu")
    _G.rfsuite.session.fblConnected = true
  end
  do
    -- A question does not survive it.
    local w, r = open()
    moveTo(r.levels[1], "erase_blackbox")
    Roll.press(w); build(w)
    check("the question stands", r.levels[2] ~= nil and r.levels[2].question ~= nil)
    w.connectionReady = false
    build(w)
    check("and goes with the link", r.focus == 1 and (r.levels[2] == nil or r.levels[2].question == nil))
    w.connectionReady = true
  end

  -- The picker over the menu has its own roll, and the menu keeps its place under it.
  do
    local w, r = open()
    toSetup(w, r)
    w.state.batteryPick = { loaded = true, candidates = { { id = "a", name = "A", cap = 3000 } } }
    Views.navigate(w, "openView:battery_pick")
    req("widgets/dashboard/battery_pick_menu.lua").build({}, w)
    check("the picker's roll is on top", Views.topRoll(w) ~= r and Views.topRoll(w).view == "battery_pick")
    Views.navigate(w, "closeView")
    check("the menu's place is under it", Views.topRoll(w) == r and r.base == 2 and rowId(r.levels[2]) == "setup")
  end

  -- on the first row selectable now, and with all grey on the first.
  do
    local w = newWidget()
    w._viewBase = "theme"
    w.connectionReady = false
    Views.navigate(w, "openView:menu")
    build(w)
    local r = Views.topRoll(w)
    check("the first row selectable now", r.levels[1].rows[r.levels[1].index].id == "tool")
    w.state.armed = true
    Views.navigate(w, "closeView")
    Views.navigate(w, "openView:menu")
    build(w)
    r = Views.topRoll(w)
    check("all grey: the first row", r.levels[1].index == 1)
    w.state.armed = false
  end

  -- The tree goes with the visit, and is read outside the module cache.
  do
    local w, r = open()
    check("the tree is on the session", Views.session(w).tree ~= nil and Views.session(w).tree.manifest ~= nil)
    check("not in the module cache the tool empties", _G.rfsuite.modules == nil or _G.rfsuite.modules["app/manifest.lua"] == nil)
    Tree.refresh(Views.session(w).tree)
    check("refreshed lists are made afresh", next(Views.session(w).tree.lists) == nil)
    Views.navigate(w, "closeView")
    moveTo(r.levels[1], "tool")
  end
end

if selfTest then
  local MUTANTS = {
    { "a press on the right never shifts", function(t)
        return (string.gsub(t, "if right.question == nil and source.enter ~= nil then", "if false then", 1)) end },
    { "RTN at depth on the left closes instead of shifting", function(t)
        return (string.gsub(t, "if roll.base > 1 then", "if false then", 1)) end },
    { "the place is not kept for the visit", function(t)
        return (string.gsub(t, "widget._rollPlace = place", "widget._rollPlace = nil", 1)) end },
    { "every close returns to the roll", function(t)
        return (string.gsub(t, "if place == nil or %(outcome ~= \"back\" and outcome ~= \"failed\"%) then return end", "if place == nil then return end", 1)) end },
    { "a grey row is not grey", function(t)
        return (string.gsub(t, "if row.needsFc == true and not Tree.connected%(%) then return REASON_FC end", "", 1)) end },
    { "an ancestor's condition stays with the ancestor", function(t)
        return (string.gsub(t, "rows = rowsOf%(widget, tree, menu.pages or {}, row.below%)", "rows = rowsOf(widget, tree, menu.pages or {}, false)", 1)) end },
    { "an unknown version counts as enough", function(t)
        return (string.gsub(t, "reaches%(entry.minApiVersion%) ~= true", "reaches(entry.minApiVersion) == false", 1)) end },
    { "ESC & Motors rolls on", function(t)
        return (string.gsub(t, "local TILES = { esc_motors_menu = true }", "local TILES = {}", 1)) end },
    { "a reconnect loses the place", function(t)
        return (string.gsub(t, "local session = { rolls = { %[M.DEFAULT_VIEW%] = roll } }", "local session = {}", 1)) end },
    { "the picker takes the menu's roll", function(t)
        return (string.gsub(t, "session.rolls%[view%] = roll\n", "session.rolls = { [view] = roll }\n", 1)) end },
    { "a question survives its row", function(t)
        return (string.gsub(t, "if source.enter ~= nil and not isOff%(roll, row%) then rows, question = source.enter%(row%) end", "if source.enter ~= nil then rows, question = source.enter(row) end", 1)) end },
    { "the list starts where the pilot cannot press", function(t)
        return (string.gsub(t, "return none or open or 1", "return none or 1", 1)) end },
  }
  quiet = true
  local red = 0
  for i = 1, #MUTANTS do
    local source = ""
    for path in pairs(MUTABLE) do
      local file = assert(io.open(SRC .. path, "rb"))
      source = source .. string.gsub(file:read("a"), "\r\n", "\n")
      file:close()
    end
    if MUTANTS[i][2](source) == source then
      print("SELF-TEST: mutant did not apply: " .. MUTANTS[i][1])
      os.exit(1)
    end
    failures, cases = 0, 0
    local ok = pcall(run, MUTANTS[i][2])
    if failures > 0 or not ok then
      red = red + 1
    else
      print("SELF-TEST: not caught: " .. MUTANTS[i][1])
    end
  end
  print(red .. " of " .. #MUTANTS .. " mutants caught")
  os.exit(red == #MUTANTS and 0 or 1)
end

run(nil)
print(cases .. " checks, " .. failures .. " failures")
os.exit(failures == 0 and 0 or 1)
