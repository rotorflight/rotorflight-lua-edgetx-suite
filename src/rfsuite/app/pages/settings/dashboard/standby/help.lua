return function(ctx)
  local i18n = ctx and ctx.i18n
  local message = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_standby.help_message")
    or "Choose what the standby screen shows, in up to three rows, while the dashboard waits for the flight controller."
  return { message = message }
end
