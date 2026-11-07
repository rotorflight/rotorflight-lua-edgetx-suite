-- What the dashboard says the first time it stands on a radio. A file of its own so that its strings
-- cost a radio nothing once the pilot has read them: it is loaded only for the build that shows them.
return function(t)
  return t("widgets.dashboard.standby.intro_title", "Getting started"), {
    t("widgets.dashboard.standby.intro_placed", "The dashboard is placed, nothing else is needed."),
    t("widgets.dashboard.standby.intro_others", "No other dashboards or service widgets on this model."),
    t("widgets.dashboard.standby.intro_foreign_job", "Remove other background jobs (e.g. rf2bg) from Special Functions."),
    t("widgets.dashboard.standby.intro_own_job", "rfsbg is added by the suite: do not delete it."),
    t("widgets.dashboard.standby.intro_full_screen", "Done reading? Long-press the dashboard: Full screen."),
    (t("widgets.dashboard.standby.intro_keys", "In full screen: SYS opens the suite, TELE the quick menu.")),
  }
end
