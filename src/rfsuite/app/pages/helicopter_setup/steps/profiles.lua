return function(w)
  local L,H=w.L,w.math
  local ranges=w.data.adjustment_ranges.adjustment_ranges
  local pid,gain=H.rangeOf(ranges,2),H.rangeOf(ranges,83)
  w.profile=w.profile or {mode=H.profileMode(ranges),gain=not gain and 1 or gain.adjStep>0 and 3 or 2,
    channel=pid and pid.adjChannel or 0,gainChannel=gain and gain.adjChannel or 0,positions={}}
  local p=w.profile
  local function cancel() p.listen,p.record,p.base,p.peaks,p.positions=nil,nil,nil,nil,{} end
  -- Reserve every required slot before changing anything. A full table must not
  -- leave only one half of a paired profile or gain assignment installed.
  local function writeRanges(items)
    local slots,used={},{}
    for n,r in ipairs(items) do
      for i,old in ipairs(ranges) do if old.adjFunction==r.adjFunction and not used[i] then slots[n]=i;break end end
      if not slots[n] then
        for i,old in ipairs(ranges) do if old.adjFunction==0 and not used[i] then slots[n]=i;break end end
      end
      if not slots[n] then w.message=L.noSlots;return false end
      used[slots[n]]=true
    end
    for n,r in ipairs(items) do
      local slot=slots[n];ranges[slot]=r
      w.bus:add(w:rangeJob("adjustment_ranges",slot))
    end
    w:touch("adjustment_ranges");return true
  end
  local function remove(fn)
    for i,r in ipairs(ranges) do
      if r.adjFunction==fn then
        ranges[i]=H.mapped(0,0,1500,1500,0,0)
        w.bus:add(w:rangeJob("adjustment_ranges",i));w:touch("adjustment_ranges")
      end
    end
  end
  local function sample(v)
    if not v or v<=0 then return end
    for _,cluster in ipairs(p.positions) do
      if v>=cluster.low-149 and v<=cluster.high+149 then
        cluster.low,cluster.high=math.min(cluster.low,v),math.max(cluster.high,v)
        local i=1
        while i<#p.positions do
          local a,b=p.positions[i],p.positions[i+1]
          if b.low-a.high<150 then a.high=math.max(a.high,b.high);table.remove(p.positions,i+1)
          else i=i+1 end
        end
        return
      end
    end
    -- The usable channel span permits at most nine separated clusters.
    if #p.positions<9 then p.positions[#p.positions+1]={low=v,high=v};table.sort(p.positions,function(a,b) return a.low<b.low end) end
  end
  w.onLive=function(api,d)
    if api~="rc" then return end
    if p.record and getTime()>p.untilAt then
      p.record,p.base,p.peaks=nil,nil,nil
      w.message=#p.positions>=2 and string.format(L.positionsRecorded,#p.positions) or L.twoPositions
      if w.logInfo then w:keyMessage("positionsRecorded") end
      return
    end
    if p.listen and getTime()>p.untilAt then cancel();w.message=L.detectTimeout;return end
    if p.record then sample(d.channels[p.channel+6]) end
    if not p.listen then return end
    if not p.base then p.base=d.channels;p.peaks={};return end
    for i=6,#d.channels do p.peaks[i-5]=math.max(p.peaks[i-5] or 0,math.abs(d.channels[i]-(p.base[i] or d.channels[i]))) end
    local aux=H.moved(p.peaks,nil,p.listen=="profile" and 300 or p.gain==2 and 250 or 100)
    if not aux then return end
    if p.listen=="profile" then
      p.channel,p.positions,p.record,p.untilAt=aux-1,{},true,getTime()+2000
      sample(p.base[aux+5]);sample(d.channels[aux+5])
    else
      p.gainChannel=aux-1
      writeRanges({H.gain(83,p.gainChannel,p.gain==3),H.gain(84,p.gainChannel,p.gain==3)})
    end
    p.listen=nil;w.message=L.detected
  end
  local function listen(kind)
    local baseline=w:channelSnapshot("rc")
    if not baseline or #baseline<6 then w.message=L.waitChannels;return end
    cancel();p.base,p.peaks=baseline,{}
    p.listen,p.untilAt=kind,getTime()+2000;w.message=L.flick
  end
  local function channelValue(channel) return w.data.rc and w.data.rc.channels[channel+6] end
  local function plan(channel)
    local uses={}
    for _,r in ipairs(w.data.mode_ranges.mode_ranges) do
      if r.auxChannelIndex==channel and r.range.start<r.range["end"] then
        uses[#uses+1]=r.id==0 and L.arm or r.id==53 and L.rescue or r.id==47 and L.trainer or tostring(r.id)
      end
    end
    local pr,gr=H.rangeOf(ranges,2),H.rangeOf(ranges,83)
    if pr and pr.adjChannel==channel then uses[#uses+1]=L.profiles end
    if gr and gr.adjChannel==channel then uses[#uses+1]=L.masterGain end
    return #uses>0 and table.concat(uses," / ") or L.none
  end
  local cards={
    w:cardDef(L.profiles,L.profileHint,{
      {kind="choice",label=L.profileSwitch,values={L.bothProfiles,L.pidOnly,L.none},get=function() return p.mode end,
        set=function(v)
          cancel()
          if v==3 then remove(1);remove(2)
          elseif v==2 then remove(1)
          else
            local r=H.rangeOf(ranges,2)
            if r then
              local clone=H.mapped(1,r.adjChannel,r.adjRange1.start,r.adjRange1["end"],r.adjMin,r.adjMax)
              if not writeRanges({clone}) then return end
            end
          end
          p.mode=v
        end},
      w:button(function() return (p.listen or p.record) and L.cancelDetect or L.detect end,function() if p.listen or p.record then cancel() else listen("profile") end end,function() return p.mode~=3 end),
      w:value(L.positions,function() local range=H.rangeOf(ranges,2)
        local count=(p.record or #p.positions>0) and math.min(3,#p.positions) or range and range.adjMax-range.adjMin+1 or 0
        return string.format("CH%d: %d",w:channelNumber(p.channel),count) end),
      w:button(L.useSwitch,function()
        if #p.positions<2 then w.message=L.twoPositions;return end
        local first,last=p.positions[1],p.positions[#p.positions]
        local low,high=(first.low+first.high)/2,(last.low+last.high)/2
        low,high=H.round(low/5)*5,H.round(high/5)*5
        local count=math.min(3,#p.positions)
        local items={H.mapped(2,p.channel,low,high,1,count)}
        if p.mode==1 then items[2]=H.mapped(1,p.channel,low,high,1,count) end
        if writeRanges(items) then cancel() end
      end,function() return p.mode~=3 and #p.positions>=2 end)
    },nil,"switch"),
    w:cardDef(L.masterGain,L.gainHint,{
      {kind="choice",label=L.method,values={L.none,L.knob,L.buttons},get=function() return p.gain end,
        set=function(v)
          if p.gain==v then return end;cancel();p.gain=v;remove(83);remove(84)
          w.buildRequested=true;w:rebuild()
        end},
      w:button(function() return p.listen and L.cancelDetect or L.detect end,function() if p.listen then cancel() elseif p.gain>1 then listen("gain") end end),
      w:value(L.channel,function() local r=H.rangeOf(ranges,83);return r and "CH"..(w:channelNumber(r.adjChannel)) or L.none end),
      w:value(L.gainNow,function()
        local r=H.rangeOf(ranges,83);local v=r and channelValue(r.adjChannel)
        if not v then return "--" end
        if r.adjStep==0 then return H.mappedValue(r,v).."%" end
        for _,fn in ipairs({83,84}) do
          local a=H.rangeOf(ranges,fn)
          if a then
            if v>=a.adjRange1.start and v<a.adjRange1["end"] then return (fn==83 and L.cyclic or L.yaw).." -5%" end
            if v>=a.adjRange2.start and v<a.adjRange2["end"] then return (fn==83 and L.cyclic or L.yaw).." +5%" end
          end
        end
        return L.none
      end)
    })
  }
  if p.gain==3 then
    cards[#cards+1]=w:cardDef(L.trimGuide,L.trimHint,{
      w:value(L.cyclicDown,function() return "30% / 1654 us" end),w:value(L.cyclicUp,function() return "40% / 1705 us" end),
      w:value(L.yawDown,function() return "50% / 1756 us" end),w:value(L.yawUp,function() return "60% / 1807 us" end)
    })
  end
  local rows={
      w:value(L.profileNow,function()
        local r=H.rangeOf(ranges,2);local v=r and channelValue(r.adjChannel)
        return v and H.mappedValue(r,v) or "--"
      end),
      w:value(L.channelCount,function() return w.data.rc and w.data.rc.channel_count or "--" end),
      w:value("CH"..w:channelNumber(0),function() return plan(0) end),w:value("CH"..w:channelNumber(1),function() return plan(1) end),
      w:value("CH"..w:channelNumber(2),function() return plan(2) end)
  }
  local function addPlan()
    local card=w:cardDef(L.channelPlan,L.channelPlanHint,rows)
    card.dense=true;cards[#cards+1]=card;rows={}
  end
  local channels={}
  for _,r in ipairs(w.data.mode_ranges.mode_ranges) do if r.range.start<r.range["end"] then channels[r.auxChannelIndex]=true end end
  for _,fn in ipairs({2,83}) do local r=H.rangeOf(ranges,fn);if r then channels[r.adjChannel]=true end end
  for channel=3,26 do
    if channels[channel] then local ch=channel;rows[#rows+1]=w:value("CH"..w:channelNumber(ch),function() return plan(ch) end) end
    -- At 480x272, 135 px remain above the status line: seven rows at 18 px.
    if #rows==7 then addPlan() end
  end
  if #rows>0 then addPlan() end
  return cards
end
