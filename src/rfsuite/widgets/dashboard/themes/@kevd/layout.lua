--[[
  Copyright (C) 2025 Rotorflight Project
  GPLv3 — https://www.gnu.org/licenses/gpl-3.0.en.html

  @Kevd -- the tiles of all three phases, after the Ethos suite's kevd.

  Preflight, 7 cols x 12 rows
    model (1-3, 1-9)         | BEC V arc (4-5, 1-8)   | ESC temp arc (6-7, 1-8)
                             | rates (4) | profile (5) | flights (6-7)      (rows 9-10)
    battery bar (1-3, 10-12) | blackbox (4-5)          | governor (6-7)     (rows 11-12)
  Inflight, 24 cols x 20 rows
    framed panel (1-18, 1-20) holding the ESC temp, throttle and head speed arcs, staggered
    right column (19-24): flight time (1-4), battery (5-16), governor (17-20)
  Postflight, 24 cols x 20 rows
    flights (1-9, 1-4)    | total time (10-18, 1-4)
    max rpm (1-9, 5-9)    | max ESC temp (10-18, 5-9)
    min link (1-9, 10-14) | max current (10-18, 10-14)
    max alt (1-9, 15-20)  | max watts (10-18, 15-20)
    right column (19-24) as in flight

  Inflight and postflight share the grid so that the right column stands still across the landing.
]] --

if type(_G) == "table" and type(_G.__rfsuiteThemeKevdLayoutModule) == "table" then
  return _G.__rfsuiteThemeKevdLayoutModule
end

local function loadCommon()
  if type(_G) == "table" and type(_G.__rfsuiteThemeKevdCommonModule) == "table" then
    return _G.__rfsuiteThemeKevdCommonModule
  end
  if _G.rfsuite and type(_G.rfsuite.require) == "function" then
    local mod = _G.rfsuite.require("widgets/dashboard/themes/@kevd/common.lua")
    if type(mod) == "table" then return mod end
  end
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/themes/@kevd/common.lua", mode)
  if not chunk then return nil end
  local ok, mod = pcall(chunk)
  if ok and type(mod) == "table" then return mod end
  return nil
end

local C = loadCommon()

local Layout = {}

-- Keep in step with configure.lua.
Layout.DEFAULTS = { rpm_max = 3000, bec_min = 3.0, bec_warn = 6.0, bec_max = 13.0, esctemp_warn = 90, esctemp_max = 140 }

local PREFLIGHT = { cols = 7, rows = 12, padding = 6, showstats = false, bgcolor = C.BG }
local FLIGHT = { cols = 24, rows = 20, padding = 4, showstats = false, bgcolor = C.BG }

local function rawValue(state, key)
  local cfg = state and state.themeConfig
  local v = tonumber(cfg and cfg[key])
  if v ~= nil then return v end
  return Layout.DEFAULTS[key]
end

