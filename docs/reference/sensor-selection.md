---
title: How a value finds its telemetry sensor
sidebar_label: Sensor selection
---

# How a value finds its telemetry sensor

The suite asks for values by what they are -- fuel, voltage, headspeed, current, link quality --
and the radio holds telemetry sensors with four-character names. This page is what sits between
the two: how a value is matched to one of the model's sensors, how long that choice lasts, and
why a sensor the radio is not receiving is not taken for a reading.

It applies everywhere a telemetry value is used: the dashboard widget, the audio announcements,
the flight log and the flight record.

## While the suite decodes the telemetry itself

The flight controller's own values arrive in Rotorflight's custom telemetry frames, and a part of
the suite decodes them: the [background decoder](background-decoder.md) when the model runs it,
otherwise the dashboard's script, or the tool started from the radio's *Tools* menu while it is
open. Whichever part decodes, it publishes every value as a radio sensor, so the radio's telemetry
page, alarms, logical switches and SD log keep working as before.

**The part that decodes reads its own values straight from its decoder.** When the dashboard or
the tool decodes for itself, a value of the custom telemetry -- voltage, current, headspeed, the
profiles, the arming state, the temperatures and the rest -- comes from what the decoder took from
the last frame, not from the radio's sensor of that name. It therefore does not depend on the
radio having discovered that sensor, and a sensor of the same name that some other source created
cannot stand in for it. While the background decoder runs, the dashboard reads the radio's sensors,
because its values are in the background decoder's script, not in the dashboard's.

**Such a value is the flight controller's, as it sends it.** The radio applies the settings of
its own telemetry page -- ratio, offset, filter, a changed unit or number of decimals, a headspeed
multiplier -- when it stores a value in its sensor, and a value read from the decoder has none of
them. Calibrate a value in the flight controller; a correction made on the radio's sensor page
shows on the radio's own screens, its alarms and its SD log, and in the dashboard only while the
background decoder runs.

Not from the decoder, and searched for as described below: a value the flight controller does not
send (the next name on the list answers, as before), a value whose list starts with a sensor that
is not part of the custom telemetry -- smart fuel, which the suite computes itself, or the link
statistics -- and the values that come as a group, such as the cells, the attitude or the GPS
position. After the link is lost the sensors are read until the decoder has taken new frames.

## Choosing a sensor

Each value has a list of sensor names, most preferred first -- fuel is looked for as `Bat%`,
then `Fuel`, then `fuel`. The list is tried in order and the first name the radio is receiving
is taken. That choice is then remembered, so later passes read the chosen sensor directly instead
of searching again.

Where a value has been matched to something other than the first name on its list, the first name
is re-tried every few seconds, and the value moves back to it as soon as it is arriving.
That covers a sensor which appears late -- the flight controller's own values arrive a moment
after the link comes up, and two of them the suite publishes itself.

A value the model carries no sensor for at all -- no altimeter, no BEC voltage, no ESC
temperature -- would otherwise be searched for on every pass, for the whole flight. Those searches
are spaced out instead: the first retry comes after about two seconds and the wait doubles up to
half a minute. A value whose sensor the model does carry but the radio is not receiving at the
moment -- the link is down, or the flight controller has stopped sending -- stays on the two-second
retry, so it is picked up again within about two seconds of coming back.

## Asking for a sensor by its own name

Everything above is about the suite's own values, each with a list of names behind it. A name
that is not one of those -- a flight controller sensor the suite has no value for, or one of the
link statistics -- is read straight from the model's sensor of that name, and the same spacing
applies: a name the model carries no sensor for is retried after about two seconds and then less
and less often, not on every pass.

Two things come with that.

**The session minimum and maximum.** The radio keeps the lowest and the highest reading of every
sensor, and offers them under the sensor's name with a trailing `-` or `+`: `Hspd+` is the
highest headspeed, `RQly-` the worst link quality. They are the radio's figures rather than the
suite's, so they cover everything received since the radio last reset telemetry -- when the model
was loaded, when the radio was switched on, or on *Reset Telemetry* -- and not one flight.
[Flight statistics](flight-statistics.md) are the per-flight ones. One oddity is worth knowing:
on a **voltage** sensor the radio resets the minimum whenever a new maximum arrives, on the
assumption that a higher voltage means a fresh battery. A minimum or maximum stays a valid figure
after its sensor has stopped arriving, so it is taken whenever the sensor has arrived at all since
that reset.

