return function(w)
  local L = w.L
  local fields = w:loadModule("lib/governor_fields.lua")
  local function mode()
    if (w.data.feature_config.enabledFeatures & (1 << 26)) == 0 then return 0 end
    return w.data.governor_config.gov_mode
  end
  local function governs() return mode() == 3 or mode() == 4 end
  local function source()
    if (w.data.feature_config.enabledFeatures & (1 << 28)) ~= 0 then return 1 end
    return w.data.motor_config.use_dshot_telemetry ~= 0 and 2 or 0
  end
  local profiles = {}
  local range = w.math.rangeOf(w.data.adjustment_ranges.adjustment_ranges, 2)
  if range then
    for i = math.max(1, range.adjMin), math.min(w.data.status.pid_profile_count, range.adjMax) do
      profiles[#profiles + 1] = i - 1
      if #profiles == 3 then break end
    end
  end
  if #profiles == 0 then profiles[1] = 0 end
  local function enter()
    if w.governorFilterLoaded and (not governs() or w.governorLoaded) then return end
    w.transition = true
    if not w.governorFilterLoaded then
      w:read("filter_config", function(d) w.data.filter_config = d end)
      w:run(function()
        w.governorRpmFilter = w.data.filter_config.rpm_preset ~= 0
        -- CUSTOM (preset zero) is enabled by any configured notch on any axis.
        if not w.governorRpmFilter then
          for axis = 0, 2 do
            w:read("rpm_filter_v2", function(d)
              for i = 1, 16 do
                if d["notch_source_" .. i] == nil then w:fail("rpm_filter_v2", "decode"); return end
                if d["notch_source_" .. i] ~= 0 then w.governorRpmFilter = true end
              end
            end, false, {axis})
          end
        end
        w:run(function()
          w.governorFilterLoaded = true
          w.transition = nil; w.buildRequested = true; w:rebuild()
        end)
      end)
    end
    if governs() and not w.governorLoaded then
      local previous = w.governorSpeeds or {}
      w.governorSpeeds = {}
      for index in pairs(w.governorChanged or {}) do w.governorSpeeds[index] = previous[index] end
      local index = w.data.status.current_pid_profile_index
      w:read("governor_profile", function(d)
        if not (w.governorChanged and w.governorChanged[index]) then
          w.governorSpeeds[index] = d.governor_headspeed
        end
      end)
      w:run(function()
        w.governorLoaded = true
        -- Filter jobs appended by the earlier run still own the transition.
        if w.governorFilterLoaded then w.transition = nil; w.buildRequested = true; w:rebuild() end
      end)
    end
  end
  local function readAll()
    if not governs() or w.transition then return end
    w.transition = true
    w:profileLoop("pid", #profiles, nil, profiles, function(d, index)
      if not (w.governorChanged and w.governorChanged[index]) then
        w.governorSpeeds[index] = d.governor_headspeed
      end
    end)
    w:run(function()
      w.transition = nil; w.buildRequested = true; w:rebuild()
    end)
  end
  w.commit = function()
    local chosen = {}
    if governs() then
      for _, id in ipairs(profiles) do
        if w.governorChanged and w.governorChanged[id] then chosen[#chosen + 1] = id end
      end
    end
    if #chosen > 0 then
      w:profileLoop("pid", #chosen, function(d, index)
        d.governor_headspeed = w.governorSpeeds[index]
      end, chosen)
    end
    w:run(function()
      w.governorChanged = nil
      if not governs() then w.governorLoaded, w.governorSpeeds = nil, nil end
    end)
  end
  local function setMode(v)
    w:field("governor_config", "gov_mode", v - 1, true)
    w:feature(26, v > 1)
    w.rebootPending = true
    if v < 4 and w.data.governor_config.gov_throttle_type == 1 then
      w:field("governor_config", "gov_throttle_type", 0, true)
    end
    w.buildRequested=true;w:rebuild()
  end
  local cards = { w:cardDef(L.governorMode, L.governorHint, {
    { kind = "choice", label = L.mode, values = { L.off, L.limit, L.direct, L.electric, L.nitro },
      get = function() return mode() + 1 end, set = setMode }
  }, enter) }
  cards[1].summary = L.governorSummary
  if governs() then
    cards[1].rows[#cards[1].rows+1] = w:button(L.readAllProfiles, readAll,
      function() return w.governorLoaded == true and not w.transition end)
  end
  if mode()>0 or w.governorRpmFilter then
    cards[#cards+1]=w:cardDef(L.rpmSource, L.rpmSourceHint, {
      { kind = "choice", label = L.rpmSource, fullWidth = w.wideScreen, allowUnset = true, values = { L.rpmWire, L.bidirectionalDshot },
        get = source,
        set = function(v)
          if (mode()==0 and not w.governorRpmFilter) or (v~=1 and v~=2) then return end
          -- DShot150 ESCs send no bidirectional DShot RPM; the protocol is changed in the Motor step.
          if v==2 and w.data.motor_config.motor_pwm_protocol==5 then w.message=L.dshot150NoRpm;return end
          w:feature(28, v==1)
          if v==2 then w:field("motor_config", "use_dshot_telemetry", 1, true) end
          w.rebootPending = true
          w.buildRequested = true; w:rebuild()
        end,enabled=function() return mode()>0 or w.governorRpmFilter end },
      w:value(L.linkStatus, function() return w:rpmStatus() end)
    })
    cards[#cards].summary = L.rpmSourceSummary
    if w.governorRpmFilter and source() == 0 then
      local warning = w:cardDef(L.rpmFilter, L.rpmFilterHint, {
        {kind="notice", get=function() return L.rpmFilterMissing end},
        {kind="notice", get=function() return L.rpmFilterChoose end},
        {kind="notice", get=function() return L.rpmFilterDisable end}
      })
      warning.summaryColor = "warning"
      cards[#cards+1] = warning
    end
  end
  if mode()>0 then
    cards[#cards+1]=w:cardDef(L.throttleType, L.throttleTypeHint, {
      { kind = "choice", label = L.throttleType, values = { L.normal, L.switch, L.functionMode },
        get = function() return w.data.governor_config.gov_throttle_type + 1 end,
        set = function(v)
          if mode()==0 then return end
          if v == 2 and mode() < 3 then w.message = L.governorSwitch; return end
          w:field("governor_config", "gov_throttle_type", v - 1, true)
        end,enabled=function() return mode()>0 end }
    })
  end
  if governs() then
    for _, id in ipairs(profiles) do
      local index = id
      local spec = fields.headspeed
      cards[#cards+1] = w:cardDef(string.format(L.headspeedProfile, index + 1), L.headspeedHint, {
        {kind="number", label=L.headspeed, min=spec.min, max=spec.max,
          display=function(v) return w.governorSpeeds and w.governorSpeeds[index] ~= nil and tostring(v) or "--" end,
          get=function() return w.governorSpeeds and w.governorSpeeds[index] or 0 end,
          set=function(v)
            if not governs() or not w.governorLoaded or w.governorSpeeds[index] == nil then return end
            local value = v
            if value == w.governorSpeeds[index] then return end
            w.governorSpeeds[index] = value
            w.governorChanged = w.governorChanged or {}; w.governorChanged[index] = true
            w:touch("governor_profile")
          end, enabled=function() return governs() and w.governorLoaded == true and w.governorSpeeds[index] ~= nil end}
      }, enter)
      cards[#cards].summary = L.headspeedSummary
    end
    local rows = {}
    for _, item in ipairs({{"gov_spoolup_time", L.spoolupTime}, {"gov_spooldown_time", L.spooldownTime},
      {"gov_recovery_time", L.recoveryTime}}) do
      local key, label = item[1], item[2]
      local spec = fields[key]
      local row = w:n("governor_config", key, label, spec.min, spec.max)
      row.display = fields.seconds
      row.enabled = governs
      rows[#rows+1] = row
    end
    cards[#cards+1] = w:cardDef(L.rampTimes, L.rampHint, rows)
    cards[#cards].summary = L.rampSummary
  end
  return cards
end