-- The settings that must rise from first to last (configure.lua holds an edit to that). A stored
-- chain out of order -- written by hand, or into a model's settings elsewhere -- would leave an
-- arc with no range or a colour step that never fires, so the whole chain falls back to its
-- defaults.
local ORDERED = { { "bec_min", "bec_warn", "bec_max" }, { "esctemp_warn", "esctemp_max" } }
-- The step the settings page edits each in (configure.lua's `scale`): the order is tested on the
-- values rounded to it, as the page tests it, so the page and the dashboard never disagree about
-- whether a stored chain is in order.
local STEP = { bec_min = 10, bec_warn = 10, bec_max = 10, esctemp_warn = 1, esctemp_max = 1 }
local CHAIN_OF = {}
for _, chain in ipairs(ORDERED) do
  for _, key in ipairs(chain) do CHAIN_OF[key] = chain end
end

local function cfgValue(state, key)
  local chain = CHAIN_OF[key]
  if chain then
    for i = 2, #chain do
      local hi, lo = chain[i], chain[i - 1]
      if math.floor(rawValue(state, hi) * STEP[hi] + 0.5) <= math.floor(rawValue(state, lo) * STEP[lo] + 0.5) then
        return Layout.DEFAULTS[key]
      end
    end
  end
  local v = rawValue(state, key)
  -- A full scale of zero or below gives the head speed arc and bar no range.
  if key == "rpm_max" and v <= 0 then return Layout.DEFAULTS.rpm_max end
  return v
end

local function place(box, col, row, colspan, rowspan)
  box.col, box.row, box.colspan, box.rowspan = col, row, colspan, rowspan
  return box
end

-- The profile tiles colour the number: profile 1 plain, 2 amber, any other green.
local PROFILE_THRESHOLDS = {
  { value = 1.5, textcolor = C.TEXT },
  { value = 2.5, textcolor = C.WARN },
  { value = 100, textcolor = C.OK },
}

local FUEL_THRESHOLDS = {
  { value = 25, fillcolor = C.CRIT },
  { value = 50, fillcolor = C.WARN },
  { value = 100000, fillcolor = C.OK },
}

local function escTempThresholds(state)
  return {
    { value = cfgValue(state, "esctemp_warn"), fillcolor = C.OK },
    { value = cfgValue(state, "esctemp_max") - 1, fillcolor = C.WARN },
    { value = 100000, fillcolor = C.CRIT },
  }
end

-- The right column of the flight and post-flight screens: the flight time, the battery as a
-- vertical bar with the pack voltage, the voltage per cell and the capacity used over it, and
-- the governor in its red frame.
local function rightColumn(grid, boxes)
  boxes[#boxes + 1] = C.tile(grid, place({ type = "time", subtype = "flight", title = "@i18n(widgets.dashboard.flight_time):upper()@" }, 19, 1, 6, 4), 5, 4)

  local w, h = C.span(grid, 6, 12)
  local pad = grid.lowres and 4 or 6
  local barH = h - 2 * pad - 2
  local font, lineH = C.fit(w - 2 * pad - 8, math.floor(barH / 3), 4, 5)
  boxes[#boxes + 1] = place({
    id = "battery",
    type = "gauge", subtype = "bar", gaugeorientation = "vertical",
    source = "smartfuel", unit = "%", transform = "floor", min = 0, max = 100,
    gaugepaddingtop = pad, gaugepaddingbottom = pad, gaugepaddingleft = pad, gaugepaddingright = pad,
    bgcolor = C.PANEL, bordercolor = C.FRAME, borderwidth = grid.lowres and 2 or 3, rounded = 6,
    fillbgcolor = C.TRACK, fillcolor = C.OK, thresholds = FUEL_THRESHOLDS,
    textcolor = C.TEXT, valuealign = CENTER, font = font,
    -- At two thirds of the bar, below the three lines drawn over its top.
    valuepaddingtop = math.floor(barH * 0.18) - math.floor(lineH / 2) + 6,
  }, 19, 5, 6, 12)

  local lineFont = grid.lowres and SMLSIZE or 0
  local function overlay(id, row, box)
    box.id = id
    box.type = "text"
    box.subtype = box.stattype and "stats" or "telemetry"
    box.bgcolor = false
    box.textcolor = C.TEXT
    box.valuealign = CENTER
    box.font = lineFont
    -- objects/common.lua's defaultValueY puts an untitled value 45 % down its rect; this lifts
    -- it to the top of the two rows, clear of the bar's own frame.
    local _, oh = C.span(grid, 6, 2)
    box.value_offset_y = pad + 2 - math.max(14, math.floor(oh * 0.45))
    boxes[#boxes + 1] = place(box, 19, row, 6, 2)
  end
  overlay("pack_voltage", 5, { source = "voltage", unit = "V", decimals = 1 })
  overlay("cell_voltage", 7, { source = "voltage", stattype = "cell", unit = "V", decimals = 2 })
  overlay("consumed", 9, { source = "smartconsumption", unit = " mAh", transform = "floor" })

  boxes[#boxes + 1] = C.tile(grid, place({
    type = "text", subtype = "governor",
    title = "@i18n(widgets.dashboard.governor):upper()@",
    bordercolor = C.CRIT, warningcolor = C.CRIT, activecolor = C.OK,
  }, 19, 17, 6, 4), 9, 3)
  return boxes
