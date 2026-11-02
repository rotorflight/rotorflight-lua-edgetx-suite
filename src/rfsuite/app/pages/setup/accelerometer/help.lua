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
  local t = Common and Common.pageT("setup_accelerometer") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local help_p1 = t(i18n, "help_p1",
    "The trims correct drift in Angle, Horizon and Rescue; Save writes them to EEPROM; * calibrates after disarming with the model held level and still until the notice.")

  return {
    title = t(i18n, "help_title", "Accelerometer Help"),
    message = help_p1
  }
end
