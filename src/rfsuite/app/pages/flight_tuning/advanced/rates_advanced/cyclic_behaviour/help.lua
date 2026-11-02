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
  local t = Common and Common.pageT("flight_tuning_rates_advanced_cyclic_behaviour") or function(_, k) return k end
  local i18n = ctx.i18n

  return {
    title = t(i18n, "help_title"),
    message = t(i18n, "help_intro")
  }
end
