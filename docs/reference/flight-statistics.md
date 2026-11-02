# Flight statistics

The suite records the extremes of each flight — the highest headspeed, the lowest pack voltage, the
warmest ESC and so on — together with how long the flight was armed. This page says where that
record lives, who keeps it, and what each field means.

## Where it lives

The record is published under `rfsuite.session.flight`, in the Lua state the suite's widgets run
in, and is readable by anything else in that state.

```lua
rfsuite.session.flight = {
  current      = { maxRpm = 2050, minVoltage = 22.4, ... },  -- the flight in progress
  last         = { maxRpm = 2210, minVoltage = 21.9, ... },  -- the flight before it
  seconds      = 128.4,   -- armed seconds of the flight in progress
  lastSeconds  = 301.2,   -- armed seconds of the flight that ended
  flights      = 37,      -- flights the flight controller counts
  totalSeconds = 44210,   -- armed seconds the flight controller counts, plus the live flight
  armed        = true,    -- whether a record is open
}
```

A key of `current` or `last` is **absent until that statistic has taken a value**, so a reader asks
`current[key]` first and falls back to `last[key]`. Statistic text boxes and gauges' maxima use
`Utils.statFromRecord`: while armed, an absent statistic shows no value. Urban, Grid and Deck's
own telemetry, link and battery views still fall back to the previous flight. The keys are:

| key | from | recorded |
|---|---|---|
| `maxThrottlePercent` | throttle % | maximum |
| `maxRpm`, `minRpm` | headspeed | maximum of any reading; minimum only while the rotor is powered (below) and above zero |
| `maxCurrent`, `minCurrent` | current | maximum of any reading; minimum only while the rotor is powered (below) |
| `maxWatts` | power, measured or voltage × current | maximum |
| `maxAltitude` | altitude | maximum |
| `maxEscTemp` | ESC temperature | maximum |
| `maxMcuTemp` | MCU temperature | maximum |
| `minFuel` | smart fuel, else fuel | minimum, and only once a fuel sensor has answered in this flight |
| `maxVoltage`, `minVoltage` | pack voltage | both, above zero only |
| `minBecVoltage` | BEC voltage | minimum, above zero only |
| `maxLq`, `minLq` | link quality | both, and only for a 0–100 % reading from a sensor that is not a known RSSI source — a receiver without an RQly sensor falls back to 1RSS/2RSS, which carry dBm |
| `sagCount` | pack voltage | how many voltage sags the flight had (below). `0` where the pack was watched and nothing happened; absent where it could not be watched |
| `minSagCellVoltage` | pack voltage | the deepest per-cell voltage reached inside a sag; absent where there was none |
| `maxRpmP1`, `minRpmP1` … `maxRpmP3`, `minRpmP3` | headspeed | both, per PID profile, and only while the rotor is powered (below) |

## Voltage sags

A pack that dips under load and comes back is a different thing from a pack that ends the flight
low, and the second is already `minVoltage`. `sagCount` counts the first.

* The line is the flight controller's own **minimum cell voltage** (*Setup* → *Power* → *Battery*
  → *Min cell voltage*), multiplied by the cell count. A reading **at or below** it opens an
  episode.
* An episode ends when the pack is back **0.05 V per cell above** the line. Without that
  hysteresis a helicopter hovering with its pack on the line produces one episode per sample
  instead of the one the pilot would recognise.
* A pack reading **at or below 1 V** is the main power gone rather than a sag. Nothing is counted
  for it and an episode open across it is dropped.
* `minSagCellVoltage` is the deepest per-cell voltage seen inside an episode.

The cell count is the flight controller's own where it has one; a configured count of zero means
the board detects it itself, and then telemetry answers instead. Where neither answers, or where
the board has not reported a minimum cell voltage, **nothing is judged**: `sagCount` is absent
rather than `0`, which is how a reader tells "watched, none" from "could not watch".

**The resolution is the sampling interval.** The statistics are read every 0.5 s, so a dip
shorter than that can fall between two samples and be missed entirely, and the deepest voltage is
the deepest *sampled* voltage rather than the deepest the pack reached.

## When a minimum is taken: the rotor has to be under power

A pilot arms first and spools up afterwards, so the first readings inside an armed window are the
lowest ones that window will ever carry — and on a minimum tracked across the whole window they
stay the minimum for the rest of the flight. The lowest headspeed then comes from the spool-up or
the spool-down rather than from the flight, and the lowest current is the current at arming, which
is in practice zero.

