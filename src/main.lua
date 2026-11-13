-- TNS|RFSuite|TNE
local originalLoadScript = loadScript
local chunkCache = {}
-- The kept chunks of files under app/pages/, the only ones releaseChunksUnder ever lets go: its
-- walk stays as short as a page area's own files, whatever else the cache holds.
local pageChunkPaths = {}
_G.rfsuite = _G.rfsuite or {}
_G.rfsuite.utils = _G.rfsuite.utils or {}
_G.rfsuite.utils.clearChunkCache = function()
  for k in pairs(chunkCache) do
    chunkCache[k] = nil
  end
  for k in pairs(pageChunkPaths) do
    pageChunkPaths[k] = nil
  end
  if _G.rfsuite and _G.rfsuite.clearAllModules then
    _G.rfsuite.clearAllModules()
  end
  _G.loadScript = originalLoadScript
end

-- Lets go of every kept chunk whose path starts with `prefix` and returns how many went. The page
-- registry calls it when the pilot has left the area of a page that asks for it (visitMenu in
-- app/pages/init.lua). A module instance made from such a chunk is not touched: whoever holds it
-- keeps it, and the next load of the file reads it from the card again. The tool opened from the
-- dashboard publishes the same function for its own loader (widgets/dashboard/tool_host.lua).
_G.rfsuite.utils.releaseChunksUnder = function(prefix)
  local released = 0
  if type(prefix) ~= "string" or prefix == "" then return released end
  for path in pairs(pageChunkPaths) do
    if string.sub(path, 1, #prefix) == prefix then
      pageChunkPaths[path] = nil
      chunkCache[path] = nil
      released = released + 1
    end
  end
  return released
end

-- A page's own module file. Whoever loaded it -- the page cache in app/pages/init.lua, or a
-- page that uses another page's functions -- holds the module for as long as it wants it, and
-- the chunk is not kept beyond that: kept here, the bytecode of every page ever opened would
-- stay until the tool closes. The other files under app/pages/ stay cached.
local function isPageModule(path)
  return type(path) == "string"
    and string.sub(path, -9) == "/page.lua"
    and string.find(path, "/app/pages/", 1, true) ~= nil
end

_G.loadScript = function(path, mode)
  local cached = chunkCache[path]
  if cached then
    return cached
  end
  -- lib/require.lua publishes the load mode the whole suite uses; until it has been
  -- loaded, the mode the caller asked for still applies.
  local chunk, err = originalLoadScript(path, _G.rfsuite.loadMode or mode)
  if chunk and not isPageModule(path) then
    chunkCache[path] = chunk
    if string.find(path, "/app/pages/", 1, true) then pageChunkPaths[path] = true end
  end
  return chunk, err
end

-- The wrapper above holds on to every chunk it loads except a page's own module file, which
-- is what makes loading a shared module a second time cheap; a page that has left the page
-- cache is loaded from the card again. A bulk pass over the tree wants no caching at all and
-- is given the loader that does not cache (see lib/precompile.lua).
_G.rfsuite.utils.loadScriptUncached = originalLoadScript

-- Initialize module require memoizer
local requireChunk = loadScript("/SCRIPTS/RFSUITE/core/lib/require.lua", "t")
if requireChunk then
  requireChunk()
end

-- This is the tool, and the radio runs it in the script state: a call there is yielded once it
-- has held the interpreter for one task period, never cut off at an instruction count. So this
-- is one of the two places allowed to bring a card written by an earlier release across; the
-- widgets read such a card without writing to it. Guarded because an older core has no such
-- module and the tool still has to come up.
pcall(function() return _G.rfsuite.require("lib/config_store.lua").allowMigration() end)

local chunk = assert(loadScript(_G.rfsuite.paths.core .. "/ui/home.lua", "t"))
return chunk()


