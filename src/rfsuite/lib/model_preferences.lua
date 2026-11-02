local M = {}

local USER_ROOTS = {
  "/SCRIPTS/TOOLS/rfsuite.user",
  "SCRIPTS:/TOOLS/rfsuite.user"
}

-- Reload request file monitored by the dashboard widget via fstat size.
-- Uses a rotating byte counter (1..32 bytes) so changes are reliably detected
-- where fstat is available even without an RTC or when the INI byte-size doesn't change,
-- without ever consuming or deleting the file (which breaks multi-reader and drops armed events).
local RELOAD_REQ_FILE = "reload.req"

M.USER_ROOTS = USER_ROOTS
M.RELOAD_REQ_FILE = RELOAD_REQ_FILE

local function bumpReloadCounter(userRoot)
  M.bumpReloadCounter(userRoot)
end

local function logD(fmt, ...)
  local L = _G.rfsuite and _G.rfsuite.Log
  if L and type(L.emitf) == "function" then
    L.emitf("rfsuite.reload", "debug", fmt, ...)
  end
end

local function trim(s)
  local asString = tostring(s or "")
  asString = string.gsub(asString, "^%s+", "")
  asString = string.gsub(asString, "%s+$", "")
  return asString
end

local function loadConfigStore()
  if _G.rfsuite and _G.rfsuite.require then
    return _G.rfsuite.require("lib/config_store.lua")
  end
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript("/SCRIPTS/TOOLS/rfsuite-core/lib/config_store.lua", mode)
  if not chunk then return nil end
  local ok, mod = pcall(chunk)
  if ok and type(mod) == "table" then return mod end
  return nil
end

-- The one place a per-model store's contents are declared. A section's `keys` carry the
-- defaults and are written on every save; an `open` section keeps the keys it is handed,
-- because its key names are built at runtime and no schema can name them. A section declared
-- nowhere here is dropped at the next save, which is how a key outliving the code that read
-- it leaves the file again.
local MODEL_SCHEMA = {
  -- Per-pack figures, keyed by the pack the pilot selected.
  battery = { open = true },
  dashboard = {
    keys = {
      model_override = false,
      model_theme_preflight = "nil",
      model_theme_inflight = "nil",
      model_theme_postflight = "nil",
    },
    -- Whether this model uses its own theme and theme settings. Without a default, because an
    -- absent switch is answered from what the file holds (app/pages/settings/dashboard/lib.lua).
    optional = { "overrides" },
    -- A theme's own configuration belongs to the machine and is stored here, under keys built
    -- from the theme's path (app/pages/settings/dashboard/lib.lua).
    open = true,
  },
  -- The model's half of the in-flight tuning overlay: how far suggested functions move per
  -- press, and which parameters appear in flight.
  --
  -- What is true of the transmitter whatever is plugged into it -- the interlock switch, the two
  -- channels and global variables the mixer devotes to the adjustment pair, and
  -- the trims -- belongs to the radio and is seeded in lib/preferences.lua, also under
  -- [inflight]. Those keys are never read out of a per-model store, so seeding them here only
  -- wrote them into every model file and showed a reader numbers nothing used.
  --
  -- These keys MUST agree with the model half of M.DEFAULTS in
  -- widgets/dashboard/inflight/setup.lua, which is what the overlay actually reads. They are
  -- duplicated rather than shared because this library is loaded by the whole suite and must not
  -- pull in a widget module to reach them; the same note sits on the other side.
  inflight = {
    keys = {
      step = 5,
      step_headspeed = 50,
      flight_list = "",
    },
  },
  -- Per-widget state, keyed by the widget.
  widgets = { open = true },
  -- The machine's own announcement settings, which override the radio-wide ones. Declared where
  -- they are offered, in app/pages/settings/audio/events/, and partly built in a loop, so this
  -- section keeps what it is handed rather than holding a second copy of that list.
  audio_events = { open = true },
  -- Which battery the flight log last booked a flight against.
  flightlog = { open = true },
  -- What the setup assistant has been told about this machine: a resume cursor and one key per
  -- procedure the pilot passed over, the radio-side ones carrying the transmitter model in the
  -- key (app/pages/setup_wizard/store.lua).
  setup_wizard = { open = true },
  -- Where the name a rename replaced was kept before it moved to a store of its own. Read once
  -- at rename time so a rename in effect across an update is not stranded.
  model = { open = true },
  -- What the flight controller calls itself, written while a board is connected so that a store
  -- can be told apart from the others on the card with nothing plugged in. Every other thing in
  -- this file is addressed by the board's MCU id, which is the one thing a reader cannot
  -- recognise.
  --
  -- It is NOT the section above: `model.previous_name` is the name the RADIO's model had before
  -- a rename wrote the craft name over it, and a `name` beside it would read as that key's
  -- current value while meaning the opposite thing.
  --
  -- `optional` rather than a key with a default, and the difference is what the file looks like
  -- on a board that has no name. A declared default is written into every model file on every
  -- save, so the file would carry a placeholder; a placeholder cannot be told apart from a craft
  -- actually called that, and the next connect would read it as a name already present and never
  -- correct it. An optional key is written only once there is a value for it, and a file without
  -- it still loads complete -- so no existing store is rewritten for the sake of a key it has no
  -- value for.
  craft = { optional = { "name" } },
}

