local M = {}
local function load(path) return assert(loadScript("/SCRIPTS/TOOLS/rfsuite-core/" .. path, "t"))() end
local Palette = _G.rfsuite and _G.rfsuite.palette or (_G.rfsuite and _G.rfsuite.require or load)("ui/palette.lua")
local Common, Controls, Standby, t
local NOTE_LINE_H = 24
local ui = { loaded = false, dirty = false, enabled = false, rows = {}, runtime = nil, salvaged = false }

local function deps()
  Common = Common or load("app/pages/settings/common.lua")
  Controls = Controls or load("ui/controls.lua")
  Standby = Standby or load("widgets/dashboard/standby.lua")
  ui.runtime = ui.runtime or Common.createFormRuntime(ui)
  t = t or Common.pageT("settings_dashboard_standby")
end

local function fromPrefs(prefs)
  local dashboard = type(prefs.dashboard) == "table" and prefs.dashboard or {}
  ui.enabled = dashboard[Standby.KEY_ENABLED] == true
  local items, err = Standby.decode(dashboard[Standby.KEY_LAYOUT])
  ui.rows, ui.salvaged = Standby.toRows(items), err ~= nil
end

local function ensure(prefs) if not ui.loaded then fromPrefs(prefs); ui.loaded = true end end

local function typeLabel(i18n, id)
  if id == "clock" then return t(i18n, "module_clock", "Clock") end
  if id == "date" then return t(i18n, "module_date", "Date") end
  if id == "tx_battery" then return t(i18n, "module_tx_battery", "TX battery") end
  if id == "model" then return t(i18n, "module_model", "Selected model") end
  if id == "timer1" then return t(i18n, "module_timer1", "Timer 1") end
  if id == "timer2" then return t(i18n, "module_timer2", "Timer 2") end
  if id == "timer3" then return t(i18n, "module_timer3", "Timer 3") end
  if id == "tx_gps" then return t(i18n, "module_tx_gps", "TX GPS") end
  if id == "uptime" then return t(i18n, "module_uptime", "Radio uptime") end
  if id == "firmware" then return t(i18n, "module_firmware", "Firmware") end
  if id == "elrs" then return t(i18n, "module_elrs", "ELRS TX configuration") end
  return id
end

local function typeOptions(ids, labels)
  local out = {}
  for i = 1, #ids do out[#out + 1] = { value = ids[i], label = labels[ids[i]] } end
  return out
end

local function fitLabels(i18n)
  local labels = {}
  for i = 1, #Standby.TYPES do local id = Standby.TYPES[i]; labels[id] = typeLabel(i18n, id) end
  labels.elrs_last_read = t(i18n, "elrs_last_read", "Last read %d s ago")
  labels.elrs_rate_short = t(i18n, "elrs_rate_short", "Rate")
  labels.elrs_ratio_short = t(i18n, "elrs_ratio_short", "TLM")
  labels.elrs_power_short = t(i18n, "elrs_power_short", "Max")
  labels.elrs_dynamic_short = t(i18n, "elrs_dynamic_short", "Dyn")
  labels.gps_no_fix = t(i18n, "gps_no_fix", "No fix")
  labels.gps_latitude = t(i18n, "gps_latitude", "Latitude")
  labels.gps_longitude = t(i18n, "gps_longitude", "Longitude")
  labels.gps_course = t(i18n, "gps_course", "Course")
  labels.gps_hdop = t(i18n, "gps_hdop", "HDOP")
  labels.gps_satellites = t(i18n, "gps_satellites", "Sat")
  labels.gps_time_unavailable = t(i18n, "gps_time_unavailable", "Time status unknown")
  return labels
end

