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
  local t = Common and Common.pageT("flight_tuning_advanced_tail_rotor") or function(_, _, fb) return fb end
  local ApiVersion = loadModule("lib/api_version.lua")
  local i18n = ctx.i18n

  local help_p1 = t(i18n, "help_p1", "Yaw stop gain: Stop gain (PD) for CW and CCW rotation, typically 50-200; higher stops more crisply, too high may oscillate.")
  local help_p2 = t(i18n, "help_p2", "Precomp Cutoff: Frequency limit for all yaw precompensation actions.")
  local help_p3 = t(i18n, "help_p3", "Cyclic FF gain: Tail precompensation for cyclic inputs.")
  local help_p4 = t(i18n, "help_p4", "Collective FF gain: Tail precompensation for collective inputs.")

  local parts = { help_p1, help_p2, help_p3, help_p4 }

  local session = _G and _G.rfsuite and _G.rfsuite.session or nil
  local rawApiVersion = session and session.apiVersion
  
  local isBefore12_0_8 = false
  local isAtLeast12_0_9 = true
  if rawApiVersion and rawApiVersion ~= "" and tostring(rawApiVersion) ~= "0" then
    if ApiVersion and ApiVersion.isAtLeast then
      isBefore12_0_8 = not ApiVersion.isAtLeast(rawApiVersion, {12, 0, 8})
      isAtLeast12_0_9 = ApiVersion.isAtLeast(rawApiVersion, {12, 0, 9})
    end
  end

  if isBefore12_0_8 then
    parts[#parts + 1] = t(i18n, "help_p5", "Collective Impulse FF: Gain sets the impulse precompensation for sudden collective inputs and Decay sets its decay time.")
  else
    parts[#parts + 1] = t(i18n, "help_p7", "Inertia Precomp: Gain increases yaw precompensation for main-rotor inertia; a higher derivative Cutoff applies it more sharply.")
  end

  if isAtLeast12_0_9 then
    parts[#parts + 1] = t(i18n, "help_p6", "Tail Torque Assist: Gain (usually 50-150) raises headspeed to drive a motorized tail in the negative direction; Limit (usually 20-50%) caps the increase above full headspeed.")
  end

  return {
    title = t(i18n, "help_title", "Tail Rotor Help"),
    message = table.concat(parts, "\n")
  }
end
