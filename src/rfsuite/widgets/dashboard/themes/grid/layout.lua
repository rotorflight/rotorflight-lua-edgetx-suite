-- The panels the flight view and the statistics view are assembled from.
--
-- Split off common.lua only for size: the drawing primitives and the value getters are
-- there, the arrangement is here. Both are cached on _G, the same way the shipped themes cache
-- theirs, until the dashboard releases a theme no widget uses any more (releaseUnusedThemes in
-- widgets/dashboard/runtime.lua): module state here starts afresh when the theme is shown again.
-- This module is the theme's whole surface to the phase modules: buildFlight, buildStats,
-- sources and renderKey, so that a phase module is one require and a few forwards.
--
-- The look: the top bar, a battery panel down the left (a card, the segmented gauge, or
-- nothing, at one of three widths), a grid of bordered value tiles beside it -- two to nine
-- cells, filled from six slots in order, with an extra tile in the first cell the slots leave
-- free -- and the status bar at the foot, which the pilot can switch off.
--
-- Extending the theme -- where a change goes, and what it costs:
--
--   a new value a tile can show            one entry in L.SOURCES; the configure page and the
--                                          grid both read that list, nothing else changes.
--   a new panel or a new box in a panel    a build-time function here appending nodes; every
--                                          moving field a Common.getter over `state`; every
--                                          firmware probe at build time, never in a closure.
--   a new build-time reading               a term in L.renderKey -- with a dead band where the
--                                          reading is continuous, or the panel rebuilds on noise.
--   a derived quantity (a latch, a peak,   NOT here. A theme has no per-pass entry point but the
--   a decoder, a sag detector)             render key, and that runs inside the host's most
--                                          expensive pass. Derivation belongs on the host's
--                                          `state` or flight record; the theme draws it.

if type(_G) == "table" and type(_G.__rfsuiteThemeGridLayoutModule) == "table" then
  return _G.__rfsuiteThemeGridLayoutModule
end

local function requireModule(path)
  if _G.rfsuite and type(_G.rfsuite.require) == "function" then
    local mod = _G.rfsuite.require(path)
    if type(mod) == "table" then return mod end
  end
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/" .. path, mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local Common = requireModule("widgets/dashboard/themes/grid/common.lua")
if not Common then return {} end

local L = {}
local C = Common.C
local T = Common.T
local num = Common.num

-- The colour scheme's option list and its default, forwarded from common.lua where the
-- palettes are. The configure page loads this module and not common.lua, and a page that
-- carried its own copy of the list would be free to offer a scheme the theme cannot draw.
L.SCHEMES = Common.SCHEMES
L.DEFAULT_SCHEME = Common.DEFAULT_SCHEME

-- The settings this theme carries beyond the six tile slots, the colour scheme and the arm
-- colours. They are declared HERE for the reason the value catalogue is here: the settings page
-- loads this module, so the list a pilot chooses from and the list the panels draw from are one
-- list and cannot drift apart.
--
-- This half is what the DRAWING needs and nothing else: the key, the page of init.lua the row is
-- set on, the values that are valid, and the default. The defaults draw a complete screen with
-- nothing touched: the battery card beside a 3 x 2 grid, the clock showing the time alone.
--
-- Values are STRINGS, the numbers included. common.lua says why; the two numeric rows are read
-- back through tonumber() at build time.
--
-- A row with `min` and `max` in place of `values` is a whole number the pilot sets freely in that
-- range rather than one picked from a list; it is stored as text like the rest. `notAbove` names
-- the row whose value it may not exceed: the settings page holds it there, and the theme's own
-- read does too (Common.fuelSteps).
--
-- `lead` puts a row ahead of the slot choices on its page rather than after them: the grid size
-- decides how many of the slots below it are drawn at all, so it is read first.
--
-- None of these belongs in the render key. A themeConfig read is a BUILD-TIME read: the host
-- reloads the theme when its preferences change, and what the key bills is a reading that moves
-- in flight, which no setting does.
local ON_OFF = { "on", "off" }

L.SETTINGS = {
  -- The firmware's own frame around every place on the full screen that takes a press -- the
  -- menu and tool buttons, the link bars, the battery panel, the tiles, the status bar, the buttons of the views. Off covers
  -- it (Common.button); the outlines this theme draws itself stay.
  { page = "look",   key = "tap_frames", values = ON_OFF,                      default = "on" },
  -- The battery gauge's yellow and red steps, in percent of the fuel reading. The defaults are
  -- the steps the gauge draws with when nobody has set them.
  { page = "look",   key = "fuel_low",   min = 0, max = 100, default = tostring(Common.FUEL_LOW_DEFAULT) },
  { page = "look",   key = "fuel_crit",  min = 0, max = 100, default = tostring(Common.FUEL_CRIT_DEFAULT),
    notAbove = "fuel_low" },
  -- The battery panel down the left: the card (the percentage large, the cell voltage and the
  -- capacity used, a fill bar at the foot), the segmented gauge, or nothing -- the tiles then take
  -- the whole width. Its width is a share of the content width.
  { page = "layout", key = "left",       values = { "card", "gauge", "off" },  default = "card" },
  { page = "layout", key = "left_width", values = { "narrow", "normal", "wide" }, default = "normal" },
  -- The status bar at the foot, on the flight view and the statistics view alike: a control that
  -- hid it on one and not on the other would be worse than none. Off, the tiles take its height.
  { page = "layout", key = "status_bar", values = ON_OFF,                      default = "on" },
  -- The status bar's transmitter power.
  { page = "layout", key = "tpwr",       values = ON_OFF,                      default = "on" },
  -- How many cells the tile grid has, columns by rows. The six slots fill the cells in order; a
  -- slot past the last cell is not drawn.
  { page = "tiles",  key = "size",       values = { "2x2", "3x2", "4x2", "2x3", "3x3" }, default = "3x2",
    lead = true },
  -- What the first cell the slots leave free shows: the model's picture, or the PID, rate and
  -- battery profile numbers. Off leaves the cell empty.
  { page = "tiles",  key = "extra",      values = { "model", "profiles", "off" }, default = "model" },
  { page = "topbar", key = "clock",      values = { "date_time", "time" },     default = Common.CLOCK_MODE_DEFAULT },
  -- The link bars, one row each: the receiver's link quality, the transmitter's, and the signal
  -- strength as headroom above the air rate's sensitivity floor.
  { page = "topbar", key = "lq_bar",     values = ON_OFF,                      default = "on" },
  { page = "topbar", key = "tq_bar",     values = ON_OFF,                      default = "on" },
  { page = "topbar", key = "rssi_bars",  values = ON_OFF,                      default = "on" },
  { page = "topbar", key = "tx_battery", values = ON_OFF,                      default = "on" },
  { page = "topbar", key = "bar_colors", values = { "always", "warn" },        default = "always" },
  -- The link bars' warning and critical steps are not settings of this theme: they are the levels
  -- of the announcements (Settings > Audio > Events > Link), read off `state.alerts` (L.alertSteps),
  -- so a bar turns amber where the voice speaks. A value an older version of this theme stored
  -- for its own steps stays in the settings file and is no longer read.
  -- The unit in each tile's caption row. On by default here: a tile has the room for it beside
  -- its caption, so switching it off gives the value nothing back.
  { page = "tiles",  key = "units",      values = ON_OFF,                      default = "on" },
  { page = "tiles",  key = "temp_colors", values = { "off", "standard", "early" }, default = Common.TEMP_COLORS_DEFAULT },
}

-- And this half is what the SETTINGS PAGE needs: the row's label and a label per value. It is a
-- FUNCTION rather than a table, and that is the whole of the trick -- a function body costs the
-- widget's Lua state one closure at load, where the same strings as a literal cost a table
-- constructor per row and per option, paid in the pass that RELOADS THE THEME -- which runs on
-- every phase change -- for text the widget never draws. The settings page calls this once, in a
-- Lua state of its own.
--
-- A value with no label here would reach the page as its raw stored string.
--
-- Every word is a translation marker in the settings page's block of the suite's translation
-- files, resolved by the packager into each locale's build. On, Off, Always and Standard are the
-- suite's own words for them, read from the pages that already carry them.
function L.settingsLabels()
  local function onOff()
    return { on = "@i18n(app.pages.flight_tuning_advanced_pid_controller.tbl_on)@",
             off = "@i18n(app.pages.flight_tuning_advanced_pid_controller.tbl_off)@" }
  end
  return {
    tap_frames = { label = "@i18n(app.pages.settings_dashboard_settings.urban_tap_frames)@", values = onOff() },
    left = { label = "@i18n(app.pages.settings_dashboard_settings.grid_left)@",
             values = { card = "@i18n(app.pages.settings_dashboard_settings.grid_left_card)@",
                        gauge = "@i18n(app.pages.settings_dashboard_settings.grid_left_gauge)@",
                        off = "@i18n(app.pages.flight_tuning_advanced_pid_controller.tbl_off)@" } },
    left_width = { label = "@i18n(app.pages.settings_dashboard_settings.grid_left_width)@",
                   values = { narrow = "@i18n(app.pages.settings_dashboard_settings.grid_width_narrow)@",
                              normal = "@i18n(app.pages.settings_dashboard_settings.grid_width_normal)@",
                              wide = "@i18n(app.pages.settings_dashboard_settings.grid_width_wide)@" } },
    status_bar = { label = "@i18n(app.pages.settings_dashboard_settings.urban_status_bar)@", values = onOff() },
    size = { label = "@i18n(app.pages.settings_dashboard_settings.grid_size)@",
             values = { ["2x2"] = "2 x 2", ["3x2"] = "3 x 2", ["4x2"] = "4 x 2",
                        ["2x3"] = "2 x 3", ["3x3"] = "3 x 3" } },
    extra = { label = "@i18n(app.pages.settings_dashboard_settings.grid_extra)@",
              values = { model = "@i18n(app.pages.settings_dashboard_settings.grid_extra_model)@",
                         profiles = "@i18n(app.pages.settings_dashboard_settings.grid_extra_profiles)@",
                         off = "@i18n(app.pages.flight_tuning_advanced_pid_controller.tbl_off)@" } },
    fuel_low = { label = "@i18n(app.pages.settings_dashboard_settings.urban_fuel_low)@", suffix = " %" },
    fuel_crit = { label = "@i18n(app.pages.settings_dashboard_settings.urban_fuel_crit)@", suffix = " %" },
    clock = { label = "@i18n(app.pages.settings_dashboard_settings.urban_clock)@",
              values = { date_time = "@i18n(app.pages.settings_dashboard_settings.urban_clock_date_time)@",
                         time = "@i18n(app.pages.settings_dashboard_settings.urban_clock_time)@" } },
    lq_bar = { label = "@i18n(app.pages.settings_dashboard_settings.urban_lq_bar)@", values = onOff() },
    tq_bar = { label = "@i18n(app.pages.settings_dashboard_settings.urban_tq_bar)@", values = onOff() },
    rssi_bars = { label = "@i18n(app.pages.settings_dashboard_settings.urban_rssi_bars)@", values = onOff() },
    tx_battery = { label = "@i18n(app.pages.settings_dashboard_settings.urban_tx_battery)@", values = onOff() },
    tpwr = { label = "@i18n(app.pages.settings_dashboard_settings.urban_status_bar)@: TPWR", values = onOff() },
    bar_colors = { label = "@i18n(app.pages.settings_dashboard_settings.urban_bar_colors)@",
                   values = { always = "@i18n(app.pages.setup_adjustments.channel_always)@",
                              warn = "@i18n(app.pages.settings_dashboard_settings.urban_bar_colors_warn)@" } },
    units = { label = "@i18n(app.pages.settings_dashboard_settings.urban_units)@", values = onOff() },
    temp_colors = { label = "@i18n(app.pages.settings_dashboard_settings.urban_temp_colors)@",
                    values = { off = "@i18n(app.pages.flight_tuning_advanced_pid_controller.tbl_off)@",
                               standard = "@i18n(app.pages.settings_dashboard_inflight.standard)@",
                               early = "@i18n(app.pages.settings_dashboard_settings.urban_temp_colors_early)@" } },
  }
end

local SETTINGS_BY_KEY = {}
for i = 1, #L.SETTINGS do
  SETTINGS_BY_KEY[L.SETTINGS[i].key] = L.SETTINGS[i]
end

-- What the pilot chose for one key, or the theme's own default where he has chosen nothing.
local function setting(state, key)
  local entry = SETTINGS_BY_KEY[key]
  if entry.values == nil then
    return tostring(Common.percent(state, key, tonumber(entry.default)))
  end
  return Common.option(state, key, entry.values, entry.default)
end
L.setting = setting

local OUTER_PAD = 2
local CARD_GAP = 4
local CARD_PAD = 3

-- What the stored ids of the two geometry settings stand for: the battery panel's share of the
-- content width in percent, and the grid's columns and rows.
local LEFT_WIDTH_PCT = { narrow = 22, normal = 30, wide = 40 }
local GRID_SIZES = {
  ["2x2"] = { 2, 2 }, ["3x2"] = { 3, 2 }, ["4x2"] = { 4, 2 }, ["2x3"] = { 2, 3 }, ["3x3"] = { 3, 3 },
}

-- The six slots the tile grid is filled from.
L.SLOT_COUNT = 6

-- How many cells the pilot's grid size has.
local function gridCells(state)
  local size = GRID_SIZES[setting(state, "size")]
  return size[1] * size[2], size[1], size[2]
end

-- ---------------------------------------------------------------------------
-- the full screen surface: the menu control
-- ---------------------------------------------------------------------------

