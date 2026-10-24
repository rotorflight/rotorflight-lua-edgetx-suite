local M = {}

local function loadModule(path)
  if _G.rfsuite and _G.rfsuite.require then
    return _G.rfsuite.require(path)
  end
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = assert(loadScript(fullPath, "t"))
  return chunk()
end

local Palette = _G.rfsuite and _G.rfsuite.palette or loadModule("ui/palette.lua")

local function wipeTable(t)
  if type(t) ~= "table" then return end
  for k in pairs(t) do
    t[k] = nil
  end
end

function M.t(i18n, pageKey, key, fallback)
  if i18n and i18n.t then
    -- The keys in de.lua/en.lua are structured under app.pages...
    local fullKey = "app.pages." .. pageKey .. "." .. key
    local val = i18n.t(fullKey)
    if val ~= fullKey then
      return val
    end
  end
  return fallback
end

function M.pageT(pageKey)
  return function(i18n, key, fallback)
    return M.t(i18n, pageKey, key, fallback)
  end
end

-- Reusable runtime helpers for settings pages with toggle fields.
-- Keeps per-build allocations low by caching handlers/getters/setters.
function M.createFormRuntime(ui)
  local runtime = {
    requestRebuild = nil,
    sectionToggleHandlers = {},
    boolGetters = {},
    boolSetters = {},
    valueSetters = {}
  }

  -- A page may draw different controls depending on the value that has just
  -- changed, so every change has to be able to ask for a repaint. ui.dirty
  -- records that the page has been edited; it must not also act as a one-shot
  -- guard in front of the rebuild request. That is what left the three
  -- per-model combos of settings/dashboard/theme/page.lua on screen after the
  -- Model Override switch that gates them had been turned back off: the first
  -- change of a visit rebuilt, no later one did, and the page has no wakeup
  -- hook to catch it afterwards. Asking is cheap - ui/home.lua only raises a
  -- pending flag and coalesces it into at most one build per frame.
  local function markDirty()
    ui.dirty = true
    local rebuild = runtime.requestRebuild
    if rebuild then rebuild() end
  end

  function runtime.setRequestRebuild(fn)
    runtime.requestRebuild = fn
  end

  function runtime.markDirty()
    markDirty()
  end

  -- The same flag WITHOUT the rebuild, and it exists because of the difference between a
  -- numberEdit and everything else. A numberEdit calls its `set` on every click while its
  -- editor is open, and a rebuild destroys that editor: the remaining clicks then move the
  -- focus instead of the value. So a control that is edited in place marks the page dirty
  -- through this, and a control that can change WHICH controls are drawn -- a switch that
  -- gates a section, a combo that commits and closes -- goes through markDirty above.
  function runtime.markValueChanged()
    ui.dirty = true
  end

  function runtime.getSectionToggleHandler(name)
    local handler = runtime.sectionToggleHandlers[name]
    if handler then return handler end

    handler = function()
      ui.sections[name] = not ui.sections[name]
      local rebuild = runtime.requestRebuild
      if rebuild then rebuild() end
    end
    runtime.sectionToggleHandlers[name] = handler
    return handler
  end

  function runtime.getBoolGetter(key)
    local getter = runtime.boolGetters[key]
    if getter then return getter end

    getter = function(nextVal)
      if nextVal ~= nil then return end
      return ui.config[key] == true
    end
    runtime.boolGetters[key] = getter
    return getter
  end

  -- The value analogue of getBoolSetter, for a plain `ui.config[key] = value` control.
  function runtime.getValueSetter(key)
    local setter = runtime.valueSetters[key]
    if setter then return setter end

    setter = function(nextVal)
      if ui.config[key] == nextVal then return end
      ui.config[key] = nextVal
      ui.dirty = true
    end
    runtime.valueSetters[key] = setter
    return setter
  end

  function runtime.getBoolSetter(key)
    local setter = runtime.boolSetters[key]
    if setter then return setter end

    setter = function(nextVal)
      ui.config[key] = (nextVal == true)
      markDirty()
    end
    runtime.boolSetters[key] = setter
    return setter
  end

  return runtime
end

local Profile = nil

