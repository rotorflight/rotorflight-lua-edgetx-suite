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
local MixerInputPitchApi = nil
local MixerInputRollApi = nil
local MixerInputCollectiveApi = nil
local LoadingOverlay = nil
local LiveOverride = nil
local SavePipeline = nil
local t = nil

-- Reached through the global lib/log.lua publishes; absent logger, absent lines.
local function logf(level, fmt, ...)
  local Log = type(_G) == "table" and _G.rfsuite and _G.rfsuite.Log
  if type(Log) == "table" and type(Log.emitf) == "function" then
    pcall(Log.emitf, "rfsuite.geometry", level, fmt, ...)
  end
end

local MSP_SET_MIXER_OVERRIDE = 191
local MIXER_OVERRIDE_OFF = 2501
-- Passthrough: the sticks still move the swashplate through the mixer, so the geometry can be
-- watched while it is set. The firmware has it from API 12.0.8; the suite connects from 12.09.
local MIXER_OVERRIDE_PASSTHROUGH = 2502
-- Roll, pitch, yaw and collective.
local OVERRIDE_INPUTS = { 1, 2, 3, 4 }
-- A changed value is sent at most every 200 ms while setup mode is on.
local LIVE_INTERVAL = 0.20

local function u16_to_s16(u)
  if u >= 0x8000 then
    return u - 0x10000
  else
    return u
  end
end

local function s16_to_u16(s)
  if s < 0 then return s + 0x10000 end
  return s
end

local function rateToDir(u16rate)
  return (u16_to_s16(u16rate) < 0) and 0 or 1
end

local function dirSign(d)
  return (d == 0) and -1 or 1
end

local ui = {
  loaded = false,
  dirty = false,
  loading = false,
  progress = 0,
  baseTitle = nil,
  config = {
    cyclic_calibration = 400,
    collective_calibration = 400,
    geo_correction = 0,
    cyclic_pitch_limit = 20,
    collective_pitch_limit = 20,
    swash_pitch_limit = 200,
    swash_phase = 0,
    collective_tilt_correction_pos = 0,
    collective_tilt_correction_neg = 0,
    ail_direction = 1,
    ele_direction = 1,
    col_direction = 1
  },
  -- The four records as the board holds them: this visit's read, or the last save that reached
  -- EEPROM. A write -- live or saved -- goes out as fresh copies (recordsFor below), so these stay
  -- what leaving without Save puts back.
  apiData = {},
  -- The override, from app/pages/lib/live_override.lua, created the first time * is pressed in a
  -- visit: it holds what the board has as far as this page knows and what went out live. A visit
  -- that never presses * never loads it.
  override = nil,
  runtime = {
    readPending = false,
    requestRebuild = nil
  }
}

-- The four records, in the order the page writes them.
local RECORDS = { "MIXER_CONFIG", "GET_MIXER_INPUT_PITCH", "GET_MIXER_INPUT_ROLL", "GET_MIXER_INPUT_COLLECTIVE" }

-- Every record here is a flat table of numbers, so a flat copy is a full copy.
local function copyFlat(src)
  if type(src) ~= "table" then return nil end
  local out = {}
  for k, v in pairs(src) do out[k] = v end
  return out
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
  if not MixerInputPitchApi then MixerInputPitchApi = loadModule("tasks/msp/api/get_mixer_input_pitch.lua") end
  if not MixerInputRollApi then MixerInputRollApi = loadModule("tasks/msp/api/get_mixer_input_roll.lua") end
  if not MixerInputCollectiveApi then MixerInputCollectiveApi = loadModule("tasks/msp/api/get_mixer_input_collective.lua") end
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

local function getRcConfig(session)
  if type(session) ~= "table" then return nil end
  if type(session.setup_mixer_swashgeometry) ~= "table" then
    session.setup_mixer_swashgeometry = {}
  end
  return session.setup_mixer_swashgeometry
end

