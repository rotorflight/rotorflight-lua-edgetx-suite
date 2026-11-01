local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

-- Key and fallback are both written out as literals in every call below. Their precompiler
-- rewrites a translated call only in that shape, and a fallback handed in through a variable
-- would stay English in every language with nothing anywhere reporting it.
return function(ctx)
  local Common = loadModule("app/pages/settings/common.lua")
  local t = Common and Common.pageT("tools_flight_log") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  -- One sentence for the page: every setting on it carries its own ? with the specifics.
  local message = t(i18n, "help_message",
    "Lists the flights logged on the card, their totals per model and the battery registry with its editor; each setting has its own ?.")

  return {
    title = t(i18n, "help_title", "Flight Log Help"),
    message = message
  }
end
