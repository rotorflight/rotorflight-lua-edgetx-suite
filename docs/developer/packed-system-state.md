---
title: Packed system state
sidebar_label: Packed system state
---

# Packed system state

`lib/system_state.lua` decodes every defined Rotorflight `telemetry/status.h` field
of `system_status` (`STAT`) and `system_config` (`SCFG`). Call
`State.read(Sensors, source)` from a bounded wakeup pass and cache the result for
reactive properties. It returns a table or `nil` when a live word is unavailable.
Flags are booleans, enums and the three one-based profiles are integers, and `word`
retains the original integer. Reserved bits are ignored. Invalid, fractional,
negative and signed-overflow words are rejected; a live zero is valid data.

`Sensors.getLiveValue(source)` is an opt-in strict counterpart to `getValue`:
the selected sensor must have a numeric `getSourceValue` reading and its second
result must be `true`. Missing APIs, unknown quality, stopped sensors and source
errors return `nil`. Existing source aliases, duplicate-slot selection, search
throttles and the six dedicated-to-packed fallbacks remain in use. A stopped
dedicated sensor may fall back to a live packed word. Existing `getValue` readers
continue to receive held values as before.

EdgeTX's `current` status has its own timeout: a sensor can remain current for
20 seconds after its last value, and a streaming link for about one second.
This API cannot infer a shorter age from an unchanged value. It therefore supplies
informational feedback, not an acknowledgement of a configuration write or proof
that arming is disabled. `STAT` contains the armed bit, not all arming-disable flags.
Keep MSP acknowledgements and fresh arming-lock readbacks for configuration tools.

Without either sensor, callers keep their existing MSP behavior. Neither an API
version nor the presence of a sensor row proves a current reading exists. This
module does not select sensors on the flight controller or export extra sensors.

Run `lua5.3 bin/telemetry/verify_system_state.lua --self-test` for offline field,
freshness, fallback, reconnect, instruction-count and held-value negative controls.
Checked against the suite development tree and EdgeTX 2.12 source.
