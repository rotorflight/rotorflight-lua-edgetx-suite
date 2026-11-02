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
local SavePipeline = nil
local Common = nil
local MspRuntime = nil
local MixerConfigApi = nil
local MixerInputPitchApi = nil
local MixerInputRollApi = nil
local MixerInputCollectiveApi = nil
local LoadingOverlay = nil
local t = nil


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

local function applyDirectionToRate(u16rate, dir01)
  if u16rate == nil then return nil end
  local s = u16_to_s16(u16rate)
  local mag = math.abs(s)
  local signed = mag * dirSign(dir01)
  return s16_to_u16(signed)
end

local ui = {
  loaded = false,
  dirty = false,
  loading = false,
  progress = 0,
  baseTitle = nil,
  config = {
    swash_type = 0,
    main_rotor_dir = 0,
    ail_direction = 1,
    ele_direction = 1,
    col_direction = 1
  },
  apiData = {},
  runtime = {
    readPending = false,
    requestRebuild = nil
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
  if type(session.setup_mixer_swash) ~= "table" then
    session.setup_mixer_swash = {}
  end
  return session.setup_mixer_swash
end

local function loadFromSession()
  local session = getSession()
  local rcConfig = getRcConfig(session)
  if not rcConfig then return end
  ui.config.swash_type = rcConfig.swash_type or 0
  ui.config.main_rotor_dir = rcConfig.main_rotor_dir or 0
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
  rcConfig.swash_type = ui.config.swash_type
  rcConfig.main_rotor_dir = ui.config.main_rotor_dir
  rcConfig.ail_direction = ui.config.ail_direction
  rcConfig.ele_direction = ui.config.ele_direction
  rcConfig.col_direction = ui.config.col_direction
  rcConfig.apiData = ui.apiData
end

local function queueSwashRead(isAutoReload)
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

  -- Step 1: Read MIXER_CONFIG
  queue:add({
    command = MixerConfigApi.command,
    simulatorResponse = MixerConfigApi.simulatorResponse,
    processReply = function(self, buf)
      local parsed = MixerConfigApi.parse(buf)
      if type(parsed) ~= "table" then return Common.failPageRead(ui) end
      if parsed then
        ui.apiData.MIXER_CONFIG = parsed
        ui.config.swash_type = parsed.swash_type or 0
        ui.config.main_rotor_dir = parsed.main_rotor_dir or 0
      end

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
          if parsed then
            ui.apiData.GET_MIXER_INPUT_PITCH = parsed
            ui.config.ele_direction = rateToDir(parsed.rate_stabilized_pitch)
          end

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
              if parsed then
                ui.apiData.GET_MIXER_INPUT_ROLL = parsed
                ui.config.ail_direction = rateToDir(parsed.rate_stabilized_roll)
              end

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
                  if parsed then
                    ui.apiData.GET_MIXER_INPUT_COLLECTIVE = parsed
                    ui.config.col_direction = rateToDir(parsed.rate_stabilized_collective)
                  end

                  saveToSession()

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
            end,
            errorHandler = function()
              ui.runtime.readPending = false
              ui.loading = false
              if type(ui.runtime.requestRebuild) == "function" then
                ui.runtime.requestRebuild()
              end
            end
          })
        end,
        errorHandler = function()
          ui.runtime.readPending = false
          ui.loading = false
          if type(ui.runtime.requestRebuild) == "function" then
            ui.runtime.requestRebuild()
          end
        end
      })
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

local function copyRecord(record)
  local copy = {}
  for k, v in pairs(record) do copy[k] = v end
  return copy
end

