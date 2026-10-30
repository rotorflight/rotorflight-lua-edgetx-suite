-- Lazy, visit-local dependencies: opening from a widget never loads the wizard in one call.
local M = { hideSuiteFrame = true, handlesDisconnect = true }
local BASE = "/SCRIPTS/TOOLS/rfsuite-core/"
local PATH = "app/pages/helicopter_setup/"
local modules, stage, w, context, viewJob, scene, sceneInputs, pendingInputs = {}, 1
local deps = { "tasks/msp/runtime.lua", PATH .. "transport.lua", PATH .. "math.lua", PATH .. "labels.lua",
  PATH .. "controller.lua", PATH .. "forms.lua", PATH .. "workflow.lua", PATH .. "view.lua", "lib/armed.lua", PATH .. "diagrams.lua", PATH .. "navigation.lua",
  "lib/system_state.lua", "lib/sensors.lua", PATH .. "feedback.lua", PATH .. "history_store.lua", PATH .. "history.lua", PATH .. "attitude_view.lua",
  PATH .. "servo_grid.lua", "lib/port_labels.lua", PATH .. "palette.lua",
  "lib/esc_params.lua", "lib/esc_status.lua", PATH .. "esc_link.lua",
  "lib/power_fields.lua", "lib/api_version.lua" }
-- The dashboard and the tool already hold the sensor library through the shared module loader.
-- Taking that instance avoids a second copy of its source caches; the wizard never resets it.
local SHARED = { ["lib/sensors.lua"] = true }
local function loadDependency(index)
  local path = deps[index]
  local requireShared = SHARED[path] and _G.rfsuite and _G.rfsuite.require
  local shared = requireShared and requireShared(path)
  if type(shared) == "table" then return shared end
  return assert(loadScript(BASE .. path, "t"))()
end
-- Helpers only one step uses are loaded when that step first asks for them and dropped once the
-- visit has left it. The ESC helpers stay while an ESC parameter session still refers to them.
local STEP_HELPERS = { [17] = 1, [18] = 13, [19] = 11, [21] = 11, [22] = 11 }
local ESC_HELPERS = { [21] = true, [22] = true }
local function helper(index)
  local module = modules[index]
  if not module then
    module = loadDependency(index); modules[index] = module
    if w and w.logDebug then w:log("debug", "helper %s loaded", deps[index]) end
  end
  return module
end
local function lazyHelper(index)
  return setmetatable({}, { __index = function(_, key) return helper(index)[key] end })
end
local function releaseHelpers()
  for index, step in pairs(STEP_HELPERS) do
    if modules[index] and (w.overview or w.step ~= step) and (not ESC_HELPERS[index] or not w.escParams) then
      modules[index] = nil
      if w.logDebug then w:log("debug", "helper %s released", deps[index]) end
    end
  end
end
-- The history page reads and resets the completion record only; it never shows a setup step.
local HISTORY_SKIPS = { [3] = true, [7] = true, [10] = true, [12] = true, [13] = true, [23] = true, [24] = true, [25] = true }
local historyEntry
local function needed(index)
  if STEP_HELPERS[index] then return false end
  if historyEntry == nil then
    local menu = context.menu
    historyEntry = menu ~= nil and type(menu.getCurrentMenuId) == "function"
      and menu.getCurrentMenuId() == "helicopter_setup_history_page"
  end
  return not (historyEntry and HISTORY_SKIPS[index])
end
local palette
-- The tool's text colour role, read once here so the first build stays minimal.
local toolText = _G.rfsuite and _G.rfsuite.palette and _G.rfsuite.palette.text or COLOR_THEME_PRIMARY1
local loadingPoints = {{24,0},{24,0}}
local loadingFraction = 0
local keys = { "sensors", "receiver", "modes", "profiles", "rates", "swash", "servoType", "governor", "motor",
  "connect", "escTelemetry", "throttle", "servos", "direction", "level", "pitch", "tail", "gyro", "finish" }
