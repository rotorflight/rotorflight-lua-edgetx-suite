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
  local t = Common and Common.pageT("setup_servos") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local message = t(i18n, "help_pwm", "Centre, travel, speed and direction of one PWM servo output, where * holds the servos so Center can be set live; the other settings are locked meanwhile.")

  return {
    message = message
  }
end
