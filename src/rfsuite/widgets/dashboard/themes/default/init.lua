local init = {
  name = "Default",
  preflight = "preflight.lua",
  inflight = "inflight.lua",
  postflight = "postflight.lua",
  configure = "configure.lua",
  standalone = false,
  fullscreen = "theme",
  -- The settings as pages: Look is this theme's own (configure.lua), the rest are the pages
  -- every theme that declares boxes shares (app/pages/settings/dashboard/fields_form.lua) --
  -- what the tiles of each phase show, and the keys. An id here has to be one configure.lua
  -- knows; the titles are string literals because the packager reads this list as text.
  pages = {
    { id = "look",       title = "@i18n(app.pages.settings_dashboard_settings.urban_page_look)@",       icon = "icons/look.png" },
    { id = "preflight",  title = "@i18n(app.pages.settings_dashboard_settings.page_preflight)@",  icon = "icons/preflight.png" },
    { id = "inflight",   title = "@i18n(app.pages.settings_dashboard_settings.page_inflight)@",   icon = "icons/inflight.png" },
    { id = "postflight", title = "@i18n(app.pages.settings_dashboard_settings.page_postflight)@", icon = "icons/postflight.png" },
    { id = "bar",        title = "@i18n(app.pages.settings_dashboard_settings.page_bar)@",        icon = "icons/bar.png" },
    { id = "keys",       title = "@i18n(app.pages.settings_dashboard_settings.urban_page_keys)@",       icon = "icons/keys.png" },
  },
}

return init
