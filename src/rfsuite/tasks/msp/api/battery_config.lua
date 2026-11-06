-- EdgeTX MSP API: BATTERY_CONFIG
-- Ported to EdgeTX schema (Api table + parse)

local Api = {
  command = 32, -- MSP_BATTERY_CONFIG
  writeCommand = 33, -- MSP_SET_BATTERY_CONFIG
  simulatorResponse = {
    136, 19, -- batteryCapacity
    6,      -- batteryCellCount
    1,      -- voltageMeterSource
    1,      -- currentMeterSource
    74, 1,  -- vbatmincellvoltage
    164, 1, -- vbatmaxcellvoltage
    154, 1, -- vbatfullcellvoltage
    94, 1,  -- vbatwarningcellvoltage
    100,    -- lvcPercentage
    30,     -- consumptionWarningPercentage
    232, 3,  -- batteryCapacity_0
    20, 5,   -- batteryCapacity_1
    64, 6,   -- batteryCapacity_2
    108, 7,  -- batteryCapacity_3
    152, 8,  -- batteryCapacity_4
    196, 9,  -- batteryCapacity_5
    6, 6, 6, 6, 6, 6,                               -- batteryCellCount_0..5
    74, 1, 74, 1, 74, 1, 74, 1, 74, 1, 74, 1,       -- vbatmincellvoltage_0..5
    164, 1, 164, 1, 164, 1, 164, 1, 164, 1, 164, 1, -- vbatmaxcellvoltage_0..5
    154, 1, 154, 1, 154, 1, 154, 1, 154, 1, 154, 1, -- vbatfullcellvoltage_0..5
    94, 1, 94, 1, 94, 1, 94, 1, 94, 1, 94, 1        -- vbatwarningcellvoltage_0..5
  },
}

-- Firmware with per-profile battery cells appends five blocks after the six capacities: the cell
-- count of every profile (U8 x 6), then the min, max, full and warning cell voltage of every
-- profile (U16 x 6 each), 54 bytes in all. The legacy single fields then carry the values of the
-- profile that is active when the reply is built. The blocks are recognised by the reply's length
-- rather than by the API version: MSP API 12.10 was reported by firmware builds for weeks before
-- the blocks were added, and a 12.9 board always answers 27 bytes.
local PROFILE_COUNT = 6
local PROFILE_CELL_BYTES = 6 * (1 + 4 * 2)
Api.PROFILE_CELL_FIELDS = {
  "batteryCellCount",
  "vbatmincellvoltage",
  "vbatmaxcellvoltage",
  "vbatfullcellvoltage",
  "vbatwarningcellvoltage",
}

local function parseU16(lo, hi)
  return (tonumber(hi) or 0) << 8 | (tonumber(lo) or 0)
end

function Api.parse(buf)
  if type(buf) ~= "table" or #buf < 12 then return nil end
  local idx = 1
  local batteryCapacity = parseU16(buf[idx], buf[idx+1])
  idx = idx + 2
  local batteryCellCount = buf[idx] or 0
  idx = idx + 1
  local voltageMeterSource = buf[idx] or 0
  idx = idx + 1
  local currentMeterSource = buf[idx] or 0
  idx = idx + 1
  local vbatmincellvoltage = parseU16(buf[idx], buf[idx+1])
  idx = idx + 2
  local vbatmaxcellvoltage = parseU16(buf[idx], buf[idx+1])
  idx = idx + 2
  local vbatfullcellvoltage = parseU16(buf[idx], buf[idx+1])
  idx = idx + 2
  local vbatwarningcellvoltage = parseU16(buf[idx], buf[idx+1])
  idx = idx + 2
  local lvcPercentage = buf[idx] or 0
  idx = idx + 1
  local consumptionWarningPercentage = buf[idx] or 0
  idx = idx + 1
  local out = {
    batteryCapacity = batteryCapacity,
    batteryCellCount = batteryCellCount,
    voltageMeterSource = voltageMeterSource,
    currentMeterSource = currentMeterSource,
    vbatmincellvoltage = vbatmincellvoltage,
    vbatmaxcellvoltage = vbatmaxcellvoltage,
    vbatfullcellvoltage = vbatfullcellvoltage,
    vbatwarningcellvoltage = vbatwarningcellvoltage,
    lvcPercentage = lvcPercentage,
    consumptionWarningPercentage = consumptionWarningPercentage
  }
  -- Flatten batteryCapacities: batteryCapacity_0..5
  for i = 0, 5 do
    if buf[idx] and buf[idx+1] then
      out["batteryCapacity_"..i] = parseU16(buf[idx], buf[idx+1])
      idx = idx + 2
    end
  end
  -- Per-profile cells: batteryCellCount_0..5, then vbat<min|max|full|warning>cellvoltage_0..5.
  -- The probe is ">=", so it cannot tell these five blocks from different fields a later firmware
  -- might append here, and this message carries no version byte to ask instead: a later layout
  -- needs an MSP2 command or an explicit discriminator.
  if out.batteryCapacity_5 ~= nil and #buf - idx + 1 >= PROFILE_CELL_BYTES then
    for i = 0, PROFILE_COUNT - 1 do
      out["batteryCellCount_" .. i] = buf[idx] or 0
      idx = idx + 1
    end
    for f = 2, #Api.PROFILE_CELL_FIELDS do
      local field = Api.PROFILE_CELL_FIELDS[f]
      for i = 0, PROFILE_COUNT - 1 do
        out[field .. "_" .. i] = parseU16(buf[idx], buf[idx+1])
        idx = idx + 2
      end
    end
    out.hasProfileCells = true
  end
  return out
end

function Api.buildWritePayload(data)
  local function toU16(val)
    val = math.floor(tonumber(val) or 0)
    return val & 0xFF, (val >> 8) & 0xFF
  end
  local payload = {}
  local function appendU16(val)
    local lo, hi = toU16(val)
    payload[#payload+1] = lo
    payload[#payload+1] = hi
  end
  appendU16(data.batteryCapacity)
  payload[#payload+1] = tonumber(data.batteryCellCount) or 0
  payload[#payload+1] = tonumber(data.voltageMeterSource) or 0
  payload[#payload+1] = tonumber(data.currentMeterSource) or 0
  appendU16(data.vbatmincellvoltage)
  appendU16(data.vbatmaxcellvoltage)
  appendU16(data.vbatfullcellvoltage)
  appendU16(data.vbatwarningcellvoltage)
  payload[#payload+1] = tonumber(data.lvcPercentage) or 0
  payload[#payload+1] = tonumber(data.consumptionWarningPercentage) or 0
  -- Accept the parsed flat record as well as the Power pages' array adapter. This lets
  -- transport clients round-trip every received profile without copying codec logic.
  if data.batteryCapacities or data.batteryCapacity_5 ~= nil then
    for i = 1, 6 do
      appendU16(data.batteryCapacities and data.batteryCapacities[i] or data["batteryCapacity_" .. (i - 1)])
    end
    -- Only behind the capacities: the board reads the capacities first whenever 12 bytes remain,
    -- so cell blocks sent without them would be taken for capacities. And only where the read
    -- carried them, so a board without per-profile cells never receives them.
    if data.hasProfileCells then
      for i = 0, PROFILE_COUNT - 1 do
        payload[#payload+1] = tonumber(data["batteryCellCount_" .. i]) or 0
      end
      for f = 2, #Api.PROFILE_CELL_FIELDS do
        local field = Api.PROFILE_CELL_FIELDS[f]
        for i = 0, PROFILE_COUNT - 1 do
          appendU16(data[field .. "_" .. i])
        end
      end
    end
  end
  return payload
end

return Api
