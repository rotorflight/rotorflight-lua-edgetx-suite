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
  local t = Common and Common.pageT("setup_mixer") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local message = t(i18n, "help_trims", "Swashplate and tail trims for linkages that cannot be adjusted. With * on, the servos are held at centre and every change is sent live; Save stores it.")

  return {
    title = t(i18n, "trims", "Servo Trims"),
    message = message
  }
end
