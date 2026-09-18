---
title: Custom telemetry sensors
sidebar_label: Telemetry sensors
---

# Custom telemetry sensors

Rotorflight sends most of its values in a custom frame that the radio does not understand by
itself. The suite unpacks that frame and hands each value to the radio as a telemetry sensor, so
`Vbat`, `Hspd`, `EscT` and the rest exist on the radio because something in the suite decoded
them. Which values are sent is chosen on the flight controller, on the
[Telemetry page](../pages/setup/telemetry.md); what turns them back into sensors is described
here.

Where that decoding runs — in the dashboard widget, or in the small script the suite can install
outside the widgets — is a separate subject:
[background decoder](background-decoder.md).

## Every sensor the Telemetry page offers is decoded

The page's catalogue and the decoder are kept in step deliberately: a sensor you can tick there
is one the suite can unpack. The list itself lives in the code
(`src/rfsuite/lib/rf2tlm_sensors.lua`), and that file is the authority — this page does not
repeat it, because a copy would go out of date the first time the flight controller gains a
sensor.

For the meaning of an individual value — what `Vbat` measures, what the governor states are —
see the [Rotorflight documentation](https://www.rotorflight.org/docs/); the suite does not
redefine them.

## A sensor the suite does not know stops the frame

This is the one property worth understanding, because it does not fail the way you would expect.

One frame carries several sensors packed one after another, each as an identifier followed by its
value. The decoder walks that frame from the front: it reads an identifier, looks it up, and uses
what it finds to know **how many bytes the value takes** before it can reach the next identifier.

So a sensor it does not recognise is not simply skipped. Without knowing the width, the decoder
cannot step over the value, and it stops walking the frame there. **Everything the flight
controller packed behind that sensor in the same frame is lost** — not once, but in every frame
that carries it, for as long as the sensor is selected.

What that looks like on the radio is a sensor that never appears, plus one or more *other*
sensors that also stop updating, with nothing to connect the two. Which ones depends on how the
flight controller happened to order that frame, so it can differ between models and between
flights.

**When it can happen:** running a flight controller firmware newer than your copy of the suite,
and selecting a sensor that firmware has added. The fix is to update the suite. Until then, a
workaround is to untick the unrecognised sensor on the Telemetry page, which restores everything
that was sitting behind it.

## The two counters the decoder adds

Besides the flight controller's own values, the decoder creates two sensors of its own:

| Sensor | What it counts |
| --- | --- |
| `*Cnt` | custom telemetry frames received since the model connected |
| `*Skp` | frames the radio link dropped, detected from a gap in the frame numbering |

`*Cnt` rising is the simplest confirmation that custom telemetry is arriving at all; `*Skp`
rising alongside it points at the radio link rather than at the flight controller. They are
ordinary sensors and can be deleted on the radio's own telemetry screen if you do not want the
rows — nothing in the suite depends on them being visible.

## Related

- [Telemetry page](../pages/setup/telemetry.md) — where the sensors are selected
- [Background decoder](background-decoder.md) — where the decoding runs
- [Rotorflight documentation](https://www.rotorflight.org/docs/) — what each value means

*Documented against RFSuite 0.1.7.*
