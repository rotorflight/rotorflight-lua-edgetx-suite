return function(w)
  local L = w.L
  w.validate = function()
    if w.rebootPending then return w:ack("unplugged") end
    if not w:motorOutputsOk() then w.message = L.motorFailed; return false end
    -- As w:servos() counts them: no cyclic servo without a swashplate.
    local swash = w.data.mixer_config.swash_type
    local needed = (swash == 0 and 0 or swash >= 5 and 2 or 3) + (w:motorised() and 0 or 1)
    if #w:servos() < needed then w.message = L.servoMissing; return false end
    return w:ack("connected") and w:ack("blades")
  end
  if w.rebootPending then
    return { w:cardDef(L.connect, L.rebootGateHint, {
      w:check("unplugged", L.servosUnplugged),
      w:value(L.reboot, function() return L.required end)
    }, nil, "servo") }
  end
  local cards = { w:cardDef(L.plugServos, L.connectHint, {
    w:value(L.motorOutputs, function() return w:motorOutputsOk() and L.ready or L.motorFailed end),
    w:value(L.servos, function() return table.concat(w:servoLabels(), ", ") end),
    w:check("connected", L.servosConnected), w:check("blades", L.bladesRemoved)
  }, nil, "servo") }
  cards[1].summary=L.plugServosShort
  return cards
end
