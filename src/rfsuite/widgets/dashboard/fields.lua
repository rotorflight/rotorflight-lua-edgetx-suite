--[[
  The value a box theme's tile shows, chosen by the pilot instead of written into the theme.

  A theme still declares every box with the value it shows by default. The pilot's choice is an
  ordinary theme setting, stored under `field_<phase>_<box>` beside the theme's other settings,
  so it is radio-wide per theme and a model can override it on the Per-Model Settings page like
  any other. widgets/dashboard/runtime.lua applies the choices when it loads a phase module, and
  the theme's settings pages (app/pages/settings/dashboard/fields_form.lua) offer them.

  Only boxes that draw a plain value can be reassigned: `text` boxes of subtype `telemetry` (a
  live reading) and `stats` (a figure of the flight). A gauge, a timer and the special boxes keep
  what the theme draws, because their look is bound to the value they were drawn for.

  Only fields that do not move a box are replaced -- `source`, `stattype`, `title`, `unit`,
  `decimals`, `transform` -- so the engine's cached geometry stays valid and a frame costs the
  same as before. The replaced box is a copy: a theme's tables are never written to.

  Loaded by the widget and by the settings page, which run in two separate Lua states; nothing
  here may reach for the suite's globals.
]]

local M = {}

-- What a live tile can show: `id` is what is stored, `source` what the box reads (a source of
-- objects/common.lua's Utils.mapTelemetrySource, or the name of one of the radio's telemetry
-- sensors, which that function reads when it knows no field by the name). `label` is the
-- choice on the settings page, `title` what the tile is captioned with.
M.LIVE = {
  { id = "voltage", source = "voltage", unit = "V", decimals = 1,
    label = "@i18n(widgets.dashboard.fields.voltage)@", title = "@i18n(widgets.dashboard.fields.voltage_title)@" },
  { id = "current", source = "current", unit = "A", decimals = 1,
    label = "@i18n(widgets.dashboard.fields.current)@", title = "@i18n(widgets.dashboard.fields.current_title)@" },
  { id = "rpm", source = "rpm", unit = "rpm", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.rpm)@", title = "@i18n(widgets.dashboard.fields.rpm_title)@" },
  { id = "smartfuel", source = "smartfuel", unit = "%", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.fuel)@", title = "@i18n(widgets.dashboard.fields.fuel_title)@" },
  { id = "smartconsumption", source = "smartconsumption", unit = "mAh", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.consumed)@", title = "@i18n(widgets.dashboard.fields.consumed_title)@" },
  { id = "bec_voltage", source = "bec_voltage", unit = "V", decimals = 2,
    label = "@i18n(widgets.dashboard.fields.bec_voltage)@", title = "@i18n(widgets.dashboard.fields.bec_voltage_title)@" },
  -- No unit: objects/text/telemetry.lua writes the degree sign itself, in the pilot's scale.
  { id = "esc_temp", source = "esc_temp", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.esc_temp)@", title = "@i18n(widgets.dashboard.fields.esc_temp_title)@" },
  { id = "mcu_temp", source = "mcu_temp", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.mcu_temp)@", title = "@i18n(widgets.dashboard.fields.mcu_temp_title)@" },
  { id = "watts", source = "watts", unit = "W", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.watts)@", title = "@i18n(widgets.dashboard.fields.watts_title)@" },
  { id = "throttle_percent", source = "throttle_percent", unit = "%", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.throttle)@", title = "@i18n(widgets.dashboard.fields.throttle_title)@" },
  { id = "altitude", source = "altitude", unit = "m", decimals = 1,
    label = "@i18n(widgets.dashboard.fields.altitude)@", title = "@i18n(widgets.dashboard.fields.altitude_title)@" },
  { id = "link", source = "link", unit = "%", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.link)@", title = "@i18n(widgets.dashboard.fields.link_title)@" },
  { id = "esc_load", source = "esc_load", unit = "%", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.esc_load)@", title = "@i18n(widgets.dashboard.fields.esc_load_title)@" },
  { id = "pid_profile", source = "pid_profile", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.pid_profile)@", title = "@i18n(widgets.dashboard.fields.pid_profile_title)@" },
  { id = "rate_profile", source = "rate_profile", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.rate_profile)@", title = "@i18n(widgets.dashboard.fields.rate_profile_title)@" },
  { id = "battery_profile", source = "battery_profile", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.battery_profile)@", title = "@i18n(widgets.dashboard.fields.battery_profile_title)@" },
  { id = "model_name", source = "model_name",
    label = "@i18n(widgets.dashboard.fields.model_name)@", title = "@i18n(widgets.dashboard.fields.model_name_title)@" },
  -- The radio's sensors by the names the suite's decoder gives them (lib/rf2tlm_sensors.lua);
  -- TQly, TPWR and RSNR are the link's own. A tile showing one costs the host one sensor read per
  -- telemetry pass, and only while it is shown.
  -- Not a temperature to objects/text/telemetry.lua, which converts only the ESC and MCU ones to
  -- the pilot's scale, so it carries its unit itself.
  { id = "Tbec", source = "Tbec", unit = "°C", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.bec_temp)@", title = "@i18n(widgets.dashboard.fields.bec_temp_title)@" },
  { id = "Tspd", source = "Tspd", unit = "rpm", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.tail_speed)@", title = "@i18n(widgets.dashboard.fields.tail_speed_title)@" },
  { id = "Var", source = "Var", unit = "m/s", decimals = 1,
    label = "@i18n(widgets.dashboard.fields.vario)@", title = "@i18n(widgets.dashboard.fields.vario_title)@" },
  { id = "TQly", source = "TQly", unit = "%", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.tq)@", title = "@i18n(widgets.dashboard.fields.tq_title)@" },
  { id = "TPWR", source = "TPWR", unit = "mW", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.tx_power)@", title = "@i18n(widgets.dashboard.fields.tx_power_title)@" },
  { id = "RSNR", source = "RSNR", unit = "dB", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.rsnr)@", title = "@i18n(widgets.dashboard.fields.rsnr_title)@" },
  { id = "Ibec", source = "Ibec", unit = "A", decimals = 1,
    label = "@i18n(widgets.dashboard.fields.bec_current)@", title = "@i18n(widgets.dashboard.fields.bec_current_title)@" },
  { id = "EscV", source = "EscV", unit = "V", decimals = 2,
    label = "@i18n(widgets.dashboard.fields.esc_voltage)@", title = "@i18n(widgets.dashboard.fields.esc_voltage_title)@" },
  { id = "EscI", source = "EscI", unit = "A", decimals = 1,
    label = "@i18n(widgets.dashboard.fields.esc_current)@", title = "@i18n(widgets.dashboard.fields.esc_current_title)@" },
  { id = "EscR", source = "EscR", unit = "rpm", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.esc_rpm)@", title = "@i18n(widgets.dashboard.fields.esc_rpm_title)@" },
  { id = "Sats", source = "Sats", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.gps_sats)@", title = "@i18n(widgets.dashboard.fields.gps_sats_title)@" },
  { id = "GSpd", source = "GSpd", unit = "m/s", decimals = 1,
    label = "@i18n(widgets.dashboard.fields.gps_speed)@", title = "@i18n(widgets.dashboard.fields.gps_speed_title)@" },
  { id = "GAlt", source = "GAlt", unit = "m", decimals = 1,
    label = "@i18n(widgets.dashboard.fields.gps_alt)@", title = "@i18n(widgets.dashboard.fields.gps_alt_title)@" },
  { id = "GDis", source = "GDis", unit = "m", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.gps_dist)@", title = "@i18n(widgets.dashboard.fields.gps_dist_title)@" },
  { id = "CPU%", source = "CPU%", unit = "%", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.cpu_load)@", title = "@i18n(widgets.dashboard.fields.cpu_load_title)@" },
}

