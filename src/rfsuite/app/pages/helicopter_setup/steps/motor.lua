return function(w)
  local L = w.L
  w.commit = function() w:fixMotor() end
  -- Bidirectional DShot is an on/off setting and applies to the DShot protocols only.
  -- DShot150 ESCs send no bidirectional DShot RPM.
  local dshot = w:c("motor_config", "use_dshot_telemetry", L.bidirectionalDshot, { L.off, L.on }, true)
  dshot.enabled = function()
    local p = w.data.motor_config.motor_pwm_protocol
    return p >= 6 and p <= 8
  end
  local protocol = w:enum("motor_config", "motor_pwm_protocol", L.protocol, w:motorProtocols(), true)
  local setProtocol = protocol.set
  protocol.set = function(v)
    setProtocol(v)
    -- An ESC that does not answer the bidirectional request may not arm.
    local m = w.data.motor_config
    if m.motor_pwm_protocol == 5 and m.use_dshot_telemetry ~= 0 then
      w:field("motor_config", "use_dshot_telemetry", 0, true)
    end
  end
  local cards = {
    w:cardDef(L.throttleProtocol, L.motorHint, {
      protocol,
      dshot,
      w:check("blades", L.bladesRemoved)
    }, nil, "heliBladesOff"),
    w:cardDef(L.motorGearing, L.motorGearingHint, {
      w:n("motor_config", "motor_pole_count_0", L.motorPoles, 2, 255, true),
      w:n("motor_config", "main_rotor_gear_ratio_0", L.motorPinion, 1, 50000, true),
      w:n("motor_config", "main_rotor_gear_ratio_1", L.mainGear, 1, 50000, true),
      w:value(L.ratio, function()
        local d = w.data.motor_config
        return string.format("%.3f", d.main_rotor_gear_ratio_1 / math.max(1, d.main_rotor_gear_ratio_0))
      end)
    }, nil, "motorGears"),
    w:cardDef(L.motorGearingTail, L.tailDriveHint, w:motorised() and {
      w:n("motor_config", "motor_pole_count_1", L.tailMotorPoles, 2, 255, true)
    } or {
      w:n("motor_config", "tail_rotor_gear_ratio_0", L.tailInputGear, 1, 50000, true),
      w:n("motor_config", "tail_rotor_gear_ratio_1", L.tailOutputGear, 1, 50000, true)
    })
  }
  -- A new ESC is set up first in the Suite's ESC Tools; with a host that can open pages, one press.
  if type(w.openPage) == "function" then
    table.insert(cards[1].rows, w:button(L.openEscTools, function() w:openSuitePage("esc_tools_menu") end))
  end
  cards[1].summary=function()
    return w.data.motor_config.motor_pwm_protocol == 5 and L.dshot150NoRpm or L.motorQuick
  end
  cards[2].summary=L.motorGearingShort
  return cards
end
