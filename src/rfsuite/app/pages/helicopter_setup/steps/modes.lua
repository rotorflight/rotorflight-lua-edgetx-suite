return function(w)
  local L, H = w.L, w.math
  -- Box id, card title, short name, what the mode does (the Configurator's sentences).
  local modes = { {0, L.arm, L.armName, L.armHelp}, {53, L.rescue, L.rescueName, L.rescueHelp},
    {47, L.trainer, L.trainerName, L.trainerHelp} }
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
    w.data.mode_ranges_extra.mode_ranges_extra[i] = { id = r.id, modeLogic = 0, linkedTo = 0 }
    w.bus:add(w:rangeJob("mode_ranges", i))
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
    if w.logInfo then w:keyMessage("switchDetected") end
  end
  w.validate = function() if not assigned(0) then w.message = L.armRequired; return false end; return true end
  local cards, blocks = {}, {}
  -- A text built from a mode's assignment, formatted again only when the assignment changes.
  local function slotText(id, format, none)
    local aux, lo, hi, text = false
    return function()
      local _, r = assigned(id)
      if not r then return none end
      local channel = w:channelNumber(r.auxChannelIndex)
      if channel ~= aux or r.range.start ~= lo or r.range["end"] ~= hi then
        aux, lo, hi = channel, r.range.start, r.range["end"]
        text = format(channel, lo, hi)
      end
      return text
    end
  end
  local function range(id) return slotText(id, function(_, lo, hi) return string.format(L.rangeUs, lo, hi) end, "") end
  local function channel(id) return slotText(id, function(c) return string.format("CH%d", c) end, L.notAssigned) end
  for _, mode in ipairs(modes) do
    local id, label, name = mode[1], mode[2], mode[3]
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
      local function word() local v = state(); return v == true and L.stateOn or v == false and L.stateOff or nil end
      -- What the switch does where it stands now; for ARM that is whether arming would be on.
      local onText = id == 0 and string.format(L.armState, L.stateOn) or string.format(L.modeState, name, L.stateOn)
      local offText = id == 0 and string.format(L.armState, L.stateOff) or string.format(L.modeState, name, L.stateOff)
      local function now()
        local v = state()
        if v == nil then return assigned(id) and L.unavailable or L.notAssigned end
        return v and onText or offText
      end
      local function role() return state() == true and "accent" or "text" end
      local card = w:cardDef(label, L.modeHint, {
        { kind = "value", fullWidth = true, get = now, color = role },
        w:value(L.assigned, slotText(id, function(c, lo, hi) return string.format("CH%d  %d-%d", c, lo, hi) end, L.no)),
        w:button(function() return s.id==id and L.cancelDetect or L.assign end,function()
          if s.id==id then s.id=nil;w.message=L.ready;return end
          local baseline=w:channelSnapshot("rc")
          if not baseline or #baseline<6 then w.message=L.waitChannels;return end
          s.id,s.base,s.untilAt,s.aux,s.value,s.at=id,baseline,getTime()+1500,nil,nil,nil
          w.message=L.flick
        end),
        w:button(L.remove, function()
          local i, r = assigned(id); if i then r.range.start, r.range["end"] = 1500, 1500; send(i) end
        end)
      }, nil, "switch")
      card.switchState = state
      card.summary = mode[4]
      card.badge = id == 0 and L.required or nil
      card.wideText = true
      cards[#cards + 1] = card
      blocks[#blocks + 1] = { title = name, lines = { channel(id), range(id),
        function() return word() or "" end }, colors = { nil, nil, role } }
    end
  end
  -- The step closes on one block per mode: its channel, its range and where the switch is now.
  local done = w:cardDef(L.switchesDone, L.modeHint, {})
  done.summary = function() return w.dirty.mode_ranges and L.stepChanged or L.stepUnchanged end
  done.blocks, done.wideText = blocks, true
  cards[#cards + 1] = done
  return cards
end
