-- The battery picker's look, for a host with theme views (init.lua registers it under the host's
-- own id, `battery_pick`).
--
-- The look only. What the picker offers and what each press does are the host's: the options are
-- the host's `battery_pick` record's -- one per pack, then NO BATTERY, each with the strings the
-- host already built -- and every press runs through `ctx.run`: a pick with its option, the close
-- box with the record's own `close`, handed back as the very table `ctx.entry` returned, which is
-- how the host knows it for the close. The host answers RTN with its own picker's close and
-- decides when the picker opens. The drawing is battpick.lua's.

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
local BattPick = requireModule("widgets/dashboard/themes/urban/battpick.lua") or {}

local M = {}

function M.build(children, zone, state, ctx)
  if type(K.begin) ~= "function" or type(BattPick.layout) ~= "function" then return children end
  local g = K.begin(zone, state or {})
  if g == nil then return children end
  local T = K.T

  local entry = (type(ctx) == "table" and type(ctx.entry) == "function") and ctx.entry("battery_pick") or nil
  local run = ctx and ctx.run
  local packs, none, anyCurrent = {}, nil, false
  local options = (entry ~= nil and type(entry.options) == "function") and entry.options() or {}
  for i = 1, #options do
    local option = options[i]
    local press = function() run(entry, option) end
    if option.none then
      none = { label = option.label, press = press }
    else
      if option.current then anyCurrent = true end
      -- The line under the name is this theme's own, from the registry entry the option carries;
      -- the host's `detail` stands where an option comes without one.
      local pack = option.pack
      local sub = option.detail or ""
      if type(pack) == "table" and type(BattPick.detail) == "function" then
        sub = BattPick.detail(pack.cap, pack.cycles, pack.targetProfile)
      end
      packs[#packs + 1] = { name = option.label, sub = sub, selected = option.current == true, press = press }
    end
  end
  -- NO BATTERY is the answer in force where no pack is.
  if none ~= nil then none.selected = not anyCurrent end

  local closePress
  if entry ~= nil then
    closePress = function() run(entry, entry.close) end
  else
    -- No record to run: the host's menu module did not load. The box still closes the picker.
    closePress = function() ctx.action("done") end
  end

  return BattPick.layout(children, g.w, g.h, {
    title = T.view_pick, closePress = closePress, packs = packs, none = none,
  })
end

return M
