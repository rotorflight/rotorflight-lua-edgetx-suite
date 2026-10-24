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
  local function prompt()
    local f=order[r.detect.index]
    return f==5 and L.toggleThrottle or f==6 and L.flipArm or L.move.." "..names[f]
  end
  local function detect()
    if r.detect then r.detect=nil;w.message=L.ready;return end
    local baseline=w:channelSnapshot("rx_channels")
    if not baseline then w.message=L.waitChannels;return end
    r.detect = { index = 1, found = {}, exclude = {}, peaks = {}, baseline = baseline }
    w.message = prompt()
  end
  local function travelSig()
    local map, rc = w.data.rx_map, w.data.rc_config or {}
    local parts = { tostring(rc.rc_center), tostring(rc.rc_deflection) }
    for n = 1, 4 do parts[#parts + 1] = tostring(map[keys[n]]) end
    return table.concat(parts, ",")
  end
  w.onLive = function(api, d)
    if api ~= "rx_channels" then return end
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
    if r.target then axis, dir = r.target() end
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
    if not i then return end
    s.found[order[s.index]], s.exclude[i] = i - 1, true
    s.index, s.baseline, s.peaks = s.index + 1, d.channels, {}
    if s.index <= #order then
      w.message = string.format(L.channelDetected,i).."  "..prompt();return
    end
    local used = {}; for _, c in pairs(s.found) do used[c] = true end
    local nextChannel = 0
    for n = 1, 8 do
      local channel = s.found[n]
      if channel == nil then
        while used[nextChannel] do nextChannel = nextChannel + 1 end
        channel, used[nextChannel] = nextChannel, true
      end
      map[keys[n]] = channel
    end
    r.detect = nil; w:touch("rx_map"); w.message = L.detected
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
  local function mapped(n)
    return function()
      local channels = (w.data.rx_channels or {}).channels or {}
      return channels[(w.data.rx_map[keys[n]] or n - 1) + 1] or "--"
    end
  end
  local function travel(n)
    return function() return string.format(L.travelPair, r.travel[n][1], r.travel[n][2]) end
  end
  -- Every receiver setting stays locked until the pilot unlocks it: a wrong one can cut the very
  -- link this wizard talks over, and the setup cannot go on without it.
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
  r.target = function()
    for _, g in ipairs(GUIDE) do
      if r.travel[g[1]][g[2] > 0 and 2 or 1] < TRAVEL then return g[1], g[2] end
    end
  end
  local function prompt()
    local axis, dir = r.target()
    if not axis then return L.sticksDone end
    return string.format(L.stickGuide, names[axis], words[axis][dir > 0 and 1 or 2])
  end
  local function throttleNow()
    local v = mapped(5)(); if type(v) ~= "number" then return "--" end
    local zero = w.data.rc_config.rc_min_throttle
    if zero == 0 then zero = H.round(w.data.rc_config.rc_center - 0.9 * w.data.rc_config.rc_deflection) end
    return v > 0 and v < zero - 5 and string.format(L.throttleLowNow, v) or tostring(v)
  end
  local cards = {
    w:cardDef(L.receiver, L.receiverHint, {
      { kind = "toggle", label = L.advanced, values = { L.no, L.yes },
        get = function() return unlocked() and 2 or 1 end, set = function(v) r.advanced = v == 2 end },
      locked(protocol),
      w:button(L.receiverUsb, function() w.message=L.receiverUsbHint end),
      locked(w:button(L.saveReboot, function() w:serialReceiver(); w:reboot() end))
    }),
    w:cardDef(L.channelOrder, L.channelHint, {
      locked(w:button(function() return r.detect and L.cancelDetect or L.detect end, detect)),
      { kind="choice",label=L.standardOrder,values={"ELRS","FrSky","Futaba / Hitec","DSM / Graupner / JR"},
        get=function()
          for i,preset in ipairs({{0,1,3,2,5,4,6,7},{0,1,3,4,2,5,6,7},{0,1,3,5,2,4,6,7},{1,2,3,5,0,4,6,7}}) do
            local match=true;for n,k in ipairs(keys) do if w.data.rx_map[k]~=preset[n] then match=false end end
            if match then return i end
          end;return 0
        end,
        set=function(v)
          local preset=({{0,1,3,2,5,4,6,7},{0,1,3,4,2,5,6,7},{0,1,3,5,2,4,6,7},{1,2,3,5,0,4,6,7}})[v]
          if not preset then return end
          r.detect=nil;for i,k in ipairs(keys) do w.data.rx_map[k]=preset[i] end;w:touch("rx_map")
        end, enabled=unlocked }
    }),
    w:cardDef(L.checkSticks, L.stickGuideHint, {
      w:value(L.travelRoll, travel(1)), w:value(L.travelPitch, travel(2)), w:value(L.travelYaw, travel(3)),
      w:value(L.travelCollective, travel(4)),
      w:button(L.travelReset, function() r.travel, r.guideKey = { {0, 0}, {0, 0}, {0, 0}, {0, 0} }, nil end)
    }, nil, "stickGuide"),
    w:cardDef(L.throttleRange, L.throttleCardHint, {
      w:value(L.throttle, throttleNow),
      locked(w:button(function() return r.record and L.useRange or L.record end, function()
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
      end)),
      locked(w:n("rc_config", "rc_min_throttle", L.minimum, 0, 2100)),
      locked(w:n("rc_config", "rc_max_throttle", L.maximum, 0, 2100))
    },nil,"throttle")
  }
  local function lockedSummary(text) return function() return unlocked() and text or L.receiverLocked end end
  cards[1].summary=function() return unlocked() and L.receiverUnlocked or L.receiverWarning end
  cards[1].summaryColor, cards[1].summaryBold = "warning", true
  cards[2].summary=lockedSummary(L.channelQuick)
  cards[3].summary=function() return r.wrong or prompt() end
  cards[3].summaryColor, cards[3].summaryBold = "accent", true
  cards[3].dense = true
  cards[4].summary=function()
    if r.record then return r.high>0 and string.format(L.throttleRecording, r.low, r.high) or L.throttleSwitchRange end
    return unlocked() and L.throttleQuick or L.receiverLocked
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
  return cards
end
