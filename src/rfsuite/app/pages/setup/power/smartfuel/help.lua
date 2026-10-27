return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.setup_power_smartfuel.help_message")
    or "How the remaining fuel of the pack is estimated.\nFirmware Source: what the flight controller computes; COMBINED takes the more pessimistic of voltage and current.\nVoltage drop rate: how fast the filtered voltage may fall, so that a brief sag under load does not pull the estimate down.\nCharge drop rate: how fast the reported fuel may drop once the model has been armed.\nSag gain: how strongly the voltage is corrected for sag under load; raise it if the estimate reads too low in flight."

  return {
    message = message
  }
end
