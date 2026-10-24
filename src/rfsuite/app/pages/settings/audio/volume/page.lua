local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  return chunk()
end

local Palette = _G.rfsuite and _G.rfsuite.palette or (_G.rfsuite and _G.rfsuite.require or loadModule)("ui/palette.lua")

local Controls = nil
local Common = nil
-- The mode rules lib/audio.lua acts on (lib/audio_volume.lua), so the page shows what the suite
-- will do with the file rather than a second reading of it.
local Rules = nil
-- Loaded only in the mode that needs them: the model chain's reader (Master volume), the arming
-- state (Master volume's tests and Create), the announcement module (both tests, on a press), the
-- chain's writer and the confirm dialog (Create, on a press).
local Chain = nil
local Armed = nil
local Audio = nil
local Create = nil
local ConfirmDialog = nil

-- ─── Config schema ────────────────────────────────────────────────────────────

-- `volume_mode` and `connected_only` are resolved through Rules after the plain copy below,
-- because a file written before they existed carries neither. `level_connected_only` is carried
-- through as it was read: it is what such a file meant, and nothing on this page edits it.
local CONFIG_SCHEMA = {
  { key = "volume_mode",          type = "number", default = 0 },
  { key = "connected_only",       type = "bool",   default = false },
  { key = "level",                type = "number", default = 0 },
  { key = "level_connected_only", type = "bool",   default = false },
  { key = "master_gvar",          type = "number", default = 0 },
  { key = "master_normal",        type = "number", default = 80 },
  { key = "master_alert",         type = "number", default = 100 },
}

local MODE_OFF, MODE_LEVEL, MODE_MASTER = 0, 1, 2

-- The level a pilot starts from on picking Callout level with none stored: 3 plays a sound file
-- at a quarter of its amplitude, which is what the radio's own Wav volume 0 does (EdgeTX
-- radio/src/audio.cpp, WavContext::mixBuffer).
local LEVEL_START = 3

-- The global variables only. The picker has no empty entry: Mode's Off is what turns the master
-- volume off, so there is one place for it. Read from the lvgl table, which every firmware with
-- lvgl.source exports; the number is only a fallback, EdgeTX 2.12's SRC_GVAR 1 << 15
-- (radio/src/dataconstants.h).
local SRC_GVAR_FILTER = (lvgl ~= nil and lvgl.SRC_GVAR) or 0x8000

local function buildDefaultConfig()
  local cfg = {}
  for _, field in ipairs(CONFIG_SCHEMA) do cfg[field.key] = field.default end
  return cfg
end

-- ─── State ────────────────────────────────────────────────────────────────────

local ui = {
  loaded    = false,
  dirty     = false,
  config    = buildDefaultConfig(),
}

ui.runtime = nil

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local t = nil

local function ensureDeps()
  if not Common then
    Common = loadModule("app/pages/settings/common.lua")
  end
  if not Controls then
    Controls = loadModule("ui/controls.lua")
  end
  if not Rules then
    Rules = loadModule("lib/audio_volume.lua")
  end
  if not ui.runtime then
    ui.runtime = Common.createFormRuntime(ui)
  end
  if not t then
    t = Common.pageT("settings_audio_volume")
  end
end

local function copyFromPrefs(prefs)
  local audio = (prefs and prefs.audio) or {}

  for _, field in ipairs(CONFIG_SCHEMA) do
    if field.type == "string" then
      local v = tostring(audio[field.key] or "")
      ui.config[field.key] = v ~= "" and v or field.default
    elseif field.type == "bool" then
      if audio[field.key] ~= nil then
        ui.config[field.key] = audio[field.key]
      else
        ui.config[field.key] = field.default
      end
    else
      ui.config[field.key] = tonumber(audio[field.key]) or field.default
    end
  end

  local mode = Rules.mode(audio)
  ui.config.volume_mode = mode
  ui.config.connected_only = Rules.connectedOnly(audio, mode)
  -- Until the pilot sets Connected only, or a save has stored it, it shows how the file is read. A
  -- file that opens in Master volume without it reads as one written before the setting existed,
  -- whose master volume waited for the link: that reading is kept, also on coming back to Master volume.
  ui.connectedOnlySet = audio.connected_only ~= nil
  ui.masterBeforeSetting = not ui.connectedOnlySet and mode == MODE_MASTER
end

local function ensureLoaded(prefs)
  if ui.loaded then return end
  copyFromPrefs(prefs)
  ui.loaded = true
end

local function getModeOptions(i18n)
  return {
    { value = MODE_OFF, label = t(i18n, "mode_off", "Off (radio default)") },
    { value = MODE_LEVEL, label = t(i18n, "mode_level", "Callout level") },
    { value = MODE_MASTER, label = t(i18n, "mode_master", "Master volume") },
  }
end

local function getLevelOptions()
  return {
    { value = 1, label = "1" },
    { value = 2, label = "2" },
    { value = 3, label = "3" },
    { value = 4, label = "4" },
    { value = 5, label = "5" },
  }
end

local function onModeSelected(value)
  ui.config.volume_mode = value
  ui.createResult = nil
  if value == MODE_LEVEL and (tonumber(ui.config.level) or 0) <= 0 then
    ui.config.level = LEVEL_START
  end
  -- Unset, a mode picked here starts from `level_connected_only`, the callout level's switch from
  -- before the page offered one mode, which a fresh file has off: a new Master volume setup starts
  -- with Connected only off.
  if not ui.connectedOnlySet then
    if value == MODE_MASTER and ui.masterBeforeSetting then
      ui.config.connected_only = true
    else
      ui.config.connected_only = ui.config.level_connected_only == true
    end
  end
  -- The rows below depend on the mode, so this asks for a rebuild.
  ui.runtime.markDirty()
