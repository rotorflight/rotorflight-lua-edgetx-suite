local M = {}

local function loadModule(path)
  local fullPath = _G.rfsuite.paths.core .. "/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local Controls = nil
local Common = nil
local MspRuntime = nil
local MixerConfigApi = nil
local LoadingOverlay = nil
local LiveOverride = nil
local SavePipeline = nil
local t = nil

local MSP_SET_MIXER_OVERRIDE = 191
local MIXER_OVERRIDE_OFF = 2501
local MIXER_OVERRIDE_ON = 0
-- Roll, pitch, yaw and collective: the stabilized inputs the four trims act on.
local OVERRIDE_INPUTS = { 1, 2, 3, 4 }
-- A changed trim is sent at most every 200 ms while the override is on.
local LIVE_INTERVAL = 0.20

local ui = {
  loaded = false,
  dirty = false,
  loading = false,
  progress = 0,
  baseTitle = nil,
  config = {
    tail_rotor_mode = 0,
    swash_trim_0 = 0,
    swash_trim_1 = 0,
    swash_trim_2 = 0,
    tail_center_trim = 0
  },
  apiData = {},
  -- The override, from app/pages/lib/live_override.lua, created the first time * is pressed in a
  -- visit: it holds what the board has as far as this page knows (the read, or the last save that
  -- reached EEPROM) and what went out live. A visit that never presses * never loads it.
  override = nil,
  runtime = {
    readPending = false,
    requestRebuild = nil
  }
}

local function round(x)
  if x >= 0 then return math.floor(x + 0.5) end
  return math.ceil(x - 0.5)
end

local function getSession()
  local root = _G and _G.rfsuite
  return root and root.session or nil
end

local function ensureDeps()
  if not Common then Common = loadModule("app/pages/settings/common.lua") end
  if not Controls then Controls = loadModule("ui/controls.lua") end
  if not MspRuntime then MspRuntime = loadModule("tasks/msp/runtime.lua") end
  if not MixerConfigApi then MixerConfigApi = loadModule("tasks/msp/api/mixer_config.lua") end
  if not LoadingOverlay then LoadingOverlay = loadModule("ui/loading_overlay.lua") end
  if not t then t = Common and Common.pageT("setup_mixer") or nil end

  if type(ui.runtime) ~= "table" then
    ui.runtime = {
      readPending = false,
      requestRebuild = nil
    }
  end
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

local function getQueue()
  if not MspRuntime or type(MspRuntime.getState) ~= "function" then return nil end
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then return nil end
  return queue
end

local function getRcConfig(session)
  if type(session) ~= "table" then return nil end
  if type(session.setup_mixer_trims) ~= "table" then
    session.setup_mixer_trims = {}
  end
  return session.setup_mixer_trims
end

local function loadFromSession()
  local session = getSession()
  local rcConfig = getRcConfig(session)
  if not rcConfig then return end
  ui.config.tail_rotor_mode = rcConfig.tail_rotor_mode or 0
  ui.config.swash_trim_0 = rcConfig.swash_trim_0 or 0
  ui.config.swash_trim_1 = rcConfig.swash_trim_1 or 0
  ui.config.swash_trim_2 = rcConfig.swash_trim_2 or 0
  ui.config.tail_center_trim = rcConfig.tail_center_trim or 0

  if type(rcConfig.apiData) == "table" then
    ui.apiData = rcConfig.apiData
  end
end

local function saveToSession()
  local session = getSession()
  local rcConfig = getRcConfig(session)
  if not rcConfig then return end
  rcConfig.tail_rotor_mode = ui.config.tail_rotor_mode
  rcConfig.swash_trim_0 = ui.config.swash_trim_0
  rcConfig.swash_trim_1 = ui.config.swash_trim_1
  rcConfig.swash_trim_2 = ui.config.swash_trim_2
  rcConfig.tail_center_trim = ui.config.tail_center_trim
  rcConfig.apiData = ui.apiData
end

-- The values this page edits, from a record or from the screen; the live loop sends them when they
-- change.
local function trimValues(from)
  from = from or ui.config
  return {
    swash_trim_0 = from.swash_trim_0,
    swash_trim_1 = from.swash_trim_1,
    swash_trim_2 = from.swash_trim_2,
    tail_center_trim = from.tail_center_trim
  }
end

-- The record a write carries: what was read, with the trims on screen. The read record itself stays
-- as read, so leaving without Save can still put it back.
local function recordWith(values)
  local record = {}
  for k, v in pairs(ui.apiData.MIXER_CONFIG) do record[k] = v end
  for k, v in pairs(values) do record[k] = v end
  return record
