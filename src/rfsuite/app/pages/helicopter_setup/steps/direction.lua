return function(w)
  local L = w.L
  local cards = {}
  -- The first row names the input the check needs and shows where the stick is now.
  for _, a in ipairs({ {1, L.rollRight, L.rollHint,L.rightDown,L.inputRoll}, {2, L.pitchForward, L.pitchHint,L.frontDown,L.inputPitch}, {4, L.collectiveUp, L.collectiveHint,L.allUp,L.inputCollective} }) do
    local axis = a[1]
    cards[#cards + 1] = w:cardDef(a[2], a[3], {
      w:value(a[5], function() return w:stickNow(axis) end),
      w:value(L.expected,function() return a[4] end),
      w:button(L.wrongReverse, function() w:invertInput(axis); w.checks["control" .. axis] = nil end),
      w:check("control" .. axis, L.directionCorrect)
    }, function() w:holdAxes(nil, 0, true) end, axis == 1 and "swashRoll" or axis == 2 and "swashPitch" or "swashLift")
  end
  for i,card in ipairs(cards) do
    local axis=({1,2,4})[i]
    card.summary=axis==2 and L.sideCheck or L.rearCheck
    card.meter=function() return w.data.rc_command and (w.data.rc_command.commands[axis] or 0)/500 or 0 end
  end
  w.validate = function() return w:ack("control1") and w:ack("control2") and w:ack("control4") end
  return cards
end
