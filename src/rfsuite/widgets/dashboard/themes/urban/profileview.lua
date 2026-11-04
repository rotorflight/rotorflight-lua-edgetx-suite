-- The battery profile page's look, for a host with theme views (init.lua registers it under the
-- host's own id, `battery_profile`).
--
-- The look only. What the page offers and what each press does are the host's: the options are
-- the host's `battery_profile` record's -- one per profile the board carries, the capacity as the
-- label and the cells and warning voltage as the `detail` the host built -- and every press is
-- `ctx.run` with the follow-up `none`, so the page stays up and the outcome the host reports
-- (`ctx.status`) can be read on it. While the model is armed the profiles are drawn without a
-- press, the one in force still marked, and the host's note says why. The back box returns to the
-- quick menu (`closeView`), the close box leaves (`done`); RTN is the host page's own back.

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

local M = {}

function M.build(children, zone, state, ctx)
  if type(K.begin) ~= "function" then return children end
  local g = K.begin(zone, state or {})
  if g == nil then return children end
  local UD, C = K.UD, K.C

  local profile = (type(ctx) == "table" and type(ctx.entry) == "function") and ctx.entry("battery_profile") or nil
  local title = (profile and profile.title) or K.T.battery_profile or ""
  local contentY = K.header(children, g, title, function() ctx.action("done") end, nil,
    function() ctx.action("closeView") end)
  if profile == nil then return children end

  local x, w = g.x + g.pad, g.w - 2 * g.pad
  local bottom = g.y + g.h - g.pad
  local f = K.rowFonts(g)
  local armed = state ~= nil and state.armed == true

  -- The foot line: the host's note while armed, else the outcome of the last write from here.
  local word, color
  if armed then
    word, color = profile.armedNote, C.label
  else
    word, color = K.outcome(ctx.status("battery_profile"))
  end
  local footY = bottom - f.nameH
  if word ~= nil then
    UD.label(children, x, footY, w, f.nameH, UD.fit(f.name, word, w), f.name, color, CENTER)
  end

  -- The profiles: three columns from five up on a wide zone, so six are two rows; two below
  -- that, and one on a narrow zone. The rows share the room between the header and the foot line.
  local options = type(profile.options) == "function" and profile.options() or {}
  if #options == 0 then return children end
  local cols = 2
  if w < 200 then cols = 1 end
  if #options > 4 and w >= 400 then cols = 3 end
  local rows = math.ceil(#options / cols)
  local btnW = math.floor((w - (cols - 1) * g.gap) / cols)
  local btnH = math.floor((footY - g.gap - contentY - (rows - 1) * g.gap) / rows)
  for i = 1, #options do
    local option = options[i]
    local bx = x + ((i - 1) % cols) * (btnW + g.gap)
    local by = contentY + math.floor((i - 1) / cols) * (btnH + g.gap)
    if armed then
      K.inert(children, g, f, bx, by, btnW, btnH, option.label, option.detail, option.current == true)
    else
      K.button(children, g, f, bx, by, btnW, btnH, option.label, option.detail, option.current == true,
        function() ctx.run(profile, option, "none") end)
    end
  end
  return children
end

-- Rebuilt when the profile in force moves and when the model arms or disarms; a new outcome
-- rebuilds the page on the host's side.
function M.renderKey(_, state)
  if state == nil then return "" end
  return tostring(state.batteryProfile) .. (state.armed == true and "|a" or "|")
end

return M
