local function loadModule(path)
  local fullPath = _G.rfsuite.paths.core .. "/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local function getTableHelp(i18n, t, rType)
  if rType == 0 then return t(i18n, "help_table_0") end
  if rType == 1 then return t(i18n, "help_table_1") end
  if rType == 2 then return t(i18n, "help_table_2") end
  if rType == 3 then return t(i18n, "help_table_3") end
  if rType == 4 then return t(i18n, "help_table_4") end
  if rType == 5 then return t(i18n, "help_table_5") end
  return t(i18n, "help_table_6")
end

return function(ctx)
  local Common = loadModule("app/pages/settings/common.lua")
  local t = Common and Common.pageT("flight_tuning_rates") or function(_, k) return k end
  local i18n = ctx and ctx.i18n
  local ratesType = ctx and tonumber(ctx.ratesType) or 6

  local parts = {
    t(i18n, "help_intro"),
    getTableHelp(i18n, t, ratesType),
    t(i18n, "help_dynamics")
  }

  return {
    title = t(i18n, "help_title"),
    message = table.concat(parts, "\n\n")
  }
end
