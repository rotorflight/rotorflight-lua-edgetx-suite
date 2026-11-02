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

  local message = t(i18n, "help_tail", "Tail rotor type, direction, centre trim, gain and limits. On a variable-pitch tail, * holds the yaw input at centre so the trim can be set while watching the tail.")

  return {
    title = t(i18n, "tail", "Tail Setup"),
    message = message
  }
end
