return function(w)
  local L = w.L
  local function unplugged() return w.checks.unplugged == true end
  -- Servo types per group: centre pulse (1520 us wide band, 760 us narrow band) and frame rate.
  -- The cyclic and the tail group each offer the types made for them; nothing else is offered.
  local TYPES = {
    cyclic = {
      { key = "analog", name = L.servoAnalog, mid = 1520, rate = 50 },
      { key = "digital", name = L.servoDigital, mid = 1520, rate = 165 },
      { key = "hiend-digital", name = L.servoHiendDigital, mid = 1520, rate = 333 },
      { key = "narrow-band", name = L.servoNarrowBand, mid = 760, rate = 560 },
    },
    tail = {
      { key = "digital", name = L.servoDigital, mid = 1520, rate = 200 },
      { key = "specific-digital", name = L.servoSpecificDigital, mid = 760, rate = 333 },
      { key = "hiend-specific-digital", name = L.servoHiendSpecificDigital, mid = 760, rate = 560 },
    },
  }
  local function group(tail) return tail and "tail" or "cyclic" end
  -- The servos of each group, read once: the swash layout cannot change within this step, and
  -- w:servos() builds a new list, too costly for a getter the screen calls on every refresh.
  local members = { [false] = {}, [true] = {} }
  for _, index in ipairs(w:servos()) do local list = members[index == 3]; list[#list + 1] = index end
  local function apply(tail, kind)
    if not w.checks.unplugged then w.message = L.confirmCheck; return end
    local preset = TYPES[group(tail)][kind]
    if not preset then w.message=L.servoHzQuick;return end
    for _, index in ipairs(members[tail]) do
      do
        local servo = w.data.servo_configurations.servos[index]
        local narrow = preset.mid == 760
        if (servo.mid <= 860) ~= narrow then
          servo.mid, servo.min, servo.max = narrow and 760 or 1520, narrow and -250 or -700, narrow and 250 or 700
          servo.rneg, servo.rpos = narrow and 250 or 500, narrow and 250 or 500
        end
        if servo.rate ~= preset.rate then w.rebootPending = true end
        servo.rate = preset.rate
      end
    end
    w:touch("servo_configurations", false, true)
    if w.refreshPulse then w.refreshPulse() end
  end
  -- The type every servo of the group matches, or 0 when they differ or match none.
  local function current(tail)
    local result
    for _, index in ipairs(members[tail]) do
      do
        local s = w.data.servo_configurations.servos[index]
        local kind = 0
        for n, preset in ipairs(TYPES[group(tail)]) do
          if s.rate == preset.rate and (s.mid <= 860) == (preset.mid == 760) then kind = n end
        end
        if result and result ~= kind then return 0 end
        result = kind
      end
    end
    return result or 0
  end
  -- Servos that match no type open the list on its neutral placeholder; nothing is written until
  -- a type is chosen.
  local function row(tail, label)
    local values = {}
    for n, preset in ipairs(TYPES[group(tail)]) do values[n] = preset.name end
    return { kind = "choice", label = label, enabled = unplugged, values = values, allowUnset = true,
      get = function() return current(tail) end,
      set = function(v) if values[v] then apply(tail, v) end end }
  end
  -- The picture and its caption: the type's servo picture with its name and values, or, while no
  -- type is chosen, the live pulse train of what the servos hold. Texts change only with the setting.
  local function captions(tail, indices)
    local shownKey, long, short
    return function(isShort)
      local first = w.data.servo_configurations.servos[indices[1]]
      local kind = current(tail)
      local key = (kind * 10000 + first.rate) * 10000 + first.mid
      if key ~= shownKey then
        local preset = TYPES[group(tail)][kind]
        local name = preset and preset.name or L.servoNoType
        local values = string.format(L.servoSpec, first.mid, first.rate)
        shownKey, long, short = key, name .. "\n" .. values, name .. "  " .. values
      end
      return isShort and short or long
    end
  end
  -- Geometry correction is bit 1; bit 0 reverses the servo. The firmware reads it on every servo
  -- update, so it is written without a restart. A group whose servos disagree has no single
  -- answer: the list then opens on its placeholder.
  local function geometryRow(indices)
    return {kind="choice",label=L.geometryCorrection,values={L.off,L.on},allowUnset=true,
      get=function()
        local result
        for _,index in ipairs(indices) do
          local on=(w.data.servo_configurations.servos[index].flags & 2)~=0 and 2 or 1
          if result and result~=on then return 0 end
          result=on
        end
        return result or 0
      end,
      set=function(v)
        if v~=1 and v~=2 then return end
        for _,index in ipairs(indices) do
          local s=w.data.servo_configurations.servos[index]
          s.flags=v==2 and (s.flags | 2) or (s.flags & ~2)
        end
        w:touch("servo_configurations",false,true)
      end}
  end
  -- One card per group: the servo type and its geometry correction (a motorised tail has neither).
  local cards={}
  for _,tail in ipairs({false,true}) do
    local indices=members[tail]
    if #indices>0 and not (tail and w:motorised()) then
      local rows={w:check("unplugged",L.servosUnplugged),row(tail,tail and L.tailServo or L.cyclicServos),geometryRow(indices)}
      local card=w:cardDef(tail and L.tailServo or L.cyclicServos,L.servoHzHint.."\n"..L.geometryHint,rows,nil,"pulses")
      card.summary=function() return unplugged() and L.servoCardQuick or L.servoUnpluggedRequired end
      card.servoIndex,card.servoIndices=indices[1],indices
      local text = captions(tail, indices)
      card.caption, card.captionShort = function() return text(false) end, function() return text(true) end
      card.captionLines, card.wideText = 2, true
      -- The type's picture while the group matches a type.
      card.servoPicture=function()
        local preset = TYPES[group(tail)][current(tail)]
        return preset and ("servo-" .. group(tail) .. "-" .. preset.key) or nil
      end
      cards[#cards+1]=card
    end
  end
  if #cards==0 then cards[1]=w:cardDef(L.servoType,L.servoTypeHint,{w:value(L.servo,function() return L.unavailable end)},nil,"servo") end
  return cards
end