local function appendNote(children, x, y, w, text, color)
  children[#children + 1] = { type = "label", x = x, y = y, w = w, text = text, color = color, font = SMLSIZE }
  if lcd and type(lcd.sizeText) == "function" then
    local textWidth = lcd.sizeText(text, SMLSIZE)
    if type(textWidth) == "number" and textWidth <= w then return NOTE_LINE_H end
  end
  if type(Controls.estimateWrappedTextHeight) == "function" then
    local height = Controls.estimateWrappedTextHeight(text, w, SMLSIZE)
    if type(height) == "number" and height > NOTE_LINE_H then return height end
  end
  return NOTE_LINE_H
end

local function appendLine(children, x, y, w, text, color)
  children[#children + 1] = { type = "label", x = x, y = y, w = w, text = text, color = color, font = SMLSIZE }
  return NOTE_LINE_H
end

local function button(children, x, y, w, text, press)
  children[#children + 1] = { type = "button", x = x, y = y, w = w, h = 36, text = text, press = press }
end

local function firstNewType(ids, row)
  local used = {}
  for i = 1, #row do used[row[i].type] = true end
  for i = 1, #ids do if not used[ids[i]] then return ids[i] end end
  return ids[1]
end

function M.getHeaderActions() deps(); return { save = true, help = true } end
function M.onReload(ctx) deps(); fromPrefs(ctx.preferences); ui.dirty = false end

function M.onSave(ctx)
  deps()
  local items = Standby.fromRows(ui.rows)
  local valid, reason = Standby.validate(items, LCD_W or 480, LCD_H or 320, fitLabels(ctx.i18n))
  if ui.enabled and not valid then
    local message = reason == "empty" and t(ctx.i18n, "fit_empty", "Add at least one row before saving.")
      or t(ctx.i18n, "invalid_message", "Every field must fit readably in its row.")
    ctx.reportSave({ title = t(ctx.i18n, "invalid_title", "Layout not saved"), message = message })
    return
  end
  local encodedLayout = valid and Standby.encode(items) or nil
  ctx.preferences.dashboard = ctx.preferences.dashboard or {}
  local previousEnabled = ctx.preferences.dashboard[Standby.KEY_ENABLED]
  local previousLayout = ctx.preferences.dashboard[Standby.KEY_LAYOUT]
  ctx.preferences.dashboard[Standby.KEY_ENABLED] = ui.enabled
  if encodedLayout ~= nil then ctx.preferences.dashboard[Standby.KEY_LAYOUT] = encodedLayout end
  local ok, err = ctx.savePreferences()
  if ok then
    ui.dirty = false
    ctx.reportSave({ ok = true, title = t(ctx.i18n, "saved_title", "Saved"),
      message = t(ctx.i18n, "saved_message", "Standby screen saved") })
  else
    ctx.preferences.dashboard[Standby.KEY_ENABLED] = previousEnabled
    ctx.preferences.dashboard[Standby.KEY_LAYOUT] = previousLayout
    ctx.reportSave({ title = t(ctx.i18n, "save_error_title", "Error"),
      message = t(ctx.i18n, "save_error_message", "Save failed") .. ": "
        .. Common.saveFailureReason(ctx.i18n, err) })
  end
end

function M.build(ctx)
  deps(); ensure(ctx.preferences); ui.runtime.setRequestRebuild(ctx.requestRebuild)
  local children, x, w, i18n, y = ctx.children, ctx.x, ctx.w, ctx.i18n, ctx.y
  local screenW, screenH = LCD_W or 480, LCD_H or 320
  local labels, geometry = fitLabels(i18n), Standby.geometry(screenW, screenH)
  local idsByCount, choicesByCount, measureCache = {}, {}, {}
  local rowFormat = t(i18n, "row", "Row %d")
  local fieldFormat = t(i18n, "field", "Field %d")
  local removeField = t(i18n, "remove_field", "Remove field")
  local removeRow = t(i18n, "remove_row", "Remove row")
  local function options(count, wantChoices)
    if idsByCount[count] == nil then
      idsByCount[count] = Standby.typesForField(screenW, screenH, count, labels, measureCache, geometry)
    end
    if wantChoices and choicesByCount[count] == nil then
      choicesByCount[count] = typeOptions(idsByCount[count], labels)
    end
    return idsByCount[count], choicesByCount[count]
  end
  y = y + Controls.appendRadioSwitch(children, x, y, w, t(i18n, "enabled", "Standby screen"), ui.enabled,
    function(value) ui.enabled = value == true; ui.dirty = true; ctx.requestRebuild() end)
  if ui.salvaged then
    y = y + appendNote(children, x, y, w,
      t(i18n, "saved_entries_skipped", "Unsupported saved entries were skipped."), Palette.warning)
  end
  for rowNumber = 1, #ui.rows do
    local row = ui.rows[rowNumber]
    y = y + appendLine(children, x, y, w, string.format(rowFormat, rowNumber),
      Palette.accent)
    local _, choices = options(#row, true)
    for field = 1, #row do
      y = y + Controls.appendComboSelect(children, x, y, w,
        string.format(fieldFormat, field), choices, row[field].type,
        function(value) row[field].type = value; ui.salvaged = false; ui.dirty = true; ctx.requestRebuild() end)
      if #row > 1 then
        button(children, x, y, w, removeField, function()
          table.remove(row, field); ui.dirty = true; ctx.requestRebuild()
        end)
        y = y + 42
      end
    end
    local nextType = #row < geometry.maxFields
      and Standby.firstAddableType(row, screenW, screenH, labels, measureCache, geometry) or nil
    local half = math.floor((w - 6) / 2)
    if nextType then
      button(children, x, y, half, t(i18n, "add_field", "+ Field"), function()
        row[#row + 1] = { type = nextType }
        ui.dirty = true; ctx.requestRebuild()
      end)
    end
    button(children, x + half + 6, y, half, removeRow, function()
      table.remove(ui.rows, rowNumber); ui.dirty = true; ctx.requestRebuild()
    end)
    y = y + 42
  end
  if #ui.rows < geometry.maxRows then
    local ids = options(1)
    if #ids > 0 then
      button(children, x, y, w, t(i18n, "add_row", "+ Row"), function()
        ui.rows[#ui.rows + 1] = { { type = firstNewType(ids, {}) } }
        ui.dirty = true; ctx.requestRebuild()
      end)
    end
  end
end

function M.onClose() Common.resetPageState(ui); Common, Controls, Standby, t = nil, nil, nil, nil end
function M.hasUnsavedChanges() return ui.dirty == true end
return M
