-- Behavioral contracts traced to Configurator PR 491. Runs only with offline
-- fixtures; no radio, EdgeTX executable, model API or virtual FC is started.
return function(h)
  local world,load,H,L,q=h.world,h.load,h.H,h.L,h.q
  local eq,check=h.eq,h.check
  local cases={}
  local function case(id,fn)
    cases[#cases+1]=id
    fn()
  end
  local function step(w,name)
    w.commit,w.validate,w.onLive=nil,nil,nil
    local cards=load("app/pages/helicopter_setup/steps/"..name..".lua")(w)
    w.cards=cards
    return cards
  end
  local function drain(w)
    for _=1,1500 do
      h.measure("contract wakeup",function() w:tick() end);h.pump();h.advance(1)
      if w.error or (w.bus:idle() and (w.cleanupPending or 0)==0) then return end
    end
    check(false,"contract transport completes")
  end
  local function settle(w) w.buildRequested=nil;drain(w);w.statusAt=getTime() end
  case("CORE.api-12-10-gate",function()
    local manifest=load("app/manifest.lua")
    eq(#manifest.menus.wizards_menu.pages,1,"CORE Wizards lists only Helicopter Setup")
    eq(manifest.menus.wizards_menu.pages[1].id,"helicopter_setup","CORE Helicopter Setup is the wizard menu entry")
    check(manifest.menus.setup_wizard_menu~=nil,"CORE legacy assistant definitions are retained")
    local entries={}
    for _,entry in ipairs(manifest.menus.wizards_menu.pages) do
      if entry.id=="helicopter_setup" then entries[#entries+1]=entry end
    end
    for _,entry in ipairs(manifest.menus.helicopter_setup_menu.pages) do entries[#entries+1]=entry end
    eq(#entries,22,"CORE all wizard entry points are covered by the API contract")
    for _,entry in ipairs(entries) do
      eq(type(entry.minApiVersion)=="table" and table.concat(entry.minApiVersion,".") or "","12.0.9",
        "CORE "..entry.id.." stays reachable on the Suite's packaged API")
    end
    local session=_G.rfsuite.session
    local old=session.apiVersion
    session.apiVersion="12.09"
    local w=world();settle(w)
    check(w.apiTooOld and w.cards and w.cards[1].title==L.apiTooOldTitle,"CORE an FC below API 12.10 gets the reason instead of the steps")
    eq(w.cards[1].rows[1].get(),"12.09","CORE the reason names the FC's API version")
    for _,m in ipairs(q.sent) do check(m.command~=120 and m.command~=42,"CORE an FC below API 12.10 gets no configuration reads") end
    check(not w.validate(),"CORE the API card never completes")
    session.helicopterSetupRecovery=session.mcu_id;w=world();settle(w)
    check(w.recoveryCard,"CORE a pending recovery is shown before the API card")
    w.checks.recoveryPowerCycle=true;w:next();drain(w)
    check(session.helicopterSetupRecovery==nil and w.cards and w.cards[1].title==L.apiTooOldTitle,
      "CORE after the recovery acknowledgement the API card follows")
    session.apiVersion="12.10";w=world();settle(w)
    check(not w.apiTooOld,"CORE API 12.10 opens the steps")
    session.apiVersion="13.0";check(w:apiSupported(),"CORE a later major version is accepted")
    session.apiVersion=old
  end)
  case("PORTS.board-printed-labels",function()
    local w=world();settle(w)
    eq(w.data.board_info and w.data.board_info.board_design,"F7C1","PORTS startup caches board design from MSP")
    local reads=0
    for _,m in ipairs(q.sent) do if m.command==4 then reads=reads+1 end end
    eq(reads,1,"PORTS board design is read once at startup")
    w.data.serial_config={}
    for i,id in ipairs({0,3,30,31,40}) do
      w.data.serial_config["port_"..i.."_identifier"]=id
      w.data.serial_config["port_"..i.."_function_mask"]=0
    end
    local function choices()
      return {step(w,"escTelemetry")[2].rows[1],w:port(L.port,64)}
    end
    for _,row in ipairs(choices()) do
      eq(row.values[1],"S.BUS [UART1]","PORTS known board names UART1")
      eq(row.values[2],"Port A [UART4]","PORTS ESC and receiver choices use printed UART4 name")
      eq(row.values[3],"SOFTSERIAL1","PORTS softserial1 keeps its identifier name")
      eq(row.values[4],"SOFTSERIAL2","PORTS softserial2 keeps its identifier name")
      eq(row.values[5],"LPUART1","PORTS low-power UART uses identifier 40")
    end
    for _,design in ipairs({"UNKNOWN",""}) do
      w.data.board_info={board_design=design}
      for _,row in ipairs(choices()) do
        eq(row.values[2],"UART4","PORTS unknown board keeps plain UART4 in both choices")
      end
    end
    w.data.board_info=nil
    eq(w:port(L.port,64).values[2],"UART4","PORTS missing board design keeps plain UART4")
    h.setFailCommand(4);w=h.beginWorld();drain(w);h.setFailCommand(nil)
    check(w.ready and not w.error,"PORTS unavailable board info does not block startup")
  end)
  case("CORE.paged-startup",function()
    local w=world();settle(w)
    if h.mutation=="bulk-read" then
      w.readRecords=function(self,name)
        self:read(name,function(d) self.data[name]=d;self:loadProgress() end)
      end
      w:load();drain(w)
    end
    check(w.ready and not w.error,"CORE paged startup reaches ready on telemetry")
    local slots,servos={},{}
    for _,m in ipairs(q.sent) do
      check(m.command~=52 and m.command~=120,"CORE no oversized startup command")
      if m.command==156 or m.command==125 then
        eq(#m.payload,1,"CORE indexed read carries one index")
        check(not m.isWrite,"CORE indexed read is a read")
        local list=m.command==156 and slots or servos;list[#list+1]=m.payload[1]
      end
    end
    eq(#slots,42,"CORE every adjustment slot read")
    for i=1,42 do eq(slots[i],i-1,"CORE adjustment indexes keep order") end
    eq(table.concat(servos,","),"0,1,2,3","CORE PWM servo indexes read")
    eq(#w.data.adjustment_ranges.adjustment_ranges,42,"CORE complete adjustment table published")
    eq(w.progress,w.loadTotal,"CORE loading progress reaches total")
    check(string.find(w.loadingText,tostring(w.loadTotal),1,true)~=nil,"CORE loading text reports progress")
    h.setServoCount(22)
    local full={22};local template=h.api("servo_configurations").simulatorResponse
    for slot=0,21 do
      local raw=slot<4 and slot or slot-4+8
      for i=2,17 do full[#full+1]=template[i] end
      full[2+slot*16],full[3+slot*16]=(1300+raw)%256,math.floor((1300+raw)/256)
    end
    h.fixtures[120]=full
    w=world();settle(w)
    local raw={}
    for _,m in ipairs(q.sent) do if m.command==125 then raw[#raw+1]=m.payload[1] end end
    eq(#raw,22,"CORE packed bus table reads all records")
    eq(raw[5],8,"CORE bus table skips unused PWM indexes")
    eq(raw[22],25,"CORE bus table reaches last raw servo")
    eq(w.data.servo_configurations.servo_count,22,"CORE packed servo count preserved")
    eq(w.data.servo_configurations.servos[4].mid,1308,"CORE raw bus record stored at packed index")
    for i=0,3 do w.data.servo_configurations.servos[i].mid=w.data.servo_configurations.servos[i].mid+1 end
    q.sent={};w:touch("servo_configurations");w:save();drain(w)
    local written={}
    for _,m in ipairs(q.sent) do if m.command==212 then written[#written+1]=m.payload[1] end end
    eq(table.concat(written,","),"0,1,2,3","CORE PWM changes never rewrite packed bus servo slots")
    h.fixtures[120]=nil;h.setServoCount(4)
    for _,fault in ipairs({{command=156,index=16},{command=156,index=16,short=true},{command=125,index=2,short=true}}) do
      h.setRecordFault(fault);w=h.beginWorld();drain(w)
      check(not w.ready and w.error~=nil,"CORE missing indexed record blocks ready")
      check(w.data[fault.command==156 and "adjustment_ranges" or "servo_configurations"]==nil,
        "CORE incomplete indexed table never published")
      check(not w:usable(),"CORE indexed failure leaves controls disabled")
      h.setRecordFault(nil)
    end
  end)
  case("CORE.individual-step-entry",function()
    for selected=1,19 do
      local w=world();settle(w);w:showSteps()
      local scene=h.view.new(w,{w=480,h=272},h.diagrams)
      while not scene:step() do end
      local start
      for _,item in ipairs(scene.children) do
        if item.type=="choice" then item.set(selected) end
        if item.type=="button" and item.text==L.startStep then start=item end
      end
      check(start~=nil,"CORE individual start control exists")
      start.press();drain(w);w:tick()
      eq(w.step,selected,"CORE selected individual step starts directly")
      check(w.singleStep and not w.overview,"CORE individual mode is explicit")
      if w:standalonePreparation() then
        eq(w.cards[1].title,L.prepareStep,"CORE individual prerequisites are visible")
        local card=w.card;w:next();eq(w.card,card,"CORE individual prerequisite must be acknowledged")
        check(next(w.holds)==nil,"CORE preparation does not enter an automatic servo hold")
      end
      w.checks=setmetatable({},{__index=function() return true end})
      w.data.mode_ranges.mode_ranges[1]={id=0,auxChannelIndex=0,range={start=1800,["end"]=2100}}
      for _=1,1500 do
        w:tick();h.pump();h.advance(1)
        if w.cards and not w.transition and not w.error then
          if w.step==13 then for _,s in pairs(w.data.servo_configurations.servos) do s.mid=s.mid>860 and 1520 or 760 end end
          w:next()
        end
        if w.overview or w.error then break end
      end
      check(w.overview and not w.error,"CORE completed individual step returns to overview")
      check(w.active and w.locked,"CORE individual completion retains arming lock")
    end
  end)
  case("CORE.step-switch-save-discard",function()
    local w=world();settle(w)
    local original=w.data.board_alignment_config.yaw_degrees
    w:field("board_alignment_config","yaw_degrees",45,true)
    w:hold("servo",0,400);w:requestSteps()
    check(next(w.holds)==nil,"CORE step switch releases held output")
    check(w.confirmExit and w.exitToSteps and not w.overview,"CORE dirty step switch asks save/discard")
    w:back();check(not w.confirmExit and not w.overview,"CORE cancel retains current step")
    w:requestSteps();w:resolveExit(false);drain(w)
    check(w.overview and not next(w.dirty),"CORE discarded step switch returns clean")
    eq(w.data.board_alignment_config.yaw_degrees,original,"CORE discard restores displayed baseline")
    check(not w.rebootPending,"CORE discard clears unsaved reboot requirement")
    w:startStep(1,true);w:tick()
    w:field("board_alignment_config","yaw_degrees",90,true)
    w:requestSteps();w:resolveExit(true);drain(w)
    check(w.overview and not next(w.dirty),"CORE saved step switch returns clean")
    eq(w.data.board_alignment_config.yaw_degrees,90,"CORE saved step switch retains new value")
    check(w.rebootPending,"CORE saved reboot requirement remains visible")
    w:startStep(13);check(w.overview,"CORE bench step blocked until pending restart")
    w:startStep(2);w:tick()
    w:field("rc_config","rc_min_throttle",950)
    w:requestSteps();w:resolveExit(false);drain(w)
    check(w.rebootPending,"CORE discard preserves earlier saved reboot requirement")
    w.rebootPending=nil;w:startStep(5);w:tick();w:back()
    check(w.overview,"CORE Back from individual step returns to overview")
    w:back();check(w.confirmExit and not w.exitToSteps,"CORE Back from overview offers exit")
    w=world();settle(w)
    local status=h.api("status").parse(h.fixtures[101]);status.reboot_required=1
    w:acceptStatus(status);w:requestSteps();w:startStep(13)
    check(w.overview and w.rebootPending,"CORE existing MSP restart flag blocks direct bench entry")
  end)
  case("CORE.status-during-save",function()
    local w=world();settle(w)
    w:touch("adjustment_ranges");w:save()
    local statusReads=0
    for _=1,1500 do
      w:tick();h.pump();h.advance(15)
      if w.error or not w.transition then break end
    end
    for _,m in ipairs(q.sent) do if m.command==101 then statusReads=statusReads+1 end end
    check(not w.error and not w.transition,"CORE long indexed save keeps status fresh")
    check(statusReads>5,"CORE STATUS preempts a long save")
  end)
  case("VISUAL.retained-scene-transitions",function()
    -- EdgeTX sweeps the published tree after refresh(), even when a replacement
    -- is still being prepared. Keep that exact old tree through the transition.
    local function sweep(scene,phase)
      local ok,err=pcall(h.resolve,scene.children)
      check(ok,"VISUAL retained scene survives "..phase..(ok and "" or ": "..tostring(err)))
    end
    for _,size in ipairs({{320,240},{480,272},{480,320},{800,480}}) do
      for index,name in ipairs(h.stepNames) do
        local w=world();settle(w);w.step=index;step(w,name)
        local scenes={}
        for card=1,#w.cards do
          w.card=card
          local scene=h.view.new(w,{w=size[1],h=size[2]},h.diagrams)
          while not scene:step() do end
          scenes[#scenes+1]=scene;sweep(scene,name.." initial")
        end
        w:navigate(index%19+1)
        for _,scene in ipairs(scenes) do
          sweep(scene,name.." navigation")
          for _,item in ipairs(scene.children) do
            if item.type=="numberEdit" or item.type=="choice" or type(item.text)=="function" and item.press then
              check(not item.active(),"VISUAL replaced card cannot accept stale input")
            end
          end
        end
        w.buildRequested=nil;drain(w)
        for _,scene in ipairs(scenes) do sweep(scene,name.." cleanup") end
        w.ready=false
        for _,scene in ipairs(scenes) do sweep(scene,name.." reload") end
        w.active=false
        for _,scene in ipairs(scenes) do sweep(scene,name.." teardown") end
      end
      local w=world();settle(w);w.step=5;step(w,"rates");w.card=1
      local scene=h.view.new(w,{w=size[1],h=size[2]},h.diagrams)
      while not scene:step() do end
      sweep(scene,"rates before discard")
      w:discard(function() w:navigate(6) end)
      for _=1,1500 do
        w:tick();h.pump();h.advance(1)
        sweep(scene,"rates discard")
        if w.error or (w.bus:idle() and not w.transition) then break end
      end
      check(not w.error,"VISUAL retained rates discard completes")
    end
  end)
  case("CORE.completed-transport-retention",function()
    local w=world();settle(w)
    local sent=#q.sent
    for _=1,101 do h.advance(25);w:poll();drain(w) end
    check(#q.sent>sent+100,"CORE retention control completed real polling jobs")
    check(w.bus:idle() and not w.error,"CORE retention polling remains ready")
    check(#w.bus.jobs<=8,"CORE completed transport jobs stay bounded: "..#w.bus.jobs)
    print("TRANSPORT retained jobs: "..#w.bus.jobs.." after "..(#q.sent-sent).." completed polling messages")
  end)
  case("S01.manual-alignment-fallback",function()
    local w=world();settle(w);w.step=1;step(w,"sensors");w.card=3
    local before=w.data.board_alignment_config.yaw_degrees
    h.setFailCommand(0x5F13);w:startTrial("board_auto_align");drain(w);h.setFailCommand(nil)
    check(not w.error and not w.trial,"S01 unsupported auto alignment preserves manual setup")
    eq(w.message,L.manualAlign,"S01 unsupported detection explains the manual alternative")
    eq(w.data.board_alignment_config.yaw_degrees,before,"S01 refused detection preserves current angles")
    w.cards[3].rows[4].set(45)
    eq(w.data.board_alignment_config.yaw_degrees,45,"S01 manual angle remains editable after refusal")
    check(w.dirty.board_alignment_config and w.rebootPending,"S01 manual fallback retains save/reboot semantics")
  end)
  case("VISUAL.rotor-direction-arrow",function()
    -- The rotor card shows the Configurator's rotor picture whose arrow turns the chosen way.
    local w=world();settle(w);local c=step(w,"swash");w.card=2
    local scene=h.view.new(w,{w=800,h=480},h.diagrams);while not scene:step() do end
    local picture
    for _,item in ipairs(scene.children) do
      if item.type=="image" and type(item.file)=="function" then picture=item end
    end
    check(picture~=nil,"VISUAL swash shows a rotor direction picture")
    if picture then
      w.data.mixer_config.main_rotor_dir=0
      check(string.find(picture.file(),"/rotor%-cw%.png$")~=nil,"VISUAL clockwise shows the clockwise rotor")
      w.data.mixer_config.main_rotor_dir=1
      check(string.find(picture.file(),"/rotor%-ccw%.png$")~=nil,"VISUAL counter-clockwise shows the counter-clockwise rotor")
    end
  end)
  case("VISUAL.live-orientation-model",function()
    for _,size in ipairs({{320,240},{480,272},{480,320},{800,480}}) do
      local w=world();settle(w);step(w,"sensors");w.card=4
      local scene=h.view.new(w,{w=size[1],h=size[2]},h.diagrams)
      while not scene:step() do end
      check(w.attitudeView~=nil,"VISUAL orientation check has a live model")
      if w.attitudeView then
        local function pose(roll,pitch)
          w.data.attitude={roll=roll,pitch=pitch,yaw=0};w.attitudeAt=getTime()
          h.measure("attitude update",function() w:tick() end)
          return h.resolve(scene.children)
        end
        local neutral=pose(0,0)
        local model=w.attitudeView
        check(model.valid,"VISUAL fresh attitude enables the model")
        local nose=model.projected[1][2];local right=model.projected[17][2]
        pose(0,25);check(model.projected[1][2]>nose,"VISUAL positive pitch lowers the nose")
        pose(0,-25);check(model.projected[1][2]<nose,"VISUAL negative pitch raises the nose")
        pose(25,0);check(model.projected[17][2]>right,"VISUAL positive roll lowers the right side")
        pose(-25,0);check(model.projected[17][2]<right,"VISUAL negative roll raises the right side")
        local slots={}
        for i,item in ipairs(scene.children) do if item.type=="line" and type(item.pts)=="function" then slots[i]=item.pts() end end
        for _,angles in ipairs({{180,0},{-180,0},{0,90},{0,-90},{90,90},{-90,-90},{45,-45}}) do
          pose(angles[1],angles[2])
          for i,points in pairs(slots) do
            eq(scene.children[i].pts(),points,"VISUAL attitude retains point table identity")
            for _,p in ipairs(points) do check(p[1]>=0 and p[2]>=0 and p[1]<size[1] and p[2]<size[2] and p[1]%1==0 and p[2]%1==0,
              "VISUAL full attitude range keeps valid native points") end
          end
        end
        check(not w.checks.orientation,"VISUAL motion never confirms physical orientation")
        local rebuilds=w.rebuilds;pose(12,17);eq(w.rebuilds,rebuilds,"VISUAL attitude never rebuilds the scene")
        local sin,cos=math.sin,math.cos
        math.sin=function() error("projection in native getter") end;math.cos=math.sin
        local ok=pcall(h.resolve,scene.children);math.sin,math.cos=sin,cos
        check(ok,"VISUAL native getters only read projected caches")
        h.advance(201);w:tick();check(not model.valid,"VISUAL stale attitude hides the model")
        pose(0,0);check(model.valid,"VISUAL fresh attitude restores the same model")
        w.data.attitude.pitch=0/0;w:tick();check(not model.valid,"VISUAL invalid attitude hides the model")
        pose(0,0);w.attitudeAt=getTime()+1;w:tick();check(not model.valid,"VISUAL future timestamp cannot prove a live sample")
        pose(0,0);w:navigate(2);h.resolve(scene.children)
        check(not model.valid,"VISUAL leaving invalidates the retained model")
      end
    end
  end)
  case("VISUAL.mode-switch-feedback",function()
    local w=world();settle(w);w.data.boxids.box_ids={0,53,47};w.step=3;step(w,"modes");w.card=1
    w.data.mode_ranges.mode_ranges[1]={id=0,auxChannelIndex=0,range={start=1800,["end"]=2100}}
    w.data.rc={channels={1500,1500,1500,1500,1500,1000}};w.animationFrame=0
    local scene=h.view.new(w,{w=480,h=272},h.diagrams)
    while not scene:step() do end
    local picture
    for _,item in ipairs(scene.children) do if item.type=="image" then picture=item end end
    check(picture~=nil,"VISUAL switch feedback has a reactive picture")
    if not picture then return end
    local prefix="/SCRIPTS/TOOLS/rfsuite-core/app/pages/helicopter_setup/gfx/dark/"
    local count=#scene.children
    eq(picture.file(),prefix.."switch-left.png","VISUAL OFF shows the left switch")
    w.data.rc.channels[6]=1900
    eq(picture.file(),prefix.."switch-right.png","VISUAL ON shows the right switch")
    eq(#scene.children,count,"VISUAL switch changes retain the scene")
    local card=w.cards[1]
    check(card.switchState()==true,"VISUAL ARM input can be active while arming stays locked")
    w.data.rc=nil;eq(card.switchState(),nil,"VISUAL absent RC input stays unknown")
    check(picture.visible==nil or picture.visible(),"VISUAL unknown switch keeps its picture")
    eq(picture.file(),prefix.."switch-left.png","VISUAL unknown switch shows the switch at rest")
    local unavailable=false
    for _,item in ipairs(scene.children) do
      if item.type=="label" and type(item.text)=="function" and item.text()==L.unavailable then unavailable=true end
    end
    check(unavailable,"VISUAL unknown input retains the unavailable cue")
    step(w,"modes");w.card=2
    local rescue=w.cards[2]
    w.data.mode_ranges.mode_ranges[2]={id=53,auxChannelIndex=1,range={start=1800,["end"]=2100}}
    w.data.status.flight_mode_flags=0;eq(rescue.switchState(),false,"VISUAL Rescue reads the FC mode flag")
    eq(rescue.rows[4].color(),"text","VISUAL an OFF switch reads in the text colour")
    w.data.status.flight_mode_flags=2;eq(rescue.switchState(),true,"VISUAL Rescue follows an active FC flag")
    eq(rescue.rows[4].color(),"accent","VISUAL an ON switch is accented")
    w.data.mode_ranges.mode_ranges[2].range["end"]=1800
    eq(rescue.switchState(),nil,"VISUAL unassigned mode stays neutral")
  end)
  case("VISUAL.native-background",function()
    local w=world();settle(w)
    local scene=h.view.new(w,{w=480,h=272},h.diagrams)
    eq(scene.all[1].color,lcd.RGB(20,25,30),"VISUAL page uses the dark palette background")
    check(scene.all[1].filled==true,"VISUAL page background is filled")
    for _,item in ipairs(scene.all) do
      if item.type=="button" or item.type=="momentaryButton" then
        local primary=item.y==234 and item.x>240
        eq(item.color,primary and w.palette.accent or w.palette.card,"VISUAL button background follows its role")
        eq(item.textColor,primary and w.palette.accentText or item.y==2 and item.text~="?" and w.palette.accent or w.palette.text,
          "VISUAL button text contrasts with its background")
      end
    end
  end)
  case("CORE.packed-feedback",function()
    local w=world();settle(w)
    local values, reads = {}, 0
    load("app/pages/helicopter_setup/feedback.lua").attach(w,load("lib/system_state.lua"),{
      getLiveValue=function(source) reads=reads+1;return values[source] end
    })
    local function poll() h.advance(25);w:pollSystemState() end
    w.message=L.ready
    poll();poll();eq(w:feedbackText(),L.ready,"CORE missing packed words preserve MSP feedback")
    values.system_config=(1<<12)|(1<<14)|1|(2<<3)|(3<<6)
    poll();poll();eq(w:feedbackText(),L.fcReboot,"CORE FC restart observation is shown")
    check(not w.rebootPending,"CORE packed feedback cannot create a local restart transaction")
    values.system_config=1<<13;poll();poll()
    eq(w:feedbackText(),L.fcSaving,"CORE FC saving observation is shown")
    w.message=L.failed;eq(w:feedbackText(),L.failed,"CORE operation failure wins over packed hint")
    w.message=L.ready;w.legacyHold=true
    eq(w:feedbackText(),L.persistent,"CORE permanent override warning wins over packed hint")
    w.message=L.confirmCheck
    eq(w:feedbackText(),L.confirmCheck,"CORE a refused check is not hidden by the override warning")
    w:check("anyCheck",L.directionCorrect).set(2)
    check(w.message~=L.confirmCheck,"CORE answering a check clears the reminder that asked for it")
    w.message=L.confirmCheck
    w.message=L.ready
    w.legacyHold=nil;w.transition=true
    eq(w:feedbackText(),L.ready,"CORE packed hint does not obscure active transaction")
    w.transition=nil;values.system_config=1<<12;poll();poll()
    eq(w:feedbackText(),L.fcUnsaved,"CORE FC dirty observation is shown")
    values.system_config=nil;values.system_status=1<<20;poll();poll()
    eq(w:feedbackText(),L.fcOverride,"CORE FC override observation is shown")
    values.system_status=1<<19;w.step=1;poll();poll()
    eq(w:feedbackText(),L.fcAcc,"CORE calibration observation is contextual")
    values.system_status=0;w.step=2;poll();poll()
    eq(w:feedbackText(),L.fcReceiver,"CORE receiver observation is contextual")
    values.system_status=8;w.overview=true
    values.system_config=1|(2<<3)|(3<<6);poll();poll()
    eq(w:feedbackText(),string.format(L.fcProfiles,1,2,3),"CORE FC profiles are readable")
    local count=reads;w:pollSystemState();eq(reads,count,"CORE telemetry feedback polling is paced")
    values.system_status,values.system_config=nil,nil;poll();poll()
    eq(w:feedbackText(),L.ready,"CORE stale words clear optional hint")
    w:acceptStatus(h.api("status").parse(h.fixtures[101]))
    check(w:usable(),"CORE absent telemetry does not block fresh MSP lock")
    w.locked=false;values.system_status=0;values.system_config=0;poll();poll()
    check(not w:usable(),"CORE packed words never prove MSP arming lock")
    w.error="MSP failure";poll()
    check(not w.systemStatus and not w.systemConfig and not w.systemHint,"CORE error clears packed cache")
  end)
  case("SOURCE.pure-helper-golden-vectors",function()
    local vectors=assert(loadfile("bin/wizard/source_vectors.lua"))().cases
    local function same(actual,expected,prefix)
      if type(expected)~="table" then eq(actual,expected,prefix);return end
      check(type(actual)=="table",prefix.." table")
      if type(actual)~="table" then return end
      for key,value in pairs(expected) do same(actual[key],value,prefix.."/"..key) end
    end
    for i,v in ipairs(vectors) do
      local result
      if v.fn=="style" then
        result=v.args[1];H.style(result,v.args[2],v.args[3])
      elseif v.fn=="switchRange" then
        local a,b=H.switchRange(table.unpack(v.args));result={a,b}
      elseif v.fn=="moved" then
        result=H.moved(v.args[1],nil,v.args[3])
      else result=H[v.fn](table.unpack(v.args)) end
      same(result,v.expected,"SOURCE vector "..i.." "..v.fn)
    end
  end)
  case("S01.calibration-alignment",function()
    local w=world();local c=step(w,"sensors")
    eq(c[2].rows[3].get(),L.yes,"S01 clear ACC calibration flag shows calibrated")
    local status=w.data.status
    status.arming_disable_flags=status.arming_disable_flags|(1<<23);w.onLive("status",status)
    eq(c[2].rows[3].get(),L.no,"S01 ACC calibration flag shows not calibrated live")
    status.arming_disable_flags=(status.arming_disable_flags&(~(1<<23)))|(1<<12);w.onLive("status",status)
    eq(c[2].rows[3].get(),L.yes,"S01 general calibration flag does not erase stored ACC calibration")
    w.data.status.sensor_status=0;c=step(w,"sensors")
    check(not c[2].rows[1].enabled(),"S01 missing accelerometer blocks calibration")
    eq(c[2].rows[3].get(),L.unavailable,"S01 absent accelerometer has no calibration reading")
    w.data.status.sensor_status=1;c=step(w,"sensors")
    c[2].rows[1].press();check(w.calibrationAt==nil,"S01 preparation required")
    w.checks.unplugged,w.checks.blades=true,true;c[2].rows[1].press();settle(w)
    check(w.calibrationAt~=nil,"S01 calibration starts after ACK")
    h.advance(200)
    local status=h.api("status").parse(h.fixtures[101]);status.arming_disable_flags=(1<<16)|(1<<12)
    w:acceptStatus(status)
    check(w.calibrationAt~=nil,"S01 ongoing calibration bit blocks premature completion")
    status.arming_disable_flags=1<<16;w:acceptStatus(status)
    check(w.calibrationAt==nil and w.message==L.calibrated,"S01 calibration completes only after both calibration flags clear")
    w.trial={api="board_auto_align"};w:trialReply({state=6})
    eq(w.message,L.calibrateFirst,"S01 uncalibrated firmware diagnosis")
    w.trial={api="board_auto_align"};w:trialReply({state=2,roll_degrees=-90,pitch_degrees=0,yaw_degrees=180})
    eq(w.data.board_alignment_config.roll_degrees,-90,"S01 signed alignment")
    check(w.rebootPending and w.dirty.board_alignment_config,"S01 alignment deferred to reboot gate")
    check(not w.validate(),"S01 physical direction answer required")
  end)
  case("REVIEW.fc-input-learning",function()
    local w=world();settle(w);w.step=2
    local values={1500,1500,1500,1500,1000,1000,1500,1500}
    local function raw()
      local copy={};for i,v in ipairs(values) do copy[i]=v end
      w.data.rx_channels={channels=copy};w.rxChannelsAt=getTime()
      return w.data.rx_channels
    end
    raw();local cards=step(w,"receiver")
    for _,row in ipairs(cards[1].rows) do check(row.label~=L.port,"REVIEW receiver UART is not editable on its radio link") end
    cards[2].rows[1].press()
    values[4]=2000;h.measure("RX learning",function() w.onLive("rx_channels",raw()) end)
    check(w.rx.detect and w.rx.detect.index==2,"REVIEW first movement after Detect uses the pre-click FC baseline")
    for _,channel in ipairs({1,2,3,5,7}) do values[channel]=2000;h.measure("RX learning",function() w.onLive("rx_channels",raw()) end) end
    check(w.rx.detect==nil and w.data.rx_map.throttle==4,"REVIEW subsequent controls need no extra baseline reply")
    w.data.rx_map.throttle=4;values[5]=1000;raw()
    cards[4].rows[2].press();values[5]=2000;w.onLive("rx_channels",raw());cards[4].rows[2].press()
    eq(w.data.rc_config.rc_min_throttle,1020,"REVIEW throttle recording includes the current OFF switch endpoint")
    eq(w.data.rc_config.rc_max_throttle,1980,"REVIEW one ON switch transition completes the range")
    -- Stick travel: percent of the FC's stick range, both ways, per control.
    w.data.rc_config.rc_center,w.data.rc_config.rc_deflection=1500,500
    eq(cards[3].title,L.checkSticks,"S02 the guided stick check measures the travel")
    cards[3].rows[5].press()
    for i=1,4 do values[i]=1500 end;w.onLive("rx_channels",raw())
    eq(cards[3].rows[1].get(),string.format(L.travelPair,0,0),"S02 centred sticks have no travel yet")
    eq(cards[3].summary(),string.format(L.stickGuide,L.roll,L.dirRight),"S02 the guided check asks for roll right first")
    values[w.data.rx_map.aileron+1]=1000;w.onLive("rx_channels",raw())
    eq(cards[3].summary(),L.stickReversed,"S02 roll moved left while right is asked names the reversed channel")
    values[w.data.rx_map.aileron+1]=1500;values[w.data.rx_map.elevator+1]=2000;w.onLive("rx_channels",raw())
    eq(cards[3].summary(),string.format(L.stickWrongChannel,L.pitch),"S02 another control moving names it")
    values[w.data.rx_map.elevator+1]=1500;values[w.data.rx_map.aileron+1]=2000;w.onLive("rx_channels",raw())
    values[w.data.rx_map.aileron+1]=2000;w.onLive("rx_channels",raw())
    eq(cards[3].summary(),string.format(L.stickGuide,L.pitch,L.dirBack),"S02 a roll resting at the end stop just reached is no wrong control")
    values[w.data.rx_map.aileron+1]=1500;values[w.data.rx_map.collective+1]=1150;w.onLive("rx_channels",raw())
    check(cards[3].summary()~=string.format(L.stickWrongChannel,L.roll),"S02 a roll returning to centre is no wrong control")
    eq(cards[3].summary(),string.format(L.stickWrongChannel,L.collective),"S02 the collective moving away from centre is named")
    w.onLive("rx_channels",raw())
    eq(cards[3].summary(),string.format(L.stickWrongChannel,L.collective),"S02 the warning holds while the collective stays out")
    values[w.data.rx_map.elevator+1]=1000;w.onLive("rx_channels",raw())
    eq(cards[3].summary(),string.format(L.stickGuide,L.yaw,L.dirRight),"S02 a collective already parked low when the prompt appears is not named")
    values[w.data.rx_map.elevator+1]=1500;values[w.data.rx_map.collective+1]=1500;w.onLive("rx_channels",raw())
    for i=1,4 do values[i]=1000 end;w.onLive("rx_channels",raw())
    for i=1,4 do values[i]=2000 end;values[w.data.rx_map.collective+1]=1950;w.onLive("rx_channels",raw())
    eq(cards[3].rows[1].get(),string.format(L.travelPair,100,100),"S02 full roll travel reads 100 both ways")
    eq(cards[3].rows[4].get(),string.format(L.travelPair,100,90),"S02 a collective short of its end reads its travel")
    eq(cards[3].summary(),string.format(L.stickGuide,L.collective,L.dirUp),"S02 the guided check asks for the missing end stop")
    w.rx.detect=nil;w.data.status.arming_disable_flags=0
    check(not w.validate() and w.message==L.sticksShort,"S02 a control under 95 percent keeps the step open")
    values[w.data.rx_map.collective+1]=2000;w.onLive("rx_channels",raw())
    check(w.validate(),"S02 full travel on every control completes the step")
    local collective=w.data.rx_map.collective
    w.data.rx_map.collective=7;w.onLive("rx_channels",raw())
    check(not w.validate(),"S02 a changed channel map measures the travel anew")
    w.data.rx_map.collective=collective;w.onLive("rx_channels",raw())
    for i=1,8 do values[i]=i<=4 and 1000 or values[i] end;w.onLive("rx_channels",raw())
    for i=1,4 do values[i]=2000 end;w.onLive("rx_channels",raw())
    check(w.validate(),"S02 the travel measured on the restored map completes the step")
    local short={1500,1500,1500};w.data.rx_channels={channels=short}
    check(not w.validate(),"S02 a reply without every mapped control does not complete the step")
    raw();w.data.rc_config.rc_deflection=0
    check(not w.validate(),"S02 a zero stick range does not complete the step")
    w.data.rc_config.rc_deflection=500
    w.step=3;w:navigate(2,1)
    check(w.rx.travel==nil,"S02 every visit to the receiver step measures the travel anew")
    w.step=2;cards=step(w,"receiver")
    cards[3].rows[5].press()
    eq(cards[3].rows[2].get(),string.format(L.travelPair,0,0),"S02 measure again clears the travel")
    -- The guided check measures each control from where it rested since the prompt appeared.
    for i=1,4 do values[i]=1500 end;w.onLive("rx_channels",raw())
    values[w.data.rx_map.aileron+1]=2000;w.onLive("rx_channels",raw());w.onLive("rx_channels",raw())
    eq(cards[3].summary(),string.format(L.stickGuide,L.roll,L.dirLeft),"S02 roll resting at the right stop just reached is no reversal")
    values[w.data.rx_map.aileron+1]=1500;w.onLive("rx_channels",raw())
    values[w.data.rx_map.aileron+1]=2000;w.onLive("rx_channels",raw())
    eq(cards[3].summary(),L.stickReversed,"S02 roll centred and moved right again while left is asked is a reversal")
    values[w.data.rx_map.aileron+1]=1000;values[w.data.rx_map.collective+1]=1150;w.onLive("rx_channels",raw())
    eq(cards[3].summary(),string.format(L.stickGuide,L.pitch,L.dirForward),"S02 a collective parked low when the prompt appears is not named")
    values[w.data.rx_map.aileron+1]=1500;values[w.data.rx_map.collective+1]=1500;w.onLive("rx_channels",raw())
    values[w.data.rx_map.collective+1]=2000;w.onLive("rx_channels",raw())
    eq(cards[3].summary(),string.format(L.stickWrongChannel,L.collective),"S02 the parked collective centred and moved up is named")
    values[w.data.rx_map.collective+1]=1500;w.onLive("rx_channels",raw())
    cards[3].rows[5].press()
    -- Receiver settings stay locked until Advanced is switched on.
    check(not cards[1].rows[2].enabled() and not cards[1].rows[4].enabled() and not cards[2].rows[1].enabled()
      and not cards[2].rows[2].enabled() and not cards[4].rows[2].enabled() and not cards[4].rows[3].enabled(),
      "S02 receiver settings are locked until Advanced is on")
    check(cards[3].rows[5].enabled==nil and cards[1].rows[3].enabled==nil,"S02 the stick check and the USB hint stay usable")
    cards[1].rows[1].set(2)
    check(cards[1].rows[2].enabled() and cards[2].rows[1].enabled() and cards[4].rows[4].enabled(),
      "S02 Advanced unlocks the receiver settings")
    w.step=3;w:navigate(2,1)
    check(w.rx.advanced==nil,"S02 every visit to the receiver step starts locked")
  end)
  case("REVIEW.mode-first-flick",function()
    local w=world();settle(w);w.step=3;w.data.boxids.box_ids={0}
    w.data.rc={channels={1500,1500,1500,1500,1000,1000}};w.rcAt=getTime()
    local cards=step(w,"modes");cards[1].rows[2].press()
    local nextValue={channels={1500,1500,1500,1500,1000,2000}}
    w.data.rc=nextValue;w.rcAt=getTime();w.onLive("rc",nextValue)
    h.advance(40);h.measure("mode learning",function() w.onLive("rc",nextValue) end)
    check(w.modeListen.id==nil,"REVIEW immediate switch flick is learned from the pre-click FC input")
    local found
    for _,r in ipairs(w.data.mode_ranges.mode_ranges) do if r.id==0 and r.range.start<r.range["end"] then found=r end end
    check(found and found.auxChannelIndex==0,"REVIEW learned mode uses the FC AUX index after five controls")
    eq(w.message,string.format(L.switchDetected,w:channelNumber(0),found.range.start,found.range["end"]),
      "REVIEW detection message names the stored range, not the raw samples")
    local copy=w:channelSnapshot("rc");w.data.rc.channels[6]=1000
    eq(copy[6],2000,"REVIEW click baseline is a snapshot, not a mutable packet alias")
    w.rcAt=nil;w.rxChannelsAt=getTime();cards[1].rows[2].press()
    check(w.modeListen.id==nil and w.message==L.waitChannels,"REVIEW raw-RX freshness cannot substitute for missing RC freshness")
    w.rcAt=getTime()-201;cards[1].rows[2].press()
    check(w.modeListen.id==nil,"REVIEW stale FC channels cannot start learning")
    w.rcAt=getTime();w.step=4;w.profile=nil
    local profiles=step(w,"profiles");profiles[1].rows[1].set(1);profiles[1].rows[2].press()
    local profileValue={channels={1500,1500,1500,1500,1000,2000}}
    w.data.rc=profileValue;w.rcAt=getTime();h.measure("profile learning",function() w.onLive("rc",profileValue) end)
    check(w.profile.record and w.profile.channel==0,"REVIEW profile switch also learns the first post-click movement")
  end)
  case("S02.elrs-review-fixes",function()
    local w=world();settle(w);w.step=2
    local session=w:session();local oldType=session.telemetryType
    session.telemetryType="crsf"
    w.data.feature_config.enabledFeatures=1<<3;w.data.rx_config.serialrx_provider=9
    local starts,running,choices={},false,{}
    local rate={options={"500 Hz","333 Hz"},selectedIndex=1}
    local ratio={options={"1:4","1:8"},selectedIndex=0}
    local fake={MODE_PROBE=0,MODE_ROTORFLIGHT_TO_ELRS=1,MODE_ELRS_TO_ROTORFLIGHT=2,
      start=function(mode) starts[#starts+1]=mode;running=true end,wakeup=function() running=false end,
      reset=function() running=false end,isRunning=function() return running end,
      getStatus=function() return "idle" end,getStatusText=function() return "task status" end,
      getRateField=function() return rate end,getRatioField=function() return ratio end,
      selectOption=function(kind,index) choices[#choices+1]={kind,index};running=true end,setOwner=function() end}
    local realLoad=w.loadModule
    w.loadModule=function(self,path)
      if string.find(path,"elrslink_task",1,true) then return fake end
      return realLoad(self,path)
    end
    local cards=step(w,"receiver")
    local index;for i,c in ipairs(cards) do if c.link=="combined" then index=i end end
    -- A refused telemetry read on the card is not a wizard failure.
    h.setFailCommand(73);w.card=index;cards[index].enter();w:tick();drain(w);h.setFailCommand(nil)
    check(not w.error,"S02 a refused link read on the ELRS card does not fail the wizard")
    local gated=0
    for _,row in ipairs(cards[index].rows) do
      if row.enabled then gated=gated+1;check(not row.enabled(),"S02 ELRS controls wait for Advanced") end
    end
    check(gated>0,"S02 the ELRS card has controls behind Advanced")
    w.rx.advanced=true
    -- A picker write is followed by a fresh walk of the module.
    h.fixtures[73]=h.api("telemetry_config").simulatorResponse
    w.cards=cards;w.card=index;cards[index].enter();w:tick();drain(w);w:tick();drain(w)
    local probes=#starts
    local picker;for _,row in ipairs(cards[index].rows) do if row.kind=="choice" then picker=row;break end end
    check(picker~=nil,"S02 the combined card offers a module picker")
    picker.set(2);w:tick();drain(w);w:tick();drain(w);w:tick();drain(w)
    check(#choices==1 and #starts>probes,"S02 a picker write is followed by a fresh module walk")
    h.fixtures[73]=nil;session.telemetryType=oldType
  end)
  case("CORE.fc-sensor-list-complete",function()
    local w=world();settle(w)
    local short={};for i=1,14 do short[i]=0 end
    w.data.telemetry_config={buffer=short,telem_sensor_slot_1=3,telem_sensor_slot_2=4}
    eq(w:fcSensorsListed(),nil,"CORE a short FC telemetry reply reads as unread, not as missing")
  end)
  case("S02.elrs-inline-task",function()
    local w=world();settle(w);w.step=2
    local session=w:session()
    local oldType=session.telemetryType
    h.fixtures[73]=h.api("telemetry_config").simulatorResponse
    session.telemetryType="crsf"
    w.data.feature_config.enabledFeatures=1<<3;w.data.rx_config.serialrx_provider=9
    local starts,wakes,resets,choices={},0,0,{}
    local running=false
    local rate={options={"F500","D500","500 Hz","333 Hz","250 Hz"},selectedIndex=2}
    local ratio={options={"1:2","1:4","1:8","1:16","1:32"},selectedIndex=1}
    local fake={MODE_PROBE=0,MODE_ROTORFLIGHT_TO_ELRS=1,MODE_ELRS_TO_ROTORFLIGHT=2,
      start=function(mode) starts[#starts+1]=mode;running=true end,
      wakeup=function() wakes=wakes+1;running=false end,
      reset=function() resets=resets+1;running=false end,
      isRunning=function() return running end,
      getStatus=function() return "idle" end,getStatusText=function() return "task status" end,
      getRateField=function() return rate end,getRatioField=function() return ratio end,
      selectOption=function(kind,index) choices[#choices+1]={kind,index} end,
      setOwner=function(client,guard) eq(client,"helicopter-elrs","S02 task owns a separate MSP client") end}
    local question,shown,loads=nil,true,0
    local realLoad=w.loadModule
    w.loadModule=function(self,path)
      if string.find(path,"elrslink_task",1,true) then loads=loads+1;return fake end
      if path=="ui/confirm_dialog.lua" then return {show=function(ctx) question=ctx;return shown end} end
      return realLoad and realLoad(self,path) or load(path)
    end
    local cards=step(w,"receiver")
    local index
    local links=0
    for i,c in ipairs(cards) do if c.link=="combined" then index=i;links=links+1 end end
    eq(links,1,"S02 receiver has one combined ELRS card")
    w.rx.advanced=true
    check(index~=nil,"S02 inline ELRS card replaces the pointer")
    if not index then session.telemetryType=oldType;return end
    eq(loads,0,"S02 task stays unloaded on other receiver cards")
    w.card=index;h.measure("ELRS enter",cards[index].enter);drain(w)
    w:tick();drain(w)
    eq(session.crsfTelemetryConfig.linkRate,250,"S02 telemetry read caches the FC declared rate in session")
    eq(session.crsfTelemetryConfig.linkRatio,8,"S02 telemetry read caches the FC declared ratio in session")
    eq(session.telemetryConfigBuffer[9],250,"S02 telemetry read retains the raw FC write buffer")
    check(next(w.dirty)==nil,"S02 telemetry read stays outside the wizard draft")
    session.crsfTelemetryConfig={mode=1,linkRate=333,linkRatio=8}
    session.elrsLinkConfig={packetRate=500,telemetryRatio=4,packetRateLabel="500 Hz",telemetryRatioLabel="1:4"}
    local rows=w.cards[index].rows
    local controller=w.linkController
    eq(controller:boardText(),string.format(L.linkPair,333,8),"S02 CRSF shows FC rate and ratio in confirmation")
    eq(controller:moduleText(),string.format(L.linkModulePair,"500 Hz","1:4"),"S02 CRSF shows module rate and ratio in confirmation")
    controller:updateSummary()
    eq(cards[index].summary(),"task status\n"..string.format(L.linkDiffPair,333,8,500,4),"S02 summary shows status and FC/module difference")
    local difference={get=function() return controller:difference() end}
    if difference.get then
      local function differs(rate,ratio,expected)
        session.crsfTelemetryConfig={mode=1,linkRate=rate,linkRatio=ratio}
        eq(difference.get(),expected,"S02 ELRS names only differing known values")
        controller:updateSummary()
        eq(cards[index].summary(),expected~="" and "task status\n"..expected or "task status","S02 summary follows the current difference")
      end
      differs(333,8,string.format(L.linkDiffPair,333,8,500,4))
      differs(500,8,string.format(L.linkDiffRatio,8,4))
      differs(333,4,string.format(L.linkDiffRate,333,500))
      differs(500,4,"")
      differs(1000,4,string.format(L.linkDiffRate,1000,500))
      for _,label in ipairs({"D500","D250"}) do
        session.elrsLinkConfig.packetRateLabel=label
        session.elrsLinkConfig.packetRate=tonumber(string.sub(label,2))
        session.crsfTelemetryConfig={mode=1,linkRate=1000,linkRatio=4}
        eq(difference.get(),"","S02 "..label.." vs FC 1000 has no rate difference")
        session.crsfTelemetryConfig.linkRatio=8
        eq(difference.get(),string.format(L.linkDiffRatio,8,4),"S02 "..label.." compares only the ratio")
      end
      session.elrsLinkConfig.packetRateLabel="D500"
      session.elrsLinkConfig.packetRate=500
      session.crsfTelemetryConfig={mode=1,linkRate=500,linkRatio=4}
      eq(difference.get(),"","S02 D500 vs FC 500 does not compare the rate")
      session.elrsLinkConfig.packetRateLabel="500 Hz"
      for _,key in ipairs({"linkRate","linkRatio"}) do
        session.crsfTelemetryConfig[key]=nil;eq(difference.get(),"","S02 unknown FC values have no difference line")
        session.crsfTelemetryConfig[key]=key=="linkRate" and 333 or 8
      end
      for _,key in ipairs({"packetRate","telemetryRatio"}) do
        local old=session.elrsLinkConfig[key];session.elrsLinkConfig[key]=nil
        eq(difference.get(),"","S02 unknown module values have no difference line")
        session.elrsLinkConfig[key]=old
      end
    end
    eq(#starts,1,"S02 entry starts exactly one automatic probe")
    eq(starts[#starts],0,"S02 entry starts MODE_PROBE")
    running=true
    local before=wakes;h.measure("ELRS wakeup",function() w:tick() end);check(wakes>before,"S02 current ELRS card wakes its task")
    eq(#starts,1,"S02 the combined card never probes twice without an action")
    rows=w.cards[index].rows
    local function ask(row,mode)
      local count=#starts;question=nil;row.press()
      check(question~=nil,"S02 sync asks for confirmation")
      eq(#starts,count,"S02 sync press writes nothing before confirmation")
      question.onCancel();eq(#starts,count,"S02 declined sync writes nothing")
      eq(w.linkNotice,L.linkCancelled,"S02 decline reports nothing written")
      row.press();question.onConfirm();eq(starts[#starts],mode,"S02 confirmed sync starts the requested mode")
      running=false
    end
    ask(rows[1],1);ask(rows[2],2)
    shown=false;local count=#starts;rows[1].press()
    eq(#starts,count,"S02 impossible confirmation writes nothing")
    eq(w.linkNotice,L.linkNoDialog,"S02 impossible confirmation explains nothing written")
    eq(w.message,L.linkNoDialog,"S02 impossible confirmation is visible on the combined card")
    shown=true;rows[1].press();local deferred=question
    w:release();w.statusAt=getTime();deferred.onConfirm()
    eq(#starts,count,"S02 a confirmation from a released visit writes nothing")
    rows[1].press();h.advance(301);question.onConfirm()
    eq(#starts,count,"S02 confirmation rechecks STATUS freshness")
    w.statusAt=getTime();w.dirty.rx_config=true;rows[2].press()
    eq(#starts,count,"S02 FC save cannot commit unsaved wizard changes")
    w.dirty={}
    rows[1].press();question.onConfirm()
    eq(starts[#starts],1,"S02 a fresh confirmation works again after release")
    check(type(w.linkTick)=="function","S02 resuming after release restores task wakeup")
    running=false
    check(rows[3].kind=="choice" and rows[4].kind=="choice","S02 walked module fields offer two pickers")
    eq(table.concat(rows[3].values,","),table.concat({L.link333,L.link500,L.linkD500},","),"S02 rate picker is the project subset")
    rate.selectedIndex=3;rows[3].set(2);eq(choices[#choices][2],2,"S02 500 Hz never selects F500 or D500")
    rows[3].set(3);eq(choices[#choices][2],1,"S02 D500 uses the module option index")
    rows[4].set(4);eq(choices[#choices][2],4,"S02 ratio uses the module option index")
    for _,size in ipairs({{320,240},{480,272},{480,320},{800,480}}) do
      for _,i in ipairs({index}) do
        w.card=i
        local card=w.cards[i]
        local scene=h.view.new(w,{w=size[1],h=size[2]},h.diagrams)
        while not scene:step() do end
        local firstButtonY=size[2]-(size[1]>=700 and 44 or size[1]>=480 and 32 or 26)-6
        for _,item in ipairs(scene.children) do
          if item.y and item.h then check(item.y+item.h<=size[2],"S02 ELRS widgets fit "..size[1].."x"..size[2]) end
          if item.type=="choice" then check(item.y+item.h<firstButtonY,"S02 ELRS pickers stay above navigation") end
        end
        eq(#card.rows,4,"S02 combined ELRS card keeps both sync directions and both pickers")
        local controls={}
        local summary
        for _,item in ipairs(scene.children) do
          if item.text==card.summary then summary=item end
          if item.type=="choice" or item.text==L.linkUseFc or item.text==L.linkUseModule then controls[#controls+1]=item end
          check(item.text~=L.linkProbe,"S02 automatic probe needs no duplicate button")
        end
        eq(#controls,4,"S02 all four ELRS controls are rendered")
        check(summary and summary.w>=size[1]*.35,"S02 status and difference use the summary area")
        local bottom=summary and summary.x+summary.w>controls[1].x and summary.y+summary.h or 0
        for _,item in ipairs(controls) do
          eq(item.h,size[1]>=700 and 44 or size[1]>=480 and 32 or 26,"S02 controls retain normal touch height")
          check(item.y>=bottom,"S02 ELRS controls do not overlap preceding content")
          bottom=item.y+item.h
        end
        check(bottom<=firstButtonY-(size[1]>=700 and 34 or 21),"S02 controls stay above the status line")
      end
    end
    w.card=index
    for _,fault in ipairs({"provider","feature","telemetry"}) do
      w.data.rx_config.serialrx_provider=fault=="provider" and 2 or 9
      w.data.feature_config.enabledFeatures=fault=="feature" and 0 or 1<<3
      session.telemetryType=fault=="telemetry" and "sport" or "crsf"
      local n=#starts;local picked=#choices
      rows[1].press();rows[3].set(1);w:tick()
      eq(w.message,L.linkNeedsCrsf,"S02 non-CRSF settings explain why: "..fault)
      check(not rows[1].enabled() and not rows[2].enabled(),"S02 non-CRSF sync buttons are inactive: "..fault)
      eq(#starts,n,"S02 non-CRSF cannot start a task: "..fault)
      eq(#choices,picked,"S02 non-CRSF cannot change module options: "..fault)
      eq(rows[3].get(),0,"S02 unavailable picker has a safe value: "..fault)
    end
    w.data.rx_config.serialrx_provider=9;w.data.feature_config.enabledFeatures=1<<3;session.telemetryType="crsf"
    w:navigate(2,1);check(resets>0,"S02 leaving the combined card resets the task")
    drain(w);before=wakes;w:tick()
    eq(wakes,before,"S02 other cards never wake the link task")
    w.card=index;w.cards=step(w,"receiver");w.cards[index].enter();drain(w)
    local resetBefore=resets;w:close();check(resets>resetBefore,"S02 closing the wizard resets the task")
    session.telemetryType=oldType;h.fixtures[73]=nil
    session.crsfTelemetryConfig,session.elrsLinkConfig,session.telemetryConfigBuffer=nil,nil,nil
    for _,locale in ipairs({"en","de"}) do
      local s=load("i18n/"..locale..".lua").app.modules.helicopter_setup
      check(utf8.len(s.linkHint)<600,"S02 link detail stays below 600 characters")
      for line in string.gmatch(s.linkHint,"[^\n]+") do check(utf8.len(line)<=200,"S02 link detail lines stay below 200 characters") end
      check(not s.receiverElrs and not s.receiverElrsLink and not s.openElrsLink,"S02 obsolete pointer strings removed")
    end
  end)
  case("S02.elrs-task-ownership",function()
    local w=world();settle(w)
    local session=w:session()
    local oldType,oldConnected,oldRequire=session.telemetryType,session.isConnected,_G.rfsuite.require
    local oldVersion,oldLoader=getVersion,loadScript
    session.telemetryType,session.isConnected="crsf",true
    _G.rfsuite.require=function(path)
      if path=="lib/armed.lua" then return {isArmed=function() return false end,changeCount=function() return 0 end} end
      return oldRequire and oldRequire(path)
    end
    getVersion=function() return "2.12","simu" end
    loadScript=function(path,...)
      if string.find(path,"lib/crsf.lua",1,true) then
        return function() return {popFrame=function() return nil end} end
      end
      return oldLoader(path,...)
    end
    local task=load("app/pages/tools/diagnostics/elrs_link/elrslink_task.lua")
    check(type(task.setOwner)=="function","S02 shared task supports visit-owned MSP cancellation")
    if not task.setOwner then
      session.telemetryType,session.isConnected,_G.rfsuite.require=oldType,oldConnected,oldRequire
      getVersion,loadScript=oldVersion,oldLoader;return
    end
    local current=true
    task.setOwner("helicopter-elrs",function() return current and w:usable() end)
    local function start()
      w.statusAt=getTime()
      session.crsfTelemetryConfig={mode=1,linkRate=333,linkRatio=8}
      session.telemetryConfigBuffer=h.api("telemetry_config").simulatorResponse
      task.start(task.MODE_ELRS_TO_ROTORFLIGHT)
      for _=1,3 do h.measure("ELRS task",task.wakeup);h.advance(60) end
      return q.messages[#q.messages]
    end
    q.messages={};local write=start()
    eq(write.command,74,"S02 module sync writes FC telemetry configuration")
    eq(write.client,"helicopter-elrs","S02 FC write has its own queue owner")
    eq(write.payload[9]+256*write.payload[10],500,"S02 FC write uses the module packet rate")
    eq(write.payload[11]+256*write.payload[12],4,"S02 FC write uses the module telemetry ratio")
    check(next(w.dirty)==nil,"S02 task FC writes never become wizard draft state")
    q:add({command=1,client="unrelated"})
    task.reset()
    eq(#q.messages,1,"S02 reset removes the task's queued FC write")
    eq(q.messages[1].client,"unrelated","S02 reset preserves other queue clients")
    write.processReply();eq(#q.messages,1,"S02 late write reply cannot enqueue EEPROM after reset")
    eq(session.crsfTelemetryConfig.linkRate,333,"S02 cancelled FC write never claims a saved session value")
    q.messages={};write=start();q.messages={};write.processReply()
    local save=q.messages[1]
    eq(save.command,h.api("eeprom_write").writeCommand,"S02 acknowledged FC write queues EEPROM")
    eq(save.client,"helicopter-elrs","S02 EEPROM uses the same task queue owner")
    task.reset();eq(#q.messages,0,"S02 reset also removes the pending EEPROM write")
    save.processReply();eq(session.crsfTelemetryConfig.linkRate,333,"S02 late EEPROM reply cannot update the session after reset")
    q.messages={};write=start();h.advance(301);task.wakeup()
    eq(#q.messages,0,"S02 expired STATUS cancels the task's pending FC write")
    write.processReply();eq(#q.messages,0,"S02 expired STATUS cannot be followed by EEPROM")
    q.messages={};write=start();q.messages={};current=false;write.processReply()
    eq(#q.messages,0,"S02 leaving before the FC reply prevents EEPROM")
    current=true
    -- Complete a fresh transaction through both acknowledgements.
    task.reset();write=start();q.messages={};write.processReply();save=q.messages[1];q.messages={};save.processReply()
    eq(session.crsfTelemetryConfig.linkRate,500,"S02 FC rate is published only after EEPROM acknowledgement")
    eq(session.crsfTelemetryConfig.linkRatio,4,"S02 FC ratio is published only after EEPROM acknowledgement")
    check(not task.isRunning(),"S02 acknowledged FC save completes the task")
    task.reset()
    session.telemetryType,session.isConnected,_G.rfsuite.require=oldType,oldConnected,oldRequire
    session.crsfTelemetryConfig,session.telemetryConfigBuffer,session.elrsLinkConfig=nil,nil,nil
    getVersion,loadScript=oldVersion,oldLoader
  end)
  case("S02.protocol-ids-presets-feature-group",function()
    local w=world();local entries=w:receiverProtocols();local ids={}
    for _,e in ipairs(entries) do ids[e[2]]=e[1] end
    eq(ids["S.BUS2"],15,"S02 S.BUS2 wire ID")
    eq(ids["F.PORT2"],16,"S02 F.PORT2 wire ID")
    eq(ids.FBUS,17,"S02 FBUS wire ID")
    eq(ids["XBUS A"],18,"S02 XBUS A wire ID")
    eq(ids.IBUS2,19,"S02 IBUS2 wire ID")
    w.data.rx_config.serialrx_provider=9;w.data.feature_config.enabledFeatures=1<<25
    local rx=step(w,"receiver")
    eq(rx[1].rows[2].get(),0,"S02 SPI receiver does not masquerade as stored serial protocol")
    rx[1].rows[2].set(1)
    eq(w.data.feature_config.enabledFeatures,1<<3,"S02 choosing stored CRSF still changes receiver feature group")
    eq(rx[1].rows[2].get(),1,"S02 serial receiver selection readback")
    w.data.feature_config.enabledFeatures=(1<<0)|(1<<13)|(1<<14)|(1<<25)|(1<<28)
    w:serialReceiver()
    eq(w.data.feature_config.enabledFeatures,(1<<3)|(1<<28),"S02 RX feature group preserves RPM feature")
    local c=step(w,"receiver")
    for i,map in ipairs({{0,1,3,2,5,4,6,7},{0,1,3,4,2,5,6,7},{0,1,3,5,2,4,6,7},{1,2,3,5,0,4,6,7}}) do
      c[2].rows[2].set(i)
      for n,key in ipairs({"aileron","elevator","rudder","collective","throttle","aux1","aux2","aux3"}) do
        eq(w.data.rx_map[key],map[n],"S02 preset "..i.." function "..n)
      end
      eq(c[2].rows[2].get(),i,"S02 preset readback")
    end
  end)
  case("S02.port-selection",function()
    local w=world()
    w.data.serial_config.port_1_identifier=20;w.data.serial_config.port_1_function_mask=0
    w.data.serial_config.port_2_identifier=30;w.data.serial_config.port_2_function_mask=0
    w.data.serial_config.port_3_function_mask=1|64
    local row=w:port(L.port,64)
    for _,name in ipairs(row.values) do check(name~="UART21","S02 USB VCP never offered") end
    local current=row.get();row.set(current)
    eq(w.data.serial_config.port_3_function_mask,65,"S02 current port preserves shared function mask")
    local free
    for n,name in ipairs(row.values) do if name=="SOFTSERIAL1" then free=n end end
    check(free~=nil,"S02 supported soft serial name shown")
    row.set(free)
    eq(w.data.serial_config.port_2_function_mask,64,"S02 free destination gets RX function")
    eq(w.data.serial_config.port_3_function_mask,1,"S02 old RX port preserves other functions")
  end)
  case("S02.order-detection-and-throttle",function()
    local w=world();local c=step(w,"receiver")
    local values={1500,1500,1500,1500,1500,1500,1500,1500}
    local function reply()
      local copy={};for i,v in ipairs(values) do copy[i]=v end
      w.data.rx_channels={channels=copy};w.rxChannelsAt=getTime();w.onLive("rx_channels",w.data.rx_channels)
    end
    reply()
    c[2].rows[1].press()
    -- Collective, roll, pitch, yaw, throttle, arm; a used channel is never reused.
    for n,channel in ipairs({3,2,4,1,5,7}) do
      if n==6 then
        check(w.rx.detect~=nil and string.find(w.message,L.flipArm,1,true)~=nil,"S02 detection asks for the arm switch last")
      end
      values[channel]=2000;reply();reply()
    end
    eq(w.data.rx_map.collective,2,"S02 collective detected first")
    eq(w.data.rx_map.aileron,1,"S02 roll detected")
    eq(w.data.rx_map.elevator,3,"S02 pitch detected")
    eq(w.data.rx_map.rudder,0,"S02 yaw detected")
    eq(w.data.rx_map.throttle,4,"S02 throttle detected")
    eq(w.data.rx_map.aux1,6,"S02 arm switch detected as AUX1")
    check(w.rx.detect==nil and w.dirty.rx_map,"S02 permutation completes")
    values[5]=1100;reply();c[4].rows[2].press();values[5]=1399;reply();c[4].rows[2].press()
    check(w.message==L.travelShort and w.rx.record,"S02 travel below 300 rejected and still recording")
    eq(c[4].rows[2].label(),L.useRange,"S02 the record button turns into Use range while recording")
    values[5]=1900;reply();c[4].rows[2].press()
    eq(w.data.rc_config.rc_min_throttle,1120,"S02 low range margin")
    eq(w.data.rc_config.rc_max_throttle,1880,"S02 high range margin")
    eq(c[4].rows[2].label(),L.record,"S02 applying the range ends the recording")
    c[4].rows[3].set(0);c[4].rows[4].set(0);w.data.rx_channels={channels={1500,1500,1500,1500,1030}}
    eq(c[4].rows[1].get(),string.format(L.throttleLowNow,1030),"S02 default 1041 minus deadband allows 1030")
    w.data.rx_channels.channels[5]=0
    check(c[4].rows[1].get()~=string.format(L.throttleLowNow,0),"S02 absent throttle is not low confirmation")
  end)
  case("S03.mode-status-versus-switch",function()
    local w=world();w.data.boxids.box_ids={0,53,47}
    w.data.mode_ranges.mode_ranges[1]={id=0,auxChannelIndex=0,range={start=1800,["end"]=2100}}
    w.data.mode_ranges.mode_ranges[2]={id=53,auxChannelIndex=1,range={start=1800,["end"]=2100}}
    w.data.rc={channels={1500,1500,1500,1500,1000,2000,2000}}
    w.data.status.flight_mode_flags=0
    local c=step(w,"modes")
    w.data.rx_map.aux1=4
    eq(w:channelNumber(0),5,"S03 displayed receiver channel follows RX_MAP")
    check(string.find(c[1].rows[1].get(),"CH5",1,true)~=nil,"S03 switch assignment names physical receiver channel")
    eq(c[1].rows[4].get(),L.switchOn,"S03 ARM shows switch position despite arming inhibit")
    eq(c[2].rows[4].get(),L.switchOff,"S03 rescue requires actual mode flag")
    w.data.status.flight_mode_flags=2
    eq(c[2].rows[4].get(),L.switchOn,"S03 actual rescue mode flag")
    c[2].rows[3].press();check(w.dirty.mode_ranges,"S03 remove live write")
    eq(w.data.mode_ranges.mode_ranges[2].range.start,1500,"S03 remove disables slot")
    check(w.validate(),"S03 ARM assignment required and present")
    c[1].rows[3].press();check(not w.validate(),"S03 missing ARM blocks advance")
  end)
  case("S03.switch-settle",function()
    local w=world();w.data.boxids.box_ids={0}
    w.data.rc={channels={1500,1500,1500,1500,1000,1000}};w.rcAt=getTime()
    local c=step(w,"modes");c[1].rows[2].press()
    w.onLive("rc",{channels={1500,1500,1500,1500,1000,1000}})
    w.onLive("rc",{channels={1500,1500,1500,1500,1000,2000}})
    h.advance(39);w.onLive("rc",{channels={1500,1500,1500,1500,1000,2000}})
    check(w.modeListen.id~=nil,"S03 switch waits 400 ms")
    h.advance(1);w.onLive("rc",{channels={1500,1500,1500,1500,1000,2000}})
    check(w.modeListen.id==nil,"S03 settled switch assigned")
    local r=w.data.mode_ranges.mode_ranges[2]
    eq(w.data.mode_ranges.mode_ranges[1].id,1,"S03 unrelated existing mode preserved")
    eq(r.auxChannelIndex,0,"S03 AUX index starts after five controls")
    eq(r.range.start,1500,"S03 switch range midpoint")
    eq(r.range["end"],2100,"S03 switch high end margin")
    eq(w.data.mode_ranges_extra.mode_ranges_extra[2].linkedTo,0,"S03 removes previous mode linkage")
  end)
  case("S04.channel-use-cards-describe-channels",function()
    local w=world();settle(w);local c=step(w,"profiles");local seen=0
    for _,card in ipairs(c) do
      if card.title==L.channelPlan then
        seen=seen+1
        check(card.dense and #card.rows<=7,"S04 plan uses dense rows within the compact display limit")
        check(card.detail==L.channelPlanHint or card.detail==L.beyondEight,"S04 channel-use card explains the channel list")
      end
    end
    eq(seen,1,"S04 channel plan fits on one dense card")
    for channel=3,5 do
      w.data.mode_ranges.mode_ranges[channel]={id=53,auxChannelIndex=channel,range={start=1800,["end"]=2100}}
    end
    c=step(w,"profiles");local counts={};local total=0
    for _,card in ipairs(c) do if card.title==L.channelPlan then
      counts[#counts+1]=#card.rows;total=total+#card.rows
      check(card.dense and #card.rows<=7,"S04 overflow remains dense with at least 18 px per row")
    end end
    eq(table.concat(counts,","),"7,1","S04 eighth plan row starts a second dense card")
    eq(total,8,"S04 splitting preserves every channel-plan row")
  end)
  case("S04.recording-expiry-and-trim-guide",function()
    local w=world();settle(w);w.step=4;w.card=2
    local c=step(w,"profiles")
    local function guides(cards)
      local n=0;for _,card in ipairs(cards) do if card.title==L.trimGuide then n=n+1 end end;return n
    end
    eq(guides(c),0,"S04 None has no trim-button guide")
    for _,method in ipairs({3,2,3,1}) do
      c[2].rows[1].set(method)
      check(w.buildRequested,"S04 method change requests the existing card rebuild")
      drain(w);c=w.cards
      eq(w.card,2,"S04 method rebuild retains the gain card")
      eq(guides(c),method==3 and 1 or 0,"S04 only Buttons includes the trim guide after rebuilding")
    end
    c[1].rows[1].set(1)
    w.profile.record,w.profile.untilAt=true,getTime()-1
    w.profile.positions={{low=1000,high=1000},{low=2000,high=2000}}
    w.onLive("rc",{channels={}})
    check(not w.profile.record and #w.profile.positions==2,"S04 recording expiry preserves learned positions")
    eq(w.message,string.format(L.positionsRecorded,2),"S04 recording expiry reports the recorded count")
    check(c[1].rows[4].enabled(),"S04 recorded switch remains usable after expiry")
    check(string.find(c[1].rows[3].get(),": 2",1,true)~=nil,"S04 position row retains the recorded count")
    c[1].rows[4].press()
    check(H.rangeOf(w.data.adjustment_ranges.adjustment_ranges,2)~=nil,"S04 expired recording can still install the switch")
    w.profile.record,w.profile.untilAt=true,getTime()-1;w.profile.positions={{low=1500,high=1500}}
    w.onLive("rc",{channels={}})
    eq(w.message,L.twoPositions,"S04 a short recording gives the two-position hint")
    eq(#w.profile.positions,1,"S04 short recording also retains its position")
    w.profile.listen,w.profile.untilAt="profile",getTime()-1
    w.onLive("rc",{channels={}})
    eq(w.message,L.detectTimeout,"S04 listening without movement keeps timeout feedback")
    eq(#w.profile.positions,0,"S04 listening timeout still cancels detection")
  end)
  case("S04.readback-paired-capacity",function()
    local w=world();local ranges=w.data.adjustment_ranges.adjustment_ranges
    ranges[1]=H.mapped(2,2,1000,2000,1,3)
    ranges[2]=H.gain(83,3,true);ranges[3]=H.gain(84,3,true)
    local c=step(w,"profiles")
    eq(w.profile.mode,2,"S04 existing PID-only assignment inferred")
    eq(w.profile.gain,3,"S04 existing stepped gain inferred")
    eq(w.profile.channel,2,"S04 existing profile channel inferred")
    c[1].rows[1].set(1)
    eq(H.rangeOf(ranges,1).adjChannel,2,"S04 both copies existing PID channel")
    c[1].rows[1].set(3)
    check(not H.rangeOf(ranges,1) and not H.rangeOf(ranges,2),"S04 none removes both profiles")
    for i=1,#ranges do ranges[i]=H.gain(50,0,false) end
    ranges[1].adjFunction=0
    local before=#w.bus.jobs
    w.profile.mode=1;w.profile.positions={{low=1000,high=1000},{low=2000,high=2000}}
    c[1].rows[4].press()
    eq(w.message,L.noSlots,"S04 full-table feedback")
    eq(ranges[1].adjFunction,0,"S04 full pair leaves free slot untouched")
    eq(#w.bus.jobs,before,"S04 no partial paired write")
  end)
  case("S04.switch-recording-gain-feedback",function()
    local w=world();local c=step(w,"profiles")
    w.data.rc={channels={1500,1500,1500,1500,1000,1000,2012}};w.rcAt=getTime()
    c[1].rows[1].set(1);c[1].rows[2].press()
    local function rc(value)
      w.data.rc={channels={1500,1500,1500,1500,1000,value,2012}};w.rcAt=getTime();w.onLive("rc",w.data.rc)
    end
    rc(1000);rc(2000);rc(1500);rc(1200)
    c[1].rows[4].press()
    local r=H.rangeOf(w.data.adjustment_ranges.adjustment_ranges,2)
    eq(r.adjMax,3,"S04 four positions capped at three profiles")
    eq(r.adjRange1.start,1000,"S04 full switch travel low")
    eq(r.adjRange1["end"],2000,"S04 full switch travel high")
    c[2].rows[1].set(3);c[2].rows[2].press()
    rc(2012);rc(1654)
    local gr=H.rangeOf(w.data.adjustment_ranges.adjustment_ranges,83)
    eq(gr.adjStep,5,"S04 gain buttons step 5")
    eq(gr.enaChannel,255,"S04 adjustment always enabled")
    eq(gr.adjMin,25,"S04 gain minimum")
    eq(gr.adjMax,200,"S04 gain maximum")
    w.data.rc={channels={1500,1500,1500,1500,1000,1654,2012}}
    check(string.find(c[2].rows[4].get(),"-5%%")~=nil,"S04 pressed cyclic-down feedback")
    w.data.rc.channels[6]=2012
    eq(c[2].rows[4].get(),L.none,"S04 neutral outside button windows")
  end)
  local function cardOrder(cards,titles,id)
    eq(#cards,#titles,id.." card count")
    for i,title in ipairs(titles) do eq(cards[i] and cards[i].title,title,id.." card title "..i) end
  end
  local function savedPayload(w,name,id)
    local api=load("tasks/msp/api/"..name..".lua")
    local expected=api.buildWritePayload(w.data[name])
    local count=0
    for _,m in ipairs(q.sent) do
      if m.command==api.writeCommand then
        count=count+1
        eq(table.concat(m.payload,","),table.concat(expected,","),id.." saved "..name.." payload")
      end
    end
    eq(count,1,id.." writes "..name.." once")
  end
  case("S05.profile-cards-and-save",function()
    local w=world();settle(w);w.step=5
    local ranges=w.data.adjustment_ranges.adjustment_ranges
    ranges[1]=H.mapped(2,1,1000,2000,1,3);ranges[2]=H.mapped(1,1,1000,2000,1,3)
    local c=step(w,"rates")
    cardOrder(c,{string.format(L.switchRateProfile,1,1),string.format(L.switchRateProfile,2,2),
      string.format(L.switchRateProfile,3,3)},"S05")
    c[1].enter();settle(w)
    check(c[1].rows[1].enabled(),"S05 three switch positions enable Suggest")
    c[1].rows[1].press()
    for i=1,3 do eq(w.rateStyles[i-1],i,"S05 Suggest follows switch position "..i) end
    w.rateTunings[0].rcRates_4=80;w.rateTunings[1].rcRates_4=120
    check(c[1].rows[3].get()~=c[2].rows[2].get(),"S05 collective readout belongs to its profile")
    c[1].rows[2].set(1);c[2].rows[1].set(4);c[3].rows[1].set(2)
    eq(w.rateStyles[0],nil,"S05 Keep current leaves the first profile unwritten")
    eq(w.rateStyles[1],3,"S05 second card edits only profile two")
    eq(w.rateStyles[2],1,"S05 third card edits only profile three")
    local expected={}
    local fixture=load("tasks/msp/api/rc_tuning.lua")
    for _,style in ipairs({3,1}) do
      local d=fixture.parse(fixture.simulatorResponse);H.style(d,style,6)
      expected[#expected+1]=table.concat(fixture.buildWritePayload(d),",")
    end
    q.sent={};w:save();settle(w)
    local count=0
    for _,m in ipairs(q.sent) do
      if m.command==204 then count=count+1;eq(table.concat(m.payload,","),expected[count],"S05 per-profile save fields "..count) end
    end
    eq(count,2,"S05 only the two selected profiles are saved")
    ranges[1],ranges[2]=nil,nil;c=step(w,"rates")
    cardOrder(c,{string.format(L.rateProfileTitle,w.data.status.current_control_rate_profile_index+1)},"S05 active")
    eq(c[1].rows[1].label,L.flyingStyle,"S05 active profile has no selector or Suggest")
    w.rateStyles={};w.rateMatched={}
    eq(c[1].summary(),L.rateNoMatchShort,"S05 unmatched profile explains rate replacement")
    check(string.find(c[1].detail,L.rateNoMatch,1,true)~=nil,"S05 help includes the full unmatched warning")
  end)
  case("S08.card-order-and-save",function()
    local w=world();settle(w);w.step=8;w.data.feature_config.enabledFeatures=0
    local c=step(w,"governor");cardOrder(c,{L.governorMode},"S08 Off")
    c[1].rows[1].set(4);c=step(w,"governor")
    cardOrder(c,{L.governorMode,L.throttleType},"S08 On")
    c[2].rows[1].set(2)
    eq(w.data.governor_config.gov_mode,3,"S08 Electric mode field")
    eq(w.data.governor_config.gov_throttle_type,1,"S08 Switch throttle field")
    check(w.rebootPending,"S08 mode still requires restart")
    q.sent={};w:save();settle(w)
    savedPayload(w,"governor_config","S08");savedPayload(w,"feature_config","S08")
    c=step(w,"governor");c[1].rows[1].set(1);c=step(w,"governor")
    cardOrder(c,{L.governorMode},"S08 disabled again")
  end)
  case("S09.card-order-and-save",function()
    for _,tail in ipairs({0,1}) do
      local w=world();settle(w);w.step=9;w.data.mixer_config.tail_rotor_mode=tail
      local c=step(w,"motor")
      cardOrder(c,{L.throttleProtocol,L.motorGearing,L.motorGearingTail},"S09 tail "..tail)
      c[1].rows[1].set(5);c[1].rows[2].set(2)
      c[2].rows[1].set(14);c[2].rows[2].set(12);c[2].rows[3].set(120)
      eq(c[2].rows[4].get(),"10.000","S09 ratio still follows tooth counts")
      if tail==0 then c[3].rows[1].set(20);c[3].rows[2].set(90)
      else c[3].rows[1].set(8) end
      eq(w.data.motor_config.motor_pwm_protocol,5,"S09 protocol wire ID")
      eq(w.data.motor_config.use_dshot_telemetry,1,"S09 DShot field")
      eq(w.data.motor_config.motor_pole_count_0,14,"S09 main pole field")
      eq(w.data.motor_config.main_rotor_gear_ratio_0,12,"S09 pinion field")
      eq(w.data.motor_config.main_rotor_gear_ratio_1,120,"S09 main gear field")
      if tail==0 then
        eq(w.data.motor_config.tail_rotor_gear_ratio_0,20,"S09 tail input field")
        eq(w.data.motor_config.tail_rotor_gear_ratio_1,90,"S09 tail output field")
      else eq(w.data.motor_config.motor_pole_count_1,8,"S09 tail pole field") end
      eq(c[2].art,"motorGears","S09 gearing has its own picture")
      q.sent={};w:save();settle(w)
      savedPayload(w,"motor_config","S09");savedPayload(w,"feature_config","S09")
    end
  end)
  local function noConfigWrites(w,id)
    q.sent={};w:save();settle(w)
    local config={}
    for _,name in ipairs({"motor_config","governor_config","feature_config","esc_sensor_config","serial_config","rc_tuning"}) do
      local api=load("tasks/msp/api/"..name..".lua");config[api.writeCommand]=true
    end
    local eeprom=0
    for _,m in ipairs(q.sent) do
      check(not config[m.command],id.." adds no configuration write")
      if m.command==250 then eeprom=eeprom+1 end
    end
    eq(eeprom,1,id.." save still reaches EEPROM")
  end
  case("S10.card-order-and-save",function()
    local w=world();settle(w);w.step=10;w.rebootPending=nil;w.data.motor={motor_1=1000,motor_2=1000}
    local c=step(w,"connect");cardOrder(c,{L.plugServos,L.battery},"S10")
    c[1].rows[3].set(2);c[1].rows[4].set(2)
    check(w.validate(),"S10 both confirmations still complete the step")
    noConfigWrites(w,"S10")
    w.rebootPending=true;c=step(w,"connect");cardOrder(c,{L.connect},"S10 restart")
    eq(c[1].rows[1].label,L.servosUnplugged,"S10 restart retains unplugged confirmation")
    eq(c[1].art,"servo","S10 restart retains its picture")
  end)
  case("S11.card-order-save-and-calibration-navigation",function()
    local w=world();settle(w);w.step=11;w.card=1;w.data.motor_config.motor_pwm_protocol=0
    w.data.motor={motor_1=1000,motor_2=1000}
    local c=step(w,"throttle")
    cardOrder(c,{L.fullThrottleTitle,L.connectBattery,L.lowThrottle,L.throttle,L.motorDirection},"S11 PWM")
    w.checks.escBlades=true;c[1].rows[2].press()
    local hold=w.motorHold;check(hold~=nil,"S11 calibration navigation has a running hold")
    w:navigate(11,2)
    eq(w.motorHold,hold,"S11 full throttle survives only the battery-card handoff")
    eq(w.motorHold and w.motorHold.untilAt,hold.untilAt,"S11 battery handoff never extends hold timeout")
    settle(w);c=step(w,"throttle")
    w.data.motor.motor_1=1994;check(not c[2].rows[2].enabled(),"S11 battery card retains full-output safety gate")
    w.data.motor.motor_1=2000;c[2].rows[2].press()
    check(not w.motorHold and w.escStage=="low","S11 Low throttle still releases the hold")
    w:navigate(11,3);settle(w);c=step(w,"throttle")
    for _,output in ipairs({0,1006}) do
      w.data.motor.motor_1=output;c[3].rows[1].press();check(not w.calibratedEsc,"S11 invalid low output cannot confirm calibration")
    end
    w.data.motor.motor_1=1000;c[3].rows[1].press();check(w.calibratedEsc,"S11 valid low output confirms calibration")
    check(not w.validate(),"S11 Continue still requires motor direction")
    c[5].rows[1].set(2);check(w.validate(),"S11 motor direction still completes the step")
    noConfigWrites(w,"S11")
    w.card=1;c[1].rows[2].press()
    check(w.motorHold~=nil,"S11 Back control starts with full throttle active")
    w:navigate(11,2);settle(w)
    w:navigate(11,1);check(not w.motorHold,"S11 Back from the battery card releases full throttle")
    settle(w);w.escStage="idle";c=step(w,"throttle");c[1].rows[2].press()
    check(w.motorHold~=nil,"S11 skip control starts with full throttle active")
    w:navigate(11,4);check(not w.motorHold,"S11 skipping calibration cards releases full throttle")
    settle(w);w.card=1;w.escStage="full"
    w.motorHold={index=0,value=100,mode="spin",due=0,untilAt=getTime()+1500}
    w:navigate(11,2);check(not w.motorHold,"S11 battery handoff never retains a spin-test hold")
    settle(w);w.data.motor_config.motor_pwm_protocol=5;c=step(w,"throttle")
    cardOrder(c,{L.connectBattery,L.throttle,L.motorDirection},"S11 non-PWM")
  end)
  case("S12.card-order-and-save",function()
    local w=world();settle(w);w.step=12;w.data.motor_config.motor_pwm_protocol=5
    w.data.esc_sensor_config.protocol=1
    local c=step(w,"escTelemetry")
    cardOrder(c,{L.escTelemetry,L.port,L.telemetryCheck,L.telemetryStatus},"S12 serial")
    c[1].rows[1].set(3);c[2].rows[1].set(1)
    eq(w.data.esc_sensor_config.protocol,2,"S12 protocol field")
    check(w:hasPort(1024),"S12 port assignment still selects telemetry")
    q.sent={};w:save();settle(w)
    savedPayload(w,"esc_sensor_config","S12");savedPayload(w,"feature_config","S12")
    local serialWrites,expected=0,{}
    local api=load("tasks/msp/api/serial_config.lua")
    for i=1,12 do
      local port={}
      for _,key in ipairs({"identifier","function_mask","msp_baud_index","gps_baud_index","telem_baud_index","blackbox_baud_index"}) do
        port[key]=w.data.serial_config["port_"..i.."_"..key]
      end
      if port.identifier~=nil then expected[#expected+1]=table.concat(api.buildWritePayload(port),",") end
    end
    for _,m in ipairs(q.sent) do
      if m.command==55 then
        serialWrites=serialWrites+1
        eq(table.concat(m.payload,","),expected[serialWrites],"S12 preserves all saved serial fields "..serialWrites)
      end
    end
    eq(serialWrites,#expected,"S12 saves every configured serial port")
    check(serialWrites>0,"S12 port assignment is saved")
    c=step(w,"escTelemetry");c[1].rows[1].set(1);c=step(w,"escTelemetry")
    cardOrder(c,{L.escTelemetry,L.telemetryCheck,L.telemetryStatus},"S12 Off")
    w.data.motor_config.motor_pwm_protocol=9;c=step(w,"escTelemetry")
    cardOrder(c,{L.escTelemetry,L.telemetryCheck,L.telemetryStatus},"S12 Castle")
    eq(c[1].detail,L.castleTelemetryHint,"S12 Castle explains its throttle wire")
    check(not c[1].rows[1].enabled(),"S12 Castle protocol stays read-only")
  end)
  case("S05.scoped-rates-and-readback",function()
    local w=world();w.step=5
    local ranges=w.data.adjustment_ranges.adjustment_ranges
    ranges[1]=H.mapped(2,1,1000,2000,2,3);ranges[2]=H.mapped(1,1,1000,2000,2,3)
    local c=step(w,"rates");c[1].enter();settle(w)
    eq(table.concat(w.rateProfiles,","),"1,2","S05 only mapped rate profiles offered")
    check(w.rateTunings[1] and w.rateTunings[2] and not w.rateTunings[0],"S05 profiles read individually")
    check(not c[1].rows[1].enabled(),"S05 suggest only offered for three positions")
    c[1].rows[2].set(2)
    q.sent={};w:save();settle(w)
    local writes=0;local selections={}
    for _,m in ipairs(q.sent) do
      if m.command==204 then writes=writes+1 end
      if m.command==210 then selections[#selections+1]=m.payload[1] end
    end
    eq(writes,1,"S05 only chosen profile written")
    eq(table.concat(selections,","),"129,130","S05 selected profile restored")
    check(next(w.rateStyles)==nil,"S05 chosen styles cleared after save")
    local tuning={rates_type=6,rcRates_4=100}
    for style=1,3 do
      H.style(tuning,style);eq(H.matchStyle(tuning,6),style,"S05 preset matches readback "..style)
      eq(H.collective(tuning),12.5,"S05 collective preserved")
    end
    H.style(tuning,2,4);eq(tuning.rates_type,4,"S05 pre-12.09 Actual helper")
    eq(tuning.rcRates_1,19,"S05 Actual centre rounding")
  end)
  case("S06.tail-transition-and-pin",function()
    local w=world();w.data.mixer_config.tail_rotor_mode=1;w.startTail=1
    w.data.tail_motor_output={output=1,result=0}
    local c=step(w,"swash");c[3].rows[1].set(3);w.commit()
    check(w.restoreProfile==nil,"S06 motor to bidirectional preserves custom TTA")
    eq(math.abs(w.data.mixer_input.inputs[3].rate),1000,"S06 motor yaw scale")
    w.startTail=0;w.commit()
    check(w.restoreProfile~=nil,"S06 servo-to-motor updates TTA across PID profiles")
    w.bus:cancel();w.restoreProfile=nil;w.startTail=1
    w.data.tail_motor_output={output=0,result=0};step(w,"swash");w.commit()
    -- Module write reply must confirm the requested pin, rather than ACK alone.
    local job=w.bus.jobs[#w.bus.jobs]
    job.after({output=0,result=1})
    check(w.error~=nil,"S06 refused tail pin blocks advancement")
  end)
  case("REVIEW.custom-servo-hz",function()
    local w=world();local c=step(w,"servoType")
    local rate
    for _,r in ipairs(c[1].rows) do if r.kind=="number" then rate=r end end
    check(rate~=nil,"REVIEW servo type offers an editable Hz field")
    if not rate then return end
    eq(rate.min,25,"REVIEW custom Hz uses the firmware minimum")
    eq(rate.max,5000,"REVIEW custom Hz uses the firmware maximum")
    local servos=w.data.servo_configurations.servos
    local mid,travel,scale=servos[0].mid,servos[0].max,servos[0].rpos
    local original=servos[0].rate;rate.set(200)
    eq(servos[0].rate,original,"REVIEW Hz change requires unplugged servos")
    w.checks.unplugged=true;local tailRate=servos[3].rate;rate.set(200)
    for i=0,2 do eq(servos[i].rate,200,"REVIEW Hz applies to every cyclic PWM servo") end
    eq(servos[3].rate,tailRate,"REVIEW cyclic Hz leaves the tail unchanged")
    eq(servos[0].mid,mid,"REVIEW Hz preserves calibrated centre")
    eq(servos[0].max,travel,"REVIEW Hz preserves calibrated travel")
    eq(servos[0].rpos,scale,"REVIEW Hz preserves output scale")
    check(w.rebootPending and w.dirty.servo_configurations,"REVIEW custom Hz marks the configuration for restart")
    eq(c[1].rows[2].get(),4,"REVIEW custom Hz is shown as a custom type")
    local tail=c[2].rows[3];tail.set(250)
    eq(servos[3].rate,250,"REVIEW tail Hz has a separate field")
    eq(servos[0].rate,200,"REVIEW tail Hz leaves cyclic rates unchanged")
    rate.set(24);rate.set(5001);rate.set(200.5)
    eq(servos[0].rate,200,"REVIEW out-of-range/fractional Hz cannot be written")
    servos[1].rate=333;eq(c[1].rows[4].get(),L.mixed,"REVIEW different group settings are explicitly marked mixed")
    w.cards=c;w.card=1
    local scene=h.view.new(w,{w=320,h=240},h.diagrams)
    while not scene:step() do end
    local wave
    for _,item in ipairs(scene.children) do if item.type=="line" and type(item.pts)=="function" and #item.pts()==50 then wave=item end end
    check(wave~=nil,"REVIEW custom Hz has a cached pulse reference")
    local points=wave.pts();local before=points[5][1]
    h.measure("Hz edit",function() rate.set(250) end);eq(wave.pts(),points,"REVIEW Hz edits retain native point-table identity")
    check(points[5][1]~=before,"REVIEW custom Hz updates the existing waveform")
    rate.set(5000);check(not wave.visible(),"REVIEW impossible pulse timing is not drawn as a valid waveform")
    rate.set(200);check(wave.visible(),"REVIEW supported timing restores the same waveform")
    eq(c[1].rows[4].get(),L.uniform,"REVIEW group Hz edit resolves mixed rates explicitly")
  end)
  case("S07.geometry-correction",function()
    local w=world();local c=step(w,"servoType");local card=(function() for _,x in ipairs(c) do if x.title==L.geometryCorrection then return x end end end)()
    eq(card.title,L.geometryCorrection,"S07 geometry correction has a card of its own")
    local row=card.rows[1];local servos=w.data.servo_configurations.servos
    servos[0].flags=1;servos[1].flags=0;servos[2].flags=0;servos[3].flags=0
    eq(row.get(),1,"S07 geometry correction reads off")
    row.set(2)
    eq(servos[0].flags,3,"S07 geometry correction keeps the reverse bit")
    eq(servos[1].flags,2,"S07 geometry correction sets every cyclic servo")
    eq(servos[3].flags,0,"S07 geometry correction leaves the tail servo alone")
    check(w.dirty.servo_configurations and not w.rebootPending,"S07 geometry correction is written without a restart")
    servos[2].flags=0;eq(row.get(),0,"S07 differing geometry flags read as mixed")
    row.set(1);eq(servos[0].flags,1,"S07 clearing geometry correction keeps the reverse bit")
    eq(row.get(),1,"S07 geometry correction reads off again")
  end)
  case("S07.tail-geometry-correction",function()
    local w=world();local c=step(w,"servoType");local tail
    for _,card in ipairs(c) do if L.tailGeometryCorrection and card.title==L.tailGeometryCorrection then tail=card end end
    check(tail~=nil,"S07 servo tail has its own geometry choice")
    if tail then
      local row=tail.rows[1];local servos=w.data.servo_configurations.servos
      servos[0].flags=5;servos[1].flags=2;servos[2].flags=0
      for _,flags in ipairs({0,1,4,5}) do
        servos[3].flags=flags
        eq(row.get(),1,"S07 tail geometry reads off")
        row.set(2);eq(servos[3].flags,flags | 2,"S07 tail geometry sets bit 1 and preserves other bits")
        eq(row.get(),2,"S07 tail geometry reads on")
        row.set(1);eq(servos[3].flags,flags,"S07 tail geometry clears bit 1 and preserves reverse")
      end
      eq(servos[0].flags,5,"S07 tail geometry leaves cyclic servo 0 alone")
      eq(servos[1].flags,2,"S07 tail geometry leaves cyclic servo 1 alone")
      eq(servos[2].flags,0,"S07 tail geometry leaves cyclic servo 2 alone")
      check(w.dirty.servo_configurations and w.live.servo_configurations and not w.rebootPending,
        "S07 tail geometry is live without a restart")
      check(tail.detail==L.geometryHint and tail.summary==L.geometryQuick,"S07 tail geometry carries the shared explanation")
    end
    for _,mode in ipairs({1,2}) do
      w.data.mixer_config.tail_rotor_mode=mode;c=step(w,"servoType")
      local count=0
      for _,card in ipairs(c) do
        if L.tailGeometryCorrection and card.title==L.tailGeometryCorrection then count=count+1 end
      end
      eq(count,0,"S07 motorised tail has no tail geometry choice")
    end
  end)
  case("S07.geometry-guidance",function()
    for _,locale in ipairs({"en","de"}) do
      local labels=load("i18n/"..locale..".lua").app.modules.helicopter_setup
      check(utf8.len(labels.geometryHint)<600,"S07 "..locale.." geometry help stays below 600 characters")
      for line in string.gmatch(labels.geometryHint,"[^\n]+") do
        check(utf8.len(line)<=200,"S07 "..locale.." geometry help lines stay within 200 characters")
      end
      check(string.find(labels.geometryHint,locale=="en" and "Leave it off" or "Aus lassen",1,true)~=nil,
        "S07 "..locale.." geometry help explains when to leave it off")
      check(string.find(labels.geometryHint,locale=="en" and "tail limits" or "Hecklimits",1,true)~=nil,
        "S07 "..locale.." geometry help asks for limit checks")
      local lines=0
      for line in string.gmatch(labels.geometryQuick,"[^\n]+") do
        lines=lines+1
        check(utf8.len(line)<=28,"S07 "..locale.." geometry summary fits the left column")
      end
      check(lines<=2,"S07 "..locale.." geometry summary uses at most two lines")
    end
  end)
  case("S07.servo-bands-and-reboot",function()
    local w=world();w.checks.unplugged=true
    local c=step(w,"servoType");c[1].rows[2].set(3)
    local s=w.data.servo_configurations.servos[0]
    eq(s.mid,760,"S07 narrow midpoint")
    eq(s.min,-250,"S07 narrow minimum")
    eq(s.max,250,"S07 narrow maximum")
    eq(s.rneg,250,"S07 narrow negative scale")
    eq(s.rpos,250,"S07 narrow positive scale")
    eq(s.rate,560,"S07 narrow rate")
    check(w.rebootPending,"S07 frame rate requires reboot")
    c[1].rows[2].set(2)
    eq(s.mid,1520,"S07 wide midpoint")
    eq(s.min,-700,"S07 wide minimum")
    eq(s.rpos,500,"S07 wide scale")
    s.mid=1530;c[1].rows[2].set(1)
    eq(s.mid,1530,"S07 same pulse band preserves centre")
    w.checks.unplugged=false;c[1].rows[2].set(3)
    eq(s.mid,1530,"S07 plugged servos block band change")
  end)
  case("S08.governor-feature-and-rpm",function()
    local w=world();w.data.feature_config.enabledFeatures=0;w.data.governor_config.gov_mode=3
    local c=step(w,"governor")
    eq(c[1].rows[1].get(),1,"S08 disabled feature overrides latent mode")
    eq(#c,1,"S08 Off omits the throttle type card")
    w.data.feature_config.enabledFeatures=1<<26;c=step(w,"governor")
    w.data.feature_config.enabledFeatures=0;c[2].rows[1].set(3)
    eq(w.data.feature_config.enabledFeatures & (1<<26),0,"S08 throttle edit never enables latent governor")
    w.data.governor_config.gov_throttle_type=1;c[1].rows[1].set(3)
    eq(w.data.governor_config.gov_throttle_type,0,"S08 leaving headspeed resets Switch throttle")
    c[2].rows[1].set(2)
    eq(w.data.governor_config.gov_throttle_type,0,"S08 unsupported Switch choice refused")
    w.data.motor_config.motor_pole_count_0=14;w.data.motor_config.motor_pwm_protocol=5;w.data.motor_config.use_dshot_telemetry=1
    check(w:fastRpm(),"S08 bidirectional DShot is fast RPM")
    w.data.motor_config.use_dshot_telemetry=0;w.data.esc_sensor_config.protocol=1
    check(not w:fastRpm(),"S08 serial ESC telemetry does not prove fast RPM")
  end)
  case("S11.motor-output-read-during-hold",function()
    local w=world();settle(w);w.step=11;local c=step(w,"throttle");w.cards=c;w.card=1
    w.data.motor_config.motor_pwm_protocol=0;c=step(w,"throttle");w.cards=c
    w.checks.escBlades=true;q.sent={}
    c[1].rows[2].press()
    check(w.motorHold~=nil,"S11 full throttle starts a motor hold")
    for _=1,300 do w:tick();h.pump();h.advance(1) end
    local reads,overrides,run,longest=0,0,0,0
    for _,m in ipairs(q.sent) do
      if m.command==104 then reads=reads+1;run=0 end
      if m.command==195 then overrides=overrides+1;run=run+1;if run>longest then longest=run end end
    end
    check(overrides>=4,"S11 the hold keeps refreshing the override")
    check(reads>=2,"S11 the motor output is read while the hold runs")
    check(longest<=2,"S11 no long run of overrides without an output read")
  end)
  case("HOST.open-suite-pages",function()
    local w=world();settle(w);w.step=2
    local opened
    w.openPage=function(id) opened=id end
    local rx=step(w,"receiver")
    eq(#rx[1].rows,4,"HOST receiver card keeps the unlock, protocol, USB and reboot without a diagnostics pointer")
    w.step=9
    local motor=step(w,"motor")
    local esc
    for _,row in ipairs(motor[1].rows) do if row.label==L.openEscTools then esc=row end end
    check(esc~=nil,"HOST a host that opens pages gets an ESC Tools button")
    esc.press();eq(opened,"esc_tools_menu","HOST the button opens ESC Tools")
    w.openPage=nil
    local plain=step(w,"motor")
    for _,row in ipairs(plain[1].rows) do check(row.label~=L.openEscTools,"HOST without openPage there is no button") end
  end)
  case("S09.new-esc-guidance",function()
    local w=world();settle(w);local card=step(w,"motor")[1]
    check(type(card.summary)=="string" and card.summary==L.motorQuick,
      "S09 motor card shows a short new ESC instruction beside full help")
    eq(#card.rows,3,"S09 protocol card keeps protocol, DShot and blades confirmation")
    local manifest=load("app/manifest.lua")
    for _,locale in ipairs({"en","de"}) do
      local b=load("i18n/"..locale..".lua");local s=b.app.modules.helicopter_setup
      local path=table.concat({b.app.header_configuration,b.app.modules.setup.name,b.app.modules.esc_motors.name,
        b.app.modules.esc_motors.esc_tools}," > ")
      check(string.find(s.motorHint,path,1,true)~=nil,"S09 "..locale.." help uses the Suite ESC Tools menu path")
      check(utf8.len(s.motorHint)<600,"S09 "..locale.." motor help stays below 600 characters")
      for _,entry in ipairs(manifest.menus.esc_tools_menu.pages) do
        check(string.find(s.motorHint,entry.title,1,true)~=nil,"S09 "..locale.." ESC help includes "..entry.title)
      end
      for _,key in ipairs({"motorQuick"}) do
        check(type(s[key])=="string","S09 "..locale.." "..key.." is translated")
        eq(load("app/pages/helicopter_setup/labels.lua")[key],"@i18n(app.modules.helicopter_setup."..key..")@",
          "S09 "..key.." is bound through labels")
      end
      if locale=="en" then
        for _,text in ipairs({"new ESC first","BEC voltage","motor timing","ESC governor off when using the FC governor",
          "direction","FC's ESC telemetry protocol matches"}) do
          check(string.find(s.motorHint,text,1,true)~=nil,"S09 ESC help explains "..text)
        end
      end
    end
    w.card,w.step=1,9;local help
    w.openHelp=function(text) help=text end
    local scene=h.view.new(w,{w=480,h=272},h.diagrams)
    while not scene:step() do end
    local shown=false
    for _,item in ipairs(scene.children) do
      if item.type=="label" and item.text==L.motorQuick then shown=true end
      if item.type=="button" and item.text=="?" then item.press() end
    end
    check(shown,"S09 new ESC instruction is rendered on the motor card")
    check(help and string.find(help,card.detail,1,true)~=nil,"S09 question mark opens the full ESC guidance")
  end)
  case("S09.bidirectional-dshot-switch",function()
    local w=world();settle(w);local c=step(w,"motor");local row=c[1].rows[2]
    eq(row.kind,"choice","S09 bidirectional DShot is an on/off choice")
    w.data.motor_config.motor_pwm_protocol=0
    check(not row.enabled(),"S09 bidirectional DShot is inactive for PWM")
    w.data.motor_config.motor_pwm_protocol=6;w.data.motor_config.use_dshot_telemetry=0
    check(row.enabled(),"S09 bidirectional DShot is offered for DShot")
    row.set(2);eq(w.data.motor_config.use_dshot_telemetry,1,"S09 On writes 1")
  end)
  case("S09-S12.versioned-esc-and-ports",function()
    local w=world();local oldVersion=rfsuite.session.apiVersion
    for _,v in ipairs({{version="12.09",off=10,telem=14},{version="12.10",off=11,telem=15}}) do
      rfsuite.session.apiVersion=v.version
      local e=w:motorProtocols();eq(e[#e][1],v.off,"S09 disabled wire ID "..v.version)
      eq(#w:telemetryProtocols(),v.telem,"S12 supported telemetry protocols "..v.version)
      for _,item in ipairs(e) do check(item[1]~=4,"S09 undefined protocol never offered") end
    end
    rfsuite.session.apiVersion=oldVersion
    w.data.serial_config.port_1_function_mask=1024|1
    local c=step(w,"escTelemetry");c[1].rows[1].set(1)
    eq(w.data.serial_config.port_1_function_mask,1,"S12 telemetry off frees only its function")
    w.data.motor_config.motor_pwm_protocol=9;w:fixMotor()
    eq(w.data.esc_sensor_config.protocol,0,"S09 Castle protocol fix")
    check((w.data.feature_config.enabledFeatures & (1<<27))~=0,"S09 Castle feature remains enabled")
    check(not w:canDetect(1024),"S12 Castle has no wiring trial")
    w.data.motor_telemetry={motors={{voltage=0,temperature=0,current=0,rpm=0}}}
    eq(c[4].rows[3].get(),L.noTelemetry,"S12 zero data is missing telemetry")
    w.data.motor_telemetry.motors[1].voltage=24000
    eq(c[4].rows[3].get(),L.receiving,"S12 voltage proves reception")
  end)
  case("S10.connection-gate",function()
    local w=world();w.rebootPending=true
    step(w,"connect");check(not w.validate(),"S10 reboot requires unplugged confirmation")
    w.checks.unplugged=true;check(w.validate(),"S10 reboot gate allows confirmed unplugged state")
    w.rebootPending=nil;w.data.motor={motor_1=0,motor_2=0}
    step(w,"connect");check(not w.validate(),"S10 missing main motor blocks connection gate")
    w.data.motor.motor_1=1000;w.data.motor.motor_2=1000
    w.checks.connected,w.checks.blades=true,true
    check(w.validate(),"S10 required outputs and physical answers allow next")
  end)
  case("S11.motor-hold-and-calibration",function()
    local w=world();w.data.motor_config.motor_pwm_protocol=0;w.bladesOff=true;w.data.motor={motor_1=1000,motor_2=1000}
    w:spin(0,1);check(w.motorHold==nil,"S11 PWM calibration required")
    eq(w.message,L.calibrateEscFirst,"S11 explains blocked spin")
    w.calibratedEsc=true;w:spin(0,1)
    eq(w.motorHold.value,100,"S11 initial 10 percent command")
    eq(w.motorHold.untilAt-getTime(),1500,"S11 hold bounded to fifteen seconds")
    w:stopMotor();check(w.motorHold==nil,"S11 release stops desired output")
    w.bladesOff=false;w:spin(0,1);check(w.motorHold==nil,"S11 blades acknowledgement required")
    local c=step(w,"throttle");c[1].rows[1].set(2);c[1].rows[2].press()
    eq(w.motorHold.value,1000,"S11 calibration high command")
    w.data.motor={motor_1=1994};check(not c[2].rows[2].enabled(),"S11 actual high output required")
    w.data.motor.motor_1=2000;check(c[2].rows[2].enabled(),"S11 actual full output enables low transition")
    c[2].rows[2].press();w.data.motor.motor_1=1000;c[3].rows[1].press()
    check(w.calibratedEsc,"S11 low calibration completion")
    w.step=10;w:navigate(11,1)
    check(not w.calibratedEsc,"S11 revisiting requires fresh ESC procedure")
  end)
  case("S13.servo-direction-centre",function()
    local w=world();w.wideScreen=false;local c=step(w,"servos");c[1].enter()
    eq(w.holds.servo0.value,0,"S13 centre held on entry")
    local one,two=c[1].grid[1],c[1].grid[2]
    one.test();eq(w.holds.servo0.value,400,"S13 +20 degree servo test")
    two.test();eq(w.holds.servo0.value,0,"S13 testing another servo re-centres the first")
    eq(w.holds.servo1.value,400,"S13 one servo tested at a time")
    two.test();eq(w.holds.servo1.value,0,"S13 test toggles to centre")
    local s=w.data.servo_configurations.servos[0];s.flags=6;one.test();one.down()
    eq(s.flags,7,"S13 reverse preserves other flags")
    check(one.testing(),"S13 reverse keeps the test running")
    one.up();eq(w.holds.servo0.value,0,"S13 affirmative answer centres tested servo")
    check(w.checks.servoUp0,"S13 answer recorded")
    s.mid=1520;for _=1,50 do one.nudge(10) end
    eq(s.mid,1920,"S13 centre nudge stays inside the pulse band")
    eq(one.status(),L.servoFar,"S13 large offset explains mechanical remedy")
    for _,col in ipairs(c[1].grid) do w.checks["servoUp"..col.index]=true end
    for _,servo in pairs(w.data.servo_configurations.servos) do servo.mid=servo.mid>860 and 1520 or 760 end
    check(w.validate(),"S13 confirmed directions and centres within 100 us complete the step")
    w.data.servo_configurations.servos[3].mid=1650
    check(not w.validate() and w.message==L.servoFar,"S13 a far tail centre keeps the step open")
    w.data.servo_configurations.servos[3].mid=1520;w.checks.servoUp1=nil
    check(not w.validate(),"S13 an unconfirmed direction keeps the step open")
    eq(#c,2,"S13 compact screens give the tail a card of its own")
    w.wideScreen=true;w.data.mixer_config.swash_type=2;local wide=step(w,"servos")
    eq(#wide,1,"S13 large screens show every servo on one page")
    eq(#wide[1].grid,4,"S13 the tail is the fourth row on large screens")
    eq(wide[1].grid[1].role,L.roleCentreLine,"S13 each servo names its role")
  end)
  case("CORE.prerequisite-sensors",function()
    local w=world();settle(w)
    w.modelPreparationRequired,w.modelPreparationDone,w.activeModelName=true,nil,"Heli"
    check(w:buildModelPreparation(),"CORE the model card is built")
    local rows=w.cards[1].rows
    eq(rows[3].label,L.fcStatusSensor,"CORE the model card checks the FC status sensor up front")
    eq(rows[4].label,L.fcConfigSensor,"CORE the model card checks the FC config sensor up front")
    w.systemStatus,w.systemConfig,w.systemReads=nil,nil,1
    eq(rows[3].get(),L.sensorChecking,"CORE a sensor not read yet is still being checked")
    w.systemReads=4;w.systemStatus={word=1}
    eq(rows[3].get(),L.sensorLive,"CORE a decoded status word reads as live")
    eq(rows[4].get(),L.sensorMissing,"CORE a sensor without value after four reads reads as missing")
    check(string.find(w.cards[1].detail,L.sensorsHint,1,true)~=nil,"CORE the help says where to add a missing sensor")
    w.checks.modelReady=true;w.systemStatus,w.systemConfig={word=0},nil;w:next()
    check(w.modelPreparationCard and w.message==L.sensorsRequired,"CORE a missing FC state sensor keeps the steps closed")
    w.systemConfig={word=0};w:next()
    check(not w.modelPreparationCard,"CORE both FC state sensors live open the steps")
    -- The FC side: its telemetry list carries 120 and 121, or the card offers to add them.
    local buf={};for i=1,52 do buf[i]=0 end;buf[13],buf[14]=3,4
    w.data.telemetry_config={buffer=buf};for i=1,40 do w.data.telemetry_config["telem_sensor_slot_"..i]=buf[12+i] end
    eq(w:fcSensorsListed(),false,"CORE an FC list without 120/121 reads as missing")
    w.modelPreparationRequired,w.modelPreparationDone=true,nil;w:buildModelPreparation()
    local add=w.cards[1].rows[5]
    eq(add.label(),L.addFcSensors,"CORE the model card offers to add the sensors to the FC")
    check(add.enabled(),"CORE the add button is offered while the FC lacks them")
    q.sent={};add.press();drain(w)
    local written
    for _,m in ipairs(q.sent) do if m.command==74 then written=m.payload end end
    check(written and written[13]==3 and written[14]==4 and written[15]==120 and written[16]==121,
      "CORE adding writes the FC's own buffer with 120/121 in the first free slots")
    check(w:fcSensorsListed()==true and add.label()==L.fcSensorsListed,"CORE after adding the card reads both listed")
  end)
  case("S14-S15.axis-direction-and-trims",function()
    local w=world();local c=step(w,"direction");c[1].enter()
    for _,i in ipairs({1,2,4}) do eq(w.holds["mixer"..i].value,2502,"S14 passthrough axis "..i) end
    eq(c[1].rows[2].get(),L.rightDown,"S14 roll expectation stays visible beside the controls")
    eq(c[1].rows[1].label,L.inputRoll,"S14 the first row names the input the check needs")
    w.data.rc_command={commands={-225,0,0,500}}
    eq(c[1].rows[1].get(),string.format(L.stickNow,L.dirLeft,45),"S14 the stick shows its direction and travel")
    eq(c[3].rows[1].get(),string.format(L.stickNow,L.dirUp,100),"S14 collective up reads as up")
    w.data.rc_command={commands={10,0,0,0}}
    eq(c[1].rows[1].get(),L.stickCentre,"S14 a stick near centre reads as centre")
    w.data.rc_command={commands={0,0,300,0}}
    local tailCards=step(w,"tail")
    eq(tailCards[2].rows[1].label,L.inputYaw,"S17 the tail direction card names the yaw input")
    eq(tailCards[2].rows[1].get(),string.format(L.stickNow,L.dirRight,60),"S17 yaw right reads as right")
    tailCards[3].rows[1].press()
    eq(tailCards[3].rows[1].label(),L.releaseTest,"S17 a held tail end shows release on its button")
    eq(tailCards[3].rows[2].label(),L.holdNegative22,"S17 the other end keeps its hold caption")
    eq(c[1].summary,L.rearCheck,"S14 left/right is defined from behind the helicopter")
    w.checks.control1=true;local before=w.data.mixer_input.inputs[1].rate;c[1].rows[3].press()
    eq(w.data.mixer_input.inputs[1].rate,-before,"S14 reverse input scale")
    check(not w.checks.control1,"S14 reversal invalidates previous physical answer")
    c=step(w,"level");c[1].enter()
    eq(c[1].rows[1].label,L.roll,"S15 first trim is roll axis")
    eq(c[1].rows[2].label,L.pitch,"S15 second trim is pitch axis")
    eq(c[1].rows[3].label,L.collective,"S15 third trim is collective axis")
    for i=1,3 do c[1].rows[i].set(i*10) end
    c[1].rows[4].press()
    for i=0,2 do eq(w.data.mixer_config["swash_trim_"..i],0,"S15 reset trim "..i) end
  end)
  case("S16.pitch-calibration-limits-fullstick",function()
    local w=world();local c=step(w,"pitch");c[2].enter()
    w.data.mixer_input.inputs[1].rate=-1000;w.data.mixer_input.inputs[2].rate=1000
    c[2].rows[1].press();eq(w.holds.mixer2.value,750,"S16 9-degree test command")
    eq(w.holds.mixer1.value,0,"S16 other cyclic axis held zero")
    c[2].rows[2].set(180);c[2].rows[3].press()
    eq(w.data.mixer_input.inputs[1].rate,-500,"S16 correction preserves roll sign")
    eq(w.data.mixer_input.inputs[2].rate,500,"S16 correction from measured pitch axis")
    c[2].rows[1].press();eq(w.holds.mixer2.value,0,"S16 test toggles off")
    c[3].rows[1].set(120)
    eq(w.data.mixer_input.inputs[1].min,-1000,"S16 cyclic negative limit")
    eq(w.data.mixer_input.inputs[2].max,1000,"S16 cyclic positive limit")
    c[3].rows[3].set(360);eq(w.data.mixer_config.swash_pitch_limit,3000,"S16 total 36 degree range")
    w.data.rc_tuning.rates_type=0
    check(not c[4].rows[1].enabled(),"S16 unsupported rate type offers no numeric full-stick edit")
  end)
  case("S17.tail-servo-and-motor-variants",function()
    local w=world();w.data.mixer_config.tail_rotor_mode=0
    local c=step(w,"tail");c[1].enter();eq(w.holds.mixer3.value,0,"S17 neutral yaw")
    c[1].rows[1].set(-100);eq(w.data.mixer_config.tail_center_trim,-417,"S17 centre trim conversion")
    c[3].rows[1].press();eq(w.holds.mixer3.value,917,"S17 +22 degree command")
    c[3].rows[1].press();eq(w.holds.mixer3.value,0,"S17 test toggles to neutral")
    c[4].rows[2].press();eq(w.holds.mixer3.value,-2500,"S17 -60 degree command")
    c[4].rows[3].set(600);eq(w.data.mixer_input.inputs[3].min,-2500,"S17 clockwise stop units")
    w.data.mixer_input.inputs[3].rate=-250;c[3].rows[3].set(500)
    eq(w.data.mixer_input.inputs[3].rate,-500,"S17 yaw calibration preserves sign")
    w:release();drain(w);w.data.mixer_config.tail_rotor_mode=2;c=step(w,"tail")
    eq(#c[1].rows,4,"S17 bidirectional reverse hold available")
    w.bladesOff=true;w.data.motor={motor_1=1000,motor_2=1000};c[1].rows[4].press();eq(w.motorHold.value,-100,"S17 reverse motor command")
    c[1].rows[4].release();check(w.motorHold==nil,"S17 reverse release stops")
    eq(c[2].rows[1].max,255,"S17 idle U8 ceiling")
  end)
  case("S18-S19.physical-check-and-summary",function()
    local w=world();w.data.mixer_config.tail_rotor_mode=0;local c=step(w,"gyro")
    eq(#c,3,"S18 servo tail includes yaw gyro check")
    check(not w.validate(),"S18 gyro response never auto-confirmed")
    c[1].rows[2].press();eq(w.step,1,"S18 wrong response returns to orientation")
    w.data.mixer_config.tail_rotor_mode=2;c=step(w,"gyro")
    eq(#c,2,"S18 motor tail omits servo yaw check")
    w.data.motor_config.motor_pwm_protocol=9;c=step(w,"finish")
    eq(c[1].rows[3].get(),L.bidirectional,"S19 tail summary distinguishes bidirectional")
    eq(c[2].rows[3].get(),"Castle Link","S19 Castle telemetry is not Off")
    check(type(c[1].rows[1].get())=="string","S19 swash summary is readable")
    check(not w.validate(),"S19 final physical acknowledgement required")
  end)
  case("CORE.loading-scene",function()
    for _,size in ipairs({{320,240},{480,272},{480,320},{800,480}}) do
      local page=load("app/pages/helicopter_setup/page.lua")
      local builds=0
      local ctx={w=size[1],h=size[2],children={},requestRebuild=function() builds=builds+1 end}
      page.build(ctx);page.wakeup(ctx)
      ctx.children={};page.build(ctx)
      eq(#ctx.children,7,"CORE loading has title hint progress and Back")
      local bar=ctx.children[6];check(type(bar.pts)=="function","CORE loading progress is reactive")
      local before=bar.pts()[2][1]
      page.wakeup(ctx);page.wakeup(ctx)
      check(bar.pts()[2][1]>before,"CORE loading progress moves without a rebuild")
      eq(builds,1,"CORE loading scene is published once")
      check(ctx.children[7].press~=nil,"CORE loading can return to Suite")
      for _,node in ipairs(ctx.children) do
        if node.y then check(node.y>=0 and node.y+(node.h or 0)<=ctx.h,"CORE loading nodes fit screen") end
      end
      page.onClose()
    end
  end)
  case("REVIEW.cleanup-single-attempt",function()
    -- Use the real queue and the messages produced by each cleanup path.
    local Queue=load("tasks/msp/queue.lua")
    for _,kind in ipairs({"servo","mixer","motor","trial"}) do
      for _,replyAt in ipairs({1,0}) do
        local w=world();settle(w)
        if kind=="trial" then
          w.bus.apis.esc_sensor_trial=h.api("esc_sensor_trial")
          w.trial={api="esc_sensor_trial"};w:stopTrial()
        else
          if kind=="motor" then w.motorHold={index=0}
          else w.holds={{kind=kind,index=kind=="servo" and 0 or 1}} end
          w:release()
        end
        local message=table.remove(q.messages,1)
        check(message and message.client=="helicopter-cleanup","REVIEW OFF uses cleanup owner")
        eq(message.maxRetries,0,"REVIEW "..kind.." OFF must disable retries")
        local sends,replies,errors=0,0,0
        local originalReply,originalError=message.processReply,message.errorHandler
        message.processReply=function(m,b) replies=replies+1;if originalReply then originalReply(m,b) end end
        message.errorHandler=function(m,reason) errors=errors+1;if originalError then originalError(m,reason) end end
        local queue=Queue.new({sendRequest=function() sends=sends+1;return true end,
          pollReply=function() if replyAt>0 and sends==replyAt then return message.command,{} end end})
        queue._simDetectDone=true;queue._simDetected=false
        local started=getTime();queue:add(message);queue:processQueue()
        eq(sends,1,"REVIEW OFF first attempt is sent")
        h.advance(199);queue:processQueue();eq(sends,1,"REVIEW OFF waits for the two-second timeout")
        for _=1,210 do
          h.advance(1);queue:processQueue()
          if queue:isProcessed() then break end
        end
        eq(sends,1,"REVIEW "..kind.." OFF is sent exactly once")
        eq(replies,replyAt>0 and 1 or 0,"REVIEW OFF acknowledges once only after a reply")
        eq(errors,replyAt>0 and 0 or 1,"REVIEW OFF fails once when its only reply is lost")
        check(queue:isProcessed(),"REVIEW OFF queue settles")
        if replyAt==0 then check(getTime()-started>=200,"REVIEW single OFF attempt gets its full timeout") end
        if kind~="trial" then
          eq(w.cleanupPending,0,"REVIEW cleanup accounting settles after one attempt")
          check((w.cleanupFailed==true)==(replyAt==0),"REVIEW a lost OFF reply fails cleanup closed")
          if replyAt==0 then
            -- The controller consumes the queue failure on its next frame.
            w:tick()
            check(not w:usable() and w.locked,"REVIEW unanswered OFF keeps edits and arming locked")
          end
        end
      end
    end
  end)
  case("REVIEW.cleanup-before-unlock",function()
    local w=world();settle(w)
    if h.mutation=="cleanup-unlock" then
      w.close=function(self)
        self:release()
        -- Former emergency teardown queued the unlock outside the controller.
        q:add({command=99,payload={0},client="helicopter-cleanup",isWrite=true,
          processReply=function() self.active=false end})
      end
    end
    w:hold("servo",0,0);drain(w)
    h.setFailCommand(193);q.sent={}
    w:close();drain(w)
    -- Observe raw emergency messages as well as the controller's own jobs.
    for _=1,3 do w:tick();h.pump();h.advance(1) end
    check(w.error and w.cleanupFailed and w.active,"REVIEW failed OFF retains the active lock")
    for _,m in ipairs(q.sent) do
      check(m.command~=99 or m.payload[1]~=0,"REVIEW failed cleanup never re-enables arming")
    end
    h.setFailCommand(nil);w:retry();drain(w)
    check(not w.error and w.locked and not w.cleanupFailed,"REVIEW explicit retry confirms all outputs OFF")
    q.sent={};w:close();drain(w)
    check(not w.active,"REVIEW successful cleanup permits normal close")
    eq(q.sent[#q.sent].command,99,"REVIEW lock release follows cleanup")
    eq(q.sent[#q.sent].payload[1],0,"REVIEW normal close restores arming last")
  end)
  case("REVIEW.abnormal-close",function()
    q.messages,q.sent={},{}
    local page=load("app/pages/helicopter_setup/page.lua")
    local ctx={w=480,h=272,children={},menu={getCurrentMenuId=function() return "helicopter_setup_page" end},
      requestRebuild=function() end}
    page.build(ctx)
    for _=1,1000 do page.wakeup(ctx);h.pump();h.advance(1) end
    local locked=false
    for _,m in ipairs(q.sent) do if m.command==99 and m.payload[1]==1 then locked=true end end
    check(locked,"REVIEW abnormal-close control first disables arming")
    q.sent={};page.onClose()
    for _=1,30 do h.measure("cleanup reply",h.pump) end
    for _,m in ipairs(q.sent) do check(m.command~=99,"REVIEW external teardown cannot release the arming lock") end
    eq(_G.rfsuite.session.helicopterSetupRecovery,"test-board","REVIEW external teardown retains a per-FC recovery marker")
    local w=world();settle(w)
    w.modelPreparationRequired=true;w.modelPreparationDone=true;w:buildModelPreparation()
    check(w.recoveryCard,"REVIEW recovery precedes remembered model preparation")
    w:next();check(w.recoveryRequired,"REVIEW recovery requires a fresh physical acknowledgement")
    w.checks.recoveryPowerCycle=true;w:next();w:tick()
    check(not w.recoveryRequired and not _G.rfsuite.session.helicopterSetupRecovery,"REVIEW confirmed power cycle clears recovery for this FC")
  end)
  case("REVIEW.armed-frame",function()
    local page=load("app/pages/helicopter_setup/page.lua")
    local banner={type="label",text="ARMED",x=0,y=0,h=24}
    local ctx={x=0,y=24,w=480,h=248,children={banner},armed=true,requestRebuild=function() end}
    page.build(ctx);page.wakeup(ctx);ctx.children={banner};page.build(ctx)
    eq(ctx.children[1],banner,"REVIEW page retains the host ARMED banner")
    local body=ctx.children[2]
    eq(body.y,24,"REVIEW owned frame starts below ARMED")
    eq(body.h,248,"REVIEW frame leaves room for ARMED")
    check(body.children[1].type=="rectangle","REVIEW page background stays inside its body")
    page.onClose()
  end)
  case("REVIEW.independent-timeout-probes",function()
    h.setLegacyMixer(true)
    local w=world();settle(w)
    if h.mutation=="shared-timeout-probe" then w.timedMixer=w.timedServo end
    check(w.timedServo and not w.timedMixer,"REVIEW servo capability cannot authorize mixer timeouts")
    w:hold("mixer",4,0);drain(w)
    local mixer
    for _,m in ipairs(q.sent) do if m.command==191 then mixer=m end end
    eq(#mixer.payload,3,"REVIEW legacy mixer hold stays three bytes")
    w:release();drain(w);w:hold("servo",0,0);drain(w)
    local servo
    for _,m in ipairs(q.sent) do if m.command==193 then servo=m end end
    eq(#servo.payload,5,"REVIEW independently proven servo uses its timeout")
    h.setLegacyMixer(false)
  end)
  case("REVIEW.pitch-discard",function()
    local w=world();settle(w);w.step=16
    w.data.rc_tuning.rates_type=6;w.saved.rc_tuning.rates_type=6
    local baseline=H.collective(w.saved.rc_tuning)
    local c=step(w,"pitch");c[4].rows[1].set(150)
    check(w.pitchFullChanged,"REVIEW collective edit is staged")
    if h.mutation=="pitch-discard" then
      local original=w.discard
      w.discard=function(self,after)
        local draft=self.pitchFull
        return original(self,function() self.pitchFull,self.pitchFullChanged=draft,true;after() end)
      end
    end
    w:discard(function() end);drain(w)
    c=step(w,"pitch")
    check(not w.pitchFullChanged and w.pitchFull==baseline,"REVIEW discarded pitch draft cannot return")
  end)
  case("REVIEW.back-preserves-commit",function()
    local w=world();settle(w);w.step=16;w.card=1
    local applied=0
    w.commit=function() applied=applied+1;w:write("rc_tuning",w.data.rc_tuning) end
    if h.mutation=="back-commit" then w.back=function(self) self:navigate(self.step-1,1) end end
    w:touch("rc_tuning");w:back()
    check(w.step==16 and w.confirmExit,"REVIEW Back asks before leaving a dirty step")
    w:resolveExit(true);drain(w)
    check(applied==1 and w.step==15 and w.active,"REVIEW Back Save runs the originating commit")
    local written=false
    for _,m in ipairs(q.sent) do if m.command==h.api("rc_tuning").writeCommand then written=true end end
    check(written,"REVIEW deferred profile changes reach the FC")
  end)
  case("REVIEW.fresh-blade-confirmation",function()
    local w=world();settle(w);w.step=10;w.checks.blades=true
    w.data.motor_config.motor_pwm_protocol=0;w:navigate(11,1)
    local c=step(w,"throttle")
    if h.mutation=="stale-blades" then w.checks.escBlades=w.checks.blades end
    c[1].rows[2].press()
    check(not w.motorHold,"REVIEW ESC calibration requires its own blade confirmation")
    w.checks.blades=true;w:load()
    check(not w.checks.blades,"REVIEW reload invalidates physical confirmations")
  end)
  case("CORE.status-wait-and-retry",function()
    local w=world();settle(w)
    w.statusAt=getTime()-301;w:tick()
    check(not w.error and w.statusWaiting,"CORE idle expiry waits for fresh status")
    check(not w:usable(),"CORE waiting status blocks all edits")
    drain(w)
    check(not w.error and w:usable() and not w.statusWaiting,"CORE idle status reacquisition completes")
    w.statusAt=getTime()-301;w:fail("status",L.stale)
    w:retry()
    if h.mutation=="retry-stale" then w.locked=true end
    check(not w.locked and not w:usable(),"CORE retry requires new arming lock proof")
    drain(w)
    check(not w.error and w.locked and w:usable(),"CORE retry escapes stale timestamp")
    w=world();settle(w)
    w.statusAt=getTime()-301;w:tick()
    local message=q.messages[#q.messages]
    check(message and message.command==101,"CORE waiting requests actual STATUS")
    message.errorHandler(message,"timeout");w:tick()
    check(w.error and not w:usable(),"CORE actual STATUS timeout remains an error")
    w:retry();drain(w)
    check(not w.error and w:usable(),"CORE timeout retry reacquires the lock")
    w.statusAt=getTime()-301;w:write("board_alignment_config",w.data.board_alignment_config)
    w:tick()
    check(w.error~=nil,"CORE expiry during pending mutation still fails closed")
  end)
  case("CORE.edit-held-across-native-list",function()
    -- A native list holds the page without a wakeup; the value arrives with expired STATUS.
    local w=world();settle(w)
    if h.mutation=="drop-stale-edit" then
      w.applyEdit=function(self,fn) if self:usable() then fn() end end
    end
    local c=step(w,"servoType");local row=(function() for _,x in ipairs(c) do if x.title==L.geometryCorrection then return x end end end)().rows[1]
    local servos=w.data.servo_configurations.servos
    for _,i in ipairs({0,1,2}) do servos[i].flags=0 end
    w.statusAt=getTime()-301
    w:applyEdit(function() row.set(2) end)
    eq(servos[0].flags,0,"CORE an expired STATUS does not authorize the edit at once")
    drain(w)
    eq(servos[0].flags,2,"CORE an edit made while a list was open applies after fresh STATUS")
    check(not w.error and w:usable(),"CORE the held edit leaves the page usable")
    w.statusAt=getTime()-301
    w:applyEdit(function() row.set(1) end)
    w:fail("status",L.stale);drain(w)
    eq(servos[0].flags,2,"CORE a failure drops the held edit")
    -- The scene control routes through the same path.
    w.error=nil;w.locked=true;settle(w);w.cards=c;for i,x in ipairs(c) do if x.title==L.geometryCorrection then w.card=i end end
    local job=h.view.new(w,{w=800,h=480},h.diagrams);while not job.done do job:step() end
    local choice
    for _,item in ipairs(job.children) do if item.type=="choice" and item.title==L.geometryCorrection then choice=item end end
    check(choice~=nil,"CORE geometry choice is on the scene")
    if choice then
      w.statusAt=getTime()-301;choice.set(1)
      eq(servos[0].flags,2,"CORE a scene edit waits for fresh STATUS")
      drain(w)
      eq(servos[0].flags,0,"CORE a scene edit made while a list was open applies")
    end
  end)
  case("CORE.save-writes-changed-rows-only",function()
    local w=world();settle(w)
    local ranges=w.data.adjustment_ranges.adjustment_ranges
    check(#ranges>10,"CORE fixture carries a full adjustment table")
    ranges[3].adjMin=(ranges[3].adjMin or 0)+1;w:touch("adjustment_ranges")
    q.sent={};w:save();drain(w)
    local rows={}
    for _,m in ipairs(q.sent) do if m.command==53 then rows[#rows+1]=m.payload[1] end end
    eq(table.concat(rows,","),"2","CORE save rewrites only the changed adjustment row")
    local modes=w.data.mode_ranges.mode_ranges
    modes[2].auxChannelIndex=(modes[2].auxChannelIndex or 0)+1;w:touch("mode_ranges")
    q.sent={};w:discard();drain(w)
    rows={}
    for _,m in ipairs(q.sent) do if m.command==35 then rows[#rows+1]=m.payload[1] end end
    eq(table.concat(rows,","),"1","CORE discard restores only the changed mode row")
  end)
  case("CORE.live-servo-edit-writes-that-servo",function()
    local w=world();settle(w)
    local s=w.data.servo_configurations.servos
    s[1].mid=s[1].mid+5;w:touch("servo_configurations",false,true)
    q.sent={};drain(w)
    local rows={}
    for _,m in ipairs(q.sent) do if m.command==212 then rows[#rows+1]=m.payload[1] end end
    eq(table.concat(rows,","),"1","CORE a live edit of one servo writes only that servo")
  end)
  case("CORE.card-result-does-not-carry-over",function()
    local w=world();settle(w);w.step=3;w.cards=step(w,"modes");w.card=1
    w.message=string.format(L.switchDetected,5,1500,2100)
    w:navigate(3,2)
    eq(w.message,L.ready,"CORE a learned-switch result does not label the next card")
    w.message=L.pendingSave;w:navigate(3,3)
    eq(w.message,L.pendingSave,"CORE the unsaved-change reminder carries over")
  end)
  case("CORE.status-expiry-during-pending-request",function()
    local w=world();settle(w);w:hold("servo",0,400)
    w.bus:add({api="rc"});w.bus:tick()
    if h.mutation=="stale-status" then
      local original=w.tick
      w.tick=function(self)
        if self.ready and getTime()-(self.statusAt or 0)>300 then return end
        return original(self)
      end
    end
    -- A live pending transaction cannot hide an expired arming status.
    w.statusAt=getTime()-301;w:tick()
    check(w.error~=nil and next(w.holds)==nil,"CORE stale status releases holds before bus wait")
    check(not w:usable(),"CORE stale status disables editing")
    local off=false
    for _,m in ipairs(q.messages) do if m.command==193 and m.payload[2]==209 and m.payload[3]==7 then off=true end end
    check(off,"CORE expired status queues legacy OFF")
  end)
  case("CORE.wiring-success-polling-and-teardown",function()
    local w=world();settle(w);w.data.serial_config.port_1_function_mask=1024
    w.trial={api="esc_sensor_trial",untilAt=getTime()+6000,due=0}
    w.bus.apis.esc_sensor_trial=h.api("esc_sensor_trial")
    w:trialReply({state=2,half_duplex=1,pin_swap=0})
    check(w.trial and w.trial.success,"CORE successful wiring remains live for inspection")
    check(not w:trialTick(),"CORE successful trial yields to live polling")
    eq(w.data.esc_sensor_config.half_duplex,1,"CORE detected half-duplex staged")
    w:release()
    check(w.trial==nil,"CORE leaving cancels trial owner")
    local stop=false
    for _,m in ipairs(q.messages) do if m.command==0x5F0C and m.payload[1]==2 and m.client=="helicopter-cleanup" then stop=true end end
    check(stop,"CORE stop survives page transport teardown")
    w.trial={api="esc_sensor_trial",untilAt=getTime()-1,due=0};w:trialTick()
    eq(w.message,L.detectTimeout,"CORE trial deadline is explicit")
  end)
  case("VISUAL.line-visible-before-points",function()
    -- EdgeTX evaluates a line's visible getter before its points getter, and a line with a points
    -- getter has no native object until then: hiding it on that first pass faults the radio.
    local w=world();settle(w);local diagrams=load("app/pages/helicopter_setup/diagrams.lua")
    local view=load("app/pages/helicopter_setup/view.lua")
    local names={"sensors","receiver","modes","profiles","rates","swash","servoType","governor","motor",
      "connect","throttle","escTelemetry","servos","direction","level","pitch","tail","gyro","finish"}
    local checked,kinds=0,{}
    for index,name in ipairs(names) do
      if name=="servoType" then
        -- A matching preset hides the pulse wave at build, the case the first-pass rule protects.
        for _,s in pairs(w.data.servo_configurations.servos) do s.rate,s.mid=50,1520 end
      end
      w.step=index;local cards=step(w,name)
      if name=="rates" then for _,p in ipairs(w.rateProfiles) do w.rateStyles[p]=2 end end
      for card=1,#cards do
        w.cards,w.card=cards,card
        local job=view.new(w,{w=480,h=320},diagrams)
        while not job.done do job:step() end
        for _,item in ipairs(job.children) do
          if item.type=="line" and type(item.pts)=="function" and type(item.visible)=="function" then
            checked=checked+1;kinds[cards[card].art or "?"]=true
            check(item.visible()==true,"VISUAL a line with a points getter is visible before its first points pass: "..name.." card "..card)
            item.pts()
          end
        end
      end
    end
    check(checked>0 and kinds.pulses and kinds.attitude,"VISUAL the first-pass rule covered the pulse wave and the attitude view")
  end)
  case("VISUAL.cached-reactivity",function()
    local w=world();local diagrams=load("app/pages/helicopter_setup/diagrams.lua")
    local view=load("app/pages/helicopter_setup/view.lua")
    local function scene(name,card)
      w.cards=step(w,name);w.card=card or 1
      local job=view.new(w,{w=320,h=240},diagrams)
      while not job.done do job:step() end
      return job.children
    end
    local function signature(children)
      local parts={}
      for _,item in ipairs(children) do
        if type(item.pts)=="function" then
          for _,p in ipairs(item.pts()) do parts[#parts+1]=p[1]..","..p[2] end
        end
        if type(item.file)=="function" then parts[#parts+1]=item.file() end
      end
      return table.concat(parts,";")
    end
    local s=scene("direction");w.data.rc_command={commands={-500,0,0,0,0}};local a=signature(s)
    w.data.rc_command.commands[1]=500
    check(a~=signature(s),"VISUAL command changes existing stick marker")
    s=scene("rates");w.rateStyles[w.rateProfiles[1]]=1;a=signature(s);w.rateStyles[w.rateProfiles[1]]=3
    check(a~=signature(s),"VISUAL selected style changes existing rate curve")
    s=scene("swash",2);w.data.mixer_config.main_rotor_dir=0;a=signature(s);w.data.mixer_config.main_rotor_dir=1
    check(a~=signature(s),"VISUAL rotor direction changes the existing picture")
  end)
  case("VISUAL.configurator-pictures",function()
    local w=world();settle(w)
    local prefix="/SCRIPTS/TOOLS/rfsuite-core/app/pages/helicopter_setup/gfx/dark/"
    local function scene(name,index)
      w.cards=step(w,name);w.card=index or 1
      local job=h.view.new(w,{w=480,h=272},h.diagrams)
      while not job:step() do end
      local picture,images
      images=0
      for _,item in ipairs(job.children) do
        if item.type=="image" then picture=item;images=images+1 end
      end
      eq(images,1,"VISUAL "..name.." card "..w.card.." has one picture")
      return job,picture
    end
    local function expect(picture,name)
      eq(picture and picture.file(),prefix..name..".png","VISUAL exact picture "..name)
    end
    for _,spec in ipairs({
      {"direction",{"swash-motion-roll","swash-motion-pitch","swash-motion-collective"}},
      {"gyro",{"gyro-roll","gyro-pitch","gyro-yaw"}},
      {"tail",{"tail-servo","tail-servo-move"}},
      {"pitch",{"pitch-9","pitch-9"}},
      {"level",{"swash-motion-level","pitch-0"}},
      {"connect",{"servo"}}
    }) do
      w.data.mixer_config.tail_rotor_mode=0
      for index,name in ipairs(spec[2]) do
        local job,picture=scene(spec[1],index);expect(picture,name)
        if spec[1]=="direction" or (spec[1]=="tail" and index==2) then
          local marker
          for _,item in ipairs(job.children) do
            if item.type=="line" and type(item.pts)=="function" then marker=item end
          end
          check(marker~=nil,"VISUAL picture retains the live input meter")
          if marker then
            local axis=spec[1]=="tail" and 3 or ({1,2,4})[index]
            w.data.rc_command={commands={0,0,0,0,0}}
            w.data.rc_command.commands[axis]=-500;local left=marker.pts()[1][1]
            w.data.rc_command.commands[axis]=500
            check(marker.pts()[1][1]>left,"VISUAL meter follows the card's input axis")
            expect(picture,name)
          end
        end
      end
    end
    local job,picture=scene("rates");local count=#job.children
    local profile=w.rateProfiles[1]
    w.rateStyles,w.rateMatched={},{}
    check(not picture.visible(),"VISUAL unmatched rates show the existing sketch")
    for style,name in ipairs({"rate-trainer-cyclic","rate-sport-cyclic","rate-3d-cyclic"}) do
      w.rateMatched[profile]=style;expect(picture,name)
      check(picture.visible(),"VISUAL matched rates show their style picture")
      eq(#job.children,count,"VISUAL rate picture changes retain the scene")
    end
    w.rateStyles[profile]=1;expect(picture,"rate-trainer-cyclic")
    w.rateStyles={};w.rateMatched={}
    check(not picture.visible(),"VISUAL removing the match restores the rates sketch")
    job,picture=scene("motor",2);expect(picture,"motor-gears")
    w.rebootPending=true;job,picture=scene("connect");expect(picture,"servo");w.rebootPending=nil
    w.data.mixer_config.tail_rotor_mode=1
    job,picture=scene("tail");local count=#job.children
    for _,value in ipairs({1,2,1}) do
      w.data.mixer_config.tail_rotor_mode=value
      expect(picture,value==2 and "tail-bidirectional" or "tail-motor")
      eq(#job.children,count,"VISUAL motor-tail change retains the scene")
    end
    w.data.mixer_config.tail_rotor_mode=0
    job,picture=scene("profiles");expect(picture,"switch-left")
    check(picture.visible==nil or picture.visible(),"VISUAL profile switch keeps its example picture")
    -- Both servo groups swap pictures and custom geometry within one scene.
    for index=1,2 do
      job,picture=scene("servoType",index);count=#job.children
      local card=w.cards[index]
      local wave
      for _,item in ipairs(job.children) do
        if item.type=="line" and type(item.pts)=="function" and #item.pts()==50 then wave=item end
      end
      check(wave~=nil,"VISUAL pulse scene retains its custom waveform")
      if wave then
        local points=wave.pts()
        for _,preset in ipairs({{50,1520,"pulse-50-1520"},{333,1520,"pulse-333-1520"},{560,760,"pulse-560-760"}}) do
          for _,servo in ipairs(card.servoIndices) do
            local member=w.data.servo_configurations.servos[servo]
            member.rate,member.mid,member.max=preset[1],preset[2],preset[2]==760 and 250 or 700
          end
          w.refreshPulse();expect(picture,preset[3])
          check(picture.visible() and not wave.visible(),"VISUAL preset shows only its picture")
          local shapes={}
          for _,custom in ipairs({{200,preset[2]},{preset[1],preset[2]+10}}) do
            local first=w.data.servo_configurations.servos[card.servoIndex]
            first.rate,first.mid=custom[1],custom[2];w.refreshPulse()
            check(not picture.visible() and wave.visible(),"VISUAL custom Hz or width uses the waveform")
            eq(wave.pts(),points,"VISUAL custom values retain waveform points")
            local shape={}
            for i,pt in ipairs(wave.pts()) do shape[i]=pt[1]..","..pt[2] end
            shapes[#shapes+1]=table.concat(shape,";")
          end
          check(shapes[1]~=shapes[2],"VISUAL a custom rate or width redraws the waveform")
          for _,servo in ipairs(card.servoIndices) do
            local member=w.data.servo_configurations.servos[servo]
            member.rate,member.mid=preset[1],preset[2]
          end
          w.refreshPulse();expect(picture,preset[3])
          check(picture.visible() and not wave.visible(),"VISUAL restoring a preset restores its picture")
          if #card.servoIndices>1 then
            local member=w.data.servo_configurations.servos[card.servoIndices[2]]
            member.mid=member.mid+1;w.refreshPulse()
            check(not picture.visible() and wave.visible(),"VISUAL a mixed group cannot show a preset")
          end
          eq(#job.children,count,"VISUAL pulse settings retain the scene")
        end
      end
    end
  end)
  case("CORE.prepared-api-roundtrip",function()
    local w=world();settle(w)
    h.fixtures[0x5F13]={1,0,0,0,0,0,0,2}
    w:startTrial("board_auto_align");drain(w)
    eq(w.message,L.liftTail,"CORE canonical board API start roundtrip")
    local request=q.sent[#q.sent]
    eq(request.command,0x5F13,"CORE board command")
    eq(request.payload[1],1,"CORE explicit board START payload")
    check(request.isWrite,"CORE board START is classified as a write")
    h.fixtures[0x5F13]={2,166,255,0,0,180,0,3}
    w:trialRequest("board_auto_align",0,function(d) w:trialReply(d) end);drain(w)
    eq(w.data.board_alignment_config.roll_degrees,-90,"CORE canonical signed alignment reaches configuration")
    eq(w.data.board_alignment_config.yaw_degrees,180,"CORE canonical yaw reaches configuration")
    check(not q.sent[#q.sent].isWrite,"CORE board poll is classified as a read")
    eq(h.api("board_auto_align").parse(h.fixtures[0x5F13]).matched_samples,3,"CORE matched samples retained")
    h.fixtures[0x5F13]=nil
    w=world();settle(w);w.data.serial_config.port_1_function_mask=1024;w.data.esc_sensor_config.protocol=1
    h.fixtures[0x5F0C]={1,2,0,0,232,3,0,0,4,1}
    w:startTrial("esc_sensor_trial");drain(w)
    check(w.trial~=nil and not w.trial.success,"CORE canonical ESC running state")
    h.fixtures[0x5F0C]={2,3,1,1,208,7,5,0,4,1}
    w:trialRequest("esc_sensor_trial",0,function(d) w:trialReply(d) end);drain(w)
    check(w.trial and w.trial.success,"CORE canonical ESC success remains live")
    eq(w.data.esc_sensor_config.half_duplex,1,"CORE canonical half-duplex result applied")
    eq(w.data.esc_sensor_config.pin_swap,1,"CORE canonical pin-swap result applied")
    check(string.find(w.trialDetails,"5 frames",1,true)~=nil,"CORE canonical frame diagnostics available in help")
    w:release();local stop=q.messages[#q.messages]
    eq(stop.command,0x5F0C,"CORE canonical ESC stop command")
    eq(stop.payload[1],2,"CORE canonical ESC cancel action")
    check(stop.isWrite,"CORE ESC cancel is classified as a write")
    h.fixtures[0x5F0C]=nil
  end)
  case("CORE.receiver-trial-radio-guard",function()
    local w=world();settle(w);local sent=#q.sent
    w:startTrial("rx_serial_trial");drain(w)
    check(w.trial==nil,"CORE receiver trial cannot own radio transport")
    eq(w.message,L.receiverUsbHint,"CORE receiver trial directs user to USB")
    for i=sent+1,#q.sent do check(q.sent[i].command~=0x5F12,"CORE no receiver trial request sent over radio") end
    local cards=step(w,"receiver")
    eq(cards[1].rows[3].label,L.receiverUsb,"CORE receiver task explains USB route")
    cards[1].rows[3].press()
    eq(w.message,L.receiverUsbHint,"CORE receiver USB button explains connection loss")
  end)
  case("CORE.trial-state-and-diagnostics",function()
    local w=world()
    for _,api in ipairs({"board_auto_align","rx_serial_trial","esc_sensor_trial"}) do
      for _,state in ipairs({0,1,3,4,5,6}) do
        w.trial={api=api,untilAt=getTime()+6000,due=0}
        w:trialReply({state=state,comboIndex=1,elapsedMs=1200})
        if state==1 then check(w.trial~=nil,"CORE running trial retains owner")
        else check(w.trial==nil,"CORE terminal trial releases owner") end
      end
    end
    local rx=h.api("rx_serial_trial")
    check(rx.parse({1,0,1,0,1,0})==nil,"CORE short RX trial refused")
    eq(rx.parse({1,0,1,0,1,52,18}).elapsedMs,4660,"CORE RX elapsed time decoded")
    local esc=h.api("esc_sensor_trial")
    check(esc.parse({1,0,0,0,0})==nil,"CORE short ESC trial refused")
    eq(esc.parse({1,0,0,0,52,18}).elapsedMs,4660,"CORE legacy ESC elapsed time")
    local e=esc.parse({2,3,1,1,52,18,5,0,4,1})
    eq(e.frameDelta,5,"CORE optional ESC frame diagnostics")
    eq(e.comboCount,4,"CORE optional ESC combination count")
    eq(e.portOpen,1,"CORE optional ESC port-open flag")
    w.trial={api="esc_sensor_trial",untilAt=getTime()+6000,due=0}
    w:trialReply(esc.parse({1,0,0,0,52,18,5,0}))
    check(string.find(w.trialDetails,"5 frames",1,true)~=nil,"CORE partial optional diagnostics are safe")
    w:stopTrial()
    w=world();settle(w);w.data.serial_config.port_1_function_mask=1024;w.data.esc_sensor_config.protocol=1
    w.bus.apis.esc_sensor_trial=esc
    w:startTrial("esc_sensor_trial")
    local job=w.bus.jobs[#w.bus.jobs]
    job.after(nil,"lost START reply")
    check(w.trial==nil,"CORE failed START releases trial owner")
    local cancel=q.messages[#q.messages]
    eq(cancel.command,esc.command,"CORE failed START queues cleanup command")
    eq(cancel.payload[1],2,"CORE failed START sends CANCEL despite missing ACK")
  end)
  case("CORE.second-pass-edges",function()
    local w=world()
    w.data.tail_motor_output={output=2,result=0};w.startTail=w.data.mixer_config.tail_rotor_mode
    step(w,"swash")
    check(not w.dirty.tail_motor_output,"CORE BOTH tail output already matches either tail kind")
    w.data.servo_configurations.servo_count=22;w.data.status.servo_count=4
    w.data.serial_config.port_1_function_mask=524288
    eq(#w:servos(),4,"CORE bus servo count follows configuration block")
    check(h.api("rc_config").parse({1,0,1,0,1,0,1})==nil,"CORE truncated RC config refused")
    local parsed=h.api("rc_config").parse(h.api("rc_config").simulatorResponse)
    eq(parsed.rc_deflection,510,"CORE complete RC config positive control")
    w=world();settle(w);w.data.serial_config.port_1_function_mask=1024;w.data.esc_sensor_config.protocol=1
    w.bus.apis.esc_sensor_trial=h.api("esc_sensor_trial")
    local half=w.data.esc_sensor_config.half_duplex
    w:startTrial("esc_sensor_trial");w:trialReply({state=2,half_duplex=1-half,pin_swap=1})
    check(w.trial and w.trial.success,"CORE cancel test has applied trial")
    w:stopTrial(true)
    eq(w.data.esc_sensor_config.half_duplex,half,"CORE cancel restores original half-duplex")
    check(not w.dirty.esc_sensor_config and not w.rebootPending,"CORE cancel restores dirty/reboot state")
    w=world();settle(w);w.data.motor_config.motor_pwm_protocol=5;w.bladesOff=true
    w.data.motor={motor_1=0,motor_2=1000};w:spin(0,1)
    check(w.motorHold==nil,"CORE disabled actual motor blocks spin despite configured output count")
    w.data.motor.motor_1=1000;w:spin(0,1);w.percent=25
    w:tick();drain(w)
    local power
    for _,m in ipairs(q.sent) do if m.command==195 and m.payload[1]==0 then power=m.payload[2]+m.payload[3]*256 end end
    eq(power,250,"CORE motor refresh follows changed power setting")
  end)
  case("CORE.suite-step-entries",function()
    -- The suite's servo fixture has the tail 120 us off centre; a pilot centres it in step 13.
    local centred={};for i,v in ipairs(h.api("servo_configurations").simulatorResponse) do centred[i]=v end
    centred[50],centred[51]=1500 & 255,1500 >> 8
    h.fixtures[120]=centred
    local fs=assert(loadfile("bin/wizard/history_fixture.lua"))()();fs:install()
    -- The model card needs both packed FC state sensors live, as the radio reports them.
    local sources={getValue=getValue,getFieldInfo=getFieldInfo,getSourceValue=getSourceValue,model=model}
    getValue=function() return 8 end
    getFieldInfo=function(name) if name=="STAT" or name=="SCFG" or name=="RxBt" then return {id=1} end end
    getSourceValue=function(name) return 8,name=="telem99" or name=="STAT" or name=="SCFG" end
    model={getSensor=function(index) if index<99 then return {name="STAT"} end end}
    local registry=load("app/pages/init.lua")
    local original=loadScript
    local loaded={}
    loadScript=function(path,mode)
      if string.find(path,"/helicopter_setup/steps/",1,true) then loaded[#loaded+1]=path end
      return original(path,mode)
    end
    local function entry(id,number,history)
      q.messages,q.sent,loaded={},{},{}
      local page=load("app/pages/helicopter_setup/page.lua")
      local closed=false
      local ctx={children={},w=480,h=272,menu={getCurrentMenuId=function() return id end},
        requestClose=function() closed=true end,requestRebuild=function() end}
      page.build(ctx)
      local found,modelGateSeen=false,false
      for _=1,1000 do
        h.measure("suite entry",function()
          page.wakeup(ctx);ctx.children={};page.build(ctx);h.resolve(ctx.children)
        end)
        h.pump();h.advance(1)
        for _,item in ipairs(ctx.children) do
          if type(item.text)=="string" then
            if history and item.text=="@i18n(app.modules.helicopter_setup.historyTitle)@" then found=true end
            if not history and tonumber(string.match(item.text,"^(%d+)/19"))==number then found=true end
          end
        end
        if not found and not history then
          for _,item in ipairs(ctx.children) do
            if item.text=="@i18n(app.modules.helicopter_setup.modelPreparationTitle)@" then
              modelGateSeen=true
              eq(#loaded,0,"CORE model gate precedes step definition loading")
            end
            if item.type=="button" and type(item.text)=="function" and item.text()=="@i18n(app.modules.helicopter_setup.no)@" then
              item.press()
            end
          end
          for _,item in ipairs(ctx.children) do
            local caption=type(item.text)=="function" and item.text() or item.text
            if item.type=="button" and caption=="@i18n(app.modules.helicopter_setup.continue)@" then item.press() end
          end
        end
        if found then break end
      end
      check(found,"CORE Suite entry opens the selected page "..id)
      eq(registry.pagePathByMenuId[id],"helicopter_setup/page.lua","CORE Suite entry shares the lazy page module")
      if history then
        eq(#loaded,0,"CORE history entry loads no setup step")
        for _,m in ipairs(q.sent) do check(m.command==99 or m.command==101,"CORE history opens without configuration reads/writes") end
      else
        check(modelGateSeen,"CORE Suite step requires current radio-model preparation")
        check(#loaded<=1,"CORE direct entry loads at most its own step definition")
      end
      if string.find(id,"_step_",1,true) then
        for _=1,2000 do
          h.measure("suite completion",function()
            page.wakeup(ctx);ctx.children={};page.build(ctx);h.resolve(ctx.children)
          end)
          h.pump();h.advance(1)
          if closed then break end
          for _,item in ipairs(ctx.children) do
            local active=type(item.active)~="function" or item.active()
            if active and item.type=="button" and type(item.text)=="function" and
              item.text()=="@i18n(app.modules.helicopter_setup.no)@" then item.press() end
            local caption=type(item.text)=="function" and item.text() or item.text
            local shown=type(item.visible)~="function" or item.visible()
            if active and shown and item.type=="button" and (caption=="@i18n(app.modules.helicopter_setup.servoTestUp)@" or
              caption=="@i18n(app.modules.helicopter_setup.answerUp)@") then item.press() end
            if active and item.type=="button" and (caption=="@i18n(app.modules.helicopter_setup.continue)@" or
              caption=="@i18n(app.modules.helicopter_setup.saveNext)@" or caption=="@i18n(app.modules.helicopter_setup.saveStep)@" or
              caption=="@i18n(app.modules.helicopter_setup.backToSuite)@") then item.press() end
          end
        end
        check(closed,"CORE direct Suite step completes back to its menu "..number)
        for _,path in ipairs(loaded) do
          check(string.find(path,"/steps/"..h.stepNames[number]..".lua",1,true)~=nil,"CORE individual visit loads no other step")
        end
        local unlock=false
        for _,m in ipairs(q.sent) do if m.command==99 and m.payload[1]==0 then unlock=true end end
        check(unlock,"CORE individual Suite completion releases the arming lock")
      end
      page.onClose()
      if not closed then
        check(_G.rfsuite.session.helicopterSetupRecovery=="test-board","CORE abandoned visit requires physical recovery")
        -- The next entry represents a separate, freshly powered fixture.
        _G.rfsuite.session.helicopterSetupRecovery=nil
      end
    end
    entry("helicopter_setup_page",1)
    for index=1,19 do entry(string.format("helicopter_setup_step_%02d_page",index),index) end
    entry("helicopter_setup_history_page",nil,true)
    local recorded=load("app/pages/helicopter_setup/history_store.lua").new("test-board");recorded:load()
    eq(recorded.mask,(1<<19)-1,"CORE all nineteen individual Suite visits record their validated completion")
    loadScript=original;fs:restore()
    h.fixtures[120]=nil
    getValue,getFieldInfo,getSourceValue,model=sources.getValue,sources.getFieldInfo,sources.getSourceValue,sources.model
  end)
  case("CORE.radio-model-preparation",function()
    local w=world();settle(w)
    local originalModel=model
    model={getInfo=function() return {name="Bench model",filename="model01.yml"} end}
    load("app/pages/helicopter_setup/navigation.lua").attach(w,{menu={getCurrentMenuId=function() return "helicopter_setup_step_13_page" end}})
    model=originalModel
    w.buildRequested=true;w:tick()
    eq(w.activeModelName,"Bench model","CORE preparation shows active radio model")
    check(w.modelPreparationCard and next(w.holds)==nil,"CORE model gate precedes automatic holds")
    w:next();check(w.modelPreparationCard,"CORE unchecked model cannot advance")
    w.checks.modelReady=true;w:next();w:tick()
    check(w.modelPreparationDone and w.preparationCard,"CORE manual model check leads to physical preparation")
    check(next(w.holds)==nil,"CORE model check does not bypass physical test prerequisites")
    local nextVisit=world();settle(nextVisit)
    load("app/pages/helicopter_setup/navigation.lua").attach(nextVisit,{menu={getCurrentMenuId=function() return "helicopter_setup_page" end}})
    nextVisit.buildRequested=true;nextVisit:tick()
    check(nextVisit.modelPreparationCard and not nextVisit:ack("modelReady"),
      "CORE new visit always rechecks the transmitter model")
  end)
  case("CORE.history-store",function()
    local fs=assert(loadfile("bin/wizard/history_fixture.lua"))()();fs:install()
    local Store=load("app/pages/helicopter_setup/history_store.lua")
    local a,b=Store.new("board-A","/user/board-A.lua"),Store.new("board-B","/user/board-B.lua")
    a:load();b:load();eq(a.mask,0,"CORE new FC has no history")
    local saved
    h.measure("history write",function() saved=a:save((1<<19)-1) end)
    check(saved,"CORE all nineteen history bits persist")
    a=Store.new("board-A","/user/board-A.lua");a:load()
    eq(a.count,19,"CORE new visit reads nineteen historical steps")
    eq(b.mask,0,"CORE another FC does not inherit history")
    check(b:save(128),"CORE another FC keeps its own history")
    check(a:save(0),"CORE explicit reset succeeds")
    eq(a.mask,0,"CORE reset clears this FC only")
    b:load();eq(b.mask,128,"CORE reset preserves another FC")
    for _,failure in ipairs({"mkdir","open","write","short","delete","rename","readback"}) do
      fs.failure=nil;check(a:save(1),"CORE persistence failure positive control")
      fs.failure=failure
      check(not a:save(3),"CORE file failure is reported "..failure)
      eq(a.mask,1,"CORE failed write never claims persisted completion "..failure)
      if failure=="rename" then
        local recovered=Store.new("board-A","/user/board-A.lua");recovered:load()
        eq(recovered.mask,3,"CORE valid temporary record recovers interrupted replacement")
      end
    end
    fs.failure=nil
    fs.files[a.path]="return { version = 1, completed = 524288 }\n";a:load()
    check(a.invalid and a.mask==0,"CORE out-of-range history is unknown")
    check(not a:save(1),"CORE unreadable history needs explicit reset")
    check(a:save(0),"CORE explicit reset replaces unreadable history")
    fs.files[a.path]="return { version = 1, completed = 2 }\n"..string.rep("x",10000)
    h.measure("history read",function() a:load() end)
    check(a.invalid,"CORE oversized history is refused after one bounded read")
    local invalid=Store.new("../another-board");invalid:load()
    check(not invalid.path and not invalid:save(1),"CORE FC identity cannot escape history directory")
    fs:restore()
  end)
  case("CORE.history-lua-record",function()
    local fs=assert(loadfile("bin/wizard/history_fixture.lua"))()();fs:install()
    local Store=load("app/pages/helicopter_setup/history_store.lua")
    local a=Store.new("board-lua")
    eq(string.sub(a.path,-4),".lua","CORE history uses a dedicated Lua file per FC")
    fs.files[string.sub(a.path,1,-5)..".txt"]="RFW1 5\n";a:load()
    eq(a.mask,0,"CORE unreleased text history is ignored")
    check(fs.files[a.path]==nil,"CORE history load does not write a record")
    check(a:save(7),"CORE explicit save writes Lua history")
    local record=fs.files[a.path]
    local chunk=assert(_G.load(record,"history-data","t",{}))
    local data=chunk()
    eq(data.version,1,"CORE saved history is valid versioned Lua data")
    eq(data.completed,7,"CORE Lua history contains the exact completion bits")
    fs.files[a.path.."c"]="invalid compiled overlay"
    local original=loadScript
    loadScript=function() error("history records must not execute card code") end
    a:load()
    loadScript=original
    eq(a.mask,7,"CORE history reads Lua data directly despite a bytecode overlay")
    check(a:save(0),"CORE Lua history remains resettable")
    a:load();eq(a.mask,0,"CORE reset Lua completion persists")
    fs.files[a.path]="return { version = 2, completed = 7 }\n";a:load()
    check(a.invalid and a.mask==0,"CORE unknown Lua version never supplies completion")
    check(not a:save(1),"CORE unknown Lua record requires explicit reset")
    check(a:save(0),"CORE explicit reset replaces an unsupported Lua record")
    local b=Store.new("board-temporary")
    fs.files[b.path..".tmp"]="return { version = 1, completed = 16 }\n";b:load()
    eq(b.mask,16,"CORE interrupted Lua save remains recoverable")
    fs:restore()
  end)
  case("CORE.history-guidance-and-reset",function()
    local fs=assert(loadfile("bin/wizard/history_fixture.lua"))()();fs:install()
    local w=world();settle(w)
    load("app/pages/helicopter_setup/history.lua").attach(w,load("app/pages/helicopter_setup/history_store.lua"))
    w:loadHistory();w.singleStep=true
    if h.mutation=="history-early" then
      local original=w.next
      w.next=function(self)
        self.history:save(self.history.mask | (1 << (self.step-1)))
        return original(self)
      end
    end
    w.step=14;w:updateHistoryHints()
    check(w.prerequisiteHint and string.find(w.prerequisiteDetails,L.receiver,1,true),"CORE missing receiver prerequisite is explained")
    check(w.checks.control1~=true,"CORE history never supplies a physical answer")
    step(w,"direction");w.card=#w.cards;w:next();drain(w)
    eq(w.history.mask,0,"CORE unconfirmed step cannot enter history")
    w.checks.control1,w.checks.control2,w.checks.control4=true,true,true
    w:next();drain(w)
    check(w.overview and (w.history.mask&(1<<13))~=0,"CORE validated single step is recorded before returning")
    w:startStep(14);w:tick()
    check(w.historyHint==L.historyRecheck,"CORE repeated step asks for recheck")
    check(not w:ack("control1") and next(w.holds)==nil,"CORE past completion cannot bypass fresh preparation")
    w.historyMode=true;w.preparationCard=nil;w:buildHistory();q.sent={}
    w.cards[1].rows[3].press();drain(w)
    check(w.history.mask~=0,"CORE resetting history requires confirmation")
    w.checks.resetHistory=true;w.cards[1].rows[3].press();drain(w)
    eq(w.history.mask,0,"CORE confirmed history reset persists zero")
    eq(w.message,L.historyResetDone,"CORE reset reports its limited effect")
    for _,m in ipairs(q.sent) do check(m.command~=250,"CORE history reset never writes FC EEPROM") end
    fs:restore()
  end)
  case("CORE.history-failure-actions",function()
    local fs=assert(loadfile("bin/wizard/history_fixture.lua"))()();fs:install()
    local w=world();settle(w)
    load("app/pages/helicopter_setup/history.lua").attach(w,load("app/pages/helicopter_setup/history_store.lua"))
    w:loadHistory();w.singleStep=true;w.step=14
    step(w,"direction");w.card=#w.cards
    w.checks.control1,w.checks.control2,w.checks.control4=true,true,true
    fs.failure="open";w:next();drain(w)
    check(w.historyFailure and not w.overview,"CORE card failure waits for explicit action")
    eq(w.history.mask,0,"CORE card failure has no completion badge")
    w:back();check(not w.historyFailure and not w.overview,"CORE Back cancels history failure without advancing")
    w:next();drain(w);fs.failure=nil;w.historyRetry();drain(w)
    check(w.overview and w.history.mask==(1<<13),"CORE explicit retry records the completed step")
    w.overview=nil;w.singleStep=true;w.step=15;step(w,"level");w.card=#w.cards;w.checks.level=true
    fs.failure="short";w:next();drain(w)
    check(w.historyFailure,"CORE failed readback is visible")
    w.historySkip();drain(w)
    check(w.overview and (w.history.mask&(1<<14))==0,"CORE explicit continue leaves failed visit unrecorded")
    fs:restore()
  end)
  return cases
end
