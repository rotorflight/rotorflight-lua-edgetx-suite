-- EdgeTX exposes string functions without a string-method metatable.
debug.getmetatable("").__index = nil
-- Offline routing, lifecycle and fast-path comparison against the original lookup algorithm.
-- Optional --drive <file> runs the same efficiency assertions on an earlier implementation.
local source="src/rfsuite/widgets/dashboard/inflight/drive.lua"
if arg[1]=="--drive" then source=assert(arg[2]) end
local cache={}
_G.rfsuite={require=function(path)
  if path=="lib/log.lua" then return {wanted=function() return false end} end
  if not cache[path] then cache[path]=assert(loadfile("src/rfsuite/"..path))() end
  return cache[path]
end}
local M=assert(loadfile(source))()
-- The overlay offers cells only after the ground read; every drive here starts from a read board.
local readBoard=dofile("bin/dashboard/inflight_board_fixture.lua")(rfsuite.require)
local newDrive=M.newDrive
M.newDrive=function(...) return readBoard(newDrive(...)) end
local Setup=cache["widgets/dashboard/inflight/setup.lua"]
local mask, reads, ticks=0,0,1000
getTime=function() return ticks end
local list={}
for row=1,6 do
  list[#list+1]={name="Trim"..row.."-", swsrc=100+(row-1)*2}
  list[#list+1]={name="Trim"..row.."+", swsrc=101+(row-1)*2}
end
local radio={now=function() return ticks end, sensor=function(name) if name=="PID#" or name=="RTE#" then return 1 end end,
  switchValue=function(id) reads=reads+1; return (mask & (1 << (id-100))) ~= 0 end,
  switchList=function() return list,nil end, setGlobalVariable=function() return true end,
  flightMode=function() return 0 end}
local function settings(mode, assignments)
  local prefs={inflight={enabled=true,trims=true,trim_mode=mode or "rows",adj_trim=4}}
  for row=1,6 do prefs.inflight["row_trim_"..row]=assignments and assignments[row] or row end
  return M.settings(prefs,{inflight={enabled=true}})
end
local function reference(drive)
  local config=drive.settings
  if not config or config.trims~=true then return nil,nil end
  local trims=drive:ensureTrims()
  if trims==nil then return nil,nil end
  if drive:navigateMode() then
    local trim=Setup.trimEntry(trims,config.adj_trim)
    if trim then
      if radio.switchValue(trim.plus)==true then return drive.row,true end
      if radio.switchValue(trim.minus)==true then return drive.row,false end
    end
    return nil,nil
  end
  for row=1,6 do
    local trim=Setup.trimEntry(trims,config.rowTrim and config.rowTrim[row])
    if trim then
      if radio.switchValue(trim.plus)==true then return row,true end
      if radio.switchValue(trim.minus)==true then return row,false end
    end
  end
  return nil,nil
end
local comparisons=0
for _, config in ipairs({settings(),settings("rows",{103,105,101,107,0,999}),settings("navigate")}) do
  local drive=M.newDrive(radio,config)
  assert(drive:ensureTrims(),"trim discovery failed")
  for bits=0,4095 do
    mask=bits; reads=0
    local a,b=drive:pollTrims(); local count=reads; reads=0
    local c,d=reference(drive)
    assert(a==c and b==d and count==reads,"routing or read order changed at mask "..bits)
    comparisons=comparisons+1
  end
end
mask=0
local drive=M.newDrive(radio,settings())
local lookups=0
local trimEntry=Setup.trimEntry
Setup.trimEntry=function(...) lookups=lookups+1; return trimEntry(...) end
drive:pollTrims(); lookups=0; reads=0
drive:pollTrims()
assert(reads==12,"idle input sample was skipped")
assert(lookups==0,"warm row poll still resolves assignments")
-- A sliced walk must not publish a partial route; migration precedes route construction.
local calls=0
local sliced={}
for key,value in pairs(radio) do sliced[key]=value end
sliced.switchList=function()
  calls=calls+1
  if calls==1 then return {list[1]},2 end
  local tail={}; for i=2,#list do tail[#tail+1]=list[i] end
  return tail,nil
end
local pending=M.newDrive(sliced,settings())
assert(pending:pollTrims()==nil and pending.rowTrims==nil,"partial trim walk was cached")
pending:pollTrims()
assert(pending.settings.rowTrim[1]==101,"legacy trim migration did not run")
-- Real settings replacement through M.get must discard the old route and re-walk.
local widget={preferences={inflight={enabled=true,trims=true,trim_mode="rows",row_trim_1=1}},
  modelPreferences={inflight={enabled=true}},state={}}
local first=M.get(widget); first.radio=radio; first:pollTrims()
assert(first.rowTrims and first.rowTrims[1].plus==101,"initial route missing")
widget.preferences={inflight={enabled=true,trims=true,trim_mode="rows",row_trim_1=2}}
local second=M.get(widget)
assert(second.rowTrims==nil and second.trimsResolved==false,"settings left a stale route")
second:pollTrims()
assert(second.rowTrims[1].plus==103,"changed assignment was not adopted")
-- Missing trims and trims disabled remain inert.
local absent={}; for key,value in pairs(radio) do absent[key]=value end
absent.switchList=function() return {},nil end
assert(M.newDrive(absent,settings()):pollTrims()==nil)
local disabled=settings(); disabled.trims=false; reads=0
assert(M.newDrive(radio,disabled):pollTrims()==nil and reads==0)
-- Run identical input edges through the full fast path with the old and new routing.
-- Compare emitted GVAR writes and pulse/cooldown state after every pass.
local function trace(useReference)
  local writes={}
  local scripted={}
  for key,value in pairs(radio) do scripted[key]=value end
  scripted.setGlobalVariable=function(index, fm, value)
    writes[#writes+1]=table.concat({index,fm,value}, ":")
    return true
  end
  local d=M.newDrive(scripted,settings())
  if useReference then d.pollTrims=reference end
  d.live=true; d.phase="live"; d.bankShown=1
  d.sessionProfiles={pid={[1]=true},rate={[1]=true}}
  local states={}
  ticks=2000
  for step=1,200 do
    -- Short taps, alternating direction, overlapping trims and held/released inputs.
    mask=({0,2,2,0,1,0,4095,0,128,128,128,0})[((step-1)%12)+1]
    ticks=ticks+({1,2,5,10})[((step-1)%4)+1]
    d:fastTick(ticks)
    states[#states+1]=table.concat({d.row,d.bank,d.written,d.trimDir or 0,
      d.trimPulseUntil or 0,d.trimCoolUntil or 0,d.fired}, ":")
  end
  d:cleanup(false)
  return table.concat(writes,";"),table.concat(states,";")
end
local oldWrites,oldStates=trace(true)
local newWrites,newStates=trace(false)
assert(#newWrites>0,"fast-path trace produced no output")
assert(oldWrites==newWrites and oldStates==newStates,"fast-path pulse or output trace changed")
mask=0
local function count(fn)
  local n=0; debug.sethook(function() n=n+1 end,"",1); fn(); debug.sethook(); return n
end
assert(count(function() return {1,2,3,4,5,6,7,8} end)>count(function() end),"instruction control failed")
local poll=count(function() drive:pollTrims() end)
drive.live=true; drive.phase="live"; drive.fastAt=nil
drive.sessionProfiles={pid={[1]=true},rate={[1]=true}}
local fast=count(function() ticks=ticks+5; drive:fastTick(ticks) end)
print(comparisons.." routing/read-count comparisons passed; sliced discovery, settings invalidation and disabled inputs passed")
print("warm row poll: "..poll.." instructions; idle fastTick: "..fast.." instructions (stubs included)")
