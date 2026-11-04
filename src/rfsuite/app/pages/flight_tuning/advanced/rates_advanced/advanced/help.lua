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
  local t = Common and Common.pageT("flight_tuning_rates_advanced_advanced") or function(_, k) return k end
  local i18n = ctx and ctx.i18n

  local parts = {
    t(i18n, "help_p1"),
    t(i18n, "help_p2"),
    t(i18n, "help_p3"),
    t(i18n, "help_p4"),
    t(i18n, "help_ceiling"),
    t(i18n, "help_deadband"),
    t(i18n, "help_deadband_filter")
  }

  return {
    title = t(i18n, "help_title"),
    message = table.concat(parts, "\n")
  }
end
