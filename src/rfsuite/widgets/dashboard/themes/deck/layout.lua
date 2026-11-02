-- The panels the flight view and the statistics view are assembled from.
--
-- Split off common.lua only for size: the drawing primitives and the value getters are
-- there, the arrangement is here. Both are cached on _G, the same way the shipped themes cache
-- theirs, until the dashboard releases a theme no widget uses any more (releaseUnusedThemes in
-- widgets/dashboard/runtime.lua): module state here starts afresh when the theme is shown again.
-- This module is the theme's whole surface to the phase modules: buildFlight, buildStats,
-- sources and renderKey, so that a phase module is one require and a few forwards.
--
-- The look: a header (the menu and tool glyphs, the model name, the link cluster, the clock and
-- the radio battery), a left column of three cards, a right column with one big card over a row
-- of up to four value columns, and a wide battery strip at the foot. Each card shows a reading or
-- one of a few kinds that are not a single reading (L.KINDS); each value column a reading with its
-- range under it.
--
-- Extending the theme -- where a change goes, and what it costs:
--
--   a new value a card can show            one entry in L.SOURCES; the configure page and the
--                                          cards both read that list, nothing else changes.
--   a new kind of card (not a value)       one entry in L.KINDS, its name in L.kindLabels, and
--                                          its drawing in drawCard.
--   a new panel or a new box in a panel    a build-time function here appending nodes; every
--                                          moving field a Common.getter over `state`; every
--                                          firmware probe at build time, never in a closure.
--   a new build-time reading               a term in L.renderKey -- with a dead band where the
--                                          reading is continuous, or the panel rebuilds on noise.
--   a derived quantity (a latch, a peak,   NOT here. A theme has no per-pass entry point but the
--   a decoder, a sag detector)             render key, and that runs inside the host's most
--                                          expensive pass. Derivation belongs on the host's
--                                          `state` or flight record; the theme draws it.

if type(_G) == "table" and type(_G.__rfsuiteThemeDeckLayoutModule) == "table" then
  return _G.__rfsuiteThemeDeckLayoutModule
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

local Common = requireModule("widgets/dashboard/themes/deck/common.lua")
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

-- The settings this theme carries beyond the eight card positions, the colour scheme and the arm
-- colours. They are declared HERE for the reason the value catalogue is here: the settings page
-- loads this module, so the list a pilot chooses from and the list the panels draw from are one
-- list and cannot drift apart.
--
-- This half is what the DRAWING needs and nothing else: the key, the page of init.lua the row is
-- set on, the values that are valid, and the default. The defaults draw a complete screen with
-- nothing touched: the clock showing the time alone, the units beside every caption.
--
-- Values are STRINGS, the numbers included. common.lua says why; the two numeric rows are read
-- back through tonumber() at build time.
--
-- A row with `min` and `max` in place of `values` is a whole number the pilot sets freely in that
-- range rather than one picked from a list; it is stored as text like the rest. `notAbove` names
-- the row whose value it may not exceed: the settings page holds it there, and the theme's own
-- read does too (Common.fuelSteps).
--
-- None of these belongs in the render key. A themeConfig read is a BUILD-TIME read: the host
-- reloads the theme when its preferences change, and what the key bills is a reading that moves
-- in flight, which no setting does.
local ON_OFF = { "on", "off" }

