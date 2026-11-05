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

  local help_intro = t(i18n, "help_intro_telemetry", "How the flight controller reads the ESC's telemetry wire; each setting has its own help.")
  local help_detect = t(i18n, "help_detect_wiring",
    "Detect wiring: While disarmed, try each Half Duplex and Pin Swap combination for the saved protocol. Save a result to store it.")
  local help_cancel = t(i18n, "help_detect_cancel", "Cancel: Stop detection and restore the previous live wiring. Reload before saving.")

  return {
    title = t(i18n, "help_title_telemetry", "Telemetry Help"),
    message = table.concat({ help_intro, help_detect, help_cancel }, "\n")
  }
end
