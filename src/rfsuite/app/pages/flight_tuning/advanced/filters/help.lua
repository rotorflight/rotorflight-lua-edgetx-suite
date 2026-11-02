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
  local t = Common and Common.pageT("flight_tuning_advanced_filters") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local help_p1 = t(i18n, "help_p1", "Filters remove vibration noise from the gyro signal.")
  local help_p2 = t(i18n, "help_p2", "Lowpass 1: Selects no filter, first-order or second-order filtering and sets the first gyro lowpass cutoff in Hz.")
  local help_p4 = t(i18n, "help_p4", "Lowpass 1 dyn.: Sets the minimum and maximum cutoff in Hz as the first lowpass follows main rotor RPM.")
  local help_lpf2 = t(i18n, "help_lpf2", "Lowpass 2: Selects no filter, first-order or second-order filtering and sets the second gyro lowpass cutoff in Hz.")
  local help_notch1 = t(i18n, "help_notch1", "Notch 1: Sets the center frequency and lower cutoff of the first static notch in Hz.")
  local help_notch2 = t(i18n, "help_notch2", "Notch 2: Sets the center frequency and lower cutoff of the second static notch in Hz.")
  local help_dyn = t(i18n, "help_dyn", "Dynamic Filters: Notches automatically track gyro noise peaks between Min and Max in Hz, with Notch Count setting their number and higher Q making them narrower.")
  local help_rpm = t(i18n, "help_rpm", "RPM filter: Higher strength removes more vibration but adds delay, and the minimum frequency should be slightly below the main rotor frequency at the lowest flying RPM.")

  local parts = { help_p1, help_p2, help_p4, help_lpf2, help_notch1, help_notch2, help_dyn, help_rpm }

  return {
    title = t(i18n, "help_title", "Filters Help"),
    message = table.concat(parts, "\n")
  }
end
