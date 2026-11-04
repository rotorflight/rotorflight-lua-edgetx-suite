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
  local t = Common and Common.pageT("setup_modes") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local help_p1 = t(i18n, "help_p1", "Ranges activate modes while AUX channels are in their windows. Save writes all changed ranges.")
  local help_p2 = t(i18n, "help_p2", "Mode: Shows ranges for a mode from the flight controller's list.\nActive ranges: Shows this mode's range count out of the controller's slots.\nRange: Each row sets AUX (AUTO: move a switch to detect its channel), OR/AND with other ranges and Start/End in us; + Add adds a range, X deletes it.\nSet: Uses the current channel position +/-50 us as the window after confirmation.")

  local parts = { help_p1, help_p2 }

  return {
    title = t(i18n, "help_title", "Modes Help"),
    message = table.concat(parts, "\n")
  }
end
