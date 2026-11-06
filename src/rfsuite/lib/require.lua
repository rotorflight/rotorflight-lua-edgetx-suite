-- lib/require.lua
-- Module and singleton memoizer for EdgeTX RFSuite.
--
-- Prevents repeated disk reads, bytecode compilation, and redundant
-- module execution of shared libraries and singletons across the suite.

_G.rfsuite = _G.rfsuite or {}
_G.rfsuite.modules = _G.rfsuite.modules or {}

-- Load mode for every script the suite loads.
--
-- "b" is what lets EdgeTX read back the .luac beside a source once that bytecode is the newer
-- of the two, which is the point of having compiled it at all; "t" is the fallback for a
-- source that has no bytecode yet, and compiling it writes the .luac for the next start.
-- lib/precompile.lua fills the tree in at start time so that first compile does not fall on
-- the first page that happens to need it.
--
-- The tool replaces _G.loadScript with a wrapper that substitutes this for whatever mode a
-- caller passed (src/main.lua). A widget state has no such wrapper -- _G there is shared with
-- every other widget on the radio, so the suite does not own that function -- and neither has
-- the special-function state. A call site those states reach therefore has to name this mode
-- itself, or the bytecode beside the source is never read.
_G.rfsuite.loadMode = "bt"

-- The loader lib/precompile.lua compiles through, which must not keep what it loads. The tool
-- has set it by now (src/main.lua, the function its caching wrapper replaced). A widget state
-- reaches this file first from a widget's create, before the tool can be opened from the
-- dashboard and put a caching wrapper over _G.loadScript, so what is there now is the radio's
-- own. Never replaced once set, so a later load of this file cannot pick up such a wrapper.
_G.rfsuite.utils = _G.rfsuite.utils or {}
if _G.rfsuite.utils.loadScriptUncached == nil then
  _G.rfsuite.utils.loadScriptUncached = loadScript
end

-- The card roots every module builds its paths from (lib/paths.lua). Every Lua state of the
-- suite -- the tool, both widgets and the special-function script -- loads this file before any
-- other module of the suite, so the table is there by the time one reads it. This load, and the
-- files that load this one, are the places that still name the code root themselves.
_G.rfsuite.paths = _G.rfsuite.paths
  or assert(loadScript("/SCRIPTS/RFSUITE/core/lib/paths.lua", _G.rfsuite.loadMode))()

-- A card updated by unpacking the archive still has the pilot's data in the old folder, and that
-- folder counts until the data has been copied and the marker written (lib/user_move.lua). Decided
-- once per Lua state, so a state keeps one folder for as long as it runs: its modules hold on to
-- the path they read when they loaded. A card with no old folder pays one fstat, and a card already
-- moved pays two.
do
  local paths = _G.rfsuite.paths
  if paths.legacyUser and paths.moveDecided == nil and type(fstat) == "function" then
    paths.moveDecided = true
    if fstat(paths.legacyUser) ~= nil and fstat(paths.user .. "/moved.txt") == nil then
      paths.moveTo = paths.user
      paths.user = paths.legacyUser
    end
  end
end

local BASE_PATH = _G.rfsuite.paths.core .. "/"

local modules = _G.rfsuite.modules

local function normalizePath(path)
  if type(path) ~= "string" or path == "" then
    return path
  end
  if string.sub(path, 1, #BASE_PATH) == BASE_PATH then
    return path
  end
  if string.sub(path, 1, 1) == "/" then
    return path
  end
  return BASE_PATH .. path
end

local function requireModule(path, forceReload)
  local fullPath = normalizePath(path)
  if not fullPath then return nil end

  if not forceReload and modules[fullPath] ~= nil then
    return modules[fullPath]
  end

  -- What each module costs, for a log read at debug. Asked once per load; a load already takes far
  -- longer than the question. A module that loads others carries theirs in its figure.
  local Logger = _G.rfsuite and _G.rfsuite.Log
  local luaBefore = nil
  if type(Logger) == "table" and type(Logger.wanted) == "function" and Logger.wanted("debug") then
    luaBefore = math.floor(collectgarbage("count") + 0.5)
  end

  local chunk, err = loadScript(fullPath, _G.rfsuite.loadMode)
  if not chunk then
    if type(err) == "string" then
      -- Raw print on purpose, here and below: this is the module loader reporting that a
      -- load failed, and the logger may be the very module that could not load.
      print("[require] Failed to load " .. tostring(fullPath) .. ": " .. err)
      local Log = _G.rfsuite and _G.rfsuite.Log
      local said = _G.rfsuite
      if type(Log) == "table" and type(Log.emit) == "function" and said then
        -- Once per file, as a caller may ask again every pass and the ring holds sixty lines. The
        -- console opted out: the line above already went there.
        said.requireFailures = said.requireFailures or {}
        if not said.requireFailures[fullPath] then
          said.requireFailures[fullPath] = true
          pcall(Log.emit, "rfsuite.require", "failed to load " .. tostring(fullPath) .. ": " .. err, "error", false)
        end
      end
    end
    return nil, err
  end

  local ok, result = pcall(chunk)
  if not ok then
    print("[require] Error executing " .. tostring(fullPath) .. ": " .. tostring(result))
    local Log = _G.rfsuite and _G.rfsuite.Log
    if type(Log) == "table" and type(Log.emit) == "function" then
      pcall(Log.emit, "rfsuite.require", "error executing " .. tostring(fullPath) .. ": " .. tostring(result), "error", false)
    end
    return nil, result
  end

  -- A module that returns nothing hands out nothing and is not cached, the same as a load that
  -- failed. Callers take a falsy result as "not available" (`rfsuite.require(path) or false`,
  -- then `if not mod`), the answer every loadScript fallback beside them gives for such a chunk;
  -- a cached `true` would pass that test and be indexed as the module table. Such a module runs
  -- again on every load, so a module that has to run once returns its table. Storing the nil also
  -- drops what a forced reload of a module that used to return a table left in the cache.
  modules[fullPath] = result

  if luaBefore then
    pcall(Logger.emitf, "rfsuite.require", "debug", "loaded %s, lua %d -> %d kB", tostring(fullPath), luaBefore,
      math.floor(collectgarbage("count") + 0.5))
  end

  return result
end

local function clearModule(path)
  local fullPath = normalizePath(path)
  if fullPath then
    local Logger = _G.rfsuite and _G.rfsuite.Log
    if modules[fullPath] ~= nil and type(Logger) == "table" and type(Logger.emitf) == "function" then
      pcall(Logger.emitf, "rfsuite.require", "debug", "released %s", tostring(fullPath))
    end
    modules[fullPath] = nil
  end
end

local function clearAllModules()
  for k in pairs(modules) do
    modules[k] = nil
  end
end

_G.rfsuite.require = requireModule
_G.rfsuite.clearModule = clearModule
_G.rfsuite.clearAllModules = clearAllModules

return requireModule