local ConfigStore = loadConfigStore()
local store = ConfigStore and ConfigStore.new({ name = "model preferences", schema = MODEL_SCHEMA })

local function fileExists(path)
  local f = io.open(path, "r")
  if not f then return false end
  io.close(f)
  return true
end

local function getToolsRoot(userRoot)
  return string.gsub(userRoot or "", "/rfsuite%.user$", "")
end

-- mkdir() is a bare global of the firmware's filesystem library, not a member of os. The
-- previous guard here tested os.mkdir and could never pass -- this Lua has no os table at
-- all -- so no directory was ever created and a store whose parent was missing simply failed
-- to write. The shape follows app/pages/logs/graph.lua, which tests fstat() the same way.
-- mkdir() creates one level at a time, so the tools root goes first.
local function makeDir(path)
  if type(mkdir) ~= "function" then return end
  if type(path) ~= "string" or path == "" then return end
  pcall(mkdir, path)
end

local function ensureDirs(userRoot)
  local toolsRoot = getToolsRoot(userRoot)
  if toolsRoot ~= "" then
    makeDir(toolsRoot)
  end
  makeDir(userRoot)
end

local function buildPathForRoot(userRoot, safeId)
  return userRoot .. "/" .. safeId .. ".lua"
end

local function dirExists(path)
  -- Either spelling of the radio-wide store counts: a card written by an earlier release still
  -- carries the former one until its first load brings it across.
  if fileExists(path .. "/preferences.lua") or fileExists(path .. "/preferences.ini")
      or fileExists(path .. "/" .. RELOAD_REQ_FILE) then
    return true
  end
  if type(fstat) == "function" then
    local ok, info = pcall(fstat, path)
    if ok and type(info) == "table" then return true end
  end
  return false
end

local memoizedRoots = {}

