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
  local t = Common and Common.pageT("setup_esc_motors") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local help_p1 = t(i18n, "help_p1_srxl2",
    "Settings of a Spektrum Smart ESC on the SRXL2 ESC port; saving reboots the flight controller, and each row's ? explains its setting.")

  return {
    title = t(i18n, "help_title_srxl2", "SRXL2 ESC Help"),
    message = help_p1
  }
end
