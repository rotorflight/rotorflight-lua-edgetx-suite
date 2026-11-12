-- Run from the repository root: lua5.3 bin/ui/verify_theme_slots.lua
-- Drive the real lib/theme_slots.lua against a stub of the radio's colour table: the slots carry the
-- scheme while the tool is open and the radio's colours afterwards, on every way out -- restore(), the
-- finaliser that runs when the Lua state is collected, and the marker file the next start reads.
local checks, failures = 0, 0
local function check(ok, label)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label)
  end
end

-- The radio's colour encoding (EdgeTX gui/colorlcd/colors.h, Lua 5.3 built with LUA_32BITS): an index flag
-- is the index shifted 16 up, an RGB flag the RGB565 value shifted 16 up with RGB_FLAG 0x8000, and every
-- integer is a signed 32-bit one -- so a light colour is negative (white is -32768).
local RGB_FLAG = 0x8000
local function int32(v)
  v = v & 0xFFFFFFFF
  if v >= 0x80000000 then return v - 0x100000000 end
  return v
end
local function rgbFlag(rgb)
  local r, g, b = (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF
  local c565 = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)
  return int32((c565 << 16) | RGB_FLAG)
end
local SLOT_NAMES = {
  "COLOR_THEME_PRIMARY1", "COLOR_THEME_PRIMARY2", "COLOR_THEME_PRIMARY3", "COLOR_THEME_SECONDARY1",
  "COLOR_THEME_SECONDARY2", "COLOR_THEME_SECONDARY3", "COLOR_THEME_FOCUS", "COLOR_THEME_EDIT",
  "COLOR_THEME_ACTIVE", "COLOR_THEME_WARNING", "COLOR_THEME_DISABLED",
}
-- EdgeTX's default theme, so light (negative) and dark (positive) values are both in the table.
local DEFAULT = { 0x000000, 0xFFFFFF, 0x0C3F66, 0x125E99, 0xB6E0F2, 0xE6F0FA, 0x14A1E5, 0xFFDE00,
  0xFFDE00, 0xE00000, 0x8C8C8C }
-- The radio's colour table: index flag -> RGB flag, as lcd.getColor answers it.
local table_ = {}
local RADIO = {}
for i, name in ipairs(SLOT_NAMES) do
  _G[name] = (i - 1) << 16
  RADIO[(i - 1) << 16] = rgbFlag(DEFAULT[i])
end
local function resetRadio()
  for flag, value in pairs(RADIO) do table_[flag] = value end
end
resetRadio()

local writes = 0
local failAfter = nil   -- setColor raises once this many more calls have gone through
_G.lcd = {
  RGB = rgbFlag,
  getColor = function(flag)
    if flag & RGB_FLAG ~= 0 then return flag end
    return table_[flag]
  end,
  setColor = function(flag, color)
    if failAfter then
      if failAfter == 0 then failAfter = nil; error("instruction limit") end
      failAfter = failAfter - 1
    end
    writes = writes + 1
    table_[flag] = color
  end,
}

local TMP = os.tmpname()
os.remove(TMP)
local USER = TMP .. "_user"
os.execute("mkdir -p '" .. USER .. "'")
local MARKER = USER .. "/theme_slots.txt"

_G.fstat = function(path)
  local f = io.open(path, "r")
  if f then f:close(); return {} end
  return nil
end
_G.del = function(path) return os.remove(path) and 0 or 4 end
-- EdgeTX's io takes the file as the first argument.
local stdio = io
_G.io = {
  open = stdio.open,
  close = function(f) return f:close() end,
  read = function(f, n) return f:read(n) end,
  write = function(f, s) return f:write(s) end,
}

local modules = {}
_G.rfsuite = {
  paths = { user = USER, core = "src/rfsuite" },
  require = function(path)
    if path ~= "lib/theme_slots.lua" and path ~= "lib/color_schemes.lua" then return nil end
    if modules[path] == nil then modules[path] = assert(loadfile("src/rfsuite/" .. path))() end
    return modules[path]
  end,
}