-- On the full screen surface the host hands the build a `ctx` (and only there), and a theme that
-- binds a press of its own gets no host controls over it. This theme binds two small boxed glyphs
-- at the left end of the top bar, before the clock: this one opens the quick menu, the one beside
-- it the suite's tool (L.toolControl). There is no close control -- a long press on RTN leaves full screen in the firmware, and
-- init.lua declares that (`fullscreenExit`), which is what the host's theme check reads.
-- With PAGE on Theme radio-wide, the page keys open the menu only when bound.
--
-- The press is a `button`, and everything drawn over it is a LINE: on the full screen surface a
-- rectangle takes a press and hands it to its PARENT, so a rectangle over the button would
-- swallow every press landing on it. A line is created not clickable. The button's own fill is
-- the panel's, so what shows is the outline and the three bars, drawn as lines over it. EdgeTX
-- gives every button a theme-coloured border of its own; the outline lines lie over it.
--
-- Returns the width it took, so the clock can start after it. Without a ctx -- the widget zone,
-- a host that does not know the key -- nothing is drawn and nothing is taken: the glyph is a
-- full screen control only.
function L.menuControl(nodes, ctx, x, y, h)
  if type(ctx) ~= "table" or type(ctx.action) ~= "function" then return 0 end
  local action = ctx.action
  local boxH = math.max(8, h - 2)
  local boxW = boxH
  local bx, by = x, y + 1
  Common.button(nodes, bx, by, boxW, boxH, C.bg, function() action("openView:menu") end)
  local x1, y1 = bx + boxW - 1, by + boxH - 1
  local edges = {
    { { bx, by }, { x1, by } }, { { bx, y1 }, { x1, y1 } },
    { { bx, by }, { bx, y1 } }, { { x1, by }, { x1, y1 } },
  }
  for i = 1, 4 do
    nodes[#nodes + 1] = { type = "line", x = 0, y = 0, w = 0, h = 0, pts = edges[i],
      color = C.line, thickness = 2 }
  end
  -- The bars scaled from the box, so the glyph keeps its shape on both screen heights.
  local barTh = math.max(2, math.floor(boxH * 0.11))
  local padX = math.max(3, math.floor(boxW * 0.24))
  local barX = bx + padX
  local barW = boxW - 2 * padX
  local gap = math.max(barTh + 1, math.floor(boxH * 0.20))
  local midY = by + math.floor(boxH / 2) - math.floor(barTh / 2)
  for i = -1, 1 do
    local lineY = midY + i * gap + math.floor(barTh / 2)
    nodes[#nodes + 1] = { type = "line", x = 0, y = 0, w = 0, h = 0,
      pts = { { barX, lineY }, { barX + barW, lineY } }, color = C.text, thickness = barTh }
  end
  return boxW + 4
end

-- Whether the full screen build's ctx comes from a host with theme views -- the one that runs
-- this theme's own views (init.lua `views`) and hands out `ctx.entry`. Only then does the flight
-- view bind the two taps that open them; a host without them gets exactly the tree it always got.
local function hasViews(ctx)
  return type(ctx) == "table" and type(ctx.action) == "function" and type(ctx.entry) == "function"
end
L.hasViews = hasViews

-- The second control of the top bar, beside the menu glyph and of its size and outline: it opens
-- the suite's tool (`openTool`), on a host with theme views -- the host this theme's views run on,
-- whose quick menu offers the tool as well. Returns the width it took, as L.menuControl does.
--
-- The host opens the tool only while the model is disarmed, and refuses the action while it is
-- armed (widgets/dashboard/tool_host.lua, `request`), as its quick menu offers the tool only while
-- disarmed. So the control says so: while armed, its outline and its glyph are drawn in the
-- track colour, the colour of a row that is not available in this theme's views. The arm state
-- is read per frame by the two colour functions the lines of the control share, rather than at
-- build time: the render key does not carry it, so the flight view is not rebuilt on the arm
-- edge (L.renderKey).
--
-- The glyph is four squares in a square, the picture of a set of tools; each square is a short
-- line as thick as it is long.
function L.toolControl(nodes, state, ctx, x, y, h)
  if not hasViews(ctx) then return 0 end
  local action = ctx.action
  -- The outline in the line colour and the squares in the text colour, as the menu glyph draws
  -- its outline and its bars.
  local edge = function()
    if state.armed == true then return C.track end
    return C.line
  end
  local ink = function()
    if state.armed == true then return C.track end
    return C.text
  end
  local boxH = math.max(8, h - 2)
  local boxW = boxH
  local bx, by = x, y + 1
  Common.button(nodes, bx, by, boxW, boxH, C.bg, function() action("openTool") end)
  local x1, y1 = bx + boxW - 1, by + boxH - 1
  local edges = {
    { { bx, by }, { x1, by } }, { { bx, y1 }, { x1, y1 } },
    { { bx, by }, { bx, y1 } }, { { x1, by }, { x1, y1 } },
  }
  for i = 1, 4 do
    nodes[#nodes + 1] = { type = "line", x = 0, y = 0, w = 0, h = 0, pts = edges[i],
      color = edge, thickness = 2 }
  end
  local s = math.max(2, math.floor(boxH * 0.22))
  local gap = math.max(2, math.floor(boxH * 0.12))
  local ox = bx + math.floor((boxW - 2 * s - gap) / 2)
  local oy = by + math.floor((boxH - 2 * s - gap) / 2)
  for i = 0, 1 do
    for j = 0, 1 do
      local cx = ox + i * (s + gap)
      local cy = oy + j * (s + gap) + math.floor(s / 2)
      nodes[#nodes + 1] = { type = "line", x = 0, y = 0, w = 0, h = 0,
        pts = { { cx, cy }, { cx + s, cy } }, color = ink, thickness = s }
    end
  end
  return boxW + 4
end

-- A press over an area that is drawn anyway: a button in the panel's own colour, appended BEFORE
-- what is drawn over it, which then has to be labels and lines -- a rectangle over a press takes
-- the press away from it. EdgeTX draws every button with a frame of its own, which the pilot can
-- have covered (Common.button).
local function tapArea(nodes, x, y, w, h, press)
  Common.button(nodes, x, y, w, h, C.bg, press)
end

-- ---------------------------------------------------------------------------
-- the full screen surface: the keys
-- ---------------------------------------------------------------------------

-- What a key may do in full screen, as the pilot chooses it on the Keys settings page: a stored
-- id and the host action it stands for. The settings page offers exactly these, so the two cannot
-- drift apart. The battery picker is not among them: the host opens it while a pick is pending
-- and at no other time. `suite_tool` is the suite's tool, which the host opens only while the
-- model is disarmed: armed, the key does nothing. `flight_log` is the same tool opened on its
-- Flight Log page, which the host opens under the same condition.
L.KEY_ACTIONS = {
  { id = "none",       action = "none" },
  { id = "menu",       action = "openView:menu" },
  { id = "tools",      action = "openView:grid_menu" },
  { id = "link",       action = "openView:grid_link" },
  { id = "telemetry",  action = "openView:grid_telemetry" },
  { id = "battery",    action = "openView:grid_battery" },
  { id = "status",     action = "openView:grid_status" },
  { id = "suite_tool", action = "openTool" },
  { id = "flight_log", action = "openTool:tools_flight_log_page" },
  { id = "exit",       action = "exitFullscreen" },
}

-- The keys the pilot can bind: the host's name in `ctx.keys`, the stored key, and the
-- unbound default. `host` is the choice that leaves `ctx.keys` empty; all rows start on Nothing.
-- Quick menu is an explicit binding, including on PAGE keys. The radio-wide defaults of
-- Settings > Dashboard > Keys (widgets/dashboard/keys.lua) are where PAGE, SYS and TELE get theirs.
-- A binding here acts only while that page leaves the key on Theme.
--
-- The stored keys are `theme_key_*`. The `key_*` ones an earlier build of this page wrote stay in
-- the pilot's files and bind nothing any more, so a key starts unbound here.
--
-- Not rows of L.SETTINGS: those are what the drawing reads, and the page probe holds each of them
-- to a change in the picture. A key binding draws nothing.
L.KEYS = {
  { key = "pageDown", pref = "theme_key_page_down", default = "none", host = "none" },
  { key = "pageUp",   pref = "theme_key_page_up",   default = "none", host = "none" },
  { key = "mdl",      pref = "theme_key_mdl",       default = "none", host = "none" },
  { key = "sys",      pref = "theme_key_sys",       default = "none", host = "none" },
  { key = "tele",     pref = "theme_key_tele",      default = "none", host = "none" },
}

local KEY_ACTION_IDS = {}
local KEY_ACTION_BY_ID = {}
for i = 1, #L.KEY_ACTIONS do
  KEY_ACTION_IDS[i] = L.KEY_ACTIONS[i].id
  KEY_ACTION_BY_ID[L.KEY_ACTIONS[i].id] = L.KEY_ACTIONS[i].action
end
L.KEY_ACTION_IDS = KEY_ACTION_IDS

-- Fill `ctx.keys` from the pilot's choices, on a host with theme views. A key set to `host`
-- (Nothing) is left unbound, and the host then does nothing with it either. Every key is
-- written on every build, an unbound one as nil: the host keeps one `ctx` for the whole visit to
-- full screen, so a binding cleared on the page has to be cleared here as well. A build-time read
-- like every other setting -- the host reloads the theme when its preferences change.
function L.bindKeys(state, ctx)
  if not hasViews(ctx) or type(ctx.keys) ~= "table" then return end
  local keys = ctx.keys
  for i = 1, #L.KEYS do
    local entry = L.KEYS[i]
    local id = Common.option(state, entry.pref, KEY_ACTION_IDS, entry.default)
    if id == entry.host then
      keys[entry.key] = nil
    else
      keys[entry.key] = KEY_ACTION_BY_ID[id]
    end
  end
end

-- ---------------------------------------------------------------------------
-- top bar: menu and tool glyphs, clock, link bars, TX battery pill
-- ---------------------------------------------------------------------------

-- The radio battery is read at BUILD time, never in a closure: getValue is a sensor probe
-- and those are barred from the reactive sweep. The render key carries it in steps, so the
-- pill follows the pack at the cost of a rebuild only when it actually moves -- a cadence of
-- minutes on a radio battery.
function L.txVoltage()
  local ok, v = pcall(getValue, "tx-voltage")
  if ok and type(v) == "number" and v > 0 then return v end
  return nil
end

-- The percentage needs the radio's own battery range, which getGeneralSettings answers with
-- a freshly allocated table. That is a build-time read: the range changes when the pilot edits
-- the radio settings, and a pill painted from the previous range until the next rebuild is
-- the whole cost of not asking every half second from the render key.
--
-- The third answer is "low": below the radio's own battery warning, as a share of the same
-- range.
function L.txBattery()
  local volts = L.txVoltage()
  local vMin, vMax, vWarn = 6.6, 8.4, nil
  local okG, g = pcall(getGeneralSettings)
  if okG and type(g) == "table" then
    if type(g.battMin) == "number" and g.battMin > 0 then vMin = g.battMin end
    if type(g.battMax) == "number" and g.battMax > vMin then vMax = g.battMax end
    if type(g.battWarn) == "number" and g.battWarn > 0 then vWarn = g.battWarn end
  end
  local pct, low = nil, false
  if volts then
    pct = math.floor((volts - vMin) / (vMax - vMin) * 100 + 0.5)
    if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
    if vWarn then
      local warnPct = math.ceil(100 - (100 * (vMax - vWarn) / (vMax - vMin)))
      low = pct < warnPct
    end
  end
  return volts, pct, low
end

-- The signal strength as the bar shows it: the headroom of a reading in dBm above the
-- sensitivity floor of the air rate the link runs, as a percentage of the window up to -40 dBm.
-- Nil without a reading or without a known floor, which the bar draws as an empty track.
local RSSI_TOP = -40
local function rssiPercent(dbm, floor)
  if type(dbm) ~= "number" or dbm == 0 then return nil end
  if type(floor) ~= "number" or floor >= RSSI_TOP then return nil end
  local r = math.min(dbm, RSSI_TOP)
  local p = 100 * (r - floor) / (RSSI_TOP - floor)
  if p < 0 then p = 0 elseif p > 100 then p = 100 end
  return math.floor(p)
end
L.rssiPercent = rssiPercent

-- The warning and critical steps of one announcement's levels (`state.alerts`, which the host
-- resolves when it builds the theme), or nil where it publishes none for that announcement -- a
-- bar then draws without steps rather than at a guessed one. The steps hold whether or not the
-- announcement itself is switched on: the bar colours the reading either way.
local function alertSteps(state, key)
  local alerts = state and state.alerts
  local levels = type(alerts) == "table" and alerts[key] or nil
  if type(levels) ~= "table" then return nil end
  local warn, crit = tonumber(levels.warn), tonumber(levels.critical)
  if warn == nil or crit == nil then return nil end
  return warn, crit
end
L.alertSteps = alertSteps

-- A link bar's fill as a reactive `size`: `full` pixels at 100, clamped to 0..100, worked out
-- once per change of the reading rather than on every frame.
local function barLength(read, full, fh)
  local lastV, lastW = Common.UNSET, 0
  return function()
    local v = read()
    if v ~= lastV then
      lastV = v
      local p = v or 0
      if p < 0 then p = 0 elseif p > 100 then p = 100 end
      lastW = math.floor(full * p / 100)
    end
    return lastW, fh
  end
end

