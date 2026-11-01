-- @Kevd, postflight: the tiles are declared in layout.lua, which holds all three phases.
local function loadLayout()
  if type(_G) == "table" and type(_G.__rfsuiteThemeKevdLayoutModule) == "table" then
    return _G.__rfsuiteThemeKevdLayoutModule
  end
  if _G.rfsuite and type(_G.rfsuite.require) == "function" then
    local mod = _G.rfsuite.require("widgets/dashboard/themes/@kevd/layout.lua")
    if type(mod) == "table" then return mod end
  end
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/widgets/dashboard/themes/@kevd/layout.lua", mode)
  if not chunk then return nil end
  local ok, mod = pcall(chunk)
  if ok and type(mod) == "table" then return mod end
  return nil
end

local Layout = loadLayout()
return Layout and Layout.phase("postflight") or {}
