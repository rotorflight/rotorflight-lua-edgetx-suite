-- Exercise real voltage forms and stores. An optional source root tests an older tree unchanged.
local root = (arg[1] or ".") .. "/src/rfsuite/"
-- The card roots the suite builds its paths from; a source tree older than lib/paths.lua has none.
local function cardPaths()
  local chunk = loadfile(root .. "lib/paths.lua")
  return chunk and chunk() or nil
end
local core = "/SCRIPTS/RFSUITE/core/"
local fields, switches, modelSaved, radioSaved, modelOk, radioOk
local function clone(value)
  local out = {}
  for k, v in pairs(value) do out[k] = type(v) == "table" and clone(v) or v end
  return out
end
local Controls = setmetatable({SECTION_H=30}, {__index=function(_, key)
  if key == "appendNumberField" then
    return function(_, _, _, _, _, config) fields[#fields+1]=config; return 40 end
  end
  if key == "appendRadioSwitch" then
    return function(_, _, _, _, _, get, set) switches[#switches+1]={get=get,set=set}; return 40 end
  end
  if string.sub(key,1,6)=="append" then return function() return 40 end end
end})
_G.loadScript = function(path)
  local rel = string.sub(path,#core+1)
  if rel == "lib/log.lua" then return nil end
  if rel == "ui/controls.lua" then return function() return Controls end end
  if rel == "lib/model_preferences.lua" then return function() return {
    saveByMcuId=function(_,prefs)
      if not modelOk then return false,"io" end
      modelSaved=clone(prefs); return true
    end
  } end end
  return loadfile(root..rel)
end
local checks=0
local function eq(actual, expected, name)
  checks=checks+1
  assert(actual==expected,name..": "..tostring(actual).." expected "..tostring(expected))
end
local function open(theme,scope,prefs,model)
  fields,switches={},{}
  modelOk,radioOk=true,true
  modelSaved,radioSaved=nil,nil
  _G.rfsuite={session={mcu_id="test",modelPreferences=model}}
  _G.rfsuite.paths=cardPaths()
  local lib=assert(loadfile(root.."app/pages/settings/dashboard/lib.lua"))()
  lib.setEditScope(scope)
  local reports={}
  local ctx={theme={path="system/"..theme},preferences=prefs,children={},x=0,y=0,w=800,h=400,
    savePreferences=function()
      if not radioOk then return false,"io" end
      radioSaved=clone(prefs); return true
    end,
    reportSave=function(report) reports[#reports+1]=report end}
  local page=assert(loadfile(root.."widgets/dashboard/themes/"..theme.."/configure.lua"))()(ctx)
  page.build(ctx)
  eq(#fields,2,"two voltage fields")
  return page,ctx,reports,lib
end
for _,theme in ipairs({"default","rfstatus","@rt-rc","@rt-rc-n"}) do
  local prefix="cfg_"..string.gsub("system/"..theme,"[^%w]","_").."_"
  local prefs,model={dashboard={}},{dashboard={overrides=true}}
  local page,ctx,reports=open(theme,"standard",prefs,model)
  if switches[1] then switches[1].set(true) end
  page.onSave(ctx)
  eq(radioSaved.dashboard[prefix.."v_min"],nil,"untouched automatic minimum")
  eq(radioSaved.dashboard[prefix.."v_max"],nil,"untouched automatic maximum")
  eq(reports[1].ok,true,"unchanged form save succeeds")
  if theme=="default" then eq(radioSaved.dashboard[prefix.."link_colors"],true,"other option saved") end

  prefs,model={dashboard={}},{dashboard={overrides=true}}
  page,ctx,reports=open(theme,"model",prefs,model)
  local originalMin=fields[1].get()
  local originalMax=fields[2].get()
  fields[1].set(originalMin+1)
  fields[1].set(originalMin)
  page.onSave(ctx)
  eq(modelSaved.dashboard[prefix.."v_min"],originalMin/10,"explicit numeric default minimum")
  eq(modelSaved.dashboard[prefix.."v_max"],originalMax/10,"explicit numeric default maximum")
  eq(radioSaved.dashboard[prefix.."v_min"],nil,"model edit leaves standard alone")
  fields[1].set(originalMin+1)
  modelOk=false
  page.onSave(ctx)
  eq(reports[#reports].ok==true,false,"failed model save is reported")
  modelOk=true
  page.onSave(ctx)
  eq(modelSaved.dashboard[prefix.."v_min"],(originalMin+1)/10,"retry preserves edited voltage")
  eq(reports[#reports].ok,true,"retry succeeds")

  prefs={dashboard={[prefix.."v_min"]=10,[prefix.."v_max"]=30}}
  model={dashboard={overrides=true}}
  page,ctx=open(theme,"model",prefs,model)
  page.onSave(ctx)
  eq(modelSaved.dashboard[prefix.."v_min"],nil,"inherited minimum stays inherited")
  eq(modelSaved.dashboard[prefix.."v_max"],nil,"inherited maximum stays inherited")
  fields[1].set(101)
  fields[1].set(100)
  page.onSave(ctx)
  eq(modelSaved.dashboard[prefix.."v_min"],nil,"explicit value equal to radio inherits")

  prefs={dashboard={[prefix.."v_min"]=10,[prefix.."v_max"]=30}}
  model={dashboard={overrides=true,[prefix.."v_min"]=12,[prefix.."v_max"]=24}}
  page,ctx=open(theme,"standard",prefs,model)
  page.onSave(ctx)
  eq(radioSaved.dashboard[prefix.."v_min"],10,"existing standard minimum survives")
  eq(modelSaved.dashboard[prefix.."v_min"],12,"existing model minimum survives standard save")
  page,ctx=open(theme,"model",prefs,model)
  page.onSave(ctx)
  eq(modelSaved.dashboard[prefix.."v_max"],24,"existing model range survives")
  fields[1].set(121)
  page.onReload(ctx)
  page.onSave(ctx)
  eq(modelSaved.dashboard[prefix.."v_min"],12,"reload discards unsaved edit")
  print("PASS "..theme)
end
print(string.format("%d voltage save assertions, 0 failures",checks))
