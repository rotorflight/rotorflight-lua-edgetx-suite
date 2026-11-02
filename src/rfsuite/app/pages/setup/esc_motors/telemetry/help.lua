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

  local help_p1 = t(i18n, "help_p1_telemetry", "Telemetry Protocol: Select the protocol used by the ESC telemetry wire.")
  local help_half_duplex = t(i18n, "help_half_duplex", "Half Duplex: Share the telemetry line with the output.")
  local help_pin_swap = t(i18n, "help_pin_swap", "Pin Swap: Swap the port pins.")
  local help_voltage = t(i18n, "help_voltage_correction", "Voltage Correction: Scales the voltage reading.")
  local help_current = t(i18n, "help_current_correction", "Current Correction: Scales the current reading.")
  local help_consumption = t(i18n, "help_consumption_correction", "Consumption Correction: Scales the consumption reading.")
  local help_detect = t(i18n, "help_detect_wiring",
    "Detect wiring: While disarmed, try each Half Duplex and Pin Swap combination for the saved protocol. Save a result to store it.")
  local help_cancel = t(i18n, "help_detect_cancel", "Cancel: Stop detection and restore the previous live wiring. Reload before saving.")

  return {
    title = t(i18n, "help_title_telemetry", "Telemetry Help"),
    message = table.concat({ help_p1, help_half_duplex, help_pin_swap, help_voltage, help_current,
      help_consumption, help_detect, help_cancel }, "\n")
  }
end
