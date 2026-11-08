---
title: Dashboard widget
sidebar_label: Dashboard
---

# Dashboard widget

The *RFSuite* widget renders a theme from live telemetry and switches between a preflight,
an inflight and a postflight layout as the flight progresses. What the README says about it
is the starting point; these files carry the detail.

| File | What it will say | Start from | Status |
| --- | --- | --- | --- |
| `widget-setup.md` | Adding the widget to a screen, sizing it, and what it shows in each of the three flight phases. | README, and the phase table in [developer/dashboard-themes.md](../developer/dashboard-themes.md) | to write |
| [themes.md](themes.md) | The shipped themes (Default, RF Status, @AERC, @AERC Nitro, @RT-RC, @RT-RC Nitro, @SRB-RC, Urban, Grid, Deck), each with a picture of its preflight, inflight and postflight screen, what every theme has in common, and choosing one under *System* → *Settings* → *Dashboard* → *Theme*. | the theme sources, and screenshots on a TX16S MK3 | written |
| `theme-settings.md` | The per-theme settings page under *Dashboard* → *Settings*: the voltage range a theme's gauges span, stored for the radio, with per-model settings where they are switched on. | theme `configure.lua` sources | to write |
| [user-themes.md](user-themes.md) | Copying a shipped theme into `/SCRIPTS/RFSUITE/user/dashboard/`, editing it, box styling, named colors, dynamic thresholds, and why a copy keeps its own settings. | nowhere yet | written |
| [developer/dashboard-themes.md](../developer/dashboard-themes.md) | For contributors: the same thing at source level — the manifest keys, what puts the widget into each phase, the grid and box vocabulary, the `configure.lua` factory, and what a theme shipped in this repository owes. | source | written |
| [urban-theme.md](urban-theme.md) | The Urban theme, a free-form theme shipped as a demonstration of a theme that takes fullscreen and declares the telemetry it reads: what it shows, the pages it opens in full screen, its five settings pages, and what it does not do yet. | theme sources | written |
| [grid-theme.md](grid-theme.md) | The Grid theme, a free-form theme built on Urban: its battery panel and grid of value tiles, what opens where in full screen, its six settings pages, and what it does not do yet. | theme sources | written |
| [deck-theme.md](deck-theme.md) | The Deck theme, a free-form theme built on Urban: its cards, value cards and battery strip, what opens where in full screen, its six settings pages, and what it does not do yet. | theme sources | written |
| [quick-menu.md](quick-menu.md) | The fullscreen quick menu: how it is reached, its entries — erasing the blackbox, opening the in-flight tuning surface, the battery prompt, opening the suite's tool inside the widget, picking the battery profile — the close button, and the entry list it builds from. | source | written |
| [inflight-tuning.md](inflight-tuning.md) | The in-flight tuning overlay: what the interlock switch brings up on the ground, in the air and after landing, and how it drives the flight controller's adjustment functions through two global variables. | the two settings pages and the overlay sources | written |
| [standby-screen.md](standby-screen.md) | The surface shown before a flight controller is ready, its single-screen fit rule, and the flight states that take priority over it. | the standby source and settings page | written |
| `model-image.md` | Where the model picture comes from, the per-cell-count variant and the accepted file types. | README | to write |
| [service-widget.md](service-widget.md) | What runs the background work, which of the two widgets to add to a model, where to place *RFSuite Service*, what its tile shows, what happens with both widgets on one model, and what to avoid. | the service and dashboard runtime sources | written |
| [../troubleshooting/collecting-logs.md](../troubleshooting/collecting-logs.md#reading-a-dashboard-log) | What the dashboard writes to the log, by tag and level, and how to read it for what it costs and where a problem began. |
