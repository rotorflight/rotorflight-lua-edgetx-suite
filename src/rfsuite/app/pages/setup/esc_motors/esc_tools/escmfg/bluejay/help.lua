return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local section = ctx and tonumber(ctx.section) or 1

  if section == 2 then
    local fallback = "ESC Target: selects the ESC to read and write.\n"
      .. "Section: switches the settings group.\n"
      .. "Motor Timing: selects commutation timing from 0 to 30 degrees.\n"
      .. "Demag Compensation: selects Off, Low or High.\n"
      .. "Brake on Stop: brakes when the throttle is closed.\n"
      .. "Braking Mode: selects the brake mode on layout 202.\n"
      .. "Braking Strength: sets brake strength from 0 to 255 on layout 204 or later.\n"
      .. "LED Control: selects the LED colour where supported."
    local message = i18n and i18n.t and i18n.t("app.pages.setup_esc_motors.help_bluejay_brake") or fallback
    return { message = message }
  end

  if section == 3 then
    local fallback = "ESC Target: selects the ESC to read and write.\n"
      .. "Section: switches the settings group.\n"
      .. "Beep Strength: sets beep volume from 1 to 255.\n"
      .. "Beacon Strength: sets lost-model beacon volume from 1 to 255.\n"
      .. "Beacon Delay: sets the delay after throttle closes, or Infinite to disable.\n"
      .. "Startup Beep: selects the power-up beep where supported."
    local message = i18n and i18n.t and i18n.t("app.pages.setup_esc_motors.help_bluejay_beacon") or fallback
    return { message = message }
  end

  if section == 4 then
    local fallback = "ESC Target: selects the ESC to read and write.\n"
      .. "Section: switches the settings group.\n"
      .. "Temperature Protection: limits power at the selected temperature.\n"
      .. "Low RPM Power Protection: available through layout 200 only.\n"
      .. "Power Rating: selects 1S or 2S+ from layout 206.\n"
      .. "Force EDT Arm: arms EDT regardless of detection.\n"
      .. "Dithering: available through layout 207 only.\n"
      .. "Threshold 96to48: sets the throttle threshold for Dynamic PWM from 96 to 48 kHz.\n"
      .. "Threshold 48to24: sets the throttle threshold from 48 to 24 kHz."
    local message = i18n and i18n.t and i18n.t("app.pages.setup_esc_motors.help_bluejay_other") or fallback
    return { message = message }
  end

  local fallback = "ESC Target: selects the ESC to read and write.\n"
    .. "Section: switches the settings group.\n"
    .. "Motor Direction: selects the direction of rotation.\n"
    .. "Rampup Start Power: sets rampup power as a percentage through layout 200.\n"
    .. "Rampup Power: sets rampup power from 1x to 13x, or Off.\n"
    .. "Min Startup Power: sets the lower startup power bound from 1000 to 1125.\n"
    .. "Max Startup Power: sets the upper startup power bound from 1004 to 1300.\n"
    .. "PWM Frequency: selects 24, 48 or 96 kHz, or Dynamic from layout 209."
  local message = i18n and i18n.t and i18n.t("app.pages.setup_esc_motors.help_bluejay_general") or fallback
  return { message = message }
end