-- What a scene is built from. A published scene stays current while every input still holds the
-- value it was built with; comparing them leaves a steady frame without a new string to collect.
local SCENE_FIELDS = { "step", "card", "cards", "confirmExit", "disconnectExit", "overview", "historyFailure", "error" }
local SCENE_W, SCENE_H = #SCENE_FIELDS + 1, #SCENE_FIELDS + 2
local function captureInputs(into)
  for i, name in ipairs(SCENE_FIELDS) do into[i] = w[name] end
  into[SCENE_W], into[SCENE_H] = context.w, context.h
  return into
end
local function sceneCurrent(inputs)
  if not w or not inputs then return false end
  for i, name in ipairs(SCENE_FIELDS) do
    if inputs[i] ~= w[name] then return false end
  end
  return inputs[SCENE_W] == context.w and inputs[SCENE_H] == context.h
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
  if scene and sceneCurrent(sceneInputs) then
    table.move(scene, 1, #scene, #ctx.children+1, ctx.children)
  elseif loadingScene then
    table.move(loadingScene,1,#loadingScene,#ctx.children+1,ctx.children)
  else
    -- The first build stays minimal; the palette is loaded by the first wakeup.
    ctx.children[#ctx.children+1] = { type="label",x=12,y=30,w=ctx.w-24,
      text="@i18n(app.modules.helicopter_setup.loading)@",color=toolText,font=SMLSIZE }
  end
end
function M.wakeup(ctx)
  if not context then return end
  if ctx and ctx.requestRebuild then context.requestRebuild = ctx.requestRebuild end
  loadingFraction = w and (w.ready and 1 or 0.2+0.8*(w.progress or 0)/math.max(1,w.loadTotal or 1)) or 0.2*(stage-1)/#deps
  loadingPoints[2][1]=24+math.floor((context.w-48)*math.min(1,loadingFraction))
  if not palette then palette = assert(loadScript(BASE .. deps[20], "t"))() end
  modules[20] = modules[20] or palette
  if not loadingScene then
    loadingScene=buildLoading(context);context.requestRebuild();return
  end
  while deps[stage] and not needed(stage) do stage = stage + 1 end
  if deps[stage] then
    modules[stage] = modules[stage] or loadDependency(stage); stage = stage + 1; return
  end
  if not w then
    w = modules[5].new(modules[1], modules[2], modules[3], modules[4])
    w.palette = palette
    w.i18n = context.i18n
    w.powerFields, w.powerApiVersion = modules[24], modules[25]
    w.newAttitudeView = function(...) return helper(17).new(...) end
    w.newServoCard = function(...) return helper(18).append(...) end
    -- Some choice cards use the full width on wide screens.
    w.wideScreen = context.w ~= nil and context.w >= 700
    modules[6].attach(w, lazyHelper(19)); if modules[7] then modules[7].attach(w) end; modules[11].attach(w, context)
    modules[14].attach(w, modules[12], modules[13])
    modules[16].attach(w, modules[15])
    if modules[23] then modules[23].attach(w, lazyHelper(21), lazyHelper(22)) end
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
  releaseHelpers()
  if viewJob then
    w:tick()
    w.canEdit=w:usable()
    if viewJob:step() then
      scene, viewJob = viewJob.children, nil
      sceneInputs, pendingInputs = pendingInputs, sceneInputs
      -- The replaced scene's inputs must not keep its cards reachable until the next build.
      if pendingInputs then for i = 1, SCENE_H do pendingInputs[i] = nil end end
      w:rebuild()
    end
    return
  end
  if ((w.ready and (w.cards or w.overview)) or w.error or w.confirmExit or w.historyFailure or w.disconnectExit)
    and not sceneCurrent(sceneInputs) then
    viewJob = modules[8].new(w, context, modules[10]); pendingInputs = captureInputs(pendingInputs or {}); return
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
  modules, stage, w, context, viewJob, scene, sceneInputs, pendingInputs = {}, 1, nil, nil, nil, nil, nil, nil
  loadingScene,loadingFraction,loadingPoints[2][1],historyEntry=nil,0,24,nil
end
function M.getHeaderActions() return { save = false, reload = false, help = false } end
return M