end

local function preflight(state)
  local grid = C.grid(state, PREFLIGHT.cols, PREFLIGHT.rows, PREFLIGHT.padding)

  local bw, bh = C.span(grid, 3, 3)
  local pad = grid.lowres and 3 or 5
  local barH = bh - 4 - 2 * pad
  local valueFont, valueLine = C.fit(math.floor(bw / 3), math.floor(barH * 0.6), 4, 4)
  local valueAlign = bw >= 300 and LEFT or CENTER
  local advFont = grid.lowres and SMLSIZE or 0

  return {
    place({ type = "image", subtype = "model", bgcolor = C.BG, titlecolor = C.TITLE }, 1, 1, 3, 9),
    place({
      id = "battery",
      type = "gauge", subtype = "bar",
      source = "smartfuel", unit = "%", transform = "floor", min = 0, max = 100,
      gaugepaddingtop = pad, gaugepaddingbottom = pad, gaugepaddingleft = pad, gaugepaddingright = pad,
      bgcolor = C.BG, bordercolor = C.FRAME, borderwidth = grid.lowres and 2 or 3, rounded = 6,
      fillbgcolor = C.TRACK, fillcolor = C.OK, thresholds = FUEL_THRESHOLDS,
      textcolor = C.TEXT, font = valueFont, valuealign = valueAlign, valuepaddingleft = 8,
      -- The percentage at the foot of the bar, the pack's figures at its head.
      valuepaddingtop = bw >= 300 and ((barH - 4 - valueLine) - math.floor((barH - 8) / 2)) or math.floor((8 - valueLine) / 2),
      -- The pack's figures need about 300 px; a narrower tile shows the percentage alone.
      battadv = bw >= 300, battadvsingleline = grid.lowres, battadvfont = advFont,
      battadvvaluealign = RIGHT, battadvpaddingtop = 2, battadvpaddingright = 6, battadvtextcolor = C.TEXT,
    }, 1, 10, 3, 3),

    C.arc(grid, place({
      id = "bec", source = "bec_voltage", unit = "V", decimals = 1,
      title = "@i18n(widgets.dashboard.bec_voltage):upper()@",
      min = cfgValue(state, "bec_min"), max = cfgValue(state, "bec_max"),
      thresholds = {
        { value = cfgValue(state, "bec_warn"), fillcolor = C.CRIT },
        { value = 100000, fillcolor = C.OK },
      },
    }, 4, 1, 2, 8), 5),
    C.arc(grid, place({
      id = "esc", source = "esc_temp", transform = "floor",
      title = "@i18n(widgets.dashboard.esc_temp):upper()@",
      min = 0, max = cfgValue(state, "esctemp_max"),
      thresholds = escTempThresholds(state),
    }, 6, 1, 2, 8), 5),

    C.tile(grid, place({ type = "text", subtype = "telemetry", source = "rate_profile", transform = "floor", title = "@i18n(widgets.dashboard.rates):upper()@", thresholds = PROFILE_THRESHOLDS }, 4, 9, 1, 2), 2, 4),
    C.tile(grid, place({ type = "text", subtype = "telemetry", source = "pid_profile", transform = "floor", title = "@i18n(widgets.dashboard.profile):upper()@", thresholds = PROFILE_THRESHOLDS }, 5, 9, 1, 2), 2, 4),
    C.tile(grid, place({ type = "time", subtype = "count", title = "@i18n(widgets.dashboard.flights):upper()@" }, 6, 9, 2, 2), 4, 4),

    C.tile(grid, place({ type = "text", subtype = "blackbox", title = "@i18n(widgets.dashboard.blackbox):upper()@" }, 4, 11, 2, 2), 10, 3),
    C.tile(grid, place({
      type = "text", subtype = "governor",
      title = "@i18n(widgets.dashboard.governor):upper()@",
      bordercolor = C.CRIT, warningcolor = C.CRIT, activecolor = C.OK,
    }, 6, 11, 2, 2), 9, 3),
  }
