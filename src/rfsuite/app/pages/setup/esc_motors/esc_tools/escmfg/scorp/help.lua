return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local fallback = "Settings held by the Scorpion speed controller itself: read from it when "
    .. "the page opens and written back to it on SAVE; the flight controller only passes them "
    .. "through."
  local message = i18n and i18n.t and i18n.t("app.pages.setup_esc_motors.help_scorp") or fallback

  return {
    message = message
  }
end
