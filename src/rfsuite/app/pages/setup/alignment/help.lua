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
  local t = Common and Common.pageT("setup_alignment") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local parts = {
    t(i18n, "help_roll", "Roll: sets the board roll mounting offset."),
    t(i18n, "help_pitch", "Pitch: sets the board pitch mounting offset."),
    t(i18n, "help_yaw", "Yaw: sets the board yaw mounting offset."),
    t(i18n, "help_mag", "Mag: sets the magnetometer orientation."),
    t(i18n, "live_view_help", "Live View: follows the attitude reported by the flight controller for 60 seconds."),
    t(i18n, "help_refresh", "Refresh: reads the attitude once and redraws the model."),
    t(i18n, "auto_align_help",
      "Auto-align: hold the model level, start, then lift the tail at least 20 degrees. The result applies at once.")
  }

  return {
    title = t(i18n, "help_title", "Alignment Help"),
    message = table.concat(parts, "\n")
  }
end
