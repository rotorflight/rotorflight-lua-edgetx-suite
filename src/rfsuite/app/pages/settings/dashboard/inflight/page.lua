-- Settings > Dashboard > In-flight tuning: radio wiring shared by all models.
-- Suggested flight-controller functions and the model flight list are configured from the
-- tuning screen on the ground. This page loads only the radio setup and its sliced model walks.

local function loadModule(path)
  local fullPath = _G.rfsuite.paths.core .. "/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  return chunk()
end

local Palette = _G.rfsuite and _G.rfsuite.palette or (_G.rfsuite and _G.rfsuite.require or loadModule)("ui/palette.lua")

-- The tuning overlay's own instance when one is already loaded: the tool opened from the dashboard
-- runs in the widget's Lua state (widgets/dashboard/tool_host.lua), and a second instance of this
-- module is some 80 kB for nothing. Otherwise a private one, released with the page, so the
-- standalone tool keeps nothing of it after the page closes. The module holds no state of its own.
local SETUP_PATH = "widgets/dashboard/inflight/setup.lua"
local function loadSetup()
  local modules = _G.rfsuite and _G.rfsuite.modules
  local shared = modules and modules[_G.rfsuite.paths.core .. "/" .. SETUP_PATH]
  if type(shared) == "table" then return shared end
  return loadModule(SETUP_PATH)
end

local Common = nil
local Controls = nil
local Setup = nil
local Plan = nil
local Backup = nil
local LoadingOverlay = nil
local Armed = nil
local Env = nil

local M = {}

-- The switch picker's filters, as the firmware numbers them. Named here rather than reached for
-- as globals: SW_SWITCH is the physical switch
-- block, SW_NONE the empty entry that lets a pilot clear the choice. Trims are a filter of their
-- own and are deliberately not offered -- a trim drives a row rather than releasing the surface.
local SW_SWITCH = 1
-- The trim block, as its own filter. A trim is offered by the picker as two positions -- the
-- decrement and the increment -- and the overlay stores the increment; see Setup.normaliseTrim.
local SW_TRIM = 1 << 1
local SW_NONE = 1 << 20

-- What a set-up or a restore takes per pass. The walk over a model and the writes do not fit beside a
-- widget pass in one call, so both are slices, the same size in the standalone tool: one path to test.
-- PLAN_SLICE is in reads off the model, as Setup.GVAR_WALK_SLICE is; WRITE_SLICE in writes, each read
-- back; PARSE_SLICE and ENCODE_SLICE in lines of the record on the card.
local PLAN_SLICE = 32
local WRITE_SLICE = 4
local PARSE_SLICE = 8
local ENCODE_SLICE = 3

local ui = {
  loaded = false,
  dirty = false,
  sections = {
    general = true,
    wiring = false,
    trims = false
  },
  config = nil,
  trimNames = nil
}

ui.runtime = nil
local t = nil
local HELP_BTN_W, HELP_BTN_H, HELP_BTN_GAP = 30, 30, 6

--- A row's `?` opens the page's help sheet with the row's label as its title.
local function onRowHelp(helpText, helpTitle)
  local openHelp = ui.runtime and ui.runtime.openHelp
  if type(openHelp) == "function" then openHelp(helpText, helpTitle) end
end

local function ensureDeps()
  if not Common then
    Common = loadModule("app/pages/settings/common.lua")
  end
  if not Controls then
    Controls = loadModule("ui/controls.lua")
  end
  if not Setup then
    Setup = loadSetup()
  end
  if not ui.runtime then
    ui.runtime = Common.createFormRuntime(ui)
  end
  if not t then
    t = Common.pageT("settings_dashboard_inflight")
  end
  if Env == nil then
    Env = loadModule("lib/env.lua")
  end
end

--- True while the page runs inside the dashboard widget's call: the tool opened from the
-- dashboard (see lib/env.lua).
--
-- That call is stopped at the widget's instruction limit, and the two model walks below do not
-- fit in it beside the page's own build on a model with many logical switches or many mixer lines.
-- There they are taken a slice per pass in M.wakeup, the way the dashboard's overlay takes the
-- switch walk (inflight/drive.lua, ensureTrims). The standalone tool has no such limit, and its
-- page wakeup is not called while the model is armed, so it keeps the whole walk in the build.
local function inWidgetCall()
  return type(Env) == "table" and Env.isWidget() == true
end

--- The same answer for a reader that can run from a control's callback. EdgeTX calls a press or a
-- set function from its own event handling, outside the widget's call, so inWidgetCall answers false
-- there even in the tool opened from the dashboard; the build always runs inside that call, and
-- what it found holds for the visit.
local function hostedVisit()
  return ui.hosted == true
end

-- The radio's preferences, as the page context carries them. It is that table and no other: the
-- suite's writer puts down the one the context holds, so a section written anywhere else is
-- written into a copy nobody saves. Answers an empty table rather than nil so that a first visit
-- on a card whose file has never been written still reads as the defaults.
local function preferences(prefs)
  if type(prefs) ~= "table" then return {} end
  return prefs
end

--- The radio model's own name: while a connected craft's name stands in its place, the name store
-- holds the one it replaced. The switch's key stores it, and the set-up line shows it.
local function ownModelName(info)
  local name = info and info.name or ""
  local ok, store = pcall(_G.rfsuite.require or loadModule, "lib/model_name_store.lua")
  if ok and type(store) == "table" and type(store.pending) == "function" then
    name = store.pending() or name
  end
  return name
end

--- One radio surface for the whole visit. It is a table of closures, so building a fresh one per
-- build would hand the page a new set of them every time the screen was laid out again.
local function radio()
  if ui.radio == nil then
    ui.radio = Setup.radio()
  end
  return ui.radio
end

local function ensureLoaded(prefs)
  if ui.loaded then return end
  ui.config = Setup.loadRadioSettings(preferences(prefs))
  do
    local info = Setup.radio().modelInfo()
    local key = Setup.modelOnKey(info and info.filename)
    local Preferences = (_G.rfsuite.require or loadModule)("lib/preferences.lua")
    ui.modelOnKey = key
    ui.modelOnName = ownModelName(info)
    ui.config.enabled = key ~= nil and Preferences.inflightOn(preferences(prefs).inflight, info)
  end
  ui.radio = nil
  ui.checkDone = false
  ui.checkResult = nil
  ui.trimNames = nil
  ui.trimScan = nil
  ui.gvarWalkDone = false
  ui.gvarWalk = nil
  ui.gvarWalkWanted = false
  ui.gvarConflicts = nil
  ui.gvarUsed = nil
  ui.gvarNamesDone = false
  ui.gvarNamesWanted = false
  ui.gvarNames = nil
  ui.gvarNameOf = nil
  ui.gvarEditOpen = false
  ui.gvarNote = nil
  ui.gvarModelChanged = false
  ui.notesWanted = false
  ui.job = nil
  ui.jobResult = nil
  ui.recordChecked = false
  ui.recordParse = nil
  ui.recordOffer = false
  ui.modelName = nil
  ui.loaded = true
end

--- A repaint WITHOUT marking the settings edited.
--
-- ui.runtime.markDirty does both, which is right for a field the pilot changed and wrong for the
-- progress of a flight controller write: that changes the board, not the settings, and raising the
-- edited flag for it would leave the page asking to save something nobody typed.
--- Whether this model already drives something with one of the two configured variables.
--
-- This replaces a PROPOSAL. The page used to walk the model for two variables nothing referred to
-- and put them in the fields; the pilot's ruling after the third radio round is that the pair is
-- a fixed default instead, because a setting that moves with the model is one nobody can write
-- down and a pilot who never opens this page had an overlay that could not go live.
--
-- The walk stays, and its answer is now a WARNING rather than a choice: the overlay pulses these
-- variables several times a second while a pilot is tuning, so one that already scales a mixer or
-- an input line would move a control surface for a reason nobody could connect to it. It names the
-- line, because a warning that says only "taken" sends the pilot through thirty-two channels.
--
-- Runs once per visit, off the same latch as the check, and writes nothing. Inside the widget's
-- call the build only asks for it and answers nil; M.wakeup walks the model and rebuilds the page
-- when it has, unless a variable's editor may be open (see inWidgetCall, appendGvarNote), so
-- `ui.gvarWalkDone` still false after this call means "being read".
local function gvarConflicts()
  if ui.gvarWalkDone then
    -- Inside the widget's call the walk's own findings are kept (stepGvarWalk). They name the first
    -- line of EVERY variable, whichever two are configured, so a changed variable is answered from
    -- them without reading the model again.
    if ui.gvarUsed ~= nil then return Setup.conflictsFromUsed(ui.gvarUsed, ui.config) end
    return ui.gvarConflicts
  end
  if inWidgetCall() then
    ui.gvarWalkWanted = true
    return nil
  end
  ui.gvarWalkDone = true
  ui.gvarConflicts = Setup.gvarConflicts(radio(), ui.config)
  return ui.gvarConflicts
