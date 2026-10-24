-- Native number editors retain their own value until update() on close.
return function(h)
  local check,eq,L=h.check,h.eq,h.L
  local function drain(w)
    for _=1,2000 do
      w:tick();h.pump();h.advance(1)
      w.canEdit=w:usable()
      if w.error or (w.bus:idle() and (w.cleanupPending or 0)==0 and not w.buildRequested) then return end
    end
    check(false,"S07 Hz transport completes")
  end
  local function scene(w,index)
    w.card=index
    local job=h.view.new(w,{w=480,h=272},h.diagrams)
    while not job:step() do end
    local controls={}
    for _,item in ipairs(job.children) do
      if item.type=="numberEdit" then controls.hz=item
      elseif item.type=="choice" then controls.template=item
      end
    end
    check(controls.hz~=nil and controls.template~=nil,"S07 Hz native controls exist")
    return controls
  end
  local function editor(control)
    local e={currentValue=control.get(),calls=0}
    function e:step(value)
      value=math.max(control.min,math.min(control.max,value))
      if value~=self.currentValue then
        self.currentValue=value;self.calls=self.calls+1;control.set(value)
      end
    end
    function e:close() self.currentValue=control.get();return self.currentValue end
    return e
  end
  local function start()
    local w=h.world();w.buildRequested=nil;drain(w);w.statusAt=getTime()
    w:startStep(7,true);drain(w)
    eq(w.step,7,"S07 Hz enters the actual servo step")
    return w
  end
  for kind,rate in ipairs({50,333,560}) do
    for group=1,2 do
      local w=start()
      w.cards[1].rows[1].set(2)
      local c=scene(w,group)
      local cards=w.cards
      c.template.set(kind)
      eq(c.hz.get(),rate,"S07 Hz template sets its initial rate")
      eq(w.cards,cards,"S07 Hz template retains the card list")
      -- No wakeup is required between native rotary steps or before update().
      local e=editor(c.hz)
      e:step(rate+1);e:step(rate+2);e:step(rate+1);e:step(rate+1)
      eq(e.calls,3,"S07 Hz unchanged native values do not call Lua set")
      eq(e:close(),rate+1,"S07 Hz fresh edit survives close after template "..kind)
      drain(w)
      c.template.set(kind);drain(w)
      w.statusAt=getTime()-301
      local before=w.data.servo_configurations.servos[group==1 and 0 or 3].rate
      e=editor(c.hz);e:step(rate+2);e:step(rate+3);e:step(rate+2)
      eq(w.data.servo_configurations.servos[group==1 and 0 or 3].rate,before,
        "S07 Hz expired STATUS cannot change servo settings")
      eq(e:close(),rate+2,"S07 Hz stale edit survives close after template "..kind)
      drain(w)
      eq(c.hz.get(),rate+2,"S07 Hz latest queued edit applies after STATUS")
      eq(c.template.get(),4,"S07 Hz edited template shows Custom")
      -- Every integer in the firmware range can be selected after any template.
      local sticks=true
      for value=25,5000 do
        w.statusAt=getTime()
        e=editor(c.hz);e:step(value)
        if e:close()~=value then sticks=false end
      end
      check(sticks,"S07 Hz all 25..5000 values survive close after template "..kind.." group "..group)
      w.statusAt=getTime()-301;sticks=true
      for value=25,5000 do
        e=editor(c.hz);e:step(value)
        if e:close()~=value then sticks=false end
      end
      check(sticks,"S07 Hz all 25..5000 drafts survive close with expired STATUS")
      drain(w)
      eq(c.hz.get(),5000,"S07 Hz later pending edits are not dropped")
      e=editor(c.hz);e:step(251);eq(e:close(),251,"S07 Hz final custom value sticks")
      -- Complete all cards with Next so the normal step save is exercised.
      w.card=#w.cards;w.statusAt=getTime();h.q.sent={};w:next();drain(w)
      eq(w.saved.servo_configurations.servos[group==1 and 0 or 3].rate,251,"S07 Hz step saves custom rate")
      local writes,eeprom=0,false
      for _,m in ipairs(h.q.sent) do
        if m.command==212 and (m.payload[1]==3)==(group==2) then
          eq(m.payload[12]+256*m.payload[13],251,"S07 Hz saved MSP record carries custom rate")
          writes=writes+1
        elseif m.command==250 then eeprom=true end
      end
      check(writes>0 and eeprom,"S07 Hz indexed settings precede step EEPROM save")
    end
    local w=start();w.cards[1].rows[1].set(2)
    local c=scene(w,1);c.template.set(kind)
    -- Preserve the acknowledged configuration in the FC fixture across its reboot.
    local original=h.fixtures[120]
    local stored={w.data.servo_configurations.servo_count}
    for i=0,stored[1]-1 do
      local record=h.api("servo_configurations").buildWritePayload({index=i,servo=w.data.servo_configurations.servos[i]})
      for j=2,#record do stored[#stored+1]=record[j] end
    end
    h.fixtures[120]=stored
    w:reboot();drain(w)
    for _=1,2000 do
      w:tick();h.pump();h.advance(1)
      w.canEdit=w:usable()
      if w.ready and not w.transition and not w.rebootPhase and not w.buildRequested and w.cards then break end
    end
    check(w.ready and not w.error and not w.checks.unplugged,"S07 Hz restart clears physical confirmation")
    c=scene(w,1)
    check(not c.hz.active() and not c.template.active(),"S07 Hz controls visibly require unplugged confirmation after restart")
    eq(type(w.cards[1].summary)=="function" and w.cards[1].summary() or w.cards[1].summary,L.servoUnpluggedRequired,"S07 Hz locked controls explain the confirmation requirement")
    local e=editor(c.hz);e:step(rate+1);e:close()
    eq(w.data.servo_configurations.servos[0].rate,rate,"S07 Hz unconfirmed restarted edit is refused")
    w.cards[1].rows[1].set(2)
    check(c.hz.active() and c.template.active(),"S07 Hz confirmation unlocks the existing scene")
    e=editor(c.hz);e:step(rate+1)
    eq(e:close(),rate+1,"S07 Hz confirmed edit sticks after restart")
    -- A replaced scene must not accept or display its abandoned edit.
    w.statusAt=getTime()-301;e=editor(c.hz);e:step(rate+2)
    w:navigate(7,2);drain(w)
    eq(w.data.servo_configurations.servos[0].rate,rate+1,"S07 Hz old scene cannot apply a queued edit")
    eq(c.hz.get(),rate+1,"S07 Hz old scene cannot retain an abandoned draft")
    c=scene(w,1);w.statusAt=getTime()-301;e=editor(c.hz);e:step(rate+2)
    w:fail("status",L.stale)
    eq(c.hz.get(),rate+1,"S07 Hz failed STATUS discards the displayed draft")
    eq(w.data.servo_configurations.servos[0].rate,rate+1,"S07 Hz failed STATUS cannot change servo settings")
    h.fixtures[120]=original
  end
  print("Servo Hz: native numberEdit templates, stale STATUS, full range, step save and restart checked")
end
