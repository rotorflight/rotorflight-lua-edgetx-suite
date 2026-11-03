local M = {}

local function loadModule(path)
  local fullPath = _G.rfsuite.paths.core .. "/" .. path
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
local Srxl2EscConfigApi = nil
local LoadingOverlay = nil
local SavePipeline = nil
local t = nil

local PAGE_ID = "setup_esc_motors_srxl2"

local function newRuntime()
  return {
    readPending = false,
    requestRebuild = nil
  }
end

local ui = {
  loaded = false,
  dirty = false,
  loading = false,
  progress = 0,
  -- What the board answered. `throttle_rate_hz` is never edited: it goes back unchanged.
  config = nil,
  readFailed = false,
  unsupported = false,
  runtime = newRuntime()
}

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not Srxl2EscConfigApi then Srxl2EscConfigApi = loadModule("tasks/msp/api/srxl2_esc_config.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not t then t = Common and Common.pageT("setup_esc_motors") or nil end
  if type(ui.runtime) ~= "table" then ui.runtime = newRuntime() end
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

local function requestRebuild()
  if ui.runtime and type(ui.runtime.requestRebuild) == "function" then ui.runtime.requestRebuild() end
end

-- `unsupported` only for an error reply: that is how a firmware without the message, or built
-- without the SRXL2 ESC driver, answers it. A timeout, a cleared request or a reply this page
-- cannot decode says nothing about the firmware and is shown as a failed read.
local function finishRead(config, unsupported)
  ui.runtime.readPending = false
  ui.loading = false
  ui.config = config
  ui.readFailed = config == nil
  ui.unsupported = config == nil and unsupported == true
  if config then
    ui.dirty = false
    ui.progress = 100
  end
  requestRebuild()
end

local function queueRead()
  if ui.runtime.readPending then return false end
  local mspState = MspRuntime and type(MspRuntime.getState) == "function" and MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not Srxl2EscConfigApi or not queue or type(queue.add) ~= "function" then return false end

  ui.runtime.readPending = true
  ui.loading = true
  ui.progress = 0
  ui.readFailed = false
  ui.unsupported = false
  requestRebuild()

  queue:add({
    command = Srxl2EscConfigApi.command,
    simulatorResponse = Srxl2EscConfigApi.simulatorResponse,
    processReply = function(_, buf)
      finishRead(Srxl2EscConfigApi.parse(buf))
    end,
    errorHandler = function(_, reason)
      finishRead(nil, reason == "refused")
    end
  })
  return true
end

local function queueWrite()
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or not Srxl2EscConfigApi then return false, "msp_runtime_unavailable" end

  return SavePipeline.start({
    pageId = PAGE_ID,
    steps = {
      {
        label = "MSP2_SET_SRXL2_ESC_CONFIG",
        command = Srxl2EscConfigApi.writeCommand,
        payload = Srxl2EscConfigApi.buildWritePayload(ui.config)
      }
    },
    -- The ESC driver reads these settings at boot only, and latches the motor 2 channel there.
    reboot = true,
    onSaved = function()
      ui.dirty = false
    end,
    onDone = function(result)
      if result.status ~= "done" then ui.dirty = true end
      requestRebuild()
    end
  })
end

local function ensureLoaded()
  if ui.loaded then return end
  -- A save whose overlay was dismissed finished without a screen. Its outcome was held back
  -- rather than raised over whatever page the user went to; claim it now that this one is open.
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if SavePipeline and type(SavePipeline.takeResult) == "function" then
    SavePipeline.takeResult(PAGE_ID)
  end
  ui.loaded = true
  ui.dirty = false
  ui.config = nil
  queueRead()
end

function M.wakeup(ctx)
  ensureDeps()
  ensureLoaded()
  if type(ctx) == "table" and type(ctx.requestRebuild) == "function" then
    ui.runtime.requestRebuild = ctx.requestRebuild
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

local function offOrNumber(offText)
  return function(value)
    local n = tonumber(value) or 0
    if n == 0 then return offText end
    return tostring(math.floor(n))
  end
end

function M.build(ctx)
  ensureDeps()
  ensureLoaded()

  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil

  local children = ctx.children
  local x, y, w, h = ctx.x, ctx.y, ctx.w, ctx.h
  local i18n = ctx.i18n

  if ui.loading then
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = "@i18n(app.loading)@",
      message = pageText(i18n, "loading_srxl2", "Loading SRXL2 ESC settings..."),
      progress = ui.progress / 100
    })
    return
  end

  local title = pageText(i18n, "title_srxl2", "SRXL2 ESC")

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, title)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  if ui.unsupported or not ui.config then
    cursorY = cursorY + 10
    if ui.unsupported then
      children[#children + 1] = {
        type = "label",
        x = x + 10, y = cursorY, w = w - 20,
        text = pageText(i18n, "srxl2_unsupported",
          "This flight controller firmware does not offer the SRXL2 ESC settings."),
        color = Palette.text,
        font = SMLSIZE
      }
    else
      Common.appendReadFailedNotice(children, x, cursorY, w)
    end
    return
  end

  -- A row's ? opens its line in the tool's help view, titled with the row's label.
  local openHelp = ctx.openHelp
  local function onRowHelp(text, label)
    if type(openHelp) == "function" and type(text) == "string" and text ~= "" then openHelp(text, label) end
  end
  local offText = pageText(i18n, "srxl2_off", "Off")
  -- `set` runs on every click while the editor is open and a rebuild would close it, so the
  -- unsaved notice is drawn once the editor has closed, and only when it is not on screen yet.
  local noticeShown = ui.dirty
  local function afterEdit()
    if ui.dirty and not noticeShown then requestRebuild() end
  end

  local label = pageText(i18n, "srxl2_telem_interval", "Telemetry Interval")
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, label, {
    helpText = pageText(i18n, "help_srxl2_telem_interval",
      "How many throttle frames pass between two telemetry requests to the ESC, 0 to 255; Off (0) stops the telemetry polling. Default 7."),
    helpTitle = label,
    onHelp = onRowHelp,
    min = 0,
    max = 255,
    display = offOrNumber(offText),
    edited = afterEdit,
    get = function() return ui.config.telem_interval_frames end,
    set = function(v)
      ui.config.telem_interval_frames = tonumber(v) or 0
      ui.dirty = true
    end
  })

  label = pageText(i18n, "srxl2_motor2_channel", "Motor 2 Channel")
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w, label, {
    helpText = pageText(i18n, "help_srxl2_motor2_channel",
      "For dual-motor Smart ESCs: the SRXL2 channel that carries motor 2 (motor 1 is always channel 0); the mixer's second motor output drives it. Off for one motor."),
    helpTitle = label,
    onHelp = onRowHelp,
    min = 0,
    max = 31,
    display = offOrNumber(offText),
    edited = afterEdit,
    get = function() return ui.config.motor2_channel end,
    set = function(v)
      ui.config.motor2_channel = tonumber(v) or 0
      ui.dirty = true
    end
  })

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

