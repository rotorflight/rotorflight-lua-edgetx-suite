return function(w)
  local L, H = w.L, w.math
  local modes = { {0, L.arm}, {53, L.rescue}, {47, L.trainer} }
  w.modeListen = w.modeListen or {}
  local s = w.modeListen
  local function assigned(id)
    for i, r in ipairs(w.data.mode_ranges.mode_ranges) do
      if r.id == id and r.range.start < r.range["end"] then return i, r end
    end
  end
  local function slot(id)
    local own = assigned(id); if own then return own end
    for i, r in ipairs(w.data.mode_ranges.mode_ranges) do if r.range.start >= r.range["end"] then return i end end
  end
  local function send(i)
    local r = w.data.mode_ranges.mode_ranges[i]
    w:action("set_mode_range", { i - 1, r.id, r.auxChannelIndex, H.step(r.range.start), H.step(r.range["end"]), 0, 0 })
    w.data.mode_ranges_extra.mode_ranges_extra[i] = { id = r.id, modeLogic = 0, linkedTo = 0 }
    w:touch("mode_ranges")
  end
  w.onLive = function(api, d)
    if api ~= "rc" or not s.id then return end
    if getTime() > s.untilAt then s.id = nil; w.message = L.detectTimeout; return end
    if not s.base then s.base = d.channels; return end
    local peaks = {}
    for i = 6, #d.channels do peaks[i - 5] = math.abs(d.channels[i] - (s.base[i] or d.channels[i])) end
    -- ARM is read from AUX1 alone: the receiver step maps the arm switch there, and
    -- ExpressLRS 4.x also outputs its arm flag on CH14, so a free search finds two winners.
    local aux
    if s.id == 0 then aux = H.moved({ peaks[1] or 0 }) else aux = H.moved(peaks) end
    if not aux then return end
    local value = d.channels[aux + 5]
    if s.aux ~= aux or math.abs((s.value or 0) - value) > 25 then s.aux, s.value, s.at = aux, value, getTime(); return end
    if getTime() - s.at < 40 then return end
    local i = slot(s.id)
    if not i then w.message = L.noSlots; s.id = nil; return end
    local lo, hi = H.switchRange(s.base[aux + 5], value)
    w.data.mode_ranges.mode_ranges[i] = { id = s.id, auxChannelIndex = aux - 1, range = { start = lo, ["end"] = hi } }
    send(i); s.id = nil
    w.message = string.format(L.switchDetected,w:channelNumber(aux-1),lo,hi)
  end
  w.validate = function() if not assigned(0) then w.message = L.armRequired; return false end; return true end
  local cards = {}
  for _, mode in ipairs(modes) do
    local id, label = mode[1], mode[2]
    local present = false; for _, value in ipairs(w.data.boxids.box_ids) do if value == id then present = true end end
    if present then
      local function state()
        if not assigned(id) then return nil end
        if id ~= 0 then return w:modeActive(id) end
        -- Arming remains inhibited: show the assigned switch, not an armed FC.
        local _,r=assigned(id);local c=w.data.rc and w.data.rc.channels
        local v=c and c[r.auxChannelIndex+6]
        if not v then return nil end
        return v>=r.range.start and v<r.range["end"]
      end
      cards[#cards + 1] = w:cardDef(label, L.modeHint, {
        w:value(L.assigned, function()
          local _, r = assigned(id)
          if not r then return L.no end
          return string.format("CH%d  %d-%d", w:channelNumber(r.auxChannelIndex), r.range.start, r.range["end"])
        end),
        w:button(function() return s.id==id and L.cancelDetect or L.assign end,function()
          if s.id==id then s.id=nil;w.message=L.ready;return end
          local baseline=w:channelSnapshot("rc")
          if not baseline or #baseline<6 then w.message=L.waitChannels;return end
          s.id,s.base,s.untilAt,s.aux,s.value,s.at=id,baseline,getTime()+1500,nil,nil,nil
          w.message=L.flick
        end),
        w:button(L.remove, function()
          local i, r = assigned(id); if i then r.range.start, r.range["end"] = 1500, 1500; send(i) end
        end),
        w:value(L.active, function()
          local v=state();return v==true and L.switchOn or v==false and L.switchOff or L.unavailable
        end)
      }, nil, "switch")
      cards[#cards].rows[4].color=function() return state()==true and "accent" or "text" end
      cards[#cards].switchState=state
      cards[#cards].summary=L.modeQuick
    end
  end
  return cards
end