end

-- The page is kept between visits and loadFromSession() puts the last record read back into
-- ui.apiData before this visit's read is even queued, so "a MIXER_CONFIG is there" says nothing
-- about this visit. ui.runtime is dropped by resetPageState() on close, which makes this flag
-- the visit's own: set only by a read that parsed, cleared when a read starts.
-- The live write while the override is on is held back by it too: it sends the same whole record.
function M.canSave()
  return ui.runtime ~= nil and ui.runtime.readComplete == true and not ui.runtime.readPending
end

-- One live write. The acknowledgement leaves the page dirty: the value is in the board's RAM only,
-- and it stays a trial until Save writes it to EEPROM.
local function sendLive(values)
  local queue = getQueue()
  if not queue or not MixerConfigApi then return false end
  if type(queue.isProcessed) == "function" and not queue:isProcessed() then return false end
  if not M.canSave() or not ui.apiData.MIXER_CONFIG then return false end
  local override = ui.override
  queue:add({
    command = MixerConfigApi.writeCommand,
    payload = MixerConfigApi.buildWritePayload(recordWith(values)),
    isWrite = true,
    processReply = function() end,
    errorHandler = function(_, reason) if override then override:writeFailed(reason) end end
  })
  return true
end

--- Leaving without Save, or Reload: a trim sent live under the override goes back to the board's
--- record, on screen and in the session copy. The payload is built here, not in a reply, because
--- onClose drops this page's modules right after.
local function rollbackLiveChanges()
  if not ui.override or not MixerConfigApi then return false end
  local queue = getQueue()
  if not queue then return false end
  local orig = ui.override:rollback(function(record)
    queue:add({
      command = MixerConfigApi.writeCommand,
      payload = MixerConfigApi.buildWritePayload(record),
      isWrite = true,
      processReply = function() end
    })
    return true
  end)
  if not orig then return false end
  ui.apiData.MIXER_CONFIG = LiveOverride.copyFlat(orig.record)
  for k, v in pairs(orig.values) do ui.config[k] = v end
  saveToSession()
  return true
end

local function queueTrimsRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  local queue = getQueue()
  if not queue or not MixerConfigApi then
    return false, "msp_runtime_unavailable"
  end

  ui.runtime.readPending = true
  if not isAutoReload then
    ui.loading = true
    ui.progress = 0
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  queue:add({
    command = MixerConfigApi.command,
    simulatorResponse = MixerConfigApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = MixerConfigApi.parse(buf)
      if type(parsed) ~= "table" then return Common.failPageRead(ui) end
      if parsed then
        ui.apiData.MIXER_CONFIG = parsed
        ui.config.tail_rotor_mode = parsed.tail_rotor_mode
        ui.config.swash_trim_0 = parsed.swash_trim_0
        ui.config.swash_trim_1 = parsed.swash_trim_1
        ui.config.swash_trim_2 = parsed.swash_trim_2
        ui.config.tail_center_trim = parsed.tail_center_trim
      end

      saveToSession()

      -- Taken here rather than at each field: nothing changes the record between the parse and
      -- this line, because the live write and Save wait for canSave(), false while readPending.
      if ui.override then ui.override:snapshot(parsed, trimValues()) end

      ui.runtime.readPending = false
      ui.runtime.readComplete = true
      ui.loading = false
      ui.dirty = false
      ui.progress = 100
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end,
    errorHandler = function()
      ui.runtime.readPending = false
      ui.loading = false
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })

  return true, nil
end

local function queueTrimsWrite()
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or not MixerConfigApi then
    return false, "msp_runtime_unavailable"
  end

  if not M.canSave() or not ui.apiData.MIXER_CONFIG then
    return false, "loaded_data_missing"
  end

  local values = trimValues()
  local writeConfig = recordWith(values)
  local override = ui.override

  local ok, reason = SavePipeline.start({
    pageId = "setup_mixer_trims",
    steps = {
      {
        label = "MSP_SET_MIXER_CONFIG",
        command = MixerConfigApi.writeCommand,
        payload = MixerConfigApi.buildWritePayload(writeConfig)
      }
    },
    reboot = false,
    -- The Tail page shows the same centre trim from its own copy.
    invalidateSessionKeys = { "setup_mixer_trims", "setup_mixer_tail" },
    onSaved = function()
      ui.dirty = false
      -- Stored: from now on this is what leaving without Save puts back.
      if override then override:stored(writeConfig, values) end
    end,
    onDone = function(result)
      if result.status == "done" then
        ui.apiData.MIXER_CONFIG = writeConfig
      else
        ui.dirty = true
      end
      if ui.runtime and type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })
  -- The save sends what is on screen, so the live loop has nothing to send until it changes.
  if ok and override then override:markSent(values) end
  return ok, reason