-- What a statistics tile can show: a figure objects/text/stats.lua resolves, as one choice. The
-- recorded extremes are the rows of objects/common.lua's FLIGHT_STATS; the rest are the pairs
-- stats.lua answers itself (the consumption, the landing voltage, the deepest cell voltage).
-- A pair that resolves to nothing would draw "--" for good, so none is offered.
M.STATS = {
  { id = "max_throttle", source = "throttle_percent", stattype = "max", unit = "%", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.max_throttle)@", title = "@i18n(widgets.dashboard.fields.max_throttle_title)@" },
  { id = "max_rpm", source = "rpm", stattype = "max", unit = "rpm", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.max_rpm)@", title = "@i18n(widgets.dashboard.fields.max_rpm_title)@" },
  { id = "min_rpm", source = "rpm", stattype = "min", unit = "rpm", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.min_rpm)@", title = "@i18n(widgets.dashboard.fields.min_rpm_title)@" },
  { id = "max_current", source = "current", stattype = "max", unit = "A", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.max_current)@", title = "@i18n(widgets.dashboard.fields.max_current_title)@" },
  { id = "min_current", source = "current", stattype = "min", unit = "A", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.min_current)@", title = "@i18n(widgets.dashboard.fields.min_current_title)@" },
  { id = "max_watts", source = "watts", stattype = "max", unit = "W", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.max_watts)@", title = "@i18n(widgets.dashboard.fields.max_watts_title)@" },
  { id = "max_altitude", source = "altitude", stattype = "max", unit = "m", decimals = 1,
    label = "@i18n(widgets.dashboard.fields.max_altitude)@", title = "@i18n(widgets.dashboard.fields.max_altitude_title)@" },
  { id = "max_esc_temp", source = "esc_temp", stattype = "max", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.max_esc_temp)@", title = "@i18n(widgets.dashboard.fields.max_esc_temp_title)@" },
  { id = "max_mcu_temp", source = "mcu_temp", stattype = "max", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.max_mcu_temp)@", title = "@i18n(widgets.dashboard.fields.max_mcu_temp_title)@" },
  { id = "min_fuel", source = "smartfuel", stattype = "min", unit = "%", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.min_fuel)@", title = "@i18n(widgets.dashboard.fields.min_fuel_title)@" },
  { id = "max_voltage", source = "voltage", stattype = "max", unit = "V", decimals = 1,
    label = "@i18n(widgets.dashboard.fields.max_voltage)@", title = "@i18n(widgets.dashboard.fields.max_voltage_title)@" },
  { id = "min_voltage", source = "voltage", stattype = "min", unit = "V", decimals = 1,
    label = "@i18n(widgets.dashboard.fields.min_voltage)@", title = "@i18n(widgets.dashboard.fields.min_voltage_title)@" },
  { id = "min_bec_voltage", source = "bec_voltage", stattype = "min", unit = "V", decimals = 2,
    label = "@i18n(widgets.dashboard.fields.min_bec_voltage)@", title = "@i18n(widgets.dashboard.fields.min_bec_voltage_title)@" },
  { id = "max_link", source = "link", stattype = "max", unit = "%", transform = "floor",
    label = "@i18n(widgets.dashboard.fields.max_link)@", title = "@i18n(widgets.dashboard.fields.max_link_title)@" },
  -- `aliases`: the other spellings of the same figure a shipped theme declares, so its box is
  -- recognised as showing this entry.
  { id = "min_link", source = "link", stattype = "min", unit = "%", transform = "floor",
    aliases = { { source = "min_link", stattype = "" } },
    label = "@i18n(widgets.dashboard.fields.min_link)@", title = "@i18n(widgets.dashboard.fields.min_link_title)@" },
  { id = "consumed", source = "smartconsumption", stattype = "max", unit = "mAh", transform = "floor",
    aliases = { { source = "current", stattype = "consumed" } },
    label = "@i18n(widgets.dashboard.fields.consumed)@", title = "@i18n(widgets.dashboard.fields.consumed_title)@" },
  { id = "landing_voltage", source = "voltage", stattype = "last", unit = "V", decimals = 2,
    label = "@i18n(widgets.dashboard.fields.landing_voltage)@", title = "@i18n(widgets.dashboard.fields.landing_voltage_title)@" },
  -- The live voltage per cell, which stats.lua divides by the live cell count: a reading rather
  -- than a figure of the flight, but a stats box is what can show it.
  { id = "cell_voltage", source = "voltage", stattype = "cell", unit = "V", decimals = 2,
    label = "@i18n(widgets.dashboard.fields.cell_voltage)@", title = "@i18n(widgets.dashboard.fields.cell_voltage_title)@" },
  { id = "landing_cell", source = "voltage", stattype = "lastcell", unit = "V", decimals = 2,
    label = "@i18n(widgets.dashboard.fields.landing_cell)@", title = "@i18n(widgets.dashboard.fields.landing_cell_title)@" },
  -- stats.lua formats this one itself, with its own unit, so the box carries none.
  { id = "min_cell", source = "min_voltage_cell", stattype = "",
    label = "@i18n(widgets.dashboard.fields.min_cell)@", title = "@i18n(widgets.dashboard.fields.min_cell_title)@" },
}