**The link statistics are the radio's sensors, not the flight controller's.** The CRSF driver
creates them from the link frames themselves, so they are there on every model flown on a
Crossfire or ELRS link, whether or not a flight controller is answering:

| Name | Unit | What it is |
| --- | --- | --- |
| `1RSS`, `2RSS` | dBm | Signal strength at the receiver, per antenna. |
| `RQly` | % | Link quality up to the aircraft -- the share of packets that arrived. |
| `RSNR` | dB | Signal-to-noise ratio at the receiver. |
| `ANT` | — | Which receiver antenna is active. |
| `RFMD` | — | The RF mode, as the module's own number. |
| `TPWR` | mW | Transmit power the module is using. |
| `TRSS` | dBm | Signal strength of the downlink, at the radio. |
| `TQly` | % | Link quality down from the aircraft. |
| `TSNR` | dB | Signal-to-noise ratio at the radio. |
| `RRSP`, `TRSP` | % | The two signal strengths again as percentages, where the module sends them. |
| `RPWR` | dBm | The receiver's transmit power, where the module sends it. |
| `TFPS` | Hz | Downlink frame rate, where the module sends it. |

Which of them a model actually has is the module's decision and not the suite's; the last four
come from extended frames that only some modules send. The units are those of EdgeTX 2.12.3 and
later; 2.12.2 and earlier declared the three signal strengths in dB. The flight controller's own
custom sensors are a separate set and are described under
[telemetry sensors](telemetry-sensors.md).

## Why a sensor the radio is not receiving is not taken for a reading

A model keeps the sensors it has ever seen. Load a model that flew with a sensor the radio is no
longer receiving -- the value was switched off in the flight controller's telemetry set, an ESC
that is not on the bus today, a receiver that has not been powered up -- and the row is still
there in *Model* -> *Telemetry*, with nothing to say it is stale.

Asked for such a row, the radio answers **zero**, not "no value". A sensor that did arrive and then
stopped -- an ESC that dropped off the bus, a value switched off in the flight controller -- keeps
answering its **last value** for as long as the model stays loaded, and while the link is down
every sensor answers zero. Each of those is a plausible reading, so a dead row can be mistaken for
a working sensor. For fuel that is the number the SmartFuel calculation publishes, the callouts
speak and the flight log records.

The suite therefore asks the radio, before it takes a sensor for a value, whether that sensor is
still arriving -- whatever it reads, zero or not. A row that has never arrived, or that has stopped
arriving, is treated as missing, and the next name on the list is tried.

**What that question can and cannot separate.** The radio keeps a timeout for every sensor: a
sensor counts as stopped once nothing has arrived for it for **20 seconds** -- the same timeout
behind the radio's *Sensor lost* announcement -- and every sensor counts as stopped about a second
after the link drops, until its next value arrives. Within those 20 seconds a sensor that has
just fallen silent cannot be told from one that is still arriving; that is the radio's resolution,
not something the suite can see behind. The suite's own decoder passes an unchanged value on again
at least every two seconds while frames carrying it arrive, so a value that simply holds still -- a
profile number, 0 A on the ground -- never reads as stopped.

The question is asked when a value is matched to a sensor, not on every read after that. A sensor
that stops **after** it was matched keeps its last reading until the choice is made again (below).

One case is narrowed rather than closed: a script that writes a sensor row before anything has
arrived makes it look like an arriving sensor for those 20 seconds. The suite does not do that
itself, but Rotorflight's RFTool background script, on a model that carries it, writes a zero into
every sensor the flight controller is configured to send as soon as it connects. Such a row is
taken if a value is matched to it within 20 seconds of that, and refused after.

## What you will see

- **The fuel callout** says nothing for a fuel row the radio is not receiving, where it used to
  announce 0 %, or the last percentage of a fuel sensor that had stopped.
- **The flight log** leaves its minimum-fuel columns empty for such a flight instead of filling
  them with a value that was never measured.
- **A value with a second sensor that is arriving** is matched to that one rather than to a first
  one that has stopped.
