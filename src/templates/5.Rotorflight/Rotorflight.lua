-- Fired once, right after a model is created from the Rotorflight template.
--
-- EdgeTX runs the script that sits beside a template's yml as a standalone script the moment
-- the template is applied (gui/colorlcd/model/model_select.cpp, the "wizard Lua script" hook).
-- The yml has already delivered everything no script can set later -- the ARM function switch,
-- the warnings, the static reference channels, the dashboard. What is still open is the
-- pilot's half: WHICH switch carries which function, and which slot the CRSF module sits in.
-- That is asked with the radio's OWN pickers -- the source picker filtered to switches for the
-- whole-switch answers, the position picker for the one position the reference construction
-- stores, the hold gate -- and written in the reference models' shape: plain lines at full
-- weight, active low, the hold as a MAX line gated by the named position, the governor beneath
-- it.
--
-- The flight controller's half -- mode ranges, adjustments -- is set up later in RFSuite,
-- against a connected board; this wizard deliberately stops at the reference-model shape a
-- pilot could also have built by hand.
--
-- Strings carry i18n markers like every suite source: the packager resolves them per locale
-- at build time, so the standalone script needs none of the suite's i18n helpers at runtime.

local RADIO_MODULE = "/SCRIPTS/RFSUITE/core/lib/model_radio.lua"

local R = nil          -- the assistant's radio-side module, loaded below
local loadError = nil

-- The rows, on two screens: the five the model cannot fly without, then the two optional
-- channels and the transmitter module. `whole` answers with a SWITCH through the radio's
-- source picker (any of its positions may carry the function -- the reference encodes the rest
-- as convention, active low); the hold row answers with the one POSITION the reference
-- construction stores; the module row is a plain choice. `min` is the position count the
-- function needs: governor and profiles carry three values across the travel, arming, rescue,
-- blackbox and backup work on two or three (the reference arms on a three-position switch).
-- An `optional` row may stay empty: its channel then keeps the yml's MIN line and sits at the
-- bottom of the travel, which is "off" for every mode range a flight controller could hold.
local ROWS = {
  { key = "arm", step = 1, whole = true, min = 2, label = "@i18n(templates.rotorflight.row_arm)@" },
  { key = "hold", step = 1, whole = false, label = "@i18n(templates.rotorflight.row_hold)@" },
  { key = "gov", step = 1, whole = true, min = 3, label = "@i18n(templates.rotorflight.row_gov)@" },
  { key = "profile", step = 1, whole = true, min = 3, label = "@i18n(templates.rotorflight.row_profile)@" },
  { key = "rescue", step = 1, whole = true, min = 2, label = "@i18n(templates.rotorflight.row_rescue)@" },
  { key = "blackbox", step = 2, whole = true, min = 2, optional = true,
    label = "@i18n(templates.rotorflight.row_blackbox)@" },
  { key = "backup", step = 2, whole = true, min = 2, optional = true,
    label = "@i18n(templates.rotorflight.row_backup)@" },
  { key = "module", step = 2, choice = true, label = "@i18n(templates.rotorflight.row_module)@" }
}

-- Pairs that may share one physical switch. Governor and profiles on one three-position switch
-- is a construction the published reference model uses (each position is a profile and a
-- governor level together), and the hold position sits on the same channel as the governor,
-- so either pair drives one function rather than two. Every other pair is refused: one switch
-- on two channels arms the backup pack with the motor, or logs whenever rescue is engaged.
local SHARED_OK = { gov = { profile = true, hold = true }, profile = { gov = true }, hold = { gov = true } }

-- The module choice: the template's yml configures the INTERNAL module for CRSF; the external
-- slot is the alternative. 1-based, the shape the radio's choice control hands to Lua.
local MODULE_INTERNAL = 1
local MODULE_EXTERNAL = 2
local MODULE_TYPE_NONE = 0
local MODULE_TYPE_CROSSFIRE = 5   -- ModuleType in the firmware's pulses/modules_constants.h
local CRSF_CHANNELS = 16

