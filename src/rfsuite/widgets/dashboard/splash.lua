local Splash = {}

local LOGO_FILE = _G.rfsuite.paths.core .. "/widgets/dashboard/gfx/logo.png"

-- title and statusLine are a string, or a function a label reads, so a new text rebuilds nothing.
-- progress is optional: a function answering 0 to 1, or nil to hide the bar.
function Splash.build(zone, statusLine, title, progress)
  local w = (zone and zone.w) or LCD_W or 320
  local h = (zone and zone.h) or LCD_H or 172
  local logoW = math.max(112, math.min(math.floor(w * 0.80), 240))
  local logoH = math.max(36, math.min(math.floor(h * 0.32), 68))
  local logoX = math.floor((w - logoW) * 0.5)
  local logoY = math.max(6, math.floor(h * 0.10))
  local titleY = math.max(math.floor(h * 0.44), logoY + logoH + 8)
  local lineY = titleY + 46

  local children = {
    {
      type = "rectangle",
      x = 0,
      y = 0,
      w = w,
      h = h,
      color = COLOR_THEME_PRIMARY3,
      filled = true
    },
    {
      type = "image",
      x = logoX,
      y = logoY,
      w = logoW,
      h = logoH,
      file = LOGO_FILE
    },
    {
      type = "label",
      x = 0,
      y = titleY,
      w = w,
      text = type(title) == "function" and title or tostring(title or "Connecting FBL..."),
      align = CENTER,
      color = COLOR_THEME_PRIMARY2,
      font = MIDSIZE
    },
    {
      type = "label",
      x = 0,
      y = lineY,
      w = w,
      text = type(statusLine) == "function" and statusLine or tostring(statusLine or "Please wait for telemetry"),
      align = CENTER,
      color = COLOR_THEME_PRIMARY2,
      font = SMLSIZE
    }
  }

  -- The same proportions as the tool's start screen, on the line's row and the one below: the line
  -- is empty while the bar stands. A zone too low for it shows the title alone.
  local barH = 12
  local barY = lineY + 4
  if progress and barY + barH <= h then
    local barW = math.min(420, math.max(200, w - 120), w - 8)
    local barX = math.floor((w - barW) / 2)
    local fillW = barW - 4
    children[#children + 1] = {
      type = "rectangle",
      x = barX, y = barY, w = barW, h = barH,
      color = COLOR_THEME_DISABLED,
      filled = true,
      visible = function() return progress() ~= nil end
    }
    children[#children + 1] = {
      type = "rectangle",
      x = barX + 2, y = barY + 2, w = 1, h = barH - 4,
      color = COLOR_THEME_PRIMARY2,
      filled = true,
      visible = function() return progress() ~= nil end,
      size = function()
        return math.max(1, math.floor(fillW * math.min(1, progress() or 0) + 0.5)), barH - 4
      end
    }
  end

  return children
end

return Splash
