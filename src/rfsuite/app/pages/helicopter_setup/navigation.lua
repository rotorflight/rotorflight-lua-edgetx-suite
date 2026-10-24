-- Complete setup and individual steps share one controller and cleanup path.
local M = {}
function M.attach(w, ctx)
  w.overview, w.selectedStep = true, 1
  local menu = ctx and ctx.menu
  local id = menu and menu.getCurrentMenuId and menu.getCurrentMenuId()
  local entry = type(id) == "string" and tonumber(string.match(id,"^helicopter_setup_step_(%d%d)_page$"))
  if id == "helicopter_setup_page" or id == "helicopter_setup_history_page" or entry and entry>=1 and entry<=19 then
    w.returnToSuite, w.overview = true, nil
    w.historyMode = id == "helicopter_setup_history_page"
    w.step, w.selectedStep = entry or 1, entry or 1
    w.singleStep = id ~= "helicopter_setup_page"
  end
  if ctx then
    w.modelPreparationRequired = not w.historyMode
    local info = type(model)=="table" and type(model.getInfo)=="function" and model.getInfo()
    w.activeModelName = type(info)=="table" and type(info.name)=="string" and info.name~="" and info.name or w.L.unknown
  end
  function w:showSteps()
    self:release()
    self.overview, self.singleStep, self.confirmExit, self.exitToSteps = true, nil, nil, nil
    self.cards, self.commit, self.validate, self.onLive, self.buildRequested = nil, nil, nil, nil, nil
    self.checks, self.preparationDone, self.preparationCard = {}, nil, nil
    self.message = self.rebootPending and self.L.pendingReboot or self.L.ready
    self:rebuild()
  end
  function w:requestSteps()
    if not self.ready or self.transition then return end
    self:release()
    if next(self.dirty) then
      self.confirmExit, self.exitToSteps = true, not self.returnToSuite; self:rebuild()
    elseif self.returnToSuite then self:close()
    else self:showSteps() end
  end
  function w:startStep(index, complete)
    if not self:usable() or not index or index < 1 or index > 19 or index % 1 ~= 0 then return end
    if index > 10 and self.rebootPending then self.message = self.L.pendingReboot; return end
    self.overview, self.singleStep, self.selectedStep = nil, not complete, index
    self.checks, self.preparationDone, self.preparationCard = {}, nil, nil
    self:navigate(index, 1)
  end
  function w:standalonePreparation()
    if not self.singleStep then return false end
    return (self.step > 1 and self.step < 10) or (self.step >= 13 and self.step <= 16) or
      (self.step == 17 and not self:motorised()) or self.step == 18
  end
  -- A prerequisite row: the packed sensor is live, missing after four reads, or still being checked.
  function w:sensorState(value)
    if value ~= nil then return self.L.sensorLive end
    return (self.systemReads or 0) >= 4 and self.L.sensorMissing or self.L.sensorChecking
  end
  -- The FC's own telemetry list (MSP telemetry_config): true when System Status (120) and System
  -- Config (121) are both in it, false when one is missing, nil when it was not read.
  local FC_SENSORS = { 120, 121 }
  function w:fcSensorsListed()
    local d = self.data.telemetry_config
    -- Only a complete reply counts: all 40 slots parsed and the raw buffer long enough to write back.
    if type(d) ~= "table" or type(d.buffer) ~= "table" or #d.buffer < 52 or d.telem_sensor_slot_40 == nil then return nil end
    for _, id in ipairs(FC_SENSORS) do
      local found = false
      for i = 1, 40 do if d["telem_sensor_slot_" .. i] == id then found = true end end
      if not found then return false end
    end
    return true
  end
  -- Puts the missing sensors into free slots of the FC's raw telemetry buffer (the API's write
  -- builder knows no slots, so the FC's own bytes are written back), then saves and restarts.
  function w:addFcSensors()
    local d = self.data.telemetry_config
    if not self:usable() or self:fcSensorsListed() ~= false or type(d.buffer) ~= "table" then return end
    local payload = {}
    for i, v in ipairs(d.buffer) do payload[i] = v end
    for _, id in ipairs(FC_SENSORS) do
      local present = false
      for i = 13, 52 do if payload[i] == id then present = true end end
      if not present then
        local free
        for i = 13, 52 do if free == nil and payload[i] == 0 then free = i end end
        if free == nil then self.message = self.L.noSensorSlot; return end
        payload[free] = id
        d["telem_sensor_slot_" .. (free - 12)] = id
      end
    end
    d.buffer = payload
    self:action("telemetry_config", payload)
    self:reboot()
  end
  function w:buildModelPreparation()
    if self.recoveryRequired then
      self.cards={self:cardDef(self.L.recoveryTitle,self.L.recoveryHint,{
        self:check("recoveryPowerCycle",self.L.fcPowerCycled)
      })}
      self.cards[1].summary=self.L.recoveryIntro
      self.card,self.recoveryCard=1,true;return true
    end
    if not self.modelPreparationRequired or self.modelPreparationDone then return false end
    self.cards={self:cardDef(self.L.modelPreparationTitle,self.L.modelPreparationIntro.."\n"..self.L.modelPreparationHint.."\n"..
      self.L.activeModel..": "..self.activeModelName.."\n"..self.L.craftNameHint.."\n\n"..self.L.sensorsHint,{
      -- The flight controller's own name, set here once so every later screen can show it.
      { kind = "text", label = self.L.craftName, length = 16,
        get = function() return self.data.name and self.data.name.name or "" end,
        set = function(v) if self.data.name then self:field("name", "name", v) end end },
      self:check("modelReady",self.L.modelChecked),
      -- Prerequisites checked up front: the two packed FC state sensors the hints depend on.
      self:value(self.L.fcStatusSensor,function() return self:sensorState(self.systemStatus) end),
      self:value(self.L.fcConfigSensor,function() return self:sensorState(self.systemConfig) end),
      self:button(function()
        local listed = self:fcSensorsListed()
        return listed and self.L.fcSensorsListed or listed == nil and self.L.fcSensorsUnread or self.L.addFcSensors
      end, function() self:addFcSensors() end, function() return self:fcSensorsListed() == false end)
    })}
    self.cards[1].summary=self.L.modelPreparationIntro.."\n"..self.L.activeModel..": "..self.activeModelName
    self.card,self.modelPreparationCard=1,true
    return true
  end
  function w:buildPreparation()
    if self:standalonePreparation() and not self.preparationDone then
      local rows = { self:check("blades", self.L.bladesRemoved) }
      rows[2] = self.step < 10 and self:check("unplugged", self.L.servosUnplugged) or
        self:check("servoSettings", self.L.servoSettingsChecked)
      self.cards = {self:cardDef(self.L.prepareStep, self.L.prepareStepHint, rows)}
      self.card, self.preparationCard = 1, true
      return true
    end
    return false
  end
  function w:preparationComplete()
    if self.preparationCard then
      return self:ack("blades") and self:ack(self.step < 10 and "unplugged" or "servoSettings")
    end
    return true
  end
  function w:finishStep()
    local function after()
      if self.singleStep then
        if self.returnToSuite then self:close() else self:showSteps() end
      elseif self.step == 19 then self:close()
      else self:navigate(self.step + 1, 1) end
    end
    if self.rememberStep then self:rememberStep(after) else after() end
  end
  function w:resolveExit(save)
    if self.transition then return end
    local steps,target = self.exitToSteps,self.backTarget
    self.confirmExit, self.exitToSteps,self.backTarget = nil, nil,nil
    local after = target and function() self:navigate(target,1) end or
      steps and function() self:showSteps() end or function() self:close() end
    if save then self:save(after) else self:discard((steps or target) and after or nil) end
  end
end
return M
