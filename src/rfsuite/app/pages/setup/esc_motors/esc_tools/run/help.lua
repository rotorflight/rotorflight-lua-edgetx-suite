return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local fallback = "Placeholder for the selected maker's ESC configurator; it offers no ESC settings yet."
  local message = i18n and i18n.t and i18n.t("app.pages.setup_esc_motors.help_run") or fallback

  return {
    message = message
  }
end
