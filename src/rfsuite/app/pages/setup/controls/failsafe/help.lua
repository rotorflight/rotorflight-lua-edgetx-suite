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
  local t = Common and Common.pageT("setup_failsafe") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local help_p1 = t(i18n, "help_p1", "How each channel behaves when the RC signal is lost.\nAuto: Roll, Pitch, Yaw and Collective go to center, Throttle to the failsafe throttle; AUX channels hold.\nHold: keeps the channel's last good value.\nSet: uses the value beside it, 875 to 2125 us.")

  return {
    title = t(i18n, "help_title", "Failsafe Help"),
    message = help_p1
  }
end
