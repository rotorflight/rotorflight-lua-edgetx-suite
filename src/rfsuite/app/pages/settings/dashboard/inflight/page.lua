-- Settings > Dashboard > In-flight tuning: radio wiring shared by all models.
-- Suggested flight-controller functions and the model flight list are configured from the
-- tuning screen on the ground. This page loads only the radio setup and its sliced model walks.

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
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
  local shared = modules and modules["/SCRIPTS/TOOLS/rfsuite-core/" .. SETUP_PATH]
  if type(shared) == "table" then return shared end
  return loadModule(SETUP_PATH)
end

local Common = nil
local Controls = nil
local Setup = nil
local ConfirmDialog = nil
local Env = nil

local M = {}

-- The switch picker's filters, as the firmware numbers them. Named here rather than reached for
-- as globals, following app/pages/setup_wizard/proc_radio.lua: SW_SWITCH is the physical switch
-- block, SW_NONE the empty entry that lets a pilot clear the choice. Trims are a filter of their
-- own and are deliberately not offered -- a trim drives a row rather than releasing the surface.
local SW_SWITCH = 1
-- The trim block, as its own filter. A trim is offered by the picker as two positions -- the
-- decrement and the increment -- and the overlay stores the increment; see Setup.normaliseTrim.
local SW_TRIM = 1 << 1
local SW_NONE = 1 << 20

