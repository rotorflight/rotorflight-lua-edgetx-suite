return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local fallback = "Reads the BLHeli_S ESC parameter block and writes it back on SAVE. Configure motor direction, "
    .. "startup power, timing, temperature protection and beeps from the radio."
  local message = i18n and i18n.t and i18n.t("app.pages.setup_esc_motors.help_blheli_s") or fallback

  return {
    message = message
  }
end
