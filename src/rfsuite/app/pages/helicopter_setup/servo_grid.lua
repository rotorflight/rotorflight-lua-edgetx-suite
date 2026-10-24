-- The servo direction and centre step as one page, so every servo is visible while one is
-- tested and centred: a row per servo on large screens, a column per servo on compact ones.
-- The entries come from steps/servos.lua.
local M = {}
function M.append(all, w, card, width, height, large, controlH, current)
  local L = w.L
  local cols = card.grid
  local n = math.max(1, #cols)
  local tiny = height < 260
  local gap = large and 8 or 4
  local lineH = large and 24 or tiny and 16 or 18
  local top = large and 130 or tiny and 44 or 48
  local function enabled() return w.canEdit == true and current() end
  local function act(fn) return function() if enabled() and w:usable() then fn() end end end
  local function label(x, y, lw, text, font)
    all[#all + 1] = { type = "label", x = x, y = y, w = lw, h = lineH, text = text, font = font or SMLSIZE,
      color = w.palette.text }
    return all[#all]
  end
  local function button(x, y, bw, text, press, visible)
    all[#all + 1] = { type = "button", x = x, y = y, w = bw, h = controlH, text = text, press = act(press),
      active = enabled, visible = visible, color = w.palette.card, textColor = w.palette.text }
    return all[#all]
  end
  local function test(c, x, y, tw)
    if c.tail then
      label(x, y + math.floor((controlH - lineH) / 2), tw, L.tailCentreOnly)
      return
    end
    button(x, y, tw, L.servoTestUp, c.test, function() return not c.testing() end)
    local half = math.floor((tw - gap) / 2)
    button(x, y, half, L.answerUp, c.up, c.testing)
    button(x + half + gap, y, tw - half - gap, L.answerDown, c.down, c.testing)
  end
  local function nudges(c, x, y, nw, steps)
    local bw = math.floor((nw - gap * (#steps - 1)) / #steps)
    for _, delta in ipairs(steps) do
      local d = delta
      button(x, y, bw, (d > 0 and "+" or "") .. d, function() c.nudge(d) end)
      all[#all].font = SMLSIZE
      x = x + bw + gap
    end
  end
  if large then
    -- Row: name and centre | test or answer | nudges | status.
    local rowH = math.floor((height - controlH - 40 - top) / n)
    local lw, tw, nw = 280, 160, 4 * 44 + 3 * gap
    local sw = width - 20 - lw - tw - nw - 3 * gap
    for k, c in ipairs(cols) do
      local y = top + (k - 1) * rowH
      local cy = y + math.floor((rowH - controlH) / 2)
      local ty = y + math.floor((rowH - 2 * lineH) / 2)
      local x = 10
      label(x, ty, lw, c.title .. "  " .. c.role)
      label(x, ty + lineH, lw, function() return c.offset() .. (c.reversed() and ("  " .. L.reversed) or "") end)
      x = x + lw + gap
      test(c, x, cy, tw); x = x + tw + gap
      nudges(c, x, cy, nw, { -10, -1, 1, 10 }); x = x + nw + gap
      label(x, ty, sw, c.status).h = 2 * lineH
    end
    return
  end
  local cw = math.floor((width - 20 - gap * (n - 1)) / n)
  for k, c in ipairs(cols) do
    local x = 10 + (k - 1) * (cw + gap)
    local y = top
    label(x, y, cw, c.title .. " " .. c.role); y = y + lineH
    label(x, y, cw, c.live); y = y + lineH + 2
    test(c, x, y, cw); y = y + controlH + 2
    label(x, y, cw, c.status); y = y + lineH + 2
    -- The nudge buttons share the column; the line below them shows the centre.
    nudges(c, x, y, cw, { -10, 10 }); y = y + controlH + 2
    label(x, y, cw, c.offset)
  end
end
return M
