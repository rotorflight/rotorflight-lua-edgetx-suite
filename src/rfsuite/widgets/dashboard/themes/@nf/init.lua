-- @NF: one full-screen cockpit for every flight phase, two pages of its own (the model and its battery before the flight,
-- the banks after it) and the colour of the cockpit as the one setting of the theme. Drawn for 800 x 480, 480 x 320 and 480 x 272
-- (pictures in gfx/, gfx_480x320/, gfx_480x272/). The bank page opens by itself when a flight has ended and closes again when armed.
local init = {
  name = "@NF",
  preflight = "cockpit.lua",
  inflight = "cockpit.lua",
  postflight = "cockpit.lua",
  configure = "configure.lua",
  standalone = false,
  fullscreen = "theme",
  fullscreenExit = "longRtn",
  views = {
    { id = "nf_preflight", module = "preflight.lua" },
    { id = "nf_banks", module = "banks.lua",
      openWhen = function(state) return state ~= nil and (state.flightMode == "postflight" or state.flightMode == "offline") end },
  },
}
return init
