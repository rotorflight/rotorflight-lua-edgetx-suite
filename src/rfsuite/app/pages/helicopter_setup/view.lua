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
  local rowY = large and 108 or height <= 272 and 76 or 88
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
  local title = w.historyMode and w.L.historyTitle or (w.overview or w.modelPreparationCard or w.recoveryCard) and w.L.name or string.format("%d/19  %s", w.step, w.L.steps[w.step] or w.L.name)
  if attitudeCard and not (w.historyMode or w.overview or w.confirmExit or w.modelPreparationCard or w.recoveryCard) then
    title=string.format("%d/19  %s",w.step,card.title)
  end
  all[#all + 1] = { type = "rectangle", x = 0, y = 0, w = width, h = height, filled = true, color = palette.background }
  if card then
    local cardY = large and 50 or 27
    all[#all + 1] = { type = "rectangle", x = 6, y = cardY, w = width-12,
      h = height-controlH-(large and 40 or 27)-cardY, filled = true, color = palette.card }
  end
  if w.historyMode or w.overview or w.confirmExit or not w.requestSteps then
    all[#all + 1] = label(10, 4, width - 54, title, large and MIDSIZE or SMLSIZE)
  end
  local function button(x, y, bw, text, press, active, kind, release)
    all[#all + 1] = { type = kind or "button", x = x, y = y, w = bw, h = controlH, text = text,
      press = press, release = release, active = active, color = palette.card, textColor = palette.text }
  end
  -- Back is deliberately first in focus order.
  button(8, height-controlH-6, math.floor(width * 0.25), w.L.back, function() w:back() end,
    function() return not w.transition end)
  if not w.historyMode and not w.overview and not w.confirmExit and w.requestSteps then
    -- Leaving is a visible button of its own; the title still does the same.
    local exitW = large and 120 or 76
    button(8, 2, width-controlH-exitW-26, title, function() w:requestSteps() end,
      function() return w.canEdit == true end)
    all[#all].h, all[#all].font = large and 44 or 24, large and MIDSIZE or SMLSIZE
    all[#all].textColor = palette.accent
    button(width-controlH-exitW-12, 2, exitW, w.L.exit, function() w:requestSteps() end,
      function() return w.canEdit == true end)
    all[#all].h, all[#all].textColor = large and 44 or 24, palette.accent
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
    local leavingStep=w.exitToSteps or w.backTarget
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
        and not w.historyFailure and not w.error and not w.disconnectExit
    end
    local illustrated = card.art ~= nil
    local formX = large and math.floor(width * 0.43) or illustrated and math.floor(width * 0.35)+4 or 10
    if attitudeCard then formX=large and math.floor(width*.64) or 10;rowY=large and 166 or height-3*controlH-10 end
    local formW = width-formX-(large and 16 or 10)
    -- The status line's top: everything a card draws ends above it.
    local cardBottom = height-controlH-(large and 40 or 27)
    -- A wide-text card gives its summary the full width on large screens; picture and controls
    -- move down below it. Smaller screens already run the summary across the full width.
    local wideText = card.wideText and large
    if wideText then rowY = 156 end
    -- Overview cards (blocks, a table, bars) draw across the full width below the summary.
    local overviewY = rowY
    if card.dense and slots > 0 then
      rowH = math.min(rowH, math.max(18, math.floor((cardBottom-2-rowY)/slots)))
      rowControlH = math.min(rowControlH, rowH-2)
    end
    -- Rows may sit at the foot of the card, under a full-width overview.
    if card.rowsAtFoot then rowY = cardBottom-2-slots*rowH end
    if attitudeCard then
      all[#all+1]=label(10,large and 58 or 30,width-20,w.L.orientationModelHint)
      all[#all].h=large and 32 or 23;all[#all].color=palette.muted
      diagrams.append(all,w,card,10,large and 108 or 56,
        large and formX-26 or width-20,large and height-controlH-168 or rowY-68)
    else
    -- The title sits above the form rows, so on large screens it takes the full width instead of
    -- wrapping into the summary below it.
    all[#all + 1] = label(10, large and 50 or 27, width-20, card.title, large and MIDSIZE or SMLSIZE)
    if card.badge then
      -- A short tag such as Required, at the right end of the title band.
      local bw = (large and 10 or 7)*#card.badge+(large and 20 or 12)
      local bh = large and 30 or 18
      all[#all+1] = { type = "rectangle", x = width-bw-12, y = large and 54 or 28, w = bw, h = bh,
        filled = true, color = palette.warning }
      all[#all+1] = label(width-bw-12+(large and 10 or 6), large and 56 or 28, bw-(large and 12 or 8), card.badge)
      all[#all].h, all[#all].color = bh-2, palette.accentText
      all[#all-2].w = width-bw-34
    end
    if not card.servo and not (card.instructions and width<400) then
    all[#all + 1] = label(10, large and 94 or 48, large and not wideText and formX-30 or width-20, card.summary or card.detail)
    all[#all].h = wideText and rowY-100 or large and (illustrated and 98 or height-controlH-154) or rowY-52
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
        local artY = wideText and rowY or large and 204 or rowY+4
        local artH = wideText and cardBottom-6-artY or large and 174 or height-controlH-35-artY
        -- A caption under the picture carries the values the picture stands for.
        if card.caption then
          local lines = card.captionLines or (large and 3 or 1)
          local lineH = large and 24 or 16
          artH = artH-lines*lineH
          all[#all+1] = label(10, artY+artH+2, formX-20, lines > 1 and card.caption or card.captionShort or card.caption)
          all[#all].h, all[#all].color = lines*lineH, palette.muted
        end
        diagrams.append(all, w, card, 6, artY, formX-18, artH)
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
        all[#all+1] = { type = "rectangle", x = x, y = overviewY, w = bw, h = bh, color = palette.border, thickness = 2 }
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
        all[#all+1] = { type = "rectangle", x = 10, y = y-3, w = width-20, h = 1, filled = true, color = palette.border }
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
        all[#all+1] = { type = "line", pts = {{barX,mid},{barX+barW-1,mid}}, color = palette.border, thickness = 2 }
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
        all[#all].color = function() return bar.done() and palette.accent or palette.text end
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
          if chosen then all[#all].color, all[#all].textColor = palette.accent, palette.accentText end
          all[#all].visible = function() return (r.selected() == true) == chosen end
        end
      elseif r.kind == "button" or r.kind == "hold" then
        button(formX, y, formW, r.label, function() if enabled() and w:usable() then r.press() end end, enabled,
          r.kind == "hold" and "momentaryButton" or "button", r.release)
        all[#all].h=rowControlH
      else
        local editW = large and 190 or math.floor(formW * 0.48)
        if attitudeCard and large then
          all[#all+1]=label(formX,y-34,formW,r.label)
          editW=formW
        elseif r.fullWidth then
          editW=formW
        else
        all[#all + 1] = label(formX, y+3, formW-editW-8, illustrated and compact[r.label] or r.label)
        end
        if r.kind == "value" then
          all[#all + 1] = label(formX+formW-editW, y+3, editW, function() return tostring(r.get() or "--") end)
          all[#all].h=(card.link=="overview" or card.dense or fitRows) and math.min(rowControlH,rowH-3) or rowControlH
          -- A value row may name a palette role for its live state, e.g. a switch that is on.
          if r.color then all[#all].color=function() return palette[r.color()] or palette.text end end
        elseif r.kind == "toggle" then
          local function set(v) w:applyEdit(function() if editable() then r.set(v) end end) end
          all[#all + 1] = { type = "button", x = formX+formW-editW, y = y, w = editW, h = rowControlH,
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
          all[#all + 1] = { type = "choice", x = formX+formW-editW, y = y, w = editW, h = rowControlH,
            title = r.label, values = values, get = get,
            set = function(v)
              if v <= offset or not values[v] then return end
              w:applyEdit(function() if editable() then r.set(v - offset) end end)
            end, active = enabled }
        elseif r.kind == "text" then
          all[#all + 1] = { type = "textEdit", x = formX+formW-editW, y = y, w = editW, h = rowControlH,
            value = r.get(), length = r.length or 16, active = enabled,
            set = function(v) w:applyEdit(function() if editable() then r.set(v) end end) end }
        else
          local pendingEdit, pendingValue
          local function get()
            if pendingEdit and w.pendingEdit == pendingEdit and editable() then return pendingValue end
            return r.get()
          end
          local function set(v)
            pendingEdit = function() if editable() then r.set(v) end end
            pendingValue = v
            w:applyEdit(pendingEdit)
          end
          -- update() reads get() when the native editor closes, before a queued
          -- STATUS reply can authorize the final value. Keep that draft visible.
          all[#all + 1] = { type = "numberEdit", x = formX+formW-editW, y = y, w = editW, h = rowControlH,
            min = r.min, max = r.max, get = get, set = set,
            display = function(v)
              if r.display then return r.display(v) end
              if r.divisor then return string.format("%.1f", v / r.divisor) end
              return tostring(v)
            end, active = enabled }
        end
      end
    end
    local function nextText() return simpleNext and w.L.continue or restartNext and w.L.reboot or w.trial and w.trial.success and w.L.saveReboot or step == 10 and w.rebootPending and w.L.reboot or step == 19 and not w.singleStep and w.L.finish or
      finalCard and (w.singleStep and (next(w.dirty) and w.L.saveStep or (w.returnToSuite and w.L.backToSuite or w.L.backToSteps)) or w.L.saveNext) or w.L.continue end
    if not w.historyMode then
    button(width-math.floor(width*0.42)-8, height-controlH-6, math.floor(width*0.42), nextText,
      function() if current() then w:next() end end, function() return w.canNext == true and current() end)
    all[#all].color, all[#all].textColor = palette.accent, palette.accentText
    all[#all + 1] = label(math.floor(width*0.27)+8, height-controlH, math.floor(width*0.28)-20,
      string.format("%d/%d", w.card, #w.cards))
    all[#all].color = palette.accent
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
