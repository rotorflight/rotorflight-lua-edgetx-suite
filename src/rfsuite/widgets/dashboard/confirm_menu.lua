-- The question a fullscreen press asks before it is performed, for an entry that carries
-- `confirm` (a quick menu row, or one a theme draws from the same records).
--
-- A view on the stack, above the surface that raised it: the menu stays open under it, and
-- declining puts the menu back exactly as it was. What is drawn here is only the question; what
-- the press does is the entry's `press` and its `after`, held by views.confirm until the pilot
-- answers, and run from this view's ERASE button. Nothing is queued, and full screen is not
-- left, until then.
--
-- It is deliberately the same two layout profiles fullscreen_menu.lua and battery_pick_menu.lua
-- use (large above 350 px, standard below), so a radio at either resolution gets a box of the
-- size it already gets from the menu.
--
-- The strings all come from the entry's `confirm` table, resolved where the entry was built; the
-- only literals here are the fallbacks for a table that is missing one, so a new confirmed
-- entry adds no string to this file.

local M = {}

local requireModule = (_G.rfsuite and _G.rfsuite.require) or function(path)
  local fullPath = string.sub(path, 1, 1) == "/" and path or (_G.rfsuite.paths.core .. "/" .. path)
  local chunk = loadScript(fullPath, "t")
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local Views = requireModule("widgets/dashboard/views.lua")

-- The press waiting for an answer: `{ spec, work }` on this visit's session.
local function pending(widget)
  if Views and type(Views.pendingConfirm) == "function" then return Views.pendingConfirm(widget) end
  return nil
end

-- Answering closes the question FIRST -- both answers do -- and agreeing then runs the work. The
-- work performs the press and, after it, the `after` action; that action belongs to the surface
-- the press was written for (the menu), not to the question that was on top of it. Closing first
-- is what makes a theme's own `after`, handed in through ctx.run, act on the menu as well.
-- Closing first also matters because the work may start a new session (`done`), which takes the
-- field with it, so a callback that read it afterwards would read a table the visit no longer
-- holds.
local function agree(widget, work)
  if Views and type(Views.closeConfirm) == "function" then Views.closeConfirm(widget) end
  if type(work) == "function" then work() end
end

-- Declining closes the question and forgets the press, leaving the menu under it standing.
local function decline(widget)
  if Views and type(Views.closeConfirm) == "function" then Views.closeConfirm(widget) end
end

--- What RTN does while the question is on top: the same as CANCEL.
--
-- Without a `back` the RTN default for a view on the stack is `closeView`, which would pop this
-- view but leave the pending press on the session -- so the next entry into full screen could
-- still perform it. Declining clears the pending press as well.
function M.back(widget)
  decline(widget)
end

function M.build(children, widget)
  local question = pending(widget)
  local spec = (question and question.spec) or {}

  local dW = widget.zone.w
  local dH = widget.zone.h
  local dX, dY = 0, 0

  local bg_color = COLOR_THEME_PRIMARY3 or BLACK
  if bg_color == BLACK and lcd and type(lcd.RGB) == "function" then
    bg_color = lcd.RGB(40, 40, 40)
  end
  local panel_color = COLOR_THEME_PRIMARY2 or bg_color
  local btn_color = COLOR_THEME_PRIMARY1 or DARKGREY
  local danger_color = COLOR_THEME_WARNING or RED
  local text_color = COLOR_THEME_PRIMARY1 or WHITE

  children[#children+1] = {
    type = "rectangle", x=dX, y=dY, w=dW, h=dH, color=bg_color, filled=true
  }

  -- The two layout profiles the menu and the picker use: a large high-resolution radio, and the
  -- standard 480x272 one.
  local isLarge = dH > 350

  local titleFont, font, smallFont, fontH, smallH
  local padding, titleStep, lineH, gap, btnH, btnTextOffY

  if isLarge then
    titleFont, font, smallFont = MIDSIZE, MIDSIZE, SMLSIZE
    fontH, smallH = 24, 16
    padding, titleStep, lineH, gap, btnH, btnTextOffY = 24, 44, 30, 14, 54, -8
  else
    titleFont, font, smallFont = SMLSIZE, SMLSIZE, SMLSIZE
    fontH, smallH = 12, 12
    padding, titleStep, lineH, gap, btnH, btnTextOffY = 12, 24, 16, 8, 36, -4
  end

  local panelW = math.min(dW - padding * 2, isLarge and 560 or 440)
  local innerW = panelW - padding * 2
  -- Room for the title, up to two lines of question, an optional detail line and the buttons.
  -- A question longer than that wraps under the buttons rather than moving them: the box is
  -- centred on the screen, so what would run off is the bottom, and the buttons stay reachable.
  local messageH = lineH * 2
  local detailH = (type(spec.detail) == "string" and spec.detail ~= "") and (smallH + 4) or 0
  local panelH = padding + titleStep + messageH + detailH + gap + btnH + padding
  if panelH > dH - padding * 2 then panelH = dH - padding * 2 end

  local panelX = dX + math.floor((dW - panelW) / 2)
  local panelY = dY + math.floor((dH - panelH) / 2)

  children[#children+1] = {
    type = "rectangle", x=panelX, y=panelY, w=panelW, h=panelH, color=panel_color, filled=true
  }

  local title = spec.title
  if type(title) ~= "string" or title == "" then title = "CONFIRM" end
  children[#children+1] = {
    type = "label", x=panelX + padding, y=panelY + padding, w=innerW,
    text=title, color=text_color, align=LEFT, font=titleFont
  }

  children[#children+1] = {
    type = "label", x=panelX + padding, y=panelY + padding + titleStep, w=innerW,
    text=spec.message or "", color=text_color, align=LEFT, font=font
  }

  if detailH > 0 then
    children[#children+1] = {
      type = "label", x=panelX + padding, y=panelY + padding + titleStep + messageH, w=innerW,
      text=spec.detail, color=text_color, align=LEFT, font=smallFont
    }
  end

  local by = panelY + panelH - padding - btnH
  local labelY = by + math.floor((btnH - fontH) / 2) + btnTextOffY
  local btnW = math.floor((innerW - gap) / 2)

  -- CANCEL, on the left: the safe answer, in the neutral colour.
  local cancelLabel = spec.cancelLabel
  if type(cancelLabel) ~= "string" or cancelLabel == "" then cancelLabel = "CANCEL" end
  children[#children+1] = {
    type = "button", x=panelX + padding, y=by, w=btnW, h=btnH, color=btn_color,
    press = function() decline(widget) end
  }
  children[#children+1] = {
    type = "label", x=panelX + padding, y=labelY, w=btnW,
    text=cancelLabel, color=WHITE, align=CENTER, font=titleFont
  }

  -- The action, on the right, in the warning colour: the one the pilot has to mean.
  local confirmLabel = spec.confirmLabel
  if type(confirmLabel) ~= "string" or confirmLabel == "" then confirmLabel = "OK" end
  local cx = panelX + padding + btnW + gap
  children[#children+1] = {
    type = "button", x=cx, y=by, w=btnW, h=btnH, color=danger_color,
    press = function() agree(widget, question and question.work) end
  }
  children[#children+1] = {
    type = "label", x=cx, y=labelY, w=btnW,
    text=confirmLabel, color=WHITE, align=CENTER, font=titleFont
  }
end

return M
