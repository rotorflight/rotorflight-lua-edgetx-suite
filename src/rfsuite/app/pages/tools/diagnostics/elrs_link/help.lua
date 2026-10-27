return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.diagnostics_elrs_link.help_message")
    or "Rotorflight: telemetry mode, link rate and ratio on the board.\nELRS Module: packet rate and telemetry ratio.\nTX Power: Max Power and dynamic power; read only.\nProbe: reads both sides again without writing; refused while armed, available after disarm. Arming stops any probe, including the opening probe or one started by Reload.\nRF -> ELRS: sets the module to the board's rate and ratio; asks first, never while armed.\nELRS -> RF: sets the board to the module's rate and ratio and saves it; asks first, never while armed."

  return { message = message }
end
