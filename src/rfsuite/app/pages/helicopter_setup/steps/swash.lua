return function(w)
  local L = w.L
  local function expectedOutput() return w:motorised() and 1 or 0 end
  local pinNames, onSave = { L.servo4, L.motor2, L.both, L.noPin }, {}
  -- The pin is moved when it does not suit the tail kind and the firmware has not refused that
  -- move already: a refusal is reported once and the step goes on, as the Configurator does.
  local function pinMovable()
    local tail, expected = w.data.tail_motor_output, expectedOutput()
    return tail ~= nil and tail.output ~= expected and tail.output ~= 3 and tail.output ~= 2
      and w.tailPinRefused ~= expected
  end
  if pinMovable() then w.dirty.tail_motor_output = true end
  w.commit = function()
    local expected = expectedOutput()
    if pinMovable() then
      w:write("tail_motor_output", { action = expected + 1 }, function(d)
        if not d then w:fail("tail_motor_output", "reply"); return end
        w.data.tail_motor_output = d
        if d.result ~= 0 or d.output ~= expected then
          w.tailPinRefused = expected
          w.tailPinNotice = string.format(L.tailPinRefused, L["tailPinResult" .. tostring(d.result)] or L.unknown)
          w.stayNotice = w.tailPinNotice
          if w.logInfo then
            w.stayNoticeKey = "tailPinRefused"
            w:log("info", "tail pin refused, result %s", d.result)
          end
        else
          w.tailPinRefused, w.tailPinNotice = nil, nil
          w.rebootPending = true
        end
      end, false, true)
    end
    if (w.startTail ~= 0) ~= w:motorised() then
      w:profileLoop("pid", w.data.status.pid_profile_count, function(d)
        d.governor_tta_gain = w:motorised() and 100 or 0
      end)
      w:run(function() w.startTail = w.data.mixer_config.tail_rotor_mode end)
    end
  end
  local tail = w:c("mixer_config", "tail_rotor_mode", L.tailType, { L.servoTail, L.motorTail, L.bidirectional }, true, true)
  local set = tail.set
  tail.set = function(v)
    local old = w.data.mixer_config.tail_rotor_mode; set(v)
    if old ~= w.data.mixer_config.tail_rotor_mode then
      local input = w.data.mixer_input.inputs[3]
      input.rate = (input.rate < 0 and -1 or 1) * (w:motorised() and 1000 or 250)
      w:touch("mixer_input", false, true)
    end
  end
  -- Three cards, as the Configurator's step has three parts: the swashplate type, the main
  -- rotor direction and the tail. Each picture follows the value chosen on its card.
  local cards = { w:cardDef(L.swashType, L.swashTypeHint, {
    w:c("mixer_config", "swash_type", L.swashType, { L.direct, "120", "135", "140", "90L", "90V" }, true, true, 1),
    {kind="choice",label=L.servoOnePosition,values={L.frontPosition,L.rearPosition},
      get=function() return w.swashRear and 2 or 1 end,
      set=function(v) w.swashRear=v==2 end,
      enabled=function() local s=w.data.mixer_config.swash_type;return s>=2 and s<=4 end}
  }, nil, "swashType"), w:cardDef(L.rotorDirection, L.rotorDirectionHint, {
    w:c("mixer_config", "main_rotor_dir", L.rotorDirection, { L.clockwise, L.counterclockwise }, false, true)
  }, nil, "rotorDir"), w:cardDef(L.tailType, L.tailTypeHint, {
    tail,
    -- The output the tail uses once saved: a pin the save moves shows where it goes. Both outputs
    -- or none are named with the Mixer, where they are set. Each moved text is formatted once.
    w:value(L.tailPin, function()
      local d = w.data.tail_motor_output
      if not d then return L.unsupported end
      if not pinMovable() then return pinNames[d.output + 1] end
      local output = expectedOutput()
      onSave[output] = onSave[output] or string.format(L.tailPinOnSave, pinNames[output + 1])
      return onSave[output]
    end),
    w:value(L.tailServo,function() return w:motorised() and L.none or L.servo4 end)
  }, nil, "tailKind") }
  cards[3].summary = function()
    if w.tailPinRefused == expectedOutput() and w.tailPinNotice then return w.tailPinNotice end
    return L.tailTypeHint
  end
  -- The step closes on what it sets: the layout picture beside every value it writes.
  local shownRate, rateText
  local ttaMotor, ttaServo = string.format(L.ttaEvery, 100), string.format(L.ttaEvery, 0)
  local swashNames = { L.direct, "120", "135", "140", "90L", "90V" }
  local tailNames = { L.servoTail, L.motorTail, L.bidirectional }
  local done = w:cardDef(L.swashSet, L.tailTypeHint, {
    w:value(L.swashType, function() return swashNames[w.data.mixer_config.swash_type] or L.unknown end),
    w:value(L.rotorDirection, function()
      return w.data.mixer_config.main_rotor_dir == 1 and L.counterclockwise or L.clockwise
    end),
    w:value(L.tailType, function()
      return tailNames[w.data.mixer_config.tail_rotor_mode + 1] or L.unknown
    end),
    cards[3].rows[2],
    -- What the tail choice also sets: the yaw input rate and, between servo and motor tail, TTA.
    w:value(L.yawInputRate, function()
      local rate = math.abs(w.data.mixer_input.inputs[3].rate)
      if rate ~= shownRate then shownRate, rateText = rate, string.format(L.percentValue, string.format("%g", rate / 10)) end
      return rateText
    end),
    w:value(L.ttaGain, function()
      if (w.startTail ~= 0) == w:motorised() then return L.unchanged end
      return w:motorised() and ttaMotor or ttaServo
    end)
  }, nil, "swashType")
  done.summary = function() return next(w.dirty) and L.stepChanged or L.stepUnchanged end
  done.dense = true
  cards[4] = done
  for _, card in ipairs(cards) do card.wideText = true end
  return cards
end
