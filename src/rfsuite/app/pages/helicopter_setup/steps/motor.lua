return function(w)
  local L = w.L
  w.commit = function() w:fixMotor() end
  -- Bidirectional DShot is an on/off setting and applies to the DShot protocols only.
  -- DShot150 ESCs send no bidirectional DShot RPM.
  local dshot = w:c("motor_config", "use_dshot_telemetry", L.bidirectionalDshot, { L.off, L.on }, true)
  dshot.enabled = function()
    local p = w.data.motor_config.motor_pwm_protocol
    return p >= 6 and p <= 8
  end
  -- Bidirectional DShot is one of the two RPM sources; turning it on turns the wire sensor off.
  dshot.set = function(v)
    if v == 2 then w:setRpmSource(true) else w:field("motor_config", "use_dshot_telemetry", 0, true) end
  end
  local protocols = w:motorProtocols()
  local protocol = w:enum("motor_config", "motor_pwm_protocol", L.protocol, protocols, true)
  local setProtocol = protocol.set
  protocol.set = function(v)
    local before = w.data.motor_config.motor_pwm_protocol
    setProtocol(v)
    -- An ESC that does not answer the bidirectional request may not arm.
    local m = w.data.motor_config
    if m.motor_pwm_protocol == 5 and m.use_dshot_telemetry ~= 0 then
      w:field("motor_config", "use_dshot_telemetry", 0, true)
    end
    -- With a governor the RPM source follows the protocol: DShot300 and DShot600 carry it,
    -- every other protocol needs the wire sensor.
    if m.motor_pwm_protocol ~= before and w:governorMode() > 0 then
      w:setRpmSource(m.motor_pwm_protocol == 6 or m.motor_pwm_protocol == 7)
    end
  end
  local cards = {
    w:cardDef(L.throttleProtocol, L.motorHint, {
      protocol,
      dshot,
      w:check("blades", L.bladesRemoved)
    }, nil, "heliBladesOff"),
    w:cardDef(L.motorPoles, L.motorPolesHint, {
      w:n("motor_config", "motor_pole_count_0", L.motorPoles, 2, 255, true)
    })
  }
  -- Gearing. The flight controller keeps two products per rotor: main = field 1 / field 0
  -- (main gear : pinion), tail speed = main speed x field 1 / field 0 (drive : tail). Two stages
  -- and a tail driven from the intermediate shaft are entered as tooth counts and stored as
  -- products; the counts are kept for the wizard session (w.gear).
  local m = w.data.motor_config
  local MAX = 50000
  local function or1(v) return (v == nil or v < 1) and 1 or v end
  local g = w.gear
  if not g or g.p0 ~= m.main_rotor_gear_ratio_0 or g.p1 ~= m.main_rotor_gear_ratio_1
    or g.t0 ~= m.tail_rotor_gear_ratio_0 or g.t1 ~= m.tail_rotor_gear_ratio_1 then
    -- Nothing kept, or the products changed elsewhere (a discard): start from the FC's values.
    g = { stages = 1, pinion = or1(m.main_rotor_gear_ratio_0), main = or1(m.main_rotor_gear_ratio_1),
      pinionSide = 1, mainSide = 1, ratio = 100,
      tail = { from = 1, a = or1(m.tail_rotor_gear_ratio_1), b = or1(m.tail_rotor_gear_ratio_0), mesh = 1, ratio = 100 } }
    w.gear = g
  end
  local t = g.tail
  -- A ratio in hundredths as the smallest whole pair: k and ratio x k.
  local function pair(ratio)
    for k = 1, 100 do if (ratio * k) % 100 == 0 then return k, ratio * k // 100 end end
    return 1, ratio // 100
  end
  local function hundredths(a, b) return math.max(100, math.min(10000, math.floor(or1(b) * 100 / or1(a) + 0.5))) end
  local function ratioText(a, b) return string.format(L.ratioFormat, or1(b) / or1(a)) end
  local function mainRatio() return ratioText(m.main_rotor_gear_ratio_0, m.main_rotor_gear_ratio_1) end
  local function tailRatio() return ratioText(m.tail_rotor_gear_ratio_0, m.tail_rotor_gear_ratio_1) end
  -- The intermediate gear meshing with the main gear: the two-stage train's, or the tail's own.
  local function mesh() return g.stages == 2 and g.mainSide or or1(t.mesh) end
  local function keep()
    g.p0, g.p1 = m.main_rotor_gear_ratio_0, m.main_rotor_gear_ratio_1
    g.t0, g.t1 = m.tail_rotor_gear_ratio_0, m.tail_rotor_gear_ratio_1
  end
  keep()
  -- Writes the products of the current counts; refuses counts whose product the FC cannot hold.
  -- Only a changed product is written, so an unchanged count asks for no restart.
  local function apply()
    local p0, p1
    if g.stages == 2 then p0, p1 = g.pinion * g.mainSide, g.pinionSide * g.main
    elseif g.stages == 3 then p0, p1 = pair(g.ratio)
    else p0, p1 = g.pinion, g.main end
    local t0, t1
    if w:motorised() then t0, t1 = m.tail_rotor_gear_ratio_0, m.tail_rotor_gear_ratio_1
    elseif t.from == 2 then t0, t1 = mesh() * t.b, g.main * t.a
    elseif t.from == 3 then t0, t1 = pair(t.ratio)
    else t0, t1 = t.b, t.a end
    if p0 > MAX or p1 > MAX or t0 > MAX or t1 > MAX then
      if w.logDebug then w:log("debug", "gear product refused %s %s %s %s", p0, p1, t0, t1) end
      w.message = L.gearTooLarge; return false
    end
    if w.logTrace then w:log("trace", "gears main %s:%s tail %s:%s", p0, p1, t0, t1) end
    if m.main_rotor_gear_ratio_0 ~= p0 then w:field("motor_config", "main_rotor_gear_ratio_0", p0, true) end
    if m.main_rotor_gear_ratio_1 ~= p1 then w:field("motor_config", "main_rotor_gear_ratio_1", p1, true) end
    if m.tail_rotor_gear_ratio_0 ~= t0 then w:field("motor_config", "tail_rotor_gear_ratio_0", t0, true) end
    if m.tail_rotor_gear_ratio_1 ~= t1 then w:field("motor_config", "tail_rotor_gear_ratio_1", t1, true) end
    keep(); return true
  end
  -- A count or ratio held in the session state; a value the FC cannot hold is taken back.
  local function value(owner, key)
    return { get = function() return owner[key] end,
      set = function(v)
        local before = owner[key]; owner[key] = v
        if not apply() then owner[key] = before end
      end }
  end
  local function ratioDisplay(v) return string.format(L.ratioFormat, v / 100) end
  local function gcd(a, c)
    while c ~= 0 do a, c = c, a % c end
    return a
  end
  local function setStages(v)
    if v == g.stages then return end
    if w.logTrace then w:log("trace", "gear train %s to %s", g.stages, v) end
    -- Kept to take the whole change back when the FC cannot hold a product.
    local before = { g.stages, g.pinion, g.main, g.pinionSide, g.mainSide, g.ratio, t.from, t.a, t.b, t.mesh, t.ratio }
    if v == 2 then
      -- Both intermediate gears start at the main gear's count, a 1:1 pair: the ratio stays.
      if g.stages == 3 then g.pinion, g.main = pair(g.ratio) end
      -- A tail already driven from the intermediate shaft names that shaft's pinion: keep it, so
      -- the tail ratio stays; otherwise both intermediate gears start at the main gear's count.
      local x = t.from == 2 and or1(t.mesh) or g.main
      if g.pinion * x > MAX or x * g.main > MAX then x = 1 end
      g.pinionSide, g.mainSide = x, x
    elseif v == 3 then
      g.ratio = hundredths(m.main_rotor_gear_ratio_0, m.main_rotor_gear_ratio_1)
      if t.from == 2 then t.from, t.ratio = 3, hundredths(m.tail_rotor_gear_ratio_0, m.tail_rotor_gear_ratio_1) end
    elseif g.stages == 2 then
      -- One stage at the same ratio: the pinion keeps its teeth where the main gear comes out
      -- whole, else the smallest whole pair. That main gear is no longer the real one, so a
      -- tail driven from the intermediate shaft becomes the equivalent drive : tail pair.
      if t.from == 2 then
        local t0, t1 = m.tail_rotor_gear_ratio_0, m.tail_rotor_gear_ratio_1
        local d = gcd(t0, t1)
        t.from, t.a, t.b = 1, t1 // d, t0 // d
      end
      local p0, p1 = g.pinion * g.mainSide, g.pinionSide * g.main
      local main = g.pinion * p1 / p0
      if main == math.floor(main) then g.main = math.floor(main)
      else
        local d = gcd(p0, p1)
        g.pinion, g.main = p0 // d, p1 // d
      end
    else g.pinion, g.main = pair(g.ratio) end
    g.stages = v
    if not apply() then
      g.stages, g.pinion, g.main, g.pinionSide, g.mainSide, g.ratio = before[1], before[2], before[3], before[4], before[5], before[6]
      t.from, t.a, t.b, t.mesh, t.ratio = before[7], before[8], before[9], before[10], before[11]
    end
    w.buildRequested = true; w:rebuild()
  end
  local trainNames = { L.stagesOne, L.stagesTwo, L.ratioOnly }
  local mainRows = {
    { kind = "choice", label = L.gearTrain, values = trainNames,
      get = function() return g.stages end, set = setStages }
  }
  if g.stages == 3 then
    local r = value(g, "ratio")
    mainRows[2] = { kind = "number", label = L.gearRatio, min = 100, max = 10000, display = ratioDisplay, get = r.get, set = r.set }
  elseif g.stages == 2 then
    mainRows[2] = { kind = "pair", label = L.pairStage1, min = 1, max = MAX, left = value(g, "pinion"), right = value(g, "pinionSide") }
    mainRows[3] = { kind = "pair", label = L.pairStage2, min = 1, max = MAX, left = value(g, "mainSide"), right = value(g, "main") }
  else
    mainRows[2] = { kind = "pair", label = L.pairSingle, min = 1, max = MAX, left = value(g, "pinion"), right = value(g, "main") }
  end
  mainRows[#mainRows + 1] = w:value(L.mainRatio, mainRatio)
  cards[3] = w:cardDef(L.mainGearRatio, L.mainGearHint, mainRows, nil, "motorGears")
  local tailRows
  if w:motorised() then
    tailRows = { w:n("motor_config", "motor_pole_count_1", L.tailMotorPoles, 2, 255, true) }
  else
    tailRows = {
      { kind = "choice", label = L.tailDriveFrom, values = { L.tailFromMain, L.tailFromIntermediate, L.ratioOnly },
        get = function() return t.from end,
        set = function(v)
          if v == t.from then return end
          -- The intermediate shaft needs tooth counts for the main gear.
          if v == 2 and g.stages == 3 then w.message = L.tailNeedsTeeth; return end
          local before, beforeMesh = t.from, t.mesh; t.from = v
          if v == 3 then t.ratio = hundredths(m.tail_rotor_gear_ratio_0, m.tail_rotor_gear_ratio_1) end
          -- The intermediate gear starts at the main gear's count: a 1:1 mesh, so the ratio stays
          -- until the real count is entered.
          if v == 2 and g.stages ~= 2 then t.mesh = g.main end
          if not apply() then t.from, t.mesh = before, beforeMesh end
          w.buildRequested = true; w:rebuild()
        end }
    }
    if t.from == 3 then
      local r = value(t, "ratio")
      tailRows[2] = { kind = "number", label = L.gearRatio, min = 100, max = 10000, display = ratioDisplay, get = r.get, set = r.set }
    elseif t.from == 2 then
      tailRows[2] = { kind = "pair", label = L.pairMainMesh, min = 1, max = MAX,
        left = g.stages == 2 and value(g, "mainSide") or value(t, "mesh"), right = value(g, "main") }
      tailRows[3] = { kind = "pair", label = L.pairTailShaft, min = 1, max = MAX, left = value(t, "a"), right = value(t, "b") }
    else
      tailRows[2] = { kind = "pair", label = L.pairTail, min = 1, max = MAX, left = value(t, "a"), right = value(t, "b") }
    end
    tailRows[#tailRows + 1] = w:value(L.tailRatio, tailRatio)
  end
  cards[4] = w:cardDef(L.tailGearRatio, L.tailGearHint, tailRows)
  local summaryRows = {
    w:value(L.protocol, function()
      for _, e in ipairs(protocols) do if e[1] == m.motor_pwm_protocol then return e[2] end end
      return tostring(m.motor_pwm_protocol)
    end),
    w:value(L.motorPoles, function() return m.motor_pole_count_0 end),
    w:value(L.gearTrain, function() return trainNames[g.stages] end),
    w:value(L.mainRatio, mainRatio),
    w:motorised() and w:value(L.tailMotorPoles, function() return m.motor_pole_count_1 end) or w:value(L.tailRatio, tailRatio)
  }
  cards[5] = w:cardDef(L.motorDone, L.motorDoneHint, summaryRows)
  cards[5].dense = true
  -- A new ESC is set up first in the Suite's ESC Tools; with a host that can open pages, one press.
  if type(w.openPage) == "function" then
    table.insert(cards[1].rows, w:button(L.openEscTools, function() w:openSuitePage("esc_tools_menu") end))
  end
  cards[1].summary=function()
    return w.data.motor_config.motor_pwm_protocol == 5 and L.dshot150NoRpm or L.motorQuick
  end
  return cards
end
