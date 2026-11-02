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
  local t = Common and Common.pageT("setup_stats") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local help_p1 = t(i18n, "help_p1", "Use this module to update the recorded flight statistics on the flight controller.")

  return {
    title = t(i18n, "help_title", "Stats Help"),
    message = help_p1
  }
end
