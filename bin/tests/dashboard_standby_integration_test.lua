local source = string.sub(debug.getinfo(1, "S").source, 2)
local root = string.match(source, "^(.*)[/\\]bin[/\\]tests[/\\]") or "."
local runtimePath = root .. "/src/rfsuite/widgets/dashboard/runtime.lua"
local standbyPath = root .. "/src/rfsuite/widgets/dashboard/standby.lua"
if arg then
  for i = 1, #arg - 1 do
    if arg[i] == "--runtime" then runtimePath = arg[i + 1] end
    if arg[i] == "--standby" then standbyPath = arg[i + 1] end
  end
end
local Stubs = assert(loadfile(root .. "/bin/accounting/stubs/edgetx.lua"))()
local FC = assert(loadfile(root .. "/bin/accounting/stubs/fc.lua"))()

local passed = 0
local function check(name, condition)
  if not condition then error("dashboard standby integration failed: " .. name, 0) end
  passed = passed + 1
end

local function install()
  Stubs.install(root)
  FC.install(Stubs)
  Stubs.reset()
  FC.reset()
end

-- Exercise the actual rows-first settings page. Draft removal, salvage, geometry-derived
-- controls, and writer rollback all pass through the production control callbacks.
install()
Stubs.installTool()
do
  local Page = assert(loadfile(root .. "/src/rfsuite/app/pages/settings/dashboard/standby/page.lua"))()
  local sessionW, sessionH = LCD_W, LCD_H
  LCD_W, LCD_H = 480, 320
  local writes, reports, rebuilds, saveSucceeds = 0, {}, 0, true
  local ctx = {
    preferences = { dashboard = {
      standby_enabled = false,
      standby_layout = "clock+tx_battery/elrs",
    } },
    i18n = {}, children = {}, x = 0, y = 0, w = 600,
    requestRebuild = function() rebuilds = rebuilds + 1 end,
    reportSave = function(report) reports[#reports + 1] = report end,
    savePreferences = function()
      writes = writes + 1
      return saveSucceeds, saveSucceeds and nil or "control"
    end,
  }
  local function build()
    ctx.children = {}
    Page.build(ctx)
    return ctx.children
  end
  local function press(label, occurrence)
    occurrence = occurrence or 1
    local seen = 0
    for i = 1, #ctx.children do
      local node = ctx.children[i]
      if node.type == "button" and node.text == label then
        seen = seen + 1
        if seen == occurrence then node.press(); return true end
      end
    end
    return false
  end
  local function hasLabel(value)
    for i = 1, #ctx.children do
      if ctx.children[i].type == "label" and ctx.children[i].text == value then return true end
    end
    return false
  end
  local function countControls(kind, title)
    local count = 0
    for i = 1, #ctx.children do
      local node = ctx.children[i]
      if node.type == kind and (title == nil or node.title == title) then count = count + 1 end
    end
    return count
  end

  Page.onReload(ctx)
  build()
  check("editor reconstructs two saved rows", hasLabel("Row 1") and hasLabel("Row 2"))
  check("editor exposes three filled fields", countControls("choice") == 3)
  check("editor has no size selectors", countControls("choice", "Size") == 0)
  check("editor has no move controls", not press("Move up") and not press("Move down"))
  check("two-row compact screen does not offer another row", not press("+ Row"))
  check("editor carries no placeholder notes",
    not hasLabel("Temporary no-module text: Unavailable.")
      and not hasLabel("Temporary default: Clock and TX battery above the ELRS row."))

  check("second row can add a fitting equal-share field", press("+ Field", 1))
  build()
  check("field addition creates no empty gap", countControls("choice") == 4)
  Page.onSave(ctx)
  check("valid rows-first edit saves while feature remains off", writes == 1
    and ctx.preferences.dashboard.standby_enabled == false
    and ctx.preferences.dashboard.standby_layout == "clock+tx_battery/elrs+clock")

  Page.onReload(ctx)
  build()
  check("field removal is available on the populated second row", press("Remove field", 4))
  build()
  Page.onSave(ctx)
  check("field removal compacts the row", writes == 2
    and ctx.preferences.dashboard.standby_layout == "clock+tx_battery/elrs")

  Page.onReload(ctx)
  build()
  check("first saved row can be removed", press("Remove row", 1))
  build()
  check("remaining row is renumbered without a stored gap", hasLabel("Row 1") and not hasLabel("Row 2"))
  check("last row can be removed", press("Remove row", 1))
  build()
  Page.onSave(ctx)
  check("disabled empty draft saves the off state", writes == 3
    and ctx.preferences.dashboard.standby_enabled == false)
  check("disabled empty draft preserves the prior layout",
    ctx.preferences.dashboard.standby_layout == "clock+tx_battery/elrs")
  for i = 1, #ctx.children do
    local node = ctx.children[i]
    if node.type == "toggle" then node.set(true); break end
  end
  Page.onSave(ctx)
  check("enabled empty draft refuses the writer", writes == 3)
  check("enabled empty draft reports the validation error", reports[#reports]
    and reports[#reports].title == "Layout not saved")

  ctx.preferences.dashboard.standby_enabled = false
  ctx.preferences.dashboard.standby_layout = "clock+tx_battery/elrs"
  Page.onReload(ctx)
  build()
  saveSucceeds = false
  for i = 1, #ctx.children do
    local node = ctx.children[i]
    if node.type == "toggle" then node.set(true); break end
  end
  Page.onSave(ctx)
  check("failed writer is called once", writes == 4)
  check("failed writer restores enabled and layout preferences",
    ctx.preferences.dashboard.standby_enabled == false
      and ctx.preferences.dashboard.standby_layout == "clock+tx_battery/elrs")

  saveSucceeds = true
  ctx.preferences.dashboard.standby_layout = "clock+unsupported+tx_battery//elrs"
  Page.onReload(ctx)
  build()
  check("salvaged saved tokens are visibly reported",
    hasLabel("Unsupported saved entries were skipped."))
  Page.onSave(ctx)
  check("salvaged valid tokens normalize on the next save", writes == 5
    and ctx.preferences.dashboard.standby_layout == "clock+tx_battery/elrs")

  local savedW, savedH, savedSizeText = LCD_W, LCD_H, lcd.sizeText
  LCD_W, LCD_H = 320, 480
  lcd.sizeText = function(value, font)
    return #tostring(value) * (font == MIDSIZE and 12 or font == DBLSIZE and 20 or 8),
      font == MIDSIZE and 24 or font == DBLSIZE and 38 or 18
  end
  ctx.preferences.dashboard.standby_layout = "clock+tx_battery/elrs"
  Page.onReload(ctx)
  build()
  local firstChoice = nil
  for i = 1, #ctx.children do
    if ctx.children[i].type == "choice" then firstChoice = ctx.children[i]; break end
  end
  local hasBattery, hasElrs = false, false
  for i = 1, #(firstChoice and firstChoice.values or {}) do
    hasBattery = hasBattery or firstChoice.values[i] == "TX battery"
    hasElrs = hasElrs or firstChoice.values[i] == "ELRS TX configuration"
  end
  check("portrait two-field catalogue keeps values that fit at the selected font", hasBattery)
  check("portrait two-field catalogue excludes ELRS whose worst case does not fit", not hasElrs)

  LCD_W, LCD_H = 800, 480
  lcd.sizeText = savedSizeText
  local storedLayout = ctx.preferences.dashboard.standby_layout
  ctx.preferences.dashboard.standby_layout = nil
  Page.onReload(ctx)
  build()
  check("large-screen default opens as clock, TX battery and model above the ELRS row",
    hasLabel("Row 1") and hasLabel("Row 2") and not hasLabel("Row 3") and countControls("choice") == 4
      and not hasLabel("Temporary default: Clock and TX battery above the ELRS row."))
  ctx.preferences.dashboard.standby_layout = storedLayout
  Page.onReload(ctx)
  build()
  check("large geometry offers a third row", press("+ Row"))
  build()
  Page.onSave(ctx)
  check("third row saves in row order", writes == 6
    and ctx.preferences.dashboard.standby_layout == "clock+tx_battery/elrs/clock")
  build()
  check("third-row callback removes that row rather than an earlier row", press("Remove row", 3))
  Page.onSave(ctx)
  check("row callback captures its own row number", writes == 7
    and ctx.preferences.dashboard.standby_layout == "clock+tx_battery/elrs")
  check("editor callbacks requested rebuilds", rebuilds >= 7)

  LCD_W, LCD_H, lcd.sizeText = savedW, savedH, savedSizeText
  Page.onClose()
  LCD_W, LCD_H = sessionW, sessionH
end

-- Timer detail captions use the same item-specific keys populated by the runtime. A generic
-- fallback would make every translated timer caption silently display English.
do
  local Standby = assert(loadfile(standbyPath))()
  local savedSizeText = lcd.sizeText
  lcd.sizeText = function(text, font)
    return #tostring(text) * (font == MIDSIZE and 9 or 6), font == MIDSIZE and 17 or 12
  end
  check("default layout fits native TX15 English font heights",
    Standby.validate(Standby.decode(nil, 480), 480, 320))
  lcd.sizeText = savedSizeText
  local cache = {}
  local labels = { timer1_detail = "Localized timer one" }
  local tree = Standby.build({ x = 0, y = 0, w = 800, h = 480 }, "waiting",
    function(key, fallback) return labels[key] or fallback end,
    Standby.decode("timer1"), { timer1 = "00:42" }, cache, { text = "info", level = "info" })
  local localized = false
  for i = 1, #tree do
    local node = tree[i]
    if node.type == "label" and node.text == "Localized timer one" then localized = true; break end
  end
  check("timer tile uses its item-specific localized detail key", localized)

  local compactItems = Standby.decode(nil, 480)
  local compactCache = {}
  local compactTree = Standby.build({ x = 0, y = 0, w = 480, h = 320 }, "waiting",
    function(_, fallback) return fallback end, compactItems, {}, compactCache,
    { text = "info", level = "info" })
  local Controls = assert(_G.rfsuite.require("widgets/dashboard/fullscreen_controls.lua"))
  Controls.appendTool(compactTree, { zone = { x = 0, y = 0, w = 480, h = 320 }, state = { armed = false } })
  local toolBottom, firstTileY
  for i = 1, #compactTree do
    local node = compactTree[i]
    if node.type == "button" and node.x == 459 and node.y == 1 and node.w == 20 and node.h == 20 then
      toolBottom = node.y + node.h
    elseif node.type == "rectangle" and node.rounded == 5 then
      firstTileY = firstTileY and math.min(firstTileY, node.y) or node.y
    end
  end
  check("compact Suite control stays above the first standby tile",
    toolBottom == 21 and firstTileY ~= nil and toolBottom < firstTileY)

  for _, size in ipairs({ { 240, 68 }, { 480, 45 } }) do
    local tinyTree = Standby.build({ x = 0, y = 0, w = size[1], h = size[2] }, "waiting",
      function(_, fallback) return fallback end,
      Standby.decode(nil), {}, {}, { text = "info", level = "info" })
    local bounded = #tinyTree == 3
    for i = 1, #tinyTree do
      local node = tinyTree[i]
      if type(node.x) == "number" and type(node.y) == "number" then
        bounded = bounded and node.x >= 0 and node.y >= 0
          and (type(node.w) ~= "number" or node.x + node.w <= size[1])
          and (type(node.h) ~= "number" or node.y + node.h <= size[2])
      end
    end
    check("minimum standard EdgeTX zone uses bounded prerequisite surface "
        .. size[1] .. "x" .. size[2], bounded)
  end
end

-- Use the actual dashboard runtime with the accounting radio/FC surface. The provider methods
-- are observed at their public boundary; no copy of the standby predicate lives in this test.
install()
do
  local Config = assert(_G.rfsuite.require("lib/elrs_config.lua"))
  local calls = { identity = 0, request = 0, step = 0, cancel = 0, requestOwners = {}, cancelOwners = {} }
  local original = {
    currentIdentity = Config.currentIdentity, request = Config.request,
    step = Config.step, cancel = Config.cancel,
  }
  Config.currentIdentity = function() calls.identity = calls.identity + 1; return "integration-model" end
  Config.request = function(_, context)
    calls.request = calls.request + 1
    calls.requestOwners[#calls.requestOwners + 1] = context and context.owner
    return true, "reading"
  end
  Config.step = function(context)
    calls.step = calls.step + 1
    return { status = "ready", identity = "integration-model", readAt = calls.step,
      packetRate = tostring(context and context.owner), telemetryRatio = "1:16",
      maxPower = "1000", dynamic = "Off", fields = {} }
  end
  Config.cancel = function(owner)
    calls.cancel = calls.cancel + 1
    calls.cancelOwners[#calls.cancelOwners + 1] = owner
  end
  -- A standby exit with the TX power alert off unloads the provider; a reload here hands the
  -- observed instance back, so the calls below stay counted. The unloading itself is checked in
  -- the lifetime block further down.
  local configPath = "/SCRIPTS/RFSUITE/core/lib/elrs_config.lua"
  local loadScriptBeforeSpy = loadScript
  _G.loadScript = function(path, mode)
    if path == configPath then return function() _G.rfsuite.elrs_config = Config; return Config end end
    return loadScriptBeforeSpy(path, mode)
  end

  local Runtime = assert(loadfile(runtimePath))()
  local MspRuntime = assert(_G.__rfsuite_msp_runtime_module
    or _G.rfsuite.require("tasks/msp/runtime.lua"))
  local originalMspState = MspRuntime.getState
  local originalMspProgress = MspRuntime.getProgressValues
  local forceRawConnected, forceUnsupported = false, false
  MspRuntime.getState = function()
    if forceUnsupported then
      return { lastConnected = true, versionReadCompleted = true, unsupportedApi = true, refusedApiVersion = "9.9" }
    end
    if forceRawConnected then return { lastConnected = true, versionReadCompleted = false } end
    return { lastConnected = false, versionReadCompleted = false }
  end
  local widget = Runtime.new({ x = 0, y = 0, w = 800, h = 480 }, {})
  widget.preferences.dashboard = widget.preferences.dashboard or {}
  widget.preferences.dashboard.standby_enabled = true
  widget.preferences.dashboard.standby_layout = "elrs"
  widget.preferences.audio_events = widget.preferences.audio_events or {}
  widget.preferences.audio_events.tpwr_alert = false
  widget.state.fblConnected = false
  widget.state.armed = false
  widget.state.hadInflightFlight = false
  widget.flightMode = "preflight"

  -- string.format here, not behind emitf's pcall, so a format that does not fit its arguments
  -- fails this test rather than printing the format string on the radio.
  local LogModule = assert(_G.rfsuite.require("lib/log.lua"))
  local realEmitf, standbyLines = LogModule.emitf, {}
  LogModule.emitf = function(tag, level, fmt, ...)
    if tag == "rfsuite.widget.standby" then
      standbyLines[#standbyLines + 1] = level .. ": " .. string.format(fmt, ...)
    end
    return realEmitf(tag, level, fmt, ...)
  end
  local function standbyLogged(wanted)
    for i = 1, #standbyLines do
      if string.find(standbyLines[i], wanted, 1, true) then return true end
    end
    return false
  end

  local treesBeforeEntry = #Stubs.lvgl.trees
  Stubs.tick()
  widget:refresh(0, nil)
  check("the info line's change is logged", standbyLogged("debug: info line: nil to controller_missing"))
  check("a rebuild logs the key it moved to", standbyLogged("debug: rebuild: "))
  check("missing controller selects the general prerequisite summary",
    widget.state.standbyInfoKind == "controller_missing")
  widget:refresh(0, nil)
  check("standby initialization job does not probe provider", calls.request == 0 and calls.step == 0)
  check("standby initializes without clearing the previous tree",
    #Stubs.lvgl.trees == treesBeforeEntry and widget._job ~= nil)
  widget:refresh(0, nil)
  check("standby prepares a large scene without clearing the previous tree",
    #Stubs.lvgl.trees == treesBeforeEntry and widget._job ~= nil and widget._job.children ~= nil)
  widget:refresh(0, nil)
  check("standby entry builds one scene", #Stubs.lvgl.trees == treesBeforeEntry + 1)
  check("a finished build logs its layout, rows, nodes, surface and zone",
    standbyLogged("info: built: layout elrs, 1 of 1 rows, " .. #Stubs.lvgl.trees[#Stubs.lvgl.trees]
      .. " nodes, full screen, zone 800x480, info controller_missing"))
  LogModule.emitf = realEmitf
  Stubs.tick()
  widget:refresh(0, nil)
  local afterState = calls.request
  check("eligible fullscreen drives standby provider", afterState > 0 and calls.step > 0)
  check("standby entry does not enqueue a nil-to-false overflow rebuild",
    #Stubs.lvgl.trees == treesBeforeEntry + 1 and widget._job == nil)
  local standbyTree = Stubs.lvgl.trees[#Stubs.lvgl.trees] or {}
  local schemeColors = _G.rfsuite.require("lib/color_schemes.lua").colors(nil)
  local suiteButton, suiteGlyphLines = nil, 0
  for i = 1, #standbyTree do
    local node = standbyTree[i]
    if node.type == "button" and node.x == 748 and node.y == 8 and node.w == 44 and node.h == 44 then
      suiteButton = node
    elseif node.type == "line" and node.color == schemeColors.text then
      suiteGlyphLines = suiteGlyphLines + 1
    end
  end
  check("standby uses the existing fullscreen Suite launch control",
    suiteButton and suiteButton.color == schemeColors.raised
      and type(suiteButton.press) == "function" and suiteGlyphLines == 6)

  -- A visible zone receives the same waiting surface at its own dimensions, without the
  -- fullscreen-only Suite control. Hidden/background and disabled widgets must not sample GPS.
  local savedGetTxGPS, gpsReads = getTxGPS, 0
  getTxGPS = function()
    gpsReads = gpsReads + 1
    return { fix = true, numsat = 8, lat = 48.12345, lon = 11.54321,
      alt = 6123, speed = 45, heading = 1274, hdop = 123 }
  end
  local deLocale = assert(loadfile(root .. "/src/rfsuite/i18n/de.lua"))()
  local enLocale = assert(loadfile(root .. "/src/rfsuite/i18n/en.lua"))()
  local function deText(key, fallback)
    local value = deLocale
    for part in string.gmatch(key, "[^.]+") do
      value = type(value) == "table" and value[part] or nil
      if value == nil then return fallback end
    end
    return value
  end
  local gpsText = deLocale.widgets.dashboard.standby
  local function firstGpsSnapshot(name, layout)
    local before = gpsReads
    local gpsWidget = Runtime.new({ x = 0, y = 0, w = 480, h = 320 }, {})
    gpsWidget.i18n = { t = deText }
    gpsWidget.preferences.dashboard = gpsWidget.preferences.dashboard or {}
    gpsWidget.preferences.dashboard.standby_enabled = true
    gpsWidget.preferences.dashboard.standby_layout = layout
    gpsWidget.preferences.audio_events = gpsWidget.preferences.audio_events or {}
    gpsWidget.preferences.audio_events.tpwr_alert = false
    gpsWidget.state.fblConnected, gpsWidget.state.armed = false, false
    gpsWidget.state.hadInflightFlight, gpsWidget.flightMode = false, "preflight"
    Stubs.tick(); gpsWidget:refresh(nil, nil)
    gpsWidget:refresh(nil, nil)
    local firstGps = gpsWidget._standbyCache and gpsWidget._standbyCache.snapshotValues
    check(name, gpsReads == before + 1 and firstGps
      and firstGps._gpsTime == gpsText.gps_time_unavailable
      and firstGps._gpsLines[1] == gpsText.gps_latitude .. ": 48.12345°"
      and firstGps._gpsLines[4] == gpsText.gps_hdop .. ": 1.23")
    gpsWidget:background()
  end
  firstGpsSnapshot("first large GPS snapshot is localized before its build pass", "tx_gps")
  firstGpsSnapshot("large then small duplicate keeps first-frame GPS detail localization",
    "tx_gps/tx_gps+clock")
  firstGpsSnapshot("small then large duplicate keeps first-frame GPS detail localization",
    "tx_gps+clock/tx_gps")
  local changingWidget = Runtime.new({ x = 0, y = 0, w = 800, h = 480 }, {})
  changingWidget.i18n = { t = deText }
  changingWidget.preferences.dashboard = changingWidget.preferences.dashboard or {}
  changingWidget.preferences.dashboard.standby_enabled = true
  changingWidget.preferences.dashboard.standby_layout = "clock"
  changingWidget.preferences.audio_events = changingWidget.preferences.audio_events or {}
  changingWidget.preferences.audio_events.tpwr_alert = false
  changingWidget.state.fblConnected, changingWidget.state.armed = false, false
  changingWidget.state.hadInflightFlight, changingWidget.flightMode = false, "preflight"
  for _ = 1, 4 do Stubs.tick(); changingWidget:refresh(nil, nil) end
  changingWidget.preferences.dashboard.standby_layout = "tx_gps"
  for _ = 1, 3 do Stubs.tick(); changingWidget:refresh(nil, nil) end
  local changedValues = changingWidget._standbyCache and changingWidget._standbyCache.snapshotValues
  local changedTree = Stubs.lvgl.trees[#Stubs.lvgl.trees] or {}
  local changedCaption = false
  for i = 1, #changedTree do
    if changedTree[i].type == "label" and changedTree[i].text == gpsText.module_tx_gps then
      changedCaption = true; break
    end
  end
  check("active layout change refreshes localized module and detail caches", changedCaption
    and changedValues and changedValues._gpsLines
    and changedValues._gpsLines[1] == gpsText.gps_latitude .. ": 48.12345°")
  changingWidget:background()
  local coldWidget = Runtime.new({ x = 0, y = 0, w = 300, h = 180 }, {})
  coldWidget.preferences.dashboard = coldWidget.preferences.dashboard or {}
  coldWidget.preferences.dashboard.standby_enabled = true
  coldWidget.preferences.dashboard.standby_layout = "tx_gps"
  coldWidget.preferences.audio_events = coldWidget.preferences.audio_events or {}
  coldWidget.preferences.audio_events.tpwr_alert = false
  coldWidget.state.fblConnected, coldWidget.state.armed = false, false
  coldWidget.state.hadInflightFlight, coldWidget.flightMode = false, "preflight"
  Stubs.tick(); coldWidget:refresh(nil, nil)
  coldWidget.preferences.dashboard.standby_enabled = false
  coldWidget:refresh(nil, nil)
  check("disabling standby before cold initialization skips module acquisition",
    coldWidget._job == nil and coldWidget._standbyModule == nil)
  coldWidget.preferences.dashboard.standby_enabled = true
  coldWidget:refresh(nil, nil)
  coldWidget:refresh(nil, nil)
  check("cold standby snapshot remains a separate cooperative phase",
    coldWidget._job ~= nil and coldWidget._job.children == nil
      and coldWidget._standbyCache.snapshotValues ~= nil)
  coldWidget.zone = { x = 0, y = 0, w = 800, h = 480 }
  coldWidget.i18n = { t = deText }
  coldWidget:refresh(nil, nil)
  local coldValues = coldWidget._standbyCache.snapshotValues
  check("cold snapshot restarts for changed zone and locale before building",
    coldWidget._job ~= nil and coldWidget._job.children == nil and coldValues._gpsLines
      and coldValues._gpsLines[1] == gpsText.gps_latitude .. ": 48.12345°")
  coldWidget:refresh(nil, nil)
  coldWidget:refresh(nil, nil)
  local coldTree, coldCaption = Stubs.lvgl.trees[#Stubs.lvgl.trees] or {}, false
  for i = 1, #coldTree do
    if coldTree[i].type == "label" and coldTree[i].text == gpsText.module_tx_gps then
      coldCaption = true; break
    end
  end
  check("cold standby swaps only the rebuilt localized geometry", coldCaption)
  coldWidget:background()
  local leaseWidget = Runtime.new({ x = 0, y = 0, w = 800, h = 480 }, {})
  leaseWidget.preferences.dashboard = leaseWidget.preferences.dashboard or {}
  leaseWidget.preferences.dashboard.standby_enabled = true
  leaseWidget.preferences.dashboard.standby_layout = "elrs"
  leaseWidget.preferences.audio_events = leaseWidget.preferences.audio_events or {}
  leaseWidget.preferences.audio_events.tpwr_alert = false
  leaseWidget.state.fblConnected, leaseWidget.state.armed = false, false
  leaseWidget.state.hadInflightFlight, leaseWidget.flightMode = false, "preflight"
  for _ = 1, 5 do Stubs.tick(); leaseWidget:refresh(nil, nil) end
  local cancelBeforeLayout, requestBeforeLayout, stepBeforeLayout = calls.cancel, calls.request, calls.step
  leaseWidget.preferences.dashboard.standby_layout = "clock"
  Stubs.tick(); leaseWidget:refresh(nil, nil)
  local requestAfterCancel, stepAfterCancel = calls.request, calls.step
  for _ = 1, 4 do Stubs.tick(); leaseWidget:refresh(nil, nil) end
  check("removing ELRS cancels its lease once and stops provider work",
    calls.cancel == cancelBeforeLayout + 1
      and requestAfterCancel == requestBeforeLayout and stepAfterCancel == stepBeforeLayout
      and calls.request == requestAfterCancel and calls.step == stepAfterCancel)
  leaseWidget:background()
  local gpsReadsBeforeZone = gpsReads
  local zoneWidget = Runtime.new({ x = 4, y = 6, w = 300, h = 180 }, {})
  zoneWidget.preferences.dashboard = zoneWidget.preferences.dashboard or {}
  zoneWidget.preferences.dashboard.standby_enabled = true
  zoneWidget.preferences.dashboard.standby_layout = "clock"
  zoneWidget.preferences.audio_events = zoneWidget.preferences.audio_events or {}
  zoneWidget.preferences.audio_events.tpwr_alert = false
  zoneWidget.state.fblConnected, zoneWidget.state.armed = false, false
  zoneWidget.state.hadInflightFlight, zoneWidget.flightMode = false, "preflight"
  local zoneTreesBefore, previousTree, requestsBeforeZone = #Stubs.lvgl.trees, Stubs.lvgl.trees[1], calls.request
  Stubs.tick(); zoneWidget:refresh(nil, nil)
  zoneWidget:refresh(nil, nil)
  check("normal-zone scene initialization stays cooperative", zoneWidget._job ~= nil
    and #Stubs.lvgl.trees == zoneTreesBefore)
  zoneWidget:refresh(nil, nil)
  check("normal-zone scene prepare stays cooperative", zoneWidget._job ~= nil
    and zoneWidget._job.children ~= nil and #Stubs.lvgl.trees == zoneTreesBefore)
  zoneWidget:refresh(nil, nil)
  local zoneTree = Stubs.lvgl.trees[#Stubs.lvgl.trees] or {}
  local zoneHasTool, zoneContained, zoneNode, zoneOverflow = false, true, false, nil
  for i = 1, #zoneTree do
    local node = zoneTree[i]
    if node.type == "button" and type(node.press) == "function" then zoneHasTool = true; break end
    if type(node.x) == "number" and type(node.y) == "number" then
      zoneNode = true
      if node.x < 0 or node.y < 0
          or (type(node.w) == "number" and node.x + node.w > 300)
          or (type(node.h) == "number" and node.y + node.h > 180) then
        zoneContained = false
        zoneOverflow = tostring(node.type) .. "@" .. tostring(node.x) .. "," .. tostring(node.y)
          .. "+" .. tostring(node.w) .. "x" .. tostring(node.h)
      end
    end
  end
  check("normal widget builds standby at the actual zone without Suite control trees="
      .. tostring(zoneTreesBefore) .. "->" .. tostring(#Stubs.lvgl.trees)
      .. " kind=" .. tostring(zoneWidget._treeKind)
      .. " fs=" .. tostring(zoneWidget._standbyFullscreen)
      .. " tool=" .. tostring(zoneHasTool)
      .. " changed=" .. tostring(zoneTree ~= previousTree)
      .. " node=" .. tostring(zoneNode) .. " contained=" .. tostring(zoneContained)
      .. " overflow=" .. tostring(zoneOverflow),
    #Stubs.lvgl.trees == zoneTreesBefore + 1 and zoneTree ~= previousTree
      and zoneNode and zoneContained and zoneWidget._treeKind == "standby"
      and zoneWidget._standbyFullscreen == false and not zoneHasTool)
  check("normal non-ELRS standby does not touch the shared ELRS reader",
    calls.request == requestsBeforeZone)
  check("unselected GPS is not sampled in normal standby", gpsReads == gpsReadsBeforeZone)
  zoneWidget.zone = { x = 0, y = 0, w = 480, h = 320 }
  Stubs.tick(); zoneWidget:refresh(0, nil)
  zoneWidget:refresh(0, nil)
  check("fullscreen transition prepares before swapping", zoneWidget._job ~= nil)
  zoneWidget:refresh(0, nil)
  local fullscreenTree = Stubs.lvgl.trees[1] or {}
  local fullscreenHasTool = false
  for i = 1, #fullscreenTree do
    if fullscreenTree[i].type == "button" and type(fullscreenTree[i].press) == "function" then
      fullscreenHasTool = true; break
    end
  end
  check("normal-to-fullscreen transition rebuilds with Suite control",
    zoneWidget._treeKind == "standby" and zoneWidget._standbyFullscreen == true and fullscreenHasTool)
  zoneWidget.zone = { x = 4, y = 6, w = 300, h = 180 }
  Stubs.tick(); zoneWidget:refresh(nil, nil)
  zoneWidget:refresh(nil, nil)
  check("zone transition prepares before swapping", zoneWidget._job ~= nil)
  zoneWidget:refresh(nil, nil)
  local returnedZoneTree = Stubs.lvgl.trees[1] or {}
  local returnedZoneHasTool = false
  for i = 1, #returnedZoneTree do
    if returnedZoneTree[i].type == "button" and type(returnedZoneTree[i].press) == "function" then
      returnedZoneHasTool = true; break
    end
  end
  check("fullscreen-to-normal transition rebuilds without Suite control",
    zoneWidget._treeKind == "standby" and zoneWidget._standbyFullscreen == false
      and not returnedZoneHasTool)
  zoneWidget:background()
  check("background releases normal standby display state",
    zoneWidget._standbyModule == nil and zoneWidget._standbyCache == nil
      and zoneWidget._standbyFullscreen == nil)
  zoneWidget.preferences.dashboard.standby_enabled = false
  Stubs.tick(); zoneWidget:refresh(nil, nil)
  check("disabled normal widget does not sample GPS", gpsReads == gpsReadsBeforeZone)

  local staleWidget = Runtime.new({ x = 0, y = 0, w = 300, h = 180 }, {})
  staleWidget.preferences.dashboard = staleWidget.preferences.dashboard or {}
  staleWidget.preferences.dashboard.standby_enabled = true
  staleWidget.preferences.dashboard.standby_layout = "clock"
  staleWidget.preferences.audio_events = staleWidget.preferences.audio_events or {}
  staleWidget.preferences.audio_events.tpwr_alert = false
  staleWidget.state.fblConnected, staleWidget.state.armed = false, false
  staleWidget.state.hadInflightFlight, staleWidget.flightMode = false, "preflight"
  for _ = 1, 4 do Stubs.tick(); staleWidget:refresh(nil, nil) end
  local treesBeforeStale = #Stubs.lvgl.trees
  staleWidget.zone = { x = 0, y = 0, w = 480, h = 320 }
  Stubs.tick(); staleWidget:refresh(nil, nil)
  staleWidget:refresh(nil, nil)
  check("standby zone change reaches prepared phase", staleWidget._job ~= nil
    and staleWidget._job.children ~= nil)
  staleWidget.zone = { x = 0, y = 0, w = 800, h = 480 }
  staleWidget.preferences.dashboard.standby_layout = "tx_battery"
  staleWidget.i18n = { t = deText }
  staleWidget:refresh(nil, nil)
  check("changed zone layout and locale discard a prepared standby tree",
    #Stubs.lvgl.trees == treesBeforeStale and staleWidget._job == nil
      and staleWidget.built == false)
  Stubs.tick(); staleWidget:refresh(nil, nil)
  staleWidget:refresh(nil, nil)
  staleWidget.preferences.dashboard.standby_enabled = false
  staleWidget:refresh(nil, nil)
  check("disabling standby between prepare and swap keeps the visible tree",
    #Stubs.lvgl.trees == treesBeforeStale and staleWidget._job == nil
      and staleWidget.built == false)
  staleWidget.preferences.dashboard.standby_enabled = true
  for _ = 1, 3 do Stubs.tick(); staleWidget:refresh(nil, nil) end
  local freshTree, freshCaption = Stubs.lvgl.trees[#Stubs.lvgl.trees] or {}, false
  for i = 1, #freshTree do
    if freshTree[i].type == "label" and freshTree[i].text == gpsText.module_tx_battery then
      freshCaption = true; break
    end
  end
  check("fresh standby inputs build after stale prepares are discarded", freshCaption)
  staleWidget.zone = { x = 0, y = 0, w = 640, h = 360 }
  Stubs.tick(); staleWidget:refresh(nil, nil)
  staleWidget:refresh(nil, nil)
  check("prepared standby keeps ownership of the visible tree",
    staleWidget._job ~= nil and staleWidget._job.children ~= nil
      and staleWidget._treeKind == "standby" and #Stubs.lvgl.trees == 1)
  staleWidget:background()
  check("background between standby prepare and swap clears the owned tree",
    staleWidget._job == nil and staleWidget._standbyModule == nil
      and staleWidget._standbyCache == nil and #Stubs.lvgl.trees == 0)

  -- The firmware keeps evaluating the visible tree's getters until the replacement is swapped in,
  -- and a layout change prepares that replacement over several passes. Every getter of the old
  -- tree must keep answering in that window, whatever the new layout drops from the cache.
  local retainedCases = {
    { w = 480, h = 320, layout = "tx_battery+clock/elrs/tx_gps" },
    { w = 800, h = 480, layout = "tx_battery+clock+model/elrs+timer1/tx_gps" },
  }
  for c = 1, #retainedCases do
    local case = retainedCases[c]
    local name = case.w .. "x" .. case.h
    local retainedWidget = Runtime.new({ x = 0, y = 0, w = case.w, h = case.h }, {})
    retainedWidget.preferences.dashboard = retainedWidget.preferences.dashboard or {}
    retainedWidget.preferences.dashboard.standby_enabled = true
    retainedWidget.preferences.dashboard.standby_layout = case.layout
    retainedWidget.preferences.audio_events = retainedWidget.preferences.audio_events or {}
    retainedWidget.preferences.audio_events.tpwr_alert = false
    retainedWidget.state.fblConnected, retainedWidget.state.armed = false, false
    retainedWidget.state.hadInflightFlight, retainedWidget.flightMode = false, "preflight"
    for _ = 1, 5 do Stubs.tick(); retainedWidget:refresh(nil, nil) end
    local retainedTree = Stubs.lvgl.trees[#Stubs.lvgl.trees]
    local retainedRefs = {}
    for i = 1, #Stubs.lvgl.refs do retainedRefs[i] = Stubs.lvgl.refs[i] end
    local batteryGetter = false
    for i = 1, #(retainedTree or {}) do
      if retainedTree[i].type == "hline" and type(retainedTree[i].size) == "function" then batteryGetter = true end
    end
    check(name .. " retained-tree fixture builds the battery tile with its getters",
      retainedWidget._treeKind == "standby" and batteryGetter and #retainedRefs > 0)
    local function resolveRetained()
      for i = 1, #retainedRefs do
        local ok, a = pcall(retainedRefs[i])
        if not ok then return false, tostring(a) end
        if a == nil then return false, "getter " .. i .. " returned nil" end
      end
      return true
    end
    check(name .. " retained getters resolve before the layout change", resolveRetained())
    retainedWidget.preferences.dashboard.standby_layout = "clock"
    local passesWithOldTree, retainedFailure = 0, nil
    for _ = 1, 8 do
      Stubs.tick(); retainedWidget:refresh(nil, nil)
      if Stubs.lvgl.trees[1] ~= retainedTree then break end
      passesWithOldTree = passesWithOldTree + 1
      local ok, err = resolveRetained()
      if not ok and retainedFailure == nil then retainedFailure = "pass " .. passesWithOldTree .. ": " .. err end
    end
    check(name .. " old standby getters resolve while a new layout prepares: " .. tostring(retainedFailure),
      retainedFailure == nil)
    check(name .. " layout change keeps the old tree standing while it prepares", passesWithOldTree >= 2
      and Stubs.lvgl.trees[1] ~= retainedTree)
    print(string.format("retained tree %s: %d getters resolved on each of %d passes", name, #retainedRefs,
      passesWithOldTree))
    retainedWidget:background()
  end

  -- Nothing saved: the default follows the zone, so a widget zone on a wide radio still shows its
  -- first row, and the full screen of a wide radio gets the three-field first row.
  for _, case in ipairs({ { 480, 320, 3 }, { 800, 480, 4 } }) do
    local defaultWidget = Runtime.new({ x = 0, y = 0, w = case[1], h = case[2] }, {})
    defaultWidget.preferences.dashboard = defaultWidget.preferences.dashboard or {}
    defaultWidget.preferences.dashboard.standby_enabled = true
    defaultWidget.preferences.dashboard.standby_layout = nil
    defaultWidget.preferences.audio_events = defaultWidget.preferences.audio_events or {}
    defaultWidget.preferences.audio_events.tpwr_alert = false
    defaultWidget.state.fblConnected, defaultWidget.state.armed = false, false
    defaultWidget.state.hadInflightFlight, defaultWidget.flightMode = false, "preflight"
    for _ = 1, 5 do Stubs.tick(); defaultWidget:refresh(nil, nil) end
    local tree, tiles = Stubs.lvgl.trees[#Stubs.lvgl.trees] or {}, 0
    for i = 1, #tree do
      if tree[i].type == "rectangle" and (tree[i].rounded == 5 or tree[i].rounded == 7) then tiles = tiles + 1 end
    end
    check(string.format("unsaved default shows %d tiles in a %dx%d zone (LCD_W %d)", case[3], case[1], case[2],
      LCD_W or 0), defaultWidget._treeKind == "standby" and tiles == case[3])
    defaultWidget:background()
  end

  local widthWidget = Runtime.new({ x = 0, y = 0, w = 320, h = 320 }, {})
  widthWidget.preferences.dashboard = widthWidget.preferences.dashboard or {}
  widthWidget.preferences.dashboard.standby_enabled = true
  widthWidget.preferences.dashboard.standby_layout = "elrs"
  widthWidget.preferences.audio_events = widthWidget.preferences.audio_events or {}
  widthWidget.preferences.audio_events.tpwr_alert = false
  widthWidget.state.fblConnected, widthWidget.state.armed = false, false
  widthWidget.state.hadInflightFlight, widthWidget.flightMode = false, "preflight"
  local function widthCount()
    local count = 0
    for _ in pairs(widthWidget._standbyCache and widthWidget._standbyCache.elrsWidths or {}) do
      count = count + 1
    end
    return count
  end
  for _, width in ipairs({ 320, 360, 400, 440, 480, 520 }) do
    widthWidget.zone = { x = 0, y = 0, w = width, h = 320 }
    for _ = 1, width == 320 and 4 or 3 do Stubs.tick(); widthWidget:refresh(nil, nil) end
    check("successful ELRS swap retains only its active width " .. tostring(width), widthCount() == 1)
  end
  widthWidget.zone = { x = 0, y = 0, w = 560, h = 320 }
  Stubs.tick(); widthWidget:refresh(nil, nil)
  widthWidget:refresh(nil, nil)
  widthWidget.zone = { x = 0, y = 0, w = 600, h = 320 }
  widthWidget:refresh(nil, nil)
  check("cancelled ELRS prepare restores the active width set", widthCount() == 1)
  for _ = 1, 3 do Stubs.tick(); widthWidget:refresh(nil, nil) end
  check("later ELRS swap still keeps the width set bounded", widthCount() == 1)
  widthWidget:background()
  getTxGPS = savedGetTxGPS

  check("active standby has cached localized texts before global reload",
    type(widget._standbyTexts) == "table"
      and type(widget.renderKey) == "string" and string.sub(widget.renderKey, 1, 8) == "standby|")
  local rawElrsBeforeReload = widget._standbyCache.elrs
  widget._standbyCache.snapshotValues = { elrs = "OLD", _elrsDisplays = { [100] = { "OLD", "OLD", "OLD" } } }
  widget._standbyCache.snapshotAt = getTime()
  widget._standbyCache.elrsCompact = { "OLD", "OLD", "OLD" }
  widget:reload(true)
  check("global reload invalidates standby texts and visible render key",
    widget._standbyTexts == nil and widget.renderKey == nil
      and widget._standbyCache.snapshotValues == nil and widget._standbyCache.snapshotAt == nil
      and widget._standbyCache.elrsCompact == nil and widget._standbyCache.elrs == rawElrsBeforeReload)
  widget.preferences.dashboard = widget.preferences.dashboard or {}
  widget.preferences.dashboard.standby_enabled = true
  widget.preferences.dashboard.standby_layout = "elrs"
  widget._job = nil
  widget:refresh(0, nil)
  widget:refresh(0, nil)
  widget:refresh(0, nil)
  local reloadedTree, localizedReactive = Stubs.lvgl.trees[#Stubs.lvgl.trees] or {}, false
  local expectedRate = enLocale.widgets.dashboard.standby.elrs_rate_short .. " "
  for i = 1, #reloadedTree do
    local node = reloadedTree[i]
    if type(node.text) == "function" then
      local ok, value = pcall(node.text)
      if ok and type(value) == "string" and string.find(value, expectedRate, 1, true) == 1 then
        localizedReactive = string.find(value, "OLD", 1, true) == nil
        break
      end
    end
  end
  check("active locale reload rebuilds reactive ELRS text before the snapshot cadence",
    localizedReactive)

  widget._standbyElrsIdentityAt = getTime()
  local identityBefore = calls.identity
  widget._job = nil
  Stubs.tick()
  widget:refresh(0, nil)
  check("identity is cached below one second", calls.identity == identityBefore)
  for _ = 1, 30 do Stubs.tick() end
  widget._job = nil
  widget:refresh(0, nil)
  check("identity refreshes on its bounded cadence", calls.identity > identityBefore)
  check("ELRS snapshot reaches standby cache", widget._standbyCache
    and widget._standbyCache.elrs and widget._standbyCache.elrs.packetRate ~= nil)

  widget._job = nil
  widget._standbyElrsActive = true
  widget.state.fblConnected, widget.state.armed, widget.state.hadInflightFlight = false, false, false
  widget.flightMode = "preflight"
  widget._standbyCache.elrs = { status = "reading", identity = "integration-model" }
  forceRawConnected = true
  MspRuntime.getProgressValues = function() return 0, 1 end
  local beforeRawRequest, beforeRawStep = calls.request, calls.step
  Stubs.tick()
  widget:refresh(0, nil)
  check("raw MSP link yields probing but keeps standby render and refreshes cancelled status",
    calls.request == beforeRawRequest and calls.step == beforeRawStep
      and widget._standbyElrsActive ~= true and widget._standbyCache.elrs.status ~= "reading"
      and ((widget._job and widget._job.kind == "standby")
        or (type(widget.renderKey) == "string" and string.sub(widget.renderKey, 1, 8) == "standby|")))
  widget._job = nil
  Stubs.tick()
  widget:refresh(0, nil)
  check("raw MSP startup takes priority over missing-controller summary: "
      .. tostring(widget.state.standbyInfoKind),
    widget.state.standbyInfoKind == "suite_loading")
  check("summary transition invalidates cached localized prerequisite",
    widget._standbyTexts == nil)
  MspRuntime.getProgressValues = originalMspProgress
  forceRawConnected = false

  forceUnsupported = true
  widget._job = nil
  Stubs.tick()
  widget:refresh(0, nil)
  check("unsupported API has the highest compatibility summary priority",
    widget.state.standbyInfoKind == "api_unsupported")
  forceUnsupported = false

  local function excluded(name, setup)
    widget._job = nil
    widget._standbyElrsActive = false
    setup()
    local before = calls.request
    Stubs.tick()
    widget:refresh(0, nil)
    check(name, calls.request == before and widget._standbyElrsActive ~= true
      and not (widget._job and widget._job.kind == "standby")
      and not (type(widget.renderKey) == "string" and string.sub(widget.renderKey, 1, 8) == "standby|"))
  end
  excluded("armed state excludes standby", function() widget.state.armed = true end)
  excluded("prior flight excludes standby", function()
    widget.state.armed = false; widget.state.hadInflightFlight = true; widget.flightMode = "preflight"
  end)
  excluded("postflight excludes standby", function()
    widget.state.hadInflightFlight = true; widget.state.rfConnected = true; widget.flightMode = "postflight"
  end)
  excluded("offline excludes standby", function()
    widget.state.hadInflightFlight = true; widget.state.rfConnected = false; widget.flightMode = "offline"
  end)

  widget.state.armed, widget.state.hadInflightFlight, widget.flightMode = false, false, "preflight"
  widget._job = nil
  widget:refresh(0, nil)
  for _ = 1, 4 do widget:refresh(0, nil) end
  check("standby re-entry starts a fresh request", widget._standbyElrsActive == true)
  widget._toolHost = { phase = "run", home = { run = function() return 0 end }, cpuHits = 0 }
  local beforeCancel = calls.cancel
  widget:refresh(0, nil)
  check("hosted tool releases standby owner", calls.cancel > beforeCancel and widget._standbyElrsActive ~= true)

  widget._toolHost = nil
  widget._job = nil
  widget:refresh(0, nil)
  for _ = 1, 4 do widget:refresh(0, nil) end
  check("standby enters after hosted tool closes", widget._standbyElrsActive == true)
  local firstCache = widget._standbyCache
  beforeCancel = calls.cancel
  widget:background()
  check("background transition releases standby owner", calls.cancel > beforeCancel
    and widget._standbyElrsActive ~= true)

  local firstOwner = calls.requestOwners[1]
  local second = Runtime.new({ x = 0, y = 0, w = 800, h = 480 }, {})
  second.preferences.dashboard = second.preferences.dashboard or {}
  second.preferences.dashboard.standby_enabled = true
  second.preferences.dashboard.standby_layout = "elrs"
  second.state.fblConnected, second.state.armed = false, false
  second.state.hadInflightFlight, second.flightMode = false, "preflight"
  second:refresh(0, nil)
  for _ = 1, 4 do second:refresh(0, nil) end
  local secondOwner = calls.requestOwners[#calls.requestOwners]
  check("separate widgets use separate standby owners", firstOwner ~= nil and secondOwner ~= nil
    and type(firstOwner) == "string" and type(secondOwner) == "string" and firstOwner ~= secondOwner)
  check("separate widgets keep separate standby caches", widget._standbyCache == nil
    and second._standbyCache ~= firstCache
    and second._standbyCache.elrs.packetRate ~= firstCache.elrs.packetRate)

  second:background()

  -- Once the normal dashboard is already up, a standby-only prerequisite change must not enqueue
  -- another scene build. Cover both the default-off case and an enabled feature excluded by flight
  -- history; the active-standby transition above separately proves its text cache is invalidated.
  local originalIsFblConnected = MspRuntime.isFblConnected
  local EventsRuntime = assert(_G.rfsuite.require("tasks/events/runtime.lua"))
  local originalEventActive = EventsRuntime.isOnconnectActive
  local originalEventProgress = EventsRuntime.getOnconnectProgress
  local originalEventPending = EventsRuntime.getOnconnectPendingTaskName
  local savedResolved = _G.rfsuite.session and _G.rfsuite.session.modelPreferencesResolved
  MspRuntime.getState = function()
    return { lastConnected = true, versionReadCompleted = true, unsupportedApi = false,
      values = { apiVersion = "12.0" } }
  end
  MspRuntime.getProgressValues = function() return 1, 1 end
  MspRuntime.isFblConnected = function() return true end
  EventsRuntime.isOnconnectActive = function() return false end
  EventsRuntime.getOnconnectProgress = function() return { done = 1, total = 1 } end
  EventsRuntime.getOnconnectPendingTaskName = function() return nil end
  if _G.rfsuite.session then _G.rfsuite.session.modelPreferencesResolved = true end
  local function readyWidget(enabled, flown)
    local readyWidget = Runtime.new({ x = 0, y = 0, w = 800, h = 480 }, {})
    readyWidget.preferences.dashboard = readyWidget.preferences.dashboard or {}
    readyWidget.preferences.dashboard.standby_enabled = enabled
    readyWidget.preferences.audio_events = readyWidget.preferences.audio_events or {}
    readyWidget.preferences.audio_events.tpwr_alert = false
    readyWidget.state.batteryTelemetrySeen = true
    readyWidget.state.rfTelemetrySeen = true
    readyWidget.pendingSince = -1000
    for _ = 1, 8 do Stubs.tick(); readyWidget:refresh(0, nil) end
    if flown then
      readyWidget.state.hadInflightFlight = true
      for _ = 1, 3 do Stubs.tick(); readyWidget:refresh(0, nil) end
    end
    return readyWidget
  end
  local function infoChangeDoesNotBuild(name, readyWidget)
    for _ = 1, 3 do readyWidget:refresh(0, nil) end
    local treesBefore = #Stubs.lvgl.trees
    local keyBefore, builtBefore = readyWidget.renderKey, readyWidget.built
    local textsBefore = { marker = name }
    readyWidget._standbyTexts = textsBefore
    readyWidget.state.standbyInfoKind = "stale-standby-only-value"
    readyWidget._lastWorkTick = nil
    readyWidget._lastLogicTick = -1000
    Stubs.tick()
    readyWidget:refresh(0, nil)
    local statePassStable = readyWidget.renderKey == keyBefore and readyWidget.built == builtBefore
      and readyWidget._job == nil
    readyWidget:refresh(0, nil)
    check(name .. " module=" .. tostring(readyWidget._standbyModule)
      .. " trees=" .. tostring(treesBefore) .. "->" .. tostring(#Stubs.lvgl.trees)
      .. " ready=" .. tostring(readyWidget.connectionReady)
      .. " info=" .. tostring(readyWidget.state.standbyInfoKind)
      .. " status=" .. tostring(readyWidget.statusLine),
      readyWidget.connectionReady == true and builtBefore == true
        and readyWidget.state.standbyInfoKind ~= "stale-standby-only-value"
        and readyWidget._standbyModule == nil and readyWidget._standbyTexts == textsBefore
        and statePassStable and #Stubs.lvgl.trees == treesBefore)
  end
  infoChangeDoesNotBuild("feature-off prerequisite change does not rebuild ready dashboard",
    readyWidget(false, false))
  infoChangeDoesNotBuild("flight-excluded prerequisite change does not rebuild ready dashboard",
    readyWidget(true, true))
  MspRuntime.isFblConnected = originalIsFblConnected
  EventsRuntime.isOnconnectActive = originalEventActive
  EventsRuntime.getOnconnectProgress = originalEventProgress
  EventsRuntime.getOnconnectPendingTaskName = originalEventPending
  if _G.rfsuite.session then _G.rfsuite.session.modelPreferencesResolved = savedResolved end

  for key, value in pairs(original) do Config[key] = value end
  _G.loadScript = loadScriptBeforeSpy
  MspRuntime.getState = originalMspState
end

-- Standby is a display-only module. Exercise its lifetime through the actual loader and runtime:
-- disabled widgets must not load it, active widgets share one instance, and the last exit must
-- release every widget-held reference. The shared ELRS provider goes with it while the TX power
-- alert is off and stays while the alert is on.
install()
do
  local standbyPath = "/SCRIPTS/RFSUITE/core/widgets/dashboard/standby.lua"
  local configPath = "/SCRIPTS/RFSUITE/core/lib/elrs_config.lua"
  local powerPath = "/SCRIPTS/RFSUITE/core/lib/elrs_power.lua"
  _G.rfsuite.clearModule("widgets/dashboard/standby.lua")
  local sharedConfig = assert(_G.rfsuite.require("lib/elrs_config.lua"))
  local originalLoadScript = loadScript
  local standbyLoads = 0
  _G.loadScript = function(path, mode)
    if path == standbyPath then standbyLoads = standbyLoads + 1 end
    return originalLoadScript(path, mode)
  end

  local Runtime = assert(loadfile(runtimePath))()
  local MspRuntime = assert(_G.__rfsuite_msp_runtime_module
    or _G.rfsuite.require("tasks/msp/runtime.lua"))
  local originalMspState = MspRuntime.getState
  MspRuntime.getState = function()
    return { lastConnected = false, versionReadCompleted = false }
  end

  local function newWidget(enabled)
    local widget = Runtime.new({ x = 0, y = 0, w = 800, h = 480 }, {})
    widget.preferences.dashboard = widget.preferences.dashboard or {}
    widget.preferences.dashboard.standby_enabled = enabled
    widget.preferences.dashboard.standby_layout = "elrs"
    widget.preferences.audio_events = widget.preferences.audio_events or {}
    widget.preferences.audio_events.tpwr_alert = false
    widget.state.fblConnected, widget.state.armed = false, false
    widget.state.hadInflightFlight, widget.flightMode = false, "preflight"
    return widget
  end

  local first = newWidget(false)
  first:refresh(0, nil)
  check("disabled standby does not load display module", standbyLoads == 0
    and _G.rfsuite.modules[standbyPath] == nil and first._standbyModule == nil)

  first.preferences.dashboard.standby_enabled = true
  first._job = nil
  first:refresh(0, nil)
  for _ = 1, 4 do first:refresh(0, nil) end
  local firstModule = first._standbyModule
  check("standby entry loads and owns display module", standbyLoads == 1
    and firstModule ~= nil and _G.rfsuite.modules[standbyPath] == firstModule
    and firstModule.consumerCount() == 1)
  check("standby entry holds the shared ELRS provider", first._standbyElrsConfig == sharedConfig)

  -- The alert was on earlier in this session and kept its own reference: with the alert off, the
  -- exit must make it let go too, or a later alert and a later standby would talk to the module
  -- through two providers.
  local Audio = assert(_G.rfsuite.require("lib/audio.lua"))
  local function audioProviderSlot()
    for index = 1, 64 do
      local name = debug.getupvalue(Audio.releaseElrsConfig, index)
      if name == "elrsConfigModule" then return index end
      if name == nil then return nil end
    end
  end
  local slot = assert(audioProviderSlot(), "the audio module's provider reference was not found")
  debug.setupvalue(Audio.releaseElrsConfig, slot, sharedConfig)
  local releasedCache = first._standbyCache
  first.preferences.dashboard.standby_enabled = false
  first._job = nil
  first:refresh(0, nil)
  check("disabled exit evicts last standby display module", first._standbyModule == nil
    and first._standbyCache == nil and first._standbyElrsConfig == nil and first._standbyCrsf == nil
    and _G.rfsuite.modules[standbyPath] == nil)
  -- Standby's entry read starts with a drain of late replies, and the clock has not moved: the
  -- provider is not idle yet, so it stays loaded until later passes have drained it.
  check("standby exit keeps the provider while its drain is pending", _G.rfsuite.elrs_config == sharedConfig)
  for _ = 1, 8 do Stubs.tick(); first:refresh(0, nil) end
  check("standby exit with the TX power alert off releases the shared ELRS provider",
    _G.rfsuite.modules[configPath] == nil and _G.rfsuite.elrs_config == nil
      and _G.rfsuite.modules[powerPath] == nil
      and select(2, debug.getupvalue(Audio.releaseElrsConfig, slot)) == nil)
  check("standby exit releases the radio status helper it loaded",
    _G.rfsuite.modules["/SCRIPTS/RFSUITE/core/lib/radio_status.lua"] == nil)

  first.preferences.dashboard.standby_enabled = true
  first._job = nil
  first:refresh(0, nil)
  first:refresh(0, nil)
  local reloadedModule = first._standbyModule
  check("standby re-entry reloads a fresh display module", standbyLoads == 2
    and reloadedModule ~= nil and reloadedModule ~= firstModule
    and first._standbyCache ~= nil and first._standbyCache ~= releasedCache)

  local second = newWidget(true)
  second.preferences.audio_events.tpwr_alert = true
  second:refresh(0, nil)
  second:refresh(0, nil)
  for _ = 1, 4 do first:refresh(0, nil); second:refresh(0, nil) end
  local reloadedConfig = second._standbyElrsConfig
  check("standby re-entry after a release loads one fresh shared ELRS provider", reloadedConfig ~= nil
    and reloadedConfig ~= sharedConfig and first._standbyElrsConfig == reloadedConfig
    and _G.rfsuite.elrs_config == reloadedConfig)
  check("two widgets share one loaded standby display module", standbyLoads == 2
    and second._standbyModule == reloadedModule and reloadedModule.consumerCount() == 2)
  first:background()
  check("first widget exit retains module for second widget", first._standbyModule == nil
    and first._standbyCache == nil and first._standbyElrsConfig == nil
    and second._standbyModule == reloadedModule and _G.rfsuite.modules[standbyPath] == reloadedModule
    and reloadedModule.consumerCount() == 1)
  second:background()
  check("last widget exit evicts shared standby display module", second._standbyModule == nil
    and _G.rfsuite.modules[standbyPath] == nil and reloadedModule.consumerCount() == 0)
  check("last exit with the TX power alert on keeps the shared ELRS provider",
    _G.rfsuite.modules[configPath] == reloadedConfig and _G.rfsuite.elrs_config == reloadedConfig)

  first._foreground = true
  first._job = nil
  first:refresh(0, nil)
  first:refresh(0, nil)
  check("backgrounded widget re-entry reloads display module", standbyLoads == 3
    and first._standbyModule ~= nil)
  first._toolHost = { phase = "run", home = { run = function() return 0 end }, cpuHits = 0 }
  first:refresh(0, nil)
  check("hosted tool exit evicts standby display module", first._standbyModule == nil
    and first._standbyElrsConfig == nil and _G.rfsuite.modules[standbyPath] == nil
    and first._treeKind ~= "standby")

  MspRuntime.getState = originalMspState
  _G.loadScript = originalLoadScript
end

-- The ELRS provider is unloaded only while it is idle. CRSF parameter replies carry no transaction
-- id, so a conversation cut short leaves the provider in quarantine until the late replies are
-- drained; unloading it then would forget that, and the next instance would take those replies
-- for its own. A lease another consumer holds keeps it loaded as well.
local function standbyElrsScenario()
  install()
  local rf = _G.rfsuite
  rf.clearModule("widgets/dashboard/standby.lua")
  rf.clearModule("lib/elrs_config.lua")
  rf.clearModule("lib/elrs_power.lua")
  rf.clearModule("lib/crsf.lua")
  rf.elrs_config, rf.crsf_manager = nil, nil
  local Runtime = assert(loadfile(runtimePath))()
  local MspRuntime = assert(_G.__rfsuite_msp_runtime_module or rf.require("tasks/msp/runtime.lua"))
  local originalMspState = MspRuntime.getState
  MspRuntime.getState = function() return { lastConnected = false, versionReadCompleted = false } end
  local sent = {}
  local originalOnPush = Stubs.onPush
  Stubs.onPush = function(command, data) sent[#sent + 1] = command; return true end
  local widget = Runtime.new({ x = 0, y = 0, w = 800, h = 480 }, {})
  widget.preferences.dashboard = widget.preferences.dashboard or {}
  widget.preferences.dashboard.standby_enabled = true
  widget.preferences.dashboard.standby_layout = "elrs"
  widget.preferences.audio_events = widget.preferences.audio_events or {}
  widget.preferences.audio_events.tpwr_alert = false
  widget.state.fblConnected, widget.state.armed = false, false
  widget.state.hadInflightFlight, widget.flightMode = false, "preflight"
  local s = { widget = widget }
  function s.passes(n) for _ = 1, n do Stubs.tick(); widget:refresh(0, nil) end end
  function s.sent(kind)
    local count = 0
    for i = 1, #sent do if sent[i] == kind then count = count + 1 end end
    return count
  end
  function s.leave()
    widget.preferences.dashboard.standby_enabled = false
    widget._job = nil
    s.passes(1)
  end
  function s.restore()
    MspRuntime.getState = originalMspState
    Stubs.onPush = originalOnPush
  end
  return s
end
local function elrsBytes(value)
  local out = {}
  for i = 1, #value do out[#out + 1] = string.byte(value, i) end
  out[#out + 1] = 0
  return out
end
local function elrsInfo(fieldCount)
  local out = { 0xEA, 0xEE }
  for _, b in ipairs(elrsBytes("ELRS TX")) do out[#out + 1] = b end
  for _, b in ipairs({ 0x45, 0x4C, 0x52, 0x53, 0, 0, 0, 1, 0, 4, 1, 0, fieldCount }) do out[#out + 1] = b end
  return out
end
local function elrsRateEntry(selected)
  local out = { 0xEA, 0xEE, 1, 0, 0, 9 }
  for _, b in ipairs(elrsBytes("Packet Rate")) do out[#out + 1] = b end
  for _, b in ipairs(elrsBytes("250Hz;500Hz")) do out[#out + 1] = b end
  for _, b in ipairs({ selected, 0, 1, 0 }) do out[#out + 1] = b end
  for _, b in ipairs(elrsBytes("")) do out[#out + 1] = b end
  return out
end

-- Standby closes while its read of the module waits for a parameter reply, with the TX power alert
-- off; the replies arrive afterwards and the ELRS Link page opens in the same Lua state. It has to
-- drain them and accept only the answer to its own request.
do
  local s = standbyElrsScenario()
  s.passes(12)
  check("standby read pinged the module", s.sent(0x28) >= 1)
  Stubs.pushFrame(0x29, elrsInfo(1))
  s.passes(2)
  check("standby read asked for the first parameter", s.sent(0x2C) >= 1)
  local provider = _G.rfsuite.elrs_config
  s.leave()
  check("standby exit evicts the display module", s.widget._standbyModule == nil)
  Stubs.pushFrame(0x29, elrsInfo(1))
  Stubs.pushFrame(0x2B, elrsRateEntry(0))

  local savedSession = _G.rfsuite.session
  _G.rfsuite.session = { isConnected = true, telemetryType = "crsf",
    crsfTelemetryConfig = { linkRate = 500, linkRatio = 4 } }
  local Task = assert(loadfile(root .. "/src/rfsuite/app/pages/tools/diagnostics/elrs_link/elrslink_task.lua"))()
  Task.reset()
  Task.start(Task.MODE_PROBE)
  local readsBefore = s.sent(0x2C)
  for _ = 1, 10 do
    Stubs.tick(); Task.wakeup()
    local field = Task.getRateField()
    check("diagnostics took the standby read's late reply as its own: " .. tostring(field and field.selectedLabel)
      .. " with " .. tostring(s.sent(0x2C) - readsBefore) .. " requests of its own; provider "
      .. (_G.rfsuite.elrs_config == provider and "kept" or "replaced"), field == nil)
  end
  check("diagnostics asked for the parameter itself after the drain", s.sent(0x2C) > readsBefore)
  Stubs.pushFrame(0x2B, elrsRateEntry(1))
  Stubs.tick(); Task.wakeup()
  local field = Task.getRateField()
  check("diagnostics accepted the answer to its own request", field ~= nil and field.selectedLabel == "500Hz")
  Task.reset()
  _G.rfsuite.session = savedSession
  s.restore()
end

-- Standby closes while the ELRS Link page holds the provider's lease. The registry keeps that
-- instance, so a second consumer cannot load another and talk to the module beside it; once the
-- lease is let go, a later pass unloads it.
do
  local s = standbyElrsScenario()
  s.passes(12)
  Stubs.pushFrame(0x29, elrsInfo(1))
  s.passes(2)
  Stubs.pushFrame(0x2B, elrsRateEntry(1))
  s.passes(2)
  local provider = _G.rfsuite.elrs_config
  check("standby read completed", provider ~= nil and provider.snapshot().status == "ready")
  check("diagnostics takes the provider's lease", provider.acquire("diagnostics"))
  s.leave()
  local loaded = _G.rfsuite.require("lib/elrs_config.lua")
  check("standby exit kept the provider diagnostics holds: registry "
    .. (_G.rfsuite.elrs_config == provider and "kept" or "dropped") .. ", a later load "
    .. (loaded == provider and "shares it" or "made another instance"),
    _G.rfsuite.elrs_config == provider and loaded == provider)
  check("a second owner is refused while diagnostics holds the lease", not provider.acquire("audio:test"))
  provider.release("diagnostics")
  s.widget:background()
  check("a later pass unloads the provider once the lease is let go", _G.rfsuite.elrs_config == nil
    and _G.rfsuite.modules["/SCRIPTS/RFSUITE/core/lib/elrs_config.lua"] == nil)
  s.restore()
end

-- Every dashboard widget loads its own copy of the runtime (src/widgets/rfsuite/main.lua), so a
-- release one widget has deferred must not go ahead while another widget's standby screen uses the
-- provider: that screen keeps its reference, and the next consumer would load a second instance.
do
  local s = standbyElrsScenario()
  s.passes(12)
  s.leave()
  local provider = _G.rfsuite.elrs_config
  check("first widget's exit during discovery defers the release", provider ~= nil)
  local Other = assert(loadfile(runtimePath))()
  local other = Other.new({ x = 0, y = 0, w = 800, h = 480 }, {})
  other.preferences.dashboard = other.preferences.dashboard or {}
  other.preferences.dashboard.standby_enabled = true
  other.preferences.dashboard.standby_layout = "elrs"
  other.preferences.audio_events = other.preferences.audio_events or {}
  other.preferences.audio_events.tpwr_alert = false
  other.state.fblConnected, other.state.armed = false, false
  other.state.hadInflightFlight, other.flightMode = false, "preflight"
  for _ = 1, 12 do Stubs.tick(); other:refresh(0, nil) end
  Stubs.pushFrame(0x29, elrsInfo(1))
  for _ = 1, 2 do Stubs.tick(); other:refresh(0, nil) end
  Stubs.pushFrame(0x2B, elrsRateEntry(1))
  for _ = 1, 2 do Stubs.tick(); other:refresh(0, nil) end
  check("second widget's standby read completed on the shared provider", other._standbyElrsConfig == provider
    and provider.snapshot().status == "ready")
  for _ = 1, 3 do Stubs.tick(); s.widget:background() end
  check("first widget's deferred release left the provider the second widget's standby uses: registry "
    .. (_G.rfsuite.elrs_config == provider and "kept" or "dropped"), _G.rfsuite.elrs_config == provider)
  other.preferences.dashboard.standby_enabled = false
  other._job = nil
  for _ = 1, 2 do Stubs.tick(); other:refresh(0, nil) end
  check("the last standby exit unloads the idle provider", _G.rfsuite.elrs_config == nil)
  s.restore()
end

Stubs.releaseCard()
print(string.format("dashboard_standby_integration_test: %d checks passed", passed))