local function load()
  return assert(loadfile("src/rfsuite/lib/theme_slots.lua"))()
end
local function exists(path) return _G.fstat(path) ~= nil end
local function radioColours()
  for flag, value in pairs(RADIO) do
    if table_[flag] ~= value then return false end
  end
  return true
end
local Schemes = rfsuite.require("lib/color_schemes.lua")

-- Controls: the stub answers as the radio does, and a written slot shows.
check(radioColours(), "control: the stub starts in the radio's colours")
lcd.setColor(COLOR_THEME_FOCUS, lcd.RGB(0x123456))
check(not radioColours(), "control: a written slot is seen")
check(RADIO[COLOR_THEME_PRIMARY2] < 0, "control: white is a negative flag, as on the radio")
resetRadio()

-- 1. apply writes every mapped slot from the scheme, leaves the rest, and leaves a marker.
local T = load()
check(T.apply("dark") == true, "apply answers true")
local dark = Schemes.colors("dark")
for _, row in ipairs(T.SLOTS) do
  check(table_[_G[row[1]]] == dark[row[2]], "dark: " .. row[1] .. " carries " .. row[2])
end
check(table_[COLOR_THEME_PRIMARY3] == RADIO[COLOR_THEME_PRIMARY3], "a slot not mapped keeps the radio's colour")
check(exists(MARKER), "apply leaves a marker")
check(T.current() == "dark", "current names the scheme")

-- 2. A second scheme rewrites the slots and keeps the radio's colours to put back.
T.apply("light")
local light = Schemes.colors("light")
check(table_[COLOR_THEME_PRIMARY2] == light.card, "light rewrites PRIMARY2 to card")
check(T.restore("test") == true, "restore answers true")
check(radioColours(), "restore after two schemes puts the radio's colours back")
check(not exists(MARKER), "restore drops the marker")
check(T.restore("again") == false, "a second restore does nothing")
check(T.current() == nil, "current is nil after restore")

-- luacheck: ignore T (dropped on purpose, so the collector can reach the finaliser)
-- 3. The finaliser: a state that ends without restore() puts the radio's colours back.
T.apply("dark")
check(not radioColours(), "the slots carry the scheme before the state ends")
T = nil
collectgarbage("collect")
collectgarbage("collect")
check(radioColours(), "the finaliser puts the radio's colours back when the module is collected")
check(not exists(MARKER), "the finaliser drops the marker")

-- 4. restore() disarms the finaliser: collecting afterwards writes nothing.
T = load()
T.apply("dark")
T.restore("test")
lcd.setColor(COLOR_THEME_FOCUS, lcd.RGB(0x00FF00))   -- the radio's colours changed afterwards
local before = writes
T = nil
collectgarbage("collect")
collectgarbage("collect")
check(writes == before, "a restored module's finaliser writes nothing")
resetRadio()

-- 5. A marker left by a run that never put the colours back, slots unchanged since: recover() puts
--    them back. Simulated by writing the slots and the marker as apply would, without a finaliser.
local function leaveMarker(scheme)
  local colors = Schemes.colors(scheme)
  local f = stdio.open(MARKER, "w")
  for _, row in ipairs(load().SLOTS) do
    local flag = _G[row[1]]
    local written = colors[row[2]]
    f:write(string.format("%d %d %d\n", flag, RADIO[flag], written))
    table_[flag] = written
  end
  f:close()
end
leaveMarker("dark")
T = load()
check(T.recover() == true, "recover answers true on a marker whose slots are unchanged")
check(radioColours(), "recover puts the radio's colours back")
check(not exists(MARKER), "recover drops the marker")
check(T.recover() == false, "recover with no marker does nothing")

