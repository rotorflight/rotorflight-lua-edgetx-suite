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
  local t = Common and Common.pageT("setup_governor") or function(_, k) return k end
  local i18n = ctx and ctx.i18n

  return {
    title = t(i18n, "help_time_title"),
    message = t(i18n, "help_time_message")
  }
end
