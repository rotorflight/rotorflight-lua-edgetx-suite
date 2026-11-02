-- The quick menu's look, for a host with theme views (init.lua registers it under the host's own
-- id, `menu`).
--
-- The look only. The rows are the host's quick menu -- `ctx.list("quick")`, in its order, each
-- drawn where `ctx.visible` offers it -- and every press is `ctx.run` of the host's record or
-- option, so what a row does and what follows it (leaving the menu, opening the picker, raising
-- the tuning surface) is the host's. No row is added and none is left out that the host offers.
-- The close box does what the host menu's own does: `done`.
--
-- The rows are laid out on the host's raster (viewkit.lua, K.PLACES): a button per place, in two
-- columns or one, and under them the host's BATTERY PROFILE row, which opens the host's page of
-- profiles. What the theme shows on a row is state the host hands out: how full the blackbox is
-- (`ctx.info`), and the profile in force (the record's `values`).

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

local K = requireModule("widgets/dashboard/themes/grid/viewkit.lua") or {}

local M = {}

-- The blackbox's fill as the host last read it, or nil where it has not.
local function blackboxLine(info)
  if type(info) ~= "table" then return nil end
  local used, total = K.UD.num(info.used), K.UD.num(info.total)
  if used == nil or total == nil or total <= 0 then return nil end
  return string.format("%s %d%%", K.T.blackbox, math.floor(used * 100 / total + 0.5))
end

function M.build(children, zone, state, ctx)
  if type(K.begin) ~= "function" then return children end
  local g = K.begin(zone, state or {})
  if g == nil then return children end
  local T = K.T

  local contentY = K.header(children, g, T.view_menu, function() ctx.action("done") end)
  if type(ctx) ~= "table" or type(ctx.list) ~= "function" then return children end

  local run, visible = ctx.run, ctx.visible
  local x, w = g.x + g.pad, g.w - 2 * g.pad
  local bottom = g.y + g.h - g.pad
  local f = K.rowFonts(g)

  -- The host's raster: K.PLACES places in two columns or one, rows of one height, and the
  -- BATTERY PROFILE row on the row after the raster's last.
  local cols = (g.w >= K.TWO_COLUMNS_FROM) and 2 or 1
  local rows = math.ceil(K.PLACES / cols)
  local rowH = math.floor((bottom - contentY - rows * g.gap) / (rows + 1))
  local cellW = math.floor((w - (cols - 1) * g.gap) / cols)

  local list = ctx.list("quick")
  local place = 0
  for i = 1, #list do
    local entry = list[i]
    if entry.id ~= "battery_profile" and visible(entry) then
      place = place + 1
      if place > K.PLACES then break end
      local sub = nil
      if entry.id == "erase_blackbox" and type(ctx.info) == "function" then sub = blackboxLine(ctx.info(entry)) end
      local bx = x + ((place - 1) % cols) * (cellW + g.gap)
      local by = contentY + math.floor((place - 1) / cols) * (rowH + g.gap)
      K.button(children, g, f, bx, by, cellW, rowH, entry.title or "", sub, false,
        function() run(entry) end)
    end
  end

  local profile = type(ctx.entry) == "function" and ctx.entry("battery_profile") or nil
  if profile ~= nil and visible(profile) then
    local values = type(profile.values) == "function" and profile.values() or {}
    K.valueRow(children, g, f, x, contentY + rows * (rowH + g.gap), w, rowH, profile.title or "", values,
      function() run(profile) end)
  end
  return children
end

-- Rebuilt when the profile in force moves, which the BATTERY PROFILE row names, and when the
-- board's battery configuration arrives or goes, which decides whether the row is there. The
-- blackbox fill is read on the build only: the host re-reads it after an erase, and an erase from
-- this menu closes it.
function M.renderKey(_, state)
  if state == nil then return "" end
  return tostring(state.batteryProfile) .. (state.battery_config ~= nil and "|c" or "|")
end

return M
