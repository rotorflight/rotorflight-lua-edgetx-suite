-- Dependencies are advice about recorded visits, never proof of a safe setup.
local M = {}
local prerequisites = {
  [3]={2}, [4]={2}, [5]={4}, [7]={6}, [9]={6}, [10]={1,6,7,8,9},
  [11]={9,10}, [12]={9}, [13]={6,7,10}, [14]={2,13}, [15]={13,14},
  [16]={14,15}, [17]={6,10}, [18]={1,14}, [19]={1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18}
}
function M.attach(w, store)
  local session = w:session()
  w.history = store.new(session.mcu_id, session.modelPreferencesFile)
  function w:updateHistoryHints()
    local missing, lines = 0, {}
    local mask = self.history.mask
    self.historyHint = (mask & (1 << (self.step-1))) ~= 0 and self.L.historyRecheck or nil
    for _, index in ipairs(prerequisites[self.step] or {}) do
      if (mask & (1 << (index-1))) == 0 then
        missing = missing + 1; lines[#lines+1] = self.L.steps[index]
      end
    end
    self.prerequisiteHint = missing > 0 and string.format(self.L.historyPrerequisites, missing) or nil
    self.prerequisiteDetails = missing > 0 and self.L.historyPrerequisitesHint .. "\n" .. table.concat(lines, "\n") or nil
    if self.history.invalid then self.historyHint = self.L.historyUnreadable end
  end
  -- The menu marks a step tile done from the same record (manifest `doneWhen`); it reads the
  -- session copy, and a changed record flips one condition so the menu rebuilds its cards.
  function w:shareHistory()
    local s = self:session()
    if type(s.mcu_id) ~= "string" then return end
    s.helicopterSetupHistory = { id = s.mcu_id, mask = self.history.mask }
    if self.menuChanged then self.menuChanged() end
  end
  function w:loadHistory() self.history:load(); self:updateHistoryHints(); self:shareHistory() end
  function w:persistHistory(mask, after, allowSkip)
    self:release(); self.transition, self.message = true, self.L.historySaving
    self:run(function()
      local saved = self.history:save(mask)
      self.transition = nil
      if saved then
        self.historyFailure, self.historyRetry, self.historySkip = nil, nil, nil
        self.message = self.L.ready
        self:updateHistoryHints(); self:shareHistory(); after()
      else
        self.historyFailure, self.message = true, self.L.historySaveFailed
        self.historyRetry = function() self.historyFailure=nil;self:persistHistory(mask,after,allowSkip) end
        self.historySkip = function()
          self.historyFailure, self.historyRetry, self.historySkip = nil, nil, nil
          self.message = self.L.historyNotSaved
          if allowSkip then after() else self:rebuild() end
        end
        self.historyAllowSkip = allowSkip; self:rebuild()
      end
    end)
  end
  function w:rememberStep(after)
    local mask = self.history.mask | (1 << (self.step-1))
    if mask == self.history.mask then after(); return end
    self:persistHistory(mask, after, true)
  end
  function w:buildHistory()
    self.cards = {self:cardDef(self.L.historyTitle,self.L.historyIntro.."\n"..self.L.historyHint,{
      self:value(self.L.historyCompleted,function() return string.format("%d/19",self.history.count) end),
      self:check("resetHistory",self.L.historyResetConfirm),
      self:button(self.L.historyReset,function()
        if not self:ack("resetHistory") then return end
        self:persistHistory(0,function()
          self.checks.resetHistory=nil;self.message=self.L.historyResetDone;self:rebuild()
        end,false)
      end)
    })}
    self.card = 1
  end
end
return M
