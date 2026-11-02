-- Free-form phase module for the flight view, before and during a flight. init.lua names
-- this one file for both `preflight` and `inflight`: the panel reads correctly armed or not,
-- and a layout that changes under the pilot at spool-up is harder to read than one that stays.
-- The host still reloads the theme on the mode change, as it does for every theme; what it
-- reloads is the same module, cached, and the rebuild it triggers is a warm one.
--
-- The runtime takes the theme.build branch and hands the returned node list straight to
-- lvgl.build. Everything is in layout.lua; this file is the host's entry point and nothing else.

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

local Layout = requireModule("widgets/dashboard/themes/grid/layout.lua") or {}

local Theme = {}

-- `ctx` arrives on the full screen build only, from a host that lets a theme bind its own
-- controls; layout.lua then draws them. The zone build gets none and draws exactly what it did.
function Theme.build(zone, state, ctx)
  if type(Layout.buildFlight) ~= "function" then return {} end
  return Layout.buildFlight(zone, state or {}, ctx)
end

-- The telemetry this view reads that no box of this theme names -- which for a free-form theme
-- is all of it, since a free-form theme declares no boxes for the host to walk. Without this,
-- a tile showing one of the host's derived readings would find an empty snapshot and draw
-- "-" for ever.
--
-- It is a FUNCTION rather than a list because the answer depends on what the pilot put in the
-- tile slots: the host calls it once per theme load, with the state, after it has resolved this
-- theme's configuration -- so the list is built from the slots that are actually on screen.
--
-- It belongs to this module and not to the statistics one, and that is what the host makes the
-- list per phase for: the statistics view reads the frozen flight record instead, so a reading a
-- pilot put on the flight screen stops being read the moment the flight is over. The two link
-- figures of the statistics view's bottom bar are the exception, and postflight.lua names them
-- itself.
function Theme.sources(_, state)
  if type(Layout.sources) ~= "function" then return {} end
  return Layout.sources(state or {})
end

function Theme.renderKey(zone, state)
  if type(Layout.renderKey) ~= "function" then return "grid" end
  return Layout.renderKey(zone, state)
end

return Theme