local function loadProfile()
  if Profile == nil then
    if _G.rfsuite and _G.rfsuite.require then
      Profile = _G.rfsuite.require("lib/profile.lua") or false
    else
      local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/profile.lua", "t")
      if type(chunk) == "function" then
        local ok, mod = pcall(chunk)
        Profile = (ok and mod) or false
      else
        Profile = false
      end
    end
  end
  return (Profile ~= false and Profile) or nil
end

function M.createProfileAwareRuntime(options)
  options = options or {}

  local profileGetter = options.profileGetter
  if not profileGetter then
    local profileType = options.profileType or "pid"
    local profileHelper = loadProfile()
    if profileHelper then
      if profileType == "rate" or profileType == "rate_profile" then
        profileGetter = function() return profileHelper.getActiveRateProfile() end
      else
        profileGetter = function() return profileHelper.getActivePidProfile() end
      end
    end
  end

  local runtime = {
    requestRebuild = nil,
    profileGetter = profileGetter,
    lastProfile = nil
  }

  function runtime.getCurrentProfile()
    if type(runtime.profileGetter) == "function" then
      return runtime.profileGetter()
    end
    return nil
  end

  function runtime.syncHeaderTitle(baseTitle, navButtons)
    local profile = runtime.getCurrentProfile()
    if profile == nil then return false end

    local root = _G and _G.rfsuite
    local ui = root and root.app and root.app.ui
    if not ui or type(ui.setHeaderTitle) ~= "function" then
      return false
    end

    local title = tostring(baseTitle or "")
    title = string.gsub(title, " #%d+$", "")
    ui.setHeaderTitle(title .. " #" .. tostring(profile), nil, navButtons)
    runtime.lastProfile = profile
    return true
  end

  return runtime
end

-- A received reply can still be rejected by its parser. Leave the page reloadable, but
-- never let the defaults left on screen become a write to the flight controller.
-- `readFailed` stays set until the page starts its next read, so a page can draw
-- appendReadFailedNotice in place of values the flight controller never sent.
function M.failPageRead(ui)
  if type(ui.runtime) ~= "table" then return end
  ui.runtime.readComplete = false
  ui.runtime.readFailed = true
  ui.runtime.readPending = false
  ui.loading = false
  if type(ui.runtime.requestRebuild) == "function" then
    ui.runtime.requestRebuild()
  end
end

-- What a read-backed page draws instead of its fields once its read has failed: one sentence,
-- the same on every page. The page's Reload reads again.
function M.appendReadFailedNotice(children, x, y, w)
  children[#children + 1] = {
    type = "label",
    x = x + 10,
    y = y,
    w = w - 20,
    text = "@i18n(app.read_failed)@",
    color = Palette.text,
    font = SMLSIZE
  }
end

