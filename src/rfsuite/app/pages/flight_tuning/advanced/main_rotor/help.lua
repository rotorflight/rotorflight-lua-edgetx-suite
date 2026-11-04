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
  local t = Common and Common.pageT("flight_tuning_advanced_main_rotor") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local help_p1 = t(i18n, "help_p1", "Col. Pitch Comp: Compensates the nose-up tendency during collective pitch pumps.")
  local help_p2 = t(i18n, "help_p2", "Cyclic Cross coupling: Gain of the compensation that removes the roll wobble when only pitch (elevator) is applied.")
  local help_p3 = t(i18n, "help_p3", "Ratio: Sets roll-to-pitch compensation relative to pitch-to-roll compensation.")
  local help_p4 = t(i18n, "help_p4", "Cutoff: Higher frequencies make the cross-coupling compensation act faster.")

  local parts = { help_p1, help_p2, help_p3, help_p4 }

  return {
    title = t(i18n, "help_title", "Main Rotor Help"),
    message = table.concat(parts, "\n")
  }
end
