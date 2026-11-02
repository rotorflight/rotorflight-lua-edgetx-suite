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
  local t = Common and Common.pageT("flight_tuning_advanced_pid_controller") or function(_, _, fb) return fb end
  local i18n = ctx.i18n

  local help_p1 = t(i18n, "help_p1", "Ground Error Decay: Bleeds off accumulated error on the ground to help prevent tipping.")
  local help_inflight_decay = t(i18n, "help_inflight_decay", "Inflight Error Decay: Time sets the cyclic I-term decay time and Limit caps its decay rate.")
  local help_p2 = t(i18n, "help_p2", "Error limit: Hard limit for the angle error, and thus the I-term, on R, P and Y.")
  local help_p3 = t(i18n, "help_p3", "HSI Offset limit: Hard limit for the High Speed Integral offset angle, and thus the O-term, on R and P.")
  local help_p4 = t(i18n, "help_p4", "Error rotation: Shares accumulated error between roll and pitch during pirouettes.")
  local help_p5 = t(i18n, "help_p5", "I-term relax: Selects the axes where fast movements limit I-term accumulation.")
  local help_cutoff = t(i18n, "help_cutoff", "Cut-off point: I-term relax cutoff in Hz on R, P and Y; lower values suppress bounce-back after movements, higher values increase high-rate turn precision.")
  local help_stick_gain = t(i18n, "help_stick_gain", "Error Decay Stick Gain: the further the cyclic stick is deflected, the faster the cyclic I-term decays, on the ground and in flight; 0 = off.")
  local help_master_gain = t(i18n, "help_master_gain", "Master Gain: Cyclic scales the roll and pitch P, I, D and Offset gains together, Yaw the tail P, I and D gains, keeping their ratios; Feedforward, Boost and precomp are not scaled.")

  local parts = { help_p1, help_inflight_decay }
  local session = ctx.session or (_G.rfsuite and _G.rfsuite.session)
  local rawApiVersion = session and session.apiVersion
  
  local ApiVersion = loadModule("lib/api_version.lua")
  local showRotation = not (rawApiVersion and rawApiVersion ~= "" and tostring(rawApiVersion) ~= "0" and ApiVersion and ApiVersion.isAtLeast and ApiVersion.isAtLeast(rawApiVersion, {12, 0, 9}))
  local showStickGain = rawApiVersion and rawApiVersion ~= "" and tostring(rawApiVersion) ~= "0"
    and ApiVersion and ApiVersion.isAtLeast and ApiVersion.isAtLeast(rawApiVersion, {12, 0, 10})

  if showStickGain then
    parts[#parts + 1] = help_stick_gain
  end
  -- The same signal the page's Master Gain row goes by: the PID profile reply carried the gains.
  if session and session.hasMasterGain == true then
    parts[#parts + 1] = help_master_gain
  end
  parts[#parts + 1] = help_p2
  parts[#parts + 1] = help_p3

  if showRotation then
    parts[#parts + 1] = help_p4
  end
  parts[#parts + 1] = help_p5
  parts[#parts + 1] = help_cutoff

  return {
    title = t(i18n, "help_title", "PID Controller Help"),
    message = table.concat(parts, "\n")
  }
end
