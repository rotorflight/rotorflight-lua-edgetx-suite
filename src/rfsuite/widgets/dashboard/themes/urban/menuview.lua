-- The quick menu's look, for a host with theme views (init.lua registers it under the host's own
-- id, `menu`).
--
-- The look only. What the menu offers, how it is laid out and what a press does are the host's
-- (widgets/dashboard/fullscreen_menu.lua, M.build): this hands it the theme's header, button and
-- value row through `ctx.menu`, and the words for the blackbox's fill.

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

local K = requireModule("widgets/dashboard/themes/urban/viewkit.lua") or {}
local Menu = requireModule("widgets/dashboard/fullscreen_menu.lua")

local M = {}

function M.build(children, zone, state, ctx)
  if type(K.begin) ~= "function" then return children end
  local g = K.begin(zone, state or {})
  if g == nil then return children end
  local T = K.T
  local f = K.rowFonts(g)

  return ctx.menu(children, nil, {
    frame = function(nodes)
      local top = K.header(nodes, g, T.view_menu, function() ctx.action("done") end)
      return { x = g.x + g.pad, w = g.w - 2 * g.pad, zoneW = g.w, top = top, bottom = g.y + g.h - g.pad,
               gapX = g.gap, gapY = g.gap }
    end,
    button = function(nodes, x, y, w, h, name, sub, press)
      K.button(nodes, g, f, x, y, w, h, name, sub, false, press)
    end,
    valueRow = function(nodes, x, y, w, h, name, values, press)
      K.valueRow(nodes, g, f, x, y, w, h, name, values, press)
    end,
    fillText = function(percent)
      return string.format("%s %d%%", T.blackbox, percent)
    end,
  })
end

-- The host's key, for the same reason as its own menu. The blackbox fill is read on the build only:
-- the host re-reads it after an erase, and an erase from this menu closes it.
function M.renderKey(_, state)
  if Menu == nil then return "" end
  return Menu.stateKey(state)
end

return M
