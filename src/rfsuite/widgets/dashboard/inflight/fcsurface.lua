-- Ground-only suggested functions. Requests, preference writes and the following read each
-- have their own pass; callbacks only record the next action.
local M = {}
local requireModule = _G.rfsuite.require
local Setup = requireModule("widgets/dashboard/inflight/setup.lua")
local FcSetup = requireModule("widgets/dashboard/inflight/fcsetup.lua")
local Text = requireModule("widgets/dashboard/inflight/fctext.lua")
local Functions = requireModule("widgets/dashboard/inflight/functions.lua")
if not Setup or not FcSetup or not Text or not Functions then error("inflight/fcsurface.lua: missing dependency", 0) end

local function refresh(widget, drive)
  drive.valueEpoch = drive.valueEpoch + 1
  widget._tuningKeyDirty = true
end

function M.close(widget, drive)
  local state = drive.fcSetup
  if state and state.run then
    FcSetup.cancel(state.run)
    if state.applied then
      drive:seedSet()
      drive.prime, drive._primeAutoDone = nil, false
    end
  end
  drive.fcSetupOpen, drive.fcSetup, drive.fcSurface = nil, nil, nil
  if drive.pendingSave and drive.pendingSave.steps then drive.pendingSave = nil end
  local clear = _G.rfsuite.clearModule
  if clear then
    clear("widgets/dashboard/inflight/fcsetup.lua")
    clear("widgets/dashboard/inflight/fctext.lua")
    clear("widgets/dashboard/inflight/fcsurface.lua")
    for _, path in ipairs(state and state.loadedOnlyHere or {}) do clear(path) end
  end
  refresh(widget, drive)
  collectgarbage("collect")
end

local function failed(widget, drive, reason)
  local state = drive.fcSetup
  if state.run then FcSetup.cancel(state.run) end
  if drive.pendingSave and drive.pendingSave.steps then drive.pendingSave = nil end
  state.phase, state.error, state.request = "error", reason, nil
  refresh(widget, drive)
end

function M.saved(widget, drive, ok, reason)
  local state = drive.fcSetup
  if not state then return end
  if not ok then
    state.storeError = reason
    failed(widget, drive, reason == "board_changed" and reason or "store")
    return
  end
  state.phase = "reread"
end