-- The reason a pilot reads after "Save failed" when a settings file could not be written. A store
-- answers a refused write with a token -- config_store's "io", "write", "delete" or "rename" --
-- or with the error text io.open gave, which carries the file's path, and the module around it
-- can answer with a Lua error. None of that is for the screen: it all reads as one sentence.
-- `modelStore` says the answer is about the model's own file (model_preferences.saveByMcuId),
-- whose "unavailable" (the store module will not load) and "missing_mcu_id" (no board id to
-- name the model's file by) have sentences of their own. The raw answer belongs in the log.
function M.saveFailureReason(i18n, err, modelStore)
  if modelStore and err == "unavailable" then
    return i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.model_store_unavailable")
      or "model settings store not available"
  end
  if modelStore and err == "missing_mcu_id" then
    return i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.model_store_missing")
      or "Connect the flight controller to save this model's settings"
  end
  return i18n and i18n.t and i18n.t("app.pages.settings_dashboard_settings.store_write_failed")
    or "the settings file could not be written to the SD card"
end

-- Shared teardown helper for page modules.
-- Keeps close/reset behavior consistent across pages.
function M.resetPageState(ui, opts)
  opts = opts or {}
  if type(ui) ~= "table" then return end

  if opts.resetLoaded ~= false and ui.loaded ~= nil then
    ui.loaded = false
  end
  if opts.resetDirty ~= false and ui.dirty ~= nil then
    ui.dirty = false
  end
  if opts.clearRebuild == true and ui.rebuild ~= nil then
    ui.rebuild = nil
  end
  if opts.clearLastAutoRefresh == true and ui.lastAutoRefreshAt ~= nil then
    ui.lastAutoRefreshAt = 0
  end

  if type(ui.handlers) == "table" then
    wipeTable(ui.handlers)
  end

  if type(ui.runtime) == "table" then
    ui.runtime.requestRebuild = nil
    wipeTable(ui.runtime.sectionToggleHandlers)
    wipeTable(ui.runtime.boolGetters)
    wipeTable(ui.runtime.boolSetters)
    wipeTable(ui.runtime.valueGetters)
    wipeTable(ui.runtime.valueSetters)
  end
  ui.runtime = nil

  -- Only list tables that build() re-creates. registry.release() runs this hook
  -- and then keeps the module in its cache, so a table that is emptied here and
  -- filled in at load time stays empty for the rest of the session.
  local tablesToWipe = opts.tablesToWipe
  if type(tablesToWipe) == "table" then
    for i = 1, #tablesToWipe do
      local key = tablesToWipe[i]
      if type(key) == "string" and type(ui[key]) == "table" then
        wipeTable(ui[key])
      end
    end
  end
end

function M.appendSectionHeader(children, x, y, w, title)
  children[#children + 1] = {
    type = "label",
    x = x,
    y = y,
    text = title,
    color = Palette.settingsText,
    font = DBLSIZE
  }

  children[#children + 1] = {
    type = "label",
    x = x + w - 18,
    y = y + 2,
    w = 16,
    text = "v",
    color = Palette.settingsText,
    align = RIGHT,
    font = DBLSIZE
  }

  children[#children + 1] = {
    type = "rectangle",
    x = x,
    y = y + 34,
    w = w,
    h = 1,
    color = Palette.border,
    filled = true
  }
end

function M.appendSettingsRow(children, x, y, w, labelText, valueText, withArrow, rowH)
  local ctrlH = (lvgl and lvgl.UI_ELEMENT_HEIGHT) or 32
  rowH = rowH or math.max(44, ctrlH + 12)
  local fontH = (lvgl and lvgl.LCD_SCALE and math.floor(21 * lvgl.LCD_SCALE + 0.5)) or 21
  local labelY = y + math.floor((rowH - fontH) / 2)
  local ctrlY = y + math.floor((rowH - ctrlH) / 2)
  local valueW = math.floor(w * 0.50)
  local valueX = x + w - valueW

  children[#children + 1] = {
    type = "label",
    x = x,
    y = labelY,
    w = valueX - x - 8,
    text = labelText,
    color = Palette.settingsText,
    font = MIDSIZE
  }

  children[#children + 1] = {
    type = "rectangle",
    x = valueX,
    y = ctrlY,
    w = valueW,
    h = ctrlH,
    color = Palette.card,
    filled = true
  }

  local valueLabelW = withArrow and (valueW - 26) or (valueW - 10)
  children[#children + 1] = {
    type = "label",
    x = valueX + 6,
    y = labelY,
    w = valueLabelW,
    text = valueText,
    color = Palette.settingsText,
    align = RIGHT,
    font = MIDSIZE
  }

  if withArrow then
    children[#children + 1] = {
      type = "label",
      x = valueX + valueW - 20,
      y = labelY,
      w = 14,
      text = "v",
      color = Palette.settingsText,
      align = RIGHT,
      font = MIDSIZE
    }
  end

  children[#children + 1] = {
    type = "rectangle",
    x = x,
    y = y + rowH - 1,
    w = w,
    h = 1,
    color = Palette.border,
    filled = true
  }
end

function M.buildSimplePage(ctx, pageKey, sectionKey, sectionFallback, rows)
  local children = ctx.children
  local x = ctx.x
  local y = ctx.y
  local w = ctx.w
  local i18n = ctx.i18n

  M.appendSectionHeader(children, x, y, w, M.t(i18n, pageKey, sectionKey, sectionFallback))

  local rowY = y + 46
  local ctrlH = (lvgl and lvgl.UI_ELEMENT_HEIGHT) or 32
  local rowH = math.max(44, ctrlH + 12)
  for i = 1, #rows do
    local row = rows[i]
    local yOffset = (i - 1) * rowH
    local label = M.t(i18n, pageKey, row.labelKey, row.labelFallback)
    local value = M.t(i18n, pageKey, row.valueKey, row.valueFallback)
    M.appendSettingsRow(children, x, rowY + yOffset, w, label, value, row.withArrow ~= false, rowH)
  end
end

return M
