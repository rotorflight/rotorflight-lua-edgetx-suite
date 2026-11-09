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
local GovernorConfigApi = nil
local SavePipeline = nil
local LoadingOverlay = nil
local t = nil

local FIELD_COUNT = 9
local THROTTLE_STEPS = { "0%", "12%", "25%", "37%", "50%", "62%", "75%", "87%", "100%" }

local ui = {
  loaded = false,
  dirty = false,
  loading = false,
  saving = false,
  progress = 0,
  baseTitle = nil,
  config = {
    curve = { 0, 5, 10, 15, 25, 30, 35, 40, 50 }
  },
  parsedCache = {},
  -- Points the pilot edited since the record was read; only these are written from the screen.
  edited = {},
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
  if not GovernorConfigApi then GovernorConfigApi = loadModule("tasks/msp/api/governor_config.lua") end
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not t then t = Common and Common.pageT("setup_governor") or nil end
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

local function clampPercent(v)
  v = tonumber(v or 0) or 0
  if v < 0 then return 0 end
  if v > 100 then return 100 end
  return math.floor(v + 0.5)
end

local function loadFromSession()
  local session = getSession()
  if not session or type(session.governor_config) ~= "table" then return end
  local cached = session.governor_config
  ui.config.curve = {}
  for i = 1, FIELD_COUNT do
    local raw = cached["gov_bypass_throttle_curve_" .. tostring(i)]
    ui.config.curve[i] = clampPercent((tonumber(raw) or 0) / 2)
  end
  ui.parsedCache = cached
  ui.edited = {}
end

local function queueGovRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not MspRuntime or not GovernorConfigApi or type(MspRuntime.getState) ~= "function" then
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
    command = GovernorConfigApi.command,
    simulatorResponse = GovernorConfigApi.simulatorResponse,
    timeout = 5.0,
    processReply = function(self, buf)
      local parsed = GovernorConfigApi.parse(buf)
      if type(parsed) ~= "table" then return Common.failPageRead(ui) end
      if parsed then
        ui.config.curve = {}
        for i = 1, FIELD_COUNT do
          local raw = parsed["gov_bypass_throttle_curve_" .. tostring(i)]
          ui.config.curve[i] = clampPercent((tonumber(raw) or 0) / 2)
        end
        ui.parsedCache = parsed
        ui.edited = {}

        local session = getSession()
        if session then
          session.governor_config = parsed
          session.governorMode = parsed.gov_mode
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

local function queueGovWrite(requestRebuild)
  if not SavePipeline or not GovernorConfigApi then
    return false, "msp_runtime_unavailable"
  end

  -- Built on a copy, so a save that is refused or fails is still compared with what this visit read.
  local writeData = {}
  for k, v in pairs(ui.parsedCache or {}) do
    writeData[k] = v
  end

  -- The page shows whole percent and the flight controller stores half percent, so a point the
  -- pilot did not edit keeps the byte it was read with; rounding it would change what is stored.
  for i = 1, FIELD_COUNT do
    local key = "gov_bypass_throttle_curve_" .. tostring(i)
    if ui.edited[i] or writeData[key] == nil then
      writeData[key] = clampPercent(ui.config.curve[i]) * 2
    end
  end

  local visit = ui.runtime
  local ok, err = SavePipeline.start({
    pageId = "setup_governor_curves",
    steps = {
      {
        label = "MSP_SET_GOVERNOR_CONFIG",
        command = GovernorConfigApi.writeCommand,
        payload = GovernorConfigApi.buildWritePayload(writeData)
      }
    },
    -- The firmware copies these values into the running governor only at start-up
    -- (governorInit()); MSP_SET_GOVERNOR_CONFIG stores them and nothing more. So a save that
    -- changes one restarts the flight controller, and a save that changes nothing does not.
    reboot = GovernorConfigApi.payloadDiffers(ui.parsedCache, writeData),
    onSaved = function()
      if ui.runtime ~= visit then return end
      ui.dirty = false
    end,
    onDone = function(result)
      if result.status == "done" then
        local session = getSession()
        -- A save whose notice was dismissed reports when this page is entered again, and the
        -- board on the link may be another one by then: its session holds its own configuration.
        if session and result.mcuId ~= nil and session.mcu_id == result.mcuId then
          session.governor_config = writeData
          session.governorMode = writeData.gov_mode
        elseif session then
          local Log = _G.rfsuite and _G.rfsuite.Log
          if Log and type(Log.emit) == "function" then
            pcall(Log.emit, "rfsuite.governor", "curves save done, board on the link not known as the one written: session not updated", "info")
          end
        end
      end
      if ui.runtime ~= visit then return end
      ui.saving = false
      if result.status == "done" then
        ui.parsedCache = writeData
        ui.edited = {}
      else
        ui.dirty = true
      end
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
  if SavePipeline and type(SavePipeline.takeResult) == "function" then
    SavePipeline.takeResult("setup_governor_curves")
  end

  if not ui.runtime then
    ui.runtime = {
      readPending = false,
      requestRebuild = nil,
      lastSessionSignature = nil,
      syncHeaderTitle = nil
    }
  end

  ui.config = {
    curve = { 0, 5, 10, 15, 25, 30, 35, 40, 50 }
  }
  ui.parsedCache = {}
  ui.edited = {}

  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()

  queueGovRead(false)
end

function M.wakeup(ctx)
  ensureDeps()
  ensureLoaded()

  ui.runtime.requestRebuild = ctx and ctx.requestRebuild or nil

  -- A save whose notice was dismissed is held for its page instead of reported (save_pipeline.lua
  -- finish()). While this page is open it claims that result here: one started on this visit would
  -- otherwise keep the Saving overlay, with Save and Reload refused, and one started before the page
  -- was entered again, still running then, would stay unreported until the next Save discards it.
  if SavePipeline and type(SavePipeline.takeResult) == "function" then
    SavePipeline.takeResult("setup_governor_curves")
  end

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
    local titleText = ui.loading and pageText(i18n, "loading_title", "Loading") or pageText(i18n, "saving_title", "Saving")
    local msgText = ui.loading and pageText(i18n, "loading_message", "Reading governor configuration...") or pageText(i18n, "saving_message", "Saving governor configuration...")
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = titleText,
      message = msgText,
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or "Bypass Curve"
  local title = pageText(i18n, "curves", displayTitle)
  if type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(title, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, title)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  -- ── 1. Curve Graph Visualization ──────────────────────────────────────────
  local graphMargin = 20
  local gx = x + graphMargin
  local gw = w - (graphMargin * 2)
  local gy = cursorY + 6
  local gh = 130

  -- Background box
  children[#children + 1] = {
    type = "rectangle",
    x = gx, y = gy,
    w = gw, h = gh,
    color = Palette.border,
    filled = false
  }

  -- Horizontal grid lines (0%, 25%, 50%, 75%, 100%)
  for i = 0, 4 do
    local gridY = gy + math.floor((gh * i) / 4 + 0.5)
    children[#children + 1] = {
      type = "line",
      x = 0, y = 0, w = 0, h = 0,
      pts = { { gx, gridY }, { gx + gw, gridY } },
      color = Palette.border,
      thickness = 1
    }
  end

  -- Vertical grid lines for each of the 9 points
  for i = 1, FIELD_COUNT do
    local gridX = gx + math.floor((gw * (i - 1)) / (FIELD_COUNT - 1) + 0.5)
    children[#children + 1] = {
      type = "line",
      x = 0, y = 0, w = 0, h = 0,
      pts = { { gridX, gy }, { gridX, gy + gh } },
      color = Palette.border,
      thickness = 1
    }
  end

  -- Curve Line and Points
  local prevX, prevY
  for i = 1, FIELD_COUNT do
    local pct = clampPercent(ui.config.curve[i])
    local ptX = gx + math.floor((gw * (i - 1)) / (FIELD_COUNT - 1) + 0.5)
    local ptY = gy + gh - math.floor((gh * pct) / 100 + 0.5)

    if prevX and prevY then
      children[#children + 1] = {
        type = "line",
        x = 0, y = 0, w = 0, h = 0,
        pts = { { prevX, prevY }, { ptX, ptY } },
        color = Palette.text,
        thickness = 2
      }
    end

    -- Marker dot
    children[#children + 1] = {
      type = "rectangle",
      x = ptX - 3, y = ptY - 3,
      w = 7, h = 7,
      color = Palette.text,
      filled = true
    }

    prevX, prevY = ptX, ptY
  end

  cursorY = gy + gh + 10

  -- ── 2. Refresh Button ─────────────────────────────────────────────────────
  local btnW = math.min(260, w - 40)
  local btnH = (lvgl and lvgl.UI_ELEMENT_HEIGHT) or (Controls and Controls.CTRL_H) or 32
  local btnX = x + math.floor((w - btnW) / 2)
  children[#children + 1] = {
    type = "button",
    x = btnX,
    y = cursorY,
    w = btnW,
    text = pageText(i18n, "refresh_graph", "Refresh Graph"),
    press = function()
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  }

  cursorY = cursorY + btnH + 10

  -- ── 3. 9 Throttle Points Inputs ───────────────────────────────────────────
  local gap = 4
  local fieldW = math.floor((gw - (gap * (FIELD_COUNT - 1))) / FIELD_COUNT)
  local labelH = (Controls and Controls.LABEL_H) or (lvgl and lvgl.LCD_SCALE and math.floor(21 * lvgl.LCD_SCALE + 0.5)) or 21
  local editH = (lvgl and lvgl.UI_ELEMENT_HEIGHT) or (Controls and Controls.CTRL_H) or 32

  for i = 1, FIELD_COUNT do
    local cellX = gx + (i - 1) * (fieldW + gap)

    -- Step Label (e.g. 0%, 12%, 25%...)
    children[#children + 1] = {
      type = "label",
      x = cellX,
      y = cursorY,
      w = fieldW,
      text = THROTTLE_STEPS[i] or ("P" .. tostring(i)),
      color = Palette.text,
      font = SMLSIZE,
      align = CENTER
    }

    -- Number Edit
    local pointIndex = i
    children[#children + 1] = {
      type = "numberEdit",
      x = cellX,
      y = cursorY + labelH + 6,
      w = fieldW,
      min = 0,
      max = 100,
      active = function() return true end,
      get = function()
        return ui.config.curve[pointIndex] or 0
      end,
      set = function(val)
        ui.config.curve[pointIndex] = clampPercent(val)
        ui.edited[pointIndex] = true
        ui.dirty = true
      end,
      display = function(val)
        return tostring(clampPercent(val)) .. "%"
      end
    }
  end

  cursorY = cursorY + labelH + 6 + editH + 14

  if ui.dirty then
    children[#children + 1] = {
      type = "label",
      x = x + 16, y = cursorY,
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
  if ui.saving then return false end
  if not M.canSave() then return false, "loaded_data_missing" end
  local ok, err = queueGovWrite(ctx and ctx.requestRebuild)
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
  if ui.saving then return true end
  local session = getSession()
  if session then
    ui.dirty = false
    loadFromSession()
    queueGovRead(false)
  end
  return true
end

function M.onHelp(ctx)
  local help = loadModule("app/pages/setup/governor/curves/help.lua")
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
  ui.saving = false
  Controls = nil
  Common = nil
  MspRuntime = nil
  GovernorConfigApi = nil
  SavePipeline = nil
  LoadingOverlay = nil
  t = nil
end

-- Asked before the page is left (ui/home.lua): true while an edit here is not saved.
function M.hasUnsavedChanges()
  return ui.dirty == true
end

return M
