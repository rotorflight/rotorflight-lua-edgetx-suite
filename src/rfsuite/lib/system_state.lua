-- Packed Rotorflight telemetry fields, matching firmware telemetry/status.h.
-- These describe observed state; neither word acknowledges an MSP write or
-- carries the complete arming-disable flags.
local M = {}
local fields = {
  system_status = {
    {"armed",0}, {"airborne",1}, {"motors_running",2}, {"rx_link_up",3},
    {"failsafe_phase",6,7}, {"gps_fix",9,3}, {"gps_healthy",11}, {"spooled_up",12},
    {"battery_state",14,7}, {"control_saturated",17}, {"gyro_overflow",18},
    {"acc_not_calibrated",19}, {"override_active",20}, {"rescue_state",21,7},
    {"blackbox_logging",24}, {"governor_state",25,15}
  },
  system_config = {
    {"pid_profile",0,7}, {"rate_profile",3,7}, {"battery_profile",6,7},
    {"unsaved_changes",12}, {"saving",13}, {"reboot_required",14}, {"beeper_on",15},
    {"acc_present",16}, {"baro_present",17}, {"mag_present",18}, {"gps_present",19},
    {"blackbox_full",21}, {"rpm_source_active",22}, {"governor_mode",23,7}
  }
}
-- Ordered definitions are shared with the diagnostic presentation.
M.fields = fields
function M.decode(source, word)
  local definitions = fields[source]
  if not definitions or type(word) ~= "number" or word < 0 or word > 0x7fffffff or word % 1 ~= 0 then return nil end
  local state = {word = word}
  for i = 1, #definitions do
    local f = definitions[i]
    local value = (word >> f[2]) & (f[3] or 1)
    if not f[3] then value = value == 1 end
    state[f[1]] = value
  end
  return state
end
function M.read(sensors, source)
  if not sensors or type(sensors.getLiveValue) ~= "function" then return nil end
  return M.decode(source, sensors.getLiveValue(source))
end
return M
