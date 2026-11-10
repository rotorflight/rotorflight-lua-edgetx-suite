-- Power editors reuse the Suite's page specifications and the wizard's save boundary.
return function(w, cards)
  local L, fields, battery = w.L, w.powerFields, w.data.battery_config
  if not battery then return end
  local function add(title, help, rows, summary)
    local card = w:cardDef(title, help, rows)
    card.power, card.summary = true, summary
    cards[#cards+1] = card
  end
  local function entries(options)
    local out = {}
    for i, option in ipairs(options) do out[i] = {option.value, option.label} end
    return out
  end
  local function sourceValue(key, signal, unit)
    local source = battery[key]
    if source == 0 then return L.off end
    if source == 2 then
      local age = w.motorTelemetryAt and getTime() - w.motorTelemetryAt
      local motor = w.data.motor_telemetry and w.data.motor_telemetry.motors[1]
      if not motor then return signal == "voltage" and L.powerNoEscVoltage or L.noTelemetry end
      if not age or age < 0 or age > 200 then return L.noTelemetry end
      if signal == "voltage" and motor.voltage <= 0 then return L.powerNoEscVoltage end
      return fields.reading(motor[signal], 1000, unit)
    end
    -- A changed source is written to the FC at once (no EEPROM); until that write is out,
    -- no reading belongs to it.
    local sent = w.sent.battery_config or w.saved.battery_config
    if not sent or source ~= sent[key] then return L.powerApplying end
    local age = w.analogAt and getTime() - w.analogAt
    if not age or age < 0 or age > 200 or not w.data.analog or not w.analogSources or w.analogSources[key] ~= source then
      return L.noTelemetry
    end
    return fields.reading(w.data.analog[signal], 100, unit)
  end
  -- A source and its live reading; both sources go on one card.
  local function sourceRows(rows, key, label, signal, unit)
    local options = fields.sourceOptions(w.i18n, battery[key], w:session().apiVersion, w.powerApiVersion)
    local row = w:enum("battery_config", key, label, entries(options))
    -- Source options already include the stored ID, even when it is unknown.
    row.allowUnset = false
    -- The firmware reads the source on every battery update, so a live write shows its reading
    -- before the card is saved.
    local set = row.set
    row.set = function(v)
      set(v); w:touch("battery_config", false, true)
      if w.logTrace then w:log("trace", "%s set to %s", key, battery[key]) end
    end
    rows[#rows+1] = row
    rows[#rows+1] = w:value(signal == "voltage" and L.voltage or L.current, function() return sourceValue(key, signal, unit) end)
  end
  local sourceRowsList = {}
  sourceRows(sourceRowsList, "voltageMeterSource", L.voltageSource, "voltage", "V")
  sourceRows(sourceRowsList, "currentMeterSource", L.currentSource, "current", "A")
  add(L.powerSources, L.powerVoltageHelp .. "\n" .. L.powerCurrentHelp, sourceRowsList, L.powerSourceShort)
  -- The cell count is picked from a list rather than typed: Auto (0, the FC detects the
  -- count) and then every count the field allows. The number row keeps its own get and set.
  local function cellList(row)
    local values = {}
    for count = fields.cellCount.min, fields.cellCount.max do
      values[#values+1] = count == 0 and L.cellsAuto or string.format(L.cellsShort, count)
    end
    local first = fields.cellCount.min
    return { kind = "choice", label = row.label, values = values, enabled = row.enabled,
      get = function() local v = row.get(); return type(v) == "number" and v - first + 1 or 1 end,
      set = function(index) if values[index] then row.set(index - 1 + first) end end }
  end
  local profile = w.data.battery_profile and w.data.battery_profile.batteryProfile
  if type(profile) ~= "number" or profile < 0 or profile > 5 or profile % 1 ~= 0 then profile = nil end
  local cellKey = battery.hasProfileCells and profile ~= nil and "batteryCellCount_" .. profile or "batteryCellCount"
  local cell = w:n("battery_config", cellKey, L.cellCount, fields.cellCount.min, fields.cellCount.max)
  if battery.hasProfileCells then
    if profile == nil then
      cell = w:value(L.cellCount, function() return battery.batteryCellCount end)
    else
      local set = cell.set
      cell.set = function(v)
        set(v)
        if battery[cellKey] == v then w:field("battery_config", "batteryCellCount", v) end
      end
      cell = cellList(cell)
    end
  else
    cell = cellList(cell)
  end
  if battery.hasProfileCells and battery.batteryCapacity_5 ~= nil then
    -- How many packs the pilot flies: as many battery profiles as hold a capacity, at least one,
    -- until the pilot says otherwise. Only these rows are edited; the record written keeps every
    -- other profile and field as it was read.
    if not w.packCount then
      local used = 0
      for i = 0, 5 do if (battery["batteryCapacity_" .. i] or 0) > 0 then used = i + 1 end end
      w.packCount = math.max(1, used)
    end
    local counts = {}
    for i = 1, 6 do counts[i] = tostring(i) end
    local rows = {
      { kind = "choice", label = L.packCount, values = counts, get = function() return w.packCount end,
        set = function(v)
          if v == w.packCount or not counts[v] then return end
          if w.logDebug then w:log("debug", "pack count %s", v) end
          -- A profile that leaves the table goes back to what was read, so nothing changed in it
          -- before is written.
          local saved = w.saved and w.saved.battery_config
          for i = v, 5 do
            for _, key in ipairs({ "batteryCellCount_" .. i, "batteryCapacity_" .. i }) do
              if saved and saved[key] ~= nil and battery[key] ~= saved[key] then battery[key] = saved[key] end
            end
          end
          w.packCount = v; w.buildRequested = true; w:rebuild()
        end }
    }
    for index = 0, w.packCount - 1 do
      local cellKey, capKey = "batteryCellCount_" .. index, "batteryCapacity_" .. index
      local cells = w:n("battery_config", cellKey, L.cellCount, fields.cellCount.min, fields.cellCount.max)
      local setCells = cells.set
      cells.set = function(v)
        setCells(v)
        -- The active profile's values are also the FC's current ones.
        if profile == index and battery[cellKey] == v then w:field("battery_config", "batteryCellCount", v) end
      end
      cells = cellList(cells)
      local capacity = w:n("battery_config", capKey, L.capacity, fields.capacity.min, fields.capacity.max)
      capacity.display = fields.capacityText
      local setCap = capacity.set
      capacity.set = function(v)
        setCap(v)
        if profile == index and battery[capKey] == v then w:field("battery_config", "batteryCapacity", v) end
      end
      rows[#rows+1] = { kind = "pair", label = L.batterySlot .. " " .. (index+1), left = cells, right = capacity,
        separator = "" }
    end
    add(L.packTable, L.packTableHelp, rows, L.packTableShort)
    cards[#cards].dense = #rows > 4
  else
  add(L.powerBattery, L.powerBatteryHelp, {
    w:value(L.selectedBattery, function() return profile ~= nil and L.batterySlot .. " " .. (profile+1) or L.powerProfileUnknown end),
    cell
  }, battery.hasProfileCells and profile == nil and L.powerProfileUnknown or L.powerBatteryShort)
  -- Six capacity slots fit on two three-row cards; never switch the active battery profile.
  if battery.batteryCapacity_5 ~= nil then
    for first = 0, 3, 3 do
      local rows = {}
      for index = first, first+2 do
        local key = "batteryCapacity_" .. index
        local row = w:n("battery_config", key, L.batterySlot .. " " .. (index+1), fields.capacity.min, fields.capacity.max)
        row.display = fields.capacityText
        local set = row.set
        row.set = function(v)
          set(v)
          if profile == index and battery[key] == v then w:field("battery_config", "batteryCapacity", v) end
        end
        rows[#rows+1] = row
      end
      add(L.capacity, first == 0 and L.powerCapacityFirstHelp or L.powerCapacityLastHelp, rows, L.powerCapacityShort)
    end
  else
    local row = w:n("battery_config", "batteryCapacity", L.capacity, fields.capacity.min, fields.capacity.max)
    row.display = fields.capacityText
    add(L.capacity, L.powerCapacityHelp, {row}, L.powerCapacityShort)
  end
  end
  if w.data.smartfuel_config then
    add(L.smartFuel, L.powerSmartFuelHelp, {
      w:enum("smartfuel_config", "smartfuel_mode", L.firmwareSource, entries(fields.modeOptions(w.i18n))),
      {kind = "notice", get = function()
        return fields.needsVoltage(w.data.smartfuel_config.smartfuel_mode) and battery.voltageMeterSource == 0
          and L.powerVoltageWarning or ""
      end}
    }, L.powerSmartFuelShort)
  end
end
