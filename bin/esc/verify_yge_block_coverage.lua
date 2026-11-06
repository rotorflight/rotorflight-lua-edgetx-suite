-- An OpenYGE block says how many parameters it carries. The parse reports what the reply covers, so a
-- transaction can refuse a truncated read, and the write keeps a block of a newer ESC whole.
--   lua5.3 bin/esc/verify_yge_block_coverage.lua
local NAME = "OpenYGE block coverage"
local checks, failures = 0, 0
local function equal(actual, expected, label)
  checks = checks + 1
  if actual ~= expected then
    failures = failures + 1
    print("FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local api = assert(loadfile("src/rfsuite/tasks/msp/api/esc_parameters_yge.lua"))()
local source = api.simulatorResponse
equal(type(source), "table", "the module carries a sample reply")

local whole = api.parse(source)
equal(type(whole), "table", "a whole block parses")
equal(whole._complete, true, "a whole block is complete")
equal(whole._receivedBytes, #source, "the received length is reported")
local declared = source[3] + 256 * source[4]
equal(whole._parameterCount, declared, "the count is the block's own")

local short = {}
for i = 1, #source - 2 do short[i] = source[i] end
local cut = api.parse(short)
if cut then
  equal(cut._complete, false, "a truncated block is not complete")
end

-- A newer ESC declares more parameters than this page knows: its tail survives a write.
local longer = {}
for i, byte in ipairs(source) do longer[i] = byte end
local extra = 3
local count = declared + extra
longer[3], longer[4] = count & 255, (count >> 8) & 255
for i = 1, extra * 2 do longer[#source + i] = 200 + i end
local parsed = api.parse(longer)
equal(parsed._complete, true, "the longer block is complete")
equal(#parsed._tail >= extra * 2, true, "the unknown parameters are kept")
local written = api.buildWritePayload(parsed)
local expected = (api.mspHeaderBytes or 2) + 2 * count
equal(#written, expected, "the write is as long as the block declares")
for i = 1, extra * 2 do
  equal(written[#written - extra * 2 + i], 200 + i, "the tail byte " .. i .. " is written back")
end

print(string.format("%s: %d checks, %d failures", NAME, checks, failures))
if failures > 0 then os.exit(1) end