local answers = { module = MODULE_INTERNAL } -- key -> swsrc (a switch's first position, or the
                                             -- hold position), or the module choice
local message = nil     -- what stands between the pilot and the next button, in words
local written = nil     -- per-channel results of the write, once it ran
local step = 1          -- which of the two form screens is up
local view = nil        -- nil (not built) | "form1" | "form2" | "done"
local quit = false      -- the closing screen's button asked to leave

-- ---------------------------------------------------------------------------------------------
-- The write: the REFERENCE construction, with the pilot's switches in it.
--
--   input Arm   <arm switch>  +100                   -> CH5 "Arming"
--   input Thr   MAX -100 gated by the hold position,
--               then <governor> +100  ("Hold"/"GOV") -> CH6 "Thr"
--   input Prof  <profile switch> +100 ("Prof")       -> CH7 "Prof"
--   input Res   <rescue switch>  +100 ("Rescue")     -> CH8 "Rescue"
--   input BB    <blackbox switch> +100 ("BlackB")    -> CH9 "BlkB"   (MIN when skipped)
--   input BckU  <backup switch>   +100 ("Backup")    -> CH10 "BckU"  (MIN when skipped)
--
-- Expo lines are alternatives: the first line whose gate matches wins, so the hold line rules
-- exactly one position and every other position carries the governor -- the reference's own
-- trick, and the reason the hold is the one position asked for. Active is LOW throughout, as
-- both reference models have it. The assistant recognises the plain lines and re-asks what it
-- cannot read when it later walks the flight-controller half.
-- ---------------------------------------------------------------------------------------------

local function sourceByName(name)
  local id = getSourceIndex ~= nil and getSourceIndex(name) or nil
  if id ~= nil then return tonumber(id) end
  local info = getFieldInfo ~= nil and getFieldInfo(name) or nil
  if type(info) == "table" and info.id ~= nil then return tonumber(info.id) end
  return nil
end

local function clearInput(index)
  for _ = 1, (model.getInputsCount(index) or 0) do
    model.deleteInput(index, 0)
  end
end

local function putLine(index, lineNo, inputName, source, weight, gate, lineName)
  model.insertInput(index, lineNo, {
    name = lineName or "",
    inputName = inputName,
    source = source,
    weight = weight,
    offset = 0,
    switch = gate or 0,
    curveType = 0,
    curveValue = 0,
    scale = 0,
    side = 3,
    trimSource = R.TRIM_OFF,
    flightModes = 0
  })
end

local function wire(channel, input, channelName)
  if not R.clearChannel(channel) then return false, "clear_failed" end
  local ok = pcall(model.insertMix, channel - 1, 0, {
    source = R.inputSource(input),
    weight = 100,
    offset = 0,
    switch = 0,
    multiplex = 0,
    curveType = 0,
    curveValue = 0,
    flightModes = 0
  })
  if not ok then return false, "insert_failed" end
  R.setChannelName(channel, channelName)
  return true
end

