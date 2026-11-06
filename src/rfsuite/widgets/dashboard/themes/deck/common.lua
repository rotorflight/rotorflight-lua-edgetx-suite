-- Shared drawing helpers for this theme.
--
-- The theme is free-form: flight.lua and postflight.lua export a build(zone, state) that
-- returns the LVGL node list itself instead of a layout/boxes grid, which is the branch
-- widgets/dashboard/runtime.lua takes where it tests type(self.theme.build) == "function".
-- Everything below therefore appends nodes with absolute coordinates to one flat list -- no
-- nesting, so no node's position depends on a parent's.
--
-- Three cost classes, and every helper here belongs to exactly one of them:
--
--   build  runs once per rebuild, in a JOB pass of its own together with the host's MSP pump
--          quantum and the FIRST reactive sweep of the new tree. Geometry, font selection and
--          every firmware probe (lcd.sizeText, getValue, io.open) happen here, never in a
--          closure; the render key repeats only the one read it needs. A rebuild is triggered
--          by the render key alone, so the build's cost is paid exactly as often as the key
--          moves.
--   sweep  the function fields handed to lvgl.build (text, color, size) run in the firmware's
--          reactive sweep, per frame and outside the widget's own pcall. They read `state` and
--          nothing else, they probe nothing, and they format one string per value change --
--          M.getter is the shape, and a closure that is not a getter still keeps to the rule.
--   key    the render key runs every 0.5 s inside the host's STATE pass, the pass that is
--          already the most expensive one the widget has. It reads what the build read, and
--          nothing that a closure could read instead.

if type(_G) == "table" and type(_G.__rfsuiteThemeDeckCommonModule) == "table" then
  return _G.__rfsuiteThemeDeckCommonModule
end

local M = {}

-- The shipped default theme's helper is deliberately NOT loaded here. It would supply the
-- cell-count estimate and the duration format, and it costs a whole module -- its own i18n
-- machinery included -- executed in the STATE pass that reloads the theme, which is the pass
-- the connect chain runs in. The two functions are restated below, to the letter of the
-- shipped ones, so the theme loads nothing outside its own folder.

-- ---------------------------------------------------------------------------
-- labels
-- ---------------------------------------------------------------------------

-- Every fixed string the panels draw, in one table, so a panel names a string and never spells
-- it. The words are translation markers in the suite's own translation files, which the
-- packager resolves into each locale's build; the firmware's identifiers, the units and the
-- sensor names beside them are not words and stand as they are. The source catalogue in
-- layout.lua keeps its own labels because the configure page lists them as options, and those
-- two must stay one list.
--
-- Where the suite already names the same thing in the same case, its key is used rather than a
-- second one: the flight-log viewer's column names, the flight statistics' total, the audio
-- events' governor states, the status page's arming-disable reasons.
M.T = {
  flights = "@i18n(widgets.dashboard.urban_flights)@",
  total_time = "@i18n(widgets.dashboard.urban_total_time)@",
  governor = "@i18n(app.pages.logs.tpl_governor)@",
  throttle = "@i18n(app.pages.logs.throttle_title)@",
  battery_profile = "@i18n(widgets.dashboard.urban_battery_profile)@",
  -- The shorter word where the full one does not fit the narrow third column.
  battery_profile_short = "@i18n(widgets.dashboard.urban_battery_profile_short)@",
  -- The arm card's state. Without a flight controller the craft's state is not known, so the
  -- card says so instead of claiming "Disarmed".
  armed = "@i18n(widgets.dashboard.urban_armed)@",
  disarmed = "@i18n(widgets.dashboard.urban_disarmed)@",
  no_fc = "@i18n(widgets.dashboard.urban_no_fc)@",
  tpwr = "TPWR",
  skp = "Skp",
  arming_disabled = "@i18n(widgets.dashboard.urban_arming_disabled)@: ",
  -- The statistics view's status bar: the flight's extremes of the link, each marked with the
  -- direction of the extreme, `-` the least and `+` the most.
  tpwr_stat = "TPWR",
  rqly_min = "RQly-",
  mcu_max = "Tmcu+",
  -- The throttle cell off the ground: disarmed it is safe, and without a link nothing is known.
  throttle_safe = "@i18n(widgets.dashboard.urban_throttle_safe)@",
  throttle_unknown = "**",
  model_fallback = "Rotorflight",
  mah = "mAh",
  -- The statistics view: its table rows, the three column heads, the link's state over the
  -- label column, and the totals and the line beneath the table.
  flight_time = "@i18n(app.pages.logs.flight_duration)@",
  total_flight_time = "@i18n(app.pages.setup_stats.totalflighttime)@",
  mah_used = "@i18n(widgets.dashboard.urban_mah_used)@",
  cell_voltage = "@i18n(widgets.dashboard.urban_cell_voltage)@",
  current = "@i18n(app.pages.logs.current_title)@",
  esc_temp = "@i18n(app.pages.logs.temp_title)@",
  bec_voltage = "@i18n(widgets.dashboard.urban_bec_voltage)@",
  latest = "@i18n(widgets.dashboard.urban_latest)@",
  min = "@i18n(app.pages.logs.min)@",
  max = "@i18n(app.pages.logs.max)@",
  state_armed = "@i18n(widgets.dashboard.urban_armed)@",
  state_disarmed = "@i18n(widgets.dashboard.urban_disarmed)@",
  state_offline = "@i18n(widgets.dashboard.urban_disconnected)@",
  -- The two governor MODES the board runs no state machine in.
  gov_off = "@i18n(widgets.governor.MODE_OFF)@",
  gov_limit = "@i18n(widgets.governor.MODE_LIMIT)@",
  -- The main pack gone while the board still answers on its BEC.
  main_power_lost = "@i18n(app.pages.settings_audio_events.main_power_lost):upper()@",
  -- The voltage sag episodes of the last flight, and the headspeed band per PID profile.
  sags = "@i18n(widgets.dashboard.urban_sags)@",
  headspeed_profile = "@i18n(widgets.dashboard.urban_headspeed_profile)@",
  -- The governor states by the flight controller's own index, and the name for a state this
  -- table does not know. Read by M.governorText.
  gov_state_0 = "@i18n(app.pages.settings_audio_events.governor_state_thr_off)@",
  gov_state_1 = "@i18n(app.pages.settings_audio_events.governor_state_idle)@",
  gov_state_2 = "@i18n(app.pages.settings_audio_events.governor_state_spoolup)@",
  gov_state_3 = "@i18n(app.pages.settings_audio_events.governor_state_recovery)@",
  gov_state_4 = "@i18n(app.pages.settings_audio_events.governor_state_active)@",
  gov_state_5 = "@i18n(widgets.dashboard.urban_gov_throttle_hold)@",
  gov_state_6 = "@i18n(widgets.dashboard.urban_gov_fallback)@",
  gov_state_7 = "@i18n(app.pages.settings_audio_events.governor_state_autorot)@",
  gov_state_8 = "@i18n(app.pages.settings_audio_events.governor_state_bailout)@",
  gov_state_9 = "@i18n(app.pages.settings_audio_events.governor_state_bypass)@",
  gov_unknown = "@i18n(widgets.dashboard.urban_gov_unknown)@",
  -- The readable names of the arming-disable bits, for the statistics bar's override and the
  -- status view. The compact descriptors of the governor card's line (NOGYRO, BOOTGRACE, ...) are
  -- the firmware's identifiers and are not translated.
  arm_flag_0 = "@i18n(app.modules.fblstatus.arming_disable_flag_0)@",
  arm_flag_1 = "@i18n(app.modules.fblstatus.arming_disable_flag_1)@",
  arm_flag_2 = "@i18n(app.modules.fblstatus.arming_disable_flag_2)@",
  arm_flag_3 = "@i18n(app.modules.fblstatus.arming_disable_flag_3)@",
  arm_flag_4 = "@i18n(app.modules.fblstatus.arming_disable_flag_4)@",
  arm_flag_5 = "@i18n(app.modules.fblstatus.arming_disable_flag_5)@",
  arm_flag_6 = "@i18n(app.modules.fblstatus.arming_disable_flag_6)@",
  arm_flag_7 = "@i18n(app.modules.fblstatus.arming_disable_flag_7)@",
  arm_flag_8 = "@i18n(app.modules.fblstatus.arming_disable_flag_8)@",
  arm_flag_9 = "@i18n(app.modules.fblstatus.arming_disable_flag_9)@",
  arm_flag_10 = "@i18n(app.modules.fblstatus.arming_disable_flag_10)@",
  arm_flag_11 = "@i18n(app.modules.fblstatus.arming_disable_flag_11)@",
  arm_flag_12 = "@i18n(app.modules.fblstatus.arming_disable_flag_12)@",
  arm_flag_13 = "@i18n(app.modules.fblstatus.arming_disable_flag_13)@",
  arm_flag_14 = "@i18n(app.modules.fblstatus.arming_disable_flag_14)@",
  arm_flag_15 = "@i18n(app.modules.fblstatus.arming_disable_flag_15)@",
  arm_flag_16 = "@i18n(app.modules.fblstatus.arming_disable_flag_16)@",
  arm_flag_17 = "@i18n(app.modules.fblstatus.arming_disable_flag_17)@",
  arm_flag_18 = "@i18n(app.modules.fblstatus.arming_disable_flag_18)@",
  arm_flag_19 = "@i18n(app.modules.fblstatus.arming_disable_flag_19)@",
  arm_flag_20 = "@i18n(app.modules.fblstatus.arming_disable_flag_20)@",
  arm_flag_21 = "@i18n(app.modules.fblstatus.arming_disable_flag_21)@",
  arm_flag_22 = "@i18n(app.modules.fblstatus.arming_disable_flag_22)@",
  arm_flag_23 = "@i18n(app.modules.fblstatus.arming_disable_flag_23)@",
  arm_flag_24 = "@i18n(app.modules.fblstatus.arming_disable_flag_24)@",
  arm_flag_25 = "@i18n(app.modules.fblstatus.arming_disable_flag_25)@",
  arm_flag_26 = "@i18n(app.modules.fblstatus.arming_disable_flag_26)@",
  -- The full screen views (toolsview, linkview, telemview): their titles, what
  -- the theme's own menu says about the work it ran, the link view's row names, and what the
  -- telemetry view says when every tile is switched off.
  view_tools = "@i18n(widgets.dashboard.urban_profile_tuning)@",
  view_telemetry = "@i18n(widgets.dashboard.urban_telemetry)@",
  no_tiles = "@i18n(widgets.dashboard.urban_no_tiles)@",
  -- The status view (statusview.lua): its title, the arm word in capitals, what the line under it
  -- says while nothing blocks arming, and its event history -- the caption, the words for a
  -- connection made, and what the list says while it is empty. The speed controller's column
  -- carries the short name every language uses, as `tpwr` and `skp` do.
  view_status = "@i18n(widgets.dashboard.urban_status)@",
  armed_caps = "@i18n(widgets.dashboard.urban_armed):upper()@",
  disarmed_caps = "@i18n(widgets.dashboard.urban_disarmed):upper()@",
  ready_to_arm = "@i18n(widgets.dashboard.urban_ready_to_arm)@",
  event_log = "@i18n(widgets.dashboard.urban_event_log)@",
  connected = "@i18n(widgets.dashboard.urban_connected)@",
  no_events = "@i18n(widgets.dashboard.urban_no_events)@",
  esc = "ESC",
  active = "@i18n(widgets.dashboard.urban_active)@",
  unavailable = "@i18n(widgets.dashboard.urban_not_available)@",
  run_busy = "@i18n(widgets.dashboard.urban_sending)@",
  run_ok = "@i18n(widgets.dashboard.urban_done)@",
  run_failed = "@i18n(widgets.dashboard.urban_failed)@",
  -- The link view's title is the link protocol's name, and its rows carry short sensor names, the
  -- same in every language -- as `tpwr` and `skp` above. Its foot line names the flight's least
  -- link quality.
  view_link = "ELRS",
  link_rq = "RQ", link_tq = "TQ", link_rss1 = "1RSS", link_rss2 = "2RSS",
  -- The battery view (battview.lua): its title, the words of the cell limits under the bar, and
  -- the three figures of its foot line.
  view_battery = "@i18n(widgets.dashboard.urban_battery)@",
  batt_crit = "@i18n(widgets.dashboard.urban_batt_crit)@",
  batt_low = "@i18n(widgets.dashboard.urban_batt_low)@",
  batt_full = "@i18n(widgets.dashboard.urban_batt_full)@",
  batt_pack = "@i18n(widgets.dashboard.urban_batt_pack)@",
  batt_cell_min = "@i18n(widgets.dashboard.urban_cell_min)@",
  batt_reserve = "@i18n(widgets.dashboard.urban_reserve)@",
  link_trss = "TRSS", link_snr = "SNR",
  link_rq_min = "@i18n(widgets.dashboard.urban_rq_min)@",
}