local function loadFromSession()
  local session = getSession()
  local rcConfig = getRcConfig(session)
  if not rcConfig then return end
  ui.config.cyclic_calibration = rcConfig.cyclic_calibration or 400
  ui.config.collective_calibration = rcConfig.collective_calibration or 400
  ui.config.geo_correction = rcConfig.geo_correction or 0
  ui.config.cyclic_pitch_limit = rcConfig.cyclic_pitch_limit or 20
  ui.config.collective_pitch_limit = rcConfig.collective_pitch_limit or 20
  ui.config.swash_pitch_limit = rcConfig.swash_pitch_limit or 200
  ui.config.swash_phase = rcConfig.swash_phase or 0
  ui.config.collective_tilt_correction_pos = rcConfig.collective_tilt_correction_pos or 0
  ui.config.collective_tilt_correction_neg = rcConfig.collective_tilt_correction_neg or 0
  ui.config.ail_direction = rcConfig.ail_direction or 1
  ui.config.ele_direction = rcConfig.ele_direction or 1
  ui.config.col_direction = rcConfig.col_direction or 1

  if type(rcConfig.apiData) == "table" then
    ui.apiData = rcConfig.apiData
  end
end

local function saveToSession()
  local session = getSession()
  local rcConfig = getRcConfig(session)
  if not rcConfig then return end
  rcConfig.cyclic_calibration = ui.config.cyclic_calibration
  rcConfig.collective_calibration = ui.config.collective_calibration
  rcConfig.geo_correction = ui.config.geo_correction
  rcConfig.cyclic_pitch_limit = ui.config.cyclic_pitch_limit
  rcConfig.collective_pitch_limit = ui.config.collective_pitch_limit
  rcConfig.swash_pitch_limit = ui.config.swash_pitch_limit
  rcConfig.swash_phase = ui.config.swash_phase
  rcConfig.collective_tilt_correction_pos = ui.config.collective_tilt_correction_pos
  rcConfig.collective_tilt_correction_neg = ui.config.collective_tilt_correction_neg
  rcConfig.ail_direction = ui.config.ail_direction
  rcConfig.ele_direction = ui.config.ele_direction
  rcConfig.col_direction = ui.config.col_direction
  rcConfig.apiData = ui.apiData
end

local function getQueue()
  if not MspRuntime or type(MspRuntime.getState) ~= "function" then return nil end
  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then return nil end
  return queue
end

local function haveRecords(records)
  for i = 1, #RECORDS do
    if type(records[RECORDS[i]]) ~= "table" then return false end
  end
  return true
end

-- The values on screen that the board's records stand for, derived the way the page shows them.
local function valuesFrom(records)
  local cfg = records.MIXER_CONFIG
  local pitch = records.GET_MIXER_INPUT_PITCH
  local roll = records.GET_MIXER_INPUT_ROLL
  local coll = records.GET_MIXER_INPUT_COLLECTIVE
  return {
    geo_correction = cfg.swash_geo_correction * 2,
    swash_pitch_limit = math.floor(cfg.swash_pitch_limit * 12 / 100 + 0.5),
    swash_phase = cfg.swash_phase,
    collective_tilt_correction_pos = cfg.collective_tilt_correction_pos,
    collective_tilt_correction_neg = cfg.collective_tilt_correction_neg,
    ele_direction = rateToDir(pitch.rate_stabilized_pitch),
    cyclic_calibration = math.abs(u16_to_s16(pitch.rate_stabilized_pitch)),
    cyclic_pitch_limit = math.floor(math.abs(u16_to_s16(pitch.max_stabilized_pitch)) * 12 / 100 + 0.5),
    ail_direction = rateToDir(roll.rate_stabilized_roll),
    col_direction = rateToDir(coll.rate_stabilized_collective),
    collective_calibration = math.abs(u16_to_s16(coll.rate_stabilized_collective)),
    collective_pitch_limit = math.floor(math.abs(u16_to_s16(coll.max_stabilized_collective)) * 12 / 100 + 0.5)
  }
end

