-- EdgeTX MSP API: TAIL_MOTOR_OUTPUT (MSP2_TAIL_MOTOR_OUTPUT, 0x5F14)
--
-- The tail pin (SERVO 4) drives either the tail servo or a tail motor as MOTOR 2. Request: an
-- optional U8 action -- none or 0 reads, 1 moves the pin to SERVO 4, 2 moves it to MOTOR 2, in
-- RAM until a save and reboot. Reply, two bytes:
--   U8 output: 0 servo, 1 motor, 2 both (MOTOR 2 has a pin of its own), 3 none
--   U8 result: 0 ok, 1 custom wiring left alone, 2 no main motor, 3 no timer, 4 timer shared,
--              5 invalid action, 6 no DMA
--
-- A read carries no payload, or action 0 with the message marked isWrite = false: the queue takes
-- any other payload on this command for a write. Only firmware that implements the command
-- answers it; an error reply or a short reply means it is not there.

local Api = {
  command = 0x5F14,
  writeCommand = 0x5F14,
  simulatorResponse = { 0, 0 }
}

function Api.parse(buf)
  if type(buf) ~= "table" or #buf ~= 2 or buf[1] > 3 or buf[2] > 8 then return nil end
  return { output = buf[1], result = buf[2] }
end

-- action 1 selects the servo, 2 the motor; anything else is refused (a read is the plain read).
function Api.buildWritePayload(data)
  local action = data and data.action
  if action ~= 1 and action ~= 2 then return nil end
  return { action }
end

return Api
