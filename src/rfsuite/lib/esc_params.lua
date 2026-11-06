-- Parameter transactions use the caller's transport and the existing API codecs.
-- No UI, page state or byte layout belongs here.
local M = {}
M.families = {
  [9] = { api = "esc_parameters_yge", modeField = "governor", linear = {1}, governing = {2,3},
    range = { zero = "stick_zero_us", span = "stick_range_us" },
    -- Literal i18n markers are resolved at package time, without runtime locale bundles.
    modes = {
      [0] = "@i18n(app.pages.setup_esc_motors.mode_yge_free)@",
      [1] = "@i18n(app.pages.setup_esc_motors.mode_yge_ext)@",
      [2] = "@i18n(app.pages.setup_esc_motors.mode_yge_heli)@",
      [3] = "@i18n(app.pages.setup_esc_motors.mode_yge_store)@",
      [4] = "@i18n(app.pages.setup_esc_motors.mode_yge_glider)@",
      [5] = "@i18n(app.pages.setup_esc_motors.mode_yge_air)@",
      [6] = "@i18n(app.pages.setup_esc_motors.mode_yge_f3a)@"
    } },
  [3] = { api = "esc_parameters_hw5", modeField = "flight_mode", linear = {1,0}, governing = {2,3},
    -- The API marks HW1128/HW1132 layouts through _supported, without flight_mode.
    supported = "_supported",
    modes = {
      [0] = "@i18n(app.pages.setup_esc_motors.mode_hw5_fixed)@",
      [1] = "@i18n(app.pages.setup_esc_motors.mode_hw5_linear)@",
      [2] = "@i18n(app.pages.setup_esc_motors.mode_hw5_elf)@",
      [3] = "@i18n(app.pages.setup_esc_motors.mode_hw5_store)@"
    } }
}

function M.expected(family, governorMode)
  return governorMode == 3 and family.linear or governorMode == 2 and family.governing or nil
end
function M.hasMode(family, block)
  return block ~= nil and (not family.supported or (block[family.supported] or {})[family.modeField] == true)
    and (not block._present or block._present[family.modeField] == true)
    and block[family.modeField] ~= nil
end
function M.hasRange(family, block)
  return family.range ~= nil and block ~= nil and block._present ~= nil
    and block._present[family.range.zero] == true and block._present[family.range.span] == true
end
function M.complete(family, block)
  if not block or block._complete == false then return false end
  -- HW5 already rejects short blocks and marks layouts without a mode field.
  if family.supported and (block[family.supported] or {})[family.modeField] == false then return true end
  return M.hasMode(family, block)
end
function M.matches(block, changes)
  if not block then return false end
  for key, value in pairs(changes) do if block[key] ~= value then return false end end
  return true
end

function M.new(bus, family, status)
  local s = { family = family, bus = bus }
  function s:observe(signature)
    local verdict = status.decode(signature)
    if verdict and verdict.transient and (self.changes or self.lastChanges) and not self.restart then
      self.changes, self.restart = self.changes or self.lastChanges, true
      return true
    end
  end
  function s:read(after)
    self.block = nil
    bus:add({api = family.api, optional = true, timeout = 1, maxRetries = 3, retryOnErrorReply = true,
      after = function(block, err)
        if not err and not M.complete(family, block) then err = "incomplete" end
        self.block = not err and block or nil
        after(self.block, err)
      end})
  end
  function s:verify(after, restarted)
    self:read(function(block, err)
      if self.restart and not restarted then after(block, "restart")
      elseif err then after(block, err)
      elseif not M.matches(block, self.changes or {}) then after(block, "mismatch")
      else self.changes, self.restart = nil, nil; after(block) end
    end)
  end
  -- A successful read in this visit is required even to begin a transaction.
  -- Then refresh it again: mode and range edits must never overwrite one another.
  -- prepare may persist an associated FC configuration before the ESC write.
  function s:write(changes, after, prepare)
    if not self.block then after(nil, "esc_not_read"); return false end
    if not M.complete(family, self.block) then after(nil, "incomplete"); return false end
    for key in pairs(changes) do
      if self.block._present and not self.block._present[key] then after(nil, "incomplete"); return false end
    end
    local edit = {}; for key, value in pairs(changes) do edit[key] = value end
    self:read(function(block, err)
      if err or not block then after(nil, err or "esc_not_read"); return end
      for key in pairs(edit) do
        if block._present and not block._present[key] then after(nil, "incomplete"); return end
      end
      local data = {}; for key, value in pairs(block) do data[key] = value end
      for key, value in pairs(edit) do data[key] = value end
      local function send()
        self.changes, self.lastChanges, self.restart = edit, edit, nil
        bus:add({api = family.api, write = true, data = data, optional = true,
          after = function(_, failure)
            if failure then self.block = nil; after(nil, failure); return end
            self:verify(after)
          end})
      end
      if prepare then prepare(send) else send() end
    end)
    return true
  end
  return s
end
return M
