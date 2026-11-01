return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local fallback = "Reads the Hobbywing V5 ESC parameter block and writes it back on SAVE. The reported hardware "
    .. "version determines which settings and choices are shown."
  local message = i18n and i18n.t and i18n.t("app.pages.setup_esc_motors.help_hw5") or fallback

  return {
    message = message
  }
end
