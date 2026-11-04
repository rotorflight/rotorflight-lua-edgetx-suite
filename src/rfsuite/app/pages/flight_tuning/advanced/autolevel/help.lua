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
  local t = Common and Common.pageT("flight_tuning_advanced_autolevel") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local help_p1 = t(i18n, "help_p1", "Acro trainer: Gain sets how strongly the heli returns to the angle limit when exceeded.")
  local help_trainer_limit = t(i18n, "help_trainer_limit", "Acro trainer: Max limits the roll and pitch angle without self-leveling.")
  local help_p2 = t(i18n, "help_p2", "Angle mode: Gain sets how strongly the heli returns to level.")
  local help_angle_limit = t(i18n, "help_angle_limit", "Angle mode: Max limits the roll and pitch angle.")
  local help_p3 = t(i18n, "help_p3", "Horizon mode: Gain sets how strongly the heli returns to level.")

  local parts = { help_p1, help_trainer_limit, help_p2, help_angle_limit, help_p3 }

  return {
    title = t(i18n, "help_title", "Autolevel Help"),
    message = table.concat(parts, "\n")
  }
end
