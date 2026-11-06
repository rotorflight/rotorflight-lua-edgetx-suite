local M = {}
local MODULE_PATH = "widgets/dashboard/standby.lua"
local consumers = {}

function M.acquire(owner)
  if owner ~= nil then consumers[owner] = true end
end

function M.release(owner)
  if owner ~= nil then consumers[owner] = nil end
  if next(consumers) == nil and type(_G) == "table" and type(_G.rfsuite) == "table"
      and type(_G.rfsuite.clearModule) == "function" then
    _G.rfsuite.clearModule(MODULE_PATH)
    -- Loaded by this module for the TX battery field. It holds no state, so a theme that keeps
    -- its own reference loses nothing.
    _G.rfsuite.clearModule("lib/radio_status.lua")
    _G.rfsuite.clearModule("lib/color_schemes.lua")
  end
end

function M.consumerCount()
  local count = 0
  for _ in pairs(consumers) do count = count + 1 end
  return count
end
local function loadRadioStatus()
  if _G.rfsuite and type(_G.rfsuite.require) == "function" then return _G.rfsuite.require("lib/radio_status.lua") end
  if type(loadScript) ~= "function" then return nil end
  local chunk = loadScript(_G.rfsuite.paths.core .. "/lib/radio_status.lua", "t")
  return chunk and chunk() or nil
end
local RadioStatus = loadRadioStatus()
local function loadSchemes()
  if _G.rfsuite and type(_G.rfsuite.require) == "function" then return _G.rfsuite.require("lib/color_schemes.lua") end
  return assert(loadScript(_G.rfsuite.paths.core .. "/lib/color_schemes.lua", "t"))()
end

M.KEY_ENABLED = "standby_enabled"
M.KEY_LAYOUT = "standby_layout"
M.MAX_ROWS = 3
M.MAX_FIELDS = 4
M.MAX_ITEMS = M.MAX_ROWS * M.MAX_FIELDS

M.TYPES = { "clock", "date", "tx_battery", "model", "timer1", "timer2", "timer3", "tx_gps", "uptime", "firmware", "elrs" }
local TYPE_KEYS = {
  clock = "module_clock", date = "module_date", tx_battery = "module_tx_battery", model = "module_model",
  timer1 = "module_timer1", timer2 = "module_timer2", timer3 = "module_timer3", tx_gps = "module_tx_gps",
  uptime = "module_uptime", firmware = "module_firmware", elrs = "module_elrs",
}

-- The default always ends in a full ELRS row, so a pilot sees what the module is set to before
-- choosing anything; a screen wide enough for four fields per row adds the model name above it.
local DEFAULT = "clock+tx_battery/elrs"
local DEFAULT_WIDE = "clock+tx_battery+model/elrs"
M.WIDE_WIDTH = 700

function M.defaultLayout(width)
  width = tonumber(width) or LCD_W or 480
  return width >= M.WIDE_WIDTH and DEFAULT_WIDE or DEFAULT
end
local TYPE_SET = {}
for i = 1, #M.TYPES do TYPE_SET[M.TYPES[i]] = true end

