---
title: Setup Assistant
sidebar_label: Setup Assistant
sidebar_position: 10
---

# Setup Assistant

A guided run through the first setup of a bare flight controller and the transmitter side that
reaches it. It proposes, shows on one screen what it is about to do, and writes only after a
press.

## Where to find it

The old Setup Assistant is no longer listed under *Configuration* → *Wizards*.
Its menu definitions, page code and transmitter templates remain in the repository
for reuse. The former entries were *Complete run*, *Radio* and *Flight controller*;
the behaviour below documents that retained implementation.

The three entries are not shortcuts into one walk: each opens the same assistant bounded to one
section, with the same steps and the same completion criteria. A step that is already done on
both sides is shown as done rather than asked again.

Each entry opens on an overview: one row per step with its state and an *Open* button, and
*Continue*, which starts the walk -- at *About* on the *Complete run* and *Radio* entries -- and
passes over the steps that are already done. Where the list does not fit the screen
it is cut into pages and the heading shows which one is on screen (*1/2*); the button beside *Close*
then reads *Next* and turns to the next page, and reads *Continue* on the last one. Back turns a
page back, and on the first page it leaves the assistant.

## Steps

| Step | What it does |
| --- | --- |
| About | What the assistant does, what it will not touch, and that nothing is written before the Write step. |
| Channel map | Reads the flight controller's channel map and shows which wire channel carries which control. Everything later is derived from this map, so "arming is on channel five" is a result rather than a constant. |
| Layout | Which of the optional channels this run should lay out. The four sticks and the required channels are not optional. |
| Sticks | Writes the four stick inputs and their channels and switches the flight-mode trims off, then checks each one end to end: move the stick, and the flight controller has to report the movement arriving. |
| CH5 Arming | The switch position that arms the model. Writes the input, the mixer line and the flight controller's mode range. |
| CH6 Throttle hold | Two answers: the switch position that holds the motor, and the three-position governor switch that drives it everywhere else. |
| CH7 Profile | A whole three-position switch, one position per profile. Needs two adjustment slots on the flight controller. |
| CH8 Rescue | The switch position that turns rescue on. Recommended rather than required. |
| Write | The plan for every channel of the run on one screen, each row marked *ready* or *blocked*, and one press that writes the transmitter and the flight controller as one act. A blocked row is skipped and nothing about it reaches the board. The screen that follows compares what the board reports against the switch being held. |
| Link | Packet rate and telemetry ratio, read from the transmitter module and from the flight controller and set on either side. Where the two differ, each row has a *use this* button, which asks before it writes. |
| Name | The model name on the flight controller. |
| Orientation | The board's mounting angles. It comes before the calibration because a calibration against an orientation that is not yet active calibrates the wrong thing. |
| Accelerometer | Level calibration, with the flight controller's reported calibration state shown beside it. The machine has to be in its own frame and level; calibrating on a workbench calibrates the workbench. |
| Done for now | What this assistant has not set up and where the rest of it is: the drivetrain, the servos and the swashplate. |

## Notes

- **Nothing on the Link step writes while the model is armed, or after it on an answer given
  before it.** The assistant's own menu entry is locked while armed, but a step that was already
  open stays open across the arming edge. A *use this* or a picker that is started while the model
  is armed, or that is still running when it is armed, does not resume at the disarm: it stops
  there, sends nothing more, and the Probe row reads *Stopped: model was armed*. A write that had
  already left before the arming is not undone. *Read* is refused while the model is armed, and a
  probe that had already started its walk when the model was armed stops the same way. This rests on the flight controller's arming
  flags reaching the radio as telemetry: an arming between two readings of them is not seen, and
  without them the radio cannot tell at all (see *Tools > Diagnostics > ELRS Link*).
- **Both *use this* buttons on the Link step ask before they write.** One sets the transmitter
  module's packet rate and telemetry ratio to the flight controller's, the other writes the flight
  controller's telemetry configuration to match the module and saves it. The question is the one
  *Tools > Diagnostics > ELRS Link* asks before the same two writes, followed by both rows as the
  step shows them, and where the arming state cannot be read it asks that as well. Declining it
  writes nothing and the Probe row says *Nothing was written*; a radio
  that cannot show the question writes nothing either. The two pickers write without a question:
  there the value is the one the pilot picked.
