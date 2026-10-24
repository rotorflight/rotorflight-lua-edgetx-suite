return function(w)
  local L = w.L
  local function unplugged() return w.checks.unplugged == true end
  local function apply(tail, kind)
    if not w.checks.unplugged then w.message = L.confirmCheck; return end
    local rate = ({50,333,560})[kind]
    if not rate then w.message=L.servoHzQuick;return end
    for _, index in ipairs(w:servos()) do
      if (index == 3) == tail then
        local servo = w.data.servo_configurations.servos[index]
        local narrow = kind == 3
        if (servo.mid <= 860) ~= narrow then
          servo.mid, servo.min, servo.max = narrow and 760 or 1520, narrow and -250 or -700, narrow and 250 or 700
          servo.rneg, servo.rpos = narrow and 250 or 500, narrow and 250 or 500
        end
        if servo.rate ~= rate then w.rebootPending = true end
        servo.rate = rate
      end
    end
    w:touch("servo_configurations", false, true)
    if w.refreshPulse then w.refreshPulse() end
  end
  local function current(tail)
    local result
    for _, index in ipairs(w:servos()) do
      if (index == 3) == tail then
        local s = w.data.servo_configurations.servos[index]
        local kind = s.rate == 50 and s.mid > 860 and 1 or s.rate == 333 and s.mid > 860 and 2 or
          s.rate == 560 and s.mid <= 860 and 3 or 0
        if result and result ~= kind then return 0 end
        result = kind
      end
    end
    return result or 0
  end
  local function row(tail, label)
    return { kind = "choice", label = label, enabled = unplugged, values = { L.analog, L.digital, L.narrow,L.customServo },
      get = function() local v=current(tail);return v==0 and 4 or v end, set = function(v) apply(tail, v) end }
  end
  local function rateRow(tail,indices)
    return {kind="number",label=L.servoHz,min=25,max=5000,enabled=unplugged,
      get=function() return w.data.servo_configurations.servos[indices[1]].rate end,
      set=function(v)
        if not w.checks.unplugged then w.message=L.confirmCheck;return end
        if type(v)~="number" or v%1~=0 or v<25 or v>5000 then return end
        local changed=false
        for _,index in ipairs(indices) do
          local servo=w.data.servo_configurations.servos[index]
          if servo.rate~=v then servo.rate=v;changed=true end
        end
        if changed then w.rebootPending=true;w:touch("servo_configurations",false,true) end
        if w.refreshPulse then w.refreshPulse() end
      end}
  end
  local cards={}
  for _,tail in ipairs({false,true}) do
    local indices={}
    for _,index in ipairs(w:servos()) do if (index==3)==tail then indices[#indices+1]=index end end
    if #indices>0 then
      local rows={w:check("unplugged",L.servosUnplugged),row(tail,tail and L.tailServo or L.cyclicServos),rateRow(tail,indices),
        w:value(L.groupState,function()
          local first=w.data.servo_configurations.servos[indices[1]]
          for _,index in ipairs(indices) do
            local s=w.data.servo_configurations.servos[index]
            if s.rate~=first.rate or (s.mid<=860)~=(first.mid<=860) then return L.mixed end
          end
          return L.uniform
        end)}
      local card=w:cardDef(tail and L.tailServo or L.cyclicServos,L.servoHzHint,rows,nil,"pulses")
      card.summary=function() return unplugged() and L.servoHzQuick or L.servoUnpluggedRequired end
      card.servoIndex,card.servoIndices=indices[1],indices
      cards[#cards+1]=card
    end
  end
  -- Geometry correction is bit 1; bit 0 reverses the servo. The firmware reads it
  -- on every servo update, so each group can change it without a restart.
  local function geometryCard(indices, title)
    local card=w:cardDef(title,L.geometryHint,{
      {kind="choice",label=L.geometryCorrection,values={L.off,L.on},
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
    })
    card.summary=L.geometryQuick
    cards[#cards+1]=card
  end
  local cyclic,tail={},{}
  for _,index in ipairs(w:servos()) do
    if index==3 then tail[#tail+1]=index else cyclic[#cyclic+1]=index end
  end
  if #cyclic>0 then geometryCard(cyclic,L.geometryCorrection) end
  if #tail>0 and not w:motorised() then geometryCard(tail,L.tailGeometryCorrection) end
  if #cards==0 then cards[1]=w:cardDef(L.servoType,L.servoTypeHint,{w:value(L.servo,function() return L.unavailable end)}) end
  return cards
end
