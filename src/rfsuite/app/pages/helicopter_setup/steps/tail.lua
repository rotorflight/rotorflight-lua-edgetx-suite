return function(w)
  local L = w.L
  if w:motorised() then
    local rows = {
      { kind = "toggle", label = L.bladesRemoved, values = { L.no, L.yes },
        get = function() return w.bladesOff and 2 or 1 end, set = function(v) w.bladesOff = v == 2; if v == 1 then w:stopMotor() end end },
      { kind = "number", label = L.powerPercent, min = 5, max = 50, get = function() return w.percent end,
        set = function(v) w.percent = v end },
      { kind = "hold", label = L.holdForward, press = function() w:spin(1, 1) end, release = function() w:stopMotor() end,enabled=function() return w:canSpin(1) end }
    }
    if w.data.mixer_config.tail_rotor_mode == 2 then
      rows[#rows + 1] = { kind = "hold", label = L.holdReverse, press = function() w:spin(1, -1) end,
        release = function() w:stopMotor() end,enabled=function() return w:canSpin(1) end }
    end
    return {
      w:cardDef(L.tail, L.tailMotorHint, rows, nil, "tailMotor"),
      w:cardDef(L.tailIdle, L.tailIdleHint, {
        w:n("mixer_config", "tail_motor_idle", L.idlePercent, 0, 255, false, true, 10),
        w:button(L.usePower, function() w:field("mixer_config", "tail_motor_idle", math.min(w.percent * 10, 255), false, true) end),
        { kind = "hold", label = L.testIdle, press = function()
          if not w:usable() or not w.bladesOff or w.rebootPending or (w.data.status.motor_count or 0)<2 then return end
          w.motorHold = { index = 1, value = w.data.mixer_config.tail_motor_idle, mode="idle", due = 0, untilAt = getTime() + 1500 }
        end, release = function() w:stopMotor() end,enabled=function() return w:canSpin(1) end }
      })
    }
  end
  local function hold(value) w:hold("mixer", 3, value) end
  local function toggle(value) w:toggleHold("mixer", 3, value) end
  -- A held end shows as "Release test" on its own button, as in the blade pitch step.
  local function holdButton(label, value)
    return w:button(function()
      local held = w.holds.mixer3
      return held and held.value == value and L.releaseTest or label
    end, function() toggle(value) end)
  end
  local cards={
    w:cardDef(L.tailCentre, L.tailCentreHint, {
      { kind = "number", label = L.centreDegrees, min = -250, max = 250, divisor = 10,
        get = function() return w.math.round(w.data.mixer_config.tail_center_trim * 0.24) end,
        set = function(v) w:field("mixer_config", "tail_center_trim", w.math.round(v / 0.24), false, true) end },
      w:check("tailCentre", L.tailCentred)
    }, function() hold(0) end, "tail"),
    w:cardDef(L.tailDirection, L.tailDirectionHint, {
      w:value(L.inputYaw, function() return w:stickNow(3) end),
      w:button(L.wrongReverse, function() w:invertInput(3); w.checks.tailDirection = nil end),
      w:check("tailDirection", L.directionCorrect)
    }, function() hold(2502) end,"tailMove"),
    -- 22.5 degrees each way (1000 units per 24 degrees): the tail blades then open to 45 degrees,
    -- a square of paper folded corner to corner, so no pitch gauge is needed.
    w:cardDef(L.tailCalibration, L.tailCalibrationHint, {
      holdButton(L.holdPositive22, 938),
      holdButton(L.holdNegative22, -938),
      { kind = "number", label = L.ratePercent, min = 100, max = 5000, divisor = 10,
        get = function() return math.abs(w.data.mixer_input.inputs[3].rate) end,
        set = function(v)
          local input = w.data.mixer_input.inputs[3]; input.rate = (input.rate < 0 and -1 or 1) * v
          w:touch("mixer_input", false, true)
        end }
    }, function() hold(0) end, "tail22"),
    w:cardDef(L.tailLimits, L.tailLimitHint, {
      holdButton(L.holdPositive60, 2500),
      holdButton(L.holdNegative60, -2500),
      { kind = "number", label = L.clockwiseDegrees, min = 0, max = 600, divisor = 10,
        get = function() return w.math.round(-w.data.mixer_input.inputs[3].min * 0.24) end,
        set = function(v) w.data.mixer_input.inputs[3].min = -w.math.round(v / 0.24); w:touch("mixer_input", false, true) end },
      { kind = "number", label = L.counterclockwiseDegrees, min = 0, max = 600, divisor = 10,
        get = function() return w.math.round(w.data.mixer_input.inputs[3].max * 0.24) end,
        set = function(v) w.data.mixer_input.inputs[3].max = w.math.round(v / 0.24); w:touch("mixer_input", false, true) end }
    }, function() hold(0) end)
  }
  cards[3].summary=L.tailCalibrationShort
  cards[2].meter=function() return w.data.rc_command and (w.data.rc_command.commands[3] or 0)/500 or 0 end
  w.validate=function() return w:ack("tailCentre") and w:ack("tailDirection") end
  return cards
end
