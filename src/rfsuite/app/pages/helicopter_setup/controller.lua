local M = {}
local BASE = "/SCRIPTS/TOOLS/rfsuite-core/"
local READS = { "status", "boxids", "mode_ranges", "mode_ranges_extra", "adjustment_ranges",
  "feature_config", "board_info", "telemetry_config", "board_alignment_config", "serial_config", "rx_map", "rx_config", "rc_config",
  "motor_config", "esc_sensor_config", "governor_config", "mixer_config", "mixer_input",
  "servo_configurations", "servo", "rc_tuning", "tail_motor_output", "name",
  "battery_config", "battery_profile", "smartfuel_config" }
local STEPS = { "sensors", "receiver", "modes", "profiles", "rates", "swash", "servoType", "governor", "motor",
  "connect", "escTelemetry", "throttle", "servos", "direction", "level", "pitch", "tail", "gyro", "finish" }
local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}; for k, x in pairs(v) do out[k] = copy(x) end; return out
end
local function now() return getTime() end
local TAG = "rfsuite.helicopter_setup"
-- Equal values in an equal shape. A value equal to its counterpart needs no call of its own,
-- which keeps a whole configuration block within one pass.
local function same(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return a == b end
  for k, x in pairs(a) do
    local y = b[k]
    if x ~= y and not (type(x) == "table" and same(x, y)) then return false end
  end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

function M.new(runtime, transport, mathModule, labels)
  local w = { runtime = runtime, math = mathModule, L = labels, data = {}, saved = {}, sent = {}, dirty = {},
    step = 1, card = 1, ready = false, active = true, holds = {}, live = {}, checks = {},
    progress = 0, message = labels.loading, generation = 0, selectedServo = 0, percent = 10, edits = 0 }
  -- The debug level, which decides what reaches the Session Logs, is read once per visit: it is
  -- chosen on the developer settings page, which is not open while this page is. At a level that
  -- drops a line, each logging site costs one field test and no message is built.
  local Log = _G.rfsuite and _G.rfsuite.Log
  w.logInfo = Log ~= nil and Log.wanted("info") == true
  w.logDebug = Log ~= nil and Log.wanted("debug") == true
  function w:log(level, fmt, ...) Log.emitf(TAG, level, fmt, ...) end
  -- The key of a label, so a log line names the message rather than its translation.
  local function labelKey(text)
    for key, value in pairs(labels) do if value == text then return key end end
  end
  -- A status line built from a template has no label of its own: the site that builds it names
  -- the template's key here, at INFO only.
  function w:keyMessage(key) self.messageKey, self.messageText = key, self.message end
  -- One line when the step, the card, the status line or the error changes; a steady visit
  -- writes nothing. The status line is logged as the pilot sees it, flight controller hints and
  -- cleanup notices included; an empty line (an error is shown) has the error line instead.
  function w:logChanges()
    if self.step ~= self.loggedStep or self.card ~= self.loggedCard or self.overview ~= self.loggedOverview then
      self.loggedStep, self.loggedCard, self.loggedOverview = self.step, self.card, self.overview
      if self.overview then self:log("info", "step list")
      else self:log("info", "step %s card %s", STEPS[self.step], self.card) end
    end
    local shown = self.feedbackText and self:feedbackText() or self.message
    if shown ~= self.loggedMessage then
      self.loggedMessage = shown
      if shown ~= nil and shown ~= "" then
        local key = labelKey(shown)
        if not key then
          if shown == self.messageText then key = self.messageKey
          elseif shown == self.systemHint and self.systemProfiles then key = "fcProfiles"
          elseif shown == self.prerequisiteHint then key = "historyPrerequisites" end
        end
        self:log("info", "message %s", key or "?")
      end
    end
    local e = self.error
    if e ~= self.loggedError then
      self.loggedError = e
      if type(e) == "string" then
        local api, reason = string.match(e, "^([%w_]+): (.*)$")
        if api then self:log("info", "error %s: %s", api, labelKey(reason) or reason)
        else self:log("info", "error %s", e) end
      end
    end
  end
  function w:loadModule(path)
    return assert(loadScript(BASE .. path, "t"))()
  end
  function w:session() return _G.rfsuite and _G.rfsuite.session or {} end
  -- The setup steps use MSP added in API 12.10 (Rotorflight 4.7). The version is the "major.minor"
  -- string the Suite reports; an unknown version is left to the Suite's own connect check.
  function w:apiSupported()
    local major, minor = string.match(tostring(self:session().apiVersion or ""), "^(%d+)%.(%d+)$")
    if not major then return true end
    major, minor = tonumber(major), tonumber(minor)
    return major > 12 or (major == 12 and minor >= 10)
  end
  function w:channelSnapshot(api)
    local at
    if api=="rc" then at=self.rcAt elseif api=="rx_channels" then at=self.rxChannelsAt else return nil end
    local d=self.data[api]
    if not at or now()<at or now()-at>200 or not d or not d.channels or #d.channels<5 then return nil end
    local copy={}
    for i=1,math.min(18,#d.channels) do copy[i]=d.channels[i] end
    return copy
  end
  function w:allowed()
    local s = self:session()
    if not s.mcu_id or s.mcu_id == "" then return false end
    if not self.identity then self.identity = s.mcu_id end
    local armed = self.runtime.armedReading()
    return self.active and s.fblConnected == true and armed ~= true and not self.statusArmed
      and (not self.identity or self.identity == s.mcu_id)
  end
  function w:fail(api, reason)
    self.escBusy = nil
    self.bus:cancel()
    local dropped = self.pendingEditDropped
    self.statusQueued, self.pendingEdit, self.pendingEditDropped = nil, nil, nil
    if dropped then dropped() end
    self.statusFailure = api == "status" or api == "arming_disable"
    self.error = api .. ": " .. tostring(reason)
    self.message, self.transition = self.L.failed, nil
    self.closing = nil
    if api~="cleanup" then self:release() end
    -- A failed multi-profile transaction must restore the selected profile, too.
    if self.restoreProfile and self:allowed() then
      self.bus:add({ api = "set_pid_profile", write = true, payload = { self.restoreProfile }, optional = true })
      self.restoreProfile = nil
    end
  end
  -- The error screen's detail line: the MSP name as the transport reports it, the reason in the
  -- pilot's language where it is one of the wizard's own.
  local reasons = { ["lock lost"] = "errLockLost", ["not active"] = "errLockNotActive", ["servo count"] = "errServoCount",
    configuration = "errConfiguration", timeout = "errTimeout", reply = "errReply", decode = "errDecode",
    payload = "errPayload", cleared = "errCleared", cancelled = "errCancelled", max_retries = "errMaxRetries",
    ["short status"] = "errShortStatus", link = "errLink", arming = "errArming" }
  function w:errorText()
    local e = self.error
    if type(e) ~= "string" then return "" end
    local api, reason = string.match(e, "^([%w_]+): (.*)$")
    if not api then return reasons[e] and self.L[reasons[e]] or e end
    return api .. ": " .. (reasons[reason] and self.L[reasons[reason]] or reason)
  end
  w.bus = transport.new(runtime, function() return w:allowed() end, function(a, r) w:fail(a, r) end)
  function w:loadProgress()
    self.progress = self.progress + 1
    self.loadingText = string.format("%s %d/%d", self.L.loading, self.progress, self.loadTotal)
  end
  function w:readRecords(name, api, field, servo)
    local records, index = {}, 0
    self.bus:add({ expand = function()
      local count = servo and self.data.status.servo_count or 42
      if index >= count then return end
      local slot, raw = index, index
      if servo and count > 8 then
        local pwm = count - 18
        if slot >= pwm then raw = slot - pwm + 8 end
      end
      index = index + 1
      return { api = api, payload = { raw }, after = function(d)
        records[servo and slot or slot + 1] = d[field]
        self:loadProgress()
      end }
    end })
    self:run(function()
      self.data[name] = servo and { servo_count = index, servos = records } or { adjustment_ranges = records }
    end)
  end
  function w:read(api, after, optional, payload)
    self.bus:add({ api = api, payload = payload, optional = optional, after = after })
  end
  function w:write(api, data, after, optional, decode)
    self.bus:add({ api = api, write = true, data = data, after = after, optional = optional, decode = decode })
  end
  function w:action(api, payload, after, optional)
    self.bus:add({ api = api, write = true, payload = payload, after = after, optional = optional })
  end
  function w:run(fn) self.bus:add({ run = fn }) end
  function w:rebuild() if self.requestRebuild then self.requestRebuild() end end
  function w:usable()
    return self.ready and self.locked and not self.error and not self.transition and (self.cleanupPending or 0)==0 and self:allowed()
      and now() - (self.statusAt or 0) <= 300
  end
  function w:acceptStatus(d)
    self.data.status, self.statusAt = d, now()
    if self.statusWaiting then
      self.statusWaiting, self.message = nil, self.beforeStatusWait or self.L.ready
      self.beforeStatusWait = nil
    end
    if (d.reboot_required or 0) ~= 0 then self.rebootPending = true end
    if self.locked and (d.arming_disable_flags & (1 << 16)) == 0 then
      self.locked = false; self:fail("arming_disable", "lock lost"); return
    end
    self.statusArmed = false
    for i, id in ipairs(self.data.boxids and self.data.boxids.box_ids or {}) do
      if id == 0 then self.statusArmed = (d.flight_mode_flags & (1 << (i - 1))) ~= 0; break end
    end
    if self.calibrationAt and now() - self.calibrationAt >= 200 and (d.arming_disable_flags & ((1 << 12) | (1 << 23))) == 0 then
      self.calibrationAt = nil; self.message = self.L.calibrated
    elseif self.calibrationAt and now()-self.calibrationAt>=1000 then
      self.calibrationAt=nil;self.message=self.L.calibrationFailed
    end
    local edit, dropped = self.pendingEdit, self.pendingEditDropped
    self.pendingEdit, self.pendingEditDropped = nil, nil
    if edit and self:usable() then edit() elseif dropped then dropped() end
  end
  -- A native list or number editor can hold the page for seconds without a wakeup,
  -- so the STATUS that authorizes an edit may have expired by the time the value
  -- arrives. The value is kept and applied only once a fresh STATUS confirms the
  -- arming lock; it is dropped if that STATUS does not.
  function w:applyEdit(fn, dropped)
    if self:usable() then fn(); return end
    if not (self.ready and self.locked and not self.error and self:allowed()) then
      if dropped then dropped() end
      return
    end
    self.pendingEdit, self.pendingEditDropped = fn, dropped
    if not self.statusQueued then
      self.statusQueued = true
      self.bus:urgent({ api = "status", after = function(d)
        self.statusQueued = nil; self:acceptStatus(d)
      end })
    end
  end
  function w:retry()
    if not self.bus:idle() or not self:allowed() or (self.cleanupPending or 0)>0 then return end
    if self.cleanupFailed or self.needsRelease then self:release(true) end
    self.error, self.transition, self.locked = nil, true, false
    self.statusWaiting, self.statusQueued, self.beforeStatusWait = nil, nil, nil
    self.canEdit, self.canNext, self.message = false, false, self.L.checkingStatus
    self:write("arming_disable", { disabled = true })
    self:read("status", function(d)
      if (d.arming_disable_flags & (1 << 16)) == 0 then self:fail("arming_disable", "not active"); return end
      self.locked = true; self:acceptStatus(d)
      if not self.ready then self:load() else self.transition = nil; self:rebuild() end
    end)
  end
  function w:touch(api, reboot, live)
    self.dirty[api] = true
    self.edits = self.edits + 1
    if reboot then self.rebootPending = true end
    if live then self.live[api] = true end
    self.message = reboot and self.L.pendingReboot or live and self.L.liveApplied or self.L.pendingSave
  end
  function w:field(api, key, value, reboot, live)
    if not self:usable() then return end
    if self.data[api][key] == value then return end
    self.data[api][key] = value; self:touch(api, reboot, live)
  end
  -- A block of `sent` is the `saved` table itself while both hold the same values. Rows are
  -- replaced, never changed in place, so a block takes its own copy of the block and its row
  -- list before its first row is replaced.
  function w:sentRows(api, key)
    local block = self.sent[api]
    if block and block == self.saved[api] and block[key] then
      local own, rows = {}, {}
      for k, x in pairs(block) do own[k] = x end
      for k, x in pairs(block[key]) do rows[k] = x end
      own[key] = rows; self.sent[api] = own; block = own
    end
    return block and block[key]
  end
  -- Record that FC RAM holds `data` for this block: the `saved` table when it holds the same.
  function w:sentFromData(api)
    local saved, d = self.saved[api], self.data[api]
    self.sent[api] = same(saved, d) and saved or copy(d)
  end
  -- Snapshot the exact row queued for FC RAM, including the extras carried by a mode write.
  function w:rangeJob(api, index, from)
    local d = from or self.data
    local r = copy(d[api][api][index]); self:sentRows(api, api)[index] = r
    if api == "mode_ranges" then
      local extra = copy(d.mode_ranges_extra.mode_ranges_extra[index] or {})
      self:sentRows("mode_ranges_extra", "mode_ranges_extra")[index] = extra
      return { api = "set_mode_range", write = true, payload = { index - 1, r.id, r.auxChannelIndex,
        self.math.step(r.range.start), self.math.step(r.range["end"]), extra.modeLogic or 0, extra.linkedTo or 0 } }
    end
    return { api = "set_adjustment_range", write = true, payload = self.math.adjustPayload(index - 1, r) }
  end
  function w:sendDirty(api, from)
    local d = from or self.data
    -- Generate at most one indexed message per call. A full adjustment table
    -- must not be encoded in a button callback or an MSP reply.
    local cursor = 0
    local count = api == "servo_configurations" and (d[api].servo_count > 8 and d[api].servo_count-18 or d[api].servo_count) or
      api == "mixer_input" and 4 or api == "serial_config" and 12 or
      api == "mode_ranges" and #d[api].mode_ranges or
      api == "adjustment_ranges" and #d[api].adjustment_ranges
    -- Mode and adjustment tables are written row by row, and a full table is dozens of
    -- messages. Only rows that differ from the last queued FC RAM snapshot are sent.
    -- Live edits can return to the saved value while FC RAM still holds an earlier edit.
    local other = self.sent
    local servos, mixer = api == "servo_configurations", api == "mixer_input"
    local rows = (api == "mode_ranges" or api == "adjustment_ranges" or servos or mixer)
      and self:sentRows(api, servos and "servos" or mixer and "inputs" or api)
    local function unchanged(index)
      if not rows then return false end
      if servos then return same(d[api].servos[index - 1], rows[index - 1]) end
      if mixer then return same(d[api].inputs[index], rows[index]) end
      if not same(d[api][api][index], rows[index]) then return false end
      if api ~= "mode_ranges" then return true end
      local extra, otherExtra = d.mode_ranges_extra, other.mode_ranges_extra
      return extra ~= nil and otherExtra ~= nil and
        same(extra.mode_ranges_extra[index], otherExtra.mode_ranges_extra[index])
    end
    if count then
      self.bus:add({ expand = function()
        cursor = cursor + 1
        -- Compare a few rows per pass at most; an unchanged stretch yields an empty job.
        local skipped = 0
        while cursor <= count and unchanged(cursor) do
          cursor, skipped = cursor + 1, skipped + 1
          if skipped == 4 and cursor <= count then cursor = cursor - 1; return { run = function() end } end
        end
        if cursor > count then return nil end
        local index = cursor
        if api == "servo_configurations" then
          local r = copy(d[api].servos[index - 1]); rows[index - 1] = r
          return { api = api, write = true, data = { index = index - 1, servo = r } }
        elseif api == "mixer_input" then
          local r = copy(d[api].inputs[index]); rows[index] = r
          return { api = api, write = true, data = { index = index, rate = r.rate, min = r.min, max = r.max } }
        elseif api == "serial_config" then
          local p = {}
          for _, key in ipairs({ "identifier", "function_mask", "msp_baud_index", "gps_baud_index", "telem_baud_index", "blackbox_baud_index" }) do
            p[key] = d[api]["port_" .. index .. "_" .. key]
          end
          if p.identifier == nil then return { run = function() end } end
          return { api = api, write = true, data = p }
        else
          return self:rangeJob(api, index, d)
        end
      end })
      return
    end
    self:write(api, function()
      self.sent[api] = copy(d[api]); return d[api]
    end)
  end
  function w:release(all)
    if self.stopLink then self:stopLink() end
    local held, motor = self.holds, self.motorHold
    self.holds, self.motorHold, self.listen, self.legacyHold = {}, nil, nil, nil
    if self.rx then self.rx.detect, self.rx.record = nil, nil end
    if self.modeListen then self.modeListen.id = nil end
    if self.profile then self.profile.listen, self.profile.record = nil, nil end
    if self.stopTrial then self:stopTrial() end
    self.bus:dropOverrides()
    local q = self.bus:queue()
    if not q then return end
    q:clear("helicopter-overrides")
    if not self:allowed() then self.needsRelease = true; return end
    -- These modules are preloaded on entry. The cleanup owner survives the host's page clear.
    local apis = self.bus.apis
    local jobs={}
    local full=all or self.needsRelease
    local function send(api,data)
      local mod=apis[api]
      if not mod then self.cleanupFailed,self.needsRelease=true,true;return end
      jobs[#jobs+1]={command=mod.writeCommand,payload=mod.buildWritePayload(data)}
    end
    if full then
      for i=0,7 do send("servo_override",{servo_id=i,action=2001}) end
      for i=1,4 do send("mixer_override",{index=i,value=2501}) end
      for i=0,3 do send("motor_override",{index=i,value=0}) end
    else
      for _,h in pairs(held) do
        if h.kind=="servo" then send("servo_override",{servo_id=h.index,action=2001})
        else send("mixer_override",{index=h.index,value=2501}) end
      end
      if motor then send("motor_override",{index=motor.index,value=0}) end
    end
    if #jobs==0 then return end
    local index,failed=1,false
    self.cleanupPending=(self.cleanupPending or 0)+#jobs
    self.canEdit,self.canNext=false,false
    self.needsRelease=nil
    -- One OFF is in flight at a time. Each callback queues at most one next
    -- message, so STATUS can run between them and the owner survives page close.
    local dispatch
    local function complete(_,reason)
      self.cleanupPending=self.cleanupPending-1
      if reason then
        failed,self.cleanupFailed,self.needsRelease=true,true,true
      end
      index=index+1
      local session=self:session()
      local armed=self.runtime.armedReading()
      local connected=session.fblConnected==true and session.mcu_id==self.identity and armed~=true
      if reason=="cleared" or not connected then
        self.cleanupPending=self.cleanupPending-(#jobs-index+1)
        self.cleanupFailed,self.needsRelease=true,true;return
      end
      if index<=#jobs then dispatch()
      elseif full then self.cleanupFailed,self.needsRelease=failed,failed or nil end
    end
    dispatch=function()
      local job=jobs[index]
      -- MSP replies match only the command (tasks/msp/queue.lua): a late retry ACK could
      -- confirm the next OFF even if it never arrived. One attempt keeps a lost reply a cleanup failure.
      q:add({command=job.command,payload=job.payload,isWrite=true,client="helicopter-cleanup",
        maxRetries=0,processReply=function(m) complete(m,nil) end,errorHandler=complete})
    end
    dispatch()
  end
  function w:afterRelease(fn)
    local done=false
    self.bus:add({expand=function()
      if (self.cleanupPending or 0)>0 then return {run=function() end} end
      if self.cleanupFailed or self.needsRelease then self:fail("cleanup",self.L.cleanupFailed);return end
      if not done then done=true;return {run=fn} end
    end})
  end
  function w:hold(kind, index, value)
    if not self:usable() or self.rebootPending then return end
    local timed=self.timedMixer
    if kind=="servo" then timed=self.timedServo end
    self.message = not timed and self.L.persistent or value == 0 and self.L.neutralHold or self.L.holding
    self.legacyHold = not timed
    self.holds[kind .. index] = { kind = kind, index = index, value = value, due = 0, timed=timed }
  end
  function w:holdAxes(axis, value, passthrough)
    for _, i in ipairs({ 1, 2, 4 }) do self:hold("mixer", i, passthrough and 2502 or (i == axis and value or 0)) end
  end
  function w:spin(index, direction)
    if not self:usable() or not self.bladesOff or self.rebootPending then return end
    if index >= (self.data.status.motor_count or 0) then return end
    if index == 0 and self.data.motor_config.motor_pwm_protocol == 0 and not self.calibratedEsc
      and self.rangeSource ~= "asserted" and self.rangeSource ~= "esc_link" then
      self.message = self.L.calibrateEscFirst; return
    end
    self.message = self.L.holding
    if not self:canSpin(index) then self.message=self.L.motorFailed;return end
    self.motorHold = { index = index, value = self.percent * 10 * direction, mode="spin", direction=direction, due = 0, untilAt = now() + 1500 }
  end
  function w:stopMotor()
    self.motorHold = nil
    self.bus:dropOverrides()
    local q = self.bus:queue()
    if q then q:clear("helicopter-overrides") end
    if self:allowed() then
      for i = 0, 1 do self:write("motor_override", { index = i, value = 0 }) end
    end
  end
  function w:profileLoop(kind, count, apply, indexes, loaded)
    -- A nil apply reads profiles without profile writes or rollback snapshots; selection still restores.
    local status = self.data.status
    local original = kind == "rates" and status.current_control_rate_profile_index + 128 or status.current_pid_profile_index
    local api = kind == "rates" and "rc_tuning" or "governor_profile"
    self.restoreProfile = original
    for i = 0, math.min(indexes and #indexes or count, 6) - 1 do
      local index = indexes and indexes[i+1] or i
      self:action("set_pid_profile", { index + (kind == "rates" and 128 or 0) })
      self:read(api, function(d)
        self.profileData = d
        if loaded then loaded(d, index) end
        if apply then
          self.profileOriginal = self.profileOriginal or {}
          self.profileOriginal[kind] = self.profileOriginal[kind] or {}
          self.profileOriginal[kind][index] = self.profileOriginal[kind][index] or copy(d)
        end
      end)
      if apply then self:write(api, function()
        if apply(self.profileData, index) == false then return false end
        return self.profileData
      end) end
    end
    self:action("set_pid_profile", { original }, function() self.restoreProfile = nil end)
    self:read(api, function(d) self.data[api] = d end)
    self:read("status", function(d) self.data.status = d end)
  end
  function w:save(after)
    if self.logInfo then
      local names = {}
      for api in pairs(self.dirty) do names[#names + 1] = api end
      self:log("info", "save %s", table.concat(names, ","))
    end
    self.transition = true; self.message = self.L.saving
    self.edits = self.edits + 1
    self:release()
    if self.commit then self.commit() end
    for api in pairs(self.dirty) do
      if api ~= "rc_tuning" and api ~= "governor_profile" and api ~= "tail_motor_output" then self:sendDirty(api) end
    end
    local written
    self:write("eeprom_write", {}, function()
      written = self.dirty
      if self.logInfo then self:log("info", "save ok") end
      self.dirty, self.live, self.profileOriginal = {}, {}, nil
      self.savedRebootPending = self.rebootPending
      self.snapshotIndex = 1
    end)
    -- Snapshot one API block per wakeup; never clone the whole configuration in a reply. A block
    -- the save did not mark keeps its saved table while that still holds the data's values;
    -- a marked block is copied without comparing, so no pass compares and copies a large one.
    for _, api in ipairs(READS) do
      local name = api
      self:run(function()
        if (written and written[name]) or not same(self.saved[name], self.data[name]) then
          self.saved[name] = copy(self.data[name])
        end
      end)
      self:run(function() self:sentFromData(name) end)
    end
    self:run(function()
      self.transition = nil
      -- A commit may report something the pilot has to see before moving on; the save itself
      -- is complete, and the next Save & next goes on.
      if self.stayNotice then
        self.message, self.stayNotice = self.stayNotice, nil
        if self.logInfo then self:keyMessage(self.stayNoticeKey) end
        self:rebuild(); return
      end
      self.message = self.L.saved; if after then after() end
    end)
  end
  -- What a step owns from one visit to the next: its confirmations and its test state. Cleared
  -- when the step is entered from another step and when it is started from the step menu, so a
  -- "blades removed" answer or a finished calibration never carries into a new visit.
  function w:resetVisit(step)
    local owned = ({ [1] = {"orientation", "unplugged", "blades"}, [10] = {"connected"}, [12] = {"motorDirection", "escBlades"},
      [13] = {"servoUp0", "servoUp1", "servoUp2", "servoCentre0", "servoCentre1", "servoCentre2", "servoCentre3"},
      [14] = {"control1", "control2", "control4"}, [15] = {"level"}, [16] = {"pitch"},
      [17] = {"tailCentre", "tailDirection"}, [18] = {"gyro1", "gyro2", "gyro3"}, [19] = {"finish"} })[step]
    for _, name in ipairs(owned or {}) do self.checks[name] = nil end
    if step == 12 or step == 17 then self.bladesOff, self.percent = false, 10 end
    if step == 12 then
      self.calibratedEsc, self.escStage = nil, nil
      if self.rangeSource == "calibrated" then self.rangeSource = nil end
    end
    if step == 11 then
      if self.escParams then self.escParams.block = nil end
      self.escAttempted,self.escBusy,self.escResultKey=nil,nil,nil
    end
    if step == 4 then self.profile = nil end
    if step == 5 then self.rateStyles, self.rateLoaded = {}, nil end
    if step == 8 then self.governorLoaded, self.governorFilterLoaded = nil, nil end
    -- Stick travel is measured anew on every visit to the receiver step.
    if step == 2 and self.rx then self.rx.travel, self.rx.travelSig, self.rx.advanced = nil, nil, nil end
  end
  function w:navigate(step, card)
    if self.transition or not self.ready then return end
    if self.step >= 10 and step <= 9 then self.checks.unplugged = nil end
    if step ~= self.step then self:resetVisit(step) end
    -- Full throttle must remain active while the battery instruction is displayed.
    -- Back and every other transition still release all overrides.
    local calibrationForward=self.step==12 and step==12 and self.card==1 and card==2
      and self.data.motor_config.motor_pwm_protocol==0 and self.escStage=="full" and self.motorHold
      and self.motorHold.index==0 and self.motorHold.value==1000 and self.motorHold.mode==nil
    if not calibrationForward then self:release() end
    -- A result reported on one card (a learned switch, a calibration) is not about the next one;
    -- only the unsaved-change reminder and a pending status check carry over.
    local L = self.L
    if not self.statusWaiting and self.message ~= L.pendingSave and self.message ~= L.liveApplied
      and self.message ~= L.pendingReboot then
      self.message = L.ready
    end
    -- A move between cards of one step keeps that step's cards while nothing they were built
    -- from has changed since; the build still runs every gate and the new card's entry.
    local model = step == self.step and self.cards and self.cards.model
    self.keptCards = model and model.edits == self.edits and model.rebootPending == self.rebootPending
      and self.cards or nil
    self.step, self.card, self.commit, self.cards, self.enter, self.onLive = step, card or 1, nil, nil, nil, nil
    if self.attitudeView then self.attitudeView.valid=false;self.attitudeView=nil end
    if self.updateHistoryHints then self:updateHistoryHints() end
    self.buildRequested = self.keptCards and not self.buildRequested and "card" or true; self:rebuild()
  end
  function w:next()
    if self.escBusy then return end
    if not self:usable() or not self.cards then return end
    if self.recoveryCard then
      if not self:ack("recoveryPowerCycle") then return end
      self:session().helicopterSetupRecovery=nil
      self.recoveryRequired,self.recoveryCard,self.cards=nil,nil,nil
      self.buildRequested=true;self:rebuild();return
    end
    if self.modelPreparationCard then
      if not self:ack("modelReady") then return end
      if self.systemStatus == nil or self.systemConfig == nil then self.message = self.L.sensorsRequired; return end
      self.modelPreparationDone,self.modelPreparationCard=true,nil
      self.cards,self.buildRequested=nil,true;self:rebuild();return
    end
    if self.entryRebootGate then
      if self:ack("unplugged") and self:ack("blades") then self:reboot() end
      return
    end
    if self.preparationCard then
      if not self:preparationComplete() then return end
      self.preparationDone, self.preparationCard = true, nil
      self.cards, self.buildRequested = nil, true
      self:rebuild();return
    end
    if self.trial then
      if self.trial.success then self:reboot() else self.message=self.L.detecting end
      return
    end
    if self.step == 1 and (not self:ack("unplugged") or not self:ack("blades")) then return end
    if self.card < #self.cards then self:navigate(self.step, self.card + 1); return end
    if self.validate and not self.validate() then return end
    if self.step == 10 and self.rebootPending then self:reboot(); return end
    if self.rebootPending and self.step > 10 then self:reboot(); return end
    if not next(self.dirty) then
      if self.finishStep then self:finishStep() elseif self.step == 19 then self:close() else self:navigate(self.step + 1, 1) end
      return
    end
    self:save(function()
      if self.finishStep then self:finishStep() elseif self.step == 19 then self:close() else self:navigate(self.step + 1, 1) end
    end)
  end
  function w:back()
    if not self:allowed() then
      self:release();self.disconnectExit=true;self:rebuild();return
    end
    if self.escBusy then return end
    if not self.ready then
      self.bus:cancel();self.transition=nil;self:close();return
    end
    if self.transition then return end
    if self.historyFailure then
      self.historyFailure, self.historyRetry, self.historySkip = nil, nil, nil
      self.message = self.L.historyNotSaved
      self:rebuild(); return
    end
    if self.confirmExit then self.confirmExit, self.exitToSteps, self.backTarget = nil, nil, nil; self:rebuild(); return end
    if self.overview then
      if next(self.dirty) then self.confirmExit = true; self:rebuild() else self:close() end
      return
    end
    if self.requestSteps and self.card == 1 and (self.singleStep or self.step == 1) then self:requestSteps(); return end
    if self.card > 1 then self:navigate(self.step, self.card - 1)
    elseif self.step > 1 then
      if next(self.dirty) then
        self.backTarget,self.confirmExit=self.step-1,true;self:release();self:rebuild()
      else self:navigate(self.step - 1, 1) end
    else self:release(); self.confirmExit = true; self:rebuild() end
  end
  function w:leaveDisconnected()
    if self:allowed() then self.disconnectExit=nil;self:rebuild();return end
    self.cleanPhysicalExit,self.active=true,false
    self:session().helicopterSetupRecovery=nil
    if self.requestClose then self.requestClose() end
  end
  function w:close()
    if self.closing then return end
    if self.logInfo then self:log("info", "close") end
    self.closing,self.transition=true,true
    self:release()
    if self.recoveryRequired then
      self.active=false;if self.requestClose then self.requestClose() end;return
    end
    self:afterRelease(function()
      self:write("arming_disable",{disabled=false},function()
        self.active=false;if self.requestClose then self.requestClose() end
      end)
    end)
  end
  function w:discard(after)
    if self.logInfo then self:log("info", "discard") end
    self.transition = true
    self.edits = self.edits + 1
    self:release()
    for kind, profiles in pairs(self.profileOriginal or {}) do
      for index, original in pairs(profiles) do
        self:action("set_pid_profile", { index + (kind == "rates" and 128 or 0) })
        self:write(kind == "rates" and "rc_tuning" or "governor_profile", original)
      end
      local status = self.data.status
      self:action("set_pid_profile", { kind == "rates" and status.current_control_rate_profile_index + 128 or status.current_pid_profile_index })
    end
    for api in pairs(self.dirty) do
      if self.saved[api] then
        if api == "tail_motor_output" then
          self:write(api, { action = self.saved[api].output + 1 })
        elseif api ~= "rc_tuning" and api ~= "governor_profile" then self:sendDirty(api, self.saved) end
      end
    end
    if after then
      for _, name in ipairs(READS) do
        local api = name
        self:run(function() self.data[api] = copy(self.saved[api]) end)
        self:run(function() self.sent[api] = self.saved[api] end)
      end
      self:run(function()
        self.dirty, self.live, self.profileOriginal = {}, {}, nil
        self.edits = self.edits + 1
        self.profile = nil
        self.pitchFull,self.pitchFullChanged,self.rateProfile,self.rateLoaded=nil,nil,nil,nil
        self.rateStyles,self.rateTunings,self.rateMatched=nil,nil,nil
        self.governorLoaded,self.governorSpeeds,self.governorChanged,self.governorFilterLoaded=nil,nil,nil,nil
        self.startTail=self.data.mixer_config.tail_rotor_mode
        self.rebootPending, self.transition = self.savedRebootPending, nil
        if self.logInfo then self:log("info", "discard done") end
        after()
      end)
    else self:run(function() self:close() end) end
  end
  function w:reboot()
    self:save(function()
      if self.logInfo then self:log("info", "reboot") end
      self.transition = true; self.message = self.L.rebooting; self.rebootAt = now(); self.rebootPhase = "sent"
      self:write("reboot", {}, function() self.rebootPhase = "wait" end, true)
    end)
  end
  function w:load()
    if self.logInfo then self:log("info", "load start") end
    self.ready, self.error, self.progress, self.transition = false, nil, 0, true
    self.edits = self.edits + 1
    self.checks,self.card,self.bladesOff,self.calibratedEsc={},1,false,nil
    if self.escParams then self.escParams.block = nil end
    self.escAttempted,self.escBusy,self.rangeSource=nil,nil,nil
    self.rangeNeedsVerification = self.rangeChoice == "esc_link" and self.escRangeExpected ~= nil
    self.preparationDone,self.preparationCard=nil,nil
    self.tailPinRefused,self.tailPinNotice,self.stayNotice=nil,nil,nil
    self.governorLoaded,self.governorSpeeds,self.governorChanged,self.governorFilterLoaded=nil,nil,nil,nil
    self.data.battery_config, self.data.battery_profile, self.data.smartfuel_config = nil, nil, nil
    self.data.analog, self.analogAt = nil, nil
    self.statusQueued, self.statusWaiting, self.beforeStatusWait = nil, nil, nil
    self.recoveryRequired=self:session().helicopterSetupRecovery==self:session().mcu_id
    self.loadingText, self.loadTotal = self.L.loading, #READS + 66
    self.locked = false
    self:write("arming_disable", { disabled = true })
    self:read("status", function(d)
      if (d.arming_disable_flags & (1 << 16)) == 0 then self:fail("arming_disable", "not active"); return end
      local count = d.servo_count
      if count > 26 or (count > 8 and count < 18) then self:fail("status", "servo count"); return end
      self.loadTotal = #READS + 40 + count
      self.locked = true; self:acceptStatus(d)
    end)
    if self.loadHistory then self:run(function() self:loadHistory() end) end
    if self.historyMode then
      self:run(function()
        self.ready, self.transition, self.buildRequested = true, nil, true
        if self.logInfo then self:log("info", "load ready, history only") end
        self.message = self.L.ready; self:rebuild()
      end)
      return
    end
    -- An FC below API 12.10 gets the reason instead of reads it cannot answer.
    if not self:apiSupported() then
      self:run(function()
        self.ready, self.transition, self.buildRequested, self.apiTooOld = true, nil, true, true
        if self.logInfo then self:log("info", "load stopped, API %s", self:session().apiVersion) end
        self.message = self.L.apiTooOld; self:rebuild()
      end)
      return
    end
    for _, api in ipairs({ "servo_override", "mixer_override", "motor_override" }) do
      local name = api
      self:run(function() self.bus:load(name) end)
    end
    self:run(function() self:release(true) end)
    -- Old firmware can acknowledge a five-byte override while ignoring its
    -- timeout. Probe each parser with OFF only: valid five bytes must succeed
    -- and invalid four bytes must be explicitly refused, never just time out.
    local servoCandidate,mixerCandidate=false,false
    self:write("servo_override",{servo_id=0,action=2001,timeout=500},function(_,err) servoCandidate=err==nil end,true)
    self:action("servo_override",{0,209,7,0},function(_,err) self.timedServo=servoCandidate and err=="refused" end,true)
    self:write("mixer_override",{index=0,value=2501,timeout=500},function(_,err) mixerCandidate=err==nil end,true)
    self:action("mixer_override",{0,197,9,0},function(_,err)
      self.timedMixer=mixerCandidate and err=="refused"
      self.timed=self.timedServo and self.timedMixer
    end,true)
    for _, name in ipairs(READS) do
      local api = name
      -- Bulk adjustment/servo tables can exceed the firmware's 320-byte
      -- telemetry response buffer. Read their records through the Suite APIs.
      if api == "smartfuel_config" and not self.powerFields.supportsSmartFuel(self:session().apiVersion, self.powerApiVersion) then
        self:run(function() self:loadProgress() end)
      elseif api == "adjustment_ranges" then
        self:readRecords(api, "get_adjustment_range", "adjustment_range")
      elseif api == "servo_configurations" then
        self:readRecords(api, "get_servo_config", "servo_config", true)
      else self:read(api, function(d, err)
        if err and (api == "battery_config" or api == "battery_profile" or api == "smartfuel_config") then d = nil end
        if api == "board_alignment_config" and d then
          for _, key in ipairs({"roll_degrees", "pitch_degrees", "yaw_degrees"}) do d[key] = self.math.signed(d[key]) end
        end
        self.data[api] = d; self:loadProgress()
        if api == "status" then
          -- The ARM box bit is identified by BOXIDS below, never assumed to be bit zero.
          self:acceptStatus(d)
        end
      end, api == "tail_motor_output" or api == "board_info" or api == "telemetry_config"
        or api == "battery_config" or api == "battery_profile" or api == "smartfuel_config",
        api == "tail_motor_output" and {0} or nil) end
      self:run(function()
        -- A reload reads current RAM; unsaved APIs retain their original discard baseline.
        -- Mode extras share the mode table's dirty flag and rollback boundary.
        if not self.dirty[api] and not (api == "mode_ranges_extra" and self.dirty.mode_ranges) then
          self.saved[api] = copy(self.data[api])
        end
      end)
      self:run(function() self:sentFromData(api) end)
    end
    -- Loading many API blocks can take seconds over telemetry. Read the lock
    -- again immediately before offering bench controls.
    self:read("status", function(d) self:acceptStatus(d) end)
    self:run(function()
      self.identity = self:session().mcu_id
      local inputs = self.data.mixer_input.inputs
      if not inputs[4] or not self.data.status.pid_profile_count or self.data.status.pid_profile_count < 1 then
        self:fail("status", "configuration"); return
      end
      self.startTail = self.data.mixer_config.tail_rotor_mode
      self.savedRebootPending = self.rebootPending
      self.ready, self.transition, self.buildRequested = true, nil, true
      if self.logInfo then self:log("info", "load ready") end
      self.message = self.L.ready
      self:rebuild()
    end)
  end
  function w:poll()
    if self.historyMode or self.modelPreparationCard then return end
    local time = now()
    if time - (self.lastPoll or 0) < 20 then return end
    self.lastPoll = time
    local attitudeCheck=self.step==1 and self.cards and self.cards[self.card] and self.cards[self.card].art=="attitude"
    -- Switch learning reads the channels three polls in four; STATUS keeps its turn.
    local switches=self.step==3 or self.step==4
    self.pollIndex = (self.pollIndex or 0) % ((attitudeCheck or switches) and 4 or 3) + 1
    local api = switches and (self.pollIndex==1 and "status" or "rc") or
      attitudeCheck and (self.pollIndex%2==1 and "attitude" or self.pollIndex==2 and "status" or "servo") or
      self.pollIndex == 1 and "status" or self.pollIndex == 2 and "servo" or
      ({ [1] = "attitude", [2] = "rx_channels", [3] = "rc", [4] = "rc", [10] = "motor", [11] = "motor_telemetry",
        [12] = "motor", [14] = "rc_command", [17] = self:motorised() and "motor" or "rc_command" })[self.step]
    -- On Power cards, replace the unused servo poll with one nine-byte selected-source reading.
    local card = self.cards and self.cards[self.card]
    if self.step == 11 and card and card.power and self.pollIndex == 2 then api = "analog" end
    if self.motorHold then api = "motor" end
    if not api then return end
    local selectedSources = self.saved.battery_config
    -- An idle bus holds no queued or pending job, so the previous poll's job is free again.
    local job = self.bus:idle() and self.pollJob
    if not job then
      job = {}
      job.after = function(d, err) self:pollReply(job, d, err) end
      self.pollJob = job
    end
    job.api, job.optional = api, api == "analog"
    job.voltageSource = selectedSources and selectedSources.voltageMeterSource
    job.currentSource = selectedSources and selectedSources.currentMeterSource
    self.bus:add(job)
  end
  function w:pollReply(job, d, err)
    local api = job.api
    self.data[api] = not err and d or nil
    if api == "analog" then
      self.analogAt = not err and now() or nil
      self.analogSources = {voltageMeterSource = job.voltageSource, currentMeterSource = job.currentSource}
    end
    if api == "motor_telemetry" then self.motorTelemetryAt = now() end
    if api == "attitude" then self.attitudeAt = now() end
    if api == "rc" then self.rcAt = now() end
    if api == "rx_channels" then self.rxChannelsAt = now() end
    if api == "status" then
      self:acceptStatus(d)
    end
    if self.onLive then self.onLive(api, d) end
  end
  function w:motorised() return self.data.mixer_config and self.data.mixer_config.tail_rotor_mode ~= 0 end
  function w:servos()
    local d = self.data.servo_configurations
    if not d then return {} end
    local swash = self.data.mixer_config.swash_type
    local cyclic = swash == 0 and 0 or (swash == 5 or swash == 6) and 2 or 3
    local count = math.min(d.servo_count, self.data.status.servo_count or 0)
    for i = 1, 12 do
      local mask = self.data.serial_config["port_" .. i .. "_function_mask"] or 0
      if (mask & (262144 | 524288)) ~= 0 then count = math.max(0, d.servo_count - 18); break end
    end
    local list = {}; for i = 0, math.min(cyclic, count, 8) - 1 do list[#list + 1] = i end
    if not self:motorised() and count >= 4 then list[#list + 1] = 3 end
    return list
  end
  function w:tick()
    if self.logInfo then self:logChanges() end
    if self.escParams and self.escParams:observe(self.escSignature) and not self.escBusy then
      self:escResult(nil,"restart")
    end
    if self.linkTick then self:linkTick() end
    if self.attitudeView then
      self.attitudeView:update(self.data.attitude,self.attitudeAt,now(),
        self.active and self.ready and self.locked and not self.transition and not self.error and self:allowed())
    end
    if not self.active then return end
    if not self:allowed() then
      if not self.suspended then
        if self.logInfo then self:log("info", "link lost") end
        self.suspended, self.escBusy = true, nil; self.bus:cancel(); self:release(); self.message = self.L.disconnected
        self.ready = false; self:rebuild()
      end
      return
    end
    if self.suspended then
      self.suspended,self.disconnectExit = nil,nil
      if self.logInfo then self:log("info", "link back") end
      if self.rebootPhase then self.rebootPhase = nil; self.rebootPending = nil; self:load()
      else self.error = "link"; self.message = self.L.reload end
      return
    end
    if self.rebootPhase and self.rebootPhase ~= "sent" then
      if now() - self.rebootAt > 3000 then self.rebootPhase = nil; self:fail("reboot", "timeout") end
      if now() - self.rebootAt >= 200 and self.bus:idle() then
        self:read("status", function(d, err)
          if err or not d or d.reboot_required ~= 0 then return end
          self.rebootPhase, self.rebootPending = nil, nil
          if self.logInfo then self:log("info", "reboot done") end
          self:load()
        end, true)
      end
      if not self.bus:idle() then self.bus:tick() end
      return
    end
    if self.cleanupFailed and (self.cleanupPending or 0)==0 and not self.error then
      self:fail("cleanup",self.L.cleanupFailed);return
    end
    -- STATUS preempts long indexed writes and wiring trials. Check expiry before
    -- waiting for the transport, so an unanswered request cannot keep a hold alive.
    if self.ready and self.locked and not self.error and not self.rebootPhase then
      local age = now() - (self.statusAt or 0)
      if age > 300 then
        -- No stale status may authorize an edit or keep a test running. An idle
        -- read-only visit can await its outstanding fresh reply without claiming
        -- that configuration was lost. Mutations and tests still fail closed.
        if self.transition or self.motorHold or next(self.holds) or self.trial or self.calibrationAt or not self.bus:readOnly() then
          self:fail("status", self.L.stale); self.message = self.L.stale; return
        end
        if not self.statusWaiting then
          self.beforeStatusWait, self.statusWaiting = self.message, true
          self.canEdit, self.canNext, self.message = false, false, self.L.checkingStatus
          self:release()
        end
      end
      if age > 100 and not self.statusQueued then
        self.statusQueued = true
        self.bus:urgent({ api = "status", after = function(d)
          self.statusQueued = nil; self:acceptStatus(d)
        end })
      end
    end
    if not self.bus:idle() then self.bus:tick(); return end
    if self.buildRequested and self.ready then
      -- Only a plain card move may reuse the step's cards; any other request builds them anew.
      local kept = self.buildRequested == "card" and self.keptCards
      self.buildRequested, self.keptCards = nil, nil
      if self.overview then self:rebuild(); return end
      if self.historyMode then self:buildHistory();self:rebuild();return end
      -- A pending power-cycle acknowledgement comes first, so its marker can still be cleared.
      if self.apiTooOld and not self.recoveryRequired then
        self.cards={self:cardDef(self.L.apiTooOldTitle,self.L.apiTooOld,{
          self:value(self.L.fcApi,function() return tostring(self:session().apiVersion or "--") end)
        })}
        self.cards[1].summary=self.L.apiTooOld
        self.card=1;self.validate=function() self.message=self.L.apiTooOld;return false end
        self:rebuild();return
      end
      if self:buildModelPreparation() then self:rebuild();return end
      -- A range transaction owns its motor reboot; first keep ESC restart/readback reachable.
      self.entryRebootGate = self.returnToSuite and self.step > 10 and self.rebootPending
        and not (self.step == 11 and self.escRangeExpected) or nil
      if self.entryRebootGate then
        self.cards={self:cardDef(self.L.pendingReboot,self.L.entryRestartHint,{
          self:check("blades",self.L.bladesRemoved),self:check("unplugged",self.L.servosUnplugged)
        })}
        self.card=1;self:rebuild();return
      end
      local key = STEPS[self.step]
      self.validate, self.onLive, self.commit = nil, nil, nil
      if self.buildPreparation and self:buildPreparation() then self:rebuild();return end
      local model = kept and kept.model
      -- A step may name a check for state its cards captured that no edit reports.
      if model and model.step == self.step and model.edits == self.edits and model.rebootPending == self.rebootPending
        and not (kept.stale and kept.stale()) then
        self.cards, self.validate, self.onLive, self.commit = kept, model.validate, model.onLive, model.commit
        if self.logDebug then self:log("debug", "cards %s kept", key) end
      else
        self.cards = assert(loadScript(BASE .. "app/pages/helicopter_setup/steps/" .. key .. ".lua", "t"))()(self)
        self.cards.model = { step = self.step, edits = self.edits, rebootPending = self.rebootPending,
          validate = self.validate, onLive = self.onLive, commit = self.commit }
        if self.logDebug then self:log("debug", "cards %s built, %s", key, #self.cards) end
      end
      self.card = math.min(self.card, #self.cards)
      if self.cards[self.card].enter then self:afterRelease(self.cards[self.card].enter) end
      self:rebuild(); return
    end
    if not self.ready or self.error or self.transition then return end
    if self.trialTick and self:trialTick() then return end
    if self.live and next(self.live) then
      local api = next(self.live); self.live[api] = nil
      if self.logInfo then self:log("info", "live write %s", api) end
      self:sendDirty(api); return
    end
    if self.escTick and self:escTick() then return end
    if self.holdPollTurn then
      self.holdPollTurn, self.lastPoll = nil, nil
      self:poll(); return
    end
    if self.motorHold then
      local h = self.motorHold
      if h.untilAt and now() >= h.untilAt then self:stopMotor(); return end
      -- A refresh takes about as long as its interval on a radio link, so without a turn of
      -- its own the motor output read would never run while a hold is active.
      if now() >= h.due and not h.pollTurn then
        if h.mode=="spin" then h.value=self.percent*10*h.direction end
        if h.mode=="idle" then h.value=self.data.mixer_config.tail_motor_idle end
        h.due, h.pollTurn = now() + 25, true
        self.bus:add({ api = "motor_override", write = true, override = true,
          data = { index = h.index, value = h.value } }); return
      end
      if h.pollTurn then h.pollTurn = nil; self.lastPoll = nil end
    end
    local refreshed = false
    -- Finish one round of due holds, then reserve a turn for live output reads.
    for _, h in pairs(self.holds) do
      if now() >= h.due then
        h.due = now() + 100
        local d = h.kind == "servo" and { servo_id = h.index, action = h.value } or { index = h.index, value = h.value }
        if h.timed then d.timeout = 3000 end
        self.bus:add({ api = h.kind .. "_override", write = true, override = true, data = d })
        refreshed = true
      end
    end
    if refreshed then self.holdPollTurn = true; return end
    self:poll()
  end
  return w
end
return M