**`minRpm` and `minCurrent` are therefore taken only while the rotor is under power.** The maxima
beside them keep the whole armed window on purpose: nothing about a ramp can raise them. The
headspeed band kept per PID profile uses the same gate on both of its ends (below).

The flight controller's own **governor state** is what says the rotor is under power, and two of
its states qualify:

| state | |
|---|---|
| `ACTIVE` | the governor is holding the requested headspeed |
| `BYPASS` | the governor is bypassed and the throttle curve drives the head directly |

Every other state is a ramp or is not driving the head — throttle off, throttle idle, spool-up,
recovery, throttle hold, autorotation and bailout all carry a headspeed or a current below
anything the flight holds. `FALLBACK` is left out for a different reason: the flight controller
enters it when the motor rpm signal has failed, so a headspeed sampled there is not a headspeed.

The gate has to **hold for 2 s** — four samples — before a minimum is taken. The flight controller
enters `ACTIVE` at 99 % of the requested headspeed, so the readings behind the transition are
already flight readings; the wait is what keeps a single sample taken on the edge of one out of
them.

### Where there is no governor state

The governor state is only maintained for the governor modes that run a governor state machine.
With the governor **off**, or **limiting the throttle only**, the flight controller leaves the
state at the value it started with and it never moves — and a model whose receiver is not sending
the governor state sensor at all reads nothing. On those models a gate on the state alone would
take no minimum for the whole flight.

So the state is trusted only once a value inside its own range has been seen in this flight. Until
then the gate is the reading a model without a governor still has:

* headspeed at or above **100 rpm**, and
* throttle at or above **25 %**, or current at or above **1.5 A**.

The second line is the rule the suite already applies to the same question when it draws a logged
flight (`app/pages/logs/graph.lua`); the headspeed threshold is added here.

**Without a governor state the gate is held on its way out as well.** A reading is taken only once
the gate has also held for **another 2 s after it**, so the last 2 s of a driven stretch never
count. The head can slow before the current falls — at the start of a spool-down, or a head bogging
under load — and as long as current is still drawn such a reading passes the gate; only the wait
after it tells it from flight. Two things follow on such a model: a driven stretch shorter than
4 s leaves no minimum at all, and a low reading inside the last 2 s before the gate closes is not
taken either.

The governor state needs none of this. The flight controller leaves `ACTIVE` and `BYPASS` on the
throttle input itself — the throttle cut, or the throttle falling below the handover point — and
the headspeed only falls after that, so the reading that ends a powered stretch is already outside
the gate. A headspeed that falls while the governor stays `ACTIVE` is the governor holding under
load, which is a flight reading.

**Its limit, said plainly:** without a governor state there is nothing that says the head has
*settled*, only that it is turning and something is driving it. A slow spool-up can therefore
still put its own low reading into the minimum on such a model; the 2 s wait on the way in clips
the tail of that band and not the whole of it.

## Headspeed per PID profile

A pilot flies a PID profile per flying style, so the headspeed band of a flight is up to three
bands rather than one. `maxRpmP1`/`minRpmP1` to `maxRpmP3`/`minRpmP3` are those bands, taken from
the PID profile the flight controller reports while the reading is being sampled.

Three, because that is what the flight log's columns carry. A flight controller with more than
256 kB of flash offers six PID profiles; a reading taken on profile 4, 5 or 6 goes into the
overall `maxRpm` and `minRpm` like any other reading, and into no per-profile key.

**Both ends are gated on the rotor being powered**, not only the minimum: the pair says what the
head was held at under that profile, and a reading taken while the governor was not holding it
belongs to no profile in particular. The gate is the one above, unchanged — the governor state
where there is one, and where there is not, the fallback with its wait on both sides of a reading.
On that fallback path a reading is booked to the PID profile it was read on, not to the one the
flight controller reports once the wait after it has passed.

## Who keeps it

Whichever widget of the suite is running the background work: the dashboard widget, or — on a model
that does not use the dashboard — the service widget, which exists to run the runtimes and publish
the MSP surface for other widgets. The record is kept by the event runtimes rather than by a
screen, so **a model with no dashboard placed still records its flights**, and a dashboard placed
afterwards shows the last one.

