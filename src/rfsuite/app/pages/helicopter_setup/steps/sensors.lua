return function(w)
  local L = w.L
  local acc = (w.data.status.sensor_status & 1) ~= 0
  local calibrated
  local function calibration(d, accelerometer)
    return not accelerometer and L.unavailable or (d.arming_disable_flags & (1<<23))==0 and L.yes or L.no
  end
  w.onLive=function(api,d)
    if api=="status" then calibrated=calibration(d, acc) end
  end
  w.onLive("status",w.data.status)
  w.validate = function() return w:ack("orientation") end
  -- The firmware applies the alignment as it arrives, so the live model shows the typed angles.
  -- A confirmation given for other angles no longer holds.
  local function angle(row, key)
    local set = row.set
    row.set = function(v)
      if w.data.board_alignment_config[key] ~= v then w.checks.orientation = nil end
      set(v)
    end
    return row
  end
  local cards = {
    -- As in the Configurator's step: blades off first, then the accelerometer on a level
    -- helicopter, then the orientation with the tail lifted, then the live check.
    w:cardDef(L.sensors, L.prepare, {
      w:check("blades", L.bladesRemoved), w:check("unplugged", L.servosUnplugged)
    }, nil, "heliBladesOff"),
    w:cardDef(L.calibrateTitle, L.calibrateHint, {
      w:button(L.calibrate, function()
        if not acc or not w.checks.unplugged or not w.checks.blades then w.message = L.confirmCheck; return end
        if w.logDebug then w:log("debug", "accelerometer calibration start") end
        w:write("acc_calibration", {}, function() w.message = L.calibrating; w.calibrationAt = getTime() end)
      end, function() return acc and not w.calibrationAt end),
      w:value(L.accelerometer, function() return acc and L.available or L.unavailable end),
      w:value(L.accCalibrated, function() return calibrated end)
    }, nil, "heliLevel"),
    w:cardDef(L.orientation, L.alignHint, {
      w:button(L.autoAlign, function() w:startTrial("board_auto_align") end, function() return acc end),
      angle(w:n("board_alignment_config", "roll_degrees", L.roll, -180, 180, false, true), "roll_degrees"),
      angle(w:n("board_alignment_config", "pitch_degrees", L.pitch, -180, 180, false, true), "pitch_degrees"),
      angle(w:n("board_alignment_config", "yaw_degrees", L.yaw, -180, 180, false, true), "yaw_degrees")
    }, nil, "heliLift"),
    w:cardDef(L.checkOrientation, L.orientationHint, {
      w:check("orientation", L.directionCorrect)
    }, nil, "attitude")
  }
  -- A move between cards builds them again when the latest status would set them up differently.
  cards.stale = function()
    local now = (w.data.status.sensor_status & 1) ~= 0
    return now ~= acc or calibration(w.data.status, now) ~= calibrated
  end
  return cards
end
