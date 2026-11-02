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
  local t = Common and Common.pageT("setup_blackbox") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local help_p1 = t(i18n, "help_logging_p1", "Select which fields are logged to the Blackbox.")
  local help_p2 = t(i18n, "help_logging_p2", "Logging fields can only be selected when a logging device and mode are enabled.")

  return {
    title = t(i18n, "help_logging_title", "Blackbox Logging Help"),
    message = help_p1 .. "\n\n" .. help_p2
  }
end
