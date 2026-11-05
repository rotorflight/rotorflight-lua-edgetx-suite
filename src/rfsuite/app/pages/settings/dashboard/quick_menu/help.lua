return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_quick_menu.help_message")
    or "Which entries the quick menu shows and in which order. An entry still hides where it does not apply; Battery profile is always the last one."

  return {
    message = message
  }
end