On a model that carries both widgets, the dashboard keeps the record and the service widget stands
down, so the record is never driven twice. If the dashboard stops driving — taken off the model, or
held up for more than half a second — the service widget takes over within about 0.6 s, inside the
one-second step below, so the flight clock is credited the whole gap.

The statistics are sampled every 0.5 s while a flight is running. The flight clock advances on
every wakeup, so a flight's duration does not depend on how often the statistics are sampled, and
a single step of that clock is capped at one second — a widget can be suspended for a whole tool
session, and the wakeup after that must not credit the flight with all of it.

**Nothing is sampled while the telemetry link is down.** Once the link has not streamed for a
second, EdgeTX answers every telemetry value with 0, and a 0 there is not a reading: the lowest
ESC temperature, which has no gate of its own, would take it as the flight's minimum. The record
skips its samples for as long as the link is not streaming and takes the next one as soon as it
is back; the flight clock keeps running through the gap, since the flight does. A gap long enough
for the link to count as lost — down for 2 s, about 3 s after the last frame — is a different case,
described below: while the craft is armed the flight is kept, and it goes on if the craft is still
armed when the link comes back.

## The readings a sampling pass offers, once

The record runs from the event runtimes, and a widget drives those at the top of its own pass —
before it reads any telemetry for itself. So on a pass where the record samples, it asks the
sensors first and the dashboard then asks for most of the same names a second time. A second read
inside one pass cannot answer anything the first did not: a pass runs to completion without
yielding, so a telemetry value does not move inside it.

The record therefore offers what it has just read, and the dashboard takes it instead of asking
again:

```lua
rfsuite.session.telemetryRead = {
  values = { rpm = 2050, voltage = 22.4, ... },  -- this pass's raw answers, by sensor name
  pass   = 4711,   -- counted by the reader, once per pass, before the runtimes are driven
  at     = 4711,   -- the pass `values` was filled in
  now    = 2355.5, -- the reader's clock for this pass, in seconds, set with `pass`
  reads  = true,   -- whether the reader's read falls due in this pass, set with `pass`
}
```

Three properties make it safe to read, and they are the whole of the contract:

- **`values` is raw.** It is the sensor's own answer, before the record's rounding, its watts
  inference and its fuel clamp — so a reader applies its own derivations and keeps its own
  numbers. A name the sensor answered nothing for is absent, which is what a reader has to see.
  So are `smartconsumption`, `smartfuel` and `fuel` whenever SmartFuel has handed consumption and
  fuel over in the same Lua state: the record does not ask those sensors then, and the dashboard
  takes the hand-over ahead of them as well.
- **`at == pass` is what makes an offer this pass's.** The reader counts the pass before the
  runtimes are driven, so a fill from a wakeup anywhere else in the same Lua state — a second
  widget's background work — carries the pass before it and can never be taken for this one's.
- **The table is created by a reader and by nobody else.** On a model that keeps the record from
  the service widget there is no such reader, nothing creates it, and the record offers nothing.

An offer is only taken on a pass where the reader reads as well. So while a reader is counting
passes — its `now` is less than one sampling interval old — the record **samples on the passes on which
the reader's read falls due**, and measures its 0.5 s on the reader's clock rather than its own: the
reader takes the time at the top of the pass and the record a little later, and a clock tick
between the two would otherwise put a sample one pass ahead of the read. The interval still
applies, so a reader whose read is due on every pass — the dashboard skips its read while it
shows a finished flight with the link gone, and its read clock then stands still — does not make
the record sample on every pass. Without a counting reader the record keeps its own clock.

The first sample of a flight is therefore taken on the first read after the arm rather than on
the arm itself: normally within about half a second. Until then the statistic boxes and gauges'
maxima show no value through `Utils.statFromRecord`; Urban, Grid and Deck's own views still fall
back to the previous flight. A flight shorter than that records nothing. No background work runs
while the dashboard builds a scene, so on a theme that
draws the armed phase with a module of its own, the first sample follows that scene's build.

## When a flight starts and ends

On the flight controller's arm flag, as the event runtimes read it — the same edge the flight log
and the post-disarm reads already fire on. The arm edge opens a record; the disarm edge moves it to
`last` and starts an empty one. The record is closed **first** of everything that runs on the
disarm edge, so anything behind it in that chain reads a finished flight.