end

local function inflight(state)
  local grid = C.grid(state, FLIGHT.cols, FLIGHT.rows, FLIGHT.padding)
  local boxes = {
    -- The frame the three arcs stand in; the arcs draw no fill of their own over it.
    place({ id = "panel", type = "text", subtype = "text", value = "", bgcolor = C.PANEL, bordercolor = C.FRAME, borderwidth = grid.lowres and 2 or 3, rounded = 6 }, 1, 1, 18, 20),

    C.arc(grid, place({
      id = "esc", source = "esc_temp", transform = "floor", arcmax = true, bgcolor = false,
      title = "@i18n(widgets.dashboard.esc_temp):upper()@",
      min = 0, max = cfgValue(state, "esctemp_max"),
      thresholds = escTempThresholds(state),
    }, 1, 1, 6, 14), 5),
    C.arc(grid, place({
      id = "throttle", source = "throttle_percent", unit = "%", transform = "floor", arcmax = true, bgcolor = false,
      title = "@i18n(widgets.dashboard.throttle):upper()@",
      min = 0, max = 100,
      thresholds = {
        { value = 70, fillcolor = C.OK, textcolor = C.TEXT },
        { value = 85, fillcolor = C.WARN, textcolor = C.TEXT },
        { value = 100000, fillcolor = C.CRIT, textcolor = C.TEXT },
      },
    }, 7, 7, 6, 14), 4),
    C.arc(grid, place({
      id = "rpm", source = "rpm", transform = "floor", arcmax = true, bgcolor = false,
      title = "@i18n(widgets.dashboard.headspeed):upper()@",
      min = 0, max = cfgValue(state, "rpm_max"),
      thresholds = { { value = 100000, fillcolor = C.PURPLE } },
    }, 13, 1, 6, 16), 4),
  }
  return rightColumn(grid, boxes)
end

