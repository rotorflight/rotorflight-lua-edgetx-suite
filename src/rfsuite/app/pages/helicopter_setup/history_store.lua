-- Informational completion history, isolated from FC and transmitter settings.
-- One bounded record per MCU. No saved bit can satisfy a physical check.
local M = {}
local MAX = (1 << 19) - 1
local function read(path)
  local file = io.open(path, "r")
  if not file then return nil, false end
  local text = io.read(file, 64)
  io.close(file)
  -- This is a fixed Lua data record, read without compiling or running card code.
  -- A bounded read also rejects truncated, oversized and unsupported records.
  local value = type(text) == "string" and tonumber(string.match(text, "^return { version = 1, completed = (%d+) }\r?\n$"))
  if value and value >= 0 and value <= MAX and value % 1 == 0 then return value, true end
  return nil, true
end
local function location(identity, modelFile)
  if type(identity) ~= "string" or #identity > 64 or not string.match(identity, "^[%w_-]+$") then return nil end
  local root = type(modelFile) == "string" and string.match(modelFile, "^(.*)/[^/]+$")
  local directory = (root or "/SCRIPTS/TOOLS/rfsuite.user") .. "/wizard-history"
  return directory, directory .. "/" .. identity .. ".lua"
end
-- The completed-step mask of one flight controller, or 0. For the menu's done marks only.
function M.mask(identity, modelFile)
  local _, path = location(identity, modelFile)
  if not path then return 0 end
  local mask, found = read(path)
  if not found then mask = read(path .. ".tmp") end
  return mask or 0
end
function M.new(identity, modelFile)
  local h = { mask = 0, count = 0 }
  h.directory, h.path = location(identity, modelFile)
  function h:publish(mask)
    self.mask, self.count = mask, 0
    for bit = 0,18 do if (mask & (1 << bit)) ~= 0 then self.count = self.count + 1 end end
  end
  function h:load()
    if not self.path then self.invalid = true; return end
    local mask, found = read(self.path)
    if not found then mask, found = read(self.path .. ".tmp") end
    self.invalid = found and mask == nil
    self:publish(mask or 0)
  end
  function h:save(mask)
    if not self.path or (self.invalid and mask ~= 0) or type(mask) ~= "number" or
      mask < 0 or mask > MAX or mask % 1 ~= 0 then return false end
    if type(rename) ~= "function" or type(del) ~= "function" or type(mkdir) ~= "function" then return false end
    local directoryResult = mkdir(self.directory)
    if directoryResult ~= 0 and directoryResult ~= 8 then return false end
    local temporary = self.path .. ".tmp"
    local file = io.open(temporary, "w")
    if not file then return false end
    local wrote = io.write(file, "return { version = 1, completed = " .. mask .. " }\n")
    io.close(file)
    if not wrote or read(temporary) ~= mask then return false end
    local _, exists = read(self.path)
    if exists and del(self.path) ~= 0 then return false end
    if rename(temporary, self.path) ~= 0 or read(self.path) ~= mask then return false end
    self.invalid = nil
    self:publish(mask)
    return true
  end
  return h
end
return M