- **The dashboard** still shows `0` for a value with no sensor behind it: every telemetry value it
  keeps starts at zero and is only overwritten by a reading that arrived. A sensor that had already
  stopped when the dashboard matched its values is now treated the same way, where its last value
  used to be shown. Making those tiles show `--` is a separate gate and this is not it.

## When two sensors have the same name

A sensor name is not unique on the radio. The case that happens: the native CRSF battery frame
creates `RxBt`, `Curr`, `Capa` and `Bat%`, and a model whose sensors were discovered while the
flight controller was still on its default native telemetry keeps those four after it is switched
to custom telemetry -- above the flight controller's own `Curr`, `Capa` and `Bat%` in *Model* ->
*Telemetry*. Asked for a name, the radio answers with the **first** sensor of that name, so fuel,
current and consumption would come from the native rows, which no longer receive anything: no
value at all, or the last one they received, frozen.

So where a name is carried by more than one sensor, the suite reads the one the radio is receiving:
the first of them, in the order of *Model* -> *Telemetry*, that the radio counts as current; if
none is, the first that has received anything since the model was loaded. The radio counts a
sensor as current until about 20 seconds after its last value, and none once the link has stopped.
The choice is made on every read, so it follows the radio: when the native rows stop being current,
the values move to the flight controller's rows by themselves.

- **The first sensor wins while both are current**, so a model on native telemetry reads the native
  rows, as it always did -- and for up to 20 seconds after the native rows last received something.
- **Only a model that carries `RxBt` is looked at.** `RxBt` is the radio's own receiver battery
  sensor, which the native telemetry creates and the suite never does. On such a model the suite
  lists the model's sensors about two seconds after each connection, and again when a search meets
  a sensor that has never received anything while one has been added since; a model without
  `RxBt` reads every name as before.
- **A sensor added after that list is noticed by a search.** On a model that meets custom
  telemetry for the first time while the native rows still hold a value -- the telemetry mode
  changed with the radio left on -- the values stay on the native rows until the next connection.
- The **session minimum and maximum** (`Curr+`, `Bat%-`) follow the same sensor.

Deleting the native rows in *Model* -> *Telemetry* removes the question altogether.

The [validate sensors](../pages/tools/diagnostics/validate_sensors.md) page is not part of this: it
asks the radio for each name itself and grades the first sensor of that name.

## When the choice is made again

The sensor chosen for a value is forgotten in three places, and it is worth knowing which,
because they are not the same event:

- **The dashboard widget** forgets the choice on its own link edges, so a session that begins
  after a reconnect matches everything again from the top of its list. That matching is spread
  over the first few reads -- normally no more than four values start their search in one pass,
  and the arming state is not held back -- so after a reconnect the dashboard's values appear
  over about two seconds rather than all on the first read, and somewhat later where other
  readers in the same pass start searches of their own. The same applies when the widget starts.
- **The configuration tool** forgets the choice once, on the audio tick where it stops
  considering the connection ready -- no link quality, no battery reading, or no flight
  controller answering. While it waits it keeps reading link quality, voltage and fuel on every
  audio tick (five times a second); a sensor the model carries is searched for on the
  two-second retry described above, so it is found again within about two seconds of the link
  coming back. Once it is ready, the choice stays until that test fails again.
- **The radio's own telemetry reset** -- which happens when a model is loaded, when the radio is
  switched on, and on *Reset Telemetry* -- puts the sensor rows themselves back to "never
  received".

A link that drops does not reset the rows, but it makes every one of them count as stopped until
its next value arrives, so a value matched while the link is down finds nothing and is searched
for again. A sensor that stopped in the middle of a session is refused the next time the choice is
made. So a model flown with a different ESC, or with a value switched off since, picks up the
right sensor at the next match rather than only when the model is next loaded.

## Related

- [No connection to the flight controller](../troubleshooting/no-connection.md) -- when nothing
  off the flight controller is shown at all, rather than one value.
- [Collecting logs](../troubleshooting/collecting-logs.md) -- the suite's log names the sensor
  each value was matched to when the log level is raised -- when it is matched, not on every read.
- [Flight statistics](flight-statistics.md) -- what the flight record keeps, and which values it
  reads through this layer.
