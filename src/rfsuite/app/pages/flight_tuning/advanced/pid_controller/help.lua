local function loadModule(path)
  local fullPath = "/SCRIPTS/TOOLS/rfsuite-core/" .. path
  local chunk = loadScript(fullPath, "t")
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

return function(ctx)
  local Common = loadModule("app/pages/settings/common.lua")
  local t = Common and Common.pageT("flight_tuning_advanced_pid_controller") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local help_p1 = t(i18n, "help_p1", "Error decay ground: PID decay to help prevent heli from tipping over when on the ground.")
  local help_p2 = t(i18n, "help_p2", "Error limit: Angle limit for I-term.")
  local help_p3 = t(i18n, "help_p3", "Offset limit: Angle limit for High Speed Integral (O-term).")
  local help_p4 = t(i18n, "help_p4", "Error rotation: Allow errors to be shared between all axes.")
  local help_p5 = t(i18n, "help_p5", "I-term relax: Limit accumulation of I-term during fast movements - helps reduce bounce back after fast stick movements.")
  local help_stick_gain = t(i18n, "help_stick_gain", "Error Decay Stick Gain: the further the cyclic stick is deflected, the faster the cyclic I-term decays, on the ground and in flight; 0 = off.")
  local help_master_gain = t(i18n, "help_master_gain", "Master Gain: scales the cyclic P, I, D and Offset gains (Cyclic) and the tail P, I and D gains (Yaw) together, keeping their ratios. Feedforward, Boost and precomp are not scaled. A change in flight does not upset trim already held by I and Offset.")

  local parts = { help_p1 }
  local session = ctx.session or (_G.rfsuite and _G.rfsuite.session)
  local rawApiVersion = session and session.apiVersion
  
  local ApiVersion = loadModule("lib/api_version.lua")
  local showRotation = not (rawApiVersion and rawApiVersion ~= "" and tostring(rawApiVersion) ~= "0" and ApiVersion and ApiVersion.isAtLeast and ApiVersion.isAtLeast(rawApiVersion, {12, 0, 9}))
  local showStickGain = rawApiVersion and rawApiVersion ~= "" and tostring(rawApiVersion) ~= "0"
    and ApiVersion and ApiVersion.isAtLeast and ApiVersion.isAtLeast(rawApiVersion, {12, 0, 10})

  if showStickGain then
    parts[#parts + 1] = help_stick_gain
  end
  -- The master gains are not tied to an API version (rotorflight-firmware#538 did not bump it):
  -- shown when the PID profile reply carried them, the same answer the page's row goes by.
  if session and session.hasMasterGain == true then
    parts[#parts + 1] = help_master_gain
  end
  parts[#parts + 1] = help_p2
  parts[#parts + 1] = help_p3

  if showRotation then
    parts[#parts + 1] = help_p4
  end
  parts[#parts + 1] = help_p5

  return {
    title = t(i18n, "help_title", "PID Controller Help"),
    message = table.concat(parts, "\n\n")
  }
end