end

local function onConnectedOnlySet(value)
  ui.connectedOnlySet = true
  ui.runtime.getBoolSetter("connected_only")(value)
end

-- The source index of GV1. The global variables are one block of mix sources, so GV n is that
-- index + n - 1; "gvar1" is the firmware's own field name and does not move when a variable is
-- renamed (radio/src/lua/api_general.cpp, luaMultipleFields).
local function gvarSourceBase()
  if type(getFieldInfo) ~= "function" then return nil end
  local ok, info = pcall(getFieldInfo, "gvar1")
  if ok and type(info) == "table" then return tonumber(info.id) end
  return nil
end

-- A row's `?` opens the page's help sheet with the row's label as its title (the pattern of
-- app/pages/settings/audio/events/category_page.lua). Cached on ui.runtime, so onClose drops it.
local function getInlineHelpHandler()
  if ui.runtime.inlineHelpHandler then return ui.runtime.inlineHelpHandler end
  ui.runtime.inlineHelpHandler = function(helpText, helpTitle)
    local openHelp = ui.runtime.openHelp
    if type(openHelp) == "function" and type(helpText) == "string" and helpText ~= "" then
      openHelp(helpText, helpTitle)
    end
  end
  return ui.runtime.inlineHelpHandler
end

-- The options table a row control takes for its `?` button; empty when the row has no text,
-- which leaves the control as it is drawn without one.
local function helpOpts(text, title)
  if type(text) ~= "string" or text == "" then return {} end
  return { helpText = text, helpTitle = title, onHelp = getInlineHelpHandler() }
end

-- The global variable row. The picker is EdgeTX's own source picker, filtered to the global
-- variables this radio has, with their names. Controls has no wrapper for it, so the row draws
-- its label, the picker and its `?` where appendComboSelect places them.
local HELP_BTN_W, HELP_BTN_H, HELP_BTN_GAP, PICKER_W = 30, 30, 6, 172

local function appendGvarPicker(children, x, y, w, labelText, help)
  local rowH = Controls.ROW_H
  local pickerW = PICKER_W
  if pickerW > w then pickerW = w end
  local pickerX = x + w - pickerW - 10 - HELP_BTN_W - HELP_BTN_GAP
  -- Asked once per build rather than on every refresh of the picker: both answers are tables
  -- the firmware allocates, and neither changes while the page is open. A pick rebuilds the page.
  local base = gvarSourceBase()
  local storedGv = tonumber(ui.config.master_gvar) or 0
  local shown = 0
  if storedGv > 0 and base ~= nil and Rules.gvarOnBoard(storedGv) then shown = base + storedGv - 1 end

  children[#children + 1] = {
    type = "label",
    x = x, y = Controls.labelY(y, rowH), w = pickerX - x - 8,
    text = labelText, color = Palette.text, font = SMLSIZE
  }
  children[#children + 1] = {
    type = "source",
    x = pickerX, y = Controls.controlY(y, rowH), w = pickerW, h = Controls.CTRL_H,
    -- NO `title`: the source picker does not take one (see app/pages/setup_wizard/proc_radio.lua).
    filter = SRC_GVAR_FILTER,
    -- None picked yet, or a variable this radio lacks, is 0, which EdgeTX draws as its empty
    -- source: past the last variable come the radio's own sources (TX voltage, time, GPS), and
    -- the picker would name one of those.
    get = function() return shown end,
    set = function(value)
      value = tonumber(value) or 0
      local gv = base and (value - base + 1) or 0
      if gv < 1 or gv > Rules.MAX_GVARS then return end
      shown = value
      if gv == (tonumber(ui.config.master_gvar) or 0) then return end
      ui.config.master_gvar = gv
      -- What the last Create did belongs to the variable it was made for.
      ui.createResult = nil
      -- Normal and Alert are drawn only with a variable picked.
      ui.runtime.markDirty()
    end
  }
  if help.helpText then
    children[#children + 1] = {
      type = "button",
      x = pickerX + pickerW + HELP_BTN_GAP, y = y + math.floor((rowH - HELP_BTN_H) / 2),
      w = HELP_BTN_W, h = HELP_BTN_H,
      text = "?",
      press = function() help.onHelp(help.helpText, help.helpTitle) end
    }
  end
  children[#children + 1] = {
    type = "rectangle",
    x = x, y = y + rowH, w = w, h = 1,
    color = Palette.border, filled = true
  }
  return rowH + 1
end

local function appendNote(children, x, y, w, text)
  children[#children + 1] = {
    type = "label",
    x = x, y = y, w = w,
    text = text,
    color = Palette.text,
    font = SMLSIZE
  }
  return Controls.LABEL_H + 4
end

local function appendPercentField(children, x, y, w, labelText, key, help)
  return Controls.appendNumberField(
    children, x, y, w,
    labelText,
    {
      min = 0,
      max = 100,
      step = 5,
      suffix = "%",
      get = function() return ui.config[key] end,
      set = ui.runtime.getValueSetter(key),
      helpText = help.helpText,
      helpTitle = help.helpTitle,
      onHelp = help.onHelp
    }
  )
end

-- ─── Model chain and tests ───────────────────────────────────────────────────

