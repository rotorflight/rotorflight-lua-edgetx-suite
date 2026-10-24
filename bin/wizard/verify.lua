-- Offline protocol, lifecycle and per-call budget regression checks. No simulator.
local ROOT = "src/rfsuite/"
local BASE = "/SCRIPTS/TOOLS/rfsuite-core/"
local PATH = "app/pages/helicopter_setup/"
local ticks, assertions, failures, worst = 100, 0, 0, {}
local function check(ok, name)
  assertions = assertions + 1
  if not ok then failures = failures + 1; print("FAIL " .. name) end
end
local function eq(a,b,name) check(a == b, name .. " (" .. tostring(a) .. "/" .. tostring(b) .. ")") end
local function load(path) return assert(loadfile(ROOT .. path))() end
function getTime() return ticks end
COLOR_THEME_PRIMARY1, COLOR_THEME_PRIMARY2, COLOR_THEME_PRIMARY3, COLOR_THEME_SECONDARY1 = 1, 2, 3, 4
-- Keep RGB channels intact in exported scenes for the desktop renderer.
lcd = { RGB = function(r,g,b) return (r << 16) | (g << 8) | b end }
SMLSIZE, MIDSIZE = 0, 1
LCD_W, LCD_H = 480, 272
local armed = false
_G.rfsuite = { session = { fblConnected = true, mcu_id = "test-board", apiVersion = "12.10" } }
local q = { messages = {}, sent = {}, pending = nil }
function q:add(m) self.messages[#self.messages + 1] = m end
function q:clear(client)
  local keep = {}
  for _, m in ipairs(self.messages) do
    if m.client ~= client then keep[#keep + 1] = m elseif m.errorHandler then m.errorHandler(m, "cleared") end
  end
  self.messages = keep
end
local runtime = { getState = function() return { queue = q } end, armedReading = function() return armed, true end }
local originalLoadScript
function loadScript(path)
  local relative = string.sub(path, #BASE + 1)
  if relative == "tasks/msp/runtime.lua" then return function() return runtime end end
  if relative == "lib/armed.lua" then return function() return { changeCount = function() return 0 end } end end
  return loadfile(ROOT .. relative)
end
local function u16(p,v) p[#p+1],p[#p+2] = v & 255,(v >> 8) & 255 end
local modules = {}
local function api(name) if not modules[name] then modules[name] = load("tasks/msp/api/" .. name .. ".lua") end; return modules[name] end
local lockDisabled, statusServoCount, recordFault = true, 4, nil
local function status()
  local values = { sensor_status = 3, pid_profile_count = 3, control_rate_profile_count = 3,
    motor_count = 2, servo_count = statusServoCount, current_pid_profile_index = 1, current_control_rate_profile_index = 2,
    arming_disable_flags = lockDisabled and (1 << 16) or 0 }
  local p = {}
  for _, f in ipairs(api("status").fields) do
    local n = f[2] == "U32" and 4 or f[2] == "U16" and 2 or 1
    local v = values[f[1]] or 0
    for _ = 1,n do p[#p+1] = v & 255; v = v >> 8 end
  end
  return p
end
local fixtures = {
  -- MSP_BOARD_INFO with length-prefixed strings, board design F7C1.
  [4] = {83,55,88,50,0,0,0,1,9,83,84,77,51,50,70,55,88,50,
    8,78,69,88,85,83,95,70,55,4,70,55,67,49,4,82,68,77,83},
  [101] = status(), [103] = {240,5,240,5,240,5,240,5}, [104] = {232,3,232,3,0,0,0,0,0,0,0,0,0,0,0,0},
  [113] = {0,0,0,0,0,0,0,0,0,0}, [114] = {220,5,220,5,220,5,220,5,232,3,232,3,220,5,208,7},
  [108] = {0,0,0,0,0,0}, [139] = {0}, [0x5F14] = {0,0}
}
fixtures[52] = {}; for _ = 1,42*14 do fixtures[52][#fixtures[52]+1] = 0 end
fixtures[170] = {}; for _ = 0,28 do u16(fixtures[170],1000);u16(fixtures[170],-1000);u16(fixtures[170],1000) end
local byCommand = {}
for _, name in ipairs({ "board_info","telemetry_config","status","boxnames","boxids","mode_ranges","mode_ranges_extra","adjustment_ranges",
  "feature_config","board_alignment_config","serial_config","rx_map","rx_config","rc_config","motor_config",
  "esc_sensor_config","governor_config","mixer_config","mixer_input","servo_configurations","servo","rc_tuning",
  "tail_motor_output","governor_profile","rc","attitude","motor","motor_telemetry","rx_channels","rc_command" }) do
  local a = api(name); byCommand[a.command] = a
end
local defaultRx, rxSweep = fixtures[114], false
local failCommand, legacy, legacyMixer = nil, false, false
local function pump()
  local m = table.remove(q.messages,1); if not m then return end
  q.sent[#q.sent+1] = m
  if m.command==99 then lockDisabled=m.payload[1]==1;fixtures[101]=status() end
  if m.command == failCommand or (legacy and m.command == 196 and #m.payload == 4) then
    if m.errorHandler then m.errorHandler(m,"error") end; return
  end
  if (m.command==193 or m.command==191) and #m.payload==4 and not legacy and not (m.command==191 and legacyMixer) then
    if m.errorHandler then m.errorHandler(m,"refused") end;return
  end
  -- Real telemetry cannot serialize the USB-sized adjustment/servo tables.
  if m.command == 52 or m.command == 120 then
    if m.errorHandler then m.errorHandler(m,"max_retries") end; return
  end
  if recordFault and m.command==recordFault.command and m.payload[1]==recordFault.index and not recordFault.short then
    if m.errorHandler then m.errorHandler(m,"max_retries") end;return
  end
  local b
  if m.command == 156 then
    b = {};local offset=m.payload[1]*14
    for i=1,14 do b[i]=fixtures[52][offset+i] end
  elseif m.command == 125 then
    b = {};local full=fixtures[120] or api("servo_configurations").simulatorResponse
    local count=full[1];local raw=m.payload[1]
    local slot=count>8 and raw>=8 and raw-8+count-18 or raw
    for i=1,16 do b[i]=full[1+slot*16+i] end
  end
  if b and recordFault and m.command==recordFault.command and m.payload[1]==recordFault.index and recordFault.short then b[#b]=nil end
  b = b or fixtures[m.command] or (byCommand[m.command] and byCommand[m.command].simulatorResponse) or {}
  -- The walks move the four sticks end to end between replies, as a pilot does on the stick travel card.
  if m.command==114 and fixtures[114]==defaultRx then
    rxSweep=not rxSweep
    local swept={};for i,v in ipairs(b) do swept[i]=v end
    for i=1,7,2 do swept[i],swept[i+1]=(rxSweep and 2000 or 1000)&255,(rxSweep and 2000 or 1000)>>8 end
    b=swept
  end
  if m.processReply then m.processReply(m,b) end
end
local function measure(name, fn)
  local count = 0
  debug.sethook(function() count = count + 1 end, "", 1)
  fn()
  debug.sethook()
  worst[name] = math.max(worst[name] or 0, count)
  if count > 14000 then check(false, name .. " exceeds 14000: " .. count) end
end
local H = load(PATH .. "math.lua")
for i=1,#arg do
  if arg[i]=="--mixer-api" then modules.mixer_override=assert(loadfile(arg[i+1]))() end
end
eq(H.calibrated(-1000,18),-500,"pitch scale preserves sign")
eq(H.calibrated(1000,4.5),2000,"pitch scale clamp")
eq(H.calibrated(1000,0),nil,"zero measurement refused")
local lo,hi = H.switchRange(1000,2000); eq(lo,1500,"switch lower band");eq(hi,2100,"switch upper band")
eq(H.moved({301,200}),nil,"ambiguous movement refused");eq(H.moved({500,100}),1,"clear movement accepted")
local p = api("mixer_override").buildWritePayload({index=3,value=-1000})
eq(#p,3,"mixer write is one record");eq(p[1],3,"mixer index");eq(p[2],24,"signed mixer low")
eq(#api("mixer_override").buildWritePayload({index=4,value=0,timeout=3000}),5,"timed mixer length")
eq(#api("servo_override").buildWritePayload({servo_id=2,action=2001}),3,"release has no timeout")
eq(#api("servo_override_all").buildWritePayload({value=2001,timeout=500}),4,"safe timeout probe")
check(api("rc_command").parse({255,255,0,0,0,0,0,0,0,0}).commands[1] == -1,"signed RC command")
check(api("rx_channels").parse({1}) == nil,"truncated raw channel reply refused")
check(api("servo").parse({1}) == nil,"truncated servo reply refused")
check(api("motor_telemetry").parse({1}) == nil,"truncated telemetry reply refused")
local telem = {1}; for _=1,16 do telem[#telem+1]=0 end
telem[14],telem[15] = 156,255
eq(api("motor_telemetry").parse(telem).motors[1].temperature,-100,"signed ESC temperature")
local bad = {}; for i=1,#telem-1 do bad[i]=telem[i] end
check(api("motor_telemetry").parse(bad) == nil,"telemetry positive/negative length control")

local L = load(PATH .. "labels.lua")
-- Resolve the real locale bundle for geometry checks and scene exports.
local locale="en"
for i=1,#arg do if arg[i]=="--locale" then locale=arg[i+1] end end
local bundle = load("i18n/"..locale..".lua")
for k in pairs(L) do if bundle.app.modules.helicopter_setup[k] then L[k] = bundle.app.modules.helicopter_setup[k] end end
L.steps = { L.sensors,L.receiver,L.modeSwitches,L.profiles,L.rates,L.swash,L.servoType,L.governor,L.motor,L.connect,
  L.spinTest,L.escTelemetry,L.servoDirectionCentre,L.controlDirections,L.level,L.bladePitch,L.tail,L.gyroCheck,L.finish }
local rawLabels = load(PATH .. "labels.lua")
check(#rawLabels.numberedSteps == 19 and rawLabels.numberedSteps[1] == "1. " .. rawLabels.sensors
  and rawLabels.numberedSteps[19] == "19. " .. rawLabels.finish, "step chooser entries are numbered like the source")
L.numberedSteps = {}
for i, name in ipairs(L.steps) do L.numberedSteps[i] = i .. ". " .. name end
do
  local manifest = assert(loadfile("src/rfsuite/app/manifest.lua"))()
  local numbered = 0
  for _, menu in pairs(manifest.menus or {}) do
    for _, entry in ipairs(menu.pages or {}) do
      local n = tonumber(string.match(entry.id or "", "^step_(%d%d)$") or "")
      if n and menu.title == "@i18n(app.modules.helicopter_setup.name)@" then
        check(string.sub(entry.title, 1, #(n .. ". @i18n(")) == n .. ". @i18n(", "menu entry " .. n .. " is numbered")
        numbered = numbered + 1
      end
    end
  end
  eq(numbered, 19, "all nineteen step entries in the wizard menu are numbered")
  -- Done marks: each step tile reads its bit of the connected FC's completion record.
  local steps = {}
  for _, entry in ipairs(manifest.menus.helicopter_setup_menu.pages) do
    local n = tonumber(string.match(entry.id or "", "^step_(%d%d)$") or "")
    if n then steps[n] = entry end
  end
  local session = _G.rfsuite.session
  local kept = session.helicopterSetupHistory
  session.helicopterSetupHistory = { id = session.mcu_id, mask = 5 }
  check(type(steps[1].doneWhen) == "function" and steps[1].doneWhen() == true and steps[2].doneWhen() == false
    and steps[3].doneWhen() == true, "MENU step tiles follow the connected FC's completion record")
  session.helicopterSetupHistory = { id = "another-board", mask = 7 }
  check(steps[1].doneWhen() == false, "MENU another FC's record never marks a tile")
  session.helicopterSetupHistory = kept
end
local function beginWorld()
  q.messages,q.sent = {},{}
  local w = load(PATH .. "controller.lua").new(runtime,load(PATH .. "transport.lua"),H,L)
  w.palette=load(PATH .. "palette.lua")
  w.newAttitudeView=load(PATH .. "attitude_view.lua").new
  w.newServoGrid=load(PATH .. "servo_grid.lua").append
  load(PATH .. "forms.lua").attach(w,load("lib/port_labels.lua"));load(PATH .. "workflow.lua").attach(w);load(PATH .. "navigation.lua").attach(w)
  w.requestRebuild = function() w.rebuilds = (w.rebuilds or 0)+1 end
  -- Controller-only worlds have no telemetry poller: both packed FC state words are live.
  local packed = load("lib/system_state.lua")
  w.systemStatus, w.systemConfig = packed.decode("system_status", 0), packed.decode("system_config", 0)
  w:load()
  return w
end
local function world()
  local w=beginWorld()
  for _=1,1000 do measure("wakeup",function() w:tick() end);pump(); ticks=ticks+1; if w.ready or w.error then break end end
  check(w.ready and not w.error,"initial configuration read")
  check(w.overview==true,"initial step overview is available")
  w:startStep(1,true)
  w:tick(); pump(); ticks=ticks+1
  return w
end
local w = world()
check(w.timed,"timeout capability proved per override parser")
eq(q.sent[1].command,99,"arming disabled before configuration writes")
eq(q.sent[1].payload[1],1,"arming disabled payload")
local steps = { "sensors","receiver","modes","profiles","rates","swash","servoType","governor","motor","connect",
  "throttle","escTelemetry","servos","direction","level","pitch","tail","gyro","finish" }
local view = load(PATH .. "view.lua")
local diagrams = load(PATH .. "diagrams.lua")
for i=1,#arg do if arg[i]=="--view" then view=assert(loadfile(arg[i+1]))() end end
assert(loadfile("bin/wizard/servo_hz.lua"))()({
  world=world,view=view,diagrams=diagrams,check=check,eq=eq,L=L,q=q,pump=pump,
  advance=function(value) ticks=ticks+value end,fixtures=fixtures,api=api
})
if arg[1]=="--servo-hz-only" then
  print(string.format("Wizard: %d assertions, %d failures",assertions,failures))
  os.exit(failures>0 and 1 or 0)
end
local exported = {}
local function resolve(t)
  local out = {}
  for k,v in pairs(t) do
    if type(v) == "function" then
      if k=="pos" then
        local x,y=v()
        assert(type(x)=="number" and type(y)=="number" and x>=0 and y>=0,"LVGL pos returns two coordinates")
        out[k]={x,y}
      elseif k=="pts" then out[k]=resolve(v())
      elseif k=="text" or k=="get" or k=="active" or k=="visible" or k=="color" or k=="file" then out[k] = v()
      elseif k=="display" and t.get then out[k] = v(t.get()) end
    elseif type(v)=="table" then out[k] = resolve(v)
    else out[k] = v end
  end
  return out
end
local historyPreview=world()
load(PATH.."history.lua").attach(historyPreview,load(PATH.."history_store.lua"))
load(PATH.."feedback.lua").attach(historyPreview,load("lib/system_state.lua"),{})
historyPreview.history:publish(1)
for _,size in ipairs({{320,240},{480,272},{480,320},{800,480}}) do
  local loadingPage=load(PATH.."page.lua")
  local loadingCtx={w=size[1],h=size[2],children={},requestRebuild=function() end}
  loadingPage.build(loadingCtx)
  for _=1,12 do loadingPage.wakeup(loadingCtx) end
  loadingCtx.children={};loadingPage.build(loadingCtx)
  local snapshot=resolve(loadingCtx.children)
  for _,node in ipairs(snapshot) do
    if type(node.text)=="string" then
      local key=string.match(node.text,"^@i18n%(app%.modules%.helicopter_setup%.([%w_]+)%)@$")
      if key then node.text=bundle.app.modules.helicopter_setup[key] end
    end
  end
  exported[#exported+1]={step=0,name="loading",task="loading",width=size[1],height=size[2],children=snapshot}
  loadingPage.onClose()
  historyPreview.error,historyPreview.statusFailure=nil,nil
  historyPreview.overview,historyPreview.historyMode=nil,nil
  historyPreview.activeModelName="Model01"
  historyPreview.modelPreparationRequired,historyPreview.modelPreparationDone=true,nil
  historyPreview:buildModelPreparation()
  local modelScene=view.new(historyPreview,{w=size[1],h=size[2]},diagrams)
  while not modelScene.done do modelScene:step() end
  exported[#exported+1]={step=0,name="model-preparation",task="model",width=size[1],height=size[2],children=resolve(modelScene.children)}
  historyPreview.modelPreparationCard,historyPreview.modelPreparationRequired=nil,nil
  historyPreview.overview,historyPreview.historyMode=nil,true
  historyPreview:buildHistory();historyPreview.message=L.ready
  local menu=view.new(historyPreview,{w=size[1],h=size[2]},diagrams)
  while not menu.done do menu:step() end
  exported[#exported+1]={step=0,name="history",width=size[1],height=size[2],children=resolve(menu.children)}
  historyPreview.historyMode=nil;historyPreview.singleStep=true;historyPreview.step=13
  historyPreview:updateHistoryHints();historyPreview:buildPreparation()
  local preparation=view.new(historyPreview,{w=size[1],h=size[2]},diagrams)
  while not preparation.done do preparation:step() end
  exported[#exported+1]={step=0,name="preparation",task="prepare",width=size[1],height=size[2],children=resolve(preparation.children)}
  historyPreview.error,historyPreview.statusFailure="status: timeout",true
  local failure=view.new(historyPreview,{w=size[1],h=size[2]},diagrams)
  while not failure.done do failure:step() end
  exported[#exported+1]={step=0,name="status-error",task="status-error",width=size[1],height=size[2],children=resolve(failure.children)}
  historyPreview.error,historyPreview.statusFailure=nil,nil
  historyPreview.recoveryRequired=true;historyPreview:buildModelPreparation()
  local recovery=view.new(historyPreview,{w=size[1],h=size[2]},diagrams)
  while not recovery.done do recovery:step() end
  exported[#exported+1]={step=0,name="recovery",task="recovery",width=size[1],height=size[2],children=resolve(recovery.children)}
  historyPreview.recoveryRequired,historyPreview.recoveryCard=nil,nil
  historyPreview.disconnectExit=true
  local disconnected=view.new(historyPreview,{w=size[1],h=size[2]},diagrams)
  while not disconnected.done do disconnected:step() end
  exported[#exported+1]={step=0,name="disconnected",task="disconnected",width=size[1],height=size[2],children=resolve(disconnected.children)}
  historyPreview.disconnectExit=nil
end
-- Properties each widget type already used on the radio; lvgl.build raises "Invalid property" on others.
RADIO_PROPS={}
for t,keys in pairs({label="color,font,h,pos,text,type,visible,w,x,y,align",
  momentaryButton="active,color,h,press,release,text,textColor,type,w,x,y",numberEdit="active,display,get,h,max,min,set,type,w,x,y",
  button="active,color,font,h,press,text,textColor,type,visible,w,x,y",choice="active,get,h,set,title,type,values,w,x,y",
  rectangle="color,filled,h,thickness,type,w,x,y",line="color,pts,thickness,type,visible",
  image="file,h,type,visible,w,x,y"}) do
  RADIO_PROPS[t]={};for k in string.gmatch(keys,"[^,]+") do RADIO_PROPS[t][k]=true end
end
for _, size in ipairs({ {320,240},{480,272},{480,320},{800,480} }) do
  for n,name in ipairs(steps) do
    w.step, w.stepKey, w.rebootPending, w.transition = n,name,nil,nil
    w.wideScreen = size[1] >= 700
    -- Rendered with a host that opens pages, so the extra buttons are laid out too.
    w.openPage = function() end
    measure("definition",function() w.cards = load(PATH .. "steps/" .. name .. ".lua")(w) end)
    if n==2 then
      w.data.rx_channels={channels={1500,1500,1500,1500,1500,1500,1500,1500}}
      w.data.rx_channels.channels[w.data.rx_map.throttle+1]=1000
      w.rxChannelsAt=getTime();w.rx.low,w.rx.high=1000,2000
    end
    check(type(w.cards)=="table" and #w.cards>0,name.." has cards")
    for c, card in ipairs(w.cards) do
      w.card = c
      local job
      measure("view",function() job = view.new(w,{ w=size[1],h=size[2] },diagrams) end)
      while not job.done do measure("view slice",function() job:step() end) end
      measure("reactive",function() resolve(job.children) end)
      for _,item in ipairs(job.children) do
        if item.y and item.h then check(item.y+item.h<=size[2],name.." fits height") end
        if size[1]>=700 and item.type=="label" and item.y==50 and item.text==card.title and card.art~="attitude" then
          check(item.w>=size[1]-40,name.." card title spans the full width on large screens")
        end
        local known=RADIO_PROPS[item.type]
        check(known~=nil,name.." widget type "..tostring(item.type).." is known on the radio")
        for key in pairs(item) do
          if known and not known[key] then check(false,name.." "..item.type.." property '"..tostring(key).."' is known on the radio") end
        end
        if item.type=="choice" and item.values and #item.values==2 then
          check(not ((item.values[1]==L.no or item.values[1]=="@i18n(app.modules.helicopter_setup.no)@") and
            (item.values[2]==L.yes or item.values[2]=="@i18n(app.modules.helicopter_setup.yes)@")),
            name.." a yes/no answer is a toggle, not a native list")
        end
        if size[1]>=700 and card.grid and item.type=="label" and item.y==94 then
          check(item.w>=size[1]-40,name.." grid summary spans the full width on large screens")
        end
        if card.grid and item.type=="button" and type(item.text)=="string" and (#item.text<=4 or size[1]>=700) then
          local big=size[1]>=700
          check(item.w>=#item.text*(item.font==SMLSIZE and (big and 8 or 6) or (big and 12 or 8))+12,name.." grid button label fits "..size[1].."x"..size[2])
        end
        if item.type=="line" then
          local pts=type(item.pts)=="function" and item.pts() or item.pts
          for _,point in ipairs(pts) do
            check(type(point)=="table" and #point==2 and point[1]%1==0 and point[2]%1==0 and
              point[1]>=0 and point[2]>=0 and point[1]<size[1] and point[2]<size[2],name.." safe LVGL points")
          end
        end
      end
      if card.art then
        local lines,images=0,0
        for _,item in ipairs(job.children) do
          if item.type=="line" then lines=lines+1 end
          if item.type=="image" then
            images=images+1
            -- The picture ships in the package, and its frame keeps the 220x160 aspect.
            local file=item.file
            if type(file)=="function" then file=file() end
            local rel=string.match(file or "","^/SCRIPTS/TOOLS/rfsuite%-core/(.+)$")
            local f=rel and io.open("src/rfsuite/"..rel,"rb")
            check(f~=nil,name.." picture "..tostring(file).." exists in the package")
            if f then f:close() end
            check(item.w>0 and item.h>0 and math.abs(item.w*160-item.h*220)<=220,name.." picture frame keeps its aspect on "..size[1].."x"..size[2])
          end
        end
        check(lines>=4 or images==1,name.." illustrates the task on "..size[1].."x"..size[2])
      end
      if c==1 then exported[#exported+1] = {step=n,name=name,width=size[1],height=size[2],children=resolve(job.children)} end
      if n==1 and c==4 then
        w.data.attitude={roll=0,pitch=0,yaw=0};w.attitudeAt=getTime()
        w.attitudeView:update(w.data.attitude,w.attitudeAt,getTime(),true)
      end
      if ((n==5 or n==8 or n==9 or n==10 or n==11 or n==12) and c>1) or (n==1 and c>1) or (n==2 and c>1) or (n==6 and c>1) or (n==7 and c==2) or ((n==15 or n==16 or n==17) and c==2) or (n==13 and c==2) or ((n==14 or n==18) and c>1) then
        exported[#exported+1] = {step=n,name=name,task=c,width=size[1],height=size[2],children=resolve(job.children)}
      end
      if n==6 then
        -- Each of the three cards swaps its picture in the existing scene when its value moves.
        local m=w.data.mixer_config
        local field=({"swash_type","main_rotor_dir","tail_rotor_mode"})[c]
        local values=({{2,5},{0,1},{0,1}})[c]
        local old=m[field]
        local function picture()
          for _,item in ipairs(job.children) do
            if item.type=="image" then return type(item.file)=="function" and item.file() or item.file end
          end
        end
        local count=#job.children
        m[field]=values[1]
        if c==1 then exported[#exported+1] = {step=n,name=name,task="120",width=size[1],height=size[2],children=resolve(job.children)} end
        local first=picture()
        m[field]=values[2]
        local second=picture()
        check(first~=nil and second~=nil and first~=second,"swash card "..c.." picture follows "..field)
        eq(#job.children,count,"changing "..field.." keeps the scene")
        m[field]=old
        if c==1 then
          -- swash_type 1..6 is Direct, 120, 135, 140, 90L, 90V; a motor tail drops servo 4.
          local tail,rear=m.tail_rotor_mode,w.swashRear
          m.tail_rotor_mode=1;w.swashRear=false
          for s,want in ipairs({"swash%-direct","swash%-120%-front","swash%-135%-front","swash%-140%-front","swash%-90l","swash%-90v"}) do
            m.swash_type=s
            check(string.find(picture() or "","/"..want.."%.png$")~=nil,"swash type "..s.." shows its own layout")
          end
          m.swash_type=3;w.swashRear=true;m.tail_rotor_mode=0
          check(string.find(picture() or "","/swash%-135%-rear%-tail%.png$")~=nil,"servo 1 behind and a servo tail show in the layout")
          m.tail_rotor_mode,w.swashRear=tail,rear;m[field]=old
        end
      end
    end
  end
end
-- Additional picture variants use the same card definitions as the normal walk.
for _,size in ipairs({{320,240},{480,272},{800,480}}) do
  local function export(name,task,prepare,card)
    w.rebootPending=nil
    if prepare then prepare() end
    for n,key in ipairs(steps) do if key==name then w.step=n;break end end
    w.cards=load(PATH.."steps/"..name..".lua")(w);w.card=card or 1
    local job=view.new(w,{w=size[1],h=size[2]},diagrams)
    while not job.done do job:step() end
    exported[#exported+1]={step=w.step,name=name,task=task,width=size[1],height=size[2],children=resolve(job.children)}
  end
  for _,value in ipairs({1000,1900}) do
    export("modes",value==1000 and "off" or "on",function()
      w.data.mode_ranges.mode_ranges[1]={id=0,auxChannelIndex=0,range={start=1800,["end"]=2100}}
      w.data.rc={channels={1500,1500,1500,1500,1500,value}}
    end)
  end
  export("connect","restart",function() w.rebootPending=true end)
  local features=w.data.feature_config.enabledFeatures
  export("governor","throttle-type",function()
    w.data.feature_config.enabledFeatures=features | (1<<26)
  end,2)
  w.data.feature_config.enabledFeatures=features
  local protocol=w.data.motor_config.motor_pwm_protocol
  for card=1,3 do
    export("throttle","pwm-"..card,function() w.data.motor_config.motor_pwm_protocol=0 end,card)
  end
  w.data.motor_config.motor_pwm_protocol=protocol
  export("throttle","non-pwm",function() w.data.motor_config.motor_pwm_protocol=5 end)
  w.data.motor_config.motor_pwm_protocol=protocol
  local ranges=w.data.adjustment_ranges.adjustment_ranges
  local pid,rate=ranges[1],ranges[2]
  for card=1,3 do
    export("rates","profile-"..card,function()
      ranges[1]=H.mapped(2,1,1000,2000,1,3);ranges[2]=H.mapped(1,1,1000,2000,1,3)
      w.rateStyles={[0]=1,[1]=2,[2]=3}
    end,card)
  end
  ranges[1],ranges[2]=pid,rate;w.rateStyles={}
  local telemetry=w.data.esc_sensor_config.protocol
  export("escTelemetry","castle",function() w.data.motor_config.motor_pwm_protocol=9 end)
  w.data.motor_config.motor_pwm_protocol=protocol
  export("escTelemetry","off",function() w.data.esc_sensor_config.protocol=0 end)
  w.data.esc_sensor_config.protocol=telemetry
  for _,mode in ipairs({1,2}) do
    export("tail",mode==2 and "bidirectional" or "motor",function() w.data.mixer_config.tail_rotor_mode=mode end)
  end
  w.data.mixer_config.tail_rotor_mode=0
  for _,preset in ipairs({{50,1520},{333,1520},{560,760},{200,1520}}) do
    export("servoType","pulse-"..preset[1].."-"..preset[2],function()
      for _,servo in pairs(w.data.servo_configurations.servos) do
        servo.rate,servo.mid,servo.max=preset[1],preset[2],preset[2]==760 and 250 or 700
      end
    end)
  end
end
-- Multi-frame previews prove that parameter/live bindings update one scene.
for _,size in ipairs({{320,240},{480,272},{800,480}}) do
  local samples={
    {name="direction",card=1,group="command",values={-500,0,500,0},apply=function(value)
      w.data.rc_command={commands={value,0,0,0,0}}
    end},
    {name="modes",card=1,group="switch",values={1000,1900,1000},apply=function(value)
      w.data.mode_ranges.mode_ranges[1]={id=0,auxChannelIndex=0,range={start=1800,["end"]=2100}}
      w.data.rc={channels={1500,1500,1500,1500,1500,value}}
    end},
    {name="sensors",card=4,group="attitude-roll",values={0,30,0,-30,0},apply=function(value)
      w.data.attitude={roll=value,pitch=0,yaw=0};w.attitudeAt=getTime()
      w.attitudeView:update(w.data.attitude,w.attitudeAt,getTime(),true)
    end},
    {name="sensors",card=4,group="attitude-pitch",values={0,30,0,-30,0},apply=function(value)
      w.data.attitude={roll=0,pitch=value,yaw=0};w.attitudeAt=getTime()
      w.attitudeView:update(w.data.attitude,w.attitudeAt,getTime(),true)
    end},
    {name="rates",card=1,group="rates",values={1,2,3},apply=function(value) w.rateStyles[w.rateProfiles[1]]=value end},
    {name="servoType",card=1,group="pulses",values={50,333,560},apply=function(value)
      for _,index in ipairs(w.cards[1].servoIndices) do
        local servo=w.data.servo_configurations.servos[index]
        servo.rate,servo.mid,servo.max=value,value==560 and 760 or 1520,value==560 and 250 or 700
      end
      if w.refreshPulse then w.refreshPulse() end
    end},
    {name="swash",card=1,group="geometry",values={2,5,6},apply=function(value) w.data.mixer_config.swash_type=value end}
  }
  for _,sample in ipairs(samples) do
    for n,name in ipairs(steps) do if sample.name==name then w.step=n;break end end
    w.cards=load(PATH.."steps/"..sample.name..".lua")(w);w.card=sample.card
    local job=view.new(w,{w=size[1],h=size[2]},diagrams)
    while not job.done do job:step() end
    local count=#job.children
    for n,value in ipairs(sample.values) do
      sample.apply(value)
      exported[#exported+1]={step=w.step,name=sample.name,width=size[1],height=size[2],
        motion=sample.group,frame=n,input=value,children=resolve(job.children)}
      eq(#job.children,count,"motion preview retains scene objects")
    end
  end
end
eq(#steps,19,"exact step count")
-- ARM is learned from AUX1 only. ExpressLRS 4.x also outputs the arm flag on CH14 (AUX9),
-- which moves with the arm switch; Rescue/Trainer keep the free search.
do
  local m=world()
  local function listen(id,moves)
    m.data.boxids.box_ids={0,53,47}
    local slots={};for i=1,20 do slots[i]={id=0,auxChannelIndex=0,range={start=900,["end"]=900}} end
    m.data.mode_ranges.mode_ranges=slots;m.data.mode_ranges_extra.mode_ranges_extra={}
    for n,name in ipairs(steps) do if name=="modes" then m.step=n end end
    load(PATH.."steps/modes.lua")(m)
    local base={};for i=1,14 do base[i]=i<=5 and 1500 or 1000 end
    m.modeListen.id,m.modeListen.base,m.modeListen.untilAt=id,base,ticks+1500
    m.modeListen.aux,m.modeListen.value,m.modeListen.at=nil,nil,nil
    local now={};for i=1,14 do now[i]=moves[i] or base[i] end
    m.onLive("rc",{channels=now});ticks=ticks+50;m.onLive("rc",{channels=now})
    for _,r in ipairs(m.data.mode_ranges.mode_ranges) do
      if r.id==id and r.range.start<r.range["end"] then return r end
    end
  end
  local r=listen(0,{[6]=1900,[14]=1900})
  eq(r and r.auxChannelIndex,0,"ARM with a mirrored CH14 lands on AUX1")
  eq(listen(0,{[7]=1900}),nil,"ARM ignores a switch on another AUX")
  r=listen(53,{[7]=1900})
  eq(r and r.auxChannelIndex,1,"Rescue still found on any AUX")
end
-- Live replies update cached values, never the scene.
w.step,w.error,w.transition,w.rebuilds = 14,nil,nil,0
w.data.rc_command = {commands={0,0,0,0,0}}
for _=1,300 do w:tick();pump();ticks=ticks+2 end
eq(w.rebuilds,0,"live replies do not rebuild")
-- Release queued/in-flight hold writes as well as the locally held state.
w.holds = {}; w:hold("servo",0,400); w:hold("mixer",1,2502)
w.bus:add({api="servo_override",write=true,override=true,data={servo_id=0,action=400,timeout=3000}})
local firstRelease=#q.sent+1
w:release()
for _=1,20 do measure("cleanup reply",pump) end
check(next(w.holds)==nil,"leaving releases held state")
for _,j in ipairs(w.bus.jobs) do check(not j.override,"leaving drops unsent override job") end
local releases = {};for i=firstRelease,#q.sent do local m=q.sent[i];releases[m.command] = true end
check(releases[193] and releases[191],"servo and mixer OFF acknowledged on leave")
-- An API version of 12.10 without #541 must use persistent three-byte writes.
legacy=true
local old=world();check(not old.timed,"12.10 without timeouts is detected")
old:hold("servo",0,400)
for _=1,20 do old:tick();pump();ticks=ticks+1 end
for _,m in ipairs(q.sent) do if m.command==193 and m.payload[2]==144 then eq(#m.payload,3,"legacy hold has no timeout") end end
legacy=false
local sent=#q.sent;armed=true
for _=1,20 do old:tick();pump();ticks=ticks+1 end
eq(#q.sent,sent,"armed dispatch stops")
check(old.motorHold==nil and next(old.holds)==nil,"armed transition clears desired holds")
armed=false
-- A write error must not save or advance the wizard.
w=world();w.step=9;w.data.motor_config.motor_pole_count_0=14;w:touch("motor_config");failCommand=222
w:save(function() w.advanced=true end)
for _=1,500 do w:tick();pump();ticks=ticks+1;if w.error then break end end
check(w.error and not w.advanced,"failed write blocks advance")
local eeprom=false;for _,m in ipairs(q.sent) do if m.command==250 then eeprom=true end end
check(not eeprom,"failed write never reaches EEPROM")
failCommand=nil
-- Whole-table work is generated one record per pass, with EEPROM last.
w=world()
q.sent = {}
-- Every row differs, so every row is sent; unchanged rows are skipped (contracts).
for _,r in ipairs(w.data.adjustment_ranges.adjustment_ranges) do r.adjStep=(r.adjStep or 0)+1 end
for _,r in ipairs(w.data.mode_ranges.mode_ranges) do r.auxChannelIndex=(r.auxChannelIndex or 0)+1 end
for _,name in ipairs({"mode_ranges","adjustment_ranges","servo_configurations","mixer_input","serial_config"}) do w:touch(name) end
measure("save callback",function() w:save(function() w.completedSave=true end) end)
for _=1,1800 do
  measure("bulk save",function() w:tick() end);pump();ticks=ticks+1
  if w.completedSave or w.error then break end
end
check(w.completedSave and not w.error,"full-table save completes")
local lastWrite
for _,m in ipairs(q.sent) do if m.isWrite then lastWrite=m.command end end
eq(lastWrite,250,"EEPROM follows every indexed write")
local count=0;for _,m in ipairs(q.sent) do if m.command==53 then count=count+1 end end
eq(count,42,"all adjustment slots written exactly once")
-- Per-profile read/write order and restoration.
w=world();q.sent={}
w:profileLoop("rates",3,function(d,i) H.style(d,i+1) end)
for _=1,500 do w:tick();pump();ticks=ticks+1;if w.bus:idle() then break end end
local selected={};local tunes=0
for _,m in ipairs(q.sent) do
  if m.command==210 then selected[#selected+1]=m.payload[1] end
  if m.command==204 then tunes=tunes+1 end
end
eq(table.concat(selected,","),"128,129,130,130","original rate profile restored")
eq(tunes,3,"three rate profiles written")
-- Maximum packed servo table, including bus channels, is still bounded.
local full={26};local fixture=api("servo_configurations").simulatorResponse
for _=1,26 do for i=2,17 do full[#full+1]=fixture[i] end end
local packed
measure("servo decode",function() packed=api("servo_configurations").parse(full) end)
eq(packed.servo_count,26,"maximum servo table parsed")
w.data.servo_configurations=packed;w.data.status.servo_count=22
w.data.serial_config.port_1_function_mask=524288
eq(#w:servos(),4,"bus channels excluded from wizard PWM servos")
w.data.mixer_config.swash_type=5
eq(#w:servos(),3,"90L has two cyclic servos and a tail")
w.data.mixer_config.tail_rotor_mode=1
eq(#w:servos(),2,"motor tail excludes servo 4")
local motorCards=load(PATH.."steps/tail.lua")(w)
eq(#motorCards,2,"motor tail variant stays within Tail step")
-- Actual page bootstrap and scene slices, including every reactive callback.
local historyFiles=assert(loadfile("bin/wizard/history_fixture.lua"))()()
historyFiles:install()
local originalSources={getValue=getValue,getFieldInfo=getFieldInfo,getSourceValue=getSourceValue,model=model}
function getValue() return 8 end
function getFieldInfo(name) if name=="STAT" or name=="SCFG" or name=="RxBt" then return {id=1} end end
function getSourceValue(name) return 8,name=="telem99" or name=="STAT" or name=="SCFG" end
model={getSensor=function(index) if index<99 then return {name="STAT"} end end}

local page=load(PATH.."page.lua")
local ctx={children={},x=0,y=0,w=480,h=272,requestRebuild=function() end,requestClose=function() end}
page.build(ctx)
for _=1,500 do
  measure("page wakeup",function() page.wakeup(ctx) end);pump();ticks=ticks+1
  ctx.children={};measure("page build",function() page.build(ctx) end)
  measure("page sweep",function() resolve(ctx.children) end)
end
page.onClose()
check(_G.rfsuite.session.helicopterSetupRecovery=="test-board","external teardown retains a recovery requirement")
_G.rfsuite.session.helicopterSetupRecovery=nil
-- Walk the actual page through its rendered callbacks. Construction and every
-- reactive getter share this measured frame, as they do in the dashboard host.
local frameClosed,frameVisited=false,{}
-- The suite's servo fixture has the tail 120 us off centre; a pilot centres it in step 13.
local centred={};for i,v in ipairs(api("servo_configurations").simulatorResponse) do centred[i]=v end
centred[50],centred[51]=1500 & 255,1500 >> 8
fixtures[120]=centred
local pausedModelChoice=false
local frameCtx={children={},x=0,y=0,w=480,h=272,menu={getCurrentMenuId=function() return "helicopter_setup_page" end},requestRebuild=function() end,
  requestClose=function() frameClosed=true end}
page.build(frameCtx)
for _=1,5000 do
  measure("hosted frame",function()
    page.wakeup(frameCtx)
    frameCtx.children={};page.build(frameCtx);resolve(frameCtx.children)
  end)
  pump();ticks=ticks+5
  if frameClosed then break end
  for _,item in ipairs(frameCtx.children) do
    local active=type(item.active)~="function" or item.active()
    if (item.type=="label" or item.type=="button") and type(item.text)=="string" then
      local number=string.match(item.text,"^(%d+)/19")
      if number then frameVisited[tonumber(number)]=true end
    end
    if active and item.type=="choice" and item.set and
      (item.title==L.modelChecked or item.title=="@i18n(app.modules.helicopter_setup.modelChecked)@") and
      not pausedModelChoice then
      ticks=ticks+400;pausedModelChoice=true
    end
    local answer=item.type=="button" and type(item.text)=="function" and item.text()
    if active and (answer==L.no or answer=="@i18n(app.modules.helicopter_setup.no)@") then
      if not pausedModelChoice then ticks=ticks+400;pausedModelChoice=true end
      measure("page input",item.press)
    end
    if active and item.type=="button" and item.press then
      local caption=type(item.text)=="function" and item.text() or item.text
      local key=type(caption)=="string" and string.match(caption,"^@i18n%(app%.modules%.helicopter_setup%.([%w_]+)%)@$")
      local shown=type(item.visible)~="function" or item.visible()
      if shown and (key=="servoTestUp" or key=="answerUp" or caption==L.servoTestUp or caption==L.answerUp) then
        measure("page input",item.press)
      end
      if key=="continue" or key=="saveNext" or key=="finish" or key=="completeSetup" or
        caption==L.continue or caption==L.saveNext or caption==L.finish or caption==L.completeSetup then
        measure("page input",item.press)
      end
    end
  end
  -- Input/continuations can invalidate the model before EdgeTX releases the old
  -- native tree. Sweep it before allowing the next page build to replace it.
  measure("retained page sweep",function() resolve(frameCtx.children) end)
end
fixtures[120]=nil
check(pausedModelChoice,"actual page includes a four-second input pause")
check(frameClosed,"actual rendered page completes the whole wizard")
local frameCount=0;for _ in pairs(frameVisited) do frameCount=frameCount+1 end
eq(frameCount,19,"actual page callbacks visit all nineteen steps")
page.onClose()
local storedHistory=load(PATH.."history_store.lua").new("test-board")
storedHistory:load()
eq(storedHistory.mask,(1<<19)-1,"actual complete run persists every validated step")
historyFiles:restore()
getValue,getFieldInfo,getSourceValue,model=originalSources.getValue,originalSources.getFieldInfo,originalSources.getSourceValue,originalSources.model

-- Follow all 19 steps with explicit positive physical answers. No simulator or
-- radio events are synthesized; these are calls into the actual page controller.
w=world();q.sent={};w.requestClose=function() w.closed=true end
w.checks=setmetatable({},{__index=function() return true end})
w.data.mode_ranges.mode_ranges[1]={id=0,auxChannelIndex=0,range={start=1800,["end"]=2100}}
local visited={}
for _=1,3000 do
  w:tick();pump();ticks=ticks+5
  if w.ready and w.cards and not w.transition and not w.error then
    if w.step==13 then for _,s in pairs(w.data.servo_configurations.servos) do s.mid=s.mid>860 and 1520 or 760 end end
    visited[w.step]=true;w:next()
  end
  if w.closed or w.error then break end
end
check(w.closed and not w.error,"complete 19-step walk exits")
local visitedCount=0;for _ in pairs(visited) do visitedCount=visitedCount+1 end
eq(visitedCount,19,"all nineteen steps visited in order")
eq(q.sent[#q.sent].command,99,"exit finishes with arming command")
eq(q.sent[#q.sent].payload[1],0,"arming availability restored only on exit")
-- ACK alone is insufficient: disappearance of the status flag blocks edits.
w=world();w.holds={};w:hold("mixer",1,0)
local unlocked=api("status").parse(status());unlocked.arming_disable_flags=0
w:acceptStatus(unlocked)
check(w.error and not w.locked and next(w.holds)==nil,"arming-lock readback failure stops bench work")
w=world();w.checks.gyro1=true;w.step=17;w:navigate(18,1)
check(w.checks.gyro1==nil,"returning to a physical check requires a fresh answer")
local originalId=_G.rfsuite.session.mcu_id
_G.rfsuite.session.mcu_id="different-board"
check(not w:allowed(),"a different board cannot inherit a visit")
_G.rfsuite.session.mcu_id=originalId
w.requestClose=function() w.closed=true end
_G.rfsuite.session.fblConnected=false
local queuedBefore=#q.messages
w:back()
check(not w.closed and w.active and w.disconnectExit,"link loss explains physical cleanup before EXIT")
eq(#q.messages,queuedBefore,"disconnected exit sends no unguarded MSP")
w:leaveDisconnected()
check(w.closed and not w.active,"confirmed physical power-off permits EXIT after link loss")
_G.rfsuite.session.fblConnected=true
local mutation
for i=1,#arg do if arg[i]=="--mutation" then mutation=arg[i+1] end end
local function contractWorld()
  local v=world()
  -- Negative controls inject the former defect only into contract fixtures.
  if mutation=="rx-ids" then
    local original=v.receiverProtocols
    v.receiverProtocols=function(self)
      local entries=original(self)
      for _,e in ipairs(entries) do if e[2]=="FBUS" then e[1]=16 end end
      return entries
    end
  elseif mutation=="mode-flag" then v.modeActive=function() return true end
  elseif mutation and mutation~="bulk-read" and mutation~="history-early" and mutation~="stale-status" and mutation~="retry-stale"
    and mutation~="pitch-discard" and mutation~="back-commit" and mutation~="stale-blades"
    and mutation~="shared-timeout-probe" and mutation~="cleanup-unlock" and mutation~="drop-stale-edit" then error("Unknown negative control: "..mutation) end
  return v
end
local contractCases=assert(loadfile("bin/wizard/contracts.lua"))()({
  world=contractWorld,load=load,H=H,L=L,q=q,check=check,eq=eq,pump=pump,measure=measure,api=api,stepNames=steps,
  fixtures=fixtures,advance=function(value) ticks=ticks+value end,
  beginWorld=beginWorld,mutation=mutation,
  setServoCount=function(count) statusServoCount=count end,
  setLegacyMixer=function(value) legacyMixer=value end,
  setFailCommand=function(value) failCommand=value end,
  setRecordFault=function(value) recordFault=value end,
  view=view,diagrams=diagrams,resolve=resolve
})
print("Source contracts: "..#contractCases.." scenario groups")
for name,count in pairs(worst) do print(string.format("BUDGET %-12s %d / 14000",name,count)) end
if arg[1]=="--export" then
  local function json(v)
    if type(v)=="string" then return '"'..string.gsub(string.gsub(string.gsub(v,'\\','\\\\'),'"','\\"'),'\n','\\n')..'"' end
    if type(v)=="number" or type(v)=="boolean" then return tostring(v) end
    if type(v)~="table" then return "null" end
    local parts={};local array=#v>0
    for k,x in pairs(v) do parts[#parts+1]=(array and "" or json(tostring(k))..":")..json(x) end
    return (array and "[" or "{")..table.concat(parts,",")..(array and "]" or "}")
  end
  local file=assert(io.open(arg[2],"w"));file:write(json(exported));file:close()
end
-- The radio fonts have no em dash or ellipsis glyph: such a character draws as a gap.
for _,locale in ipairs({"en","de"}) do
  local file=assert(io.open("src/rfsuite/i18n/"..locale..".lua","rb"));local text=file:read("a");file:close()
  local first,_,indent=string.find(text,"\n([ ]*)helicopter_setup = {")
  local last=first and string.find(text,"\n"..(indent or "").."}",first+1,true)
  local block=last and string.sub(text,first,last) or ""
  check(#block>1000,"I18N "..locale.." wizard strings found")
  check(not string.find(block,"\226\128\148",1,true) and not string.find(block,"\226\128\166",1,true),
    "I18N "..locale.." wizard strings use glyphs the radio fonts have")
end
print(string.format("Wizard: %d assertions, %d failures",assertions,failures))
if failures>0 then os.exit(1) end