-- 6. The same marker after the pilot applied a radio theme: left alone, marker dropped.
leaveMarker("dark")
lcd.setColor(COLOR_THEME_PRIMARY1, lcd.RGB(0xABCDEF))
local themed = table_[COLOR_THEME_PRIMARY1]
T = load()
check(T.recover() == false, "recover answers false when the slots changed since")
check(table_[COLOR_THEME_PRIMARY1] == themed, "recover leaves a theme applied since alone")
check(not exists(MARKER), "recover drops a marker it cannot use")
resetRadio()

-- 7. apply over such a marker takes the radio's colours from it, not from the slots it wrote.
leaveMarker("light")
T = load()
T.apply("dark")
T.restore("test")
check(radioColours(), "apply over a marker restores the radio's colours, not the suite's")

-- 8. recover() leaves alone a marker this state owns.
T.apply("dark")
check(T.recover() == false, "recover does nothing while this state has written the slots")
check(exists(MARKER), "this state's own marker stays")
T.restore("test")

-- 10. A restore stopped half way (the instruction limit, hosted) keeps everything for a second try.
T = load()
T.apply("dark")
failAfter = 3
check(not pcall(T.restore, "stopped"), "control: the stopped restore raised")
check(not radioColours(), "a stopped restore leaves some slots in the scheme")
check(T.current() == "dark", "a stopped restore keeps the state")
check(exists(MARKER), "a stopped restore keeps the marker")
check(T.restore("again") == true and radioColours(), "a second restore puts every colour back")
check(not exists(MARKER), "and drops the marker")

-- 11. The finaliser keeps the marker when a colour could not be written back, and recover() then
--     finishes from the half-restored slots.
T = load()
T.apply("dark")
failAfter = 2
T = nil
collectgarbage("collect")
collectgarbage("collect")
failAfter = nil
check(not radioColours(), "control: the finaliser's writes stopped part way")
check(exists(MARKER), "the finaliser keeps the marker when a write failed")
T = load()
check(T.recover() == true, "recover takes a half-restored table as its own")
check(radioColours(), "recover puts the rest back")
check(not exists(MARKER), "and drops the marker")

-- 12. A scheme change stopped half way: the scheme is not named yet, so the next change makes it again,
--     and a slot table mixed from both schemes still counts as the suite's.
T = load()
T.apply("dark")
failAfter = 3
check(not pcall(T.apply, "light"), "control: the stopped change raised")
check(T.current() == "dark", "a stopped change does not name the new scheme")
check(T.holding(), "and the state still holds the radio's colours")
check(T.apply("light") == true and table_[COLOR_THEME_PRIMARY2] == light.card, "the next change goes through")
T.restore("test")
check(radioColours(), "and the restore after it puts the radio's colours back")
leaveMarker("dark")
lcd.setColor(COLOR_THEME_PRIMARY1, light.text)   -- part of the slots already in the other scheme
T = load()
check(T.recover() == true, "recover takes a table mixed from both schemes as the suite's")
check(radioColours(), "and puts every colour back")

-- 13. An apply stopped at its first write still holds its state, so recover() leaves its marker alone.
T = load()
failAfter = 0
check(not pcall(T.apply, "dark"), "control: the stopped apply raised")
check(T.holding() and T.current() == nil, "a stopped apply holds the colours and names no scheme")
check(T.recover() == false and exists(MARKER), "recover leaves the marker of a state that holds colours")
check(T.restore("test") == true and radioColours() and not exists(MARKER), "restore finishes it")