-- A shared library through the suite's own module cache where there is one, so the page and the
-- tool use the same lib/audio.lua and lib/armed.lua rather than a second copy of each.
local function requireShared(path)
  if _G.rfsuite and _G.rfsuite.require then
    return _G.rfsuite.require(path)
  end
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/" .. path, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if ok then return mod end
  return nil
end

local function getAudio()
  if Audio == nil then Audio = requireShared("lib/audio.lua") or false end
  return Audio or nil
end

-- Why a test that writes into the model is refused right now: "armed", "uncertain" (the arming
-- state cannot be told: the link is up and no arming flags are reported), or nil when it is not.
-- It fails CLOSED: without lib/armed.lua, or with a question that raises, the page cannot tell,
-- and "cannot tell" is not "disarmed".
local function lockReason()
  if Armed == nil then Armed = requireShared("lib/armed.lua") or false end
  if type(Armed) ~= "table" or type(Armed.isArmed) ~= "function"
    or type(Armed.isUncertain) ~= "function" then return "uncertain" end
  local ok, armed = pcall(Armed.isArmed)
  if not ok then return "uncertain" end
  if armed == true then return "armed" end
  local okU, uncertain = pcall(Armed.isUncertain)
  if not okU or uncertain == true then return "uncertain" end
  return nil
end

-- What the model holds for the global variable being shown, read once per visit and per global
-- variable: on opening the page, on picking another one, and on Reload. Every other rebuild --
-- Connected only, a `?` sheet closing, the arming edge -- draws the same answer again, because a
-- walk reads every input, mix line, logical switch and special function of the model.
local function getDiagnosis(gv)
  if ui.diag and ui.diag.gv == gv then return ui.diag.result end
  if not Chain then Chain = loadModule("app/pages/settings/audio/volume/chain.lua") end
  local result = { readable = false }
  local base = gvarSourceBase()
  if base ~= nil then result = Chain.read(gv, base + gv - 1) end
  ui.diag = { gv = gv, result = result }
  return result
end

-- How long the Normal and Alarm tests hold their value before the earlier one is put back, in
-- getTime() ticks of 10 ms. There is no query for "has the radio finished speaking", so this is
-- an estimate: the sample is a word and a number, about two seconds, plus whatever was queued.
local TEST_HOLD_TICKS = 500

-- How often, in getTime() ticks of 10 ms, Master volume's test row asks for the arming state
-- again. The tool rebuilds the page on an arming edge, but not when the arming flags first arrive
-- or go away, so the page asks for that rebuild itself.
local LOCK_POLL_TICKS = 100

local pageWakeup

-- The page has a wakeup only while there is something for it to do: a test holding its value, or
-- Master volume's test row watching the arming state. ui/home.lua calls a page's wakeup on every
-- pass while the craft is not armed.
local function updateWakeup()
  if ui.test or ui.lockPoll then M.wakeup = pageWakeup else M.wakeup = nil end
end

-- A test's earlier value goes back only while the global variable still holds what the test
-- wrote. If something else wrote to it in between -- the suite's own master volume on a change of
-- the link, a critical alert -- that newer value is the one to keep. Should that writer have
-- written the very value the test held, the restore cannot tell; the suite is then told to write
-- what it wants again on its next refresh rather than trust what it wrote last.
local function restoreTest()
  local pending = ui.test
  ui.test = nil
  updateWakeup()
  if type(pending) ~= "table" or type(model) ~= "table" then return end
  if type(model.getGlobalVariable) ~= "function" or type(model.setGlobalVariable) ~= "function" then return end
  local ok, current = pcall(model.getGlobalVariable, pending.idx, 0)
  if ok and current == pending.wrote then
    pcall(model.setGlobalVariable, pending.idx, 0, pending.prev)
    local audio = getAudio()
    if audio and type(audio.forgetMasterVolume) == "function" then audio.forgetMasterVolume() end
  end
end

-- Called only while the craft is NOT armed; the arming edge is covered by the rebuild it causes
-- (see M.build). A test holding its value puts the earlier one back after the hold. Once a second
-- the page asks for the arming state again and rebuilds when the answer has changed -- the flags
-- arriving, or going away, is no arming edge -- and the rebuild puts a held value back at once
-- when the answer is no longer "disarmed".
pageWakeup = function()
  local now = getTime and getTime() or 0
  local pending = ui.test
  if pending and now >= pending.untilTick then restoreTest() end
  local poll = ui.lockPoll
  if poll and now >= poll.nextTick then
    poll.nextTick = now + LOCK_POLL_TICKS
    if lockReason() ~= poll.reason then
      ui.lockPoll = nil
      updateWakeup()
      if ui.test then restoreTest() end
      if type(poll.rebuild) == "function" then poll.rebuild() end
    end
  end
end

