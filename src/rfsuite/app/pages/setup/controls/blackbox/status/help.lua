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

  local help_p1 = t(i18n, "help_status_p1", "Monitor storage media state and space usage.")
  local help_p2 = t(i18n, "help_status_p2", "Press * to erase onboard dataflash logs. Asks first; lit only when the board has a dataflash.")

  return {
    title = t(i18n, "help_status_title", "Blackbox Status Help"),
    message = help_p1 .. "\n\n" .. help_p2
  }
end
