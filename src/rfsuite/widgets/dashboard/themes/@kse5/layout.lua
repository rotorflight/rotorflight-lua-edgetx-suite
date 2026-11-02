--[[
  Copyright (C) 2025 Rotorflight Project
  GPLv3 — https://www.gnu.org/licenses/gpl-3.0.en.html

  @KSE5 -- the tiles of all three phases, after the Ethos suite's kse5: rings over readouts. The
  palette and the tile are @KSE4's (themes/@kse4/common.lua).

  Grid: 16 cols x 14 rows
  Preflight
    fuel ring | headspeed ring | current ring | ESC temp ring    (rows 1-8)
    model (1-8, 9-12)    | governor (9-12) | BEC V (13-16)      (rows 9-11)
    flights (1-8, 13-14) | cell V (9-12)   | used mAh (13-16)   (rows 12-14)
  Inflight
    fuel ring (1-6, 1-10) | headspeed ring (7-11, 1-6) | ESC temp ring (12-16, 1-6)
                          | timer (7-11, 7-10)         | governor (12-16, 7-10)
    current | cell V | BEC V | throttle                         (rows 11-14)
  Postflight
    fuel min | rpm max | current max | ESC max rings            (rows 1-8)
    flight time (1-8, 9-11) | cell V min (9-12) | BEC V min (13-16)
    consumed (1-8, 12-14)   | watts max (9-12) | link min (13-16)
]] --

if type(_G) == "table" and type(_G.__rfsuiteThemeKse5LayoutModule) == "table" then
  return _G.__rfsuiteThemeKse5LayoutModule
end

local function loadCommon()
  if type(_G) == "table" and type(_G.__rfsuiteThemeKse4CommonModule) == "table" then
    return _G.__rfsuiteThemeKse4CommonModule
  end
  if _G.rfsuite and type(_G.rfsuite.require) == "function" then
    local mod = _G.rfsuite.require("widgets/dashboard/themes/@kse4/common.lua")
    if type(mod) == "table" then return mod end
  end
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(_G.rfsuite.paths.core .. "/widgets/dashboard/themes/@kse4/common.lua", mode)
  if not chunk then return nil end
  local ok, mod = pcall(chunk)
  if ok and type(mod) == "table" then return mod end
  return nil
end

local C = loadCommon()

local Layout = {}

-- Keep in step with configure.lua.
Layout.DEFAULTS = { rpm_max = 3000, current_max = 150, temp_max = 100 }

Layout.layout = { cols = 16, rows = 14, padding = 4, showstats = false, bgcolor = C.BG }

-- A ring is an arc gauge drawn all the way round, from the top. 359 rather than 360 degrees: an
-- arc whose two ends fall on the same angle is an empty one to LVGL.
local RING_START, RING_END = 270, 629

local function cfgValue(state, key)
  local cfg = state and state.themeConfig
  local v = tonumber(cfg and cfg[key])
  if v and v > 0 then return v end
  return Layout.DEFAULTS[key]
end

