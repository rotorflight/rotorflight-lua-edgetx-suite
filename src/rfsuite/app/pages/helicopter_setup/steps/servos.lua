-- Servo direction and centre on one page, as the Configurator wizard shows it: every servo is
-- held at its centre while the page is open, one at a time is moved up 20 degrees for the
-- direction question, and the centre is nudged in microseconds.
return function(w)
  local L = w.L
  local TEST = 400 -- override units: 1000 is 50 degrees on a PWM servo
  local FAR = 100  -- a centre further than this from the band's should move the arm a spline
  w.servoTest = w.servoTest or {}
  local t = w.servoTest
  local roles = {
    { L.rolePitch, L.roleRoll, L.roleCollective },
    { L.roleCentreLine, L.roleLeft, L.roleRight },
    { L.roleCentreLine, L.roleLeft, L.roleRight },
    { L.roleCentreLine, L.roleLeft, L.roleRight },
    { L.roleFront, L.roleLeft },
    { L.roleFrontLeft, L.roleFrontRight }
  }
  local function holdAll()
    t.testing = nil
    for _, i in ipairs(w:servos()) do w:hold("servo", i, 0) end
  end
  local function centreOf(s) return s.mid > 860 and 1520 or 760 end
  local function column(index)
    local s = w.data.servo_configurations.servos[index]
    local tail = index == 3
    local c = { index = index, tail = tail, title = L.servo .. " " .. (index + 1) }
    c.role = tail and L.roleTail or (roles[w.data.mixer_config.swash_type] or {})[index + 1] or ""
    c.testing = function() return t.testing == index end
    c.confirmed = function() return tail or w.checks["servoUp" .. index] == true end
    c.far = function() return math.abs(s.mid - centreOf(s)) > FAR end
    c.live = function()
      local v = w.data.servo and w.data.servo.servos and w.data.servo.servos[index + 1]
      return (v and (v .. " us") or "--") .. (c.reversed() and ("  " .. L.reversed) or "")
    end
    c.reversed = function() return (s.flags & 1) ~= 0 end
    c.status = function()
      if c.far() then return L.servoFar end
      if tail then return "" end
      if c.testing() then return L.servoQuestion end
      return c.confirmed() and L.directionOk or L.directionOpen
    end
    c.offset = function() return string.format(L.offsetFrom, s.mid, s.mid - centreOf(s)) end
    c.test = function()
      if t.testing ~= nil then w:hold("servo", t.testing, 0) end
      if t.testing == index then t.testing = nil; return end
      t.testing = index
      w:hold("servo", index, TEST)
    end
    c.up = function()
      w.checks["servoUp" .. index] = true
      t.testing = nil
      w:hold("servo", index, 0)
    end
    -- Reversed: flip only the reverse bit and keep the test running so the change shows.
    c.down = function()
      s.flags = s.flags ~ 1
      w.checks["servoUp" .. index] = nil
      w:touch("servo_configurations", false, true)
    end
    c.nudge = function(delta)
      local centre = centreOf(s)
      local range = centre == 760 and 200 or 400
      local v = math.max(centre - range, math.min(centre + range, s.mid + delta))
      if v ~= s.mid then s.mid = v; w:touch("servo_configurations", false, true) end
    end
    return c
  end
  local swash, tailColumn = {}, nil
  for _, i in ipairs(w:servos()) do
    if i == 3 then tailColumn = column(i) else swash[#swash + 1] = column(i) end
  end
  local function card(cols)
    local d = w:cardDef(L.servoDirectionCentre, L.servoGridHint, {}, holdAll)
    d.grid, d.summary = cols, L.servoGridQuick
    return d
  end
  local cards = {}
  if w.wideScreen then
    local all = {}
    for _, c in ipairs(swash) do all[#all + 1] = c end
    if tailColumn then all[#all + 1] = tailColumn end
    if #all > 0 then cards[1] = card(all) end
  else
    if #swash > 0 then cards[#cards + 1] = card(swash) end
    if tailColumn then cards[#cards + 1] = card({ tailColumn }) end
  end
  if #cards == 0 then
    cards[1] = w:cardDef(L.servoDirectionCentre, L.servoGridHint, { w:value(L.servo, function() return L.unavailable end) })
  end
  -- Done as in the Configurator: every swash servo's direction is confirmed, and no centre is
  -- further than FAR from its band's centre.
  w.validate = function()
    for _, c in ipairs(swash) do if not w:ack("servoUp" .. c.index) then return false end end
    for _, c in ipairs(swash) do if c.far() then w.message = L.servoFar; return false end end
    if tailColumn and tailColumn.far() then w.message = L.servoFar; return false end
    return true
  end
  return cards
end
