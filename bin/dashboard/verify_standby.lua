MIDSIZE, SMLSIZE, DBLSIZE, RIGHT = 2, 1, 3, 4
COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY2, COLOR_THEME_PRIMARY3 = 1, 2, 3
COLOR_THEME_SECONDARY1, COLOR_THEME_SECONDARY2, COLOR_THEME_WARNING = 4, 5, 6
LCD_W, LCD_H = 480, 320

local fontWidths = { [SMLSIZE] = 7, [MIDSIZE] = 10, [DBLSIZE] = 20 }
local fontHeights = { [SMLSIZE] = 16, [MIDSIZE] = 22, [DBLSIZE] = 38 }
lcd = { sizeText = function(value, font)
  return #tostring(value) * (fontWidths[font] or 7), fontHeights[font] or 16
end, RGB = function(rgb) return rgb end }

local batterySample = { volts = nil, pct = nil, low = false }
local Schemes
CENTER = CENTER or 8
rfsuite = { require = function(path)
  if path == "lib/radio_status.lua" then
    return { txBattery = function() return batterySample.volts, batterySample.pct, batterySample.low end }
  end
  if path == "lib/color_schemes.lua" then return Schemes end
end }

local source = string.sub(debug.getinfo(1, "S").source, 2)
local root = string.match(source, "^(.*)[/\\]bin[/\\]dashboard[/\\]") or "."
rfsuite.paths = dofile(root .. "/src/rfsuite/lib/paths.lua")
Schemes = dofile(root .. "/src/rfsuite/lib/color_schemes.lua")
local colors = Schemes.colors(nil)
local standbyPath = root .. "/src/rfsuite/widgets/dashboard/standby.lua"
if arg then
  for i = 1, #arg - 1 do if arg[i] == "--standby" then standbyPath = arg[i + 1] end end
end
local standby = assert(loadfile(standbyPath))()
local passed = 0
local function check(name, condition)
  if not condition then error("standby regression failed: " .. name, 0) end
  passed = passed + 1