- **The channels the assistant lays out are CH5 to CH8 and the four stick channels.** It replaces
  every mixer line and every input line on the channels it writes, which the channel screen says
  before it does so. Each channel has a fixed input -- the sticks I1 to I4, CH5 to CH8 I5 to I8 --
  and another channel's mixer line may use the same input. Where one does, *Set up* on the Sticks
  step and *Write* ask first and name the input and those channels, because after the write they
  follow the new input. Declining writes nothing and the screen says *Nothing was written*; a
  radio that cannot show the question writes nothing either.
- **A channel counts as done when the flight controller acts on it the way this assistant
  writes it.** For CH5 and CH8 that is a mode range on the channel's aux slot in the window the
  assistant writes, 1700 to 2100 µs, and none for the same mode on that slot in another window --
  the window, not the presence of a range, decides which switch position arms. A range in another
  window leaves the channel open, and *Write* moves that range rather than adding a second one.
  For CH7 it is both profile adjustments read from the channel's own aux slot over its whole
  travel, onto profiles 1 to 3; after *Write* has moved one, the step reads the slots again before
  CH7 counts as done.
- **The output stage of CH5 to CH8 has to be at its defaults**, and only of those four. The
  assistant tells the flight controller absolute microsecond windows, and what a channel finally
  puts on the wire is the mixer value after its output stage. A channel whose end points, subtrim,
  centre offset or output curve have been moved cannot produce those microseconds: it is refused on
  the Write screen, it is not counted as laid out, and the channel screen says so. Set the end
  points back to -100 and +100 with no subtrim, centre offset or curve on the transmitter's own
  outputs page. A reverted channel is the exception and needs nothing: the assistant reads the
  direction and writes every line's weight to match it.
  **The four stick channels are not covered by this** -- their output stage is the pilot's servo
  travel and the assistant neither reads it nor asks for it back. Naming a stick channel keeps
  its output stage as it is, its output curve included.
- **Nothing is written before the Write step.** Every earlier screen reads, proposes or measures.
  The one exception is the Sticks step, which writes the four stick channels because its own check
  is what proves them.
- **A row that says *blocked* is a row that will not be written**, and the reason is on the screen
  the answer belongs to: no switch chosen, a switch with too few positions, a channel the flight
  controller's map puts no aux slot on, or an output stage that cannot carry the window. The
  Profile channel is also blocked where the flight controller has no free adjustment slot left for
  each of the two functions it needs, and where an adjustment slot did not answer while the step
  read them and one of the two has not been found: the missing slot may already hold it. Opening the step again reads them
  again.
- **Orientation writes only what it has read.** The step sends all three alignments back -- the
  board's, the second gyro's and the magnetometer's -- with only the first changed. Where the
  flight controller does not answer the read, the step says *could not be read* and writes
  nothing.
- **The assistant never selects a model.** EdgeTX registers no model-selection function for Lua, so
  every write lands on the model that is open.
- **Why the Link step exists.** The flight controller does not measure the link: it is told the
  packet rate and telemetry ratio and paces every telemetry frame it sends from that pair. Told more
  than the link carries, it schedules more than drains away -- a backlog, dropped frames, values
  that are stale rather than missing. Told less, bandwidth stays unused. Both read as laggy
  telemetry, and neither side reports an error. This holds in both CRSF telemetry modes, Native and
  Custom.
- **What the Link step shows and writes.** *Probe* is the state of the current or last read or
  write, and *Read* reads the flight controller and the transmitter module again. The *Flight
  controller* row shows the pair it is set to, followed by *native* where its CRSF telemetry runs in
  Native mode; the *Transmitter module* row shows the pair the module runs. Where the two agree,
  both rows say so. Where they differ, each row carries a *use this* button. On the flight
  controller's row it sets the module's packet rate and telemetry ratio to the flight controller's,
  each one only where the module offers that value. On the module's row it writes the module's pair
  to the flight controller, switches its CRSF telemetry to Custom mode and saves it. *Packet rate*
  and *Telemetry ratio* are shown where the module reports the setting and set the module directly;
  they offer this suite's own list, reduced to what the module offers, or the module's whole list
  where it offers none of them. After a write to the module, the module row shows the new values
  once *Read* has read the module again. Leaving the Link step -- for another step, the overview,
  or by closing the assistant -- stops its current module read and clears that read's result; open
  the step and press *Read* to start a new one.

## Related

- [Rotorflight documentation](https://doc.rotorflight.org/)

*Documented against RFSuite 0.1.7.*