end

--- Which other variables of this model carry one of the two names the setup writes.
--
-- A separate question from the walk above, and the walk above cannot answer it: a model set up once
-- against a different pair keeps the names on the variables it used then, and a variable nothing
-- refers to any more has no reference for a mixer walk to find. Nine detail reads, on the same
-- terms as the check -- once per visit, and in the standalone tool again when one of the two
-- variables is changed (opened from the dashboard the names are kept, until Set up the model
-- writes the model; see below).
local function gvarNameClashes()
  if not ui.gvarNamesDone then
    -- Inside the widget's call M.wakeup reads them, in a pass of their own; see gvarConflicts.
    if inWidgetCall() then
      ui.gvarNamesWanted = true
      return nil
    end
    ui.gvarNamesDone = true
    ui.gvarNames = Setup.gvarNameClashes(radio(), ui.config)
  end
  -- Inside the widget's call every variable's name is kept, for the same reason as the walk's
  -- findings in gvarConflicts.
  if ui.gvarNameOf ~= nil then return Setup.nameClashesFromNames(ui.gvarNameOf, ui.config) end
  return ui.gvarNames
end

--- The walked trim block is in: keep it, or `false` for a radio that reported none.
local function trimsResolved(trims)
  ui.trimNames = trims or false
  -- A store written before the trims were picked with the radio's own picker holds semantic
  -- indices, 1..6; from here on they are switch positions. The walk is the first moment this
  -- page can say what an old index meant, so the conversion happens here -- in the working copy
  -- only. It reaches the card on the next save, which is what the pilot asked for: nothing is
  -- rewritten behind him, and a page he opens and leaves changes nothing.
  if ui.trimNames ~= false then Setup.migrateTrims(ui.config, ui.trimNames) end
end

--- True while the trim block is still being walked, a slice per pass (see inWidgetCall). Every
-- reader of trimNames() asks this first: until the walk is through, a stored trim cannot be told
-- from one this radio lacks, and nil would read as the second. The setup button and the trim
-- pickers read it from their callbacks, hence hostedVisit.
local function trimsPending()
  return ui.trimNames == nil and hostedVisit()
end

local function trimNames()
  if ui.trimNames == nil then
    if hostedVisit() then return nil end
    trimsResolved(Setup.resolveTrims(radio()))
  end
  if ui.trimNames == false then return nil end
  return ui.trimNames
end

