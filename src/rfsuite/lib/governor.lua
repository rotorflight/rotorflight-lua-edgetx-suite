local M = {}

-- Keep the stored mode while the feature is unknown, including a failed feature read.
function M.getEffectiveMode(session)
  if not session then return nil end
  if session.governorFeature == false then return 0 end
  return session.governorMode
end

return M
