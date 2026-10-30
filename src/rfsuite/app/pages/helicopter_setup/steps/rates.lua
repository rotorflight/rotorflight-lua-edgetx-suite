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
  -- What a profile will hold: its current rates, or the chosen style applied to a copy of them.
  -- The copy is made once per choice, not per frame.
  local previews={}
  local function shown(index)
    local t=w.rateTunings and w.rateTunings[index]
    if not t then return nil end
    -- Discard clears the styles while the closing card may still be drawn.
    local s=w.rateStyles and w.rateStyles[index]
    if not s then return t end
    local p=previews[index]
    if not p or p.style~=s or p.base~=t then
      local copy={};for k,v in pairs(t) do copy[k]=v end
      H.style(copy,s,ratesType);p={style=s,base=t,tuning=copy};previews[index]=p
    end
    return p.tuning
  end
  -- A text built from a profile's shown rates, formatted again only when they change.
  local function memo(index,format)
    -- false, not nil: a profile not read yet must still produce its placeholder once.
    local last,text=false,nil
    return function()
      local t=shown(index)
      if t~=last then last,text=t,t and format(t) or "--" end
      return text
    end
  end
  local function number(v) return v and tostring(v) or "--" end
  local function caption(t)
    local c,_,y,ce,_,ye=H.rateValues(t)
    return string.format(L.rateLine,L.cyclic,number(c),L.expo,number(ce)).."\n"..
      string.format(L.rateLine,L.yaw,number(y),L.expo,number(ye)).."\n"..
      L.collective.." "..string.format(L.degreeValue,number(H.collective(t)))
  end
  local function short(t)
    local c,_,y=H.rateValues(t)
    return string.format(L.rateShort,number(c),number(y),number(H.collective(t)))
  end
  local switched=H.profileMode(w.data.adjustment_ranges.adjustment_ranges)==1
    and H.rangeOf(w.data.adjustment_ranges.adjustment_ranges,1)~=nil
  local styles={L.styleCustom,L.styleTrainer,L.styleSport,L.style3d}
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
    -- One tile per style; Custom keeps the profile's own rates and is marked while none matches.
    for n,name in ipairs(styles) do
      local choice=n>1 and n-1 or nil
      rows[#rows+1]={ kind="tile",label=name,
        selected=function() return style()==choice end,
        press=function() w.rateStyles[index]=choice;w:touch("rc_tuning") end }
    end
    local title=switched and string.format(L.switchRateProfile,position,index+1) or string.format(L.rateProfileTitle,index+1)
    local card=w:cardDef(title,L.ratesHint.."\n"..L.rateNoMatch,rows,enter,"rates")
    card.rateStyle=style
    card.summary=function() return style() and L.ratesHint or L.rateNoMatchShort end
    card.caption,card.captionShort=memo(index,caption),memo(index,short)
    card.wideText,card.dense=true,#rows>4
    cards[#cards+1]=card
  end
  -- The step closes on a table of everything a style sets: a column per profile, the rates type,
  -- a row per axis with rate and expo, and the collective with its expo, as Save & next will hold them.
  local TYPES={[4]="Actual",[6]="Rotorflight"}
  local columns,typeRow,curveRow,collectiveRow={},{},{},{}
  local axisRows={{},{},{}}
  for _,id in ipairs(profiles) do
    columns[#columns+1]=string.format(L.rateProfileTitle,id+1)
    typeRow[#typeRow+1]=memo(id,function(t) return TYPES[t.rates_type] or "--" end)
    -- A style also writes the Rotorflight curve shape, or the Actual centre rates.
    curveRow[#curveRow+1]=memo(id,function(t)
      if t.rates_type==6 then
        local a,b,c,d=t.rates_1,t.rates_2,t.rates_3,t.rates_4
        if a==b and b==c and c==d then return tostring(a) end
        return string.format("%s/%s/%s/%s",a,b,c,d)
      end
      if t.rates_type==4 then return string.format("%s/%s/%s",t.rcRates_1*10,t.rcRates_2*10,t.rcRates_3*10) end
      return "--"
    end)
    for axis=1,3 do
      local cells=axisRows[axis]
      cells[#cells+1]=memo(id,function(t)
        local v={H.rateValues(t)};return string.format(L.rateCell,number(v[axis]),number(v[axis+3]))
      end)
    end
    collectiveRow[#collectiveRow+1]=memo(id,function(t)
      return string.format(L.collectiveCell,number(H.collective(t)),number(t.rcExpo_4))
    end)
  end
  local done=w:cardDef(L.ratesSet,L.ratesHint.."\n"..L.rateNoMatch,{},enter)
  done.summary=function()
    local chosen=w.rateStyles
    return chosen and next(chosen) and L.stepChanged or L.stepUnchanged
  end
  done.table={columns=columns,rows={{label=L.ratesType,cells=typeRow},
    {label=L.curveShape,cells=curveRow},{label=L.roll,cells=axisRows[1]},{label=L.pitch,cells=axisRows[2]},
    {label=L.yaw,cells=axisRows[3]},{label=L.collective,cells=collectiveRow}},legend=L.rateLegend}
  done.wideText=true
  cards[#cards+1]=done
  return cards
end
