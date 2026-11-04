return function(w)
  local L, H = w.L, w.math
  w.pitchMeasured = w.pitchMeasured or { 90, 90 }
  local status = w.data.status
  -- The rate profiles on the profile switch, else the active one, as the Rates step offers them.
  -- Only the profiles shown here are written.
  local profiles = H.rateProfiles(w.data.adjustment_ranges.adjustment_ranges,
    status.current_control_rate_profile_index, status.control_rate_profile_count)
  local cards = {}
  -- One cyclic calibration, as every interface to the firmware has it. It is measured over roll,
  -- with pitch and collective at zero, so the rotor head stays where it stood for collective, the
  -- blades along the boom. Its rate goes to roll and pitch alike.
  for _, calibration in ipairs({ {4, L.collective, 1, L.pitchMeasureHint}, {1, L.cyclic, 2, L.pitchMeasureCyclicHint} }) do
    local axis, title, index, hint = calibration[1], calibration[2], calibration[3], calibration[4]
    -- Calibration is at 9 degrees; other angles are for checking. The angle is never stored and is
    -- 9 again on every entry, the FC follows it while held, and release goes back to 0. It stays
    -- within the stored limit, which is what a stick could command anyway.
    local limit = math.floor(math.abs(w.data.mixer_input.inputs[axis].max) * 0.12)
    local function held() return w.pitchHeld == index and w.holds["mixer" .. axis] ~= nil end
    local function command(tenths) return H.round(tenths * 750 / 90) end
    local card = w:cardDef(title, hint, {
      { kind = "holdNumber", label = L.degrees, fullWidth = true, min = -limit, max = limit, divisor = 10,
        holdLabel = function() return held() and L.releaseTest or L.holdTest end,
        press = function()
          if held() then w.pitchHeld = nil; w:holdAxes(axis, 0); return end
          w.pitchHeld = index
          w:holdAxes(axis, command(w.pitchAngle or 0))
        end,
        get = function() return w.pitchAngle or 0 end,
        set = function(v)
          w.pitchAngle = v
          if held() then w:holdAxes(axis, command(v)) end
        end },
      { kind = "number", label = L.measuredDegrees, min = 10, max = 300, divisor = 10,
        get = function() return w.pitchMeasured[index] end, set = function(v) w.pitchMeasured[index] = v end },
      w:button(L.apply, function()
        if not held() or w.pitchAngle ~= 90 then return end
        local rate = H.calibrated(w.data.mixer_input.inputs[axis].rate, w.pitchMeasured[index] / 10)
        if not rate then return end
        for _, i in ipairs(index == 1 and {4} or {1,2}) do
          local old = w.data.mixer_input.inputs[i]
          old.rate = (old.rate < 0 and -1 or 1) * math.abs(rate)
        end
        w:touch("mixer_input", false, true); w.pitchMeasured[index] = 90
        w.message = L.calibratedMeasureAgain
      end, function() return held() and w.pitchAngle == 90 end),
      { kind = "number", label = L.ratePercent, min = 200, max = 2000, divisor = 10,
        get = function() return math.abs(w.data.mixer_input.inputs[axis].rate) end,
        set = function(v)
          for _, i in ipairs(index == 1 and {4} or {1,2}) do
            local input = w.data.mixer_input.inputs[i]; input.rate = (input.rate < 0 and -1 or 1) * v
          end; w:touch("mixer_input", false, true)
        end }
    }, function()
      w.pitchHeld, w.pitchAngle = nil, math.min(90, limit)
      w:holdAxes(nil, 0)
    end, "pitch")
    if limit < 90 then card.summary, card.summaryColor = L.pitchLimitBelowNine, "warning" end
    cards[#cards + 1] = card
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
  -- These two last cards hold nothing: the sticks have to move the swash to reach the end stops.
  -- Loaded counts only once every read is in, so a failed read is read again.
  local function enterFull()
    if w.pitchLoaded then return end
    w.transition = true
    w.pitchFull = w.pitchFull or {}
    w:profileLoop("rates", #profiles, nil, profiles, function(d, index)
      if not (w.pitchFullChanged and w.pitchFullChanged[index]) then w.pitchFull[index] = H.collective(d) end
      if w.logDebug then w:log("debug", "rate profile %s collective read", index) end
    end)
    w:run(function() w.pitchLoaded, w.transition = true, nil end)
  end
  local function overLimit()
    local limitDegrees = w.data.mixer_input.inputs[4].max * 0.012
    for _, id in ipairs(profiles) do
      local value = w.pitchFull and w.pitchFull[id]
      if value and value > limitDegrees then return L.fullStickOverLimit end
    end
    return ""
  end
  -- Three rows and the warning fit one card at 480x272; more profiles take another card.
  for first = 1, #profiles, 3 do
    local rows = {}
    for position = first, math.min(first + 2, #profiles) do
      local index = profiles[position]
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
    rows[#rows + 1] = { kind = "notice", get = overLimit }
    local full = w:cardDef(L.fullStick, L.fullStickHint, rows, enterFull)
    full.dense = true
    cards[#cards + 1] = full
  end
  cards[#cards + 1] = w:cardDef(L.bindingTitle, L.bindingHint, { w:check("pitch", L.noBinding) })
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
