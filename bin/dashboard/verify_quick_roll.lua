-- Checks the quick menu's rotary style, offline, with desktop Lua 5.3, from the repository root:
--
--   lua5.3 bin/dashboard/verify_quick_roll.lua               the checks; exit 1 on any failure
--   lua5.3 bin/dashboard/verify_quick_roll.lua --self-test   proves the checks can go red
--
-- What is REAL: widgets/dashboard/quick_roll.lua, fullscreen_menu.lua, views.lua, menu_look.lua and
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
local ROLL = "widgets/dashboard/quick_roll.lua"

local selfTest = false
for i = 1, #arg do
  if arg[i] == "--self-test" then
    selfTest = true
  else
    io.stderr:write("usage: lua5.3 bin/dashboard/verify_quick_roll.lua [--self-test]\n")
    os.exit(2)
  end
end

for name, value in pairs({
  MIDSIZE = 1, SMLSIZE = 2, CENTER = 1, LEFT = 0, RIGHT = 2, DARKGREY = 3, RED = 4, WHITE = 5, BLACK = 0, BLUE = 6,
  COLOR_THEME_PRIMARY1 = 11, COLOR_THEME_PRIMARY3 = 13, COLOR_THEME_SECONDARY1 = 14, COLOR_THEME_DISABLED = 17,
  EVT_VIRTUAL_ENTER = 101, EVT_VIRTUAL_EXIT = 102,
}) do
  _G[name] = value
end