-- How many of the lines the write would remove are named one by one in the question. Past this the
-- rest are counted instead: a confirmation nobody reads to the end is not a confirmation.
local PLAN_LINES_SHOWN = 6

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
  ui.planNotice = nil
  ui.notesWanted = false
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
local function appendTrimPicker(children, x, y, w, label, get, set)
  local pickerW = 172
  if pickerW > w then pickerW = w end
  local rowH = Controls.ROW_H
  children[#children + 1] = {
    type = "label", x = x, y = Controls.labelY(y, rowH), w = w - pickerW - 18,
    text = label, color = Palette.text, font = SMLSIZE
  }
  children[#children + 1] = {
    type = "switch",
    x = x + w - pickerW - 10, y = Controls.controlY(y, rowH), w = pickerW, h = rowH - 6,
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
      ui.planNotice = nil
      ui.runtime.markValueChanged()
    end
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
  ui.planNotice = nil
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

  if type(ctx.savePreferences) ~= "function" then return false, "preferences" end
  return ctx.savePreferences()
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

--- The question the pilot answers, built from the plan and not from what the page intended.
--
-- The destructive half comes first and with the count in the sentence, because that is the part
-- that cannot be undone from this page. The lines are then named the way the radio's own mixer
-- page names them, so that they can be recognised before they are gone.
local function planQuestion(i18n, plan)
  local lines = {}

  -- The plan is built from the fields as they stand, which is not the same as the file on the card:
  -- a channel or a variable edited and not yet saved is what gets written. Saying so is cheaper than
  -- refusing, and it is the truthful half -- a pilot who wants the saved values presses save first.
  lines[#lines + 1] = t(i18n, "plan_from_page",
    "It writes the values as they are set on this page, saved or not.")
  lines[#lines + 1] = ""

  local removals = 0
  for i = 1, #plan.channels do
    local entry = plan.channels[i]
    removals = removals + entry.removed
    if entry.removed > 0 then
      lines[#lines + 1] = string.format("%s CH%d: %d",
        t(i18n, "plan_remove", "Remove from"), entry.channel, entry.removed)
    end
  end
  if removals == 0 then
    lines[#lines + 1] = t(i18n, "plan_remove_none", "Nothing has to be removed.")
  end

  local shown = 0
  for i = 1, #plan.deletions do
    if shown >= PLAN_LINES_SHOWN then
      lines[#lines + 1] = string.format("  ... %d", #plan.deletions - shown)
      break
    end
    shown = shown + 1
    lines[#lines + 1] = "  - " .. tostring(plan.deletions[i].text)
  end

  lines[#lines + 1] = ""
  for i = 1, #plan.insertions do
    local entry = plan.insertions[i]
    lines[#lines + 1] = string.format("%s CH%d: %s",
      t(i18n, "plan_add", "Add to"), entry.channel, tostring(entry.text))
  end

  -- The logical switch that times each pulse, named the way the radio's own list names it, and
  -- only where an empty slot is about to be written: a slot that already holds it is left alone.
  if plan.ls ~= nil then
    lines[#lines + 1] = string.format("%s L%02d: |GV%d| > 0",
      t(i18n, "plan_ls", "Pulse timer"), plan.ls.slot + 1, plan.ls.gvar or 0)
  end

  for i = 1, #plan.gvars do
    local entry = plan.gvars[i]
    lines[#lines + 1] = string.format("%s GV%d %s -100..100",
      t(i18n, "plan_gvar", "Set"), entry.index, entry.name)
  end

  if #plan.trims > 0 then
    local modes = {}
    for i = 1, #plan.trims do modes[#modes + 1] = tostring(plan.trims[i].fm) end
    lines[#lines + 1] = string.format("%s %s",
      t(i18n, "plan_trims", "Trims off in flight mode"), table.concat(modes, ", "))
  end

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
  end
  return t(i18n, "plan_unsupported", "This radio does not offer the mixer writer.")
end

--- Plan, ask, write, check again -- and write nothing at all if the answer is no.
--
-- The plan is built here rather than carried over from the last build, so that the lines it offers
-- to delete are the ones on the model at the moment the question is asked. The write and the
-- re-check both happen inside the confirmation's own callback, which is where the pilot's answer
-- is; nothing outside this function reaches applyPlan.
local function offerSetup(i18n)
  -- The resolved trim block goes with the settings, exactly as it does into the check: a stored trim
  -- is a switch POSITION, and the plan's trim half indexes the firmware's own trim-mode table by the
  -- semantic number behind it. Without it no trim fault the check raises could be fixed here.
  -- So while the walk is still running there is no plan to offer yet.
  if trimsPending() then
    ui.planNotice = t(i18n, "reading_radio", "Reading the radio...")
    ui.runtime.markDirty()
    return
  end
  local plan = Setup.plan(radio(), ui.config, trimNames())
  if type(plan) ~= "table" or plan.ok ~= true then
    ui.planNotice = refusalText(i18n, type(plan) == "table" and plan.refused or nil)
    ui.runtime.markDirty()
    return
  end

  -- Nothing to write, so there is nothing to confirm. The dialog used to come up on a model that
  -- already matched and offer to delete the line it had written itself.
  if plan.nothing == true then
    ui.planNotice = t(i18n, "plan_nothing",
      "The model already carries this setup; nothing to write.")
    ui.runtime.markDirty()
    return
  end

  if ConfirmDialog == nil then
    ConfirmDialog = loadModule("ui/confirm_dialog.lua")
  end

  local function apply()
    local report = Setup.applyPlan(radio(), plan)
    -- The verdict on the screen was reached about the model as it was; the model has just changed.
    ui.checkDone = false
    -- So were the variable walk and the names kept for the visit (gvarConflicts): the next change
    -- of a variable reads the model again, as the standalone tool does (markValue). A walk still
    -- running has read part of the model as it was, so it starts again from the first channel.
    ui.gvarModelChanged = true
    if hostedVisit() and not ui.gvarWalkDone then ui.gvarWalk = nil end
    if report.failed > 0 then
      ui.planNotice = string.format("%s (%d/%d)",
        t(i18n, "plan_failed", "The radio refused part of the setup"),
        report.written, report.written + report.failed)
    else
      ui.planNotice = string.format("%s (%d)",
        t(i18n, "plan_done", "Model set up"), report.written)
    end
    ui.runtime.markDirty()
  end

  local shown = false
  if ConfirmDialog and type(ConfirmDialog.show) == "function" then
    shown = ConfirmDialog.show({
      title = t(i18n, "plan_title", "Set up the model"),
      message = planQuestion(i18n, plan),
      onConfirm = apply,
      onCancel = function()
        -- Deliberately empty of writes AND deliberately present: a declined plan changes nothing,
        -- and saying so here is what keeps that from being an accident of the dialog's defaults.
        ui.planNotice = t(i18n, "plan_cancelled", "Nothing was changed")
        ui.runtime.markDirty()
      end
    })
  end

  if not shown then
    -- No confirmation could be put up, so there is no answer to act on. A model write is not
    -- something to do on the assumption that the pilot would have said yes.
    ui.planNotice = t(i18n, "plan_no_dialog", "This radio cannot show the confirmation.")
    ui.runtime.markDirty()
  end
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
  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    t(i18n, "enabled", "In-flight tuning on this radio"),
    ui.runtime.getBoolGetter("enabled"),
    ui.runtime.getBoolSetter("enabled"))
  cursorY = cursorY + appendNote(children, x, cursorY, w,
    t(i18n, "enabled_note",
      "The master switch for every model."))

  cursorY = cursorY + appendNote(children, x, cursorY, w, describeCheck(i18n, checkResult()))

  -- The button that makes the model match what the verdict just reported. It sits here rather than
  -- in the wiring section because this is where that verdict is read.
  local btnW = math.min(240, w)
  local btnH = (lvgl and lvgl.UI_ELEMENT_HEIGHT) or Controls.CTRL_H or 32
  children[#children + 1] = {
    type = "button",
    x = x + math.floor((w - btnW) / 2), y = cursorY, w = btnW, h = btnH,
    text = t(i18n, "setup_model", "Set up the model"),
    press = function() offerSetup(i18n) end
  }
  cursorY = cursorY + btnH + 6

  if ui.planNotice then
    cursorY = cursorY + appendNote(children, x, cursorY, w, ui.planNotice)
  end

  return cursorY
end

local function appendNumber(children, x, y, w, label, key, minValue, maxValue, step, edited)
  return Controls.appendNumberField(children, x, y, w, label, {
    min = minValue,
    max = maxValue,
    step = step or 1,
    get = function() return ui.config[key] end,
    set = function(value) markValue(key, value) end,
    edited = edited
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
  cursorY = cursorY + appendNumber(children, x, cursorY, w,
    t(i18n, "bank_ch", "Enable channel"), "bank_ch", Setup.CHANNEL_MIN, Setup.CHANNEL_MAX)
  cursorY = cursorY + appendNumber(children, x, cursorY, w,
    t(i18n, "value_ch", "Value channel"), "value_ch", Setup.CHANNEL_MIN, Setup.CHANNEL_MAX)
  cursorY = cursorY + appendNumber(children, x, cursorY, w,
    t(i18n, "bank_gvar", "Enable variable"), "bank_gvar", 0, Setup.GVAR_MAX_INDEX, nil, gvarEdited)
  cursorY = cursorY + appendNumber(children, x, cursorY, w,
    t(i18n, "value_gvar", "Value variable"), "value_gvar", 0, Setup.GVAR_MAX_INDEX, nil, gvarEdited)

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
  cursorY = cursorY + Controls.appendRadioSwitch(children, x, cursorY, w,
    t(i18n, "trims", "Drive rows from the trims"),
    ui.runtime.getBoolGetter("trims"),
    ui.runtime.getBoolSetter("trims"))

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
  cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
    t(i18n, "trim_mode", "Trim layout"), modeOptions, ui.config.trim_mode,
    function(value)
      if ui.config.trim_mode == value then return end
      ui.config.trim_mode = value
      ui.checkDone = false
      ui.planNotice = nil
      ui.runtime.markDirty()
    end)

  if ui.config.trim_mode == Setup.TRIM_MODE_NAVIGATE then
    cursorY = cursorY + appendNote(children, x, cursorY, w, navigateNote)
    cursorY = cursorY + appendTrimPicker(children, x, cursorY, w,
      t(i18n, "bank_trim", "Group trim"), trimField("bank_trim"))
    cursorY = cursorY + appendNote(children, x, cursorY, w, bankTrimNote)
    cursorY = cursorY + appendTrimPicker(children, x, cursorY, w,
      t(i18n, "nav_trim", "Walk trim"), trimField("nav_trim"))
    cursorY = cursorY + appendTrimPicker(children, x, cursorY, w,
      t(i18n, "adj_trim", "Adjust trim"), trimField("adj_trim"))
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
  for row = 1, Setup.TRIM_COUNT do
    local index = row
    cursorY = cursorY + appendTrimPicker(children, x, cursorY, w, labels[row],
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
  local finished = false
  if not inWidgetCall() then return
  elseif ui.notesWanted then
    finished = stepNotes(ctx and ctx.i18n)
  elseif ui.trimNames == nil then
    finished = stepTrimWalk()
    -- The only notice the setup button can have left while the walk ran is the one saying so.
    if finished then ui.planNotice = nil end
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
  ui.planNotice = nil
  ui.noteLines = nil
  ui.noteW = nil
  ui.buildW = nil
  ui.hosted = nil
  ui.notesWanted = false
  Controls = nil
  Common = nil
  Setup = nil
  ConfirmDialog = nil
  Env = nil
  t = nil
end

return M
