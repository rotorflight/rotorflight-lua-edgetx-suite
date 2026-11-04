--[[
  Copyright (C) 2025 Rotorflight Project
  GPLv3 — https://www.gnu.org/licenses/gpl-3.0.en.html

  @KSE4 -- the tiles of all three phases, after the Ethos suite's kse4.

  Grid: 16 cols x 12 rows
  Preflight
    model (1-4, 1-5)     | headspeed (5-12, 1-5)               | timer (13-16, 1-5)
    flights (1-4, 6-8)   | current | voltage | BEC V | ESC temp (5-16, 6-8)
    governor (1-4, 9-12) | fuel bar (5-16, 9-12)
  Inflight
    headspeed (1-8, 1-5)  | timer (9-16, 1-5)
    current | cell V | ESC temp | throttle (rows 6-8)
    governor (1-4, 9-12) | fuel bar (5-16, 9-12)
  Postflight
    flight time (1-6, 1-4) | consumed (7-11) | fuel left (12-16)
    rpm max | current max | watts max | throttle max (rows 5-8)
    ESC max | cell V min  | BEC V min | link min     (rows 9-12)
]] --

if type(_G) == "table" and type(_G.__rfsuiteThemeKse4LayoutModule) == "table" then
  return _G.__rfsuiteThemeKse4LayoutModule
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

Layout.layout = { cols = 16, rows = 12, padding = 4, showstats = false, bgcolor = C.BG }

