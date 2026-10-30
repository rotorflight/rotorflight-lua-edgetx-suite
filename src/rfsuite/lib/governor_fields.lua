-- Editor limits of the governor ramp times, shared by every page that edits them, and of the
-- headspeed the helicopter setup wizard edits (the range of the flight tuning Governor page). The
-- firmware stores each time in tenths of a second; seconds() shows such a value as the page does.
local M = {
  headspeed = { min = 0, max = 30000, step = 10 },
  gov_spoolup_time = { min = 0, max = 600, step = 1 },
  gov_spooldown_time = { min = 0, max = 600, step = 1 },
  gov_recovery_time = { min = 0, max = 100, step = 1 }
}
function M.seconds(v)
  return string.format("%.1fs", (tonumber(v) or 0) / 10)
end
return M
