return function(w)
  local L = w.L
  local function output() return w.data.motor and w.data.motor.motor_1 or 0 end
  local rows = {
    { kind = "toggle", label = L.bladesRemoved, values = { L.no, L.yes },
      get = function() return w.bladesOff and 2 or 1 end, set = function(v) w.bladesOff = v == 2; if v == 1 then w:stopMotor() end end },
    { kind = "number", label = L.powerPercent, min = 5, max = 50, get = function() return w.percent end,
      set = function(v) w.percent = v end },
    { kind = "hold", label = L.holdSpin, press = function() w:spin(0, 1) end, release = function() w:stopMotor() end,
      enabled=function() return w:canSpin(0) end },
    w:value(L.output, function() return output() end)
  }
  local cards = {}
  if w.data.motor_config.motor_pwm_protocol == 0 then
    cards[1] = w:cardDef(L.fullThrottleTitle, L.fullThrottleHint, {
      w:check("escBlades", L.bladesRemoved),
      w:button(function() return w.escStage=="full" and L.cancelTest or L.fullThrottle end, function()
        if w.escStage=="full" then w:stopMotor();w.escStage="idle";w.message=L.ready;return end
        if not w:usable() or w.rebootPending or (w.data.status.motor_count or 0)<1 or not w.checks.escBlades then w.message = L.confirmCheck; return end
        w.motorHold = { index = 0, value = 1000, due = 0, untilAt = getTime() + 6000 }; w.escStage = "full"
      end),
      w:value(L.output, function() return output() end)
    })
    cards[2] = w:cardDef(L.connectBattery, L.connectBatteryPwmHint, {
      w:button(L.cancelTest, function() w:stopMotor();w.escStage="idle";w.message=L.ready end,
        function() return w.escStage=="full" end),
      w:button(L.lowThrottle, function() w:stopMotor(); w.escStage = "low" end,
        function() return w.escStage == "full" and output() >= 1995 end),
    })
    cards[3] = w:cardDef(L.lowThrottle, L.lowThrottleHint, {
      w:button(L.calibrationDone, function()
        if w.escStage == "low" and output() > 0 and output() <= 1005 then w.calibratedEsc = true; w.message = L.ready end
      end),
      w:value(L.output, function() return output() end)
    })
    cards[1].summary=L.fullThrottleShort
    cards[2].summary=L.connectBatteryShort
    cards[3].summary=L.lowThrottleShort
  else
    cards[1] = w:cardDef(L.connectBattery, L.connectBatteryHint, {})
  end
  cards[#cards + 1] = w:cardDef(L.throttle, L.spinHint, rows, nil, "heliBladesOff")
  cards[#cards].meter=function() return math.max(-1,math.min(1,(output()-1000)/500-1)) end
  w.validate = function() return w:ack("motorDirection") end
  cards[#cards + 1] = w:cardDef(L.motorDirection, L.motorDirectionHint, { w:check("motorDirection", L.directionCorrect) })
  return cards
end
