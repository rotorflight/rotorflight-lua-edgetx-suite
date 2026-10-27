return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.setup_power_smartfuel.help_message")
    or "How the remaining fuel of the pack is estimated.\nFirmware Source: Off disables SmartFuel; Voltage uses pack voltage, Current consumed mAh and capacity, Combined the lower estimate; enabled modes need a battery voltage sensor.\nVoltage drop rate: limits how fast the voltage track falls in VOLTAGE and COMBINED.\nCharge drop rate: limits how fast the voltage track's charge percentage falls once armed or previously armed, in VOLTAGE and COMBINED.\nSag gain: compensates voltage sag in VOLTAGE and COMBINED; increase if SmartFuel reads too low under load, decrease if too high."

  return {
    message = message
  }
end
