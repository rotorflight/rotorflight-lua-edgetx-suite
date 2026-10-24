-- Lazy, visit-local dependencies: opening from a widget never loads the wizard in one call.
local M = { hideSuiteFrame = true, handlesDisconnect = true }
local BASE = "/SCRIPTS/TOOLS/rfsuite-core/"
local PATH = "app/pages/helicopter_setup/"
local modules, stage, w, context, viewJob, scene, sceneKey = {}, 1
local deps = { "tasks/msp/runtime.lua", PATH .. "transport.lua", PATH .. "math.lua", PATH .. "labels.lua",
  PATH .. "controller.lua", PATH .. "forms.lua", PATH .. "workflow.lua", PATH .. "view.lua", "lib/armed.lua", PATH .. "diagrams.lua", PATH .. "navigation.lua",
  "lib/system_state.lua", "lib/sensors.lua", PATH .. "feedback.lua", PATH .. "history_store.lua", PATH .. "history.lua", PATH .. "attitude_view.lua",
  PATH .. "servo_grid.lua", "lib/port_labels.lua", PATH .. "palette.lua" }
local palette
local loadingPoints = {{24,0},{24,0}}
local loadingFraction = 0
local keys = { "sensors", "receiver", "modes", "profiles", "rates", "swash", "servoType", "governor", "motor",
  "connect", "throttle", "escTelemetry", "servos", "direction", "level", "pitch", "tail", "gyro", "finish" }
local function key()
  if not w then return "loading" end
  return tostring(w.step) .. ":" .. tostring(w.card) .. ":" .. tostring(w.cards) .. ":" .. tostring(w.confirmExit)
    .. ":" .. tostring(w.disconnectExit) .. ":" .. tostring(w.overview) .. ":" .. tostring(w.historyFailure) .. ":" .. tostring(w.error) .. ":" .. tostring(context.w) .. ":" .. tostring(context.h)
