return function(w)
  local L = w.L
  -- Without a swashplate there is nothing to level; the step says so and offers the way there.
  if w.data.mixer_config.swash_type == 0 then
    if w.logDebug then w:log("debug", "level: no swashplate set") end
    return { w:cardDef(L.level, L.levelNoSwash, { w:button(L.levelToSwash, function() w:navigate(6, 1) end) }) }
  end
  w.validate = function() return w:ack("motorUnplugged") and w:ack("level") and w:ack("bladeZero") end
  local function zero() w:holdAxes(nil, 0) end
  local cards = {}
  -- From here on blades may be fitted to measure, so the motor comes off first and stays off until
  -- Finish. A step opened alone asks the same on its preparation card.
  if not w.singleStep then
    cards[1] = w:cardDef(L.motorOffTitle, L.motorOffHint, { w:check("motorUnplugged", L.motorUnplugged) }, nil, "level")
  end
  cards[#cards + 1] = w:cardDef(L.level, L.levelHint, {
    w:n("mixer_config", "swash_trim_0", L.roll, -1000, 1000, false, true, 10),
    w:n("mixer_config", "swash_trim_1", L.pitch, -1000, 1000, false, true, 10),
    w:n("mixer_config", "swash_trim_2", L.collective, -1000, 1000, false, true, 10),
    w:button(L.reset, function()
      if w.logTrace then w:log("trace", "level trims reset") end
      for i = 0, 2 do w:field("mixer_config", "swash_trim_" .. i, 0, false, true) end
    end)
  }, zero, "level")
  cards[#cards + 1] = w:cardDef(L.levelCheck, L.levelCheckHint, { w:check("level", L.swashLevel) }, zero, "level")
  -- With the swash level, the blade links set zero pitch.
  cards[#cards + 1] = w:cardDef(L.bladeZeroTitle, L.bladeZeroHint, { w:check("bladeZero", L.bladeZero) }, zero, "levelCheck")
  return cards
end
