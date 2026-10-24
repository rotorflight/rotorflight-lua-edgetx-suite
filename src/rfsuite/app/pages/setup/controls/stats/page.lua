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
local FlightStatsApi = nil
local LoadingOverlay = nil
local ConfirmDialog = nil
local ApiVersion = nil
local SavePipeline = nil
local t = nil

local ui = {
  loaded = false,
  dirty = false,
  loading = false,
  saving = false,
  progress = 0,
  baseTitle = nil,
  config = {
    flightcount = 0,
    totalflighttime = 0,
    totaldistance = 0,
    minarmedtime = 0
  },
  runtime = {
    readPending = false,
    requestRebuild = nil,
    lastSessionSignature = nil,
    syncHeaderTitle = nil
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
  if not FlightStatsApi then FlightStatsApi = loadModule("tasks/msp/api/flight_stats.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not ConfirmDialog then ConfirmDialog = loadModule("ui/confirm_dialog.lua") end
  if not ApiVersion then ApiVersion = loadModule("lib/api_version.lua") end
  if not t then t = Common and Common.pageT("setup_stats") or nil end
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
  if not session or type(session.setup_controls_stats) ~= "table" then return end
  local cached = session.setup_controls_stats
  ui.config.flightcount = tonumber(cached.flightcount) or 0
  ui.config.totalflighttime = tonumber(cached.totalflighttime) or 0
  ui.config.totaldistance = tonumber(cached.totaldistance) or 0
  ui.config.minarmedtime = tonumber(cached.minarmedtime) or 0
end

local function queueStatsRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not MspRuntime or not FlightStatsApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  local readValid = true
  ui.runtime.readPending = true
  if not isAutoReload then
    ui.loading = true
    ui.progress = 0
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  queue:add({
    command = FlightStatsApi.command,
    simulatorResponse = FlightStatsApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = FlightStatsApi.parse(buf)
      if type(parsed) ~= "table" then return Common.failPageRead(ui) end
      if parsed then
        ui.config.flightcount = parsed.flightcount or 0
        ui.config.totalflighttime = parsed.totalflighttime or 0
        ui.config.totaldistance = parsed.totaldistance or 0
        ui.config.minarmedtime = parsed.minarmedtime or 0

        -- Update session flightcount
        local session = getSession()
        if session then
          session.flightcount = ui.config.flightcount
          session.setup_controls_stats = {
            flightcount = ui.config.flightcount,
            totalflighttime = ui.config.totalflighttime,
            totaldistance = ui.config.totaldistance,
            minarmedtime = ui.config.minarmedtime
          }
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

local function queueStatsWrite(requestRebuild)
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or not FlightStatsApi then
    return false, "msp_runtime_unavailable"
  end

  local flightcount = ui.config.flightcount
  -- The write and the EEPROM commit belong to the pipeline, not to this page: the page can be
  -- left while they are on the wire, and its close releases ui.runtime and the module handles
  -- above. So nothing below may assume the page is still open.
  local ok, err = SavePipeline.start({
    pageId = "setup_controls_stats",
    steps = {
      {
        label = "MSP_SET_FLIGHT_STATS",
        command = FlightStatsApi.writeCommand,
        payload = FlightStatsApi.buildWritePayload({
          flightcount = ui.config.flightcount,
          totalflighttime = ui.config.totalflighttime,
          totaldistance = ui.config.totaldistance,
          minarmedtime = ui.config.minarmedtime
        })
      }
    },
    reboot = false,
    onSaved = function()
      ui.dirty = false
      -- The board stores the four values as sent. The flight record counts from this one, and
      -- the read below that would refresh it only runs while the page is open.
      local session = getSession()
      if session then session.flightcount = flightcount end
    end,
    onDone = function(result)
      ui.saving = false
      if not ui.runtime then return end
      if result.saved then queueStatsRead(true) end
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
  -- A save left running on an earlier visit clears this in its onDone; a new visit starts clear,
  -- as both Beepers pages do.
  ui.saving = false

  ui.config = {
    flightcount = 0,
    totalflighttime = 0,
    totaldistance = 0,
    minarmedtime = 0
  }

  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()

  -- Check api version
  local session = getSession()
  local rawApiVersion = session and session.apiVersion
  local isSupported = rawApiVersion and ApiVersion and ApiVersion.isAtLeast(rawApiVersion, {12, 0, 9})

  if isSupported then
    queueStatsRead(false)
  else
    ui.loading = false
  end
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
  local session = getSession()
  local rawApiVersion = session and session.apiVersion
  local isSupported = rawApiVersion and ApiVersion and ApiVersion.isAtLeast(rawApiVersion, {12, 0, 9})

  return {
    save = isSupported == true,
    reload = isSupported == true,
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
    local msgText = ui.loading and pageText(i18n, "loading", "Loading flight statistics...") or pageText(i18n, "saving", "Saving flight statistics...")
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = titleText,
      message = msgText,
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or "Stats"
  local title = pageText(i18n, "title", displayTitle)
  if type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(title, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, title)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  local session = getSession()
  local rawApiVersion = session and session.apiVersion
  local isSupported = rawApiVersion and ApiVersion and ApiVersion.isAtLeast(rawApiVersion, {12, 0, 9})

  -- 1. Flight Count
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "flightcount", "Flight Count"),
    {
      min = 0,
      max = 1000000000,
      active = function() return isSupported == true end,
      get = function() return ui.config.flightcount end,
      set = function(v)
        ui.config.flightcount = tonumber(v) or 0
        ui.dirty = true
      end
    }
  )

  -- 2. Total Flight Time
  cursorY = cursorY + Controls.appendNumberField(
    children, x, cursorY, w,
    pageText(i18n, "totalflighttime", "Total Flight Time"),
    {
      min = 0,
      max = 1000000000,
      suffix = "s",
      active = function() return isSupported == true end,
      get = function() return ui.config.totalflighttime end,
      set = function(v)
        ui.config.totalflighttime = tonumber(v) or 0
        ui.dirty = true
      end
    }
  )

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
  -- The header's Save stays reachable over the overlay. A second save beside the running one
  -- would send the same write again, with a second EEPROM write.
  if ui.saving then return false end
  local ok, err = queueStatsWrite(ctx and ctx.requestRebuild)
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
    ui.dirty = false
    loadFromSession()
    queueStatsRead(false)
  end
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/controls/stats/help.lua")
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
  FlightStatsApi = nil
  LoadingOverlay = nil
  ConfirmDialog = nil
  ApiVersion = nil
  SavePipeline = nil
  t = nil
end

-- Asked before the page is left (ui/home.lua): true while an edit here is not saved.
function M.hasUnsavedChanges()
  return ui.dirty == true
end

return M