local function queueSwashWrite()
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if not SavePipeline or not MixerConfigApi or not MixerInputPitchApi
    or not MixerInputRollApi or not MixerInputCollectiveApi then
    return false, "msp_runtime_unavailable"
  end

  if not M.canSave()
    or type(ui.apiData.MIXER_CONFIG) ~= "table"
    or type(ui.apiData.GET_MIXER_INPUT_PITCH) ~= "table"
    or type(ui.apiData.GET_MIXER_INPUT_ROLL) ~= "table"
    or type(ui.apiData.GET_MIXER_INPUT_COLLECTIVE) ~= "table" then
    return false, "loaded_data_missing"
  end

  -- Whether this save has to restart the flight controller is decided here, from the difference
  -- between what was read and what is about to be written. A module-level flag set when the
  -- control changed stood here instead, and it was only ever cleared on the success path: a chain
  -- that died earlier left it set, so the next save on this page restarted the board although the
  -- swashplate type had not been touched.
  local swashTypeChanged = ui.apiData.MIXER_CONFIG.swash_type ~= ui.config.swash_type

  -- The save is built on copies, and the records read stay as read until it is done. Written into
  -- in place, a save that was refused or failed after MSP_SET_MIXER_CONFIG left the new swashplate
  -- type in the read record, so the next Save compared the new type with itself and did not
  -- restart the board, although only a restart applies it.
  local writeConfig = copyRecord(ui.apiData.MIXER_CONFIG)
  local writePitch = copyRecord(ui.apiData.GET_MIXER_INPUT_PITCH)
  local writeRoll = copyRecord(ui.apiData.GET_MIXER_INPUT_ROLL)
  local writeCollective = copyRecord(ui.apiData.GET_MIXER_INPUT_COLLECTIVE)

  writeConfig.swash_type = ui.config.swash_type
  writeConfig.main_rotor_dir = ui.config.main_rotor_dir

  writePitch.rate_stabilized_pitch = applyDirectionToRate(writePitch.rate_stabilized_pitch, ui.config.ele_direction)
  writeRoll.rate_stabilized_roll = applyDirectionToRate(writeRoll.rate_stabilized_roll, ui.config.ail_direction)
  writeCollective.rate_stabilized_collective =
    applyDirectionToRate(writeCollective.rate_stabilized_collective, ui.config.col_direction)

  return SavePipeline.start({
    pageId = "setup_mixer_swash",
    steps = {
      {
        label = "MSP_SET_MIXER_CONFIG",
        command = MixerConfigApi.writeCommand,
        payload = MixerConfigApi.buildWritePayload(writeConfig)
      },
      {
        label = "MSP_SET_MIXER_INPUT_PITCH",
        command = MixerInputPitchApi.writeCommand,
        payload = MixerInputPitchApi.buildWritePayload(writePitch)
      },
      {
        label = "MSP_SET_MIXER_INPUT_ROLL",
        command = MixerInputRollApi.writeCommand,
        payload = MixerInputRollApi.buildWritePayload(writeRoll)
      },
      {
        label = "MSP_SET_MIXER_INPUT_COLLECTIVE",
        command = MixerInputCollectiveApi.writeCommand,
        payload = MixerInputCollectiveApi.buildWritePayload(writeCollective)
      }
    },
    reboot = swashTypeChanged,
    invalidateSessionKeys = { "setup_mixer_swash" },
    onSaved = function()
      ui.dirty = false
    end,
    onDone = function(result)
      if result.status == "done" then
        -- The board holds what was written, and the next save is compared with that.
        ui.apiData.MIXER_CONFIG = writeConfig
        ui.apiData.GET_MIXER_INPUT_PITCH = writePitch
        ui.apiData.GET_MIXER_INPUT_ROLL = writeRoll
        ui.apiData.GET_MIXER_INPUT_COLLECTIVE = writeCollective
      else
        ui.dirty = true
      end
      if ui.runtime and type(ui.runtime.requestRebuild) == "function" then
        ui.runtime.requestRebuild()
      end
    end
  })
end

local function buildSessionSignature()
  return "1"
end

local function getBaseTitle()
  return pageText(nil, "swash", "Swashplate")
end

local function ensureLoaded()
  if ui.loaded then return end
  -- A save whose overlay was dismissed finished without a screen. Its outcome was held back
  -- rather than raised over whatever page the user went to; claim it now that this one is open.
  if not SavePipeline then SavePipeline = loadModule("tasks/msp/save_pipeline.lua") end
  if SavePipeline and type(SavePipeline.takeResult) == "function" then
    SavePipeline.takeResult("setup_mixer_swash")
  end
  loadFromSession()
  ui.loaded = true
  ui.dirty = false
  ui.runtime.lastSessionSignature = buildSessionSignature()
  ui.baseTitle = getBaseTitle()
  queueSwashRead(false)
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
    queueSwashRead(false)
  end
end

function M.getHeaderActions()
  return {
    save = true,
    reload = true,
    menu = true
  }
end