L.SETTINGS = {
  -- The firmware's own frame around every place on the full screen that takes a press -- the
  -- menu and tool buttons, the link cluster, the cards, the battery strip, the buttons of the
  -- views. Off covers it (Common.button); the outlines this theme draws itself stay.
  { page = "look",   key = "tap_frames", values = ON_OFF,                      default = "on" },
  -- The battery strip's and the charge card's yellow and red steps, in percent of the fuel
  -- reading. The defaults are the steps they draw with when nobody has set them.
  { page = "look",   key = "fuel_low",   min = 0, max = 100, default = tostring(Common.FUEL_LOW_DEFAULT) },
  { page = "look",   key = "fuel_crit",  min = 0, max = 100, default = tostring(Common.FUEL_CRIT_DEFAULT),
    notAbove = "fuel_low" },
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
  -- The unit in brackets after each caption. On by default here: a card's caption has the room
  -- for it, and the figure under it does not grow when it is off.
  { page = "values", key = "units",      values = ON_OFF,                      default = "on" },
  { page = "values", key = "temp_colors", values = { "off", "standard", "early" }, default = Common.TEMP_COLORS_DEFAULT },
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
    fuel_low = { label = "@i18n(app.pages.settings_dashboard_settings.urban_fuel_low)@", suffix = " %" },
    fuel_crit = { label = "@i18n(app.pages.settings_dashboard_settings.urban_fuel_crit)@", suffix = " %" },
    clock = { label = "@i18n(app.pages.settings_dashboard_settings.urban_clock)@",
              values = { date_time = "@i18n(app.pages.settings_dashboard_settings.urban_clock_date_time)@",
                         time = "@i18n(app.pages.settings_dashboard_settings.urban_clock_time)@" } },
    lq_bar = { label = "@i18n(app.pages.settings_dashboard_settings.urban_lq_bar)@", values = onOff() },
    tq_bar = { label = "@i18n(app.pages.settings_dashboard_settings.urban_tq_bar)@", values = onOff() },
    rssi_bars = { label = "@i18n(app.pages.settings_dashboard_settings.urban_rssi_bars)@", values = onOff() },
    tx_battery = { label = "@i18n(app.pages.settings_dashboard_settings.urban_tx_battery)@", values = onOff() },
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

local OUTER_PAD = 4
local CARD_GAP = 4
local CARD_PAD = 4

-- ---------------------------------------------------------------------------
-- the full screen surface: the menu control
-- ---------------------------------------------------------------------------

-- On the full screen surface the host hands the build a `ctx` (and only there), and a theme that
-- binds a press of its own gets no host controls over it. This theme binds two small boxed glyphs
-- at the left end of the header, before the model name: this one opens the quick menu, the one beside
-- it the suite's tool (L.toolControl). There is no close control -- a long press on RTN leaves
-- full screen in the firmware, and init.lua declares that (`fullscreenExit`), which is what the
-- host's theme check reads. With PAGE on Theme radio-wide, the page keys open the menu only when bound.
--
-- The press is a `button`, and everything drawn over it is a LINE: on the full screen surface a
-- rectangle takes a press and hands it to its PARENT, so a rectangle over the button would
-- swallow every press landing on it. A line is created not clickable. The button's own fill is
-- the panel's, so what shows is the outline and the three bars, drawn as lines over it. EdgeTX
-- gives every button a theme-coloured border of its own; the outline lines lie over it.
--
-- Returns the width it took, so the model name can start after it. Without a ctx -- the widget zone,
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

-- The second control of the header, beside the menu glyph and of its size and outline: it opens
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
  { id = "tools",      action = "openView:deck_menu" },
  { id = "link",       action = "openView:deck_link" },
  { id = "telemetry",  action = "openView:deck_telemetry" },
  { id = "battery",    action = "openView:deck_battery" },
  { id = "status",     action = "openView:deck_status" },
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
-- the header: menu and tool glyphs, model name, link cluster, clock, TX battery pill
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

-- Whether the reading behind `state.lq` is a link QUALITY in percent or a signal STRENGTH in dBm.
-- The suite's search for the link sensor ends in 1RSS and 2RSS, which carry an RSSI; the widget
-- publishes which sensor answered as `lqSource` (widgets/dashboard/runtime.lua), and the flight
-- record refuses to keep a link quality from the same two (tasks/events/telemetry/flight_record.lua,
-- RSSI_LINK_SOURCES). A build-time reading and a term of the render key: what the RQ bar and its
-- figure draw is decided when they are built.
local RSSI_LINK_SOURCES = { ["1RSS"] = true, ["2RSS"] = true }

function L.lqIsRssi(state)
  local s = state and state.lqSource
  return type(s) == "string" and RSSI_LINK_SOURCES[s] == true
end

-- The header, left to right: the menu and tool glyphs (full screen only), the model name, the link
-- cluster centred on the header's midline -- the receiver's link figure beside the stacked link
-- bars -- the clock, and the radio battery pill at the right end.
--
-- `showLink` false draws everything but the link cluster, whatever the pilot set for the bars: the
-- statistics view is the one caller that passes it, and after a flight the link has nothing left
-- to report that the table below does not say better.
function L.header(nodes, state, x, y, w, h, font, fontH, ctx, showLink)
  local textY = y + math.floor((h - fontH) / 2)

  -- Every setting this header reads is a BUILD-TIME read of state.themeConfig, and none of them is
  -- in the render key: the host reloads the theme when its preferences change.
  local quietBars = setting(state, "bar_colors") == "warn"

  local nameX = x + 1 + L.menuControl(nodes, ctx, x + 1, y, h)
  nameX = nameX + L.toolControl(nodes, state, ctx, nameX, y, h)

  -- The TX battery as a pill: fill, terminal, outline, and the percentage over it. Switched
  -- off, the pill is not drawn AND its width is given back to the rest of the header.
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
    rightLimit = pillX - 4
  end

  -- The clock, in the mode the pilot chose, right-aligned against the pill, and its width measured
  -- against THAT mode's own sample -- common.lua keeps the format and the sample in one entry.
  local clock = Common.clockMode(setting(state, "clock"))
  local clockW = Common.textWidth(font, clock.sample) + 4
  local clockX = rightLimit - clockW
  Common.label(nodes, clockX, textY, clockW, fontH, Common.clock(clock), font, C.text, RIGHT)
  rightLimit = clockX

  -- The link cluster's room comes first: centred on the header's midline, so it never moves when
  -- the name, the clock or the pill change width, at most 36 % of the header, and shrunk
  -- symmetrically where the clock or the pill would touch it.
  local mid = x + math.floor(w / 2)
  local clusterW = math.max(0, math.min(math.floor(w * 0.36), 2 * ((rightLimit - 6) - mid)))
  if showLink == false then clusterW = 0 end

  -- The model name, at most 30 % of the header and never into the cluster. Common.label cuts
  -- nothing, and a name is data, so it is held to the number of characters its box takes, measured
  -- once per build against a word of ordinary mixed case and cut once per change of the name.
  local nameLimit = (clusterW > 0) and (mid - math.floor(clusterW / 2) - 6) or (rightLimit - 6)
  local nameW = math.max(1, math.min(math.floor(w * 0.30), nameLimit - nameX))
  local NAME_SAMPLE = "Rotorflight"
  local nameChars = math.max(4, math.floor(nameW * #NAME_SAMPLE / math.max(1, Common.textWidth(font, NAME_SAMPLE))))
  local name = Common.modelName(state)
  local lastName, nameText = nil, ""
  Common.label(nodes, nameX, textY, nameW, fontH, function()
    local n = name()
    if n ~= lastName then
      lastName = n
      nameText = (#n > nameChars) and (Common.cutUtf8(n, nameChars - 1) .. ".") or n
    end
    return nameText
  end, font, C.text, LEFT)
  if showLink == false then return end

  -- The link bars, stacked: RQ, TQ, the receiver's first antenna and -- once the link has shown
  -- that a second one is there -- the second. Each bar is its reading across the width, with
  -- notches at its warning and critical steps, green / amber / red by those steps (or neutral
  -- while fine, where the pilot chose colour only on warning). The steps are the announcements'
  -- levels: link quality's for both link-quality bars, the RSSI alert's for the signal bars.
  --
  -- On a receiver whose link reading is a signal strength (L.lqIsRssi) there is no link quality to
  -- draw: the RQ bar stays an empty track, and the figure beside the bars says the strength in dBm
  -- instead of a percentage.
  local rssiLink = L.lqIsRssi(state)
  local lqWarn, lqCrit = alertSteps(state, "lq")
  local rsWarn, rsCrit = alertSteps(state, "rssi")
  local bars = {}
  local showFigure = setting(state, "lq_bar") == "on"
  if showFigure then
    local readLq = Common.field(state, "lq")
    bars[#bars + 1] = { read = rssiLink and function() return nil end or readLq, warn = lqWarn, crit = lqCrit }
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

  -- The figure stands at the cluster's left end and the bars take the rest of it. Where the cluster
  -- is too narrow for both, the figure is left out before the bars are.
  local figSample = rssiLink and "-120" or "100%"
  local figW = showFigure and (Common.textWidth(font, figSample) + 4) or 0
  if clusterW - figW < 24 then figW, showFigure = 0, false end
  if clusterW < 8 then return end
  local barX = mid - math.floor(clusterW / 2) + figW
  local barW = clusterW - figW
  local availH = math.max(n * 2, h - 2)
  local slotH = math.floor(availH / n)
  local barH = math.max(2, slotH - 1)
  local topY = y + math.floor((h - slotH * n) / 2)
  -- Two looks: an outlined track with a fill inset in it where a bar is at least six pixels
  -- tall, a plain filled track below that, which is what a 480x320 screen gets.
  local outlined = barH >= 6
  local good = quietBars and C.neut or C.ok

  -- In full screen, on a host with theme views, the cluster -- figure and bars -- is the tap that
  -- opens the link view: the bars are what that page shows in detail. Everything over the press is
  -- then a label or a line rather than a rectangle, in the same places and colours; the widget zone
  -- draws the rectangles it always drew.
  local asLines = hasViews(ctx)
  if asLines then
    local action = ctx.action
    tapArea(nodes, barX - figW - 2, topY - 1, barW + figW + 4, slotH * n + 1, function() action("openView:deck_link") end)
  end

  if showFigure then
    local lastQ, figText = Common.UNSET, "--"
    Common.label(nodes, barX - figW, textY, figW - 2, fontH, function()
      local q = num(state.lq)
      if q == lastQ then return figText end
      lastQ = q
      if q == nil then
        figText = "--"
      elseif rssiLink then
        figText = string.format("%d", math.floor(q + 0.5))
      else
        figText = string.format("%d%%", math.floor(q + 0.5))
      end
      return figText
    end, font, C.text, RIGHT)
  end

  for i = 1, n do
    local read, warn, crit = bars[i].read, bars[i].warn, bars[i].crit
    local by = topY + (i - 1) * slotH
    -- Decided once per change of the reading, as the battery strip's fill colour is (Common.fuelLevel).
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
-- the value catalogue the card positions choose from
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
-- `list` is the configure page's order, `id` the cfg value it stores, `label` the card's caption
-- as a translation marker -- the configure page lists it as the option and the card draws it, so
-- the two cannot name a reading differently. This list is the one
-- extension point a new value needs: `make` returns the card's reactive getter over `state`,
-- `color` (optional) its reactive colour, `sample` the widest string the font is picked against.
--
-- `source` (optional) is the name the HOST knows the reading by, and it is what L.sources below
-- adds for a position a pilot chose. An entry without one reads a fixed field of the state and
-- costs the host nothing to supply; an entry with one is a reading the host resolves only because
-- this theme asked for it, so the position half of the list is built from the positions a pilot
-- actually chose. None of the defaults carries a `source`; the readings the theme declares whatever
-- the positions say are listed in L.sources, with the reason for each.
--
-- `minKey` / `maxKey` (optional) name the flight record's extremes of the reading
-- (tasks/events/telemetry/flight_record.lua, FLIGHT_STATS), which the value columns and the
-- telemetry view print under the figure at `places` decimals. A side the record does not keep
-- is absent and prints `-`; a reading with neither is not in the record at all and its tile has
-- no range line.
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
    -- Below the theme's own minimum (`v_min`, where one is on file) the figure turns.
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
    -- The pack voltage turns with the battery strip and the arm card when the main pack is gone.
    -- This reading has no minimum of its own -- the cell figure is the one the theme's configured
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
  -- The fuel reading is the battery strip's: nothing until the host has seen a fuel reading.
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
  -- THIS READING KEEPS THE RECORD, AND THE ARM CARD DELIBERATELY DOES NOT. The host publishes
  -- both readings; the arm card takes `esc_status_live` and this reading takes `esc_status`, so on
  -- a controller that faulted and recovered the two say different things at the same time.
  -- That is the design and not a bug to tidy away: the card answers "what is wrong now" and would
  -- be lying if it held a withdrawn alarm, while this reading answers "what has this flight seen" and
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
  -- floor as ExpressLRS states it. The reading shows the floor itself; the RSSI bars in the
  -- header draw the headroom above it.
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

  { id = "none", label = "@i18n(widgets.dashboard.urban_off)@", unit = "", sample = "8888",
    make = function() return function() return "" end end },
}

local SOURCES_BY_ID = {}
for i = 1, #L.SOURCES do SOURCES_BY_ID[L.SOURCES[i].id] = L.SOURCES[i] end

-- The telemetry view's tiles (telemview.lua), chosen on the Telemetry settings page from the same
-- catalogue as the card positions. Up to twelve, three to a row; a tile set to `none` is left out and
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
-- Two halves. The readings the flight view draws whatever the positions say:
--
--   esc_status_live, esc_status_live_level   the speed controller's LIVE status, which the arm
--                                            card and the status view read. Declared
--                                            unconditionally: a declaration built from the
--                                            positions alone would leave it unresolved on every
--                                            radio whose pilot has not put it on a card, and the
--                                            card would then say nothing for a reason no pilot
--                                            could ever see.
--   TQly, TPWR                               the transmitter's link quality and power, for the
--                                            TQ bar and the statistics view's bar.
--   link_floor                               the sensitivity floor of the air rate, which the
--                                            signal bars measure their headroom against.
--   link_diversity                           whether a second antenna has been seen.
--   *Skp                                     the skipped-frame count, which the suite publishes
--                                            itself (tasks/events/telemetry_bg/drain.lua,
--                                            setTelemetryValue 0xEE02). A bare `Skp` is not
--                                            declared: no current source creates it, and an
--                                            absent name is still a read on every pass.
--
-- And the `source` of each reading a pilot put on a card or in a value column -- with, for a raw
-- sensor, the `-` and `+` forms of its name, the radio's own least and most of it, which the range
-- under the figure reads.
--
-- BOTH names of the live pair are declared, and the second one is not redundant even though the
-- host pairs them itself: that pairing runs as a pass over the collected list, so it only sees a
-- declaration collected BEFORE it. If the order of those two steps ever reversed, the level would
-- go undeclared, the severity would arrive as nil, and the arm card would fall back to the arm
-- state on a model with a faulty controller, with nothing going red. Naming it costs a table entry the
-- host would have added anyway, and it turns an ordering assumption into no assumption at all.
--
-- `esc_status` -- the worst reading since the flight controller connected -- is NOT in the first
-- half. It is the ESC Status reading's, so it arrives through the position loop when a pilot
-- selects that reading, and a pilot who has not selected it does not pay for it.
--
-- That is a cost on the HOST, per snapshot, and it is stated rather than hidden: each name is
-- resolved on every snapshot, an absent one is searched again on the host's back-off of 2 s
-- rising to 30 s, and `link_floor` makes the host ask the transmitter module once per link which
-- ExpressLRS generation it runs. A host without `sources` support resolves none of it, and those
-- cards read "-" while the arm card falls back to the arm state.
--
-- Duplicates are dropped here rather than left to the host: two positions showing one reading is
-- a thing a pilot can do, and the list is a declaration, not a count.
local ALWAYS_DECLARED = {
  "esc_status_live", "esc_status_live_level",
  "TQly", "TPWR", "link_floor", "link_diversity", "*Skp",
}

function L.sources(state)
  local cfg = (state and state.themeConfig) or {}
  local list, seen = {}, {}
  local function add(name)
    if not seen[name] then
      seen[name] = true
      list[#list + 1] = name
    end
  end
  for i = 1, #ALWAYS_DECLARED do add(ALWAYS_DECLARED[i]) end
  local function addDef(def)
    local src = def and def.source
    if src then
      add(src)
      if def.rawRange then
        add(src .. "-")
        add(src .. "+")
      end
    end
  end
  for i = 1, L.CARD_COUNT do
    local entry = L.resolveCard(cfg, i)
    if entry.kind == "value" then addDef(entry.def) end
  end
  for i = 1, L.VALUE_COUNT do addDef(L.resolveValue(cfg, i)) end
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
-- `none`. Each is a reading of the catalogue -- the same label, unit, figure and colour -- plus
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
-- the cards: what a position shows
-- ---------------------------------------------------------------------------

-- Eight positions: three cards down the left column, one big card over the value row on the right
-- (`card1` .. `card4`), and the four columns of the value row (`value1` .. `value4`). A card shows
-- a reading of the catalogue above or one of these kinds, which are not a single reading; a column
-- of the value row shows a reading. `none` -- the catalogue's own Off -- leaves a position empty,
-- and the rest of its column or its row takes its room.
--
-- `first` marks a kind offered on the first position alone: the model picture is the one entry
-- that is not text, and only the tall first card fits it with its footer. The kinds' names are
-- the settings page's (L.kindLabels); what a kind draws carries its own words.
L.KINDS = {
  { id = "image", first = true },
  { id = "arm" },
  { id = "gov" },
  { id = "charge" },
  { id = "ftime" },
  { id = "ttime" },
}
L.CARD_COUNT = 4
L.VALUE_COUNT = 4

-- The defaults draw a complete screen with nothing configured: the model picture over the arm
-- state over the governor on the left, the headspeed as the big card, and current, cell voltage,
-- BEC and ESC temperature in the value row.
L.DEFAULT_CARDS = { "image", "arm", "gov", "rpm" }
L.DEFAULT_VALUES = { "current", "cell_voltage", "bec_voltage", "esc_temp" }

-- The kinds' names on the settings page. A function for the reason L.settingsLabels is one: the
-- widget's Lua state never draws them.
function L.kindLabels()
  return {
    image = "@i18n(app.pages.settings_dashboard_settings.deck_kind_image)@",
    arm = "@i18n(app.pages.settings_dashboard_settings.deck_kind_arm)@",
    gov = "@i18n(app.pages.logs.tpl_governor)@",
    charge = "@i18n(widgets.dashboard.urban_battery)@",
    ftime = "@i18n(app.pages.logs.flight_duration)@",
    ttime = "@i18n(widgets.dashboard.urban_total_time)@",
  }
end

local KIND_BY_ID = {}
for i = 1, #L.KINDS do KIND_BY_ID[L.KINDS[i].id] = L.KINDS[i] end

-- Whether `id` may stand on card position `slot`: a kind (the picture on the first position only)
-- or any reading of the catalogue, `none` included. The settings page asks the same question, so
-- it offers exactly what the flight view draws.
function L.cardAllows(slot, id)
  local kind = KIND_BY_ID[id]
  if kind ~= nil then return slot == 1 or not kind.first end
  return SOURCES_BY_ID[id] ~= nil
end

-- What a card position resolves to: `{ kind = <kind id> }`, `{ kind = "value", def = <entry> }`
-- or `{ kind = "none" }`. A stored id the position does not allow -- a hand-edited file naming the
-- picture on another position, an id a newer build offered -- is the position's default.
function L.resolveCard(cfg, slot)
  local id = cfg["card" .. slot]
  if type(id) ~= "string" or not L.cardAllows(slot, id) then id = L.DEFAULT_CARDS[slot] end
  if KIND_BY_ID[id] ~= nil then return { kind = id } end
  if id == "none" then return { kind = "none" } end
  return { kind = "value", def = SOURCES_BY_ID[id] }
end

-- What a column of the value row shows: a catalogue entry, or nil for `none`.
function L.resolveValue(cfg, slot)
  local id = cfg["value" .. slot]
  local def = (type(id) == "string") and SOURCES_BY_ID[id] or nil
  if def == nil then def = SOURCES_BY_ID[L.DEFAULT_VALUES[slot]] end
  if def == nil or def.id == "none" then return nil end
  return def
end

-- A reading's caption: its name, and its unit in brackets where the pilot has the units on and the
-- reading has one. A signal strength stands in the link reading's place on a receiver without a
-- link quality (L.lqIsRssi), so that reading's unit follows it. Both halves are constants of the
-- build.
local function caption(state, def, showUnits)
  local unit = def.unit or ""
  if def.id == "link" and L.lqIsRssi(state) then unit = "dBm" end
  if not showUnits or unit == "" then return def.label, "" end
  return def.label, " (" .. unit .. ")"
end

-- A caption fitted to `w`: the unit goes first where the two do not fit together, and the name is
-- cut with two dots only where it does not fit alone -- a cut name says less than a name without
-- its unit. Cached with the zone's other measurements.
local function fitCaption(font, name, unit, w)
  if unit ~= "" and Common.textWidth(font, name .. unit) <= w then return name .. unit end
  return Common.fitLabel(font, name, w)
end

-- The range under a reading: "<least> .. <most>" of the flight record -- the flight in progress
-- where it has taken a value, the flight that ended otherwise, the rule the telemetry view's tiles
-- read the record by -- or of the radio's own least and most for a raw sensor. `compact` is the
-- form for a column too narrow for both ends: the most alone, after the word for it. Nil for a
-- reading nothing keeps a range of.
local function chipGetter(state, def, compact)
  local cells = def.perCell and Common.cells(state) or nil
  if not compact then
    if def.rawRange then return rawRangeGetter(state, def) end
    if def.minKey or def.maxKey then return rangeGetter(state, def, cells) end
    return nil
  end
  local read
  if def.rawRange then
    local highName = def.source .. "+"
    read = function()
      local d = state.derived
      local v = d and d[highName]
      if type(v) ~= "number" then return nil end
      return v
    end
  elseif def.maxKey then
    read = extremeReader(state, def.maxKey, cells)
  else
    return nil
  end
  local fmt = "%." .. tostring(def.places or 0) .. "f"
  local prefix = T.max .. " "
  return Common.getter(read, function(v)
    if v == nil then return prefix .. "-" end
    return prefix .. string.format(fmt, v)
  end)
end

-- The sample the small face is fitted to: a range of two four-figure readings.
local S_CHIP = "888.8 .. 888.8"

-- The widest string a range of this reading can be, for the decision whether it fits.
local function chipSample(def)
  if def.perCell then return "4.20 .. 4.20" end
  return def.sample .. " .. " .. def.sample
end

-- Whether a sample is a figure (digits, a point, a sign, a colon) rather than words. Figures in one
-- row share a face; a reading in words takes its own, so one word does not shrink every figure.
local function isFigure(sample)
  return string.find(sample, "^[%d%.%-:]+$") ~= nil
end

-- A caption over one large figure, with an optional line under it. As the card gets flatter the
-- line goes first and then the caption, decided against the height LEFT FOR THE FIGURE: a card
-- exists to show its figure, and a caption and a line in a flat card can leave it a few pixels.
local MIN_VALUE_H = 12

local function cardBody(nodes, g, x, y, w, h, cap, value, valueColor, valueSample, sub, subColor)
  local iw = math.max(1, w - 2 * CARD_PAD)
  local capH, subH = g.smlH + 6, g.smlH + 4
  local showSub = sub ~= nil and (h - capH - subH - 4) >= MIN_VALUE_H
  local showCap = cap ~= nil and (h - capH - (showSub and subH or 4)) >= MIN_VALUE_H
  local top = showCap and capH or 4
  local room = h - top - (showSub and subH or 4)
  if room < MIN_VALUE_H then top, room = 2, math.max(1, h - 4) end
  local valueFont = Common.selectFont(room, iw - 4, valueSample)
  local valueH = math.min(Common.measure(valueFont, valueSample), room)
  local valueY = top + math.max(0, math.floor((room - valueH) / 2))
  if valueY + valueH > h - 2 then valueY = math.max(2, h - 2 - valueH) end
  if showCap then
    Common.label(nodes, x + CARD_PAD, y + 4, iw, g.smlH, cap, g.sml, C.label, CENTER)
  end
  Common.label(nodes, x + CARD_PAD, y + valueY, iw, valueH, value, valueFont, valueColor or C.text, CENTER)
  if showSub then
    Common.label(nodes, x + CARD_PAD, y + h - g.smlH - 5, iw, g.smlH, sub, g.sml, subColor or C.label, CENTER)
  end
end

-- What the arm card says, and in which colour, as ONE closure the text node and the colour node
-- both ask. The arm state, unless something outranks it:
--
--   main power lost      over everything: the board answers on its BEC and nothing else on the
--                        screen looks wrong.
--   speed controller     its LIVE verdict where it reports a warning or a fault, in that level's
--                        colour, while a flight controller answers. "OK" is not worth the arm
--                        state's place, and a fault the controller has cleared is not shown -- the
--                        ESC Status reading keeps the record (L.SOURCES).
--   arm state            ARMED / DISARMED in the colours the pilot chose, "No FC connected" muted.
--
-- `capChars` is the number of characters the caller measured the card to hold; the cut is made
-- once per change of the text, never per frame.
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

-- How many characters of ordinary capitals fit `w` px in `font`: the arm card's and the governor
-- card's strings are capitals -- the controller's verdicts, the arming descriptors.
local CAPS_SAMPLE = "BOOTGRACE"
local function capsFit(font, w)
  return math.max(4, math.floor(w * #CAPS_SAMPLE / math.max(1, Common.textWidth(font, CAPS_SAMPLE))))
end

-- The widest of the arm card's own words, by bytes, which over-counts a multi-byte character and
-- errs towards the smaller face.
local function armSample()
  local best = T.disarmed
  local list = { T.armed, T.no_fc, T.main_power_lost }
  for i = 1, #list do
    if #list[i] > #best then best = list[i] end
  end
  return best
end

-- Under the model picture: the flight controller's flight count and total flight time, and the
-- board's battery profile -- in the warn colour while the host still waits for a battery pick on
-- this connection (L.renderKey carries `pending`, so the colour follows the prompt).
local function imageFooter(nodes, state, g, x, y, w, footH)
  local inner = w - 2 * CARD_PAD
  local w3 = math.floor(inner * 0.28)
  local w1 = math.floor((inner - w3) * 0.40)
  local w2 = inner - w3 - w1
  local capH = g.smlH
  local valueH = footH - capH
  local valueFont = Common.selectFont(valueH, w2 - 4, "999:59:59")
  local vH = Common.measure(valueFont, "999:59:59")
  local bp = type(state.batteryPick) == "table" and state.batteryPick or nil
  local bpLabel = T.battery_profile
  if Common.textWidth(g.sml, bpLabel) > w3 then bpLabel = T.battery_profile_short end
  local cx = x + CARD_PAD
  Common.stacked(nodes, cx, y, w1, 0, Common.fitLabel(g.sml, T.flights, w1),
    Common.getter(Common.field(state, "flights"), Common.integer), g.sml, capH, valueFont, vH)
  Common.stacked(nodes, cx + w1, y, w2, 0, Common.fitLabel(g.sml, T.total_time, w2),
    Common.getter(Common.field(state, "totalFlightSeconds"), Common.longDuration), g.sml, capH, valueFont, vH)
  Common.label(nodes, cx + w1 + w2, y, w3, capH, Common.fitLabel(g.sml, bpLabel, w3), g.sml,
    (bp and bp.pending == true) and C.warn or C.label, CENTER)
  Common.label(nodes, cx + w1 + w2, y + capH, w3, vH,
    Common.getter(Common.field(state, "batteryProfile"), Common.integer), valueFont, C.accent, CENTER)
end

-- Which view a card's press opens, by what it shows: a reading opens the telemetry view, the arm
-- state and the governor the status view, the charge the battery view, the picture this theme's
-- own menu (the battery profiles and the tuning surface).
local CARD_VIEW = {
  value = "openView:deck_telemetry", ftime = "openView:deck_telemetry", ttime = "openView:deck_telemetry",
  arm = "openView:deck_status", gov = "openView:deck_status",
  charge = "openView:deck_battery", image = "openView:deck_menu",
}

-- A button's children are placed against its content area, which starts inside its padding:
-- `pad_button`, PAD_MEDIUM left and right and PAD_TINY above and below, both scaled by the screen
-- class (radio/src/gui/colorlcd/libui/etx_lv_theme.cpp and etx_lv_theme.h, LAYOUT_SCALE), plus
-- the 2 px frame (PAD_BORDER). A Lua button takes no padding parameter, so a picture built into
-- one is placed that far up and to the left, and lands where the widget zone draws it.
local function layoutScale(v)
  if LCD_W == 800 then return math.floor((v * 11 + 4) / 8) end
  if LCD_W == 320 then return math.floor((v * 8 + 5) / 10) end
  return v
end
local BUTTON_BORDER = 2
L.buttonInset = function() return layoutScale(6) + BUTTON_BORDER, layoutScale(2) + BUTTON_BORDER end

-- A card's surface and outline. In the widget zone, and on a host without theme views, the
-- rounded card. Over a press, the press itself is the surface -- a button in the card colour --
-- and the outline is four lines, because a line takes no press where a rectangle would take it.
-- Cards stand next to each other, so the outline cannot be built into the button the way a single
-- panel can: the children of a button are drawn up and to the left of it by the button's padding,
-- into the gap beside the next card. `outline` may be a colour or a per-frame colour function.
-- Answers the index of the button node, or nil.
local function cardFrame(nodes, x, y, w, h, ctx, view, outline)
  if not (view and hasViews(ctx)) then
    Common.card(nodes, x, y, w, h, outline)
    return nil
  end
  local action = ctx.action
  local at = #nodes + 1
  Common.button(nodes, x, y, w, h, C.card, function() action(view) end)
  local color = outline or C.line
  local x1, y1 = x + w - 1, y + h - 1
  local edges = {
    { { x, y }, { x1, y } }, { { x, y1 }, { x1, y1 } },
    { { x, y }, { x, y1 } }, { { x1, y }, { x1, y1 } },
  }
  for i = 1, 4 do
    nodes[#nodes + 1] = { type = "line", x = 0, y = 0, w = 0, h = 0, pts = edges[i], color = color, thickness = 1 }
  end
  return at
end

-- One card: its frame and what its position resolved to, drawn into the rectangle it is given.
-- Every kind shrinks by DROPPING a part, never by clipping one.
local function drawCard(nodes, state, g, entry, x, y, w, h, ctx, bodyW)
  local kind = entry.kind
  if kind == "none" then return end
  local outline = (kind == "gov") and Common.governorFrameColor(state) or nil
  local at = cardFrame(nodes, x, y, w, h, ctx, CARD_VIEW[kind], outline)
  w = bodyW or w
  local iw = math.max(1, w - 2 * CARD_PAD)

  if kind == "arm" then
    -- One line, fitted to the card: the state is the one thing a pilot checks at a glance.
    local sample = armSample()
    local font = Common.selectFont(math.max(10, h - 8), iw - 8, sample)
    local fh = math.min(Common.measure(font, sample), math.max(1, h - 4))
    local cell = stateCell(state, capsFit(font, iw - 8))
    Common.label(nodes, x + CARD_PAD, y + math.max(2, math.floor((h - fh) / 2)), iw, fh,
      function()
        local said = cell()
        return said
      end, font,
      function()
        local _, color = cell()
        return color
      end, CENTER)

  elseif kind == "gov" then
    -- The governor, and under it what stands between the pilot and arming, while disarmed, in the
    -- firmware's own short descriptors -- the one line on this screen that says why the model will
    -- not arm.
    local why = Common.armDisableText(state)
    local chars = capsFit(g.sml, iw)
    local lastRaw, lastCut = nil, ""
    cardBody(nodes, g, x, y, w, h, Common.fitLabel(g.sml, T.governor, iw),
      Common.governorText(state), Common.governorColor(state), Common.governorSample(),
      function()
        if state.armed == true or state.rfConnected ~= true then return "" end
        local raw = why()
        if raw ~= lastRaw then
          lastRaw = raw
          lastCut = (#raw > chars) and (Common.cutUtf8(raw, chars - 1) .. ".") or raw
        end
        return lastCut
      end, C.warning)

  elseif kind == "charge" then
    -- The pack's charge as the battery strip reads it (Common.fuelLevel: the steps the pilot set,
    -- no reading with the main pack gone), the figure turning yellow and red at those steps; the
    -- capacity used under it. The cell count is a render key term, so the caption is a constant.
    local level = Common.fuelLevel(state)
    cardBody(nodes, g, x, y, w, h,
      Common.fitLabel(g.sml, T.view_battery .. " " .. tostring(Common.cells(state)) .. "S", iw),
      Common.getter(function()
        local p = level()
        return p
      end, function(p)
        if p == nil then return "--%" end
        return string.format("%d%%", math.floor(p + 0.5))
      end),
      function()
        if state.mainPowerLost == true then return C.crit end
        local _, fill = level()
        if fill == C.bar_crit then return C.crit end
        if fill == C.bar_low then return C.warn end
        return C.text
      end, "100%",
      Common.getter(Common.field(state, "consumedMah"), function(v)
        if v == nil then return "- " .. T.mah end
        return string.format("%d ", math.floor(v + 0.5)) .. T.mah
      end))

  elseif kind == "ftime" then
    cardBody(nodes, g, x, y, w, h, Common.fitLabel(g.sml, T.flight_time, iw),
      Common.getter(Common.field(state, "flightSeconds"), Common.duration), nil, "88:88")

  elseif kind == "ttime" then
    cardBody(nodes, g, x, y, w, h, Common.fitLabel(g.sml, T.total_time, iw),
      Common.getter(Common.field(state, "totalFlightSeconds"), Common.longDuration), nil, "999:59:59")

  elseif kind == "image" then
    -- The picture, top-anchored at its own aspect ratio, with the totals under it -- which go first
    -- where the card is too flat for both. In full screen the picture is built into the card's
    -- button, against its content area, so a press on it reaches the button whatever the picture
    -- does with one.
    local footH = 2 * g.smlH + 2
    local showFoot = h >= footH + 2 * g.smlH + 12
    local slotH = math.max(8, h - (showFoot and (footH + 10) or 8))
    local slotW = math.max(1, w - 8)
    local path = Common.modelImage(state)
    local imgW, imgH = slotW, slotH
    local bw, bh = Common.imageSize(path)
    if bw and bh then
      local scale = math.min(slotW / bw, slotH / bh)
      imgW = math.max(1, math.floor(bw * scale))
      imgH = math.max(1, math.floor(bh * scale))
    end
    local image = { type = "image", x = x + 4 + math.floor((slotW - imgW) / 2), y = y + 4, w = imgW, h = imgH,
      file = path, fill = false }
    if at ~= nil then
      local insetX, insetY = L.buttonInset()
      image.x, image.y = image.x - x - insetX, image.y - y - insetY
      nodes[at].children = { image }
    else
      nodes[#nodes + 1] = image
    end
    if showFoot then
      imageFooter(nodes, state, g, x, y + h - footH - 4, w, footH)
    end

  elseif kind == "value" then
    local def = entry.def
    local name, unit = caption(state, def, g.showUnits)
    local chip = chipGetter(state, def, Common.textWidth(g.sml, chipSample(def)) > iw)
    cardBody(nodes, g, x, y, w, h, fitCaption(g.sml, name, unit, iw),
      def.make(state), def.color and def.color(state) or nil, def.sample, chip)
  end
end

-- The left column's three cards. A card's HEIGHT belongs to its POSITION, never to its content, so
-- a reading added to the catalogue only has to scale into a rectangle that already exists. Their
-- shares are 54 / 14 / 32 of the column; a position set to Off gives its share to the others in
-- proportion, so nothing gapes and the heights depend on HOW MANY cards are on, never on WHICH
-- content they show. The middle card keeps room for one line and the bottom one for a caption and
-- a line under the figure.
local LEFT_SHARE = { 0.54, 0.14, 0.32 }

local function leftColumn(nodes, state, cfg, g, x, y, w, h, ctx)
  local entries, shown, onCount, shareSum = {}, {}, 0, 0
  for i = 1, 3 do
    entries[i] = L.resolveCard(cfg, i)
    if entries[i].kind ~= "none" then
      shown[i] = true
      onCount = onCount + 1
      shareSum = shareSum + LEFT_SHARE[i]
    end
  end
  if onCount == 0 or w <= 0 or h <= 0 then return end
  local floors = { 0, g.smlH + 8, g.smlH + 18 }
  local avail = h - (onCount - 1) * CARD_GAP
  local heights, fixed, flex = { 0, 0, 0 }, 0, 0
  for i = 1, 3 do
    if shown[i] then
      if avail * LEFT_SHARE[i] / shareSum < floors[i] then
        heights[i] = floors[i]
        fixed = fixed + floors[i]
      else
        heights[i] = -1
        flex = flex + LEFT_SHARE[i]
      end
    end
  end
  local total = 0
  for i = 1, 3 do
    if heights[i] == -1 then
      heights[i] = math.max(1, math.floor(math.max(1, avail - fixed) * LEFT_SHARE[i] / flex))
    end
    total = total + heights[i]
  end
  -- Every position on its floor can still overshoot -- a small widget zone -- and an overshooting
  -- column runs into the strip: the whole column is scaled back rather than one card overflowing.
  if total > avail then
    for i = 1, 3 do
      if heights[i] > 0 then heights[i] = math.max(1, math.floor(heights[i] * avail / total)) end
    end
  end
  local cy = y
  for i = 1, 3 do
    if shown[i] then
      drawCard(nodes, state, g, entries[i], x, cy, w, heights[i], ctx)
      cy = cy + heights[i] + CARD_GAP
    end
  end
end

-- The big card, with a side column of its own at its right: the most the reading reached in this
-- flight where the record keeps a most, and the throttle under it. The side column belongs to the
-- POSITION, so it is there whatever the card shows.
local BIG_SHARE = 0.46
local SIDE_SHARE = 0.34

local function bigCard(nodes, state, cfg, g, x, y, w, h, ctx)
  local entry = L.resolveCard(cfg, 4)
  if entry.kind == "none" then return end
  local sideW = math.floor(w * SIDE_SHARE)
  if sideW <= 30 then sideW = 0 end
  drawCard(nodes, state, g, entry, x, y, w, h, ctx, w - sideW)
  if sideW == 0 then return end
  local sideX = x + w - sideW
  local valueW = math.min(sideW - 16, Common.textWidth(g.sml, "88888") + 6)
  local labelW = math.max(1, sideW - 10 - valueW)
  local rowY = y + math.floor(h * 0.30)
  local def = entry.def
  if entry.kind == "value" and (def.maxKey or def.rawRange) then
    local read
    if def.rawRange then
      local highName = def.source .. "+"
      read = function()
        local d = state.derived
        local v = d and d[highName]
        if type(v) ~= "number" then return nil end
        return v
      end
    else
      read = extremeReader(state, def.maxKey, def.perCell and Common.cells(state) or nil)
    end
    Common.label(nodes, sideX, rowY, labelW, g.smlH, Common.fitLabel(g.sml, T.max, labelW), g.sml, C.label, LEFT)
    Common.label(nodes, sideX + labelW, rowY, valueW, g.smlH,
      Common.scaledGetter(read, def.places or 0), g.sml, C.text, RIGHT)
    rowY = rowY + g.smlH + 4
  end
  Common.label(nodes, sideX, rowY, labelW, g.smlH, Common.fitLabel(g.sml, T.throttle, labelW), g.sml, C.label, LEFT)
  Common.label(nodes, sideX + labelW, rowY, valueW, g.smlH, Common.throttleText(state), g.sml, C.text, RIGHT)
end

-- The value row: one card with up to four columns, each a caption over a figure over its range.
-- A column set to Off drops out and the rest share the width. Every figure shares ONE face, fitted
-- by pixel width to the widest figure among the columns that are drawn, so the row reads even; a
-- reading in words takes the largest face up to the shared one in which its own sample fits. The
-- range is "least .. most" where the columns are wide enough for the widest range among the
-- columns drawn, the most alone (after the word for it) where only that fits, and nothing where
-- neither does -- decided once for the row from the readings' own samples, so every column reads
-- the same way. A range that does not fit would wrap and be cut off
-- by the row. In full screen, on a host with theme views, the row is
-- the press that opens the telemetry view, which shows the same readings and more.
local function valueRow(nodes, state, cfg, g, x, y, w, h, ctx)
  local slots = {}
  for i = 1, L.VALUE_COUNT do
    local def = L.resolveValue(cfg, i)
    if def ~= nil then slots[#slots + 1] = def end
  end
  if #slots == 0 or w <= 0 or h <= g.smlH + 12 then return end
  local asLines = hasViews(ctx)
  cardFrame(nodes, x, y, w, h, ctx, "openView:deck_telemetry")
  local n = #slots
  local colW = math.floor((w - 2 * CARD_PAD) / n)
  local textW = math.max(1, colW - 10)
  local chipH = g.smlH
  local valAvailH = math.max(12, h - g.smlH - chipH - 14)

  local sample, sampleW = "8888", Common.textWidth(g.sml, "8888")
  for i = 1, n do
    local s = slots[i].sample
    if isFigure(s) then
      local sw = Common.textWidth(g.sml, s)
      if sw > sampleW then sample, sampleW = s, sw end
    end
  end
  local valueFont = Common.selectFont(valAvailH, colW - 12, sample)
  local valueH = Common.measure(valueFont, sample)
  local compact, noChip = false, false
  for i = 1, n do
    local def = slots[i]
    if (def.rawRange or def.minKey or def.maxKey) and Common.textWidth(g.sml, chipSample(def)) > textW then
      compact = true
      break
    end
  end
  if compact then
    local prefix = T.max .. " "
    for i = 1, n do
      local def = slots[i]
      if (def.rawRange or def.maxKey) and Common.textWidth(g.sml, prefix .. (def.perCell and "4.20" or def.sample)) > textW then
        noChip = true
        break
      end
    end
  end

  for i = 1, n do
    local def = slots[i]
    local cx = x + CARD_PAD + (i - 1) * colW
    if i > 1 then
      local lx = cx
      if asLines then
        nodes[#nodes + 1] = { type = "line", x = 0, y = 0, w = 0, h = 0,
          pts = { { lx, y + 5 }, { lx, y + h - 6 } }, color = C.line, thickness = 1 }
      else
        Common.rect(nodes, lx, y + 5, 1, math.max(1, h - 10), C.line, true)
      end
    end
    local name, unit = caption(state, def, g.showUnits)
    Common.label(nodes, cx + 5, y + 5, textW, g.smlH, fitCaption(g.sml, name, unit, textW), g.sml, C.label, LEFT)
    local font, fontH = valueFont, valueH
    if not isFigure(def.sample) then
      font = Common.selectFont(valAvailH, colW - 12, def.sample, valueFont)
      fontH = Common.measure(font, def.sample)
    end
    Common.label(nodes, cx + 6, y + 5 + g.smlH + math.max(0, math.floor((h - 10 - g.smlH - chipH - fontH) / 2)),
      math.max(1, colW - 12), fontH, def.make(state), font, def.color and def.color(state) or C.text, CENTER)
    local chip = (not noChip) and chipGetter(state, def, compact) or nil
    if chip ~= nil then
      Common.label(nodes, cx + 5, y + h - chipH - 4, textW, chipH, chip, g.sml, C.label, CENTER)
    end
  end
end

-- ---------------------------------------------------------------------------
-- the battery strip
-- ---------------------------------------------------------------------------

-- A wide charge bar across the foot: a headline over it -- the word, the cell count, the pack
-- voltage and the capacity used -- with the percentage at its right end, and a 0 .. 100 % scale
-- under it. The fill reads the one fuel closure every place this theme draws the charge asks
-- (Common.fuelLevel), so the steps the pilot set, the orange of a pack that was not full when it
-- was plugged in and the empty reading of a main pack that is gone are the same here as on the
-- charge card.
local QUARTERS = { 25, 50, 75 }

-- The bar in lines, for the press over it in full screen: the same track, fill, ticks and outline
-- as the rectangles, at the same coordinates. A line's `y` is its middle and its `h` its thickness.
local function stripLines(nodes, x, y, w, h, read, color)
  local midY = y + math.floor(h / 2)
  nodes[#nodes + 1] = { type = "hline", x = x, y = midY, w = w, h = h, color = C.track }
  nodes[#nodes + 1] = { type = "hline", x = x, y = midY, w = 1, h = h, color = color, size = barLength(read, w, h) }
  for i = 1, #QUARTERS do
    vline(nodes, x + math.floor(w * QUARTERS[i] / 100), y + 1, y + h - 2, C.tick, 1)
  end
  local x1, y1 = x + w - 1, y + h - 1
  local edges = {
    { { x, y }, { x1, y } }, { { x, y1 }, { x1, y1 } },
    { { x, y }, { x, y1 } }, { { x1, y }, { x1, y1 } },
  }
  for i = 1, 4 do
    nodes[#nodes + 1] = { type = "line", x = 0, y = 0, w = 0, h = 0, pts = edges[i], color = C.line, thickness = 1 }
  end
end

function L.battStrip(nodes, state, g, x, y, w, barH, ctx)
  local level = Common.fuelLevel(state)
  local stripH = g.smlH + 2 + barH + 1 + g.smlH
  if hasViews(ctx) then
    local action = ctx.action
    tapArea(nodes, x, y, w, stripH, function() action("openView:deck_battery") end)
  end
  local pctW = math.max(30, math.floor(w * 0.14))
  local cells = Common.cells(state)
  local head = T.view_battery .. " " .. tostring(cells) .. "S   "
  local headSample = T.view_battery .. " 12S   88.8V   8888 " .. T.mah_used
  local headFont = Common.selectFont(g.smlH, w - pctW - 8, headSample)
  local headH = Common.measure(headFont, headSample)
  -- One string over two readings, formatted once per change of either: the voltage at the tenth it
  -- is printed with, and the capacity used.
  local lastV, lastMah, headText = Common.UNSET, Common.UNSET, ""
  Common.label(nodes, x, y, w - pctW - 4, headH, function()
    local v = num(state.voltage)
    if v ~= nil then v = math.floor(v * 10 + 0.5) end
    local mah = num(state.consumedMah)
    if mah ~= nil then mah = math.floor(mah + 0.5) end
    if v == lastV and mah == lastMah then return headText end
    lastV, lastMah = v, mah
    headText = head .. ((v ~= nil) and string.format("%.1fV", v / 10) or "-")
      .. "   " .. ((mah ~= nil) and string.format("%d ", mah) or "- ") .. T.mah_used
    return headText
  end, headFont, C.label, LEFT)
  Common.label(nodes, x + w - pctW, y, pctW, g.smlH,
    Common.getter(function()
      local p = level()
      return p
    end, function(p)
      if p == nil then return "--%" end
      return string.format("%d%%", math.floor(p + 0.5))
    end), g.sml, Common.packColor(state, C.text), RIGHT)

  local barY = y + g.smlH + 2
  local fill = function()
    local p = level()
    return p
  end
  local color = function()
    local _, c = level()
    return c
  end
  if hasViews(ctx) then
    stripLines(nodes, x, barY, w, barH, fill, color)
  else
    Common.hbar(nodes, x, barY, w, barH, fill, color, QUARTERS)
  end

  -- The 0 / 25 / 50 / 75 / 100 % scale.
  local scaleY = barY + barH + 1
  local labelW = math.max(20, math.floor(w * 0.14))
  Common.label(nodes, x, scaleY, labelW, g.smlH, "0%", g.sml, C.label, LEFT)
  for i = 1, #QUARTERS do
    local p = QUARTERS[i]
    Common.label(nodes, x + math.floor(w * p / 100) - math.floor(labelW / 2), scaleY, labelW, g.smlH,
      string.format("%d%%", p), g.sml, C.label, CENTER)
  end
  Common.label(nodes, x + w - labelW, scaleY, labelW, g.smlH, "100%", g.sml, C.label, RIGHT)
end

-- ---------------------------------------------------------------------------
-- the statistics view's bar
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

-- The arming override of the statistics view's bar: while the flight controller names reasons that
-- block arming, the whole bar gives way to "Arming Disabled: <reason>", one reason at a time,
-- two seconds each, in the WARNING colour. The returned function is the visibility the bar's
-- ordinary labels take in the meantime. getTime is the radio's tick counter, not one of the
-- probes a closure may not make.
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

-- Four zones: the header, a left column of three cards, a right column with the big card over the
-- value row, and the battery strip at the foot. The left column takes 35 % of the content width.
-- The big card takes 46 % of the right column's height when it is on; off, the value row takes the
-- whole column.
--
-- The header is 7.5 % of the height (at least 18 px), its box two pixels shorter, and nothing is
-- reserved for controls: the two controls this theme draws sit inside the header. The small face
-- every caption, range and the strip are set in follows the SCREEN, not the card, so every caption
-- on the panel is set in one face.
local LEFT_WIDTH = 0.35

function L.buildFlight(zone, state, ctx)
  local nodes = {}
  local x0, y0, w, h = zone.x or 0, zone.y or 0, zone.w or 0, zone.h or 0
  if w <= 0 or h <= 0 then return nodes end
  -- The scheme FIRST, before a single node is appended: every colour below, in a node and in
  -- a closure alike, is then the one the pilot chose. It is a build-time reading and needs no
  -- term in the render key -- the host reloads the theme when its preferences change.
  local cfg = state.themeConfig or {}
  Common.applyScheme(cfg.scheme)
  Common.applyFrames(state.themeConfig)
  Common.beginBuild(zone)
  L.bindKeys(state, ctx)

  local barH = math.max(18, math.floor(h * 0.075))
  local boxH = math.max(1, barH - 2)
  local font = Common.selectFont(boxH, nil, T.total_time)
  local fontH = Common.measure(font, T.total_time)
  local sml = Common.selectFont(math.max(8, math.floor(h * 0.05)), math.floor(w * 0.14), S_CHIP)
  local g = { sml = sml, smlH = Common.measure(sml, S_CHIP), showUnits = setting(state, "units") == "on" }

  local contentW = w - 2 * OUTER_PAD
  local stripBarH = math.max(8, math.floor(h * 0.055))
  local stripH = g.smlH + 2 + stripBarH + 1 + g.smlH
  local yContent = y0 + OUTER_PAD + barH + CARD_GAP
  local yStrip = y0 + h - OUTER_PAD - stripH
  local contentH = math.max(30, yStrip - CARD_GAP - yContent)

  local leftX = x0 + OUTER_PAD
  local leftW = math.floor(contentW * LEFT_WIDTH)
  local rightX = leftX + leftW + CARD_GAP
  local rightW = math.max(0, x0 + w - OUTER_PAD - rightX)

  Common.rect(nodes, x0, y0, w, h, C.bg, true)
  L.header(nodes, state, x0, y0 + 2, w - 4, boxH, font, fontH, ctx)

  leftColumn(nodes, state, cfg, g, leftX, yContent, leftW, contentH, ctx)

  if rightW > 0 then
    local bigOn = L.resolveCard(cfg, 4).kind ~= "none"
    local bigH = bigOn and math.floor(contentH * BIG_SHARE) or 0
    if bigOn then
      bigCard(nodes, state, cfg, g, rightX, yContent, rightW, bigH, ctx)
    end
    local valuesY = yContent + bigH + (bigOn and CARD_GAP or 0)
    valueRow(nodes, state, cfg, g, rightX, valuesY, rightW, yContent + contentH - valuesY, ctx)
  end

  L.battStrip(nodes, state, g, x0 + OUTER_PAD + 2, yStrip, contentW - 4, stripBarH, ctx)
  return nodes
end

-- ---------------------------------------------------------------------------
-- the statistics view
-- ---------------------------------------------------------------------------

-- The statistics view: the header without its link cluster across the top, the model and its totals
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
    -- The least the pack reached against the theme's own minimum (`v_min`). Without a minimum on
    -- file there is nothing to compare with and the figure carries no closure at all.
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

  -- The header as the flight view has it, so the two screens share their top (see
  -- L.buildFlight). The table and the line beneath it are set in the same face, and the bar at the
  -- foot is the statistics bar.
  local barH = math.max(18, math.floor(h * 0.075))
  local boxH = math.max(1, barH - 2)
  local font = Common.selectFont(boxH, nil, T.total_time)
  local fontH = Common.measure(font, T.total_time)
  local textFont, textH = font, fontH

  local contentW = w - 2 * OUTER_PAD
  local xContent = x0 + OUTER_PAD
  local yContent = y0 + OUTER_PAD + barH + CARD_GAP
  local yStatus = y0 + h - OUTER_PAD - barH
  local infoH = textH + 6
  local yInfo = yStatus - CARD_GAP - infoH
  local tableH = math.max(1, yInfo - CARD_GAP - yContent)

  Common.rect(nodes, x0, y0, w, h, C.bg, true)
  L.header(nodes, state, x0, y0 + 2, w - 4, boxH, font, fontH, ctx, false)
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
  Common.hline(nodes, xContent, yStatus - 1, contentW)

  -- The statistics bar. That the flight controller has stopped answering is said by the table's
  -- header row ("Disconnected"), which reads the phase per frame.
  L.statsStatusBar(nodes, state, x0, yStatus, w - 4, boxH, font, fontH, lastStat)
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
-- geometry or one of the build-time readings changes: the zone, the cell count the battery
-- figures are stated in, the model picture, the TX battery the pill was painted from, and which
-- sensor answered for the link -- which decides whether the RQ bar can fill at all.
-- Without a key of its own a free-form theme is built once and never again, and a model
-- change would leave the previous picture up. A slot change needs no term here: the
-- preference watcher reloads the theme and clears `built` itself. The phase is in the key
-- although the host reloads the theme on every mode change -- one tostring, and the key then
-- stays right on a host that stops doing so.
--
-- The battery pick's `pending` is a build-time reading for the same reason: the battery profile's
-- word under the model picture is coloured at build time, so without the term the warn colour would never
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
  return "deck"
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
    .. "|" .. tostring(state and state.lqSource or "")
end

if type(_G) == "table" then _G.__rfsuiteThemeDeckLayoutModule = L end

return L