end
local loadingScene
local function buildLoading(ctx)
  local y=math.floor(ctx.h*0.38)
  loadingPoints[1][2],loadingPoints[2][2]=y+68,y+68
  local children={}
  children[#children+1]={type="rectangle",x=0,y=0,w=ctx.w,h=ctx.h,filled=true,color=palette.background}
  children[#children+1]={type="label",x=24,y=y-34,w=ctx.w-48,h=28,text="@i18n(app.modules.helicopter_setup.name)@",font=ctx.w>=700 and MIDSIZE or SMLSIZE,color=palette.text}
  children[#children+1]={type="label",x=24,y=y,w=ctx.w-48,h=28,
      text=function() return w and w.ready and "@i18n(app.modules.helicopter_setup.preparingView)@" or w and w.loadingText or "@i18n(app.modules.helicopter_setup.loading)@" end,font=SMLSIZE,color=palette.text}
  children[#children+1]={type="label",x=24,y=y+30,w=ctx.w-48,h=30,text="@i18n(app.modules.helicopter_setup.loadingHint)@",font=SMLSIZE,color=palette.muted}
  children[#children+1]={type="line",pts={{24,y+68},{ctx.w-24,y+68}},thickness=3,color=palette.border}
  children[#children+1]={type="line",pts=function() return loadingPoints end,thickness=7,color=palette.accent}
  children[#children+1]={type="button",x=12,y=ctx.h-38,w=math.floor(ctx.w*0.25),h=30,text="@i18n(app.modules.helicopter_setup.back)@",color=palette.card,textColor=palette.text,press=function() M.onBack() end}
  return children
end
function M.build(ctx)
  context = ctx
  -- The host's independent ARMED strip stays outside this page's own frame.
  if (ctx.y or 0)>0 then
    local body={type="box",x=ctx.x or 0,y=ctx.y,w=ctx.w,h=ctx.h,children={}}
    ctx.children[#ctx.children+1]=body
    ctx=setmetatable({children=body.children},{__index=ctx})
  end
  if w then w.requestClose, w.requestRebuild, w.openPage = ctx.requestClose, ctx.requestRebuild, ctx.openPage end
  if w then w.openHelp = ctx.openHelp end
  if w and ctx.armed then
    w.canEdit, w.canNext, w.message = false, false, w.L.disconnected
    w:release()
  end
  if scene and sceneKey == key() then
    table.move(scene, 1, #scene, #ctx.children+1, ctx.children)
  elseif loadingScene then
    table.move(loadingScene,1,#loadingScene,#ctx.children+1,ctx.children)
  else
    -- The first build stays minimal; the palette is loaded by the first wakeup.
    ctx.children[#ctx.children+1] = { type="label",x=12,y=30,w=ctx.w-24,
      text="@i18n(app.modules.helicopter_setup.loading)@",color=COLOR_THEME_PRIMARY1,font=SMLSIZE }
  end
end
function M.wakeup(ctx)
  if not context then return end
  if ctx and ctx.requestRebuild then context.requestRebuild = ctx.requestRebuild end
  loadingFraction = w and (w.ready and 1 or 0.2+0.8*(w.progress or 0)/math.max(1,w.loadTotal or 1)) or 0.2*(stage-1)/#deps
  loadingPoints[2][1]=24+math.floor((context.w-48)*math.min(1,loadingFraction))
  if not palette then palette = assert(loadScript(BASE .. deps[#deps], "t"))() end
  modules[#deps] = modules[#deps] or palette
  if not loadingScene then
    loadingScene=buildLoading(context);context.requestRebuild();return
  end
  if deps[stage] then
    modules[stage] = modules[stage] or assert(loadScript(BASE .. deps[stage], "t"))(); stage = stage + 1; return
  end
  if not w then
    w = modules[5].new(modules[1], modules[2], modules[3], modules[4])
    w.palette = palette
    w.i18n = context.i18n
    w.newAttitudeView = modules[17].new
    w.newServoGrid = modules[18].append
    -- Steps lay out for the screen class: the servo step puts the tail beside the swash servos
    -- on a large screen and on a card of its own on a compact one.
    w.wideScreen = context.w ~= nil and context.w >= 700
    modules[6].attach(w, modules[19]); modules[7].attach(w); modules[11].attach(w, context)
    modules[14].attach(w, modules[12], modules[13])
    modules[16].attach(w, modules[15])
    w.requestClose, w.requestRebuild, w.openPage = context.requestClose, context.requestRebuild, context.openPage
    w.menuChanged = function()
      local menu = context.menu
      if menu and menu.setCondition then
        menu.setCondition("helicopterSetupHistory", not (menu.conditions and menu.conditions.helicopterSetupHistory))
      end
    end
    w.armedEpoch = modules[9].changeCount()
    w:load(); return
  end
  if modules[9].changeCount() ~= w.armedEpoch then
    w.armedEpoch = modules[9].changeCount(); w.bus:cancel(); w:release(); w.error = "arming"; w:rebuild(); return
  end
  w.stepKey = keys[w.step]
  if viewJob then
    w:tick()
    w.canEdit=w:usable()
    if viewJob:step() then scene, sceneKey = viewJob.children, viewJob.key; viewJob = nil; w:rebuild() end
    return
  end
  if ((w.ready and (w.cards or w.overview)) or w.error or w.confirmExit or w.historyFailure or w.disconnectExit) and sceneKey ~= key() then
    viewJob = modules[8].new(w, context, modules[10]); viewJob.key = key(); return
  end
  w:tick()
  w:pollSystemState()
  w.canEdit = w:usable()
  w.canNext = w.canEdit and not w.historyMode and not w.historyFailure and w.cards ~= nil and (not w.trial or w.trial.success == true)
end
function M.onBack()
  if w then w:back() elseif context and context.requestClose then context.requestClose() end
  return true
end
function M.onClose()
  if w then
    w.bus:cancel()
    if not w.closing or w.active or w.recoveryRequired then w:release(true) end
    -- Only close() may re-enable arming, after Save/Discard and acknowledged OFFs.
    -- An external teardown has no confirmed rollback; retain the FC's lock.
    if not w.closing and not w.cleanPhysicalExit then
      w:session().helicopterSetupRecovery=w.identity
    end
    w.active = false
  end
  modules, stage, w, context, viewJob, scene, sceneKey = {}, 1, nil, nil, nil, nil, nil
  loadingScene,loadingFraction,loadingPoints[2][1]=nil,0,24
end
function M.getHeaderActions() return { save = false, reload = false, help = false } end
return M
