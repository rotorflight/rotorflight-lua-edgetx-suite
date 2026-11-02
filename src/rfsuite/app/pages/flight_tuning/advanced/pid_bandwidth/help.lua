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
  local t = Common and Common.pageT("flight_tuning_advanced_pid_bandwidth") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local help_p1 = t(i18n, "help_p1", "PID Bandwidth: Sets the overall PID-loop bandwidth in Hz for Roll, Pitch and Yaw.")
  local help_p2 = t(i18n, "help_p2", "D-term cut-off: Sets the D-term cutoff frequency in Hz for Roll, Pitch and Yaw.")
  local help_p3 = t(i18n, "help_p3", "B-term cut-off: Sets the boost cutoff frequency in Hz for Roll, Pitch and Yaw.")

  local parts = { help_p1, help_p2, help_p3 }

  return {
    title = t(i18n, "help_title", "PID Bandwidth Help"),
    message = table.concat(parts, "\n")
  }
end
