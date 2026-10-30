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
    local saved = w.saved.battery_config
    if not saved or source ~= saved[key] then return L.powerSaveFirst end
    local age = w.analogAt and getTime() - w.analogAt
    if not age or age < 0 or age > 200 or not w.data.analog or not w.analogSources or w.analogSources[key] ~= source then
      return L.noTelemetry
    end
    return fields.reading(w.data.analog[signal], 100, unit)
  end
  local function sourceCard(key, label, signal, unit, help)
    local options = fields.sourceOptions(w.i18n, battery[key], w:session().apiVersion, w.powerApiVersion)
    local row = w:enum("battery_config", key, label, entries(options))
    -- Source options already include the stored ID, even when it is unknown.
    row.allowUnset = false
    add(label, help, {
      row,
      w:value(signal == "voltage" and L.voltage or L.current, function() return sourceValue(key, signal, unit) end)
    }, L.powerSourceShort)
  end
  sourceCard("voltageMeterSource", L.voltageSource, "voltage", "V", L.powerVoltageHelp)
  sourceCard("currentMeterSource", L.currentSource, "current", "A", L.powerCurrentHelp)
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
    end
  end
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