end
local function text(_, fallback) return fallback end
local function rectangles(scene, rounded)
  local out = {}
  for i = 1, #scene do
    local node = scene[i]
    if node.type == "rectangle" and node.rounded == rounded then out[#out + 1] = node end
  end
  return out
end
local function labelsInside(scene, tile)
  local out = {}
  for i = 1, #scene do
    local node = scene[i]
    if node.type == "label" and type(node.y) == "number" and type(node.h) == "number"
        and node.x >= tile.x and node.x < tile.x + tile.w
        and node.y >= tile.y and node.y < tile.y + tile.h then out[#out + 1] = node end
  end
  return out
end
local function rendered(node)
  return type(node.text) == "function" and node.text() or node.text
end

local default, defaultErr = standby.decode(nil)
check("default decodes two compact rows", defaultErr == nil and #default == 3
  and default[1].row == 1 and default[2].row == 1 and default[3].row == 2
  and standby.encode(default) == "clock+tx_battery/elrs")
local wide, wideErr = standby.decode(nil, 800)
check("large-screen default carries clock, TX battery and model above a full ELRS row", wideErr == nil
  and standby.encode(wide) == "clock+tx_battery+model/elrs")
check("large-screen default validates at 800x480", standby.validate(wide, 800, 480))
check("the default follows the radio width when none is given",
  standby.encode(standby.decode(nil)) == "clock+tx_battery/elrs")
for _, fixture in ipairs({
  { 480, 272, 2 }, { 480, 320, 2 }, { 800, 480, 3 }, { 320, 480, 3 },
}) do
  local geometry = standby.geometry(fixture[1], fixture[2])
  check(string.format("geometry %dx%d exposes %d rows", fixture[1], fixture[2], fixture[3]),
    geometry.maxRows == fixture[3])
  check(string.format("default validates at %dx%d", fixture[1], fixture[2]),
    standby.validate(default, fixture[1], fixture[2]))
end
check("narrow screens expose at most two fields", standby.geometry(699, 480).maxFields == 2)
check("800-wide screens expose four fields", standby.geometry(800, 480).maxFields == 4)

local rows = standby.toRows(default)
check("row conversion keeps equal-share grouping", #rows == 2 and #rows[1] == 2 and #rows[2] == 1)
check("row conversion round trips", standby.encode(standby.fromRows(rows)) == "clock+tx_battery/elrs")
local empty, emptyErr = standby.decode("-")
check("empty sentinel round trips", #empty == 0 and emptyErr == nil and standby.encode(empty) == "-")
local salvaged, salvageErr = standby.decode("clock+secret+tx_battery//elrs+bogus/uptime")
check("invalid tokens are salvaged independently", salvageErr == "salvaged"
  and standby.encode(salvaged) == "clock+tx_battery/elrs/uptime")
local malformed, malformedErr = standby.decode("secret+bogus")
check("fully invalid saved input is malformed", #malformed == 0 and malformedErr == "malformed")
local capped, cappedErr = standby.decode("clock+date+tx_battery+model+timer1/timer1/timer2/timer3")
check("excess row fields are skipped without losing valid rows", cappedErr == "salvaged"
  and standby.encode(capped) == "clock+date+tx_battery+model/timer1/timer2")
local longCorrupt, longCorruptErr = standby.decode(string.rep("unknown+", 20000) .. "clock")
check("corrupt saved input has bounded scanning and allocation", #longCorrupt == 0
  and longCorruptErr == "malformed")
local function decodeInstructions(value)
  local instructions = 0
  debug.sethook(function() instructions = instructions + 1 end, "", 1)
  standby.decode(value)
  debug.sethook()
  return instructions
end
local validDecodeInstructions = decodeInstructions("clock+tx_battery/elrs")
local separatorDecodeInstructions = decodeInstructions(string.rep("/", 512))
check("corrupt separator input has a bounded decode cost with a valid positive control",
  validDecodeInstructions > 0 and separatorDecodeInstructions > validDecodeInstructions
    and separatorDecodeInstructions < 6000)
local noisyPrefix, noisyPrefixErr = standby.decode("clock+date+tx_battery+model+" .. string.rep("bogus+", 21))
local emptyPrefix, emptyPrefixErr = standby.decode("clock+date+tx_battery+model+" .. string.rep("+", 21))
check("bounded decode keeps a valid unterminated row before excess bad neighbors",
  noisyPrefixErr == "salvaged" and emptyPrefixErr == "salvaged"
    and standby.encode(noisyPrefix) == "clock+date+tx_battery+model"
    and standby.encode(emptyPrefix) == "clock+date+tx_battery+model")

fontWidths[SMLSIZE], fontWidths[MIDSIZE], fontHeights[SMLSIZE], fontHeights[MIDSIZE] = 8, 12, 18, 24
check("conservative fallback validates portrait default", standby.validate(default, 320, 480))
check("conservative fallback validates compact default", standby.validate(default, 480, 272))
local labels = {
  clock = "Clock", date = "Date", tx_battery = "TX battery", model = "Selected model",
  timer1 = "Timer 1", timer2 = "Timer 2", timer3 = "Timer 3", tx_gps = "TX GPS",
  uptime = "Radio uptime", firmware = "Firmware", elrs = "ELRS TX configuration",
  elrs_power = "Power", elrs_power_fixed = "fixed",
  elrs_power_dynamic = "dynamic", gps_no_fix = "No fix",
  gps_satellites = "Sat",
  gps_latitude = "Latitude", gps_longitude = "Longitude", gps_course = "Course", gps_hdop = "HDOP",
}
local duplicateLabels = {}
for i = 1, #standby.TYPES do duplicateLabels[standby.TYPES[i]] = string.rep("W", 100) end
duplicateLabels.clock, duplicateLabels.date, duplicateLabels.tx_battery = "Clock", "Date", "Battery"
check("field addition falls back to a valid duplicate when no unused module fits",
  standby.firstAddableType({ { type = "clock" }, { type = "date" }, { type = "tx_battery" } },
    800, 480, duplicateLabels) == "clock")
check("conservative captions validate portrait default", standby.validate(default, 320, 480, labels))
local portraitGpsTypes = standby.typesForField(320, 480, 1, labels)
local portraitHasGps = false
for i = 1, #portraitGpsTypes do if portraitGpsTypes[i] == "tx_gps" then portraitHasGps = true end end
check("portrait catalogue keeps GPS by choosing compact content", portraitHasGps)
local narrowTypes = standby.typesForField(200, 480, 2, labels)
local narrowHasClock = false
for i = 1, #narrowTypes do if narrowTypes[i] == "clock" then narrowHasClock = true end end
check("catalogue excludes a clock whose reactive date detail would overflow", not narrowHasClock)
local gps = standby.decode("tx_gps")
local longGpsLabels = {}; for key, value in pairs(labels) do longGpsLabels[key] = value end
longGpsLabels.tx_gps = string.rep("W", 50)
check("detailed GPS validates its half-width header cell", not standby.validate(gps, 800, 480, longGpsLabels))
fontWidths[SMLSIZE], fontWidths[MIDSIZE], fontHeights[SMLSIZE], fontHeights[MIDSIZE] = 7, 10, 16, 22

local tick = 100
getTime = function() return tick end
getDateTime = function() return { year = 2026, mon = 10, day = 19, hour = 12, min = 34 } end
getVersion = function() return "2.12.0", "tx16s-simu" end
local gpsCalls = 0
getTxGPS = function()
  gpsCalls = gpsCalls + 1
  return { fix = true, numsat = 7, lat = 52.12345, lon = 13.54321,
    alt = 1234, speed = 56, heading = 2712, hdop = 85 }
end
model = {
  getInfo = function() return { name = string.rep("W", 30) } end,
  getTimer = function(index) return { value = index == 0 and 999999 or 0 } end,
}
local cache = { text = text }
local values = standby.snapshot(default, cache)
check("default snapshot reads only selected sources", values.clock == "12:34" and values.date == "2026-10-19"
  and values.tx_battery == "-" and values.firmware == nil and values.timer1 == nil
  and values.tx_gps == nil and gpsCalls == 0)
local selected = standby.snapshot(standby.decode("firmware+timer1/tx_gps"), { text = text },
  { w = 800, h = 480 })
check("selected sources retain bounded values", selected.firmware == "2.12.0"
  and selected.timer1 == ">999:59" and selected.tx_gps == "Fix | 7" and gpsCalls == 1)
check("detailed GPS values remain available for adaptive rendering", selected._gpsLines
  and selected._gpsLines[1] == "Latitude: 52.12345°"
  and selected._gpsLines[4] == "HDOP: 0.85")

local defaultScene = standby.build({ w = 480, h = 320 }, "Waiting", text, default, values, cache)
local defaultTiles = rectangles(defaultScene, 5)
check("compact default renders all three fields", #defaultTiles == 3)
local portraitScene = standby.build({ w = 320, h = 480 }, "Waiting", text, default, values, cache)
check("portrait default renders all fields", #rectangles(portraitScene, 7) == 3)
local elrsTile = rectangles(portraitScene, 7)[3]
local elrsLabels = labelsInside(portraitScene, elrsTile)
table.sort(elrsLabels, function(a, b) return a.y < b.y end)
local noOverlap = #elrsLabels == 4
for i = 2, #elrsLabels do
  noOverlap = noOverlap and elrsLabels[i - 1].y + elrsLabels[i - 1].h <= elrsLabels[i].y
end
check("portrait ELRS text rectangles do not overlap", noOverlap)

fontWidths[SMLSIZE], fontHeights[SMLSIZE] = 8, 18
local de = assert(loadfile(root .. "/src/rfsuite/i18n/de.lua"))()
local deText = function(key, fallback) return de.widgets.dashboard.standby[key] or fallback end
local detailCache = { text = deText }
local detailValues = standby.snapshot(default, detailCache, { w = 320, h = 480 })
local detailScene = standby.build({ w = 320, h = 480 }, "Waiting", deText, default,
  detailValues, detailCache)
local detailsFit = true
for i = 1, #detailScene do
  local node = detailScene[i]
  if node.type == "label" and type(node.w) == "number" then
    local value = type(node.text) == "function" and node.text() or node.text
    if type(value) == "string" then
      detailsFit = detailsFit and lcd.sizeText(value, node.font or SMLSIZE) <= node.w
    end
  end
end
check("rendered German static and reactive text fits actual subcells", detailsFit)
fontWidths[SMLSIZE], fontHeights[SMLSIZE] = 7, 16

local trailing = standby.decode("clock+tx_battery/elrs/model+date")
local trailingCache = { text = text }
local compactScene = standby.build({ w = 480, h = 272 }, "Waiting", text, trailing,
  standby.snapshot(trailing, trailingCache), trailingCache)
local compactTiles = rectangles(compactScene, 5)
check("smaller zones render complete leading rows only", #compactTiles == 3)
check("cropping does not rewrite saved trailing rows", standby.encode(trailing) == "clock+tx_battery/elrs/model+date")
local oversizedTrailing = standby.decode("clock/date+model+timer1")
local oversizedCache = { text = text }
local oversizedScene = standby.build({ w = 480, h = 320 }, "Waiting", text, oversizedTrailing,
  standby.snapshot(oversizedTrailing, oversizedCache), oversizedCache)
check("oversized trailing row does not blank a leading valid row", #rectangles(oversizedScene, 5) == 1)
check("a build counts the saved rows it left out, for the widget's log line",
  oversizedCache.rowsShown == 1 and oversizedCache.rowsSaved == 2)
local oversizedValid, oversizedReason = standby.validate(oversizedTrailing, 480, 320, labels)
check("strict validation still rejects an oversized trailing row",
  not oversizedValid and oversizedReason == "fields")

local largest = standby.decode("clock+date+tx_battery+model/timer1+timer2+timer3+uptime/clock+date+tx_battery+model")
check("largest twelve-field equal-share layout validates", standby.validate(largest, 800, 480, labels))
local largestCache = { text = text }
local largestScene = standby.build({ w = 800, h = 480 }, "Waiting", text, largest,
  standby.snapshot(largest, largestCache), largestCache)
check("largest valid layout renders twelve tiles", #rectangles(largestScene, 7) == 12)

local elrsItems = standby.decode("elrs/elrs+clock")
local elrsCache = { text = text }
standby.setElrsSnapshot(elrsCache, {
  status = "ready", readAt = 1, identity = "one", packetRate = "D250", telemetryRatio = "1:128",
  maxPower = "25/250", dynamic = "AUX12", fields = { maxPower = { unit = "mW" } },
}, 1)
tick = 1800
local elrsValues = standby.snapshot(elrsItems, elrsCache)
local elrsScene = standby.build({ w = 800, h = 480 }, "Waiting", text, elrsItems, elrsValues, elrsCache)
check("ELRS source text preserves exact Dynamic label next to Max Power",
  string.find(elrsValues.elrs, "Max Power: 25/250 mW", 1, true)
    and string.find(elrsValues.elrs, "Dynamic: AUX12", 1, true))
local seenWidths, exactCompact = {}, 0
for i = 1, #elrsScene do
  local node = elrsScene[i]
  if node.type == "label" and type(node.text) == "function" then
    local value = rendered(node)
    if type(value) == "string" and string.find(value, "AUX12", 1, true) then
      seenWidths[node.w] = true; exactCompact = exactCompact + 1
    end
  end
end
local widthCount = 0; for _ in pairs(seenWidths) do widthCount = widthCount + 1 end
check("different-width ELRS fields keep independent display caches", exactCompact == 2 and widthCount == 2)
standby.setElrsSnapshot(elrsCache, {
  status = "ready", readAt = 2, identity = "one", packetRate = string.rep("LongRate", 20),
  telemetryRatio = string.rep("LongRatio", 20), maxPower = string.rep("LongPower", 20),
  dynamic = "AUX12", fields = { maxPower = { unit = "mW" } },
}, 2)
tick = 2406
local longValues = standby.snapshot(elrsItems, elrsCache)
local longScene = standby.build({ w = 800, h = 480 }, "Waiting", text, elrsItems, longValues, elrsCache)
local ellipses = 0
for i = 1, #longScene do
  local value = longScene[i].type == "label" and rendered(longScene[i]) or nil
  if type(value) == "string" and string.sub(value, -3) == "..." then ellipses = ellipses + 1 end
end
check("module-supplied ELRS strings are bounded instead of rejecting the scene", ellipses >= 2
  and elrsCache.valueOverflow == false and #rectangles(longScene, 7) == 3)

local unavailableCache = { text = text }
standby.setElrsSnapshot(unavailableCache, { status = "unavailable" }, 1)
tick = 3012
local unavailableItems = standby.decode("elrs")
local unavailableValues = standby.snapshot(unavailableItems, unavailableCache)
local unavailableScene = standby.build({ w = 320, h = 480 }, "Waiting", text,
  unavailableItems, unavailableValues, unavailableCache)
local unavailableFound = false
for i = 1, #unavailableScene do
  if rendered(unavailableScene[i]) == "Unavailable" then unavailableFound = true end
end
check("unknown module state renders Unavailable", unavailableFound)

local function elrsWords(reason, textFn)
  local cache = { text = textFn }
  standby.setElrsSnapshot(cache, { status = "unavailable", reason = reason }, 1)
  local items = standby.decode("elrs")
  local scene = standby.build({ w = 480, h = 320 }, "Waiting", textFn, items, standby.snapshot(items, cache), cache)
  local words = {}
  for i = 1, #scene do
    local value = rendered(scene[i])
    if type(value) == "string" then words[value] = true end
  end
  return words
end
for _, reason in ipairs({ "no_crsf", "not_elrs", "no_answer" }) do
  check("a radio without an ELRS module reads No ELRS module (" .. reason .. ")",
    elrsWords(reason, text)["No ELRS module"] and not elrsWords(reason, text)["Unavailable"])
  check("a radio without an ELRS module reads Kein ELRS-Modul in German (" .. reason .. ")",
    elrsWords(reason, deText)["Kein ELRS-Modul"] == true)
end
check("an ELRS module that answered without the fields still reads Unavailable",
  elrsWords("no_fields", text)["Unavailable"] == true and not elrsWords("no_fields", text)["No ELRS module"])

batterySample.volts, batterySample.pct, batterySample.low = 7.8, 50, false
tick = 3618
local batteryItems, batteryCache = standby.decode("tx_battery"), { text = text }
local batteryValues = standby.snapshot(batteryItems, batteryCache)
local batteryScene = standby.build({ w = 480, h = 320 }, "Waiting", text,
  batteryItems, batteryValues, batteryCache)
local fillSize
for i = 1, #batteryScene do
  check("no line with a reactive size on the screen", not (batteryScene[i].type == "hline" and batteryScene[i].size))
  if batteryScene[i].type == "rectangle" and type(batteryScene[i].size) == "function" then fillSize = batteryScene[i].size end
end
check("battery graphic uses cached percentage", type(fillSize) == "function" and fillSize() > 0)
do
  local tile = rectangles(batteryScene, 5)[1]
  local texts, figures = 0, nil
  for i = 1, #batteryScene do
    local node = batteryScene[i]
    if node.type == "label" and node.x >= tile.x and node.x < tile.x + tile.w
        and node.y >= tile.y and node.y < tile.y + tile.h then
      texts = texts + 1
      if node.align == CENTER and type(node.text) == "function" then figures = node end
    end
  end
  check("the battery tile has a caption and its figures, no third text", texts == 2 and figures ~= nil)
  local frame
  for i = 1, #batteryScene do
    local node = batteryScene[i]
    if node.type == "rectangle" and node.filled == false then frame = node end
  end
  check("the battery symbol is the large part of the tile", frame ~= nil and frame.h >= 24 and frame.w >= 60)
  check("the symbol stands inside the tile, above the figures", frame.x >= tile.x and frame.x + frame.w <= tile.x + tile.w
    and frame.y > tile.y and figures ~= nil and frame.y + frame.h <= figures.y)
  local left, right = frame.x - tile.x, tile.x + tile.w - (frame.x + frame.w)
  check("the symbol is centred, its terminal counted", right > left and right - left <= 12)
end

-- Retain the source-selection, formatting, cache, and renderer regressions that predate the
-- rows-first codec. They guard behavior that the layout rewrite must not change.
model.getInfo = function() return { name = "Model\195\169LongEnough" } end
tick = 4224
local modelValues = standby.snapshot(standby.decode("model"), { text = text })
check("UTF-8 model truncates at a codepoint", modelValues.model == "Model\195\169LongEn...")
local modelOnlyCache = { text = text }
tick = 4830
local modelOnlyValues = standby.snapshot(standby.decode("model"), modelOnlyCache)
check("unselected battery leaves no sampled value", modelOnlyValues.tx_battery == nil
  and modelOnlyCache.batteryPercent == nil)

batterySample.volts, batterySample.pct, batterySample.low = nil, nil, false
tick = 5436
local unknownBatteryCache = { text = text }
local unknownBatteryValues = standby.snapshot(batteryItems, unknownBatteryCache)
local unknownBatteryScene = standby.build({ w = 480, h = 320 }, "Waiting", text,
  batteryItems, unknownBatteryValues, unknownBatteryCache)
local unknownSize, unknownColor
for i = 1, #unknownBatteryScene do
  if unknownBatteryScene[i].type == "rectangle" and type(unknownBatteryScene[i].size) == "function" then
    unknownSize, unknownColor = unknownBatteryScene[i].size, unknownBatteryScene[i].color
  end
end
check("unknown battery draws an empty outline", unknownSize() == 0)
batterySample.volts, batterySample.pct, batterySample.low = 6.8, 100, true
tick = 6042
standby.snapshot(batteryItems, unknownBatteryCache)
check("battery graphic reaches full and uses warning color", unknownSize() > fillSize()
  and unknownColor() == colors.warning)

local gpsItems, gpsCache = standby.decode("tx_gps"), { text = text }
getTxGPS = function()
  gpsCalls = gpsCalls + 1
  return { fix = true, numsat = 7, lat = 52.12345, lon = 13.54321,
    alt = 1234, speed = 56, heading = 2712, hdop = 85 }
end
tick = 6648
-- Half the width of a 480x320 screen is too narrow for two detail columns.
local compactGpsValues = standby.snapshot(standby.decode("tx_gps+clock"), { text = text }, { w = 480, h = 320 })
check("compact GPS does not format hidden detail fields", compactGpsValues.tx_gps == "Fix | 7"
  and compactGpsValues._gpsLines == nil)
fontWidths[SMLSIZE], fontHeights[SMLSIZE] = 8, 18
local portraitGpsCache = { text = text }
local portraitGpsValues = standby.snapshot(gpsItems, portraitGpsCache, { w = 320, h = 480 })
local portraitGpsScene = standby.build({ w = 320, h = 480 }, "Waiting", text,
  gpsItems, portraitGpsValues, portraitGpsCache)
local portraitDetails = 0
for i = 1, #portraitGpsScene do
  local value = rendered(portraitGpsScene[i])
  if type(value) == "string" and string.find(value, "Latitude:", 1, true) then
    portraitDetails = portraitDetails + 1
  end
end
check("portrait GPS renders compact content when detail subcells do not fit",
  #rectangles(portraitGpsScene, 7) == 1 and portraitDetails == 0
    and portraitGpsValues._gpsLines == nil)
fontWidths[SMLSIZE], fontHeights[SMLSIZE] = 7, 16
local localeGpsItems = standby.decode("tx_gps+clock")
local localeGpsCache = { text = deText }
local deGpsValues = standby.snapshot(localeGpsItems, localeGpsCache, { w = 774, h = 480 })
localeGpsCache.text = text
local enGpsValues = standby.snapshot(localeGpsItems, localeGpsCache, { w = 774, h = 480 })
check("GPS detail demand is recomputed when localized caption widths change",
  deGpsValues._gpsLines == nil and enGpsValues._gpsLines ~= nil)
local gpsValues = standby.snapshot(gpsItems, gpsCache, { w = 800, h = 480 })
check("selected GPS reads and formats transmitter fix", gpsValues.tx_gps == "Fix | 7")
check("GPS formats all detailed units", gpsValues._gpsLines
  and gpsValues._gpsLines[1] == "Latitude: 52.12345°"
  and gpsValues._gpsLines[2] == "Longitude: 13.54321°"
  and gpsValues._gpsLines[3] == "Course: 271.2°"
  and gpsValues._gpsLines[4] == "HDOP: 0.85")
-- EdgeTX fills altitude and speed in different units for UBX and NMEA receivers, so neither is shown.
check("GPS shows no altitude and no speed", gpsValues._gpsLines and #gpsValues._gpsLines == 4)
local gpsScene = standby.build({ w = 800, h = 480 }, "Waiting", text,
  gpsItems, gpsValues, gpsCache)
local gpsDetails, gpsTimeFound = 0, false
for i = 1, #gpsScene do
  local value = rendered(gpsScene[i])
  if type(value) == "string" and (string.find(value, "Latitude:", 1, true)
      or string.find(value, "Longitude:", 1, true) or string.find(value, "Course:", 1, true)
      or string.find(value, "HDOP:", 1, true)) then gpsDetails = gpsDetails + 1 end
  if value == "Time status unknown" then gpsTimeFound = true end
end
check("wide GPS scene renders four detailed fields", gpsDetails == 4 and gpsCache.valueOverflow == false)
check("no GPS field claims a time status", not gpsTimeFound)
local twoGpsItems = standby.decode("tx_gps+clock")
local twoGpsCache = { text = text }
tick = 6720
local twoGpsValues = standby.snapshot(twoGpsItems, twoGpsCache, { w = 800, h = 480 })
local twoGpsScene = standby.build({ w = 800, h = 480 }, "Waiting", text,
  twoGpsItems, twoGpsValues, twoGpsCache)
local gpsTile = rectangles(twoGpsScene, 7)[1]
local gpsRects = labelsInside(twoGpsScene, gpsTile)
local gpsNoOverlap = true
for i = 1, #gpsRects do
  for j = i + 1, #gpsRects do
    local a, b = gpsRects[i], gpsRects[j]
    local horizontal = a.x + a.w <= b.x or b.x + b.w <= a.x
    local vertical = a.y + a.h <= b.y or b.y + b.h <= a.y
    gpsNoOverlap = gpsNoOverlap and (horizontal or vertical)
  end
end
check("two-column detailed GPS text rectangles do not overlap", gpsNoOverlap)
-- The screen skips a saved row the zone cannot carry and draws the GPS row after it; the
-- snapshot has to prepare the details for the rows the screen keeps, not stop at the skipped one.
do
  local skippedGpsItems = standby.decode("clock+clock+clock/tx_gps")
  local skippedGpsCache = { text = text }
  local skippedGpsValues = standby.snapshot(skippedGpsItems, skippedGpsCache, { w = 480, h = 480 })
  local skippedGpsScene = standby.build({ w = 480, h = 480 }, "Waiting", text,
    skippedGpsItems, skippedGpsValues, skippedGpsCache)
  local skippedDetails = 0
  for i = 1, #skippedGpsScene do
    local value = rendered(skippedGpsScene[i])
    if type(value) == "string" and (string.find(value, "Latitude: ", 1, true)
        or string.find(value, "HDOP: ", 1, true)) then skippedDetails = skippedDetails + 1 end
  end
  check("a GPS row after a skipped row shows its details", #rectangles(skippedGpsScene, 7) == 1
    and skippedDetails == 2)
end
local callsAfterGps = gpsCalls
tick = 6900
local cachedGpsValues = standby.snapshot(gpsItems, gpsCache)
check("selected GPS snapshot respects one-second cache", gpsCalls == callsAfterGps and cachedGpsValues == gpsValues)
tick = 7254
local refreshedGpsValues = standby.snapshot(gpsItems, gpsCache)
check("selected GPS refreshes after bounded cadence", gpsCalls == callsAfterGps + 1
  and refreshedGpsValues.tx_gps == "Fix | 7")
getTxGPS = function() gpsCalls = gpsCalls + 1; return { fix = false, numsat = 3 } end
tick = 7860
local noFixGpsValues = standby.snapshot(gpsItems, gpsCache)
check("selected GPS without fix still shows satellites", noFixGpsValues.tx_gps == "No fix | Sat 3"
  and noFixGpsValues._gpsLines == nil)
getTxGPS = function() gpsCalls = gpsCalls + 1; return { fix = nil } end
tick = 8466
check("selected GPS with missing fix stays unknown", standby.snapshot(gpsItems, gpsCache).tx_gps == "-")
getTxGPS = function() gpsCalls = gpsCalls + 1; return nil end
tick = 9072
check("selected unavailable GPS stays unknown", standby.snapshot(gpsItems, gpsCache).tx_gps == "-")
getTxGPS = function()
  gpsCalls = gpsCalls + 1
  return { fix = true, numsat = 4, lat = math.huge, lon = 181, alt = 1000000,
    speed = -1, heading = 3600, hdop = 65536 }
end
tick = 9678
local malformedGpsValues = standby.snapshot(gpsItems, gpsCache)
check("detailed GPS rejects non-finite and out-of-range members",
  malformedGpsValues._gpsLines[1] == "Latitude: -"
    and malformedGpsValues._gpsLines[2] == "Longitude: -"
    and malformedGpsValues._gpsLines[4] == "HDOP: -")

local tinyScene = standby.build({ w = 240, h = 68 }, "Please wait...", text, default, values, {})
check("tiny widget zone shows only a readable prerequisite", #tinyScene == 3
  and tinyScene[3].type == "label" and tinyScene[3].y >= 0 and tinyScene[3].y < 68)
local shortScene = standby.build({ w = 480, h = 275 }, "Please wait...", text, default, values, {})
local shortLogo, shortDivider, shortFirstTile
for i = 1, #shortScene do
  local node = shortScene[i]
  if node.type == "image" then shortLogo = node
  elseif node.type == "rectangle" and node.h == 1 then shortDivider = node
  elseif node.type == "rectangle" and node.rounded == 5 and shortFirstTile == nil then shortFirstTile = node end
end
check("short dashboard header keeps logo above divider and tiles", shortLogo and shortDivider and shortFirstTile
  and shortLogo.y + shortLogo.h <= shortDivider.y and shortDivider.y < shortFirstTile.y)
local invalidRadius = false
for i = 1, #defaultScene do if defaultScene[i].radius ~= nil then invalidRadius = true end end
check("standby tiles use the native rounded property", not invalidRadius)

local infoScene = standby.build({ w = 480, h = 320 }, "Exact connection reason", text,
  default, values, cache, { text = "Flight controller not detected", level = "info" })
local warningScene = standby.build({ w = 480, h = 320 }, "Unsupported API 9.9", text,
  default, values, cache, { text = "Compatibility check failed", level = "warning" })
local infoMarker, warningMarker, statusFound = false, false, false
for i = 1, #infoScene do
  local node = infoScene[i]
  if node.type == "rectangle" and node.w == 3 and node.color == colors.accent then infoMarker = true end
  if node.text == "Exact connection reason" then statusFound = true end
end
for i = 1, #warningScene do
  local node = warningScene[i]
  if node.type == "rectangle" and node.w == 3 and node.color == colors.warning then warningMarker = true end
end
check("general information strip uses calm theme accent", infoMarker)
check("general information strip preserves exact status below", statusFound)
check("warning information uses warning marker", warningMarker)
local utf8InfoScene = standby.build({ w = 480, h = 320 }, "Waiting", text, default, values, cache,
  { text = string.rep("Pr\195\169requis", 200), level = "info" })
local fittedInfo
for i = 1, #utf8InfoScene do
  local node = utf8InfoScene[i]
  if node.type == "label" and type(node.text) == "string" and string.sub(node.text, -3) == "..." then
    fittedInfo = node.text; break
  end
end
local fittedPrefix = fittedInfo and string.sub(fittedInfo, 1, -4) or ""
local asciiPrefix = string.gsub(fittedPrefix, "\195\169", "")
check("long UTF-8 information is visibly bounded", fittedInfo ~= nil
  and not string.find(asciiPrefix, "[\128-\255]"))
local captionAccent = false
for i = 1, #defaultScene do
  local node = defaultScene[i]
  if node.type == "label" and node.text == "clock" and node.color == colors.accentInk then
    captionAccent = true; break
  end
end
check("tile captions use the theme accent", captionAccent)
local compactHeaderLabels = 0
for i = 1, #defaultScene do
  local node = defaultScene[i]
  if node.type == "label" and node.y < 43 then compactHeaderLabels = compactHeaderLabels + 1 end
end
check("header omits duplicate battery title and module count", compactHeaderLabels == 0)
local largeScene = standby.build({ w = 800, h = 480 }, string.rep("W", 80), text,
  default, values, cache)
local fullStatus = false
for i = 1, #largeScene do if largeScene[i].text == string.rep("W", 80) then fullStatus = true end end
check("status line preserves the full reason", fullStatus)
local valueClosure
for i = 1, #defaultScene do
  local node = defaultScene[i]
  if node.type == "label" and type(node.text) == "function" and node.text() == "12:34" then
    valueClosure = node.text; break
  end
end
check("scene exposes a reactive value", type(valueClosure) == "function")
cache.snapshotValues.clock = "12:35"
check("reactive value updates without rebuild", valueClosure() == "12:35")

-- The fit checks above run on even-width stand-in fonts. These run on the radio's own advance
-- widths (edgetx_font_widths.lua: 800x480 radios use the lrg set, 480x272/480x320 the std set).
do
  local Widths = assert(loadfile(root .. "/bin/dashboard/edgetx_font_widths.lua"))()
  local savedSizeText, savedW, savedH = lcd.sizeText, LCD_W, LCD_H
  local measured = 0
  -- A font or a character the tables do not hold is recorded, never stood in for, and checked
  -- after each case: standby measures inside pcall, so an error raised here would only make it
  -- fall back to its own estimate.
  local unknownFonts, missingGlyphs = {}, {}
  local function useFonts(set)
    local byFont = { [SMLSIZE] = set.XS, [MIDSIZE] = set.L, [DBLSIZE] = set.bold_XL }
    lcd.sizeText = function(value, font)
      measured = measured + 1
      local widths, width = byFont[font], 0
      if widths == nil then unknownFonts[#unknownFonts + 1] = tostring(font); return 0, 0 end
      for _, code in utf8.codes(tostring(value)) do
        if widths[code] == nil then missingGlyphs[#missingGlyphs + 1] = string.format("U+%04X", code)
        else width = width + widths[code] end
      end
      return width, widths.line
    end
  end
  local function sum(widths, value)
    local width = 0
    for _, code in utf8.codes(value) do width = width + widths[code] end
    return width
  end
  local function has(list, kind)
    for i = 1, #list do if list[i] == kind then return true end end
    return false
  end
  local function tiles(scene)
    local n = 0
    for i = 1, #scene do
      if scene[i].type == "rectangle" and (scene[i].rounded == 5 or scene[i].rounded == 7) then n = n + 1 end
    end
    return n
  end
  for _, case in ipairs({ { Widths.lrg, 800, 480, "elrs+elrs+elrs+elrs/clock" },
      { Widths.std, 480, 320, "clock+clock+clock/elrs" } }) do
    useFonts(case[1]); LCD_W, LCD_H = case[2], case[3]
    local name = case[2] .. "x" .. case[3]
    check(name .. " the stand-in measures each Lua font with its own EdgeTX table",
      lcd.sizeText("23:59", SMLSIZE) == sum(case[1].XS, "23:59")
        and lcd.sizeText("23:59", MIDSIZE) == sum(case[1].L, "23:59")
        and lcd.sizeText("23:59", DBLSIZE) == sum(case[1].bold_XL, "23:59")
        and select(2, lcd.sizeText("Ag", DBLSIZE)) == case[1].bold_XL.line)
    check(name .. " small-screen default draws its three tiles with the radio's fonts",
      tiles(standby.build({ w = case[2], h = case[3] }, "Waiting", text, standby.decode("clock+tx_battery/elrs"),
        {}, {})) == 3)
    check(name .. " the editor offers the model name in a two-field row",
      has(standby.typesForField(case[2], case[3], 2, nil, {}), "model"))
    local skipped = standby.build({ w = case[2], h = case[3] }, "Waiting", text, standby.decode(case[4]), {}, {})
    check(name .. " a saved row that does not fit does not hide the rows after it", tiles(skipped) == 1)
    local wideScene = standby.build({ w = case[2], h = case[3] }, "Waiting", text, standby.decode(nil, case[2]), {}, {})
    check(name .. " the unsaved default draws every tile with the radio's fonts",
      tiles(wideScene) == (case[2] >= 700 and 4 or 3))
    local longName, nameCache = string.rep("W", 15), {}
    local nameScene = standby.build({ w = case[2], h = case[3] }, "Waiting", text,
      standby.decode(case[2] >= 700 and "clock+tx_battery+model" or "model+clock"), { model = longName }, nameCache)
    local nameNode
    for i = 1, #nameScene do
      local node = nameScene[i]
      if node.type == "label" and type(node.text) == "function" and string.sub(node.text(), 1, 1) == "W" then
        nameNode = node
      end
    end
    local shown = nameNode and nameNode.text() or ""
    -- 800x480, three fields: the name's prefix does not fit at MIDSIZE, so editor and screen both
    -- step down to SMLSIZE. 480x320, two fields: it fits at MIDSIZE.
    check(name .. " the screen draws the name in the font the editor's fit check chose",
      nameNode ~= nil and nameNode.font == (case[2] >= 700 and SMLSIZE or MIDSIZE)
        and has(standby.typesForField(case[2], case[3], case[2] >= 700 and 3 or 2, nil, {}), "model"))
    check(name .. " a model name wider than its field is shortened with ... to the field width",
      string.sub(shown, -3) == "..." and #shown < #longName + 3
        and lcd.sizeText(shown, nameNode.font) <= nameNode.w)
    local before = measured
    nameNode.text(); nameNode.text()
    check(name .. " an unchanged name is not measured again", measured == before)
    nameCache.snapshotValues = { model = "Gaui X3" }
    check(name .. " a name that fits is drawn whole", nameNode.text() == "Gaui X3")
    do
      -- The firmware string is the other radio-supplied name and is shortened the same way.
      local longFirmware, firmwareCache = string.rep("W", 20), {}
      local firmwareScene = standby.build({ w = case[2], h = case[3] }, "Waiting", text,
        standby.decode(case[2] >= 700 and "clock+tx_battery+firmware" or "firmware+clock"),
        { firmware = longFirmware }, firmwareCache)
      local firmwareNode
      for i = 1, #firmwareScene do
        local node = firmwareScene[i]
        if node.type == "label" and type(node.text) == "function" and string.sub(node.text(), 1, 1) == "W" then
          firmwareNode = node
        end
      end
      local firmwareShown = firmwareNode and firmwareNode.text() or ""
      check(name .. " a firmware string wider than its field is shortened with ... to the field width",
        firmwareNode ~= nil and string.sub(firmwareShown, -3) == "..." and #firmwareShown < #longFirmware + 3
          and lcd.sizeText(firmwareShown, firmwareNode.font) <= firmwareNode.w)
      before = measured
      firmwareNode.text(); firmwareNode.text()
      check(name .. " an unchanged firmware string is not measured again", measured == before)
      firmwareCache.snapshotValues = { firmware = "EdgeTX 2.12.2" }
      check(name .. " a changed firmware string is measured again and drawn whole when it fits",
        firmwareNode.text() == "EdgeTX 2.12.2" and measured > before)
    end
    -- Detailed GPS needs the row height of four text lines and room for its detail columns: a
    -- full-width field has both, three columns on 800x480 and two on 480x320.
    local savedGps = getTxGPS
    getTxGPS = function()
      return { fix = true, numsat = 7, lat = -33.12345, lon = -151.54321, alt = -1234, speed = 56, heading = 2712, hdop = 85 }
    end
    for _, language in ipairs({ { "en", text }, { "de", deText } }) do
      local gpsItemsReal, gpsCacheReal = standby.decode("tx_gps"), { text = language[2] }
      local gpsValuesReal = standby.snapshot(gpsItemsReal, gpsCacheReal, { w = case[2], h = case[3] })
      local gpsSceneReal = standby.build({ w = case[2], h = case[3] }, "Waiting", language[2],
        gpsItemsReal, gpsValuesReal, gpsCacheReal)
      local detailLines, allFit = 0, true
      for i = 1, #gpsSceneReal do
        local node = gpsSceneReal[i]
        local value = rendered(node)
        if node.type == "label" and type(value) == "string" and string.find(value, ": ", 1, true) then
          detailLines = detailLines + 1
          allFit = allFit and lcd.sizeText(value, node.font) <= node.w
        end
      end
      check(name .. " " .. language[1] .. " TX GPS in a full-width field is detailed",
        detailLines == 4 and allFit)
    end
    getTxGPS = savedGps
    check(name .. " every measured font and character is in the radio's font tables: "
      .. table.concat(unknownFonts, ",") .. table.concat(missingGlyphs, ","),
      #unknownFonts == 0 and #missingGlyphs == 0)
  end
  lcd.sizeText, LCD_W, LCD_H = savedSizeText, savedW, savedH
end

-- The status line is read by its label, so a new line rebuilds nothing; a plain string still works.
do
  local function holds(line)
    local tree = standby.build({ x = 0, y = 0, w = 800, h = 480 }, line, function(_, fallback) return fallback end,
      standby.decode("clock"), {}, {}, { text = "", level = "info" })
    local found = false
    for i = 1, #tree do
      local node = tree[i]
      if node.type == "label" and node.text == (type(line) == "function" and line or "the line") then found = true end
    end
    return found
  end
  check("a status line given as a function stays one on its label", holds(function() return "the line" end))
  check("a status line given as a string is shown", holds("the line"))
end

-- One read stands five seconds, one second only where a model timer is shown, and a layout that
-- changes inside that time is read at once.
do
  local cache5 = { text = text }
  local gpsOnly = standby.decode("tx_gps")
  tick = 5000
  standby.snapshot(gpsOnly, cache5)
  local reads = gpsCalls
  tick = 5400
  standby.snapshot(gpsOnly, cache5)
  check("a read stands for four seconds", gpsCalls == reads)
  tick = 5501
  standby.snapshot(gpsOnly, cache5)
  check("a read is due after five seconds", gpsCalls == reads + 1)
  local changed = standby.snapshot(standby.decode("clock"), cache5)
  check("a changed layout does not wait for the next read", changed.clock ~= nil)
  local cache1 = { text = text }
  local withTimer = standby.decode("tx_gps+timer1")
  tick = 6000
  standby.snapshot(withTimer, cache1)
  reads = gpsCalls
  tick = 6101
  standby.snapshot(withTimer, cache1)
  check("a model timer keeps the read at a second", gpsCalls == reads + 1)

  local elrsItems = standby.decode("elrs")
  local cacheE = { text = text }
  standby.setElrsSnapshot(cacheE, { status = "ready", readAt = 1, identity = "x", packetRate = "250Hz",
    telemetryRatio = "1:128", maxPower = "100", dynamic = "Off" })
  tick = 7000
  local first = standby.snapshot(elrsItems, cacheE)
  local compact = cacheE.elrsCompact
  check("the ELRS field has its three lines and no age", #compact == 3)
  tick = 7600
  local second = standby.snapshot(elrsItems, cacheE)
  check("a new read with the same answer keeps its text", second ~= first and cacheE.elrsCompact == compact)

  -- Just after power-on the clock is low: a new answer still has to show, not wait for a read.
  local cacheLow = { text = text }
  tick = 100
  standby.setElrsSnapshot(cacheLow, { status = "reading" })
  standby.snapshot(elrsItems, cacheLow)
  local before = cacheLow.elrsCompact[1]
  standby.setElrsSnapshot(cacheLow, { status = "ready", readAt = 1, identity = "x", packetRate = "250Hz",
    telemetryRatio = "1:128", maxPower = "100", dynamic = "Off" })
  standby.snapshot(elrsItems, cacheLow)
  check("an answer right after power-on shows at once", cacheLow.elrsCompact[1] ~= before)

  local function elrsLines(fields)
    local cacheL = { text = text }
    standby.setElrsSnapshot(cacheL, fields)
    tick = tick + 10
    standby.snapshot(elrsItems, cacheL)
    return cacheL.elrsCompact
  end
  local dual = elrsLines({ status = "ready", readAt = 1, identity = "x", packetRate = "500Hz(-105dBm)",
    telemetryRatio = "1:8", maxPower = "25/100", dynamic = "Dyn", fields = { maxPower = { unit = "mW" } } })
  check("the rate loses the bracket and gains a space", string.find(dual[1], " 500 Hz", 1, true) ~= nil
    and string.find(dual[1], "dBm", 1, true) == nil)
  check("the telemetry ratio has its own line", string.find(dual[2], " 1:8", 1, true) ~= nil)
  check("Dyn reads as dynamic", string.find(dual[3], "25/100 mW, dynamic", 1, true) ~= nil
    and string.find(dual[3], "Dyn", 1, true) == nil)
  check("Off reads as fixed", string.find(elrsLines({ status = "ready", readAt = 1, identity = "x", packetRate = "D250",
    telemetryRatio = "1:8", maxPower = "100", dynamic = "Off" })[3], "100, fixed", 1, true) ~= nil)
  check("an AUX choice names its channel", string.find(elrsLines({ status = "ready", readAt = 1, identity = "x", packetRate = "D250",
    telemetryRatio = "1:8", maxPower = "100", dynamic = "AUX12" })[3], "dynamic AUX12", 1, true) ~= nil)

  local cacheN = { text = text }
  local noModule = { status = "unavailable", reason = "no_answer", readAt = 1 }
  standby.setElrsSnapshot(cacheN, noModule)
  tick = 8000
  standby.snapshot(elrsItems, cacheN)
  local said = cacheN.elrsCompact[1]
  standby.setElrsSnapshot(cacheN, { status = "reading", previous = noModule })
  standby.snapshot(elrsItems, cacheN)
  check("a retry keeps saying no module was found", cacheN.elrsCompact[1] == said)
  local cacheR = { text = text }
  standby.setElrsSnapshot(cacheR, { status = "reading" })
  standby.snapshot(elrsItems, cacheR)
  check("a first read still says it is reading", cacheR.elrsCompact[1] ~= said)
end

print(string.format("standby regression: %d checks passed", passed))