-- The records a write carries: the board's records, as fresh tables, with the fields of the values
-- that differ from what those records stand for. A field whose value is unchanged keeps its raw
-- record value: the screen holds the limits in 0.1 degree and the geo correction in steps of two,
-- so writing every field back from the screen would move raw values nobody changed -- and putting
-- the original screen values back would not put those raw values back.
local function recordsFor(values)
  if not haveRecords(ui.apiData) then return nil end
  local board = valuesFrom(ui.apiData)
  local function changed(...)
    for i = 1, select("#", ...) do
      local k = select(i, ...)
      if values[k] ~= board[k] then return true end
    end
    return false
  end
  local pConfig = copyFlat(ui.apiData.MIXER_CONFIG)
  local pPitch = copyFlat(ui.apiData.GET_MIXER_INPUT_PITCH)
  local pRoll = copyFlat(ui.apiData.GET_MIXER_INPUT_ROLL)
  local pColl = copyFlat(ui.apiData.GET_MIXER_INPUT_COLLECTIVE)

  local cyclicRate = math.floor(values.cyclic_calibration + 0.5)
  local collRate = math.floor(values.collective_calibration + 0.5)

  local cyclicMax_raw = math.floor((values.cyclic_pitch_limit or 0) * 100 / 12 + 0.5)
  local collMax_raw   = math.floor((values.collective_pitch_limit or 0) * 100 / 12 + 0.5)

  -- MIXER_CONFIG
  if changed("geo_correction") then
    pConfig.swash_geo_correction = math.floor((values.geo_correction or 0) / 2 + 0.5)
  end
  if changed("swash_pitch_limit") then
    pConfig.swash_pitch_limit = math.floor((values.swash_pitch_limit or 0) * 100 / 12 + 0.5)
  end
  if changed("swash_phase") then pConfig.swash_phase = math.floor(values.swash_phase or 0) end
  if changed("collective_tilt_correction_pos") then
    pConfig.collective_tilt_correction_pos = math.floor(values.collective_tilt_correction_pos or 0)
  end
  if changed("collective_tilt_correction_neg") then
    pConfig.collective_tilt_correction_neg = math.floor(values.collective_tilt_correction_neg or 0)
  end

  -- PITCH and ROLL share the cyclic gain and limit; each has its own direction.
  if changed("cyclic_calibration", "ele_direction") then
    pPitch.rate_stabilized_pitch = s16_to_u16(cyclicRate * dirSign(values.ele_direction))
  end
  if changed("cyclic_calibration", "ail_direction") then
    pRoll.rate_stabilized_roll = s16_to_u16(cyclicRate * dirSign(values.ail_direction))
  end
  if changed("cyclic_pitch_limit") then
    pPitch.max_stabilized_pitch = s16_to_u16(math.abs(cyclicMax_raw))
    pPitch.min_stabilized_pitch = s16_to_u16(-math.abs(cyclicMax_raw))
    pRoll.max_stabilized_roll = s16_to_u16(math.abs(cyclicMax_raw))
    pRoll.min_stabilized_roll = s16_to_u16(-math.abs(cyclicMax_raw))
  end

  -- COLLECTIVE
  if changed("collective_calibration", "col_direction") then
    pColl.rate_stabilized_collective = s16_to_u16(collRate * dirSign(values.col_direction))
  end
  if changed("collective_pitch_limit") then
    pColl.max_stabilized_collective = s16_to_u16(math.abs(collMax_raw))
    pColl.min_stabilized_collective = s16_to_u16(-math.abs(collMax_raw))
  end

  return {
    MIXER_CONFIG = pConfig,
    GET_MIXER_INPUT_PITCH = pPitch,
    GET_MIXER_INPUT_ROLL = pRoll,
    GET_MIXER_INPUT_COLLECTIVE = pColl
  }
end

local function writeApis()
  return { MixerConfigApi, MixerInputPitchApi, MixerInputRollApi, MixerInputCollectiveApi }
end

-- All four queued at once rather than each from the reply before it: a rollback or a read queued
-- meanwhile would otherwise land between them, and the rest would reach the board after it.
local function queueRecords(queue, records, errorHandler)
  local apis = writeApis()
  for i = 1, #RECORDS do
    queue:add({
      command = apis[i].writeCommand,
      payload = apis[i].buildWritePayload(records[RECORDS[i]]),
      isWrite = true,
      processReply = function() end,
      errorHandler = errorHandler
    })
  end
end

-- The page is kept between visits and loadFromSession() puts the last records read back into
-- ui.apiData before this visit's read is even queued, so "the records are there" says nothing
-- about this visit. ui.runtime is dropped by resetPageState() on close, which makes this flag
-- the visit's own: set only when every read of the chain parsed, cleared when a read starts.
-- The live write in setup mode is held back by it too: it sends the same whole records.
function M.canSave()
  return ui.runtime ~= nil and ui.runtime.readComplete == true and not ui.runtime.readPending
end

