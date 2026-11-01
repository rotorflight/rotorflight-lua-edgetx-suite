return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local fallback = "Reads the XDFly ESC parameter block and writes it back on SAVE. Configure BEC voltage, motor "
    .. "direction and startup, battery cutoff and the ESC governor from the radio."
  local message = i18n and i18n.t and i18n.t("app.pages.setup_esc_motors.help_xdfly") or fallback

  return {
    message = message
  }
end
