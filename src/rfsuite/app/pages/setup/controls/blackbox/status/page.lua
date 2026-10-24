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
local DataflashSummaryApi = nil
local SdcardSummaryApi = nil
local DataflashEraseApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local t = nil

local SDCARD_STATE = {
  NOT_PRESENT = 0,
  FATAL = 1,
  CARD_INIT = 2,
  FS_INIT = 3,
  READY = 4
}

local ui = {
  loaded = false,
  dirty = false,
  dataflash = {
    ready = false,
    supported = false,
    totalSize = 0,
    usedSize = 0
  },
  sdcard = {
    supported = false,
    state = 0,
    filesystemLastError = 0,
    freeSizeKB = 0,
    totalSizeKB = 0
  },
  eraseInProgress = false,
  eraseStarted = false,
  loading = false,
  saving = false,
  progress = 0,
  baseTitle = nil,
  runtime = {
    readPending = false,
    requestRebuild = nil,
    lastSessionSignature = nil,
    syncHeaderTitle = nil,
    lastPollTime = 0
  }
}

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not DataflashSummaryApi then DataflashSummaryApi = loadModule("tasks/msp/api/dataflash_summary.lua") end
  if not SdcardSummaryApi then SdcardSummaryApi = loadModule("tasks/msp/api/sdcard_summary.lua") end
  if not DataflashEraseApi then DataflashEraseApi = loadModule("tasks/msp/api/dataflash_erase.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not t then t = Common and Common.pageT("setup_blackbox") or nil end
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

local function nowSeconds()
  if getTime then
    local ok, value = pcall(getTime)
    if ok and type(value) == "number" then
      return value / 100
    end
  end
  if os and type(os.clock) == "function" then
    return os.clock()
  end
  return 0
end

local function formatSize(bytes)
  if not bytes or bytes <= 0 then return "0 B" end
  if bytes < 1024 then return string.format("%d B", bytes) end
  local kb = bytes / 1024
  if kb < 1024 then return string.format("%.1f kB", kb) end
  local mb = kb / 1024
  if mb < 1024 then return string.format("%.1f MB", mb) end
  local gb = mb / 1024
  return string.format("%.2f GB", gb)
end

local function formatDataflashStatus(i18n)
  if not ui.dataflash.supported then return pageText(i18n, "not_supported", "Not supported") end
  if ui.eraseInProgress or not ui.dataflash.ready then return pageText(i18n, "erasing_busy", "Erasing / busy...") end
  local total = ui.dataflash.totalSize or 0
  local used = ui.dataflash.usedSize or 0
  return string.format(pageText(i18n, "used_fmt", "Used %s / %s"), formatSize(used), formatSize(total))
end

local function formatSDCardStatus(i18n)
  if not ui.sdcard.supported then return pageText(i18n, "not_supported", "Not supported") end
  local state = ui.sdcard.state or SDCARD_STATE.NOT_PRESENT
  if state == SDCARD_STATE.NOT_PRESENT then return pageText(i18n, "no_card", "No card") end
  if state == SDCARD_STATE.FATAL then return string.format(pageText(i18n, "error_code_fmt", "Error (code %d)"), ui.sdcard.filesystemLastError or 0) end
  if state == SDCARD_STATE.CARD_INIT then return pageText(i18n, "initializing_card", "Initializing card...") end
  if state == SDCARD_STATE.FS_INIT then return pageText(i18n, "initializing_filesystem", "Initializing filesystem...") end
  if state == SDCARD_STATE.READY then
    local totalKB = ui.sdcard.totalSizeKB or 0
    local freeKB = ui.sdcard.freeSizeKB or 0
    local usedKB = math.max(totalKB - freeKB, 0)
    return string.format(pageText(i18n, "used_fmt", "Used %s / %s"), formatSize(usedKB * 1024), formatSize(totalKB * 1024))
  end
  return string.format(pageText(i18n, "unknown_state_fmt", "Unknown state (%d)"), state)
end

local function pollSummaries(isAuto)
  if not ui.runtime or ui.runtime.readPending then return end
  ensureDeps()
  if not MspRuntime or not DataflashSummaryApi or not SdcardSummaryApi or type(MspRuntime.getState) ~= "function" then
    return
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return
  end

  ui.runtime.readPending = true
  if not isAuto then
    ui.loading = true
    ui.progress = 0
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  local dfApi = DataflashSummaryApi
  local sdApi = SdcardSummaryApi

  -- Queue Dataflash Summary Read
  queue:add({
    command = dfApi.command,
    simulatorResponse = dfApi.simulatorResponse,
    processReply = function(self, buf)
      if not ui.loaded or not ui.runtime or not ui.runtime.readPending then return end
      local api = DataflashSummaryApi or dfApi
      if api and type(api.parse) == "function" then
        local reply = api.parse(buf)
        if reply then
          ui.dataflash.ready = (reply.flags & 1) ~= 0
          ui.dataflash.supported = (reply.flags & 2) ~= 0
          ui.dataflash.totalSize = reply.total
          ui.dataflash.usedSize = reply.used
        end
      end

      local currentSdApi = SdcardSummaryApi or sdApi
      if not currentSdApi then
        if ui.runtime then ui.runtime.readPending = false end
        ui.loading = false
        return
      end

      -- Now queue SD Card Summary Read
      queue:add({
        command = currentSdApi.command,
        simulatorResponse = currentSdApi.simulatorResponse,
        processReply = function(self2, buf2)
          if not ui.loaded or not ui.runtime or not ui.runtime.readPending then return end
          local replyApi = SdcardSummaryApi or currentSdApi
          if replyApi and type(replyApi.parse) == "function" then
            local reply2 = replyApi.parse(buf2)
            if reply2 then
              ui.sdcard.supported = reply2.supported
              ui.sdcard.state = reply2.state
              ui.sdcard.filesystemLastError = reply2.filesystemLastError
              ui.sdcard.freeSizeKB = reply2.freeSizeKB
              ui.sdcard.totalSizeKB = reply2.totalSizeKB
            end
          end

          if ui.runtime then ui.runtime.readPending = false end
          ui.loading = false
          -- During an erase this is one of the polls that wait for the flash; the bar belongs
          -- to the erase then and stays where the erase put it.
          if not ui.eraseInProgress then ui.progress = 100 end
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end,
        errorHandler = function()
          if not ui.loaded or not ui.runtime then return end
          ui.runtime.readPending = false
          ui.loading = false
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end
      })
    end,
    errorHandler = function()
      if not ui.loaded or not ui.runtime then return end
      ui.runtime.readPending = false
      ui.loading = false
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })
end

local function queueEraseDataflash()
  ensureDeps()
  if not MspRuntime or not DataflashEraseApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  ui.eraseInProgress = true
  ui.eraseStarted = false
  ui.loading = false
  ui.saving = true -- This displays the Saving/Erasing overlay
  ui.progress = 0
  if type(ui.runtime.requestRebuild) == "function" then
    ui.runtime.requestRebuild()
  end

  local eraseApi = DataflashEraseApi
  queue:add({
    command = eraseApi.writeCommand,
    payload = eraseApi.buildWritePayload({}),
    isWrite = true,
    -- The quick menu's erase of the same command waits as long (widgets/dashboard/fullscreen_menu.lua);
    -- a resend after the default 2 s would ask the flight controller to erase a second time.
    timeout = 10.0,
    simulatorResponse = {},
    processReply = function()
      if not ui.loaded or not ui.runtime then return end
      -- Erase started successfully. We will monitor ui.dataflash.ready in wakeup.
      -- The ready flag held until now is from a summary sent before the erase: the flash was idle,
      -- which is why it could be erased. The queue sends one request at a time in order, so every
      -- summary answered from here on was asked after the erase command, and only such an answer
      -- may end the erase.
      ui.dataflash.ready = false
      ui.eraseStarted = true
      ui.progress = 50
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end,
    errorHandler = function()
      if not ui.loaded or not ui.runtime then return end
      ui.eraseInProgress = false
      ui.eraseStarted = false
      ui.saving = false
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })

  return true, nil
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

  ui.dataflash = {
    ready = false,
    supported = false,
    totalSize = 0,
    usedSize = 0
  }
  ui.sdcard = {
    supported = false,
    state = 0,
    filesystemLastError = 0,
    freeSizeKB = 0,
    totalSizeKB = 0
  }
  ui.eraseInProgress = false
  ui.eraseStarted = false
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()
  ui.runtime.lastPollTime = nowSeconds()
  pollSummaries(false)
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

  -- Periodic polling: every 2 seconds
  local now = nowSeconds()
  if not ui.runtime.readPending and not ui.saving and not ui.loading then
    if (now - ui.runtime.lastPollTime) >= 2.0 then
      ui.runtime.lastPollTime = now
      pollSummaries(true)
    end
  end

  -- Monitor erase completion:
  -- If we requested an erase, we poll continuously until ui.dataflash.ready becomes true again
  if ui.eraseInProgress then
    if not ui.runtime.readPending then
      if (now - ui.runtime.lastPollTime) >= 0.5 then
        ui.runtime.lastPollTime = now
        pollSummaries(true)
      end
    end
    if ui.eraseStarted and ui.dataflash.ready then
      ui.eraseInProgress = false
      ui.eraseStarted = false
      ui.saving = false
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  end
end

function M.getHeaderActions()
  -- `*` erases the onboard dataflash (M.onStar asks first). It is offered only once the board has
  -- reported a dataflash, and not while an erase is running: a board without one has nothing to
  -- erase, and its summary never reports a flash that is ready, so an erase command the board
  -- accepts would leave the page waiting indefinitely. Reload is held while erasing too: it
  -- reloads the page state, which would drop the wait for an erase still running.
  return {
    save = false,
    reload = not ui.eraseInProgress,
    help = true,
    menu = true,
    star = ui.dataflash.supported == true and not ui.eraseInProgress
  }
end

local function appendStatusRow(children, x, y, w, label, value)
  local rowH = (Controls and Controls.ROW_H) or 64
  local leftMargin = 15
  local rightMargin = 15
  local labelY = (Controls and Controls.labelY and Controls.labelY(y, rowH)) or (y + math.floor((rowH - 21) / 2))

  -- Left Label
  children[#children + 1] = {
    type  = "label",
    x = x + leftMargin, y = labelY,
    text  = label,
    color = Palette.text,
    font  = SMLSIZE
  }

  -- Right Label
  children[#children + 1] = {
    type  = "label",
    x = x + leftMargin, y = labelY,
    w = w - leftMargin - rightMargin,
    text  = value,
    color = Palette.text,
    align = RIGHT,
    font  = SMLSIZE
  }

  -- Divider Line
  children[#children + 1] = {
    type   = "rectangle",
    x = x, y = y + rowH,
    w = w, h = 1,
    color  = Palette.border, filled = true
  }

  return rowH + 1
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
    local titleText = ui.loading and "@i18n(app.loading)@" or "@i18n(app.erasing)@"
    local msgText = ui.loading and pageText(i18n, "loading_status", "Loading blackbox status...") or pageText(i18n, "erasing_dataflash", "Erasing dataflash...")
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = titleText,
      message = msgText,
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or "Status"
  local title = pageText(i18n, "title_status", displayTitle)
  if type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(title, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, title)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  -- Dataflash Status Row
  local dfStatus = formatDataflashStatus(i18n)
  cursorY = cursorY + appendStatusRow(children, x, cursorY, w, pageText(i18n, "dataflash", "Dataflash"), dfStatus)

  -- SD Card Status Row
  local sdStatus = formatSDCardStatus(i18n)
  cursorY = cursorY + appendStatusRow(children, x, cursorY, w, pageText(i18n, "sdcard", "SD Card"), sdStatus)
end

function M.onSave(ctx)
  return true
end

function M.onReload(ctx)
  ui.loaded = false
  ensureLoaded()
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/controls/blackbox/status/help.lua")
  if type(help) == "function" then
    return help(ctx)
  end
  return { title = "Help", message = "No help available" }
end

function M.onStar(ctx)
  if not ConfirmDialog then return false end
  -- The host resolves the header before the page's build resets its state, so on a revisit `*`
  -- can be drawn from the previous visit until this visit's first read answers; a press then is
  -- answered with a redraw, which greys the button.
  if ui.dataflash.supported ~= true or ui.eraseInProgress then return true end
  local i18n = ctx and ctx.i18n
  local title = pageText(i18n, "title_status", "Blackbox Status")
  local message = pageText(i18n, "erase_prompt", "Erase onboard dataflash logs?")

  ConfirmDialog.show({
    title = title,
    message = message,
    onConfirm = function()
      queueEraseDataflash()
    end
  })
  return true
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
  DataflashSummaryApi = nil
  SdcardSummaryApi = nil
  DataflashEraseApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  t = nil
end

return M
