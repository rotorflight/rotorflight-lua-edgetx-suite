-- Compact illustrated tasks use a drawing beside the controls. Large displays
-- have a separate instruction column. The scene is published four objects per pass.
local M = {}
function M.new(w, ctx, diagrams)
  local palette = w.palette
  local function label(x, y, width, text, font)
    return { type = "label", x = x, y = y, w = width, text = text, font = font or SMLSIZE, color = palette.text }
  end
  local width, height = ctx.w, ctx.h
  local large = width >= 700
  w.refreshPulse=nil
  if w.attitudeView then w.attitudeView.valid=false;w.attitudeView=nil end
  local card = w.cards and w.cards[w.card]
  local attitudeCard=card and card.art=="attitude"
  local compact = width < 400 and {
    [w.L.directionCorrect]=w.L.shortCorrect,
    [w.L.servosUnplugged]=w.L.shortUnplugged,[w.L.cyclicServos]=w.L.shortCyclicServos,
    [w.L.swashType]=w.L.shortSwash, [w.L.rotorDirection]=w.L.shortRotation,
    [w.L.measuredDegrees]=w.L.shortMeasured, [w.L.ratePercent]=w.L.shortRate,
    [w.L.centreOffset]=w.L.shortOffset, [w.L.armCentred]=w.L.shortArm,
    [w.L.servo1Trim]=w.L.shortTrim1, [w.L.servo2Trim]=w.L.shortTrim2, [w.L.servo3Trim]=w.L.shortTrim3
  } or {}
  local controlH = large and 44 or width >= 480 and 32 or 26
  -- `lcd.sizeText(text, flags)` answers for the font a label is drawn in; the estimate is only
  -- for a build that does not offer the call.
  local measured = lcd ~= nil and type(lcd.sizeText) == "function"
  local function textWidth(text, font)
    text = tostring(text or "")
    local fn = lcd and lcd.sizeText
    if type(fn) == "function" then
      local ok, tw = pcall(fn, text, font)
      tw = tonumber(tw)
      if ok and tw then return tw end
    end
    return math.floor(#text * (font == MIDSIZE and (large and 14 or 10) or (large and 10 or 7.5)) + 0.5)
  end
  -- A card's explanation runs across the full width at the top; the rows start below it. It takes the lines it needs, two at least and three at most, the third
  -- only where the rows still fit above the status line; the ? sheet carries the whole text.
  -- The servo grid and the attitude view lay out their own.
  local cardScene = card and not w.overview and not w.confirmExit and not w.error and not w.historyFailure
    and not w.disconnectExit and not w.stepMenu
  local summaryText = cardScene and not card.servo and not attitudeCard and (card.summary or card.detail) or nil
  if summaryText == "" then summaryText = nil end
  -- Below the header band and the ? button (controlH high from y 2).
  local textY = large and 56 or controlH+6
  local lineH = large and 24 or height <= 272 and 17 or 18
  local textLines = 2
  if summaryText and type(summaryText) == "string" then
    -- A wrapped line breaks at a word, so a line holds a little less than its width.
    local need = math.ceil(textWidth(summaryText, SMLSIZE) * 1.15 / (width - 20))
    local rowsBelow = card.rows and #card.rows or 0
    local bottom = height-controlH-(large and 40 or 27)
    local rowNeed = large and 52 or controlH+6
    if need >= 3 and textY+3*lineH+(large and 14 or 8)+rowsBelow*rowNeed <= bottom then textLines = 3 end
  end
  local textH = summaryText and textLines*lineH or 0
  local textEnd = textY + textH + (large and 4 or 2)
  local rowY = cardScene and (summaryText and textEnd + (large and 10 or 6) or textY) or
    (large and 108 or height <= 272 and 80 or 88)
  local rowH = large and 52 or math.min(controlH+6, math.floor((height-2*controlH-31-rowY)/3))
  if card and card.link=="overview" and not large then
    rowH=math.min(rowH,math.floor((height-2*controlH-31-rowY)/4))
  end
  -- Row slots: below the large layout, tiles go two to a slot.
  local slotOf, slots, tileCol = {}, 0, 0
  for i, r in ipairs(card and card.rows or {}) do
    if r.kind == "tile" and not large then
      if tileCol == 0 then slots = slots + 1 end
      slotOf[i], tileCol = { slots, tileCol }, (tileCol + 1) % 2
    else
      slots, tileCol = slots + 1, 0
      slotOf[i] = { slots }
    end
  end
  -- A dense card fits all of its rows above the status line; its value rows shrink to the font.
  if card and card.dense and slots>0 then
    rowH=math.min(rowH,math.max(18,math.floor((height-controlH-(large and 40 or 27)-2-rowY)/slots)))
  end
  local rowControlH = controlH
  -- Only opted-in cards on medium displays compress their rows and controls.
  local fitRows = card and card.fitRows and width >= 480 and not large
  if fitRows and card.rows and #card.rows > 0 then
    rowH=math.min(rowH,math.floor((height-controlH-27-2-rowY)/#card.rows))
    rowControlH=math.min(controlH,rowH-2)
  end
  local all = {}
  -- The header says where the pilot is: the step, then the card's own name and its place.
  -- Preparation cards are no step's card, so they name the wizard instead.
  local stepCard = cardScene and not (w.historyMode or w.modelPreparationCard or w.recoveryCard)
  local headStep = w.historyMode and w.L.historyTitle or (not stepCard or w.overview) and w.L.name
    or w.L.steps[w.step] or w.L.name
  -- A card named like its step shows only its place, so no name stands twice.
  local headCard = cardScene and card.title or nil
  local counted = headCard and stepCard and not w.preparationCard and #w.cards > 1
  if headCard == headStep then headCard = counted and string.format(w.L.cardCount, w.card, #w.cards) or nil
  elseif counted then headCard = string.format(w.L.cardPlace, headCard, w.card, #w.cards) end
  all[#all + 1] = { type = "rectangle", x = 0, y = 0, w = width, h = height, filled = true, color = palette.page }
  if card then
    local cardY = large and 50 or 27
    all[#all + 1] = { type = "rectangle", x = 6, y = cardY, w = width-12,
      h = height-controlH-(large and 40 or 27)-cardY, filled = true, color = palette.card }
  end
  local function button(x, y, bw, text, press, active, kind, release)
    all[#all + 1] = { type = kind or "button", x = x, y = y, w = bw, h = controlH, text = text,
      press = press, release = release, active = active, color = palette.card, textColor = palette.text }
  end
  -- Back is deliberately first in focus order.
  button(8, height-controlH-6, math.floor(width * 0.22), w.L.back, function() w:back() end,
    function() return not w.transition end)
  local exitOffered = not w.historyMode and not w.overview and not w.confirmExit and w.requestSteps
  if exitOffered then
    local exitW = large and 160 or 100
    button(math.floor((width-exitW)/2), height-controlH-6, exitW, w.L.exit, function() w:requestSteps() end,
      function() return w.canEdit == true end)
  end
  local headH, headFont = large and 44 or 24, large and MIDSIZE or SMLSIZE
  local headRight = width-controlH-12
  -- A step's card opens the step menu from its header; the labels above the button take no taps.
  local menuHeader = stepCard and not w.preparationCard and w.openStepMenu ~= nil
  if menuHeader then
    button(8, 2, headRight-8, "", function() w:openStepMenu() end, function() return w.canEdit == true end)
    all[#all].h, all[#all].textColor = headH, palette.accentInk
  end
  local counter = menuHeader and string.format(w.L.stepCounter, w.step) or nil
  local chevronW = menuHeader and (large and 12 or 9) or 0
  local nameX = menuHeader and 18 or 10
  local chevronX = headRight-10-chevronW
  local function fits(stepFont, withCounter, cardText)
    local right = chevronX-(chevronW > 0 and 6 or 0)-(withCounter and counter and textWidth(counter, SMLSIZE) or 0)
    local used = nameX+textWidth(headStep, stepFont)
    if cardText then used = used+(large and 22 or 15)+textWidth(cardText, SMLSIZE) end
    return used+8 <= right
  end
  if measured and headCard then
    local count = stepCard and #w.cards > 1 and string.format(w.L.cardCount, w.card, #w.cards) or nil
    if not fits(headFont, true, headCard) then
      if large and fits(SMLSIZE, true, headCard) then headFont = SMLSIZE
      elseif fits(headFont, false, headCard) then counter = nil
      elseif large and fits(SMLSIZE, false, headCard) then headFont, counter = SMLSIZE, nil
      elseif count and fits(headFont, true, count) then headCard = count
      elseif count then headCard, counter = count, nil end
    end
  end
  local counterW = counter and textWidth(counter, SMLSIZE) or 0
  local counterX = chevronX-(chevronW > 0 and 6 or 0)-counterW
  local nameW = math.min(textWidth(headStep, headFont), (counter and counterX or headRight)-8-nameX)
  all[#all + 1] = label(nameX, large and 7 or 3, nameW, headStep, headFont)
  all[#all].h, all[#all].color = large and 32 or 20, menuHeader and palette.accentInk or palette.text
  if headCard then
    -- The step and the card are parted by a drawn chevron: the radio's fonts carry no arrow glyph.
    local sepX = nameX+nameW+(large and 8 or 5)
    local cardX = sepX+(large and 14 or 10)
    local room = (counter and counterX or headRight)-8-cardX
    local text = headCard
    if room > 20 then
      local cy, s = 2+math.floor(headH/2), large and 5 or 4
      all[#all + 1] = { type = "line", pts = {{sepX, cy-s}, {sepX+s, cy}}, color = palette.muted, thickness = 2 }
      all[#all + 1] = { type = "line", pts = {{sepX+s, cy}, {sepX, cy+s}}, color = palette.muted, thickness = 2 }
      all[#all + 1] = label(cardX, large and 13 or 4, room, text)
      all[#all].h, all[#all].color = large and 24 or 18, palette.muted
    end
  end
  if counter then
    all[#all + 1] = label(counterX, large and 13 or 4, counterW+8, counter)
    all[#all].h, all[#all].color = large and 24 or 18, palette.muted
  end
  if menuHeader then
    local cx, cy, s = chevronX, 2+math.floor(headH/2), math.floor(chevronW/2)
    all[#all + 1] = { type = "line", pts = {{cx, cy-math.floor(s/2)}, {cx+s, cy+math.floor(s/2)+1}},
      color = palette.accentInk, thickness = 2 }
    all[#all + 1] = { type = "line", pts = {{cx+s, cy+math.floor(s/2)+1}, {cx+2*s, cy-math.floor(s/2)}},
      color = palette.accentInk, thickness = 2 }
  end
  button(width-controlH-6, 2, controlH, "?", function()
    local current = w.cards and w.cards[w.card]
    local detail = w.overview and w.L.stepMenuHint or current and current.detail
    local focused = w.modelPreparationCard or w.historyMode
    local message = detail and (focused and detail or detail.."\n\n"..w.L.help) or w.L.help
    if w.trialDetails then message=message.."\n"..w.trialDetails end
    if not focused and w.historyHint then message=message.."\n\n"..w.historyHint end
    if not focused and w.prerequisiteDetails then message=message.."\n\n"..w.prerequisiteDetails end
    if w.openHelp then w.openHelp(message, w.L.name) end
  end)
  if w.disconnectExit then
    all[#all+1]=label(12,48,width-24,w.L.disconnectedExitHint);all[#all].h=100;all[#all].color=palette.warning
    button(12,160,width-24,w.L.powerOffLeave,function() w:leaveDisconnected() end)
  elseif w.confirmExit then
    local leavingStep=w.exitToSteps or w.backTarget or w.jumpTarget
    all[#all + 1] = label(12, 48, width-24, leavingStep and w.L.leaveStepHint or w.L.exitHint)
    button(12, 100, math.floor(width/2)-18, leavingStep and w.L.saveChanges or w.L.saveExit,
      function() if w.resolveExit then w:resolveExit(true) else w:save(function() w:close() end) end end)
    button(math.floor(width/2)+6, 100, math.floor(width/2)-18, leavingStep and w.L.discardChanges or w.L.discardExit,
      function() if w.resolveExit then w:resolveExit(false) else w:discard() end end)
  elseif w.error then
    all[#all + 1] = label(12, 48, width-24, w.statusFailure and w.L.statusUnavailable or next(w.dirty) and w.L.failed or w.L.failedClean)
    all[#all].h=36;all[#all].color=palette.error
    all[#all + 1] = label(12, 88, width-24, w.errorText and w:errorText() or w.error)
    all[#all].color=palette.error
    if w.statusFailure then
      all[#all+1]=label(12,116,width-24,w.L.statusWaitHint);all[#all].h=50
    end
    button(12, w.statusFailure and 172 or 132, width-24, w.L.retry, function() w:retry() end)
  elseif w.historyFailure then
    all[#all+1]=label(12,48,width-24,w.L.historySaveFailed)
    all[#all].color=palette.warning
    button(12,100,width-24,w.L.retry,function() w.historyRetry() end)
    button(12,100+rowH,width-24,w.historyAllowSkip and w.L.historyContinue or w.L.back,function() w.historySkip() end)
  elseif w.stepMenu and card then
    -- The step menu: every step as a button, the current one in the accent colour, a done step
    -- with a mark in the ok colour. Back returns to the card it was opened from.
    local hint = large or height > 272
    if hint then
      all[#all + 1] = label(10, textY, width-20, w.L.stepMenuOpen)
      all[#all].h, all[#all].color = large and 28 or 18, palette.muted
    end
    local cols, rows = 3, 7
    local top = hint and textY+(large and 34 or 20) or textY
    local bottom = height-controlH-(large and 40 or 27)-4
    local gap = large and 6 or 2
    local margin = large and 10 or 6
    local bh = math.min(controlH, math.floor((bottom-top)/rows)-gap)
    -- Each column is as wide as its longest step name and the button's own padding; what is left
    -- of the width is shared out, so a long name in one column does not cramp the others.
    local names = large and w.L.numberedSteps or w.L.steps
    local colW, used = {}, 0
    for c = 1, cols do
      local most = 0
      for index = c, 19, cols do most = math.max(most, textWidth(names[index], SMLSIZE)) end
      colW[c] = most + (large and 20 or 16); used = used + colW[c]
    end
    local spare = math.floor((width-2*margin-(cols-1)*gap-used)/cols)
    local colX = { margin }
    for c = 1, cols do
      colW[c] = math.max(1, colW[c]+spare)
      colX[c+1] = colX[c]+colW[c]+gap
    end
    local mask = w.history and w.history.mask or 0
    for index = 1, 19 do
      local col, row = (index-1) % cols, math.floor((index-1)/cols)
      local x, y, bw = colX[col+1], top+row*(bh+gap), colW[col+1]
      local target = index
      button(x, y, bw, names[index], function() w:jumpToStep(target) end,
        function() return w.canEdit == true end)
      all[#all].h, all[#all].font = bh, SMLSIZE
      if index == w.step then all[#all].color, all[#all].textColor = palette.accent, palette.onAccent end
      if (mask & (1 << (index-1))) ~= 0 then
        local d = large and 8 or 6
        all[#all + 1] = { type = "rectangle", x = x+4, y = y+math.floor((bh-d)/2), w = d, h = d,
          filled = true, color = index == w.step and palette.onAccent or palette.ok }
      end
    end
  elseif w.overview then
    all[#all + 1] = label(10, large and 55 or 30, width-20, w.L.chooseStep, large and MIDSIZE or SMLSIZE)
    all[#all + 1] = label(10, large and 94 or 48, large and math.floor(width*0.4)-24 or width-20, w.L.stepMenuHint)
    all[#all].color=palette.muted
    if not large then all[#all].h = rowY-52 end
    local x = large and math.floor(width*0.43) or 10
    local bw = width-x-10
    all[#all+1] = { type="choice",x=x,y=rowY,w=bw,h=controlH,title=w.L.chooseStep,
      values=w.L.numberedSteps,get=function() return w.selectedStep end,
      set=function(v) w:applyEdit(function() if not w.overview or v<1 or v>19 then return end w.selectedStep=v end) end,
      active=function() return w.canEdit == true end }
    button(x,rowY+rowH,bw,w.L.startStep,function() w:startStep(w.selectedStep) end,
      function() return w.canEdit == true end)
    button(x,rowY+2*rowH,bw,w.L.completeSetup,function() w:startStep(1,true) end,
      function() return w.canEdit == true end)
    button(x,rowY+3*rowH,bw,w.L.saveReboot,function() if w:usable() then w:reboot() end end,
      function() return w.canEdit == true and w.rebootPending == true end)
    all[#all].visible=function() return w.rebootPending == true end
  elseif card then
    -- Native LVGL keeps sweeping this tree while its replacement is staged.
    -- Navigation clears w.cards before the next scene can be published.
    local cards, cardIndex, step = w.cards, w.card, w.step
    local finalCard = cardIndex == #cards
    local simpleNext = w.modelPreparationCard or w.preparationCard or w.recoveryCard
    local restartNext = w.entryRebootGate
    local function current()
      return w.cards == cards and w.card == cardIndex and not w.confirmExit and not w.overview
        and not w.historyFailure and not w.error and not w.disconnectExit and not w.stepMenu
    end
    local illustrated = card.art ~= nil
    local formX = illustrated and math.floor(width * (large and 0.43 or 0.35))+(large and 0 or 4) or 10
    if attitudeCard then formX=large and math.floor(width*.64) or 10;rowY=large and 166 or height-3*controlH-10 end
    local formW = width-formX-(large and 16 or 10)
    -- The status line's top: everything a card draws ends above it.
    local cardBottom = height-controlH-(large and 40 or 27)
    -- Without a picture the controls follow right after a label column, leaving space on the
    -- right; beside a picture they keep to the form column's right edge.
    local labelW = not illustrated and not attitudeCard and (large and 280 or math.floor(formW*0.36)) or nil
    -- Overview cards (blocks, a table, bars) draw across the full width below the summary.
    local overviewY = rowY
    if card.dense and slots > 0 then
      rowH = math.min(rowH, math.max(18, math.floor((cardBottom-2-rowY)/slots)))
      rowControlH = math.min(rowControlH, rowH-2)
    end
    -- Rows may sit at the foot of the card, under a full-width overview.
    if card.rowsAtFoot then rowY = cardBottom-2-slots*rowH end
    if attitudeCard then
      all[#all+1]=label(10,textY,width-20,w.L.orientationModelHint)
      all[#all].h=large and 32 or 23;all[#all].color=palette.muted
      diagrams.append(all,w,card,10,large and 108 or textY+26,
        large and formX-26 or width-20,large and height-controlH-168 or rowY-textY-38)
    else
    -- The card's name is in the header; its explanation leads the card across the full width.
    local badgeW = 0
    if card.badge then
      -- A short tag such as Required, at the right end of the text band.
      local bw = (large and 10 or 7)*#card.badge+(large and 20 or 12)
      local bh = large and 30 or 18
      badgeW = bw+10
      all[#all+1] = { type = "rectangle", x = width-bw-12, y = textY, w = bw, h = bh,
        filled = true, color = palette.warning }
      all[#all+1] = label(width-bw-12+(large and 10 or 6), textY+1, bw-(large and 12 or 8), card.badge)
      all[#all].h, all[#all].color = bh-2, palette.onAccent
    end
    if summaryText then
      all[#all + 1] = label(10, textY, width-20-badgeW, summaryText)
      all[#all].h = textH
      all[#all].color = palette.muted
      -- A card may lead with a warning or a live prompt instead of a muted summary.
      if card.summaryColor then all[#all].color = palette[card.summaryColor] or all[#all].color end
      if card.summaryBold and height > 272 then all[#all].font = BOLD end
    end
    if illustrated and not card.servo then
      if card.instructions and width<400 then
        -- The picture shares the title band so all three instructions fit below it.
        diagrams.append(all, w, card, width-76, 27, 66, 48)
      else
        local artY = rowY + (large and 0 or 2)
        local artH = cardBottom-(large and 6 or 8)-artY
        -- A caption under the picture carries the values the picture stands for.
        if card.caption then
          local lines = card.captionLines or (large and 3 or 1)
          local lineH = large and 24 or 16
          artH = artH-lines*lineH
          all[#all+1] = label(10, artY+artH+2, formX-20, lines > 1 and card.caption or card.captionShort or card.caption)
          all[#all].h, all[#all].color = lines*lineH, palette.muted
        end
        diagrams.append(all, w, card, 6, artY, formX-18, artH)
        -- The controls sit in line with the picture: their block is centred on its frame.
        if not (card.blocks or card.table or card.bars or card.rowsAtFoot or card.dense or card.instructions) then
          local blockH = slots*rowH
          if blockH < artH then rowY = artY + math.floor((artH-blockH)/2) end
        end
      end
    end
    end
    if card.blocks then
      -- One framed block per item, side by side, each a title and live lines below it.
      local n, gap = #card.blocks, 8
      local bw = math.floor((width-20-(n-1)*gap)/math.max(1,n))
      local lineH = large and 30 or height <= 272 and 16 or 18
      local bh = math.min(cardBottom-4-overviewY, (#card.blocks[1].lines+1)*lineH+12)
      for i, block in ipairs(card.blocks) do
        local x = 10+(i-1)*(bw+gap)
        all[#all+1] = { type = "rectangle", x = x, y = overviewY, w = bw, h = bh, color = palette.rule, thickness = 2 }
        all[#all+1] = label(x+6, overviewY+4, bw-12, block.title, large and MIDSIZE or SMLSIZE)
        all[#all].h = lineH
        for j, line in ipairs(block.lines) do
          all[#all+1] = label(x+6, overviewY+4+j*lineH, bw-12, line)
          all[#all].h = lineH
          if block.colors and block.colors[j] then
            local role = block.colors[j]
            all[#all].color = function() return palette[role()] or palette.text end
          end
        end
      end
    end
    if card.table then
      -- A grid: a header row, then one row per quantity with a cell per column.
      local t = card.table
      local cols = #t.columns
      local firstW = math.floor((width-20)*(large and 0.22 or 0.26))
      local cw = math.floor((width-20-firstW)/math.max(1,cols))
      local lineH = math.min(large and 40 or 24, math.floor((cardBottom-2-overviewY)/(#t.rows+1)))
      local y = overviewY
      for c, head in ipairs(t.columns) do
        all[#all+1] = label(10+firstW+(c-1)*cw, y, cw-6, head)
        all[#all].h, all[#all].color = lineH-4, palette.muted
      end
      for _, row in ipairs(t.rows) do
        y = y+lineH
        all[#all+1] = { type = "rectangle", x = 10, y = y-3, w = width-20, h = 1, filled = true, color = palette.rule }
        all[#all+1] = label(10, y, firstW-6, row.label)
        all[#all].h = lineH-4
        for c, cell in ipairs(row.cells) do
          all[#all+1] = label(10+firstW+(c-1)*cw, y, cw-6, cell)
          all[#all].h = lineH-4
        end
      end
      if t.legend and y+lineH+lineH <= cardBottom then
        all[#all+1] = label(10, y+lineH, width-20, t.legend)
        all[#all].h, all[#all].color = math.min(2*lineH, cardBottom-y-lineH-2), palette.muted
      end
    end
    if card.bars then
      -- One live bar per control: name, the two directions at the ends, the reading in percent.
      local n = #card.bars
      local top, bottom = overviewY, rowY-4
      local lineH = math.max(14, math.floor((bottom-top)/math.max(1,n)))
      local nameW = math.floor(width*(large and 0.2 or 0.24))
      local wordW = math.floor(width*(large and 0.12 or 0.14))
      local pctW = math.floor(width*(large and 0.09 or 0.12))
      local barX = 10+nameW+wordW
      local barW = width-20-nameW-2*wordW-pctW
      for i, bar in ipairs(card.bars) do
        local y = top+(i-1)*lineH
        local mid = y+math.floor(lineH/2)
        all[#all+1] = label(10, y, nameW-4, bar.name)
        all[#all].h = lineH-2
        all[#all+1] = label(10+nameW, y, wordW-4, bar.left)
        all[#all].h, all[#all].color = lineH-2, palette.muted
        all[#all+1] = { type = "line", pts = {{barX,mid},{barX+barW-1,mid}}, color = palette.rule, thickness = 2 }
        local centre = barX+math.floor(barW/2)
        all[#all+1] = { type = "line", pts = {{centre,mid-4},{centre,mid+4}}, color = palette.muted, thickness = 2 }
        -- The marker's points are rewritten in place and only when the reading moves.
        local pts, last = {{centre,mid-7},{centre,mid+7}}, nil
        all[#all+1] = { type = "line", color = palette.accent, thickness = 4, pts = function()
          local value = bar.value()
          value = value and math.max(-1, math.min(1, value)) or 0
          if value ~= last then
            local x = barX+math.floor((barW-1)*(value+1)/2+0.5)
            pts[1][1], pts[2][1], last = x, x, value
          end
          return pts
        end }
        all[#all+1] = label(barX+barW+6, y, wordW-4, bar.right)
        all[#all].h, all[#all].color = lineH-2, palette.muted
        all[#all+1] = label(width-10-pctW, y, pctW, bar.percent)
        all[#all].h = lineH-2
        all[#all].color = function() return bar.done() and palette.accentInk or palette.text end
      end
    end
    if card.instructions then
      local instructionY = width<400 and 82 or rowY
      all[#all+1] = label(width<400 and 10 or formX, instructionY, width<400 and width-20 or formW, card.instructions)
      all[#all].h = height-controlH-(large and 40 or 27)-instructionY
    end
    if card.servo then w.newServoCard(all, w, card, width, height, large, current, diagrams) end
    for i, r in ipairs(card.rows) do
      local y = rowY + (slotOf[i][1]-1)*rowH
      local function editable() return current() and (not r.enabled or r.enabled()) end
      local function enabled() return w.canEdit == true and editable() end
      if r.kind == "notice" then
        all[#all+1]=label(formX,y+3,formW,r.get)
        all[#all].h=math.min(rowControlH,rowH-3)
        all[#all].visible=function() return r.get()~="" end
      elseif r.kind == "tile" then
        -- One of several choices drawn as full-width tiles: the chosen one in the accent colour.
        -- Two buttons per tile, one shown at a time, so no native colour has to change live.
        local function press()
          if enabled() and w:usable() then w:applyEdit(function() if editable() then r.press() end end) end
        end
        local tileX, tileW = formX, formW
        if not large then
          tileW = math.floor((formW-4)/2)
          tileX = formX + slotOf[i][2]*(tileW+4)
        end
        for _, chosen in ipairs({ false, true }) do
          button(tileX, y, tileW, r.label, press, enabled)
          all[#all].h = rowControlH
          if chosen then all[#all].color, all[#all].textColor = palette.accent, palette.onAccent end
          all[#all].visible = function() return (r.selected() == true) == chosen end
        end
      elseif r.kind == "button" or r.kind == "hold" then
        -- An action button is as wide as its label; a label that changes keeps a fixed width.
        local bw = formW
        if type(r.label) == "string" then
          bw = math.max(2*controlH, math.min(formW, textWidth(r.label, SMLSIZE)+(large and 48 or 28)))
        else
          bw = math.min(formW, large and 320 or 220)
        end
        button(formX, y, bw, r.label, function() if enabled() and w:usable() then r.press() end end, enabled,
          r.kind == "hold" and "momentaryButton" or "button", r.release)
        all[#all].h=rowControlH
      else
        local editW = large and 190 or math.floor(formW * 0.48)
        local editX = formX+formW-editW
        local textW = formW-editW-8
        if labelW and not r.fullWidth then
          editW = large and 270 or math.min(formW-labelW, 190)
          editX, textW = formX+labelW, labelW-8
        end
        if attitudeCard and large then
          all[#all+1]=label(formX,y-34,formW,r.label)
          editW, editX = formW, formX
        elseif r.fullWidth then
          editW, editX = formW, formX
        else
        all[#all + 1] = label(formX, y+3, textW, illustrated and compact[r.label] or r.label)
        end
        -- A plain yes/no or off/on answer is a switch. A choice that can be unknown (not read yet,
        -- or servos of one group that disagree) keeps its list while it is, so no answer is implied.
        local values = r.values
        local yesNo = type(values) == "table" and #values == 2 and
          ((values[1] == w.L.no and values[2] == w.L.yes) or (values[1] == w.L.off and values[2] == w.L.on))
        local switch = yesNo and (r.kind == "toggle" or (r.kind == "choice" and not (r.allowUnset and r.get() == 0)))
        if r.kind == "value" then
          all[#all + 1] = label(editX, y+3, editW, function() return tostring(r.get() or "--") end)
          all[#all].h=(card.link=="overview" or card.dense or fitRows) and math.min(rowControlH,rowH-3) or rowControlH
          -- A value row may name a palette role for its live state, e.g. a switch that is on.
          if r.color then all[#all].color=function() return palette[r.color()] or palette.text end end
        elseif switch then
          local sw, sh = large and 72 or 56, math.min(rowControlH, large and 36 or 28)
          all[#all + 1] = { type = "toggle", x = editX, y = y+math.floor((rowControlH-sh)/2), w = sw, h = sh,
            get = function() return r.get() == 2 end,
            set = function(v)
              -- Some EdgeTX builds call set() without a payload: that is a flip.
              local on
              if v == nil then on = r.get() ~= 2
              elseif type(v) == "boolean" then on = v
              else on = (tonumber(v) or 0) ~= 0 end
              if on == (r.get() == 2) then return end
              if w.logTrace then w:log("trace", "switch %s %s", tostring(r.label), tostring(on)) end
              w:applyEdit(function() if editable() then r.set(on and 2 or 1) end end)
            end, active = enabled }
        elseif r.kind == "toggle" then
          local function set(v) w:applyEdit(function() if editable() then r.set(v) end end) end
          all[#all + 1] = { type = "button", x = editX, y = y, w = editW, h = rowControlH,
            text = function() return r.values[r.get()] end, color = palette.card, textColor = palette.text,
            press = function() if enabled() then set(r.get() == 2 and 1 or 2) end end, active = enabled }
        elseif r.kind == "choice" then
          local values, get = r.values, r.get
          -- Native choices need a one-based index: an unanswered question gets a neutral first
          -- entry, only while nothing is chosen, so a set list keeps its own order.
          local unset = r.allowUnset and r.get() == 0
          local offset = unset and 1 or 0
          if unset then
            values = { w.L.notSet }
            for _, value in ipairs(r.values) do values[#values+1] = value end
            get = function() return r.get() + 1 end
          end
          all[#all + 1] = { type = "choice", x = editX, y = y, w = editW, h = rowControlH,
            title = r.label, values = values, get = get,
            set = function(v)
              if v <= offset or not values[v] then return end
              w:applyEdit(function()
                if not editable() then return end
                r.set(v - offset)
                if unset and yesNo then w.buildRequested = true; w:rebuild() end
              end)
            end, active = enabled }
        elseif r.kind == "text" then
          all[#all + 1] = { type = "textEdit", x = editX, y = y, w = editW, h = rowControlH,
            value = r.get(), length = r.length or 16, active = enabled,
            set = function(v) w:applyEdit(function() if editable() then r.set(v) end end) end }
        else
          local function numberField(x, fieldW, field)
            local pendingEdit, pendingValue
            local function get()
              if pendingEdit and w.pendingEdit == pendingEdit and editable() then return pendingValue end
              return field.get()
            end
            local function set(v)
              pendingEdit = function() if editable() then field.set(v) end end
              pendingValue = v
              w:applyEdit(pendingEdit)
            end
            -- update() reads get() when the native editor closes, before a queued
            -- STATUS reply can authorize the final value. Keep that draft visible.
            all[#all + 1] = { type = "numberEdit", x = x, y = y, w = fieldW, h = rowControlH,
              min = r.min, max = r.max, get = get, set = set,
              display = function(v)
                if r.display then return r.display(v) end
                if r.divisor then return string.format("%.1f", v / r.divisor) end
                return tostring(v)
              end, active = enabled }
          end
          if r.kind == "holdNumber" then
            -- A hold button and the angle it holds, side by side in one row.
            local half = math.floor((formW - 8) / 2)
            button(formX, y, half, r.holdLabel, function() if enabled() and w:usable() then r.press() end end, enabled)
            all[#all].h = rowControlH
            numberField(formX + half + 8, formW - half - 8, r)
          elseif r.kind == "pair" then
            -- Two counts of one gear pair side by side, "a : b".
            local half = math.floor((editW - 12) / 2)
            numberField(editX, half, r.left)
            all[#all + 1] = label(editX+half, y+3, 12, ":")
            numberField(editX+editW-half, half, r.right)
          else
            numberField(editX, editW, r)
          end
        end
      end
    end
    -- The last card of a step moves on to the next step, saving what changed; the last step
    -- finishes. From Connect servos on, a pending restart comes first and the button says so.
    local function nextText()
      return simpleNext and w.L.continue or restartNext and w.L.reboot or w.trial and w.trial.success and w.L.saveReboot
        or finalCard and step >= 10 and w.rebootPending and w.L.reboot
        or finalCard and step == 19 and w.L.finish or finalCard and w.L.nextStep or w.L.continue
    end
    if not w.historyMode then
    local nextW = math.floor(width*0.30)
    button(width-nextW-8, height-controlH-6, nextW, nextText,
      function() if current() then w:next() end end, function() return w.canNext == true and current() end)
    all[#all].color, all[#all].textColor = palette.accent, palette.onAccent
    end
  end
  all[#all + 1] = label(10, height-controlH-(large and 40 or 27), width-20,
    function() return w.feedbackText and w:feedbackText() or w.legacyHold and w.L.persistent or w.message or "" end)
  all[#all].color = palette.muted
  local job = { all = all, children = {}, index = 1 }
  function job:step()
    for _ = 1, 4 do
      local item = self.all[self.index]
      if not item then self.done = true; return true end
      self.children[#self.children + 1] = item; self.index = self.index + 1
    end
    return false
  end
  return job
end
return M
