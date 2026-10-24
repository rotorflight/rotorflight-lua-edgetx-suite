-- Optional telemetry hints never acknowledge writes or replace the MSP lock.
local M = {}
function M.attach(w, state, sensors)
  local due, source = 0, "system_status"
  function w:pollSystemState()
    if not self.ready or self.error or self.historyMode then
      self.systemStatus, self.systemConfig, self.systemHint = nil, nil, nil
      return
    end
    local now = getTime()
    if now < due then return end
    due = now + 25
    local value = state.read(sensors, source)
    self.systemReads = (self.systemReads or 0) + 1
    if source == "system_status" then self.systemStatus = value; source = "system_config"
    else self.systemConfig = value; source = "system_status" end
    local status, config, L = self.systemStatus, self.systemConfig, self.L
    local hint
    self.systemProfiles = nil
    if config and config.saving then hint = L.fcSaving
    elseif config and config.reboot_required then hint = L.fcReboot
    elseif config and config.unsaved_changes then hint = L.fcUnsaved
    elseif status and status.override_active then hint = L.fcOverride
    elseif status and self.step == 1 and status.acc_not_calibrated then hint = L.fcAcc
    elseif status and self.step == 2 and not status.rx_link_up then hint = L.fcReceiver
    elseif config and config.pid_profile > 0 and config.rate_profile > 0 and config.battery_profile > 0 and
      (self.overview or self.step == 4 or self.step == 5) then
      hint = string.format(L.fcProfiles, config.pid_profile, config.rate_profile, config.battery_profile)
      self.systemProfiles = true
    end
    self.systemHint = hint
  end
  function w:feedbackText()
    if self.error or self.historyFailure then return "" end
    if self.disconnectExit then return self.L.disconnected end
    if (self.cleanupPending or 0)>0 then return self.L.releasingTests end
    if self.recoveryRequired then return self.L.recoveryAwaiting end
    if self.historyMode then return self.history.invalid and self.L.historyUnreadable or self.message or "" end
    -- The untimed-override warning stays until another message answers what the pilot just did.
    local m = self.message
    if self.legacyHold and (m == nil or m == self.L.persistent or m == self.L.holding or m == self.L.neutralHold or
      m == self.L.ready or m == self.L.saved) then return self.L.persistent end
    if not self.error and not self.transition and (self.message == self.L.ready or self.message == self.L.saved) then
      if self.systemHint and not self.systemProfiles then return self.systemHint end
      return self.prerequisiteHint or self.historyHint or self.systemHint or self.message
    end
    return self.message or ""
  end
end
return M