-- Normal or Alarm: the global variable at that level, the sample at the radio's own Wav volume
-- (the master volume carries the level), then the earlier value back. Not an edit of the page.
local function startMasterTest(gv, pct)
  if lockReason() ~= nil then return end
  local result = ui.diag and ui.diag.gv == gv and ui.diag.result
  if not (result and result.complete) then return end
  local audio = getAudio()
  if not audio or type(audio.volumeRaw) ~= "function" or type(audio.playSample) ~= "function" then return end
  if type(model) ~= "table" or type(model.getGlobalVariable) ~= "function"
    or type(model.setGlobalVariable) ~= "function" then return end
  -- A second press inside the hold starts from the value before the first one.
  restoreTest()
  local idx = gv - 1
  local ok, prev = pcall(model.getGlobalVariable, idx, 0)
  if not ok or prev == nil then return end
  local raw = audio.volumeRaw(tonumber(pct) or 0)
  -- Every accepted model.setGlobalVariable marks the model for a save, so a level the variable
  -- already holds -- the suite's own Normal, most of the time -- is played without a write and
  -- without a restore.
  if raw ~= prev then
    if not pcall(model.setGlobalVariable, idx, 0, raw) then return end
    ui.test = { idx = idx, prev = prev, wrote = raw, untilTick = (getTime and getTime() or 0) + TEST_HOLD_TICKS }
    updateWakeup()
  end
  audio.playSample(nil)
end

-- A row of buttons with the row's label on the left and its `?` on the right, in the places
-- appendComboSelect uses. `buttons` is { { text, press, active }, ... }, drawn left to right and
-- appended in that order, so the rotary reaches them before the row's `?`, as on every other row.
-- A button is as wide as its text in the button's font (the radio's standard font), with room for
-- the button's own padding, and never narrower than TEST_BTN_W.
local TEST_BTN_W, TEST_BTN_GAP, TEST_BTN_PAD = 84, 6, 28

local function buttonWidth(text)
  local fn = lcd and lcd.sizeText
  local w = nil
  if type(fn) == "function" then
    local ok, tw = pcall(fn, text, 0)
    if ok then w = tonumber(tw) end
  end
  if w == nil then w = #text * 7 end
  return math.max(TEST_BTN_W, w + TEST_BTN_PAD)
end

