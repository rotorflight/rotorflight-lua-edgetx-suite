-- Checks the quick menu's rotary style, offline, with desktop Lua 5.3, from the repository root:
--
--   lua5.3 bin/dashboard/verify_menu_roll.lua               the checks; exit 1 on any failure
--   lua5.3 bin/dashboard/verify_menu_roll.lua --self-test   proves the checks can go red
--
-- What is REAL: widgets/dashboard/menu_roll.lua, menu_roll_sources.lua, fullscreen_menu.lua, views.lua, menu_look.lua and
-- quick_menu_order.lua, loaded from the tree. What is STUBBED: the firmware (a wheel detent is the
-- `scrolled` call LVGL makes for the focus move) and the flight controller side, so a press is
-- judged by what it queues and whether it leaves the menu.

local ROOT = "."
do
  local this = arg and arg[0]
  local dir = type(this) == "string" and string.match(this, "^(.*)[/\\][^/\\]*$") or nil
  if dir then ROOT = string.match(dir, "^(.*)[/\\]bin[/\\]dashboard$") or (dir .. "/../..") end
end
local SRC = ROOT .. "/src/rfsuite/"
local ROLL = "widgets/dashboard/menu_roll.lua"
local SOURCES = "widgets/dashboard/menu_roll_sources.lua"
local MENU = "widgets/dashboard/fullscreen_menu.lua"
local PICKER = "widgets/dashboard/battery_pick_menu.lua"

local selfTest = false
for i = 1, #arg do
  if arg[i] == "--self-test" then
    selfTest = true
  else
    io.stderr:write("usage: lua5.3 bin/dashboard/verify_menu_roll.lua [--self-test]\n")
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

