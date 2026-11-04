return {
  Viewport = assert(loadScript(_G.rfsuite.paths.core .. "/core/viewport.lua", "t"))(),
  BorderLayout = assert(loadScript(_G.rfsuite.paths.core .. "/layouts/border.lua", "t"))(),
  GridLayout = assert(loadScript(_G.rfsuite.paths.core .. "/layouts/grid.lua", "t"))(),
  FlowLayout = assert(loadScript(_G.rfsuite.paths.core .. "/layouts/flow.lua", "t"))()
}
