local DETECT_MOVES = { {0,-1}, {1,0}, {0,-1}, {1,0}, {0,-1}, {0,0} }
return function(w)
  local L, H = w.L, w.math
  w.commit = function()
    if w.dirty.serial_config or w.dirty.rx_config then w:serialReceiver() end
  end
  w.rx = w.rx or { low = 3000, high = 0 }
  local r = w.rx
  local keys = { "aileron", "elevator", "rudder", "collective", "throttle", "aux1", "aux2", "aux3" }
  -- Collective first as in the Configurator, then the arm switch as well, so the arm
  -- channel is learned like the others instead of being filled in.
  local order = { 4, 1, 2, 3, 5, 6 }
  local names = { L.roll, L.pitch, L.yaw, L.collective, L.throttle }
  local function detectPrompt()
    local f=order[r.detect.index]
    return f==5 and L.toggleThrottle or f==6 and L.flipArm or L.move.." "..names[f]
  end
  local function detect()
    if r.detect then r.detect=nil;w.message=L.ready;return end
    local baseline=w:channelSnapshot("rx_channels")
    if not baseline then w.message=L.waitChannels;return end
    if w.logTrace then w:log("trace", "channel detection start") end
    r.detect = { index = 1, found = {}, exclude = {}, peaks = {}, baseline = baseline }
    w.message = detectPrompt()
    if w.logInfo then w:keyMessage("move") end
  end
  local function travelSig()
    local map, rc = w.data.rx_map, w.data.rc_config or {}
    local parts = { tostring(rc.rc_center), tostring(rc.rc_deflection) }
    for n = 1, 4 do parts[#parts + 1] = tostring(map[keys[n]]) end
    return table.concat(parts, ",")
  end
  -- The next control of the detection: a channel found for this one, or none when it is skipped.
  local function advance(found, channels)
    local s = r.detect
    if found then s.found[order[s.index]], s.exclude[found] = found - 1, true end
    s.index, s.baseline, s.peaks = s.index + 1, channels, {}
    if w.logDebug then w:log("debug", "detect next %s, channel %s", s.index, tostring(found)) end
    if s.index <= #order then
      w.message = found and string.format(L.channelDetected, found) .. "  " .. detectPrompt() or detectPrompt()
      if w.logInfo then w:keyMessage(found and "channelDetected" or "move") end
      return
    end
    local used = {}; for _, c in pairs(s.found) do used[c] = true end
    local nextChannel = 0
    for n = 1, 8 do
      local channel = s.found[n]
      if channel == nil then
        while used[nextChannel] do nextChannel = nextChannel + 1 end
        channel, used[nextChannel] = nextChannel, true
      end
      w.data.rx_map[keys[n]] = channel
    end
    -- Detection movements belong to learning the map, not to the guided end-stop check.
    r.travel, r.travelSig = { {0, 0}, {0, 0}, {0, 0}, {0, 0} }, travelSig()
    r.guideKey, r.wrong = nil, nil
    r.detect = nil; w:touch("rx_map"); w.message = L.detected
    if w.logInfo then w:log("info", "channel map detected") end
  end
  -- Stick center (rc_center), by the rules the Configurator and the Ethos suite use: radios do not all
  -- send 1500 us with the sticks centred (some ELRS setups send 1520), and an offset reads as every
  -- stick held slightly off centre. Roll, pitch and yaw are read as the FC receives them, through the
  -- channel map; collective does not spring back and is left out. The samples are this step's own
  -- channel polls (about one every 0.3 s), so Detect adds no MSP request of its own.
  local CENTRE_MIN, CENTRE_MAX, CENTRE_READS = 1400, 1600, 5
  -- A stick whose readings spread more than STILL (us) moved; the three must agree within AGREE (us);
  -- a centre is worth changing beyond OFF (us); sticks within NEAR (us) of rc_center are taken as centred.
  local CENTRE_STILL, CENTRE_AGREE, CENTRE_OFF, CENTRE_NEAR = 10, 5, 3, 60
  -- From samples[1..n], each {roll, pitch, yaw} in us: status, centre, axis. Values, not a table.
  --   "noSignal"  no samples, or a channel reads 0
  --   "moving"    a stick moved while sampling
  --   "trim"      axis (1 roll, 2 pitch, 3 yaw) is further than AGREE from the middle value
  --   "range"     the centre is outside CENTRE_MIN..CENTRE_MAX
  --   "ok"        the centre is the rounded average of the three
  local function centreFromSamples(samples, n)
    if n < 1 then return "noSignal" end
    for i = 1, n do
      local s = samples[i]
      if (s[1] or 0) <= 0 or (s[2] or 0) <= 0 or (s[3] or 0) <= 0 then return "noSignal" end
    end
    local m1, m2, m3
    for axis = 1, 3 do
      local lo, hi, sum = math.huge, -math.huge, 0
      for i = 1, n do
        local v = samples[i][axis] or 0
        if v < lo then lo = v end
        if v > hi then hi = v end
        sum = sum + v
      end
      if hi - lo > CENTRE_STILL then return "moving" end
      if axis == 1 then m1 = sum / n elseif axis == 2 then m2 = sum / n else m3 = sum / n end
    end
    local centre = H.round((m1 + m2 + m3) / 3)
    local middle = math.max(math.min(m1, m2), math.min(math.max(m1, m2), m3))
    local worst, worstOff = 1, math.abs(m1 - middle)
    if math.abs(m2 - middle) > worstOff then worst, worstOff = 2, math.abs(m2 - middle) end
    if math.abs(m3 - middle) > worstOff then worst, worstOff = 3, math.abs(m3 - middle) end
    if worstOff > CENTRE_AGREE then return "trim", centre, worst end
    if centre < CENTRE_MIN or centre > CENTRE_MAX then return "range", centre end
    return "ok", centre
  end
  -- Plain data on w.rx, so a result outlives the card rebuild an edit causes: status, value, axis,
  -- text, samples and count while Detect runs, hintWanted for the one read after the card is entered.
  r.centre = r.centre or {}
  local centre = r.centre
  -- One reused sample for the hint, so the read after entering the card allocates nothing.
  centre.hintList = centre.hintList or { { 0, 0, 0 } }
  local function onCentreCard()
    local card = w.cards and w.cards[w.card]
    return card ~= nil and card.centre == true and not w.stepMenu and not w.confirmExit and not w.error
  end
  local function centreResult(status, value, axis)
    centre.samples, centre.count = nil, nil
    centre.status, centre.value = status, value
    local rc = w.data.rc_config
    local before = rc.rc_center
    if status == "ok" and math.abs(value - rc.rc_center) > CENTRE_OFF then
      w:field("rc_config", "rc_center", value)
      -- The wizard refuses an edit while it is not usable (no fresh STATUS); then nothing was set.
      if rc.rc_center ~= value then
        centre.status, centre.text = "notSet", L.noReceiver
        if w.logInfo then w:log("info", "stick center %s not set: edit refused", value) end
        return
      end
      centre.text = string.format(L.centreSet, value)
    elseif status == "ok" then
      centre.text = string.format(L.centreSame, value)
    elseif status == "moving" then
      centre.text = L.centreMoving
    elseif status == "trim" then
      centre.text = string.format(L.centreTrimOff, names[axis])
    elseif status == "range" then
      centre.text = string.format(L.centreRange, value, CENTRE_MIN, CENTRE_MAX)
    else
      centre.text = L.noReceiver
    end
    if w.logInfo then
      w:log("info", "stick center %s %s, rc_center %s -> %s", status, tostring(value), tostring(before), tostring(rc.rc_center))
    end
  end
  -- One channel reply on the stick center card: a sample while Detect runs, or the one read for the hint.
  local function centreLive(d)
    if not centre.samples and not centre.hintWanted then return end
    if not onCentreCard() then
      if centre.samples and w.logTrace then w:log("trace", "stick center detection left with its card") end
      centre.samples, centre.count, centre.hintWanted = nil, nil, nil
      return
    end
    local status = w.data.status
    local rxLoss = status and status.arming_disable_flags and (status.arming_disable_flags & 4) ~= 0
    local channels, map = d and d.channels, w.data.rx_map
    local s = centre.samples and { 0, 0, 0 } or centre.hintList[1]
    for a = 1, 3 do
      local v = channels and channels[(map[keys[a]] or a - 1) + 1]
      s[a] = (not rxLoss and type(v) == "number") and v or 0
    end
    if not centre.samples then
      -- The hint: shown only while the resting sticks sit near rc_center and differ from it.
      centre.hintWanted = nil
      local st, c = centreFromSamples(centre.hintList, 1)
      local rc = w.data.rc_config.rc_center
      local hint = st == "ok" and math.abs(c - rc) <= CENTRE_NEAR and math.abs(c - rc) > CENTRE_OFF and c or nil
      centre.hint = hint and string.format(L.centreHint, hint, rc) or nil
      if w.logTrace then w:log("trace", "stick center hint %s", tostring(hint)) end
      return
    end
    local n = centre.count + 1
    centre.samples[n], centre.count = s, n
    if w.logDebug then w:log("debug", "stick center sample %s: %s %s %s", n, s[1], s[2], s[3]) end
    -- In RX loss the channels hold failsafe values, which are still and agree: no signal at once. A STATUS
    -- past the wizard's own limit (it waits for one and allows no edit) leaves the loss unknown: the same.
    if rxLoss or w.statusWaiting then centreResult("noSignal"); return end
    if n >= CENTRE_READS then centreResult(centreFromSamples(centre.samples, n)) end
  end
  local function startCentre()
    centre.samples, centre.count = {}, 0
    centre.status, centre.value, centre.text, centre.hint, centre.hintWanted = nil, nil, nil, nil, nil
    if w.logInfo then w:log("info", "stick center detection start") end
  end
  -- The stored centre as text, formatted again only when it changes.
  local shownCentre, shownCentreText
  local function centreNow()
    local c = w.data.rc_config.rc_center
    if c ~= shownCentre then shownCentre, shownCentreText = c, string.format(L.centreValue, c) end
    return shownCentreText
  end
  -- The guide's next end stop. A local of this visit, never kept on w.rx: the measurement
  -- stays for the whole wizard, the step's code leaves with the step.
  local target
  w.onLive = function(api, d)
    if api == "status" and centre.samples and d and d.arming_disable_flags
      and (d.arming_disable_flags & 4) ~= 0 then
      centreResult("noSignal")
      return
    end
    if api ~= "rx_channels" then return end
    centreLive(d)
    local map = w.data.rx_map
    local rc = w.data.rc_config
    local span = rc and rc.rc_deflection or 0
    -- Travel belongs to one channel map and one stick range; a change starts the measurement over.
    local sig = travelSig()
    if sig ~= r.travelSig then r.travel, r.travelSig, r.guideKey = { {0, 0}, {0, 0}, {0, 0}, {0, 0} }, sig, nil end
    local now = {}
    for n = 1, 4 do
      local v = d.channels[(map[keys[n]] or n - 1) + 1]
      if type(v) == "number" and v > 500 and span > 0 then
        local pct, t = math.floor((v - rc.rc_center) * 100 / span + 0.5), r.travel[n]
        now[n] = pct
        if pct < 0 and -pct > t[1] then t[1] = math.min(-pct, 100) end
        if pct > 0 and pct > t[2] then t[2] = math.min(pct, 100) end
      end
    end
    -- The guided check names a wrong move: the asked control going the other way, or another one.
    -- Each control is measured from where it rested closest to centre since the prompt appeared, so
    -- a stick still at the end stop just reached, or a collective parked low, is not a wrong move,
    -- while the same stick brought back and moved again is.
    local axis, dir
    if target then axis, dir = target() end
    local key = axis and axis * 10 + dir or 0
    if key ~= r.guideKey then r.guideKey, r.guideRest, r.guideBest = key, {}, nil end
    local rest = r.guideRest
    for n = 1, 4 do
      if now[n] and (rest[n] == nil or math.abs(now[n]) < rest[n]) then rest[n] = math.abs(now[n]) end
    end
    local signed = axis and now[axis] and now[axis] * dir
    if signed and (r.guideBest == nil or signed > r.guideBest) then r.guideBest = signed end
    r.wrong = nil
    if signed and signed <= -60 and signed < r.guideBest - 60 then
      r.wrong = L.stickReversed
    elseif axis and (signed or 0) < 30 then
      for n = 1, 4 do
        if n ~= axis and now[n] and math.abs(now[n]) - (rest[n] or 0) >= 60 then
          r.wrong = string.format(L.stickWrongChannel, names[n])
        end
      end
    end
    local throttle = d.channels[(map.throttle or 4) + 1]
    if r.record and throttle and throttle > 500 then r.low, r.high = math.min(r.low, throttle), math.max(r.high, throttle) end
    local s = r.detect
    if not s then return end
    if not s.baseline then s.baseline = d.channels; return end
    for i = 1, math.min(8, #d.channels) do
      s.peaks[i] = math.max(s.peaks[i] or 0, math.abs(d.channels[i] - (s.baseline[i] or d.channels[i])))
    end
    local i = H.moved(s.peaks, s.exclude)
    if i then advance(i, d.channels) end
  end
  -- Stick travel: the furthest each control has gone either way, in percent of the FC's stick
  -- range, the way the firmware scales it (rc.c: (rcInput - rc_center) / rc_deflection).
  r.travel = r.travel or { {0, 0}, {0, 0}, {0, 0}, {0, 0} }
  local TRAVEL = 95
  -- Recorded travel counts only for the current channel map and stick range, and only while the
  -- latest reply still carries every mapped control.
  local function travelOk()
    local rc, channels = w.data.rc_config, (w.data.rx_channels or {}).channels or {}
    if r.travelSig ~= travelSig() or not rc or (rc.rc_deflection or 0) <= 0 then return false end
    for n = 1, 4 do
      if type(channels[(w.data.rx_map[keys[n]] or n - 1) + 1]) ~= "number" then return false end
      if r.travel[n][1] < TRAVEL or r.travel[n][2] < TRAVEL then return false end
    end
    return true
  end
  w.validate = function()
    local raw = w.data.rx_channels
    local ok = raw and #raw.channels >= 5 and (w.data.status.arming_disable_flags & 4) == 0
    if not ok then w.message = L.noReceiver; return false end
    if r.detect then return false end
    if not travelOk() then w.message = L.sticksShort; return false end
    return true
  end
  local NO_CHANNELS = {}
  local function mapped(n)
    return function()
      local raw = w.data.rx_channels
      local channels = raw and raw.channels or NO_CHANNELS
      return channels[(w.data.rx_map[keys[n]] or n - 1) + 1] or "--"
    end
  end
  -- Receiver configuration stays locked until the pilot unlocks it: a wrong setting can cut
  -- the link this wizard talks over. Throttle range and limits do not change that link.
  local function unlocked() return r.advanced == true end
  local function locked(row)
    local own = row.enabled
    row.enabled = function() return unlocked() and (not own or own()) end
    return row
  end
  local protocol=w:enum("rx_config","serialrx_provider",L.protocol,w:receiverProtocols(),true)
  local protocolGet,protocolSet=protocol.get,protocol.set
  protocol.get=function()
    return (w.data.feature_config.enabledFeatures & (1<<3))~=0 and protocolGet() or 0
  end
  protocol.set=function(v)
    protocolSet(v);w:serialReceiver();w:touch("rx_config",true)
  end
  protocol.enabled=function() return not w.trial end
  -- The guided stick check asks for the first end stop not yet reached: right/forward/up first.
  local GUIDE = { {1,1},{1,-1},{2,1},{2,-1},{3,1},{3,-1},{4,1},{4,-1} }
  local words = { {L.dirRight,L.dirLeft},{L.dirForward,L.dirBack},{L.dirRight,L.dirLeft},{L.dirUp,L.dirDown} }
  target = function()
    for _, g in ipairs(GUIDE) do
      if r.travel[g[1]][g[2] > 0 and 2 or 1] < TRAVEL then return g[1], g[2] end
    end
  end
  -- The prompt is formatted again only when the asked end stop changes.
  local promptKey, promptText
  local function prompt()
    local axis, dir = target()
    if not axis then return L.sticksDone end
    local key = axis * 10 + dir
    if key ~= promptKey then
      promptKey, promptText = key, string.format(L.stickGuide, names[axis], words[axis][dir > 0 and 1 or 2])
    end
    return promptText
  end
  -- The text is formatted again only when the reading or its low threshold moves.
  local throttleValue, shownValue, shownZero, shownText = mapped(5), nil, nil, nil
  local function throttleNow()
    local v = throttleValue(); if type(v) ~= "number" then return "--" end
    local zero = w.data.rc_config.rc_min_throttle
    if zero == 0 then zero = H.round(w.data.rc_config.rc_center - 0.9 * w.data.rc_config.rc_deflection) end
    if v ~= shownValue or zero ~= shownZero then
      shownValue, shownZero = v, zero
      shownText = v > 0 and v < zero - 5 and string.format(L.throttleLowNow, v) or tostring(v)
    end
    return shownText
  end
  local PRESET_NAMES = { "ELRS", "FrSky", "Futaba / Hitec", "DSM / Graupner / JR" }
  local PRESETS = { {0,1,3,2,5,4,6,7}, {0,1,3,4,2,5,6,7}, {0,1,3,5,2,4,6,7}, {1,2,3,5,0,4,6,7} }
  local function presetIndex()
    for i, preset in ipairs(PRESETS) do
      local match = true; for n, k in ipairs(keys) do if w.data.rx_map[k] ~= preset[n] then match = false end end
      if match then return i end
    end
    return 0
  end
  local function automatic() return w.data.rc_config.rc_min_throttle == 0 and w.data.rc_config.rc_max_throttle == 0 end
  local function autoRange()
    local rc = w.data.rc_config
    local mid, span = rc.rc_center or 1500, math.floor((rc.rc_deflection or 510) * 0.9 + 0.5)
    return mid - span, mid + span
  end
  local function throttleRows()
    local rows = {
      w:value(L.throttle, throttleNow),
      { kind = "toggle", label = L.throttleAuto, values = { L.no, L.yes },
        get = function() return automatic() and 2 or 1 end,
        set = function(v)
          r.record = nil
          if v == 2 then
            if w.logDebug then w:log("debug", "throttle range automatic") end
            w:field("rc_config", "rc_min_throttle", 0)
            w:field("rc_config", "rc_max_throttle", 0)
          else
            -- Off starts from the range the firmware used, for the pilot to adjust or record.
            local low, high = autoRange()
            if w.logDebug then w:log("debug", "throttle range manual from %s to %s", low, high) end
            w:field("rc_config", "rc_min_throttle", low)
            w:field("rc_config", "rc_max_throttle", high)
          end
          w.buildRequested = true; w:rebuild()
        end }
    }
    if automatic() then
      rows[#rows+1] = w:value(L.throttleAutoRange, function() return string.format(L.throttleAutoValue, autoRange()) end)
      return rows
    end
    rows[#rows+1] = w:button(function() return r.record and L.useRange or L.record end, function()
      if r.record then
        if r.high - r.low < 300 then w.message = L.travelShort; return end
        r.record = nil
        w:field("rc_config", "rc_min_throttle", r.low + 20)
        w:field("rc_config", "rc_max_throttle", r.high - 20)
        return
      end
      local channels=w:channelSnapshot("rx_channels")
      local v=channels and channels[(w.data.rx_map.throttle or 4)+1]
      if type(v)~="number" or v<=500 then w.message=L.waitChannels;return end
      r.low,r.high,r.record=v,v,true;w.message=L.throttleSwitchRange
    end)
    rows[#rows+1] = w:n("rc_config", "rc_min_throttle", L.minimum, 0, 2100)
    rows[#rows+1] = w:n("rc_config", "rc_max_throttle", L.maximum, 0, 2100)
    return rows
  end
  local cards = {
    w:cardDef(L.cardReceiverProtocol, L.receiverHint, {
      { kind = "toggle", label = L.advanced, values = { L.no, L.yes },
        get = function() return unlocked() and 2 or 1 end, set = function(v) r.advanced = v == 2 end },
      locked(protocol),
      locked(w:button(L.saveReboot, function() w:serialReceiver(); w:reboot() end))
    }, nil, "receiver"),
    w:cardDef(L.channelOrder, L.channelHint, {
      { kind="choice",label=L.standardOrder,allowUnset=true,values=PRESET_NAMES,
        get=presetIndex,
        set=function(v)
          local preset=PRESETS[v]
          if not preset then return end
          r.detect=nil;for i,k in ipairs(keys) do w.data.rx_map[k]=preset[i] end;w:touch("rx_map")
        end, enabled=unlocked },
      locked(w:button(function() return r.detect and L.cancelDetect or L.detect end, detect)),
      w:button(L.detectSkip, function() if r.detect then advance(nil, nil) end end, function() return r.detect ~= nil end)
    }, nil, "stickDetect"),
    w:cardDef(L.checkSticks, L.stickGuideHint, {
      w:button(L.travelReset, function() r.travel, r.guideKey = { {0, 0}, {0, 0}, {0, 0}, {0, 0} }, nil end)
    }),
    -- As in the Configurator: the automatic range is Minimum and Maximum 0, and the firmware then
    -- uses rc_center -/+ 0.9 x rc_deflection. Off shows the two fields and Record travel. Nothing is
    -- written when the card opens; a stored range, also one with a single 0, stays as it is.
    w:cardDef(L.throttleRange, L.throttleCardHint, throttleRows(),nil,"heliBladesOff"),
    -- After the throttle range, before the summary, as in the Configurator and the Ethos suite.
    w:cardDef(L.centreTitle, L.centreCardHint, {
      w:value(L.centreTitle, centreNow),
      w:button(L.detect, startCentre, function() return not centre.samples and not r.detect end)
    }, function()
      -- Every entry starts afresh and asks for one read for the hint.
      centre.samples, centre.count, centre.status, centre.value, centre.text, centre.hint = nil, nil, nil, nil, nil, nil
      centre.hintWanted = true
      if w.logTrace then w:log("trace", "stick center card entered") end
    end),
  }
  cards[4].dense = true
  cards[1].summary=function() return unlocked() and L.receiverUnlocked or L.receiverWarning end
  cards[1].summaryColor, cards[1].summaryBold = "warning", true
  cards[2].summary=function() return r.detect and detectPrompt() or unlocked() and L.channelOrderPick or L.receiverLocked end
  cards[2].stickMove=function()
    local move=r.detect and DETECT_MOVES[r.detect.index]
    if move then return move[1],move[2] end
    return 0,0
  end
  cards[3].summary=function() return r.wrong or prompt() end
  cards[3].summaryColor, cards[3].summaryBold = "accentInk", true
  -- One live bar per control, as the radio sends it: its channel, both directions, the reading in
  -- percent of the FC's stick range, accented once both end stops are reached.
  local bars = {}
  for n = 1, 4 do
    -- false, not nil: the first refresh without a reading must still produce its placeholder.
    local channel, name, percent, shown = nil, nil, nil, false
    -- Read in place on every refresh: no closure and no table is made here.
    local function value()
      local raw, rc = w.data.rx_channels, w.data.rc_config
      local v = raw and raw.channels and raw.channels[(w.data.rx_map[keys[n]] or n - 1) + 1]
      if type(v) ~= "number" or not rc then return nil end
      return (v - rc.rc_center) / math.max(1, rc.rc_deflection)
    end
    bars[n] = {
      name = function()
        local c = (w.data.rx_map[keys[n]] or n - 1) + 1
        if c ~= channel then channel, name = c, string.format(L.barName, names[n], c) end
        return name
      end,
      left = words[n][2], right = words[n][1], value = value,
      percent = function()
        local v = value()
        local p = v and H.round(v * 100) or nil
        if p ~= shown then shown, percent = p, p == 0 and "0 %" or p and string.format(L.percent, p) or "--" end
        return percent
      end,
      -- Navigation clears the measurement before the next scene replaces this one.
      done = function() local t = r.travel; return t ~= nil and t[n][1] >= TRAVEL and t[n][2] >= TRAVEL end,
      -- Each end on its own: 1 is the left word's direction, 2 the right word's.
      reached = function(side) local t = r.travel; return t ~= nil and t[n][side] >= TRAVEL end
    }
  end
  cards[3].bars, cards[3].rowsAtFoot, cards[3].wideText = bars, true, true
  cards[4].summary=function()
    if r.record then return r.high>0 and string.format(L.throttleRecording, r.low, r.high) or L.throttleSwitchRange end
    return L.throttleQuick
  end
  cards[5].centre, cards[5].summaryColor, cards[5].summaryBold = true, "accentInk", true
  cards[5].summary = function()
    if centre.samples then return L.centreSampling end
    return centre.text or centre.hint or L.centreText
  end
  -- Keep the cards present when the protocol is edited; the rows report applicability live.
  for _,kind in ipairs({"combined"}) do
    local card=w:cardDef(L.linkTitle,L.linkHint,{
      w:value(L.linkStatus,function() return L.linkNeedsCrsf end)
    })
    card.link,card.summary=kind,L.linkQuick
    card.enter=function()
      if not w.linkController then
        w.linkController=w:loadModule("app/pages/helicopter_setup/elrs_link.lua").new(w)
      end
      w.linkController:enter(card)
    end
    cards[#cards+1]=card
  end
  -- The step closes on what it has set; the text says whether Next step has anything to store.
  local rangeMin, rangeMax, rangeText
  local done = w:cardDef(L.receiverDone, L.receiverDoneHint, {
    w:value(L.protocol, function() return protocol.values[protocol.get()] or L.notSet end),
    w:value(L.channelOrder, function() return PRESET_NAMES[presetIndex()] or L.servoCustom end),
    w:value(L.throttleRange, function()
      local rc = w.data.rc_config
      if rc.rc_min_throttle ~= rangeMin or rc.rc_max_throttle ~= rangeMax then
        rangeMin, rangeMax = rc.rc_min_throttle, rc.rc_max_throttle
        rangeText = (rangeMin == 0 and rangeMax == 0) and L.throttleDefaults or string.format(L.rangeUs, rangeMin, rangeMax)
      end
      return rangeText
    end),
    w:value(L.centreTitle, centreNow)
  }, nil, "receiver")
  done.summary = function() return next(w.dirty) and L.stepChanged or L.stepUnchanged end
  cards[#cards+1] = done
  return cards
end
