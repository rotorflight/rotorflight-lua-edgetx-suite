-- EdgeTX exposes string functions without a string-method metatable.
debug.getmetatable("").__index = nil
-- Exercise the real settings controls and model store seam without MSP or radio writes.
local cache, saved, checked = {}, {}, 0
local function check(ok, message) checked = checked + 1; assert(ok, message) end
loadScript = function(path)
  local relative = string.gsub(path, "^/SCRIPTS/TOOLS/rfsuite%-core/", "")
  return assert(loadfile("src/rfsuite/" .. relative))
end
rfsuite = { session = { mcu_id = "board", isConnected = true,
  modelPreferences = { inflight = { flight_list = "18,250" } } }, require = function(path)
  assert(not string.find(path, "tasks/msp/", 1, true), "picker must not reach MSP")
  if path == "lib/env.lua" then return { isWidget = function() return true end } end
  if path == "lib/model_preferences.lua" then return { saveByMcuId = function(id, prefs)
    saved[#saved + 1] = { id = id, stored = prefs.inflight.flight_list }; return true end } end
  if not cache[path] then cache[path] = loadScript(path)() end
  return cache[path]
end }
local realLoad = loadScript
loadScript = function(path)
  if string.find(path, "lib/model_preferences.lua", 1, true) or string.find(path, "lib/env.lua", 1, true) then
    return function() return rfsuite.require(string.gsub(path, "^/SCRIPTS/TOOLS/rfsuite%-core/", "")) end
  end
  return realLoad(path)
end
SMLSIZE, MIDSIZE, CENTER = 1, 2, 0
COLOR_THEME_PRIMARY1, COLOR_THEME_SECONDARY1, COLOR_THEME_SECONDARY2 = 1, 2, 3
lvgl = { UI_ELEMENT_HEIGHT = 32 }
local F = rfsuite.require("widgets/dashboard/inflight/functions.lua")
local Setup = rfsuite.require("widgets/dashboard/inflight/setup.lua")
-- Every standard cell carries its function's full range: the firmware clamps each step into the
-- slot's adjMin..adjMax, so a narrower band turns a first press into a jump to its edge.
local function clampStep(record, value, step)
  return math.max(record.adjMin, math.min(record.adjMax, value + step))
end
for bank = 1, F.BANK_COUNT do
  for row = 1, F.ROW_COUNT do
    local record = assert(F.standardRecord(bank, row, 5, 6))
    local fn = assert(F.byId(record.adjFunction))
    check(record.adjMin == fn.min and record.adjMax == fn.max,
      "standard cell " .. bank .. "/" .. row .. " carries the function's own range")
  end
end
local hover = assert(F.standardRecord(3, 6, 5, 6))
check(hover.adjFunction == 40 and clampStep(hover, 600, -5) == 595, "rescue hover collective steps once from 600")
check(clampStep({ adjMin = 10, adjMax = 200 }, 600, -5) == 200, "control: the documented band jumps 600 to 200")
check(clampStep(assert(F.standardRecord(3, 3, 5, 6)), 0, 5) == 5, "a D gain of 0 steps to 5, not to 10")
-- Under its group's title a name does not repeat the title; a name that does not start with it stays whole.
check(F.shortName(49) == "P-gain" and F.nameOf(49) == "Governor P-gain", "the group title is not repeated")
check(F.shortName(58) == "B-gain", "Yaw B-gain under Yaw")
check(F.shortName(39) == F.nameOf(39), "control: a name without the title as prefix is unchanged")
-- The overlay is the only flight-list editor; the radio page must not load its old editor.
local target = {}
Setup.storeModelSettings(target, {flight_list = "18,83"})
check(Setup.loadModelSettings({inflight = target}).flight_list == "18,83", "model flight-list store round trip")
local legacy = Setup.loadModelSettings({inflight = {enabled = false, set_mode = "custom"}})
check(legacy.enabled == nil and legacy.set_mode == nil, "old model switches are ignored")
check(Setup.settings({inflight = {enabled = true}}, {inflight = {enabled = false}}).active,
  "radio master alone enables a model with its old switch off")
check(not Setup.settings({inflight = {enabled = false}}, {inflight = {enabled = true}}).active,
  "control: a model switch cannot enable the radio master")
local Page = rfsuite.require("app/pages/settings/dashboard/inflight/page.lua")
local function upvalue(fn, key)
  for i = 1, 100 do local name, value = debug.getupvalue(fn, i); if name == key then return value end end
  error("missing upvalue " .. key)
end
Page.getHeaderActions()
local ui = upvalue(Page.build, "ui")
local ctx = {preferences = {}, children = {}, x = 0, y = 0, w = 456,
  requestRebuild = function() end, savePreferences = function() return true end}
Page.onReload(ctx)
Page.build(ctx)
check(ui.flightPicker == nil and ui.flightWanted == nil, "radio page contains no model list editor")
for key in pairs(cache) do check(not string.find(key, "flightlist", 1, true), "no old editor loaded") end
Page.onClose()

-- The radio page takes the overlay's instance of the setup module when the dashboard holds one
-- (the tool hosted in the widget shares its Lua state), and a private one released with the page
-- otherwise, so the standalone tool keeps nothing of it after closing.
do
  local key = "/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/inflight/setup.lua"
  -- This test has a minimal memoizer of its own; the suite's keeps its modules here.
  rfsuite.modules = rfsuite.modules or {}
  local saved = rfsuite.modules[key]
  local overlay = saved or Setup
  local function used()
    for _, name in ipairs({"build", "onReload", "getHeaderActions"}) do
      for i = 1, 100 do
        local upname, value = debug.getupvalue(Page[name], i)
        if upname == nil then break end
        if upname == "ensureDeps" then return upvalue(value, "Setup") end
      end
    end
    error("the page's dependency loader was not found")
  end
  for _, loaded in ipairs({true, false}) do
    rfsuite.modules[key] = loaded and overlay or nil
    Page.onReload(ctx); Page.build(ctx)
    local instance = used()
    if loaded then
      check(instance == overlay, "the hosted page shares the overlay's setup module")
    else
      check(type(instance) == "table" and instance ~= overlay and rfsuite.modules[key] == nil,
        "without an overlay the page loads a private setup module and caches nothing")
    end
    Page.onClose()
    check(used() == nil, "closing the page drops its setup reference")
  end
  rfsuite.modules[key] = saved
end

-- The sheet builds wrapped labels inside the actual scrollable help page at 480x320.
LCD_W, LCD_H = 480, 320
local HelpView = rfsuite.require("ui/help_view.lua")

-- The remaining radio help sheet obeys the same character limits in both locales.
for _, lang in ipairs({ "en", "de" }) do
  local locale = assert(loadfile("src/rfsuite/i18n/" .. lang .. ".lua"))()
  local function translate(key)
    local value = locale
    for part in string.gmatch(key, "[^.]+") do value = value[part] end
    return value
  end
  for _, path in ipairs({ "settings/dashboard/inflight" }) do
    local help = loadScript("/SCRIPTS/TOOLS/rfsuite-core/app/pages/" .. path .. "/help.lua")()({ i18n = { t = translate } }).message
    local length = utf8.len(help)
    local preview = lang == "de" and "Sichtbar, sobald Einstellungen > Allgemein > Vorschau an ist."
      or "Shown once Settings > General > Preview is on."
    check(string.find(help, preview, 1, true), "existing preview help context is retained")
    check(length <= 600, lang .. " " .. path .. " sheet length " .. length)
    for line in string.gmatch(help, "[^\n]+") do check(utf8.len(line) <= 200, "help line <= 200") end
    local scene = HelpView.build({ contentW = 480, message = help, title = "Help" })
    check(scene[1].type == "page" and scene[1].backButton, "help remains scrollable on 480x320")
    for _, node in ipairs(scene[1].children) do
      check(node.w == 464 and node.x == nil, "help label/marker stays within 480px body")
    end
    print(lang .. " " .. path .. " help: " .. length .. " characters")
  end
end
print(checked .. " flight-list/page/help checks passed; model save and refusal controls included")
