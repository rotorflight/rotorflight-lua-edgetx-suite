return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local fallback = "Settings held by the AM32 speed controller itself, read when the page opens and written back on "
    .. "SAVE; each has its own help."
  local message = i18n and i18n.t and i18n.t("app.pages.setup_esc_motors.help_am32") or fallback

  return {
    message = message
  }
end