end

local function buildSessionSignature()
  return "1"
end

local function getBaseTitle()
  return pageText(nil, "trims", "Servo Trims")
end

local function ensureLoaded()
  if ui.loaded then return end
  -- A save whose overlay was dismissed finished without a screen; claim its outcome now.
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if SavePipeline and type(SavePipeline.takeResult) == "function" then
    SavePipeline.takeResult("setup_mixer_trims")
  end
  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()
  ui.baseTitle = getBaseTitle()
  queueTrimsRead(false)
end

local function overrideActive()
  return ui.override ~= nil and ui.override.active == true
end

-- A save is still writing: a step or the EEPROM commit is ahead. The pipeline queues each step from
-- the previous reply, so a rollback queued now would land between them and EEPROM could keep the
-- old value while the save reports the new one. A save that needs no restart lets the page be left
-- meanwhile (SavePipeline.blocksNavigation()). Asked of the pipeline rather than kept in a flag:
-- a dismissed save's outcome is delivered late, and a flag cleared there could stay set.
local function saveWriting()
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or type(SavePipeline.getProgress) ~= "function" then return false end
  local progress = SavePipeline.getProgress()
  local phases = SavePipeline.PHASE or {}
  return type(progress) == "table"
    and (progress.phase == (phases.WRITE or "write") or progress.phase == (phases.COMMIT or "commit"))
end

local function ensureOverride()
  if ui.override then return ui.override end
  local read = ui.apiData.MIXER_CONFIG
  if type(read) ~= "table" then return nil end
  if not LiveOverride then LiveOverride = loadModule("app/pages/lib/live_override.lua") end
  if not LiveOverride then return nil end
  ui.override = LiveOverride.new({
    command = MSP_SET_MIXER_OVERRIDE,
    inputs = OVERRIDE_INPUTS,
    on = MIXER_OVERRIDE_ON,
    off = MIXER_OVERRIDE_OFF,
    cadence = "periodic",
    interval = LIVE_INTERVAL
  })
  -- The record read stays as read (writes go out as copies), so it is what the board holds, even
  -- when trims were edited on screen before *.
  ui.override:snapshot(read, trimValues(read))
  return ui.override
end

function M.wakeup(ctx)
  ensureDeps()
  ensureLoaded()
  if type(ctx) == "table" and type(ctx.requestRebuild) == "function" then
    ui.runtime.requestRebuild = ctx.requestRebuild
  end

  local signature = buildSessionSignature()
  if signature ~= ui.runtime.lastSessionSignature then
    ui.runtime.lastSessionSignature = signature
    queueTrimsRead(false)
  end

  if overrideActive() and ui.dirty then
    ui.override:tick(trimValues(), sendLive)
  end
end

