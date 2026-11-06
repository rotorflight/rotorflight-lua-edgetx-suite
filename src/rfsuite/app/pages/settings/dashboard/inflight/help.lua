-- The translator reaches this sheet through the house form: a `pageT` call the i18n precompiler
-- can derive a prefix from, and a wrapper named `t`, which is one of the two call names the
-- precompiler's pattern knows. A hand-rolled wrapper spelled anything else is a runtime lookup
-- only, and a packaged card carries no locale bundle, so the sheet would ship its English
-- fallbacks into a German install (#284).
local function loadModule(path)
  local fullPath = _G.rfsuite.paths.core .. "/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

return function(ctx)
  local Common = loadModule("app/pages/settings/common.lua")
  local t = Common and Common.pageT("settings_dashboard_inflight") or function(_, _, fb) return fb end
  local i18n = ctx and ctx.i18n or nil

  -- One sentence for the page. Each setting carries its own line behind the `?` on its row, and
  -- how the overlay itself is flown is the docs page's.
  return {
    message = t(i18n, "help_message",
      "Radio wiring applies to all models; Set up the model shows what it changes before writing. Shown once Settings > General > Preview is on.")
  }
end
