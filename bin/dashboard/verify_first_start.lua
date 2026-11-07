-- The dashboard's first-start tile, on the real runtime: where it shows, what closes it, what is
-- remembered, and that its text fits the supported screens in both languages.
--
-- Run from the repository root: lua5.3 bin/dashboard/verify_first_start.lua

local root = "."
local Stubs = assert(loadfile(root .. "/bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile(root .. "/bin/accounting/stubs/fc.lua"))()
Stubs.clearCard()
Stubs.install(root)
FC.install(Stubs)
Stubs.reset()
FC.reset()

-- The stubs define no tiny font, and the tile's last step down is that one.
_G.TINSIZE = _G.TINSIZE or 0x500

local failures, checks = 0, 0
local function check(ok, label, detail)
  checks = checks + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. label .. (detail ~= nil and (": " .. tostring(detail)) or ""))
  end
end

local TITLE = "Getting started"
local Runtime = assert(loadfile(root .. "/src/rfsuite/widgets/dashboard/runtime.lua"))()
local Preferences = assert(_G.rfsuite.require("lib/preferences.lua"))

local function treeHasLabel(text)
  local tree = Stubs.lvgl.trees[#Stubs.lvgl.trees] or {}
  for i = 1, #tree do
    if tree[i].type == "label" and tree[i].text == text then return true end
  end
  return false
end

local function pass(widget, event, count)
  for _ = 1, count or 12 do
    Stubs.tick()
    widget:refresh(event, nil)
  end
end

local function waiting(zone)
  local widget = Runtime.new(zone, {})
  widget.state.fblConnected, widget.state.armed = false, false
  widget.state.hadInflightFlight, widget.flightMode = false, "preflight"
  return widget
end

local function savedKey()
  local dashboard = Preferences.load().dashboard
  return dashboard and dashboard.standby_intro_seen
end

local function clearKey()
  local prefs = Preferences.load()
  prefs.dashboard = prefs.dashboard or {}
  prefs.dashboard.standby_intro_seen = nil
  assert(Preferences.save(prefs))
end

-- Counts the loads of the tile's two files, so "costs nothing once read" is a measurement.
local tileLoads = 0
local realLoadScript = loadScript
_G.loadScript = function(path, ...)
  if string.find(tostring(path), "first_start.lua", 1, true) or string.find(tostring(path), "notice.lua", 1, true) then
    tileLoads = tileLoads + 1
  end
  return realLoadScript(path, ...)
end

-- A zone the size of the screen shows it, in place of the rows.
LCD_W, LCD_H = 480, 320
do
  local widget = waiting({ x = 0, y = 0, w = 480, h = 270 })
  pass(widget)
  check(widget.built and treeHasLabel(TITLE), "a screen-sized zone with the top bar shows the tile")
  check(not treeHasLabel("Clock"), "the tile takes the place of the rows")
  check(savedKey() == nil, "showing it remembers nothing")
  check(tileLoads == 2, "the tile's two files are loaded for its build", tileLoads)

  -- The first change to full screen closes it and writes the key; going back leaves it closed.
  pass(widget, 0)
  check(not treeHasLabel(TITLE), "full screen closes the tile")
  check(savedKey() == true, "the first change to full screen writes the key", savedKey())
  check(widget.built and treeHasLabel("Clock"), "the rows stand in full screen")
  pass(widget, nil)
  check(not treeHasLabel(TITLE) and treeHasLabel("Clock"), "back in the zone it stays closed, and the rows stand")

  -- A later start: nothing of it runs.
  local loads = tileLoads
  local later = waiting({ x = 0, y = 0, w = 480, h = 270 })
  pass(later)
  check(not treeHasLabel(TITLE) and treeHasLabel("Clock"), "after a restart it stays closed")
  check(tileLoads == loads, "with the key saved its files are not loaded", tileLoads - loads)
end

-- A zone too small for it: the normal screen, and the key stays open for a zone that fits.
clearKey()
do
  local loads = tileLoads
  local small = waiting({ x = 0, y = 0, w = 240, h = 180 })
  pass(small)
  check(small.built and not treeHasLabel(TITLE), "a small zone shows no tile")
  check(tileLoads == loads, "a small zone does not load its files", tileLoads - loads)
  pass(small, 0)
  check(savedKey() == nil, "full screen from a small zone writes no key: the tile was not seen", savedKey())
  small:background()

  local narrow = waiting({ x = 0, y = 0, w = 300, h = 300 })
  pass(narrow)
  check(narrow.built and not treeHasLabel(TITLE), "a zone narrower than three quarters of the screen shows no tile")
  narrow:background()
  local low = waiting({ x = 0, y = 0, w = 480, h = 200 })
  pass(low)
  check(low.built and not treeHasLabel(TITLE), "a zone lower than three quarters of the screen shows no tile")
  low:background()
end

-- A full screen with the top bar's zone width reduced by sliders still counts.
do
  local widget = waiting({ x = 0, y = 0, w = 390, h = 240 })
  pass(widget)
  check(treeHasLabel(TITLE), "a zone at three quarters of the screen's size shows the tile")
  widget:background()
end

-- Armed: closed at once, written after the disarm.
clearKey()
do
  local widget = waiting({ x = 0, y = 0, w = 480, h = 270 })
  pass(widget)
  check(treeHasLabel(TITLE), "armed leg: the tile stands first")
  widget.state.armed = true
  Stubs.tick(); widget:refresh(0, nil)
  check(widget._standbyIntroClosed == true and savedKey() == nil, "armed: closed, nothing written to the card", savedKey())
  widget.state.armed = false
  pass(widget, 0, 12)
  check(savedKey() == true, "after the disarm the key is written", savedKey())
end

-- A save that fails raises nothing, the session stays closed, and the next start shows it again.
clearKey()
do
  local realSave = Preferences.save
  Preferences.save = function() return false, "control" end
  local widget = waiting({ x = 0, y = 0, w = 480, h = 270 })
  pass(widget)
  local ok, err = pcall(pass, widget, 0)
  check(ok, "a failed save raises nothing", err)
  check((widget._jobFaults.standby or 0) == 0, "a failed save does not count against the screen", widget._jobFaults.standby)
  Preferences.save = realSave
  check(savedKey() == nil, "a failed save leaves the key open", savedKey())
  pass(widget, nil)
  check(not treeHasLabel(TITLE), "after a failed save it stays closed this session")
  local later = waiting({ x = 0, y = 0, w = 480, h = 270 })
  pass(later)
  check(treeHasLabel(TITLE), "after a failed save the next start shows it again")
  later:background()
end

-- A zone the text does not fit: the rows stand, a warning says so, and the key stays open. The same
-- widget in a larger zone then shows it, since nothing was read.
clearKey()
do
  local realSize = lcd.sizeText
  local LogModule = assert(_G.rfsuite.require("lib/log.lua"))
  local realEmitf, warned = LogModule.emitf, false
  LogModule.emitf = function(tag, level, fmt, ...)
    if level == "warn" and string.find(fmt, "does not fit", 1, true) then warned = true end
    return realEmitf(tag, level, fmt, ...)
  end
  lcd.sizeText = function(value, font)
    local w, h = realSize(value, font)
    return string.find(tostring(value), "Getting", 1, true) and 100000 or w, h
  end
  local widget = waiting({ x = 0, y = 0, w = 480, h = 270 })
  pass(widget)
  check(widget.built and not treeHasLabel(TITLE) and treeHasLabel("Clock"), "a text that does not fit: the rows stand")
  check(warned, "a text that does not fit: a warning says so")
  check(savedKey() == nil, "a text that does not fit writes no key", savedKey())
  pass(widget, 0)
  check(savedKey() == nil, "full screen after it did not fit writes no key", savedKey())
  lcd.sizeText = realSize
  LogModule.emitf = realEmitf
  widget.zone = { x = 0, y = 0, w = 480, h = 290 }
  pass(widget, nil)
  check(treeHasLabel(TITLE), "the same widget in a larger zone shows it")
  widget:background()
end

-- Armed by the sensor while this file's copy says disarmed: nothing is written.
clearKey()
do
  local Armed = assert(_G.rfsuite.require("lib/armed.lua"))
  local realIsArmed = Armed.isArmed
  Armed.isArmed = function() return true end
  local widget = waiting({ x = 0, y = 0, w = 480, h = 270 })
  Armed.isArmed = realIsArmed
  pass(widget)
  check(treeHasLabel(TITLE), "sensor armed leg: the tile stands first")
  Armed.isArmed = function() return true end
  Stubs.tick(); widget:refresh(0, nil)
  check(widget._standbyIntroOwed == true and savedKey() == nil, "armed by the sensor: nothing written", savedKey())
  Armed.isArmed = realIsArmed
  pass(widget, 0, 12)
  check(savedKey() == true, "disarmed by the sensor: the key is written", savedKey())
  widget:background()
end

-- Full screen before the tile ever stood writes nothing.
clearKey()
do
  local widget = waiting({ x = 0, y = 0, w = 480, h = 270 })
  pass(widget, 0)
  check(savedKey() == nil, "full screen with the tile never shown writes no key", savedKey())
  widget:background()
end

-- The text against EdgeTX's own font widths, on the zones of the supported screens, in both
-- languages. The tables hold the small font; the normal and tiny ones are proportional estimates
-- here, so this proves the fit in the small font and the choice between fonts, and the frames on a
-- simulator read the rest.
do
  local Widths = assert(loadfile(root .. "/bin/dashboard/edgetx_font_widths.lua"))()
  local Notice = assert(loadfile(root .. "/src/rfsuite/widgets/dashboard/notice.lua"))()
  local firstStart = assert(loadfile(root .. "/src/rfsuite/widgets/dashboard/first_start.lua"))()
  local Schemes = assert(_G.rfsuite.require("lib/color_schemes.lua"))
  local savedSizeText = lcd.sizeText
  local missing = {}
  local function useFonts(set, onlySmall)
    local xs = set.XS
    lcd.sizeText = function(value, font)
      local scale = font == SMLSIZE and 1 or font == TINSIZE and 0.8 or 1.25
      if onlySmall and font ~= SMLSIZE then return 100000, xs.line end
      local width = 0
      for _, code in utf8.codes(tostring(value)) do
        if xs[code] == nil then missing[#missing + 1] = code else width = width + xs[code] end
      end
      return math.ceil(width * scale), math.ceil(xs.line * scale)
    end
  end
  local function strings(locale)
    local table_ = assert(loadfile(root .. "/src/rfsuite/i18n/" .. locale .. ".lua"))()
    local node = table_
    for part in string.gmatch("widgets.dashboard.standby", "[^.]+") do node = node[part] end
    return function(key)
      local name = string.match(key, "([^.]+)$")
      return assert(node[name], "no " .. locale .. " text for " .. key)
    end
  end
  -- Full-screen layouts with the top bar and with sliders and trims, read off the zones EdgeTX gives.
  local ZONES = {
    { "lrg", 800, 458 }, { "lrg", 800, 412 }, { "lrg", 700, 412 },
    { "std", 480, 320 }, { "std", 480, 270 }, { "std", 390, 270 },
    { "std", 480, 272 }, { "std", 480, 222 }, { "std", 390, 222 },
  }
  local Standby = assert(loadfile(root .. "/src/rfsuite/widgets/dashboard/standby.lua"))()
  local colors = Schemes.colors("dark")
  for _, locale in ipairs({ "en", "de" }) do
    local title, lines = firstStart(strings(locale))
    check(#lines == 6, locale .. ": six lines", #lines)
    local whole = table.concat(lines, " ")
    for _, zone in ipairs(ZONES) do
      local set, w, h = Widths[zone[1]], zone[2], zone[3]
      for _, onlySmall in ipairs({ false, true }) do
        useFonts(set, onlySmall)
        local tileX, tileY, tileW, tileH = Standby.noticeArea(w, h)
        local nodes = {}
        local rows = Notice.append(nodes, tileX, tileY, tileW, tileH, title, lines, colors)
        local label = string.format("%s %dx%d%s", locale, w, h, onlySmall and ", small font alone" or "")
        -- The low zones need the tiny font, and the smallest with sliders and trims may not take the
        -- German at all: there the rows stand, which the leg above shows.
        local promised = not onlySmall and not (locale == "de" and w < 480 and h < 240)
        if onlySmall then promised = h >= 300 end
        if promised then check(rows ~= nil, label .. ": it fits") end
        if rows then
          local parts = {}
          for i = 3, #nodes do
            local row = nodes[i]
            check(lcd.sizeText(row.text, row.font) <= tileW - 16, label .. ": a row stays inside the tile", row.text)
            check(row.y + row.h <= tileY + tileH, label .. ": a row stays above the footer", row.y + row.h)
            parts[#parts + 1] = row.text
          end
          check(table.concat(parts, " ") == whole, label .. ": no word is lost", #parts)
        end
      end
    end
  end
  check(#missing == 0, "every character is in the font table", missing[1])
  useFonts(Widths.std)
  check(Notice.append({}, 0, 0, 200, 20, "A title", { "A line that needs room" }, colors) == nil,
    "a room it does not fit gets no tile")
  check(Notice.append({}, 0, 0, 100, 400, "A title", { string.rep("W", 200) }, colors) == nil,
    "a word wider than the room at every font gets no tile")
  lcd.sizeText = savedSizeText
end

_G.loadScript = realLoadScript
print(string.format("verify_first_start: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