function M.toRows(items)
  local byNumber = {}
  for i = 1, math.min(type(items) == "table" and #items or 0, M.MAX_ITEMS) do
    local item = items[i]
    if type(item) == "table" and TYPE_SET[item.type] then
      local rowNumber = math.floor(tonumber(item.row) or 1)
      if rowNumber >= 1 and rowNumber <= M.MAX_ROWS then
        local row = byNumber[rowNumber]
        if row == nil then row = {}; byNumber[rowNumber] = row end
        if #row < M.MAX_FIELDS then row[#row + 1] = { type = item.type } end
      end
    end
  end
  local rows = {}
  for rowNumber = 1, M.MAX_ROWS do
    if byNumber[rowNumber] and #byNumber[rowNumber] > 0 then rows[#rows + 1] = byNumber[rowNumber] end
  end
  return rows
end

function M.fromRows(rows)
  local items = {}
  for rowNumber = 1, math.min(type(rows) == "table" and #rows or 0, M.MAX_ROWS) do
    local row = rows[rowNumber]
    for field = 1, math.min(type(row) == "table" and #row or 0, M.MAX_FIELDS) do
      local item = row[field]
      if type(item) == "table" and TYPE_SET[item.type] then
        items[#items + 1] = { type = item.type, row = rowNumber }
      end
    end
  end
  return items
end

function M.decode(value, width)
  if value == nil then value = M.defaultLayout(width) end
  if value == "-" then return {} end
  if type(value) ~= "string" or value == "" then return {}, "malformed" end
  local scanLimit = 256
  local tokenLimit = M.MAX_ITEMS * 2
  local length = math.min(#value, scanLimit)
  local rows, row, invalid, tokenStart, tokens = {}, {}, #value > scanLimit, 1, 0
  for at = 1, length + 1 do
    local separator = at > length and "/" or string.sub(value, at, at)
    if separator == "+" or separator == "/" then
      tokens = tokens + 1
      if tokens > tokenLimit then
        if #row > 0 and #rows < M.MAX_ROWS then rows[#rows + 1] = row end
        invalid = true
        break
      end
      local kind = string.sub(value, tokenStart, at - 1)
      if TYPE_SET[kind] and #row < M.MAX_FIELDS then row[#row + 1] = { type = kind }
      else invalid = true end
      tokenStart = at + 1
      if separator == "/" then
        if #row > 0 and #rows < M.MAX_ROWS then rows[#rows + 1] = row
        else invalid = true end
        row = {}
        if #rows >= M.MAX_ROWS and at <= length then invalid = true; break end
      end
    end
  end
  local out = M.fromRows(rows)
  if #out == 0 then return {}, invalid and "malformed" or nil end
  return out, invalid and "salvaged" or nil
end

function M.encode(items)
  local rows, out = M.toRows(items), {}
  for rowNumber = 1, #rows do
    local fields = {}
    for field = 1, #rows[rowNumber] do fields[#fields + 1] = rows[rowNumber][field].type end
    if #fields > 0 then out[#out + 1] = table.concat(fields, "+") end
  end
  if #out == 0 then return "-" end
  return table.concat(out, "/")
end

-- Names the radio supplies (the model name, the firmware string) are shortened with "..." where
-- the field is narrower than the name. A field offers them when this prefix fits; the screen
-- shortens with the same fitLine in the same font.
local SHORTENED = { model = true, firmware = true }
local SHORTENED_WORST = string.rep("W", 8) .. "..."
local WORST = {
  clock = "23:59", date = "2099-12-31", tx_battery = "12.0 V  100%", model = "WWWWWWWWWWWWWWW",
  timer1 = "<-999:59", timer2 = "<-999:59", timer3 = "<-999:59", tx_gps = "No fix | Sat 99+",
  uptime = ">999:59", firmware = "WWWWWWWWWWWWWWWWWWWW",
}
local ELRS_WORST = {
  { "elrs_packet_rate", "Packet Rate", "1000Hz Full" },
  { "elrs_telemetry_ratio", "Telemetry Ratio", "1:128" },
  { "elrs_max_power", "Max Power", "25/250 mW" },
  { "elrs_dynamic", "Dynamic", "AUX12" },
}
-- What an ELRS field has to fit: the three lines, the last without its mode, which a narrow field
-- shortens rather than giving up the field for.
local ELRS_COMPACT_WORST = {
  { "elrs_packet_rate", "Packet Rate", "1000 Hz Full" },
  { "elrs_telemetry_ratio", "Telemetry Ratio", "1:128" },
  { "elrs_power", "Power", "25/250 mW" },
}
-- No altitude and no speed: EdgeTX fills them in 0.1 m and 0.1 m/s from a UBX receiver but in
-- m and cm/s from an NMEA one (radio/src/gps_ubx.cpp, gps_nmea.cpp), and getTxGPS() passes them
-- on without saying which protocol is in use.
local GPS_WORST = {
  { "gps_latitude", "Latitude", "-180.00000°" },
  { "gps_longitude", "Longitude", "-180.00000°" },
  { "gps_course", "Course", "359.9°" },
  { "gps_hdop", "HDOP", "655.35" },
}

local function measure(text, font, cache)
  text = tostring(text)
  local fontCache
  if cache then
    fontCache = cache[font]
    if fontCache == nil then fontCache = {}; cache[font] = fontCache end
    local hit = fontCache[text]
    if hit then return hit, fontCache[false] end
  end
  local w, h
  if lcd and type(lcd.sizeText) == "function" then
    local ok, measuredW, measuredH = pcall(lcd.sizeText, text, font)
    if ok and type(measuredW) == "number" and type(measuredH) == "number" then
      w, h = measuredW, measuredH
    end
  end
  if w == nil then
    if font == DBLSIZE then w, h = #text * 20, 38
    else w, h = #text * (font == MIDSIZE and 12 or 8), font == MIDSIZE and 24 or 18 end
  end
  if fontCache then
    fontCache[text] = w
    if fontCache[false] == nil then fontCache[false] = h end
  end
  return w, h
end

local function fitLine(text, width, font)
  text = tostring(text or "")
  local byteLimit = 192
  if #text <= byteLimit and measure(text, font) <= width then return text end
  local positions, i = {}, 1
  while i <= #text and i <= byteLimit do
    positions[#positions + 1] = i
    local byte = string.byte(text, i)
    i = i + (byte < 0x80 and 1 or byte < 0xE0 and 2 or byte < 0xF0 and 3 or 4)
  end
  local low, high, best = 1, #positions, 0
  while low <= high do
    local middle = math.floor((low + high) / 2)
    local candidate = string.sub(text, 1, positions[middle] - 1) .. "..."
    if measure(candidate, font) <= width then
      best, low = middle, middle + 1
    else
      high = middle - 1
    end
  end
  if best > 0 then return string.sub(text, 1, positions[best] - 1) .. "..." end
  return "..."
end
local function frameGeometry(height)
  local compact = height < 400
  if height < 160 then return true, 0, 24, nil, true, true end
  local short = height < 300
  return compact, short and 34 or compact and 49 or 68,
    short and 52 or 64, short and 28 or compact and 43 or 60, short, false
end
function M.geometry(width, height)
  local compact, top, footer, _, _, micro = frameGeometry(height)
  local gap = micro and 4 or compact and 6 or 10
  local margin = width < 360 and 6 or compact and 10 or 16
  local _, textHeight = measure("Ag", SMLSIZE)
  local rowHeight = math.max(compact and 84 or 96, textHeight * 4 + 12)
  local available = math.max(0, height - top - footer - gap)
  local rows = math.min(M.MAX_ROWS, math.floor((available + gap) / (rowHeight + gap)))
  return { compact = compact, micro = micro, top = top, footer = footer, gap = gap,
    margin = margin, rowHeight = rowHeight, maxRows = rows, maxFields = width >= M.WIDE_WIDTH and 4 or 2 }
end

local function fieldWidth(width, geometry, fields)
  return math.floor((width - geometry.margin * 2 - geometry.gap * (fields - 1)) / fields)
end

local function gpsDetailed(width, height, labels, measureCache, knownGeometry)
  local geometry = knownGeometry or M.geometry(width, height)
  local _, lineHeight = measure("Ag", SMLSIZE, measureCache)
  local columns = width >= 600 and 3 or 2
  -- As build draws it: the caption, 12 px, then the detail lines.
  local lines = 1 + math.ceil(#GPS_WORST / columns)
  if lineHeight * lines + 12 > geometry.rowHeight then return false end
  local inner = width - 16
  local detailWidth = math.floor((inner - geometry.gap * (columns - 1)) / columns)
  for n = 1, #GPS_WORST do
    local spec = GPS_WORST[n]
    local line = (labels and labels[spec[1]] or spec[2]) .. ": " .. spec[3]
    if measure(line, SMLSIZE, measureCache) > detailWidth then return false end
  end
  return true
end

local function valueFont(kind, boxW, geometry)
  -- The battery's figures sit small under its symbol, which takes the value's place.
  if kind == "elrs" or kind == "tx_battery" then return SMLSIZE end
  if kind == "clock" then
    return boxW >= 360 and (geometry.compact and MIDSIZE or DBLSIZE) or MIDSIZE
  end
  return boxW < 180 and SMLSIZE or MIDSIZE
end
-- A value whose worst case does not fit in its font steps down, DBLSIZE to MIDSIZE to SMLSIZE.
-- The editor's fit check and the screen use this one answer, so what is offered is what is drawn.
local STEP_DOWN = {}
if DBLSIZE ~= nil then STEP_DOWN[DBLSIZE] = MIDSIZE end
if MIDSIZE ~= nil then STEP_DOWN[MIDSIZE] = SMLSIZE end
local function fittingFont(kind, worstValue, boxW, width, geometry, measureCache)
  local font = valueFont(kind, boxW, geometry)
  while font ~= nil and measure(worstValue, font, measureCache) > width do font = STEP_DOWN[font] end
  return font
end

local function moduleFits(kind, boxW, height, labels, knownGeometry, measureCache)
  local geometry = knownGeometry or M.geometry(boxW, height)
  local inner = boxW - 16
  local label = labels and labels[kind] or kind
  local detailedGps = kind == "tx_gps" and gpsDetailed(boxW, height, labels, measureCache, geometry)
  local headerWidth = detailedGps and math.floor(inner / 2) or inner
  if measure(label, SMLSIZE, measureCache) > headerWidth then return false end
  local worstValue = SHORTENED[kind] and SHORTENED_WORST or WORST[kind] or "-"
  if kind == "tx_gps" then
    worstValue = string.format("%s | %s 99+", labels and labels.gps_no_fix or "No fix",
      labels and labels.gps_satellites or "Sat")
  end
  if kind == "elrs" then
    for n = 1, #ELRS_COMPACT_WORST do
      local spec = ELRS_COMPACT_WORST[n]
      local line = (labels and labels[spec[1]] or spec[2]) .. " " .. spec[3]
      if measure(line, SMLSIZE, measureCache) > inner then return false end
    end
    return SMLSIZE
  end
  local font = fittingFont(kind, worstValue, boxW, headerWidth, geometry, measureCache)
  if font == nil then return false end
  if kind == "clock" and measure(WORST.date, SMLSIZE, measureCache) > inner then return false end
  return font
end

function M.typesForField(width, height, fields, labels, measureCache, knownGeometry)
  local geometry = knownGeometry or M.geometry(width, height)
  if fields < 1 or fields > geometry.maxFields then return {} end
  local boxW, out = fieldWidth(width, geometry, fields), {}
  for i = 1, #M.TYPES do
    if moduleFits(M.TYPES[i], boxW, height, labels, geometry, measureCache) then out[#out + 1] = M.TYPES[i] end
  end
  return out
end

function M.firstAddableType(row, width, height, labels, measureCache, knownGeometry)
  local fields = type(row) == "table" and #row + 1 or 1
  local geometry = knownGeometry or M.geometry(width, height)
  if fields < 1 or fields > geometry.maxFields then return nil end
  local boxW, used = fieldWidth(width, geometry, fields), {}
  local fallback
  for i = 1, fields - 1 do
    local kind = row[i].type
    used[kind] = true
    if not moduleFits(kind, boxW, height, labels, geometry, measureCache) then return nil end
    if fallback == nil then fallback = kind end
  end
  for i = 1, #M.TYPES do
    local kind = M.TYPES[i]
    if not used[kind] and moduleFits(kind, boxW, height, labels, geometry, measureCache) then return kind end
  end
  return fallback
end

function M.canAddField(row, width, height, labels)
  local count = type(row) == "table" and #row or 0
  local types = M.typesForField(width, height, count + 1, labels)
  if #types == 0 then return false end
  local allowed = {}
  for i = 1, #types do allowed[types[i]] = true end
  for i = 1, count do if not allowed[row[i].type] then return false end end
  return true, types
end

local function layout(items, width, height, labels, crop)
  local sourceRows, geometry = M.toRows(items), M.geometry(width, height)
  if #sourceRows == 0 then return nil, "empty", 1 end
  if not crop and #sourceRows > geometry.maxRows then return nil, "rows", 1 end
  local rows, itemIndex, fitCache, detailCache, heightCache = {}, 0, {}, {}, {}
  local _, detailHeight = measure("Ag", SMLSIZE)
  heightCache[SMLSIZE] = detailHeight
  -- A drawn screen (crop) skips a saved row that does not fit this zone and packs the rows that
  -- do from the top, so one row too wide for a widget zone does not hide the rows after it.
  for rowNumber = 1, crop and #sourceRows or math.min(#sourceRows, geometry.maxRows) do
    if #rows >= geometry.maxRows then break end
    local source = sourceRows[rowNumber]
    local tooMany = #source > geometry.maxFields
    if tooMany and not crop then return nil, "fields", itemIndex + 1 end
    local boxW = fieldWidth(width, geometry, #source)
    local row = { items = {}, y = geometry.top + #rows * (geometry.rowHeight + geometry.gap),
      h = geometry.rowHeight }
    local fits = not tooMany
    for field = 1, tooMany and 0 or #source do
      itemIndex = itemIndex + 1
      local item = source[field]
      local fitKey = item.type .. ":" .. tostring(boxW)
      local fitsItem = fitCache[fitKey]
      if fitsItem == nil then
        fitsItem = moduleFits(item.type, boxW, height, labels, geometry)
        fitCache[fitKey] = fitsItem
      end
      if not fitsItem then
        if crop then fits = false; break end
        return nil, "width", itemIndex
      end
      local font = fitsItem
      if heightCache[font] == nil then local _; _, heightCache[font] = measure("Ag", font) end
      local detailed = false
      if item.type == "tx_gps" then
        detailed = detailCache[boxW]
        if detailed == nil then
          detailed = gpsDetailed(boxW, height, labels, nil, geometry)
          detailCache[boxW] = detailed
        end
      end
      row.items[#row.items + 1] = { item = item,
        x = geometry.margin + (field - 1) * (boxW + geometry.gap), w = boxW,
        font = font, lineHeight = heightCache[font], detailHeight = detailHeight,
        valueY = detailHeight + 12, detailedGps = detailed }
    end
    if fits then rows[#rows + 1] = row end
  end
  if #rows == 0 then return crop and {} or nil, "fit", 1 end
  return rows, #rows < #sourceRows and "cropped" or nil
end

-- Whether the screen draws a detailed GPS field: asked of the same rows the screen keeps.
function M.needsGpsDetails(items, width, height, labels)
  local rows = layout(items, width, height, labels, true) or {}
  for r = 1, #rows do
    local boxes = rows[r].items
    for i = 1, #boxes do if boxes[i].detailedGps then return true end end
  end
  return false
end

function M.validate(items, width, height, labels)
  if type(items) ~= "table" or #items == 0 then return false, "empty" end
  if #items > M.MAX_ITEMS then return false, "count" end
  if width < 200 or height < 45 then return false, "fit", nil, 1 end
  local rows, err, offending = layout(items, width, height, labels, false)
  return rows ~= nil, err, rows, offending
end

local function safeCall(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, ...)
  if ok then return value end
  return nil
end

local function timerValue(index)
  if not model or type(model.getTimer) ~= "function" then return nil end
  local value = safeCall(model.getTimer, index - 1)
  if type(value) == "table" then value = value.value end
  if type(value) ~= "number" then return nil end
  local sign = value < 0 and "-" or ""
  value = math.abs(math.floor(value))
  if value > 59999 then return sign == "-" and "<-999:59" or ">999:59" end
  return string.format("%s%d:%02d", sign, math.floor(value / 60), value % 60)
end

local function bounded(value, limit)
  if type(value) ~= "string" or value == "" then return "-" end
  local positions, i = {}, 1
  while i <= #value do
    positions[#positions + 1] = i
    local byte = string.byte(value, i)
    i = i + (byte < 0x80 and 1 or byte < 0xE0 and 2 or byte < 0xF0 and 3 or 4)
  end
  if #positions <= limit then return value end
  return string.sub(value, 1, positions[limit - 2] - 1) .. "..."
end

-- The gap between the battery symbol's outline and its fill, on each side.
local BATTERY_INSET = 3

local function battery(cache)
  local volts, pct, low = nil, nil, false
  if RadioStatus then volts, pct, low = RadioStatus.txBattery() end
  cache.batteryLow = low
  cache.batteryPercent = pct
  if cache.batteryWidths then
    cache.batteryFills = cache.batteryFills or {}
    for width in pairs(cache.batteryWidths) do
      cache.batteryFills[width] = math.max(0, math.floor((width - BATTERY_INSET * 2) * (pct or 0) / 100))
    end
  end
  if not volts or not pct then return "-" end
  return string.format("%.1f V  %d%%", volts, pct)
end

local function usableGps(value, minimum, maximum)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
    and value >= minimum and value <= maximum
end

local function scaledGpsValue(gps, key, format, unit, minimum, maximum)
  local value = gps[key]
  if not usableGps(value, minimum, maximum) then return "-" end
  return string.format(format, value / 10) .. unit
end

-- How long one read of the radio stands, in getTime() ticks of 10 ms. Nothing here has to be exact
-- to the second except a model timer, the only field that shows seconds.
local READ_TICKS, READ_TICKS_SECONDS = 500, 100

local function readValues(cache, items, wantsGpsDetails)
  local selected = cache.selectedItems == items and cache.selectedTypes or nil
  if selected == nil then
    selected = {}
    for i = 1, #(items or {}) do selected[items[i].type] = true end
    cache.selectedItems, cache.selectedTypes = items, selected
    cache.snapshotTicks = (selected.timer1 or selected.timer2 or selected.timer3) and READ_TICKS_SECONDS or READ_TICKS
  end
  local wantsGps = selected.tx_gps == true
  local dt = (selected.clock or selected.date) and safeCall(getDateTime) or nil
  local info = selected.model and model and safeCall(model.getInfo) or nil
  local gps = wantsGps and safeCall(getTxGPS) or nil
  local version = nil
  if selected.firmware and type(getVersion) == "function" then
    local ok, firmwareVersion = pcall(getVersion)
    if ok and type(firmwareVersion) == "string" and firmwareVersion ~= "" then version = firmwareVersion end
  end
  local now = selected.uptime and type(getTime) == "function" and getTime() or 0
  local values = {
    clock = selected.clock and (type(dt) == "table"
      and string.format("%02d:%02d", dt.hour or 0, dt.min or 0) or "-") or nil,
    date = (selected.clock or selected.date) and (type(dt) == "table"
      and string.format("%04d-%02d-%02d", dt.year or 0, dt.mon or 0, dt.day or 0) or "-") or nil,
    tx_battery = selected.tx_battery and battery(cache) or nil,
    model = selected.model and bounded(type(info) == "table" and info.name or nil, 15) or nil,
    timer1 = selected.timer1 and timerValue(1) or nil,
    timer2 = selected.timer2 and timerValue(2) or nil,
    timer3 = selected.timer3 and timerValue(3) or nil,
    uptime = selected.uptime and (now > 359999999 and ">999:59"
      or string.format("%d:%02d", math.floor(now / 360000), math.floor(now / 6000) % 60)) or nil,
    firmware = selected.firmware and bounded(version, 20) or nil,
    elrs = selected.elrs and M.elrsText(cache) or nil,
  }
  if wantsGps and type(gps) == "table" then
    if gps.fix == true or gps.fix == 1 then
      local fix = cache.text and cache.text("gps_fix", "Fix") or "Fix"
      values.tx_gps = type(gps.numsat) == "number"
        and string.format("%s | %s", fix, gps.numsat > 99 and "99+" or tostring(math.max(0, math.floor(gps.numsat)))) or fix
      if wantsGpsDetails then
        local gpsValues = {
          usableGps(gps.lat, -90, 90) and string.format("%.5f°", gps.lat) or "-",
          usableGps(gps.lon, -180, 180) and string.format("%.5f°", gps.lon) or "-",
          scaledGpsValue(gps, "heading", "%.1f", "°", 0, 3599),
          usableGps(gps.hdop, 0, 65535) and string.format("%.2f", gps.hdop / 100) or "-",
        }
        values._gpsLines = {}
        for i = 1, #GPS_WORST do
          local caption = cache.text and cache.text(GPS_WORST[i][1], GPS_WORST[i][2]) or GPS_WORST[i][2]
          values._gpsLines[i] = caption .. ": " .. gpsValues[i]
        end
      end
    elseif gps.fix == false or gps.fix == 0 then
      local noFix = cache.text and cache.text("gps_no_fix", "No fix") or "No fix"
      local sat = cache.text and cache.text("gps_satellites", "Sat") or "Sat"
      values.tx_gps = type(gps.numsat) == "number"
        and string.format("%s | %s %s", noFix, sat, gps.numsat > 99 and "99+"
          or tostring(math.max(0, math.floor(gps.numsat)))) or noFix
    else
      values.tx_gps = "-"
    end
  elseif wantsGps then
    values.tx_gps = "-"
  end
  return values
end

function M.setElrsSnapshot(cache, snapshot)
  local old = cache.elrs
  cache.elrs = snapshot
  if type(old) ~= "table" or type(snapshot) ~= "table" or old.status ~= snapshot.status or old.readAt ~= snapshot.readAt
      or old.identity ~= snapshot.identity or old.packetRate ~= snapshot.packetRate or old.telemetryRatio ~= snapshot.telemetryRatio
      or old.maxPower ~= snapshot.maxPower or old.dynamic ~= snapshot.dynamic then cache.snapshotAt = nil end
end

-- Reasons a finished read gives when no ELRS module answered: no CRSF module at all, a CRSF
-- module that is not ELRS, or no device information within the discovery pings.
local NO_MODULE = { no_crsf = true, not_elrs = true, no_answer = true }

function M.elrsText(cache)
  local snap, text = cache.elrs, cache.text
  -- A retry while no module answered is not news until it has an answer: the field keeps saying
  -- so rather than blinking to Reading every few seconds.
  if type(snap) == "table" and snap.status == "reading" and type(snap.previous) == "table"
      and NO_MODULE[snap.previous.reason] then
    snap = snap.previous
  end
  -- The same answer in the same language is the same text; a finished read is one table until
  -- the next read replaces it.
  if cache.elrsShown == snap and cache.elrsShownBy == text and cache.elrsCompact and cache.elrsShownValue then
    return cache.elrsShownValue
  end
  cache.elrsShown, cache.elrsShownBy = snap, text
  if type(snap) ~= "table" or snap.status == "unavailable" then
    local unavailable
    if type(snap) == "table" and NO_MODULE[snap.reason] then
      unavailable = text and text("elrs_no_module", "No ELRS module") or "No ELRS module"
    else
      unavailable = text and text("elrs_unavailable", "Unavailable") or "Unavailable"
    end
    cache.elrsCompact = { unavailable, "", "" }
    cache.elrsShownValue = unavailable
    return unavailable
  end
  if snap.status == "reading" then
    local reading = text and text("elrs_reading", "Reading") or "Reading"
    cache.elrsCompact = { reading, "", "" }
    cache.elrsShownValue = reading
    return reading
  end
  local lines = {}
  local fields = {
    { "elrs_packet_rate", "Packet Rate", snap.packetRate },
    { "elrs_telemetry_ratio", "Telemetry Ratio", snap.telemetryRatio },
    { "elrs_max_power", "Max Power", snap.maxPower },
    { "elrs_dynamic", "Dynamic", snap.dynamic },
  }
  for i = 1, #fields do
    local row = fields[i]
    local value = tostring(row[3] or "-")
    if row[1] == "elrs_max_power" and snap.fields and snap.fields.maxPower and snap.fields.maxPower.unit
        and snap.fields.maxPower.unit ~= "" then value = value .. " " .. tostring(snap.fields.maxPower.unit) end
    lines[#lines + 1] = (text and text(row[1], row[2]) or row[2]) .. ": " .. value
  end
  -- The rate without the sensitivity a module adds in brackets, and with a space before the unit.
  local rate = string.gsub(string.gsub(tostring(snap.packetRate or "-"), "%s*%b()", ""), "(%d)Hz", "%1 Hz")
  local ratio = tostring(snap.telemetryRatio or "-")
  local power = tostring(snap.maxPower or "-")
  if snap.fields and snap.fields.maxPower and snap.fields.maxPower.unit
      and snap.fields.maxPower.unit ~= "" then power = power .. " " .. tostring(snap.fields.maxPower.unit) end
  -- The module's Dynamic option in words: Off, Dyn, or an AUX channel that boosts to the maximum.
  local fixedWord = text and text("elrs_power_fixed", "fixed") or "fixed"
  local dynamicWord = text and text("elrs_power_dynamic", "dynamic") or "dynamic"
  local mode = nil
  if snap.dynamic == "Off" then mode = fixedWord
  elseif snap.dynamic == "Dyn" then mode = dynamicWord
  elseif snap.dynamic ~= nil then mode = dynamicWord .. " " .. tostring(snap.dynamic) end
  cache.elrsCompact = {
    (text and text("elrs_packet_rate", "Packet Rate") or "Packet Rate") .. " " .. rate,
    (text and text("elrs_telemetry_ratio", "Telemetry Ratio") or "Telemetry Ratio") .. " " .. ratio,
    (text and text("elrs_power", "Power") or "Power") .. " " .. power .. (mode and (", " .. mode) or ""),
  }
  cache.elrsShownValue = table.concat(lines, "\n")
  return cache.elrsShownValue
end

local function prepareElrsDisplay(cache, values, width)
  values._elrsDisplays = values._elrsDisplays or {}
  if values._elrsDisplays[width] ~= nil then return end
  -- A new read of the radio with the same text fits nothing again: measuring is the dear part.
  if cache.elrsFitted == nil or cache.elrsFittedFor ~= cache.elrsCompact then
    cache.elrsFitted, cache.elrsFittedFor = {}, cache.elrsCompact
  end
  local lines = cache.elrsFitted[width]
  if lines == nil then
    lines = {}
    for i = 1, #(cache.elrsCompact or {}) do lines[i] = fitLine(cache.elrsCompact[i], width, SMLSIZE) end
    cache.elrsFitted[width] = lines
  end
  values._elrsDisplays[width] = lines
end

-- The captions and worst-case texts a layout is fitted with, in the screen's language. The
-- snapshot fits with the same table as the screen, so both keep the same rows.
local function screenLabels(i18n, items)
  local labels, hasElrs, hasGps = {}, false, false
  for i = 1, #items do
    local id = items[i].type
    if labels[id] == nil then labels[id] = i18n(TYPE_KEYS[id], id) end
    if id == "elrs" then hasElrs = true end
    if id == "tx_gps" then hasGps = true end
  end
  if hasElrs then
    for i = 1, #ELRS_WORST do labels[ELRS_WORST[i][1]] = i18n(ELRS_WORST[i][1], ELRS_WORST[i][2]) end
    for i = 1, #ELRS_COMPACT_WORST do
      labels[ELRS_COMPACT_WORST[i][1]] = i18n(ELRS_COMPACT_WORST[i][1], ELRS_COMPACT_WORST[i][2])
    end
  end
  if hasGps then
    for i = 1, #GPS_WORST do labels[GPS_WORST[i][1]] = i18n(GPS_WORST[i][1], GPS_WORST[i][2]) end
    labels.gps_no_fix = i18n("gps_no_fix", "No fix")
    labels.gps_satellites = i18n("gps_satellites", "Sat")
  end
  return labels
end

function M.snapshot(items, cache, zone)
  cache = cache or {}
  local now = type(getTime) == "function" and getTime() or 0
  local zoneW = type(zone) == "table" and (zone.w or LCD_W) or cache.zoneW or LCD_W
  local zoneH = type(zone) == "table" and (zone.h or LCD_H) or cache.zoneH or LCD_H
  local hasGps, hasElrs = false, false
  for i = 1, #items do
    local itemType = items[i].type
    if itemType == "tx_gps" then hasGps = true end
    if itemType == "elrs" then hasElrs = true end
  end
  local wantsGpsDetails
  if cache.gpsDetailItems == items and cache.gpsDetailW == zoneW and cache.gpsDetailH == zoneH
      and cache.gpsDetailText == cache.text then
    wantsGpsDetails = cache.gpsDetailNeeded
  else
    wantsGpsDetails = hasGps and M.needsGpsDetails(items, zoneW, zoneH,
      cache.text and screenLabels(cache.text, items) or nil)
    cache.gpsDetailItems, cache.gpsDetailW, cache.gpsDetailH = items, zoneW, zoneH
    cache.gpsDetailText = cache.text
    cache.gpsDetailNeeded = wantsGpsDetails
  end
  if cache.snapshotValues and cache.snapshotAt and cache.selectedItems == items
      and now < cache.snapshotAt + (cache.snapshotTicks or READ_TICKS)
      and (not wantsGpsDetails or cache.snapshotGpsDetails) then
    return cache.snapshotValues
  end
  local values = readValues(cache, items, wantsGpsDetails)
  if hasElrs then
    values._elrsDisplays = {}
    for width in pairs(cache.elrsWidths or {}) do prepareElrsDisplay(cache, values, width) end
  end
  cache.valueOverflow = false
  cache.snapshotValues, cache.snapshotAt = values, now
  cache.snapshotGpsDetails = wantsGpsDetails
  return cache.snapshotValues
end

-- One line of what a snapshot read, in the order of M.TYPES, for the widget's trace line. Only
-- called when that line is wanted.
function M.valuesLine(values, cache)
  local parts = {}
  for i = 1, #M.TYPES do
    local kind = M.TYPES[i]
    local value = values[kind]
    if kind == "elrs" and value ~= nil and cache and type(cache.elrsCompact) == "table" then
      value = table.concat(cache.elrsCompact, ", ")
    end
    if value ~= nil then parts[#parts + 1] = kind .. " " .. tostring(value) end
  end
  return table.concat(parts, "; ")
end

function M.build(zone, statusLine, i18n, items, values, cache, info, scheme)
  local Schemes = loadSchemes()
  local colors = Schemes.colors(scheme)
  local warningColor, textColor, accentColor = colors.warning, colors.text, colors.accent
  cache = cache or {}
  cache.text = i18n
  local w, h = zone.w or LCD_W, zone.h or LCD_H
  local labels, fittedDetails = screenLabels(i18n, items), {}
  local function fittedDetail(value, width)
    local key = tostring(value) .. ":" .. tostring(width)
    local fitted = fittedDetails[key]
    if fitted == nil then fitted = fitLine(value, width, SMLSIZE); fittedDetails[key] = fitted end
    return fitted
  end
  cache.zoneW, cache.zoneH, cache.labels = w, h, labels
  local rows, fitNote = layout(items, w, h, labels, true)
  rows = rows or {}
  -- What the widget's log line reports once this tree stands: a saved row can be left out here
  -- without anything on the screen saying so. Counted again only where the layout says one was.
  cache.rowsShown, cache.rowsSaved = #rows, fitNote and #M.toRows(items) or #rows
  -- The answer M.snapshot would compute for these inputs, so its next pass need not fit them again.
  local detailedGps = false
  for r = 1, #rows do
    for i = 1, #rows[r].items do if rows[r].items[i].detailedGps then detailedGps = true end end
  end
  cache.gpsDetailItems, cache.gpsDetailW, cache.gpsDetailH = items, w, h
  cache.gpsDetailText, cache.gpsDetailNeeded = i18n, detailedGps
  cache.valueOverflow = false
  local compact, _, footerH, headerDividerY, short, micro = frameGeometry(h)
  local logoW = short and math.min(100, math.floor(w * 0.28))
    or compact and math.min(145, math.floor(w * 0.34)) or math.min(210, math.floor(w * 0.30))
  local logoH = math.floor(logoW * 84 / 400 + 0.5)
  local headerY = compact and 6 or 8
  local footerY = h - footerH
  local contentMargin = w < 360 and 6 or compact and 10 or 16
  local contentWidth = w - contentMargin * 2
  local infoX = contentMargin + 8
  local infoWidth = w - infoX - contentMargin
  local stripH, markerY, infoY, statusY, statusH = 23, 5, 3, 27, footerH - 32
  if short then stripH, markerY, infoY, statusY, statusH = 19, 3, 1, 22, footerH - 26 end
  local children
  if micro then
    children = {
      { type = "rectangle", x = 0, y = 0, w = w, h = h, color = colors.page, filled = true },
      { type = "rectangle", x = 0, y = footerY, w = w, h = footerH,
        color = colors.raised, filled = true },
      { type = "label", x = 4, y = footerY + 3, w = math.max(1, w - 8), h = footerH - 6,
        text = fitLine(info and info.text or statusLine or "", math.max(1, w - 8), SMLSIZE),
        color = textColor, font = SMLSIZE },
    }
  else
    children = {
    { type = "rectangle", x = 0, y = 0, w = w, h = h, color = colors.page, filled = true },
    { type = "image", x = contentMargin, y = headerY, w = logoW, h = logoH,
      file = Schemes.logo(scheme) },
    { type = "rectangle", x = contentMargin, y = headerDividerY, w = contentWidth, h = 1,
      color = accentColor, filled = true },
    { type = "rectangle", x = 0, y = footerY, w = w, h = stripH, color = colors.raised, filled = true },
    { type = "rectangle", x = contentMargin, y = footerY + markerY, w = 3, h = 13, filled = true,
      color = info and (info.level == "warning" or info.level == "error") and warningColor
        or accentColor },
    { type = "label", x = infoX, y = footerY + infoY, w = infoWidth, h = 18,
      text = fitLine(info and info.text or "", infoWidth, SMLSIZE),
      color = textColor, font = SMLSIZE },
    { type = "label", x = contentMargin, y = footerY + statusY, w = contentWidth,
      h = statusH, text = type(statusLine) == "function" and statusLine or tostring(statusLine or ""),
      color = colors.muted, font = SMLSIZE },
    }
    -- The compile pass's bar, on the line's row and clear of its words: see runtime.lua. It starts at
    -- the middle, or after the words where a narrow zone leaves them past it, and a zone with no room
    -- left keeps the words alone. Measured here and only here: a new kind of line rebuilds the scene
    -- (standbyInfoKind), and the restart request that follows the words hides the bar. A micro layout
    -- has no such row.
    local progress = info and info.progress
    local line = type(statusLine) == "function" and statusLine() or statusLine
    local barX = math.max(math.floor(w / 2), contentMargin + measure(line or "", SMLSIZE) + 6)
    local barW = w - barX - contentMargin
    if progress and barW >= 40 then
      local barH = math.min(10, statusH)
      local barY = footerY + statusY + math.floor((statusH - barH) / 2)
      local fillW = barW - 4
      children[#children + 1] = { type = "rectangle", x = barX, y = barY, w = barW, h = barH,
        color = colors.rule, filled = true,
        visible = function() return progress() ~= nil end }
      children[#children + 1] = { type = "rectangle", x = barX + 2, y = barY + 2, w = 1, h = barH - 4,
        color = accentColor, filled = true,
        visible = function() return progress() ~= nil end,
        size = function()
          return math.max(1, math.floor(fillW * math.min(1, progress() or 0) + 0.5)), barH - 4
        end }
    end
  end
  for r = 1, #rows do
    local row = rows[r]
    for i = 1, #row.items do
    local box = row.items[i]
    local item = box.item
    local x, y, boxW = box.x, row.y, box.w
    local label = labels[item.type]
    children[#children + 1] = { type = "rectangle", x = x, y = y, w = boxW, h = row.h,
      color = colors.card, filled = true, rounded = compact and 5 or 7 }
    children[#children + 1] = { type = "label", x = x + 8, y = y + 3, w = boxW - 16,
      h = box.detailHeight, text = label, color = colors.accentInk, font = SMLSIZE }
    if item.type == "elrs" then
      local lineWidth = boxW - 16
      cache.elrsWidths = cache.elrsWidths or {}
      cache.elrsWidths[lineWidth] = true
      if cache.elrsBuildWidths then cache.elrsBuildWidths[lineWidth] = true end
      local currentValues = cache.snapshotValues or values
      prepareElrsDisplay(cache, currentValues, lineWidth)
      local dataY = y + box.detailHeight + 6
      for field = 1, 3 do
        children[#children + 1] = { type = "label", x = x + 8,
          y = dataY + (field - 1) * box.detailHeight, w = lineWidth, h = box.detailHeight,
          text = function()
            local snap = cache.snapshotValues or values
            local display = snap._elrsDisplays and snap._elrsDisplays[lineWidth]
            return display and display[field] or "-"
          end,
          color = textColor, font = box.font }
      end
    else
      local valueX = box.detailedGps and x + math.floor(boxW / 2) or x + 8
      local valueY = box.detailedGps and y + 5 or item.type == "tx_battery" and y + row.h - 21 or y + box.valueY
      local valueW = box.detailedGps and math.floor(boxW / 2) - 8 or boxW - 16
      local shownFont, shown = box.font, SHORTENED[item.type] and { raw = false, text = "-" } or nil
      children[#children + 1] = { type = "label", x = valueX, y = valueY, w = valueW,
        text = shown and function()
          local raw = (cache.snapshotValues or values)[item.type]
          if raw ~= shown.raw then shown.raw, shown.text = raw, fitLine(tostring(raw or "-"), valueW, shownFont) end
          return shown.text
        end or function() local snap = cache.snapshotValues or values; return tostring(snap[item.type] or "-") end,
        align = box.detailedGps and RIGHT or item.type == "tx_battery" and CENTER or nil,
        color = item.type == "tx_battery"
          and function() return cache.batteryLow and warningColor or textColor end
          or textColor,
        font = box.font }
      local detail = ""
      if item.type == "tx_gps" and box.detailedGps then
        local fieldColumns = boxW >= 600 and 3 or 2
        local fieldGap = micro and 4 or compact and 6 or 10
        local fieldW = math.floor((boxW - 16 - fieldGap * (fieldColumns - 1)) / fieldColumns)
        local detailY = y + box.detailHeight + 12
        for field = 1, #GPS_WORST do
          local column = (field - 1) % fieldColumns
          local line = math.floor((field - 1) / fieldColumns)
          children[#children + 1] = { type = "label", x = x + 8 + column * (fieldW + fieldGap),
            y = detailY + line * box.detailHeight, w = fieldW, h = box.detailHeight,
            text = function()
              local snap = cache.snapshotValues or values
              return snap._gpsLines and snap._gpsLines[field] or ""
            end,
            color = textColor, font = SMLSIZE }
        end
      elseif item.type == "tx_battery" then
        -- The symbol is the reading; it fills what the caption and the figures leave, centred.
        local top, bottom = y + box.detailHeight + 5, y + row.h - 23
        local batteryH = math.max(12, math.min(compact and 28 or 34, bottom - top))
        local terminalW = math.max(3, math.floor(batteryH / 7))
        local batteryW = math.min(batteryH * 3, boxW - 16 - terminalW)
        local batteryX = x + math.floor((boxW - batteryW - terminalW) / 2)
        local batteryY = top + math.floor((bottom - top - batteryH) / 2)
        cache.batteryWidths = cache.batteryWidths or {}
        cache.batteryFills = cache.batteryFills or {}
        cache.batteryWidths[batteryW] = true
        cache.batteryFills[batteryW] = math.max(0,
          math.floor((batteryW - BATTERY_INSET * 2) * (cache.batteryPercent or 0) / 100))
        children[#children + 1] = { type = "rectangle", x = batteryX + batteryW,
          y = batteryY + math.floor(batteryH / 4), w = terminalW, h = batteryH - math.floor(batteryH / 4) * 2,
          color = textColor, filled = true }
        -- A rectangle, not an hline: a reactive size on a line repaints from the zone's origin to the
        -- line's end on every pass (lua_lvgl_widget.cpp, LvglWidgetLineBase::setSize compares nothing),
        -- where a rectangle's lv_obj_set_width returns when the value is the same.
        children[#children + 1] = { type = "rectangle", x = batteryX + BATTERY_INSET,
          y = batteryY + BATTERY_INSET, w = 1, h = batteryH - BATTERY_INSET * 2, filled = true,
          size = function()
            local fills = cache.batteryFills
            return fills and fills[batteryW] or 0, batteryH - BATTERY_INSET * 2
          end,
          color = function() return cache.batteryLow and warningColor or accentColor end }
        children[#children + 1] = { type = "rectangle", x = batteryX, y = batteryY,
          w = batteryW, h = batteryH, color = textColor, filled = false,
          rounded = 3, thickness = 2 }
      elseif item.type == "model" then detail = i18n("model_detail", "EdgeTX model")
      elseif item.type == "timer1" or item.type == "timer2" or item.type == "timer3" then
        detail = i18n(item.type .. "_detail", "EdgeTX model timer")
      elseif item.type == "uptime" then detail = i18n("uptime_detail", "Since radio power-on")
      elseif item.type == "firmware" then detail = i18n("firmware_detail", "Radio firmware")
      elseif item.type == "date" then detail = i18n("date_detail", "Radio date") end
      local detailW = boxW - 16
      if item.type ~= "tx_gps" and item.type ~= "tx_battery" then
        children[#children + 1] = { type = "label", x = x + 8, y = y + row.h - 21,
          w = detailW, h = box.detailHeight,
          text = item.type == "clock"
            and function() local snap = cache.snapshotValues or values; return tostring(snap.date or "-") end
            or fittedDetail(detail, detailW),
          color = colors.muted, font = SMLSIZE }
      end
    end
    end
  end
  return children
end

return M
