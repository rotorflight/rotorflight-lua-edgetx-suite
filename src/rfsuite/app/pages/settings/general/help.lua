return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.settings_general.help_message")
    or "Prompts, appearance, preview features and developer tools of this radio."

  return { message = message }
end