-- The governor states' keys, built once: M.governorText and M.governorSample read them every
-- build or every change, and neither should concatenate a key to do it.
local GOV_STATE_KEYS = {}
for i = 0, 9 do GOV_STATE_KEYS[i] = "gov_state_" .. i end

-- The widest governor name of the package's language, which the governor cell is sized against
-- so no state of THAT language is clipped. Measured by byte length, which over-counts a
-- multi-byte character and errs towards the smaller face, never the clipped one.
function M.governorSample()
  local t, best = M.T, M.T.gov_unknown
  for i = 0, 9 do
    local s = t[GOV_STATE_KEYS[i]]
    if s and #s > #best then best = s end
  end
  if #t.gov_off > #best then best = t.gov_off end
  if #t.gov_limit > #best then best = t.gov_limit end
  return best
end

-- The first `n` bytes of `text`, moved back to the start of a UTF-8 character if the cut would
-- split one -- an accented letter is two bytes, and half of one draws as garbage.
function M.cutUtf8(text, n)
  if n >= #text then return text end
  if n < 0 then n = 0 end
  while n > 0 do
    local b = string.byte(text, n + 1)
    if b == nil or b < 0x80 or b >= 0xC0 then break end
    n = n - 1
  end
  return string.sub(text, 1, n)
end

-- ---------------------------------------------------------------------------
-- colours
-- ---------------------------------------------------------------------------

local function rgb(hex, fallback)
  if lcd and type(lcd.RGB) == "function" then
    local ok, col = pcall(lcd.RGB, math.floor(hex / 65536) % 256, math.floor(hex / 256) % 256, hex % 256)
    if ok and col then return col end
  end
  return fallback
end

