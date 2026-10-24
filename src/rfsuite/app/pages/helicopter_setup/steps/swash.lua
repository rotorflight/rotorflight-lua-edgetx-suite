return function(w)
  local L = w.L
  local initial = w.data.tail_motor_output
  if initial and initial.output ~= (w:motorised() and 1 or 0) and initial.output ~= 3 and initial.output ~= 2 then
    w.dirty.tail_motor_output = true
  end
  w.commit = function()
    local tail = w.data.tail_motor_output
    local expected = w:motorised() and 1 or 0
    if tail and tail.output ~= expected and tail.output ~= 3 and tail.output ~= 2 then
      w:write("tail_motor_output", { action = expected + 1 }, function(d)
        if not d or d.result ~= 0 or d.output ~= expected then w:fail("tail_motor_output", d and d.result or "reply")
        else w.data.tail_motor_output = d; w.rebootPending = true end
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
  return { w:cardDef(L.swashType, L.swashTypeHint, {
    w:c("mixer_config", "swash_type", L.swashType, { L.direct, "120", "135", "140", "90L", "90V" }, true, true, 1),
    {kind="choice",label=L.servoOnePosition,values={L.frontPosition,L.rearPosition},
      get=function() return w.swashRear and 2 or 1 end,
      set=function(v) w.swashRear=v==2 end,
      enabled=function() local s=w.data.mixer_config.swash_type;return s>=2 and s<=4 end}
  }, nil, "swashType"), w:cardDef(L.rotorDirection, L.rotorDirectionHint, {
    w:c("mixer_config", "main_rotor_dir", L.rotorDirection, { L.clockwise, L.counterclockwise }, false, true)
  }, nil, "rotorDir"), w:cardDef(L.tailType, L.tailTypeHint, {
    tail,
    w:value(L.tailPin, function()
      local d = w.data.tail_motor_output
      if not d then return L.unsupported end
      return ({ L.servo4, L.motor2, L.both, L.noPin })[d.output + 1]
    end),
    w:value(L.tailServo,function() return w:motorised() and L.none or L.servo4 end)
  }, nil, "tailKind") }
end