-- 14. The tool hosted in the dashboard: closing it (widgets/dashboard/tool_host.lua, finish) puts the radio's
--     colours back through the module instance the tool wrote them with, and a close whose restore stops is
--     marked as owed to the widget's next pass.
do
  local Host = assert(loadfile("src/rfsuite/widgets/dashboard/tool_host.lua"))()
  local Shared = rfsuite.require("lib/theme_slots.lua")
  Shared.apply("dark")
  local widget = { _toolHost = {} }
  Host.abandon(widget, "test")
  check(radioColours() and not Shared.holding(), "the hosted close puts the radio's colours back")
  check(widget._themeRestoreOwed == nil, "and owes nothing")
  Shared.apply("dark")
  widget = { _toolHost = {} }
  failAfter = 2
  Host.abandon(widget, "stopped")
  failAfter = nil
  check(widget._themeRestoreOwed == true, "a hosted close whose restore stopped is owed to the next pass")
  check(Shared.holding(), "and the state still holds the colours")
  check(Shared.restore("next pass") == true and radioColours(), "the owed restore finishes it")
end

-- 15. The same close while the widget is off screen (widgets/dashboard/runtime.lua, background, abandons
--     the hosted tool): the widget's next background pass finishes the owed restore, with no refresh
--     in between (src/widgets/rfsuite/main.lua, background).
do
  local savedLvgl = lvgl
  lvgl = lvgl or {}
  local Wrapper = assert(loadfile("src/widgets/rfsuite/main.lua"))()
  lvgl = savedLvgl
  local Host = assert(loadfile("src/rfsuite/widgets/dashboard/tool_host.lua"))()
  local Shared = rfsuite.require("lib/theme_slots.lua")
  Shared.apply("dark")
  local widget = { _toolHost = {} }
  widget.background = function(w)
    if w._toolHost ~= nil then Host.abandon(w, "widget in the background"); w._toolHost = nil end
  end
  failAfter = 2
  Wrapper.background(widget)
  failAfter = nil
  check(widget._themeRestoreOwed == true and Shared.holding(), "control: the background close's restore stopped and is owed")
  Wrapper.background(widget)
  check(radioColours() and not Shared.holding(), "the next background pass puts the radio's colours back")
  check(widget._themeRestoreOwed == nil, "and owes nothing more")
end

-- 16. The widget's marker recovery after a pause (src/widgets/rfsuite/main.lua, recoverThemeSlots): a
--     recover that stops part way is tried again on the next pass while the marker is still there, and
--     given up after three tries until the next pause, so a recover that keeps failing does not load the
--     module on every pass.
do
  local savedLvgl = lvgl
  lvgl = lvgl or {}
  local Wrapper = assert(loadfile("src/widgets/rfsuite/main.lua"))()
  lvgl = savedLvgl
  local function freshMarker()
    local T = load()
    T.apply("dark")
    modules["lib/theme_slots.lua"] = load()   -- the widget's own instance holds nothing
  end
  freshMarker()
  local widget = { refresh = function() end }
  Wrapper.refresh(widget)                          -- first pass: the pause is seen
  check(widget._themeRecoverOwed == true, "control: the first pass owes a recovery")
  failAfter = 2
  Wrapper.refresh(widget)                          -- recover stops after two writes
  failAfter = nil
  check(not radioColours() and exists(MARKER), "control: the stopped recover left colours and marker")
  Wrapper.refresh(widget)
  check(radioColours() and not exists(MARKER), "the next pass finishes the recovery")
  freshMarker()
  widget = { refresh = function() end }
  Wrapper.refresh(widget)
  local stops = 0
  for _ = 1, 5 do
    failAfter = 0
    Wrapper.refresh(widget)
    if failAfter == nil then stops = stops + 1 end
    failAfter = nil
  end
  check(stops == 3, "a recover that keeps stopping is tried three times, not on every pass (" .. stops .. ")")
  rfsuite.require("lib/theme_slots.lua").recover()
end

-- 9. Without lcd.setColor (a desktop runner, an old radio) nothing is attempted.
local saved = lcd.setColor
lcd.setColor = nil
T = load()
check(T.apply("dark") == false, "apply refuses without lcd.setColor")
check(not exists(MARKER), "and leaves no marker")
lcd.setColor = saved

os.execute("rm -rf '" .. USER .. "'")
print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
