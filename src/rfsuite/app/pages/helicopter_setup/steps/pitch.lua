return function(w)
  local L, H = w.L, w.math
  w.pitchMeasured = w.pitchMeasured or { 90, 90 }
  local status = w.data.status
  -- The rate profiles on the profile switch, else the active one. At most three fit one card and
  -- three positions are what a switch offers; only the profiles shown here are written.
  local profiles = {}
  for i, id in ipairs(H.rateProfiles(w.data.adjustment_ranges.adjustment_ranges,
    status.current_control_rate_profile_index, status.control_rate_profile_count)) do
    if i <= 3 then profiles[i] = id end
  end
  local cards = {}
  -- One cyclic calibration, as every interface to the firmware has it. It is measured over roll,
  -- with pitch and collective at zero, so the rotor head stays where it stood for collective, the
  -- blades along the boom. Its rate goes to roll and pitch alike.
  for _, calibration in ipairs({ {4, L.collective, 1, L.pitchMeasureHint}, {1, L.cyclic, 2, L.pitchMeasureCyclicHint} }) do
    local axis, title, index, hint = calibration[1], calibration[2], calibration[3], calibration[4]
    cards[#cards + 1] = w:cardDef(title, hint, {
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
        w.message = L.calibratedMeasureAgain
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
  local function zero() w:holdAxes(nil, 0) end
  local function limit(axis, label)
    return { kind = "number", label = label, min = 0, max = 200, divisor = 10,
      get = function() return H.round(w.data.mixer_input.inputs[axis].max * 0.12) end,
      set = function(v)
        for _, i in ipairs(axis == 2 and {1,2} or {4}) do
          local d = w.data.mixer_input.inputs[i]; d.min, d.max = -H.round(v / 0.12), H.round(v / 0.12)
        end; w:touch("mixer_input", false, true)
      end }
  end
  local function limitCard(axis, label, use, tenths)
    local row = limit(axis, label)
    cards[#cards + 1] = w:cardDef(label, L.pitchLimitHint, { row,
      w:button(use, function() row.set(tenths) end) }, zero)
  end
  limitCard(2, L.cyclicLimit, L.useTen, 100)
  limitCard(4, L.collectiveLimit, L.useTwelve, 120)
  cards[#cards + 1] = w:cardDef(L.totalLimit, L.totalLimitHint, {
    { kind = "number", label = L.totalLimit, min = 0, max = 360, divisor = 10,
      get = function() return H.round(w.data.mixer_config.swash_pitch_limit * 0.12) end,
      set = function(v) w:field("mixer_config", "swash_pitch_limit", H.round(v / 0.12), false, true) end }
  }, zero)
  -- The collective at full stick lives in each rate profile, so each profile is read and only a
  -- value the pilot changed is written, at Save. A style the wizard cannot express shows no value.
  local function enterFull()
    zero()
    if w.pitchLoaded then return end
    w.pitchLoaded, w.transition = true, true
    w.pitchFull = w.pitchFull or {}
    w:profileLoop("rates", #profiles, nil, profiles, function(d, index)
      if not (w.pitchFullChanged and w.pitchFullChanged[index]) then w.pitchFull[index] = H.collective(d) end
      if w.logDebug then w:log("debug", "rate profile %s collective read", index) end
    end)
    w:run(function() w.transition = nil end)
  end
  local rows = {}
  for _, id in ipairs(profiles) do
    local index = id
    rows[#rows + 1] = { kind = "number", label = string.format(L.rateProfileTitle, index + 1), min = 0, max = 250, divisor = 10,
      display = function(v)
        if not (w.pitchFull and w.pitchFull[index]) then return "--" end
        return string.format("%.1f", v / 10)
      end,
      get = function() return H.round(((w.pitchFull and w.pitchFull[index]) or 0) * 10) end,
      set = function(v)
        if not (w.pitchFull and w.pitchFull[index]) then return end
        w.pitchFull[index] = v / 10
        w.pitchFullChanged = w.pitchFullChanged or {}; w.pitchFullChanged[index] = true
        w:touch("rc_tuning")
      end,
      enabled = function() return w.pitchFull ~= nil and w.pitchFull[index] ~= nil end }
  end
  rows[#rows + 1] = { kind = "notice", get = function()
    local limitDegrees = w.data.mixer_input.inputs[4].max * 0.012
    for _, id in ipairs(profiles) do
      local value = w.pitchFull and w.pitchFull[id]
      if value and value > limitDegrees then return L.fullStickOverLimit end
    end
    return ""
  end }
  local full = w:cardDef(L.fullStick, L.fullStickHint, rows, enterFull)
  full.dense = true
  cards[#cards + 1] = full
  cards[#cards + 1] = w:cardDef(L.bindingTitle, L.bindingHint, { w:check("pitch", L.noBinding) }, zero)
  w.commit = function()
    local chosen = {}
    for _, id in ipairs(profiles) do
      if w.pitchFullChanged and w.pitchFullChanged[id] then chosen[#chosen + 1] = id end
    end
    if #chosen == 0 then return end
    w:profileLoop("rates", #chosen, function(d, index)
      return H.setCollective(d, w.pitchFull[index])
    end, chosen)
    w:run(function() w.pitchFullChanged = nil end)
  end
  w.validate = function() return w:ack("pitch") end
  return cards
end
