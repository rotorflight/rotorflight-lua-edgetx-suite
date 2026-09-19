return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.diagnostics_validate_sensors.help_message")
    or "Checks each configured sensor. OK: receiving it now. NO DATA: known, nothing arriving. INVALID: no such sensor."

  return { message = message }
end