-- One live write. The acknowledgements leave the page dirty: the values are in the board's RAM
-- only, and they stay a trial until Save writes them to EEPROM.
local function sendLive(values)
  local queue = getQueue()
  if not queue or not MixerConfigApi then return false end
  if type(queue.isProcessed) == "function" and not queue:isProcessed() then return false end
  if not M.canSave() then return false end
  local records = recordsFor(values)
  if not records then return false end
  local override = ui.override
  queueRecords(queue, records, function(_, reason) if override then override:writeFailed(reason) end end)
  return true
end

--- Leaving without Save, or Reload: geometry sent live in setup mode goes back to the board's
--- records, on the board, on screen and in the session copy. The payloads are built here, not in
--- a reply, because onClose drops this page's modules right after.
local function rollbackLiveChanges()
  if not ui.override or not MixerConfigApi then return false end
  local queue = getQueue()
  if not queue then return false end
  local orig = ui.override:rollback(function(records)
    queueRecords(queue, records)
    return true
  end)
  if not orig then return false end
  for i = 1, #RECORDS do
    ui.apiData[RECORDS[i]] = copyFlat(orig.record[RECORDS[i]])
  end
  for k, v in pairs(orig.values) do ui.config[k] = v end
  saveToSession()
  return true
end

local function queueGeometryRead(isAutoReload)
  if ui.runtime.readPending then return false, "read_pending" end
  ui.runtime.readComplete = false
  if not MspRuntime or not MixerConfigApi or not MixerInputPitchApi or not MixerInputRollApi or not MixerInputCollectiveApi or type(MspRuntime.getState) ~= "function" then
    return false, "msp_runtime_unavailable"
  end

  local mspState = MspRuntime.getState()
  local queue = mspState and mspState.queue
  if not queue or type(queue.add) ~= "function" then
    return false, "msp_queue_unavailable"
  end

  ui.runtime.readPending = true
  if not isAutoReload then
    ui.loading = true
    ui.progress = 0
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  local function readFailed()
    logf("warn", "read of the swashplate geometry failed")
    ui.runtime.readPending = false
    ui.loading = false
    if type(ui.runtime.requestRebuild) == "function" then
      ui.runtime.requestRebuild()
    end
  end

  -- Step 1: Read MIXER_CONFIG
  queue:add({
    command = MixerConfigApi.command,
    simulatorResponse = MixerConfigApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = MixerConfigApi.parse(buf)
      if type(parsed) ~= "table" then return Common.failPageRead(ui) end
      ui.apiData.MIXER_CONFIG = parsed

      ui.progress = 25
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end

      -- Step 2: Read GET_MIXER_INPUT_PITCH
      queue:add({
        command = MixerInputPitchApi.command,
        payload = { 2 },
        simulatorResponse = MixerInputPitchApi.simulatorResponse,
        processReply = function(self, buf)
          local parsed = MixerInputPitchApi.parse(buf)
          if type(parsed) ~= "table" then return Common.failPageRead(ui) end
          ui.apiData.GET_MIXER_INPUT_PITCH = parsed

          ui.progress = 50
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end

          -- Step 3: Read GET_MIXER_INPUT_ROLL
          queue:add({
            command = MixerInputRollApi.command,
            payload = { 1 },
            simulatorResponse = MixerInputRollApi.simulatorResponse,
            processReply = function(self, buf)
              local parsed = MixerInputRollApi.parse(buf)
              if type(parsed) ~= "table" then return Common.failPageRead(ui) end
              ui.apiData.GET_MIXER_INPUT_ROLL = parsed

              ui.progress = 75
              if type(ui.runtime.requestRebuild) == "function" then
                ui.runtime.requestRebuild()
              end

              -- Step 4: Read GET_MIXER_INPUT_COLLECTIVE
              queue:add({
                command = MixerInputCollectiveApi.command,
                payload = { 4 },
                simulatorResponse = MixerInputCollectiveApi.simulatorResponse,
                processReply = function(self, buf)
                  local parsed = MixerInputCollectiveApi.parse(buf)
                  if type(parsed) ~= "table" then return Common.failPageRead(ui) end
                  ui.apiData.GET_MIXER_INPUT_COLLECTIVE = parsed

                  -- The screen shows what the four records stand for, all four read.
                  local values = valuesFrom(ui.apiData)
                  for k, v in pairs(values) do ui.config[k] = v end
                  saveToSession()

                  -- Taken here rather than at each parse: nothing changes the four records
                  -- between their parse and this line, because the live write and Save wait for
                  -- canSave(), false while readPending.
                  if ui.override then
                    local records = {}
                    for i = 1, #RECORDS do records[RECORDS[i]] = copyFlat(ui.apiData[RECORDS[i]]) end
                    ui.override:snapshot(records, values)
                  end

                  ui.runtime.readPending = false
                  ui.runtime.readComplete = true
                  ui.loading = false
                  ui.dirty = false
                  ui.progress = 100
                  if type(ui.runtime.requestRebuild) == "function" then
                    ui.runtime.requestRebuild()
                  end
                end,
                errorHandler = readFailed
              })
            end,
            errorHandler = readFailed
          })
        end,
        errorHandler = readFailed
      })
    end,
    errorHandler = readFailed
  })

  return true, nil
