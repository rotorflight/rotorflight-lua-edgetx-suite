return function(w)
  local L,H = w.L,w.math
  w.rateStyles = w.rateStyles or {}
  w.rateProfiles = H.rateProfiles(w.data.adjustment_ranges.adjustment_ranges,
    w.data.status.current_control_rate_profile_index,w.data.status.control_rate_profile_count)
  local profiles=w.rateProfiles
  if not w.rateProfile or not w.rateTunings or not w.rateTunings[w.rateProfile] then w.rateProfile=profiles[1] end
  local ratesType=w:apiAtLeast(9) and 6 or 4
  w.commit = function()
    local chosen={}
    for _,i in ipairs(profiles) do if w.rateStyles[i] then chosen[#chosen+1]=i end end
    if #chosen==0 then return end
    w:profileLoop("rates", #chosen, function(d,i)
      H.style(d,w.rateStyles[i],ratesType); w.rateTunings[i]=d
    end,chosen)
    w:run(function() w.rateStyles={} end)
  end
  local function enter()
    if w.rateLoaded then return end
    w.rateLoaded,w.transition,w.rateTunings,w.rateMatched=true,true,{},{}
    local original=w.data.status.current_control_rate_profile_index+128
    w.restoreProfile=original
    for _,id in ipairs(profiles) do
      local index=id
      w:action("set_pid_profile",{index+128})
      w:read("rc_tuning",function(d) w.rateTunings[index]=d; w.rateMatched[index]=H.matchStyle(d,ratesType) end)
    end
    w:action("set_pid_profile",{original},function() w.restoreProfile=nil end)
    w:read("rc_tuning",function(d) w.data.rc_tuning=d end)
    w:run(function() w.transition=nil end)
  end
  local switched=H.profileMode(w.data.adjustment_ranges.adjustment_ranges)==1
    and H.rangeOf(w.data.adjustment_ranges.adjustment_ranges,1)~=nil
  local cards={}
  for position,id in ipairs(profiles) do
    local index=id
    local function style()
      return w.rateStyles and w.rateStyles[index] or w.rateMatched and w.rateMatched[index]
    end
    local rows={}
    if switched and position==1 then
      rows[#rows+1]=w:button(L.suggest,function()
        for i,profile in ipairs(profiles) do w.rateStyles[profile]=i end;w:touch("rc_tuning")
      end,function() return #profiles==3 end)
    end
    rows[#rows+1]={ kind="choice",label=L.flyingStyle,values={L.keep,L.trainerRates,L.sportRates,L.threeDRates},
      get=function() return (style() or 0)+1 end,
      set=function(v) w.rateStyles[index]=v>1 and v-1 or nil;w:touch("rc_tuning") end }
    rows[#rows+1]=w:value(L.collective,function() return H.collective((w.rateTunings or {})[index] or w.data.rc_tuning) or "--" end)
    local title=switched and string.format(L.switchRateProfile,position,index+1) or string.format(L.rateProfileTitle,index+1)
    local card=w:cardDef(title,L.ratesHint.."\n"..L.rateNoMatch,rows,enter,"rates")
    card.rateStyle=style
    card.summary=function() return style() and L.ratesHint or L.rateNoMatchShort end
    cards[#cards+1]=card
  end
  return cards
end