function M.getHeaderActions()
  return {
    save = true,
    reload = true,
    -- Switching the override on waits for this visit's read, as Save does (M.canSave above):
    -- until then the live write sends nothing. Switching it off is always offered.
    star = overrideActive() or M.canSave(),
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

  if ui.loading then
    LoadingOverlay.append(children, {
      x = x, y = y, w = w, h = h,
      title = pageText(i18n, "loading_title", "Loading"),
      message = pageText(i18n, "loading_trims", "Reading trims configuration..."),
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or getBaseTitle()
  if overrideActive() then
    displayTitle = displayTitle .. " *"
  end

  if type(ui.runtime) == "table" and type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(displayTitle, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, displayTitle)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  cursorY = cursorY + 10

  -- 1) Roll Trim
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "roll_trim", "Roll trim"),
    {
      min = -1000,
      max = 1000,
      step = 1,
      get = function() return ui.config.swash_trim_0 or 0 end,
      set = function(val)
        if ui.config.swash_trim_0 ~= val then
          ui.config.swash_trim_0 = val
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f%%", (tonumber(v) or 0) / 10) end,
      suffix = "%",
      helpText = pageText(i18n, "help_roll_trim",
        "Swashplate roll trim; use it only when the linkages cannot be adjusted.")
    }
  )

  -- 2) Pitch Trim
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "pitch_trim", "Pitch trim"),
    {
      min = -1000,
      max = 1000,
      step = 1,
      get = function() return ui.config.swash_trim_1 or 0 end,
      set = function(val)
        if ui.config.swash_trim_1 ~= val then
          ui.config.swash_trim_1 = val
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f%%", (tonumber(v) or 0) / 10) end,
      suffix = "%",
      helpText = pageText(i18n, "help_pitch_trim",
        "Swashplate pitch trim; use it only when the linkages cannot be adjusted.")
    }
  )

  -- 3) Collective Trim
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "collective_trim", "Col. trim"),
    {
      min = -1000,
      max = 1000,
      step = 1,
      get = function() return ui.config.swash_trim_2 or 0 end,
      set = function(val)
        if ui.config.swash_trim_2 ~= val then
          ui.config.swash_trim_2 = val
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f%%", (tonumber(v) or 0) / 10) end,
      suffix = "%",
      helpText = pageText(i18n, "help_collective_trim",
        "Swashplate collective trim; use it only when the linkages cannot be adjusted.")
    }
  )

  -- 4) Yaw Trim (only shown if tail_rotor_mode == 0). The centre trim of a variable-pitch tail, in
  -- 0.1 degree as the Tail page and the Configurator show it: raw * 24 / 100.
  if ui.config.tail_rotor_mode == 0 then
    cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
      pageText(i18n, "yaw_trim", "Yaw. trim"),
      {
        min = -250,
        max = 250,
        step = 1,
        get = function() return round((tonumber(ui.config.tail_center_trim) or 0) * 24 / 100) end,
        set = function(val)
          local raw = round((tonumber(val) or 0) * 100 / 24)
          if ui.config.tail_center_trim ~= raw then
            ui.config.tail_center_trim = raw
            ui.dirty = true
          end
        end,
        display = function(v) return string.format("%.1f", (tonumber(v) or 0) / 10) .. "°" end,
        suffix = "°",
        helpText = pageText(i18n, "help_yaw_trim",
          "Tail blade pitch at zero yaw command; the same value as Yaw Center Trim on the Tail page.")
      }
    )
  end
end

function M.onSave(ctx)
  local ok, err = queueTrimsWrite()
  if not ok then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        title = pageText(ctx and ctx.i18n, "save_error_title", "Error"),
        message = tostring(err or "MSP write failed")
      })
    end
    return false
  end

  -- Nothing is announced here: the write and the EEPROM commit are still ahead, and the save
  -- pipeline reports the outcome once it knows it.
  return true
end

function M.onReload(ctx)
  local session = getSession()
  if session then
    -- Before the read, so the read is queued behind the rollback and shows the board's value.
    if ui.dirty and not saveWriting() then rollbackLiveChanges() end
    loadFromSession()
    ui.dirty = false
    queueTrimsRead(false)
  end
  return true
end

function M.onStar(ctx)
  if not overrideActive() and not M.canSave() then return false end
  if not ensureOverride() then return false end

  local i18n = ctx and ctx.i18n
  local title
  local message

  if not overrideActive() then
    title = pageText(i18n, "enable_mixer_override", "Enable swash override")
    message = pageText(i18n, "enable_mixer_message", "Enable swash override so the flight controller centers the servos while adjusting trims. \n\nLive changes from this page are sent to the flight controller.")
  else
    title = pageText(i18n, "disable_mixer_override", "Disable swash override")
    message = pageText(i18n, "disable_mixer_message", "Disable swash override and return mixer control to the flight controller.")
  end

  ui.override:confirm({
    title = title,
    message = message,
    uncertainText = pageText(i18n, "override_armed_unknown",
      "The flight controller does not report whether it is armed. Make sure the rotors cannot spin."),
    onConfirm = function()
      local override = ui.override
      if not override then return end
      if not override.active then
        -- Checked again: Yes comes later than the press, and the page may have closed since.
        if not M.canSave() then return end
        override:enable(getQueue())
      else
        override:disable(getQueue())
      end
      if ui.runtime and type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })

  return true
end


function M.onClose()
  -- An unsaved trim sent live is taken back first, while the override still holds the servos.
  -- Queued ahead of the override writes on purpose: should the close end before every write is
  -- out, a lost override write leaves a board that refuses to arm, a lost rollback a trial trim
  -- the model would fly with. A save still writing is not undone here (saveWriting above).
  if ui.dirty and not saveWriting() then rollbackLiveChanges() end
  if overrideActive() then
    ui.override:disable(getQueue())
  end
  ui.override = nil
  if Common and type(Common.resetPageState) == "function" then
    Common.resetPageState(ui, {
      resetLoaded = true,
      resetDirty = true
    })
  end
  Controls = nil
  Common = nil
  MspRuntime = nil
  MixerConfigApi = nil
  LoadingOverlay = nil
  LiveOverride = nil
  SavePipeline = nil
  t = nil
end

return M