-- How many characters a value of each entry needs at most, its unit included, for a box that
-- sizes its font to a width (`autosize_chars`): the theme sized that box for the value it drew, so
-- a reassigned box is sized for the new one. Digits by entry, four where none is named; a
-- temperature's unit is the two characters the object writes itself.
local DIGITS = {
  current = 5, altitude = 5, smartfuel = 3, throttle_percent = 3, link = 3, esc_load = 3,
  pid_profile = 1, rate_profile = 1, battery_profile = 1, model_name = 10, Tbec = 3, TQly = 3,
  RSNR = 3, EscV = 5, EscI = 5, EscR = 5, Sats = 2, GAlt = 5, ["CPU%"] = 3,
  max_throttle = 3, max_current = 5, min_current = 5, max_altitude = 5, max_esc_temp = 3,
  max_mcu_temp = 3, min_fuel = 3, max_link = 3, min_link = 3, min_cell = 7,
}
local TEMPERATURES = { esc_temp = true, mcu_temp = true, max_esc_temp = true, max_mcu_temp = true }

local LIVE_BY_ID, STATS_BY_ID = {}, {}
for _, list in ipairs({ M.LIVE, M.STATS }) do
  for i = 1, #list do
    local entry = list[i]
    entry.chars = (DIGITS[entry.id] or 4) + #(entry.unit or "") + (TEMPERATURES[entry.id] and 2 or 0)
  end
