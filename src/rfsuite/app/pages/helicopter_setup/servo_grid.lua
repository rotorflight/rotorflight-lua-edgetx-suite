-- One servo's direction, centre and arm reference share each card. Reactive getters read
-- live values without changing controller state.
local M = {}
function M.append(all, w, card, width, height, large, current, diagrams)
  local L, c = w.L, card.servo
  local tiny = width < 400
  local gap = large and 8 or 4
  local lineH = large and 26 or tiny and 17 or 18
  local space = tiny and 1 or 2
  local top = large and 110 or tiny and 45 or 60
  local tw = large and 420 or tiny and 200 or 300
  local buttonH = large and 56 or height >= 300 and 40 or 32
  local function enabled() return w.canEdit == true and current() end
  local function act(fn) return function() if enabled() and w:usable() then fn() end end end
  local function label(x, y, lw, text)
    all[#all + 1] = { type = "label", x = x, y = y, w = lw, h = lineH, text = text,
      font = SMLSIZE, color = w.palette.text }
    return all[#all]
  end
  local function button(x, y, bw, text, press, visible)
    all[#all + 1] = { type = "button", x = x, y = y, w = bw, h = buttonH, text = text,
      press = act(press), active = enabled, visible = visible, color = w.palette.card,
      textColor = w.palette.text, font = SMLSIZE }
  end
  local offset = label(10, top, tw, c.offset)
  offset.color = function() return c.far() and w.palette.warning or w.palette.text end
  label(10, top + lineH + space, tw, c.live)
  local testY = top + 2 * (lineH + space)
  if c.tail then
    label(10, testY, tw, L.tailCentreOnly)
  else
    button(10, testY, tw, L.servoTestUp, c.test, function() return not c.testing() end)
    local half = math.floor((tw - gap) / 2)
    button(10, testY, half, L.answerUp, c.up, c.testing)
    button(10 + half + gap, testY, tw - half - gap, L.answerDown, c.down, c.testing)
  end
  local statusY = testY + buttonH + space
  label(10, statusY, tw, c.status)
  local nudgeY = statusY + lineH + space
  local nw = large and tw or width - 20
  local bw = math.floor((nw - 3 * gap) / 4)
  local x = 10
  for _, delta in ipairs({ -10, -1, 1, 10 }) do
    local d = delta
    button(x, nudgeY, bw, (d > 0 and "+" or "") .. d, function() c.nudge(d) end)
    x = x + bw + gap
  end
  local warningY = large and 340 or nudgeY + buttonH + space
  local warning = label(10, warningY, width - 20, function() return c.far() and L.servoFar or "" end)
  warning.color = w.palette.warning
  diagrams.append(all, w, card, tw + 20, top, width - tw - 30, large and 220 or tiny and 80 or 90)
end
return M
