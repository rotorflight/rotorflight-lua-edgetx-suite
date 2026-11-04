-- Free-form phase module for the view after a flight: what the last one reached, kept by
-- the runtime after the link drops.

local function requireModule(path)
  if _G.rfsuite and type(_G.rfsuite.require) == "function" then
    local mod = _G.rfsuite.require(path)
    if type(mod) == "table" then return mod end
  end
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(_G.rfsuite.paths.core .. "/" .. path, mode)
  if chunk then
    local ok, mod = pcall(chunk)
    if ok and type(mod) == "table" then return mod end
  end
  return nil
end

local Layout = requireModule("widgets/dashboard/themes/deck/layout.lua") or {}

local Theme = {}

-- `ctx`: see flight.lua.
function Theme.build(zone, state, ctx)
  if type(Layout.buildStats) ~= "function" then return {} end
  return Layout.buildStats(zone, state or {}, ctx)
end

-- The readings the statistics view takes from the host's snapshot rather than from the flight
-- record: the transmitter power and the skipped packets of its bottom bar (layout.lua,
-- L.STATS_SOURCES). The host resolves only what the phase module standing names, so without this
-- the first snapshot after the disarm drops both and the two cells read "-".
function Theme.sources()
  return Layout.STATS_SOURCES or {}
end

function Theme.renderKey(zone, state)
  if type(Layout.renderKey) ~= "function" then return "deck" end
  return Layout.renderKey(zone, state)
end

return Theme