local function postflight(state)
  local grid = C.grid(state, FLIGHT.cols, FLIGHT.rows, FLIGHT.padding)

  -- The highest current against the ESC's current limit where one is on file (Setup > Power >
  -- Preferences, or read off the ESC), amber from 80 % and red from 95 % of it; otherwise the
  -- Ethos theme's fixed 300 A scale with its steps at 160 and 199 A.
  local limit = tonumber(state and state.escCurrentLimit)
  local currentMax, currentWarn, currentCrit = 300, 160, 199
  if limit and limit > 0 then
    currentMax, currentWarn, currentCrit = limit, limit * 0.8, limit * 0.95
  end

  local function header(col, box)
    box.bgcolor = C.BG
    box.titlepos = "top"
    box.titlealign = CENTER
    box.titlecolor = C.TITLE
    box.textcolor = C.TEXT
    box.valuealign = CENTER
    local w, h = C.span(grid, 9, 4)
    local top = C.titleH()
    local font, lineH = C.fit(w - 12, h - top - 2, 8, 4)
    box.font = font
    box.value_offset_y = top - math.max(14, math.floor(h * 0.45))
    return place(box, col, 1, 9, 4)
  end

  -- A flight figure as a bar in a framed tile, its caption at the head.
  local function bar(col, row, rowspan, box)
    local w, h = C.span(grid, 9, rowspan)
    local pad = grid.lowres and 5 or 8
    local padTop = math.max(0, C.titleH() + 2 - 20)
    local barH = math.max(12, (h - 18 - 4) - padTop - pad)
    local font, lineH = C.fit(w - 2 * pad - 8, barH, 7, 4)
    box.type, box.subtype = "gauge", "bar"
    box.bgcolor = C.PANEL
    box.bordercolor = C.FRAME
    box.borderwidth = grid.lowres and 2 or 3
    box.rounded = 6
    box.titlepos = "top"
    box.titlealign = CENTER
    box.titlecolor = C.TITLE
    box.textcolor = C.TEXT
    box.fillbgcolor = C.TRACK
    box.gaugepaddingtop, box.gaugepaddingbottom = padTop, pad
    box.gaugepaddingleft, box.gaugepaddingright = pad, pad
    box.valuealign = CENTER
    box.valuepaddingleft = 0
    box.valuepaddingtop = math.floor((8 - lineH) / 2)
    box.font = font
    box.transform = box.transform or "floor"
    return place(box, col, row, 9, rowspan)
  end

  local boxes = {
    header(1, { type = "time", subtype = "count", title = "@i18n(widgets.dashboard.flights):upper()@" }),
    header(10, { type = "time", subtype = "total", title = "@i18n(widgets.dashboard.total_flight_duration):upper()@" }),

    bar(1, 5, 5, { source = "rpm", stattype = "max", unit = "rpm", min = 0, max = cfgValue(state, "rpm_max"),
      title = "@i18n(widgets.dashboard.rpm_max):upper()@",
      thresholds = { { value = 100000, fillcolor = C.OK } } }),
    bar(10, 5, 5, { source = "esc_temp", stattype = "max", min = 0, max = cfgValue(state, "esctemp_max"),
      title = "@i18n(widgets.dashboard.esc_max_temp):upper()@",
      thresholds = escTempThresholds(state) }),
    bar(1, 10, 5, { source = "link", stattype = "min", unit = "%", min = 0, max = 100,
      title = "@i18n(widgets.dashboard.link_min):upper()@",
      thresholds = { { value = 59, fillcolor = C.CRIT }, { value = 74, fillcolor = C.WARN }, { value = 100000, fillcolor = C.OK } } }),
    bar(10, 10, 5, { source = "current", stattype = "max", unit = "A", min = 0, max = currentMax,
      title = "@i18n(widgets.dashboard.current_max):upper()@",
      thresholds = { { value = currentWarn, fillcolor = C.OK }, { value = currentCrit, fillcolor = C.WARN }, { value = 100000, fillcolor = C.CRIT } } }),
    bar(1, 15, 6, { source = "altitude", stattype = "max", unit = "m", min = 0, max = 150,
      title = "@i18n(widgets.dashboard.altitude_max):upper()@",
      thresholds = { { value = 60, fillcolor = C.OK }, { value = 105, fillcolor = C.WARN }, { value = 100000, fillcolor = C.CRIT } } }),
    bar(10, 15, 6, { source = "watts", stattype = "max", unit = "W", min = 0, max = 15000,
      title = "@i18n(widgets.dashboard.watts_max):upper()@",
      thresholds = { { value = 7000, fillcolor = C.OK }, { value = 9000, fillcolor = C.WARN }, { value = 100000, fillcolor = C.CRIT } } }),
  }
  return rightColumn(grid, boxes)
end


local PHASES = {
  preflight = { layout = PREFLIGHT, boxes = preflight },
  inflight = { layout = FLIGHT, boxes = inflight },
  postflight = { layout = FLIGHT, boxes = postflight },
}

--- The phase module for `phase`: the grid, and the boxes resolved for the size it is drawn at.
--- The engine's render key includes the ESC current limit, so the postflight current bar is
--- rebuilt to a limit that arrives after the first build.
function Layout.phase(phase)
  local p = PHASES[phase] or PHASES.preflight
  return {
    layout = p.layout,
    boxes = function(_, state) return p.boxes(state) end,
  }
end

if type(_G) == "table" then
  _G.__rfsuiteThemeKevdLayoutModule = Layout
end

return Layout
