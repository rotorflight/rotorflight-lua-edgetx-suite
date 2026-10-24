local M = {}

local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Palette = _G.rfsuite and _G.rfsuite.palette or (_G.rfsuite and _G.rfsuite.require or loadModule)("ui/palette.lua")

local Controls = nil
local Common = nil
local MspRuntime = nil
local RxfailConfigApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local SavePipeline = nil
local t = nil

-- One key and fallback pair per channel, in the form the packager translates in place, so an
-- installed suite shows the channel names in the pilot's language.
local CHANNEL_NAMES = {
  { labelKey = "roll", labelFallback = "Roll" },
  { labelKey = "pitch", labelFallback = "Pitch" },
  { labelKey = "yaw", labelFallback = "Yaw" },
  { labelKey = "collective", labelFallback = "Collective" },
  { labelKey = "throttle", labelFallback = "Throttle" },
  { labelKey = "aux1", labelFallback = "AUX 1" },
  { labelKey = "aux2", labelFallback = "AUX 2" },
  { labelKey = "aux3", labelFallback = "AUX 3" },
  { labelKey = "aux4", labelFallback = "AUX 4" },
  { labelKey = "aux5", labelFallback = "AUX 5" },
  { labelKey = "aux6", labelFallback = "AUX 6" },
  { labelKey = "aux7", labelFallback = "AUX 7" },
  { labelKey = "aux8", labelFallback = "AUX 8" },
  { labelKey = "aux9", labelFallback = "AUX 9" },
  { labelKey = "aux10", labelFallback = "AUX 10" },
  { labelKey = "aux11", labelFallback = "AUX 11" },
  { labelKey = "aux12", labelFallback = "AUX 12" },
  { labelKey = "aux13", labelFallback = "AUX 13" }
}

