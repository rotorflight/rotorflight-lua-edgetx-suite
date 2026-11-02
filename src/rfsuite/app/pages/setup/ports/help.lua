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
  local t = Common and Common.pageT("setup_ports") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  -- One line per control, in the order the page shows them, each starting with what the pilot
  -- sees; the reasons and the edge cases are on the documentation page.
  local parts = {
    t(i18n, "help_p1",
      "One row per serial port. Where the board layout is known, a port is named as the board prints it, with its UART name in brackets."),
    t(i18n, "help_p2",
      "Function (first list): what the port is used for. A function another port already uses is not offered."),
    t(i18n, "help_p3",
      "Baud rate (second list): only where the function has a choice; otherwise the fixed rate is shown as text."),
    t(i18n, "help_p4", "[RX]: the receiver's port. It cannot be changed here."),
    t(i18n, "help_p5",
      "Save: writes the ports you changed, restarts the flight controller and reads the ports back from it.")
  }

  return {
    title = t(i18n, "help_title", "Ports Help"),
    message = table.concat(parts, "\n")
  }
end