A link that goes down does **not** end the record. After a flight the pilot disarms and unplugs the
pack, and the post-flight page has to outlive that: its tiles read this record, so the statistics,
the flight time and the flight count stay as they were for as long as the link is down. The record
is dropped when the next session begins — when a link comes up again, which is, as far as anything
here can tell, a fresh pack — and the next arm edge opens a fresh `current` as it always has.

**A link lost while the craft is armed is not a new session when it comes back with the craft
still armed.** A pack is not swapped under a flying model, so the record, its clock and the flight
count are kept through the gap and the flight goes on: one flight, with its statistics from both
sides of the gap, and the flight log's line for it at the disarm. Whether the craft is still armed
is taken from an arm reading the radio has received since the link came back — the reading from
before the gap is what the radio keeps answering until the next one arrives, so it cannot say. A
craft that turns out to have disarmed in the gap ends the flight with no line in the flight log,
as there is no honest end to it, and a session begins as above. So does a link after which no arm
reading arrives within 5 s; the arm edge then opens a fresh record if the craft is armed.

The readings the statistics are taken from are dropped at the same moment. Within a session a
sensor that answers nothing in a pass leaves its previous reading standing; across a new connection
it does not, so a model connected without a sensor the session before it had records nothing for
that sensor rather than the previous session's last value. A sensor that has not answered since
the connection came up leaves its statistics absent: a model without an ESC temperature or altitude
sensor records nothing for it rather than 0, and the first sample does not take a 0 for a sensor
not found yet. Until this was changed, a reconnect
cleared the statistics but kept those readings, and a missing sensor's last value from the session
before went into the new flight's maxima and minima. The powered gate above reads the same values,
so an inherited throttle-hold state would have kept it shut for the whole session. The voltage-sag
detector's pack — its cell count and its line — is cleared with them, and is resolved again on the
next arm edge.

## The two totals — what changed, and why they can go down

**The total flight time now means something else than it used to, and a tile showing it will jump.**
It used to be the armed seconds *this dashboard widget instance* had counted since it was created:
never stored, so it started at zero every time the widget was built; undercounted, because the clock
only advanced in a pass where telemetry had changed; and separate per placement, so two dashboards
disagreed. It is now the **flight controller's lifetime total for this model** — the board's own
`stats_total_time_s`, which it keeps across power cycles — plus the flight in progress while armed.
A pilot who saw this session's minutes on that tile will now see the machine's hours.

The flight count moved the same way and for the same reason: it is the board's count, not one this
widget kept.

`flights` and `totalSeconds` therefore come from the **flight controller**; `totalSeconds` has the
flight in progress added to it, since the board has not been told about that one yet. Until the
board has answered — an older firmware, a read that failed, the counter switched off on the board —
the suite falls back to what it has seen itself in this session.

The board adds a flight only once its armed time passes the board's own minimum
(`stats_min_armed_time_s`, 15 s by default; the whole counter can be switched off on the board). So
a very short flight can be counted by the suite and not by the board, and the totals can **fall** by
that flight at the moment the board is read again after the disarm. That is the board's definition,
and the suite reports what the board says rather than arguing with it.

## Reading it from a theme

A dashboard theme reads the record through the box's own `stattype`, which is the supported route:

```lua
{ type = "text", subtype = "stats", source = "rpm", stattype = "max" }
```

A theme that reaches into the widget state directly can use `state.flight`, which is the same table
as `rfsuite.session.flight`.

`stattype` resolves a **box source** — a telemetry reading — to that reading's recorded extreme,
so it reaches `maxRpm` and `minRpm` but not the two sag keys or the per-profile headspeed keys: a
sag count is not an extreme of anything the pilot can put on a tile as a live value, and there is
no telemetry reading called "headspeed on PID profile 1". A theme that wants them reads them off
the record by name — `sagCount` here, `maxRpmP1` and the rest the same way:

```lua
{ type = "text", value = function(_, state)
    local flight = state and state.flight
    local record = flight and (flight.current.sagCount ~= nil and flight.current or flight.last)
    return record and record.sagCount
  end }
```

**Deprecated:** before the record had an owner it lived on the dashboard widget's state as flat
fields — `currentFlightMaxRpm`, `lastFlightMaxRpm`, `lastMinVoltage` and the rest. Those names still
answer, mapped onto the record, so a theme written against them keeps working. They are deprecated:
new themes should read `state.flight` or use `stattype`.
