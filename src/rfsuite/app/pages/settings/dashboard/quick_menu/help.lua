return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.settings_dashboard_quick_menu.help_message")
    or "How the quick menu is drawn, and which entries it shows in which order. An entry still hides where it does not apply; Battery profile is always the last one."

  return {
    message = message
  }
end