-- The theme's two colour schemes, stored under `scheme`: `light`, the default, and `dark`,
-- role for role:
--
--   bg        the panel behind the cards
--   card      the surface of every card
--   text      every value
--   label     every caption and label -- black on the light scheme, as every theme's labels are
--   line      the outlines: the cards, the pill, the buttons of the views, separators
--   frame     the battery page's gauge, the link bars' outline
--   empty     the battery page's empty segments
--   track     the link bars' and the battery strip's empty track
--   tick      the threshold notches on the link bars and the strip, the units
--   disabled  "No FC connected"
--   warning   the arming reasons
--   accent    the battery profile's number under the model picture
--   ok / warn / crit / neut   the traffic light of the link bars, the arm state and the governor
--   bar_*     the battery fills: green, yellow at the low step, red at the critical one, and
--             orange for a pack that was not full when it was plugged in
--   vtx_*     the radio battery pill's two fills
--   ink       the figures over a filled bar or segment
--   pill_ink  the percentage on the radio battery pill
--
-- A scheme is a FUNCTION and not a table of hex numbers: a body only runs for the scheme that is
-- actually asked for. A Lua state draws one of the two, so the other's lcd.RGB calls -- C calls
-- behind a pcall -- are never paid. Load costs two closures and the two-row list below.
--
-- `M.C` is ONE table for the theme's whole life and applyScheme rewrites its FIELDS. Every
-- helper, every node and every per-frame closure holds that one table, so a scheme change
-- cannot leave half the tree on the previous palette.
local SCHEMES = {
  dark = function()
    return {
      bg = rgb(0x0C0E10, BLACK),
      card = rgb(0x1E242A, COLOR_THEME_SECONDARY2),
      text = rgb(0xF2F4F6, WHITE),
      label = rgb(0x9AA4AE, COLOR_THEME_DISABLED),
      line = rgb(0x4A545E, COLOR_THEME_SECONDARY1),
      frame = rgb(0x4A545E, COLOR_THEME_SECONDARY1),
      -- Light enough for the dark overlay ink: the battery page draws its figure in `ink` over
      -- these segments, and a segment is empty below its own step.
      empty = rgb(0x6A747E, COLOR_THEME_SECONDARY2),
      track = rgb(0x2A323A, COLOR_THEME_SECONDARY2),
      tick = rgb(0xC8CED4, COLOR_THEME_DISABLED),
      disabled = rgb(0xFFC400, 0xFFC000),
      warning = rgb(0xFF4550, 0xFF0000),
      accent = rgb(0x2ED16E, GREEN or 0x00FF00),
      ok = rgb(0x2ED16E, GREEN or 0x00FF00),
      warn = rgb(0xFFD24A, 0xFF8000),
      crit = rgb(0xFF4550, 0xFF0000),
      neut = rgb(0x8A9096, COLOR_THEME_DISABLED),
      bar_ok = rgb(0x2ED16E, GREEN or 0x00FF00),
      bar_low = rgb(0xFFD24A, 0xFFFF00),
      bar_warn = rgb(0xFF9030, 0xFF8000),
      bar_crit = rgb(0xFF4550, 0xFF0000),
      vtx_ok = rgb(0x2ED16E, GREEN or 0x00FF00),
      vtx_low = rgb(0xFF4550, 0xFF0000),
      ink = rgb(0x0C0E10, BLACK),
      pill_ink = rgb(0xF2F4F6, WHITE),
    }
  end,
  light = function()
    return {
      bg = rgb(0xF4F6F8, WHITE),
      card = rgb(0xE2E6EA, COLOR_THEME_SECONDARY2),
      text = rgb(0x14181C, BLACK),
      label = rgb(0x000000, BLACK),
      line = rgb(0xB0B8C0, COLOR_THEME_SECONDARY1),
      frame = rgb(0xB0B8C0, COLOR_THEME_SECONDARY1),
      empty = rgb(0xB0B8C0, COLOR_THEME_SECONDARY2),
      -- A shade darker than the card, so the battery strip's empty part reads on the panel.
      track = rgb(0xD0D6DC, COLOR_THEME_SECONDARY2),
      tick = rgb(0x2A3038, COLOR_THEME_DISABLED),
      disabled = rgb(0xF83C00, 0xFF8000),
      warning = rgb(0xE03030, 0xFF0000),
      accent = rgb(0x2E8BE0, COLOR_THEME_PRIMARY1),
      -- `ok` and `warn` are words as well as fills -- the arm state, the governor, a figure at its
      -- yellow step -- so on this light card they are a shade darker than the battery fills
      -- below: the bright amber of `bar_low` reads at about 1.4 : 1 against the card.
      ok = rgb(0x168A40, GREEN or 0x00FF00),
      warn = rgb(0xA06800, 0xFF8000),
      crit = rgb(0xE03030, 0xFF0000),
      neut = rgb(0x9AA2AA, COLOR_THEME_SECONDARY1),
      bar_ok = rgb(0x22C55E, GREEN or 0x00FF00),
      bar_low = rgb(0xF0C000, 0xFFFF00),
      bar_warn = rgb(0xF08000, 0xFF8000),
      bar_crit = rgb(0xE03030, 0xFF0000),
      vtx_ok = rgb(0x22C55E, GREEN or 0x00FF00),
      vtx_low = rgb(0xE03030, 0xFF0000),
      ink = rgb(0x14181C, BLACK),
      pill_ink = rgb(0x14181C, BLACK),
    }
  end,
}

-- What the configure page offers, in the order it offers it. The list is here rather than on
-- the page because the palettes are here: the page cannot offer a scheme this table has no
-- colours for, and applyScheme is never handed one the page never showed.
M.SCHEMES = {
  { id = "light", label = "@i18n(app.pages.settings_dashboard_settings.urban_scheme_light)@" },
  { id = "dark", label = "@i18n(app.pages.settings_dashboard_settings.urban_scheme_dark)@" },
}
M.DEFAULT_SCHEME = "light"

M.C = {}
local resolved = {}
local appliedScheme = nil

-- Called at the TOP of a build, before a single node is appended, so every colour a node
-- carries and every colour a closure reads per frame come from the same set. An unknown id
-- and an absent one both land on the theme's own default: a theme that trusts a preferences
-- file it did not write is a theme that draws in a colour nobody chose.
function M.applyScheme(id)
  if SCHEMES[id] == nil then id = M.DEFAULT_SCHEME end
  if id == appliedScheme then return id end
  appliedScheme = id
  local colors = resolved[id]
  if colors == nil then
    colors = SCHEMES[id]()
    resolved[id] = colors
  end
  local dst = M.C
  for k, v in pairs(colors) do dst[k] = v end
  return id
end

M.applyScheme(M.DEFAULT_SCHEME)

-- ---------------------------------------------------------------------------
-- fonts and text metrics
-- ---------------------------------------------------------------------------