local function boxesFor(phase, state)
  local grid = C.grid(state, 16, 14, 4)
  local rpmMax = cfgValue(state, "rpm_max")
  -- The ESC's current limit where one is on file; the Look page's figure otherwise.
  local escLimit = tonumber(state and state.escCurrentLimit)
  local currentMax = (escLimit and escLimit > 0) and escLimit or cfgValue(state, "current_max")
  local tempMax = cfgValue(state, "temp_max")
  local zoneH = tonumber(state and state.zoneH) or 0

  local function tile(col, row, colspan, rowspan, box, chars, maxIndex)
    box.col, box.row, box.colspan, box.rowspan = col, row, colspan, rowspan
    box.titlealign = box.titlealign or CENTER
    return C.tile(grid, box, chars, maxIndex)
  end

  -- Small readout: title top-left, value right-aligned, as on KSE5.
  local function readout(col, row, colspan, rowspan, box, chars, maxIndex)
    box.titlealign = LEFT
    box.valuealign = box.valuealign or RIGHT
    if not box.type then
      box.type = "text"
      box.subtype = box.stattype and "stats" or "telemetry"
    end
    return tile(col, row, colspan, rowspan, box, chars, maxIndex or 3)
  end

  -- The arc renderer's own geometry (objects/gauge.lua, renderArc), so the value can be sized to
  -- the inside of the ring and centred in it.
  local function ring(col, row, colspan, rowspan, box, chars, maxIndex)
    local w, h = C.span(grid, colspan, rowspan)
    local panelH = math.max(40, h - 8 - 22)
    local radius = math.max(18, math.floor(math.min(w - 14, panelH - 10) / 2))
    local thickness = math.max(5, math.floor(radius * 0.18))
    local inner = 2 * (radius - thickness) - 8
    local font, lineH = C.fit(inner, inner, chars or 4, maxIndex or 4)
    local cy = 4 + math.floor(panelH * 0.52)
    local lift = (zoneH >= 400) and 8 or 0
    box.type, box.subtype = "gauge", "arc"
    box.arcstart, box.arcend = RING_START, RING_END
    box.titlepos = "bottom"
    box.value_font = font
    box.value_center_lift = lift
    box.fillbgcolor = C.TRACK
    box.font = font
    tile(col, row, colspan, rowspan, box, chars, maxIndex)
    -- After tile(), which centres a text tile's value: the arc places its value from the ring's
    -- centre instead.
    box.value_offset_y = math.floor(thickness * 1.3) - math.floor(lineH / 2)
    return box
  end

  -- Green below 70% of the full scale, warning to 90%, critical above.
  local function rising(maxValue)
    return {
      { value = maxValue * 0.7, fillcolor = C.OK },
      { value = maxValue * 0.9, fillcolor = C.WARN },
      { value = 100000, fillcolor = C.CRIT },
    }
  end

  local function fuelRing(col, row, colspan, rowspan, extra, maxIndex)
    local box = {
      source = "smartfuel", unit = "%", transform = "floor", min = 0, max = 100,
      title = "@i18n(widgets.dashboard.battery):upper()@",
      thresholds = {
        { value = 25, fillcolor = C.CRIT, textcolor = C.TEXT },
        { value = 45, fillcolor = C.WARN, textcolor = C.TEXT },
        { value = 100000, fillcolor = C.OK, textcolor = C.TEXT },
      },
    }
    for k, v in pairs(extra or {}) do box[k] = v end
    return ring(col, row, colspan, rowspan, box, 4, maxIndex)
  end

  local function rpmRing(col, row, colspan, rowspan, extra)
    local box = {
      source = "rpm", transform = "floor", min = 0, max = rpmMax,
      title = "@i18n(widgets.dashboard.headspeed):upper()@",
      thresholds = { { value = 100000, fillcolor = C.ACCENT } },
    }
    for k, v in pairs(extra or {}) do box[k] = v end
    return ring(col, row, colspan, rowspan, box, 4, 3)
  end

  local function currentRing(col, row, colspan, rowspan, extra)
    local box = {
      source = "current", unit = "A", transform = "floor", min = 0, max = currentMax,
      title = "@i18n(widgets.dashboard.current):upper()@",
      thresholds = rising(currentMax),
    }
    for k, v in pairs(extra or {}) do box[k] = v end
    return ring(col, row, colspan, rowspan, box, 4, 3)
  end

  local function tempRing(col, row, colspan, rowspan, extra)
    local box = {
      source = "esc_temp", transform = "floor", min = 0, max = tempMax,
      title = "@i18n(widgets.dashboard.esc_temp):upper()@",
      thresholds = rising(tempMax),
    }
    for k, v in pairs(extra or {}) do box[k] = v end
    return ring(col, row, colspan, rowspan, box, 5, 3)
  end

  local function governor(col, row, colspan, rowspan, valuealign)
    return readout(col, row, colspan, rowspan, {
      type = "text", subtype = "governor",
      title = "@i18n(widgets.dashboard.governor):upper()@",
      valuealign = valuealign, warningcolor = C.CRIT, activecolor = C.OK,
    }, 9, 3)
  end

  if phase == "inflight" then
    return {
      fuelRing(1, 1, 6, 10, nil, 5),
      rpmRing(7, 1, 5, 6),
      tempRing(12, 1, 5, 6),

      tile(7, 7, 5, 4, { type = "time", subtype = "flight", title = "@i18n(widgets.dashboard.timer):upper()@" }, 5, 4),
      governor(12, 7, 5, 4, CENTER),

      readout(1, 11, 4, 4, { source = "current", unit = "A", transform = "floor", title = "@i18n(widgets.dashboard.current):upper()@" }, 4, 4),
      readout(5, 11, 4, 4, { stattype = "cell", source = "voltage", unit = "V", decimals = 2, title = "@i18n(widgets.dashboard.cell_voltage):upper()@" }, 5, 4),
      readout(9, 11, 4, 4, { source = "bec_voltage", unit = "V", decimals = 1, title = "@i18n(widgets.dashboard.bec_voltage):upper()@" }, 4, 4),
      readout(13, 11, 4, 4, { source = "throttle_percent", unit = "%", transform = "floor", title = "@i18n(widgets.dashboard.throttle):upper()@" }, 4, 4),
    }
  end

  if phase == "postflight" then
    return {
      fuelRing(1, 1, 4, 8, { stattype = "min", title = "@i18n(widgets.dashboard.fuel_remaining):upper()@" }),
      rpmRing(5, 1, 4, 8, { stattype = "max", title = "@i18n(widgets.dashboard.rpm_max):upper()@" }),
      currentRing(9, 1, 4, 8, { stattype = "max", title = "@i18n(widgets.dashboard.current_max):upper()@" }),
      tempRing(13, 1, 4, 8, { stattype = "max", title = "@i18n(widgets.dashboard.esc_max_temp):upper()@" }),

      readout(1, 9, 8, 3, { type = "time", subtype = "flight", title = "@i18n(widgets.dashboard.flight_duration):upper()@" }, 5, 4),
      readout(1, 12, 8, 3, { stattype = "max", source = "smartconsumption", unit = "mAh", transform = "floor", title = "@i18n(widgets.dashboard.consumed_mah):upper()@" }, 7, 4),

      readout(9, 9, 4, 3, { stattype = "", source = "min_voltage_cell", unit = "V", decimals = 2, title = "@i18n(widgets.dashboard.cell_voltage):upper()@" }, 7),
      readout(13, 9, 4, 3, { stattype = "min", source = "bec_voltage", unit = "V", decimals = 1, title = "@i18n(widgets.dashboard.bec_voltage):upper()@" }, 5),
      readout(9, 12, 4, 3, { stattype = "max", source = "watts", unit = "W", transform = "floor", title = "@i18n(widgets.dashboard.watts_max):upper()@" }, 5),
      readout(13, 12, 4, 3, { stattype = "min", source = "link", unit = "%", transform = "floor", title = "@i18n(widgets.dashboard.link_min):upper()@" }, 4),
    }
  end

  -- preflight
  return {
    fuelRing(1, 1, 4, 8),
    rpmRing(5, 1, 4, 8),
    currentRing(9, 1, 4, 8),
    tempRing(13, 1, 4, 8),

    { col = 1, row = 9, colspan = 8, rowspan = 4, type = "image", subtype = "model", bgcolor = C.PANEL, bordercolor = C.FRAME, borderwidth = 1, rounded = grid.lowres and 4 or 6, titlecolor = C.TITLE },
    tile(1, 13, 8, 2, { type = "time", subtype = "count", title = "@i18n(widgets.dashboard.flights):upper()@", titlealign = LEFT, valuealign = RIGHT }, 4, 3),

    governor(9, 9, 4, 3),
    readout(13, 9, 4, 3, { source = "bec_voltage", unit = "V", decimals = 1, title = "@i18n(widgets.dashboard.bec_voltage):upper()@" }, 5),
    readout(9, 12, 4, 3, { stattype = "cell", source = "voltage", unit = "V", decimals = 2, title = "@i18n(widgets.dashboard.cell_voltage):upper()@" }, 5),
    readout(13, 12, 4, 3, { source = "smartconsumption", unit = "mAh", transform = "floor", title = "@i18n(widgets.dashboard.consumed_mah):upper()@" }, 7),
  }
end


--- The phase module for `phase`: the grid, and the boxes resolved for the size it is drawn at.
--- The engine's render key includes the ESC current limit, so the current ring is rebuilt to a
--- limit that arrives after the first build.
function Layout.phase(phase)
  return {
    layout = Layout.layout,
    boxes = function(_, state) return boxesFor(phase, state) end,
  }
end

if type(_G) == "table" then
  _G.__rfsuiteThemeKse5LayoutModule = Layout
end

return Layout