end

--- `hadEdit` is the unsaved flag before Save cleared it: a save that does not reach EEPROM puts it
--- back, so leaving then still takes back what the save's writes left in the board's RAM.
local function queueGeometryWrite(hadEdit)
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or not MixerConfigApi or not MixerInputPitchApi or not MixerInputRollApi or not MixerInputCollectiveApi then
    return false, "msp_runtime_unavailable"
  end

  local values = copyFlat(ui.config)
  local records = M.canSave() and recordsFor(values) or nil
  if not records then
    return false, "loaded_data_missing"
  end

  -- The visit this save belongs to. The page's close sets ui.runtime to nil and its next visit
  -- creates a new table, so the hooks below change this visit's state only.
  local visit = ui.runtime
  local override = ui.override

  -- The writes and the EEPROM commit belong to the pipeline, not to this page: the page can be
  -- left while they are on the wire, and its close releases ui.runtime and the module handles
  -- above. So every payload is built here, and nothing below may assume the page is still open.
  local ok, err = SavePipeline.start({
    pageId = "setup_mixer_swashgeometry",
    steps = {
      { label = "MSP_SET_MIXER_CONFIG", command = MixerConfigApi.writeCommand,
        payload = MixerConfigApi.buildWritePayload(records.MIXER_CONFIG) },
      { label = "MSP_SET_MIXER_INPUT", command = MixerInputPitchApi.writeCommand,
        payload = MixerInputPitchApi.buildWritePayload(records.GET_MIXER_INPUT_PITCH) },
      { label = "MSP_SET_MIXER_INPUT", command = MixerInputRollApi.writeCommand,
        payload = MixerInputRollApi.buildWritePayload(records.GET_MIXER_INPUT_ROLL) },
      { label = "MSP_SET_MIXER_INPUT", command = MixerInputCollectiveApi.writeCommand,
        payload = MixerInputCollectiveApi.buildWritePayload(records.GET_MIXER_INPUT_COLLECTIVE) }
    },
    reboot = false,
    onSaved = function()
      -- Stored: from now on this is what leaving without Save puts back.
      if override then override:stored(records, values) end
      if ui.runtime ~= visit then return end
      for i = 1, #RECORDS do ui.apiData[RECORDS[i]] = copyFlat(records[RECORDS[i]]) end
      saveToSession()
    end,
    onDone = function(result)
      local saved = type(result) == "table" and result.saved == true
      if not saved and override then override:saveFailed() end
      if ui.runtime ~= visit then return end
      if not saved and hadEdit then
        logf("info", "save not stored: the page stays unsaved")
        ui.dirty = true
      end
      if type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })
  if not ok then return false, err end

  -- The save sends what is on screen, so the live loop has nothing to send until it changes, and
  -- until the save is stored its writes count as sent.
  if override then override:markSent(values) end
  return true, nil
end

local function buildSessionSignature()
  return "1"
end

local function getBaseTitle()
  return pageText(nil, "geometry", "Swashplate Geometry")
end

local function ensureLoaded()
  if ui.loaded then return end
  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()
  ui.baseTitle = getBaseTitle()
  queueGeometryRead(false)
end

local function overrideActive()
  return ui.override ~= nil and ui.override.active == true
end

