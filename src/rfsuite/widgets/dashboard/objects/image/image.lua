local Render = {}

-- Joined once here, so a render does not join it again.
local DEFAULT_IMAGE = _G.rfsuite.paths.core .. "/widgets/dashboard/gfx/default_image.png"

function Render.render(nodes, rect)
  nodes[#nodes + 1] = {
    type = "image",
    x = rect.x + 4,
    y = rect.y + 4,
    w = math.max(18, rect.w - 8),
    h = math.max(18, rect.h - 8),
    file = DEFAULT_IMAGE
  }
end

return Render