local function boxesFor(phase, state)
  local grid = C.grid(state, 16, 12, 4)

  local function at(col, row, colspan, rowspan, box, chars, maxIndex)
    box.col, box.row, box.colspan, box.rowspan = col, row, colspan, rowspan
    return C.tile(grid, box, chars, maxIndex)
  end

  local function live(col, row, colspan, rowspan, box, chars, maxIndex)
    box.type, box.subtype = "text", "telemetry"
    return at(col, row, colspan, rowspan, box, chars, maxIndex)
  end

  local function stat(col, row, colspan, rowspan, stattype, box, chars)
    box.type, box.subtype, box.stattype = "text", "stats", stattype
    return at(col, row, colspan, rowspan, box, chars, 4)
  end

  local function governor(col, row, colspan, rowspan)
    return at(col, row, colspan, rowspan, {
      type = "text", subtype = "governor",
      title = "@i18n(widgets.dashboard.governor):upper()@",
      warningcolor = C.CRIT, activecolor = C.OK,
    }, 9, 3)
  end

  local function fuelBar(col, row, colspan, rowspan)
    return C.fuelBar(grid, { col = col, row = row, colspan = colspan, rowspan = rowspan })
  end

  local function timer(col, row, colspan, rowspan, title, maxIndex)
    return at(col, row, colspan, rowspan, { type = "time", subtype = "flight", title = title }, 5, maxIndex)
  end

  if phase == "inflight" then
    return {
      live(1, 1, 8, 5, { source = "rpm", transform = "floor", title = "@i18n(widgets.dashboard.headspeed):upper()@" }, 4, 5),
      timer(9, 1, 8, 5, "@i18n(widgets.dashboard.timer):upper()@", 5),

      live(1, 6, 4, 3, { source = "current", unit = "A", transform = "floor", title = "@i18n(widgets.dashboard.current):upper()@" }, 4, 4),
      stat(5, 6, 4, 3, "cell", { source = "voltage", unit = "V", decimals = 2, title = "@i18n(widgets.dashboard.cell_voltage):upper()@" }, 5),
      live(9, 6, 4, 3, { source = "esc_temp", transform = "floor", title = "@i18n(widgets.dashboard.esc_temp):upper()@" }, 5, 4),
      live(13, 6, 4, 3, { source = "throttle_percent", unit = "%", transform = "floor", title = "@i18n(widgets.dashboard.throttle):upper()@" }, 4, 4),

      governor(1, 9, 4, 4),
      fuelBar(5, 9, 12, 4),
    }
  end

  if phase == "postflight" then
    local warn, crit = C.fuelLevels(grid)
    local fuelText = { { value = crit, textcolor = C.CRIT }, { value = warn, textcolor = C.WARN } }
    return {
      timer(1, 1, 6, 4, "@i18n(widgets.dashboard.flight_duration):upper()@", 4),
      stat(7, 1, 5, 4, "max", { source = "smartconsumption", unit = "mAh", transform = "floor", title = "@i18n(widgets.dashboard.consumed_mah):upper()@" }, 7),
      stat(12, 1, 5, 4, "min", { source = "smartfuel", unit = "%", transform = "floor", title = "@i18n(widgets.dashboard.fuel_remaining):upper()@",
        thresholds = fuelText }, 4),

      stat(1, 5, 4, 4, "max", { source = "rpm", transform = "floor", title = "@i18n(widgets.dashboard.rpm_max):upper()@" }, 4),
      stat(5, 5, 4, 4, "max", { source = "current", unit = "A", transform = "floor", title = "@i18n(widgets.dashboard.current_max):upper()@" }, 4),
      stat(9, 5, 4, 4, "max", { source = "watts", unit = "W", transform = "floor", title = "@i18n(widgets.dashboard.watts_max):upper()@" }, 5),
      stat(13, 5, 4, 4, "max", { source = "throttle_percent", unit = "%", transform = "floor", title = "@i18n(widgets.dashboard.throttle_max):upper()@" }, 4),

      stat(1, 9, 4, 4, "max", { source = "esc_temp", transform = "floor", title = "@i18n(widgets.dashboard.esc_max_temp):upper()@" }, 5),
      stat(5, 9, 4, 4, "", { source = "min_voltage_cell", unit = "V", decimals = 2, title = "@i18n(widgets.dashboard.cell_voltage):upper()@" }, 5),
      stat(9, 9, 4, 4, "min", { source = "bec_voltage", unit = "V", decimals = 1, title = "@i18n(widgets.dashboard.bec_voltage):upper()@" }, 5),
      stat(13, 9, 4, 4, "min", { source = "link", unit = "%", transform = "floor", title = "@i18n(widgets.dashboard.link_min):upper()@" }, 4),
    }
  end

  -- preflight
  return {
    { col = 1, row = 1, colspan = 4, rowspan = 5, type = "image", subtype = "model", bgcolor = C.PANEL, bordercolor = C.FRAME, borderwidth = 1, rounded = grid.lowres and 4 or 6, titlecolor = C.TITLE },
    at(1, 6, 4, 3, { type = "time", subtype = "count", title = "@i18n(widgets.dashboard.flights):upper()@" }, 4, 4),

    live(5, 1, 8, 5, { source = "rpm", transform = "floor", title = "@i18n(widgets.dashboard.headspeed):upper()@" }, 4, 5),
    timer(13, 1, 4, 5, "@i18n(widgets.dashboard.timer):upper()@", 4),

    live(5, 6, 3, 3, { source = "current", unit = "A", transform = "floor", title = "@i18n(widgets.dashboard.current):upper()@" }, 4, 4),
    live(8, 6, 3, 3, { source = "voltage", unit = "V", decimals = 1, title = "@i18n(widgets.dashboard.voltage):upper()@" }, 5, 4),
    live(11, 6, 3, 3, { source = "bec_voltage", unit = "V", decimals = 1, title = "@i18n(widgets.dashboard.bec_voltage):upper()@" }, 5, 4),
    live(14, 6, 3, 3, { source = "esc_temp", transform = "floor", title = "@i18n(widgets.dashboard.esc_temp):upper()@" }, 5, 4),

    governor(1, 9, 4, 4),
    fuelBar(5, 9, 12, 4),
  }
end

--- The phase module for `phase`: the grid, and the boxes resolved for the size it is drawn at.
function Layout.phase(phase)
  return {
    layout = Layout.layout,
    boxes = function(_, state) return boxesFor(phase, state) end,
  }
end

if type(_G) == "table" then
  _G.__rfsuiteThemeKse4LayoutModule = Layout
end

return Layout