local function ensureOverride()
  if ui.override then return ui.override end
  if not haveRecords(ui.apiData) then return nil end
  if not LiveOverride then LiveOverride = loadModule("app/pages/lib/live_override.lua") end
  if not LiveOverride then return nil end
  ui.override = LiveOverride.new({
    command = MSP_SET_MIXER_OVERRIDE,
    inputs = OVERRIDE_INPUTS,
    on = MIXER_OVERRIDE_PASSTHROUGH,
    off = MIXER_OVERRIDE_OFF,
    cadence = "periodic",
    interval = LIVE_INTERVAL
  })
  logf("debug", "setup mode: override created")
  -- The records read stay as read (writes go out as copies), so they are what the board holds,
  -- even when values were edited on screen before *.
  local records = {}
  for i = 1, #RECORDS do records[RECORDS[i]] = copyFlat(ui.apiData[RECORDS[i]]) end
  ui.override:snapshot(records, valuesFrom(records))
  return ui.override
end

-- Whether leaving or Reload has to put back what went out live: only with an override in this
-- visit, and not while a save is still writing, whose steps a rollback would land between.
local function rollbackDue()
  return ui.dirty and ui.override ~= nil and LiveOverride ~= nil and not LiveOverride.saveWriting()
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
    queueGeometryRead(false)
  end

  if overrideActive() and ui.dirty then
    ui.override:tick(ui.config, sendLive)
  end
end

function M.getHeaderActions()
  return {
    save = true,
    reload = true,
    -- Switching setup mode on waits for this visit's read, as Save does (M.canSave above):
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
      message = pageText(i18n, "loading_geometry", "Reading swashplate geometry configuration..."),
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

  -- 1) Cyclic Calibration
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "cyclic_calibration", "Cyclic Calibration"),
    {
      min = 200,
      max = 2000,
      step = 1,
      get = function() return ui.config.cyclic_calibration or 400 end,
      set = function(val)
        if ui.config.cyclic_calibration ~= val then
          ui.config.cyclic_calibration = val
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f%%", (tonumber(v) or 0) / 10) end,
      suffix = "%",
      helpText = pageText(i18n, "help_cyclic_calibration",
        "Cyclic gain matched to the mechanical gain of the rotor head.")
    }
  )

  -- 2) Collective Calibration
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "collective_calibration", "Collective Calibration"),
    {
      min = 200,
      max = 2000,
      step = 1,
      get = function() return ui.config.collective_calibration or 400 end,
      set = function(val)
        if ui.config.collective_calibration ~= val then
          ui.config.collective_calibration = val
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f%%", (tonumber(v) or 0) / 10) end,
      suffix = "%",
      helpText = pageText(i18n, "help_collective_calibration",
        "Collective gain matched to the mechanical gain of the rotor head.")
    }
  )

  -- 3) Geo Correction
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "geo_correction", "Geo Correction"),
    {
      min = -250,
      max = 250,
      step = 2,
      get = function() return ui.config.geo_correction or 0 end,
      set = function(val)
        if ui.config.geo_correction ~= val then
          ui.config.geo_correction = val
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f%%", (tonumber(v) or 0) / 10) end,
      suffix = "%",
      helpText = pageText(i18n, "help_geo_correction",
        "Adjust until the positive and negative collective deflections are equal.")
    }
  )

  -- 4) Cyclic Pitch Limit
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "cyclic_pitch_limit", "Cyclic Pitch Limit"),
    {
      min = 0,
      max = 200,
      step = 1,
      get = function() return ui.config.cyclic_pitch_limit or 20 end,
      set = function(val)
        if ui.config.cyclic_pitch_limit ~= val then
          ui.config.cyclic_pitch_limit = val
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f°", (tonumber(v) or 0) / 10) end,
      suffix = "°",
      helpText = pageText(i18n, "help_cyclic_pitch_limit",
        "Most cyclic blade pitch the mixer commands, in degrees.")
    }
  )

  -- 5) Collective Pitch Limit
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "collective_pitch_limit", "Collective Pitch Limit"),
    {
      min = 0,
      max = 200,
      step = 1,
      get = function() return ui.config.collective_pitch_limit or 20 end,
      set = function(val)
        if ui.config.collective_pitch_limit ~= val then
          ui.config.collective_pitch_limit = val
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f°", (tonumber(v) or 0) / 10) end,
      suffix = "°",
      helpText = pageText(i18n, "help_collective_pitch_limit",
        "Most collective blade pitch the mixer commands, in degrees.")
    }
  )

  -- 6) Total Pitch Limit
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "swash_pitch_limit", "Total Pitch Limit"),
    {
      min = 0,
      max = 360,
      step = 1,
      get = function() return ui.config.swash_pitch_limit or 200 end,
      set = function(val)
        if ui.config.swash_pitch_limit ~= val then
          ui.config.swash_pitch_limit = val
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f°", (tonumber(v) or 0) / 10) end,
      suffix = "°",
      helpText = pageText(i18n, "help_swash_pitch_limit",
        "Most total blade pitch, cyclic and collective together, in degrees.")
    }
  )

  -- 7) Phase Angle
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "swash_phase", "Phase Angle"),
    {
      min = -1800,
      max = 1800,
      step = 1,
      get = function() return ui.config.swash_phase or 0 end,
      set = function(val)
        if ui.config.swash_phase ~= val then
          ui.config.swash_phase = val
          ui.dirty = true
        end
      end,
      display = function(v) return string.format("%.1f°", (tonumber(v) or 0) / 10) end,
      suffix = "°",
      helpText = pageText(i18n, "help_swash_phase",
        "Phase offset of the swashplate controls, in degrees.")
    }
  )

  -- 8) Collective Tilt Correction +
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "collective_tilt_correction_pos", "Collective Tilt Correction +"),
    {
      min = -100,
      max = 100,
      step = 1,
      get = function() return ui.config.collective_tilt_correction_pos or 0 end,
      set = function(val)
        if ui.config.collective_tilt_correction_pos ~= val then
          ui.config.collective_tilt_correction_pos = val
          ui.dirty = true
        end
      end,
      display = function(v) return tostring(v or 0) .. "%" end,
      suffix = "%",
      helpText = pageText(i18n, "help_collective_tilt_correction_pos",
        "At full positive collective, adjust until the swashplate pivot ball stays still while cyclic is added.")
    }
  )

  -- 9) Collective Tilt Correction -
  cursorY = cursorY + Controls.appendNumberField(children, x, cursorY, w,
    pageText(i18n, "collective_tilt_correction_neg", "Collective Tilt Correction -"),
    {
      min = -100,
      max = 100,
      step = 1,
      get = function() return ui.config.collective_tilt_correction_neg or 0 end,
      set = function(val)
        if ui.config.collective_tilt_correction_neg ~= val then
          ui.config.collective_tilt_correction_neg = val
          ui.dirty = true
        end
      end,
      display = function(v) return tostring(v or 0) .. "%" end,
      suffix = "%",
      helpText = pageText(i18n, "help_collective_tilt_correction_neg",
        "At full negative collective, adjust until the swashplate pivot ball stays still while cyclic is added.")
    }
  )
