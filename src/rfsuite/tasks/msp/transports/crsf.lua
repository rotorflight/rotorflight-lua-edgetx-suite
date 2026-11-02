local CRSF_ADDRESS_BETAFLIGHT = 0xC8
local CRSF_ADDRESS_RADIO_TRANSMITTER = 0xEA
local CRSF_FRAMETYPE_MSP_REQ = 0x7A
local CRSF_FRAMETYPE_MSP_WRITE = 0x7C
local CRSF_FRAMETYPE_MSP_RESP = 0x7B

local transport = {}
local currentFrameType = CRSF_FRAMETYPE_MSP_REQ

function transport.prepareRequest(isWrite)
  currentFrameType = isWrite == true and CRSF_FRAMETYPE_MSP_WRITE or CRSF_FRAMETYPE_MSP_REQ
end

function transport.mspSend(payload)
  local payloadOut = { CRSF_ADDRESS_BETAFLIGHT, CRSF_ADDRESS_RADIO_TRANSMITTER }
  for i = 1, #payload do
    payloadOut[i + 2] = payload[i]
  end
  return crossfireTelemetryPush(currentFrameType, payloadOut)
end

local function loadModule(path)
  local fullPath = _G.rfsuite.paths.core .. "/" .. path
  local mode = (_G.rfsuite and _G.rfsuite.loadMode) or "bt"
  local chunk = loadScript(fullPath, mode)
  if type(chunk) ~= "function" then return nil end
  local ok, mod = pcall(chunk)
  if not ok then return nil end
  return mod
end

local CrsfManager = nil

function transport.mspPoll()
  if not CrsfManager then
    CrsfManager = loadModule("lib/crsf.lua")
  end
  if not CrsfManager then return nil end

  -- Keep polling cooperative: scan only a bounded number of frames per call
  -- so the UI loop stays responsive on radios with busy telemetry streams.
  local scanned = 0
  local maxFramesPerPoll = transport.maxFramesPerPoll or 24

  while scanned < maxFramesPerPoll do
    scanned = scanned + 1
    local data = CrsfManager.popFrame(CRSF_FRAMETYPE_MSP_RESP)
    if data and data[1] == CRSF_ADDRESS_RADIO_TRANSMITTER and data[2] == CRSF_ADDRESS_BETAFLIGHT then
      local mspData = {}
      for i = 3, #data do
        mspData[i - 2] = data[i]
      end
      return mspData
    elseif data == nil then
      return nil
    end
  end

  return nil
end

transport.maxTxBufferSize = 8
transport.maxRxBufferSize = 58
transport.mspPollBudget = 0.1
transport.mspNonBlocking = true
transport.mspPollSliceSeconds = 0.004
transport.mspPollSlicePolls = 6
transport.maxFramesPerPoll = 24

return transport