-- Save waits for the visit's read: until it has answered there is nothing of the board's to
-- write back. A failed or refused read is refused in onSave, with the reason.
function M.canSave()
  return not (ui.runtime and ui.runtime.readPending)
end

function M.onSave(ctx)
  local i18n = ctx and ctx.i18n
  if not ui.config then
    if ctx and type(ctx.reportSave) == "function" then
      local message = "@i18n(app.read_failed)@"
      if ui.unsupported then
        message = pageText(i18n, "srxl2_unsupported",
          "This flight controller firmware does not offer the SRXL2 ESC settings.")
      end
      ctx.reportSave({ title = pageText(i18n, "save_error_title", "Error"), message = message })
    end
    return false
  end

  local ok, err = queueWrite()
  if not ok then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        title = pageText(i18n, "save_error_title", "Error"),
        message = tostring(err or "MSP write failed")
      })
    end
    return false
  end
  return true
end

function M.onReload()
  ui.dirty = false
  queueRead()
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/esc_motors/srxl2/help.lua")
  if type(help) == "function" then
    return help(ctx)
  end
  local i18n = ctx and ctx.i18n
  return {
    title = pageText(i18n, "help_title_srxl2", "SRXL2 ESC Help"),
    message = pageText(i18n, "help_p1_srxl2",
      "Settings of a Spektrum Smart ESC on the SRXL2 ESC port; saving reboots the flight controller, and each row's ? explains its setting.")
  }
end

function M.onClose()
  if Common and type(Common.resetPageState) == "function" then
    Common.resetPageState(ui, {
      resetLoaded = true,
      resetDirty = true
    })
  end
  ui.config = nil
  ui.readFailed = false
  ui.unsupported = false
  ui.loading = false
  Controls = nil
  Common = nil
  MspRuntime = nil
  Srxl2EscConfigApi = nil
  LoadingOverlay = nil
  SavePipeline = nil
  t = nil
end

-- Asked before the page is left (ui/home.lua): true while an edit here is not saved.
function M.hasUnsavedChanges()
  return ui.dirty == true
end

return M
