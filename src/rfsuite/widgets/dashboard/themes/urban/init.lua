local init = {
  name = "Urban",
  -- One module for both: the flight view does not change shape at spool-up.
  preflight = "flight.lua",
  inflight = "flight.lua",
  postflight = "postflight.lua",
  -- No `armed` and no `offline` module, and both are decisions rather than omissions.
  --
  -- A host that knows the two extra phases lets a theme REFINE two of the three: `armed` refines
  -- the ground screen, `offline` the post-flight one, and a theme naming no module for them
  -- draws the module of the phase they refine -- without rebuilding anything, because the scene
  -- already standing is the one that would be built.
  --
  -- `armed` would draw this theme's flight view either way: the view does not change shape at
  -- spool-up, and the bottom bar already says ARMED in the arm-state colour the moment the arm
  -- flag turns. A module for it would be a second copy of one file to keep in step for nothing.
  --
  -- `offline` DOES show something different -- the numbers are final and the model cannot be
  -- armed again -- but it is one word on one line, and postflight.lua draws it from
  -- `state.flightMode` in a per-frame closure. So the change reaches the screen without a
  -- module the host has to load, and there is one statistics view rather than two that must
  -- not drift apart.
  configure = "configure.lua",
  standalone = false,
  -- A host that knows this key draws this theme at the full screen size instead of the quick
  -- menu; one that does not know it ignores the key and full screen stays the quick menu.
  fullscreen = "theme",
  -- The way out of full screen is a long press on RTN, which the firmware always honours, so
  -- this theme draws no close control. The two controls it binds are the menu and the tool
  -- glyphs in the top bar (layout.lua, L.menuControl, L.toolControl).
  fullscreenExit = "longRtn",
  -- The settings of this theme are three pages rather than one long form. A host that knows
  -- `pages` opens the theme's tile on a grid of these and hands the chosen one to the
  -- configure module as `ctx.page`; a host that does not know it ignores the field and shows
  -- the whole form, which is what the module does when no page arrives. `icon` is relative
  -- to this folder.
  --
  -- An id named here has to be named in configure.lua as well, and the two live in different
  -- files: an id this list carries that that module does not know falls through to its
  -- `only == nil` branch and draws the WHOLE form on that one tile -- silently, with nothing
  -- raising anywhere.
  --
  -- Each title is a quoted string literal, and that is not a style choice: the packager reads
  -- `pages` out of this file as TEXT, with a regular expression that wants `title = "..."`
  -- (bin/package/build_package.py, parse_theme_pages), and drops an entry without one without
  -- a word. A translation marker is such a literal. The generated theme index is written into
  -- the staged tree before the markers are resolved, so the marker is resolved in the index
  -- and in this file alike, and a radio reading either one gets the title in its language.
  pages = {
    { id = "look",   title = "@i18n(app.pages.settings_dashboard_settings.urban_page_look)@",   icon = "icons/look.png" },
    { id = "rows",   title = "@i18n(app.pages.settings_dashboard_settings.urban_page_rows)@",   icon = "icons/rows.png" },
    { id = "topbar", title = "@i18n(app.pages.settings_dashboard_settings.urban_page_topbar)@", icon = "icons/topbar.png" },
    { id = "keys",   title = "@i18n(app.pages.settings_dashboard_settings.urban_page_keys)@",   icon = "icons/keys.png" },
    { id = "telemetry", title = "@i18n(app.pages.settings_dashboard_settings.urban_page_telemetry)@", icon = "icons/telemetry.png" },
  },
  -- The full screen views, on a host that has theme views; any other host ignores the key. The quick
  -- menu, the battery picker and the battery profile page are the host's own, the same on every
  -- theme. `urban_menu` is the
  -- is
  -- theme's own menu (the battery profiles and the tuning surface, opened by a tap on the flight
  -- view's profile row), `urban_link` its ELRS link page (opened by a tap on the link bars),
  -- `urban_telemetry` its telemetry page (opened by a tap on the value rows; its tiles are chosen
  -- on the Telemetry settings page).
  -- `urban_battery` its battery page (opened by a tap on the battery gauge).
  -- `urban_status` its status page (opened by a tap on the governor and status rows of the
  -- left panel).
  --
  -- The link view also opens on a switch, in full screen and in the widget zone alike, and shows
  -- while the switch holds the position: a glance at the link without a tap, in flight too. The
  -- switch is the pilot's, on the Top Bar settings page (`link_switch`, a switch position as the
  -- radio's own picker stores it). Until the pilot names one, `default` stands: 0, no switch --
  -- the view then opens by its tap only.
  views = {
    { id = "urban_menu",   module = "toolsview.lua" },
    { id = "urban_link",   module = "linkview.lua", where = "both",
      openWhen = { switch = { pref = "link_switch", default = 0 } } },
    { id = "urban_telemetry", module = "telemview.lua" },
    { id = "urban_battery", module = "battview.lua" },
    { id = "urban_status", module = "statusview.lua" },
  },
}

return init
