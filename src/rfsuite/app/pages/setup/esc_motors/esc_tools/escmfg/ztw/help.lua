return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local fallback = "Reads the ZTW ESC parameter block and writes it back on SAVE. Only settings supported by the "
    .. "connected ESC firmware are shown."
  local message = i18n and i18n.t and i18n.t("app.pages.setup_esc_motors.help_ztw") or fallback

  return {
    message = message
  }
end