end

function M.onSave(ctx)
  local hadEdit = ui.dirty
  local ok, err = queueGeometryWrite(hadEdit)
  if not ok then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        title = pageText(ctx and ctx.i18n, "save_error_title", "Error"),
        message = tostring(err or "MSP write failed")
      })
    end
    return false
  end

  -- The shared save's notice reports how the save ended; the page has nothing to add to it. A
  -- save that does not reach EEPROM puts the unsaved flag back (queueGeometryWrite).
  ui.dirty = false
  return true
end

function M.onReload(ctx)
  local session = getSession()
  if session then
    -- Before the read, so the read is queued behind the rollback and shows the board's values.
    if rollbackDue() then rollbackLiveChanges() end
    loadFromSession()
    ui.dirty = false
    queueGeometryRead(false)
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
    title = pageText(i18n, "enable_swash_override", "Enable swash setup mode")
    message = pageText(i18n, "enable_swash_override_message", "Enable passthrough mixer override so you can move the sticks while adjusting swash geometry. \n\nLive changes from this page are sent to the flight controller.")
  else
    title = pageText(i18n, "disable_swash_override", "Disable swash setup mode")
    message = pageText(i18n, "disable_swash_override_message", "Disable swash setup mode and return mixer control to the flight controller.")
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
  -- Unsaved geometry sent live is taken back first, while setup mode is still on. Queued ahead of
  -- the override writes on purpose: should the close end before every write is out, a lost
  -- override write leaves a board that refuses to arm, a lost rollback a trial geometry the model
  -- would fly with. A save still writing is not undone here (rollbackDue above).
  if rollbackDue() then
    rollbackLiveChanges()
  elseif ui.dirty and ui.override then
    logf("debug", "close: a save is still writing, nothing put back")
  end
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
  MixerInputPitchApi = nil
  MixerInputRollApi = nil
  MixerInputCollectiveApi = nil
  LoadingOverlay = nil
  LiveOverride = nil
  SavePipeline = nil
  t = nil
end

return M
