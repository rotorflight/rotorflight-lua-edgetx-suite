return function(w)
  local L=w.L
  w.validate=function() return w:ack("finish") end
  local function protocol(entries,value)
    for _,e in ipairs(entries) do if e[1]==value then return e[2] end end;return L.unknown
  end
  local motorProtocols,telemetryProtocols=w:motorProtocols(),w:telemetryProtocols()
  local cards = {
    w:cardDef(L.finish,L.finishHint,{
      w:value(L.swashType,function() return ({L.none,L.direct,"120","135","140","90L","90V"})[w.data.mixer_config.swash_type+1] or L.unknown end),
      w:value(L.rotorDirection,function() return w.data.mixer_config.main_rotor_dir==0 and L.clockwise or L.counterclockwise end),
      w:value(L.tailType,function() return ({L.servoTail,L.motorTail,L.bidirectional})[w.data.mixer_config.tail_rotor_mode+1] end),
      w:value(L.collectiveLimit,function() return string.format("%.1f°",w.data.mixer_input.inputs[4].max*0.012) end)
    }),
    w:cardDef(L.finish,L.finishHint,{
      w:value(L.cyclicLimit,function() return string.format("%.1f°",w.data.mixer_input.inputs[2].max*0.012) end),
      w:value(L.protocol,function() return protocol(motorProtocols,w.data.motor_config.motor_pwm_protocol) end),
      w:value(L.escTelemetry,function() return w.data.motor_config.motor_pwm_protocol==9 and "Castle Link" or protocol(telemetryProtocols,w.data.esc_sensor_config.protocol) end),
      w:value(L.governor,function()
        if (w.data.feature_config.enabledFeatures & (1<<26))==0 then return L.off end
        return ({L.off,L.limit,L.direct,L.electric,L.nitro})[w.data.governor_config.gov_mode+1] or L.unknown
      end)
    }),
    w:cardDef(L.finish,L.finishSafetyHint,{
      w:value(L.throttleType,function() return ({L.normal,L.switch,L.functionMode})[w.data.governor_config.gov_throttle_type+1] or L.unknown end),
      w:value(L.fastRpm,function() return w:fastRpm() and L.available or L.rpmMissing end),
      w:value(L.arm,function()
        for _,r in ipairs(w.data.mode_ranges.mode_ranges) do if r.id==0 and r.range.start<r.range["end"] then return L.assigned end end
        return L.armRequired
      end),
      w:check("finish",L.finalCheck)
    })
  }
  if w:analogThrottle() then
    cards[#cards+1] = w:cardDef(L.finish,L.rangeSummaryHelp,{
      w:value(L.throttleRange,function()
        return w.rangeSource == "esc_link" and L.rangeViaLink or w.rangeSource == "asserted" and L.rangeByPilot
          or w.rangeSource == "calibrated" and L.rangeCalibrated or L.unknown
      end)
    })
  end
  return cards
end
