-- NovaFly RC: one full-screen cockpit for every flight phase, a bank view of its own, and the colour of the cockpit as
-- the theme's one setting. Drawn for 800 x 480 and offered on that screen size only (`screen`).
local init = {
  name = "@NovaFly RC",
  preflight = "cockpit.lua",
  inflight = "cockpit.lua",
  postflight = "cockpit.lua",
  configure = "configure.lua",
  standalone = false,
  fullscreen = "theme",
  fullscreenExit = "longRtn",
  views = {
    { id = "novafly_bank", module = "bank.lua" },
  },
  screen = { w = 800, h = 480 },
}
return init