local now, adds, exits, toolOpened = 0, {}, 0, 0
_G.getTime = function() return now end
local QUEUE = {}
function QUEUE:add(msg) adds[#adds + 1] = msg end
_G.lcd = {
  RGB = function(r, g, b) if g == nil then return r end return (r * 65536) + (g * 256) + b end,
  -- A rough width, so a budget below counts the rows a build measures.
  sizeText = function(text) return #tostring(text) * 8, 16 end,
  exitFullScreen = function() exits = exits + 1 end,
}

-- Loads the modules; `mutate` rewrites the roll's source, for the self-test.
local function loadWorld(mutate)
  local cache = {}
  local STUBS = {
    ["lib/log.lua"] = function() return nil end,
    ["tasks/msp/runtime.lua"] = function() return { getState = function() return { queue = QUEUE } end } end,
    ["tasks/msp/api/dataflash_erase.lua"] = function()
      return { writeCommand = 71, buildWritePayload = function() return {} end }
    end,
    ["tasks/msp/api/dataflash_summary.lua"] = function()
      return { command = 70, simulatorResponse = {}, parse = function() return nil end }
    end,
    ["tasks/msp/api/battery_profile.lua"] = function()
      return { writeCommand = 1, buildWritePayload = function(fields) return fields end }
    end,
    ["tasks/msp/api/eeprom_write.lua"] = function()
      return { writeCommand = 250, buildWritePayload = function() return {} end }
    end,
    ["widgets/dashboard/tool_host.lua"] = function()
      return { request = function() toolOpened = toolOpened + 1; return true end }
    end,
  }
  local function requireStub(path)
    if cache[path] ~= nil then return cache[path] end
    local mod
    if STUBS[path] then
      mod = STUBS[path]()
    else
      local f = assert(io.open(SRC .. path, "rb"))
      local text = f:read("a")
      f:close()
      if (path == ROLL or path == SOURCES or path == MENU or path == PICKER) and mutate then text = mutate(text) end
      mod = assert(load(text, "@" .. path))()
    end
    cache[path] = mod
    return mod
  end
  _G.rfsuite = {
    require = requireStub, session = { dataflash = { used = 50, total = 100 }, fblConnected = true },
    paths = { core = string.sub(SRC, 1, -2), user = "/none" },
  }
  _G.loadScript = function(path) return loadfile(path) end
  return requireStub("widgets/dashboard/views.lua"), requireStub("widgets/dashboard/fullscreen_menu.lua"), requireStub
end

local function newWidget(style)
  return {
    zone = { w = 800, h = 480 }, connectionReady = true, built = true, renderKey = "test", theme = {},
    state = {
      armed = false, connectionReady = true, batteryProfile = 2,
      battery_config = { batteryCapacity_0 = 2000, batteryCapacity_1 = 3000, batteryCapacity_2 = 4000 },
    },
    preferences = { general = { menu_style = style }, dashboard = {} },
  }
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

-- A built scene, and the things a pilot can reach in it.
local function scene(Menu, widget)
  local children = {}
  Menu.build(children, widget)
  local boxes, buttons = {}, {}
  for i = 1, #children do
    local node = children[i]
    if node.type == "box" and node.scrolled ~= nil then boxes[#boxes + 1] = node end
    if node.type == "button" then buttons[#buttons + 1] = node end
  end
  return { children = children, forward = boxes[1], reverse = boxes[2], buttons = buttons }
end

local function run(mutate)
  local Views, Menu, req = loadWorld(mutate)
  local Roll = req(ROLL)
  local Look = req("widgets/dashboard/menu_look.lua")
  local function open()
    adds, exits, toolOpened = {}, 0, 0
    local w = newWidget("rotary")
    w._viewBase = "theme"
    Views.navigate(w, "openView:menu")
    return w, scene(Menu, w)
  end
  local function roll(w) return Views.topRoll(w) end
  local function detent(box, h, row) box.scrolled(0, row * h) end

  -- Every colour these pages read is a role of both schemes: an unset colour draws white.
  do
    local Schemes = req("lib/color_schemes.lua")
    for _, name in ipairs({ "light", "dark" }) do
      for _, role in ipairs(Look.ROLES) do
        check(name .. " has the role " .. role[2], Schemes.SCHEMES[name][role[2]] ~= nil)
      end
      local colors = Look.colors({ preferences = { general = { color_scheme = name } } })
      for _, role in ipairs(Look.ROLES) do
        check(name .. " gives " .. role[1], type(colors[role[1]]) == "number")
      end
    end
    check("the two schemes differ", Look.colors({ preferences = { general = { color_scheme = "dark" } } }).bg
      ~= Look.colors({ preferences = { general = { color_scheme = "light" } } }).bg)
  end

  -- The card is what a radio with no choice gets.
  do
    local w = newWidget(nil)
    local s = scene(Menu, w)
    check("no choice draws the raster, not the ladders", s.forward == nil)
  end

  -- The lists: entries offered now, BATTERY PROFILE last.
  do
    local w, s = open()
    local r = roll(w)
    check("two ladders", s.forward ~= nil and s.reverse ~= nil)
    check("the quick menu hands the shared roll how its rows are made, read again at a rest", type(r.make) == "function")
    check("left list holds three rows", #r.levels[1].rows == 3)
    check("BATTERY PROFILE is last", r.levels[1].rows[#r.levels[1].rows].id == "battery_profile")
    check("starts on the first row", r.levels[1].index == 1)
  end

  -- The rows are no buttons, nor is the close box: the wheel's walk holds the two ladders and nothing else.
  do
    local _, s = open()
    check("no button outside the ladders", #s.buttons == 0)
    local inside = 0
    for _, box in ipairs({ s.forward, s.reverse }) do
      for i = 1, #box.children do if box.children[i].type == "button" then inside = inside + 1 end end
    end
    check("twelve buttons in each ladder", inside == 24)
  end

  -- The wheel: both ways, fixed ends, and the sum across the widget's own focus step.
  do
    local w, s = open()
    local r = roll(w)
    local h = s.forward.h
    detent(s.forward, h, 1)
    check("a detent forward moves one row", r.levels[1].index == 2)
    detent(s.forward, h, 2)
    check("a second detent moves on", r.levels[1].index == 3)
    detent(s.forward, h, 3)
    check("the list ends: no wrap past the last row", r.levels[1].index == 3)
    detent(s.forward, h, 2)
    check("turning back at the end moves at once", r.levels[1].index == 2)
  end
  do
    local w, s = open()
    local r = roll(w)
    local h = s.forward.h
    detent(s.forward, h, 1)
    check("one forward", r.levels[1].index == 2)
    -- Back onto the widget reports nothing, and the reverse ladder then counts both detents.
    detent(s.reverse, h, 12 - 1)
    check("the detent over the widget is not lost in the sum", r.levels[1].index == 1)
    -- Coming back into the forward ladder: its reset to the spare row is acknowledged, not counted.
    s.forward.scrolled(0, 0)
    check("the ladder's own reset is not a detent", r.levels[1].index == 1)
    s.forward.scrolled(0, 0)
    check("nor is the same position reported again", r.levels[1].index == 1)
  end
  do
    -- A build asked for near a ladder's end: detents still on the standing scene count one each.
    local w, s = open()
    local r = roll(w)
    r.levels[1].rows = {}
    for i = 1, 30 do r.levels[1].rows[i] = { id = "row" .. i, title = "row" } end
    local h = s.forward.h
    for row = 1, 9 do detent(s.forward, h, row) end
    check("nine detents, nine rows", r.levels[1].index == 10)
    detent(s.forward, h, 10)
    check("the detent after the build was asked for is one row", r.levels[1].index == 11)
  end
  do
    local w, s = open()
    local r = roll(w)
    s.forward.scrolled(0, 7)
    check("a finger's fraction of a row is not a detent", r.levels[1].index == 1)
  end

  -- The middle row's text follows the selection, and the left entry's choice shows on the right.
  do
    local w, s = open()
    local r = roll(w)
    local h = s.forward.h
    detent(s.forward, h, 2)
    check("the profile row is current", r.levels[1].rows[r.levels[1].index].id == "battery_profile")
    local shown = false
    for i = 1, #s.children do
      local node = s.children[i]
      if node.type == "label" and type(node.text) == "function" and string.find(node.text() or "", "3000 mAh", 1, true) then
        shown = true
      end
    end
    check("the right list shows the choice before any press", shown)
    check("the one in force is marked", (function()
      local marked = 0
      for i = 1, #s.children do
        local node = s.children[i]
        if node.type == "circle" and node.visible() then marked = marked + 1 end
      end
      return marked == 1
    end)())
  end

  -- MAIN MENU leads on, and opens nothing by itself.
  do
    local w, s = open()
    local r = roll(w)
    detent(s.forward, s.forward.h, 1)
    check("MAIN MENU is current", r.levels[1].rows[r.levels[1].index].id == "tool")
    Roll.press(w)
    check("a press moves the focus into the suite's menu", toolOpened == 0 and r.focus == 2 and #r.levels[2].rows > 0)
  end

  -- The question: on the right, the safe answer first, and nothing queued before the answer.
  do
    local w, s = open()
    local r = roll(w)
    Roll.press(w)
    check("the press raises the question on the right", r.focus == 2 and r.levels[2].question ~= nil)
    check("nothing is queued by the question", #adds == 0)
    Roll.press(w)
    check("a double press lands on CANCEL", r.focus == 1 and #adds == 0 and exits == 0)
  end
  do
    local w = open()
    local r = roll(w)
    Roll.press(w)
    local s = scene(Menu, w)
    detent(s.forward, s.forward.h, 1)
    check("one detent reaches ERASE", r.levels[2].index == 2)
    Roll.press(w)
    check("ERASE queues the erase", #adds >= 1)
  end
  do
    local w = open()
    local r = roll(w)
    Roll.press(w)
    Views.key(w, EVT_VIRTUAL_EXIT)
    check("RTN on the question goes back and erases nothing", r.focus == 1 and #adds == 0)
  end

  -- A profile: stays up until answered; a failed write stays visible.
  local function toProfile()
    local w = open()
    local s = scene(Menu, w)
    local r = roll(w)
    detent(s.forward, s.forward.h, 2)
    Roll.press(w)
    return w, r
  end
  do
    local w, r = toProfile()
    check("the focus moves right on a choice", r.focus == 2)
    check("and starts on the one in force", r.levels[2].index == 2)
    Views.key(w, EVT_VIRTUAL_ENTER)
    check("a press writes", #adds == 2)
    check("and it writes the profile in force's own number here", adds[1].payload.batteryProfile == 1)
    check("the menu stays up while it is sent", roll(w) ~= nil and Views.status(w, "battery_profile") == "busy")
    adds[#adds].processReply(adds[#adds], {})
    check("an answered write closes the menu", w._viewStack == nil or roll(w) == nil)
  end
  do
    -- The wheel rests on another profile: the scene is built again, and that profile is what is written.
    local w, r = toProfile()
    local s = scene(Menu, w)
    detent(s.forward, s.forward.h, 1)
    check("one detent on the right moves one option", r.levels[2].index == 3)
    now = now + 100
    Menu.renderKey(w)
    s = scene(Menu, w)
    for i = 1, #s.children do
      local node = s.children[i]
      if node.type == "label" and type(node.text) == "function" then node.text() end
    end
    check("a build keeps the place on the right", r.levels[2].index == 3)
    Views.key(w, EVT_VIRTUAL_ENTER)
    check("and the press writes that option", adds[1] ~= nil and adds[1].payload.batteryProfile == 2)
  end
  do
    -- An entry comes in above the one the pilot is on: the place goes with the entry, not its number.
    local w, r = toProfile()
    local s = scene(Menu, w)
    detent(s.forward, s.forward.h, 1)
    check("on the third profile", r.levels[2].index == 3)
    -- ERASE BLACKBOX leaves the list, so the row's number changes under it.
    local one = { Menu.entry(w, "tool") }
    Roll.build({}, w, function()
      return req("widgets/dashboard/menu_roll_sources.lua").quick(w, one, function(_, f) return f end)
    end, Look.colors(w))
    check("the row keeps its entry", r.levels[1].rows[r.levels[1].index].id == "battery_profile" and r.levels[1].index == 2 and r.focus == 2)
    check("and the option its place", r.levels[2].index == 3)
  end
  do
    -- The option under the focus goes: no other one takes its place under the same press.
    local w, r = toProfile()
    check("focus on the profile in force", r.focus == 2 and r.levels[2].index == 2)
    w.state.battery_config.batteryCapacity_1 = 0
    scene(Menu, w)
    check("the option gone, the focus is back on the left", r.focus == 1)
    Views.key(w, EVT_VIRTUAL_ENTER)
    check("and the press writes nothing", #adds == 0)
  end
  do
    -- A question stands through a build, in what the row says now.
    local w = open()
    local r = roll(w)
    Roll.press(w)
    check("the question has the fill", string.find(r.levels[2].question.detail or "", "50", 1, true) ~= nil)
    _G.rfsuite.session.dataflash = { used = 80, total = 100 }
    scene(Menu, w)
    check("it says the fill as it is now", r.focus == 2 and string.find(r.levels[2].question.detail or "", "80", 1, true) ~= nil)
    _G.rfsuite.session.dataflash = { used = 50, total = 100 }
  end
  do
    -- The row itself goes: its question or choice goes with it.
    local w, r = toProfile()
    w.state.battery_config = nil
    scene(Menu, w)
    check("no profile row, so back on the left", r.focus == 1)
    local q = open()
    local rq = roll(q)
    Roll.press(q)
    q.connectionReady = false
    q.state.connectionReady = false
    scene(Menu, q)
    check("the link gone, the erase question goes with its row", rq.focus == 1 and (rq.levels[2] == nil or rq.levels[2].question == nil))
  end
  do
    -- ERASE current: CANCEL is the labelled row above it.
    local w = open()
    local r = roll(w)
    Roll.press(w)
    local s = scene(Menu, w)
    detent(s.forward, s.forward.h, 1)
    check("ERASE is current", r.levels[2].index == 2)
    local seen = false
    for i = 1, #s.children do
      local node = s.children[i]
      if node.type == "label" and type(node.text) == "function" and node.text() == "CANCEL" then seen = true end
    end
    check("CANCEL stays labelled above it", seen)
  end
  do
    -- A theme's look registered since the menu opened: its own keys are not answered for it.
    local w = open()
    local entry = Views.find(w, "menu")
    entry.load = function() return {} end
    check("ENTER is no longer the roll's", Views.key(w, EVT_VIRTUAL_ENTER) ~= true and toolOpened == 0 and roll(w) == nil)
  end
  do
    local w = toProfile()
    Views.key(w, EVT_VIRTUAL_ENTER)
    adds[1].errorHandler(adds[1], "timeout")
    check("a failed write stays up and says so",
      roll(w) ~= nil and Views.status(w, "battery_profile") == "failed")
    adds[#adds].processReply(adds[#adds], {})
    check("the last message's answer does not close over a failed one",
      roll(w) ~= nil and Views.status(w, "battery_profile") == "failed")
  end
  do
    -- A reply to a write from before the menu was closed says nothing about the menu opened since.
    local w = toProfile()
    Views.key(w, EVT_VIRTUAL_ENTER)
    local late = adds[#adds]
    Views.navigate(w, "closeView")
    Views.navigate(w, "openView:menu")
    scene(Menu, w)
    local session = w._viewStack
    late.processReply(late, {})
    check("an old reply leaves the new menu up", w._viewStack == session and roll(w) ~= nil)
  end
  do
    -- A reply that comes while the battery prompt stands over the menu leaves the prompt up.
    local w = toProfile()
    Views.key(w, EVT_VIRTUAL_ENTER)
    local late = adds[#adds]
    w.state.batteryPick = { loaded = true, pending = true, candidates = { { id = "a", name = "Pack A", cap = 3000 } } }
    Views.resolve(w)
    req("widgets/dashboard/battery_pick_menu.lua").build({}, w)
    check("the prompt rose over the menu", Views.top(w) == "battery_pick" and Views.roll(w, "battery_pick") ~= nil)
    late.processReply(late, {})
    check("a reply under the prompt leaves it up", Views.top(w) == "battery_pick" and w.state.batteryPick.pending == true)
  end
  do
    -- The menu as the default view, on an empty stack with no base layer: the prompt rises over it and is
    -- answered, and the write's reply comes before the next pass has named the menu the view again.
    adds, exits, toolOpened = {}, 0, 0
    local w = newWidget("rotary")
    w._viewId = Views.resolve(w)
    local s = scene(Menu, w)
    local r = roll(w)
    check("the default menu has its roll on an empty stack", Views.top(w) == nil and r ~= nil and r.view == "menu")
    detent(s.forward, s.forward.h, 2)
    Roll.press(w)
    Views.key(w, EVT_VIRTUAL_ENTER)
    local late = adds[#adds]
    local session = w._viewStack
    w.state.batteryPick = { loaded = true, pending = true, candidates = { { id = "a", name = "Pack A", cap = 3000 } } }
    w._viewId = Views.resolve(w)
    req("widgets/dashboard/battery_pick_menu.lua").build({}, w)
    check("the prompt rose over the default menu", w._viewId == "battery_pick" and Views.top(w) == "battery_pick")
    w.state.batteryPick.pending = false
    Views.navigate(w, "done")
    check("the prompt hands back to the default menu", Views.top(w) == nil and w._viewStack == session
      and Views.roll(w, "battery_pick") == nil and Views.roll(w, "menu") == r)
    late.processReply(late, {})
    check("the answered write closes the default menu though the last pass named the prompt",
      w._viewStack ~= session or Views.roll(w, "menu") == nil)
  end
  do
    -- A view taken off the stack starts over; one merely covered keeps its place.
    local w = open()
    local r = roll(w)
    w.state.batteryPick = { loaded = true, pending = true, candidates = { { id = "a", name = "Pack A", cap = 3000 } } }
    Views.resolve(w)
    req("widgets/dashboard/battery_pick_menu.lua").build({}, w)
    check("the menu keeps its roll under the prompt", Views.roll(w, "menu") == r and Views.roll(w, "battery_pick") ~= nil)
    Views.navigate(w, "openView:menu")
    check("going back to the menu drops the prompt's roll", Views.top(w) == "menu" and Views.roll(w, "battery_pick") == nil
      and Views.roll(w, "menu") == r)
    w.state.batteryPick.pending = false
    Views.resolve(w)
    w.state.batteryPick.pending = true
    Views.resolve(w)
    req("widgets/dashboard/battery_pick_menu.lua").build({}, w)
    check("the prompt rose again with a roll", Views.top(w) == "battery_pick" and Views.roll(w, "battery_pick") ~= nil)
    w.state.batteryPick.pending = false
    Views.resolve(w)
    check("a prompt whose condition fell leaves no roll behind", Views.top(w) == "menu" and Views.roll(w, "battery_pick") == nil)
  end
  do
    -- The right list follows the left entry, from the one in force.
    local w, r = toProfile()
    r.levels[2].index = 3
    r.slots = nil
    Views.key(w, EVT_VIRTUAL_EXIT)
    local s = scene(Menu, w)
    detent(s.forward, s.forward.h, -1 + 1)
    r.levels[1].index = 1
    r.slots = nil
    for i = 1, #s.children do
      local node = s.children[i]
      if node.type == "label" and type(node.text) == "function" then node.text() end
    end
    r.levels[1].index = #r.levels[1].rows
    r.slots = nil
    for i = 1, #s.children do
      local node = s.children[i]
      if node.type == "label" and type(node.text) == "function" then node.text() end
    end
    check("coming back to a choice starts on the one in force", r.levels[2].index == 2)
  end
  do
    local w, r = toProfile()
    Views.key(w, EVT_VIRTUAL_EXIT)
    check("RTN returns left", r.focus == 1)
    Views.key(w, EVT_VIRTUAL_EXIT)
    check("RTN from the left closes the menu", Views.top(w) == nil)
  end

  -- The finger.
  local function touch(w, event, fields) return Views.key(w, event, fields) end
  local function tap(w, x, y)
    touch(w, EVT_TOUCH_FIRST, { x = x, y = y })
    touch(w, EVT_TOUCH_BREAK, { x = x, y = y })
  end
  local function geoOf(w) return roll(w).geo end
  do
    local w = open()
    local r = roll(w)
    local g = geoOf(w)
    tap(w, g.leftX + 5, g.slotY(1) + 2)
    check("a tap on the row under the middle brings it there", r.levels[1].index == 2)
    check("and runs nothing", toolOpened == 0 and #adds == 0)
    scene(Menu, w)
    tap(w, g.leftX + 5, g.slotY(0) + 2)
    check("a tap on the middle row is a press", r.focus == 2)
  end
  do
    local w = open()
    local r = roll(w)
    local g = geoOf(w)
    tap(w, g.leftX + 5, g.slotY(-2) + 2)
    check("a tap on a free slot does nothing", r.levels[1].index == 1 and toolOpened == 0)
  end
  do
    -- A swipe: a row's height a row, the finger moving up to the next.
    local w = open()
    local r = roll(w)
    local g = geoOf(w)
    touch(w, EVT_TOUCH_FIRST, { x = g.leftX + 5, y = g.slotY(1) })
    touch(w, EVT_TOUCH_SLIDE, { x = g.leftX + 5, y = 0, slideY = -math.floor(g.rowH / 2) })
    check("half a row moves nothing", r.levels[1].index == 1)
    touch(w, EVT_TOUCH_SLIDE, { x = g.leftX + 5, y = 0, slideY = -math.floor(g.rowH / 2) - 1 })
    check("a row's height moves one row", r.levels[1].index == 2)
    touch(w, EVT_TOUCH_SLIDE, { x = g.leftX + 5, y = 0, slideY = -10 * g.rowH })
    check("the list ends", r.levels[1].index == #r.levels[1].rows)
    touch(w, EVT_TOUCH_BREAK, { x = g.leftX + 5, y = 0 })
    check("a swipe is no tap", toolOpened == 0 and #adds == 0)
  end
  do
    -- A release with no touch of its own runs nothing: a gesture's coordinates end with it.
    local w = open()
    local r = roll(w)
    local g = geoOf(w)
    Roll.press(w)
    scene(Menu, w)
    g = geoOf(w)
    touch(w, EVT_TOUCH_FIRST, { x = g.rightX + 5, y = g.slotY(0) })
    touch(w, EVT_TOUCH_SLIDE, { x = g.rightX + 5, y = 0, slideY = -(g.rowH + 1) })
    touch(w, EVT_TOUCH_BREAK, { x = g.rightX + 5, y = 0 })
    check("the swipe brought ERASE to the middle", r.levels[2].index == 2)
    touch(w, EVT_TOUCH_BREAK, { x = g.rightX + 5, y = 0 })
    check("and a stray release does not answer the question", #adds == 0)
  end
  do
    -- A touch on the header is no row.
    local w = open()
    local Sources = req("widgets/dashboard/menu_roll_sources.lua")
    local two = { Menu.entry(w, "erase_blackbox"), Menu.entry(w, "flight_log") }
    Roll.build({}, w, function() return Sources.quick(w, two, function(_, f) return f end) end, Look.colors(w))
    local r = roll(w)
    r.levels[1].index = 2
    r.slots = nil
    local g = geoOf(w)
    tap(w, 20, 30)
    check("a tap on the header moves nothing", r.levels[1].index == 2 and toolOpened == 0)
    tap(w, g.rightX + 5, g.slotY(0) + 2)
    check("a tap on an empty right column runs nothing", toolOpened == 0)
    touch(w, EVT_TOUCH_FIRST, { x = g.rightX + 5, y = g.slotY(0) + 2 })
    touch(w, EVT_TOUCH_SLIDE, { x = g.rightX + 5, y = 0, slideY = -(g.rowH + 1) })
    touch(w, EVT_TOUCH_BREAK, { x = g.rightX + 5, y = 0 })
    check("a swipe on an empty right column moves nothing", r.levels[1].index == 2 and r.focus == 1)
  end
  do
    -- RTN and the wheel's press arriving with a touch table stay what they are.
    local w, r = toProfile()
    Views.key(w, EVT_VIRTUAL_EXIT, {})
    check("RTN with a table still steps back", r.focus == 1)
  end
  do
    -- On the right: a swipe takes the focus there, and a press writes where it stopped.
    local w = open()
    local r = roll(w)
    local s = scene(Menu, w)
    detent(s.forward, s.forward.h, 2)
    s = scene(Menu, w)
    local g = geoOf(w)
    check("the preview is up, the focus left", r.focus == 1 and r.levels[1].index == #r.levels[1].rows)
    touch(w, EVT_TOUCH_FIRST, { x = g.rightX + 5, y = g.slotY(0) })
    touch(w, EVT_TOUCH_SLIDE, { x = g.rightX + 5, y = 0, slideY = -(g.rowH + 1) })
    touch(w, EVT_TOUCH_BREAK, { x = g.rightX + 5, y = 0 })
    check("the swipe took the focus right", r.focus == 2)
    check("and moved one option", r.levels[2].index == 3)
    scene(Menu, w)
    tap(w, g.rightX + 5, g.slotY(0) + 2)
    check("a tap on its middle writes that one", adds[1] ~= nil and adds[1].payload.batteryProfile == 2)
  end

  -- At rest the scene is NOT built: the ladders hide for one sweep, which takes the focus back to the widget,
  -- and show again in the next; the selection stays and the next detent counts from the widget.
  do
    local w, s = open()
    local r = roll(w)
    local h = s.forward.h
    local function ladderShown(box)
      for i = 1, #box.children do
        local node = box.children[i]
        if node.type == "button" then return node.visible == nil or node.visible() end
      end
    end
    check("the ladders are shown while the wheel turns", ladderShown(s.forward) and ladderShown(s.reverse))
    detent(s.forward, h, 1)
    detent(s.forward, h, 2)
    r.slots = { stale = true }
    local key = Menu.renderKey(w)
    now = now + 100
    check("the key stays once the wheel has rested", Menu.renderKey(w) == key)
    check("the selection is kept", r.levels[1].index == 3)
    check("the lists are read afresh", r.slots == nil)
    check("the ladders hide for the sweep", not ladderShown(s.forward) and not ladderShown(s.reverse))
    -- The sweep: the focus passes over the forward ladder's buttons, LVGL scrolls to each; none is a detent.
    s.forward.scrolled(0, 3 * h)
    s.forward.scrolled(0, 4 * h)
    check("no detent while the ladders hide", r.levels[1].index == 3)
    check("the ladders are asked back to their spare rows", select(2, s.forward.scrollTo()) == 0
      and select(2, s.reverse.scrollTo()) == 12 * h)
    check("the hiding sweep is over after the reverse ladder", r.recentre ~= nil and r.recentre.state == "show")
    check("and the ladders show in the next", ladderShown(s.forward) and ladderShown(s.reverse))
    s.reverse.scrollTo()
    check("which ends it", r.recentre == nil)
    check("the count starts over", r.position == 0)
    detent(s.reverse, h, 11)
    check("a detent back from the widget moves one row", r.levels[1].index == 2)
    check("still no build", Menu.renderKey(w) == key)
  end
  do
    -- A sweep that never comes: the scene is built after all, and the wheel is not left without ladders.
    local w, s = open()
    local r = roll(w)
    detent(s.forward, s.forward.h, 1)
    local key = Menu.renderKey(w)
    now = now + 100
    Menu.renderKey(w)
    check("the rest started hiding", r.recentre ~= nil)
    now = now + 1000
    Menu.renderKey(w)
    check("a slow pass is no reason to give up", r.recentre ~= nil and Menu.renderKey(w) == key)
    Menu.renderKey(w)
    check("four passes without the sweep build the scene", Menu.renderKey(w) ~= key and r.recentre == nil)
  end
  do
    -- A touch arrives relative to the object it lands on: over the touch box, only labels, pictures and dots
    -- (which take none) and a rectangle starting at the same corner may lie.
    local _, s = open()
    local after, wrong = false, {}
    for i = 1, #s.children do
      local node = s.children[i]
      if node.type == "box" and node.scrolled == nil and node.x == 0 and node.y == 0 and node.scrollDir == 0 then
        after = true
      elseif after and node.type == "rectangle" and (node.x ~= 0 or node.y ~= 0) then
        wrong[#wrong + 1] = tostring(node.x) .. "," .. tostring(node.y)
      end
    end
    check("no rectangle over the touch box away from its corner: " .. table.concat(wrong, " "), after and #wrong == 0)
  end
  do
    -- A rest asks the menu for its rows afresh, as a build did: the question says the fill as it is now.
    local w, s = open()
    local r = roll(w)
    Roll.press(w)
    s = scene(Menu, w)
    check("the question has the fill", string.find(r.levels[2].question.detail or "", "50", 1, true) ~= nil)
    local before = r.source
    detent(s.forward, s.forward.h, 1)
    local key = Menu.renderKey(w)
    now = now + 100
    check("an unchanged question rests without a build", Menu.renderKey(w) == key)
    check("and the menu's rows were made afresh", r.source ~= before and type(r.make) == "function")
    s.reverse.scrollTo()
    s.reverse.scrollTo()
    _G.rfsuite.session.dataflash = { used = 80, total = 100 }
    detent(s.forward, s.forward.h, 1)
    Menu.renderKey(w)
    now = now + 100
    check("a question whose words changed is built again", Menu.renderKey(w) ~= key)
    check("in what it says now", string.find(r.levels[2].question.detail or "", "80", 1, true) ~= nil)
    _G.rfsuite.session.dataflash = { used = 50, total = 100 }
  end
  do
    -- The close box during an opening: it calls the opening off and closes, as the button did, until the
    -- tool is starting.
    local w = open()
    local r = roll(w)
    local g = geoOf(w)
    local ran = 0
    Roll.openNext(r, "Opening...", function() ran = ran + 1 end)
    tap(w, g.leftX + 5, g.slotY(1) + 2)
    check("a finger elsewhere is ignored while a page opens", r.opening ~= nil and Views.top(w) ~= nil)
    tap(w, g.closeX + 2, g.closeY + 2)
    check("the close box calls the opening off and closes", r.opening == nil and Views.top(w) == nil and ran == 0)
    w = open()
    r = roll(w)
    g = geoOf(w)
    Roll.openNext(r, "Opening...", function() ran = ran + 1 end)
    r.opening.started = true
    tap(w, g.closeX + 2, g.closeY + 2)
    check("once the tool is starting it does nothing", r.opening ~= nil and Views.top(w) ~= nil)
  end
  do
    -- The close box: drawn, and a tap on it closes the menu.
    local w = open()
    local g = geoOf(w)
    tap(w, g.closeX + 2, g.closeY + 2)
    check("a tap on the close box closes the menu", Views.top(w) == nil)
  end

  -- Drawn as buttons, the keys are the buttons' again.
  do
    local w = open()
    check("the rolling menu has its state", roll(w) ~= nil)
    w.preferences.general.menu_style = nil
    scene(Menu, w)
    check("the card ends it", roll(w) == nil)
    check("and ENTER is not answered for it", Views.key(w, EVT_VIRTUAL_ENTER) ~= true)
  end

  -- The battery picker in the rotary style: its own view, a roll of its own.
  local function openPicker(setsProfile, cap2)
    adds, exits, toolOpened = {}, 0, 0
    local w = newWidget("rotary")
    w._viewBase = "theme"
    w.preferences.flightlog = { enabled = true, set_fc_profile = setsProfile == true }
    w.state.batteryPick = {
      loaded = true, pending = true,
      candidates = {
        { id = "a", name = "Pack A", cap = 3000, cycles = 12 },
        { id = "b", name = "Pack B", cap = cap2 or 9999, cycles = 3 },
        { id = "c", name = "Pack C", cap = 4000 },
      },
    }
    Views.navigate(w, "openView:battery_pick")
    local children = {}
    req("widgets/dashboard/battery_pick_menu.lua").build(children, w)
    local boxes = {}
    for i = 1, #children do
      if children[i].type == "box" and children[i].scrolled ~= nil then boxes[#boxes + 1] = children[i] end
    end
    return w, children, boxes[1]
  end
  local function labelsOf(children)
    local out = {}
    for i = 1, #children do
      local node = children[i]
      if node.type == "label" then
        local text = node.text
        if type(text) == "function" then text = text() end
        out[#out + 1] = text
      end
    end
    return table.concat(out, "|")
  end
  do
    local w, children, forward = openPicker(false)
    local r = roll(w)
    check("the picker has a roll of its own", r ~= nil and r.view == "battery_pick" and forward ~= nil)
    check("and hands the shared roll how its packs are made, read again at a rest", type(r.make) == "function")
    check("with no pack in force it starts on NO BATTERY", r.levels[1].rows[r.levels[1].index].none == true)
    check("its title is the picker's", string.find(labelsOf(children), "WHICH BATTERY?", 1, true) ~= nil)
    forward.scrolled(0, -1 * 0)
    r.levels[1].index = 1
    r.slots = nil
    local text = labelsOf(children)
    check("the first pack's facts stand on the right",
      string.find(text, "3000 mAh", 1, true) ~= nil and string.find(text, "12 cycles", 1, true) ~= nil)
    r.levels[1].index = 3
    r.slots = nil
    check("a pack without a cycle count leaves it out", string.find(labelsOf(children), "cycles", 1, true) == nil)
    r.levels[1].index = 1
    r.slots = nil
    Views.key(w, EVT_VIRTUAL_ENTER)
    check("with the switch off a press picks at once", w._batteryPickRequest == "a" and (w._viewStack == nil or roll(w) == nil))
  end
  do
    local w = openPicker(false)
    Views.key(w, EVT_VIRTUAL_EXIT)
    check("RTN on the picker ends the prompt", w.state.batteryPick.dismissed == true and w.state.batteryPick.pending == false)
  end
  do
    -- With the switch on, what has no profile on this board is shown and takes no press.
    local w, children = openPicker(true)
    local r = roll(w)
    local rows = r.levels[1].rows
    check("Pack A has its profile", rows[1].selectable == true and rows[1].writes == true)
    check("Pack B has none and cannot be picked", rows[2].selectable == false)
    check("NO BATTERY always can", rows[#rows].selectable ~= false)
    r.levels[1].index = 2
    r.slots = nil
    check("it says why", string.find(labelsOf(children), "no profile", 1, true) ~= nil)
    Views.key(w, EVT_VIRTUAL_ENTER)
    check("a press on it does nothing", w._batteryPickRequest == nil and roll(w) ~= nil)
    check("nor can a theme's run reach it", (function()
      Menu.run(w, Menu.entry(w, "battery_pick"), rows[2])
      return w._batteryPickRequest == nil
    end)())
    r.levels[1].index = 1
    r.slots = nil
    Views.key(w, EVT_VIRTUAL_ENTER)
    check("a pack that writes stays up and says so", w._batteryPickRequest == "a" and roll(w) ~= nil
      and Views.status(w, "battery_pick") == "busy")
    w._batteryPickRequest = nil
    Views.key(w, EVT_VIRTUAL_ENTER)
    check("a second press while it is sent does nothing", w._batteryPickRequest == nil)
  end
  do
    -- The prompt while a pick is out. A writing one stays open, a closing one counts as answered.
    local w = openPicker(true)
    local rows = roll(w).levels[1].rows
    check("the prompt is open", Views.condition("batteryPickPending", w) == true)
    Menu.run(w, Menu.entry(w, "battery_pick"), rows[1])
    check("it stays open through a pick that writes, or it would close and raise again",
      Views.condition("batteryPickPending", w) == true)
    w._batteryPickRequest, w._batteryPickPress = nil, nil
    w._viewStack = nil
    local q = openPicker(false)
    rows = roll(q).levels[1].rows
    Menu.run(q, Menu.entry(q, "battery_pick"), rows[1])
    check("a pick that closes counts as the answer", Views.condition("batteryPickPending", q) == false)
  end
  do
    -- The answer closes what the press left up, and nothing that came over it.
    local w = openPicker(true)
    local session = w._viewStack
    check("with the picker on top it closes", Views.top(w) == "battery_pick" and Views.finish(w, session, "battery_pick") == true)
    local q = openPicker(true)
    session = q._viewStack
    Views.navigate(q, "openView:menu")
    check("a menu opened over it stays", Views.finish(q, session, "battery_pick") == false and Views.top(q) == "menu")
    check("nor does a visit begun since end", Views.finish(q, {}, "menu") == false)
    -- What the answer closes was fixed at the press, whatever has opened before the job ran.
    local r = openPicker(true)
    local rows = roll(r).levels[1].rows
    Menu.run(r, Menu.entry(r, "battery_pick"), rows[1])
    check("the press holds the view it was made on", r._batteryPickPress ~= nil and r._batteryPickPress.top == "battery_pick"
      and r._batteryPickPress.visit == r._viewStack)
    Views.navigate(r, "openView:menu")
    check("a menu opened before the job ran stays",
      Views.finish(r, r._batteryPickPress.visit, r._batteryPickPress.top) == false and Views.top(r) == "menu")
  end
  do
    -- A replaced configuration or list is worked out again, and the picker's key moves.
    local w = openPicker(true)
    local rows = roll(w).levels[1].rows
    check("no match while the capacity is on no profile", rows[2].selectable == false)
    local page = req("widgets/dashboard/battery_pick_menu.lua")
    local key = page.renderKey(w)
    w.state.battery_config = { batteryCapacity_0 = 9999 }
    check("a replaced configuration moves the key", page.renderKey(w) ~= key)
    key = page.renderKey(w)
    local same = {}
    for i, pack in ipairs(w.state.batteryPick.candidates) do same[i] = pack end
    w.state.batteryPick.candidates = same
    check("a replaced list of the same length moves it too", page.renderKey(w) ~= key)
    rows = Menu.entry(w, "battery_pick").options()
    check("and the pack is worked out again", rows[2].selectable == true)
    w.state.batteryPick.candidates = { { id = "z", name = "Z", cap = 1, profile = 4 } }
    rows = Menu.entry(w, "battery_pick").options()
    check("a replaced list under the same configuration too", rows[1].selectable == true)
  end
  do
    -- A list too long to build as cards rolls, whichever style is chosen, within a widget call's limit.
    local function big(count)
      adds, exits, toolOpened = {}, 0, 0
      local w = newWidget(nil)
      w.preferences.flightlog = { enabled = true, set_fc_profile = true }
      local list = {}
      for i = 1, count do list[i] = { id = "n" .. i, name = "N" .. i, cap = 2000, cycles = i, targetProfile = 0 } end
      -- As the load publishes it: each pack's profile worked out in the load's own steps.
      w.state.batteryPick = { loaded = true, pending = true, candidates = list,
        resolvedFor = req("lib/battery_pick.lua").configKey(w.state.battery_config), resolvedPacks = list }
      Views.navigate(w, "openView:battery_pick")
      return w
    end
    local page = req("widgets/dashboard/battery_pick_menu.lua")
    local function cost(w)
      local children = {}
      local n = 0
      debug.sethook(function() n = n + 1 end, "", 1)
      page.build(children, w)
      debug.sethook()
      return n, children
    end
    local w = big(40)
    local n, children = cost(w)
    local box = false
    for i = 1, #children do
      if children[i].type == "box" and children[i].children ~= nil and #children[i].children > 0 then box = true end
    end
    check("forty packs are still cards", roll(w) == nil and box)
    check("and their build stays well inside a call: " .. n, n < 20000 * 0.9)
    w = big(41)
    cost(w)
    check("forty-one roll", roll(w) ~= nil and roll(w).view == "battery_pick")
    Views.key(w, EVT_VIRTUAL_ENTER)
    check("and the wheel's press is answered", w._batteryPickRequest ~= nil or w._viewStack == nil or roll(w) == nil)
    -- What a pack says follows its language, its profile and whether it can be picked.
    do
      local q = big(2)
      local pick = q.state.batteryPick
      local entry = Menu.entry(q, "battery_pick")
      check("the words say the profile", string.find(entry.options()[1].detail, "Profile 1", 1, true) ~= nil)
      pick.candidates[1].targetProfile = 3
      check("a new profile is said", string.find(entry.options()[1].detail, "Profile 4", 1, true) ~= nil)
      q.i18n = { t = function(key, fallback)
        if key == "widgets.dashboard.battery_pick_cycles" then return "%d Zyklen" end
        return fallback
      end }
      check("another language is said", string.find(Menu.entry(q, "battery_pick").options()[1].detail, "Zyklen", 1, true) ~= nil)
      -- The battery page's save changes the shared table in place.
      q = big(2)
      local packs = Menu.entry(q, "battery_pick").options()
      q.state.batteryPick.resolvedFor = nil
      Menu.entry(q, "battery_pick").options()
      q.state.batteryPick.candidates[1].cap = 3000
      q.state.battery_config.batteryCapacity_0 = 3000
      local moved = Menu.entry(q, "battery_pick").options()[1]
      check("a save in place is worked out again", moved.selectable == true and moved.detail ~= packs[1].detail)
      q = big(2)
      q.state.batteryPick.candidates[1].targetProfile = nil
      local off = Menu.entry(q, "battery_pick").options()[1]
      check("no profile: the reason stays when shortened", off.selectable == false and off.details[#off.details] == "no profile")
      q.preferences.flightlog.set_fc_profile = false
      local on = Menu.entry(q, "battery_pick").options()[1]
      check("the switch off: the profile goes first when shortened", on.selectable == true and string.find(on.details[#on.details], "mAh", 1, true) ~= nil)
    end
    w = big(100)
    n = cost(w)
    check("a hundred roll inside a call: " .. n, n < 20000 * 0.9)
    local again = cost(w)
    check("and a build at rest pays less per pack: " .. again, again < n)
  end
  do
    -- As cards: every pack is a button the wheel can reach, and a grey one's press does nothing.
    adds, exits, toolOpened = {}, 0, 0
    local w = newWidget(nil)
    w.preferences.flightlog = { enabled = true, set_fc_profile = true }
    w.state.batteryPick = { loaded = true, pending = true, candidates = {} }
    for i = 1, 12 do
      w.state.batteryPick.candidates[i] = { id = "n" .. i, name = "N" .. i, cap = 7000 + i, cycles = i }
    end
    Views.navigate(w, "openView:battery_pick")
    local children = {}
    req("widgets/dashboard/battery_pick_menu.lua").build(children, w)
    local cells
    for i = 1, #children do
      if children[i].type == "box" and children[i].children ~= nil then cells = children[i].children end
    end
    check("more packs than the room scroll in a box", cells ~= nil)
    local buttons = 0
    local press
    for i = 1, #(cells or {}) do
      if cells[i].type == "button" then
        buttons = buttons + 1
        press = press or cells[i].press
      end
    end
    check("each pack a button, grey ones too", buttons == 12)
    if press then press() end
    check("a grey card's press does nothing", w._batteryPickRequest == nil)
  end
  do
    -- A pack in force that has lost its profile: marked, not started on.
    local w
    do
      adds, exits, toolOpened = {}, 0, 0
      w = newWidget("rotary")
      w.preferences.flightlog = { enabled = true, set_fc_profile = true }
      w.state.batteryPick = { loaded = true, selectedId = "b", candidates = {
        { id = "a", name = "A", cap = 3000 }, { id = "b", name = "B", cap = 9999 } } }
      Views.navigate(w, "openView:battery_pick")
      req("widgets/dashboard/battery_pick_menu.lua").build({}, w)
    end
    local r = roll(w)
    local rows = r.levels[1].rows
    check("it stays marked", rows[2].current == true and rows[2].selectable == false)
    check("the roll starts on NO BATTERY", rows[r.levels[1].index].none == true)
    check("a pack in force with a profile is started on", (function()
      Views.dropRoll(w, "battery_pick")
      w.state.batteryPick.selectedId = "a"
      req("widgets/dashboard/battery_pick_menu.lua").build({}, w)
      local again = roll(w)
      return again.levels[1].index == 1
    end)())
  end
  do
    -- In the quick menu the same start rule holds on the BATTERY row.
    adds, exits, toolOpened = {}, 0, 0
    local w = newWidget("rotary")
    w.preferences.flightlog = { enabled = true }
    w.preferences.dashboard.quick_menu = "battery_pick"
    w.state.batteryPick = { loaded = true, candidates = { { id = "a", name = "A", cap = 3000 }, { id = "b", name = "B", cap = 4000 } } }
    Views.navigate(w, "openView:menu")
    scene(Menu, w)
    local r = roll(w)
    check("BATTERY is offered", r.levels[1].rows[1].id == "battery_pick")
    Roll.press(w)
    check("the focus starts on NO BATTERY there too", r.focus == 2 and r.levels[2].rows[r.levels[2].index].none == true)
  end
  do
    -- A finger down: nothing moves the focus under it, however long the wheel has rested.
    local w, s = open()
    local r = roll(w)
    detent(s.forward, s.forward.h, 1)
    local g = geoOf(w)
    touch(w, EVT_TOUCH_FIRST, { x = g.leftX + 5, y = g.slotY(0) })
    local key = Menu.renderKey(w)
    now = now + 100
    check("no build while a finger is down", Menu.renderKey(w) == key)
    check("nor does the focus move under it", r.recentre == nil)
    touch(w, EVT_TOUCH_BREAK, { x = g.leftX + 5, y = g.slotY(0) })
    Menu.renderKey(w)
    check("and the rest is honoured after it", r.recentre ~= nil or r.steppedAt == nil)
  end

  -- The model arming greys the list under the right side, with the place kept.
  do
    local w, r = toProfile()
    w.state.armed = true
    scene(Menu, w)
    check("the place stays while the model is armed", r.focus == 2)
    local written = #adds
    Roll.press(w)
    check("and a press writes nothing", #adds == written)
    w.state.armed = false
  end
end

if selfTest then
  local MUTANTS = {
    { "the list wraps", function(t) return (string.gsub(t, "if value > count then return count end", "if value > count then return 1 end")) end },
    { "ERASE first", function(t)
      return (string.gsub(t, "{ id = \"cancel\", label = confirm.cancelLabel or \"CANCEL\", cancel = true },\n    { id = \"agree\", label = confirm.confirmLabel or \"OK\", agree = true },",
        "{ id = \"agree\", label = confirm.confirmLabel or \"OK\", agree = true },\n    { id = \"cancel\", label = confirm.cancelLabel or \"CANCEL\", cancel = true },"))
    end },
    { "closes before the answer", function(t)
      return (string.gsub(t, "Menu.run%(widget, entry, choice, \"none\", report%)", "Menu.run(widget, entry, choice, \"done\", report)"))
    end },
    { "a write's success closes whatever it finds", function(t)
      return (string.gsub(t, "if value == \"ok\" and widget._viewStack == session and Views.onTop%(widget, roll.view%)\n      and Views.roll%(widget, roll.view%) == roll\n      and Views.status%(widget, entry.id%) == \"ok\" then", "if value == \"ok\" then"))
    end },
    { "a position reported twice counts", function(t)
      return (string.gsub(t, "if sy == window.y then return end\n", ""))
    end },
    { "a build forgets the place on the right", function(t)
      return (string.gsub(t, "level.index = place\n", "level.index = 1\n"))
    end },
    { "another option takes a gone one's place", function(t)
      return (string.gsub(t, "level.index = level.rows and startIndex%(level.rows, source%) or 1\n        for i = #levels, depth %+ 1, %-1 do levels%[i%] = nil end\n        roll.base = math.min%(roll.base, depth %- 1%)\n        roll.focus = 1\n", "level.index = 1\n"))
    end },
    { "a question keeps what it said", function(t)
      return (string.gsub(t, "level.rows, level.question = rows, question\n", ""))
    end },
    { "the place goes by the row's number", function(t)
      return (string.gsub(t, "local found = indexOfRow%(first.rows, before%)", "local found = (before ~= nil and first.rows[first.index] ~= nil) and first.index or nil"))
    end },
    { "a detent is not summed", function(t)
      return (string.gsub(t, "local delta = position %- roll.position", "local delta = (position > roll.position) and 1 or -1"))
    end },
    { "a theme's run reaches a pack without a profile", function(t)
      return (string.gsub(t, "if option ~= nil and option.selectable == false then return true end\n", ""))
    end },
    { "a long list stays cards", function(t)
      return (string.gsub(t, "#pick.candidates > CARDS_MAX", "false"))
    end },
    { "a pack's words outlive its language or profile", function(t)
      return (string.gsub(t, "if facts == nil or pack.pickKey ~= wordsKey or pack.pickTarget ~= target then", "if facts == nil then"))
    end },
    { "a pack's words made afresh on every build", function(t)
      return (string.gsub(t, "pack.pickFacts, pack.pickKey, pack.pickTarget = facts, wordsKey, target\n", ""))
    end },
    { "a replaced list keeps its old profiles", function(t)
      return (string.gsub(t, " and pick.resolvedPacks == pick.candidates then return end", " then return end"))
    end },
    { "a second pick over one still being sent", function(t)
      return (string.gsub(t, "Views.status%(widget, entry.id%) == \"busy\" then", "false then"))
    end },
    { "the picker starts on the first pack", function(t)
      return (string.gsub(t, "if row.none == true then none = i end\n", ""))
    end },
    { "RTN on the picker only closes the view", function(t)
      return (string.gsub(t, "    close = close,\n    back = close,", "    close = close,\n    back = function() Views.navigate(widget, \"closeView\") end,"))
    end },
    { "a build under the finger", function(t)
      return (string.gsub(t, "recentre == nil and roll.touchX == nil and", "recentre == nil and"))
    end },
    { "the rest builds the scene", function(t)
      return (string.gsub(t, "    if relayout then\n", "    if relayout or true then\n"))
    end },
    { "the ladders never hide", function(t)
      return (string.gsub(t, "return recentre == nil or recentre.state ~= \"hide\"", "return true"))
    end },
    { "the hiding sweep's scrolls count as detents", function(t)
      local kept = "        recentre.swallowed = recentre.swallowed + 1\n"
      return (string.gsub(t, "        recentre.swallowed = recentre.swallowed %+ 1\n        return\n", kept))
    end },
    { "the hiding never ends", function(t)
      return (string.gsub(t, "          recentre.state = \"show\"\n", ""))
    end },
    { "hidden ladders are never given up", function(t)
      return (string.gsub(t, "recentre.passes > HIDDEN_PASSES", "false"))
    end },
    { "a rest keeps the rows the last build made", function(t)
      return (string.gsub(t, "  if type%(roll.make%) == \"function\" then\n", "  if false then\n"))
    end },
    { "the quick menu hands in rows made once", function(t)
      return (string.gsub(t, "function%(%) return Sources.quick%(widget, entries or M.entries%(widget%), t%) end",
        "Sources.quick(widget, entries or M.entries(widget), t)"))
    end },
    { "the picker hands in packs made once", function(t)
      return (string.gsub(t, "function%(%) return Sources.pick%(widget, t%) end", "Sources.pick(widget, t)"))
    end },
    { "the close box is dead while a page opens", function(t)
      local tail = "      end\n    end\n    return true\n"
      return (string.gsub(t, "        roll.source.close%(%)\n" .. tail, tail))
    end },
    { "the close box does nothing", function(t)
      return (string.gsub(t, "    roll.source.close%(%)\n    return\n", "    return\n"))
    end },
  }
  quiet = true
  local red = 0
  for i = 1, #MUTANTS do
    local file = assert(io.open(SRC .. ROLL, "rb"))
    local source = string.gsub(file:read("a"), "\r\n", "\n")
    file:close()
    for _, path in ipairs({ SOURCES, MENU, PICKER }) do
      file = assert(io.open(SRC .. path, "rb"))
      source = source .. string.gsub(file:read("a"), "\r\n", "\n")
      file:close()
    end
    local mutated = MUTANTS[i][2](source)
    if mutated == source then
      print("SELF-TEST: mutant did not apply: " .. MUTANTS[i][1])
      os.exit(1)
    end
    failures, cases = 0, 0
    local mutate = function(text) return MUTANTS[i][2]((string.gsub(text, "\r\n", "\n"))) end
    local ok = pcall(run, mutate)
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