end
for i = 1, #M.LIVE do LIVE_BY_ID[M.LIVE[i].id] = M.LIVE[i] end
for i = 1, #M.STATS do STATS_BY_ID[M.STATS[i].id] = M.STATS[i] end

local KINDS = { telemetry = { list = M.LIVE, byId = LIVE_BY_ID }, stats = { list = M.STATS, byId = STATS_BY_ID } }

-- The catalogue a box chooses from, or nil for a box that cannot be reassigned.
local function kindOf(box)
  if type(box) ~= "table" or box.type ~= "text" then return nil end
  return KINDS[box.subtype]
end

--- The catalogue (`M.LIVE` or `M.STATS`) a box chooses from, or nil.
function M.catalogue(box)
  local kind = kindOf(box)
  return kind and kind.list or nil
end

--- A box's name within its phase: its own `id`, else its grid cell. A box declares an id only
--- where its cell is shared with another box of the same phase.
function M.boxId(box)
  if type(box) ~= "table" then return nil end
  if type(box.id) == "string" and box.id ~= "" then return box.id end
  if box.col ~= nil and box.row ~= nil then return tostring(box.col) .. "_" .. tostring(box.row) end
  return nil
end

--- The setting a box's choice is stored under, in the theme's configuration.
function M.settingKey(phase, id)
  return "field_" .. tostring(phase) .. "_" .. tostring(id)
end

