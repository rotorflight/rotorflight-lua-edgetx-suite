return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.diagnostics_info.help_message")
    or "Shows firmware, board, transport, and link information read from the flight controller and runtime.\nRF Mode: decoded for the module's ExpressLRS generation once it has identified itself; - until then and for a module that is not ExpressLRS 3.x or 4.x.\nRF Band: shown for ExpressLRS 4.x modules, whose RF Mode value carries the band; - for 3.x."

  return { message = message }
end
