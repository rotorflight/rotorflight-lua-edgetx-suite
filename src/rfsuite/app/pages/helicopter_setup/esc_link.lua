-- Visit-local ESC controls. Transactions and family capabilities live in esc_params.
local M = {}
function M.attach(w, params, status)
  function w:analogThrottle()
    local protocol = self.data.motor_config.motor_pwm_protocol
    return protocol >= 0 and protocol <= 3
  end
  function w:escGovernorMode()
    return (self.data.feature_config.enabledFeatures & (1 << 26)) ~= 0 and self.data.governor_config.gov_mode or 0
  end
  function w:escFamily()
    local family = params.families[self.data.esc_sensor_config.protocol]
    if self.escParams and self.escParams.family ~= family then self.escParams = nil end
    return family
  end
  function w:escLinkReady()
    local config = self.data.esc_sensor_config
    local motor = self.data.motor_telemetry and self.data.motor_telemetry.motors[1]
    return self:escFamily() and self:escGovernorMode() ~= 4 and config.half_duplex == 1 and self:hasPort(1024)
      and not self.rebootPending and not self.trial and not self.dirty.esc_sensor_config and not self.dirty.serial_config
      and motor and (motor.voltage > 0 or motor.temperature > 0)
      and self.motorTelemetryAt and getTime() - self.motorTelemetryAt <= 300
  end
  function w:escRefresh()
    self.buildRequested = true; self:rebuild()
  end
  function w:escResult(block, err)
    self.escBusy = nil
    self.escResultKey = err and "escLinkFailure" or "escVerified"
    if err == "cancelled" then self.escResultKey = "escNotWritten" end
    -- A readback mismatch after an acknowledged write may need a battery restart.
    if err == "restart" or err == "mismatch" then self.escResultKey = "escRestart" end
    if err and self.escOperation == "range" then
      self.rangeSource = nil
      -- The flight controller is saved before the ESC is written; say so when only it took the values.
      if self.escFcWritten and err ~= "restart" and err ~= "mismatch" then self.escResultKey = "escRangeFcOnly" end
    end
    if not err and self.escOperation == "range" and self.escRangeExpected then
      local m, e = self.data.motor_config, self.escRangeExpected
      if m.mincommand == e.mincommand and m.minthrottle == e.minthrottle and m.maxthrottle == e.maxthrottle then
        self.rangeSource = "esc_link"
      end
    end
    self:escRefresh()
  end
  function w:readEsc()
    if self.escBusy or not self:escLinkReady() then return end
    self.escParams = self.escParams or params.new(self.bus, self:escFamily(), status)
    self.escBusy, self.escAttempted = true, true
    self.message = self.L.loading
    if self.escParams.changes or self.escParams.restart then
      self.escParams:verify(function(d, failure) self:escResult(d, failure) end)
      return
    end
    self.escParams:read(function(block, err)
      self.escBusy = nil
      self.escResultKey = err and "escLinkFailure" or nil
      if err and self.rangeSource == "esc_link" then
        self.rangeSource, self.rangeNeedsVerification = nil, self.escRangeExpected ~= nil
      end
      if block and self.rangeChoice == "esc_link" and self.escRangeExpected and self.rangeNeedsVerification then
        self.escOperation, self.rangeNeedsVerification = "range", nil
        self.escParams.changes = self.escRangeChanges
        self.escParams:verify(function(d, failure) self:escResult(d, failure) end)
        self.escBusy = true
      else self:escRefresh() end
    end)
  end
  -- Runs after load/scene construction, never from the page's build path.
  function w:escTick()
    if self.step ~= 11 or self.overview then return end
    if not self:escLinkReady() then return end
    if not self.escAttempted then self:readEsc(); return true end
  end
  function w:escCanWrite()
    return self:usable() and self:escLinkReady() and not self.escBusy and self.escParams and self.escParams.block
      and not self.escParams.changes
  end
  function w:useEscRange()
    if self.rangeChoice ~= "esc_link" or not self:analogThrottle() or not self:escCanWrite() then return end
    local family, draft = self:escFamily(), self.escRangeDraft
    if not params.hasRange(family, self.escParams.block) or not draft or draft.minthrottle <= 1000 or draft.maxthrottle <= draft.minthrottle then
      self.message = self.L.escRangeInvalid; return
    end
    local limits = self.bus.apis.motor_config.limits
    for _, key in ipairs({"minthrottle", "maxthrottle"}) do
      if draft[key] < limits[key].min or draft[key] > limits[key].max then self.message = self.L.escRangeInvalid; return end
    end
    local expected = {mincommand = 1000, minthrottle = draft.minthrottle, maxthrottle = draft.maxthrottle}
    -- Assumption: stick_zero_us is the 0% pulse and stick_range_us is its span;
    -- the implied 100% point is zero + range.
    local changes = {[family.range.zero] = expected.minthrottle,
      [family.range.span] = expected.maxthrottle - expected.minthrottle}
    self.escBusy, self.escOperation, self.rangeSource, self.escFcWritten = true, "range", nil, nil
    self.escRangeExpected, self.escRangeChanges = expected, changes
    self.escParams:write(changes, function(d, err) self:escResult(d, err) end, function(send)
      self:applyEdit(function()
        for key, value in pairs(expected) do self.data.motor_config[key] = value end
        self:touch("motor_config", true)
        self:save(function()
          self:read("motor_config",function(actual)
            self.data.motor_config = actual
            if not params.matches(actual,expected) then self:escResult(nil,"fc_mismatch"); return end
            self.escFcWritten = true
            send()
          end)
        end)
      end, function() self:escResult(nil,"cancelled") end)
    end)
  end
  function w:setEscMode(value)
    if not self:escCanWrite() then return end
    local family = self:escFamily()
    local expected = params.expected(family, self:escGovernorMode())
    if not params.hasMode(family, self.escParams.block) or not expected then return end
    local valid = false; for _, mode in ipairs(expected) do if value == mode then valid = true end end
    if not valid then return end
    self.escBusy, self.escOperation = true, "mode"
    self.message = self.L.saving
    self.escParams:write({[family.modeField] = value}, function(d, err) self:escResult(d, err) end,
      function(send) self:applyEdit(send, function() self:escResult(nil,"cancelled") end) end)
  end
  function w:verifyEscRestart()
    if self.escBusy or not self:usable() or not self.escParams or not self.checks.escBatteryCycle then return end
    self.checks.escBatteryCycle = nil
    self.escBusy = true
    self.escParams:verify(function(d, err) self:escResult(d, err) end, true)
  end
  function w:escModeName(value)
    local family = self:escFamily()
    local text = family and family.modes[value] or self.L.unknown
    return self.i18n and self.i18n.resolve and self.i18n.resolve(text) or text
  end
  function w:escCards(cards)
    local L, family = self.L, self:escFamily()
    if self:escGovernorMode() == 4 then return end
    local function add(title, detail, rows, summary)
      local card = self:cardDef(title, detail, rows); card.summary = summary
      cards[#cards + 1] = card
    end
    if self:analogThrottle() then
      local routes, labels = {}, {}
      if self.data.motor_config.motor_pwm_protocol == 0 then routes[#routes+1], labels[#labels+1] = "calibrate", L.rangeCalibrate end
      routes[#routes+1], labels[#labels+1] = "asserted", L.rangeManual
      if family and family.range and (not self.escParams or not self.escParams.block or params.hasRange(family, self.escParams.block)) then
        routes[#routes+1], labels[#labels+1] = "esc_link", L.rangeLink
      end
      add(L.throttleRange,L.rangeChoiceHelp,{{kind="choice", label=L.rangeQuestion, values=labels, fullWidth=true, allowUnset=true,
        get=function()
          for i,route in ipairs(routes) do if route == self.rangeChoice then return i end end
          return 0
        end,
        set=function(value)
          if not routes[value] or self.escBusy then return end
          self.rangeChoice, self.rangeSource, self.calibratedEsc = routes[value], nil, nil
          self.escRangeExpected,self.escRangeChanges,self.escOperation=nil,nil,nil
          self.rangeNeedsVerification = nil
          self.checks.rangeAsserted = nil; self:escRefresh()
        end}},L.rangeQuestion)
      if self.rangeChoice == "asserted" then
        local confirm = self:check("rangeAsserted", L.rangeConfirm)
        confirm.fullWidth = true
        local set = confirm.set
        confirm.get = function() return self.rangeSource == "asserted" and 2 or 1 end
        confirm.set = function(value) set(value); self.rangeSource = value == 2 and "asserted" or nil end
        add(L.throttleRange,L.rangeManualHelp,{confirm},L.rangeConfirm)
      end
    end
    if not family then return end
    local s = self.escParams
    local block = s and s.block
    local function linkState()
      return self.escBusy and L.loading or self.escResultKey and L[self.escResultKey] or
        not self:escLinkReady() and L.escLinkPrerequisite or self.escParams and self.escParams.block and L.ready
        or L.escLinkFailure
    end
    local stateText = linkState()
    local selected = 1
    -- A move between cards builds them again when the link card would now read differently
    -- or a mode was picked but not written; both start from the current state then.
    cards.stale = function() return linkState() ~= stateText or selected ~= 1 end
    add(L.escLink,L.escLinkHelp,{
      self:button(L.escRead,function() self:readEsc() end,function() return not self.escBusy and self:escLinkReady() end)
    }, stateText)
    if s and s.changes then
      add(L.escRestartTitle,L.escRestartHelp,{
        self:check("escBatteryCycle",L.escBatteryCycle),
        self:button(L.escVerify,function() self:verifyEscRestart() end,function() return not self.escBusy end)
      },L.escRestart)
    end
    if not block then return end
    if params.hasMode(family, block) then
      local expected = params.expected(family,self:escGovernorMode())
      local matching = not expected
      for _,mode in ipairs(expected or {}) do if block[family.modeField] == mode then matching = true end end
      local currentMode = self:escModeName(block[family.modeField])
      local rows = {self:value(L.escCurrentMode,function() return currentMode end)}
      if not matching then
        local values = {}; for i,mode in ipairs(expected) do values[i] = self:escModeName(mode) end
        rows[#rows+1] = {kind="choice", label=L.escExpectedMode, values=values,
          get=function() return selected end, set=function(v) selected=v end}
        rows[#rows+1] = self:button(L.escSetMode,function() self:setEscMode(expected[selected]) end,
          function() return self:escCanWrite() end)
      end
      add(L.escMode,L.escModeHelp,rows,matching and L.escModeShort or L.escModeWarning)
    else
      -- HW1128/HW1132 have no mode field: report that on the link card, without a mode card.
      add(L.escLink,L.escLinkHelp,{self:value(L.escCurrentMode,function() return L.escModeUnavailable end)},L.escModeUnavailable)
    end
    if self:analogThrottle() and self.rangeChoice == "esc_link" and params.hasRange(family, block) then
      add(L.escCurrentRange,L.escCurrentHelp,{
        self:value(L.escModel,function() return block.model_name or block.esc_type or block.esc_model or L.unknown end),
        self:value(L.escFirmware,function() return block.firmware_version or L.unknown end),
        self:value(L.escZero,function() return block[family.range.zero] end),
        self:value(L.escFull,function() return block[family.range.zero] + block[family.range.span] end)
      },L.escCurrentShort)
      self.escRangeDraft = self.escRangeDraft or {minthrottle=1070,maxthrottle=2000}
      local rows = {self:value(L.rangeStop,function() return 1000 end)}
      for _, item in ipairs({{"minthrottle",L.rangeMin},{"maxthrottle",L.rangeMax}}) do
        local key, label = item[1], item[2]
        local limit = self.bus.apis.motor_config.limits[key]
        rows[#rows+1] = {kind="number",label=label,min=limit.min,max=limit.max,
          get=function() return self.escRangeDraft[key] end,
          set=function(v) if not self.escBusy then self.escRangeDraft[key]=v end end}
      end
      rows[#rows+1] = self:button(L.rangeUse,function() self:useEscRange() end,function() return self:escCanWrite() end)
      add(L.throttleRange,L.escRangeHelp,rows,L.escRangeShort)
    end
  end
end
return M
