return function(w)
  local L = w.L
  w.validate = function()
    w:escFamily()
    if w.escParams and (w.escParams.changes or w.escParams.restart) then w.message=L.escRestart; return false end
    return not w.escBusy
  end
  local function motor() return w.data.motor_telemetry and w.data.motor_telemetry.motors[1] end
  w.commit = function() w:fixMotor() end
  local protocol = w:enum("esc_sensor_config", "protocol", L.protocol, w:telemetryProtocols(), true)
  local set = protocol.set
  protocol.set = function(v)
    local previous = w.data.esc_sensor_config.protocol
    set(v)
    if w.data.esc_sensor_config.protocol == previous then return end
    w.escParams,w.escAttempted,w.escResultKey,w.escBusy=nil,nil,nil,nil
    w.rangeChoice,w.rangeSource,w.escRangeExpected=nil,nil,nil
    if w.data.esc_sensor_config.protocol == 0 then
      for i=1,12 do
        local key="port_"..i.."_function_mask"
        local mask=w.data.serial_config[key]
        if mask and (mask & 1024) ~= 0 then w.data.serial_config[key]=mask & (~1024); w:touch("serial_config",true) end
      end
    end
    w.buildRequested=true;w:rebuild()
  end
  local castle=w.data.motor_config.motor_pwm_protocol==9
  protocol.enabled=function() return not castle and not w.trial and not w.escBusy end
  local port=w:port(L.port,1024)
  port.enabled=function() return not castle and not w.trial and not w.escBusy and w.data.esc_sensor_config.protocol>0 end
  local cards={
    w:cardDef(L.connectBattery, L.telemetryBatteryHint, {}, nil, "esc"),
    w:cardDef(L.escTelemetry, castle and L.castleTelemetryHint or L.telemetryHint, {
      protocol,
      w:button(L.saveReboot, function() w:reboot() end,
        function() return not w.escBusy and not (w.escParams and w.escParams.changes) end)
    })
  }
  if castle then cards[2].summary=L.castleTelemetryShort end
  if not castle and w.data.esc_sensor_config.protocol>0 then
    cards[#cards+1]=w:cardDef(L.port,L.telemetryPortHint,{port})
  end
  cards[#cards+1]=w:cardDef(L.telemetryCheck,L.telemetryCheckHint,{
    w:button(function() return w.trial and L.cancelDetect or L.detectWiring end,
      function() if w.trial then w:stopTrial(true) else w:startTrial("esc_sensor_trial") end end,
      function() return w.trial ~= nil or w:canDetect(1024) end),
    w:value(L.voltage, function() local m = motor(); return m and w.powerFields.reading(m.voltage, 1000, "V") or "--" end),
    w:value(L.temperature, function() local m = motor(); return m and string.format("%.1f°C", m.temperature / 10) or "--" end),
  })
  cards[#cards].summary=L.telemetryCheckShort
  cards[#cards+1]=w:cardDef(L.telemetryStatus,L.telemetryStatusHint,{
    w:value(L.current, function() local m = motor(); return m and w.powerFields.reading(m.current, 1000, "A") or "--" end),
    w:value(L.rpm, function() local m = motor(); return m and m.rpm or "--" end),
    w:value(L.active,function()
      local m=motor();return m and (m.voltage>0 or m.temperature>0) and L.receiving or L.noTelemetry
    end),
    w:value(L.protocol,function() return castle and "Castle Link" or w.data.esc_sensor_config.protocol==0 and L.off or L.on end)
  })
  w:loadModule("app/pages/helicopter_setup/power_cards.lua")(w, cards)
  w:escCards(cards)
  return cards
end
