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
  local t = Common and Common.pageT("flight_tuning_advanced_rescue") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local parts = {
    t(i18n, "help_intro", "Configures rescue for the active PID profile."),
    t(i18n, "help_p3", "Pull-up: collective pitch and time of the first climb before the flip or climb stage."),
    t(i18n, "help_p4", "Climb: collective pitch and time of the climb stage before hovering."),
    t(i18n, "help_p5", "Hover: collective pitch to maintain altitude after the climb."),
    t(i18n, "help_p6", "Flip: Fail time aborts rescue if the flip times out, while Exit time rate-limits collective for a smooth return to normal flight."),
    t(i18n, "help_p7", "Gains: Level and Flip set the strength of leveling and flipping upright."),
    t(i18n, "help_dynamics", "Dynamics: Rate and Accel limit roll/pitch rotation rate and acceleration.")
  }

  return {
    title = t(i18n, "help_title", "Rescue Help"),
    message = table.concat(parts, "\n")
  }
end
