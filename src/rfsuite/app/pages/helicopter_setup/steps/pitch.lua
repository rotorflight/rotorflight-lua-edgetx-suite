return function(w)
  local L, H = w.L, w.math
  w.pitchMeasured = w.pitchMeasured or { 90, 90 }
  w.pitchFull = w.pitchFull or H.collective(w.data.rc_tuning)
  local cards = {}
  for _, calibration in ipairs({ {4, L.collective, 1}, {2, L.cyclic, 2} }) do
    local axis, title, index = calibration[1], calibration[2], calibration[3]
    cards[#cards + 1] = w:cardDef(title, L.pitchMeasureHint, {
      w:button(function() return w.holds["mixer"..axis] and w.holds["mixer"..axis].value==750 and L.releaseTest or L.holdNine end, function() w:holdAxes(axis, w.holds["mixer" .. axis] and w.holds["mixer" .. axis].value == 750 and 0 or 750) end),
      { kind = "number", label = L.measuredDegrees, min = 10, max = 300, divisor = 10,
        get = function() return w.pitchMeasured[index] end, set = function(v) w.pitchMeasured[index] = v end },
      w:button(L.apply, function()
        if not w.holds["mixer"..axis] or w.holds["mixer"..axis].value~=750 then return end
        local rate = H.calibrated(w.data.mixer_input.inputs[axis].rate, w.pitchMeasured[index] / 10)
        if not rate then return end
        for _, i in ipairs(index == 1 and {4} or {1,2}) do
          local old = w.data.mixer_input.inputs[i]
          old.rate = (old.rate < 0 and -1 or 1) * math.abs(rate)
        end
        w:touch("mixer_input", false, true); w.pitchMeasured[index] = 90
      end),
      { kind = "number", label = L.ratePercent, min = 200, max = 2000, divisor = 10,
        get = function() return math.abs(w.data.mixer_input.inputs[axis].rate) end,
        set = function(v)
          for _, i in ipairs(index == 1 and {4} or {1,2}) do
            local input = w.data.mixer_input.inputs[i]; input.rate = (input.rate < 0 and -1 or 1) * v
          end; w:touch("mixer_input", false, true)
        end }
    }, function() w:holdAxes(nil, 0) end, "pitch")
  end
  local function limit(axis, label)
    return { kind = "number", label = label, min = 0, max = 200, divisor = 10,
      get = function() return H.round(w.data.mixer_input.inputs[axis].max * 0.12) end,
      set = function(v)
        for _, i in ipairs(axis == 2 and {1,2} or {4}) do
          local d = w.data.mixer_input.inputs[i]; d.min, d.max = -H.round(v / 0.12), H.round(v / 0.12)
        end; w:touch("mixer_input", false, true)
      end }
  end
  cards[#cards + 1] = w:cardDef(L.pitchLimits, L.pitchLimitHint, {
    limit(2, L.cyclicLimit), limit(4, L.collectiveLimit),
    { kind = "number", label = L.totalLimit, min = 0, max = 360, divisor = 10,
      get = function() return H.round(w.data.mixer_config.swash_pitch_limit * 0.12) end,
      set = function(v) w:field("mixer_config", "swash_pitch_limit", H.round(v / 0.12), false, true) end }
  }, function() w:holdAxes(nil, 0) end)
  cards[#cards + 1] = w:cardDef(L.fullStick, L.fullStickHint, {
    { kind = "number", label = L.degrees, min = 0, max = 250, divisor = 10,
      get = function() return H.round((w.pitchFull or 0) * 10) end,
      set = function(v) if not H.collective(w.data.rc_tuning) then return end
        w.pitchFull = v / 10; w.pitchFullChanged = true; w:touch("rc_tuning") end,
      enabled=function() return H.collective(w.data.rc_tuning)~=nil end },
    w:check("pitch", L.noBinding)
  })
  w.commit = function()
    if not w.pitchFullChanged then return end
    w:profileLoop("rates", w.data.status.control_rate_profile_count, function(d)
      return H.setCollective(d, w.pitchFull)
    end)
    w:run(function() w.pitchFullChanged = nil end)
  end
  w.validate = function() return w:ack("pitch") end
  return cards
end
