return function(ctx)
  local i18n = ctx and ctx.i18n or nil
  local message = i18n and i18n.t and i18n.t("app.pages.diagnostics_session_logs.help_message")
    or "The last log lines this script kept in memory, newest at the bottom, coloured by level; gone when it stops unless Log Session To Card (Developer > Settings) is on.\nReload (header): draws the page again; it also updates itself as lines arrive."

  return { message = message }
end
