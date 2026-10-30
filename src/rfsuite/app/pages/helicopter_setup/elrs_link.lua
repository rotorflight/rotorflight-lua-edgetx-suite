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
    self.asked,self.signature,self.started=true,nil,nil
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
    return {kind="choice",label=label,values=values,allowUnset=true,
      enabled=function() return self:writable() end,
      get=function()
        if not self:applies() then return 0 end
        local current=kind=="rate" and task.getRateField() or task.getRatioField()
        for i,index in ipairs(indices) do if current and current.selectedIndex==index then return i end end
        return 0
      end,
      set=function(value)
        if not self:applies() then self:notice(L.linkNeedsCrsf);return end
        if not self:writable() then return end
        local current=kind=="rate" and task.getRateField() or task.getRatioField()
        local index=indices[value]
        if current and index~=nil and index~=current.selectedIndex then
          if next(w.dirty) then self:notice(L.saveFirst);return end
          local dialog=w:loadModule("ui/confirm_dialog.lua")
          local epoch=self.epoch
          local shown=dialog and dialog.show({title=L.linkConfirmTitle,
            message=string.format(L.linkPickerQuestion,values[value]),
            onConfirm=function()
              if epoch~=self.epoch or not self:writable() or next(w.dirty) then
                self:notice(L.linkCancelled);return
              end
              self:bind();w.linkNotice=nil;self.started=true;self.rewalk=true;task.selectOption(kind,index)
            end,
            onCancel=function() self:notice(L.linkCancelled) end})
          if not shown then self:notice(L.linkNoDialog) end
        end
      end}
  end
  function c:rows()
    self.card.summary=function() return self.summary end
    self.card.rows={
        w:button(L.linkUseFc,function() self:sync(task.MODE_ROTORFLIGHT_TO_ELRS) end,
          function() return self:writable() end),
        w:button(L.linkUseModule,function() self:sync(task.MODE_ELRS_TO_ROTORFLIGHT) end,
          function() return self:writable() end),
        self:picker("rate",L.linkRate),self:picker("ratio",L.linkRatio)}
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
    if self.rewalk and not self:busy() then self.rewalk,self.asked=nil,nil end
    if not self.asked then self.asked=true;self:probe();return end
    if self:busy() then task.wakeup() end
    self:updateSummary()
    local rate,ratio=task.getRateField(),task.getRatioField()
    local signature=tostring(rate)..":"..tostring(ratio)..":"..tostring(self:applies())
    if signature~=self.signature then
      self.signature=signature;self:rows();self:refresh()
    end
  end
  function c:enter(card)
    self.card,self.asked,self.signature,self.started=card,nil,nil,nil
    w.linkNotice=nil;self.appliesSeen=nil
    self:updateSummary()
    task.setOwner("helicopter-elrs",function() return self:current() and self:applies() and w:usable() end)
    self:bind()
    self:rows();self:refresh()
  end
  return c
end
return M
