---
title: ESC status
sidebar_label: ESC status
---

# ESC status

A dashboard box can show what the speed controller says about its own health, in words a pilot
can read at arm's length: *OK*, *OVERHEAT*, *THROTTLE LOST*, *BEC UNDERVOLTAGE*. This page says
where that comes from, what has to be switched on before it can appear at all, and what each
family of controller is able to report.

Nothing here is configured on the radio. There is no setting for it: a theme that shows the line
shows it, and a theme that does not costs nothing for it.

## Two sensors on the flight controller, and neither is on by default

The reading is decoded from two of the flight controller's own telemetry values:

| Sensor | On the Telemetry page | What it carries |
| --- | --- | --- |
| `Esc#` | *ESC1 Model* | which telemetry protocol the controller speaks |
| `EscF` | *ESC1 Status* | the controller's status word |

Both have to be in the flight controller's telemetry sensor list, on
[*Setup* → *Telemetry*](../pages/setup/telemetry.md), before they exist on the radio at all —
and neither is a value the suite needs for anything else, so on most models neither is selected.
*Diagnostics* → *Validate Sensors* lists them under those two labels, which is the quickest way
to see whether a radio has them.

**Both are needed.** The status word has no common layout: each manufacturer's protocol assigns
its own bits, so without the model byte there is nothing to read the word against. With only the
model byte the box reports *NO STATUS*; with neither it draws `--`.

## Not every controller reports a status word

The flight controller recognises fifteen protocol signatures. Ten of them fill a status word —
through eight decoders, because XDFly, OMP Hobby and ZTW share one — and for the other five it
never touches the word. A protocol that fills none leaves a zero standing, and a zero from those
is not a clean bill of health, so they report **NO STATUS** rather than *OK*, which would be a
claim nothing supports.

| Controller | Reports a status word | What is decoded from it |
| --- | --- | --- |
| Kontronik | yes | 24 error and warning flags, the widest layout of any of them |
| Hobbywing V5 | yes | 8 fault codes, every one of them a fault the controller acted on |
| Scorpion | yes | 6 error flags |
| Graupner | yes | 7 warning flags |
| APD | yes | 5 fault flags; the protocol's *motor started* bit is a running motor, not a fault, and is not reported |
| OpenYGE | yes | not flags: a motor state and a warning code sharing one byte, see below |
| FlyRotor | yes | that something is being reported, and nothing more — the layout is not published |
| XDFly, OMP Hobby, ZTW | yes | the same: that something is being reported |
| Hobbywing V4 | no | — |
| BLHeli32, BLHeli_S, AM32, Goosky | no | — |
| Castle | no | — |

**OpenYGE is read differently on purpose.** Its byte holds the motor state in one half and a
warning code in the other, and three of its four codes are only a failure in certain motor
states — an over-temperature warning while the motor is running is a warning; the same code with
the power cut is a fault. Its fourth case is a warning code of zero, which means an overvoltage
if and only if the power is cut. All of that is followed rather than flattened, and the code also
says whether the indicator is about the controller or about its BEC.

## Three levels

Each reading carries a severity, which a theme uses to colour the line:

| Level | Meaning |
| --- | --- |
| 1 | nothing wrong, or nothing the controller can tell us |
| 2 | a warning, or a limit the controller has reached |
| 3 | a fault the controller has acted on |

There is no level 0: where nothing answered there is no level at all, which is the same reading as
the box drawing `--`.

Where the manufacturer's protocol says *error* or *protection*, the reading is a fault. Where it
says *warning* or *limit reached*, it is a warning. Where it says neither, a named voltage,
current or temperature fault is a fault and a condition that only reports a state is a warning —
and where a protocol calls its whole field *warning flags*, as Graupner does, every one of them
is a warning however it reads on its own.

## Two readings, because "now" and "this flight" are different questions

The same decode answers both, and a theme picks the one its own surface promises.

**The reading on file is the worst since the flight controller connected.** A controller that cut
power for half a second and recovered has told you why the flight ended, and a dashboard pass is
slower than a fault: a reading shown only while it lasts is a reading nobody sees. The record is
dropped when the widget starts a new session with a flight controller — which for a pilot means
switching the model off and on, not landing.

**One reading is deliberately not written into that record.** A controller that has to be
restarted before parameters just written to it take effect reports that in place of its model
byte, and the flight controller withdraws it again on the very next telemetry frame. That is a
passing request rather than a state, so it is never put on file, and a fault already on file
outranks it. Nor is a *NO STATUS* that only means the status word has not arrived yet — the
model byte can arrive first — so the first real reading replaces it, and a status word that
stops arriving leaves the record as it was.

**The live reading is what the controller is saying on this pass, and nothing more.** It follows
the status word down as well as up, so a fault the controller has cleared stops being shown; the
restart request above is part of it, because a request that stands right now is exactly what an
unlatched reading is for. Where nothing answered there is no live reading either.

**Neither replaces the other, and mixing them up is how a surface comes to lie.** A line a pilot
reads as *what is wrong with my machine* has to be the live one, or it holds an alarm the
controller withdrew. A row a pilot reads as *what has this flight seen* has to be the one on file,
or it loses the fault that ended the flight. Both are offered so that a theme can show both at
once, which is what a status line above a value row is.

## Where the layouts are

One file: `src/rfsuite/lib/esc_status.lua`, one table per protocol, and a comment on each saying
which of the manufacturer's own words the severity came from. It is a pure decoder — two bytes in,
one verdict out — so a new protocol is a new table and nothing else.

A theme declares a reading as a box source; the four names and how to colour a box from a level
are in [dashboard themes](../developer/dashboard-themes.md).

## Related

The meaning of an individual condition is the controller manufacturer's and the flight
controller's, not the suite's. For what the flight controller does with a status word, and for
which ESC telemetry protocol to set, see the
[Rotorflight documentation](https://doc.rotorflight.org/).
