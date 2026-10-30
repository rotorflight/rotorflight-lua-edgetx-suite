local M = {}
function M.attach(w)
  function w:serialReceiver()
    local d=self.data.feature_config
    d.enabledFeatures=(d.enabledFeatures & (~((1<<0)|(1<<3)|(1<<13)|(1<<14)|(1<<25)))) | (1<<3)
    self:touch("feature_config", true)
  end
  function w:hasPort(bit)
    for i=1,12 do
      if ((self.data.serial_config["port_"..i.."_function_mask"] or 0) & bit) ~= 0 then return true end
    end
    return false
  end
  function w:canDetect(bit)
    if self.rebootPending or self.trial or self.dirty.serial_config then return false end
    if bit==64 then return not self.dirty.rx_config and self:hasPort(bit) end
    return not self.dirty.esc_sensor_config and self:hasPort(bit) and
      self.data.esc_sensor_config.protocol > 0 and self.data.motor_config.motor_pwm_protocol ~= 9 and
      not (self:apiAtLeast(10) and self.data.motor_config.motor_pwm_protocol==10)
  end
  function w:modeActive(id)
    for i,box in ipairs(self.data.boxids.box_ids) do
      if box==id then return (self.data.status.flight_mode_flags & (1 << (i-1))) ~= 0 end
    end
    return false
  end
  function w:toggleHold(kind,index,value)
    local h=self.holds[kind..index]
    self:hold(kind,index,h and h.value==value and 0 or value)
  end
  function w:rpmStatus()
    local m, features = self.data.motor_config, self.data.feature_config.enabledFeatures
    local freq = (features & (1 << 28)) ~= 0
    -- DShot150 ESCs send no bidirectional DShot RPM.
    local dshot = m.motor_pwm_protocol >= 6 and m.motor_pwm_protocol <= 8
    if m.motor_pole_count_0 == 0 then return self.L.rpmSetPoles end
    if not freq and m.use_dshot_telemetry ~= 0 and not dshot then return self.L.rpmNeedsDshot end
    if self.rebootPending or self.dirty.feature_config or self.dirty.motor_config then return self.L.rpmAfterReboot end
    -- The source is selected at boot; a configured frequency sensor still needs a FREQ resource.
    local mode = (features & (1 << 26)) ~= 0 and self.data.governor_config.gov_mode or 0
    if mode==3 or mode==4 then
      if (self.data.status.arming_disable_flags & (1 << 6)) ~= 0 then return self.L.rpmFcMissing end
      return self.L.rpmFcFast, true
    end
    local configured = freq or (dshot and m.use_dshot_telemetry ~= 0)
    return configured and self.L.rpmConfigured or self.L.rpmMissing, configured
  end
  function w:fastRpm()
    local _, fast = self:rpmStatus()
    return fast == true
  end
  function w:fixMotor()
    local castle = self.data.motor_config.motor_pwm_protocol == 9
    if castle then self.data.esc_sensor_config.protocol = 0; self:touch("esc_sensor_config") end
    self:feature(27, castle or self.data.esc_sensor_config.protocol > 0, true)
    -- DShot150 ESCs send no bidirectional DShot RPM, and one that does not answer the request
    -- may not arm; a stored combination is cleared when the Motor step is saved.
    local m = self.data.motor_config
    if m.motor_pwm_protocol == 5 and m.use_dshot_telemetry ~= 0 then
      self:field("motor_config", "use_dshot_telemetry", 0, true)
    end
  end
  function w:canSpin(index)
    local m=self.data.motor
    local output=m and m["motor_"..(index+1)] or 0
    return self.bladesOff and not self.rebootPending and output>0 and
      not (self.escParams and self.escParams.changes) and
      index<(self.data.status.motor_count or 0) and
      (index~=0 or self.data.motor_config.motor_pwm_protocol~=0 or self.calibratedEsc
        or self.rangeSource=="asserted" or self.rangeSource=="esc_link")
  end
  function w:motorOutputsOk()
    local m = self.data.motor
    return m and m.motor_1 > 0 and (not self:motorised() or m.motor_2 > 0)
  end
  function w:servoLabels()
    local result = {}; for _, i in ipairs(self:servos()) do result[#result + 1] = self.L.servo .. " " .. (i + 1) end
    return result
  end
  function w:trialRequest(api,action,after)
    self.bus:add({api=api,write=action~=0,optional=true,decode=action~=0,after=after,
      payload=function() return self.bus.apis[api].buildPayload(action) end})
  end
  function w:startTrial(api)
    -- A receiver wiring trial reopens the UART carrying this MSP connection.
    if api == "rx_serial_trial" then self.message=self.L.receiverUsbHint;return end
    if not self:usable() or self.trial then return end
    if api ~= "board_auto_align" and not self:canDetect(api == "rx_serial_trial" and 64 or 1024) then
      self.message=self.L.saveFirst;return
    end
    self.trial = { api = api, untilAt = getTime() + 6000, due = 0,
      rebootBefore=self.rebootPending }
    if api ~= "board_auto_align" then
      local name=api=="rx_serial_trial" and "rx_config" or "esc_sensor_config"
      local keys=api=="rx_serial_trial" and {"serialrx_inverted","halfDuplex","pinSwap"} or {"half_duplex","pin_swap"}
      self.trial.config,self.trial.keys,self.trial.before,self.trial.dirtyBefore=name,keys,{},self.dirty[name]
      for _,key in ipairs(keys) do self.trial.before[key]=self.data[name][key] end
    end
    self:trialRequest(api,1,function(d,error)
      if error then
        self:stopTrial()
        self.message = api == "board_auto_align" and self.L.manualAlign or self.L.unsupported
      else self:trialReply(d) end
    end)
  end
  function w:trialReply(d)
    local trial = self.trial; if not trial then return end
    if not d then self.message = self.L.unsupported; self:stopTrial(); return end
    self.trialDetails=d.elapsedMs and string.format("%d ms",d.elapsedMs) or nil
    if d.frameDelta then
      self.trialDetails=(self.trialDetails or "")..string.format(" / %d frames",d.frameDelta)
      if d.portOpen~=nil then self.trialDetails=self.trialDetails..string.format(" / port %d",d.portOpen) end
    end
    if d.state == 1 then
      trial.due=getTime()+20
      self.message=trial.api=="board_auto_align" and self.L.liftTail or
        self.L.detecting.." "..tostring((d.comboIndex or 0)+1).."/"..(trial.api=="rx_serial_trial" and "8" or "4")
      if self.logInfo then self:keyMessage("detecting") end
      return
    end
    if d.state ~= 2 then
      self.message = trial.api == "board_auto_align" and d.state == 6 and self.L.calibrateFirst or
        trial.api=="board_auto_align" and d.state==4 and self.L.detectTimeout or
        trial.api=="board_auto_align" and d.state==5 and self.L.orientationUnknown or
        trial.api~="board_auto_align" and d.state==3 and self.L.wiringNotFound or self.L.trialRejected
      self:stopTrial(); return
    end
    if trial.api == "board_auto_align" then
      local a = self.data.board_alignment_config
      a.roll_degrees, a.pitch_degrees, a.yaw_degrees = d.roll_degrees, d.pitch_degrees, d.yaw_degrees
      self:touch("board_alignment_config", true)
    elseif trial.api == "rx_serial_trial" then
      local a = self.data.rx_config
      a.serialrx_inverted, a.halfDuplex, a.pinSwap = d.inverted, d.half_duplex, d.pin_swap
      self:touch("rx_config", true)
    else
      local a = self.data.esc_sensor_config
      a.half_duplex, a.pin_swap = d.half_duplex, d.pin_swap
      self:touch("esc_sensor_config", true)
    end
    self.message = trial.api == "board_auto_align" and self.L.detected or self.L.detectedSave
    if trial.api == "board_auto_align" then self.trial = nil
    else trial.success = true end
  end
  function w:stopTrial(discard)
    local trial = self.trial; self.trial = nil
    if trial and trial.success and discard and trial.before then
      for _,key in ipairs(trial.keys) do self.data[trial.config][key]=trial.before[key] end
      self.dirty[trial.config]=trial.dirtyBefore
      self.rebootPending=trial.rebootBefore
      self.message=self.L.ready
    end
    if trial and trial.api ~= "board_auto_align" and self:allowed() then
      self.bus:dropApi(trial.api)
      local api,q=self.bus.apis[trial.api],self.bus:queue()
      if api and q then
        q:add({command=api.command,payload=api.buildPayload(2),isWrite=true,
          client="helicopter-cleanup",maxRetries=0})
      end
    end
  end
  function w:trialTick()
    if not self.trial or self.trial.success then return false end
    if getTime() > self.trial.untilAt then self.message = self.L.detectTimeout; self:stopTrial(); return true end
    if getTime() < self.trial.due then return true end
    local api = self.trial.api
    self:trialRequest(api,0,function(d,err)
      if err then self.message = self.L.unsupported; self:stopTrial() else self:trialReply(d) end
    end)
    return true
  end
end
return M
