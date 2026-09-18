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

*Configuration* → *Wizards* → *Setup Assistant* → *Complete run*, *Radio* or *Flight controller*

Hidden until *System* → *Settings* → *General* → *Preview* → *Setup Assistant* is on. Greyed out
until the flight controller answers. Read-only while the model is armed.

The three entries are not shortcuts into one walk: each opens the same assistant bounded to one
section, with the same steps and the same completion criteria. A step that is already done on
both sides is shown as done rather than asked again.

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
| Link | Packet rate and telemetry ratio, read from the transmitter module and from the flight controller and set on either side. |
| Name | The model name on the flight controller. |
| Orientation | The board's mounting angles. It comes before the calibration because a calibration against an orientation that is not yet active calibrates the wrong thing. |
| Accelerometer | Level calibration, with the flight controller's reported calibration state shown beside it. The machine has to be in its own frame and level; calibrating on a workbench calibrates the workbench. |
| Done for now | What this assistant has not set up and where the rest of it is: the drivetrain, the servos and the swashplate. |

## Notes

- **Nothing on the Link step writes while the model is armed.** The assistant's own menu entry is
  locked while armed, but a step that was already open stays open across the arming edge. Both
  *use this* buttons and the two pickers are refused for as long as the model is armed, and a
  transfer that was already running is abandoned rather than finished.
- **The channels the assistant lays out are CH5 to CH8 and the four stick channels.** It replaces
  every mixer line and every input line on the channels it writes, which the channel screen says
  before it does so.
- **The output stage of CH5 to CH8 has to be at its defaults**, and only of those four. The
  assistant tells the flight controller absolute microsecond windows, and what a channel finally
  puts on the wire is the mixer value after its output stage. A channel whose end points, subtrim,
  centre offset or output curve have been moved cannot produce those microseconds: it is refused on
  the Write screen, it is not counted as laid out, and the channel screen says so. Set the end
  points back to -100 and +100 with no subtrim, centre offset or curve on the transmitter's own
  outputs page. A reverted channel is the exception and needs nothing: the assistant reads the
  direction and writes every line's weight to match it.
  **The four stick channels are not covered by this** -- their output stage is the pilot's servo
  travel and the assistant neither reads it nor asks for it back.
- **Nothing is written before the Write step.** Every earlier screen reads, proposes or measures.
  The one exception is the Sticks step, which writes the four stick channels because its own check
  is what proves them.
- **A row that says *blocked* is a row that will not be written**, and the reason is on the screen
  the answer belongs to: no switch chosen, a switch with too few positions, a channel the flight
  controller's map puts no aux slot on, or an output stage that cannot carry the window. The
  Profile channel is also blocked where the flight controller has no free adjustment slot left for
  each of the two functions it needs.
- **The assistant never selects a model.** EdgeTX registers no model-selection function for Lua, so
  every write lands on the model that is open.

## Related

- [Rotorflight documentation](https://www.rotorflight.org/docs/)

*Documented against RFSuite 0.1.7.*
