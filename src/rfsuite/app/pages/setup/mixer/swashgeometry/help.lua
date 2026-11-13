local function loadModule(path)
  local fullPath = _G.rfsuite.paths.core .. "/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

return function(ctx)
  local Common = loadModule("app/pages/settings/common.lua")
  local t = Common and Common.pageT("setup_mixer") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local message = t(i18n, "help_geometry", "Swashplate gains, pitch limits, phase and tilt correction, where * lets the sticks move the swashplate through the mixer and sends every change live until Save stores it.")

  return {
    message = message
  }
end
