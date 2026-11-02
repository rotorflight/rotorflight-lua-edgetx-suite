-- This theme's own menu (init.lua registers it as `grid_menu`), opened by a tap on the extra tile
-- of the flight view: the battery profiles and the in-flight tuning surface,
-- with what the host says about each.
--
-- Both rows are the host's quick menu records (`ctx.entry`), and every press is `ctx.run`: the
-- theme brings no work of its own. What it adds is what the host hands out about them --
--
--   * whether the tuning surface is offered now (`ctx.visible`); where it is not, the row says so
--     and binds nothing;
--   * which battery profile is in force (the option's `current`, the board's own report);
--   * what became of a profile write this menu ran (`ctx.status`): sending, done, or failed.
--
-- A profile is run with the follow-up `none` rather than the host's `done`, so the menu stays up
-- and the outcome can be read on it; the close box closes it (`closeView`), back to the flight
-- view. The tuning row keeps the host's follow-up: the surface takes the screen over this menu.

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

function M.build(children, zone, state, ctx)
  if type(K.begin) ~= "function" then return children end
  local g = K.begin(zone, state or {})
  if g == nil then return children end
  local UD, C, T = K.UD, K.C, K.T

  local contentY = K.header(children, g, T.view_tools, function() ctx.action("closeView") end)
  if type(ctx) ~= "table" or type(ctx.entry) ~= "function" then return children end

  local x, w = g.x + g.pad, g.w - 2 * g.pad
  local bottom = g.y + g.h - g.pad
  local f = K.rowFonts(g)

  -- What is drawn first, so the rows can share the room there is (K.stretch): the tuning row, a
  -- button or -- with the line saying why -- a note, then the profiles' title and their grid.
  local tuning = ctx.entry("inflight_tuning")
  local tuningOn = tuning ~= nil and ctx.visible(tuning)
  local profile = ctx.entry("battery_profile")
  if profile ~= nil and not ctx.visible(profile) then profile = nil end
  local options = (profile ~= nil and type(profile.options) == "function") and profile.options() or {}
  local cols = (#options > 4 and w >= 400) and 3 or 2
  local naturals, fixed = {}, 0
  if tuning ~= nil then naturals[1] = tuningOn and f.lineH or f.rowH end
  -- A profile's button carries the host's `detail` under its capacity where the board reports
  -- the cells and the warning voltage, so its rows need the height of two lines then.
  local profileH = f.lineH
  for i = 1, #options do
    if options[i].detail ~= nil then profileH = f.rowH end
  end
  if profile ~= nil then
    fixed = fixed + f.nameH + g.gap
    for _ = 1, math.ceil(#options / cols) do naturals[#naturals + 1] = profileH end
  end
  fixed = fixed + math.max(0, #naturals - 1) * g.gap
  local heights = K.stretch(g, bottom - contentY, fixed, naturals)

  -- The tuning surface: a button where the host offers it, a note where it does not.
  if tuning ~= nil then
    local rowH = heights[1]
    if tuningOn then
      K.button(children, g, f, x, contentY, w, rowH, tuning.title or "", nil, false,
        function() ctx.run(tuning) end)
    else
      K.unavailable(children, g, f, x, contentY, w, rowH, tuning.title or "")
    end
    contentY = contentY + rowH + g.gap
  end

  -- The battery profiles: the title with the profile in force and the outcome of the last write,
  -- then one button per profile the board carries.
  if profile == nil then return children end
  local active = nil
  for i = 1, #options do
    if options[i].current then active = options[i].id end
  end
  local lineH = f.nameH
  local title = profile.title or ""
  if active ~= nil then title = title .. "  " .. T.active .. ": " .. tostring(active) end
  local word, color = K.outcome(ctx.status("battery_profile"))
  local wordW = 0
  if word ~= nil then
    wordW = UD.textWidth(f.name, word) + g.pad
    UD.label(children, x + w - wordW, contentY, wordW, lineH, word, f.name, color, RIGHT)
  end
  UD.label(children, x, contentY, w - wordW, lineH, UD.fit(f.name, title, w - wordW), f.name, C.label, LEFT)
  contentY = contentY + lineH + g.gap

  local btnW = math.floor((w - (cols - 1) * g.gap) / cols)
  local btnH = heights[#heights] or profileH
  for i = 1, #options do
    local option = options[i]
    local by = contentY + math.floor((i - 1) / cols) * (btnH + g.gap)
    if by + btnH > bottom then break end
    local bx = x + ((i - 1) % cols) * (btnW + g.gap)
    K.button(children, g, f, bx, by, btnW, btnH, option.label, option.detail, option.current == true,
      function() ctx.run(profile, option, "none") end)
  end
  return children
end

-- Rebuilt when the profile in force moves and when the tuning surface's state appears or goes;
-- a new outcome rebuilds the view on the host's side.
function M.renderKey(_, state)
  if state == nil then return "" end
  return tostring(state.batteryProfile) .. (type(state.inflight) == "table" and "|t" or "|")
end

return M