local now, adds, exits, toolOpened = 0, {}, 0, 0
_G.getTime = function() return now end
local QUEUE = {}
function QUEUE:add(msg) adds[#adds + 1] = msg end
_G.lcd = {
  RGB = function(r, g, b) return (r * 65536) + (g * 256) + b end,
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
      if path == ROLL and mutate then text = mutate(text) end
      mod = assert(load(text, "@" .. path))()
    end
    cache[path] = mod
    return mod
  end
  _G.rfsuite = { require = requireStub, session = { dataflash = { used = 50, total = 100 } } }
  return requireStub("widgets/dashboard/views.lua"), requireStub("widgets/dashboard/fullscreen_menu.lua"), requireStub
end

local function newWidget(style)
  return {
    zone = { w = 800, h = 480 }, connectionReady = true, built = true, renderKey = "test",
    state = {
      armed = false, connectionReady = true, batteryProfile = 2,
      battery_config = { batteryCapacity_0 = 2000, batteryCapacity_1 = 3000, batteryCapacity_2 = 4000 },
    },
    preferences = { general = {}, dashboard = { quick_menu_style = style } },
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
    if node.type == "box" then boxes[#boxes + 1] = node end
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
  local function roll(w) return w._viewStack.roll end
  local function detent(box, h, row) box.scrolled(0, row * h) end

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
    check("left list holds three rows", #r.leftList == 3)
    check("BATTERY PROFILE is last", r.leftList[#r.leftList].id == "battery_profile")
    check("starts on the first row", r.left == 1)
  end

  -- A slot with no row in it is not there.
  do
    local _, s = open()
    local shown, hidden = 0, 0
    for i = 1, #s.buttons do
      local visible = s.buttons[i].visible
      if type(visible) == "function" then
        if visible() then shown = shown + 1 else hidden = hidden + 1 end
      end
    end
    check("on the first row the two slots above it are gone and the two under it are there", shown == 2 and hidden == 2)
  end

  -- The wheel: both ways, fixed ends, and the sum across the widget's own focus step.
  do
    local w, s = open()
    local r = roll(w)
    local h = s.forward.h
    detent(s.forward, h, 1)
    check("a detent forward moves one row", r.left == 2)
    detent(s.forward, h, 2)
    check("a second detent moves on", r.left == 3)
    detent(s.forward, h, 3)
    check("the list ends: no wrap past the last row", r.left == 3)
    detent(s.forward, h, 2)
    check("turning back at the end moves at once", r.left == 2)
  end
  do
    local w, s = open()
    local r = roll(w)
    local h = s.forward.h
    detent(s.forward, h, 1)
    check("one forward", r.left == 2)
    -- Back onto the widget reports nothing, and the reverse ladder then counts both detents.
    detent(s.reverse, h, 12 - 1)
    check("the detent over the widget is not lost in the sum", r.left == 1)
    -- Coming back into the forward ladder: its reset to the spare row is acknowledged, not counted.
    s.forward.scrolled(0, 0)
    check("the ladder's own reset is not a detent", r.left == 1)
    s.forward.scrolled(0, 0)
    check("nor is the same position reported again", r.left == 1)
  end
  do
    -- A build asked for near a ladder's end: detents still on the standing scene count one each.
    local w, s = open()
    local r = roll(w)
    r.leftList = {}
    for i = 1, 30 do r.leftList[i] = { id = "row" .. i, title = "row" } end
    local h = s.forward.h
    for row = 1, 9 do detent(s.forward, h, row) end
    check("nine detents, nine rows", r.left == 10)
    detent(s.forward, h, 10)
    check("the detent after the build was asked for is one row", r.left == 11)
  end
  do
    local w, s = open()
    local r = roll(w)
    s.forward.scrolled(0, 7)
    check("a finger's fraction of a row is not a detent", r.left == 1)
  end

  -- The middle row's text follows the selection, and the left entry's choice shows on the right.
  do
    local w, s = open()
    local r = roll(w)
    local h = s.forward.h
    detent(s.forward, h, 2)
    check("the profile row is current", r.leftList[r.left].id == "battery_profile")
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

  -- A row with nothing behind it runs at once.
  do
    local w, s = open()
    local r = roll(w)
    detent(s.forward, s.forward.h, 1)
    check("MAIN MENU is current", r.leftList[r.left].id == "tool")
    Roll.press(w)
    check("a press runs it", toolOpened == 1)
  end

  -- The question: on the right, the safe answer first, and nothing queued before the answer.
  do
    local w, s = open()
    local r = roll(w)
    Roll.press(w)
    check("the press raises the question on the right", r.side == "right" and r.question ~= nil)
    check("nothing is queued by the question", #adds == 0)
    Roll.press(w)
    check("a double press lands on CANCEL", r.side == "left" and #adds == 0 and exits == 0)
  end
  do
    local w = open()
    local r = roll(w)
    Roll.press(w)
    local s = scene(Menu, w)
    detent(s.forward, s.forward.h, 1)
    check("one detent reaches ERASE", r.right == 2)
    Roll.press(w)
    check("ERASE queues the erase", #adds >= 1)
  end
  do
    local w = open()
    local r = roll(w)
    Roll.press(w)
    Views.key(w, EVT_VIRTUAL_EXIT)
    check("RTN on the question goes back and erases nothing", r.side == "left" and #adds == 0)
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
    check("the focus moves right on a choice", r.side == "right")
    check("and starts on the one in force", r.right == 2)
    Views.key(w, EVT_VIRTUAL_ENTER)
    check("a press writes", #adds == 2)
    check("and it writes the profile in force's own number here", adds[1].payload.batteryProfile == 1)
    check("the menu stays up while it is sent", w._viewStack.roll ~= nil and Views.status(w, "battery_profile") == "busy")
    adds[#adds].processReply(adds[#adds], {})
    check("an answered write closes the menu", w._viewStack == nil or w._viewStack.roll == nil)
  end
  do
    -- The wheel rests on another profile: the scene is built again, and that profile is what is written.
    local w, r = toProfile()
    local s = scene(Menu, w)
    detent(s.forward, s.forward.h, 1)
    check("one detent on the right moves one option", r.right == 3)
    now = now + 100
    Menu.renderKey(w)
    s = scene(Menu, w)
    for i = 1, #s.children do
      local node = s.children[i]
      if node.type == "label" and type(node.text) == "function" then node.text() end
    end
    check("a build keeps the place on the right", r.right == 3)
    Views.key(w, EVT_VIRTUAL_ENTER)
    check("and the press writes that option", adds[1] ~= nil and adds[1].payload.batteryProfile == 2)
  end
  do
    -- An entry comes in above the one the pilot is on: the place goes with the entry, not its number.
    local w, r = toProfile()
    local s = scene(Menu, w)
    detent(s.forward, s.forward.h, 1)
    check("on the third profile", r.right == 3)
    -- ERASE BLACKBOX leaves the list, so the row's number changes under it.
    Roll.build({}, w, { Menu.entry(w, "tool") }, Look.colors(w), function(_, f) return f end)
    check("the row keeps its entry", r.leftList[r.left].id == "battery_profile" and r.left == 2 and r.side == "right")
    check("and the option its place", r.right == 3)
  end
  do
    -- The option under the focus goes: no other one takes its place under the same press.
    local w, r = toProfile()
    check("focus on the profile in force", r.side == "right" and r.right == 2)
    w.state.battery_config.batteryCapacity_1 = 0
    scene(Menu, w)
    check("the option gone, the focus is back on the left", r.side == "left")
    Views.key(w, EVT_VIRTUAL_ENTER)
    check("and the press writes nothing", #adds == 0)
  end
  do
    -- A question stands through a build, in what the row says now.
    local w = open()
    local r = roll(w)
    Roll.press(w)
    check("the question has the fill", string.find(r.question.confirm.detail or "", "50", 1, true) ~= nil)
    _G.rfsuite.session.dataflash = { used = 80, total = 100 }
    scene(Menu, w)
    check("it says the fill as it is now", r.side == "right" and string.find(r.question.confirm.detail or "", "80", 1, true) ~= nil)
    _G.rfsuite.session.dataflash = { used = 50, total = 100 }
  end
  do
    -- The row itself goes: its question or choice goes with it.
    local w, r = toProfile()
    w.state.battery_config = nil
    scene(Menu, w)
    check("no profile row, so back on the left", r.side == "left")
    local q = open()
    local rq = roll(q)
    Roll.press(q)
    q.connectionReady = false
    q.state.connectionReady = false
    scene(Menu, q)
    check("the link gone, the erase question goes with its row", rq.side == "left" and rq.question == nil)
  end
  do
    -- ERASE current: CANCEL is the labelled row above it.
    local w = open()
    local r = roll(w)
    Roll.press(w)
    local s = scene(Menu, w)
    detent(s.forward, s.forward.h, 1)
    check("ERASE is current", r.right == 2)
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
    check("ENTER is no longer the roll's", Views.key(w, EVT_VIRTUAL_ENTER) ~= true and toolOpened == 0 and w._viewStack.roll == nil)
  end
  do
    local w = toProfile()
    Views.key(w, EVT_VIRTUAL_ENTER)
    adds[1].errorHandler(adds[1], "timeout")
    check("a failed write stays up and says so",
      w._viewStack.roll ~= nil and Views.status(w, "battery_profile") == "failed")
    adds[#adds].processReply(adds[#adds], {})
    check("the last message's answer does not close over a failed one",
      w._viewStack.roll ~= nil and Views.status(w, "battery_profile") == "failed")
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
    check("an old reply leaves the new menu up", w._viewStack == session and session.roll ~= nil)
  end
  do
    -- The right list follows the left entry, from the one in force.
    local w, r = toProfile()
    r.right = 3
    Views.key(w, EVT_VIRTUAL_EXIT)
    local s = scene(Menu, w)
    detent(s.forward, s.forward.h, -1 + 1)
    r.left = 1
    for i = 1, #s.children do
      local node = s.children[i]
      if node.type == "label" and type(node.text) == "function" then node.text() end
    end
    r.left = #r.leftList
    for i = 1, #s.children do
      local node = s.children[i]
      if node.type == "label" and type(node.text) == "function" then node.text() end
    end
    check("coming back to a choice starts on the one in force", r.right == 2)
  end
  do
    local w, r = toProfile()
    Views.key(w, EVT_VIRTUAL_EXIT)
    check("RTN returns left", r.side == "left")
    Views.key(w, EVT_VIRTUAL_EXIT)
    check("RTN from the left closes the menu", Views.top(w) == nil)
  end

  -- A tap: what turning there and pressing does.
  do
    local w, s = open()
    -- Close box first, then the rows above the middle (two), then the rows under it.
    local under = s.buttons[4]
    under.press()
    check("a tap on the row under the middle runs it", toolOpened == 1)
  end

  -- At rest the scene is built again, and the selection stays.
  do
    local w, s = open()
    local r = roll(w)
    detent(s.forward, s.forward.h, 1)
    local key = Menu.renderKey(w)
    now = now + 100
    check("the key moves once the wheel has rested", Menu.renderKey(w) ~= key)
    check("the selection is kept", r.left == 2)
    scene(Menu, w)
    check("and the built ladder starts over", r.position == 0 and r.left == 2)
  end

  -- Drawn as buttons, the keys are the buttons' again.
  do
    local w = open()
    check("the rolling menu has its state", w._viewStack.roll ~= nil)
    w.preferences.dashboard.quick_menu_style = nil
    scene(Menu, w)
    check("the card ends it", w._viewStack.roll == nil)
    check("and ENTER is not answered for it", Views.key(w, EVT_VIRTUAL_ENTER) ~= true)
  end

  -- The model arming takes the list away from under the right side.
  do
    local w, r = toProfile()
    w.state.armed = true
    scene(Menu, w)
    check("what the right list showed has gone: back to the left", r.side == "left")
  end
end

if selfTest then
  local MUTANTS = {
    { "the list wraps", function(t) return (string.gsub(t, "if value > count then return count end", "if value > count then return 1 end")) end },
    { "ERASE first", function(t)
      return (string.gsub(t, "{ label = confirm.cancelLabel or \"CANCEL\", cancel = true },\n    { label = confirm.confirmLabel or \"OK\", agree = true },",
        "{ label = confirm.confirmLabel or \"OK\", agree = true },\n    { label = confirm.cancelLabel or \"CANCEL\", cancel = true },"))
    end },
    { "closes before the answer", function(t)
      return (string.gsub(t, "Menu.run%(widget, entry, choice, \"none\", report%)", "Menu.run(widget, entry, choice, \"done\", report)"))
    end },
    { "a write's success closes whatever it finds", function(t)
      return (string.gsub(t, "if value == \"ok\" and widget._viewStack == session and session.roll == roll\n        and Views.status%(widget, entry.id%) == \"ok\" then", "if value == \"ok\" then"))
    end },
    { "a position reported twice counts", function(t)
      return (string.gsub(t, "if sy == window.y then return end\n", ""))
    end },
    { "a build forgets the place on the right", function(t)
      return (string.gsub(t, "roll.right = place
", "roll.right = 1
"))
    end },
    { "another option takes a gone one's place", function(t)
      return (string.gsub(t, "roll.side = \"left\"
        roll.right = roll.rightOptions and currentIndex%(roll.rightOptions%) or 1", "roll.right = 1"))
    end },
    { "a question keeps what it said", function(t)
      return (string.gsub(t, "roll.question = roll.leftList%[found%]
", ""))
    end },
    { "the place goes by the row's number", function(t)
      return (string.gsub(t, "local found = indexOfEntry%(roll.leftList, before%)", "local found = (before ~= nil and roll.leftList[roll.left] ~= nil) and roll.left or nil"))
    end },
    { "a detent is not summed", function(t)
      return (string.gsub(t, "local delta = position %- roll.position", "local delta = (position > roll.position) and 1 or -1"))
    end },
  }
  quiet = true
  local red = 0
  for i = 1, #MUTANTS do
    local file = assert(io.open(SRC .. ROLL, "rb"))
    local source = string.gsub(file:read("a"), "\r\n", "\n")
    file:close()
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