--- One slice of the switch walk, as the overlay's own drive takes it. Answers true on the pass
-- that completes it.
local function stepTrimWalk()
  local scan = ui.trimScan
  if scan == nil then
    scan = { list = {}, from = nil }
    ui.trimScan = scan
  end
  local slice, resumeAt = radio().switchList(scan.from, Setup.SWITCH_SLICE)
  scan.from = resumeAt
  if type(slice) == "table" then
    for i = 1, #slice do
      scan.list[#scan.list + 1] = slice[i]
    end
  end
  if resumeAt ~= nil and #scan.list < Setup.SWITCH_WALK_LIMIT then return false end
  ui.trimScan = nil
  trimsResolved(Setup.trimsFromList(scan.list))
  return true
end

--- One slice of the variable walk. Answers true on the pass that completes it.
local function stepGvarWalk()
  if ui.gvarWalk == nil then
    ui.gvarWalk = Setup.newGvarWalk(radio())
    -- No mixer readers on this radio: the walk cannot be made, which the whole walk reports as nil.
    if ui.gvarWalk == nil then
      ui.gvarConflicts = nil
      ui.gvarWalkDone = true
      ui.gvarWalkWanted = false
      return true
    end
  end
  if not Setup.gvarWalkStep(ui.gvarWalk, Setup.GVAR_WALK_SLICE) then return false end
  ui.gvarUsed = ui.gvarWalk.used
  ui.gvarWalk = nil
  ui.gvarWalkDone = true
  ui.gvarWalkWanted = false
  return true
end

--- One trim, chosen with the radio's own switch picker rather than from a list this page wrote.
--
-- The list was a per-radio guess: the six semantic trims with the radio's labels where they could
-- be read and English stems where they could not, on a radio that may carry four. The picker is
-- the firmware's own, filtered to the trim block, so it offers exactly the trims this radio has
-- and names each of them the way every other page of the radio does.
--
-- It offers both positions of every trim and the store keeps the INCREMENT: the drive derives the
-- decrement from the same block entry, and a setting that could hold either would be two
-- spellings of one choice. A picked decrement is normalised to its own increment on the way in.
--
-- Controls has no wrapper for this picker, so the row places its `?` where the wrapped rows have
-- theirs, and the picker moves left to make room.
local function appendTrimPicker(children, x, y, w, label, helpText, get, set)
  local pickerW = 172
  if pickerW > w then pickerW = w end
  local rowH = Controls.ROW_H
  local pickerX = x + w - pickerW - 10 - HELP_BTN_W - HELP_BTN_GAP
  children[#children + 1] = {
    type = "label", x = x, y = Controls.labelY(y, rowH), w = pickerX - x - 8,
    text = label, color = Palette.text, font = SMLSIZE
  }
  children[#children + 1] = {
    type = "switch",
    x = pickerX, y = Controls.controlY(y, rowH), w = pickerW, h = rowH - 6,
    filter = SW_TRIM | SW_NONE,
    get = get,
    set = function(value)
      -- A picker of the previous build can still be on screen for a pass after Reload has started
      -- the walk again; a pick made then is not taken rather than stored as off.
      if trimsPending() then return end
      local wanted = Setup.normaliseTrim(trimNames(), value)
      if get() == wanted then return end
      set(wanted)
      ui.checkDone = false
      ui.runtime.markValueChanged()
    end
  }
  -- After the picker, as the wrapped rows have it: the encoder walks the children in this order.
  children[#children + 1] = {
    type = "button",
    x = x + w - 10 - HELP_BTN_W, y = y + math.floor((rowH - HELP_BTN_H) / 2),
    w = HELP_BTN_W, h = HELP_BTN_H,
    text = "?",
    press = function() onRowHelp(helpText, label) end
  }
  return rowH
end

--- A getter and a setter for one of the three named trim settings.
local function trimField(key)
  return function() return ui.config[key] or 0 end,
         function(value) ui.config[key] = value end
end

--- The setup check, cached.
--
-- `ui.checkDone` is the whole discipline: the walk runs when it is false and sets it, and only a
-- field's `set` puts it back. So a screen laid out again for any other reason -- a section opened,
-- a dialog closed, a rebuild the form runtime asked for -- costs no model reads at all.
local function checkResult()
  -- Not latched while the trims are still being walked: a check made without them leaves the trim
  -- faults out, and the latch would keep that answer for the whole visit.
  if trimsPending() then return "reading" end
  if not ui.checkDone then
    ui.checkDone = true
    -- The resolved block goes with it: a trim setting is a switch POSITION now, and the trim-mode
    -- half of the check indexes the firmware's own table by the semantic number behind it.
    ui.checkResult = Setup.check({ radio = radio(), settings = ui.config }, ui.config, trimNames())
    ui.faultSettled = false
  end
  return ui.checkResult
end

--- The verdict in one sentence, grouped by the page of the radio's own menus a pilot has to open:
-- the mixer, the global variables, the trims. A list of one line per fault reads longer and says
-- the same thing.
local function describeCheck(i18n, result)
  if result == nil then return t(i18n, "check_unchecked", "Setup not checked") end
  if result == "reading" then return t(i18n, "reading_radio", "Reading the radio...") end
  if result == "ok" then return t(i18n, "check_ok", "Setup OK") end
  if type(result) ~= "table" then return "" end

  local unset, mix, gvar, trim, claim = false, false, false, false, false
  -- The two halves pointed at one variable or one channel are not an unset field, and reading as
  -- one sent the pilot looking for something he had already filled in. They are the most dangerous
  -- verdict on this page -- the parameter that moves is not the one on the screen -- so each says
  -- what it is.
  local sameGvar, sameChannel = false, false
  for i = 1, #result do
    local code = result[i]
    if string.find(code, "mix", 1, true) then
      mix = true
    elseif string.find(code, "gvar_", 1, true) then
      gvar = true
    elseif string.find(code, "trim_mode", 1, true) then
      trim = true
    elseif code == "no_nav_trim" or code == "trim_claimed_twice" then
      claim = true
    elseif code == "same_gvar" then
      sameGvar = true
    elseif code == "same_channel" then
      sameChannel = true
    else
      unset = true
    end
  end

  local parts = {}
  if unset then parts[#parts + 1] = t(i18n, "check_unset", "Variables not set") end
  if sameGvar then
    parts[#parts + 1] = t(i18n, "check_same_gvar", "Bank and value point at the same variable")
  end
  if sameChannel then
    parts[#parts + 1] = t(i18n, "check_same_channel", "Bank and value point at the same channel")
  end
  if mix then parts[#parts + 1] = t(i18n, "check_mix", "Mixer line missing or wrong") end
  if gvar then parts[#parts + 1] = t(i18n, "check_gvar", "Variable range or precision") end
  if trim then parts[#parts + 1] = t(i18n, "check_trim", "Trim still active in a flight mode") end
  if claim then parts[#parts + 1] = t(i18n, "check_claim", "Walk and adjust need two different trims") end
  return table.concat(parts, " / ")
end

--- Whether the set-up button can answer this verdict. Two trims claimed twice, a variable pair not
-- chosen and the like are the fields' to fix; the verdict line says which.
local function setupCanFix(result)
  if type(result) ~= "table" then return result == nil end
  for i = 1, #result do
    local code = result[i]
    if string.find(code, "mix", 1, true) or string.find(code, "gvar_", 1, true)
        or string.find(code, "trim_mode", 1, true) then
      return true
    end
  end
  return false
end

--- The conflict warning's text, or nil where there is nothing to warn about.
local function conflictsText(i18n, conflicts)
  if type(conflicts) ~= "table" or #conflicts == 0 then return nil end
  local parts = {}
  for i = 1, #conflicts do
    parts[#parts + 1] = "GV" .. tostring(conflicts[i].index) .. " "
      .. t(i18n, "gvar_in_use", "is in use by") .. " " .. tostring(conflicts[i].where)
  end
  return table.concat(parts, " / ")
end

--- What the line drawn while the variables are read says now (see appendGvarNote): the warning for
-- the variables as they are set, once the walk has answered.
local function refreshGvarNote()
  if not ui.gvarWalkDone then return end
  ui.gvarNote = conflictsText(ui.i18n, gvarConflicts()) or ""
end

--- A field changed, so the verdict on the screen was reached about a different model.
local function markValue(key, value)
  if ui.config[key] == value then return end
  ui.config[key] = value
  ui.checkDone = false
  -- The conflict warning names the variable that was configured when the walk ran, so a changed
  -- variable makes it a sentence about a setting nobody holds any more.
  if key == "value_gvar" or key == "bank_gvar" then
    if hostedVisit() then
      -- Opened from the dashboard nothing is read again (unless the model was written since): the
      -- walk and the names kept for the visit answer for any pair (gvarConflicts, gvarNameClashes),
      -- and a walk still running goes on. Nor is the page built again from here: a number field
      -- calls this on every click while its editor is open, and a rebuild closes that editor. The
      -- screen follows when the editor closes (gvarEdited); until then the line drawn while the
      -- variables are read, if it is on screen, is updated in place. EdgeTX calls this from its
      -- event handling, outside the widget's call, hence hostedVisit.
      if ui.gvarModelChanged then
        -- The model was written since the walk (Set up the model): read it again from the start,
        -- without a rebuild while the editor is open. The warning on screen is brought up to date
        -- when the editor closes (gvarEdited), or at the page's next build.
        ui.gvarModelChanged = false
        ui.gvarWalk = nil
        ui.gvarUsed = nil
        ui.gvarNameOf = nil
        ui.gvarWalkDone = false
        ui.gvarNamesDone = false
        ui.gvarWalkWanted = true
        ui.gvarNamesWanted = true
      end
      ui.gvarEditOpen = true
      refreshGvarNote()
    else
      ui.gvarWalkDone = false
      ui.gvarNamesDone = false
    end
  end
  ui.runtime.markValueChanged()
end

--- Into the radio's own preferences, the way the other Settings pages do it.
--
-- The section is written in place on the published table and the suite's own writer puts the file
-- down, so the widget learns of the change through the reload signal that writer raises -- the
-- same route the theme and the preview switch already travel. Only this page's own keys are
-- touched: see inflight/setup.lua M.storeRadioSettings.
local function saveToStore(ctx)
  local prefs = ctx and ctx.preferences
  if type(prefs) ~= "table" then return false, "preferences" end
  if type(prefs.inflight) ~= "table" then prefs.inflight = {} end
  Setup.storeRadioSettings(prefs.inflight, ui.config)
  -- Written only while on, so a model never switched on carries nothing. The value is the model's own
  -- name, so a later model with the same file name is not on: see lib/preferences.lua M.inflightOn.
  if ui.modelOnKey ~= nil then
    prefs.inflight[ui.modelOnKey] = ui.config.enabled == true and (ui.modelOnName or "") or nil
  end

  -- A set-up's result arrives with the build's context, which carries the table and not the writer.
  local save = ctx.savePreferences or (_G.rfsuite and _G.rfsuite.savePreferences)
  if type(save) ~= "function" then return false, "preferences" end
  return save()
end

function M.getHeaderActions()
  ensureDeps()
  return { save = true, help = true }
end

function M.onReload(ctx)
  ensureDeps()
  ui.loaded = false
  ui.dirty = false
  ensureLoaded(ctx and ctx.preferences)
  return true
end

function M.onSave(ctx)
  ensureDeps()
  local ok, err = saveToStore(ctx)
  if ctx and type(ctx.reportSave) == "function" then
    if ok then
      ui.dirty = false
      ctx.reportSave({
        ok = true,
        title = t(ctx.i18n, "saved_title", "Saved"),
        message = t(ctx.i18n, "saved_message", "In-flight tuning settings saved")
      })
    else
      ctx.reportSave({
        title = t(ctx.i18n, "save_error_title", "Error"),
        message = t(ctx.i18n, "save_error_message", "Save failed") .. ": " .. Common.saveFailureReason(ctx.i18n, err)
      })
    end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Setting the model up
-- ---------------------------------------------------------------------------

--- What the set-up will do, in the three lines a box can hold on the smallest screen: which channels
-- and variables, and how many lines it replaces. The lines themselves are kept for the restore.
local function planQuestion(i18n, plan)
  local first = string.format("%s CH%d, CH%d / %s GV%d, GV%d",
    t(i18n, "plan_channels", "Channels"), ui.config.bank_ch, ui.config.value_ch,
    t(i18n, "plan_variables", "Variables"), ui.config.bank_gvar, ui.config.value_gvar)
  if #plan.trims > 0 then first = first .. " / " .. t(i18n, "plan_trims_off", "trims off") end
  local lines = { first }

  local parts = {}
  for i = 1, #plan.channels do
    local entry = plan.channels[i]
    if entry.removed > 0 then
      parts[#parts + 1] = string.format("CH%d %d %s", entry.channel, entry.removed,
        t(i18n, "plan_lines", "lines"))
    end
  end
  if #parts > 0 then
    lines[#lines + 1] = t(i18n, "plan_replaces", "Replaces") .. " " .. table.concat(parts, ", ")
  end

  -- The plan is built from the fields as they stand, which is not the same as the file on the card:
  -- a channel or a variable edited and not yet saved is what gets written.
  lines[#lines + 1] = t(i18n, "plan_from_page", "It writes and saves the values as they are set on this page.")
  return table.concat(lines, "\n")
end

--- The same for a restore: what comes back.
local function restoreQuestion(i18n, plan)
  local parts = {}
  for i = 1, #plan.channels do
    local entry = plan.channels[i]
    parts[#parts + 1] = string.format("CH%d %d %s", entry.channel, entry.removed,
      t(i18n, "plan_lines", "lines"))
  end
  local lines = { t(i18n, "restore_ask", "Puts back what the last set-up replaced on this radio model.") }
  if #parts > 0 then lines[#lines + 1] = table.concat(parts, ", ") end
  return table.concat(lines, "\n")
end

--- What a plan that will not be carried out says instead of the question.
local function refusalText(i18n, reason)
  if reason == "no_gvar" then
    return t(i18n, "plan_no_gvar", "Choose both variables first.")
  elseif reason == "same_gvar" then
    return t(i18n, "plan_same_gvar", "The two variables have to be different.")
  elseif reason == "same_channel" then
    return t(i18n, "plan_same_channel", "The two channels have to be different.")
  elseif reason == "no_ls" then
    return t(i18n, "plan_no_ls", "No logical switch is free to time the pulses; empty one first.")
  elseif reason == "trim_claimed_twice" or reason == "no_nav_trim" then
    -- The sentence the check shows for both.
    return t(i18n, "check_claim", "Walk and adjust need two different trims")
  end
  return t(i18n, "plan_unsupported", "This radio does not offer the mixer writer.")
end

local function requestRebuild()
  if type(ui.requestRebuild) == "function" then ui.requestRebuild() end
end

--- A step of a job, in the log. Built only when the level passes: a slice runs every pass.
local function logJob(level, fmt, ...)
  local log = (_G.rfsuite.require or loadModule)("lib/log.lua")
  if type(log) == "table" and type(log.wanted) == "function" and log.wanted(level) then
    log.emit("rfsuite.inflight", string.format(fmt, ...), level)
  end
end

local function ensureArmed()
  if Armed == nil then Armed = (_G.rfsuite.require or loadModule)("lib/armed.lua") end
  return Armed
end

local function ensurePlan()
  if Plan == nil then
    Plan = loadModule("widgets/dashboard/inflight/setup_plan.lua")
    Plan.bind(Setup, (_G.rfsuite.require or loadModule)("lib/log.lua"))
  end
  return Plan
end

local function ensureBackup()
  if Backup == nil then
    Backup = loadModule("widgets/dashboard/inflight/setup_backup.lua")
    Backup.bind(ensurePlan())
  end
  return Backup
end

local function modelFile()
  local info = radio().modelInfo()
  return info and info.filename or nil
end

--- A set-up and a restore change what the radio sends, so they run with nothing on the link at all, which
-- is how a pilot sets a model up at home. Asking for armed alone would let them through on a craft that
-- is powered with its arming flags unreported.
local function isArmed()
  local armed = ensureArmed()
  return armed ~= nil and armed.isArmed() == true
end

local function linkUp()
  local armed = ensureArmed()
  return armed ~= nil and armed.linkUp() == true
end

local function finishJob(title, message)
  logJob("info", "setup job ended: %s", tostring(message))
  ui.job = nil
  ui.jobResult = { title = title, message = message }
  requestRebuild()
end

--- The model has been written, so what was read about it for this visit no longer stands: the verdict
-- on the screen, the variable walk and the names (gvarConflicts), and whether a restore is on offer.
-- A walk still running has read part of the model as it was, so it starts again from the first channel.
local function modelWritten()
  ui.checkDone = false
  ui.gvarModelChanged = true
  if hostedVisit() and not ui.gvarWalkDone then ui.gvarWalk = nil end
  ui.recordChecked = false
  ui.recordParse = nil
  ui.recordOffer = false
end

--- Whether a write may go on. `home.lua` wakes no page while the model is armed, so a whole arm and
-- disarm can pass between two slices with nothing to see but the count.
local function mayGoOn(job)
  local armed = ensureArmed()
  if armed ~= nil and (armed.isArmed() == true or armed.linkUp() == true or armed.changeCount() ~= job.armCount) then
    return false
  end
  return modelFile() == job.modelFile
end

--- A set-up saves the page's values at once: they have just gone to the radio, and with others on the
-- card the check would fail on the next visit. It turns nothing on; that is the switch's. Answers the
-- text to add when the save failed, so the result does not claim what the card does not hold.
local function storeSetup()
  local ok, err = saveToStore(ui.saveCtx)
  logJob(ok and "info" or "warn", "setup job: page values saved %s %s", tostring(ok), tostring(err or ""))
  if ok then
    ui.dirty = false
    return ""
  end
  return " " .. t(ui.i18n, "plan_not_saved", "The settings could not be saved; save the page.")
end

--- A restore leaves the model not set up, so tuning goes off for it. Only that key is stored: edits on
-- the page that were not saved stay unsaved. Answers the text to add when the save failed.
local function storeRestored(file)
  ui.config.enabled = false
  local ctx = ui.saveCtx
  local prefs = ctx and ctx.preferences
  local save = ctx and ctx.savePreferences or (_G.rfsuite and _G.rfsuite.savePreferences)
  local key = Setup.modelOnKey(file)
  local ok, err = false, "preferences"
  if type(prefs) == "table" and type(prefs.inflight) == "table" and type(save) == "function" and key ~= nil then
    prefs.inflight[key] = nil
    prefs.inflight.enabled = false
    ok, err = save()
  end
  logJob(ok and "info" or "warn", "setup job: tuning off for this radio model, saved %s %s", tostring(ok), tostring(err or ""))
  if ok then return "" end
  return " " .. t(ui.i18n, "plan_not_saved", "The settings could not be saved; save the page.")
end

--- A setup fault turns tuning off for this radio model until the pilot switches it on again: a model
-- repaired or changed since would otherwise run tuning as soon as the check passes, with no choice made.
-- The switch goes off at once. With the page's values as saved the fault is the model's, and only its key
-- is stored, as a restore does; with edits not saved yet the fault may be theirs, and the switch's off
-- is stored with the page. Once per verdict.
local function settleFault()
  if ui.faultSettled or not ui.checkDone or type(ui.checkResult) ~= "table" then return false end
  ui.faultSettled = true
  local wasOn = ui.config.enabled == true
  ui.config.enabled = false
  local ctx = ui.saveCtx
  local prefs = ctx and ctx.preferences
  local key = ui.modelOnKey
  if ui.dirty or key == nil or type(prefs) ~= "table" or type(prefs.inflight) ~= "table"
      or prefs.inflight[key] == nil then
    logJob("debug", "setup fault: switch off on the page, on before %s", tostring(wasOn))
    return false
  end
  local save = ctx.savePreferences or (_G.rfsuite and _G.rfsuite.savePreferences)
  prefs.inflight[key] = nil
  prefs.inflight.enabled = false
  local ok, err = false, "preferences"
  if type(save) == "function" then ok, err = save() end
  logJob(ok and "info" or "warn", "setup fault: tuning off for this radio model, saved %s %s", tostring(ok), tostring(err or ""))
  return true
end

local JOB_STAGES = {}

--- Plan first, and read nothing more than the plan needs: the pilot has only pressed the button.
function JOB_STAGES.plan(job)
  local i18n = ui.i18n
  -- The resolved trim block goes with the settings, exactly as it does into the check: a stored trim
  -- is a switch POSITION, and the plan's trim half indexes the firmware's own trim-mode table by the
  -- semantic number behind it. So the walk comes first.
  if trimsPending() then
    stepTrimWalk()
    return
  end
  if job.planJob == nil then
    job.planJob = ensurePlan().newPlanJob(radio(), ui.config, trimNames())
    job.modelFile = modelFile()
  end
  if job.checkedRecord ~= true then
    -- What was cut off comes first: this plan would read the model it left, and its lines would have no
    -- record at all once the channels differ from the ones in the record.
    job.checkedRecord = true
    if ensureBackup().stateOf(job.modelFile) == "partial" then
      finishJob(t(i18n, "plan_title", "Set up radio"),
        t(i18n, "plan_restore_first", "A set-up was cut off: use Restore previous setup first."))
      return
    end
  end
  if not Plan.planStep(job.planJob, PLAN_SLICE) then
    logJob("trace", "setup job: plan stage %s", tostring(job.planJob.stage))
    return
  end
  local plan = job.planJob.plan
  job.planJob = nil
  job.plan = plan
  if plan.ok ~= true then
    finishJob(t(i18n, "plan_title", "Set up radio"), refusalText(i18n, plan.refused))
  elseif plan.nothing == true then
    -- Nothing to write, so there is nothing to confirm; the page's values are what it carries.
    finishJob(t(i18n, "plan_title", "Set up radio"),
      t(i18n, "plan_nothing", "This radio model already carries this setup; nothing to write.")
      .. " " .. t(i18n, "plan_switch_next", "Turn tuning on with the switch on this page.") .. storeSetup())
  else
    logJob("info", "setup job: asks, %d step(s) planned", #plan.gvars + #plan.deletions + #plan.insertions + #plan.trims)
    job.stage = "ask"
    requestRebuild()
  end
end

function JOB_STAGES.ask()
  -- The box's two buttons answer; see appendJobBox.
end

--- The pilot's word that the helicopter is powered off, before anything is written. A write is refused
-- while anything answers on the link, so every write that gets here has nothing on it, and with nothing
-- on it the radio cannot tell an unpowered helicopter from one whose receiver sends no telemetry: with
-- telemetry off the radio reads no signal from a receiver that is on and bound. The model's mixer lines
-- are the ones a powered helicopter flies on, so the question is asked every time.
function JOB_STAGES.power()
  -- The box's two buttons answer; see appendJobBox.
end

--- The record goes on the card BEFORE the first write, and is read back: no record, no write. A restore
-- marks its record `partial` first, so one cut off in the middle is still offered.
function JOB_STAGES.backup(job)
  local i18n = ui.i18n
  local store = ensureBackup()
  local restoring = job.kind == "restore"
  if not restoring and job.encode == nil then job.encode = store.newEncode(job.plan, job.modelFile) end
  if not restoring and not store.encodeStep(job.encode, ENCODE_SLICE) then return end
  -- Before the card: the record of the set-up before this one is the only way back to its lines, and it
  -- is not to be replaced for a write that will not happen.
  if not mayGoOn(job) then
    logJob("warn", "setup job stopped before the record: armed or another model")
    finishJob(restoring and t(i18n, "restore_setup", "Restore previous setup") or t(i18n, "plan_title", "Set up radio"),
      t(i18n, "plan_stopped_early", "Stopped: a receiver or flight controller came up, or another radio model was selected. Nothing was changed."))
    return
  end
  -- The answer may have stood for a while, and a restore's deletions clear whatever stands there. Its own
  -- pass: this reads the model's state.
  if restoring and job.record.state == "complete" and job.rechecked ~= true then
    job.rechecked = true
    if not store.stillCarries(radio(), job.record) then
      logJob("info", "setup job: restore refused, the model changed during the question")
      ui.recordChecked = false
      ui.recordOffer = false
      finishJob(t(i18n, "restore_setup", "Restore previous setup"),
        t(i18n, "restore_changed", "This radio model changed since the set-up; nothing was restored."))
    end
    return
  end
  local saved
  if restoring then
    saved = store.markState(job.modelFile, "partial")
  else
    saved = store.saveText(job.modelFile, job.encode.text)
    job.encode = nil
  end
  if not saved then
    finishJob(restoring and t(i18n, "restore_setup", "Restore previous setup") or t(i18n, "plan_title", "Set up radio"),
      t(i18n, "plan_no_backup", "The restore data could not be saved; nothing was changed."))
    return
  end
  logJob("info", "setup job: record on the card")
  job.apply = ensurePlan().newApplyJob(radio(), job.plan)
  job.stage = "write"
  requestRebuild()
end

function JOB_STAGES.write(job)
  local i18n = ui.i18n
  local restoring = job.kind == "restore"
  local title = restoring and t(i18n, "restore_setup", "Restore previous setup")
    or t(i18n, "plan_title", "Set up radio")
  if not mayGoOn(job) then
    logJob("warn", "setup job stopped: armed or another model, %d step(s) done", job.apply.at - 1)
    modelWritten()
    finishJob(title, t(i18n, "plan_stopped",
      "Stopped: a receiver or flight controller came up, or another radio model was selected. Restore previous setup puts it back."))
    return
  end
  if not Plan.applyStep(job.apply, WRITE_SLICE) then return end
  local report = job.apply.report
  modelWritten()
  if restoring then
    if job.apply.stopped then
      finishJob(title, t(i18n, "restore_failed", "The radio refused part of the restore; the saved setup is kept"))
    else
      local note = ""
      if not ensureBackup().remove(job.modelFile) then
        logJob("warn", "setup job: the record could not be removed after the restore")
        -- Still `partial` it would offer this restore again and refuse a set-up. `complete` is offered only
        -- while the model carries what that set-up wrote, which it no longer does.
        if not ensureBackup().markState(job.modelFile, "complete") then
          logJob("warn", "setup job: the record could not be retired either")
        end
        note = " " .. t(i18n, "restore_not_removed", "The saved setup could not be deleted from the card.")
      end
      finishJob(title, t(i18n, "restore_done", "Previous setup restored") .. note .. storeRestored(job.modelFile))
    end
  elseif job.apply.stopped then
    finishJob(title, string.format("%s (%d/%d)",
      t(i18n, "plan_failed", "The radio refused part of the setup; Restore previous setup puts it back"),
      report.written, #job.apply.ops))
  else
    if not ensureBackup().markState(job.modelFile, "complete") then
      -- The set-up stands; the record still says partial, so the restore stays on offer.
      logJob("warn", "setup job: the record could not be marked complete")
    end
    finishJob(title, string.format("%s (%d)", t(i18n, "plan_done", "Radio set up"), report.written)
      .. " " .. t(i18n, "plan_switch_next", "Turn tuning on with the switch on this page.") .. storeSetup())
  end
end

--- A restore reads its record line by line, then asks.
function JOB_STAGES.read(job)
  local i18n = ui.i18n
  local store = ensureBackup()
  local title = t(i18n, "restore_setup", "Restore previous setup")
  if job.record == nil then
    if job.parse == nil then
      job.modelFile = modelFile()
      job.parse = store.newParse(job.modelFile)
      if job.parse == nil then
        finishJob(title, t(i18n, "restore_failed", "The radio refused part of the restore; the saved setup is kept"))
        return
      end
    end
    if not store.parseStep(job.parse, PARSE_SLICE) then return end
    job.record = job.parse.record
    job.parse = nil
    return
  end
  if job.checked ~= true then
    -- Its own pass: the model's state is read here. A damaged record cannot put anything back and, kept,
    -- would refuse every set-up, so it goes. The offer was read when the page opened; a function script
    -- or another widget can have changed the model since. A `partial` record is restored whatever stands.
    job.checked = true
    if not store.isWhole(job.record) then
      local removed = store.remove(job.modelFile)
      logJob("warn", "setup job: the record is damaged, removed %s", tostring(removed))
      ui.recordChecked = false
      ui.recordOffer = false
      finishJob(title, removed and t(i18n, "restore_damaged", "The saved setup is damaged and was discarded; nothing was changed.")
        or t(i18n, "restore_damaged_kept", "The saved setup is damaged and could not be deleted; delete it from the card."))
    elseif job.record.state == "complete" and not store.stillCarries(radio(), job.record) then
      logJob("info", "setup job: restore refused, the model changed since the set-up")
      ui.recordChecked = false
      ui.recordOffer = false
      finishJob(title, t(i18n, "restore_changed", "This radio model changed since the set-up; nothing was restored."))
    end
    return
  end
  job.plan = store.restorePlan(radio(), job.record)
  job.stage = "ask"
  requestRebuild()
end

local function stepJob()
  JOB_STAGES[ui.job.stage](ui.job)
end

--- Whether a restore is on offer, once per visit: a record saying `partial` always, one saying `complete`
-- only while the model still carries what that set-up wrote. Answers true when the page has to show it.
local function stepRecordCheck()
  local store = ensureBackup()
  if ui.recordParse == nil then
    local file = modelFile()
    local state = store.stateOf(file)
    if state == nil or state == "partial" then
      ui.recordChecked = true
      ui.recordOffer = state == "partial"
      if not ui.recordOffer then
        Backup = nil
        Plan = nil
      end
      return ui.recordOffer
    end
    ui.recordParse = store.newParse(file)
    if ui.recordParse == nil then
      ui.recordChecked = true
      return false
    end
  end
  if not store.parseStep(ui.recordParse, PARSE_SLICE) then return false end
  -- A record that is not whole is not compared: stillCarries indexes the model by its entries.
  local record = ui.recordParse.record
  ui.recordOffer = store.isWhole(record) and store.stillCarries(radio(), record)
  logJob("debug", "setup job: restore offered %s", tostring(ui.recordOffer))
  ui.recordParse = nil
  ui.recordChecked = true
  return ui.recordOffer
end

--- The set-up button: start the job and do nothing else. EdgeTX calls a press from its own event
-- handling, on what is left of a widget pass, and the walk over a model does not fit there.
local function offerSetup(i18n)
  if isArmed() then
    ui.jobResult = {
      title = t(i18n, "plan_title", "Set up radio"),
      message = t(i18n, "plan_armed", "Not while the model is armed.")
    }
  elseif linkUp() then
    logJob("info", "setup job: set-up refused, the link is up")
    ui.jobResult = {
      title = t(i18n, "plan_title", "Set up radio"),
      message = t(i18n, "plan_connected", "Not while a receiver or flight controller is connected; power it off first.")
    }
  else
    logJob("debug", "setup job: set-up started")
    ui.job = { kind = "setup", stage = "plan" }
  end
  requestRebuild()
end

local function offerRestore(i18n)
  if isArmed() then
    ui.jobResult = {
      title = t(i18n, "restore_setup", "Restore previous setup"),
      message = t(i18n, "plan_armed", "Not while the model is armed.")
    }
  elseif linkUp() then
    logJob("info", "setup job: restore refused, the link is up")
    ui.jobResult = {
      title = t(i18n, "restore_setup", "Restore previous setup"),
      message = t(i18n, "plan_connected", "Not while a receiver or flight controller is connected; power it off first.")
    }
  else
    logJob("debug", "setup job: restore started")
    ui.job = { kind = "restore", stage = "read" }
  end
  requestRebuild()
end

--- The box over the page while a job runs, and its result.
local function appendJobBox(children, x, y, w, h, i18n)
  if LoadingOverlay == nil then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  local result = ui.jobResult
  if result ~= nil then
    LoadingOverlay.appendNotice(children, {
      x = x, y = y, w = w, h = h, title = result.title, message = result.message,
      buttonText = t(i18n, "plan_close", "Close"),
      press = function()
        ui.jobResult = nil
        requestRebuild()
      end
    })
    return
  end

  local job = ui.job
  local restoring = job.kind == "restore"
  local title = restoring and t(i18n, "restore_setup", "Restore previous setup")
    or (t(i18n, "plan_title", "Set up radio") .. ": " .. ui.modelName)
  if job.stage == "ask" then
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h, title = title, bar = false,
      message = restoring and restoreQuestion(i18n, job.plan) or planQuestion(i18n, job.plan),
      actions = {
        {
          text = t(i18n, "plan_cancel", "Cancel"),
          press = function()
            ui.job = nil
            requestRebuild()
          end
        },
        {
          text = restoring and t(i18n, "restore_confirm", "Restore") or t(i18n, "plan_confirm", "Set up"),
          press = function()
            logJob("debug", "setup job: answered, asks whether the helicopter is off")
            job.stage = "power"
            requestRebuild()
          end
        }
      }
    })
  elseif job.stage == "power" then
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h, title = title, bar = false,
      message = t(i18n, "plan_power_question",
        "Is the helicopter powered off? With telemetry off the radio cannot see a receiver that is on."),
      actions = {
        {
          text = t(i18n, "plan_cancel", "Cancel"),
          press = function()
            logJob("info", "setup job: cancelled at the power question")
            ui.job = nil
            requestRebuild()
          end
        },
        {
          text = t(i18n, "plan_power_confirm", "It is off"),
          press = function()
            -- The answer only: the write runs from the page's wakeup. The count starts here, so an
            -- arm and disarm from now on stops it.
            logJob("info", "setup job: the pilot confirmed the helicopter is off")
            local armed = ensureArmed()
            job.armCount = armed and armed.changeCount() or 0
            job.stage = "backup"
            requestRebuild()
          end
        }
      }
    })
  elseif job.stage == "write" then
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h, title = title,
      message = t(i18n, "plan_writing", "Writing to the radio..."),
      progress = function()
        local apply = ui.job and ui.job.apply
        if apply == nil or #apply.ops == 0 then return 1 end
        return (apply.at - 1) / #apply.ops
      end
    })
  else
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h, title = title, bar = false,
      message = t(i18n, "reading_radio", "Reading the radio...")
    })
  end
end

--- The radio model's own name, once per visit. While a flight controller is connected its craft name
-- can stand in the model's name field (tasks/events/onconnect/tasks/model_name_sync.lua); what the
-- model is really called is kept in lib/model_name_store.lua until the name is put back.
local function radioModelName()
  if ui.modelName == nil then
    ui.modelName = ownModelName(radio().modelInfo())
  end
  return ui.modelName
end

-- ---------------------------------------------------------------------------
-- Setting the flight controller up
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- The sections
-- ---------------------------------------------------------------------------

-- A label narrower than its text WRAPS rather than clipping, so a constant advance draws
-- the next row on top of the second line -- which is what the longest note on this page
-- did at 800 pixels, and what every note here would do on a 480-pixel screen. The library
-- has the answer already: ui/controls.lua measures a wrapped label, and its own comment is
-- about precisely this mistake. One line keeps the row height it always had, so nothing
-- that fitted moves.
local function measureLines(text, w)
  local lines = 1
  if Controls and type(Controls.estimateWrappedTextHeight) == "function" then
    local total = Controls.estimateWrappedTextHeight(text, w, SMLSIZE)
    local one = Controls.estimateWrappedTextHeight("Ag", w, SMLSIZE)
    if type(total) == "number" and type(one) == "number" and one > 0 then
      lines = math.floor((total / one) + 0.5)
      if lines < 1 then lines = 1 end
    end
  end
  return lines
end

--- How many lines a note wraps to, measured once per visit and width.
--
-- That measurement is a text-size call per word, and it was most of what this page's build cost:
-- every note was measured again on every build, and the page builds again after each of the walks
-- above. A note's height depends only on its text and the width, so the answer is kept for the
-- visit; the arithmetic is the same, so the screen is the same.
local function noteLines(text, w)
  if type(text) ~= "string" then return measureLines(text, w) end
  if ui.noteLines == nil or ui.noteW ~= w then
    ui.noteLines = {}
    ui.noteW = w
  end
  local lines = ui.noteLines[text]
  if lines == nil then
    lines = measureLines(text, w)
    ui.noteLines[text] = lines
  end
  return lines
end

--- True when every note given has been measured at this width.
local function notesMeasured(w, ...)
  local cache = ui.noteLines
  if cache == nil or ui.noteW ~= w then return select("#", ...) == 0 end
  for i = 1, select("#", ...) do
    local text = select(i, ...)
    if type(text) == "string" and cache[text] == nil then return false end
  end
  return true
end

local function appendNote(children, x, y, w, text)
  children[#children + 1] = {
    type = "label", x = x, y = y, w = w, text = text, color = Palette.text, font = SMLSIZE
  }
  return noteLines(text, w) * 24
end

local function buildGeneral(children, x, y, w, i18n)
  local cursorY = y
  cursorY = cursorY + appendNote(children, x, cursorY, w,
    t(i18n, "pointer_tuning", "Set up suggested functions from the tuning screen on the ground."))
  -- On only while this radio model is set up: with a fault the overlay refuses to drive anyway, and a
  -- switch that says on then says something untrue. A fault also turns it off for the model (see
  -- settleFault), so after a repair the pilot switches it on again.
  local enabledLabel = t(i18n, "enabled", "In-flight tuning on this radio model")
  local result = checkResult()
  local ready = result == "ok"
  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    enabledLabel,
    function() return ready and ui.config.enabled == true end,
    function(value)
      -- This model alone; the others keep what they have.
      ui.config.enabled = value == true
      ui.runtime.markValueChanged()
    end,
    function() return ready end,
    {
      helpText = t(i18n, "help_enabled", "On or off for this radio model, once it is set up. Renaming the model turns it off. With it off, in-flight tuning drives nothing on it."),
      helpTitle = enabledLabel,
      onHelp = onRowHelp
    })
  if result ~= "reading" and not ready and setupCanFix(result) then
    cursorY = cursorY + appendNote(children, x, cursorY, w,
      t(i18n, "enabled_needs_setup", "Set up this radio model first."))
  end

  cursorY = cursorY + appendNote(children, x, cursorY, w, describeCheck(i18n, result))

  -- Which model the button writes: the radio's, not the flight controller's.
  cursorY = cursorY + appendNote(children, x, cursorY, w,
    t(i18n, "active_model", "Active radio model") .. ": " .. radioModelName())

  -- The button that makes the model match what the verdict just reported. It sits here rather than
  -- in the wiring section because this is where that verdict is read.
  local btnW = math.min(240, w - 2 * (HELP_BTN_W + HELP_BTN_GAP + 10))
  local btnH = (lvgl and lvgl.UI_ELEMENT_HEIGHT) or Controls.CTRL_H or 32
  local btnX = x + math.floor((w - btnW) / 2)
  local setupLabel = t(i18n, "setup_model", "Set up radio")
  children[#children + 1] = {
    type = "button", x = btnX, y = cursorY, w = btnW, h = btnH,
    text = setupLabel,
    press = function() offerSetup(i18n) end
  }
  children[#children + 1] = {
    type = "button",
    x = x + w - 10 - HELP_BTN_W, y = cursorY + math.floor((btnH - HELP_BTN_H) / 2),
    w = HELP_BTN_W, h = HELP_BTN_H,
    text = "?",
    press = function()
      onRowHelp(t(i18n, "help_setup",
        "Writes and saves this radio model's channels, variables and trims as set here; check them first. Tuning stays off until the switch is on. Restore previous setup puts back what it replaced."),
        setupLabel)
    end
  }
  cursorY = cursorY + btnH + 6

  -- Offered only while it can put the model back; see stepRecordCheck.
  if ui.recordOffer then
    children[#children + 1] = {
      type = "button", x = btnX, y = cursorY, w = btnW, h = btnH,
      text = t(i18n, "restore_setup", "Restore previous setup"),
      press = function() offerRestore(i18n) end
    }
    cursorY = cursorY + btnH + 6
  end

  return cursorY
end

local function appendNumber(children, x, y, w, label, key, minValue, maxValue, helpText, step, edited)
  return Controls.appendNumberField(children, x, y, w, label, {
    min = minValue,
    max = maxValue,
    step = step or 1,
    get = function() return ui.config[key] end,
    set = function(value) markValue(key, value) end,
    edited = edited,
    helpText = helpText,
    helpTitle = label,
    onHelp = onRowHelp
  })
end

--- The editor of one of the two variables has closed.
--
-- Inside the widget's call this is where a change to one of them reaches the screen: the page is
-- built again, and the warning is drawn from the walk kept for the visit, without a read. Not from
-- markValue, which runs on every click while the editor is open, and a rebuild closes that editor.
-- Where the walk is still running, its own end builds the page, now that no editor is open. EdgeTX
-- calls this from its event handling, outside the widget's call, hence hostedVisit. It does not call
-- it when an encoder edit ends because another control took the focus (NumberArea's focus handler
-- leaves edit mode without changeEnd), nor before 2.11.5 / 2.12.0: there a walk still running puts
-- its answer into the line under the fields in place (appendGvarNote), and a warning already drawn
-- is brought up to date by the page's next build. The standalone tool walks in the build, so there
-- the warning is brought up to date by the next build, as before.
local function gvarEdited()
  if not hostedVisit() or not ui.gvarEditOpen then return end
  ui.gvarEditOpen = false
  if ui.gvarWalkDone and ui.gvarNamesDone then ui.runtime.markDirty() end
end

--- The longest warning the line drawn while the variables are read can come to hold, spelled once
-- per visit: two variables, each on a channel or an input.
local function widestWarning(i18n)
  if ui.widestWarning == nil then
    ui.widestWarning = conflictsText(i18n, {
      { index = Setup.GVAR_MAX_INDEX, where = "CH32" },
      { index = Setup.GVAR_MAX_INDEX - 1, where = "CH32" }
    })
  end
  return ui.widestWarning
end

--- The notes the wiring section draws whatever the model holds; see sectionHeldBack. The last two
-- size the line drawn while the variables are read (appendGvarNote).
local function wiringNotes(i18n)
  return t(i18n, "wiring_note",
      "One mixer line per channel: MAX at the variable's weight, added; a logical switch on the value line."),
    t(i18n, "reading_radio", "Reading the radio..."),
    widestWarning(i18n)
end

--- The line drawn while the variables are read. Reached inside the widget's call only: the
-- standalone tool walks in the build.
--
-- Drawn through a closure, so a changing notice does not rebuild the page,
-- because one of the two variables can be edited while the walk runs. The walk's answer cannot
-- then be shown by building the page again, which would close the editor (see markValue), and
-- EdgeTX does not always say when that editor has closed (gvarEdited). So the walk's end, and every
-- click after it, put the warning into this line instead; the full page follows once the editor is
-- known to be closed. The line is as tall as the longest warning it can hold, so it never runs
-- into what is drawn below it.
local function appendGvarNote(children, x, y, w, readingNote, widestNote)
  ui.gvarNote = readingNote
  children[#children + 1] = {
    type = "label", x = x, y = y, w = w, color = Palette.text, font = SMLSIZE,
    text = function() return ui.gvarNote or "" end
  }
  return math.max(noteLines(readingNote, w), noteLines(widestNote, w)) * 24
end

local function buildWiring(children, x, y, w, i18n)
  local wiringNote, readingNote, widestNote = wiringNotes(i18n)
  local cursorY = y
  cursorY = cursorY + appendNote(children, x, cursorY, w, wiringNote)
  -- The link carries the two channels, and an ExpressLRS switch mode quantises both of them to a
  -- fixed number of positions. The windows the flight controller decodes are 50 microseconds wide,
  -- so a quantised code can land in the gap beside its own window or inside the neighbouring row's.
  cursorY = cursorY + appendNumber(children, x, cursorY, w,
    t(i18n, "bank_ch", "Enable channel"), "bank_ch", Setup.CHANNEL_MIN, Setup.CHANNEL_MAX,
    t(i18n, "help_bank_ch",
      "Bank the flight controller listens on, 5 to 16. On ExpressLRS use Wide or full resolution; Hybrid can pick the wrong parameter."))
  cursorY = cursorY + appendNumber(children, x, cursorY, w,
    t(i18n, "value_ch", "Value channel"), "value_ch", Setup.CHANNEL_MIN, Setup.CHANNEL_MAX,
    t(i18n, "help_value_ch",
      "Steps the parameter, 5 to 16. On ExpressLRS use Wide or full resolution; Hybrid can pick the wrong parameter."))
  cursorY = cursorY + appendNumber(children, x, cursorY, w,
    t(i18n, "bank_gvar", "Enable variable"), "bank_gvar", 0, Setup.GVAR_MAX_INDEX,
    t(i18n, "help_bank_gvar",
      "The global variable on the enable channel, 0 to 9, where 0 is none. A line under the fields warns when another mixer line uses it."),
    nil, gvarEdited)
  cursorY = cursorY + appendNumber(children, x, cursorY, w,
    t(i18n, "value_gvar", "Value variable"), "value_gvar", 0, Setup.GVAR_MAX_INDEX,
    t(i18n, "help_value_gvar",
      "The global variable on the value channel, 0 to 9, where 0 is none. A line under the fields warns when another mixer line uses it."),
    nil, gvarEdited)

  -- The variables are fixed defaults now, so the model is walked to say when one of them is
  -- already spoken for rather than to choose a free pair. It is a warning and not a refusal: a
  -- pilot who knows what that line does may well want it.
  local conflicts = gvarConflicts()
  local named = gvarNameClashes()
  if not ui.gvarWalkDone or not ui.gvarNamesDone then
    cursorY = cursorY + appendGvarNote(children, x, cursorY, w, readingNote, widestNote)
  elseif type(conflicts) == "table" and #conflicts > 0 then
    cursorY = cursorY + appendNote(children, x, cursorY, w, conflictsText(i18n, conflicts))
  end

  -- And the other trace a variable can carry: the name, on a variable this setup does not drive. A
  -- model set up once against a different pair shows two VALs and two BNKs on the radio's own pages,
  -- and only one of each pair does anything. Read above, beside the walk.
  if type(named) == "table" and #named > 0 then
    local parts = {}
    for i = 1, #named do
      -- Spelled the way the reference warning above it is, out of fragments rather than through a
      -- format string: a translated format a locale spelled differently would raise here, inside a
      -- page build, and a warning is not worth a screen that does not come up.
      parts[#parts + 1] = "GV" .. tostring(named[i].index) .. " " .. tostring(named[i].name)
        .. " " .. t(i18n, "gvar_name_clash", "is not the variable this setup drives")
    end
    cursorY = cursorY + appendNote(children, x, cursorY, w, table.concat(parts, " "))
  end
  return cursorY
end

--- The notes the trims section can draw, in either layout; see sectionHeldBack.
local function trimsNotes(i18n)
  return t(i18n, "navigate_note", "Optional trims: one highlights a parameter, the other steps it. Touch remains available."),
    t(i18n, "bank_trim_note", "The group trim changes group; the walk trim highlights a parameter inside it."),
    t(i18n, "trims_unreadable", "This radio did not report its trims; the default order is used.")
end

--- Which trim does what.
--
-- Two arrangements, and the difference is how many trims a pilot has to spare. `rows` gives each
-- of the six rows its own trim, which is the layout the project's own radio setup documents;
-- `navigate` claims two -- one walks the whole set, one moves what the walk selected -- which is
-- what a radio with four trims can offer and what a pilot who does not want to remember six
-- positions asks for.
local function buildTrims(children, x, y, w, i18n)
  local navigateNote, bankTrimNote, unreadableNote = trimsNotes(i18n)
  local cursorY = y
  local trimsLabel = t(i18n, "trims", "Drive rows from the trims")
  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    trimsLabel,
    ui.runtime.getBoolGetter("trims"),
    function(value)
      -- The check claims trims only while they drive the surface, so its verdict was about the other value.
      ui.checkDone = false
      ui.runtime.getBoolSetter("trims")(value)
    end,
    nil,
    {
      helpText = t(i18n, "help_trims",
        "Whether the physical trims move the surface at all. Off by default; touch, PAGE and the encoder work without them."),
      helpTitle = trimsLabel,
      onHelp = onRowHelp
    })

  -- No picker until the walk is through: normaliseTrim needs the block, and a trim picked before it
  -- would be stored as off.
  if trimsPending() then
    cursorY = cursorY + appendNote(children, x, cursorY, w, t(i18n, "reading_radio", "Reading the radio..."))
    return cursorY
  end

  if trimNames() == nil then
    cursorY = cursorY + appendNote(children, x, cursorY, w, unreadableNote)
  end

  local modeOptions = {
    { value = Setup.TRIM_MODE_ROWS, label = t(i18n, "trim_mode_rows", "One trim per row") },
    { value = Setup.TRIM_MODE_NAVIGATE, label = t(i18n, "trim_mode_navigate", "Walk and adjust") }
  }
  local modeLabel = t(i18n, "trim_mode", "Trim layout")
  cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
    modeLabel, modeOptions, ui.config.trim_mode,
    function(value)
      if ui.config.trim_mode == value then return end
      ui.config.trim_mode = value
      ui.checkDone = false
      ui.runtime.markDirty()
    end,
    {
      helpText = t(i18n, "help_trim_mode",
        "Walk and adjust claims up to three trims. One trim per row gives each of the six rows its own trim, so it needs six to spare."),
      helpTitle = modeLabel,
      onHelp = onRowHelp
    })

  if ui.config.trim_mode == Setup.TRIM_MODE_NAVIGATE then
    cursorY = cursorY + appendNote(children, x, cursorY, w, navigateNote)
    cursorY = cursorY + appendTrimPicker(children, x, cursorY, w,
      t(i18n, "bank_trim", "Group trim"),
      t(i18n, "help_bank_trim", "Changes the group. With none assigned, touch or PAGE changes the group."),
      trimField("bank_trim"))
    cursorY = cursorY + appendNote(children, x, cursorY, w, bankTrimNote)
    cursorY = cursorY + appendTrimPicker(children, x, cursorY, w,
      t(i18n, "nav_trim", "Walk trim"),
      t(i18n, "help_nav_trim", "Highlights a parameter inside the current group."),
      trimField("nav_trim"))
    cursorY = cursorY + appendTrimPicker(children, x, cursorY, w,
      t(i18n, "adj_trim", "Adjust trim"),
      t(i18n, "help_adj_trim", "Moves the value of the highlighted parameter."),
      trimField("adj_trim"))
    return cursorY
  end

  local labels = {
    t(i18n, "row_1", "Row 1"),
    t(i18n, "row_2", "Row 2"),
    t(i18n, "row_3", "Row 3"),
    t(i18n, "row_4", "Row 4"),
    t(i18n, "row_5", "Row 5"),
    t(i18n, "row_6", "Row 6")
  }
  local rowHelp = t(i18n, "help_row_trim", "The trim that moves this row of the surface.")
  for row = 1, Setup.TRIM_COUNT do
    local index = row
    cursorY = cursorY + appendTrimPicker(children, x, cursorY, w, labels[row], rowHelp,
      function() return ui.config.rowTrim[index] or 0 end,
      function(value) ui.config.rowTrim[index] = value end)
  end
  return cursorY
end

local SECTIONS = {
  { key = "general", titleKey = "section_general", titleFallback = "In-flight tuning", build = buildGeneral },
  { key = "wiring", titleKey = "section_wiring", titleFallback = "Channels and variables", build = buildWiring,
    notes = wiringNotes },
  { key = "trims", titleKey = "section_trims", titleFallback = "Rows and trims", build = buildTrims,
    notes = trimsNotes }
}

--- True while an open section's body waits for its notes to be measured (inside the widget's call
-- only; see inWidgetCall).
--
-- Measuring them was most of what such a section cost to build, and the page builds in one pass:
-- with both sections open, the build alone did not fit beside the rest of a widget pass. So there
-- the section's header is drawn at once and its body is held back; M.wakeup measures the notes, a
-- section per pass, and the body is drawn on the rebuild that follows, from the measured heights.
-- This is the dashboard's own scene job in small (widgets/dashboard/runtime.lua, sceneJobStep):
-- prepare a slice per pass, then build in a pass of its own. The notes that only exist once the
-- walks have answered are measured where they are drawn; they are short, and come one at a time.
local function sectionHeldBack(section, i18n, w)
  if section.notes == nil or not inWidgetCall() then return false end
  return not notesMeasured(w, section.notes(i18n))
end

--- One open section's notes measured. Answers true on the pass after which no open section is
-- held back any more, which is when the page has to be built again to show them.
local function stepNotes(i18n)
  -- The wakeup is not told the page's width; the build that held the section back was.
  local w = ui.buildW
  local measured = false
  for i = 1, #SECTIONS do
    local section = SECTIONS[i]
    if ui.sections[section.key] and sectionHeldBack(section, i18n, w) then
      -- One section per pass, and the pass that measured one asks whether another is still waiting.
      if measured then return false end
      local texts = { section.notes(i18n) }
      for j = 1, #texts do noteLines(texts[j], w) end
      measured = true
    end
  end
  ui.notesWanted = false
  return measured
end

function M.build(ctx)
  ensureDeps()
  ensureLoaded(ctx.preferences)
  ui.runtime.setRequestRebuild(ctx.requestRebuild)
  ui.runtime.openHelp = ctx.openHelp
  -- ui/home.lua builds before it calls the page's wakeup in the same pass; see M.wakeup.
  ui.builtThisPass = true
  ui.hosted = inWidgetCall()
  -- A build closes every editor that was open; see markValue.
  ui.gvarEditOpen = false

  local children = ctx.children
  local x, w = ctx.x, ctx.w
  local i18n = ctx.i18n
  local cursorY = ctx.y
  ui.buildW = w
  -- markValue writes the warning from a callback, which is handed no i18n.
  ui.i18n = i18n
  ui.requestRebuild = ctx.requestRebuild
  ui.saveCtx = ctx

  -- While a job runs the page is that job's box and nothing else: no control under it can change
  -- what the pilot has just agreed to.
  if ui.job ~= nil or ui.jobResult ~= nil then
    radioModelName()
    appendJobBox(children, x, cursorY, w, ctx.h, i18n)
    return
  end

  for i = 1, #SECTIONS do
    local section = SECTIONS[i]
    if i > 1 then cursorY = cursorY + 10 end
    Controls.appendSectionHeader(children, x, cursorY, w,
      t(i18n, section.titleKey, section.titleFallback),
      ui.sections[section.key],
      function()
        ui.runtime.getSectionToggleHandler(section.key)()
      end)
    cursorY = cursorY + Controls.SECTION_H
    if ui.sections[section.key] then
      if sectionHeldBack(section, i18n, w) then
        ui.notesWanted = true
      else
        cursorY = section.build(children, x, cursorY, w, i18n)
      end
    end
  end
end

--- The model walks, a slice per pass, while the page runs inside the widget's call (see
-- inWidgetCall). One job at a time and one slice of it per pass: first the notes of a section
-- that is held back (see sectionHeldBack), because the pilot has just opened it; then the trims,
-- because the check and the setup button wait on them. The pass that completes a job asks for one
-- rebuild, which is when the screen can say what it found -- except a variable job while one of the
-- two variables' editors may be open (see appendGvarNote).
function M.wakeup(ctx)
  if not ui.loaded or Setup == nil then return end
  -- Never in the pass that built the page: the build is the most expensive thing that pass does,
  -- and a slice beside it is what would take the pass over the limit. One pass later costs nothing.
  -- This relies on builds being event-driven: a page rebuilt on every pass would never take a
  -- slice, and would show its reading notice for as long as it stays open.
  if ui.builtThisPass then
    ui.builtThisPass = false
    return
  end
  if ui.job ~= nil then
    stepJob()
    return
  end
  -- A pass of its own, as a save is.
  if settleFault() then return end
  -- The record on the card, once per visit: whether a restore is on offer.
  if not inWidgetCall() then
    if not ui.recordChecked and stepRecordCheck() then requestRebuild() end
    return
  end
  local finished = false
  if ui.notesWanted then
    finished = stepNotes(ctx and ctx.i18n)
  elseif ui.trimNames == nil then
    finished = stepTrimWalk()
  elseif ui.gvarWalkWanted and not ui.gvarWalkDone then
    finished = stepGvarWalk()
    -- One of the two variables was edited while the walk ran, and its editor may still be open:
    -- the answer goes into the line under the fields, and the page is built when the editor closes
    -- (see appendGvarNote).
    if finished and ui.gvarEditOpen then
      refreshGvarNote()
      finished = false
    end
  elseif ui.gvarNamesWanted and not ui.gvarNamesDone then
    -- Every variable's name, kept for the visit; see gvarNameClashes.
    ui.gvarNameOf = Setup.gvarNames(radio())
    ui.gvarNamesDone = true
    ui.gvarNamesWanted = false
    finished = not ui.gvarEditOpen
  elseif not ui.recordChecked then
    finished = stepRecordCheck()
  end
  if finished and ctx and type(ctx.requestRebuild) == "function" then ctx.requestRebuild() end
end

function M.onClose()
  Common.resetPageState(ui)
  ui.radio = nil
  ui.checkResult = nil
  ui.trimNames = nil
  ui.trimScan = nil
  ui.gvarWalk = nil
  ui.gvarWalkDone = false
  ui.gvarWalkWanted = false
  ui.gvarConflicts = nil
  ui.gvarUsed = nil
  ui.gvarNamesDone = false
  ui.gvarNamesWanted = false
  ui.gvarNames = nil
  ui.gvarNameOf = nil
  ui.gvarNote = nil
  ui.gvarEditOpen = false
  ui.builtThisPass = false
  ui.gvarModelChanged = false
  ui.widestWarning = nil
  ui.i18n = nil
  ui.noteLines = nil
  ui.noteW = nil
  ui.buildW = nil
  ui.hosted = nil
  ui.notesWanted = false
  -- A job cut off here is safe: its record on the card still says `partial`, and the next visit
  -- offers the restore.
  ui.job = nil
  ui.jobResult = nil
  ui.requestRebuild = nil
  ui.saveCtx = nil
  ui.recordChecked = false
  ui.recordParse = nil
  ui.recordOffer = false
  ui.modelName = nil
  Controls = nil
  Common = nil
  Setup = nil
  Plan = nil
  Backup = nil
  LoadingOverlay = nil
  Armed = nil
  Env = nil
  t = nil
end

return M
