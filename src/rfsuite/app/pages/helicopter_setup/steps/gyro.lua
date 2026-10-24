return function(w)
  local L = w.L
  local cards = {}
  for _, a in ipairs({ {1, L.roll, L.gyroRollHint}, {2, L.pitch, L.gyroPitchHint}, {3, L.yaw, L.gyroYawHint} }) do
    local axis = a[1]
    if axis ~= 3 or not w:motorised() then
      cards[#cards + 1] = w:cardDef(a[2], a[3], {
        w:check("gyro" .. axis, L.againstMovement),
        w:button(L.withMovement, function() w.checks["gyro" .. axis] = nil; w:navigate(1, 1) end)
      }, function() w:release() end, axis == 1 and "gyroRoll" or axis == 2 and "gyroPitch" or "gyroYaw")
    end
  end
  w.validate = function() return w:ack("gyro1") and w:ack("gyro2") and (w:motorised() or w:ack("gyro3")) end
  return cards
end
