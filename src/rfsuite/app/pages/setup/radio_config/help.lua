local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

return function(ctx)
  local Common = loadModule("app/pages/settings/common.lua")
  local t = Common and Common.pageT("setup_radio_config") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local help_p1 = t(i18n, "help_p1", "These stick and throttle settings are stored on the flight controller; Save restarts it.\nCenter: Channel value for centered roll, pitch and yaw sticks (0%).\nDeflection: Maximum travel from center to full stick input (100%).\nCyclic: Ignores roll and pitch input within the deadband around center.\nYaw: Ignores yaw input within the deadband around center.\nArming: Throttle must be below this value to arm (only below MSP API 12.09).\nMin: Channel value for 0% throttle; throttle must reach at least 10 us below it to arm.\nMax: Channel value for 100% throttle.")

  return {
    title = t(i18n, "help_title", "Radio Config Help"),
    message = help_p1
  }
end