-- The top bar, left to right: the menu and tool glyphs (full screen only), the clock, the link bars
-- centred on the bar's midline, the radio battery pill at the right end.
--
-- `showLink` false draws the clock and the pill and nothing between them, whatever the pilot
-- set for the bars: the statistics view is the one caller that passes it, and after a flight
-- the link has nothing left to report that the table below does not say better.
function L.topBar(nodes, state, x, y, w, h, font, fontH, ctx, showLink)
  local textY = y + math.floor((h - fontH) / 2)

  -- Every setting this bar reads is a BUILD-TIME read of state.themeConfig, and none of them is
  -- in the render key: the host reloads the theme when its preferences change.
  local quietBars = setting(state, "bar_colors") == "warn"

  local clockX = x + 1 + L.menuControl(nodes, ctx, x + 1, y, h)
  clockX = clockX + L.toolControl(nodes, state, ctx, clockX, y, h)

  -- The clock, in the mode the pilot chose, and its width measured against THAT mode's own
  -- sample -- common.lua keeps the format and the sample in one entry.
  local clock = Common.clockMode(setting(state, "clock"))
  local clockW = Common.textWidth(font, clock.sample) + 8
  Common.label(nodes, clockX, textY, clockW, fontH, Common.clock(clock), font, C.text, LEFT)

  -- The TX battery as a pill: fill, terminal, outline, and the percentage over it. Switched
  -- off, the pill is not drawn AND its width is given back to the link bars.
  local rightLimit = x + w
  if setting(state, "tx_battery") == "on" then
    local pillH = math.max(8, math.floor((h - 2) * ((h >= 28) and 0.76 or 0.92)))
    local pillW = math.max(30, math.floor(pillH * 2.6))
    local termW = math.max(2, math.floor(pillW * 0.06))
    local pillX = x + w - pillW - termW - 1
    local pillY = y + math.floor((h - pillH) / 2)
    local pillR = math.max(2, math.floor(pillH * 0.26))
    local volts, pct, low = L.txBattery()
    Common.rect(nodes, pillX + pillW, pillY + math.floor(pillH * 0.28), termW,
      math.max(2, math.floor(pillH * 0.44)), C.line, true, 0)
    if pct ~= nil and pct > 0 then
      Common.rect(nodes, pillX + 1, pillY + 1, math.max(1, math.floor((pillW - 2) * pct / 100)), pillH - 2,
        low and C.vtx_low or C.vtx_ok, true, math.max(1, pillR - 2))
    end
    Common.rect(nodes, pillX, pillY, pillW, pillH, C.line, false, pillR, 1)
    local pillFont = Common.selectFont(pillH - 2, pillW - 4, "100%")
    local pillFontH = Common.measure(pillFont, "100%")
    Common.label(nodes, pillX, pillY + math.floor((pillH - pillFontH) / 2), pillW, pillFontH,
      (pct ~= nil) and string.format("%d%%", pct)
        or (volts and string.format("%.1fV", volts) or "--"),
      pillFont, C.pill_ink, CENTER)
    rightLimit = pillX
  end
  if showLink == false then return end

  -- The link bars, stacked: RQ, TQ, the receiver's first antenna and -- once the link has shown
  -- that a second one is there -- the second. Each bar is its reading across the width, with
  -- notches at its warning and critical steps, green / amber / red by those steps (or neutral
  -- while fine, where the pilot chose colour only on warning). The steps are the announcements'
  -- levels: link quality's for both link-quality bars, the RSSI alert's for the signal bars.
  local lqWarn, lqCrit = alertSteps(state, "lq")
  local rsWarn, rsCrit = alertSteps(state, "rssi")
  local bars = {}
  if setting(state, "lq_bar") == "on" then
    bars[#bars + 1] = { read = Common.field(state, "lq"), warn = lqWarn, crit = lqCrit }
  end
  if setting(state, "tq_bar") == "on" then
    bars[#bars + 1] = { read = function()
      local d = state.derived
      return d and num(d.TQly) or nil
    end, warn = lqWarn, crit = lqCrit }
  end
  if setting(state, "rssi_bars") == "on" then
    -- Kept per pair of readings: the bar's colour and its length both ask, every frame, and the
    -- percentage only moves when the reading or the floor does. rssiPercent tests both for a
    -- number itself.
    local function rss(field)
      local lastDbm, lastFloor, lastP = Common.UNSET, Common.UNSET, nil
      return function()
        local d = state.derived
        local dbm, floor = state[field], d and d.link_floor
        if dbm == lastDbm and floor == lastFloor then return lastP end
        lastDbm, lastFloor = dbm, floor
        lastP = rssiPercent(dbm, floor)
        return lastP
      end
    end
    bars[#bars + 1] = { read = rss("rss1"), warn = rsWarn, crit = rsCrit }
    -- The second antenna is a bar only where the host has seen diversity, which is a build-time
    -- reading carried in the render key.
    if L.diversity(state) then
      bars[#bars + 1] = { read = rss("rss2"), warn = rsWarn, crit = rsCrit }
    end
  end
  local n = #bars
  if n == 0 then return end

  -- Always centred on the bar's midline, so the cluster never moves when the clock or the pill
  -- change width; at most 40 % of the bar, and shrunk symmetrically if either side would touch.
  local leftLimit = clockX + clockW + 6
  local mid = x + math.floor(w / 2)
  local half = math.min(mid - leftLimit, (rightLimit - 6) - mid)
  local barW = math.max(8, math.min(2 * half, math.floor(w * 0.40)))
  local barX = mid - math.floor(barW / 2)
  local availH = math.max(n * 2, h - 2)
  local slotH = math.floor(availH / n)
  local barH = math.max(2, slotH - 1)
  local topY = y + math.floor((h - slotH * n) / 2)
  -- Two looks: an outlined track with a fill inset in it where a bar is at least six pixels
  -- tall, a plain filled track below that, which is what a 480x320 screen gets.
  local outlined = barH >= 6
  local good = quietBars and C.neut or C.ok

  -- In full screen, on a host with theme views, the cluster is the tap that opens the link view:
  -- the bars are what that page shows in detail. Everything over the press is then a line rather
  -- than a rectangle, in the same places and colours; the widget zone draws the rectangles it
  -- always drew.
  local asLines = hasViews(ctx)
  if asLines then
    local action = ctx.action
    tapArea(nodes, barX - 2, topY - 1, barW + 4, slotH * n + 1, function() action("openView:grid_link") end)
  end

  for i = 1, n do
    local read, warn, crit = bars[i].read, bars[i].warn, bars[i].crit
    local by = topY + (i - 1) * slotH
    -- Decided once per change of the reading, as the gauge's fill colour is (Common.fuelLevel).
    local lastV, lastColor = Common.UNSET, nil
    local color = function()
      local v = read()
      if v == lastV then return lastColor end
      lastV = v
      if v == nil then lastColor = C.track
      elseif crit and v <= crit then lastColor = C.crit
      elseif warn and v <= warn then lastColor = C.warn
      else lastColor = good end
      return lastColor
    end
    if asLines then
      L.barLines(nodes, barX, by, barW, barH, outlined, warn, crit, read, color)
    elseif outlined then
      local fh, fwMax = barH - 2, barW - 2
      Common.rect(nodes, barX, by, barW, barH, C.frame, false, 2, 1)
      nodes[#nodes + 1] = {
        type = "rectangle", x = barX + 1, y = by + 1, w = 1, h = fh, filled = true, rounded = 1,
        color = color,
        size = barLength(read, fwMax, fh)
      }
      local nh = math.max(2, math.floor(barH * 0.45))
      if crit then
        Common.rect(nodes, barX + math.floor(barW * crit / 100), by + barH - nh, 2, nh, C.tick, true, 0)
        Common.rect(nodes, barX + math.floor(barW * warn / 100), by + barH - nh, 2, nh, C.tick, true, 0)
      end
    else
      Common.rect(nodes, barX, by, barW, barH, C.track, true, 0)
      nodes[#nodes + 1] = {
        type = "rectangle", x = barX, y = by, w = 1, h = barH, filled = true,
        color = color,
        size = function()
          local v = read() or 0
          if v < 0 then v = 0 elseif v > 100 then v = 100 end
          return math.floor(barW * v / 100), barH
        end
      }
      if crit then
        Common.rect(nodes, barX + math.floor(barW * crit / 100), by, 1, barH, C.tick, true, 0)
        Common.rect(nodes, barX + math.floor(barW * warn / 100), by, 1, barH, C.tick, true, 0)
      end
    end
  end
end

-- One link bar drawn in lines, for the full screen tap cluster above: the same track, fill,
-- notches and outline as the rectangles, at the same coordinates. A line's `y` is its middle
-- and its `h` its thickness; the fill is an `hline` whose reactive `size` is its length.
local function vline(nodes, x, y1, y2, color, thickness)
  nodes[#nodes + 1] = { type = "line", x = 0, y = 0, w = 0, h = 0,
    pts = { { x, y1 }, { x, y2 } }, color = color, thickness = thickness }
end

function L.barLines(nodes, barX, by, barW, barH, outlined, warn, crit, read, color)
  local x0, fw, fh = barX, barW, barH
  if outlined then x0, fw, fh = barX + 1, barW - 2, barH - 2 end
  if not outlined then
    nodes[#nodes + 1] = { type = "hline", x = barX, y = by + math.floor(barH / 2), w = barW, h = barH,
      color = C.track }
  end
  nodes[#nodes + 1] = {
    type = "hline", x = x0, y = (outlined and by + 1 or by) + math.floor(fh / 2), w = 1, h = fh,
    color = color,
    size = barLength(read, fw, fh)
  }
  if outlined then
    local nh = math.max(2, math.floor(barH * 0.45))
    if crit then
      vline(nodes, barX + math.floor(barW * crit / 100) + 1, by + barH - nh, by + barH - 1, C.tick, 2)
      vline(nodes, barX + math.floor(barW * warn / 100) + 1, by + barH - nh, by + barH - 1, C.tick, 2)
    end
    local x1, y1 = barX + barW - 1, by + barH - 1
    local edges = {
      { { barX, by }, { x1, by } }, { { barX, y1 }, { x1, y1 } },
      { { barX, by }, { barX, y1 } }, { { x1, by }, { x1, y1 } },
    }
    for i = 1, 4 do
      nodes[#nodes + 1] = { type = "line", x = 0, y = 0, w = 0, h = 0, pts = edges[i],
        color = C.frame, thickness = 1 }
    end
  else
    if crit then
      vline(nodes, barX + math.floor(barW * crit / 100), by, by + barH - 1, C.tick, 1)
      vline(nodes, barX + math.floor(barW * warn / 100), by, by + barH - 1, C.tick, 1)
    end
  end
end

-- Whether the host has seen a second receiver antenna: its `link_diversity` reading, which it
-- latches for the link. A build-time reading, and a term of the render key, so the fourth bar
-- appears with a rebuild once the host has seen the second antenna.
function L.diversity(state)
  local d = state and state.derived
  local v = d and d.link_diversity
  return v == true or (type(v) == "number" and v ~= 0)
end

-- ---------------------------------------------------------------------------
-- the value catalogue the six slots choose from
-- ---------------------------------------------------------------------------

local function intGetter(field)
  return function(state)
    return Common.getter(Common.field(state, field), Common.integer)
  end
end

local function decimalGetter(field, places)
  return function(state)
    return Common.scaledGetter(Common.field(state, field), places)
  end
end

-- A reading that is not a fixed field of the host's state but a DERIVED one: the host resolves
-- it into `state.derived` under its own name, and only for a theme that has declared it. The
-- table is indexed per call and never captured, because the host replaces the snapshot rather
-- than filling the one a build happened to see.
local function derivedGetter(source, format)
  return function(state)
    return Common.getter(function()
      local d = state.derived
      return d and d[source] or nil
    end, format)
  end
end

-- A reading straight off one of the radio's telemetry sensors, by the name EdgeTX gives it. The
-- host has no field for these: naming the sensor as a source makes it resolve the name with
-- `getValue` on its own pass (objects/common.lua, Utils.mapTelemetrySource, which falls through to
-- the sensor module's direct lookup), and the closure reads the snapshot. `places` is the number
-- of decimals drawn. The telemetry view's range for such a reading is the radio's own least and
-- most of the sensor since its last telemetry reset -- the `-` and `+` forms of the same name --
-- because the flight record keeps none of them.
local function rawSource(id, label, sensor, unit, sample, places)
  local format
  if places == 0 then
    format = Common.integer
  else
    format = function(v) return Common.decimals(v, places) end
  end
  return { id = id, label = label, unit = unit, sample = sample, source = sensor, rawRange = true,
    places = places, make = derivedGetter(sensor, format) }
end

-- Every source reads a state field the runtime's telemetry pass fills; nothing here probes.
-- `list` is the configure page's order, `id` the cfg value it stores, `label` the tile's caption
-- as a translation marker -- the configure page lists it as the option and the tile draws it, so
-- the two cannot name a reading differently. This list is the one
-- extension point a new value needs: `make` returns the tile's reactive getter over `state`,
-- `color` (optional) its reactive colour, `sample` the widest string the font is picked against.
--
-- `source` (optional) is the name the HOST knows the reading by, and it is what L.sources below
-- adds for a tile a pilot chose. An entry without one reads a fixed field of the state and costs
-- the host nothing to supply; an entry with one is a reading the host resolves only because this
-- theme asked for it, so the slot half of the list is built from the slots a pilot actually chose
-- that get a cell. None of the default slots carries a `source`; the readings the theme declares whatever
-- the slots say are listed in L.sources, with the reason for each.
--
-- `minKey` / `maxKey` (optional) name the flight record's extremes of the reading
-- (tasks/events/telemetry/flight_record.lua, FLIGHT_STATS), which the telemetry view prints under
-- the figure at `places` decimals. A side the record does not keep is absent and prints `-`; a
-- reading with neither is not in the record at all and its tile has no range line.
L.SOURCES = {
  { id = "cell_voltage", label = "@i18n(widgets.dashboard.urban_cell_voltage)@", unit = "V", sample = "4.20",
    minKey = "minVoltage", maxKey = "maxVoltage", places = 2, perCell = true,
    make = function(state)
      -- The cell count is a render key term, so it is a constant of this build. Common.cells
      -- answers a count even when the host has none (from the configured full-pack voltage), so
      -- whether the count is KNOWN is read live: a pack voltage divided by a guessed count is not a
      -- cell voltage, and the row shows "-" until the host has a count.
      local cells = Common.cells(state)
      return Common.scaledGetter(function()
        local v = num(state.voltage)
        if v == nil or v <= 0 then return nil end
        local known = num(state.batteryCellCount)
        if known == nil or known <= 0 then return nil end
        return v / cells
      end, 2)
    end,
    -- The one coloured row: below the theme's own minimum the figure turns, the same
    -- bounds the gauge is scaled by.
    color = function(state)
      return function()
        -- The pack being gone outranks the pack being low: the figure beside this colour is
        -- no longer a measurement of the main pack at all.
        if state.mainPowerLost == true then return C.crit end
        -- No cell count, no cell voltage to judge: the row shows "-" and is not coloured.
        local known = num(state.batteryCellCount)
        if known == nil or known <= 0 then return C.text end
        local v = num(state.voltage)
        local cfg = state.themeConfig
        local vMin = cfg and num(cfg.v_min) or nil
        if v ~= nil and v > 0 and vMin ~= nil and v < vMin then return C.crit end
        return C.text
      end
    end },
  { id = "voltage", label = "@i18n(app.pages.logs.voltage_title)@", unit = "V", sample = "99.9", make = decimalGetter("voltage", 1),
    minKey = "minVoltage", maxKey = "maxVoltage", places = 1,
    -- The pack voltage turns with the battery panel and the status bar when the main pack is
    -- gone. This reading has no minimum of its own -- the cell figure is the one the theme's configured
    -- bounds apply to -- so this is its only colour.
    color = function(state) return Common.packColor(state, C.text) end },
  { id = "rpm", label = "@i18n(app.pages.logs.rpm_title)@", unit = "rpm", sample = "9999", make = intGetter("rpm"),
    minKey = "minRpm", maxKey = "maxRpm", places = 0 },
  { id = "current", label = "@i18n(app.pages.logs.current_title)@", unit = "A", sample = "999.9", make = decimalGetter("current", 1),
    minKey = "minCurrent", maxKey = "maxCurrent", places = 1 },
  -- The two temperature rows are the only ones with a ladder a pilot sets: the colour comes from
  -- the `temp_colors` row of the settings page, which answers nil while it is off -- so the row
  -- then carries no colour closure at all and the setting costs nothing per frame. common.lua
  -- holds the ladders and the reasoning for their being one row rather than four.
  { id = "esc_temp", label = "@i18n(app.pages.logs.temp_title)@", unit = "C", sample = "9999", make = intGetter("escTemp"),
    minKey = "minEscTemp", maxKey = "maxEscTemp", places = 0,
    color = function(state) return Common.tempColor(setting(state, "temp_colors"), state, "esc", "escTemp") end },
  { id = "mcu_temp", label = "@i18n(widgets.dashboard.urban_mcu_temp)@", unit = "C", sample = "9999", make = intGetter("mcuTemp"),
    maxKey = "maxMcuTemp", places = 0,
    color = function(state) return Common.tempColor(setting(state, "temp_colors"), state, "mcu", "mcuTemp") end },
  { id = "bec_voltage", label = "@i18n(widgets.dashboard.urban_bec_voltage)@", unit = "V", sample = "99.99",
    make = decimalGetter("bec_voltage", 2), minKey = "minBecVoltage", maxKey = "maxBecVoltage", places = 2 },
  { id = "watts", label = "@i18n(app.pages.logs.tpl_power)@", unit = "W", sample = "8888", make = intGetter("watts"),
    maxKey = "maxWatts", places = 0 },
  { id = "throttle", label = "@i18n(app.pages.logs.throttle_title)@", unit = "%", sample = "888", make = intGetter("throttlePercent"),
    maxKey = "maxThrottlePercent", places = 0 },
  -- The fuel row reads what the gauge reads: nothing until the host has seen a fuel reading.
  { id = "fuel", label = "@i18n(app.pages.settings_audio_events.section_fuel)@", unit = "%", sample = "888",
    minKey = "minFuel", places = 0,
    make = function(state)
      return Common.getter(function() return Common.fuel(state) end, Common.integer)
    end },
  { id = "consumed", label = "@i18n(widgets.dashboard.urban_used)@", unit = "mAh", sample = "8888", make = intGetter("consumedMah"),
    maxKey = "maxConsumedMah", places = 0 },
  { id = "altitude", label = "@i18n(widgets.dashboard.urban_altitude)@", unit = "m", sample = "888.8",
    make = decimalGetter("altitude", 1), maxKey = "maxAltitude", places = 1 },
  { id = "link", label = "@i18n(app.pages.logs.tpl_link)@", unit = "%", sample = "888", make = intGetter("lq"),
    minKey = "minLq", maxKey = "maxLq", places = 0 },

  -- The readings below are the host's DERIVED ones. Each names the source it needs, and
  -- L.sources declares exactly those of them a pilot has put in a row.

  -- The current as a percentage of the limit the speed controller is set to allow: a figure a
  -- pilot can judge without knowing the controller. Where no limit is on file the host resolves
  -- it to nil and the row reads "-", which is the state every model is in until the limit has
  -- been typed in or read off the controller -- which is why this is an option and not a
  -- default. The interesting part is above 100, so the row is not clamped to it.
  { id = "esc_load", label = "@i18n(widgets.dashboard.urban_esc_load)@", unit = "%", sample = "888", source = "esc_load",
    make = derivedGetter("esc_load", Common.integer) },

  -- The speed controller's health in words. Two properties decide how it is drawn: the reading
  -- is the WORST the controller has reported since the flight controller connected rather than
  -- what it is reporting this second -- a fault the controller has since cleared is still why a
  -- flight ended early -- and it is a translated string, which is why the colour comes from a
  -- second reading rather than from a threshold on the text.
  --
  -- THIS TILE KEEPS THE RECORD, AND THE STATUS BAR DELIBERATELY DOES NOT. The host publishes
  -- both readings; the bar takes `esc_status_live` and this tile takes `esc_status`, so on a
  -- controller that faulted and recovered the two say different things at the same time.
  -- That is the design and not a bug to tidy away: the bar answers "what is wrong now" and would
  -- be lying if it held a withdrawn alarm, while this tile answers "what has this flight seen" and
  -- would be useless if it forgot the fault that ended the flight. Changing either one to match
  -- the other destroys a reading nothing else on the screen provides.
  --
  -- Truncated at build-time-fixed length rather than sized against the longest status there is:
  -- the longest of them is three times the width of this column, and a font picked against it
  -- would make the row unreadable for the ninety-nine passes out of a hundred that say nothing
  -- is wrong. One cut per value change, in the format path, never per frame.
  -- The sample is not a word, and that is deliberate: the row cuts its string at twelve
  -- characters and every string it can be handed is capitals, so a sample spelled as a word
  -- would measure a mixed-case string of that length and the row would clip after its own
  -- truncation. Twelve of the widest capital is the bound the cut actually guarantees. It costs
  -- this row a font class -- the sample is wider than any real status of that length -- and a
  -- row of words reads perfectly well one class down, where a clipped one does not read at all.
  { id = "esc_status", label = "@i18n(widgets.dashboard.urban_esc_status)@", unit = "", sample = "WWWWWWWWWWW.",
    source = "esc_status",
    make = derivedGetter("esc_status", function(v)
      if type(v) ~= "string" or v == "" then return "-" end
      if #v > 12 then return string.sub(v, 1, 11) .. "." end
      return v
    end),
    -- 1 nothing wrong, 2 a warning, 3 a fault, nil where nothing answered. Naming either of the
    -- pair declares both on the host's side, so this closure costs no second sensor read.
    color = function(state)
      return function()
        local d = state.derived
        local level = d and d.esc_status_level
        if level == 3 then return C.crit end
        if level == 2 then return C.warn end
        return C.text
      end
    end },

  -- The air rate the link is running, spelled as ExpressLRS spells it. It is the transmitter
  -- module's own enumeration and the frame does not say whose: on a link that is not
  -- ExpressLRS, or on a receiver older than the 4.x numbering, the row names a rate that is not
  -- being run. That is why it is an option a pilot turns on rather than a default.
  { id = "link_rate", label = "@i18n(widgets.dashboard.urban_air_rate)@", unit = "", sample = "100Hz Full",
    source = "link_packet_rate",
    make = derivedGetter("link_packet_rate", function(v)
      if type(v) ~= "string" or v == "" then return "-" end
      return v
    end) },

  -- The receiver sensitivity that rate is specified down to, in dBm and negative. It is the
  -- floor as ExpressLRS states it. The row shows the floor itself; the RSSI bars in the top bar
  -- draw the headroom above it.
  { id = "link_floor", label = "@i18n(widgets.dashboard.urban_rate_floor)@", unit = "dBm", sample = "-888",
    source = "link_floor",
    make = derivedGetter("link_floor", Common.integer) },

  -- Readings the host has no field for, straight off the radio's telemetry sensors (rawSource
  -- above). Each costs the host a sensor read per telemetry pass only while a row or a tile shows
  -- it, and a tile showing it two more for its range. The names are the ones the suite's own
  -- decoder creates (lib/rf2tlm_sensors.lua); TQly, TPWR and RSNR are the link's own.
  rawSource("bec_temp", "@i18n(widgets.dashboard.urban_bec_temp)@", "Tbec", "C", "999", 0),
  rawSource("tail_speed", "@i18n(widgets.dashboard.urban_tail_speed)@", "Tspd", "rpm", "9999", 0),
  rawSource("vario", "@i18n(widgets.dashboard.urban_vario)@", "Var", "m/s", "-99.9", 1),
  rawSource("tq", "@i18n(widgets.dashboard.urban_tq)@", "TQly", "%", "888", 0),
  rawSource("tx_power", "@i18n(widgets.dashboard.urban_tx_power)@", "TPWR", "mW", "8888", 0),
  rawSource("esc_bec_temp", "@i18n(widgets.dashboard.urban_esc_bec_temp)@", "BecT", "C", "999", 0),
  rawSource("bec_current", "@i18n(widgets.dashboard.urban_bec_current)@", "Ibec", "A", "99.9", 1),
  rawSource("esc_voltage", "@i18n(widgets.dashboard.urban_esc_voltage)@", "EscV", "V", "99.99", 2),
  rawSource("esc_current", "@i18n(widgets.dashboard.urban_esc_current)@", "EscI", "A", "999.9", 1),
  rawSource("esc_used", "@i18n(widgets.dashboard.urban_esc_used)@", "EscC", "mAh", "8888", 0),
  rawSource("esc_rpm", "@i18n(widgets.dashboard.urban_esc_rpm)@", "EscR", "rpm", "99999", 0),
  rawSource("esc_pwm", "@i18n(widgets.dashboard.urban_esc_pwm)@", "EscP", "%", "100.0", 1),
  rawSource("esc_telem_load", "@i18n(widgets.dashboard.urban_esc_telem_load)@", "Esc%", "%", "100.0", 1),
  rawSource("gps_sats", "@i18n(widgets.dashboard.urban_gps_sats)@", "Sats", "", "88", 0),
  rawSource("gps_speed", "@i18n(widgets.dashboard.urban_gps_speed)@", "GSpd", "m/s", "99.9", 1),
  rawSource("gps_alt", "@i18n(widgets.dashboard.urban_gps_alt)@", "GAlt", "m", "888.8", 1),
  rawSource("gps_dist", "@i18n(widgets.dashboard.urban_gps_dist)@", "GDis", "m", "8888", 0),
  rawSource("pitch", "@i18n(widgets.dashboard.urban_pitch)@", "Ptch", "deg", "-180", 0),
  rawSource("roll", "@i18n(widgets.dashboard.urban_roll)@", "Roll", "deg", "-180", 0),
  rawSource("yaw", "@i18n(widgets.dashboard.urban_yaw)@", "Yaw", "deg", "-180", 0),
  rawSource("cpu_load", "@i18n(widgets.dashboard.urban_cpu_load)@", "CPU%", "%", "888", 0),
  rawSource("sys_load", "@i18n(widgets.dashboard.urban_sys_load)@", "SYS%", "%", "888", 0),
  rawSource("rt_load", "@i18n(widgets.dashboard.urban_rt_load)@", "RT%", "%", "888", 0),
  rawSource("bus_voltage", "@i18n(widgets.dashboard.urban_bus_voltage)@", "Vbus", "V", "99.99", 2),
  rawSource("mcu_voltage", "@i18n(widgets.dashboard.urban_mcu_voltage)@", "Vmcu", "V", "9.99", 2),
  rawSource("rsnr", "@i18n(widgets.dashboard.urban_rsnr)@", "RSNR", "dB", "-88", 0),

  -- The board's state and the flight's own figures: the governor, the three profiles, the
  -- flight time and the flight controller's totals. None of them is in the flight record, so a
  -- tile of the telemetry view showing one has no range line.
  { id = "governor", label = "@i18n(app.pages.logs.tpl_governor)@", unit = "", sample = Common.governorSample(),
    make = function(state) return Common.governorText(state) end },
  { id = "profile", label = "@i18n(widgets.dashboard.urban_profile)@", unit = "", sample = "8",
    make = intGetter("profile") },
  { id = "rate_profile", label = "@i18n(widgets.dashboard.urban_rate)@", unit = "", sample = "8",
    make = intGetter("rateProfile") },
  { id = "battery_profile", label = "@i18n(widgets.dashboard.urban_battery_profile)@", unit = "", sample = "8",
    make = intGetter("batteryProfile") },
  { id = "flight_time", label = "@i18n(app.pages.logs.flight_duration)@", unit = "", sample = "88:88",
    make = function(state) return Common.getter(Common.field(state, "flightSeconds"), Common.duration) end },
  { id = "total_time", label = "@i18n(widgets.dashboard.urban_total_time)@", unit = "", sample = "999:59:59",
    make = function(state) return Common.getter(Common.field(state, "totalFlightSeconds"), Common.longDuration) end },
  { id = "flights", label = "@i18n(widgets.dashboard.urban_flights)@", unit = "", sample = "8888",
    make = intGetter("flights") },

  { id = "none", label = "@i18n(widgets.dashboard.urban_off)@", unit = "", sample = "8888",
    make = function() return function() return "" end end },
}

local SOURCES_BY_ID = {}
for i = 1, #L.SOURCES do SOURCES_BY_ID[L.SOURCES[i].id] = L.SOURCES[i] end

-- The defaults: headspeed, current, ESC temperature, BEC and power in the first five cells of the
-- default 3 x 2 grid, the sixth slot off so the extra tile takes the last cell. The battery panel
-- beside the grid already carries the pack. ESC load is offered and not a default: it reads "-"
-- on every model whose controller limit is not on file.
L.DEFAULT_SLOTS = { "rpm", "current", "esc_temp", "bec_voltage", "watts", "none" }

-- The telemetry view's tiles (telemview.lua), chosen on the Telemetry settings page from the same
-- catalogue as the six slots. Up to twelve, three to a row; a tile set to `none` is left out and
-- the others close up. Nine are on by default, the pack, the drive and the electronics, so a
-- page nobody has configured is already worth opening.
L.TILE_COUNT = 12
L.DEFAULT_TILES = {
  "voltage", "cell_voltage", "current",
  "consumed", "fuel", "rpm",
  "esc_temp", "mcu_temp", "bec_voltage",
  "none", "none", "none",
}

-- What this theme asks the host to resolve for it.
--
-- A free-form theme declares no boxes, so the host has nothing to walk for the readings its
-- closures want: this list is the only way any of them reaches `state.derived`. It is read on
-- every theme load and again on every phase change, with the module being drawn -- which is why
-- it belongs to the flight view and not to the statistics one. The statistics view reads the
-- flight record, so a reading a pilot put on the flight screen costs nothing once the flight is
-- over; the two link figures of its bottom bar are the exception, with a list of their own
-- (L.STATS_SOURCES).
--
-- Two halves. The readings the flight view draws whatever the slots say:
--
--   esc_status_live, esc_status_live_level   the speed controller's LIVE status, which the
--                                            status bar and the status view read. Declared
--                                            unconditionally: a declaration built from the slots
--                                            alone would leave it unresolved on every radio
--                                            whose pilot has not put it in a tile, and the bar would then say
--                                            nothing for a reason no pilot could ever see.
--   TQly, TPWR                               the transmitter's link quality and power, for the
--                                            TQ bar and the status bar.
--   link_floor                               the sensitivity floor of the air rate, which the
--                                            signal bars measure their headroom against.
--   link_diversity                           whether a second antenna has been seen.
--   *Skp                                     the skipped-frame count, which the suite publishes
--                                            itself (tasks/events/telemetry_bg/drain.lua,
--                                            setTelemetryValue 0xEE02). A bare `Skp` is not
--                                            declared: no current source creates it, and an
--                                            absent name is still a read on every pass.
--
-- And the `source` of each tile a pilot put in one of the slots that get a cell.
--
-- BOTH names of the live pair are declared, and the second one is not redundant even though the
-- host pairs them itself: that pairing runs as a pass over the collected list, so it only sees a
-- declaration collected BEFORE it. If the order of those two steps ever reversed, the level would
-- go undeclared, the severity would arrive as nil, and the status bar would fall back to the
-- arm state on a model with a faulty controller, with nothing going red. Naming it costs a table entry the
-- host would have added anyway, and it turns an ordering assumption into no assumption at all.
--
-- `esc_status` -- the worst reading since the flight controller connected -- is NOT in the first
-- half. It is the ESC Status tile's reading, so it arrives through the slot loop when a
-- pilot selects that tile, and a pilot who has not selected it does not pay for it.
--
-- That is a cost on the HOST, per snapshot, and it is stated rather than hidden: each name is
-- resolved on every snapshot, an absent one is searched again on the host's back-off of 2 s
-- rising to 30 s, and `link_floor` makes the host ask the transmitter module once per link which
-- ExpressLRS generation it runs. A host without `sources` support resolves none of it, and those
-- tiles read "-" while the status bar falls through to the arming reasons and the arm state.
--
-- Duplicates are dropped here rather than left to the host: two slots showing one reading is a
-- thing a pilot can do, and the list is a declaration, not a count.
local ALWAYS_DECLARED = {
  "esc_status_live", "esc_status_live_level",
  "TQly", "TPWR", "link_floor", "link_diversity", "*Skp",
}

function L.sources(state)
  state = state or {}
  local list, seen = {}, {}
  for i = 1, #ALWAYS_DECLARED do
    list[i] = ALWAYS_DECLARED[i]
    seen[ALWAYS_DECLARED[i]] = true
  end
  -- Only the slots the grid size leaves a cell (L.placedSlots): a slot past the last cell is not
  -- drawn, and a reading nothing draws is not worth a resolve on every snapshot.
  local slots = L.placedSlots(state, (gridCells(state)))
  for i = 1, #slots do
    local src = slots[i].source
    if src and not seen[src] then
      seen[src] = true
      list[#list + 1] = src
    end
  end
  return list
end

-- What the telemetry view's tiles read beyond the fixed state fields: the `source` of each tile,
-- and for a raw sensor the `-` and `+` forms of its name, the radio's own least and most of it,
-- which only a tile draws. telemview.lua hands this to the host as the view's own `sources`, so
-- they are read while the view is open and at no other time; the flight view's list above names
-- only what the flight view draws. None of the default tiles carries a `source`.
function L.tileSources(state)
  local cfg = (state and state.themeConfig) or {}
  local list, seen = {}, {}
  local function add(name)
    if not seen[name] then
      seen[name] = true
      list[#list + 1] = name
    end
  end
  for i = 1, L.TILE_COUNT do
    local def = SOURCES_BY_ID[cfg["tile" .. i]] or SOURCES_BY_ID[L.DEFAULT_TILES[i]]
    local src = def and def.source
    if src then
      add(src)
      if def.rawRange then
        add(src .. "-")
        add(src .. "+")
      end
    end
  end
  return list
end

-- One extreme of the flight record as a reader for the per-frame sweep: the flight in progress
-- where it has taken a value for the key, the flight that ended otherwise -- the rule the host's
-- own boxes read the record by (objects/common.lua, Utils.statFromRecord). `cells` divides a pack
-- reading down to a cell: the live count for the flight in progress, and for the flight that ended
-- the count of the pack it was flown on where the host took one (Common.flownCells), since a pack
-- plugged in after the landing changes the live count.
local function extremeReader(state, key, cells)
  return function()
    local flight = state.flight
    if type(flight) ~= "table" then return nil end
    local rec = flight.current
    local v = type(rec) == "table" and rec[key] or nil
    local div = cells
    if v == nil then
      rec = flight.last
      v = type(rec) == "table" and rec[key] or nil
      if cells then div = Common.flownCells(state) or cells end
    end
    if type(v) ~= "number" then return nil end
    if div then return v / div end
    return v
  end
end

-- "<least> .. <most>" of the flight record, a side the record does not keep as `-`, formatted once
-- per change of either side.
local function rangeGetter(state, def, cells)
  local readMin = def.minKey and extremeReader(state, def.minKey, cells) or nil
  local readMax = def.maxKey and extremeReader(state, def.maxKey, cells) or nil
  local fmt = "%." .. tostring(def.places or 0) .. "f"
  local lastMin, lastMax, text = Common.UNSET, Common.UNSET, nil
  return function()
    local lo = readMin and readMin() or nil
    local hi = readMax and readMax() or nil
    if lo == lastMin and hi == lastMax then return text end
    lastMin, lastMax = lo, hi
    text = (lo and string.format(fmt, lo) or "-") .. " .. " .. (hi and string.format(fmt, hi) or "-")
    return text
  end
end

-- "<least> .. <most>" of a raw sensor, from the radio's `-` and `+` forms of its name as the host
-- resolved them into the snapshot (L.sources declares both for a tile).
local function rawRangeGetter(state, def)
  local lowName, highName = def.source .. "-", def.source .. "+"
  local fmt = "%." .. tostring(def.places or 0) .. "f"
  local lastMin, lastMax, text = Common.UNSET, Common.UNSET, nil
  return function()
    local d = state.derived
    local lo = d and d[lowName]
    local hi = d and d[highName]
    if type(lo) ~= "number" then lo = nil end
    if type(hi) ~= "number" then hi = nil end
    if lo == lastMin and hi == lastMax then return text end
    lastMin, lastMax = lo, hi
    text = (lo and string.format(fmt, lo) or "-") .. " .. " .. (hi and string.format(fmt, hi) or "-")
    return text
  end
end

-- The telemetry view's tiles, in the order the settings page lists them, without the ones set to
-- `none`. Each is a tile of the flight view's grid -- the same label, unit, figure and colour -- plus
-- `range`, the record's extremes as one string, nil for a reading the record does not keep.
function L.tileRows(state)
  local cfg = state.themeConfig or {}
  local tiles = {}
  local cells = nil
  for i = 1, L.TILE_COUNT do
    local def = SOURCES_BY_ID[cfg["tile" .. i]] or SOURCES_BY_ID[L.DEFAULT_TILES[i]]
    if def and def.id ~= "none" then
      local range = nil
      if def.rawRange then
        range = rawRangeGetter(state, def)
      elseif def.minKey or def.maxKey then
        if def.perCell and cells == nil then cells = Common.cells(state) end
        range = rangeGetter(state, def, def.perCell and cells or nil)
      end
      tiles[#tiles + 1] = {
        label = def.label,
        unit = def.unit,
        sample = def.sample,
        value = def.make(state),
        color = def.color and def.color(state) or nil,
        range = range,
        rangeSample = def.perCell and "4.20 .. 4.20" or (def.sample .. " .. " .. def.sample),
      }
    end
  end
  return tiles
end

-- ---------------------------------------------------------------------------
-- the battery panel and the tile grid
-- ---------------------------------------------------------------------------

-- Which of the six slots get a cell: in slot order, skipping the ones set to `none`, and only as
-- many as the grid has cells -- so a slot set to `none` moves the next one up, and a slot past the
-- last cell is not drawn. The one rule the grid and L.sources both apply, so the declaration
-- cannot name a reading the screen does not show.
local function placedSlots(state, cells)
  local cfg = state.themeConfig or {}
  local slots = {}
  for i = 1, L.SLOT_COUNT do
    if #slots >= cells then break end
    local def = SOURCES_BY_ID[cfg["slot" .. i]] or SOURCES_BY_ID[L.DEFAULT_SLOTS[i]]
    if def and def.id ~= "none" then slots[#slots + 1] = def end
  end
  return slots
end
L.placedSlots = placedSlots

-- A button's children are placed against its content area, which starts inside its padding:
-- `pad_button`, PAD_MEDIUM left and right and PAD_TINY above and below, both scaled by the screen
-- class (radio/src/gui/colorlcd/libui/etx_lv_theme.cpp and etx_lv_theme.h, LAYOUT_SCALE), plus
-- the 2 px frame (PAD_BORDER). A Lua button takes no padding parameter, so a drawing built into
-- one is placed that far up and to the left, and lands where the widget zone draws it.
local function layoutScale(v)
  if LCD_W == 800 then return math.floor((v * 11 + 4) / 8) end
  if LCD_W == 320 then return math.floor((v * 8 + 5) / 10) end
  return v
end
local BUTTON_BORDER = 2
L.buttonInset = function() return layoutScale(6) + BUTTON_BORDER, layoutScale(2) + BUTTON_BORDER end

-- A panel drawn by `draw(into, x, y)`, and in full screen on a host with theme views the press
-- that opens `view`. The battery panel is built of rectangles -- the card, the fill bar, the
-- gauge's segments -- and a rectangle over a press takes it; but a rectangle hands a press it takes on to the object it
-- was built INTO (radio/src/gui/colorlcd/libui/window.cpp, Window::onClicked). So there the panel
-- is built as the children of the button, and a tap anywhere on it reaches the button. The widget
-- zone and a host without theme views draw the panel as it always was.
local function pressable(nodes, x, y, w, h, ctx, view, draw)
  if not hasViews(ctx) then
    draw(nodes, x, y)
    return
  end
  local action = ctx.action
  local at = #nodes + 1
  Common.button(nodes, x, y, w, h, C.bg, function() action(view) end)
  local insetX, insetY = L.buttonInset()
  local inner = {}
  draw(inner, -insetX, -insetY)
  nodes[at].children = inner
end

-- The battery card, laid out from the FOOT upwards so the percentage takes whatever height is
-- left: the fill bar at the foot, the cell voltage above it, and the heading at the top -- the
-- word and the cell count on the left, the capacity used on the right.
--
-- The percentage and the fill bar read the one fuel closure the gauge reads (Common.fuelLevel),
-- so the steps the pilot set, the orange of a pack that was not full when it was plugged in and
-- the empty reading of a main pack that is gone are the same here as on the gauge. The cell
-- voltage is the catalogue's own row, with its rules: "-" until the host knows the cell count,
-- the critical colour below the configured minimum or with the main pack gone.
local function batteryCard(nodes, state, x, y, w, h, g)
  Common.card(nodes, x, y, w, h)
  local ipad = math.max(4, math.min(12, math.floor(w * 0.09)))
  local iw = math.max(8, w - 2 * ipad)
  local lblFont, lblH = g.lblFont, g.lblH
  local headY = y + ipad
  local foot = y + h - ipad

  -- The cell count is a render key term, so the heading is a constant of this build.
  local headW = math.floor(iw * 0.55)
  Common.label(nodes, x + ipad, headY, headW, lblH,
    Common.fitLabel(lblFont, T.view_battery .. " " .. tostring(Common.cells(state)) .. "S", headW),
    lblFont, C.label, LEFT)
  Common.label(nodes, x + ipad + headW, headY, iw - headW, lblH,
    Common.getter(Common.field(state, "consumedMah"), function(v)
      if v == nil then return "- " .. T.mah end
      return string.format("%d ", math.floor(v + 0.5)) .. T.mah
    end), lblFont, C.label, RIGHT)

  local level = Common.fuelLevel(state)
  local barH = math.max(6, math.floor(h * 0.06))
  foot = foot - barH
  Common.hbar(nodes, x + ipad, foot, iw, barH,
    function()
      local p = level()
      return p
    end,
    function()
      local _, color = level()
      return color
    end)
  foot = foot - math.max(3, math.floor(h * 0.03))

  -- The cell row: the word on the left, the figure right-aligned, the unit beside it where the
  -- pilot has the units on. The figure's face is fitted to the room right of the word.
  local cellDef = SOURCES_BY_ID.cell_voltage
  local cellLabelW = Common.textWidth(lblFont, T.cell) + 6
  local unit = (setting(state, "units") == "on") and cellDef.unit or ""
  local unitW = (unit ~= "") and (Common.textWidth(lblFont, unit) + 3) or 0
  local cellFont = Common.selectFont(math.max(8, math.floor(h * 0.10)),
    math.max(8, iw - cellLabelW - unitW), cellDef.sample)
  local cellH = Common.measure(cellFont, cellDef.sample)
  foot = foot - cellH
  local cellLabelY = foot + math.floor((cellH - lblH) / 2)
  Common.label(nodes, x + ipad, cellLabelY, cellLabelW, lblH, T.cell, lblFont, C.label, LEFT)
  if unitW > 0 then
    Common.label(nodes, x + ipad + iw - unitW, cellLabelY, unitW, lblH, unit, lblFont, C.tick, RIGHT)
  end
  Common.label(nodes, x + ipad + cellLabelW, foot, iw - cellLabelW - unitW, cellH,
    cellDef.make(state), cellFont, cellDef.color(state), RIGHT)
  foot = foot - 4

  -- The percentage, centred in whatever is left between the heading and the cell row.
  local pctTop = headY + lblH + 4
  local avail = foot - pctTop
  if avail >= 10 then
    local pctFont = Common.selectFont(avail, iw, "100%")
    local pctH = Common.measure(pctFont, "100%")
    Common.label(nodes, x + ipad, pctTop + math.floor((avail - pctH) / 2), iw, pctH,
      Common.getter(function()
        local p = level()
        return p
      end, function(p)
        if p == nil then return "--%" end
        return string.format("%d%%", math.floor(p + 0.5))
      end), pctFont, Common.packColor(state, C.text), CENTER)
  end
end

-- The battery panel down the left, as the pilot chose it -- the card or the segmented gauge --
-- and in full screen on a host with theme views the press that opens the battery view.
function L.leftPanel(nodes, state, x, y, w, h, ctx, g)
  local mode = setting(state, "left")
  pressable(nodes, x, y, w, h, ctx, "openView:grid_battery", function(into, ox, oy)
    if mode == "gauge" then
      Common.fuelGauge(into, state, ox, oy, w, h)
    else
      batteryCard(into, state, ox, oy, w, h, g)
    end
  end)
end

-- A card's outline. In the widget zone, and on a host without theme views, the rounded rectangle;
-- over a press, four lines in the same colour, because a line takes no press where a rectangle
-- would take it. A tile is a press of its own and its neighbours are presses too, so its outline
-- cannot be built into its button the way the battery panel is: the children of a button are drawn
-- up and to the left of it by the button's padding, into the gap between two tiles.
local function cardOutline(nodes, x, y, w, h, asLines)
  if not asLines then
    Common.card(nodes, x, y, w, h)
    return
  end
  local x1, y1 = x + w - 1, y + h - 1
  local edges = {
    { { x, y }, { x1, y } }, { { x, y1 }, { x1, y1 } },
    { { x, y }, { x, y1 } }, { { x1, y }, { x1, y1 } },
  }
  for i = 1, 4 do
    nodes[#nodes + 1] = { type = "line", x = 0, y = 0, w = 0, h = 0, pts = edges[i], color = C.card, thickness = 1 }
  end
end

-- One tile: the card, the caption at the top with the unit at its right end, and the figure along
-- the foot. A caption wider than its room in a longer language is cut with two dots rather than
-- drawn into the unit; the cut is kept with the zone's other measurements. In full screen, on a
-- host with theme views, the tile is the press that opens the telemetry view -- the tiles are what
-- that page shows more of -- and everything over the press is a label or a line.
local function valueTile(nodes, x, y, w, h, tile, g, ctx)
  local asLines = hasViews(ctx)
  if asLines then
    local action = ctx.action
    tapArea(nodes, x, y, w, h, function() action("openView:grid_telemetry") end)
  end
  cardOutline(nodes, x, y, w, h, asLines)
  local capW = w - 2 * g.hpad
  if tile.unit ~= "" then
    local unitW = Common.textWidth(g.lblFont, tile.unit) + 4
    Common.label(nodes, x + w - g.hpad - unitW, y + g.vpad, unitW, g.lblH, tile.unit, g.lblFont, C.tick, RIGHT)
    capW = math.max(8, capW - unitW - 4)
  end
  Common.label(nodes, x + g.hpad, y + g.vpad, capW, g.lblH, Common.fitLabel(g.lblFont, tile.label, capW),
    g.lblFont, C.label, LEFT)
  Common.label(nodes, x + g.hpad, y + h - g.vpad - g.valH, w - 2 * g.hpad, g.valH, tile.value, g.valFont,
    tile.color or C.text, LEFT)
end

-- The extra tile: the model's picture, top-anchored at its own aspect ratio, or the PID, rate and
-- battery profile numbers side by side. While the host is still waiting for a battery pick on this
-- connection the battery profile's word is drawn in the warn colour; L.renderKey carries `pending`,
-- so the colour follows the prompt.
--
-- In full screen, on a host with theme views, it is the press that opens this theme's own menu --
-- the battery profiles and the tuning surface, which change what the profile numbers show. The
-- picture is then built into that button, against its content area, so a press on it reaches the
-- button whatever the picture does with one.
local function extraTile(nodes, state, x, y, w, h, kind, g, ctx)
  local asLines = hasViews(ctx)
  local at = #nodes + 1
  if asLines then
    local action = ctx.action
    tapArea(nodes, x, y, w, h, function() action("openView:grid_menu") end)
  end
  cardOutline(nodes, x, y, w, h, asLines)
  if kind == "profiles" then
    local pad = 4
    local third = math.floor((w - 2 * pad) / 3)
    local lastW = w - 2 * pad - 2 * third
    local numFont = Common.selectFont(math.max(1, math.min(g.valH, h - g.lblH - 2 * g.vpad)), lastW, "8")
    local numH = Common.measure(numFont, "8")
    local fy = y + math.floor((h - g.lblH - numH) / 2)
    local bp = type(state.batteryPick) == "table" and state.batteryPick or nil
    -- The three words in one face, at most the captions', in which the widest of them fits a
    -- third: the shorter battery profile word where the full one does not fit even the smallest.
    local bpLabel = T.battery_profile
    local widest = T.profile
    if #T.rate > #widest then widest = T.rate end
    if #bpLabel > #widest then widest = bpLabel end
    local capFont = Common.selectFont(g.lblH, lastW, widest, g.lblFont)
    local capH = Common.measure(capFont, widest)
    if Common.textWidth(capFont, bpLabel) > lastW then bpLabel = T.battery_profile_short end
    Common.stacked(nodes, x + pad, fy, third, 0, Common.fitLabel(capFont, T.profile, third),
      Common.getter(Common.field(state, "profile"), Common.integer), capFont, capH, numFont, numH)
    Common.stacked(nodes, x + pad + third, fy, third, 0, Common.fitLabel(capFont, T.rate, third),
      Common.getter(Common.field(state, "rateProfile"), Common.integer), capFont, capH, numFont, numH)
    Common.stacked(nodes, x + pad + 2 * third, fy, lastW, 0, Common.fitLabel(capFont, bpLabel, lastW),
      Common.getter(Common.field(state, "batteryProfile"), Common.integer), capFont, capH, numFont, numH,
      (bp and bp.pending == true) and C.warn or nil)
    return
  end
  local inset = 6
  local iw, ih = math.max(1, w - 2 * inset), math.max(1, h - 2 * inset)
  local path = Common.modelImage(state)
  local imgW, imgH = iw, ih
  local bw, bh = Common.imageSize(path)
  if bw and bh then
    local scale = math.min(iw / bw, ih / bh)
    imgW = math.max(1, math.floor(bw * scale))
    imgH = math.max(1, math.floor(bh * scale))
  end
  local image = { type = "image", x = x + inset + math.floor((iw - imgW) / 2), y = y + inset, w = imgW, h = imgH,
    file = path, fill = false }
  if asLines then
    local insetX, insetY = L.buttonInset()
    image.x, image.y = image.x - x - insetX, image.y - y - insetY
    nodes[at].children = { image }
  else
    nodes[#nodes + 1] = image
  end
end

-- The tile grid: the slots in the cells they are counted into, then the extra tile in the first
-- cell they leave free.
--
-- Every figure shares ONE value face, picked once against the widest numeric sample among the
-- slots that are actually drawn: a row of figures whose faces differ by whichever value happens to
-- be wider reads worse than a row of uniformly smaller ones. A reading that is WORDS -- a governor
-- state, a speed controller's verdict, an air rate -- is not held to it: it takes the largest face
-- up to the shared one in which its own sample fits, so one word tile does not shrink every figure.
local function isFigure(sample)
  return string.find(sample, "^[%d%.%-:]+$") ~= nil
end

function L.tileGrid(nodes, state, x, y, w, h, ctx, lblFont, lblH)
  local cells, cols, rows = gridCells(state)
  local cellW = math.floor((w - (cols - 1) * CARD_GAP) / cols)
  local cellH = math.floor((h - (rows - 1) * CARD_GAP) / rows)
  if cellW < 16 or cellH < lblH + 8 then return end
  local slots = placedSlots(state, cells)
  -- Widest by pixels, not by characters: "-99.9" and "99999" are both five characters, and a
  -- face fitted to the narrower one does not hold the other (a label is not clipped).
  local sample = "8888"
  local sampleW = Common.textWidth(lblFont, sample)
  for i = 1, #slots do
    local s = slots[i].sample
    if isFigure(s) then
      local sw = Common.textWidth(lblFont, s)
      if sw > sampleW then sample, sampleW = s, sw end
    end
  end
  local vpad = math.max(2, math.min(8, math.floor(cellH * 0.07)))
  local hpad = math.max(3, math.min(10, math.floor(cellW * 0.08)))
  local valAvailH = math.max(1, math.min(math.floor(cellH * 0.5), cellH - lblH - 3 * vpad))
  local valFont = Common.selectFont(valAvailH, cellW - 2 * hpad, sample)
  local g = { lblFont = lblFont, lblH = lblH, valFont = valFont, valH = Common.measure(valFont, sample),
    vpad = vpad, hpad = hpad }
  local showUnits = setting(state, "units") == "on"

  for i = 1, #slots do
    local def = slots[i]
    local tile = {
      label = def.label,
      unit = showUnits and (def.unit or "") or "",
      value = def.make(state),
      color = def.color and def.color(state) or nil,
    }
    local tg = g
    if not isFigure(def.sample) then
      local font = Common.selectFont(valAvailH, cellW - 2 * hpad, def.sample, valFont)
      tg = { lblFont = lblFont, lblH = lblH, valFont = font, valH = Common.measure(font, def.sample),
        vpad = vpad, hpad = hpad }
    end
    local cx = x + ((i - 1) % cols) * (cellW + CARD_GAP)
    local cy = y + math.floor((i - 1) / cols) * (cellH + CARD_GAP)
    valueTile(nodes, cx, cy, cellW, cellH, tile, tg, ctx)
  end

  local extra = setting(state, "extra")
  if extra ~= "off" and #slots < cells then
    local cx = x + (#slots % cols) * (cellW + CARD_GAP)
    local cy = y + math.floor(#slots / cols) * (cellH + CARD_GAP)
    extraTile(nodes, state, cx, cy, cellW, cellH, extra, g, ctx)
  end
end

-- ---------------------------------------------------------------------------
-- status bar
-- ---------------------------------------------------------------------------

-- A reading the host resolves only because this theme declared it (L.sources for the flight view,
-- L.STATS_SOURCES for the statistics view): the transmitter module's power and the receiver's
-- skipped-packet count. Nil where nothing answers.
local function derivedNumber(state, name, altName)
  local d = state.derived
  if d == nil then return nil end
  local v = num(d[name])
  if v == nil and altName then v = num(d[altName]) end
  return v
end

local function labelled(label, read, fmt)
  return Common.getter(read, function(v)
    if v == nil then return label .. ": -" end
    return label .. ": " .. string.format(fmt, v)
  end)
end

-- The arming override: while the flight controller names reasons that block arming, the whole
-- bar gives way to "Arming Disabled: <reason>", one reason at a time, two seconds each, in the
-- WARNING colour. The returned function is the visibility the bar's ordinary labels take in the
-- meantime. getTime is the radio's tick counter, not one of the probes a closure may not make.
--
-- Common.label cuts nothing, and "Arming Disabled: " with the longest reason is wider than the
-- bar in a longer language and on a small screen. The texts are a bounded set of constants -- the
-- prefix and the twenty-six reason names of the package's language -- so each one is fitted to
-- the bar HERE, at build time, through Common.fitLabel, whose answers are kept with the zone's
-- other measurements. The closure below only looks the fitted text up and makes no firmware call.
--
-- The fitted texts depend on nothing but the face and the width, so the set of the last build
-- is kept and handed to the next one that asks for the same pair. A rebuild in the same zone
-- then joins and looks up none of the twenty-six texts again.
local armingFit = { font = nil, w = nil, texts = nil }

local function armingTexts(font, textW)
  if armingFit.texts ~= nil and armingFit.font == font and armingFit.w == textW then
    return armingFit.texts
  end
  local fitted = {}
  local names = Common.armFlagNames()
  for i = 1, #names do
    local name = names[i]
    if name ~= nil and fitted[name] == nil then
      fitted[name] = Common.fitLabel(font, T.arming_disabled .. name, textW)
    end
  end
  armingFit.font, armingFit.w, armingFit.texts = font, textW, fitted
  return fitted
end

local function armingOverride(nodes, state, x, y, w, fontH, font)
  local list = Common.armDisableList(state)
  local textW = w - 2 * CARD_PAD
  local fitted = armingTexts(font, textW)
  local index, since, lastList, lastText, lastName = 1, nil, nil, "", nil
  Common.label(nodes, x + CARD_PAD, y, textW, fontH, function()
    local l = list()
    if l == nil then
      since, lastList = nil, nil
      return ""
    end
    local now = getTime()
    if l ~= lastList then
      lastList, index, since = l, 1, now
    elseif now - since >= 200 then
      index, since = (index % #l) + 1, now
    end
    local name = l[index]
    if name ~= lastName then
      lastName = name
      lastText = fitted[name] or (T.arming_disabled .. tostring(name))
    end
    return lastText
  end, font, C.warning, LEFT)
  return function() return list() == nil end
end

-- What the middle of the flight view's bar says, and in which colour, as ONE closure the text node
-- and the colour node both ask. The arm state, unless something outranks it:
--
--   main power lost      over everything: the board answers on its BEC and nothing else on the
--                        screen looks wrong.
--   speed controller     its LIVE verdict where it reports a warning or a fault, in that level's
--                        colour, while a flight controller answers. "OK" is not worth the arm
--                        state's place, and a fault the controller has cleared is not shown --
--                        the ESC Status tile keeps the record (L.SOURCES).
--   arm state            ARMED / DISARMED in the colours the pilot chose, "No FC connected"
--                        muted.
--
-- The arming reasons are not here: while any are named the whole bar gives way to them
-- (armingOverride). `capChars` is the number of characters the caller measured the middle to
-- hold; the cut is made once per change of the text, never per frame.
local function stateCell(state, capChars)
  local armedText, armedColor = Common.armedText(state), Common.armedColor(state)
  local lastRaw, lastCut = nil, ""
  local function fit(raw)
    if #raw <= capChars then return raw end
    if raw ~= lastRaw then
      lastRaw = raw
      lastCut = Common.cutUtf8(raw, capChars - 1) .. "."
    end
    return lastCut
  end
  return function()
    if state.mainPowerLost == true then return fit(T.main_power_lost), C.crit end
    if state.rfConnected == true then
      local derived = state.derived
      local level = derived and derived.esc_status_live_level or nil
      local esc = derived and derived.esc_status_live or nil
      if type(esc) == "string" and esc ~= "" and type(level) == "number" and level >= 2 then
        if level >= 3 then return fit(esc), C.crit end
        return fit(esc), C.warn
      end
    end
    return armedText(), armedColor()
  end
end

-- The flight view's bar: "Model: <name>" in the left 46 %, the state centred on the whole bar
-- (stateCell), the transmitter power right-aligned in the next 24 % and the skipped-packet count
-- in the last 16 %. In full screen, on a host with theme views, the bar is the tap that opens the
-- status view, which says more about all of it; drawn first, so everything on the bar lies over it.
function L.statusBar(nodes, state, x, y, w, h, font, fontH, ctx)
  local textY = y + math.floor((h - fontH) / 2)
  if hasViews(ctx) then
    local action = ctx.action
    tapArea(nodes, x, y, w, h, function() action("openView:grid_status") end)
  end
  local shown = armingOverride(nodes, state, x, textY, w, fontH, font)
  local modelW = math.floor(w * 0.46)
  local skpW = math.floor(w * 0.16)
  local tpwrW = math.floor(w * 0.24)
  local name = Common.modelName(state)
  local last, text = nil, nil
  local nodesBefore = #nodes
  Common.label(nodes, x + CARD_PAD, textY, math.max(1, modelW - 2 * CARD_PAD), fontH, function()
    local n = name()
    if n ~= last then last, text = n, T.model_prefix .. n end
    return text
  end, font, C.text, LEFT)
  -- The middle is held to the middle 40 % of the bar, the room a short model name leaves it,
  -- measured against a word of ordinary capitals: the speed controller's verdicts are capitals.
  local CAPS_SAMPLE = "BOOTGRACE"
  local capChars = math.max(6, math.floor(math.floor(w * 0.40) * #CAPS_SAMPLE
    / math.max(1, Common.textWidth(font, CAPS_SAMPLE))))
  local cell = stateCell(state, capChars)
  Common.label(nodes, x, textY, w, fontH,
    function()
      local said = cell()
      return said
    end, font,
    function()
      local _, color = cell()
      return color
    end, CENTER)
  if setting(state, "tpwr") == "on" then
    Common.label(nodes, x + w - skpW - tpwrW, textY, tpwrW, fontH,
      labelled(T.tpwr, function() return derivedNumber(state, "TPWR") end, "%dmW"),
      font, C.text, RIGHT)
  end
  Common.label(nodes, x + w - skpW, textY, skpW - CARD_PAD, fontH,
    labelled(T.skp, function() return derivedNumber(state, "*Skp") end, "%d"),
    font, C.text, RIGHT)
  for i = nodesBefore + 1, #nodes do nodes[i].visible = shown end
end

-- The readings the statistics view's bar takes from the host's snapshot, which holds only what
-- the phase module standing names: postflight.lua hands the host this list. While the flight
-- controller still answers, the two cells follow the link. Once it stops, the host rebuilds the
-- snapshot only on a theme load (widgets/dashboard/runtime.lua, `isPostflightOffline`,
-- reloadActiveTheme), so they keep the reading taken last: the last one the link delivered, or
-- what the radio still holds for the sensor where the statistics view loaded after the link had
-- gone.
L.STATS_SOURCES = { "TPWR", "*Skp" }

-- The statistics view's bar, four link and board figures in four equal cells: the transmitter
-- power, the least link quality, the hottest the flight controller got, and the skipped packets.
-- The host keeps no record of the power, so that cell is the reading the link delivered last,
-- under the flight view's label rather than one marked as a maximum. The power and the skipped
-- packets are the snapshot's (L.STATS_SOURCES above).
function L.statsStatusBar(nodes, state, x, y, w, h, font, fontH, lastStat)
  local textY = y + math.floor((h - fontH) / 2)
  local shown = armingOverride(nodes, state, x, textY, w, fontH, font)
  local item = math.floor(w / 4)
  local nodesBefore = #nodes
  Common.label(nodes, x, textY, item, fontH,
    labelled(T.tpwr_stat, function() return derivedNumber(state, "TPWR") end, "%dmW"),
    font, C.text, CENTER)
  Common.label(nodes, x + item, textY, item, fontH,
    labelled(T.rqly_min, function() return num(lastStat(state, "minLq", "lastMinLq")) end, "%d%%"),
    font, C.text, CENTER)
  Common.label(nodes, x + 2 * item, textY, item, fontH,
    labelled(T.mcu_max, function() return num(lastStat(state, "maxMcuTemp", "lastFlightMaxMcuTemp")) end, "%.0f°C"),
    font, C.text, CENTER)
  Common.label(nodes, x + 3 * item, textY, w - 3 * item, fontH,
    labelled(T.skp, function() return derivedNumber(state, "*Skp") end, "%d"),
    font, C.text, CENTER)
  for i = nodesBefore + 1, #nodes do nodes[i].visible = shown end
end

-- ---------------------------------------------------------------------------
-- the flight view
-- ---------------------------------------------------------------------------

-- Four zones: the top bar, the battery panel down the left, the tile grid beside it, the status
-- bar at the foot. The battery panel takes the share of the content width the pilot chose, and
-- never so much that the grid is left less than 40 px -- in a narrow widget zone an uncapped share
-- would give the grid a negative width. With the panel off the grid takes the whole width, and
-- with the status bar off the whole height below the top bar.
--
-- Both bars are 7.5 % of the height (at least 18 px), their boxes two pixels shorter, and
-- nothing is reserved for controls: the two controls this theme draws sit inside the top bar.
-- The captions of the tiles and the battery card follow the SCREEN, not the cell, so every
-- caption on the panel is set in one face.
function L.buildFlight(zone, state, ctx)
  local nodes = {}
  local x0, y0, w, h = zone.x or 0, zone.y or 0, zone.w or 0, zone.h or 0
  if w <= 0 or h <= 0 then return nodes end
  -- The scheme FIRST, before a single node is appended: every colour below, in a node and in
  -- a closure alike, is then the one the pilot chose. It is a build-time reading and needs no
  -- term in the render key -- the host reloads the theme when its preferences change.
  Common.applyScheme((state.themeConfig or {}).scheme)
  Common.applyFrames(state.themeConfig)
  Common.beginBuild(zone)
  L.bindKeys(state, ctx)

  local barH = math.max(18, math.floor(h * 0.075))
  local boxH = math.max(1, barH - 2)
  local font = Common.selectFont(boxH, nil, "Total Time")
  local fontH = Common.measure(font, "Total Time")
  local lblFont = Common.selectFont(math.max(1, math.floor(h * 0.045)), nil, "Ag")
  local lblH = Common.measure(lblFont, "Ag")

  local showStatus = setting(state, "status_bar") == "on"
  local contentW = w - 2 * OUTER_PAD
  local yContent = y0 + OUTER_PAD + barH + CARD_GAP
  local statusH = showStatus and (barH + CARD_GAP) or 0
  local contentH = h - 2 * OUTER_PAD - barH - CARD_GAP - statusH

  local leftW = 0
  if setting(state, "left") ~= "off" then
    leftW = math.floor(contentW * LEFT_WIDTH_PCT[setting(state, "left_width")] / 100)
    if leftW > contentW - 40 then leftW = math.max(0, contentW - 40) end
  end
  local gx = x0 + OUTER_PAD
  local rx = (leftW > 0) and (gx + leftW + CARD_GAP) or gx
  local rw = contentW - (rx - gx)

  Common.rect(nodes, x0, y0, w, h, C.bg, true)
  L.topBar(nodes, state, x0, y0 + OUTER_PAD, w - 4, boxH, font, fontH, ctx)

  if leftW > 0 and contentH > 0 then
    L.leftPanel(nodes, state, gx, yContent, leftW, contentH, ctx, { lblFont = lblFont, lblH = lblH })
  end
  if rw > 0 and contentH > 0 then
    L.tileGrid(nodes, state, rx, yContent, rw, contentH, ctx, lblFont, lblH)
  end

  if showStatus then
    L.statusBar(nodes, state, x0, yContent + contentH + CARD_GAP, w - 4, boxH, font, fontH, ctx)
  end
  return nodes
end

-- ---------------------------------------------------------------------------
-- the statistics view
-- ---------------------------------------------------------------------------

-- The statistics view: the clock and the radio battery across the top, the model and its totals
-- over a table of what the flight reached -- the reading now, the least and the most of every
-- row -- then one line with the flight time and the capacity used, and the status bar at the
-- foot.
--
-- The flight record's `last` bucket is read directly. The host's flat aliases over `state`
-- (`lastFlightMaxRpm`, `lastMinVoltage`, ...) are a metatable it installs for USER themes only:
-- widgets/dashboard/runtime.lua skips them when the theme path is `system/`, and a shipped theme
-- is installed as one. The flat name stays as the fallback for a host that publishes the record
-- under it.
local function lastStat(state, key, flatName)
  local flight = state.flight
  local last = type(flight) == "table" and flight.last or nil
  local v = nil
  if type(last) == "table" then v = last[key] end
  if v == nil then v = state[flatName] end
  return v
end

-- One record key as a reader for the per-frame sweep: lastStat's lookup written out, with both
-- names joined once here rather than on every call, and the number test folded in.
local function statReader(state, key, flatName)
  return function()
    local flight = state.flight
    local last = type(flight) == "table" and flight.last or nil
    local v = nil
    if type(last) == "table" then v = last[key] end
    if v == nil then v = state[flatName] end
    if type(v) ~= "number" then return nil end
    return v
  end
end

-- A reading printed at `places` decimals, formatted once per change at that precision.
local scaled = Common.scaledGetter

-- One row of the table from one record key: the live reading and the record's two extremes of
-- it. The "Latest" column is the state field the flight view reads. Once the flight controller
-- has stopped answering, the host stops reading telemetry into `state` for the rest of the
-- session (runtime.lua, `isPostflightOffline`), so that column then holds the last reading the
-- link delivered.
local function recordRow(state, label, sample, field, key, places)
  return {
    label = label, sample = sample,
    latest = scaled(Common.field(state, field), places),
    min = scaled(statReader(state, "min" .. key, "lastFlightMin" .. key), places),
    max = scaled(statReader(state, "max" .. key, "lastFlightMax" .. key), places),
  }
end

local function statsRows(state)
  local cfg = state.themeConfig or {}

  -- The voltage row is per CELL, with the cell count in the label. The label, the Min and the Max
  -- belong to the flight that ended, so they take the count of the pack it was flown on where the
  -- host took one at the disarm (Common.flownCells); the Latest column is the live reading and
  -- takes the live count, which follows a pack plugged in after the landing. This view is built
  -- after the disarm, and the flown count changes only on an arm or a disarm edge, both of which
  -- rebuild it; the live count is a render key term. So both can be constants of this build.
  local liveCells = Common.cells(state)
  local cells = Common.flownCells(state) or liveCells
  local function perCell(v, n)
    v = num(v)
    if v == nil or v <= 0 then return nil end
    return v / n
  end
  local vMin = num(tonumber(cfg.v_min))
  local cellMinColor = C.text
  if vMin ~= nil then
    -- The least the pack reached against the theme's own minimum, the bound the gauge and the
    -- flight view's cell row are drawn against. Without a minimum on file there is nothing to
    -- compare with and the figure carries no closure at all.
    -- The flown pack's least reached is compared per cell, against the minimum per cell of the
    -- count the host worked `v_min` out for (`_boundsCells`, widgets/dashboard/runtime.lua,
    -- updateVoltageThemeConfig): that count follows the live pack, so after a pack of another
    -- count is plugged in the two are still compared cell for cell. A `v_min` without such a
    -- count is a pack voltage of the pilot's own and is compared as it is. Either way the answer
    -- is the one before this change while both counts agree.
    local boundCells = tonumber(cfg._boundsCells)
    local cellMinBound = (boundCells and boundCells > 0) and (vMin / boundCells) or nil
    cellMinColor = function()
      local raw = lastStat(state, "minVoltage", "lastMinVoltage")
      if cellMinBound == nil then
        raw = num(raw)
        if raw ~= nil and raw > 0 and raw < vMin then return C.crit end
        return C.text
      end
      local v = perCell(raw, cells)
      if v ~= nil and v < cellMinBound then return C.crit end
      return C.text
    end
  end
  local voltage = {
    label = T.cell_voltage .. " (" .. tostring(cells) .. "S)", sample = "4.20",
    latest = scaled(function() return perCell(state.voltage, liveCells) end, 2),
    min = scaled(function() return perCell(lastStat(state, "minVoltage", "lastMinVoltage"), cells) end, 2),
    max = scaled(function() return perCell(lastStat(state, "maxVoltage", "lastFlightMaxVoltage"), cells) end, 2),
    -- The flight view's own cell-row colour, so the two screens cannot disagree about the pack.
    latestColor = SOURCES_BY_ID.cell_voltage.color(state),
    minColor = cellMinColor,
  }

  -- The headspeed band per PID profile, three FIXED rows: a pilot flies a profile per flying
  -- style, and a row that stays where it is reads at a glance where one that comes and goes with
  -- the flight does not. A profile that was not flown reads `-`. The live headspeed stands only
  -- on the row of the profile the board is on now.
  local function headspeed(p)
    local key = "RpmP" .. p
    return {
      label = T.headspeed_profile .. p, sample = "8888",
      latest = scaled(function()
        local cur = num(state.profile)
        if cur == nil or math.floor(cur) ~= p then return nil end
        return num(state.rpm)
      end, 0),
      min = scaled(statReader(state, "min" .. key, "lastFlightMin" .. key), 0),
      max = scaled(statReader(state, "max" .. key, "lastFlightMax" .. key), 0),
    }
  end

  -- How often the pack went at or below the flight controller's OWN minimum cell voltage and
  -- came back: the count where the reading stands, the deepest per-cell voltage in the Min
  -- column, and both in the alarm colour once a single episode is counted. `-` for none -- the
  -- count is the flight's and not a live reading, so there is no Max.
  local function sagCount() return num(lastStat(state, "sagCount", "lastFlightSagCount")) end
  local sags = {
    label = T.sags, sample = "4.20",
    latest = Common.getter(sagCount, function(n)
      if n == nil or n <= 0 then return "-" end
      return string.format("%dx", math.floor(n + 0.5))
    end),
    min = scaled(function()
      local n = sagCount()
      if n == nil or n <= 0 then return nil end
      return num(lastStat(state, "minSagCellVoltage", "lastMinSagCellVoltage"))
    end, 2),
    max = "-",
  }
  sags.latestColor = function()
    if (sagCount() or 0) > 0 then return C.crit end
    return C.text
  end
  sags.minColor = sags.latestColor

  return {
    voltage,
    headspeed(1), headspeed(2), headspeed(3),
    recordRow(state, T.current, "888.8", "current", "Current", 1),
    recordRow(state, T.esc_temp, "120.0", "escTemp", "EscTemp", 1),
    recordRow(state, T.bec_voltage, "88.88", "bec_voltage", "BecVoltage", 2),
    sags,
  }
end

-- What the header row says about the link: armed, disarmed, or gone. Gone is the one case in the
-- warning colour, because it is the one in which nothing on this screen will change any more.
local function connectionText(state)
  return function()
    if state.flightMode == "offline" then return T.state_offline end
    if state.armed then return T.state_armed end
    return T.state_disarmed
  end
end

local function connectionColor(state)
  return function()
    if state.flightMode == "offline" then return C.warn end
    if state.armed then return (Common.armColors(state)) end
    return C.text
  end
end

-- The line under the table: the flight time and the capacity it used, with the least the fuel
-- reading reached beside it. The capacity is the record's maximum rather than the live reading,
-- because the live one reads 0 on a link that dropped just before the disarm edge.
local function infoLine(state)
  local lastSecs, lastMah, lastFuel, text = nil, nil, nil, nil
  return function()
    local secs = num(state.lastFlightSeconds)
    local mah = num(lastStat(state, "maxConsumedMah", "lastFlightMaxConsumedMah")) or num(state.consumedMah)
    local fuel = num(lastStat(state, "minFuel", "lastFlightMinFuel"))
    if text ~= nil and secs == lastSecs and mah == lastMah and fuel == lastFuel then return text end
    lastSecs, lastMah, lastFuel = secs, mah, fuel
    local used = "-"
    if mah ~= nil then
      used = string.format("%d", math.floor(mah + 0.5))
      if fuel ~= nil then used = used .. string.format(" (%d%%)", math.floor(fuel + 0.5)) end
    end
    text = T.flight_time .. "  " .. Common.duration(secs) .. "        " .. T.mah_used .. "  " .. used
    return text
  end
end

function L.buildStats(zone, state, ctx)
  local nodes = {}
  local x0, y0, w, h = zone.x or 0, zone.y or 0, zone.w or 0, zone.h or 0
  if w <= 0 or h <= 0 then return nodes end
  Common.applyScheme((state.themeConfig or {}).scheme)
  Common.applyFrames(state.themeConfig)
  Common.beginBuild(zone)
  L.bindKeys(state, ctx)

  -- The bars as the flight view has them, so the two screens share their top and their foot
  -- (see L.buildFlight); the status bar follows the same setting, and without it the table takes
  -- its height. The table and the line beneath it are set in the same face.
  local barH = math.max(18, math.floor(h * 0.075))
  local boxH = math.max(1, barH - 2)
  local font = Common.selectFont(boxH, nil, "Total Time")
  local fontH = Common.measure(font, "Total Time")
  local textFont, textH = font, fontH

  local contentW = w - 2 * OUTER_PAD
  local xContent = x0 + OUTER_PAD
  local yContent = y0 + OUTER_PAD + barH + CARD_GAP
  local showStatus = setting(state, "status_bar") == "on"
  local yStatus = showStatus and (y0 + h - OUTER_PAD - barH) or (y0 + h - OUTER_PAD + CARD_GAP)
  local infoH = textH + 6
  local yInfo = yStatus - CARD_GAP - infoH
  local tableH = math.max(1, yInfo - CARD_GAP - yContent)

  Common.rect(nodes, x0, y0, w, h, C.bg, true)
  L.topBar(nodes, state, x0, y0 + OUTER_PAD, w - 4, boxH, font, fontH, ctx, false)
  Common.hline(nodes, xContent, yContent - 1, contentW)

  -- The table: a label column of about a third, and three equal value columns in what is left.
  local innerW = contentW - 2 * CARD_PAD
  local labelW = math.floor(innerW * 0.31)
  local colW = math.floor((innerW - labelW) / 3)
  local lastColW = innerW - labelW - 2 * colW
  local colX = xContent + CARD_PAD + labelW

  local rows = statsRows(state)
  local topRowH = math.max(textH + 4, math.floor(tableH * 0.15))
  local headerRowH = math.max(textH + 2, math.floor(tableH * 0.12))
  local headerGap = math.max(3, math.floor(tableH * 0.02))
  local rowH = math.max(1, math.floor((tableH - topRowH - headerGap - headerRowH) / #rows))
  local usedH = topRowH + headerGap + headerRowH + rowH * #rows
  local yTop = yContent + math.max(0, math.floor((tableH - usedH) / 2))
  local yHeader = yTop + topRowH + headerGap
  local yRows = yHeader + headerRowH

  -- The top row: the model large on the left, the flight controller's totals on the right as
  -- label and figure pairs, with two caps -- the totals at most MIDSIZE, the model at most
  -- DBLSIZE.
  local totalLabel = T.total_flight_time .. ":"
  local flightsLabel = T.flights .. ":"
  local pairGap, itemGap = 8, 3
  local totalLabelW = Common.textWidth(textFont, totalLabel)
  local flightsLabelW = Common.textWidth(textFont, flightsLabel)
  local metaFixedW = totalLabelW + flightsLabelW + pairGap + 2 * itemGap
  local metaValueW = math.max(1, math.floor((innerW - metaFixedW) / 2))
  local metaFont = Common.selectFont(topRowH - 2, metaValueW, "999:59:59", MIDSIZE)
  local metaH = Common.measure(metaFont, "999:59:59")
  local totalValueW = Common.textWidth(metaFont, "999:59:59")
  local flightsValueW = Common.textWidth(metaFont, "9999")
  local clusterW = totalLabelW + itemGap + totalValueW + pairGap + flightsLabelW + itemGap + flightsValueW
  local metaX = math.max(xContent + CARD_PAD, xContent + contentW - CARD_PAD - clusterW)
  local modelW = math.max(1, metaX - (xContent + CARD_PAD) - 8)
  -- The name is sized against ITSELF: a sample long enough for any name would put a short name
  -- in the smallest face on a small screen, beside totals sized for their own room. The flight
  -- record is final by the time this view is built, and so is the model it belongs to.
  local derived = state.derived
  local name = derived and (derived.model_name or derived.edgetx_model_name)
  if type(name) ~= "string" or name == "" then name = T.model_fallback end
  local modelFont = Common.fitFont(topRowH - 2, modelW, name, DBLSIZE)
  local modelH = Common.measure(modelFont, T.model_fallback)
  local rowMid = yTop + math.floor(topRowH / 2)

  Common.label(nodes, xContent + CARD_PAD, rowMid - math.floor(modelH / 2), modelW, modelH,
    Common.modelName(state), modelFont, C.text, LEFT)
  local lx = metaX
  Common.label(nodes, lx, rowMid - math.floor(textH / 2), totalLabelW, textH, totalLabel, textFont, C.label, LEFT)
  lx = lx + totalLabelW + itemGap
  Common.label(nodes, lx, rowMid - math.floor(metaH / 2), totalValueW, metaH,
    Common.getter(Common.field(state, "totalFlightSeconds"), Common.longDuration), metaFont, C.text, LEFT)
  lx = lx + totalValueW + pairGap
  Common.label(nodes, lx, rowMid - math.floor(textH / 2), flightsLabelW, textH, flightsLabel, textFont, C.label, LEFT)
  lx = lx + flightsLabelW + itemGap
  Common.label(nodes, lx, rowMid - math.floor(metaH / 2), flightsValueW, metaH,
    Common.getter(Common.field(state, "flights"), Common.integer), metaFont, C.text, LEFT)

  -- The header row: the link's state over the label column, the three column names over theirs.
  local headerY = yHeader + math.floor((headerRowH - textH) / 2)
  Common.label(nodes, xContent + CARD_PAD, headerY, labelW - CARD_PAD, textH,
    connectionText(state), textFont, connectionColor(state), LEFT)
  Common.label(nodes, colX, headerY, colW, textH, T.latest, textFont, C.label, CENTER)
  Common.label(nodes, colX + colW, headerY, colW, textH, T.min, textFont, C.label, CENTER)
  Common.label(nodes, colX + 2 * colW, headerY, lastColW, textH, T.max, textFont, C.label, CENTER)
  Common.hline(nodes, xContent + CARD_PAD, yRows, innerW)

  -- The row labels share one face, which must also fit the row: eight rows on a 480x272 screen
  -- are shorter than the text above them. The sample is the widest label, at a two-digit count.
  local rowLabelSample = T.cell_voltage .. " (12S)"
  local rowLabelFont = Common.selectFont(math.min(textH, rowH - 2), labelW - CARD_PAD, rowLabelSample)
  local rowLabelH = Common.measure(rowLabelFont, rowLabelSample)

  -- Each row picks its own value font against its own widest sample.
  for i = 1, #rows do
    local row = rows[i]
    local rowY = yRows + (i - 1) * rowH
    local valueFont = Common.selectFont(rowH - 2, colW, row.sample)
    local valueH = Common.measure(valueFont, row.sample)
    local valueY = rowY + math.floor((rowH - valueH) / 2)
    Common.label(nodes, xContent + CARD_PAD, rowY + math.floor((rowH - rowLabelH) / 2), labelW - CARD_PAD, rowLabelH,
      row.label, rowLabelFont, C.label, LEFT)
    Common.label(nodes, colX, valueY, colW, valueH, row.latest, valueFont, row.latestColor or C.text, CENTER)
    Common.label(nodes, colX + colW, valueY, colW, valueH, row.min, valueFont, row.minColor or C.text, CENTER)
    Common.label(nodes, colX + 2 * colW, valueY, lastColW, valueH, row.max, valueFont, C.text, CENTER)
    if i < #rows then
      Common.hline(nodes, xContent + CARD_PAD, rowY + rowH, innerW)
    end
  end

  Common.hline(nodes, xContent, yInfo - 1, contentW)
  Common.label(nodes, xContent, yInfo + 3, contentW, textH, infoLine(state), textFont, C.text, CENTER)
  -- The statistics bar. That the flight controller has stopped answering is said by the table's
  -- header row ("Disconnected"), which reads the phase per frame.
  if showStatus then
    Common.hline(nodes, xContent, yStatus - 1, contentW)
    L.statsStatusBar(nodes, state, x0, yStatus, w - 4, boxH, font, fontH, lastStat)
  end
  return nodes
end

-- ---------------------------------------------------------------------------
-- rebuild key
-- ---------------------------------------------------------------------------

-- The radio battery's key term, in 0.2 V steps with a dead band. A plain rounding flips
-- between two steps for as long as the reading sits on their boundary -- a radio battery
-- reads with a few hundredths of jitter -- and every flip is a full rebuild of the tree,
-- in flight as much as on the ground. So the step only moves once the reading is more than
-- 0.15 V from the centre of the step it is on: 0.05 V past the boundary, never on it.
-- Module state, one number, shared by both views: the key is one key.
local txStep = nil

local function txBatteryStep()
  local v = L.txVoltage()
  if v == nil then
    txStep = nil
    return 0
  end
  if txStep == nil or math.abs(v - txStep / 5) > 0.15 then
    txStep = math.floor(v * 5 + 0.5)
  end
  return txStep
end

-- Everything that moves is a reactive closure, so the tree only has to be rebuilt when its
-- geometry or one of the build-time readings changes: the zone, the cell count the gauge
-- figures are sized from, the model picture, and the TX battery the pill was painted from.
-- Without a key of its own a free-form theme is built once and never again, and a model
-- change would leave the previous picture up. A slot change needs no term here: the
-- preference watcher reloads the theme and clears `built` itself. The phase is in the key
-- although the host reloads the theme on every mode change -- one tostring, and the key then
-- stays right on a host that stops doing so.
--
-- The battery pick's `pending` is a build-time reading for the same reason: the B-Profile
-- label's colour is a constant of the build, so without the term the warn colour would never
-- clear. The picked pack is not a term: nothing drawn depends on it.
--
-- This runs every 0.5 s inside the host's STATE pass: one sensor read, no probe of the card or
-- the settings. The key is one `..` expression, so no list is built to be joined. What a call
-- still allocates is the key itself: Lua 5.3 makes a new string for every key over 40 bytes,
-- and the model picture's path (the suite logo's when there is no picture) puts it over. What a
-- build reads beyond this (the radio's battery range, the image on the card) is read at build
-- time and is not a term.
function L.renderKey(zone, state)
  local derived = state and state.derived or nil
  local bp = state and type(state.batteryPick) == "table" and state.batteryPick or nil
  return "grid"
    .. "|" .. tostring(zone and zone.w or 0)
    .. "|" .. tostring(zone and zone.h or 0)
    .. "|" .. tostring(Common.cells(state or {}))
    -- The picture the host resolved -- which follows the craft name and the cell count as well
    -- as the EdgeTX bitmap -- and whether a second antenna has been seen, which adds a bar.
    .. "|" .. tostring(derived and derived.model_image or "")
    .. "|" .. (L.diversity(state) and "div" or "")
    -- The phase, and it is `themePhase` rather than `flightMode` on purpose.
    --
    -- A host that knows the two refinement phases puts the widget into `armed` on the arm edge
    -- and into `offline` when the flight controller stops answering. Neither has a module of
    -- this theme's (see init.lua): `armed` draws the preflight module and `offline` the
    -- postflight one, and the host does not reload anything for that. `themePhase` is the phase
    -- whose MODULE is on screen AFTER that fallback, so it does not move for either of them --
    -- which is exactly right, because the screen the fallback lands on is the screen already
    -- standing. Keyed on `flightMode` instead, this theme would tear its whole flight view down
    -- and build the identical one again on every single arm edge.
    --
    -- Neither is drawn differently by a rebuild: the statistics view says "Disconnected" from a
    -- per-frame closure, so `offline` needs no flag of its own here.
    --
    -- `flightMode` is the fallback for a host that publishes no `themePhase`: there the two
    -- refinement phases do not exist either, so the term is what it always was.
    .. "|" .. tostring(state and (state.themePhase or state.flightMode) or "")
    .. "|" .. tostring(txBatteryStep())
    .. "|" .. tostring(bp and bp.pending or false)
end

if type(_G) == "table" then _G.__rfsuiteThemeGridLayoutModule = L end

return L