local function orderedRoots(safeId)
  local cacheKey = safeId or "__default"
  if memoizedRoots[cacheKey] then
    return memoizedRoots[cacheKey]
  end

  local prioritized = {}
  local used = {}

  local function add(root)
    if type(root) ~= "string" or root == "" then return end
    if used[root] then return end
    used[root] = true
    prioritized[#prioritized + 1] = root
  end

  if safeId then
    for i = 1, #USER_ROOTS do
      local root = USER_ROOTS[i]
      if fileExists(buildPathForRoot(root, safeId)) then
        add(root)
      end
    end
  end

  for i = 1, #USER_ROOTS do
    local root = USER_ROOTS[i]
    if fileExists(root .. "/preferences.lua") or fileExists(root .. "/preferences.ini") then
      add(root)
    end
  end

  for i = 1, #USER_ROOTS do
    local root = USER_ROOTS[i]
    if dirExists(root) then
      add(root)
    end
  end

  for i = 1, #USER_ROOTS do
    add(USER_ROOTS[i])
  end

  memoizedRoots[cacheKey] = prioritized
  return prioritized
end

local function normalizeMcuId(mcuId)
  if mcuId == nil then return nil end
  local id = trim(tostring(mcuId))
  if id == "" then return nil end
  -- Keep filename safe even if an unexpected UID format appears.
  id = string.gsub(id, "[^%w_-]", "_")
  if id == "" then return nil end
  return id
end

local RELOAD_REQ_PATHS = {}
for i = 1, #USER_ROOTS do
  RELOAD_REQ_PATHS[i] = USER_ROOTS[i] .. "/" .. RELOAD_REQ_FILE
end

function M.reloadRequestPaths()
  return RELOAD_REQ_PATHS
end

function M.getUserRoots()
  local roots = {}
  for i = 1, #USER_ROOTS do
    roots[i] = USER_ROOTS[i]
  end
  return roots
end

function M.getUserRoot(safeId)
  local safe = normalizeMcuId(safeId)
  local roots = orderedRoots(safe)
  return roots[1] or USER_ROOTS[1]
end

function M.preferencesPath(safeId)
  return M.getUserRoot(safeId) .. "/preferences.lua"
end

function M.reloadRequestPath(userRootOrSafeId)
  local root
  if type(userRootOrSafeId) == "string" and userRootOrSafeId ~= "" then
    if string.find(userRootOrSafeId, "/") then
      root = userRootOrSafeId
    else
      root = M.getUserRoot(userRootOrSafeId)
    end
  else
    root = M.getUserRoot()
  end
  return root .. "/" .. RELOAD_REQ_FILE
end

function M.bumpReloadCounter(userRoot)
  local targetPath = M.reloadRequestPath(userRoot)
  local prevN = 0
  local n = 1
  if type(fstat) == "function" then
    local ok, info = pcall(fstat, targetPath)
    if ok and type(info) == "table" then
      prevN = (info.size or 0)
      n = (prevN % 32) + 1
    end
  end
  local f = io.open(targetPath, "w")
  if f then
    io.write(f, string.rep("x", n))
    io.close(f)
    logD("bumpReloadCounter: wrote %d bytes (was %d) to %s", n, prevN, targetPath)
  else
    logD("bumpReloadCounter: FAILED to open %s for write", targetPath)
  end
end

function M.clearCache()
  memoizedRoots = {}
end

function M.buildPath(mcuId)
  local safeId = normalizeMcuId(mcuId)
  if not safeId then return nil end

  local roots = orderedRoots(safeId)
  if #roots == 0 then return nil end
  return buildPathForRoot(roots[1], safeId)
end

--- Reads the store for one board. Answers the table and the path it came from; the table is
--- usable whatever the card did, and its identity is fresh on every call so that a caller may
--- treat it as a generation marker.
---
--- A connected board is left with a file carrying every declared key, so a release that adds
--- one does not leave every model file behind: the store is written back where the file was
--- absent or predates a key. That write happens in the Lua state that may migrate and nowhere
--- else: the connect tasks run in the widgets as well, and a widget call is cut off at a fixed
--- instruction count, which a write is as likely to land in the middle of as a parse. A widget
--- therefore answers with what the card holds and leaves settling the file to the next tool
--- session -- which changes no value, because the declared defaults fill the gaps either way.
function M.loadByMcuId(mcuId, force)
  local safeId = normalizeMcuId(mcuId)
  if not safeId then return nil, nil end
  if not store then return nil, nil end

  local roots = orderedRoots(safeId)

  for i = 1, #roots do
    local userRoot = roots[i]
    local path = buildPathForRoot(userRoot, safeId)

    ensureDirs(userRoot)

    -- A card written by an earlier release carries the former format. Bringing it across is a
    -- one-off, and after it the probe costs one failed open. It does nothing in a state that is
    -- not allowed to migrate; the load below then reads the former file into memory instead.
    store:migrate(path, ConfigStore.legacyPath(path))

    local prefs, info = store:load(path)
    local settled = info.found
    if ConfigStore.migrationAllowed() and (not info.found or not info.complete) then
      local ok, err = store:save(path, prefs)
      if ok then
        settled = true
      else
        logD("loadByMcuId: could not write %s: %s", path, tostring(err))
      end
    end

    -- A root that has neither a file to read nor room to write one is not this board's root,
    -- whatever the ordering said. The next one is tried before the defaults are given up to.
    -- In a state that may not write, only the first half of that test can be made, so a board
    -- whose file does not exist yet is answered from the declared defaults with no path -- the
    -- same answer this gives today when no root can be written to.
    if settled then
      local d = prefs.dashboard or {}
      -- The name logged is the file that was actually read: on a card that has not been brought
      -- across yet that is the former one beside the store, and a reader of this line that
      -- opens the store's name would find nothing there.
      local readFrom = info.legacy and ConfigStore.legacyPath(path) or path
      logD("loadByMcuId: loaded from disk %s (force=%s, override=%s, preflight=%s)",
        readFrom, tostring(force), tostring(d.model_override), tostring(d.model_theme_preflight))
      return prefs, path
    end
  end

  -- No root at all to read or write; the declared defaults are still the right answer.
  local fallback = store:defaults()
  logD("loadByMcuId: fallback defaults for mcuId=%s", safeId)
  return fallback, nil
end

--- Writes the store for one board and tells the widgets that it changed. What is written is
--- the schema above, so a key nothing declares any more leaves the file here.
function M.saveByMcuId(mcuId, prefs)
  local safeId = normalizeMcuId(mcuId)
  if not safeId then return false, "missing_mcu_id" end
  if not store then return false, "unavailable" end

  local roots = orderedRoots(safeId)
  local lastErr = "io"

  for i = 1, #roots do
    local userRoot = roots[i]
    local path = buildPathForRoot(userRoot, safeId)
    ensureDirs(userRoot)

    local okSave, saveErr = store:save(path, prefs)
    if okSave then
      memoizedRoots = {}
      -- Signal the dashboard widget that model preferences have changed via
      -- rotating sequence length in reload.req. Multi-reader safe, armed-safe,
      -- and independent of RTC timestamp or file size equality.
      bumpReloadCounter(userRoot)
      local d = (type(prefs) == "table" and prefs.dashboard) or {}
      logD("saveByMcuId: saved to %s (override=%s, preflight=%s)",
        path, tostring(d.model_override), tostring(d.model_theme_preflight))
      return true
    end
    lastErr = saveErr or "io"
    logD("saveByMcuId: could not write %s: %s", path, tostring(saveErr))
  end

  memoizedRoots = {}
  return false, lastErr
end

local CRAFT_SECTION = "craft"
local CRAFT_NAME_KEY = "name"

--- Records what the flight controller calls itself, so that this board's store can be
--- recognised on the card without a board to ask. The name arrives on connect, in
--- rfsuite.session.modelName.
---
--- `prefs` is the store already in memory -- the session's copy -- and it is updated in place
--- as well as written, because the next save serialises that table: a name written to the file
--- and not into the table would be dropped again by whichever page saves next. A caller with no
--- table in hand passes nil and the store is read here.
---
--- Answers true only where a file was written. Everything else is answered false with the
--- reason, and only two of those reasons are failures:
---
---   missing_mcu_id  no board id to address a store with
---   unavailable     the store module is not loadable, or the card refused the write
---   no_name         nothing to record -- see below
---   unchanged       the file already says this
---   not_allowed     this Lua state may not write -- see below
---
--- A board with no name answers the read with an EMPTY STRING rather than with nothing, and for
--- that nothing is stored. A placeholder would be indistinguishable from a craft actually called
--- that, and the next connect would then find a name present and never correct it. What to
--- display for a store that has no name is the caller's decision and not this file's.
---
--- The write happens in a Lua state that may write and in no other, which is the test
--- loadByMcuId's settling write already makes and for the same reason: a widget call is cut off
--- at a fixed instruction count, and a save is as likely to land in the middle of that as a
--- parse. The connect tasks run in the widgets too, so without the test this would be attempted
--- there on every connect. The tool and the background decoder both turn the switch on at their
--- entry point, and between them they cover every connect a radio makes with either on screen.
function M.recordModelName(mcuId, prefs, name)
  local safeId = normalizeMcuId(mcuId)
  if not safeId then return false, "missing_mcu_id" end
  if not store or not ConfigStore then return false, "unavailable" end

  if type(name) ~= "string" then return false, "no_name" end
  local craftName = trim(name)
  if craftName == "" then return false, "no_name" end

  if type(ConfigStore.migrationAllowed) ~= "function" or not ConfigStore.migrationAllowed() then
    return false, "not_allowed"
  end

  local target = prefs
  if type(target) ~= "table" then
    target = M.loadByMcuId(safeId, true)
    if type(target) ~= "table" then return false, "unavailable" end
  end

  local section = target[CRAFT_SECTION]
  if type(section) ~= "table" then
    section = {}
    target[CRAFT_SECTION] = section
  end

  -- Only a change is written. A connect otherwise costs the comparison and nothing else: a save
  -- rewrites the whole file and bumps the reload counter, which makes every widget reading this
  -- board re-read its settings.
  if section[CRAFT_NAME_KEY] == craftName then return false, "unchanged" end

  section[CRAFT_NAME_KEY] = craftName
  logD("recordModelName: %s is called %s", safeId, craftName)
  return M.saveByMcuId(safeId, target)
end

-- The files in a user root that are NOT a per-board store, and they are named rather than
-- guessed at: these are what the suite itself writes there.
--
--   preferences.lua / .ini        lib/preferences.lua, the settings belonging to the transmitter
--   model_name_restore.lua / .ini lib/model_name_store.lua, the name a rename replaced
--   the reload request            this file, above
--
-- The rest of what a root holds is excluded by the pattern below rather than by name: the
-- directories (dashboard, logs, flightlog, sim), lib/precompile.lua's stamp, an `.ini.bak` left
-- by a migration, and a `.lua.tmp` left by a save that was interrupted.
local NOT_A_STORE = {
  ["preferences.lua"] = true,
  ["preferences.ini"] = true,
  ["model_name_restore.lua"] = true,
  ["model_name_restore.ini"] = true,
  [RELOAD_REQ_FILE] = true,
}

-- Listing a directory, in the shape app/pages/settings/dashboard/lib.lua already uses for the
-- theme folders: dir() is an iterator where the firmware has one, system.listFiles is the
-- fallback, and a radio with neither is answered with nothing at all rather than with an error.
-- The shape is followed rather than shared, because that is a page module and this library is
-- loaded by the whole suite.
local function listDirectory(path)
  if type(dir) == "function" then
    local ok, iterator = pcall(dir, path)
    if not ok or type(iterator) ~= "function" then return nil end
    local entries = {}
    local walked = pcall(function()
      for name in iterator do
        entries[#entries + 1] = name
      end
    end)
    if not walked then return nil end
    return entries
  end

  if system and type(system.listFiles) == "function" then
    local ok, entries = pcall(system.listFiles, path)
    if ok and type(entries) == "table" then return entries end
    return nil
  end

  return nil
end

-- What one entry of such a listing is called, whether the firmware hands back a bare name, a
-- path, or a directory with a separator on the end.
local function entryName(entry)
  if type(entry) ~= "string" or entry == "" then return nil end
  local trimmed = string.gsub(entry, "[/\\]+$", "")
  return string.match(trimmed, "([^/\\]+)$")
end

--- The stores this card holds, without reading them. Answers { mcuId, path, root } records,
--- sorted by id and de-duplicated across user roots. It writes nothing.
---
--- WHAT IT COSTS: one directory listing per user root, with each entry matched once. A caller
--- that must stay inside a widget call lists once, then reads one record per pass with
--- readKnownModel rather than reading every store in the listing pass.
function M.listKnownModelIds()
  local out = {}

  local ids = {}
  local rootOf = {}
  local roots = orderedRoots(nil)

  for i = 1, #roots do
    local userRoot = roots[i]
    local entries = listDirectory(userRoot)
    if type(entries) == "table" then
      for j = 1, #entries do
        local entry = entryName(entries[j])
        if entry and not NOT_A_STORE[entry] then
          -- Exactly the shape normalizeMcuId produces, which is what keeps everything else in
          -- the root out without a second list to maintain.
          local id = string.match(entry, "^([%w_-]+)%.lua$")
          if id and not rootOf[id] then
            rootOf[id] = userRoot
            ids[#ids + 1] = id
          end
        end
      end
    end
  end

  -- The bare sort, as the store's own serialiser does it: the comparison happens in C, and a
  -- comparator would also make the order depend on the string-hash seed.
  table.sort(ids)

  for i = 1, #ids do
    local id = ids[i]
    out[#out + 1] = {
      mcuId = id,
      path = buildPathForRoot(rootOf[id], id),
      root = rootOf[id],
    }
  end

  return out
end

local knownModelReader = nil

--- Reads one record from listKnownModelIds, filling in its name and error and returning it.
--- A name is nil where the file carries none or it is empty. It writes nothing: recover = false
--- leaves even an interrupted save alone, and messages = {} keeps complaints in the record.
---
--- WHAT IT COSTS: one file read, one compile and one table constructor. The section-only reader
--- is created on first use and kept; no file contents are cached. A caller that must stay inside
--- a widget call reads one record per pass.
function M.readKnownModel(record)
  if not ConfigStore or type(ConfigStore.new) ~= "function" then
    record.name = nil
    return record
  end

  -- A reader of its own, declaring only the section this call reads. Two reasons, and the first
  -- is not a saving: Store:load takes the generation counter out of the file it read, so
  -- scanning every store on the card with the store that also SAVES would leave the connected
  -- board's counter standing at whatever the last file scanned happened to carry, and a reader
  -- watching that board for a change would miss the next save. The second is that merging one
  -- section is cheaper than merging all of them, per file.
  if not knownModelReader then
    knownModelReader = ConfigStore.new({
      name = "model preferences",
      schema = { [CRAFT_SECTION] = MODEL_SCHEMA[CRAFT_SECTION] },
    })
  end

  -- The complaint about a store that will not parse goes into the record rather than into the
  -- log: one line per unreadable file would bury the answer this call was made for.
  local prefs, info = knownModelReader:load(record.path, { recover = false, messages = {} })
  local section = type(prefs) == "table" and prefs[CRAFT_SECTION] or nil
  local name = type(section) == "table" and section[CRAFT_NAME_KEY] or nil
  if type(name) ~= "string" or name == "" then name = nil end
  record.name = name
  record.error = info and info.error or nil
  return record
end

--- The stores this card holds, one record per board, WITH NOTHING CONNECTED. No MCU id is
--- needed, because finding the ids is what listKnownModelIds is for.
---
--- One record per file, sorted by id:
---
---   mcuId  the board id the file is named after
---   name   what the board called itself, or nil where the file does not say
---   path   the file
---   root   the user root it was found in
---   error  why the file could not be read, where it could not be
---
--- A name of nil is the ordinary case and not an error: a store written before this release
--- carries no name, and a board that has none never gets one. Producing something to display
--- for such a record is the caller's. It writes nothing and caches no file contents.
function M.listKnownModels()
  if not ConfigStore or type(ConfigStore.new) ~= "function" then return {} end
  local out = M.listKnownModelIds()
  for i = 1, #out do
    M.readKnownModel(out[i])
  end

  return out
end

return M