function M.tick(widget, drive, Prime)
  local state = drive.fcSetup
  if not state then
    local root = _G.rfsuite
    local defaults = Setup.loadModelSettings(root.session and root.session.modelPreferences)
    state = {phase = "choices", step = defaults.step, step_headspeed = defaults.step_headspeed}
    state.loadedOnlyHere = {}
    local modules = root.modules or {}
    for _, path in ipairs({"tasks/msp/api/rx_map.lua", "tasks/msp/api/get_adjustment_function_ids.lua",
      "tasks/msp/api/get_adjustment_range.lua", "tasks/msp/api/set_adjustment_range.lua", "tasks/msp/api/eeprom_write.lua"}) do
      if modules["/SCRIPTS/TOOLS/rfsuite-core/" .. path] == nil then
        state.loadedOnlyHere[#state.loadedOnlyHere + 1] = path
      end
    end
    drive.fcSetup = state
    refresh(widget, drive)
    return
  end
  -- Check the widget's own armed reading as well as the writer's fail-closed sensor check.
  if widget.state.armed == true then
    if state.phase ~= "error" then failed(widget, drive, "armed") end
    return
  end
  local refusal = Prime.setupRefusal and Prime.setupRefusal(widget)
  if refusal and state.phase ~= "error" then failed(widget, drive, refusal); return end
  if state.phase == "reread" then
    M.close(widget, drive)
    drive:seedSet()
    drive.prime = nil
    Prime.start(widget, drive, true)
    return
  end
  local run = state.run
  if run and state.phase ~= "error" then
    local board = Prime.boardOnLink()
    if board == nil then failed(widget, drive, "no_link"); return end
    if board ~= run.board then failed(widget, drive, "board_changed"); return end
  end
  if state.phase == "saving" or state.phase == "error" then return end
  if not widget.state.fblConnected and state.run then failed(widget, drive, "no_link"); return true end
  local function progress()
    if state.lastPhase ~= run.phase then
      state.lastPhase = run.phase
      refresh(widget, drive)
    end
  end
  local handlers = {
    onProgress = progress,
    onError = function(_, reason) failed(widget, drive, reason) end,
    onPlan = function(_, plan)
      if not plan.ok then failed(widget, drive, plan.refused); return end
      state.phase, state.page, state.pages = "plan", 1, nil
      refresh(widget, drive)
    end,
    onDone = function(_, report)
      if report.verdict ~= "match" then
        failed(widget, drive, report.stepOnly and "verify_step_only" or "verify_differs")
        return
      end
      state.phase = "saving"
      drive.pendingSave = {mcu = run.mcu,
        steps = {step = run.settings.step, step_headspeed = run.settings.step_headspeed}}
      refresh(widget, drive)
    end
  }
  if state.request == "read" then
    state.request, state.phase = nil, "busy"
    local settings = {bank_ch = drive.settings.bank_ch, value_ch = drive.settings.value_ch,
      step = state.step, step_headspeed = state.step_headspeed}
    run = FcSetup.newRun(settings)
    state.run = run
    local session = _G.rfsuite.session
    run.mcu = session and session.mcu_id
    run.board, run.boardOnLink = Prime.boardOnLink(), Prime.boardOnLink
    if not run.board then failed(widget, drive, "no_link"); return end
    FcSetup.begin(run, handlers)
    refresh(widget, drive)
  elseif state.request == "write" then
    state.request, state.phase = nil, "busy"
    state.applied = true
    FcSetup.apply(run, handlers)
    refresh(widget, drive)
  elseif state.phase == "busy" then
    FcSetup.tick(run, handlers)
  else return false end
  return true
end

-- The screen supplies its existing geometry and node helpers. Buttons remain ordinary focusable
-- LVGL controls, as in the parameter picker, for both touch and the hardware encoder.
function M.build(children, widget, m, w, h, t, p, label, action, wrap)
  local drive = widget._inflight
  local state = drive.fcSetup
  local width, y = w - m.pad * 2, m.headerH + 4
  local lineH = m.large and 24 or 16
  local row = {actionH = m.large and 44 or 30, small = m.small, textOff = m.textOff}
  local bottom = h - m.pad - row.actionH
  local function text(value, color)
    label(children, m.pad, y, width, value, color or p.text, m.small, LEFT)
    y = y + lineH
  end
  local function button(x, by, bw, value, press, accent)
    action(children, row, x, by, bw, value, p, press)
    children[#children].text = value
    if accent then
      children[#children - 1].color, children[#children].color = p.accent, p.onAccent
    end
  end
  local function cancel() M.close(widget, drive) end
  local cancelText = t("widgets.dashboard.inflight_pick_cancel", "Cancel")
  text(t("widgets.dashboard.inflight_fc_setup_action", "Set up suggested functions"), p.accent)
  if not state then text(t("widgets.dashboard.inflight_fc_preparing", "Preparing setup")); return end
  if state.phase == "choices" then
    local first = Functions.STANDARD_FIRST_SLOT + 1
    local intro = string.format(t("widgets.dashboard.inflight_fc_setup_intro",
      "Replaces adjustment slots %d-%d with the suggestions, whatever they hold now.\nSlots 1-%d (profile selection) stay.\nThe next page lists what is replaced."),
      first, first + #Functions.STANDARD_SLOT_ORDER - 1, first - 1)
    local introW = width + 2
    for _, line in ipairs(wrap(intro, introW, m.small)) do
      label(children, m.pad, y, introW, line, p.text, m.small, LEFT)
      y = y + lineH
    end
    local function choices(key, name, values)
      text(name)
      local gap, bw = 4, math.floor((width - 12) / 4)
      for index, value in ipairs(values) do
        button(m.pad + (index - 1) * (bw + gap), y, bw, tostring(value), function()
          if drive.fcSetup ~= state or state.phase ~= "choices" or state.request or widget.state.armed == true then return end
          state[key] = value
          refresh(widget, drive)
        end, value == state[key])
      end
      y = y + row.actionH + 3
    end
    choices("step", t("widgets.dashboard.inflight_fc_step", "Step size"), Setup.STEP_CHOICES)
    choices("step_headspeed", t("widgets.dashboard.inflight_fc_step_headspeed", "Head speed step"), Setup.HEADSPEED_STEP_CHOICES)
    local bw = math.floor((width - m.pad) / 2)
    button(m.pad, bottom, bw, cancelText, cancel)
    button(m.pad * 2 + bw, bottom, bw, t("widgets.dashboard.inflight_fc_next", "Next"), function()
      if drive.fcSetup == state and state.phase == "choices" and not state.request
        and widget.state.armed ~= true then state.request = "read" end
    end, true)
  elseif state.phase == "plan" then
    if not state.pages then
      state.pages = {{}}
      local count = math.max(1, math.floor((bottom - y - 4) / lineH))
      for _, entry in ipairs(Text.question(state.run.plan, t)) do
        local lines = wrap(entry, width, m.small)
        local page = state.pages[#state.pages]
        if #page > 0 and #page + #lines > count then
          page = {}
          state.pages[#state.pages + 1] = page
        end
        for _, line in ipairs(lines) do page[#page + 1] = line end
      end
    end
    for _, line in ipairs(state.pages[state.page]) do text(line) end
    local cancelW, arrowW = math.floor(width / 4), m.large and 60 or 44
    button(m.pad, bottom, cancelW, cancelText, cancel)
    button(m.pad + cancelW + 4, bottom, arrowW, "<", function()
      state.page = math.max(1, state.page - 1); refresh(widget, drive)
    end)
    button(m.pad + cancelW + arrowW + 8, bottom, arrowW, ">", function()
      state.page = math.min(#state.pages, state.page + 1); refresh(widget, drive)
    end)
    if state.page == #state.pages then
      local confirmX = m.pad + cancelW + arrowW * 2 + 12
      button(confirmX, bottom, w - m.pad - confirmX, t("widgets.dashboard.inflight_fc_confirm", "Confirm"), function()
        if drive.fcSetup == state and state.phase == "plan" and not state.request
          and state.page == #state.pages and widget.state.armed ~= true then state.request = "write" end
      end, true)
    end
  elseif state.phase == "error" then
    for _, line in ipairs(wrap(Text.refusalText(state.error, t), width, m.small)) do text(line, p.warn) end
    button(m.pad, bottom, width, t("widgets.dashboard.inflight_back", "Back"), cancel)
  else
    local run = state.run or {}
    local function counters()
      return string.format(t("widgets.dashboard.inflight_progress_step", "Step %d of %d"), run.done or 0, run.total or 0)
    end
    text(counters)
    y = y + lineH
    children[#children + 1] = {type = "rectangle", x = m.pad, y = y, w = width, h = lineH, color = p.button, filled = true}
    -- lvgl.build takes only numbers for w and h; a live width goes through `size`.
    children[#children + 1] = {type = "rectangle", x = m.pad, y = y, w = 0, h = lineH,
      color = p.accent, filled = true,
      size = function()
        return math.floor(width * math.min(1, (run.done or 0) / math.max(1, run.total or 0))), lineH
      end}
    y = y + lineH * 2
    local step = (state.phase == "saving" or state.phase == "reread")
      and t("widgets.dashboard.inflight_fc_done", "Flight controller set up")
      or (run.phase == "verify" and t("widgets.dashboard.inflight_fc_verifying", "Reading back")
      or (run.phase == "writing" or run.phase == "commit") and t("widgets.dashboard.inflight_fc_writing", "Writing")
      or t("widgets.dashboard.inflight_fc_reading", "Reading the flight controller"))
    text(step)
    if state.phase ~= "saving" and state.phase ~= "reread" then
      button(m.pad, bottom, width, cancelText, cancel)
    end
  end
end

return M