-- Built from what the firmware actually exports: XLSIZE is present on some builds and not
-- on others, and a nil font constant renders at the default size without complaining.
local FONTS = {}
do
  -- Largest first, TINSIZE at the foot.
  local order = { "XXLSIZE", "XLSIZE", "DBLSIZE", "MIDSIZE", "STDSIZE", "SMLSIZE", "TINSIZE" }
  for i = 1, #order do
    local value = _G[order[i]]
    if order[i] == "STDSIZE" and type(value) ~= "number" then value = 0 end
    if type(value) == "number" then FONTS[#FONTS + 1] = value end
  end
  if #FONTS == 0 then FONTS[1] = 0 end
end

-- lcd.sizeText is a firmware call that lays the text out to measure it, and a build makes
-- dozens of them -- every one against a sample string that is a constant of the code and a
-- zone that does not change between two rebuilds. So the answers are kept, keyed by the zone
-- they were measured in: the first build in a zone pays them, every rebuild after it pays
-- none. The cache is bounded by construction -- its keys are the (font, sample) pairs the code
-- contains, not anything a value or a pilot supplies -- and it is dropped whole when the zone
-- changes, so a resize measures afresh. Anything measured against a DYNAMIC string (a model
-- name in M.fitFont) bypasses it, or the cache would grow with the data.
-- Three tables keyed by the sample string, then by a number -- the font, or the height and
-- width packed into one integer -- so a lookup builds no string of its own.
local metricZoneW, metricZoneH = nil, nil
local heights, widths, fonts, fits = {}, {}, {}, {}

function M.beginBuild(zone)
  local w, h = zone and zone.w or 0, zone and zone.h or 0
  if w ~= metricZoneW or h ~= metricZoneH then
    metricZoneW, metricZoneH = w, h
    heights, widths, fonts, fits = {}, {}, {}, {}
  end
end

local function rawSize(text, font)
  local w, h = lcd.sizeText(text, font)
  return w or 0, h or 10
end

-- The lookups below are written out rather than shared through a helper: they run dozens of
-- times per build, and a function call per lookup would give back part of what the cache saves.
function M.measure(font, sample)
  local text = sample or "X"
  local entry = heights[text]
  if entry == nil then
    entry = {}
    heights[text] = entry
  end
  local h = entry[font]
  if h == nil then
    local _, mh = lcd.sizeText(text, font)
    h = mh or 10
    entry[font] = h
  end
  return h
end

-- The width half of the same call, for a sample string that is a constant of the code.
function M.textWidth(font, sample)
  local text = sample or ""
  local entry = widths[text]
  if entry == nil then
    entry = {}
    widths[text] = entry
  end
  local w = entry[font]
  if w == nil then
    w = lcd.sizeText(text, font) or 0
    entry[font] = w
  end
  return w
end

-- The longest prefix of `text` that still fits `maxW`, with two dots marking what was cut.
-- Measured raw: the text may be data, so it must not enter the cache.
--
-- Found by halving rather than by shortening a byte at a time from the end. A prefix with its
-- two dots never gets narrower as the prefix grows, so the longest one that fits takes about
-- log2 of the length in measurements instead of one per byte cut away -- which is what a long
-- text in a narrow box costs, the arming override's reasons in a longer language above all. Every
-- candidate goes through M.cutUtf8, so a cut still never splits a multibyte character, and the
-- answer is the one the walk from the end would have stopped at.
function M.fit(font, text, maxW)
  text = tostring(text or "")
  if type(maxW) ~= "number" or maxW <= 0 then return text end
  if rawSize(text, font) <= maxW then return text end
  -- The largest n in 1 .. #text - 1 whose cut fits; none leaves the two dots alone.
  local lo, hi, best = 1, #text - 1, nil
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local cut = M.cutUtf8(text, mid) .. ".."
    if rawSize(cut, font) <= maxW then
      best, lo = cut, mid + 1
    else
      hi = mid - 1
    end
  end
  return best or ".."
end

-- Largest font whose sample fits both the height and the width on offer. Two pixels of
-- overshoot are tolerated in height, which is what keeps a 20 px status bar off the
-- smallest face on a 480x272 screen.
--
-- `maxFont` is the largest face the caller will take at all, whatever room there is -- the
-- statistics view uses it to keep the totals beside the model name from outgrowing the name. A
-- font the firmware does not export caps nothing.
function M.selectFont(availH, availW, sample, maxFont)
  local text = sample or "X"
  local entry = fonts[text]
  if entry == nil then
    entry = {}
    fonts[text] = entry
  end
  local first = 1
  if maxFont ~= nil then
    for i = 1, #FONTS do
      if FONTS[i] == maxFont then first = i break end
    end
  end
  -- Height, width and the cap in one integer key; a screen is nowhere near 4096 px either way,
  -- a nil width takes the slot no real width can, and there are fewer than eight faces.
  local key = (availH * 4096 + (availW or 4095)) * 8 + first
  local cached = entry[key]
  if cached ~= nil then return cached end
  local chosen = FONTS[#FONTS]
  for i = first, #FONTS do
    local w, h = lcd.sizeText(text, FONTS[i])
    w, h = w or 0, h or 10
    if h <= (availH + 2) and (not availW or w <= availW) then
      chosen = FONTS[i]
      break
    end
  end
  entry[key] = chosen
  return chosen
end

-- M.fit for a string that is a constant of the code rather than data -- a value row's name in
-- the package's language, a bounded set -- so its answer can be kept with the zone's other
-- measurements, and a rebuild in the same zone measures nothing. A name that fits costs one cached
-- width lookup.
function M.fitLabel(font, text, maxW)
  if M.textWidth(font, text) <= maxW then return text end
  -- Kept per text, per face and per width. The face is a key of its own: the size flags are
  -- multiples of 256, so folding them into one number with the width lost them, and a cut made
  -- for a small face was handed back for a larger one at the same width.
  local entry = fits[text]
  if entry == nil then
    entry = {}
    fits[text] = entry
  end
  local byFont = entry[font]
  if byFont == nil then
    byFont = {}
    entry[font] = byFont
  end
  local cut = byFont[maxW]
  if cut == nil then
    cut = M.fit(font, text, maxW)
    byFont[maxW] = cut
  end
  return cut
end

-- The largest face, at most `maxFont`, in which a DYNAMIC string fits -- the model's name, which
-- is sized against the name itself rather than against a sample. Measured raw, like M.fit, so the
-- string never enters the metrics cache and the cache cannot grow with the number of models on
-- the radio. At most one lcd.sizeText per face, once per build of the one view that asks.
function M.fitFont(availH, availW, text, maxFont)
  local first = 1
  if maxFont ~= nil then
    for i = 1, #FONTS do
      if FONTS[i] == maxFont then first = i break end
    end
  end
  for i = first, #FONTS do
    local w, h = rawSize(tostring(text or ""), FONTS[i])
    if h <= (availH + 2) and w <= availW then return FONTS[i] end
  end
  return FONTS[#FONTS]
end

-- ---------------------------------------------------------------------------
-- nodes
-- ---------------------------------------------------------------------------

function M.label(nodes, x, y, w, h, text, font, color, align)
  nodes[#nodes + 1] = {
    type = "label", x = x, y = y, w = w, h = h,
    text = text, font = font, color = color or M.C.text, align = align or CENTER
  }
end

function M.rect(nodes, x, y, w, h, color, filled, rounded, thickness)
  nodes[#nodes + 1] = {
    type = "rectangle", x = x, y = y, w = w, h = h,
    color = color, filled = filled and true or false,
    rounded = rounded or 0, thickness = thickness or (filled and 0 or 1)
  }
end

function M.hline(nodes, x, y, w, color)
  M.rect(nodes, x, y, w, 1, color or M.C.line, true)
end

-- A card as the widget zone draws it: the card surface with a hairline outline over it. In full
-- screen a card that takes a press is drawn by layout.lua instead -- a button in the card colour
-- with its outline as lines -- because a rectangle over a press takes the press away from it.
M.CARD_R = 6

function M.card(nodes, x, y, w, h, outline)
  M.rect(nodes, x, y, w, h, M.C.card, true, M.CARD_R)
  M.rect(nodes, x, y, w, h, outline or M.C.line, false, M.CARD_R, 1)
end

-- A horizontal fill bar with tick marks at `marks` percent: a track, one fill rectangle whose
-- width is reactive, the ticks and an outline. `fill` answers 0..100 or nil and `color` the fill
-- colour; both are the caller's and already memoised, so the per-frame cost is two closures and
-- a clamp. Nil draws the narrowest fill: the node list is fixed at build time.
function M.hbar(nodes, x, y, w, h, fill, color, marks)
  M.rect(nodes, x, y, w, h, M.C.track, true, 2)
  nodes[#nodes + 1] = {
    type = "rectangle", x = x, y = y, w = 1, h = h, filled = true, rounded = 2,
    color = color,
    size = function()
      local p = fill()
      if type(p) ~= "number" then return 1, h end
      if p < 0 then p = 0 elseif p > 100 then p = 100 end
      return math.max(1, math.floor(w * p / 100)), h
    end
  }
  if marks ~= nil and h >= 6 then
    for i = 1, #marks do
      M.rect(nodes, x + math.floor(w * marks[i] / 100), y + 1, 1, h - 2, M.C.tick, true)
    end
  end
  M.rect(nodes, x, y, w, h, M.C.line, false, 2, 1)
end

-- Whether the firmware's own frame shows around this theme's buttons, as the pilot chose it on the
-- Look page (`tap_frames`, layout.lua L.SETTINGS). Set at the start of every build, as the colour
-- scheme is, because one module serves the flight view, the statistics view and every view.
M.tapFrames = true

function M.applyFrames(themeConfig)
  M.tapFrames = not (type(themeConfig) == "table" and themeConfig.tap_frames == "off")
end

-- A press: a `button` the size of the area, filled in `fill`. Everything the caller draws over it
-- has to be labels and lines -- on the full screen surface a rectangle takes a press and hands it
-- to its parent.
--
-- EdgeTX draws every button with a frame of its own: a 2 px border in the radio theme's secondary
-- colour, the light blue of the default theme, with rounded corners
-- (radio/src/gui/colorlcd/libui/button.cpp, etx_btn_style; etx_lv_theme.cpp, etx_std_settings,
-- PAD_BORDER). A Lua button takes no border parameter, its `color` is the fill alone, and no
-- other Lua object takes a press (radio/src/lua/lua_lvgl_widget.cpp, LvglWidgetTextButtonBase).
-- So the frame cannot be switched off from here, only covered: with `tapFrames` off the button
-- gets square corners (`cornerRadius`, in every firmware with LVGL for Lua) and four lines in its
-- fill colour lie exactly over the border. A 2 px line reaches one pixel above and left of its
-- coordinate and stops a pixel short of its end point, which is what the coordinates below allow
-- for. The focus outline the firmware draws OUTSIDE a focused button is not covered, so a button
-- reached with the rotary encoder still shows that it is.
function M.button(nodes, x, y, w, h, fill, press)
  local node = { type = "button", x = x, y = y, w = w, h = h, color = fill, press = press }
  nodes[#nodes + 1] = node
  if M.tapFrames then return end
  node.cornerRadius = 0
  local x1, y1 = x + w - 1, y + h - 1
  local edges = {
    { { x, y + 1 }, { x + w, y + 1 } }, { { x, y1 }, { x + w, y1 } },
    { { x + 1, y }, { x + 1, y + h } }, { { x1, y }, { x1, y + h } },
  }
  for i = 1, 4 do
    nodes[#nodes + 1] = { type = "line", x = 0, y = 0, w = 0, h = 0, pts = edges[i], color = fill, thickness = 2 }
  end
end

-- A button whose drawing is built into it: returns the list of its children and the screen position
-- of their origin, which lies inside the button by `insetX`, `insetY`. What is appended after a button
-- lies over everything in it, so the lines M.button covers the frame with would cut the edge off a
-- drawing that reaches the frame. Here the covering comes first among the children instead, as four
-- rectangles on the same pixels as those lines, and the drawing lies over it.
function M.buttonInto(nodes, x, y, w, h, fill, press, insetX, insetY)
  local inner = {}
  local node = { type = "button", x = x, y = y, w = w, h = h, color = fill, press = press, children = inner }
  nodes[#nodes + 1] = node
  if not M.tapFrames then
    node.cornerRadius = 0
    M.rect(inner, -insetX, -insetY, w, 2, fill, true)
    M.rect(inner, -insetX, h - 2 - insetY, w, 2, fill, true)
    M.rect(inner, -insetX, -insetY, 2, h, fill, true)
    M.rect(inner, w - 2 - insetX, -insetY, 2, h, fill, true)
  end
  return inner, x + insetX, y + insetY
end

-- A label above a value, both centred in their column -- the shape the model picture's footer is
-- built from. `labelColor` is optional and defaults to the muted label colour.
function M.stacked(nodes, x, y, w, pad, labelText, valueText, labelFont, labelH, valueFont, valueH, labelColor)
  M.label(nodes, x, y + pad, w, labelH, labelText, labelFont, labelColor or M.C.label, CENTER)
  M.label(nodes, x, y + pad + labelH, w, valueH, valueText, valueFont, M.C.text, CENTER)
end

-- ---------------------------------------------------------------------------
-- value getters
-- ---------------------------------------------------------------------------

local function num(value)
  return type(value) == "number" and value or nil
end

M.num = num

-- A reader of one numeric state field, nil for anything that is not a number: `num(state[key])`
-- with the test written out, because a getter calls its reader on every frame.
function M.field(state, key)
  return function()
    local v = state[key]
    if type(v) ~= "number" then return nil end
    return v
  end
end

-- What a memo holds before its first reading: a table no reading can be equal to, so the first
-- call always formats and every later one costs a single comparison -- where a separate `primed`
-- flag would cost a second test on every frame.
local UNSET = {}
M.UNSET = UNSET

-- One formatted string per value change: the sweep calls these every frame, so the format
-- has to be gated on the reading actually having moved.
function M.getter(read, format)
  local last, cached = UNSET, nil
  return function()
    local v = read()
    if v == last then return cached end
    last = v
    cached = format(v)
    return cached
  end
end

-- A number printed at `places` decimals, "-" without one. Two memos: the reading itself, which a
-- value that has not moved passes in one comparison, and the reading rounded to the printed
-- precision, so a change too small to show hands back the string already standing instead of
-- formatting the same text again.
function M.scaledGetter(read, places)
  local scale = 10 ^ places
  local fmt = "%." .. tostring(places) .. "f"
  local lastRaw, lastScaled, cached = UNSET, UNSET, nil
  return function()
    local v = read()
    if v == lastRaw then return cached end
    lastRaw = v
    local s = nil
    if v ~= nil then s = math.floor(v * scale + 0.5) end
    if s == lastScaled then return cached end
    lastScaled = s
    if s == nil then
      cached = "-"
    else
      cached = string.format(fmt, s / scale)
    end
    return cached
  end
end

-- The cell count the battery figures are stated in: the flight controller's own where the
-- runtime has read it, otherwise derived from the theme's configured full-pack voltage. The
-- same rule the shipped themes' estimateCellCount applies, clamped to 1..14.
function M.cells(state)
  local c = tonumber(state and state.batteryCellCount)
  if c and c > 0 then
    c = math.floor(c + 0.5)
  else
    local cfg = state and state.themeConfig or nil
    local vMax = tonumber(cfg and cfg.v_max) or 25.2
    c = math.floor((vMax / 4.2) + 0.5)
  end
  if c < 1 then return 1 end
  if c > 14 then return 14 end
  return c
end

-- The cell count of the pack the flight that ended was flown on: the count the host takes at the
-- disarm together with the landing voltage (`state.lastFlightEndingCells`,
-- widgets/dashboard/runtime.lua, updateDerivedFlightState), or nil while it holds none -- in flight,
-- since the arm clears it, and after a landing on a pack that read 0 V. A figure of the ended
-- flight's record is divided by this count rather than by M.cells: the live count follows whatever
-- pack is plugged in after the landing. The host's own statistics box does the same
-- (widgets/dashboard/objects/text/stats.lua). Rounded and capped as M.cells is, so a label and a
-- gauge never disagree about the same count.
function M.flownCells(state)
  local c = tonumber(state and state.lastFlightEndingCells)
  if c == nil or c <= 0 then return nil end
  c = math.floor(c + 0.5)
  if c < 1 then return 1 end
  if c > 14 then return 14 end
  return c
end

-- mm:ss below an hour, h:mm from one hour on -- the shipped themes' formatDuration.
function M.duration(seconds)
  local v = math.max(0, math.floor((num(seconds) or 0) + 0.5))
  local hours = math.floor(v / 3600)
  if hours > 0 then
    return string.format("%d:%02d", hours, math.floor((v % 3600) / 60))
  end
  return string.format("%02d:%02d", math.floor(v / 60), v % 60)
end

-- Hours in full on the totals field, where "2:15" would read as minutes.
function M.longDuration(seconds)
  local v = math.max(0, math.floor((num(seconds) or 0) + 0.5))
  return string.format("%02d:%02d:%02d", math.floor(v / 3600), math.floor((v % 3600) / 60), v % 60)
end

function M.decimals(value, places)
  local v = num(value)
  if v == nil then return "-" end
  return string.format("%." .. tostring(places) .. "f", v)
end

function M.integer(value)
  local v = num(value)
  if v == nil then return "-" end
  return string.format("%d", math.floor(v + 0.5))
end

-- The governor states are `M.T.gov_state_<n>` (see the label table): the
-- indices are the flight controller's own (rotorflight-firmware src/main/flight/governor.h,
-- GOV_STATE_THROTTLE_OFF .. GOV_STATE_BYPASS). The keys are GOV_STATE_KEYS, built once beside
-- the label table, so the format path concatenates nothing.

-- The flight controller runs a governor STATE machine in the DIRECT, ELECTRIC and NITRO modes
-- only. In OFF and LIMIT it never enters one, and the state sensor stands at its initial value
-- -- throttle off -- from power-up to the end of the flight. Read literally, this cell would
-- report a hovering helicopter as having its throttle off, with nothing on screen to say why.
--
-- So in those two the MODE is shown instead of the state. The rule is not invented here: it is
-- the one the host's own governor object applies, and `state.governorMode` is the field it
-- reads -- carried over from the mode the connect chain fetches once, and nil until that has
-- answered, in which case this cell shows the state.
--
-- The host's object has two further branches ahead of this one, an arming-disable reason and a
-- disarmed label. Neither is repeated here: this theme gives the disable reasons the governor
-- card's line under the figure and ARMED/DISARMED the arm card, and a figure that said the same
-- thing again would cost the one line that can say what the governor is doing.
local GOV_MODE_OFF = 0
local GOV_MODE_LIMIT = 1

function M.governorText(state)
  -- The mode belongs in the memoised reading as much as the state does: a mode that arrives
  -- while the state has not moved would otherwise never reach the format path, and that is
  -- exactly the case this is for -- in OFF and LIMIT the state never moves again.
  --
  -- One number for the pair, so the getter still formats once per change and allocates
  -- nothing per frame. The state reaches 101 and the mode a handful, so 1000 keeps them
  -- apart; both are shifted by one so that "absent" is 0 rather than a valid reading.
  return M.getter(function()
    local mode = num(state.governorMode)
    local v = num(state.governor)
    return (mode and (math.floor(mode + 0.5) + 1) or 0) * 1000
      + (v and (math.floor(v + 0.5) + 1) or 0)
  end, function(packed)
    local mode = math.floor(packed / 1000) - 1
    local v = (packed % 1000) - 1
    -- The mode decides before the state does, because in these two there is no state to read.
    if mode == GOV_MODE_OFF then return M.T.gov_off end
    if mode == GOV_MODE_LIMIT then return M.T.gov_limit end
    if v < 0 then return "-" end
    local key = GOV_STATE_KEYS[v]
    return (key and M.T[key]) or M.T.gov_unknown
  end)
end

-- The governor card's colours. FALLBACK and AUTOROTATION are alarms (the flight controller's
-- states 6 and 7): the figure turns critical and so does the card's outline, for those two and
-- for nothing else -- the governor OFF is a mode a pilot runs on purpose, and a card that stood
-- red for it would cry wolf. ACTIVE is ok, SPOOLUP, RECOVERY and BAILOUT are on the way to or
-- from it. In the OFF and LIMIT modes there is no state to colour (M.governorText shows the mode).
local function govState(state)
  local mode = num(state.governorMode)
  if mode ~= nil then
    mode = math.floor(mode + 0.5)
    if mode == GOV_MODE_OFF or mode == GOV_MODE_LIMIT then return nil end
  end
  local v = num(state.governor)
  if v == nil then return nil end
  return math.floor(v + 0.5)
end

function M.governorColor(state)
  return function()
    local v = govState(state)
    if v == nil then return M.C.text end
    if v == 6 or v == 7 then return M.C.crit end
    if v == 4 then return M.C.ok end
    if v == 2 or v == 3 or v == 8 then return M.C.warn end
    return M.C.text
  end
end

function M.governorFrameColor(state)
  return function()
    local v = govState(state)
    if v == 6 or v == 7 then return M.C.crit end
    return M.C.line
  end
end

-- The throttle cell: "**" without a link, "Safe" while disarmed, and the throttle only once the
-- model is armed. One number for the three cases, so the getter formats once per change: -2 no
-- link, -1 disarmed, else the rounded percentage.
function M.throttleText(state)
  return M.getter(function()
    if state.rfConnected ~= true then return -2 end
    if state.armed ~= true then return -1 end
    local v = num(state.throttlePercent)
    if v == nil then return nil end
    return math.floor(v + 0.5)
  end, function(v)
    if v == -2 then return M.T.throttle_unknown end
    if v == -1 then return M.T.throttle_safe end
    if v == nil then return "--" end
    return string.format("%d%%", v)
  end)
end

-- The arm card's arm state: "No FC connected" while no flight controller answers, since the
-- craft's state is then not known and "Disarmed" would be a claim.
function M.armedText(state)
  return function()
    if state.rfConnected ~= true then return M.T.no_fc end
    if state.armed then return M.T.armed end
    return M.T.disarmed
  end
end

-- ---------------------------------------------------------------------------
-- the settings, as the theme reads them
-- ---------------------------------------------------------------------------

-- EVERY setting this theme stores is a STRING, the numeric ones included, and that is a
-- decision about the store rather than a style. A value goes through the host's preferences
-- file and comes back through DashboardLib.getThemeConfig; what survives that round trip
-- unambiguously is text. A boolean written as `false` and read back as the string "false" is
-- TRUE in Lua, so a switch would silently stop switching off -- and a number read back as text
-- would not equal the number the settings page put in its option list, which draws the combo as
-- an unknown value. One shape for all of them costs a tonumber() at build time, in the build
-- pass, once.
--
-- Every read goes through the two helpers below, and both answer the DEFAULT for anything they
-- do not recognise -- an absent key, a hand-edited file, a value from a newer build of the
-- theme.
local function configValue(state, key)
  local cfg = state and state.themeConfig or nil
  local v = cfg and cfg[key]
  if type(v) == "string" and v ~= "" then return v end
  -- A host or a hand-edited file that stored the value as a number is met halfway rather than
  -- ignored: the theme asked for text, and a number says the same thing.
  if type(v) == "number" then return tostring(v) end
  return nil
end

-- One of the values the caller offers, or the default. `values` is the flat list layout.lua
-- declares beside the key, so the check is against the list a pilot was actually given and a
-- value from an older build of the theme -- or from a hand-edited file -- lands on the default
-- rather than somewhere undefined. A linear scan over at most five short strings, at build time,
-- a handful of times per build: a lookup table for that is a table constructor per setting in
-- the pass that reloads the theme, which costs more than it saves.
function M.option(state, key, values, default)
  local v = configValue(state, key)
  if v ~= nil then
    for i = 1, #values do
      if values[i] == v then return v end
    end
  end
  return default
end

-- A whole percentage from 0 to 100, or the default where nothing usable is stored. A number
-- outside the range is pulled to its edge and a fraction is cut to the whole number below it,
-- so a hand-edited file still draws with a step the settings page could have set; anything that
-- is not a number at all is no choice made.
function M.percent(state, key, default)
  local v = tonumber(configValue(state, key))
  if v == nil or v ~= v then return default end
  if v < 0 then return 0 end
  if v > 100 then return 100 end
  return math.floor(v)
end

-- The battery fill's two steps, in percent of the fuel reading: yellow at or below the first,
-- red at or below the second. The defaults are 20 % and 0 % (no red step).
M.FUEL_LOW_DEFAULT = 20
M.FUEL_CRIT_DEFAULT = 0

-- Both steps as the fill uses them. Red is never above yellow: the settings page does not let a
-- pilot set it there, and a stored pair that has it there anyway -- a hand-edited file, say -- is
-- drawn with red pulled down to yellow, so a reading can never be red while a higher one is still
-- yellow.
function M.fuelSteps(state)
  local low = M.percent(state, "fuel_low", M.FUEL_LOW_DEFAULT)
  local crit = M.percent(state, "fuel_crit", M.FUEL_CRIT_DEFAULT)
  if crit > low then crit = low end
  return low, crit
end

-- The two clock modes, with the format string and the WIDTH SAMPLE of each in one place.
--
-- The header measures the clock's width against the sample, so the two have to agree: a format
-- one character longer than its sample clips the clock, one character shorter wastes bar width
-- the link bars could have used. Keeping them in one entry means the only way to change one is
-- to change the other.
--
-- Time only frees about eleven characters of the header, and the header follows the choice
-- rather than keeping the gap: the link bars have the room the clock does not take.
M.CLOCK_MODES = {
  date_time = {
    sample = "00.00.00  00:00",
    render = function(t)
      return string.format("%02d.%02d.%02d  %02d:%02d",
        t.day or 0, t.mon or 0, (t.year or 0) % 100, t.hour or 0, t.min or 0)
    end,
  },
  time = {
    sample = "00:00",
    render = function(t)
      return string.format("%02d:%02d", t.hour or 0, t.min or 0)
    end,
  },
}
M.CLOCK_MODE_DEFAULT = "time"

-- The id is resolved by the caller, which is the one place that reads the configuration; an id
-- this file has no format for falls back rather than leaving the bar with no clock at all.
function M.clockMode(id)
  return M.CLOCK_MODES[id] or M.CLOCK_MODES[M.CLOCK_MODE_DEFAULT]
end

-- The two temperature ladders, and the reason this is one row rather than four. An ESC warning,
-- an ESC critical, an MCU warning and an MCU critical are four numbers for one intention -- "tell
-- me when it is getting hot" -- and four rows of a settings page for a pilot who has no reason to
-- hold an opinion about any of them separately. What he is actually choosing is whether the
-- temperatures are coloured at all, and how early; the four numbers follow from that. `early` is
-- the `standard` ladder moved down by a class.
--
-- The limits are not derivable: nothing the flight controller or the host publishes to a theme
-- says what this controller's temperature limit is -- the derived readings the host resolves
-- carry a current limit and no thermal one -- so a control is unavoidable. Off is the default:
-- no colour.
local TEMP_LADDERS = {
  standard = { esc = { 90, 110 }, mcu = { 75, 90 } },
  early    = { esc = { 80, 100 }, mcu = { 65, 80 } },
}
M.TEMP_COLORS_DEFAULT = "off"

-- The colour of a temperature row, or nil where the pilot has left the rows uncoloured -- and
-- nil is the point: the row then carries no colour closure at all, so the setting costs nothing
-- per frame instead of costing a comparison that can never fire.
function M.tempColor(id, state, which, field)
  local ladder = TEMP_LADDERS[id]
  if ladder == nil then return nil end
  local warn, crit = ladder[which][1], ladder[which][2]
  return function()
    local v = num(state[field])
    if v == nil then return M.C.text end
    if v >= crit then return M.C.crit end
    if v >= warn then return M.C.warn end
    return M.C.text
  end
end

-- The two arm-state colour schemes the pilot chooses between, stored under `arm_colors`:
-- `amber`, this theme's default, is armed in the warn colour and disarmed in the label colour;
-- `signal` is armed green and disarmed in the WARNING red. Resolved per frame rather than captured
-- at build time -- it is two lookups on a state field, and every place that paints the arm state
-- asks here, so one setting rules all of them.
local ARM_COLORS_DEFAULT = "amber"

-- Answers the armed colour and the disarmed colour. M.C is indexed at call time, so nothing
-- here can hold a colour the theme has stopped painting with.
function M.armColors(state)
  local cfg = state.themeConfig
  local id = cfg and cfg.arm_colors
  if id ~= "amber" and id ~= "signal" then id = ARM_COLORS_DEFAULT end
  if id == "signal" then return M.C.ok, M.C.warning end
  return M.C.warn, M.C.label
end

-- "No FC connected" is muted, in the placeholder colour: it is not an arm state.
function M.armedColor(state)
  return function()
    if state.rfConnected ~= true then return M.C.disabled end
    local armedCol, disarmedCol = M.armColors(state)
    if state.armed then return armedCol end
    return disarmedCol
  end
end

-- The main pack gone while the flight controller still answers on its BEC. `mainPowerLost` is a
-- plain field of the host's state (widgets/dashboard/runtime.lua, from the same test the spoken
-- announcement uses) rather than a box source, so it costs nothing to read and needs no
-- declaration. It is read with `== true` everywhere, so a host without the field draws exactly
-- what it would draw with the pack present.
--
-- It is not the same fact as "the pack is low", and this theme draws it where the pack is drawn
-- -- the arm card says it in words, the battery strip, the charge card and the voltage readings
-- turn -- rather than adding a card for it. A reading that is no longer being measured is what the
-- strip shows as no level at all; without the words beside it, that is indistinguishable from a
-- model with no fuel sensor.
-- The colour a reading taken from the main pack is drawn in: critical while the pack is gone,
-- otherwise whatever the caller would have used. One test per frame, no allocation.
function M.packColor(state, base)
  return function()
    if state.mainPowerLost == true then return M.C.crit end
    if type(base) == "function" then return base() end
    return base or M.C.text
  end
end

-- The fuel reading, or nil before the host has seen one. The host seeds `state.fuel` with 0 and
-- sets `fuelTelemetrySeen` only once a fuel source has produced a number (runtime.lua,
-- readTelemetry), and clears both again on a disconnect. Read off the value alone, a model that
-- has not reported yet would draw an empty pack in the critical colour. The suite's fuel
-- announcements wait for the same flag (lib/audio.lua).
function M.fuel(state)
  if state.fuelTelemetrySeen ~= true then return nil end
  return num(state.fuel)
end

-- The fuel reading, decoded once per value change and shared by every node that follows it:
-- the battery strip, the charge card and the battery page's segments all ask one such closure, so
-- the colour is computed once per change rather than once per node per frame, and no two of them
-- can disagree about it.
function M.fuelLevel(state)
  local last, lastNotFull, lastColor = UNSET, nil, M.C.empty
  -- The steps are settings, read once here, when the view is built: the host rebuilds the
  -- theme when its settings change, so no frame reads the configuration.
  local low, crit = M.fuelSteps(state)
  return function()
    -- With the main pack gone the fuel figure is not low, it is no longer being measured:
    -- the fill empties rather than freezing on the last reading it took.
    --
    -- Written out rather than as `cond and nil or value`: that idiom cannot yield nil in Lua --
    -- `true and nil` is false, so the `or` arm runs and the reading comes back anyway.
    --
    -- M.fuel is written out here too: up to a dozen nodes ask this closure every frame.
    local p = nil
    if state.fuelTelemetrySeen == true and state.mainPowerLost ~= true then
      p = state.fuel
      if type(p) ~= "number" then p = nil end
    end
    -- The host's verdict on the pack that was plugged in (`packNotFull`, judged once per
    -- connection). It is part of the key as well as the reading: it arrives after the first fuel
    -- reading, because it waits for the battery configuration over MSP, and a key on the reading
    -- alone would keep the colour decided before it for as long as the reading stands still.
    local notFull = state.packNotFull == true
    if p == last and notFull == lastNotFull then return p, lastColor end
    last, lastNotFull = p, notFull
    -- Critical at or below the red step, low at or below the yellow step. Above that, orange for
    -- a pack that was not full when it was plugged in and green for one that was: low and
    -- critical say more about the pack in hand than how it started, so they come first.
    if p == nil then lastColor = M.C.empty
    elseif p <= crit then lastColor = M.C.bar_crit
    elseif p <= low then lastColor = M.C.bar_low
    elseif notFull then lastColor = M.C.bar_warn
    else lastColor = M.C.bar_ok end
    return p, lastColor
  end
end

-- One formatted clock string per minute. getDateTime is a firmware call, not one of the
-- three probe classes the reactive-closure rule bars (sensor, model.*, file) -- but it
-- allocates a table on every call, and a closure runs per frame. So it is asked at most once a
-- second, gated on getTime's tick count, and the string is rebuilt only when the minute moves.
--
-- `mode` is an entry of M.CLOCK_MODES, resolved by the caller at build time -- the same entry it
-- measured its width against, which is what keeps the two from disagreeing. The minute gate is
-- the same for both modes: the date only ever changes on a minute that also changes.
function M.clock(mode)
  mode = mode or M.CLOCK_MODES[M.CLOCK_MODE_DEFAULT]
  local render = mode.render
  local lastMin, cached, nextAt = nil, "--:--", 0
  return function()
    local now = getTime()
    if now < nextAt then return cached end
    nextAt = now + 100
    local ok, t = pcall(getDateTime)
    if not ok or type(t) ~= "table" then return cached end
    local stamp = (t.hour or 0) * 60 + (t.min or 0)
    if stamp == lastMin then return cached end
    lastMin = stamp
    cached = render(t)
    return cached
  end
end

-- The firmware's arming-disable bit names in two spellings: the short upper-case descriptors the
-- governor card's line strings together, and the readable names the statistics bar cycles through
-- one at a time and the status view lists.
local ARM_DISABLE_DESCS = {
  [0] = "NOGYRO", [1] = "FAILSAFE", [2] = "RXLOSS", [3] = "BADRX", [4] = "BOXFAILSAFE",
  [5] = "GOVERNOR", [6] = "RPM_SIGNAL", [7] = "THROTTLE", [8] = "ANGLE", [9] = "BOOTGRACE",
  [10] = "NOPREARM", [11] = "LOAD", [12] = "CALIB", [13] = "CLI", [14] = "CMS", [15] = "BST",
  [16] = "MSP", [17] = "PARALYZE", [18] = "GPS", [19] = "RESCUE_SW", [20] = "RPMFILTER",
  [21] = "REBOOT_REQD", [22] = "DSHOT_BBANG", [23] = "NO_ACC_CAL", [24] = "MOTOR_PROTO",
  [25] = "OVERRIDE",
  [26] = "ARMSWITCH"
}

-- The readable names are `M.T.arm_flag_<n>`, so they follow the package's language; the keys are built
-- once here so the decode below concatenates nothing.
local ARM_FLAG_KEYS = {}
for i = 0, 26 do ARM_FLAG_KEYS[i] = "arm_flag_" .. i end

-- The readable names in bit order, for a caller that prepares something per name at build time.
function M.armFlagNames()
  local out = {}
  for b = 0, 26 do out[#out + 1] = M.T[ARM_FLAG_KEYS[b]] end
  return out
end

local function flagBits(v)
  v = math.floor(v)
  if v < 0 then v = v + 4294967296 end
  return v
end

-- Decoded arming-disable reasons in compact form, or "" when nothing blocks: "* " and the
-- descriptors in bit order, cut with "+" once they pass eighteen characters. One decode per
-- value change.
function M.armDisableText(state)
  return M.getter(M.field(state, "armDisableFlags"), function(v)
    if v == nil or v == 0 then return "" end
    v = flagBits(v)
    local parts, len = {}, 0
    for b = 0, 26 do
      if v % 2 == 1 then
        local desc = ARM_DISABLE_DESCS[b] or ("FLAG" .. b)
        if len + #desc + 1 > 18 then
          parts[#parts + 1] = "+"
          break
        end
        parts[#parts + 1] = desc
        len = len + #desc + 1
      end
      v = math.floor(v / 2)
      if v == 0 then break end
    end
    if #parts == 0 then return "" end
    return "* " .. table.concat(parts, " ")
  end)
end

-- The readable names of the reasons that block arming, as a list, or nil -- for the statistics
-- bar, which shows them one at a time, and the status view. Decoded once per value change.
function M.armDisableList(state)
  local last, list, primed = nil, nil, false
  return function()
    local v = num(state.armDisableFlags)
    if primed and v == last then return list end
    last, primed, list = v, true, nil
    if v == nil or v == 0 then return nil end
    v = flagBits(v)
    local out = {}
    for b = 0, 26 do
      if v % 2 == 1 then out[#out + 1] = M.T[ARM_FLAG_KEYS[b]] or ("Flag " .. b) end
      v = math.floor(v / 2)
      if v == 0 then break end
    end
    if #out > 0 then list = out end
    return list
  end
end

function M.modelName(state)
  return M.getter(function()
    local derived = state.derived
    return (derived and (derived.model_name or derived.edgetx_model_name)) or nil
  end, function(v)
    if type(v) == "string" and v ~= "" then return v end
    return M.T.model_fallback
  end)
end

-- The model picture, resolved at build time rather than per frame: a probe of the card is
-- exactly what a reactive closure may not do.
--
-- THE HOST RESOLVES IT. `state.derived.model_image` is the suite's own answer
-- (widgets/dashboard/derived.lua, resolveModelImage), published on every snapshot whether or
-- not anything declared it, and it walks this order: `/IMAGES/<craft>-<cells>S`, then
-- `/IMAGES/<craft>`, then the EdgeTX model bitmap, each with the extensions EdgeTX accepts, and
-- the suite's logo last. The craft name is the flight controller's, so the picture follows the
-- helicopter rather than the radio slot.
--
-- The own lookup below is only for a host that publishes no `model_image`, and it is the same
-- order with the craft name from the session. Once per inputs, not once per rebuild.
local LOGO = _G.rfsuite.paths.core .. "/widgets/dashboard/gfx/logo.png"
local IMAGE_EXTS = { "", ".png", ".bmp", ".jpg", ".jpeg" }
local lookupKey, lookupPath = nil, nil

local function findImage(name)
  if type(name) ~= "string" or name == "" then return nil end
  for i = 1, #IMAGE_EXTS do
    local path = "/IMAGES/" .. name .. IMAGE_EXTS[i]
    local f = io.open(path, "r")
    if f then
      io.close(f)
      return path
    end
  end
  return nil
end

local function ownLookup(state, derived)
  local session = _G.rfsuite and _G.rfsuite.session
  local craft = type(session) == "table" and session.modelName or nil
  if type(craft) ~= "string" then craft = "" end
  local bitmap = derived and derived.edgetx_model_bitmap
  if type(bitmap) ~= "string" then bitmap = "" end
  local cells = math.floor(tonumber(state.batteryCellCount) or 0)
  local key = craft .. "\0" .. bitmap .. "\0" .. cells
  if key == lookupKey then return lookupPath end
  local path = nil
  if craft ~= "" then
    if cells > 0 then path = findImage(craft .. "-" .. cells .. "S") end
    path = path or findImage(craft)
  end
  path = path or findImage(bitmap) or LOGO
  lookupKey, lookupPath = key, path
  return path
end

-- The picture's own size, so the panel can top-anchor it at its true aspect ratio rather than
-- centring it in its slot. Bitmap.open loads the file, so it is asked once per path for as long
-- as this module is loaded; a firmware without Bitmap answers nil and the image fills its slot.
local sizes = {}

function M.imageSize(path)
  local s = sizes[path]
  if s == nil then
    s = false
    if type(Bitmap) == "table" and type(Bitmap.open) == "function" then
      local ok, bmp = pcall(Bitmap.open, path)
      if ok and bmp and type(Bitmap.getSize) == "function" then
        local okS, bw, bh = pcall(Bitmap.getSize, bmp)
        if okS and type(bw) == "number" and type(bh) == "number" and bw > 0 and bh > 0 then
          s = { bw, bh }
        end
      end
    end
    sizes[path] = s
  end
  if s then return s[1], s[2] end
  return nil, nil
end

function M.modelImage(state)
  local derived = state.derived
  local hostPath = derived and derived.model_image
  if type(hostPath) == "string" and hostPath ~= "" then return hostPath end
  return ownLookup(state, derived)
end

if type(_G) == "table" then _G.__rfsuiteThemeDeckCommonModule = M end

return M