--- The catalogue entry a box shows by the theme's own declaration: the one whose source (and,
--- for a statistic, stattype) it names. Nil for a box whose value is computed or not in the
--- catalogue -- such a box can still be reassigned, and its choice then starts on nothing.
function M.defaultEntry(box)
  local kind = kindOf(box)
  if kind == nil or type(box.source) ~= "string" then return nil end
  local stattype = box.stattype
  if stattype == nil then stattype = "" end
  local isStats = kind == KINDS.stats
  for i = 1, #kind.list do
    local entry = kind.list[i]
    if entry.source == box.source and (not isStats or (entry.stattype or "") == stattype) then
      return entry
    end
    local aliases = entry.aliases
    if aliases then
      for j = 1, #aliases do
        if aliases[j].source == box.source and aliases[j].stattype == stattype then return entry end
      end
    end
  end
  return nil
end

-- The fields a choice replaces. `thresholds` and the gauge bounds belong to the value the theme
-- drew, so they go with it: a temperature's red step is meaningless on an altitude.
local DROPPED = { "thresholds", "min", "max" }

local function reassigned(box, entry, hadTitle)
  local out = {}
  for k, v in pairs(box) do out[k] = v end
  out.source = entry.source
  out.stattype = entry.stattype
  out.unit = entry.unit
  out.decimals = entry.decimals
  out.transform = entry.transform
  -- A tile drawn without a caption stays without one: the theme laid it out that way.
  if hadTitle then
    out.title = entry.title
    out.title_lowres = nil
  end
  for i = 1, #DROPPED do out[DROPPED[i]] = nil end
  -- The width the box's font is sized to belongs to the value too. The box's room does not, so
  -- its low-resolution character limits stay.
  if type(box.autosize_chars) == "number" then out.autosize_chars = entry.chars end
  return out
end

--- `boxes` with the pilot's choices of `config` applied for `phase`, as a new list; `boxes`
--- itself when nothing applies. A choice equal to the theme's own value, or naming nothing in
--- the box's catalogue, leaves the box as the theme declared it.
function M.apply(boxes, phase, config)
  if type(boxes) ~= "table" or type(config) ~= "table" then return boxes end
  local out = nil
  for i = 1, #boxes do
    local box = boxes[i]
    local kind = kindOf(box)
    if kind then
      local id = M.boxId(box)
      local chosen = id and config[M.settingKey(phase, id)] or nil
      local entry = type(chosen) == "string" and kind.byId[chosen] or nil
      if entry and entry ~= M.defaultEntry(box) then
        if out == nil then
          out = {}
          for j = 1, i - 1 do out[j] = boxes[j] end
        end
        out[i] = reassigned(box, entry, box.title ~= nil)
      elseif out then
        out[i] = box
      end
    elseif out then
      out[i] = box
    end
  end
  return out or boxes
end

--- The reassignable boxes of one phase, in the order the theme declares them, for the settings
--- page: `{ key, title, default, list }` -- the setting key, the box's own caption (nil where it
--- has none), the catalogue id it shows by default and the catalogue it chooses from. A box whose
--- value is not in the catalogue -- one a theme computes -- is not listed: its choice would have
--- to start on a value it does not show.
function M.rows(boxes, phase)
  local rows = {}
  if type(boxes) ~= "table" then return rows end
  for i = 1, #boxes do
    local box = boxes[i]
    local kind = kindOf(box)
    local id = kind and M.boxId(box) or nil
    local entry = id and M.defaultEntry(box) or nil
    if entry then
      local title = box.title
      if type(title) ~= "string" or title == "" then title = nil end
      rows[#rows + 1] = {
        key = M.settingKey(phase, id),
        title = title,
        default = entry.id,
        defaultLabel = entry.label,
        list = kind.list,
      }
    end
  end
  return rows
end

--- The catalogue entry a stored choice names, in either catalogue, for a caller that has only
--- the stored value (the Per-Model Settings page describing an override).
function M.entry(id)
  return LIVE_BY_ID[id] or STATS_BY_ID[id]
end

return M
