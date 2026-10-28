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

  local help_p1 = t(i18n, "help_p1", "Settings: enable logging for one line per flight on the card.")
  local help_p2 = t(i18n, "help_p2", "Minimum flight length: a flight runs from arming to disarming; a shorter arm is not logged.")
  local help_p3 = t(i18n, "help_p3",
    "Batteries: pick on the dashboard; the flight's line names the pack; its first flight counts one cycle.")
  local help_p4 = t(i18n, "help_p4",
    "All models: offer the pack for every model, else only those switched on.")
  local help_p6 = t(i18n, "help_p6",
    "New battery/Edit: full-screen form until Save or Cancel. Save rewrites only this pack's plain-text registry line; all other lines stay unchanged.")
  local help_p7 = t(i18n, "help_p7",
    "Write a flight log: after connecting, the dashboard asks for this model's pack.")
  local help_p8 = t(i18n, "help_p8",
    "Set the pack's battery profile: a dashboard choice can also set the flight controller's battery profile, never while armed.")
  local help_p9 = t(i18n, "help_p9",
    "Cells: where the flight controller keeps a cell count per profile, it must match too; 0 leaves it out and a tie sets no profile.")
  local help_id = t(i18n, "help_id",
    "Id: suggestions skip logged ids; reuse one by hand and Save reports how many flights now count under this pack.")

  local parts = { help_p1, help_p2, help_p3, help_p4, help_p6, help_p7, help_p8, help_p9, help_id }

  return {
    title = t(i18n, "help_title", "Flight Log Help"),
    message = table.concat(parts, "\n")
  }
end