-- The page is kept between visits and loadFromSession() puts the last records read back into
-- ui.apiData before this visit's read is even queued, so "the records are there" says nothing
-- about this visit. ui.runtime is dropped by resetPageState() on close, which makes this flag
-- the visit's own: set only when every read of the chain parsed, cleared when a read starts.
function M.canSave()
  return ui.runtime ~= nil and ui.runtime.readComplete == true and not ui.runtime.readPending
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
      message = pageText(i18n, "loading", "Reading swashplate configuration..."),
      progress = ui.progress / 100
    })
    return
  end

  local displayTitle = ui.baseTitle or getBaseTitle()

  if type(ui.runtime) == "table" and type(ui.runtime.syncHeaderTitle) == "function" then
    ui.runtime.syncHeaderTitle(displayTitle, M.getHeaderActions())
  end

  local cursorY = y
  if Controls and type(Controls.appendStaticSectionHeader) == "function" then
    Controls.appendStaticSectionHeader(children, x, cursorY, w, displayTitle)
    cursorY = cursorY + (Controls.STATIC_SECTION_H or 50)
  end

  cursorY = cursorY + 10

  -- 1) Swashplate Type
  local swashTypeChoices = {
    { value = 0, label = pageText(i18n, "swash_none", "None") },
    { value = 1, label = pageText(i18n, "swash_direct", "Direct") },
    { value = 2, label = "CPPM 120" },
    { value = 3, label = "CPPM 135" },
    { value = 4, label = "CPPM 140" },
    { value = 5, label = "FPM 90 L" },
    { value = 6, label = "FPM 90 V" }
  }
  cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
    pageText(i18n, "swash_type", "Swashplate type"),
    swashTypeChoices,
    ui.config.swash_type,
    function(newVal)
      if ui.config.swash_type ~= newVal then
        ui.config.swash_type = newVal
        ui.dirty = true
      end
    end
  )

  -- 2) Rotor Direction
  local rotorDirChoices = {
    { value = 0, label = pageText(i18n, "cw", "CW") },
    { value = 1, label = pageText(i18n, "ccw", "CCW") }
  }
  cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
    pageText(i18n, "main_rotor_dir", "Main rotor direction"),
    rotorDirChoices,
    ui.config.main_rotor_dir,
    function(newVal)
      if ui.config.main_rotor_dir ~= newVal then
        ui.config.main_rotor_dir = newVal
        ui.dirty = true
      end
    end
  )

  -- 3) Aileron Direction
  local dirChoices = {
    { value = 0, label = pageText(i18n, "reversed", "Reversed") },
    { value = 1, label = pageText(i18n, "normal", "Normal") }
  }
  cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
    pageText(i18n, "aileron_direction", "Aileron direction"),
    dirChoices,
    ui.config.ail_direction,
    function(newVal)
      if ui.config.ail_direction ~= newVal then
        ui.config.ail_direction = newVal
        ui.dirty = true
      end
    end
  )

  -- 4) Elevator Direction
  cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
    pageText(i18n, "elevator_direction", "Elevator direction"),
    dirChoices,
    ui.config.ele_direction,
    function(newVal)
      if ui.config.ele_direction ~= newVal then
        ui.config.ele_direction = newVal
        ui.dirty = true
      end
    end
  )

  -- 5) Collective Direction
  cursorY = cursorY + Controls.appendComboSelect(children, x, cursorY, w,
    pageText(i18n, "collective_direction", "Collective direction"),
    dirChoices,
    ui.config.col_direction,
    function(newVal)
      if ui.config.col_direction ~= newVal then
        ui.config.col_direction = newVal
        ui.dirty = true
      end
    end
  )
end

function M.onSave(ctx)
  local ok, err = queueSwashWrite()
  if not ok then
    if ctx and type(ctx.reportSave) == "function" then
      ctx.reportSave({
        title = pageText(ctx and ctx.i18n, "save_error_title", "Error"),
        message = tostring(err or "MSP write failed")
      })
    end
    return false
  end

  -- Nothing is announced here. This function has only QUEUED the save: the writes, the commit
  -- and -- on this page -- the restart are all still ahead of it, and a dialog saying the
  -- settings are saved would be a claim it cannot make. It was also drawn on TOP of the
  -- overlay that reports the save, from a place where that overlay could not be repainted away
  -- first, and while a native dialog stands the tool's run() does not run at all. The pipeline
  -- reports the outcome in the overlay, once, when it knows it.
  return true
end

function M.onReload(ctx)
  local session = getSession()
  if session then
    loadFromSession()
    ui.dirty = false
    queueSwashRead(false)
  end
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
  MixerConfigApi = nil
  MixerInputPitchApi = nil
  MixerInputRollApi = nil
  MixerInputCollectiveApi = nil
  LoadingOverlay = nil
  t = nil
end

-- Asked before the page is left (ui/home.lua): true while an edit here is not saved.
function M.hasUnsavedChanges()
  return ui.dirty == true
end

return M