local function appendButtonRow(children, x, y, w, labelText, buttons, help)
  local rowH = Controls.ROW_H
  local right = x + w - 10
  local helpX = nil
  if help.helpText then
    helpX = right - HELP_BTN_W
    right = helpX - HELP_BTN_GAP
  end
  local widths, total = {}, math.max(#buttons - 1, 0) * TEST_BTN_GAP
  for i, b in ipairs(buttons) do
    widths[i] = buttonWidth(b.text)
    total = total + widths[i]
  end
  local left = right - total
  children[#children + 1] = {
    type = "label",
    x = x, y = Controls.labelY(y, rowH), w = left - x - 8,
    text = labelText, color = Palette.text, font = SMLSIZE
  }
  local bx = left
  for i, b in ipairs(buttons) do
    children[#children + 1] = {
      type = "button",
      x = bx, y = Controls.controlY(y, rowH),
      w = widths[i], h = Controls.CTRL_H,
      text = b.text,
      active = b.active,
      press = b.press
    }
    bx = bx + widths[i] + TEST_BTN_GAP
  end
  if helpX then
    children[#children + 1] = {
      type = "button",
      x = helpX, y = y + math.floor((rowH - HELP_BTN_H) / 2),
      w = HELP_BTN_W, h = HELP_BTN_H,
      text = "?",
      press = function() help.onHelp(help.helpText, help.helpTitle) end
    }
  end
  children[#children + 1] = {
    type = "rectangle",
    x = x, y = y + rowH, w = w, h = 1,
    color = Palette.border, filled = true
  }
  return rowH + 1
end

-- The diagnosis: a heading row with the chain recipe behind its `?`, one line per link -- the
-- slot found and OK, or what is wrong -- then a line per warning. Returns the height drawn.
-- Names as EdgeTX shows them: an input by its name (or its number behind the input symbol), a
-- switch by its position name (L01..L64, SA..), a special function by its number.
local function sourceName(source)
  local ok, name = false, nil
  if type(_G.getSourceName) == "function" and source then ok, name = pcall(_G.getSourceName, source) end
  if ok and type(name) == "string" and name ~= "" then return name end
  return tostring(source)
end

local function switchName(switch)
  local ok, name = false, nil
  if type(_G.getSwitchName) == "function" and switch then ok, name = pcall(_G.getSwitchName, switch) end
  if ok and type(name) == "string" and name ~= "" then return name end
  return tostring(switch)
end

local function slotName(kind, slot, key)
  if kind == "input" then
    if key then return sourceName(key) end
    return string.format("I%d", slot + 1)
  elseif kind == "ls" then
    if key then return switchName(key) end
    return string.format("L%02d", slot + 1)
  end
  return string.format("SF%d", slot + 1)
end

local function appendDiagnosis(children, x, y, w, i18n, gv, result, help)
  local startY = y
  local headLabel = t(i18n, "chain", "Model chain")
  y = y + appendButtonRow(children, x, y, w, headLabel, {}, help)
  local function line(text)
    y = y + appendNote(children, x, y + 2, w, text)
  end
  if not result.readable then
    line(t(i18n, "chain_unreadable", "This radio does not answer the questions the check needs."))
    return y - startY
  end
  local okText = t(i18n, "chain_ok", "OK")
  local inputName = result.input and slotName("input", result.input, result.inputSource)
  local lsName = result.ls and slotName("ls", result.ls, result.lsSwitch)

  local inputLabel = t(i18n, "chain_input", "Input")
  if inputName then
    line(string.format("%s: %s  %s", inputLabel, inputName, okText))
  else
    line(string.format(t(i18n, "chain_input_none", "%s: none has GV%d as its source"), inputLabel, gv))
  end

  local lsLabel = t(i18n, "chain_ls", "Logical switch")
  if lsName then
    line(string.format("%s: %s  %s", lsLabel, lsName, okText))
  elseif result.lsWrongX then
    line(string.format(t(i18n, "chain_ls_wrong_x", "%s: %s is GV%d > %d, it needs -1024"),
      lsLabel, slotName("ls", result.lsWrongX.slot, nil), gv, result.lsWrongX.x or 0))
  else
    line(string.format(t(i18n, "chain_ls_none", "%s: none is a > x with GV%d and -1024"), lsLabel, gv))
  end

  local sfLabel = t(i18n, "chain_sf", "Special function")
  if result.complete then
    line(string.format("%s: %s  %s", sfLabel, slotName("sf", result.sf), okText))
  elseif result.sfFault and result.sfFault.kind == "source" then
    line(string.format(t(i18n, "chain_sf_source", "%s: %s takes %s as its source, not the input"),
      sfLabel, slotName("sf", result.sfFault.slot), sourceName(result.sfFault.source)))
  elseif result.sfFault then
    line(string.format(t(i18n, "chain_sf_switch", "%s: %s is switched by %s, not by a logical switch above"),
      sfLabel, slotName("sf", result.sfFault.slot), switchName(result.sfFault.switch)))
  else
    line(string.format(t(i18n, "chain_sf_none", "%s: no Volume function joins the two"), sfLabel))
  end

  local warn = result.warn or {}
  if warn.popup then line(t(i18n, "gvar_popup_warning", "Note: This GV has 'Popup' enabled in EdgeTX model settings.")) end
  if warn.gvModes then
    -- As EdgeTX names the flight modes (FM1..FM8).
    local names = {}
    for _, fm in ipairs(warn.gvModes) do names[#names + 1] = "FM" .. tostring(fm) end
    line(string.format(t(i18n, "chain_warn_gv_modes", "Warning: in %s, GV%d has its own value, not the suite's."),
      table.concat(names, ", "), gv))
  end
  if warn.weight then line(string.format(t(i18n, "chain_warn_weight", "Warning: the input's weight is %d, not 100."), warn.weight)) end
  if warn.offset then line(string.format(t(i18n, "chain_warn_offset", "Warning: the input has an offset of %d."), warn.offset)) end
  if warn.curve then line(t(i18n, "chain_warn_curve", "Warning: the input has a curve.")) end
  if warn.inputSwitch then line(t(i18n, "chain_warn_input_switch", "Warning: the input has a switch.")) end
  if warn.flightModes then line(t(i18n, "chain_warn_flight_modes", "Warning: the input is limited to some flight modes.")) end
  if warn.side then
    -- As the input's Side choice names it (EdgeTX's x>0 for the positive half, x<0 for the other).
    local side = (warn.side == 2 and "x>0") or (warn.side == 1 and "x<0") or tostring(warn.side)
    line(string.format(t(i18n, "chain_warn_side", "Warning: the input's Side is %s, not both sides."), side))
  end
  if warn.lines then
    line(string.format(t(i18n, "chain_warn_lines", "Warning: the input has %d lines; the first one that is on is used."), warn.lines))
  end
  if warn.andSwitch then line(t(i18n, "chain_warn_and", "Warning: the logical switch has an AND switch.")) end
  if warn.delay then line(t(i18n, "chain_warn_delay", "Warning: the logical switch has a delay.")) end
  if warn.duration then line(t(i18n, "chain_warn_duration", "Warning: the logical switch has a duration.")) end
  if warn.sfOff then line(t(i18n, "chain_warn_sf_off", "Warning: the special function is switched off.")) end
  if warn.secondSf then
    line(string.format(t(i18n, "chain_warn_second_sf", "Warning: %s is a second Volume function that is on."),
      slotName("sf", warn.secondSf)))
  end
  return y - startY
end

-- ─── Creating the chain ──────────────────────────────────────────────────────

-- Why Create cannot go ahead, as the line under it says it. A faulty link is named by the check
-- above; Create never changes a link that is there.
local function blockedText(i18n, why)
  if why == "no_input" then return t(i18n, "create_no_input", "No free input is left.") end
  if why == "no_input_named" then
    return t(i18n, "create_no_input_named", "No free input: the empty ones are still named elsewhere.")
  end
  if why == "no_lines" then return t(i18n, "create_no_lines", "All 64 input lines are used.") end
  if why == "no_ls" then return t(i18n, "create_no_ls", "No free logical switch is left.") end
  if why == "no_ls_named" then
    return t(i18n, "create_no_ls_named", "No free logical switch: the empty ones are still named elsewhere.")
  end
  if why == "no_sf" then return t(i18n, "create_no_sf", "No free special function is left.") end
  return t(i18n, "create_blocked_fault", "A link above is faulty. Create changes no link: fix it by hand, then open the page again.")
end

-- EdgeTX's CHAR_INPUT (radio/src/translations/untranslated.h), which it draws before the number of
-- an input that has no name of its own.
local INPUT_SYMBOL = "\xC2\x8E"

-- A link's name as EdgeTX shows it once the link is there. EdgeTX names only a slot that is in use
-- (getSourceName / getSwitchName answer nil for an empty one), so a slot still to be written is
-- named the way EdgeTX names it after the write (radio/src/strhelpers.cpp): the input symbol and a
-- two-digit number, or L01..L64.
local function linkName(read, kind, slot)
  if kind == "input" then
    local ok, name = false, nil
    if type(_G.getSourceName) == "function" then ok, name = pcall(_G.getSourceName, read.firstInput + slot) end
    if ok and type(name) == "string" and name ~= "" then return name end
    return INPUT_SYMBOL .. string.format("%02d", slot + 1)
  end
  if kind == "ls" then
    local ok, name = false, nil
    if type(_G.getSwitchName) == "function" then ok, name = pcall(_G.getSwitchName, read.lsBase + slot) end
    if ok and type(name) == "string" and name ~= "" then return name end
    return string.format("L%02d", slot + 1)
  end
  return slotName("sf", slot)
end

-- The preview: one line per link, as EdgeTX's own lists show it, the links that are there as
-- "present", then that nothing else changes.
local function previewText(i18n, gv, read, plan)
  local gvName = sourceName(read.gvSource)
  local inputName = linkName(read, "input", plan.input.slot)
  local lsName = linkName(read, "ls", plan.ls.slot)
  local sfName = linkName(read, "sf", plan.sf.slot)
  local present = t(i18n, "create_present", "%s %s: present")
  local lines = {}
  if plan.input.create then
    lines[#lines + 1] = string.format(t(i18n, "create_input", "Input %s: %s, weight 100%%"), inputName, gvName)
  else
    lines[#lines + 1] = string.format(present, t(i18n, "chain_input", "Input"), inputName)
  end
  if plan.ls.create then
    lines[#lines + 1] = string.format(t(i18n, "create_ls", "Logical switch %s: a>x %s -1024"), lsName, gvName)
  else
    lines[#lines + 1] = string.format(present, t(i18n, "chain_ls", "Logical switch"), lsName)
  end
  lines[#lines + 1] = string.format(t(i18n, "create_sf", "Special function %s: %s Volume %s"), sfName, lsName, inputName)
  lines[#lines + 1] = t(i18n, "create_note", "Nothing else in the model changes, and the suite never removes these.")
  return table.concat(lines, "\n")
end

local function createAvailable()
  return type(model) == "table" and type(model.insertInput) == "function"
    and type(model.setLogicalSwitch) == "function" and type(model.setCustomFunction) == "function"
    and lvgl ~= nil and type(lvgl.confirm) == "function"
end

-- Whether the settings the suite acts on -- the stored preferences, which lib/audio.lua reads --
-- are Master volume with global variable `gv`. Until they are, the suite does not drive that
-- variable, and a chain created for it would set the volume from whatever value it holds.
local function savedFor(gv)
  local prefs = ui.prefs
  local audio = type(prefs) == "table" and prefs.audio or nil
  if type(audio) ~= "table" then return false end
  return Rules.mode(audio) == MODE_MASTER and tonumber(audio.master_gvar) == gv
end

-- What the line under Create says after a Yes, from the check run again on the model as it is
-- now -- that check is what says whether the chain was made, not the writes returning.
local function createOutcome(i18n, gv, read, plan, out)
  local names = {}
  for _, kind in ipairs(out.created) do names[#names + 1] = linkName(read, kind, plan[kind].slot) end
  local list = table.concat(names, ", ")
  ui.diag = nil
  local after = getDiagnosis(gv)
  if out.failed then
    local failedName = linkName(read, out.failed, plan[out.failed].slot)
    if #names == 0 then
      return string.format(t(i18n, "create_failed", "%s could not be written; nothing was created."), failedName)
    end
    return string.format(t(i18n, "create_partial",
      "Created %s; then %s could not be written. Nothing was removed; Create offers the rest."), list, failedName)
  end
  if after.complete then
    return string.format(t(i18n, "create_done", "Created %s. The check above reads the chain complete."), list)
  end
  return string.format(t(i18n, "create_incomplete", "Created %s, but the check above does not read the chain complete."), list)
end

-- Yes in the preview. The dialog may have stood for a while: the arming state, the page's mode and
-- global variable and the model are all read again, and nothing is written unless the model still
-- asks for exactly the links the preview listed.
local function confirmCreate(i18n, gv, shown)
  if not ui.loaded or ui.config.volume_mode ~= MODE_MASTER or (tonumber(ui.config.master_gvar) or 0) ~= gv then return end
  local function finish(text)
    ui.createResult = { gv = gv, text = text }
    if type(ui.rebuild) == "function" then ui.rebuild() end
  end
  -- Locked at Yes, or the settings not saved for this variable: nothing is written, and no result
  -- is kept -- the rebuild draws the reason under Create, which goes away with it.
  if lockReason() ~= nil or not savedFor(gv) then
    ui.createResult = nil
    if type(ui.rebuild) == "function" then ui.rebuild() end
    return
  end
  ui.diag = nil
  local read = getDiagnosis(gv)
  local plan = Chain.plan(read)
  if not Chain.samePlan(plan, shown) then
    return finish(t(i18n, "create_changed", "The model changed since the preview; nothing was written."))
  end
  if not Create then Create = loadModule("app/pages/settings/audio/volume/create.lua") end
  local out = Create.write(plan, read)
  finish(createOutcome(i18n, gv, read, plan, out))
end

local function startCreate(i18n, gv)
  if lockReason() ~= nil or not savedFor(gv) or not createAvailable() then return end
  local read = ui.diag and ui.diag.gv == gv and ui.diag.result
  local plan = read and Chain.plan(read)
  if not plan or plan.blocked then return end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  -- No fallback: without the preview nothing is written.
  ConfirmDialog.show({
    title = t(i18n, "create_title", "Create the chain?"),
    message = previewText(i18n, gv, read, plan),
    onConfirm = function() confirmCreate(i18n, gv, plan) end,
    onCancel = function() end
  })
end

-- The Create row, under the check: shown while the chain is not complete. Its button opens the
-- preview; the line under it says why it cannot, or what the last Yes did.
local function appendCreate(children, x, y, w, i18n, gv, read, reason, help)
  local startY = y
  local plan = Chain.plan(read)
  local result = ui.createResult and ui.createResult.gv == gv and ui.createResult.text or nil
  if plan then
    local saved = savedFor(gv)
    local usable = reason == nil and saved and not plan.blocked and createAvailable()
    local function isUsable() return usable end
    local label = t(i18n, "create", "Create")
    y = y + appendButtonRow(children, x, y, w, label, {
      { text = t(i18n, "create_preview", "Preview"), active = isUsable, press = function() startCreate(i18n, gv) end },
    }, help)
    local note = nil
    if reason == "armed" then
      note = t(i18n, "test_locked_armed", "Locked while the model is armed.")
    elseif reason == "uncertain" then
      note = t(i18n, "test_locked_uncertain", "Locked: the arming state is not known.")
    elseif plan.blocked then
      -- Before the save line: saving alone would not make Create available.
      note = blockedText(i18n, plan.blocked)
    elseif not createAvailable() then
      -- Nor would it on a radio that cannot write the chain.
      note = t(i18n, "create_no_api", "This radio cannot write the chain from a script.")
    elseif not saved then
      note = t(i18n, "create_save_first", "Save the page first: Create works on the saved Mode and GV.")
    end
    if note then y = y + appendNote(children, x, y + 2, w, note) end
  end
  -- While locked, the lock's reason stands alone under Create; otherwise what the last Yes did
  -- stands under any other reason.
  if result and reason == nil then y = y + appendNote(children, x, y + 2, w, result) end
  return y - startY
end

-- ─── Module API ──────────────────────────────────────────────────────────────

function M.getHeaderActions()
  ensureDeps()
  return { save = true, help = true }
end

function M.onReload(ctx)
  ensureDeps()
  -- Reload reads the model again too, after any test has put its value back.
  restoreTest()
  ui.diag = nil
  ui.createResult = nil
  copyFromPrefs(ctx.preferences)
  ui.dirty = false
end

function M.onSave(ctx)
  ensureDeps()
  if type(ctx.preferences.audio) ~= "table" then ctx.preferences.audio = {} end

  -- Every key, the other mode's included: picking a mode leaves the other one's settings in the
  -- file, so switching back finds them as they were.
  for _, field in ipairs(CONFIG_SCHEMA) do
    ctx.preferences.audio[field.key] = ui.config[field.key]
  end
  -- Saved in Off with Connected only never set, it stays out of the file, so a mode picked later
  -- still starts from that mode's own reading of it.
  if not ui.connectedOnlySet and ui.config.volume_mode == MODE_OFF then
    ctx.preferences.audio.connected_only = nil
  end
  local ok, err = ctx.savePreferences()
  if ok then
    ui.dirty = false
    ui.connectedOnlySet = ctx.preferences.audio.connected_only ~= nil
    -- The file now holds `volume_mode` (and Connected only, unless saved in Off without it set), so it
    -- no longer reads the way a file before the setting did.
    ui.masterBeforeSetting = false
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({ ok = true, title = t(ctx.i18n, "saved_title", "Saved"), message = t(ctx.i18n, "saved_message", "Settings saved") })
    end
  else
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({ title = t(ctx.i18n, "save_error_title", "Error"), message = t(ctx.i18n, "save_error_message", "Save failed") .. ": " .. Common.saveFailureReason(ctx.i18n, err) })
    end
  end
end

-- One mode at a time: the selector, Connected only under it, then the chosen mode's rows. A row a
-- mode gains later goes after that mode's last row, so the rows above it stay where they are.
function M.build(ctx)
  ensureDeps()
  ensureLoaded(ctx.preferences)

  local children = ctx.children
  local x, w = ctx.x, ctx.w
  local i18n = ctx.i18n
  local cursorY = ctx.y
  local mode = ui.config.volume_mode

  ui.runtime.setRequestRebuild(ctx.requestRebuild)
  ui.runtime.openHelp = ctx.openHelp
  ui.rebuild = ctx.requestRebuild
  -- Only Master volume's tests wait for the arming state; it sets this again below.
  ui.lockPoll = nil
  updateWakeup()
  -- A test still holding its value goes back on the rebuild an arming edge causes, whichever mode
  -- the page shows by then: while armed the page has no wakeup to do it later.
  if ui.test and lockReason() ~= nil then restoreTest() end

  local modeLabel = t(i18n, "mode", "Mode")
  cursorY = cursorY + Controls.appendComboSelect(
    children, x, cursorY, w,
    modeLabel,
    getModeOptions(i18n),
    mode,
    onModeSelected,
    helpOpts(t(i18n, "help_mode"), modeLabel)
  )

  if mode ~= MODE_LEVEL and mode ~= MODE_MASTER then return end

  local connectedLabel = t(i18n, "connected_only", "Connected only")
  cursorY = cursorY + Controls.appendRadioSwitch(
    children, x, cursorY, w,
    connectedLabel,
    ui.config.connected_only,
    onConnectedOnlySet,
    nil,
    helpOpts(t(i18n, "help_connected_only"), connectedLabel)
  )

  if mode == MODE_LEVEL then
    local levelLabel = t(i18n, "level", "Level")
    cursorY = cursorY + Controls.appendComboSelect(
      children, x, cursorY, w,
      levelLabel,
      getLevelOptions(),
      ui.config.level,
      ui.runtime.getValueSetter("level"),
      helpOpts(t(i18n, "help_level"), levelLabel)
    )
    -- The level shown, saved or not: the combo's setter has already put it in ui.config. Armed
    -- or not -- it writes nothing.
    local testLabel = t(i18n, "test", "Test")
    appendButtonRow(children, x, cursorY, w, testLabel, {
      { text = t(i18n, "test_play", "Play"),
        press = function()
          local audio = getAudio()
          if audio and type(audio.playSample) == "function" then audio.playSample(ui.config.level) end
        end }
    }, helpOpts(t(i18n, "help_test_level"), testLabel))
    return
  end

  local gvarLabel = t(i18n, "master_gvar", "Global Variable")
  cursorY = cursorY + appendGvarPicker(children, x, cursorY, w,
    gvarLabel, helpOpts(t(i18n, "help_master_gvar"), gvarLabel))

  local gv = tonumber(ui.config.master_gvar) or 0
  if gv <= 0 then
    -- Master volume with no variable picked writes nothing (lib/audio.lua); said here, so the
    -- mode is not taken for one that acts.
    local none = t(i18n, "gvar_none", "No global variable picked, so the master volume does nothing yet. Pick one above.")
    appendNote(children, x, cursorY + 2, w, none)
    return
  end
  if not Rules.gvarOnBoard(gv) then
    -- Kept in the file and not acted on (lib/audio.lua); said here, so the picker showing none is
    -- not taken for a setting that was never made.
    local missing = t(i18n, "gvar_missing", "GV%d is not on this radio, so the master volume is off. Pick one it has.")
    appendNote(children, x, cursorY + 2, w, string.format(missing, math.tointeger(math.floor(math.min(gv, 99999))) or 0))
    return
  end

  local normalLabel = t(i18n, "master_normal", "Normal")
  cursorY = cursorY + appendPercentField(children, x, cursorY, w, normalLabel, "master_normal",
    helpOpts(t(i18n, "help_master_normal"), normalLabel))

  local alertLabel = t(i18n, "master_alert", "Alert")
  cursorY = cursorY + appendPercentField(children, x, cursorY, w, alertLabel, "master_alert",
    helpOpts(t(i18n, "help_master_alert"), alertLabel))

  -- Whether the model carries the chain this global variable needs (its popup included).
  local result = getDiagnosis(gv)
  local chainLabel = t(i18n, "chain", "Model chain")
  cursorY = cursorY + appendDiagnosis(children, x, cursorY, w, i18n, gv, result,
    helpOpts(t(i18n, "help_chain"), chainLabel))

  -- Normal and Alarm write into the model, so they wait for a disarmed craft and a complete
  -- chain; the reason stands under them while they wait. An arming edge rebuilds the page, and a
  -- test still holding its value has then been put back at the top of the build.
  local reason = lockReason()
  -- The arming flags arriving or going away is no arming edge, so nothing would rebuild the page
  -- for it; while not armed the page asks itself, once a second.
  if reason ~= "armed" then
    ui.lockPoll = { reason = reason, rebuild = ctx.requestRebuild,
      nextTick = (getTime and getTime() or 0) + LOCK_POLL_TICKS }
    updateWakeup()
  end
  -- Create, while the chain is not complete; locked on the same reasons as the tests, and until
  -- the mode and global variable shown are saved (the host rebuilds the page after a save).
  ui.prefs = ctx.preferences
  local createLabel = t(i18n, "create", "Create")
  cursorY = cursorY + appendCreate(children, x, cursorY, w, i18n, gv, result, reason,
    helpOpts(t(i18n, "help_create"), createLabel))

  local usable = reason == nil and result.complete == true
  local function isUsable() return usable end
  local testLabel = t(i18n, "test", "Test")
  cursorY = cursorY + appendButtonRow(children, x, cursorY, w, testLabel, {
    { text = t(i18n, "test_normal", "Normal"), active = isUsable,
      press = function() startMasterTest(gv, ui.config.master_normal) end },
    { text = t(i18n, "test_alarm", "Alarm"), active = isUsable,
      press = function() startMasterTest(gv, ui.config.master_alert) end },
  }, helpOpts(t(i18n, "help_test_master"), testLabel))
  if reason == "armed" then
    appendNote(children, x, cursorY + 2, w, t(i18n, "test_locked_armed", "Locked while the model is armed."))
  elseif reason == "uncertain" then
    appendNote(children, x, cursorY + 2, w, t(i18n, "test_locked_uncertain", "Locked: the arming state is not known."))
  elseif not usable then
    appendNote(children, x, cursorY + 2, w, t(i18n, "test_locked_chain", "Needs the whole chain above."))
  end
end

function M.onClose()
  -- A test still holding its value puts the earlier one back before the page goes, and nothing
  -- read from the model outlives the visit (resetPageState clears only what it knows of).
  ui.lockPoll = nil
  restoreTest()
  ui.diag = nil
  ui.createResult = nil
  ui.rebuild = nil
  ui.prefs = nil
  Common.resetPageState(ui)
  Chain = nil
  Armed = nil
  Audio = nil
  Create = nil
  ConfirmDialog = nil
  Controls = nil
  Common = nil
  Rules = nil
  t = nil
end

-- Asked before the page is left (ui/home.lua): true while an edit here is not saved.
function M.hasUnsavedChanges()
  return ui.dirty == true
end

return M