local ui = {
  loaded = false,
  dirty = false,
  channels = {}, -- index 1..18, each { mode = 0, value = 1500 }
  runtime = {
    readPending = false,
    requestRebuild = nil,
    lastSessionSignature = nil,
    syncHeaderTitle = nil
  },
  loading = false,
  progress = 0,
  baseTitle = nil,
  dirtyChannels = {} -- maps channelIndex (1..18) -> true
}

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not RxfailConfigApi then RxfailConfigApi = loadModule("tasks/msp/api/rxfail_config.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not t then t = Common and Common.pageT("setup_failsafe") or nil end
end

local function pageText(i18n, key, fallback)
  if t then
    local translated = t(i18n, key, fallback)
    if translated ~= nil and translated ~= "" and translated ~= key then
      return translated
    end
  end
  return fallback
end

local function buildSessionSignature()
  local session = getSession()
  return session and session.signature or "1"
end

local function loadFromSession()
  local session = getSession()
  if not session or type(session.setup_controls_failsafe) ~= "table" then return end
  for i = 1, 18 do
    local ch = session.setup_controls_failsafe[i]
    if ch then
      ui.channels[i] = {
        mode = tonumber(ch.mode) or 0,
        value = tonumber(ch.value) or 1500
      }
    end
  end
end

local function queueFailsafeRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not MspRuntime or not RxfailConfigApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  local readValid = type(getSession()) == "table"
  ui.runtime.readPending = true
  if not isAutoReload then
    ui.loading = true
    ui.progress = 0
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  queue:add({
    command = RxfailConfigApi.command,
    simulatorResponse = RxfailConfigApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = RxfailConfigApi.parse(buf)
      if type(parsed) ~= "table" then return Common.failPageRead(ui) end
      if parsed then
        for i = 1, 18 do
          ui.channels[i] = {
            mode = parsed["channel_" .. i .. "_mode"] or 0,
            value = parsed["channel_" .. i .. "_value"] or 1500
          }
        end
        -- Sync to session
        local session = getSession()
        if session then
          if type(session.setup_controls_failsafe) ~= "table" then
            session.setup_controls_failsafe = {}
          end
          for i = 1, 18 do
            session.setup_controls_failsafe[i] = {
              mode = ui.channels[i].mode,
              value = ui.channels[i].value
            }
          end
        end
      end

      ui.runtime.readPending = false
      ui.loading = false
      ui.dirty = false
      ui.progress = 100
      ui.runtime.readComplete = readValid
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end,
    errorHandler = function()
      readValid = false
      ui.runtime.readPending = false
      ui.loading = false
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })

  return true, nil
end

local function queueFailsafeWrite(requestRebuild)
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or not RxfailConfigApi then
    return false, "msp_runtime_unavailable"
  end

  -- What is saved, taken now: the page can be left while the writes are on the wire, and a page
  -- opened again starts from other values. Every payload and the session copy come from here.
  local saved = {}
  local steps = {}
  for i = 1, 18 do
    if ui.dirtyChannels[i] then
      local ch = ui.channels[i]
      saved[#saved + 1] = { index = i, mode = ch.mode, value = ch.value }
      steps[#steps + 1] = {
        label = "MSP_SET_RXFAIL_CONFIG",
        command = RxfailConfigApi.writeCommand,
        payload = RxfailConfigApi.buildWritePayload({ index = i - 1, mode = ch.mode, value = ch.value })
      }
    end
  end

  if #steps == 0 then
    -- nothing to write
    return true
  end

  -- The visit this save belongs to. The page's close sets ui.runtime to nil and its next visit
  -- creates a new table, so the hooks below change this visit's state only -- never the edits of
  -- a visit opened since, which its own Save would then no longer write.
  local visit = ui.runtime

  -- The writes and the EEPROM commit belong to the pipeline, not to this page: the page can be
  -- left while they are on the wire, and its close releases ui.runtime and the module handles
  -- above. So nothing below may assume the page is still open.
  local ok, err = SavePipeline.start({
    pageId = "setup_controls_failsafe",
    steps = steps,
    reboot = false,
    onSaved = function()
      local session = getSession()
      if session then
        if type(session.setup_controls_failsafe) ~= "table" then
          session.setup_controls_failsafe = {}
        end
        for _, ch in ipairs(saved) do
          session.setup_controls_failsafe[ch.index] = { mode = ch.mode, value = ch.value }
        end
      end
      if ui.runtime ~= visit then return end
      ui.dirtyChannels = {}
      ui.dirty = false
    end,
    onDone = function(result)
      if ui.runtime ~= visit then return end
      ui.saving = false
      if result.saved then queueFailsafeRead(true) end
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })
  if not ok then return false, err end

  ui.saving = true
  ui.progress = 0
  if type(requestRebuild) == "function" then
    requestRebuild()
  end
  return true
end

local function ensureLoaded()
  if ui.loaded then return end

  if not ui.runtime then
    ui.runtime = {
      readPending = false,
      requestRebuild = nil,
      lastSessionSignature = nil,
      syncHeaderTitle = nil
    }
  end
  ui.loading = false
  ui.saving = false
  ui.runtime.readPending = false

  ui.channels = {}
  for i = 1, 18 do
    ui.channels[i] = { mode = 0, value = 1500 }
  end
  ui.dirtyChannels = {}

  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()
  queueFailsafeRead(false)
end

function M.wakeup(ctx)
  ensureDeps()
  ensureLoaded()

  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil

  local signature = buildSessionSignature()
  if signature ~= ui.runtime.lastSessionSignature then
    ui.runtime.lastSessionSignature = signature
    ui.loaded = false
    ensureLoaded()
  end
end

function M.getHeaderActions()
  return {
    save = true,
    reload = true,
    help = true,
    menu = true
  }
end

function M.build(ctx)
  ensureDeps()
  ensureLoaded()

  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil

  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local h = ctx.h
  local i18n = ctx.i18n

  if ui.loading or ui.saving then
    local titleText = ui.loading and "@i18n(app.loading)@" or "@i18n(app.saving)@"
    local msgText = ui.loading and pageText(i18n, "loading", "Loading failsafe configuration...") or pageText(i18n, "saving", "Saving failsafe configuration...")
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = titleText,
      message = msgText,
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or "Failsafe"
  local title = pageText(i18n, "title", displayTitle)
  if type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(title, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, title)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 38)
  end

  local rightMargin = 10
  local leftMargin = 10
  local gap = 8
  local modeW = math.floor(w * 0.32)
  local valueW = math.floor(w * 0.24)
  local rowH = (Controls and Controls.ROW_H) or 40
  local valueX = w - rightMargin - valueW
  local modeX = valueX - gap - modeW
  local titleW = modeX - leftMargin - gap

  local labelYOffset = (Controls and Controls.labelY and Controls.labelY(0, rowH)) or math.floor((rowH - 21) / 2)
  local controlYOffset = (Controls and Controls.controlY and Controls.controlY(0, rowH)) or math.floor((rowH - 32) / 2)

  local modeOptions = {
    { label = pageText(i18n, "mode_auto", "Auto"), value = 0 },
    { label = pageText(i18n, "mode_hold", "Hold"), value = 1 },
    { label = pageText(i18n, "mode_set", "Set"), value = 2 }
  }

  for i = 1, 18 do
    local channelName = CHANNEL_NAMES[i]
    local chName = pageText(i18n, channelName.labelKey, channelName.labelFallback)
    local ch = ui.channels[i] or { mode = 0, value = 1500 }

    -- 1. Left Label
    children[#children + 1] = {
      type  = "label",
      x = x + leftMargin, y = cursorY + labelYOffset,
      w = titleW,
      text  = chName,
      color = Palette.text,
      font  = SMLSIZE
    }

    -- 2. Choice field for mode
    local values = {}
    local selectedIndex = 1
    for mIdx, opt in ipairs(modeOptions) do
      values[mIdx] = tostring(opt.label or "")
      if opt.value == ch.mode then
        selectedIndex = mIdx
      end
    end

    children[#children + 1] = {
      type  = "choice",
      x = x + modeX, y = cursorY + controlYOffset,
      w = modeW,
      title = chName,
      values = values,
      get = function()
        return selectedIndex
      end,
      set = function(nextIndex)
        local idx = tonumber(nextIndex) or selectedIndex
        if idx < 1 then idx = 1 end
        if idx > #modeOptions then idx = #modeOptions end
        selectedIndex = idx
        local opt = modeOptions[idx]
        if opt then
          local oldMode = ch.mode
          ch.mode = opt.value
          if oldMode ~= ch.mode then
            ui.dirtyChannels[i] = true
            ui.dirty = true
            -- Request rebuild to show/hide/enable/disable the value field
            if type(ui.runtime.requestRebuild) == "function" then
              ui.runtime.requestRebuild()
            end
          end
        end
      end
    }

    -- 3. NumberEdit field for value
    local isEnabled = (ch.mode == 2) -- Active only when Set (2)
    children[#children + 1] = {
      type = "numberEdit",
      x = x + valueX, y = cursorY + controlYOffset,
      w = valueW,
      min = math.floor(875 / 5),
      max = math.ceil(2125 / 5),
      active = function()
        return isEnabled
      end,
      get = function()
        local current = tonumber(ch.value) or 1500
        if current < 875 then current = 875 end
        if current > 2125 then current = 2125 end
        return math.floor(current / 5)
      end,
      set = function(val)
        local nextVal = (tonumber(val) or 300) * 5
        if nextVal < 875 then nextVal = 875 end
        if nextVal > 2125 then nextVal = 2125 end
        local oldVal = ch.value
        ch.value = nextVal
        if oldVal ~= ch.value then
          ui.dirtyChannels[i] = true
          ui.dirty = true
        end
      end,
      display = function(val)
        local shown = (tonumber(val) or 300) * 5
        return tostring(shown) .. "us"
      end
    }

    -- 4. Separator Line
    children[#children + 1] = {
      type   = "rectangle",
      x = x, y = cursorY + rowH,
      w = w, h = 1,
      color  = Palette.border, filled = true
    }

    cursorY = cursorY + rowH + 1
  end

  if ui.dirty then
    children[#children + 1] = {
      type = "label",
      x = x + 16, y = cursorY + 10,
      text = pageText(i18n, "unsaved_changes", "Unsaved changes"),
      color = Palette.accent,
      font = SMLSIZE
    }
  end
end

function M.canSave()
  return ui.runtime ~= nil and ui.runtime.readComplete == true and not ui.runtime.readPending
end

function M.onSave(ctx)
  if not M.canSave() then return false, "loaded_data_missing" end
  -- The header's Save stays reachable over the overlay. The shared save refuses a second save
  -- while this one runs, and that refusal would be reported as a failed save.
  if ui.saving then return false end
  local ok, err = queueFailsafeWrite(ctx and ctx.requestRebuild)
  if not ok then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        title = pageText(ctx and ctx.i18n, "save_error_title", "Error"),
        message = tostring(err or "MSP write failed")
      })
    end
    return false
  end
  return true
end

function M.onReload(ctx)
  -- Nothing is read under a running save; Reload works again once the save has finished.
  if ui.saving then return true end
  local session = getSession()
  if session then
    ui.dirtyChannels = {}
    loadFromSession()
    ui.dirty = false
    queueFailsafeRead(false)
  end
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/controls/failsafe/help.lua")
  if type(help) == "function" then
    return help(ctx)
  end
  return { title = "Help", message = "No help available" }
end


function M.onClose()
  if Common and type(Common.resetPageState) == "function" then
    Common.resetPageState(ui, {
      resetLoaded = true,
      resetDirty = true
    })
  end
  Controls = nil
  Common = nil
  MspRuntime = nil
  RxfailConfigApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  SavePipeline = nil
  t = nil
end

-- Asked before the page is left (ui/home.lua): true while an edit here is not saved.
function M.hasUnsavedChanges()
  return ui.dirty == true
end

return M
