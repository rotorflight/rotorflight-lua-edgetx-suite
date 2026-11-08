return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_theme.help_message")
    or "Which dashboard theme the models show, and whether a model may use a theme and theme settings of its own; each setting's ? says what it does."
  
  return {
    message = message
  }
end
