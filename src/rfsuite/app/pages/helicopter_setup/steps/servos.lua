-- An arm-fitting introduction precedes one direction and centre card per servo. Every
-- servo is held at centre while the current servo is tested and nudged in microseconds.
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
  local function servo(index)
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
      if v ~= s.mid then
        s.mid = v; w:touch("servo_configurations", false, true)
      end
    end
    return c
  end
  local swash, tailServo = {}, nil
  for _, i in ipairs(w:servos()) do
    if i == 3 then tailServo = servo(i) else swash[#swash + 1] = servo(i) end
  end
  local function card(c)
    local d = w:cardDef(c.title .. " " .. c.role, L.servoGridHint, {}, holdAll, "servoArm")
    d.servo = c
    return d
  end
  local intro = w:cardDef(L.servoArmsTitle, L.servoArmsHint, {}, nil, "servoArm")
  intro.summary = L.servoArmsShort
  intro.instructions = string.match(L.servoArmsHint, "^[^\n]*\n(.*)$")
  local cards = { intro }
  for _, c in ipairs(swash) do cards[#cards + 1] = card(c) end
  if tailServo then cards[#cards + 1] = card(tailServo) end
  -- Done as in the Configurator: every swash servo's direction is confirmed, and no centre is
  -- further than FAR from its band's centre.
  w.validate = function()
    for _, c in ipairs(swash) do
      if not c.confirmed() then
        w.message = string.format(L.servoBlocked, c.title, c.role, L.servoDirectionMissing)
        if w.logInfo then w:keyMessage("servoBlocked") end
        return false
      end
    end
    for i = 2, #cards do
      local c = cards[i].servo
      if c and c.far() then
        w.message = string.format(L.servoBlocked, c.title, c.role, L.servoFar)
        if w.logInfo then w:keyMessage("servoBlocked") end
        return false
      end
    end
    return true
  end
  return cards
end
