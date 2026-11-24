-- NovaFly: one full-screen cockpit for every flight phase, two pages of its own (the model and its battery before the flight,
-- the banks after it) and the colour of the cockpit as the one setting of the theme. Drawn for 800 x 480 and offered on that
-- screen size only (`screen`). The bank page opens by itself when a flight has ended and closes again when the model is armed.
local init = {
  name = "@NovaFly",
  preflight = "cockpit.lua",
  inflight = "cockpit.lua",
  postflight = "cockpit.lua",
  configure = "configure.lua",
  standalone = false,
  fullscreen = "theme",
  fullscreenExit = "longRtn",
  views = {
    { id = "novafly_vorflug", module = "vorflug.lua" },
    { id = "novafly_baenke", module = "baenke.lua",
      openWhen = function(state) return state ~= nil and (state.flightMode == "postflight" or state.flightMode == "offline") end },
  },
  screen = { w = 800, h = 480 },
}
return init
