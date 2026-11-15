-- Visit-local adapter for the shared diagnostics task. FC configuration stays out of the draft.
local M = {}
local TASK = "app/pages/tools/diagnostics/elrs_link/elrslink_task.lua"
local RATE_KEYS = { "333", "500", "d500" }
local RATIO_KEYS = { "1:4", "1:8", "1:16", "1:32" }
local function optionIndex(options, want)
  for index, option in ipairs(options or {}) do
    local text = string.lower(tostring(option))
    if want == "500" then
      if string.find(text,"500",1,true) and not string.find(text,"d500",1,true)
        and not string.find(text,"f500",1,true) then return index-1 end
    elseif string.find(text,want,1,true) then return index-1 end
  end
end
function M.new(w)
  local L = w.L
  local c = { task=w:loadModule(TASK), epoch=0 }
  local task=c.task
  function c:busy() return self.started and task.isRunning() end
  function c:applies()
    return w.data.rx_config.serialrx_provider==9 and (w.data.feature_config.enabledFeatures & (1<<3))~=0
      and w:session().telemetryType=="crsf"
  end
  function c:current()
    return w.active and self.card and w.cards and w.cards[w.card]==self.card and not w.overview and not w.confirmExit
      and not w.historyFailure and not w.disconnectExit
  end
  function c:usable()
    return self:current() and self:applies() and w:usable()
  end
  -- Link changes can briefly cut the wizard's connection and require their own confirmation.
  -- Reading and confirmation availability are independent of the receiver's Advanced switch.
  function c:writable()
    return self:usable() and w.rx ~= nil and not self:busy()
  end
  function c:refresh()
    -- A new cards identity retires the native scene and its controls before publishing new rows.
    local cards={};for i,card in ipairs(w.cards or {}) do cards[i]=card end
    w.cards=cards;w:rebuild()
  end
  function c:stop()
    self.epoch=self.epoch+1
    task.reset()
    -- The reset forgets the module's fields: whatever binds the card again walks the module first.
    self.asked,self.signature,self.started=nil,nil,nil
    -- An unfinished Set on both ends with the task: nothing would carry it on.
    self.plan=nil
    w.linkTick,w.stopLink=nil,nil
  end
  function c:bind()
    w.linkTick=function() self:tick() end
    w.stopLink=function() self:stop() end
  end
  function c:boardText()
    if not self:applies() then return L.linkNeedsCrsf end
    local fc=w:session().crsfTelemetryConfig
    if not fc or not fc.linkRate or not fc.linkRatio then return L.linkUnknown end
    local text=string.format(L.linkPair,fc.linkRate,fc.linkRatio)
    return fc.mode==0 and string.format(L.linkNative,text) or text
  end
  function c:moduleText()
    if not self:applies() then return L.linkNeedsCrsf end
    local link=w:session().elrsLinkConfig
    if not link or not link.packetRate or not link.telemetryRatio then return L.linkUnknown end
    return string.format(L.linkModulePair,link.packetRateLabel or tostring(link.packetRate),
      link.telemetryRatioLabel or string.format(L.linkRatioValue,link.telemetryRatio))
  end
  function c:notice(text)
    w.linkNotice=text
    if text then w.message=text end
  end
  function c:difference()
    if not self:applies() then return "" end
    local fc,link=w:session().crsfTelemetryConfig,w:session().elrsLinkConfig
    if not fc or not link or not fc.linkRate or not fc.linkRatio
      or not link.packetRate or not link.telemetryRatio then return "" end
    -- The task parses the digits in DVDA labels as rate, not the on-air packet rate.
    local dvda=string.match(link.packetRateLabel or "","^D%d+")~=nil
    local rate,ratio=not dvda and fc.linkRate~=link.packetRate,fc.linkRatio~=link.telemetryRatio
    if rate and ratio then
      return string.format(L.linkDiffPair,fc.linkRate,fc.linkRatio,link.packetRate,link.telemetryRatio)
    elseif rate then return string.format(L.linkDiffRate,fc.linkRate,link.packetRate)
    elseif ratio then return string.format(L.linkDiffRatio,fc.linkRatio,link.telemetryRatio) end
    return ""
  end
  function c:status()
    if not self:applies() then return L.linkNeedsCrsf end
    return w.linkNotice or task.getStatusText(w.i18n)
  end
  function c:probe()
    if not self:usable() or self:busy() then return end
    self:bind()
    w.linkNotice=nil;self.asked=true
    local epoch=self.epoch
    -- The wizard owns this read only. The task owns both FC writes and its EEPROM commit.
    w:read("telemetry_config",function(parsed)
      if epoch~=self.epoch or not self:current() or not self:applies() or not w:usable() then return end
      if not parsed or not parsed.crsf_telemetry_link_rate or not parsed.crsf_telemetry_link_ratio then
        self:notice(L.linkUnknown);return
      end
      local session=w:session()
      session.crsfTelemetryConfig={mode=parsed.crsf_telemetry_mode,
        linkRate=parsed.crsf_telemetry_link_rate,linkRatio=parsed.crsf_telemetry_link_ratio}
      session.telemetryConfigBuffer=parsed.buffer
      self.started=true;task.start(task.MODE_PROBE)
    end,true)
  end
  function c:sync(mode)
    if not self:applies() then self:notice(L.linkNeedsCrsf);return end
    if not self:writable() then return end
    if next(w.dirty) then self:notice(L.saveFirst);return end
    local dialog=w:loadModule("ui/confirm_dialog.lua")
    local epoch=self.epoch
    local shown=dialog and dialog.show({title=L.linkConfirmTitle,
      message=string.format(L.linkQuestion,mode==task.MODE_ROTORFLIGHT_TO_ELRS and L.linkConfirmFc or L.linkConfirmModule,
        L.linkFc,self:boardText(),L.linkModule,self:moduleText()),
      onConfirm=function()
        -- Native dialogs may outlive this visit or STATUS. A missing fresh lock is never a yes.
        if epoch~=self.epoch or not self:writable() or next(w.dirty) then
          self:notice(L.linkCancelled);return
        end
        self:bind();w.linkNotice=nil;self.started=true;self.rewalk=true;task.start(mode)
      end,
      onCancel=function() self:notice(L.linkCancelled) end})
    if not shown then self:notice(L.linkNoDialog) end
  end
  function c:picker(kind,label)
    local field=kind=="rate" and task.getRateField() or task.getRatioField()
    if not field or not field.options then return w:value(label,function() return self:status() end) end
    local values,indices={},{}
    for i,key in ipairs(kind=="rate" and RATE_KEYS or RATIO_KEYS) do
      local index=optionIndex(field.options,key)
      if index~=nil then
        indices[#indices+1]=index
        values[#values+1]=kind=="rate" and ({L.link333,L.link500,L.linkD500})[i] or
          ({L.linkRatio4,L.linkRatio8,L.linkRatio16,L.linkRatio32})[i]
      end
    end
    if #values==0 then return w:value(label,function() return L.linkNoOptions end) end
    self.choices=self.choices or {}
    self.choices[kind]={values=values,indices=indices}
    return {kind="choice",label=label,values=values,allowUnset=true,
      enabled=function() return self:writable() end,
      -- A chosen value is a draft until Set on both; the module's own value shows otherwise.
      get=function()
        if not self:applies() then return 0 end
        if self.draft and self.draft[kind] then return self.draft[kind] end
        local current=kind=="rate" and task.getRateField() or task.getRatioField()
        for i,index in ipairs(indices) do if current and current.selectedIndex==index then return i end end
        return 0
      end,
      set=function(value)
        if not self:applies() then self:notice(L.linkNeedsCrsf);return end
        if not indices[value] then return end
        self.draft=self.draft or {}
        self.draft[kind]=value
        if w.logTrace then w:log("trace","ELRS draft %s %s",kind,values[value]) end
      end}
  end
  -- The two sides in a table, one result beside them; the result says unknown while a value is
  -- missing, never that they match.
  function c:fcValues()
    local fc=w:session().crsfTelemetryConfig
    if not self:applies() or not fc or not fc.linkRate or not fc.linkRatio then return nil end
    return string.format(L.linkHz,fc.linkRate),string.format(L.linkRatioValue,fc.linkRatio)
  end
  function c:moduleValues()
    local link=w:session().elrsLinkConfig
    if not self:applies() or not link or not link.packetRate or not link.telemetryRatio then return nil end
    return link.packetRateLabel or tostring(link.packetRate),link.telemetryRatioLabel or string.format(L.linkRatioValue,link.telemetryRatio)
  end
  function c:result()
    if not self:applies() then return L.linkNeedsCrsf end
    local fc,link=w:session().crsfTelemetryConfig,w:session().elrsLinkConfig
    if not fc or not link or not fc.linkRate or not fc.linkRatio or not link.packetRate or not link.telemetryRatio then
      return L.linkUnknown
    end
    return self:difference()=="" and L.linkMatch or L.linkDiffer
  end
  function c:setBoth()
    if not self:applies() then self:notice(L.linkNeedsCrsf);return end
    if not self:writable() or self.plan then return end
    if next(w.dirty) then self:notice(L.saveFirst);return end
    local draft=self.draft or {}
    local rate=draft.rate and self.choices.rate and self.choices.rate.values[draft.rate]
    local ratio=draft.ratio and self.choices.ratio and self.choices.ratio.values[draft.ratio]
    if not rate and not ratio then self:notice(L.linkSetBothNone);return end
    local _,moduleRatio=self:moduleValues()
    local moduleRate=self:moduleValues()
    local dialog=w:loadModule("ui/confirm_dialog.lua")
    local epoch=self.epoch
    local shown=dialog and dialog.show({title=L.linkConfirmTitle,
      message=string.format(L.linkSetBothQuestion,rate or moduleRate or "--",ratio or moduleRatio or "--"),
      onConfirm=function()
        if epoch~=self.epoch or not self:writable() or next(w.dirty) then self:notice(L.linkCancelled);return end
        -- The module first, one option at a time, each read back; then the FC takes the module values.
        local steps={}
        if draft.rate then steps[#steps+1]={kind="rate",index=self.choices.rate.indices[draft.rate]} end
        if draft.ratio then steps[#steps+1]={kind="ratio",index=self.choices.ratio.indices[draft.ratio]} end
        steps[#steps+1]={kind="fc"}
        self.plan={steps=steps,at=1}
        if w.logInfo then w:log("info","ELRS set on both: %s module value(s), then FC",#steps-1) end
        self:bind();w.linkNotice=nil;self:notice(L.linkSetBothStep)
      end,
      onCancel=function() self:notice(L.linkCancelled) end})
    if not shown then self:notice(L.linkNoDialog) end
  end
  -- One step of Set on both per idle wakeup: start it, then wait until the task is done and the
  -- module was read again, and check the value before the next step.
  -- The task just finished: keep its outcome for the plan step that started it, before the module
  -- walk that follows replaces the task's status.
  function c:taskDone()
    local plan=self.plan
    if plan and plan.started then plan.outcome=task.getStatus and task.getStatus() end
    self.rewalk,self.asked=nil,nil
  end
  function c:runPlan()
    local plan=self.plan
    if not plan or self:busy() or self.rewalk or not self.asked then return end
    local step=plan.steps[plan.at]
    if not step then
      self.plan,self.draft=nil,nil
      if w.logInfo then w:log("info","ELRS set on both done") end
      return
    end
    if not plan.started then
      plan.started=true;self.started=true
      if step.kind=="fc" then
        self:notice(L.linkSetBothFc);task.start(task.MODE_ELRS_TO_ROTORFLIGHT);self.rewalk=true
      else
        self.rewalk=true;task.selectOption(step.kind,step.index)
      end
      return
    end
    if step.kind=="fc" then
      -- The task owns the FC write and its EEPROM save. When the FC's RAM already holds the module
      -- values it saves nothing, which is also the state after a save of them failed: save them here.
      local outcome=plan.outcome
      if outcome=="status_rf_matches_elrs" then
        if not plan.saving then
          plan.saving=true
          if w.logDebug then w:log("debug","ELRS set on both: FC already holds the module values, saving them") end
          local epoch=self.epoch
          -- Sent only while this plan still stands: a stop (leaving the card) drops it unsent.
          local function current() return epoch==self.epoch and self.plan==plan end
          w:write("eeprom_write",function() return current() and {} or false end,function(_,err)
            if not current() then return end
            plan.outcome=err and "status_rotorflight_save_failed" or "status_rotorflight_updated"
            if w.logTrace then w:log("trace","ELRS set on both: FC save %s",tostring(err or "answered")) end
          end,true)
        end
        return
      end
      if outcome~="status_rotorflight_updated" then
        w:log("warn","ELRS set on both: FC step ended with %s",tostring(outcome))
        self.plan=nil;self:notice(L.linkSetBothFcFailed);return
      end
    else
      local field=step.kind=="rate" and task.getRateField() or task.getRatioField()
      if not field or field.selectedIndex~=step.index then
        w:log("warn","ELRS set on both: module %s not taken",step.kind)
        self.plan=nil;self:notice(L.linkSetBothFailed);return
      end
    end
    plan.at,plan.started=plan.at+1,nil
  end
  function c:rows()
    -- No text band: the table starts at the top; the ? sheet says why the sides must match.
    self.card.summary=""
    self.card.table={columns={L.linkFc,L.linkModule},rows={
      {label=L.linkRate,cells={function() local v=self:fcValues();return v or "--" end,
        function() local v=self:moduleValues();return v or "--" end}},
      {label=L.linkRatio,cells={function() local _,v=self:fcValues();return v or "--" end,
        function() local _,v=self:moduleValues();return v or "--" end}}}}
    self.card.rows={
      {kind="value",label=L.linkResult,get=function() return self:result() end,
        color=function() local r=self:result();return r==L.linkMatch and "ok" or r==L.linkDiffer and "warning" or nil end},
      {kind="group",label=L.linkMakeMatch,items={
        w:button(L.linkUseFc,function() self:sync(task.MODE_ROTORFLIGHT_TO_ELRS) end,function() return self:writable() end),
        w:button(L.linkUseModule,function() self:sync(task.MODE_ELRS_TO_ROTORFLIGHT) end,function() return self:writable() end)}},
      {kind="group",label=L.linkOther,items={
        self:picker("rate",L.linkRate),self:picker("ratio",L.linkRatio),
        w:button(L.linkSetBoth,function() self:setBoth() end,function() return self:writable() and not self.plan end)}}}
    self.card.rowsAtFoot=true
  end
  function c:updateSummary()
    local status,difference=self:status(),self:difference()
    self.summary=difference~="" and status.."\n"..difference or status
  end
  function c:tick()
    self:updateSummary()
    -- Said when the card is entered or the receiver settings stop fitting, not on every wakeup:
    -- a reminder about unsaved changes or a pending restart keeps the status line otherwise.
    local applies=self:applies()
    if self:current() and not applies and self.appliesSeen~=false then w.message=L.linkNeedsCrsf end
    self.appliesSeen=applies
    if not self:current() or not self:applies() or not w:usable() then
      if self:busy() then task.reset();self.asked,self.started=nil,nil end
      return
    end
    -- STATUS and wizard transactions retain priority; the task never becomes wizard dirty data.
    if not w.bus:idle() then return end
    -- A picker write leaves the task's fields as they were; walk the module again once it is done.
    if self.rewalk and not self:busy() then self:taskDone() end
    if not self.asked then self.asked=true;self:probe();return end
    if self:busy() then task.wakeup() end
    self:runPlan()
    self:updateSummary()
    local rate,ratio=task.getRateField(),task.getRatioField()
    local signature=tostring(rate)..":"..tostring(ratio)..":"..tostring(self:applies())
    if signature~=self.signature then
      self.signature=signature;self:rows();self:refresh()
    end
  end
  function c:enter(card)
    self.card,self.asked,self.signature,self.started=card,nil,nil,nil
    -- A draft or an unfinished Set on both does not outlive the visit.
    self.draft,self.plan=nil,nil
    w.linkNotice=nil;self.appliesSeen=nil
    self:updateSummary()
    task.setOwner("helicopter-elrs",function() return self:current() and self:applies() and w:usable() end)
    self:bind()
    self:rows();self:refresh()
  end
  return c
end
return M