local function writeAnswers()
  written = {}

  local function record(channel, name, ok, err)
    written[#written + 1] = { channel = channel, name = name, ok = ok and true or false, err = err }
  end

  local function simple(channel, input, inputName, channelName, swsrc, lineName)
    local source = R.switchSource(swsrc)
    if source == nil then record(channel, channelName, false, "no_source") return end
    clearInput(input)
    local okLine = pcall(putLine, input, 0, inputName, source, 100, 0, lineName)
    if not okLine then record(channel, channelName, false, "input_failed") return end
    local ok, err = wire(channel, input, channelName)
    record(channel, channelName, ok, err)
  end

  simple(5, 4, "Arm", "Arming", answers.arm)

  -- The throttle goes through the assistant's own writer: ONE construction, one place, and
  -- the assistant recognises its own work when it walks the flight-controller half later.
  do
    local throttleEntry = nil
    for _, entry in ipairs(R.CHANNELS) do
      if entry.key == "throttle" then throttleEntry = entry break end
    end
    if throttleEntry == nil then
      record(6, "Thr", false, "no_entry")
    else
      local ok, err = R.writeThrottleChannel(throttleEntry, answers.hold, answers.gov)
      record(6, "Thr", ok, err)
    end
  end

  simple(7, 6, "Prof", "Prof", answers.profile, "Prof")
  simple(8, 7, "Res", "Rescue", answers.rescue, "Rescue")

  -- The optional pair. Skipped, the yml's MIN line stays as it is and the result says so; the
  -- channel keeps its name so the layout reads the same either way.
  local function optional(channel, input, inputName, channelName, swsrc, lineName)
    if swsrc == nil or swsrc == 0 then
      written[#written + 1] = { channel = channel, name = channelName, ok = true, unused = true }
      return
    end
    simple(channel, input, inputName, channelName, swsrc, lineName)
  end
  optional(9, 8, "BB", "BlkB", answers.blackbox, "BlackB")
  optional(10, 9, "BckU", "BckU", answers.backup, "Backup")

  -- The module. Internal is what the yml already holds, so only the external choice writes:
  -- CRSF on the external slot, and the internal slot switched off so two modules do not both
  -- drive the same model. Read back, because a module the radio cannot drive is refused
  -- without an error.
  local moduleName = "@i18n(templates.rotorflight.row_module)@"
  if answers.module == MODULE_EXTERNAL then
    local ok = pcall(model.setModule, 1,
      { Type = MODULE_TYPE_CROSSFIRE, firstChannel = 0, channelsCount = CRSF_CHANNELS })
    if ok then ok = pcall(model.setModule, 0, { Type = MODULE_TYPE_NONE }) end
    local ext = ok and model.getModule(1) or nil
    if type(ext) == "table" and ext.Type == MODULE_TYPE_CROSSFIRE then
      written[#written + 1] = { name = moduleName, ok = true,
        detail = "@i18n(templates.rotorflight.module_external)@" }
    else
      written[#written + 1] = { name = moduleName, ok = false, err = "module_failed" }
    end
  else
    written[#written + 1] = { name = moduleName, ok = true,
      detail = "@i18n(templates.rotorflight.module_internal)@" }
  end
end

-- The physical switch an answer stands on: a whole-switch answer is already its first
-- position, the hold answer is one position of some switch.
local function switchOf(value)
  if value == nil or value == 0 then return nil end
  return R.firstPositionOf(value)
end

-- What still stands between the pilot and the next button, in one sentence -- or nil, which is
-- what lets the button act. `upTo` is the last screen whose rows are checked, so the first
-- screen's button judges the first screen alone and the Create button judges everything.
local function firstProblem(upTo)
  local used = {}   -- switch -> the rows that took it so far
  for _, row in ipairs(ROWS) do
    if row.step <= upTo and not row.choice then
      local value = answers[row.key]
      if value == nil or value == 0 then
        if not row.optional then
          return string.format("@i18n(templates.rotorflight.nothing_chosen)@", row.label)
        end
      else
        if row.min ~= nil then
          local positions = R.switchPositionCount(value) or 0
          if positions < row.min then
            return string.format("@i18n(templates.rotorflight.too_few_positions)@",
              row.label, positions, row.min)
          end
        end
        local switch = switchOf(value)
        if switch ~= nil then
          for _, other in ipairs(used[switch] or {}) do
            if not (SHARED_OK[row.key] and SHARED_OK[row.key][other.key]) then
              return string.format("@i18n(templates.rotorflight.same_switch)@",
                other.label, row.label)
            end
          end
          used[switch] = used[switch] or {}
          used[switch][#used[switch] + 1] = row
        end
      end
    end
  end
  return nil
end


-- ---------------------------------------------------------------------------------------------
-- The screens, in the suite's own look: an EdgeTX page with the suite's icon, the title and the
-- step in the header and the back arrow there, rows the way ui/controls.lua lays them out (label
-- left in SMLSIZE, the control right, a hairline under every row), and the suite's palette. The
-- page body scrolls, so a 480x272 screen reaches the button the same way a suite page does.
-- Source pickers carry no `title` (the picker class does not take the property and raises on it).
-- ---------------------------------------------------------------------------------------------

local PALETTE_MODULE = "/SCRIPTS/RFSUITE/core/ui/palette.lua"
local APP_ICON = "/SCRIPTS/RFSUITE/core/assets/icon.png"

-- The suite's palette, loaded beside the radio module; the fallbacks are the same theme slots,
-- for a card whose suite predates the file.
local P = {
  text = COLOR_THEME_PRIMARY1, muted = COLOR_THEME_DISABLED, border = COLOR_THEME_SECONDARY2,
  accent = COLOR_THEME_SECONDARY1, warning = COLOR_THEME_WARNING, error = RED, ok = GREEN
}

-- The picker filters. The bit values are the firmware's own (dataconstants.h); the source
-- filter is taken from the lvgl module where it exists, because that registered constant
-- already includes the function-switch bit -- the switches this template cares most about.
local SRC_SWITCH_FILTER = (lvgl ~= nil and lvgl.SRC_SWITCH) or 0xFFFFFFFF
-- An optional row also offers the empty entry, which is how a pilot takes a pick back.
local SRC_OPTIONAL_FILTER = SRC_SWITCH_FILTER | ((lvgl ~= nil and lvgl.SRC_CLEAR) or 0)
local SW_SWITCH = 1
local SW_NONE = 1 << 20

-- ui/controls.lua's metrics, restated: the row height by screen width, the native control and
-- font heights, the combo width; and the margins of a page body.
local W = LCD_W or 480
local ROW_H = (W >= 760 and 50) or (W <= 320 and 34) or 40
local CTRL_H = (lvgl ~= nil and lvgl.UI_ELEMENT_HEIGHT) or ((W >= 760 and 44) or (W <= 320 and 26) or 32)
local LABEL_H = (W >= 760 and 29) or (W <= 320 and 17) or 21
local PICKER_W = (W >= 760) and 260 or 172
local LEFT = 6
local BODY_W = W - 2 * LEFT
local MESSAGE_H = 3 * LABEL_H
local BUTTON_H = 34

local function rowLabel(children, y, text)
  children[#children + 1] = {
    type = "label", x = LEFT, y = y + math.floor((ROW_H - LABEL_H) / 2),
    w = BODY_W - PICKER_W - 18, text = text, color = P.text, font = SMLSIZE
  }
end

local function rowDivider(children, y)
  children[#children + 1] = {
    type = "rectangle", x = LEFT, y = y + ROW_H, w = BODY_W, h = 1, color = P.border, filled = true
  }
end

local function controlBox(y)
  return LEFT + BODY_W - PICKER_W - 10, y + math.floor((ROW_H - CTRL_H) / 2)
end

local function sourceRow(children, y, row)
  rowLabel(children, y, row.label)
  local x, cy = controlBox(y)
  children[#children + 1] = {
    type = "source", x = x, y = cy, w = PICKER_W, h = CTRL_H,
    filter = row.optional and SRC_OPTIONAL_FILTER or SRC_SWITCH_FILTER,
    get = function()
      local picked = answers[row.key]
      if picked == nil or picked == 0 then return 0 end
      return R.switchSource(picked) or 0
    end,
    set = function(value)
      answers[row.key] = R.switchFromSource(value) or 0
    end
  }
  rowDivider(children, y)
end

local function positionRow(children, y, row)
  rowLabel(children, y, row.label)
  local x, cy = controlBox(y)
  children[#children + 1] = {
    type = "switch", x = x, y = cy, w = PICKER_W, h = CTRL_H,
    filter = SW_SWITCH | SW_NONE,
    get = function() return answers[row.key] or 0 end,
    set = function(value) answers[row.key] = tonumber(value) or 0 end
  }
  rowDivider(children, y)
end

local function choiceRow(children, y, row)
  rowLabel(children, y, row.label)
  local x, cy = controlBox(y)
  children[#children + 1] = {
    type = "choice", x = x, y = cy, w = PICKER_W, h = CTRL_H,
    values = { "@i18n(templates.rotorflight.module_internal)@",
      "@i18n(templates.rotorflight.module_external)@" },
    get = function() return answers[row.key] or MODULE_INTERNAL end,
    set = function(value) answers[row.key] = tonumber(value) or MODULE_INTERNAL end
  }
  rowDivider(children, y)
end

-- Every screen is one page: the suite's icon, "Rotorflight" and the step in the header, and the
-- header's back arrow doing what that screen's own way back does.
local function buildPage(subtitle, body, onBack)
  lvgl.clear()
  lvgl.build({
    {
      type = "page", title = "Rotorflight", subtitle = subtitle, icon = APP_ICON,
      back = onBack, backButton = true, children = body
    }
  })
end

-- One form screen. Two of them, because eight rows are too many for one screen: the first
-- holds what the model cannot fly without, the second the optional channels and the module,
-- and only the second screen's button writes.
local function buildForm()
  local body = {}
  local y = 4
  for _, row in ipairs(ROWS) do
    if row.step == step then
      if row.choice then choiceRow(body, y, row)
      elseif row.whole then sourceRow(body, y, row)
      else positionRow(body, y, row) end
      y = y + ROW_H + 1
    end
  end

  -- The one sentence that stands between the pilot and the button; the button's press
  -- rebuilds this form, which is what puts the sentence on screen. Warning-colored: it is the
  -- refusal, and it must not read like one more row label. It gets up to three lines BESIDE
  -- the first screen's button, in the hint's place, and below the second screen's two buttons:
  -- above the button it pushed the button under the fold of a 480x320 screen, and a refusal
  -- that hides the way on is a dead end.
  y = y + 6
  local function refusal(x, ry, w)
    body[#body + 1] = {
      type = "label", x = x, y = ry, w = w, h = MESSAGE_H,
      color = P.warning, text = message, font = SMLSIZE
    }
  end

  if step == 1 then
    body[#body + 1] = {
      type = "button", x = LEFT, y = y, w = 200, h = BUTTON_H,
      text = "@i18n(templates.rotorflight.next_button)@",
      press = function()
        message = firstProblem(1)
        -- Either way the view is rebuilt: with nothing in the way it becomes the second
        -- screen, with a problem it comes back carrying the sentence -- a live label alone
        -- stayed blank here, and a refusal nobody can read is a button that does nothing.
        if message == nil then step = 2 end
        view = nil
      end
    }
    if message ~= nil then
      refusal(LEFT + 212, y, BODY_W - 212)
    else
      body[#body + 1] = {
        type = "label", x = LEFT + 212, y = y, w = BODY_W - 212,
        text = "@i18n(templates.rotorflight.skip_hint)@", color = P.muted, font = SMLSIZE
      }
    end
    buildPage("@i18n(templates.rotorflight.title_form)@", body, function() quit = true end)
  else
    body[#body + 1] = {
      type = "button", x = LEFT, y = y, w = 200, h = BUTTON_H,
      text = "@i18n(templates.rotorflight.create_button)@",
      press = function()
        message = firstProblem(2)
        if message == nil then writeAnswers() end
        view = nil
      end
    }
    local function back()
      message = nil
      step = 1
      view = nil
    end
    body[#body + 1] = {
      type = "button", x = LEFT + 212, y = y, w = 120, h = BUTTON_H,
      text = "@i18n(templates.rotorflight.back_button)@", press = back
    }
    if message ~= nil then refusal(LEFT, y + BUTTON_H + 6, BODY_W) end
    buildPage("@i18n(templates.rotorflight.title_form_more)@", body, back)
  end
end

local function buildDone()
  local body = {}

  -- One row per channel written, the verdict as a colored word on the right -- green carries
  -- "worked", red carries "failed: why", and nothing else on this screen wears a hard color,
  -- so a failure is the loudest thing on it. A skipped optional channel is muted, not green.
  local rowH = math.floor(ROW_H * 3 / 4)
  local statusW = math.floor(BODY_W * 2 / 5)
  local y = 4
  for _, result in ipairs(written or {}) do
    local name = tostring(result.name)
    if result.channel ~= nil then name = "CH" .. tostring(result.channel) .. "  " .. name end
    local status
    if not result.ok then
      status = string.format("@i18n(templates.rotorflight.row_failed)@", tostring(result.err))
    elseif result.unused then
      status = "@i18n(templates.rotorflight.row_unused)@"
    else
      status = result.detail or "@i18n(templates.rotorflight.row_ok)@"
    end
    local ty = y + math.floor((rowH - LABEL_H) / 2)
    body[#body + 1] = {
      type = "label", x = LEFT, y = ty, w = BODY_W - statusW - 8,
      color = P.text, text = name, font = SMLSIZE
    }
    body[#body + 1] = {
      type = "label", x = LEFT + BODY_W - statusW, y = ty, w = statusW,
      color = (not result.ok) and P.error or (result.unused and P.muted or P.ok),
      text = status, font = SMLSIZE
    }
    body[#body + 1] = {
      type = "rectangle", x = LEFT, y = y + rowH, w = BODY_W, h = 1, color = P.border, filled = true
    }
    y = y + rowH + 1
  end

  y = y + 8
  body[#body + 1] = {
    type = "label", x = LEFT, y = y, w = BODY_W, color = P.text, font = SMLSIZE,
    text = "@i18n(templates.rotorflight.next_steps)@"
  }
  body[#body + 1] = {
    type = "label", x = LEFT, y = y + 2 * LABEL_H, w = BODY_W, color = P.muted, font = SMLSIZE,
    text = "@i18n(templates.rotorflight.next_steps_path)@"
  }

  -- A button to leave by, because a screen only RTN can close reads as stuck. RTN and the
  -- header's arrow still work; the button says the same thing where a finger already is.
  body[#body + 1] = {
    type = "button", x = LEFT, y = y + 4 * LABEL_H, w = 160, h = BUTTON_H,
    text = "@i18n(templates.rotorflight.close_button)@",
    press = function() quit = true end
  }
  buildPage("@i18n(templates.rotorflight.title_done)@", body, function() quit = true end)
end

-- The notice for a card without the suite, as an lvgl page. It names no icon: the suite's icon
-- is one of the files that are missing here, and without one the page shows the radio's own.
local FALLBACK_LINES = {
  "@i18n(templates.rotorflight.fallback_created)@",
  "@i18n(templates.rotorflight.fallback_needs_1)@",
  "@i18n(templates.rotorflight.fallback_needs_2)@",
  "@i18n(templates.rotorflight.fallback_needs_3)@"
}

local function buildFallback()
  local body = {}
  local y = 4
  for i, text in ipairs(FALLBACK_LINES) do
    if i == 2 then y = y + LABEL_H end
    body[#body + 1] = { type = "label", x = LEFT, y = y, w = BODY_W, color = P.text, font = SMLSIZE, text = text }
    y = y + LABEL_H
  end
  y = y + LABEL_H
  body[#body + 1] = {
    type = "label", x = LEFT, y = y, w = BODY_W, color = P.muted, font = SMLSIZE,
    text = "@i18n(templates.rotorflight.fallback_close)@"
  }
  body[#body + 1] = {
    type = "button", x = LEFT, y = y + LABEL_H + 8, w = 160, h = BUTTON_H,
    text = "@i18n(templates.rotorflight.close_button)@",
    press = function() quit = true end
  }
  lvgl.clear()
  lvgl.build({
    {
      type = "page", title = "Rotorflight", back = function() quit = true end, backButton = true,
      children = body
    }
  })
end

local function init()
end

local function run(event)
  if quit or event == EVT_VIRTUAL_EXIT then return 1 end

  -- Without the suite there is no radio module to borrow, and half a wizard would leave half
  -- a layout. The template's yml part is already in the model either way. And without lvgl
  -- there is no picker to offer -- the same honest exit.
  -- Checked on every pass, not only until the module is loaded: a radio without lvgl has the
  -- module and still nothing to build the form with.
  if R == nil or loadError ~= nil then
    if loadError == nil then
      local chunk = loadScript(RADIO_MODULE, "t")
      if type(chunk) == "function" then
        local ok, mod = pcall(chunk)
        if ok and type(mod) == "table" then R = mod else loadError = "load" end
      else
        loadError = "missing"
      end
      local paletteChunk = loadScript(PALETTE_MODULE, "t")
      if type(paletteChunk) == "function" then
        local ok, pal = pcall(paletteChunk)
        if ok and type(pal) == "table" then
          for k, v in pairs(pal) do P[k] = v end
        end
      end
      if lvgl == nil or type(lvgl.build) ~= "function" then loadError = "no_lvgl" end
      if R ~= nil and loadError == nil and (answers.arm == nil or answers.arm == 0) then
        -- SW1 is the switch the template PREPARED -- named ARM, red while armed -- so it is
        -- the one picker that starts filled. Everything else starts empty: those answers are
        -- not prepared anywhere.
        -- Every function switch arrives identically arm-ready; SW1 is preselected only
        -- because a filled picker is one decision fewer, not because it is special.
        for _, sw in ipairs(R.switches(2)) do
          if sw.name == "SW1" then answers.arm = sw.swsrc break end
        end
      end
    end
    if R == nil or loadError ~= nil then
      -- The script runs in the lvgl layout, where lcd drawing is switched off, so on a radio
      -- with lvgl the notice is a page of its own -- built once, because a rebuild on every pass
      -- would take the focus off its button. A radio without lvgl does not know the layout flag
      -- and runs the script on the lcd canvas, where the same lines are drawn.
      if lvgl ~= nil and type(lvgl.build) == "function" then
        if view ~= "fallback" then
          buildFallback()
          view = "fallback"
        end
        return 0
      end
      if event == EVT_VIRTUAL_ENTER then return 1 end
      if lcd ~= nil and lcd.clear ~= nil then
        lcd.clear()
        lcd.drawText(30, 40, "@i18n(templates.rotorflight.fallback_created)@", 0)
        lcd.drawText(30, 70, "@i18n(templates.rotorflight.fallback_needs_1)@", 0)
        lcd.drawText(30, 90, "@i18n(templates.rotorflight.fallback_needs_2)@", 0)
        lcd.drawText(30, 110, "@i18n(templates.rotorflight.fallback_needs_3)@", 0)
        lcd.drawText(30, 150, "@i18n(templates.rotorflight.fallback_close)@", 0)
      end
      return 0
    end
  end

  if written ~= nil and view ~= "done" then
    buildDone()
    view = "done"
  elseif written == nil and view ~= "form" .. step then
    buildForm()
    view = "form" .. step
  end

  return 0
end

-- `useLvgl` puts the form's controls into the radio's focus group: the rotary moves between the
-- rows, ENTER opens a picker, RTN reaches the page's back. Without it the script window holds
-- every key itself and the controls answer to touch only.
return { init = init, run = run, useLvgl = true }
