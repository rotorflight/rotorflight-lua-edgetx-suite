-- Configurator pictures and labelled mechanical references. Reactive getters
-- select cached filenames or prepared geometry without rebuilding the scene.
local M = {}
local GFX = "/SCRIPTS/TOOLS/rfsuite-core/app/pages/helicopter_setup/gfx/"
function M.append(children, w, card, x, y, width, height)
  local ink, accent = w.palette.text, w.palette.accent
  local kind,L=card.art,w.L
  if kind=="attitude" then
    if w.attitudeView then w.attitudeView.valid=false end
    w.attitudeView=w.newAttitudeView(children,w,x,y,width,height)
    return
  end
  local scale = math.min(width / 220, height / 160)
  x, y = x + math.floor((width - 220*scale)/2), y + math.floor((height - 160*scale)/2)
  local function px(v) return math.floor(x + v*scale + 0.5) end
  local function py(v) return math.floor(y + v*scale + 0.5) end
  local function points(p)
    local out = {}
    for i,v in ipairs(p) do
      out[i]={px(v[1]),py(v[2])}
    end
    return out
  end
  local function line(p, color, thick)
    local item = { type = "line", pts = points(p), color = color or ink, thickness = thick or 2 }
    children[#children+1] = item
    return item
  end
  -- A line whose points come from a getter has no native object until its first points pass,
  -- and EdgeTX runs the visible getter first: hiding it then flags a null object and the radio
  -- faults (lua_lvgl_widget.cpp: LvglWidgetObjectBase::callRefs, LvglWidgetLine::isVisible).
  -- Such a line therefore reports itself visible until its points have been read once.
  local function reactiveLine(item, visible)
    local get, drawn = item.pts, false
    item.pts = function() drawn = true; return get() end
    item.visible = function() return not drawn or visible() end
  end
  local function rect(a,b,c,d,color)
    local item = { type = "rectangle", x = px(a), y = py(b),
      w = px(a+c)-px(a), h = py(b+d)-py(b), color = color or ink, thickness = 2 }
    children[#children+1] = item
    return item
  end
  local function text(a,b,c,value)
    local item = { type = "label", x = px(a), y = py(b), w = px(a+c)-px(a),
      text = value, color = ink, font = SMLSIZE }
    children[#children+1] = item
    return item
  end
  local function arrow(a,b,c,d,color)
    local dx, dy = c-a, d-b
    local length = math.sqrt(dx*dx + dy*dy)
    local ux, uy = dx/length, dy/length
    return line({{a,b},{c,d},{c-ux*9-uy*5,d-uy*9+ux*5},{c,d},{c-ux*9+uy*5,d-uy*9-ux*5}},color or accent,3)
  end
  local function image(picture)
    local current, file
    local item = { type = "image", x = px(0), y = py(0), w = px(220)-px(0),
      h = py(160)-py(0), file = function()
        local name = picture()
        if name ~= current then current, file = name, GFX .. "dark/" .. name .. ".png" end
        return file
      end }
    children[#children+1] = item
    return item
  end
  local function meter(a,b,c,get)
    line({{a,b},{a+c,b}},ink,1)
    line({{a+c/2,b-4},{a+c/2,b+4}},ink,1)
    local pts=points({{a+c/2,b-6},{a+c/2,b+6}})
    local item=line({{a+c/2,b-6},{a+c/2,b+6}},accent,3)
    local last
    item.pts=function()
      local value=math.max(-1,math.min(1,get() or 0))
      if value~=last then
        local pos=px(a+c*(value+1)/2)
        pts[1][1],pts[2][1],last=pos,pos,value
      end
      return pts
    end
  end
  if kind == "throttle" then
    text(5,0,210,L.throttle)
    rect(28,35,164,55);line({{45,62},{175,62}})
    line({{45,49},{45,75}});line({{175,49},{175,75}})
    arrow(63,111,157,111)
    meter(10,132,196,function()
      local map=w.data.rx_map.throttle or 4
      local raw=w.data.rx_channels and w.data.rx_channels.channels[map+1]
      return raw and (raw-w.data.rc_config.rc_center)/math.max(1,w.data.rc_config.rc_deflection) or 0
    end)
    text(5,141,210,L.testOutput)
  elseif kind == "sticks" then
    text(5,0,210,L.checkSticks)
    local keys={"aileron","elevator","rudder","collective"}
    for i,key in ipairs(keys) do
      local k=key
      text(5,21+(i-1)*31,72,({L.roll,L.pitch,L.yaw,L.collective})[i])
      meter(80,31+(i-1)*31,125,function()
        local channel=w.data.rx_map[k] or 0
        local value=w.data.rx_channels and w.data.rx_channels.channels[channel+1]
        return value and (value-w.data.rc_config.rc_center)/math.max(1,w.data.rc_config.rc_deflection) or 0
      end)
    end
    line({{5,149},{210,149}},ink,1)
  elseif kind == "stickGuide" then
    -- One large meter for the control the guided check asks for, with both end stops named.
    local names={L.roll,L.pitch,L.yaw,L.collective}
    local keys={"aileron","elevator","rudder","collective"}
    local words={{L.dirLeft,L.dirRight},{L.dirBack,L.dirForward},{L.dirLeft,L.dirRight},{L.dirDown,L.dirUp}}
    local function axis() local rx=w.rx;return rx and rx.target and rx.target() or nil end
    local heading=text(5,10,210,function() local a=axis();return a and names[a] or L.sticksDone end)
    heading.font=MIDSIZE
    line({{10,92},{210,92}},ink,2)
    line({{10,78},{10,106}},ink,2);line({{210,78},{210,106}},ink,2);line({{110,84},{110,100}},ink,1)
    meter(10,92,200,function()
      local a=axis();if not a then return 0 end
      local channel=w.data.rx_map[keys[a]] or a-1
      local value=w.data.rx_channels and w.data.rx_channels.channels[channel+1]
      return value and (value-w.data.rc_config.rc_center)/math.max(1,w.data.rc_config.rc_deflection) or 0
    end)
    text(5,116,95,function() local a=axis();return a and words[a][1] or "" end)
    text(150,116,65,function() local a=axis();return a and words[a][2] or "" end)
  elseif kind == "rates" then
    local function style() return card.rateStyle and card.rateStyle() end
    local sketchStart=#children+1
    text(5,0,210,L.rateCurve)
    line({{22,26},{22,128},{207,128}})
    line({{22,77},{207,77}},ink,1)
    local prepared={}
    for i,style in ipairs({{180,0.4},{250,0.4},{400,0.3}}) do
      local p={}
      for n=0,24 do
        local v=n/24
        p[#p+1]={22+185*v,128-100*style[1]/400*(v*(1-style[2])+v^2.75*style[2])}
      end
      prepared[i]=points(p)
    end
    -- The sketch shows only while no style is known, so its curve is the static Sport example.
    line({{0,0},{0,0}},accent,3).pts=prepared[2]
    text(5,140,210,L.artExample)
    line({{22,128},{22,132}});line({{207,128},{207,132}})
    for i=sketchStart,#children do children[i].visible=function() return style()==nil end end
    local pictures={"rate-trainer-cyclic","rate-sport-cyclic","rate-3d-cyclic"}
    local picture=image(function() return pictures[style() or 1] end)
    picture.visible=function() return style()~=nil end
  elseif kind == "motorGears" then
    image(function() return "motor-gears" end)
  elseif kind == "pulses" then
    text(5,0,210,L.pulseTrain)
    local servoIndex=card.servoIndex or 0
    local pts={}
    for i=1,50 do pts[i]={px(10),py(112)} end
    local caption,windowText,valid="","",false
    local preset
    local sketchStart=#children+1
    -- Called during scene preparation or a settings edit, never by a native getter.
    w.refreshPulse=function()
      local s=w.data.servo_configurations.servos[servoIndex] or {rate=50,mid=1520,max=700}
      preset=s.rate==50 and s.mid==1520 and "pulse-50-1520"
        or s.rate==333 and s.mid==1520 and "pulse-333-1520"
        or s.rate==560 and s.mid==760 and "pulse-560-760" or nil
      for _,index in ipairs(card.servoIndices or {servoIndex}) do
        local member=w.data.servo_configurations.servos[index]
        if member.rate~=s.rate or member.mid~=s.mid then preset=nil end
      end
      local rate=math.max(1,s.rate)
      local period,window=1000/rate,math.min(20,12000/rate)
      caption=tostring(s.rate).." Hz / "..tostring(s.mid).." us"
      valid=s.mid>0 and s.mid+s.max>0 and rate<=math.floor(950000/(s.mid+s.max))
      windowText=valid and string.format("%.1f ms",window) or L.pulseLimited
      local index,time=1,0
      local function put(a,b)
        pts[index][1],pts[index][2]=px(a),py(b);index=index+1
      end
      while time<window and index<48 do
        local a,b=math.min(time,window),math.min(time+s.mid/1000,window)
        put(10+a*200/window,112);put(10+a*200/window,64)
        put(10+b*200/window,64);put(10+b*200/window,112)
        time=time+period
      end
      while index<=50 do put(210,112) end
    end
    w.refreshPulse()
    local wave=line({{10,112},{210,112}},accent,2)
    wave.pts=function() return pts end
    reactiveLine(wave,function() return not preset and valid end)
    text(5,29,210,function() return caption end)
    text(5,140,210,function() return windowText end)
    line({{10,120},{210,120}});line({{10,117},{10,124}});line({{210,117},{210,124}})
    for i=sketchStart,#children do
      if children[i]~=wave then children[i].visible=function() return not preset end end
    end
    local picture=image(function() return preset or "pulse-50-1520" end)
    picture.visible=function() return preset~=nil end
  elseif kind == "switch" then
    text(5,0,210,L.move)
    -- The switch is always drawn; an unknown position shows it at rest (left) beside the
    -- unavailable cue, so the card never loses its picture.
    image(function()
      local value=card.switchState and card.switchState()
      return value==true and "switch-right" or "switch-left"
    end)
    text(5,141,210,function()
      if not card.switchState then return L.artExample end
      return card.switchState()==nil and L.unavailable or ""
    end)
  elseif kind == "tail22" then
    text(5,0,210,L.artTop)
    line({{199,72},{48,70},{48,87},{199,90},{199,72}},ink,3)
    rect(34,62,27,32,accent);line({{48,94},{48,127}},ink,3)
    line({{16,128},{81,128}},accent,4)
    rect(38,105,20,9,accent);line({{58,110},{74,110},{74,98},{194,98}})
    rect(178,104,26,19);arrow(16,113,16,88)
    text(5,141,210,"22°")
  elseif kind == "swashType" or kind == "rotorDir" or kind == "tailKind" or kind == "tailMotor" then
    -- The Configurator's own drawings of the swash step, one picture per value: the servo
    -- layout seen from above (nose up, servo 1 in front or behind, servo 4 when the tail
    -- has a servo), the main rotor turning, and the kind of tail.
    local SWASH = { "direct", "120", "135", "140", "90l", "90v" }
    local TAIL = { [0]="tail-servo", "tail-motor", "tail-bidirectional" }
    local function picture()
      local m = w.data.mixer_config
      if kind == "rotorDir" then return m.main_rotor_dir == 1 and "rotor-ccw" or "rotor-cw" end
      if kind == "tailMotor" then return m.tail_rotor_mode == 2 and "tail-bidirectional" or "tail-motor" end
      if kind == "tailKind" then return TAIL[m.tail_rotor_mode] or TAIL[0] end
      -- swash_type 1..6 is Direct..90V (0, none, draws as Direct).
      local s = math.max(1, math.min(6, m.swash_type or 1))
      local name = "swash-" .. SWASH[s]
      if s >= 2 and s <= 4 then name = name .. (w.swashRear and "-rear" or "-front") end
      if m.tail_rotor_mode == 0 then name = name .. "-tail" end
      return name
    end
    image(picture)
    text(5,0,210,(kind=="tailKind" or kind=="tailMotor") and L.artSide or L.artTop)
  elseif kind == "swashRoll" or kind == "swashPitch" or kind == "swashLift"
    or kind == "gyroRoll" or kind == "gyroPitch" or kind == "gyroYaw"
    or kind == "tail" or kind == "tailMove" or kind == "pitch" or kind == "level"
    or kind == "levelCheck" or kind == "servo" then
    local pictures = { swashRoll="swash-motion-roll", swashPitch="swash-motion-pitch",
      swashLift="swash-motion-collective", gyroRoll="gyro-roll", gyroPitch="gyro-pitch",
      gyroYaw="gyro-yaw", tail="tail-servo", tailMove="tail-servo-move", pitch="pitch-9",
      level="swash-motion-level", levelCheck="pitch-0", servo="servo" }
    image(function() return pictures[kind] end)
    text(5,0,210,(kind=="swashRoll" or kind=="swashLift" or kind=="gyroRoll" or kind=="level") and L.artRear
      or kind=="gyroYaw" and L.artTop or kind=="servo" and L.servo or L.artSide)
  else
    -- The side view, nose left, in the Configurator's three poses: blades crossed out where
    -- they must come off, level for the accelerometer, tail lifted 20 degrees for the board
    -- orientation. The picture fills the frame.
    local picture = kind=="heliLift" and "heli-tail-lift"
      or kind=="heliLevel" and "heli-level" or "heli-remove-blades"
    children[#children+1] = { type = "image", x = px(0), y = py(0), w = px(220)-px(0),
      h = py(160)-py(0), file = GFX .. picture .. ".png" }
    text(5,0,210,L.artSide)
    arrow(70,145,24,145); text(89,137,125,kind=="heliLift" and "20°" or L.artFront)
  end
  if card.meter then meter(10,132,196,card.meter) end
end
return M
